import Foundation

/// IOS-POC-48 A12 — what a title's remarks say about whether it is finished.
///
/// Only the source's own words count. `Vod` carries no `vod_isend` or total, so `remarks` is the one
/// place a source says 「全12集」 or 「更新至8集」. A remark that says neither — 「HD」, 「第8集」 — or
/// says both is `unknown`, and unknown never removes a favourite.
public enum SeriesCompletion: Equatable, Sendable {
    /// Finished; `total` when the remark also says how many episodes there are.
    case finished(total: Int?)
    /// More episodes are coming.
    case ongoing
    case unknown

    private static let ongoingWords = ["更新", "连载", "更至", "待续", "待更"]
    private static let finishedWords = ["完结", "全集", "大结局", "final"]
    private static let totalPatterns = ["全([0-9]+)[集话期回]", "([0-9]+)[集话期回]全", "共([0-9]+)[集话期回]",
                                        "([0-9]+)[集话期回]完"]

    public init(remarks: String) {
        let text = Self.normalized(remarks)
        if text.contains("未完") {
            self = .ongoing
            return
        }
        let total = Self.totalPatterns.lazy.compactMap { Self.lastNumber(matching: $0, in: text) }.first { $0 > 0 }
        let ongoing = Self.ongoingWords.contains { text.contains($0) }
        let finished = total != nil || Self.finishedWords.contains { text.contains($0) }
        switch (ongoing, finished) {
        case (true, true), (false, false): self = .unknown
        case (true, false): self = .ongoing
        case (false, true): self = .finished(total: total)
        }
    }

    /// The episode number an episode's name prints: the number before 集／话／期／回 (`第12集`, and
    /// `第11-12集` is 12), else the name's only number (`12`, `EP12`). Nil for a name with none or
    /// several (`S01E12`, a date) — those prove nothing.
    public static func episodeNumber(_ name: String) -> Int? {
        let text = normalized(name)
        if let number = lastNumber(matching: "([0-9]+)[集话期回]", in: text) { return number }
        let numbers = text.split { !$0.isASCII || !$0.isNumber }.compactMap { Int($0) }
        return numbers.count == 1 ? numbers[0] : nil
    }

    /// Simplified, lowercased, half-width, without spaces: 「全１２集」, 「全 12 集」 and 「全12集」 read alike.
    static func normalized(_ text: String) -> String {
        TraditionalSimplified.toSimplified(text)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .filter { !$0.isWhitespace }
    }

    static func lastNumber(matching pattern: String, in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let match = matches.last, let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }
}

/// IOS-POC-48 A12 — whether finishing an episode finishes a favourite, and so removes it.
///
/// The rule is not "the last episode listed ended" but "the source says the title is finished, and
/// the episode that ended is its real final one". A series still airing keeps its favourite at its
/// latest episode; a film keeps it; anything the facts cannot prove keeps it.
public enum FavoriteAutoRemoval {
    public enum Decision: Equatable, Sendable {
        case remove
        case keep(Reason)
    }

    public enum Reason: Equatable, Sendable {
        /// The episode did not reach its end (`finished`, or `WatchHistory.isNearEnding`).
        case notCompleted
        case notFavorite
        /// A film, or a line of one episode.
        case movie
        /// Still airing, or the remarks do not say.
        case notFinished
        case notFinalEpisode
        /// The line or the episode cannot be found, or without the line nothing proves which is last.
        case unknownEpisode
    }

    /// One playback end. `ended` is the session's `finished` (the engine's end of file, or the
    /// viewer's ending); otherwise the record's own near-ending test decides whether the episode was
    /// completed — the two completions this app already has, and no third.
    public static func decide(record: WatchHistory, ended: Bool, favorite: Favorite?, lines: [Flag]?) -> Decision {
        guard ended || record.isNearEnding else { return .keep(.notCompleted) }
        guard let favorite else { return .keep(.notFavorite) }
        return decide(favorite: favorite, flag: record.vodFlag, episodeName: record.vodRemarks,
                      episodeURL: record.episodeUrl, lines: lines)
    }

    /// Whether the episode named — its line, its name, its address, as the watch history records
    /// them — is the final episode of a finished multi-episode title. `lines` is the detail's
    /// listing when the detail screen has it; without it only a declared total and a numbered
    /// episode can prove anything.
    public static func decide(favorite: Favorite, flag: String, episodeName: String, episodeURL: String,
                              lines: [Flag]?) -> Decision {
        let genre = SeriesCompletion.normalized(favorite.typeName)
        if genre.contains("电影") || genre.contains("movie") { return .keep(.movie) }
        guard case .finished(let total) = SeriesCompletion(remarks: favorite.remarks) else { return .keep(.notFinished) }
        let number = SeriesCompletion.episodeNumber(episodeName)
        guard let lines else {
            guard let total, let number else { return .keep(.unknownEpisode) }
            guard total >= 2 else { return .keep(.movie) }
            return number == total ? .remove : .keep(.notFinalEpisode)
        }
        // By address, as the auto-advance finds the episode playing (`Flag.episode(after:)`).
        guard let line = lines.first(where: { $0.name == flag }),
              let index = line.episodes.firstIndex(where: { $0.url == episodeURL })
        else { return .keep(.unknownEpisode) }
        guard line.episodes.count >= 2 else { return .keep(.movie) }
        let last = index == line.episodes.count - 1
        if let total {
            guard total >= 2 else { return .keep(.movie) }
            if let number { return number == total ? .remove : .keep(.notFinalEpisode) }
            // Names without numbers: the line must hold exactly the declared episodes, and this its last.
            return line.episodes.count == total && last ? .remove : .keep(.notFinalEpisode)
        }
        // Finished, count unknown: the last episode of the longest line, so a line that lags behind
        // the others never passes its own last episode off as the final one.
        let longest = lines.map(\.episodes.count).max() ?? 0
        return last && line.episodes.count >= longest ? .remove : .keep(.notFinalEpisode)
    }

    /// Applies the rule to one playback end: the favourite goes — through its own store, touching
    /// no watch history and no download — and the offer that can put it back is answered. Nil when
    /// nothing was removed, including when the title is not a favourite at all.
    public static func apply(record: WatchHistory, ended: Bool, lines: [Flag]?, store: FavoriteStore,
                             now: Date = .now) async -> FavoriteUndoOffer? {
        guard let identity = record.favoriteIdentity else { return nil }
        let favorite = await store.favorite(identity)
        guard decide(record: record, ended: ended, favorite: favorite, lines: lines) == .remove,
              let removed = await store.remove(identity) else { return nil }
        return FavoriteUndoOffer(favorite: removed, offeredAt: now)
    }
}

/// A13 — the short-lived 「復原」 after an automatic removal. Memory only: a crash simply ends the
/// offer, and the favourites file already holds the removal it would have undone.
public struct FavoriteUndoOffer: Equatable, Sendable, Identifiable {
    public static let window: TimeInterval = 8

    public let id: UUID
    public let favorite: Favorite
    public private(set) var expiresAt: Date

    public init(favorite: Favorite, offeredAt now: Date) {
        id = UUID()
        self.favorite = favorite
        expiresAt = now.addingTimeInterval(Self.window)
    }

    public func isOpen(at now: Date) -> Bool { now < expiresAt }

    /// The same offer once the viewer can see it, open for at least `lasting` from `now`. The player
    /// that finished the episode may still be on screen when the favourite goes, and a window that
    /// runs out behind it was never offered at all. Never shortens an offer.
    public func shown(at now: Date, lasting: TimeInterval = window) -> FavoriteUndoOffer {
        var shown = self
        shown.expiresAt = max(expiresAt, now.addingTimeInterval(lasting))
        return shown
    }

    /// Puts the favourite back while the offer is open — its own record, so its place in the list
    /// is where it was. Only the favourites store is touched.
    public func undo(in store: FavoriteStore, now: Date = .now) async -> Bool {
        guard isOpen(at: now) else { return false }
        return await store.restore(favorite)
    }
}

public extension WatchHistory {
    /// The favourite this record's title is, when the record says which configuration it was watched
    /// on. A record from before IOS-POC-10E has no `sourceID`, and its favourite is not guessed.
    var favoriteIdentity: FavoriteIdentity? {
        guard let sourceID, !sourceID.isEmpty, let siteID else { return nil }
        let identity = FavoriteIdentity(configSourceID: sourceID, siteID: siteID, vodID: vodId)
        return identity.isComplete ? identity : nil
    }
}
