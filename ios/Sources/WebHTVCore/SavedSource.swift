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

    public var id: String { url.absoluteString }

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
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
}
