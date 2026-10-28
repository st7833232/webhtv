import Foundation

public enum LivePlaylistError: Error, Equatable, LocalizedError {
    case undecodableText
    /// A JSON array list (X-1: none of the 13 W-92 lists is one).
    case unsupportedFormat

    public var errorDescription: String? {
        switch self {
        case .undecodableText: "清單編碼無法辨識。"
        case .unsupportedFormat: "此直播源格式 iOS 尚未支援。"
        }
    }
}

/// Android's `LiveParser` for m3u and txt lists (IOS-POC-59 U1, D§6.2), with the deviations the task
/// document lists (X-4 to X-8, N-4). A pure function: no logging, no main actor, no traditional-
/// Chinese conversion (that is display work).
public enum LivePlaylistParser {
    public static func parse(_ data: Data, source: LiveSource) throws -> LivePlaylist {
        let text = try decode(data)
        if text.first(where: { !$0.isWhitespace }) == "[",
           (try? JSONSerialization.jsonObject(with: Data(text.utf8))) is [Any] {
            throw LivePlaylistError.unsupportedFormat
        }
        // X-6: a lone `\r` is a line break too (Android deletes it). Replacing before splitting also
        // keeps `\r\n` from being the single Character that `split(separator: "\n")` cannot cut.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        var builder = Builder(source: source)
        // LiveParser.M3U: any line with `#EXTM3U` and without `#genre#`.
        if lines.contains(where: { $0.contains("#EXTM3U") && !$0.contains("#genre#") }) {
            builder.m3u(lines)
        } else {
            builder.txt(lines)
        }
        return builder.playlist
    }

    private static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    private static func decode(_ data: Data) throws -> String {
        // Foundation's UTF-8 decoding drops a BOM, as OkHttp's `body().string()` does for Android
        // (W-124 M-8: an explicit strip was dead code; `aByteOrderMarkIsDropped` holds the behaviour).
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: gb18030) else {
            throw LivePlaylistError.undecodableText
        }
        return text
    }

    // MARK: settings

    /// `LiveParser.Setting`: what setting lines say about the lines after them. m3u clears it after
    /// each address; txt only at the next `#genre#`.
    private struct Setting {
        var ua: String?
        var origin: String?
        var referer: String?
        var format: String?
        /// A licence key or type, `drm_legacy`, or `drmScheme`/`drmLicense` in KODIPROP headers.
        var hasLicence = false
        var parse: Int?
        var headers: [String: String] = [:]

        var isDRM: Bool { hasLicence || ["mpd", "dash"].contains(format?.lowercased()) }

        /// X-7: the plain settings need their `key=`; Android's bare `startsWith("ua")` would also
        /// take a channel whose name starts with "ua".
        private static let prefixes = ["ua=", "parse=", "click=", "header=", "format=", "origin=", "referer=",
                                       "forceKey=", "#EXTHTTP:", "#EXTVLCOPT:", "#KODIPROP:"]

        /// Applies a setting line and says whether it was one. `click` and `forceKey` are read and
        /// ignored: L1 has no use for either.
        mutating func apply(_ line: Substring) -> Bool {
            guard Self.prefixes.contains(where: { line.hasPrefix($0) }) else { return false }
            if line.hasPrefix("ua=") || line.hasPrefix("#EXTVLCOPT:http-user-agent") {
                ua = value(after: line.hasPrefix("ua=") ? "ua=" : "user-agent=", in: line).map(unquoted)
            } else if line.hasPrefix("parse=") {
                parse = value(after: "parse=", in: line).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            } else if line.hasPrefix("header=") || line.hasPrefix("#EXTHTTP:") {
                value(after: line.hasPrefix("header=") ? "header=" : "#EXTHTTP:", in: line).map { merge(json: $0) }
            } else if line.hasPrefix("format=") {
                format = value(after: "format=", in: line).map(trimmed)
            } else if line.hasPrefix("origin=") || line.hasPrefix("#EXTVLCOPT:http-origin") {
                origin = value(after: "origin=", in: line).map(trimmed)
            } else if line.hasPrefix("referer=") {
                referer = value(after: "referer=", in: line).map(unquoted)
            } else if line.hasPrefix("#EXTVLCOPT:http-referrer") {
                referer = value(after: "referrer=", in: line).map(unquoted)
            } else if line.hasPrefix("#EXTVLCOPT:http-cookie") {
                value(after: "cookie=", in: line).map { LiveHeaders.set(&headers, "Cookie", unquoted($0)) }
            } else if line.hasPrefix("#KODIPROP:inputstream.adaptive.license_key")
                        || line.hasPrefix("#KODIPROP:inputstream.adaptive.license_type")
                        || line.hasPrefix("#KODIPROP:inputstream.adaptive.drm_legacy") {
                hasLicence = true
            } else if line.hasPrefix("#KODIPROP:inputstream.adaptive.manifest_type") {
                format = value(after: "manifest_type=", in: line).map(trimmed)
            } else if line.hasPrefix("#KODIPROP:inputstream.adaptive.stream_headers")
                        || line.hasPrefix("#KODIPROP:inputstream.adaptive.common_headers") {
                let parsed = LivePlaylistParser.headers(line)
                for (name, value) in parsed.headers { LiveHeaders.set(&headers, name, value) }
                hasLicence = hasLicence || parsed.isDRM
            }
            return true
        }

        private mutating func merge(json: Substring) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(json.trimmingCharacters(in: .whitespaces).utf8)))
                    as? [String: Any] else { return }
            for (name, value) in object {
                if let text = value as? String { LiveHeaders.set(&headers, name, text) }
                else if let number = value as? NSNumber { LiveHeaders.set(&headers, name, number.stringValue) }
            }
        }
    }

    /// The text after the first `marker`, matched without regard to case as Android's `(?i)` does.
    private static func value(after marker: String, in line: Substring) -> Substring? {
        line.range(of: marker, options: .caseInsensitive).map { line[$0.upperBound...] }
    }

    private static func trimmed(_ text: Substring) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func unquoted(_ text: Substring) -> String { trimmed(text).replacingOccurrences(of: "\"", with: "") }

    /// `Setting.headers`: `headers=a=1&b=2`, `a=1|b=2` or `a=1&b=2`. `drmScheme`/`drmLicense` mark DRM.
    private static func headers(_ text: Substring) -> (headers: [String: String], isDRM: Bool) {
        var headers: [String: String] = [:]
        var isDRM = false
        func read(_ text: Substring) {
            let params: Substring
            if let marker = text.range(of: "headers=") {
                params = text[marker.upperBound...]
            } else if text.contains("|") {
                text.split(separator: "|").forEach(read)
                return
            } else {
                params = text
            }
            for param in params.split(separator: "&") {
                guard let equals = param.firstIndex(of: "=") else { continue }
                let name = unquoted(param[..<equals])
                let value = unquoted(param[param.index(after: equals)...])
                if name == "drmScheme" || name == "drmLicense" { isDRM = true } else { LiveHeaders.set(&headers, name, value) }
            }
        }
        read(text)
        return (headers, isDRM)
    }

    // MARK: building

    private struct GroupKey: Hashable {
        let name: String
        let password: String?
    }

    private struct Builder {
        let source: LiveSource
        var playlist = LivePlaylist(groups: [])
        /// X-8: a name index per group instead of Android's linear search.
        var channelIndex: [[String: Int]] = []
        /// m3u only. N-4: name and password, so a password group never folds into the visible
        /// group of the same name (Android's `Live.find` matches the name alone).
        var groupIndex: [GroupKey: Int] = [:]

        init(source: LiveSource) { self.source = source }

        /// `Group(String, boolean)`: the name is cut at the first `_`; what follows is the password
        /// unless the source sets `pass`. An empty name, checked before the cut, is "直播" (B-4).
        func group(named raw: Substring) -> LiveGroup {
            var name = String(raw)
            var password: String?
            if let underscore = raw.firstIndex(of: "_") {
                name = String(raw[..<underscore])
                let rest = raw[raw.index(after: underscore)...]
                if !source.pass && !rest.isEmpty { password = String(rest) }
            }
            if raw.isEmpty { name = LivePlaylist.defaultGroupName }
            return LiveGroup(name: name, password: password, channels: [])
        }

        mutating func append(_ group: LiveGroup) -> Int {
            playlist.groups.append(group)
            channelIndex.append([:])
            return playlist.groups.count - 1
        }

        /// `Group.find(Channel)`: same non-empty name in the same group; an empty name never matches.
        mutating func channel(in group: Int, named name: String) -> Int {
            if !name.isEmpty, let index = channelIndex[group][name] { return index }
            playlist.groups[group].channels.append(LiveChannel(name: name, lines: []))
            let index = playlist.groups[group].channels.count - 1
            if !name.isEmpty { channelIndex[group][name] = index }
            return index
        }

        /// One address with its `|` part. X-4: the `|` headers belong to this line only. X-5: the
        /// headers live on the line. Inheritance (D§6.2.7, `Channel.live`, `Channel.getHeaders`): the
        /// line's own values, then the m3u `#EXTINF` user agent (B-3), then the source's — ua, origin
        /// and referer each, the header map only whole.
        func line(_ address: Substring, pipe: Substring?, setting: Setting, extinfUA: String?) -> LiveLine {
            let parts = trimmed(address).split(separator: "$", omittingEmptySubsequences: false)
            let url = parts.first.map(trimmed) ?? ""
            let label = parts.count > 1 ? trimmed(parts[1]) : ""
            var headers = setting.headers
            var isDRM = setting.isDRM
            if let pipe {
                let parsed = LivePlaylistParser.headers(pipe)
                for (name, value) in parsed.headers { LiveHeaders.set(&headers, name, value) }
                isDRM = isDRM || parsed.isDRM
            }
            if headers.isEmpty { headers = source.header }
            LiveHeaders.set(&headers, "User-Agent", nonEmpty(setting.ua) ?? extinfUA ?? source.ua)
            LiveHeaders.set(&headers, "Origin", nonEmpty(setting.origin) ?? source.origin)
            LiveHeaders.set(&headers, "Referer", nonEmpty(setting.referer) ?? source.referer)
            let support = LivePlaylistParser.support(of: url, isDRM: isDRM, needsParse: (setting.parse ?? 0) != 0)
            return LiveLine(url: url, label: label.isEmpty ? nil : label, headers: headers, support: support)
        }

        mutating func m3u(_ lines: [Substring]) {
            var setting = Setting()
            var current: (group: Int, channel: Int, ua: String?)?
            for line in lines {
                if setting.apply(line) { continue }
                if line.hasPrefix("#EXTM3U") {
                    let catchup = LiveCatchupRaw(type: attribute("catchup", line), source: attribute("catchup-source", line),
                                                 replace: attribute("catchup-replace", line))
                    playlist.catchup = catchup.isEmpty ? nil : catchup
                    if source.epg == nil && playlist.tvgURL == nil {
                        playlist.tvgURL = nonEmpty(attribute("tvg-url", line)) ?? nonEmpty(attribute("url-tvg", line))
                            ?? bareAttribute(line)
                    }
                } else if line.hasPrefix("#EXTINF:") {
                    let name = extinfName(line)
                    if isNote(name[...]) {
                        current = nil
                        continue
                    }
                    let found = group(named: attribute("group-title", line)[...])
                    let key = GroupKey(name: found.name, password: found.password)
                    let groupIndex: Int
                    if let known = self.groupIndex[key] {
                        groupIndex = known
                    } else {
                        groupIndex = append(found)
                        self.groupIndex[key] = groupIndex
                    }
                    let channelIndex = channel(in: groupIndex, named: name)
                    // Every #EXTINF overwrites these, as Android's setters do.
                    var channel = playlist.groups[groupIndex].channels[channelIndex]
                    channel.tvgName = nonEmpty(attribute("tvg-name", line))
                    channel.tvgID = nonEmpty(attribute("tvg-id", line))
                    channel.logo = nonEmpty(attribute("tvg-logo", line))
                    let catchup = LiveCatchupRaw(type: attribute("catchup", line), source: attribute("catchup-source", line),
                                                 replace: attribute("catchup-replace", line))
                    channel.catchup = catchup.isEmpty ? nil : catchup
                    playlist.groups[groupIndex].channels[channelIndex] = channel
                    current = (groupIndex, channelIndex, nonEmpty(attribute("http-user-agent", line)))
                } else if let current, !line.hasPrefix("#") {
                    let (address, pipe) = splitPipe(line)
                    // An address that is skipped clears nothing (LiveParser.java:129 before :132).
                    guard address.contains("://") else { continue }
                    let made = self.line(address, pipe: pipe, setting: setting, extinfUA: current.ua)
                    playlist.groups[current.group].channels[current.channel].lines.append(made)
                    setting = Setting()
                }
            }
        }

        mutating func txt(_ lines: [Substring]) {
            var setting = Setting()
            for line in lines {
                // X-7: a setting line is never also a channel line (Android reads `ua=a, b` as a
                // channel too, which only ever adds nothing).
                if setting.apply(line) { continue }
                let comma = line.firstIndex(of: ",")
                let head = comma.map { line[..<$0] } ?? line
                if line.contains("#genre#") {
                    setting = Setting()
                    // txt never merges groups; an empty group stays (B-5, LiveParser.java:145).
                    _ = append(group(named: head))
                    continue
                }
                guard let comma, !isNote(head) else { continue }
                for piece in line[line.index(after: comma)...].split(separator: "#") {
                    let (address, pipe) = splitPipe(piece)
                    guard address.contains("://") else { continue }
                    if playlist.groups.isEmpty {
                        _ = append(LiveGroup(name: LivePlaylist.defaultGroupName, password: nil, channels: []))
                    }
                    let groupIndex = playlist.groups.count - 1
                    let channelIndex = channel(in: groupIndex, named: String(head))
                    let made = self.line(address, pipe: pipe, setting: setting, extinfUA: nil)
                    playlist.groups[groupIndex].channels[channelIndex].lines.append(made)
                }
            }
        }
    }

    // MARK: line helpers

    private static func splitPipe(_ text: Substring) -> (address: Substring, pipe: Substring?) {
        guard let bar = text.firstIndex(of: "|") else { return (text, nil) }
        return (text[..<bar], text[text.index(after: bar)...])
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// `isMetaChannel`: an "updated at" note, not a channel.
    private static func isNote(_ name: Substring) -> Bool {
        let text = name.trimmingCharacters(in: .whitespaces).lowercased()
        return ["更新时间", "更新日期", "update time", "update date", "last update"].contains { text.hasPrefix($0) }
    }

    /// `NAME = .*,(.+?)$`: after the last comma that has text after it, trimmed.
    private static func extinfName(_ line: Substring) -> String {
        let text = trimmed(line)
        var end = text.endIndex
        while let comma = text[..<end].lastIndex(of: ",") {
            let after = text.index(after: comma)
            if after < text.endIndex { return text[after...].trimmingCharacters(in: .whitespacesAndNewlines) }
            end = comma
        }
        return ""
    }

    /// `.*key="(.?|.+?)".*`: the last `key="` that has a closing quote, up to that quote, trimmed.
    private static func attribute(_ key: String, _ line: Substring) -> String {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        var end = text.endIndex
        while let start = text.range(of: key + "=\"", options: .backwards, range: text.startIndex..<end) {
            if let close = text[start.upperBound...].firstIndex(of: "\"") {
                return trimmed(text[start.upperBound..<close])
            }
            end = start.lowerBound
        }
        return ""
    }

    /// `extract(line, "tvg-url=", "url-tvg=")`: an unquoted guide address in a space-split header.
    private static func bareAttribute(_ line: Substring) -> String? {
        for token in line.split(separator: " ") where token.contains("tvg-url=") || token.contains("url-tvg=") {
            let parts = token.split(separator: "=", omittingEmptySubsequences: false)
            return nonEmpty(parts[1].replacingOccurrences(of: "\"", with: ""))
        }
        return nil
    }

    /// D§6.2.8. A DRM or parse flag decides first: such a line cannot be played as it is, whatever
    /// its scheme.
    static func support(of url: String, isDRM: Bool, needsParse: Bool) -> LineSupport {
        if isDRM { return .unsupported(.drm) }
        if needsParse { return .unsupported(.parse) }
        guard let separator = url.range(of: "://") else { return .unsupported(.other) }
        switch url[..<separator.lowerBound].lowercased() {
        case "http", "https": return isYouTube(url[separator.upperBound...]) ? .unsupported(.youtube) : .playable
        case "rtmp", "rtsp": return .attempt
        case "video": return .unsupported(.sniff)
        case "p3p", "mitv", "tvbus", "thunder": return .unsupported(.p2p)
        case "proxy": return .unsupported(.proxy)
        default: return .unsupported(.other)
        }
    }

    private static func isYouTube(_ rest: Substring) -> Bool {
        var host = rest.prefix { !"/?#".contains($0) }
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        return YouTubeURL.isYouTubeHost(String(host.prefix { $0 != ":" }))
    }
}

private extension LiveCatchupRaw {
    var isEmpty: Bool { type.isEmpty && source.isEmpty && replace.isEmpty }
}
