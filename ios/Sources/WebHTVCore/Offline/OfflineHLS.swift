import Foundation

// IOS-POC-47 — reading HLS playlists for a download (RFC 8216).
//
// The ad-skip code (`HLSAdsParser`, `HLSAdTimeline`) reads playlists to find ads in them; this
// reads them to copy one rendition of them, so it keeps what that needs and nothing else: every
// variant's declared attributes, the alternative renditions, and each media segment's address,
// duration, byte range, key, initialization section and discontinuity.

/// An attribute list (`NAME=value,NAME="quoted, with commas"`), RFC 8216 §4.2.
public enum HLSAttributes {
    public static func parse<S: StringProtocol>(_ text: S) -> [String: String] {
        var result = [String: String]()
        var index = text.startIndex
        while index < text.endIndex {
            guard let equals = text[index...].firstIndex(of: "=") else { break }
            let name = text[index..<equals].trimmingCharacters(in: .whitespaces).uppercased()
            var cursor = text.index(after: equals)
            var value = ""
            if cursor < text.endIndex, text[cursor] == "\"" {
                cursor = text.index(after: cursor)
                let close = text[cursor...].firstIndex(of: "\"") ?? text.endIndex
                value = String(text[cursor..<close])
                cursor = close < text.endIndex ? text.index(after: close) : close
                // Anything between the closing quote and the next comma is not part of a value.
                cursor = text[cursor...].firstIndex(of: ",") ?? text.endIndex
            } else {
                let comma = text[cursor...].firstIndex(of: ",") ?? text.endIndex
                value = text[cursor..<comma].trimmingCharacters(in: .whitespaces)
                cursor = comma
            }
            if !name.isEmpty { result[name] = value }
            index = cursor < text.endIndex ? text.index(after: cursor) : cursor
        }
        return result
    }
}

public struct HLSByteRange: Codable, Hashable, Sendable {
    public let length: Int64
    public let offset: Int64

    public init(length: Int64, offset: Int64) {
        self.length = length
        self.offset = offset
    }

    /// `Range: bytes=…`, inclusive at both ends.
    public var httpHeader: String { "bytes=\(offset)-\(offset + length - 1)" }
}

public struct HLSKey: Codable, Hashable, Sendable {
    /// `NONE`, `AES-128`, `SAMPLE-AES`, `SAMPLE-AES-CTR`.
    public let method: String
    public let uri: URL?
    public let iv: String?
    public let keyFormat: String?
    public let keyFormatVersions: String?

    public init(method: String, uri: URL?, iv: String? = nil, keyFormat: String? = nil, keyFormatVersions: String? = nil) {
        self.method = method
        self.uri = uri
        self.iv = iv
        self.keyFormat = keyFormat
        self.keyFormatVersions = keyFormatVersions
    }

    public var isNone: Bool { method.uppercased() == "NONE" }

    /// FairPlay (`com.apple.streamingkeydelivery`, `skd://`), or any other DRM system named by its
    /// KEYFORMAT (Widevine, PlayReady). Never downloaded: only Apple's own offline flow may persist
    /// FairPlay keys, and nothing here works around a license.
    public var isDRM: Bool {
        if uri?.scheme?.lowercased() == "skd" { return true }
        guard let format = keyFormat?.lowercased(), format != "identity" else { return false }
        return true
    }

    /// Plain AES-128: the key is an ordinary 16-byte file both engines decrypt with, which may be
    /// kept beside the segments.
    public var isClearAES128: Bool {
        method.uppercased() == "AES-128" && !isDRM && uri != nil
    }
}

public struct HLSMap: Codable, Hashable, Sendable {
    public let uri: URL
    public let byteRange: HLSByteRange?
}

public struct HLSSegment: Codable, Hashable, Sendable {
    public let uri: URL
    public let duration: Double
    public let title: String
    public let byteRange: HLSByteRange?
    public let discontinuity: Bool
    public let key: HLSKey?
    public let map: HLSMap?
    public let programDateTime: String?
    public let isGap: Bool
}

public struct HLSMediaPlaylist: Sendable, Equatable {
    public var version: Int?
    public var targetDuration: Int
    public var mediaSequence: Int
    public var discontinuitySequence: Int?
    public var playlistType: String?
    public var hasEndList: Bool
    public var independentSegments: Bool
    public var segments: [HLSSegment]

    public var duration: Double { segments.reduce(0) { $0 + $1.duration } }
    /// Every key the playlist uses, in order of first use.
    public var keys: [HLSKey] {
        var seen = Set<HLSKey>()
        return segments.compactMap(\.key).filter { seen.insert($0).inserted }
    }
}

public struct HLSVariant: Sendable, Equatable {
    public let uri: URL
    public let bandwidth: Int
    public let averageBandwidth: Int?
    public let width: Int?
    public let height: Int?
    public let codecs: [String]
    public let frameRate: Double?
    /// `SDR`, `PQ` or `HLG` (RFC 8216bis); nil when not declared.
    public let videoRange: String?
    public let audioGroup: String?
    public let subtitlesGroup: String?
    public let closedCaptions: String?
    /// Every attribute as written, for rebuilding the local master.
    public let attributes: [String: String]
}

public struct HLSRendition: Sendable, Equatable {
    public let type: String
    public let groupID: String
    public let name: String
    public let language: String?
    public let isDefault: Bool
    public let autoselect: Bool
    public let forced: Bool
    public let uri: URL?
    public let channels: String?
    public let characteristics: String?
    public let attributes: [String: String]
}

public struct HLSMasterPlaylist: Sendable, Equatable {
    public var version: Int?
    public var independentSegments: Bool
    public var variants: [HLSVariant]
    public var renditions: [HLSRendition]
    public var sessionKeys: [HLSKey]

    public func renditions(type: String, group: String?) -> [HLSRendition] {
        guard let group else { return [] }
        return renditions.filter { $0.type == type && $0.groupID == group }
    }
}

public enum HLSPlaylist: Sendable, Equatable {
    case master(HLSMasterPlaylist)
    case media(HLSMediaPlaylist)

    public enum ParseError: Error, Equatable {
        case notAPlaylist
    }

    /// Reads a playlist fetched from `base`. Relative URIs are resolved against it (RFC 3986), the
    /// way both engines resolve them.
    public static func parse(_ text: String, base: URL) throws -> HLSPlaylist {
        let lines = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first, first.hasPrefix("#EXTM3U") else { throw ParseError.notAPlaylist }
        let isMaster = lines.contains { $0.hasPrefix("#EXT-X-STREAM-INF") }
        return isMaster ? .master(master(lines, base: base)) : .media(media(lines, base: base))
    }

    static func resolve(_ raw: String, base: URL) -> URL? {
        URL(string: raw, relativeTo: base)?.absoluteURL
            ?? raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
                .flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
    }

    private static func value(_ line: String, _ tag: String) -> Substring? {
        guard line.hasPrefix(tag) else { return nil }
        let rest = line.dropFirst(tag.count)
        return rest.first == ":" ? rest.dropFirst() : rest
    }

    private static func key(_ attributes: [String: String], base: URL) -> HLSKey {
        HLSKey(method: attributes["METHOD"] ?? "NONE",
               uri: attributes["URI"].flatMap { resolve($0, base: base) },
               iv: attributes["IV"], keyFormat: attributes["KEYFORMAT"],
               keyFormatVersions: attributes["KEYFORMATVERSIONS"])
    }

    private static func master(_ lines: [String], base: URL) -> HLSMasterPlaylist {
        var playlist = HLSMasterPlaylist(version: nil, independentSegments: false, variants: [], renditions: [],
                                         sessionKeys: [])
        var pending: [String: String]?
        for line in lines {
            if let version = value(line, "#EXT-X-VERSION") {
                playlist.version = Int(version)
            } else if line.hasPrefix("#EXT-X-INDEPENDENT-SEGMENTS") {
                playlist.independentSegments = true
            } else if let attributes = value(line, "#EXT-X-STREAM-INF") {
                pending = HLSAttributes.parse(attributes)
            } else if let attributes = value(line, "#EXT-X-MEDIA") {
                let parsed = HLSAttributes.parse(attributes)
                guard let type = parsed["TYPE"]?.uppercased(), let group = parsed["GROUP-ID"] else { continue }
                playlist.renditions.append(HLSRendition(
                    type: type, groupID: group, name: parsed["NAME"] ?? "",
                    language: parsed["LANGUAGE"], isDefault: parsed["DEFAULT"]?.uppercased() == "YES",
                    autoselect: parsed["AUTOSELECT"]?.uppercased() == "YES",
                    forced: parsed["FORCED"]?.uppercased() == "YES",
                    uri: parsed["URI"].flatMap { resolve($0, base: base) },
                    channels: parsed["CHANNELS"], characteristics: parsed["CHARACTERISTICS"], attributes: parsed))
            } else if let attributes = value(line, "#EXT-X-SESSION-KEY") {
                playlist.sessionKeys.append(key(HLSAttributes.parse(attributes), base: base))
            } else if !line.hasPrefix("#"), let attributes = pending {
                pending = nil
                guard let uri = resolve(line, base: base) else { continue }
                let resolution = attributes["RESOLUTION"].flatMap(Self.resolution)
                playlist.variants.append(HLSVariant(
                    uri: uri, bandwidth: Int(attributes["BANDWIDTH"] ?? "") ?? 0,
                    averageBandwidth: attributes["AVERAGE-BANDWIDTH"].flatMap { Int($0) },
                    width: resolution?.0, height: resolution?.1,
                    codecs: (attributes["CODECS"] ?? "").split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                    frameRate: attributes["FRAME-RATE"].flatMap { Double($0) },
                    videoRange: attributes["VIDEO-RANGE"]?.uppercased(),
                    audioGroup: attributes["AUDIO"], subtitlesGroup: attributes["SUBTITLES"],
                    closedCaptions: attributes["CLOSED-CAPTIONS"], attributes: attributes))
            }
        }
        return playlist
    }

    static func resolution(_ text: String) -> (Int, Int)? {
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
        return (width, height)
    }

    /// `n[@o]`. A missing offset continues from the previous sub-range of the **same** resource
    /// (RFC 8216 §4.3.2.2); with no such range it starts at zero.
    private static func byteRange(_ text: Substring, uri: URL?, previous: (URL, HLSByteRange)?) -> HLSByteRange? {
        let parts = text.split(separator: "@")
        guard let length = Int64(parts.first ?? "") , length > 0 else { return nil }
        if parts.count > 1, let offset = Int64(parts[1]) { return HLSByteRange(length: length, offset: offset) }
        if let previous, let uri, previous.0 == uri {
            return HLSByteRange(length: length, offset: previous.1.offset + previous.1.length)
        }
        return HLSByteRange(length: length, offset: 0)
    }

    private static func media(_ lines: [String], base: URL) -> HLSMediaPlaylist {
        var playlist = HLSMediaPlaylist(version: nil, targetDuration: 0, mediaSequence: 0, discontinuitySequence: nil,
                                        playlistType: nil, hasEndList: false, independentSegments: false,
                                        segments: [])
        var duration: Double?
        var title = ""
        var rangeText: Substring?
        var discontinuity = false
        var currentKey: HLSKey?
        var map: HLSMap?
        var dateTime: String?
        var gap = false
        var previousRange: (URL, HLSByteRange)?
        for line in lines {
            if let version = value(line, "#EXT-X-VERSION") {
                playlist.version = Int(version)
            } else if let target = value(line, "#EXT-X-TARGETDURATION") {
                playlist.targetDuration = Int(Double(target) ?? 0)
            } else if let sequence = value(line, "#EXT-X-MEDIA-SEQUENCE") {
                playlist.mediaSequence = Int(sequence) ?? 0
            } else if let sequence = value(line, "#EXT-X-DISCONTINUITY-SEQUENCE") {
                playlist.discontinuitySequence = Int(sequence)
            } else if let type = value(line, "#EXT-X-PLAYLIST-TYPE") {
                playlist.playlistType = type.uppercased()
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                playlist.hasEndList = true
            } else if line.hasPrefix("#EXT-X-INDEPENDENT-SEGMENTS") {
                playlist.independentSegments = true
            } else if let info = value(line, "#EXTINF") {
                let comma = info.firstIndex(of: ",")
                duration = Double(info[..<(comma ?? info.endIndex)].trimmingCharacters(in: .whitespaces))
                title = comma.map { String(info[info.index(after: $0)...]) } ?? ""
            } else if let range = value(line, "#EXT-X-BYTERANGE") {
                rangeText = range
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY"), !line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
                discontinuity = true
            } else if let attributes = value(line, "#EXT-X-KEY") {
                let parsed = key(HLSAttributes.parse(attributes), base: base)
                currentKey = parsed.isNone ? nil : parsed
            } else if let attributes = value(line, "#EXT-X-MAP") {
                let parsed = HLSAttributes.parse(attributes)
                if let uri = parsed["URI"].flatMap({ resolve($0, base: base) }) {
                    let range = parsed["BYTERANGE"].flatMap { byteRange(Substring($0), uri: uri, previous: nil) }
                    map = HLSMap(uri: uri, byteRange: range)
                }
            } else if let date = value(line, "#EXT-X-PROGRAM-DATE-TIME") {
                dateTime = String(date)
            } else if line.hasPrefix("#EXT-X-GAP") {
                gap = true
            } else if !line.hasPrefix("#") {
                guard let uri = resolve(line, base: base) else { continue }
                let range = rangeText.flatMap { byteRange($0, uri: uri, previous: previousRange) }
                previousRange = range.map { (uri, $0) }
                playlist.segments.append(HLSSegment(
                    uri: uri, duration: duration ?? 0, title: title, byteRange: range,
                    discontinuity: discontinuity, key: currentKey, map: map, programDateTime: dateTime, isGap: gap))
                duration = nil
                title = ""
                rangeText = nil
                discontinuity = false
                dateTime = nil
                gap = false
            }
        }
        return playlist
    }
}

// MARK: - What a variant is

public extension HLSVariant {
    var codec: OfflineVideoCodec {
        let lowered = codecs.map { $0.lowercased() }
        if lowered.contains(where: { $0.hasPrefix("dvh1") || $0.hasPrefix("dvhe") || $0.hasPrefix("hvc1") || $0.hasPrefix("hev1") }) {
            return .hevc
        }
        if lowered.contains(where: { $0.hasPrefix("avc1") || $0.hasPrefix("avc3") }) { return .h264 }
        if lowered.contains(where: { $0.hasPrefix("av01") }) { return .av1 }
        if lowered.contains(where: { $0.hasPrefix("vp09") || $0.hasPrefix("vp9") }) { return .vp9 }
        return .unknown
    }

    var dynamicRange: OfflineDynamicRange {
        if codecs.contains(where: { $0.lowercased().hasPrefix("dvh1") || $0.lowercased().hasPrefix("dvhe") }) {
            return .dolbyVision
        }
        switch videoRange {
        case "PQ": return .hdr10
        case "HLG": return .hlg
        default: return .sdr
        }
    }

    /// Declares only audio codecs: an audio-only rendition of the programme.
    var isAudioOnly: Bool {
        guard !codecs.isEmpty, width == nil, height == nil else { return false }
        return codecs.allSatisfy { codec in
            let lowered = codec.lowercased()
            return ["mp4a", "ac-3", "ec-3", "fLaC", "opus", "alac"].contains { lowered.hasPrefix($0.lowercased()) }
        }
    }

    /// AVERAGE-BANDWIDTH when declared, else the peak BANDWIDTH.
    var effectiveBitrate: Int { averageBandwidth ?? bandwidth }

    var info: OfflineVideoInfo {
        OfflineVideoInfo(width: width ?? 0, height: height ?? 0, codec: codec, dynamicRange: dynamicRange,
                         frameRate: frameRate, bandwidth: bandwidth > 0 ? bandwidth : nil,
                         averageBandwidth: averageBandwidth)
    }
}
