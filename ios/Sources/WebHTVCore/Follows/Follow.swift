import Foundation

/// W-313 — one followed title (追更): which episodes the source listed last time, and which new ones
/// the viewer has not played yet.
///
/// Identified exactly as a favourite is (`FavoriteIdentity`: configuration, `Site.id`, vod id), so a
/// title opened from another site or configuration is another follow. Kept in its own file rather than
/// on the watch history, whose records the player replaces whole on every save and prunes after 60 days.
public struct Follow: Codable, Equatable, Sendable, Identifiable {
    /// How many of the listing's newest episode names are remembered to recognise it next time.
    public static let tailLength = 20
    /// The most new episodes one follow keeps waiting; older ones fall off.
    public static let unseenLimit = 200

    public let identity: FavoriteIdentity
    public var vodName: String
    public var vodPic: String
    public var siteName: String
    /// The source's own remarks (「更新至12集」), shown as they are and never used to decide anything.
    public var remarks: String
    /// The longest line's length at the last look.
    public var latestCount: Int
    /// The newest episode's name at the last look.
    public var latestEpisodeName: String
    /// The newest `tailLength` episode names, normalised, newest first.
    public var knownTail: [String]
    /// New episodes found and not played yet, oldest first, as the source names them. The badge is
    /// their count.
    public var unseen: [String]
    public let createdAt: Date
    public var checkedAt: Date?
    /// Checks in a row that did not answer; reset by one that did.
    public var failures: Int
    /// The site answered, but not with this title (`detail` came back empty).
    public var notFound: Bool
    /// W-313 方案 C: a later season the same site lists, until the viewer opens it. Optional, like
    /// `seasonCheckedAt`, so a file written before 方案 C still reads.
    public var newSeason: NewSeason?
    /// When the site was last searched for a later season.
    public var seasonCheckedAt: Date?

    public struct NewSeason: Codable, Equatable, Sendable {
        public let vodID: String
        public let name: String
        public let season: Int
    }

    public var id: FavoriteIdentity { identity }

    /// Three misses in a row before the row says so: one slow evening is not news.
    public var isFailing: Bool { failures >= 3 }

    /// New episodes or a later season waiting: what the 片庫 tab counts and what sorts a row first.
    public var hasNews: Bool { !unseen.isEmpty || newSeason != nil }

    /// A new follow, its baseline the listing the detail screen has just shown: nothing is new yet.
    public init(identity: FavoriteIdentity, vodName: String, vodPic: String, siteName: String, remarks: String,
                listing: EpisodeListing, now: Date = .now) {
        self.identity = identity
        self.vodName = vodName
        self.vodPic = vodPic
        self.siteName = siteName
        self.remarks = remarks
        latestCount = listing.count
        latestEpisodeName = listing.newestFirst.first ?? ""
        knownTail = Self.tail(of: listing)
        unseen = []
        createdAt = now
        checkedAt = now
        failures = 0
        notFound = false
        newSeason = nil
        seasonCheckedAt = nil
    }

    // MARK: - Comparing a new listing (§4.2)

    /// This follow after the source listed `listing`.
    ///
    /// Two signals, the larger wins: the longest line grew (`count - latestCount`), and the newest end
    /// carries names never seen — walked from the newest episode back to the first remembered one, which
    /// is what notices a rolling list (a daily show keeping its last 20) and a trailer replaced by the
    /// episode. When the walk meets no remembered name at all and the line did not grow, the source
    /// renamed everything: that resets the baseline instead of announcing twenty "new" episodes. The walk
    /// reaches `max(tailLength, growth)` back plus the tail, so a short drama dropping thirty episodes at
    /// once still counts thirty (W-313 review N-4).
    public func updated(with listing: EpisodeListing, remarks: String, now: Date = .now) -> Follow {
        var next = self
        next.checkedAt = now
        next.failures = 0
        next.notFound = false
        if !remarks.isEmpty { next.remarks = remarks }
        guard listing.count > 0 else { return next }
        let growth = max(0, listing.count - latestCount)
        let known = Set(knownTail)
        let reach = min(listing.newestFirst.count, max(Self.tailLength, growth) + Self.tailLength)
        var walked = 0
        while walked < reach, !known.contains(Self.normalized(listing.newestFirst[walked])) { walked += 1 }
        let metKnown = walked < reach
        let fresh: Int
        if knownTail.isEmpty {
            fresh = 0
        } else if metKnown {
            fresh = max(growth, walked)
        } else {
            fresh = growth
        }
        if fresh > 0 {
            let names = listing.newestFirst.prefix(fresh).reversed()
            var seen = Set(unseen.map(Self.normalized))
            for name in names where seen.insert(Self.normalized(name)).inserted { next.unseen.append(name) }
            if next.unseen.count > Self.unseenLimit { next.unseen.removeFirst(next.unseen.count - Self.unseenLimit) }
        }
        next.latestCount = listing.count
        next.latestEpisodeName = listing.newestFirst.first ?? ""
        next.knownTail = Self.tail(of: listing)
        return next
    }

    /// A check that did not answer: everything known stays.
    public func failed(now: Date = .now) -> Follow {
        var next = self
        next.checkedAt = now
        next.failures += 1
        return next
    }

    /// The site answered without this title.
    public func missing(now: Date = .now) -> Follow {
        var next = self
        next.checkedAt = now
        next.failures = 0
        next.notFound = true
        return next
    }

    // MARK: - Clearing by playing (user decision 2b)

    /// This follow after `episodeName` started playing, or nil when that changes nothing.
    ///
    /// Playing a new episode settles it and every new one older than it; the badge keeps the newer ones
    /// (+3 for 11–13, play 11 → +2). Playing the newest episode the source lists settles them all.
    /// Matched by name, as the watch history matches episodes (`WatchHistory.carryingOver`).
    public func playing(_ episodeName: String) -> Follow? {
        guard !unseen.isEmpty else { return nil }
        let name = Self.normalized(episodeName)
        guard !name.isEmpty else { return nil }
        var next = self
        if let index = unseen.lastIndex(where: { Self.normalized($0) == name }) {
            next.unseen.removeFirst(index + 1)
        } else if name == Self.normalized(latestEpisodeName) {
            next.unseen.removeAll()
        } else {
            return nil
        }
        return next
    }

    // MARK: - A later season (方案 C, §6)

    /// New seasons are rare and a search costs more than a detail: one look a day.
    public static let seasonInterval: TimeInterval = 24 * 60 * 60

    /// What the site is searched for, or nil when this title takes no part: a special or film of a
    /// series, or a name too short to search for without matching half the site (§6.3).
    public var seasonKeyword: String? {
        let title = SeriesTitle(vodName)
        guard title.special == nil, title.baseKey.count >= 2 else { return nil }
        return title.baseDisplay
    }

    public func seasonDue(now: Date = .now) -> Bool {
        guard seasonKeyword != nil else { return false }
        guard let seasonCheckedAt else { return true }
        return now.timeIntervalSince(seasonCheckedAt) >= Self.seasonInterval
    }

    /// This follow after the site's search for `seasonKeyword` answered `results`: the highest later
    /// season among them (`SeriesGrouping.isNewerSeason`, strong markers only), never the title itself,
    /// and not older than it when both names carry a year. A hint already found is kept unless a higher
    /// one turns up: one search that misses it does not mean it is gone.
    public func searched(_ results: [Vod], now: Date = .now) -> Follow {
        var next = self
        next.seasonCheckedAt = now
        let watched = SeriesTitle(vodName)
        let watchedYear = Self.year(watched.tags)
        let found = results.compactMap { vod -> NewSeason? in
            guard vod.id != identity.vodID else { return nil }
            let candidate = SeriesTitle(vod.name)
            guard SeriesGrouping.isNewerSeason(candidate, than: watched), let season = candidate.season else { return nil }
            if let watchedYear, let year = Self.year(candidate.tags), year < watchedYear { return nil }
            return NewSeason(vodID: vod.id, name: vod.name, season: season)
        }.max { $0.season < $1.season }
        if let found, found.season > (newSeason?.season ?? 0) { next.newSeason = found }
        return next
    }

    /// The viewer opened the later season: the hint has done its job.
    public func seasonOpened(vodID: String) -> Follow? {
        guard newSeason?.vodID == vodID else { return nil }
        var next = self
        next.newSeason = nil
        return next
    }

    private static func year(_ tags: [String]) -> Int? {
        tags.lazy.compactMap { Int($0) }.first { (1900...2100).contains($0) }
    }

    static func tail(of listing: EpisodeListing) -> [String] {
        listing.newestFirst.prefix(tailLength).map(normalized)
    }

    static func normalized(_ name: String) -> String { SeriesCompletion.normalized(name) }
}

/// A detail's episodes as following reads them: the longest line, newest first.
public struct EpisodeListing: Equatable, Sendable {
    public let newestFirst: [String]
    public var count: Int { newestFirst.count }

    public init(newestFirst: [String]) { self.newestFirst = newestFirst }

    /// The longest line — a line that lags behind the others, or the one the viewer switched to, does
    /// not decide (the reason `FavoriteAutoRemoval` reads the longest line too). Which end is newest
    /// comes from the episode numbers at the two ends (`SeriesCompletion.episodeNumber`; a date-named
    /// 「20261117期」 is its own number): a first number above the last means the source lists newest
    /// first. Without numbers at both ends, oldest first — how sources usually list.
    public init(flags: [Flag]) {
        let line = flags.max { $0.episodes.count < $1.episodes.count }?.episodes.map(\.name) ?? []
        if let first = line.first.flatMap(SeriesCompletion.episodeNumber),
           let last = line.last.flatMap(SeriesCompletion.episodeNumber), first > last {
            newestFirst = line
        } else {
            newestFirst = line.reversed()
        }
    }

    /// Whether following makes sense: a series, not a film or a one-episode line.
    public static func isFollowable(flags: [Flag], typeName: String) -> Bool {
        let genre = SeriesCompletion.normalized(typeName)
        if genre.contains("电影") || genre.contains("movie") { return false }
        return (flags.map(\.episodes.count).max() ?? 0) >= 2
    }
}
