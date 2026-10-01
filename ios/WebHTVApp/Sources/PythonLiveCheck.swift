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
    /// The contract in the order a person meets it. `initialize` has no call of its own: it runs
    /// inside the first `home`, and a failure is attributed to it when Python says `init` raised.
    enum Stage: String, CaseIterable {
        case load, initialize = "init", home, category, search, detail, player, media
    }

    struct Result {
        var site = ""
        var steps = [String]()
        var passed = Set<Stage>()
        /// The first stage that stopped the chain, and why, already sorted into a cause.
        var failedStage: Stage?
        var failure: String?
        var cause: String?

        var summary: String {
            let trail = steps.joined(separator: " → ")
            if let failure { return "FAILED [\(site)] \(trail) ✗ \(failure)" }
            return "OK [\(site)] \(trail)"
        }

        mutating func pass(_ stage: Stage, _ step: String? = nil) {
            passed.insert(stage)
            steps.append(step ?? stage.rawValue)
        }

        mutating func fail(_ stage: Stage, _ message: String, cause: String) {
            guard failure == nil else { return }
            failedStage = stage
            failure = message
            self.cause = cause
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

    /// IOS-POC-7L (P5), per site since IOS-POC-37: every configured Python site driven through the
    /// **whole** contract, one row each, with the stage that stopped it and the cause sorted into
    /// dependency / site-network / content / script / policy.
    ///
    /// The bar is the full chain rather than `init → home`, because a shallower one lies. 麒麟影视
    /// imports `requests` inside a method: its module-level exec succeeds and its home returns five
    /// categories, so a home-deep survey counts it as driven — and it breaks the moment that method
    /// is called. A site only counts as complete when it reached media bytes.
    ///
    /// The rows print as they finish, so a long sweep shows progress and a crash loses nothing.
    static func survey() async -> String {
        guard let (config, source) = installedConfiguration() else { return "skipped: no configuration" }
        let resolver = CSPSourceResolver(source: source)
        let sites = config.pythonSpiderSites
        var reached = [Stage: Int](), causes = [String: Int]()

        for (index, site) in sites.enumerated() {
            let result: Result
            if resolver.canResolve(site) {
                // Be a guest. This fetches one script per site from the configuration's origin, and a
                // run of it immediately after the audit script got GitLab to stop answering entirely —
                // which then reads as "0 of 42 driven" and is a lie about the code.
                try? await Task.sleep(for: .milliseconds(400))
                result = await drive(site: site, resolver: resolver)
            } else {
                var refused = Result(site: site.name)
                refused.fail(.load, "not offered by the resolver", cause: "policy")
                result = refused
            }
            result.passed.forEach { reached[$0, default: 0] += 1 }
            causes[result.passed.contains(.media) ? "complete" : result.cause ?? "incomplete", default: 0] += 1
            let stages = Stage.allCases.map { stage in
                result.passed.contains(stage) ? "\(stage.rawValue)✓"
                    : result.failedStage == stage ? "\(stage.rawValue)✗" : "\(stage.rawValue)·"
            }.joined(separator: " ")
            print("[python] row \(index + 1)/\(sites.count) \(site.key) [\(site.name)] \(stages)"
                  + " | \(result.steps.joined(separator: " → "))"
                  + (result.failure.map { " | \(result.cause ?? "?"): \($0.prefix(160))" } ?? ""))
        }
        let counts = Stage.allCases.map { "\($0.rawValue) \(reached[$0, default: 0])" }.joined(separator: ", ")
        let tally = causes.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
        return "sites \(sites.count) | reached: \(counts) | outcome: \(tally)"
    }

    /// `load → init → home → category → detail → search → player → bytes`. Every stage records what
    /// it saw; search is not on the playback path, so its failure is recorded without stopping the
    /// chain, and later stages try a few candidates rather than judging a site on its first item.
    private static func drive(site: Site, resolver: CSPSourceResolver) async -> Result {
        var result = Result(site: site.name)
        _ = PythonSpiderRuntime.takeFailure(siteKey: site.key)  // nothing stale from an earlier run

        let session: SpiderSession
        do {
            session = try await deadline { try await resolver.session(for: site) }
            result.pass(.load)
        } catch {
            result.fail(.load, "\(error)", cause: cause(of: error, site: site, loading: true))
            return result
        }
        defer { Task { await session.destroy() } }

        var candidates = [[String: Any]]()
        do {
            let home = try decode(try await deadline { try await session.home() })
            result.pass(.initialize)
            let classes = home["class"] as? [[String: Any]] ?? []
            candidates = home["list"] as? [[String: Any]] ?? []
            result.pass(.home, "home(\(classes.count) classes, \(candidates.count) items)")

            var listed = false
            for tid in classes.prefix(3).compactMap({ string($0["type_id"]) }) {
                do {
                    let listing = try decode(try await deadline { try await session.category(tid: tid, page: "1") })
                    let items = listing["list"] as? [[String: Any]] ?? []
                    guard !items.isEmpty else { continue }
                    result.pass(.category, "category(\(items.count) items)")
                    candidates = items + candidates
                    listed = true
                    break
                } catch {
                    result.fail(.category, "\(error)", cause: cause(of: error, site: site))
                    break
                }
            }
            if !listed { result.fail(.category, "no category returned items", cause: "content") }
        } catch {
            // `init` runs inside the first `home`; Python names the method that raised. A failure
            // Python did not record happened after both returned, so `init` passed.
            let python = PythonSpiderRuntime.takeFailure(siteKey: site.key)
            let stage: Stage = python?.method == "init" ? .initialize : .home
            if stage == .home { result.passed.insert(.initialize) }
            result.fail(stage, "\(error)", cause: cause(of: error, site: site, python: python?.detail))
            return result
        }

        var vod: [String: Any]?
        for vodID in candidates.compactMap({ string($0["vod_id"]) }).prefix(2) {
            do {
                let detail = try decode(try await deadline { try await session.detail(ids: [vodID]) })
                if let found = (detail["list"] as? [[String: Any]])?.first,
                   !(string(found["vod_play_url"]) ?? "").isEmpty {
                    vod = found
                    break
                }
            } catch {
                result.fail(.detail, "\(error)", cause: cause(of: error, site: site))
                break
            }
        }
        guard let vod else {
            result.fail(.detail, candidates.isEmpty ? "nothing listed to open" : "detail carried no playable line",
                        cause: "content")
            return result
        }
        result.pass(.detail)

        let name = string(vod["vod_name"]) ?? ""
        let term = String(name.prefix(2))
        do {
            let found = try decode(try await deadline {
                try await session.search(key: term.isEmpty ? "影" : term)
            })
            let hits = (found["list"] as? [[String: Any]] ?? []).count
            if hits > 0 { result.pass(.search, "search(\(hits) hits)") } else { result.steps.append("search(0 hits)") }
        } catch {
            result.steps.append("search✗(\(cause(of: error, site: site)))")
        }

        let froms = (string(vod["vod_play_from"]) ?? "").components(separatedBy: "$$$")
        let lines = (string(vod["vod_play_url"]) ?? "").components(separatedBy: "$$$")
        var lastVerdict = "no line tried", verdictCause = "content"
        for (flag, episodes) in zip(froms, lines).prefix(3) {
            guard let episode = episodes.components(separatedBy: "#").first else { continue }
            let target = episode.contains("$") ? String(episode.drop(while: { $0 != "$" }).dropFirst()) : episode
            do {
                let play = try decode(try await deadline { try await session.player(flag: flag, id: target) })
                guard let raw = playURL(play["url"]), let media = URL(string: raw), media.scheme != nil else {
                    lastVerdict = "player returned no URL"
                    continue
                }
                if !result.passed.contains(.player) { result.pass(.player) }
                let headers = play["header"] as? [String: String] ?? [:]
                if (play["parse"] as? Int) == 1 || (play["jx"] as? Int) == 1 {
                    // parse:1 is the spider saying "this is a page": the app sniffs it with
                    // MediaSniffer (SourceClient.target), so this does too, then probes what it found.
                    guard let sniffed = await MediaSniffer.shared.sniff(
                        page: media, referer: headers["Referer"] ?? headers["referer"]) else {
                        lastVerdict = "parse=1 page yielded no stream to the sniffer: \(media.absoluteString.prefix(80))"
                        verdictCause = "content(parse=1)"
                        continue
                    }
                    if await MediaProbe.classify(sniffed, headers: headers) == .media {
                        result.pass(.media, "sniff → probe(media)")
                        return result
                    }
                    lastVerdict = "the sniffed URL did not serve media: \(sniffed.absoluteString.prefix(80))"
                    verdictCause = "content(parse=1)"
                    continue
                }
                // The step that makes this more than a JSON exercise: real bytes off the wire.
                let verdict = await MediaProbe.classify(media, headers: headers)
                if verdict == .media {
                    result.pass(.media, "probe(media)")
                    return result
                }
                lastVerdict = "the resolved URL served \(verdict): \(media.absoluteString.prefix(80))"
            } catch {
                result.fail(.player, "\(error)", cause: cause(of: error, site: site))
                return result
            }
        }
        result.fail(result.passed.contains(.player) ? .media : .player, lastVerdict, cause: verdictCause)
        return result
    }

    // MARK: - cause

    /// Sorts a failure into the thing that would fix it. A missing module is the runtime's to fix;
    /// a timeout, a 403 or a site that answers HTML where the script expects JSON is not, and must
    /// never be counted against a dependency.
    private static func cause(of error: Error, site: Site, loading: Bool = false,
                              python: String? = nil) -> String {
        let text = python ?? PythonSpiderRuntime.takeFailure(siteKey: site.key)?.detail ?? "\(error)"
        if let range = text.range(of: "No module named ") {
            return "dependency:" + text[range.upperBound...].prefix(while: { $0 != "\n" && $0 != "." })
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\\\""))
        }
        if text.contains("Cannot load native module") || text.contains("ImportError") { return "dependency:native" }
        if error is TimedOut { return "site/network(timeout)" }
        if loading, text.contains("rejected(reference"), text.contains("refuses a") { return "policy" }
        let network = ["Timeout", "timed out", "ConnectionError", "ConnectError", "SSLError", "NameResolution",
                       "Max retries exceeded", "URLError", "RemoteDisconnected", "ConnectionReset",
                       "HTTPError", "status code", "NSURLErrorDomain", "badServerResponse"]
        if network.contains(where: text.contains) { return "site/network" }
        if loading, text.contains("rejected(reference") {
            // The same-origin + HTTPS rule refusing a script is policy, by design; the script's own
            // download failing is the site's.
            return text.contains("refuses a") ? "policy" : "site/network(script fetch)"
        }
        if text.contains("JSONDecodeError") || text.contains("did not decode") || text.contains("notText") {
            return "site/content(unexpected answer)"
        }
        let last = text.split(separator: "\n").last.map(String.init) ?? text
        return "script:" + last.prefix(60)
    }

    // MARK: - deadline

    private struct TimedOut: Error, CustomStringConvertible {
        var description: String { "stage timed out" }
    }

    /// Bounds one stage. A spider that sets no timeout on its own request would otherwise hang the
    /// whole sweep; the abandoned call keeps running on that site's queue, which is only that
    /// site's problem.
    private static func deadline<T: Sendable>(_ seconds: Int = 45,
                                              _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            Task { do { once.finish(.success(try await work())) } catch { once.finish(.failure(error)) } }
            Task { try? await Task.sleep(for: .seconds(seconds)); once.finish(.failure(TimedOut())) }
        }
    }

    /// Resumes a continuation exactly once, whichever of the work and the timer gets there first.
    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
        func finish(_ outcome: Swift.Result<T, Error>) {
            lock.withLock { () -> CheckedContinuation<T, Error>? in
                defer { continuation = nil }
                return continuation
            }?.resume(with: outcome)
        }
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
