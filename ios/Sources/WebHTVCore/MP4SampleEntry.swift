import Foundation

/// W-262: the sample entry of an MP4's first video track (`moov/trak/mdia/minf/stbl/stsd`), read from a
/// whole file a spider served, so a codec AVPlayer cannot decode starts on MPV instead of stalling first.
public enum MP4SampleEntry {
    /// VVC under its standard entries and ByteVC2's renamed one (docs/W-254-bvc2-decoder.md): AVFoundation
    /// has no VVC decoder; the app's MPV does (FFmpeg `vvc`, patch 0007 for `bvc2`).
    public static let needsMPV: Set<String> = ["bvc2", "vvc1", "vvi1"]

    /// The fourcc of the first video track's first sample entry, or nil when `data` has none to read.
    public static func videoFourCC(_ data: Data) -> String? {
        data.withUnsafeBytes { videoFourCC(in: $0) }
    }

    private static func videoFourCC(in bytes: UnsafeRawBufferPointer) -> String? {
        guard let moov = boxes(bytes, 0..<bytes.count).first(where: { $0.type == "moov" }) else { return nil }
        for trak in boxes(bytes, moov.payload) where trak.type == "trak" {
            guard let mdia = child("mdia", bytes, trak.payload),
                  let hdlr = child("hdlr", bytes, mdia.payload), hdlr.payload.count >= 12,
                  fourcc(bytes, hdlr.payload.lowerBound + 8) == "vide",
                  let minf = child("minf", bytes, mdia.payload),
                  let stbl = child("stbl", bytes, minf.payload),
                  let stsd = child("stsd", bytes, stbl.payload),
                  stsd.payload.count >= 16 else { continue }
            // version/flags (4), entry_count (4), then the first entry's size (4) and type (4).
            return fourcc(bytes, stsd.payload.lowerBound + 12)
        }
        return nil
    }

    private struct Box { let type: String; let payload: Range<Int> }

    private static func child(_ type: String, _ bytes: UnsafeRawBufferPointer, _ range: Range<Int>) -> Box? {
        boxes(bytes, range).first { $0.type == type }
    }

    /// The boxes directly inside `range`; stops at the first one whose size does not fit.
    private static func boxes(_ bytes: UnsafeRawBufferPointer, _ range: Range<Int>) -> [Box] {
        var found = [Box]()
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            var size = Int(be32(bytes, offset))
            var header = 8
            if size == 1 {
                guard offset + 16 <= range.upperBound else { break }
                let large = UInt64(be32(bytes, offset + 8)) << 32 | UInt64(be32(bytes, offset + 12))
                guard large <= UInt64(Int.max) else { break }
                size = Int(large)
                header = 16
            } else if size == 0 {
                size = range.upperBound - offset
            }
            guard size >= header, offset + size <= range.upperBound else { break }
            found.append(Box(type: fourcc(bytes, offset + 4), payload: (offset + header)..<(offset + size)))
            offset += size
        }
        return found
    }

    private static func be32(_ bytes: UnsafeRawBufferPointer, _ at: Int) -> UInt32 {
        bytes[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func fourcc(_ bytes: UnsafeRawBufferPointer, _ at: Int) -> String {
        String(decoding: bytes[at..<at + 4], as: Unicode.ASCII.self)
    }
}

#if canImport(Network)
/// W-269: an MP4 on a loopback address the spider proxy does not serve — a script's own local service,
/// as the new 红果 PY runs — is read from its first bytes while native playback opens it, so a VVC one
/// moves to MPV without waiting for native to fail or time out. Nothing is read from any other address.
public enum LoopbackMP4Probe {
    /// A moov at the front of an episode fits (a 168 s bvc2 episode's is 206 KB, at byte 28); one at the end is not looked for.
    static let limit = 512 * 1024
    /// W-292: long enough for a script building its media session cold (3–18 s; 红果 refuses after ~14 s). The probe
    /// runs beside the open, so waiting costs the play nothing.
    static let timeout: TimeInterval = 30
    private static let lock = NSLock()
    nonisolated(unsafe) private static var vvc = Set<String>()

    /// What the first bytes said.
    public enum Finding: Equatable, Sendable {
        /// Whether the episode's video is VVC (or ByteVC2).
        case vvc(Bool)
        /// W-292: the script's own service answered this 5xx — it cannot make the episode, after its own retries.
        case refused(Int)
    }

    /// A loopback http address the spider proxy does not serve, and not a playlist or manifest.
    public static func applies(to url: URL) -> Bool {
        url.scheme == "http" && ["127.0.0.1", "::1", "localhost"].contains(url.host ?? "")
            && !SpiderProxyServer.serves(url) && !["m3u8", "mpd", "ts"].contains(url.pathExtension.lowercased())
    }

    /// Whether a probe found `url` to be VVC (or ByteVC2).
    public static func isVVC(_ url: URL) -> Bool { lock.withLock { vvc.contains(url.absoluteString) } }

    /// Reads up to `limit` bytes of `url` and notes whether its video is VVC; nil when that says nothing —
    /// no answer, a timeout, a 4xx, a 504 (which may only mean slow), or no whole moov.
    public static func probe(_ url: URL, headers: [String: String], fetch: OfflineFetch? = nil) async -> Finding? {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-\(limit - 1)", forHTTPHeaderField: "Range")
        request.timeoutInterval = timeout
        let fetch = fetch ?? OfflineHTTP.fetcher(origin: url, originalHeaders: headers)
        guard let response = try? await fetch(request, limit) else { return nil }
        if (500...599).contains(response.status), response.status != 504 { return .refused(response.status) }
        guard (200...299).contains(response.status) else { return nil }
        return record(url, prefix: response.data).map(Finding.vvc)
    }

    /// Notes what `prefix` (the file's first bytes) says about `url`; nil when it holds no whole moov.
    static func record(_ url: URL, prefix: Data) -> Bool? {
        guard let fourCC = MP4SampleEntry.videoFourCC(prefix) else { return nil }
        let isVVC = MP4SampleEntry.needsMPV.contains(fourCC)
        lock.withLock {
            if vvc.count >= 64 { vvc.removeAll() }
            if isVVC { vvc.insert(url.absoluteString) } else { vvc.remove(url.absoluteString) }
        }
        return isVVC
    }
}
#endif
