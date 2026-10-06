import Foundation

/// One entry of a configuration's `parses` — Android's `bean/Parse.java` (IOS-POC-56).
///
/// `type` 0 is a web page that plays the address (`<url><address>` in a web view, sniffed), 1 a JSON
/// API (`GET <url><address>` → `url`). 2 and 3 run inside the Android JAR and 4 is Android's own
/// 超級解析; this app executes 0 and 1 only.
public struct ParseEntry: Decodable, Sendable, Equatable {
    public let name: String
    public let type: Int
    public let url: String
    /// `ext.flag`: the lines this service is meant for. Empty means any line.
    public let flags: [String]
    /// `ext.header`: what the service itself is asked with.
    public internal(set) var header: [String: String]

    public init(name: String = "", type: Int, url: String, flags: [String] = [], header: [String: String] = [:]) {
        self.name = name
        self.type = type
        self.url = url
        self.flags = flags
        self.header = header
    }

    enum CodingKeys: String, CodingKey { case name, type, url, ext }
    enum ExtKeys: String, CodingKey { case flag, header }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? values.decode(String.self, forKey: .name)) ?? ""
        // `ParseTypeAdapter`: a number, or a string holding one; anything else is 0. One real
        // configuration writes `"type": "1"`.
        type = (try? values.decode(Int.self, forKey: .type))
            ?? (try? values.decode(String.self, forKey: .type)).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            ?? 0
        url = (try? values.decode(String.self, forKey: .url)) ?? ""
        let ext = try? values.nestedContainer(keyedBy: ExtKeys.self, forKey: .ext)
        flags = ((try? ext?.decode([Lenient<String>].self, forKey: .flag)) ?? nil)?.compactMap(\.value) ?? []
        header = ((try? ext?.decode([String: Lenient<String>].self, forKey: .header)) ?? nil)?
            .compactMapValues(\.value) ?? [:]
    }

    /// What this app can actually call: http(s), and not the device itself — a `127.0.0.1` service
    /// is one an Android JAR starts, and nothing listens there on iOS.
    var unusableReason: String? {
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return "不是 http(s) 網址" }
        let host = (parsed.host ?? "").lowercased()
        if ["127.0.0.1", "localhost", "::1", "0.0.0.0"].contains(host) { return "是 Android JAR 在本機提供的服務" }
        return nil
    }

    var label: String { name.isEmpty ? url : name }
}

/// A configuration's global parsing: its `parses` and its VIP line names (`flags`).
public struct ParseSettings: Sendable, Equatable {
    public let parses: [ParseEntry]
    public let flags: [String]

    public init(parses: [ParseEntry] = [], flags: [String] = []) {
        // `VodConfig.initParse`: `.distinct()` on a type whose equality is the name, first one kept.
        var seen = Set<String>()
        self.parses = parses.filter { seen.insert($0.name).inserted }
        self.flags = flags
    }

    /// `VodConfig.getParses(type, flag)`: the ones meant for this line, else every one of the type.
    func parses(type: Int, flag: String) -> [ParseEntry] {
        let items = parses.filter { $0.type == type }
        let meant = items.filter { $0.flags.contains(flag) }
        return meant.isEmpty ? items : meant
    }
}

/// Decodes what it can and leaves the rest nil, so one odd entry costs itself, not its list.
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// What to do with one play result (IOS-POC-56).
public enum ParsePlan: Equatable, Sendable {
    /// No parse service: the address is played, probed or sniffed exactly as before this task.
    case none
    /// Ask these services, all at once; the first answer wins. `header` is the chosen parse's
    /// header — the media's when a JSON service names none (`ParseJob.getHeader`).
    case run(json: [ParseEntry], web: [ParseEntry], header: [String: String])
    /// The result asks for a parse this app cannot run. Nothing else is tried in its place.
    case unsupported(String)
}

public enum GlobalParse {
    /// `Result.needParse()`, `Result.shouldUseParse()` and `ParseJob.setParse()`, in that order.
    ///
    /// `header` is the play result's own header. With no selection UI, a VIP line or `jx:1` uses
    /// Android's default selection, 超級解析: every type-1 and type-0 service meant for the line.
    public static func plan(parse: Int, jx: Int, playUrl: String, flag: String,
                            header: [String: String], settings: ParseSettings) -> ParsePlan {
        let useParse = !settings.parses.isEmpty
            && ((playUrl.isEmpty && settings.flags.contains(flag)) || jx == 1)
        guard parse == 1 || jx == 1 || useParse else { return .none }

        var chosen: ParseEntry
        if playUrl.hasPrefix("json:") {
            chosen = ParseEntry(type: 1, url: String(playUrl.dropFirst(5)))
        } else if playUrl.hasPrefix("parse:") {
            let name = String(playUrl.dropFirst(6))
            guard let named = settings.parses.first(where: { $0.name == name }) else {
                return .unsupported("這條線路指定的解析「\(name)」不在設定裡。")
            }
            chosen = named
        } else if useParse {
            let json = settings.parses(type: 1, flag: flag).filter { $0.unusableReason == nil }
            let web = settings.parses(type: 0, flag: flag).filter { $0.unusableReason == nil }
            guard !json.isEmpty || !web.isEmpty else {
                return .unsupported("設定的解析接口沒有 iOS 能用的（目前只支援 type 0 網頁解析、type 1 JSON 解析）。")
            }
            return .run(json: json, web: web, header: header)
        } else {
            // `Parse(0, playUrl)`; an empty one is "sniff the address itself", which is `.none`.
            guard !playUrl.isEmpty else { return .none }
            chosen = ParseEntry(type: 0, url: playUrl)
        }

        guard chosen.type == 0 || chosen.type == 1 else {
            return .unsupported("這條線路要用的解析「\(chosen.label)」是 type \(chosen.type)，iOS 尚未支援。")
        }
        if let reason = chosen.unusableReason {
            return .unsupported("這條線路要用的解析「\(chosen.label)」\(reason)，iOS 無法使用。")
        }
        // `Parse.setHeader`: the result's header only when the parse names none of its own.
        if chosen.header.isEmpty { chosen.header = header }
        return chosen.type == 1 ? .run(json: [chosen], web: [], header: chosen.header)
                                : .run(json: [], web: [chosen], header: chosen.header)
    }
}

public enum GlobalParseError: LocalizedError, Equatable {
    case unsupported(String)
    /// Every service was asked and none answered with a playable address.
    case unresolved([String])

    public var errorDescription: String? {
        switch self {
        case .unsupported(let message): message
        case .unresolved(let names):
            "設定的解析接口都沒有解出影片（試過：\(names.joined(separator: "、"))）。可能是接口暫時失效，請換一條線路。"
        }
    }
}

/// Runs a `ParsePlan.run`: `ParseJob` for types 0 and 1.
enum GlobalParser {
    /// `Constant.TIMEOUT_PARSE_DEF` / `TIMEOUT_PARSE_WEB`: one budget for the whole parse.
    static let budget: Duration = .seconds(15)
    /// What the JSON services are asked through. Task-local, like `MediaSniffer.waitsForTurn`, so a
    /// test can answer for them through the real `SourceClient` path without a global.
    static let session = TaskLocal<URLSession>(wrappedValue: .webHTV)

    struct Parsed: Sendable, Equatable {
        let url: URL
        let headers: [String: String]
        let subtitles: [SniffedSubtitle]
    }

    private enum Outcome: Sendable { case found(Parsed), miss, deadline }

    /// Every JSON service and the web services side by side; the first address wins and the rest
    /// are cancelled. Nil when none answered within `budget`.
    static func resolve(_ address: String, json: [ParseEntry], web: [ParseEntry], header: [String: String],
                        budget: Duration = budget, session: URLSession = session.get()) async -> Parsed? {
        await withTaskGroup(of: Outcome.self) { group in
            for entry in json {
                group.addTask { await Self.json(entry, address, fallback: header, session: session).map(Outcome.found) ?? .miss }
            }
            if !web.isEmpty {
                group.addTask { await Self.web(web, address, header: header, budget: budget).map(Outcome.found) ?? .miss }
            }
            group.addTask {
                try? await Task.sleep(for: budget)
                return .deadline
            }
            var pending = json.count + (web.isEmpty ? 0 : 1)
            while pending > 0, let outcome = await group.next() {
                switch outcome {
                case .found(let parsed):
                    group.cancelAll()
                    return parsed
                case .deadline:
                    pending = 0
                case .miss:
                    pending -= 1
                }
            }
            group.cancelAll()
            return nil
        }
    }

    /// `ParseJob.jsonParse`. The request carries the service's header; the media gets the
    /// `User-Agent`/`Referer`/`Cookie` the answer names, else `fallback`.
    static func json(_ entry: ParseEntry, _ address: String, fallback: [String: String],
                     session: URLSession) async -> Parsed? {
        guard let endpoint = URL(string: entry.url + address) else { return nil }
        var request = URLRequest(url: endpoint)
        for (name, value) in entry.header { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, _) = try? await session.data(for: request),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let top = object["url"] as? String ?? ""
        let text = top.isEmpty ? ((object["data"] as? [String: Any])?["url"] as? String ?? "") : top
        // Android's own sanity check is the length; the scheme check is what this player can open
        // (an expired account answers a relative error clip, IOS-POC-44D).
        guard text.count > 40, let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        var headers = [String: String]()
        for (key, value) in object {
            guard let value = value as? String else { continue }
            switch key.lowercased() {
            // `ua` is in Android's filter for the same reason; it means the user agent.
            case "user-agent", "ua": headers["User-Agent"] = value
            case "referer": headers["Referer"] = value
            case "cookie": headers["Cookie"] = value
            default: break
            }
        }
        let media = headers.isEmpty ? fallback : headers
        guard await isMedia(url, headers: media, session: session) else { return nil }
        return Parsed(url: url, headers: media, subtitles: [])
    }

    /// What a service hands back is only an answer when it reads as media with the headers the player
    /// will send. A dead service answers with its own error clip on a host that no longer resolves
    /// (云解, measured 2026-10-06), and playing that turns the service's failure into a player error.
    static func isMedia(_ url: URL, headers: [String: String], session: URLSession) async -> Bool {
        await MediaProbe.classify(url, headers: headers, session: session) == .media
    }

    /// `ParseJob.startWeb`: one service opens its page with its own header; several share one page of
    /// iframes, Android's `parse.html`, which sends no header of its own.
    @MainActor
    static func web(_ entries: [ParseEntry], _ address: String, header: [String: String],
                    budget: Duration) async -> Parsed? {
        let page: URL?
        let pageHeaders: [String: String]
        if entries.count == 1 {
            page = URL(string: entries[0].url + address)
            pageHeaders = entries[0].header
        } else {
            page = framesPage(entries.map { $0.url + address })
            pageHeaders = [:]
        }
        guard let page,
              let sniffed = await MediaSniffer.shared.sniffWithSubtitles(page: page, headers: pageHeaders, timeout: budget)
        else { return nil }
        // What a web view sends with the stream: its user agent, and the asking frame as the
        // referrer — the origin only, the default policy for a cross-origin request.
        var headers = [String: String]()
        if let agent = pageHeaders.first(where: { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame })?.value {
            headers["User-Agent"] = agent
        }
        if let frame = sniffed.frameURL, let scheme = frame.scheme, scheme.hasPrefix("http"), let host = frame.host {
            headers["Referer"] = "\(scheme)://\(host)\(frame.port.map { ":\($0)" } ?? "")/"
        }
        guard await isMedia(sniffed.mediaURL, headers: headers, session: session.get()) else { return nil }
        return Parsed(url: sniffed.mediaURL, headers: headers, subtitles: sniffed.subtitles)
    }

    /// Android's `assets/parse.html`, as a `data:` page: every service in its own sandboxed iframe.
    static func framesPage(_ pages: [String]) -> URL? {
        let frames = pages.map { page -> String in
            let attribute = page.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;")
            return "<iframe src=\"\(attribute)\" sandbox=\"allow-scripts allow-same-origin allow-forms\"></iframe>"
        }.joined()
        let html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>\(frames)</body></html>"
        return URL(string: "data:text/html;charset=utf-8;base64,\(Data(html.utf8).base64EncodedString())")
    }
}
