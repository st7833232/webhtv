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
    /// IOS-POC-30: the configurations whose history list has let this record go.
    ///
    /// Only a record with no `sourceID` is listed under more than one configuration, so only such a
    /// record is ever hidden rather than deleted: clearing or swiping it away on one source's list
    /// must not take it off another's. Optional for the reason `sourceID` is. A save replaces the
    /// whole record, so watching the title again drops this along with giving it an owner.
    public var hiddenFrom: [String]?
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
    /// How much of the start to skip, in milliseconds, or `nil`/`<= 0` when the viewer has set none.
    /// `History.opening`, which the viewer sets themselves on the player — it is **not** read from
    /// the configuration's `ads` or `rules` (IOS-POC-5S measured both; neither carries these).
    ///
    /// **Optional for the reason `sourceID` above is**: the synthesized `Codable` throws
    /// `keyNotFound` on a history file written before this field existed, and an unreadable file is
    /// no history at all. Android's own unset value is `C.TIME_UNSET`, a large negative, but every
    /// consumer there tests `> 0` and its reset button writes `0` — so "not positive" is already
    /// the unset state on both sides, and `openingOffset` below is the one place that decides it.
    /// The Android constant itself is deliberately not reproduced: it would put a sentinel into the
    /// Swift API that nothing here can read back out.
    public var opening: Double?
    /// How much of the end to skip, in milliseconds, measured **backwards from the end** the way
    /// `History.ending` is — `duration - position` at the moment the viewer marks it, not an
    /// absolute timestamp. `nil`/`<= 0` is unset, as for `opening`.
    public var ending: Double?
    /// Milliseconds since 1970, rewritten on every save — this is what the 60-day prune and the
    /// list's ordering both read. Android's `createTime` behaves the same way.
    public var createTime: Double

    public var id: String { key }

    public var siteID: String? {
        let suffix = Self.separator + vodId
        guard key.hasSuffix(suffix) else { return nil }
        return String(key.dropLast(suffix.count))
    }

    func reidentified(to siteID: String) -> WatchHistory {
        WatchHistory(
            key: Self.key(siteID: siteID, vodId: vodId),
            siteKey: siteKey, siteName: siteName, sourceID: sourceID, vodId: vodId,
            vodName: vodName, vodPic: vodPic, vodFlag: vodFlag, vodRemarks: vodRemarks,
            episodeUrl: episodeUrl, quality: quality, position: position, duration: duration,
            createTime: createTime, opening: opening, ending: ending, hiddenFrom: hiddenFrom
        )
    }

    public init(key: String, siteKey: String, siteName: String = "", sourceID: String? = nil, vodId: String,
                vodName: String = "", vodPic: String = "", vodFlag: String = "",
                vodRemarks: String = "", episodeUrl: String = "", quality: String = "",
                position: Double = 0, duration: Double = 0, createTime: Double = 0,
                opening: Double? = nil, ending: Double? = nil, hiddenFrom: [String]? = nil) {
        self.key = key
        self.sourceID = sourceID
        self.hiddenFrom = hiddenFrom
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
        self.opening = opening
        self.ending = ending
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

    // MARK: - IOS-POC-5S-2: the opening and the ending

    /// The opening as every Android consumer reads it: a positive number of milliseconds, or zero.
    ///
    /// `VideoActivity` tests `getOpening() > 0` at each of its four sites and `History.copyTo` only
    /// carries the value on when it is positive, so `nil`, `0` and a negative left over from a bad
    /// write all mean the same thing — unset. Collapsing them here is what keeps that decision in
    /// one place instead of at every call site.
    public var openingOffset: Double { Self.offset(opening) }

    /// The ending, read the same way. Milliseconds **from the end**, not a timestamp.
    public var endingOffset: Double { Self.offset(ending) }

    private static func offset(_ value: Double?) -> Double {
        guard let value, value.isFinite, value > 0 else { return 0 }
        return value
    }

    /// IOS-POC-21 — this record, freshly built for the episode about to play, with what the stored
    /// record of the same title still holds. One record covers the whole title, and the position in
    /// it belongs to the episode it names, so another episode starts from its beginning while the
    /// same episode on another line keeps its place — Android's `VideoActivity.updateHistory`, which
    /// keeps the position only when `Episode.matchesName` (the name, ignoring case). The opening and
    /// the ending belong to the title and always carry over (IOS-POC-5S-2).
    ///
    /// ponytail: by name, as Android does, so two items one line prints under the same name share a
    /// position; matching the address instead would lose the place on sources whose episode
    /// addresses change from one fetch to the next.
    public func carryingOver(from stored: WatchHistory) -> WatchHistory {
        var merged = self
        merged.opening = stored.opening
        merged.ending = stored.ending
        if vodRemarks.caseInsensitiveCompare(stored.vodRemarks) == .orderedSame {
            merged.position = stored.position
            merged.duration = stored.duration
        }
        return merged
    }

    /// Where playback should start, in milliseconds. Zero means "from the beginning".
    ///
    /// `VideoActivity.setPosition()` is `max(getOpening(), getPosition())` after the near-ending
    /// reset, and `resumePosition` is this project's version of that same right-hand side — it
    /// already applies the near-ending rule and D4's ten-second floor. `resuming` is false when the
    /// **next** episode is starting (IOS-POC-14): one record covers a whole title, so the previous
    /// episode's position must not be resumed into it, but the opening still belongs to the title
    /// and still applies.
    public func startPosition(resuming: Bool = true) -> Double {
        max(openingOffset, resuming ? (resumePosition ?? 0) : 0)
    }

    /// `VideoActivity.onTimeChanged()`: `ending > 0 && duration > 0 && ending + position >= duration`.
    ///
    /// The `duration > 0` term is what keeps a live stream or an item whose runtime has not been
    /// reported yet from skipping the moment it starts — with an unknown duration there is no end
    /// to measure the ending back from.
    public func hasReachedEnding(position: Double, duration: Double) -> Bool {
        endingOffset > 0 && duration > 0 && endingOffset + position >= duration
    }

    /// `Constant.getOpEdLimit`: how far into a runtime an opening, or back from it an ending, may be
    /// marked from the current position. Three minutes under a quarter of an hour, six under half,
    /// ten above. Internal — the two predicates below are the whole public surface it serves.
    static func openingEndingLimit(duration: Double) -> Double {
        if duration < 15 * 60_000 { return 3 * 60_000 }
        if duration < 30 * 60_000 { return 6 * 60_000 }
        return 10 * 60_000
    }

    /// `PlayerManager.canSetOpening`: whether "the opening ends here" is a sane thing to say about
    /// the position the viewer is at.
    public static func canSetOpening(position: Double, duration: Double) -> Bool {
        position > 0 && duration > 0 && position <= openingEndingLimit(duration: duration)
    }

    /// `PlayerManager.canSetEnding`, the same test measured from the other end.
    public static func canSetEnding(position: Double, duration: Double) -> Bool {
        position > 0 && duration > 0 && duration - position <= openingEndingLimit(duration: duration)
    }

    /// Applies a new opening, clamped so it can never place the start past the end or inside the
    /// ending.
    ///
    /// Android floors at zero (`max(0, max(0, opening) + 1000)`) and does not clamp the top at all,
    /// so holding its remote's up key walks the opening past the runtime and `setPosition` then
    /// seeks beyond the end. That is a defect rather than a contract, so the ceiling is added here.
    /// `duration <= 0` means the runtime is not known yet and only the floor applies.
    public mutating func setOpening(_ value: Double, duration: Double) {
        opening = Self.clamped(value, ceiling: duration > 0 ? max(0, duration - endingOffset) : nil)
    }

    /// Applies a new ending, clamped so it can never cut back past the opening — which would leave
    /// a negative playable span and skip the episode the instant it started.
    public mutating func setEnding(_ value: Double, duration: Double) {
        ending = Self.clamped(value, ceiling: duration > 0 ? max(0, duration - openingOffset) : nil)
    }

    private static func clamped(_ value: Double, ceiling: Double?) -> Double {
        let floored = value.isFinite ? max(0, value) : 0
        guard let ceiling else { return floored }
        return min(floored, ceiling)
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
    /// only behaviour that does not look like lost history to someone upgrading — except on a list
    /// that has already cleared or swiped it away (IOS-POC-30, `hiddenFrom`).
    public func records(for sourceID: String, now: Date = .now) -> [WatchHistory] {
        records(now: now).filter { Self.isListed($0, under: sourceID) }
    }

    private static func isListed(_ record: WatchHistory, under sourceID: String) -> Bool {
        if let owner = record.sourceID { return owner == sourceID }
        return !(record.hiddenFrom ?? []).contains(sourceID)
    }

    /// The same record, no longer listed under `sourceID`.
    private static func hiding(_ record: WatchHistory, from sourceID: String) -> WatchHistory {
        var hidden = record
        var sources = record.hiddenFrom ?? []
        if !sources.contains(sourceID) { sources.append(sourceID) }
        hidden.hiddenFrom = sources
        return hidden
    }

    public func records(now: Date = .now) -> [WatchHistory] {
        prune(loaded(), now: now)
    }

    public func record(forKey key: String, now: Date = .now) -> WatchHistory? {
        records(now: now).first { $0.key == key }
    }

    public func migrateSiteIdentities(in sites: [Site], now: Date = .now) {
        var migrated = loaded()
        var changed = false
        for index in migrated.indices {
            guard let oldID = migrated[index].siteID,
                  let newID = SiteSelection.resolveIdentity(oldID, in: sites),
                  newID != oldID else { continue }
            migrated[index] = migrated[index].reidentified(to: newID)
            changed = true
        }
        guard changed else { return }
        var newest = [String: WatchHistory]()
        for item in migrated {
            if let old = newest[item.key], old.createTime >= item.createTime { continue }
            newest[item.key] = item
        }
        store(prune(Array(newest.values), now: now))
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

    /// One row swiped away on one configuration's list (IOS-POC-30): a record that configuration
    /// owns is deleted; one from before sources were separable, which every list shows, is only
    /// hidden from this one; and one another configuration owns — the list can be a moment behind
    /// a save made from Picture in Picture — is left alone, as `clear(for:)` leaves it.
    public func remove(key: String, for sourceID: String) {
        store(loaded().compactMap { (record: WatchHistory) -> WatchHistory? in
            guard record.key == key else { return record }
            if record.sourceID == sourceID { return nil }
            return record.sourceID == nil ? Self.hiding(record, from: sourceID) : record
        })
    }

    /// Every configuration's records. **Not what the history list's 清除 does** (IOS-POC-30): that
    /// is `clear(for:)`.
    public func clear() {
        store([])
    }

    /// Clears what one configuration's history list shows, and nothing else (IOS-POC-30), so 清除
    /// empties the list on screen without touching the history of any other source. Android's 清除
    /// is the same: `History.deleteAndSync(cid)` for the current configuration only.
    ///
    /// The records this configuration owns are deleted. A record with no `sourceID` predates
    /// IOS-POC-10E and is listed under every configuration, so deleting it would take it off every
    /// other list too; it is hidden from this one instead.
    public func clear(for sourceID: String) {
        store(loaded().compactMap { (record: WatchHistory) -> WatchHistory? in
            if record.sourceID == sourceID { return nil }
            return record.sourceID == nil ? Self.hiding(record, from: sourceID) : record
        })
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
