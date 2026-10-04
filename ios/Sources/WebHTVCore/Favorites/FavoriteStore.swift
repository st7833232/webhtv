import Foundation

/// IOS-POC-48 — the favourites on disk: one JSON file, rewritten whole, newest favourite first.
///
/// The same shape as `WatchHistoryStore` (an actor over one small file, `Data.write(.atomic)`), with
/// the difference that favourites are something the viewer chose and cannot regenerate by watching
/// again, so nothing here ever answers a problem by writing an empty list over the file:
///
/// - **One record that will not decode costs nothing else.** It is kept exactly as it was and
///   written back with every save, so a later build that understands it still finds it.
/// - **A file that is not this format at all** is moved aside (`favorites.corrupt-….json`) before a
///   new one is started; if it cannot be moved, nothing is written.
/// - **A file that exists but cannot be read now** — data protection before the first unlock, a
///   permission, an I/O error — loads nothing and writes nothing; the next call tries again.
/// - **A file from a newer schema** is copied aside once (`favorites.schema<N>.backup.json`) before
///   this build first rewrites it, since this build drops the fields it does not know.
///
/// It owns favourites and nothing else: no call here reads or writes the watch history or the
/// offline downloads, and theirs never touch this file (A11).
public actor FavoriteStore {
    public static let shared = FavoriteStore()
    public static let currentSchemaVersion = 1
    static let fileName = "favorites.json"

    /// What the last load found.
    public struct LoadReport: Equatable, Sendable {
        public var loaded = 0
        public var unreadable = 0
        public var duplicates = 0
        /// The name the corrupt file was moved to.
        public var setAside: String?
        /// The copy kept of a newer schema's file.
        public var backedUp: String?
        /// The file was there and could not be read: nothing loaded, nothing will be written.
        public var failed = false
    }

    private let directory: URL
    private var file: URL { directory.appendingPathComponent(Self.fileName) }
    /// Nil until a load succeeds.
    private var favorites: [Favorite]?
    private var unreadable = [FavoriteFile.Entry.Raw]()
    public private(set) var lastLoad = LoadReport()

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Favorites", isDirectory: true)
    }

    // MARK: Reading

    /// Every favourite, the most recently favourited first.
    public func all() -> [Favorite] { loaded() ?? [] }

    public func favorite(_ identity: FavoriteIdentity) -> Favorite? {
        loaded()?.first { $0.identity == identity }
    }

    public func contains(_ identity: FavoriteIdentity) -> Bool { favorite(identity) != nil }

    // MARK: Writing

    /// Favourites a title. Favourited already, it stays one favourite — the snapshot is merged in
    /// as `refresh` would and its `createdAt` is kept. Nil when nothing could be saved.
    @discardableResult
    public func add(_ identity: FavoriteIdentity, snapshot: FavoriteSnapshot, now: Date = .now) -> Favorite? {
        guard identity.isComplete, var list = loaded() else { return nil }
        if let index = list.firstIndex(where: { $0.identity == identity }) {
            let merged = list[index].merging(snapshot, at: now)
            guard merged != list[index] else { return merged }
            list[index] = merged
            return store(list) ? merged : nil
        }
        let favorite = Favorite(identity: identity, snapshot: snapshot, createdAt: now)
        list.append(favorite)
        return store(list) ? favorite : nil
    }

    /// The detail screen's heart: favourites the title, or unfavourites it when it already is one, in
    /// one call — two quick taps are two toggles, never two adds racing each other. Answers whether
    /// the title is a favourite afterwards.
    @discardableResult
    public func toggle(_ identity: FavoriteIdentity, snapshot: FavoriteSnapshot, now: Date = .now) -> Bool {
        if favorite(identity) != nil { return remove(identity) == nil }
        return add(identity, snapshot: snapshot, now: now) != nil
    }

    /// Unfavourites a title, and answers the record that went, so an undo can put back exactly it.
    @discardableResult
    public func remove(_ identity: FavoriteIdentity) -> Favorite? {
        guard var list = loaded(), let index = list.firstIndex(where: { $0.identity == identity }) else { return nil }
        let removed = list.remove(at: index)
        return store(list) ? removed : nil
    }

    /// A freshly loaded detail over a favourite's snapshot (`Favorite.merging`). Nothing happens to a
    /// title that is not a favourite: loading a detail never favourites anything.
    @discardableResult
    public func refresh(_ identity: FavoriteIdentity, with snapshot: FavoriteSnapshot, now: Date = .now) -> Favorite? {
        guard var list = loaded(), let index = list.firstIndex(where: { $0.identity == identity }) else { return nil }
        let merged = list[index].merging(snapshot, at: now)
        guard merged != list[index] else { return merged }
        list[index] = merged
        return store(list) ? merged : nil
    }

    /// The undo of a removal: exactly the record that was removed, its `createdAt` included. A title
    /// favourited again in the meantime keeps that newer favourite.
    @discardableResult
    public func restore(_ favorite: Favorite) -> Bool {
        guard var list = loaded(), !list.contains(where: { $0.identity == favorite.identity }) else { return false }
        list.append(favorite)
        return store(list)
    }

    /// A7: re-points favourites of one configuration at a site whose identity changed in a way that
    /// provably keeps it the same site — `SiteSelection.resolveIdentity`: the identical id, or a
    /// structured `ext` that differs only in key order. A site whose `ext` really changed, or that is
    /// gone, is left as it was: the favourite stays and shows as unavailable. The key-only fallback
    /// the site picker uses is deliberately not applied — for a favourite that would be a guess.
    @discardableResult
    public func migrateSiteIdentities(in sites: [Site], configSourceID: String) -> Int {
        guard var list = loaded() else { return 0 }
        var changed = 0
        for index in list.indices where list[index].identity.configSourceID == configSourceID {
            let old = list[index].identity
            guard let siteID = SiteSelection.resolveIdentity(old.siteID, in: sites), siteID != old.siteID else { continue }
            list[index].identity = FavoriteIdentity(configSourceID: old.configSourceID, siteID: siteID, vodID: old.vodID)
            changed += 1
        }
        guard changed > 0 else { return 0 }
        return store(Self.deduplicated(list)) ? changed : 0
    }

    // MARK: The file

    private func loaded() -> [Favorite]? {
        if let favorites { return favorites }
        var report = LoadReport()
        defer { lastLoad = report }
        guard FileManager.default.fileExists(atPath: file.path) else {
            favorites = []
            unreadable = []
            return []
        }
        guard let data = try? Data(contentsOf: file) else {
            report.failed = true
            return nil
        }
        guard let stored = try? JSONDecoder().decode(FavoriteFile.self, from: data) else {
            guard let name = setAside() else {
                report.failed = true
                return nil
            }
            report.setAside = name
            favorites = []
            unreadable = []
            return []
        }
        if stored.schemaVersion > Self.currentSchemaVersion {
            guard let name = backUp(schemaVersion: stored.schemaVersion) else {
                report.failed = true
                return nil
            }
            report.backedUp = name
        }
        var list = [Favorite]()
        var raw = [FavoriteFile.Entry.Raw]()
        for entry in stored.favorites {
            switch entry {
            case .favorite(let favorite): list.append(favorite)
            case .unreadable(let value): raw.append(value)
            }
        }
        let unique = Self.deduplicated(list)
        report.loaded = unique.count
        report.unreadable = raw.count
        report.duplicates = list.count - unique.count
        let sorted = Self.sorted(unique)
        favorites = sorted
        unreadable = raw
        return sorted
    }

    /// Writes the list and only then adopts it, so memory never runs ahead of the disk.
    private func store(_ list: [Favorite]) -> Bool {
        let sorted = Self.sorted(list)
        let contents = FavoriteFile(schemaVersion: Self.currentSchemaVersion,
                                    favorites: sorted.map { .favorite($0) } + unreadable.map { .unreadable($0) })
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(contents).write(to: file, options: .atomic)
        } catch {
            return false
        }
        favorites = sorted
        return true
    }

    private func setAside() -> String? {
        let name = "favorites.corrupt-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json"
        return (try? FileManager.default.moveItem(at: file, to: directory.appendingPathComponent(name))) == nil ? nil : name
    }

    private func backUp(schemaVersion: Int) -> String? {
        let name = "favorites.schema\(schemaVersion).backup.json"
        let target = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) { return name }
        return (try? FileManager.default.copyItem(at: file, to: target)) == nil ? nil : name
    }

    /// The most recently favourited first; the identity breaks ties, so the order never wobbles.
    static func sorted(_ list: [Favorite]) -> [Favorite] {
        list.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return ($0.identity.configSourceID, $0.identity.siteID, $0.identity.vodID)
                < ($1.identity.configSourceID, $1.identity.siteID, $1.identity.vodID)
        }
    }

    /// One favourite per identity: the first one favourited.
    static func deduplicated(_ list: [Favorite]) -> [Favorite] {
        var kept = [FavoriteIdentity: Favorite]()
        for favorite in list {
            if let existing = kept[favorite.identity], existing.createdAt <= favorite.createdAt { continue }
            kept[favorite.identity] = favorite
        }
        return Array(kept.values)
    }
}

/// The file's shape: `{"favorites":[…],"schemaVersion":1}`.
struct FavoriteFile: Codable {
    var schemaVersion: Int
    var favorites: [Entry]

    init(schemaVersion: Int, favorites: [Entry]) {
        self.schemaVersion = schemaVersion
        self.favorites = favorites
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, favorites }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Every file this build writes has a version; one without is read as this version.
        schemaVersion = (try? values.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? FavoriteStore.currentSchemaVersion
        favorites = try values.decode([Entry].self, forKey: .favorites)
    }

    /// One element of `favorites`: a favourite, or whatever was there that is not one, kept verbatim.
    enum Entry: Codable {
        case favorite(Favorite)
        case unreadable(Raw)

        init(from decoder: Decoder) throws {
            if let favorite = try? Favorite(from: decoder) {
                self = .favorite(favorite)
            } else {
                self = .unreadable(try Raw(from: decoder))
            }
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .favorite(let favorite): try favorite.encode(to: encoder)
            case .unreadable(let raw): try raw.encode(to: encoder)
            }
        }

        /// Any JSON value, carried through unchanged.
        indirect enum Raw: Codable, Equatable, Sendable {
            case string(String)
            case number(Double)
            case bool(Bool)
            case object([String: Raw])
            case array([Raw])
            case null

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if container.decodeNil() { self = .null }
                else if let value = try? container.decode(Bool.self) { self = .bool(value) }
                else if let value = try? container.decode(Double.self) { self = .number(value) }
                else if let value = try? container.decode(String.self) { self = .string(value) }
                else if let value = try? container.decode([String: Raw].self) { self = .object(value) }
                else { self = .array(try container.decode([Raw].self)) }
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .string(let value): try container.encode(value)
                case .number(let value): try container.encode(value)
                case .bool(let value): try container.encode(value)
                case .object(let value): try container.encode(value)
                case .array(let value): try container.encode(value)
                case .null: try container.encodeNil()
                }
            }
        }
    }
}
