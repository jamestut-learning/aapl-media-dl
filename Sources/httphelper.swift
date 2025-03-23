import Foundation
import NIO
import NIOFileSystem
import AsyncHTTPClient

func httpDownloadAsString(from url: URL) async throws -> String {
    let (data, response) = try await URLSession.shared.data(from: url)

    guard let httpResponse = response as? HTTPURLResponse
    else {
        throw URLError(.badServerResponse)
    }

    // maybe redirect
    if (300...399).contains(httpResponse.statusCode) {
        if let redirectURLString = httpResponse.allHeaderFields["Location"] as? String {
            return try await httpDownloadAsString(from: redirectURLString)
        }
    }

    // return code must be OK before we proceed
    guard (200...299).contains(httpResponse.statusCode) else {
        throw URLError(.badServerResponse)
    }

    guard let string = String(data: data, encoding: .utf8) else {
        throw URLError(.cannotDecodeContentData)
    }

    return string
}

func httpDownloadAsString(from urlString: String) async throws -> String {
    guard let url = URL(string: urlString) else {
        throw URLError(.badURL)
    }
    return try await httpDownloadAsString(from: url)
}

final class StreamedDownloaderSession: Sendable {
    private let httpClient: HTTPClient

    init() {
        var config = HTTPClient.Configuration()
        config.decompression = .enabled(limit: .none)
        config.enableMultipath = true
        config.httpVersion = .http1Only
        config.maximumUsesPerConnection = nil
        config.redirectConfiguration = .follow(max: 16, allowCycles: false)
        self.httpClient = HTTPClient(eventLoopGroupProvider: .singleton, configuration: config)
    }

    deinit {
        try? self.httpClient.syncShutdown()
    }

    func download(from url: URL, to filePath: String) async throws {
        // skip download if file exists
        guard !FileManager.default.fileExists(atPath: filePath) else {
            return
        }

        let request = HTTPClientRequest(url: url.absoluteString)
        let response = try await httpClient.execute(request, timeout: .seconds(15))
        guard response.status == .ok else {
            throw URLError(.badServerResponse)
        }

        // create work file
        let workFilePath = "\(filePath)-work"
        // open file for writing
        try await FileSystem.shared.withFileHandle(forWritingAt: FilePath(workFilePath), options: .newFile(replaceExisting: true)) { fh in
            var writer = fh.bufferedWriter()
            for try await buff in response.body {
                try await writer.write(contentsOf: buff)
            }
            try await writer.flush()
        }

        // download OK: rename file
        try FileManager.default.moveItem(atPath: workFilePath, toPath: filePath)
    }
}
