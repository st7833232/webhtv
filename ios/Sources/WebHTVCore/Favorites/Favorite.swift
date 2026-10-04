import Foundation

// IOS-POC-48 — favourites: the records, and nothing that touches the disk or the screen.
//
// **A favourite is a title, not a playback.** It names a work on one site of one configuration and
// keeps enough of what the source said about it to recognise it offline. Where the viewer got to,
// which line and quality they chose, what is downloaded and how the site is doing all belong to the
// watch history, the offline downloads and the site health — read beside a favourite, never stored
// in it. `FavoriteTests.aFavoriteHoldsOnlyTitleMetadata` pins the field list.

/// What makes two favourites the same: the configuration (`ConfigSource.identity`), the site
/// (`Site.id` — the key **and** its `ext`, because this configuration repeats keys) and the source's
/// own vod id. Never an episode, line, quality, subtitle or resolved address: those change from one
/// fetch to the next, and the title does not.
public struct FavoriteIdentity: Codable, Hashable, Sendable {
    public let configSourceID: String
    public let siteID: String
    public let vodID: String

    public init(configSourceID: String, siteID: String, vodID: String) {
        self.configSourceID = configSourceID
        self.siteID = siteID
        self.vodID = vodID
    }

    /// The title as the detail screen opens it: the configuration loaded, the site, the list item.
    public init(source: ConfigSource, site: Site, vodID: String) {
        self.init(configSourceID: source.identity, siteID: site.id, vodID: vodID)
    }

    /// The watch-history and download key of the same title (`WatchHistory.key`), for showing
    /// progress and downloads beside a favourite. Read-only: nothing is written through it.
    public var historyKey: String { WatchHistory.key(siteID: siteID, vodId: vodID) }

    /// Whether this names something a detail screen can open: an empty part names nothing.
    public var isComplete: Bool { !configSourceID.isEmpty && !siteID.isEmpty && !vodID.isEmpty }
}

/// What the source says about a title right now, as the detail screen shows it.
public struct FavoriteSnapshot: Equatable, Sendable {
    public var name: String
    public var picture: String
    public var remarks: String
    public var year: String
    public var area: String
    public var typeName: String
    public var director: String
    public var actor: String
    public var content: String
    public var siteName: String
    public var configSourceName: String

    public init(name: String = "", picture: String = "", remarks: String = "", year: String = "",
                area: String = "", typeName: String = "", director: String = "", actor: String = "",
                content: String = "", siteName: String = "", configSourceName: String = "") {
        self.name = name
        self.picture = picture
        self.remarks = remarks
        self.year = year
        self.area = area
        self.typeName = typeName
        self.director = director
        self.actor = actor
        self.content = content
        self.siteName = siteName
        self.configSourceName = configSourceName
    }

    /// The detail when there is one, the list item for whatever it left out. Text goes through
    /// `VodText.plain` (markup a source wraps names in is not part of them) and the year through
    /// `VodText.year`; both stay in the source's own script — the screen converts, as it does for
    /// every other source string.
    public init(summary: Vod, detail: Vod?, siteName: String, configSourceName: String) {
        func text(_ field: KeyPath<Vod, String>) -> String {
            let fresh = VodText.plain(detail?[keyPath: field] ?? "")
            return fresh.isEmpty ? VodText.plain(summary[keyPath: field]) : fresh
        }
        let name = text(\.name)
        let picture = (detail?.picture ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            // A name made of markup alone cleans to nothing; the raw text is better than no name.
            name: name.isEmpty ? (summary.name.isEmpty ? detail?.name ?? "" : summary.name) : name,
            picture: picture.isEmpty ? summary.picture.trimmingCharacters(in: .whitespacesAndNewlines) : picture,
            remarks: text(\.remarks),
            year: VodText.year(detail?.year ?? "") ?? VodText.year(summary.year) ?? "",
            area: text(\.area), typeName: text(\.typeName), director: text(\.director),
            actor: text(\.actor), content: text(\.content),
            siteName: siteName, configSourceName: configSourceName)
    }
}

/// One favourite: the identity, the title's snapshot, and when it was favourited.
public struct Favorite: Codable, Equatable, Sendable, Identifiable {
    /// Settable only for a site migration (`FavoriteStore.migrateSiteIdentities`).
    public internal(set) var identity: FavoriteIdentity
    public internal(set) var name: String
    public internal(set) var picture: String
    public internal(set) var remarks: String
    public internal(set) var year: String
    public internal(set) var area: String
    public internal(set) var typeName: String
    public internal(set) var director: String
    public internal(set) var actor: String
    public internal(set) var content: String
    public internal(set) var siteName: String
    public internal(set) var configSourceName: String
    /// When the viewer favourited it. Never changed by a refresh — it is what the list sorts by.
    public let createdAt: Date
    /// When the snapshot last changed.
    public internal(set) var snapshotUpdatedAt: Date

    public var id: FavoriteIdentity { identity }

    public init(identity: FavoriteIdentity, snapshot: FavoriteSnapshot, createdAt: Date) {
        self.identity = identity
        name = snapshot.name
        picture = snapshot.picture
        remarks = snapshot.remarks
        year = snapshot.year
        area = snapshot.area
        typeName = snapshot.typeName
        director = snapshot.director
        actor = snapshot.actor
        content = snapshot.content
        siteName = snapshot.siteName
        configSourceName = snapshot.configSourceName
        self.createdAt = createdAt
        snapshotUpdatedAt = createdAt
    }

    /// The stored snapshot with what a fresh one fills in. A field the source sent replaces the old
    /// value; a field it left empty keeps it — a source that sometimes drops the cast, the year or the
    /// poster must not empty a favourite. `snapshotUpdatedAt` moves only when something changed, and
    /// `createdAt` never does.
    public func merging(_ snapshot: FavoriteSnapshot, at now: Date) -> Favorite {
        var merged = self
        func take(_ field: WritableKeyPath<Favorite, String>, _ value: String) {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            merged[keyPath: field] = value
        }
        take(\.name, snapshot.name)
        take(\.picture, snapshot.picture)
        take(\.remarks, snapshot.remarks)
        take(\.year, snapshot.year)
        take(\.area, snapshot.area)
        take(\.typeName, snapshot.typeName)
        take(\.director, snapshot.director)
        take(\.actor, snapshot.actor)
        take(\.content, snapshot.content)
        take(\.siteName, snapshot.siteName)
        take(\.configSourceName, snapshot.configSourceName)
        if merged != self { merged.snapshotUpdatedAt = now }
        return merged
    }

    /// The snapshot again, for building a summary to open the detail screen with.
    public var snapshot: FavoriteSnapshot {
        FavoriteSnapshot(name: name, picture: picture, remarks: remarks, year: year, area: area,
                         typeName: typeName, director: director, actor: actor, content: content,
                         siteName: siteName, configSourceName: configSourceName)
    }

    enum CodingKeys: String, CodingKey {
        case identity, name, picture, remarks, year, area, typeName, director, actor, content
        case siteName, configSourceName, createdAt, snapshotUpdatedAt
    }

    /// Forgiving about everything but what a favourite cannot exist without: a field a later build
    /// adds, or an older one left out, decodes to empty. A record without a whole identity or a
    /// favourited time throws, and `FavoriteStore` keeps it as it is instead of guessing.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        identity = try values.decode(FavoriteIdentity.self, forKey: .identity)
        guard identity.isComplete else {
            throw DecodingError.dataCorruptedError(forKey: .identity, in: values,
                                                   debugDescription: "an empty part names no title")
        }
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        func text(_ key: CodingKeys) -> String { (try? values.decodeIfPresent(String.self, forKey: key)) ?? "" }
        name = text(.name)
        picture = text(.picture)
        remarks = text(.remarks)
        year = text(.year)
        area = text(.area)
        typeName = text(.typeName)
        director = text(.director)
        actor = text(.actor)
        content = text(.content)
        siteName = text(.siteName)
        configSourceName = text(.configSourceName)
        snapshotUpdatedAt = (try? values.decodeIfPresent(Date.self, forKey: .snapshotUpdatedAt)) ?? createdAt
    }
}
