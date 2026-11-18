import Foundation
import os

/// W-313 — which sites are being called right now, and when the viewer last called each.
///
/// Every content call goes through `SourceClient`, which records itself here. A spider call cannot be
/// interrupted once it is made (it holds its site's serial queue for up to 65 s, `AggregateSearch`), so
/// following decides **before** calling whether a site is free; this is what it decides from.
public actor SiteActivity {
    public static let shared = SiteActivity()

    /// Set around following's own calls, so they never count as the viewer having used a site.
    @TaskLocal public static var background = false

    private var running = [Site.ID: Int]()
    private var touched = [Site.ID: Date]()

    public init() {}

    public func begin(_ site: Site.ID, now: Date = .now) {
        running[site, default: 0] += 1
        if !Self.background { touched[site] = now }
    }

    public func end(_ site: Site.ID) {
        guard let count = running[site] else { return }
        running[site] = count > 1 ? count - 1 : nil
    }

    public func isBusy(_ site: Site.ID) -> Bool { running[site] != nil }

    public func lastTouched(_ site: Site.ID) -> Date? { touched[site] }

    /// `work`, with the site counted as busy until it has really ended.
    public nonisolated func tracking<T: Sendable>(_ site: Site.ID, _ work: () async throws -> T) async rethrows -> T {
        await begin(site)
        do {
            let value = try await work()
            await end(site)
            return value
        } catch {
            await end(site)
            throw error
        }
    }
}

/// W-313 §4.3 — what may be checked, and when.
public enum FollowSchedule {
    /// A follow is looked at no more often than this, unless the viewer pulls to refresh.
    public static let interval: TimeInterval = 30 * 60
    /// A site the viewer called this recently is theirs: no spider check goes near it.
    public static let touchWindow: TimeInterval = 2 * 60
    /// A site whose last detail took longer than this is not checked in the background.
    public static let slowDetailMilliseconds = 5_000

    public struct Candidate: Sendable {
        public let follow: Follow
        public let site: Site
        public let isSpider: Bool
    }

    /// The follows of the configuration in use whose site is loaded and runnable and which are due.
    /// Busy and recently used sites are decided later, call by call (`mayStart`), because the viewer
    /// keeps moving while a round runs.
    public static func due(_ follows: [Follow], sourceID: String, sites: [Site], waiting: Set<Site.ID>,
                           spiders: Set<Site.ID>, health: [Site.ID: SiteHealth], forced: Bool,
                           now: Date = .now) -> [Candidate] {
        let byID = Dictionary(sites.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return follows.compactMap { follow in
            guard follow.identity.configSourceID == sourceID, !waiting.contains(follow.identity.siteID),
                  let site = byID[follow.identity.siteID] else { return nil }
            if !forced, let checked = follow.checkedAt, now.timeIntervalSince(checked) < interval { return nil }
            let isSpider = spiders.contains(site.id)
            // Only a round of its own leaves a slow spider out: a detail call is what rewrites the time it
            // is judged by, so a pull — the viewer asking — must still reach it, or one slow evening would
            // stop its follows for good.
            if isSpider, !forced, isSlow(health[site.id]) { return nil }
            return Candidate(follow: follow, site: site, isSpider: isSpider)
        }
    }

    static func isSlow(_ health: SiteHealth?) -> Bool {
        guard let health else { return false }
        return health.lastDetailMilliseconds > slowDetailMilliseconds || health.status == .bad
    }

    /// Whether a check may call `site` now. A CMS request can be cancelled, so only a busy site waits.
    /// A spider call cannot: it is not made while the player is open, while the viewer is on a screen
    /// that opens followed titles (記錄, a detail), on a site that is busy, or on one the viewer used in
    /// the last two minutes. A pull to refresh is the viewer asking, so only busy still applies.
    public static func mayStart(isSpider: Bool, busy: Bool, lastTouched: Date?, playerOpen: Bool,
                                onFollowScreen: Bool, forced: Bool, now: Date = .now) -> Bool {
        if busy || playerOpen { return false }
        guard isSpider, !forced else { return true }
        if onFollowScreen { return false }
        if let lastTouched, now.timeIntervalSince(lastTouched) < touchWindow { return false }
        return true
    }
}

/// W-313 — one round of checks: CMS sites two at a time, spider sites one at a time, each site's
/// follows one after another, within one budget.
public struct FollowChecker: Sendable {
    public enum Outcome: Equatable, Sendable {
        case listed(EpisodeListing, remarks: String)
        case missing
        case failed
    }

    public typealias Detail = @Sendable (Site, String) async throws -> Vod?
    /// 方案 C: one page of the site's search for a keyword.
    public typealias Search = @Sendable (Site, String) async throws -> [Vod]

    /// What a round found: each asked follow's listing, and the search results of those searched for a
    /// later season — empty when the search failed. A follow not asked is absent and stays as it was.
    public struct Report: Sendable {
        public var outcomes = [FavoriteIdentity: Outcome]()
        public var seasons = [FavoriteIdentity: [Vod]]()

        mutating func merge(_ other: Report) {
            outcomes.merge(other.outcomes) { _, new in new }
            seasons.merge(other.seasons) { _, new in new }
        }
    }
    /// What the app knows that Core does not: whether the player is open, whether a follow screen is up.
    public struct Conditions: Sendable {
        public var playerOpen: Bool
        public var onFollowScreen: Bool
        public init(playerOpen: Bool, onFollowScreen: Bool) {
            self.playerOpen = playerOpen
            self.onFollowScreen = onFollowScreen
        }
    }

    public var timeout: Duration = .seconds(10)
    public var budget: Duration = .seconds(60)
    public var cmsLimit = 2
    let detail: Detail
    let search: Search
    let activity: SiteActivity
    let conditions: @Sendable () async -> Conditions

    private static let log = Logger(subsystem: "com.webhtv.ios.poc", category: "follow")

    public init(activity: SiteActivity = .shared, conditions: @escaping @Sendable () async -> Conditions,
                search: @escaping Search = { _, _ in [] }, detail: @escaping Detail) {
        self.activity = activity
        self.conditions = conditions
        self.search = search
        self.detail = detail
    }

    /// Checks `candidates`: each one's detail and, once a day (`Follow.seasonDue`), the same site's search
    /// for a later season, under the same rules. A follow not asked (out of budget, its site busy or in
    /// use) is absent from the report and stays as it was.
    public func run(_ candidates: [FollowSchedule.Candidate], forced: Bool) async -> Report {
        let deadline = ContinuousClock.now + budget
        let bySite = Dictionary(grouping: candidates, by: \.site.id)
        let order = candidates.map(\.site.id).reduce(into: [Site.ID]()) { if !$0.contains($1) { $0.append($1) } }
        let cms = order.filter { bySite[$0]?.first?.isSpider == false }.compactMap { bySite[$0] }
        let spiders = order.filter { bySite[$0]?.first?.isSpider == true }.compactMap { bySite[$0] }
        return await SiteActivity.$background.withValue(true) {
            await withTaskGroup(of: Report.self) { group in
                let queue = SiteQueue(cms)
                for _ in 0..<max(1, cmsLimit) {
                    group.addTask { await lane(queue, spider: false, forced: forced, deadline: deadline) }
                }
                group.addTask { await lane(SiteQueue(spiders), spider: true, forced: forced, deadline: deadline) }
                var all = Report()
                for await part in group { all.merge(part) }
                return all
            }
        }
    }

    /// One worker: takes a site, checks its follows in turn, takes the next. A spider that runs past the
    /// timeout ends the spider lane for this round — its call is still running and cannot be stopped.
    private func lane(_ queue: SiteQueue, spider: Bool, forced: Bool,
                      deadline: ContinuousClock.Instant) async -> Report {
        var report = Report()
        while let site = await queue.next() {
            for candidate in site {
                guard ContinuousClock.now < deadline, !Task.isCancelled else { return report }
                guard await allowed(candidate, spider: spider, forced: forced) else {
                    Self.log.notice("[follow] skip \(candidate.site.name, privacy: .public): busy or in use")
                    break
                }
                let detail = self.detail, vodID = candidate.follow.identity.vodID, target = candidate.site
                let identity = candidate.follow.identity
                switch await Self.waiting(timeout, cancelling: !spider, { try await detail(target, vodID) }) {
                case .value(let vod?):
                    report.outcomes[identity] = .listed(EpisodeListing(flags: vod.flags), remarks: vod.remarks)
                case .value(nil):
                    report.outcomes[identity] = .missing
                case .failed:
                    report.outcomes[identity] = .failed
                case .timedOut:
                    report.outcomes[identity] = .failed
                    Self.log.notice("[follow] \(candidate.site.name, privacy: .public) past \(timeout) — no longer waited for")
                    if spider { return report }
                    continue
                }
                guard candidate.follow.seasonDue(), let keyword = candidate.follow.seasonKeyword,
                      ContinuousClock.now < deadline, await allowed(candidate, spider: spider, forced: forced)
                else { continue }
                let search = self.search
                switch await Self.waiting(timeout, cancelling: !spider, { try await search(target, keyword) }) {
                case .value(let results):
                    report.seasons[identity] = results
                case .failed:
                    // Counted as a look that found nothing, so a failing site is searched again tomorrow,
                    // not every round (review N-6). A hint already found stays (`Follow.searched`).
                    report.seasons[identity] = []
                case .timedOut:
                    report.seasons[identity] = []
                    Self.log.notice("[follow] \(candidate.site.name, privacy: .public) search past \(timeout) — no longer waited for")
                    if spider { return report }
                }
            }
        }
        return report
    }

    /// `FollowSchedule.mayStart`, asked right before each call.
    private func allowed(_ candidate: FollowSchedule.Candidate, spider: Bool, forced: Bool) async -> Bool {
        let now = await conditions()
        let id = candidate.site.id
        return FollowSchedule.mayStart(isSpider: spider, busy: await activity.isBusy(id),
                                       lastTouched: await activity.lastTouched(id), playerOpen: now.playerOpen,
                                       onFollowScreen: now.onFollowScreen, forced: forced)
    }

    enum Waited<T: Sendable>: Sendable {
        case value(T)
        case failed
        case timedOut
    }

    /// `work`, waited for at most `limit`. Past it, a CMS request is cancelled; a spider call cannot be,
    /// so it is only no longer waited for and finishes on its own (§4.3).
    static func waiting<T: Sendable>(_ limit: Duration, cancelling: Bool,
                                     _ work: @escaping @Sendable () async throws -> T) async -> Waited<T> {
        let first = FirstOf<T>()
        let task = Task {
            let result: Waited<T>
            do { result = .value(try await work()) } catch { result = .failed }
            first.settle(result)
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            first.settle(.timedOut)
        }
        let result = await first.value()
        timer.cancel()
        if case .timedOut = result, cancelling { task.cancel() }
        return result
    }

    /// The first of two answers; the later one is dropped.
    private final class FirstOf<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: Waited<T>?
        private var waiter: CheckedContinuation<Waited<T>, Never>?

        func settle(_ result: Waited<T>) {
            lock.lock()
            guard answer == nil else { lock.unlock(); return }
            answer = result
            let waiting = waiter
            waiter = nil
            lock.unlock()
            waiting?.resume(returning: result)
        }

        func value() async -> Waited<T> {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let answer {
                    lock.unlock()
                    continuation.resume(returning: answer)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }
    }

    private actor SiteQueue {
        private var sites: [[FollowSchedule.Candidate]]
        init(_ sites: [[FollowSchedule.Candidate]]) { self.sites = sites }
        func next() -> [FollowSchedule.Candidate]? { sites.isEmpty ? nil : sites.removeFirst() }
    }
}
