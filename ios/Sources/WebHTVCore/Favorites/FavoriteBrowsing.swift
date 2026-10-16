import Foundation

/// IOS-POC-48 — the two pages of the 片庫 tab. Favourites and the watch history stay two separate
/// stores; only their screens share the tab.
public enum LibrarySection: String, CaseIterable, Identifiable, Sendable {
    case favorites
    case history

    /// The page the tab opens on.
    public static let initial = LibrarySection.favorites

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .favorites: "收藏"
        case .history: "記錄"
        }
    }
}

/// A14 — whether a favourite can be opened with the configuration loaded now.
public enum FavoriteAvailability: Equatable, Sendable {
    /// The site is in the loaded configuration, under this identity.
    case available(siteID: Site.ID)
    case unavailable(Reason)

    public enum Reason: Equatable, Sendable {
        /// Favourited under a configuration that is not the one loaded.
        case otherConfiguration
        /// The loaded configuration is the favourite's own, but has no such site any more.
        case siteMissing
        /// W-143 (IOS-POC-61 plan §2.5): the site is in the configuration, waiting for the 爬蟲工具 to drive it.
        case needsSpiderTool

        /// The badge on a favourite, and the heading of the sheet a favourite or a history row opens.
        public var title: String { self == .needsSpiderTool ? "需要爬蟲工具" : "來源不可用" }
        public var message: String {
            self == .needsSpiderTool ? "這個來源要先下載爬蟲工具才能打開，記錄與收藏都會保留。"
                : "目前設定中找不到原始來源，此收藏仍會保留。"
        }
    }

    /// The same rule the site migration uses (`SiteSelection.resolveIdentity`), so a favourite never
    /// opens on a site the store would refuse to migrate it to. Never a same-named title, never
    /// another site that shares the key.
    /// `waiting` is the configuration's sites only the 爬蟲工具 would bring (`sitesNeedingSpiderTool`).
    public init(_ identity: FavoriteIdentity, configSourceID: String, sites: [Site], waiting: [Site] = []) {
        guard identity.configSourceID == configSourceID else {
            self = .unavailable(.otherConfiguration)
            return
        }
        if let siteID = SiteSelection.resolveIdentity(identity.siteID, in: sites) {
            self = .available(siteID: siteID)
        } else {
            self = .unavailable(SiteSelection.resolveIdentity(identity.siteID, in: waiting) == nil ? .siteMissing : .needsSpiderTool)
        }
    }

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// Why it cannot open; `nil` when it can.
    public var reason: Reason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// A10 — the favourites page's own search: the snapshots on this device, never a source.
public enum FavoriteSearch {
    /// The favourites whose name, cast, director, genre or year contain `query`, in the order given.
    /// Both sides are compared in Simplified form (`TraditionalSimplified`, the table searches already
    /// use), ignoring case and width, so a title stored as the source wrote it is found whichever
    /// script the viewer types. An empty query is every favourite.
    public static func filter(_ favorites: [Favorite], query: String) -> [Favorite] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return favorites }
        return favorites.filter { favorite in
            [favorite.name, favorite.actor, favorite.director, favorite.typeName, favorite.year]
                .contains { normalized($0).contains(needle) }
        }
    }

    static func normalized(_ text: String) -> String {
        TraditionalSimplified.toSimplified(text.trimmingCharacters(in: .whitespacesAndNewlines))
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }
}
