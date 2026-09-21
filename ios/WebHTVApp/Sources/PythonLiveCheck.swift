#if DEBUG
import Foundation
import WebHTVCore

/// IOS-POC-7J (P4): drives a **real** Python source all the way to media bytes.
///
/// Not a hard-coded script this time — it reads the configuration the app already has, picks a
/// Python site the resolver is willing to drive, and goes through `CSPSourceResolver`,
/// `SpiderSession` and `MediaProbe` exactly as the app does. If this passes, the path the UI uses
/// is the path that was tested.
///
/// It cannot be a `swift test`: that runs on macOS, where this interpreter does not exist.
enum PythonLiveCheck {
    struct Result {
        var site = ""
        var steps = [String]()
        var failure: String?

        var summary: String {
            let trail = steps.joined(separator: " → ")
            if let failure { return "FAILED [\(site)] \(trail) ✗ \(failure)" }
            return "OK [\(site)] \(trail)"
        }
    }

    /// The configuration the app persisted, and where it came from. Reading both from the same place
    /// the app reads them keeps this honest: a check that built its own configuration would prove
    /// something about the check.
    private static func installedConfiguration() -> (WebHTVConfig, ConfigSource)? {
        guard let stored = UserDefaults.standard.string(forKey: "configSourceURL"),
              let url = URL(string: stored),
              let support = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                        in: .userDomainMask,
                                                        appropriateFor: nil, create: false),
              let data = try? Data(contentsOf: support.appendingPathComponent("wang-movie.json")),
              let config = try? JSONDecoder().decode(WebHTVConfig.self, from: data)
        else { return nil }
        return (config, .remote(url))
    }

    static func run() async -> String {
        guard let (config, source) = installedConfiguration() else {
            return "skipped: no remote configuration is installed yet"
        }
        let resolver = CSPSourceResolver(source: source)
        let candidates = config.pythonSpiderSites.filter(resolver.canResolve)
        guard !candidates.isEmpty else { return "skipped: the configuration has no drivable Python site" }

        // 皮皮虾 first when it is there: 7.4 KB, no third-party imports, and the script P1 picked as
        // the lightest same-origin candidate. A `sorted` predicate that ignores its right operand is
        // not an ordering at all and gave an arbitrary winner, so the preferred one is lifted out.
        let preferred = candidates.filter { $0.api.contains("皮皮虾") }
        let ordered = preferred + candidates.filter { !$0.api.contains("皮皮虾") }

        // Report every attempt. One script failing on a dependency is a fact about that script, and
        // P5 has to count those; it is not a reason to say nothing about the rest.
        var attempts = [String]()
        for site in ordered.prefix(4) {
            let result = await drive(site: site, resolver: resolver)
            if result.failure == nil { return result.summary }
            attempts.append(result.summary)
        }
        return attempts.joined(separator: "  |  ")
    }

    /// IOS-POC-7L (P5): every Python site the resolver will take, driven through the **whole**
    /// contract, with the reason recorded when it will not go.
    ///
    /// The bar is the full chain rather than `init → home`, because a shallower one lies. 麒麟影视
    /// imports `requests` inside a method: its module-level exec succeeds and its home returns five
    /// categories, so a home-deep survey counts it as driven — and it breaks the moment that method
    /// is called. A site only counts when it reached media bytes.
    ///
    /// The sites that cannot load cost nothing extra here: they fail while their script is being
    /// executed, before any of their own network happens.
    static func survey() async -> String {
        guard let (config, source) = installedConfiguration() else { return "skipped: no configuration" }
        let resolver = CSPSourceResolver(source: source)
        let sites = config.pythonSpiderSites
        var driven = [String](), refused = [String: Int]()

        for site in sites {
            guard resolver.canResolve(site) else {
                refused["not offered", default: 0] += 1
                continue
            }
            // Be a guest. This fetches one script per site from the configuration's origin, and a
            // run of it immediately after the audit script got GitLab to stop answering entirely —
            // which then reads as "0 of 42 driven" and is a lie about the code.
            try? await Task.sleep(for: .milliseconds(400))
            let result = await drive(site: site, resolver: resolver)
            if let failure = result.failure {
                refused[reason(for: failure), default: 0] += 1
            } else {
                driven.append(site.name)
            }
        }
        let tally = refused.sorted { $0.value > $1.value }
            .map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
        return "driven \(driven.count)/\(sites.count): \(driven.joined(separator: ", "))  |  refused: \(tally)"
    }

    /// Collapses a traceback to the thing that stopped it, so the tally counts causes not messages.
    private static func reason(for text: String) -> String {
        if let range = text.range(of: "ModuleNotFoundError: No module named ") {
            return "missing " + text[range.upperBound...].prefix(while: { $0 != "\n" })
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\\\""))
        }
        for marker in ["Refused to load", "did not decode", "SyntaxError", "UnicodeEncodeError"]
        where text.contains(marker) { return marker }
        return String(text.prefix(40))
    }

    /// `init → home → category → detail → search → player → bytes`. Each step records what it saw,
    /// so a failure says which one broke rather than that something did.
    private static func drive(site: Site, resolver: CSPSourceResolver) async -> Result {
        var result = Result(site: site.name)
        do {
            let session = try await resolver.session(for: site)
            defer { Task { await session.destroy() } }
            result.steps.append("init")

            let home = try decode(try await session.home())
            let classes = home["class"] as? [[String: Any]] ?? []
            result.steps.append("home(\(classes.count) classes)")
            guard let first = classes.first, let tid = string(first["type_id"]) else {
                result.failure = "home returned no categories"
                return result
            }

            let listing = try decode(try await session.category(tid: tid, page: "1"))
            let items = listing["list"] as? [[String: Any]] ?? []
            result.steps.append("category(\(items.count) items)")
            guard let vodID = items.compactMap({ string($0["vod_id"]) }).first else {
                result.failure = "category \(tid) returned no items"
                return result
            }

            let detail = try decode(try await session.detail(ids: [vodID]))
            guard let vod = (detail["list"] as? [[String: Any]])?.first else {
                result.failure = "detail \(vodID) returned no vod"
                return result
            }
            result.steps.append("detail")

            // Search is part of the contract even though playback does not need it, so it is driven
            // and reported rather than skipped.
            let name = string(vod["vod_name"]) ?? ""
            let term = String(name.prefix(2))
            let found = try decode(try await session.search(key: term.isEmpty ? "影" : term))
            result.steps.append("search(\((found["list"] as? [[String: Any]] ?? []).count) hits)")

            let froms = (string(vod["vod_play_from"]) ?? "").components(separatedBy: "$$$")
            let urls = (string(vod["vod_play_url"]) ?? "").components(separatedBy: "$$$")
            guard let flag = froms.first, let episodes = urls.first,
                  let episode = episodes.components(separatedBy: "#").first else {
                result.failure = "detail carried no playable line"
                return result
            }
            let target = String(episode.drop(while: { $0 != "$" }).dropFirst())

            let play = try decode(try await session.player(flag: flag, id: target))
            result.steps.append("player")
            guard let raw = playURL(play["url"]), let media = URL(string: raw) else {
                result.failure = "player returned no URL"
                return result
            }
            let headers = play["header"] as? [String: String] ?? [:]

            // The step that makes this P4 rather than a JSON exercise: real bytes off the wire.
            let verdict = await MediaProbe.classify(media, headers: headers)
            result.steps.append("probe(\(verdict))")
            if verdict != .media {
                result.failure = "the resolved URL did not serve media: \(media.absoluteString.prefix(80))"
            }
        } catch {
            result.failure = "\(error)"
        }
        return result
    }

    // MARK: - small readers

    private static func decode(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PythonSpiderSource.Failure.notText(String(text.prefix(120)))
        }
        return object
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// `playerContent.url` has three shapes, as IOS-POC-5Q recorded: a string, a list of pairs, or a
    /// list of strings. Only the first playable one is needed here.
    private static func playURL(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let list = value as? [Any] {
            for entry in list {
                if let pair = entry as? [Any], let candidate = pair.last as? String { return candidate }
                if let text = entry as? String, text.hasPrefix("http") { return text }
            }
        }
        return nil
    }
}
#endif
