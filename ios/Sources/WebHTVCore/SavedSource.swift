import Foundation

/// A configuration source the viewer named and kept.
///
/// IOS-POC-10D. Before this the app remembered exactly one URL, so going back to a previous
/// configuration meant retyping it, and the settings page showed a long raw address where a name
/// would do.
///
/// **Identity is the URL, not a generated id.** Two entries pointing at the same address are the
/// same source however they are named, and a URL-derived identity also survives reinstalls and
/// gives each source a stable cache filename without a second lookup table.
public struct SavedSource: Codable, Identifiable, Equatable, Sendable {
    /// What the settings page shows. Free text; the viewer picks it.
    public var name: String
    public let url: URL
    /// W-311: the multi-depot address this source came from; nil for one the viewer added by itself. Optional, so a
    /// list saved before it decodes unchanged.
    public var depot: Depot?

    public var id: String { url.absoluteString }

    public init(name: String, url: URL, depot: Depot? = nil) {
        self.name = name
        self.url = url
        self.depot = depot
    }

    /// W-311: the depot a source belongs to. The depot's own address is not kept as a source (FongMi drops it too),
    /// so its name lives here, the same on every entry of the group.
    public struct Depot: Codable, Equatable, Sendable {
        /// The group key: the depot's address, or `DepotConfig.importedID` for one imported from a file.
        public var id: String
        /// Where to fetch the list again; nil for an imported file.
        public var url: URL?
        public var name: String

        public init(id: String, url: URL?, name: String) {
            self.id = id
            self.url = url
            self.name = name
        }
    }

    /// A display name that is never blank — falling back to the host rather than an empty row.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return url.host ?? url.absoluteString
    }

    /// The file this source's cached configuration lives in.
    ///
    /// **Each source caches separately, and that is a correctness requirement rather than a
    /// nicety.** With one shared cache, switching to B overwrites A's copy, and the next time A is
    /// unreachable the app would show B's sites under A's name — the last-known-good rule turning
    /// into a last-known-good-*of-something-else* rule.
    ///
    /// base64url of the address: Foundation only, collision-free because it is reversible, and
    /// filesystem-safe. A hash would be shorter but would also make a stray cache file impossible
    /// to trace back to its source by eye.
    public var cacheFileName: String {
        Data(url.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            + ".json"
    }
}

/// The saved list, as stored on disk.
///
/// A plain array in a wrapper so the file can gain fields later without breaking older readers —
/// the same reason `WatchHistory` is a struct rather than a bare dictionary.
public struct SavedSourceList: Codable, Sendable, Equatable {
    public var sources: [SavedSource]

    public init(sources: [SavedSource] = []) {
        self.sources = sources
    }

    /// Adds or updates by URL, so saving the same address twice renames it instead of duplicating.
    /// Returns the list unchanged when the URL is not http(s), because nothing else can be fetched.
    public mutating func upsert(_ source: SavedSource) {
        guard let scheme = source.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
    }

    public mutating func remove(id: SavedSource.ID) {
        sources.removeAll { $0.id == id }
    }

    public func source(id: SavedSource.ID?) -> SavedSource? {
        guard let id else { return nil }
        return sources.first { $0.id == id }
    }

    /// W-311: a depot's entries join the list under `depot`. An address already saved keeps the name the viewer gave it
    /// and moves to this depot — the last depot added owns it (user, 2026-11-17); one address is never listed twice.
    /// The depot's own address, saved when it was typed in, is dropped: it is a list, not a configuration.
    ///
    /// The group's name: a non-empty name just typed with the depot's address wins; otherwise a group this depot already
    /// has keeps its name (a refresh, or the same file imported again, never undoes a rename); otherwise `depot.name`,
    /// the caller's fallback (host or file name). Returns the depot as stored.
    @discardableResult
    public mutating func adopt(_ entries: [SavedSource], into depot: SavedSource.Depot, replacing depotURL: URL?) -> SavedSource.Depot {
        var depot = depot
        let typed = depotURL.flatMap { source(id: $0.absoluteString) }?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !typed.isEmpty {
            depot.name = typed
        } else if let existing = sources.first(where: { $0.depot?.id == depot.id })?.depot {
            depot.name = existing.name
        }
        if let depotURL { remove(id: depotURL.absoluteString) }
        // A new typed name renames the entries already in the group too, so one depot never shows two names.
        for index in sources.indices where sources[index].depot?.id == depot.id { sources[index].depot = depot }
        for entry in entries {
            var joined = entry
            joined.depot = depot
            if let index = sources.firstIndex(where: { $0.id == entry.id }) {
                if !sources[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { joined.name = sources[index].name }
                sources[index] = joined
            } else {
                sources.append(joined)
            }
        }
        return depot
    }

    /// W-311: renames a depot on every entry of its group.
    public mutating func renameDepot(id: String, to name: String) {
        for index in sources.indices where sources[index].depot?.id == id { sources[index].depot?.name = name }
    }

    /// W-311: the list as the settings page shows it — each depot's entries together, depots in the order they first
    /// appear, then the sources added one by one.
    public var groups: [Group] {
        var order = [String](), members = [String: [SavedSource]](), depots = [String: SavedSource.Depot]()
        for source in sources {
            let key = source.depot?.id ?? ""
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(source)
            if let depot = source.depot { depots[key] = depot }
        }
        return (order.filter { !$0.isEmpty } + order.filter(\.isEmpty))
            .map { Group(depot: depots[$0], sources: members[$0] ?? []) }
    }

    public struct Group: Identifiable, Equatable, Sendable {
        public var depot: SavedSource.Depot?
        public var sources: [SavedSource]
        public var id: String { depot?.id ?? "" }
    }
}
