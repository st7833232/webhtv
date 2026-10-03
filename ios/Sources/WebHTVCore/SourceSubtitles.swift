import Foundation

/// IOS-POC-45H — one subtitle a source lists with its play result: CatVod `playerContent`'s
/// `subs`, `[{"url", "name", "lang", "format", "flag"}]` (WebHTV Android `bean/Sub.java`, FongMi/TV
/// c616c0aa `bean/Sub.java`).
///
/// Kept as the source wrote it. `format` is a Media3 MIME string and is never trusted: the file's
/// content decides (`SubtitleContent.validate`). `flag` is Media3's selection bitmask — 1 default,
/// 2 forced, 4 autoselect — not the play result's line name, which is also called `flag`.
public struct SourceSubtitle: Sendable, Equatable {
    public let url: String
    public let name: String
    public let language: String
    public let format: String
    public let flag: Int

    public init(url: String, name: String = "", language: String = "", format: String = "", flag: Int = 0) {
        self.url = url
        self.name = name
        self.language = language
        self.format = format
        self.flag = flag
    }
}

extension SourceSubtitle: Decodable {
    // Read by `catvod.result`'s fingerprint (RuntimeABITests): a key added here is an output field.
    enum CodingKeys: String, CodingKey { case url, name, lang, format, flag }

    /// Throws only for an entry without a url. A number where a string belongs is read as its text,
    /// and an undecodable `flag` is no flag: one odd field never costs the entry.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String {
            if let value = try? values.decode(String.self, forKey: key) { return value }
            if let value = try? values.decode(Int.self, forKey: key) { return String(value) }
            return ""
        }
        // As FongMi's `UrlUtil.uri`: trimmed, backslashes removed.
        let url = text(.url).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "")
        guard !url.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: values, debugDescription: "no url")
        }
        self.url = url
        name = text(.name).trimmingCharacters(in: .whitespacesAndNewlines)
        language = text(.lang).trimmingCharacters(in: .whitespacesAndNewlines)
        format = text(.format).trimmingCharacters(in: .whitespacesAndNewlines)
        flag = (try? values.decode(Int.self, forKey: .flag))
            ?? (try? values.decode(String.self, forKey: .flag)).flatMap { Int($0) } ?? 0
    }

    /// A play result's `subs`, entry by entry: a broken entry is skipped, and a `subs` that is not
    /// an array is no subtitles. (Android's Gson decode loses the whole play result for either.)
    static func list<Key: CodingKey>(in container: KeyedDecodingContainer<Key>, forKey key: Key) -> [SourceSubtitle] {
        guard var items = try? container.nestedUnkeyedContainer(forKey: key) else { return [] }
        var subtitles = [SourceSubtitle]()
        while !items.isAtEnd {
            if let subtitle = try? items.decode(SourceSubtitle.self) {
                subtitles.append(subtitle)
            } else if (try? items.decode(Skipped.self)) == nil {
                break
            }
        }
        return subtitles
    }

    /// Steps over an entry that is not a subtitle; a failed decode does not move the container on.
    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

/// IOS-POC-45H — what to download for one item's source subtitles, and which one to show.
public struct SourceSubtitlePlan: Sendable, Equatable {
    /// In download order: the one to show first, then the rest in the source's order.
    public let tracks: [RemoteSubtitleTrack]
    /// The track to show by default (`SourceSubtitles.flags`), nil when the source marks none.
    public let chosenID: String?
    /// Entries the source listed.
    public let listed: Int
    /// Entries left out: a url iOS cannot fetch (`file://`, `proxy://`, loopback, relative), a
    /// repeat, or past `SourceSubtitles.maximumFiles`.
    public let skipped: Int

    public static let empty = SourceSubtitlePlan(tracks: [], chosenID: nil, listed: 0, skipped: 0)
}

public enum SourceSubtitles {
    public static let providerName = "片源"
    /// A source listing every language of a release still costs one request each; past this, none.
    public static let maximumFiles = 8

    public static func plan(_ subtitles: [SourceSubtitle], preferredLanguage: String?) -> SourceSubtitlePlan {
        // The flags are the source's whole list's, as upstream decides them, before anything iOS
        // cannot fetch is left out: an entry the source did not make the default never becomes it
        // because the one it did make is a `proxy://` address or past the limit.
        let urls = subtitles.map { url($0.url) }
        let flags = flags(subtitles.map(\.flag), scores: subtitles.indices.map { index in
            languageScore(language(of: subtitles[index], file: urls[index].map(fileName) ?? "").code,
                          preferred: preferredLanguage)
        })
        var seen = Set<String>()
        var usable = [(track: RemoteSubtitleTrack, flag: Int)]()
        for (index, subtitle) in subtitles.enumerated() {
            guard let url = urls[index], SourceSubtitleProvider.isFetchable(url),
                  seen.insert(url.absoluteString).inserted else { continue }
            usable.append((track(for: subtitle, url: url), flags[index]))
        }
        usable = Array(usable.prefix(maximumFiles))
        let tracks = usable.map(\.track)
        // As FongMi's mpv engine: the first default or forced entry.
        let chosen = usable.firstIndex { $0.flag & 0b11 != 0 }
        var order = tracks
        if let chosen, chosen > 0 { order.insert(order.remove(at: chosen), at: 0) }
        return SourceSubtitlePlan(tracks: order, chosenID: chosen.map { tracks[$0].id },
                                  listed: subtitles.count, skipped: subtitles.count - tracks.count)
    }

    /// FongMi/TV c616c0aa `MediaItemFactory.SubtitleFlags`: one entry keeps its own flag (0 is
    /// default); several where any has a flag keep theirs and the rest only autoselect; several with
    /// none make the best language match (the first when none matches) the default.
    static func flags(_ raw: [Int], scores: [Int]) -> [Int] {
        let autoselect = 4, `default` = 1
        if raw.count == 1 { return [raw[0] == 0 ? `default` : raw[0]] }
        if raw.contains(where: { $0 != 0 }) { return raw.map { $0 != 0 ? $0 : autoselect } }
        var best = 0, bestScore = 0
        for (index, score) in scores.enumerated() where score > bestScore {
            best = index
            bestScore = score
        }
        return raw.indices.map { $0 == best ? `default` : autoselect }
    }

    /// FongMi/TV c616c0aa `LangUtil.getPreferredTextLanguageScore`, on the code `SubtitleLanguage`
    /// read from the entry (so 「简体」 counts, not only `zh-CN`): the same tag 400; for a Chinese
    /// device the same script 300, bare `zh` 200, the other script 100; otherwise the same language
    /// 300 when one tag extends the other, else 200.
    static func languageScore(_ code: String?, preferred: String?) -> Int {
        func normalized(_ tag: String?) -> String {
            (tag ?? "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-").lowercased()
        }
        let track = normalized(code), device = normalized(preferred)
        guard !track.isEmpty, !device.isEmpty else { return 0 }
        if track == device { return 400 }
        func primary(_ tag: String) -> Substring { tag.split(separator: "-").first ?? "" }
        func traditional(_ tag: String) -> Bool {
            let parts = tag.split(separator: "-")
            if parts.contains("hant") { return true }
            if parts.contains("hans") { return false }
            return parts.dropFirst().contains { ["tw", "hk", "mo"].contains($0) }
        }
        guard primary(track) == primary(device) else { return 0 }
        if primary(device) == "zh" {
            if track == "zh" { return 200 }
            return traditional(device) == traditional(track) ? 300 : 100
        }
        return track.hasPrefix(device + "-") || device.hasPrefix(track + "-") ? 300 : 200
    }

    static func track(for subtitle: SourceSubtitle, url: URL) -> RemoteSubtitleTrack {
        let file = fileName(url)
        return RemoteSubtitleTrack(providerID: SourceSubtitleProvider.providerID, providerName: providerName,
                                   language: language(of: subtitle, file: file), fileName: file.isEmpty ? "subtitle" : file,
                                   title: subtitle.name.isEmpty ? nil : subtitle.name, downloadURL: url, detailURL: nil)
    }

    static func fileName(_ url: URL) -> String {
        url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
    }

    /// `lang` first, then the name (「繁體中文」), then the file name.
    static func language(of subtitle: SourceSubtitle, file: String) -> SubtitleLanguage {
        let words = [subtitle.language, subtitle.name].filter { !$0.isEmpty }
        return SubtitleLanguage.detect(label: words.first, metadata: words, fileName: file)
    }

    static func url(_ raw: String) -> URL? {
        if let url = URL(string: raw), url.scheme != nil { return url }
        return raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
    }
}

/// IOS-POC-45H — fetches a source's subtitle the way its stream is fetched: with the stream's
/// headers, which the CDN behind both often requires (WebHTV Android sends the play result's
/// headers with every subtitle request). Credentials stay with the stream's own host.
public struct SourceSubtitleProvider: SubtitleProvider {
    public static let providerID = "source"

    public let id = SourceSubtitleProvider.providerID
    public let name = SourceSubtitles.providerName
    public let availability = SubtitleProviderAvailability.available
    let headers: [String: String]
    let media: URL?

    public init(headers: [String: String], mediaURL: URL?) {
        self.headers = headers
        media = mediaURL
    }

    /// Never searched: its files come with the play result.
    public func search(_ query: SubtitleSearchQuery) async throws -> SubtitleSearchResult { .empty }

    public func downloadRequest(for track: RemoteSubtitleTrack) async throws -> URLRequest {
        guard Self.isFetchable(track.downloadURL) else { throw SubtitleProviderError.downloadUnavailable }
        var request = URLRequest(url: track.downloadURL)
        for (name, value) in Self.forwarded(headers, to: track.downloadURL, media: media) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("text/plain, application/x-subrip, text/vtt, text/x-ssa, */*;q=0.5", forHTTPHeaderField: "Accept")
        return request
    }

    public func acceptsDownload(from url: URL) -> Bool { Self.isFetchable(url) }

    /// http or https to a host other than this device. `file://` and `proxy://` (the WebDAV
    /// spider's) need the local server iOS does not have, and nothing on iOS listens on loopback.
    static func isFetchable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return !isLoopback(host)
    }

    /// `localhost`, `127.0.0.0/8`, `0.0.0.0`, `::1`, `::` and IPv4-mapped or -compatible forms of
    /// those, however written; any numeric IPv4 host not written as four plain decimal parts
    /// (`127.1`, `2130706433`, `0x7f.0.0.1`, `0177.0.0.1` all reach loopback through the resolver);
    /// and an IPv6 literal that does not parse.
    static func isLoopback(_ raw: String) -> Bool {
        var host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host.contains(":") {
            guard let groups = ipv6Groups(host) else { return true }
            guard groups.prefix(5).allSatisfy({ $0 == 0 }), groups[5] == 0 || groups[5] == 0xFFFF else { return false }
            if groups[5] == 0, groups[6] == 0, groups[7] <= 1 { return true }
            return loopbackIPv4([UInt8(groups[6] >> 8), UInt8(groups[6] & 0xFF), UInt8(groups[7] >> 8), UInt8(groups[7] & 0xFF)])
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let numeric = parts.allSatisfy { part in
            !part.isEmpty && (part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) || part.hasPrefix("0x"))
        }
        guard numeric else { return false }
        // A leading zero is octal to the resolver: not the number it looks like.
        let octets = parts.compactMap { part in part.count > 1 && part.hasPrefix("0") ? nil : UInt8(part) }
        guard parts.count == 4, octets.count == 4 else { return true }
        return loopbackIPv4(octets)
    }

    static func loopbackIPv4(_ octets: [UInt8]) -> Bool {
        octets[0] == 127 || octets.allSatisfy { $0 == 0 }
    }

    /// The eight groups of an IPv6 literal (`::` expanded, a dotted IPv4 tail read as two), nil when
    /// it is not one.
    static func ipv6Groups(_ host: String) -> [UInt16]? {
        let halves = host.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ text: String) -> [UInt16]? {
            guard !text.isEmpty else { return [] }
            var result = [UInt16]()
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            for (index, part) in parts.enumerated() {
                if index == parts.count - 1, part.contains(".") {
                    let octets = part.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
                    guard octets.count == 4, part.split(separator: ".").count == 4 else { return nil }
                    result += [UInt16(octets[0]) << 8 | UInt16(octets[1]), UInt16(octets[2]) << 8 | UInt16(octets[3])]
                } else {
                    guard (1...4).contains(part.count), let value = UInt16(part, radix: 16) else { return nil }
                    result.append(value)
                }
            }
            return result
        }
        guard let head = groups(halves[0]) else { return nil }
        if halves.count == 1 { return head.count == 8 ? head : nil }
        guard let tail = groups(halves[1]), head.count + tail.count < 8 else { return nil }
        return head + Array(repeating: 0, count: 8 - head.count - tail.count) + tail
    }

    /// Never sent: the transfer's own headers, and `Accept`, which is set for subtitles.
    static let dropped: Set<String> = ["range", "if-range", "host", "content-length", "connection",
                                       "transfer-encoding", "accept-encoding", "accept"]
    /// Sent to any host; everything else only to the stream's own host.
    static let anyHost: Set<String> = ["user-agent", "referer"]

    static func forwarded(_ headers: [String: String], to url: URL, media: URL?) -> [(String, String)] {
        let trusted = media.map { sameOrigin(url, as: $0) } ?? false
        return headers.sorted { $0.key < $1.key }.filter { name, value in
            let key = name.lowercased()
            guard !dropped.contains(key), !value.contains(where: { $0 == "\r" || $0 == "\n" }) else { return false }
            return trusted || anyHost.contains(key)
        }
    }

    /// The stream's own host, on the port it named, never from https down to plain http: a Cookie
    /// sent in clear text or to another port is a Cookie sent somewhere else.
    static func sameOrigin(_ url: URL, as media: URL) -> Bool {
        guard let host = url.host?.lowercased(), host == media.host?.lowercased(), url.port == media.port else {
            return false
        }
        return !(media.scheme?.lowercased() == "https" && url.scheme?.lowercased() != "https")
    }
}
