import Foundation

struct AudioInfo {
    var groupId: Substring?
    var description: Substring?
    var urlString: String
}

struct StreamInfo {
    var bandwidth: Int
    var resolution: Substring
    var videoRange: Substring?
    var audioGroupId: Substring?
    var urlString: String
}

func parseMainPlaylist(content: String) -> ([AudioInfo], [StreamInfo]) {
    var audioTrackList = [AudioInfo]()
    var videoTrackList = [StreamInfo]()

    // populate audioTrackList and videoTrackList
    var lastStreamInfo: StreamInfo? = nil
    var parserState: MainParserState = .ready
    for line in content.components(separatedBy: .newlines) {
        switch parserState {
        case .ready:
            if line == Constants.M3U8_HDR {
                parserState = .headerFound
            }

        case .headerFound:
            if line.starts(with: Constants.M3U8_EXT_MEDIA_HDR) {
                let extMediaEntries = getEntryProperties(
                    line.dropFirst(Constants.M3U8_EXT_MEDIA_HDR.count))
                guard extMediaEntries["TYPE"] == "AUDIO" else {
                    continue
                }
                guard let uri = extMediaEntries["URI"] else {
                    continue
                }
                audioTrackList.append(
                    AudioInfo(
                        groupId: extMediaEntries["GROUP-ID"],
                        description: extMediaEntries["NAME"],
                        urlString: String(uri)))
            } else if line.starts(with: Constants.M3U8_EXT_STREAM_HDR) {
                let extStreamEntries = getEntryProperties(
                    line.dropFirst(Constants.M3U8_EXT_STREAM_HDR.count))
                // these information are mandatory: bandwidth and resolution
                guard
                    let bandwidthStr = extStreamEntries["AVERAGE-BANDWIDTH"]
                        ?? extStreamEntries["BANDWIDTH"]
                else {
                    continue
                }
                guard let bandwidth = Int(bandwidthStr) else {
                    print("Bandwidth value of '\(bandwidthStr)' is not an integer!")
                    continue
                }
                guard let resolutionStr = extStreamEntries["RESOLUTION"] else {
                    continue
                }
                lastStreamInfo = StreamInfo(bandwidth: bandwidth, resolution: resolutionStr, urlString: "")
                lastStreamInfo!.videoRange = extStreamEntries["VIDEO-RANGE"]
                lastStreamInfo!.audioGroupId = extStreamEntries["AUDIO"]
                parserState = .getStreamUrl
            }

        case .getStreamUrl:
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            if var lastStreamInfo {
                lastStreamInfo.urlString = line
                videoTrackList.append(lastStreamInfo)
            }
            lastStreamInfo = nil
            parserState = .headerFound
        }
    }

    return (audioTrackList, videoTrackList)
}

func parseVodSegmentPlaylist(content: String) -> [String] {
    var segments = [String]()

    var parserState: MainParserState = .ready
    for line in content.components(separatedBy: .newlines) {
        switch parserState {
        case .ready:
            if line == Constants.M3U8_HDR {
                parserState = .headerFound
            }

        case .headerFound:
            if line.starts(with: Constants.M3U8_EXT_MAP) {
                let extMapEntries = getEntryProperties(line.dropFirst(Constants.M3U8_EXT_MAP.count))
                if let uri = extMapEntries["URI"] {
                    segments.append(String(uri))
                }
            } else if line.starts(with: Constants.M3U8_SEGMENT_IND) {
                parserState = .getStreamUrl
            }

        case .getStreamUrl:
            segments.append(line)
            parserState = .headerFound
        }
    }

    return segments
}

fileprivate struct Constants {
    public static let M3U8_HDR = "#EXTM3U"
    public static let M3U8_EXT_MEDIA_HDR = "#EXT-X-MEDIA:"
    public static let M3U8_EXT_STREAM_HDR = "#EXT-X-STREAM-INF:"
    public static let M3U8_EXT_MAP = "#EXT-X-MAP:"
    public static let M3U8_SEGMENT_IND = "#EXT-X-BITRATE:"
}

fileprivate enum MainParserState {
    case ready
    case headerFound
    case getStreamUrl
}

fileprivate enum ExtMediaEntryType {
    case unknown
    case audio
}

fileprivate func getEntryProperties<StrType: StringProtocol>(_ entriesRaw: StrType)
        -> [Substring: Substring]
where StrType.SubSequence == Substring {
    let componentRe = /([A-Z\-]+)=(".+?"|.+?)(?:,|$)/
    let matches = entriesRaw.matches(of: componentRe)
    var ret = [Substring: Substring]()
    for match in matches {
        let (_, key, value) = match.output
        ret[key] = maybeUnquoteString(value)
    }
    return ret
}

fileprivate func maybeUnquoteString(_ s: Substring) -> Substring {
    if s.starts(with: "\"") {
        let r = s[s.index(after: s.startIndex)..<s.index(before: s.endIndex)]
        return r
    } else {
        return s
    }
}
