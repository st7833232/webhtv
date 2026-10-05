import Foundation

/// IOS-POC-47 — one file to fetch for an asset: a media segment, an initialization section, a
/// clear AES-128 key, a WebVTT segment, or the single progressive file.
public struct OfflineDownloadUnit: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case segment, initSection, key, subtitleSegment, progressive }

    public let index: Int
    public let remoteURL: URL
    /// A sub-range of `remoteURL`, fetched into a file of its own.
    public let byteRange: HLSByteRange?
    /// Inside the asset's folder.
    public let relativePath: String
    public let role: Role
    /// IOS-POC-51: a segment's EXTINF duration, for projecting the package's size from the
    /// segments already here. Nil for keys and init sections, and in plans saved before.
    public let seconds: Double?

    public init(index: Int, remoteURL: URL, byteRange: HLSByteRange?, relativePath: String, role: Role,
                seconds: Double? = nil) {
        self.index = index
        self.remoteURL = remoteURL
        self.byteRange = byteRange
        self.relativePath = relativePath
        self.role = role
        self.seconds = seconds
    }
}

/// Everything an asset's download needs to run, or to run again after a restart: the files, the
/// local playlists that will point at them, and the request headers. Kept in the asset's
/// `download-plan.json` only while the download is unfinished — it holds signed addresses and
/// the source's headers, which nothing needs once the files are here.
public struct OfflinePackagePlan: Codable, Equatable, Sendable {
    public var units: [OfflineDownloadUnit]
    /// Relative path → playlist text. Written when every unit is in place.
    public var playlists: [String: String]
    public var package: OfflinePackageKind
    /// The stream's own address: credentials go only to its origin (`OfflineRequestPolicy`).
    public var origin: URL
    public var headers: [String: String]
    /// Sidecar subtitles (the source's own files), fetched while preparing.
    public var sidecars: [OfflineSidecarRequest]

    public init(units: [OfflineDownloadUnit], playlists: [String: String], package: OfflinePackageKind, origin: URL,
                headers: [String: String], sidecars: [OfflineSidecarRequest] = []) {
        self.units = units
        self.playlists = playlists
        self.package = package
        self.origin = origin
        self.headers = headers
        self.sidecars = sidecars
    }

    /// A fingerprint of the media timeline: the same count, durations and ranges means already
    /// downloaded files can be kept when a retry re-resolves the episode and gets fresh addresses.
    public var timelineFingerprint: [String] {
        units.map { "\($0.role.rawValue)|\($0.relativePath)|\($0.byteRange.map { "\($0.length)" } ?? "-")" }
    }

    /// IOS-POC-51: how much of the main track must be here before a projection replaces the
    /// estimate made from a few sampled segments.
    public static let projectionStart = 0.1

    /// The whole package's size projected from the files already here (`sizes`, by unit index):
    /// each timed track — the folder its segments are in: video, audio, subtitles — at the bytes per
    /// second its finished segments came to, over that track's whole duration, plus the untimed
    /// files already here. A track with nothing finished yet adds nothing. Nil until the longest
    /// track is `projectionStart` done; a plan saved before segments carried durations never projects.
    public func projectedBytes(finished sizes: [Int: Int64]) -> Int64? {
        var tracks = [String: (seconds: Double, doneSeconds: Double, doneBytes: Int64)]()
        var untimed: Int64 = 0
        for unit in units {
            let size = sizes[unit.index]
            guard let seconds = unit.seconds, seconds > 0 else {
                untimed += size ?? 0
                continue
            }
            let name = String(unit.relativePath.split(separator: "/").first ?? "")
            var track = tracks[name] ?? (0, 0, 0)
            track.seconds += seconds
            if let size {
                track.doneSeconds += seconds
                track.doneBytes += size
            }
            tracks[name] = track
        }
        guard let main = tracks.values.max(by: { $0.seconds < $1.seconds }),
              main.doneSeconds >= main.seconds * Self.projectionStart else { return nil }
        let timed = tracks.values.reduce(0.0) { total, track in
            track.doneSeconds > 0 ? total + Double(track.doneBytes) / track.doneSeconds * track.seconds : total
        }
        return OfflineSizeEstimate.bytes(timed).map { $0 + untimed }
    }
}

/// A source subtitle (`SourceSubtitle`) chosen for the download.
public struct OfflineSidecarRequest: Codable, Equatable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let language: String?
    public let format: String

    public init(id: String, url: URL, name: String, language: String?, format: String) {
        self.id = id
        self.url = url
        self.name = name
        self.language = language
        self.format = format
    }
}

/// What a download of HLS refuses before fetching a single segment.
public enum OfflinePackageError: Error, Equatable, Sendable {
    /// FairPlay or another DRM key: only Apple's offline flow may store it (AVPlayer-only).
    case drmProtected
    /// SAMPLE-AES without DRM, or an encryption without a key address.
    case unsupportedEncryption(String)
    /// No `#EXT-X-ENDLIST`: a live stream has no end to download.
    case liveStream
    case empty

    public var failure: OfflineFailure {
        switch self {
        case .drmProtected: return OfflineFailure(.drmProtected)
        case .unsupportedEncryption(let method):
            return OfflineFailure(.unsupported, detail: "不支援的加密方式（\(method)）")
        case .liveStream: return OfflineFailure(.unsupported, detail: "直播串流無法下載")
        case .empty: return OfflineFailure(.unsupported, detail: "播放清單沒有任何片段")
        }
    }
}

/// Copies one rendition of an HLS stream into a local package.
///
/// **The local playlists are written from the parsed model, not edited line by line.** Only the
/// tags a VOD rendition needs are emitted — version, target duration, media sequence,
/// discontinuity sequence, playlist type, keys, maps, discontinuities, program date-times and
/// durations — and every URI in them is a relative path inside the asset. An unknown tag that
/// carried an address cannot survive into the package, so nothing in it can reach the network.
///
/// Files are named by what they contain (`.ts`, `.m4s`, `.mp4`, `.aac`, `.vtt`, `.key`), not by
/// the source's names: FFmpeg's HLS demuxer refuses a segment whose extension does not match its
/// format (`extension_picky`), and a CDN that serves TS as `.jpg` would otherwise not play in MPV.
public enum OfflinePackageBuilder {
    public struct Rendition: Sendable {
        public let rendition: HLSRendition
        public let playlist: HLSMediaPlaylist

        public init(rendition: HLSRendition, playlist: HLSMediaPlaylist) {
            self.rendition = rendition
            self.playlist = playlist
        }
    }

    public struct Input: Sendable {
        /// Nil when the source gave a media playlist directly.
        public let master: HLSMasterPlaylist?
        public let variant: HLSVariant?
        public let video: HLSMediaPlaylist
        /// A rendition with its own playlist; nil when the audio is muxed into the video.
        public let audio: Rendition?
        public let subtitles: [Rendition]

        public init(master: HLSMasterPlaylist?, variant: HLSVariant?, video: HLSMediaPlaylist,
                    audio: Rendition?, subtitles: [Rendition]) {
            self.master = master
            self.variant = variant
            self.video = video
            self.audio = audio
            self.subtitles = subtitles
        }
    }

    public static let videoPlaylist = "playlists/video.m3u8"
    public static let audioPlaylist = "playlists/audio.m3u8"
    public static let masterPlaylist = "playlists/index.m3u8"

    /// Refuses DRM, unsupported encryption and live streams; otherwise lists each distinct file once.
    public static func validate(_ playlists: [HLSMediaPlaylist], sessionKeys: [HLSKey] = []) throws {
        let keys = sessionKeys + playlists.flatMap(\.keys)
        if keys.contains(where: \.isDRM) { throw OfflinePackageError.drmProtected }
        if let other = keys.first(where: { !$0.isNone && !$0.isClearAES128 }) {
            throw OfflinePackageError.unsupportedEncryption(other.method)
        }
        guard playlists.allSatisfy({ $0.hasEndList || $0.playlistType == "VOD" }) else {
            throw OfflinePackageError.liveStream
        }
        guard playlists.allSatisfy({ !$0.segments.isEmpty }) else { throw OfflinePackageError.empty }
    }

    public static func build(_ input: Input, origin: URL, headers: [String: String]) throws -> OfflinePackagePlan {
        var media = [input.video] + input.subtitles.map(\.playlist)
        if let audio = input.audio { media.append(audio.playlist) }
        try validate(media, sessionKeys: input.master?.sessionKeys ?? [])

        var builder = UnitTable()
        var playlists = [String: String]()
        playlists[videoPlaylist] = rewrite(input.video, prefix: "media/v", role: .segment, table: &builder)
        if let audio = input.audio {
            playlists[audioPlaylist] = rewrite(audio.playlist, prefix: "audio/a", role: .segment, table: &builder)
        }
        for (index, subtitle) in input.subtitles.enumerated() {
            playlists["playlists/sub-\(index + 1).m3u8"] = rewrite(
                subtitle.playlist, prefix: "subtitles/s\(index + 1)-", role: .subtitleSegment, table: &builder)
        }

        let entry: String
        if let master = input.master, let variant = input.variant {
            playlists[masterPlaylist] = localMaster(master, variant: variant, audio: input.audio?.rendition,
                                                    subtitles: input.subtitles.map(\.rendition))
            entry = masterPlaylist
        } else {
            entry = videoPlaylist
        }
        return OfflinePackagePlan(units: builder.units, playlists: playlists, package: .hls(entryPath: entry),
                                  origin: origin, headers: headers)
    }

    /// One distinct file per (address, range): a segment or a key used twice is fetched and kept once.
    struct UnitTable {
        var units = [OfflineDownloadUnit]()
        var byResource = [String: Int]()
        var keyCount = 0
        var mapCount = 0

        mutating func add(_ url: URL, range: HLSByteRange?, role: OfflineDownloadUnit.Role, seconds: Double? = nil,
                          path: () -> String) -> String {
            let resource = url.absoluteString + "|" + (range.map { "\($0.offset)-\($0.length)" } ?? "")
            if let existing = byResource[resource] { return units[existing].relativePath }
            let unit = OfflineDownloadUnit(index: units.count, remoteURL: url, byteRange: range,
                                           relativePath: path(), role: role, seconds: seconds)
            byResource[resource] = unit.index
            units.append(unit)
            return unit.relativePath
        }
    }

    static func segmentExtension(_ url: URL, hasMap: Bool, role: OfflineDownloadUnit.Role) -> String {
        if role == .subtitleSegment { return "vtt" }
        if hasMap { return "m4s" }
        let ext = url.pathExtension.lowercased()
        if ["aac", "ac3", "ec3", "mp3"].contains(ext) { return ext }
        return "ts"
    }

    static func number(_ value: Double) -> String {
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// `"…"` with any quote inside dropped: an attribute value cannot contain one (RFC 8216 §4.2).
    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "") + "\""
    }

    static func rewrite(_ playlist: HLSMediaPlaylist, prefix: String, role: OfflineDownloadUnit.Role,
                        table: inout UnitTable) -> String {
        var lines = ["#EXTM3U"]
        let usesMap = playlist.segments.contains { $0.map != nil }
        lines.append("#EXT-X-VERSION:\(max(playlist.version ?? 3, usesMap ? 6 : 3))")
        let longest = playlist.segments.map(\.duration).max() ?? 0
        lines.append("#EXT-X-TARGETDURATION:\(max(playlist.targetDuration, Int(longest.rounded())))")
        lines.append("#EXT-X-MEDIA-SEQUENCE:\(playlist.mediaSequence)")
        if let sequence = playlist.discontinuitySequence { lines.append("#EXT-X-DISCONTINUITY-SEQUENCE:\(sequence)") }
        lines.append("#EXT-X-PLAYLIST-TYPE:VOD")
        if playlist.independentSegments { lines.append("#EXT-X-INDEPENDENT-SEGMENTS") }

        var currentKey: HLSKey?
        var currentMap: HLSMap?
        var pendingDiscontinuity = false
        var counter = 0
        for segment in playlist.segments {
            // A gap has no media to fetch. It is left out and the timeline marks the jump, which
            // both engines follow; the EXT-X-GAP tag itself is not understood by FFmpeg.
            if segment.isGap { pendingDiscontinuity = true; continue }
            if segment.key != currentKey {
                currentKey = segment.key
                if let key = segment.key, let uri = key.uri {
                    table.keyCount += 1
                    let count = table.keyCount
                    let local = table.add(uri, range: nil, role: .key) { "keys/k\(count).key" }
                    var attributes = "METHOD=AES-128,URI=" + quoted("../" + local)
                    if let iv = key.iv { attributes += ",IV=\(iv)" }
                    lines.append("#EXT-X-KEY:" + attributes)
                } else {
                    lines.append("#EXT-X-KEY:METHOD=NONE")
                }
            }
            if let map = segment.map, map != currentMap {
                currentMap = map
                table.mapCount += 1
                let count = table.mapCount
                let local = table.add(map.uri, range: map.byteRange, role: .initSection) { "\(prefix)-init\(count).mp4" }
                lines.append("#EXT-X-MAP:URI=" + quoted("../" + local))
            }
            if segment.discontinuity || pendingDiscontinuity { lines.append("#EXT-X-DISCONTINUITY") }
            pendingDiscontinuity = false
            if let date = segment.programDateTime { lines.append("#EXT-X-PROGRAM-DATE-TIME:\(date)") }
            lines.append("#EXTINF:\(number(segment.duration)),\(segment.title)")
            counter += 1
            let sequence = counter
            let ext = segmentExtension(segment.uri, hasMap: segment.map != nil, role: role)
            let local = table.add(segment.uri, range: segment.byteRange, role: role, seconds: segment.duration) {
                "\(prefix)\(String(format: "%05d", sequence)).\(ext)"
            }
            lines.append("../" + local)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The master the package plays from: the one chosen variant, its one audio rendition, and the
    /// chosen subtitles. Both engines open this same file.
    static func localMaster(_ master: HLSMasterPlaylist, variant: HLSVariant, audio: HLSRendition?,
                            subtitles: [HLSRendition]) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:\(max(master.version ?? 3, 3))"]
        if master.independentSegments { lines.append("#EXT-X-INDEPENDENT-SEGMENTS") }
        if let audio {
            var attributes = ["TYPE=AUDIO", "GROUP-ID=\"audio\"", "NAME=" + quoted(audio.name.isEmpty ? "Audio" : audio.name)]
            if let language = audio.language { attributes.append("LANGUAGE=" + quoted(language)) }
            attributes += ["DEFAULT=YES", "AUTOSELECT=YES"]
            if let channels = audio.channels { attributes.append("CHANNELS=" + quoted(channels)) }
            attributes.append("URI=\"audio.m3u8\"")
            lines.append("#EXT-X-MEDIA:" + attributes.joined(separator: ","))
        }
        for (index, subtitle) in subtitles.enumerated() {
            var attributes = ["TYPE=SUBTITLES", "GROUP-ID=\"subs\"",
                              "NAME=" + quoted(subtitle.name.isEmpty ? "字幕 \(index + 1)" : subtitle.name)]
            if let language = subtitle.language { attributes.append("LANGUAGE=" + quoted(language)) }
            attributes.append("DEFAULT=\(subtitle.isDefault ? "YES" : "NO")")
            attributes.append("AUTOSELECT=YES")
            if subtitle.forced { attributes.append("FORCED=YES") }
            attributes.append("URI=\"sub-\(index + 1).m3u8\"")
            lines.append("#EXT-X-MEDIA:" + attributes.joined(separator: ","))
        }
        // In-band captions travel inside the video segments; their declarations carry no address.
        let captions = master.renditions(type: "CLOSED-CAPTIONS", group: variant.closedCaptions)
        for caption in captions {
            var attributes = ["TYPE=CLOSED-CAPTIONS", "GROUP-ID=\"cc\"", "NAME=" + quoted(caption.name)]
            if let language = caption.language { attributes.append("LANGUAGE=" + quoted(language)) }
            if let id = caption.attributes["INSTREAM-ID"] { attributes.append("INSTREAM-ID=" + quoted(id)) }
            lines.append("#EXT-X-MEDIA:" + attributes.joined(separator: ","))
        }

        var stream = ["BANDWIDTH=\(max(variant.bandwidth, 1))"]
        if let average = variant.averageBandwidth { stream.append("AVERAGE-BANDWIDTH=\(average)") }
        if !variant.codecs.isEmpty { stream.append("CODECS=" + quoted(variant.codecs.joined(separator: ","))) }
        if let width = variant.width, let height = variant.height { stream.append("RESOLUTION=\(width)x\(height)") }
        if let rate = variant.frameRate { stream.append("FRAME-RATE=\(number(rate))") }
        if let range = variant.videoRange { stream.append("VIDEO-RANGE=\(range)") }
        if audio != nil { stream.append("AUDIO=\"audio\"") }
        if !subtitles.isEmpty { stream.append("SUBTITLES=\"subs\"") }
        stream.append(captions.isEmpty ? "CLOSED-CAPTIONS=NONE" : "CLOSED-CAPTIONS=\"cc\"")
        lines.append("#EXT-X-STREAM-INF:" + stream.joined(separator: ","))
        lines.append("video.m3u8")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Checks a finished package before it may be called complete: every file a playlist names is
/// inside the asset and on disk, nothing names the network, and every unit arrived whole.
public enum OfflinePackageVerifier {
    public static func problems(plan: OfflinePackagePlan, root: URL,
                                fileManager: FileManager = .default) -> [String] {
        var problems = [String]()
        for unit in plan.units {
            let file = root.appendingPathComponent(unit.relativePath)
            let size = (try? fileManager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
            guard let size, size > 0 else {
                problems.append("missing \(unit.role.rawValue) #\(unit.index)")
                continue
            }
            if let range = unit.byteRange, size != range.length {
                problems.append("size \(unit.role.rawValue) #\(unit.index) \(size)≠\(range.length)")
            }
        }
        for (path, _) in plan.playlists {
            let file = root.appendingPathComponent(path)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                problems.append("missing playlist \(path)")
                continue
            }
            problems += referenceProblems(in: text, playlistPath: path, root: root, fileManager: fileManager)
        }
        return problems
    }

    /// Every URI a playlist names — segment lines and `URI="…"` attributes — must be relative,
    /// stay inside the asset, and exist.
    public static func referenceProblems(in text: String, playlistPath: String, root: URL,
                                         fileManager: FileManager = .default) -> [String] {
        var references = [String]()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if let uri = HLSAttributes.parse(line.drop { $0 != ":" }.dropFirst())["URI"] { references.append(uri) }
            } else {
                references.append(line)
            }
        }
        let base = root.appendingPathComponent(playlistPath).deletingLastPathComponent()
        let rootPath = root.standardizedFileURL.path
        var problems = [String]()
        for reference in references {
            if reference.contains("://") || reference.hasPrefix("/") || reference.hasPrefix("data:") {
                problems.append("remote reference in \(playlistPath)")
                continue
            }
            let target = base.appendingPathComponent(reference).standardizedFileURL
            guard target.path.hasPrefix(rootPath + "/") else {
                problems.append("reference outside the asset in \(playlistPath)")
                continue
            }
            if !fileManager.fileExists(atPath: target.path) {
                problems.append("missing \(reference) in \(playlistPath)")
            }
        }
        return problems
    }
}
