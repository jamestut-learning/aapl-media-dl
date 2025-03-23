import ArgumentParser
import Foundation
import NIOFileSystem

enum DownloadOutputKind: String, CaseIterable {
    case audio = "audio"
    case video = "video"
}

@main
final class Program: AsyncParsableCommand {
    @Argument(help: "URL of the main (primary) M3U8 to download")
    var url: String

    @Argument(help: "Output directory")
    var outputDir: String

    func run() async throws {
        guard let mainPlaylistUrl = URL(string: url) else {
            print("Invalid URL")
            throw ExitCode(1)
        }

        async let mainPlaylistContent = httpDownloadAsString(from: mainPlaylistUrl)
        print("Downloading main playlist ...")
        let (audioTrackList, videoTrackList) = parseMainPlaylist(
            content: try await mainPlaylistContent)

        guard audioTrackList.count > 0 && videoTrackList.count > 0 else {
            print("No audio or video tracks found.")
            throw ExitCode(1)
        }

        // ask user input for selected audio track
        print("The following audio track\(audioTrackList.count > 1 ? "s" : "") are available:")
        for (index, audioInfo) in audioTrackList.enumerated() {
            print("  \(index + 1). ", terminator: "")
            if let p = audioInfo.groupId {
                print("\(p): ", terminator: "")
            }
            print(audioInfo.description ?? "(unknown description)")
        }
        guard let audioSelIndex = Program.askForInput(audioTrackList.count) else { return }
        let selAudioTrack = audioTrackList[audioSelIndex]

        // ask user input for selected video track
        // if we have a defined audio group ID, hide videos that does not have a matching audio group ID
        var filteredVideoTrackList =
            selAudioTrack.groupId == nil
            ? videoTrackList
            : videoTrackList.compactMap { streamInfo in
                streamInfo.audioGroupId == selAudioTrack.groupId ? streamInfo : nil
            }
        guard filteredVideoTrackList.count > 0 else {
            print(
                "No matching video track for the selected audio group ID '\(selAudioTrack.groupId ?? "(none)")'"
            )
            return
        }
        // sort by bandwidth from largest to smallest
        filteredVideoTrackList.sort { a, b in
            a.bandwidth > b.bandwidth
        }

        // formatter for video bandwidth
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        fmt.countStyle = .binary
        print(
            "The following video track\(filteredVideoTrackList.count > 1 ? "s" : "") are available:"
        )
        for (index, streamInfo) in filteredVideoTrackList.enumerated() {
            let byteRate = "\(fmt.string(fromByteCount: Int64(streamInfo.bandwidth / 8)))/s"
            print("  \(index + 1). \(streamInfo.resolution) (\(byteRate)", terminator: "")
            if let p = streamInfo.videoRange {
                print(" \(p)", terminator: "")
            }
            print(")")
        }
        guard let videoSelIndex = Program.askForInput(filteredVideoTrackList.count) else { return }
        let selVideoTrack = filteredVideoTrackList[videoSelIndex]

        // create the output and working directories
        let outputDir = URL(filePath: self.outputDir)
        let workDir = outputDir.appending(component: "work")
        for kind in DownloadOutputKind.allCases {
            let workDirForKind = workDir.appending(component: kind.rawValue)
            do {
                try FileManager.default.createDirectory(
                    at: workDirForKind, withIntermediateDirectories: true)
            } catch {
                print("Error creating working directory")
                throw error
            }
        }

        guard
            let audioPlaylistUrl = URL(string: selAudioTrack.urlString, relativeTo: mainPlaylistUrl)
        else {
            print("Bad audio playlist URL")
            throw URLError(.badURL)
        }
        async let audioPlaylistData = httpDownloadAsString(from: audioPlaylistUrl)
        guard
            let videoPlaylistUrl = URL(string: selVideoTrack.urlString, relativeTo: mainPlaylistUrl)
        else {
            print("Bad video playlist URL")
            throw URLError(.badURL)
        }
        async let videoPlaylistData = httpDownloadAsString(from: videoPlaylistUrl)

        // (category, output file, HTTP URL)
        var downloadList: [(DownloadOutputKind, String, URL)] = []
        do {
            for (kind, parentUrl, content) in [
                (DownloadOutputKind.audio, audioPlaylistUrl, try await audioPlaylistData),
                (DownloadOutputKind.video, videoPlaylistUrl, try await videoPlaylistData),
            ] {
                downloadList.append(
                    contentsOf: try parseVodSegmentPlaylist(content: content).map { v in
                        guard let url = URL(string: v, relativeTo: parentUrl) else {
                            print("Bad chunk URL: \(v)")
                            throw URLError(.badURL)
                        }
                        return (kind, v, url)
                    })
            }
        } catch {
            print("Error downloading playlist: \(error)")
            throw ExitCode(1)
        }

        // now begin the parallel download
        print("Downloading \(downloadList.count) segments ...")
        let progressPrinter = await ProgressPrinter(maximum: downloadList.count)
        await progressPrinter.startPrint()
        let downloaderSession = StreamedDownloaderSession()
        for downloadTask in downloadList {
            let (kind, outFileName, url) = downloadTask
            let taskWorkPath = workDir.appending(components: kind.rawValue, outFileName)
            try await downloaderSession.download(from: url, to: urlToPath(taskWorkPath))
            await progressPrinter.progress()
        }
        await progressPrinter.stop(finish: true)
        print("Download finished!")

        // // combine the files
        print("Combining segments ...")
        var outputFileHandleStore: [DownloadOutputKind: WriteFileHandleWrapper] = [:]
        for downloadTask in downloadList {
            let (kind, outFileName, _) = downloadTask
            if outputFileHandleStore[kind] == nil {
                let outputPath = outputDir.appending(component: "\(kind.rawValue).mp4")
                outputFileHandleStore[kind] = WriteFileHandleWrapper(
                    try await FileSystem.shared.openFile(
                        forWritingAt: FilePath(urlToPath(outputPath)),
                        options: .newFile(replaceExisting: true)))
            }
            let segmentFilePath = workDir.appending(components: kind.rawValue, outFileName)
            try await FileSystem.shared.withFileHandle(
                forReadingAt: FilePath(urlToPath(segmentFilePath))
            ) { segmentFile in
                let outputWriter = outputFileHandleStore[kind]!
                for try await chunk in segmentFile.readChunks() {
                    try await outputWriter.writer.write(contentsOf: chunk)
                }
            }
        }

        for (_, wrp) in outputFileHandleStore {
            try await wrp.writer.flush()
            try await wrp.handle.close()
        }

        print("Cleaning up work directory ...")
        try await FileSystem.shared.removeItem(at: FilePath(urlToPath(workDir)), recursively: true)

        print("Done!")
    }

    private func urlToPath(_ url: URL) -> String {
        return url.path(percentEncoded: false)
    }

    private static func downloadPlaylist(from fromUrl: URL?, relativeTo: URL? = nil) async throws
        -> String?
    {
        guard let fromUrl else { return nil }
        let resolvedUrl =
            if let relativeTo {
                URL(string: fromUrl.relativeString, relativeTo: relativeTo)
            } else {
                fromUrl
            }
        guard let resolvedUrl else {
            throw URLError(.badURL)
        }
        return try await httpDownloadAsString(from: resolvedUrl)
    }

    private static func askForInput(_ max: Int) -> Int? {
        while true {
            print("Enter selection (0 to cancel): ", terminator: "")
            guard let rd = readLine() else {
                print("Please enter a selection!")
                continue
            }
            guard let selIndex = Int(rd) else {
                print("Please enter a valid integer!")
                continue
            }
            guard selIndex >= 0 else {
                print("Please enter a positive number!")
                continue
            }
            guard selIndex > 0 else {
                // selIndex == 0: user cancelled the operation
                return nil
            }
            guard selIndex <= max else {
                print("Please enter a number from 1 to \(max)!")
                continue
            }
            return selIndex - 1
        }
    }
}

final class WriteFileHandleWrapper {
    public var handle: WriteFileHandle
    public var writer: BufferedWriter<WriteFileHandle>

    init(_ handle: WriteFileHandle) {
        self.handle = handle
        self.writer = handle.bufferedWriter()
    }
}

@MainActor
final class ProgressPrinter {
    private static let frequencyMs: Int = 250

    private let maximum: Int
    private var value: Int = 0

    private var printTask: Task<Void, Error>?

    init(maximum: Int) {
        self.maximum = maximum
    }

    func progress(increment: Int = 1) {
        guard increment >= 1 else { return }
        value += increment
    }

    func stop(finish: Bool = true) {
        guard let printTask = self.printTask else { return }
        printTask.cancel()
        self.printTask = nil
        if finish {
            doPrint(val: maximum)
            doPrint(val: nil)
        }
    }

    func startPrint() {
        guard self.printTask == nil else { return }
        printTask = Task {
            var lastVal = -1
            while true {
                let ss = value
                if ss != lastVal {
                    doPrint(val: ss)
                    lastVal = ss
                }
                if lastVal >= maximum {
                    doPrint(val: nil)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func doPrint(val: Int?) {
        if let val {
            print("\r(\(val)/\(maximum))", terminator: "")
            fflush(stdout)
        } else {
            print()
        }
    }
}
