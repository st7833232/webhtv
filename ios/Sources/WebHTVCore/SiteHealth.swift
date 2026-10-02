import Foundation

/// IOS-POC-41B: one site's record of how its calls went, ported from Android's `SiteHealthStore`
/// (`app/src/main/java/com/fongmi/android/tv/setting/SiteHealthStore.java`, commit `474cc04f`).
///
/// Only what the score and the colour read is kept. Two deliberate differences from Android
/// (`docs/IOS-POC-41-source-health-diagnostics.md`): a home or category listing is recorded too,
/// weighted like a detail — Android never records one, so a site that fails at its first page only
/// shows up through search — and the key is `Site.id`, because a configuration repeats site keys.
public struct SiteHealth: Codable, Equatable, Sendable {
    public enum Event: Sendable {
        case search(count: Int, milliseconds: Int)
        case browse
        case detail(milliseconds: Int)
        case play
    }

    public enum Status: Sendable { case good, warn, bad, unknown }

    var searchSuccess = 0, searchFail = 0
    var browseSuccess = 0, browseFail = 0
    var detailSuccess = 0, detailFail = 0
    var playSuccess = 0, playFail = 0
    var lastSearchCount = 0
    var lastSearchMilliseconds = 0
    var lastDetailMilliseconds = 0
    var lastPlaySuccessAt: Double = 0
    var lastPlayFailAt: Double = 0
    var updatedAt: Double = 0

    mutating func record(_ event: Event, succeeded: Bool, at now: Double) {
        updatedAt = now
        switch event {
        case .search(let count, let milliseconds):
            lastSearchMilliseconds = max(0, milliseconds)
            lastSearchCount = max(0, count)
            if succeeded { searchSuccess += 1 } else { searchFail += 1 }
        case .browse:
            if succeeded { browseSuccess += 1 } else { browseFail += 1 }
        case .detail(let milliseconds):
            lastDetailMilliseconds = max(0, milliseconds)
            if succeeded { detailSuccess += 1 } else { detailFail += 1 }
        case .play:
            if succeeded { playSuccess += 1; lastPlaySuccessAt = now } else { playFail += 1; lastPlayFailAt = now }
        }
    }

    private var total: Int {
        searchSuccess + searchFail + browseSuccess + browseFail + detailSuccess + detailFail + playSuccess + playFail
    }

    /// `Health.score()`, plus the listing at the detail's weight.
    public var score: Double {
        let success = Double(searchSuccess + browseSuccess * 2 + detailSuccess * 2 + playSuccess * 5)
        let fail = Double(searchFail + browseFail * 2 + detailFail * 2 + playFail * 5)
        guard success + fail > 0 else { return 0 }
        var score = 60 * (success - fail) / (success + fail + 4)
        score += Double(min(lastSearchCount, 20)) * 1.2
        score -= Double(min(lastSearchMilliseconds, 8000)) / 1000
        score -= Double(min(lastDetailMilliseconds, 8000)) / 1500
        if lastPlaySuccessAt > lastPlayFailAt { score += 18 }
        if lastPlayFailAt > lastPlaySuccessAt { score -= 18 }
        return score
    }

    /// `getStatus`, thresholds unchanged.
    public var status: Status {
        guard total > 0 else { return .unknown }
        let score = score
        if lastPlayFailAt > lastPlaySuccessAt, playFail >= 3, score < 0 { return .bad }
        if score >= 20 || (lastPlaySuccessAt >= lastPlayFailAt && playSuccess > 0) { return .good }
        if score <= -20 { return .bad }
        return .warn
    }

    /// `sortSites`: healthiest first, an unrecorded site scoring 0. Stable, as Android's `List.sort`
    /// is, so with nothing recorded the configuration's own order stands.
    public static func ordered(_ sites: [Site], by health: [Site.ID: SiteHealth]) -> [Site] {
        sites.enumerated().sorted { a, b in
            let left = health[a.element.id]?.score ?? 0, right = health[b.element.id]?.score ?? 0
            return left != right ? left > right : a.offset < b.offset
        }.map(\.element)
    }
}

/// Android keeps these in `Prefers` under `site_health`; here a file next to the watch history.
/// Kept 90 days after a site's last record, saved two seconds after the last change as Android does,
/// so a search that records every site at once writes once.
public actor SiteHealthStore {
    public static let shared = SiteHealthStore()

    private static let retention: Double = 90 * 24 * 3600
    private let file: URL
    private var items: [String: SiteHealth]?
    private var pendingSave: Task<Void, Never>?

    public init(directory: URL? = nil) {
        let base = directory ?? (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        file = base.appendingPathComponent("site-health.json")
    }

    /// `source` is `ConfigSource.identity`, Android's `VodConfig.getCid()`.
    public func record(_ event: SiteHealth.Event, succeeded: Bool, siteID: Site.ID, source: String,
                       now: Date = .now) {
        var all = loaded()
        all[Self.key(source, siteID), default: SiteHealth()].record(event, succeeded: succeeded,
                                                                     at: now.timeIntervalSince1970)
        items = all
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    /// The configuration's sites that have a record, by `Site.id`.
    public func health(in source: String) -> [Site.ID: SiteHealth] {
        let prefix = source + Self.separator
        return Dictionary(uniqueKeysWithValues: loaded().compactMap { key, health in
            key.hasPrefix(prefix) ? (String(key.dropFirst(prefix.count)), health) : nil
        })
    }

    public func clear() {
        pendingSave?.cancel()
        items = [:]
        try? FileManager.default.removeItem(at: file)
    }

    /// Writes now rather than after the delay; for tests, and a caller that is about to go away.
    public func save(now: Date = .now) {
        pendingSave?.cancel()
        let cutoff = now.timeIntervalSince1970 - Self.retention
        let kept = loaded().filter { $0.value.updatedAt >= cutoff }
        items = kept
        guard let data = try? JSONEncoder().encode(kept) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private func loaded() -> [String: SiteHealth] {
        if let items { return items }
        let stored = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: SiteHealth].self, from: $0) }
        items = stored ?? [:]
        return items ?? [:]
    }

    /// `Site.id` already holds a NUL between key and `ext`, so the separator is a control character
    /// neither a URL nor an `ext` carries.
    private static let separator = "\u{1}"
    private static func key(_ source: String, _ siteID: Site.ID) -> String { source + separator + siteID }
}
