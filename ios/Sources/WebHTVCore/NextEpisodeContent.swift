import Foundation

/// W-243 — the first seconds of the next episode, fetched ahead into a folder that a loopback server
/// hands to either engine (design: `docs/W-241-next-episode-preload.md` §11).
///
/// Only the fetched segments point at the folder. Every other address in the playlist is written as
/// the source's own absolute address, so the player carries on from the source by itself and the app
/// never relays the rest of the episode. Whatever this cannot do safely is a `Skip`, and the caller
/// plays the pre-resolved address exactly as it did before.
public enum NextEpisodeContent {
    /// How much is fetched, counted from where playback will start.
    public static let seconds: Double = 15
    /// The most one episode may cost, on any network.
    public static let byteLimit = 20 * 1024 * 1024
    public static let mediaPlaylist = "media.m3u8"
    public static let masterPlaylist = "master.m3u8"

    public enum Skip: Error, Equatable, Sendable {
        case notHLS
        case live
        /// DRM, SAMPLE-AES or a key without an address: never touched (`OfflinePackageBuilder.validate`).
        case encryption
        case multiVariant
        /// A master with any other address in it — separate audio or subtitle playlists, I-frame
        /// playlists, a session key — which a rewritten local master would break.
        case renditionURIs
        case byteRanges
        /// A loopback address other than kkys's ad-stripped list.
        case localProxy
        case tooLarge
        case nothingToFetch
        case failed(String)

        public var reason: String {
            if case .failed(let why) = self { return "failed: \(why)" }
            return String(describing: self)
        }
    }

    public struct Result: Sendable, Equatable {
        /// The playlist to open, relative to the folder.
        public let entry: String
        public let segments: Int
        public let seconds: Double
        public let bytes: Int
    }

    /// Whether `url` is worth asking for at all. Loopback is the app's own spider proxy: only kkys's
    /// ad-stripped list (`type=adm3u8`) is an HLS playlist; bili's DASH and YouTube are not.
    public static func eligible(_ url: URL) -> Skip? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .notHLS }
        guard ["127.0.0.1", "localhost"].contains(url.host ?? "") else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return query.contains { $0.name == "type" && $0.value == "adm3u8" } ? nil : .localProxy
    }

    /// Fetches the playlist(s) at `url` and the segments from `startSeconds` on into `folder`, and
    /// writes the rewritten playlists there. Throws a `Skip`, or `CancellationError` once cancelled.
    public static func fetch(_ url: URL, headers: [String: String], startSeconds: Double,
                             into folder: URL, using fetch: OfflineFetch) async throws -> Result {
        if let skip = eligible(url) { throw skip }
        func get(_ address: URL, limit: Int) async throws -> OfflineHTTPResponse {
            try Task.checkCancellation()
            var request = URLRequest(url: address)
            // User-Agent and Referer go anywhere; a Cookie only to the stream's own origin.
            for (name, value) in OfflineRequestPolicy.headers(headers, for: address, origin: url) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let answer = try await fetch(request, limit)
            guard (200..<300).contains(answer.status) else { throw Skip.failed("HTTP \(answer.status)") }
            return answer
        }
        // A small read first, so an MP4 behind an address with no extension costs 64 KB, not 8 MB.
        func playlist(_ address: URL) async throws -> (text: String, base: URL) {
            var answer = try await get(address, limit: OfflineHTTP.probeLimit)
            guard String(decoding: answer.data.prefix(1024), as: UTF8.self).contains("#EXTM3U") else { throw Skip.notHLS }
            if answer.truncated { answer = try await get(address, limit: OfflineHTTP.playlistLimit) }
            guard !answer.truncated else { throw Skip.tooLarge }
            // A redirected playlist resolves its relative addresses against where it really came from.
            return (String(decoding: answer.data, as: UTF8.self), answer.url ?? address)
        }
        func parse(_ text: String, _ base: URL) throws -> HLSPlaylist {
            do { return try HLSPlaylist.parse(text, base: base) } catch { throw Skip.notHLS }
        }

        var (text, base) = try await playlist(url)
        var master: String?
        if case .master(let parsed) = try parse(text, base) {
            guard parsed.variants.count == 1 else { throw Skip.multiVariant }
            guard !text.contains("URI=") else { throw Skip.renditionURIs }
            master = text
            (text, base) = try await playlist(parsed.variants[0].uri)
        }
        guard case .media(let media) = try parse(text, base) else { throw Skip.notHLS }
        do {
            try OfflinePackageBuilder.validate([media])
        } catch OfflinePackageError.liveStream {
            throw Skip.live
        } catch OfflinePackageError.empty {
            throw Skip.nothingToFetch
        } catch {
            throw Skip.encryption
        }
        guard !media.segments.contains(where: { $0.byteRange != nil || $0.map?.byteRange != nil }) else {
            throw Skip.byteRanges
        }
        // The rewrite counts address lines; one the parser could not read would shift every segment.
        guard lines(text).filter({ !$0.hasPrefix("#") }).count == media.segments.count else {
            throw Skip.failed("unreadable segment address")
        }
        guard let first = firstSegment(media.segments, at: startSeconds) else { throw Skip.nothingToFetch }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var budget = byteLimit
        var local = [Int: String]()
        var maps = [URL: String]()
        var seconds = 0.0
        // In order and contiguous: the first gap ends the run, and only a run that starts where
        // playback starts is worth anything. Not the first segment for a later start: AVPlayer seeks
        // before it reads one, and mpv probes past it either way (W-243 Simulator runs).
        fetching: for index in first..<media.segments.count where seconds < Self.seconds {
            let segment = media.segments[index]
            var files = [(name: String, data: Data)]()
            var wanted = [(url: URL, name: String)]()
            if let map = segment.map, maps[map.uri] == nil { wanted.append((map.uri, "init\(maps.count).mp4")) }
            let ext = OfflinePackageBuilder.segmentExtension(segment.uri, hasMap: segment.map != nil, role: .segment)
            wanted.append((segment.uri, "s\(index).\(ext)"))
            for file in wanted {
                let answer: OfflineHTTPResponse
                do {
                    answer = try await get(file.url, limit: budget)
                } catch let error as CancellationError {
                    throw error
                } catch {
                    if index == first { throw (error as? Skip) ?? Skip.failed(error.localizedDescription) }
                    break fetching
                }
                guard !answer.truncated else {
                    if index == first { throw Skip.tooLarge }
                    break fetching
                }
                budget -= answer.data.count
                files.append((file.name, answer.data))
            }
            for file in files { try file.data.write(to: folder.appendingPathComponent(file.name)) }
            if let map = segment.map, maps[map.uri] == nil { maps[map.uri] = wanted[0].name }
            local[index] = wanted[wanted.count - 1].name
            seconds += segment.duration
        }
        try Task.checkCancellation()

        try rewrite(media: text, segments: media.segments, local: local, maps: maps, base: base)
            .write(to: folder.appendingPathComponent(mediaPlaylist), atomically: true, encoding: .utf8)
        if let master {
            try localMaster(master).write(to: folder.appendingPathComponent(masterPlaylist), atomically: true, encoding: .utf8)
        }
        return Result(entry: master == nil ? mediaPlaylist : masterPlaylist, segments: local.count,
                      seconds: seconds, bytes: byteLimit - budget)
    }

    /// The segment playing at `seconds`, or nil past the end.
    static func firstSegment(_ segments: [HLSSegment], at seconds: Double) -> Int? {
        var elapsed = 0.0
        for (index, segment) in segments.enumerated() {
            elapsed += segment.duration
            if elapsed > seconds { return index }
        }
        return nil
    }

    /// The playlist as the source wrote it, line for line — every tag, the media sequence and the
    /// discontinuity sequence kept, because a key without an IV uses the sequence number as its IV
    /// (RFC 8216 §5.2). Only addresses change: a fetched segment and the init section it uses become
    /// a local name, every other address (keys included) becomes the source's absolute address.
    static func rewrite(media text: String, segments: [HLSSegment], local: [Int: String],
                        maps: [URL: String], base: URL) -> String {
        var index = 0
        let rewritten = lines(text).map { line -> String in
            if !line.hasPrefix("#") {
                defer { index += 1 }
                return local[index] ?? segments[index].uri.absoluteString
            }
            guard line.hasPrefix("#EXT-X-KEY") || line.hasPrefix("#EXT-X-MAP") else { return line }
            return line.replacing(/URI="([^"]*)"/) { match in
                guard let resolved = HLSPlaylist.resolve(String(match.1), base: base) else { return String(match.0) }
                let address = line.hasPrefix("#EXT-X-MAP") ? maps[resolved] ?? resolved.absoluteString : resolved.absoluteString
                return "URI=\"\(address)\""
            }
        }
        return rewritten.joined(separator: "\n") + "\n"
    }

    /// The source's single-variant master with its one address pointed at the local media playlist.
    static func localMaster(_ text: String) -> String {
        lines(text).map { $0.hasPrefix("#") ? $0 : mediaPlaylist }.joined(separator: "\n") + "\n"
    }

    /// The lines the parser reads, in the same way (`HLSPlaylist.parse`).
    static func lines(_ text: String) -> [String] {
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        return text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
