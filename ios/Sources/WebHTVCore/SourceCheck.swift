import Foundation

/// IOS-POC-41C: drives every source the way the app does and says where each one stops — the
/// on-device form of `sweepsEveryDrivableSourceThroughTheAppPath`, which now calls this too, so
/// the Mac's sweep and the phone's check mean the same thing
/// (`docs/IOS-POC-41-source-health-diagnostics.md`).
public enum SourceCheck {
    public enum Stage: String, Sendable { case listing = "片單", detail = "詳情", play = "播放" }

    public enum Verdict: Equatable, Sendable {
        /// The first episode's address answered with media bytes.
        case playable
        /// The listing's request failed, sorted by IOS-POC-41A.
        case unreachable(SiteUnreachable)
        /// The site answered and nothing in it was a title: an outdated rule, a page that needs
        /// JavaScript, a parked domain. Not the site's health either way, so nothing is recorded.
        case noTitles
        case noEpisodes
        case noPlayURL
        /// The address resolved to a web page or nothing readable.
        case notMedia
        case failed(Stage, String)
        /// No answer within the check's limit.
        case timedOut
        /// IOS-POC-56: the first episode needs a global parse service that did not answer, or one
        /// this app cannot run. That is the service's state, not the source's, so nothing is recorded.
        case needsParse(String)
    }

    /// The report's groups, in its order.
    public enum Category: CaseIterable, Sendable {
        case playable, unreachable, noTitles, noEpisodes, noPlayURL, notMedia, needsParse, failed, timedOut

        public var label: String {
            switch self {
            case .playable: "可以播放"
            case .unreachable: "網站連不上"
            case .noTitles: "網站有回應但取不到片單"
            case .noEpisodes: "有片單但沒有集數"
            case .noPlayURL: "取不到播放網址"
            case .notMedia: "播放網址不是影片"
            case .needsParse: "需要解析接口，未解出"
            case .failed: "其他錯誤"
            case .timedOut: "檢查逾時"
            }
        }
    }

    public struct Result: Sendable {
        /// The site's position in the list handed to `run`.
        public let index: Int
        public let site: Site
        public let verdict: Verdict
        /// What the check saw on the way, for the sweep's log line.
        public let trail: String
        let detailMilliseconds: Int

        public var category: Category {
            switch verdict {
            case .playable: .playable
            case .unreachable: .unreachable
            case .noTitles: .noTitles
            case .noEpisodes: .noEpisodes
            case .noPlayURL: .noPlayURL
            case .notMedia: .notMedia
            case .needsParse: .needsParse
            case .failed: .failed
            case .timedOut: .timedOut
            }
        }

        /// The line under the site's name, when there is more to say than the group's label.
        public var detail: String? {
            switch verdict {
            case .unreachable(let failure): failure.reason
            case .failed(let stage, let message): "\(stage.rawValue)：\(message)"
            case .needsParse(let message): message
            default: nil
            }
        }

        /// What IOS-POC-41B records for it: each stage the check got through, and the one it stopped
        /// at. A stop it cannot attribute — no titles, the limit — records nothing.
        var healthEvents: [(SiteHealth.Event, Bool)] {
            let detail = SiteHealth.Event.detail(milliseconds: detailMilliseconds)
            switch verdict {
            case .playable: return [(.browse, true), (detail, true), (.play, true)]
            case .unreachable, .failed(.listing, _): return [(.browse, false)]
            case .noEpisodes, .failed(.detail, _): return [(.browse, true), (detail, false)]
            case .noPlayURL, .notMedia, .failed(.play, _): return [(.browse, true), (detail, true), (.play, false)]
            case .needsParse: return [(.browse, true), (detail, true)]
            case .noTitles, .timedOut: return []
            }
        }
    }

    /// One site, the app's own path: its home (or first category) → the first title's detail → the
    /// first episode's address → `MediaProbe`, which must read media bytes.
    public static func check(_ client: SourceClient) async -> (verdict: Verdict, trail: String, detailMilliseconds: Int) {
        var trail = ""
        var stage = Stage.listing
        var milliseconds = 0
        do {
            let home = try await client.home()
            trail += "classes=\(home.classes.count) home=\(home.list.count)"
            if let failure = home.failure { return (.unreachable(failure), trail, 0) }
            // A home with categories and no titles is common (8Movie); the app opens a category
            // then, and so does the check, rather than calling the site empty.
            var first = home.list.first
            if first == nil, let category = home.classes.first {
                let page = try await client.category(id: category.id)
                trail += " cat=\(page.list.count)"
                first = page.list.first
            }
            guard let vod = first else { return (.noTitles, trail, 0) }
            stage = .detail
            let started = ContinuousClock.now
            let detail = try await client.detail(id: vod.id)
            milliseconds = Int((ContinuousClock.now - started) / .milliseconds(1))
            let flags = detail?.flags ?? []
            trail += " flags=\(flags.count) eps=\(flags.first?.episodes.count ?? 0)"
            guard let episode = flags.first?.episodes.first, let flag = flags.first?.name else {
                return (.noEpisodes, trail, milliseconds)
            }
            stage = .play
            // Sites are checked side by side, and the app's one sniffer would otherwise cancel one
            // site's sniff whenever another's starts (IOS-POC-43).
            guard let target = try await MediaSniffer.waitsForTurn.withValue(true, operation: {
                try await client.playbackURL(for: episode, flag: flag)
            }) else {
                return (.noPlayURL, trail, milliseconds)
            }
            trail += " play=\(target.url.absoluteString.prefix(58))"
            if !target.headers.isEmpty { trail += " +hdr\(target.headers.count)" }
            // Resolving a URL is not the same as the media existing: AG動漫 resolves cleanly and then
            // 404s. Same classifier and headers the playback path uses, so a referer-checked CDN's
            // 403 is not called dead.
            let kind = await MediaProbe.classify(target.url, headers: target.headers)
            trail += " [\(kind)]"
            return (kind == .media ? .playable : .notMedia, trail, milliseconds)
        } catch let failure as SiteUnreachable where stage == .listing {
            return (.unreachable(failure), trail, 0)
        } catch let failure as GlobalParseError {
            return (.needsParse(failure.localizedDescription), trail, milliseconds)
        } catch {
            return (.failed(stage, error.localizedDescription), trail, milliseconds)
        }
    }

    /// Every site, `width` at a time, each given `limit` before it is reported timed out — its work is
    /// left to finish on its own, since a spider's JavaScript does not stop when cancelled. The stream
    /// ends early when a site finds the device offline: every later answer would blame the sites.
    public static func run(_ sites: [Site], resolver: CSPSourceResolver, width: Int = 8,
                           limit: Duration = .seconds(90)) -> AsyncStream<Result> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Result.self) { group in
                    var pending = sites.enumerated().makeIterator()
                    for _ in 0..<max(width, 1) {
                        if let (index, site) = pending.next() {
                            group.addTask { await bounded(index, site, resolver: resolver, limit: limit) }
                        }
                    }
                    while let result = await group.next() {
                        continuation.yield(result)
                        if case .unreachable(let failure) = result.verdict, failure.failure == .offline { break }
                        if Task.isCancelled { break }
                        if let (index, site) = pending.next() {
                            group.addTask { await bounded(index, site, resolver: resolver, limit: limit) }
                        }
                    }
                    // Sites still in flight finish within `limit`; the reader is not kept waiting.
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private actor Once {
        private var claimed = false
        func claim() -> Bool { defer { claimed = true }; return !claimed }
    }

    private static func bounded(_ index: Int, _ site: Site, resolver: CSPSourceResolver,
                                limit: Duration) async -> Result {
        await withCheckedContinuation { finished in
            let once = Once()
            Task {
                let outcome: (verdict: Verdict, trail: String, detailMilliseconds: Int)
                do {
                    outcome = await check(try await SourceClient.make(site: site, resolver: resolver))
                } catch {
                    outcome = (.failed(.listing, error.localizedDescription), "", 0)
                }
                if await once.claim() {
                    finished.resume(returning: Result(index: index, site: site, verdict: outcome.verdict,
                                                      trail: outcome.trail, detailMilliseconds: outcome.detailMilliseconds))
                }
            }
            Task {
                try? await Task.sleep(for: limit)
                if await once.claim() {
                    finished.resume(returning: Result(index: index, site: site, verdict: .timedOut,
                                                      trail: "timed out after \(Int(limit.components.seconds)) s",
                                                      detailMilliseconds: 0))
                }
            }
        }
    }

    /// The text the share sheet carries: when, which configuration, the tally, then each group.
    public static func report(_ results: [Result], of total: Int, source: String, at date: Date) -> String {
        let time = date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
        let groups = Category.allCases.map { category in (category, results.filter { $0.category == category }) }
        var lines = [
            "WebHTV 來源檢查",
            "時間：\(time)",
            "設定：\(source)",
            "已檢查 \(results.count)／\(total) 站：" + groups.filter { !$0.1.isEmpty }
                .map { "\($0.0.label) \($0.1.count)" }.joined(separator: "、"),
            "結果取決於檢查當下的網路，換一個網路可能不同。",
        ]
        for (category, rows) in groups where !rows.isEmpty {
            lines.append("")
            lines.append("【\(category.label)】")
            lines += rows.sorted { $0.index < $1.index }.map { row in
                row.detail.map { "\(row.site.name)：\($0)" } ?? row.site.name
            }
        }
        return lines.joined(separator: "\n")
    }
}

public extension SiteHealthStore {
    /// IOS-POC-41C: a finished check, into the same records everyday use writes.
    func record(_ results: [SourceCheck.Result], source: String, now: Date = .now) {
        for result in results {
            for (event, succeeded) in result.healthEvents {
                record(event, succeeded: succeeded, siteID: result.site.id, source: source, now: now)
            }
        }
    }
}
