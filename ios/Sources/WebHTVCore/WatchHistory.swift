import Foundation

/// One watched title: where the viewer got to, which episode, and through which line and quality.
///
/// The field names follow `app/src/main/java/com/fongmi/android/tv/bean/History.java`, because
/// `app.history` hands this straight to a WebHome page and a page written against Android must be
/// able to read it. Two fields deliberately do not match, both documented below: `key` and
/// `quality`.
public struct WatchHistory: Codable, Sendable, Equatable, Identifiable {
    /// The separator inside Android's `History.key` — `AppDatabase.SYMBOL`.
    public static let separator = "@@@"

    /// The primary key, built from **`Site.id`** rather than the site's key.
    ///
    /// This is the one place iOS must not copy Android: `wang-movie.json` carries four duplicate
    /// site keys (IOS-POC-5L), so keying on `siteKey` alone would merge two different providers'
    /// records into one. `Site.id` is `key + ext`, which is what actually identifies a source — the
    /// same reason `SpiderSessionStore` caches on it. `androidKey` below is what leaves the app.
    public let key: String
    /// Which configuration this was watched on — `ConfigSource.identity` (IOS-POC-10E).
    ///
    /// **Optional because this file already exists on people's phones.** `WatchHistory` uses the
    /// synthesized `Codable`, which does not fall back to a property's default value: a
    /// non-optional field would throw `keyNotFound` on every record written before this change,
    /// and `WatchHistoryStore` treats an unreadable file as no history at all. One `?` is the
    /// difference between adding a field and deleting somebody's viewing history.
    ///
    /// `nil` therefore means "written before sources were separable", and such a record is shown
    /// whatever source is active rather than hidden behind a field it never had. It stops being
    /// ambiguous the moment it is watched again, which rewrites it with the current source.
    ///
    /// Deliberately *not* part of the primary key: `Site.id` already identifies the provider, and
    /// folding the configuration into the key would split one title's progress in two if the same
    /// source were reached through two configurations.
    public var sourceID: String?
    public let siteKey: String
    /// Shown in the history list; `History.getSiteName()` looks it up from the config instead.
    public var siteName: String
    public let vodId: String
    public var vodName: String
    public var vodPic: String
    /// The flag — the *line* — the episode was played from. `History.vodFlag`.
    public var vodFlag: String
    /// The episode's own name. Android stores it here too: `History.getEpisode()` builds an
    /// `Episode` from `vodRemarks` and `episodeUrl`, so this field is the episode label, not the
    /// title's remarks.
    public var vodRemarks: String
    public var episodeUrl: String
    /// The quality label last played. **An iOS field with no Android counterpart** — Android
    /// expresses every quality as a line, so `vodFlag` was enough there. Since IOS-POC-5Q a single
    /// line may carry several qualities, and D3 says remember both. It is kept out of the
    /// `app.history` payload so that payload stays exactly Android's shape.
    public var quality: String
    /// Milliseconds, as Media3 and the playback bridge report them.
    public var position: Double
    public var duration: Double
    /// Milliseconds since 1970, rewritten on every save — this is what the 60-day prune and the
    /// list's ordering both read. Android's `createTime` behaves the same way.
    public var createTime: Double

    public var id: String { key }

    public init(key: String, siteKey: String, siteName: String = "", sourceID: String? = nil, vodId: String,
                vodName: String = "", vodPic: String = "", vodFlag: String = "",
                vodRemarks: String = "", episodeUrl: String = "", quality: String = "",
                position: Double = 0, duration: Double = 0, createTime: Double = 0) {
        self.key = key
        self.sourceID = sourceID
        self.siteKey = siteKey
        self.siteName = siteName
        self.vodId = vodId
        self.vodName = vodName
        self.vodPic = vodPic
        self.vodFlag = vodFlag
        self.vodRemarks = vodRemarks
        self.episodeUrl = episodeUrl
        self.quality = quality
        self.position = position
        self.duration = duration
        self.createTime = createTime
    }

    /// The internal primary key. Never split it: `Site.id` embeds the site's whole `ext`, which may
    /// contain anything at all — `siteKey` and `vodId` are stored as their own fields for that
    /// reason.
    public static func key(siteID: String, vodId: String) -> String {
        siteID + separator + vodId
    }

    /// The key Android puts in `History.key`, and the only form that leaves the app. A page calls
    /// `getSiteKey()` / `getVodId()` on it, so it has to be `siteKey@@@vodId` even though two
    /// duplicate-key sites collapse into one string here.
    public var androidKey: String { siteKey + Self.separator + vodId }

    /// `History.canSave()`: a title with no measured position is not yet worth a record.
    public var canSave: Bool { position > 0 }

    /// `History.isNearEnding()`, formula for formula: the threshold is one percent of the runtime,
    /// clamped to between 5 and 30 seconds.
    public var isNearEnding: Bool {
        guard position > 0, duration > 0 else { return false }
        let threshold = min(30_000, max(5_000, duration / 100))
        let remaining = duration - position
        return remaining >= 0 && remaining <= threshold
    }

    /// Where playback should start, or nil to start from the beginning (D4).
    ///
    /// Under ten seconds is not a place anyone wants resumed to, and a title that was watched to the
    /// end should replay rather than open on its own closing seconds.
    public var resumePosition: Double? {
        guard position > 10_000, !isNearEnding else { return nil }
        return position
    }
}

/// The watch history on disk: one JSON file, rewritten whole.
///
/// **Why a file and not a database.** A few hundred records do not pay for SwiftData or a schema to
/// migrate, and the configuration and the compatibility pack already establish the pattern — an
/// atomic write into Application Support, and a corrupt file costing the history rather than the
/// launch. `Data.write(options: .atomic)` is the whole atomicity story: it writes a temporary file
/// and renames it, so a crash mid-write leaves the previous list intact.
///
/// **Why an actor.** Every write rewrites the file, and the playback sampler writes from the main
/// actor while the bridge reads from wherever the web view answers. Serialising both through an
/// actor is what makes "rewrite the whole thing" safe.
public actor WatchHistoryStore {
    public static let shared = WatchHistoryStore()

    /// `Constant.HISTORY_TIME`.
    public static let retention: TimeInterval = 60 * 24 * 60 * 60
    /// D2. Android has no count limit because Room does not grow a file the app must parse whole;
    /// this one does, so it is capped.
    public static let limit = 500

    private let file: URL
    private var cache: [WatchHistory]?

    public init(directory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory()
        file = base.appendingPathComponent("history.json")
    }

    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("WatchHistory", isDirectory: true)
    }

    /// Everything still in retention, newest first.
    /// The records belonging to one configuration, newest first.
    ///
    /// A record with no `sourceID` predates IOS-POC-10E and is included everywhere, which is the
    /// only behaviour that does not look like lost history to someone upgrading.
    public func records(for sourceID: String, now: Date = .now) -> [WatchHistory] {
        records(now: now).filter { $0.sourceID == nil || $0.sourceID == sourceID }
    }

    public func records(now: Date = .now) -> [WatchHistory] {
        prune(loaded(), now: now)
    }

    public func record(forKey key: String, now: Date = .now) -> WatchHistory? {
        records(now: now).first { $0.key == key }
    }

    /// Upserts by `key` and stamps `createTime`, then prunes and writes.
    ///
    /// A record with no position is dropped rather than stored, which is `History.canSave()`: the
    /// app calls this the moment playback opens, before any position exists, and a title nobody
    /// actually watched should not appear in the list.
    public func save(_ record: WatchHistory, now: Date = .now) {
        guard record.canSave else { return }
        var updated = record
        updated.createTime = now.timeIntervalSince1970 * 1000
        var all = loaded().filter { $0.key != record.key }
        all.insert(updated, at: 0)
        store(prune(all, now: now))
    }

    public func remove(key: String) {
        store(loaded().filter { $0.key != key })
    }

    public func clear() {
        store([])
    }

    private func prune(_ records: [WatchHistory], now: Date) -> [WatchHistory] {
        let cutoff = (now.timeIntervalSince1970 - Self.retention) * 1000
        return records
            .filter { $0.createTime >= cutoff }
            .sorted { $0.createTime > $1.createTime }
            .prefix(Self.limit)
            .map { $0 }
    }

    private func loaded() -> [WatchHistory] {
        if let cache { return cache }
        // A file that will not decode is a lost history, not a lost launch: the next save replaces
        // it wholesale.
        let records = (try? Data(contentsOf: file))
            .flatMap { try? JSONDecoder().decode([WatchHistory].self, from: $0) } ?? []
        cache = records
        return records
    }

    private func store(_ records: [WatchHistory]) {
        cache = records
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
