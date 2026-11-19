import Foundation

/// W-317: the viewer's own site order (`docs/W-317-ios-site-order.md`). The sites the viewer dragged — the pinned
/// ones — come first, in the order they left them; the rest follow by health when 站點健康排序 is on, else in the
/// configuration's order.
public enum SiteOrder {
    /// `health` nil keeps the rest in the order given. A pinned site the configuration no longer has is skipped.
    public static func apply(_ sites: [Site], pinned: [Site.ID], health: [Site.ID: SiteHealth]?) -> [Site] {
        let byID = Dictionary(sites.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let head = pinned.compactMap { byID[$0] }
        let ids = Set(head.map(\.id))
        let rest = sites.filter { !ids.contains($0.id) }
        return head + (health.map { SiteHealth.ordered(rest, by: $0) } ?? rest)
    }

    /// The pinned list after the viewer drags `shown[from]` to `to`, SwiftUI's `onMove` destination (the index it
    /// lands before, counted in the list as it was). `shown` is what `apply` returned. The dragged site is pinned,
    /// at most just after the last pinned one, so dropping it among the rest pins no other site. Put back where it
    /// was, nothing changes (W-324).
    public static func moved(_ shown: [Site], from: Int, to: Int, pinned: [Site.ID]) -> [Site.ID] {
        guard to != from, to != from + 1 else { return pinned }
        let id = shown[from].id
        let present = Set(shown.map(\.id))
        var kept = pinned.filter { $0 != id && present.contains($0) }
        kept.insert(id, at: min(to > from ? to - 1 : to, kept.count))
        return kept
    }
}

/// W-317: the pinned sites per configuration (`ConfigSource.identity`), by `Site.id`. JSON, as `SearchExclusions`,
/// because a `Site.id` carries a NUL.
public struct SiteOrderStore {
    public static let key = "webhtv.siteOrder"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func pinned(in source: String) -> [Site.ID] { all()[source] ?? [] }

    /// Drops the sites `sites` no longer has; an empty list removes the configuration's entry.
    public func set(_ pinned: [Site.ID], in source: String, keeping sites: [Site]) {
        let present = Set(sites.map(\.id))
        var all = all()
        let kept = pinned.filter(present.contains)
        all[source] = kept.isEmpty ? nil : kept
        defaults.set(try? JSONEncoder().encode(all), forKey: Self.key)
    }

    private func all() -> [String: [Site.ID]] {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: [Site.ID]].self, from: $0) } ?? [:]
    }
}
