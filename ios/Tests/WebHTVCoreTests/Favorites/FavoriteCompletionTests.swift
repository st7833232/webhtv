import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-48 A12, A13: a finished series' favourite goes when its real final episode is finished,
// and only then; the undo puts back exactly what went.

private let siteID = "s\u{0}{}"
private let config = FavoriteFixture.configA

private func line(_ episodes: [String], name: String = "線路①") -> Flag {
    Flag(name: name, episodes: episodes.map { Episode(name: $0, url: "https://src.example/\(name)/\($0)") })
}

private func numbered(_ count: Int) -> [String] { (1...count).map { "第\($0)集" } }

/// The record the player writes for an episode: 20 minutes long, at `position` milliseconds.
private func record(_ episode: String, flag: String = "線路①", position: Double = 1_195_000,
                    sourceID: String? = config) -> WatchHistory {
    WatchHistory(key: WatchHistory.key(siteID: siteID, vodId: "1"), siteKey: "s", siteName: "站", sourceID: sourceID,
                 vodId: "1", vodName: "片", vodFlag: flag, vodRemarks: episode,
                 episodeUrl: "https://src.example/\(flag)/\(episode)", position: position, duration: 1_200_000)
}

private func favorite(remarks: String, typeName: String = "国产剧") -> Favorite {
    Favorite(identity: FavoriteFixture.identity(config: config, siteID: siteID, vod: "1"),
             snapshot: FavoriteFixture.snapshot(remarks: remarks, typeName: typeName), createdAt: FavoriteFixture.t0)
}

private func favoritedStore(_ name: String, remarks: String, typeName: String = "国产剧") async -> FavoriteStore {
    let (store, _) = FavoriteFixture.store(name)
    await store.add(FavoriteFixture.identity(config: config, siteID: siteID, vod: "1"),
                    snapshot: FavoriteFixture.snapshot(remarks: remarks, typeName: typeName), now: FavoriteFixture.t0)
    return store
}

// MARK: - What the remarks say

@Test(arguments: [("全12集", 12), ("12集全", 12), ("共24集", 24), ("第36集完结", 36), ("全１２集", 12), ("全 12 集", 12),
                  ("全40話", 40)])
func remarksThatDeclareTheFinishedTotal(remarks: String, total: Int) {
    #expect(SeriesCompletion(remarks: remarks) == .finished(total: total))
}

@Test(arguments: ["已完結", "完结", "全集", "大結局", "Final"])
func remarksThatSayFinishedWithoutATotal(remarks: String) {
    #expect(SeriesCompletion(remarks: remarks) == .finished(total: nil))
}

@Test(arguments: ["更新至8集", "連載中", "更至20集", "第8集未完結", "待續"])
func remarksThatSayMoreIsComing(remarks: String) {
    #expect(SeriesCompletion(remarks: remarks) == .ongoing)
}

/// Neither, or both: nothing to go on, and nothing is guessed.
@Test(arguments: ["", "HD", "第8集", "BD1080P", "更新至12集完结", "正片"])
func remarksThatProveNothing(remarks: String) {
    #expect(SeriesCompletion(remarks: remarks) == .unknown)
}

@Test(arguments: [("第12集", 12), ("第11-12集", 12), ("12", 12), ("EP12", 12), ("第1季第12集", 12), ("第１２集", 12),
                  ("第12话", 12)])
func anEpisodeNamePrintsItsNumber(name: String, number: Int) {
    #expect(SeriesCompletion.episodeNumber(name) == number)
}

@Test(arguments: ["S01E12", "2025-01-12", "正片", "大结局"])
func anEpisodeNameThatProvesNoNumber(name: String) {
    #expect(SeriesCompletion.episodeNumber(name) == nil)
}

// MARK: - The decision

@Test func anOngoingSeriesKeepsItsFavoriteAtItsLatestEpisode() async throws {
    let store = await favoritedStore("ongoing", remarks: "更新至8集")
    let lines = [line(numbered(8))]
    #expect(FavoriteAutoRemoval.decide(record: record("第8集"), ended: true, favorite: favorite(remarks: "更新至8集"),
                                       lines: lines) == .keep(.notFinished))
    #expect(await FavoriteAutoRemoval.apply(record: record("第8集"), ended: true, lines: lines, store: store) == nil)
    #expect(await store.all().count == 1)
}

@Test func aFinishedSeriesKeepsItsFavoriteBeforeItsFinalEpisode() {
    #expect(FavoriteAutoRemoval.decide(record: record("第11集"), ended: true, favorite: favorite(remarks: "全12集"),
                                       lines: [line(numbered(12))]) == .keep(.notFinalEpisode))
}

/// Near the end is the completion the watch history already calls 已看完 (`isNearEnding`), so
/// closing the player in the final credits counts, without a second definition of "finished".
@Test func theFinalEpisodeNearItsEndRemovesAFinishedSeries() async throws {
    let store = await favoritedStore("final", remarks: "全12集")
    let nearEnd = record("第12集", position: 1_195_000)
    #expect(nearEnd.isNearEnding)
    let offer = try #require(await FavoriteAutoRemoval.apply(record: nearEnd, ended: false, lines: [line(numbered(12))],
                                                             store: store, now: FavoriteFixture.t0))
    #expect(await store.all().isEmpty)
    #expect(offer.favorite.identity == FavoriteFixture.identity(config: config, siteID: siteID, vod: "1"))
    #expect(offer.expiresAt == FavoriteFixture.t0.addingTimeInterval(FavoriteUndoOffer.window))
}

@Test func theFinalEpisodeStoppedHalfwayIsNotFinished() {
    #expect(FavoriteAutoRemoval.decide(record: record("第12集", position: 600_000), ended: false,
                                       favorite: favorite(remarks: "全12集"), lines: [line(numbered(12))])
        == .keep(.notCompleted))
}

@Test func theEndOfFileOrTheViewersEndingCountsAsFinished() {
    // `finished` is the session's real end (engine EOF, or the viewer's ending skip, which can be
    // well before the near-ending threshold).
    #expect(FavoriteAutoRemoval.decide(record: record("第12集", position: 1_000_000), ended: true,
                                       favorite: favorite(remarks: "全12集"), lines: [line(numbered(12))]) == .remove)
}

@Test func noFavoriteIsANoOp() async throws {
    let (store, _) = FavoriteFixture.store("none")
    #expect(FavoriteAutoRemoval.decide(record: record("第12集"), ended: true, favorite: nil, lines: nil) == .keep(.notFavorite))
    #expect(await FavoriteAutoRemoval.apply(record: record("第12集"), ended: true, lines: [line(numbered(12))],
                                            store: store) == nil)
    #expect(await store.all().isEmpty)
}

@Test func aFilmKeepsItsFavoriteWhenItEnds() {
    // A single entry is a film whatever the remarks say…
    #expect(FavoriteAutoRemoval.decide(record: record("正片"), ended: true, favorite: favorite(remarks: "完结"),
                                       lines: [line(["正片"])]) == .keep(.movie))
    // …and a film is a film even when its line has two cuts.
    #expect(FavoriteAutoRemoval.decide(record: record("第2集"), ended: true,
                                       favorite: favorite(remarks: "全2集", typeName: "電影"),
                                       lines: [line(numbered(2))]) == .keep(.movie))
}

@Test func aFinishThatCannotBeConfirmedKeepsTheFavorite() {
    #expect(FavoriteAutoRemoval.decide(record: record("第12集"), ended: true, favorite: favorite(remarks: "HD"),
                                       lines: [line(numbered(12))]) == .keep(.notFinished))
}

@Test func aLaggingLineDoesNotEndAFinishedSeries() {
    let full = line(numbered(12), name: "線路①"), lagging = line(numbered(10), name: "線路②")
    let finished = favorite(remarks: "已完结")
    #expect(FavoriteAutoRemoval.decide(record: record("第10集", flag: "線路②"), ended: true, favorite: finished,
                                       lines: [full, lagging]) == .keep(.notFinalEpisode))
    #expect(FavoriteAutoRemoval.decide(record: record("第12集", flag: "線路①"), ended: true, favorite: finished,
                                       lines: [full, lagging]) == .remove)
}

@Test func aMergedFinalEntryIsTheFinalEpisode() {
    let entries = numbered(10) + ["第11-12集"]
    #expect(FavoriteAutoRemoval.decide(record: record("第11-12集"), ended: true, favorite: favorite(remarks: "全12集"),
                                       lines: [line(entries)]) == .remove)
}

@Test func unnumberedEpisodesNeedTheWholeDeclaredLine() {
    #expect(FavoriteAutoRemoval.decide(record: record("下"), ended: true, favorite: favorite(remarks: "全3集"),
                                       lines: [line(["上", "中", "下"])]) == .remove)
    // Two parts listed of three declared: the last one listed is not the last one made.
    #expect(FavoriteAutoRemoval.decide(record: record("中"), ended: true, favorite: favorite(remarks: "全3集"),
                                       lines: [line(["上", "中"])]) == .keep(.notFinalEpisode))
}

/// Played from the downloads tab the detail's listing is not at hand: only a declared total and a
/// numbered episode prove the end.
@Test func withoutTheListingOnlyADeclaredTotalProvesTheEnd() {
    #expect(FavoriteAutoRemoval.decide(record: record("第12集"), ended: true, favorite: favorite(remarks: "全12集"),
                                       lines: nil) == .remove)
    #expect(FavoriteAutoRemoval.decide(record: record("第12集"), ended: true, favorite: favorite(remarks: "完结"),
                                       lines: nil) == .keep(.unknownEpisode))
    #expect(FavoriteAutoRemoval.decide(record: record("大结局"), ended: true, favorite: favorite(remarks: "全12集"),
                                       lines: nil) == .keep(.unknownEpisode))
}

@Test func anEpisodeTheListingDoesNotHaveProvesNothing() {
    #expect(FavoriteAutoRemoval.decide(record: record("第12集", flag: "線路③"), ended: true,
                                       favorite: favorite(remarks: "全12集"), lines: [line(numbered(12))])
        == .keep(.unknownEpisode))
}

@Test func aRecordWithoutItsConfigurationIsNotGuessed() async throws {
    let store = await favoritedStore("no-source", remarks: "全12集")
    #expect(record("第12集", sourceID: nil).favoriteIdentity == nil)
    #expect(await FavoriteAutoRemoval.apply(record: record("第12集", sourceID: nil), ended: true,
                                            lines: [line(numbered(12))], store: store) == nil)
    #expect(await store.all().count == 1)
}

// MARK: - A11, A13: the removal and its undo touch favourites only

@Test func anAutomaticRemovalKeepsTheWatchHistory() async throws {
    let store = await favoritedStore("keeps-history", remarks: "全12集")
    let historyDirectory = FavoriteFixture.directory("history")
    let history = WatchHistoryStore(directory: historyDirectory)
    let watched = record("第12集")
    await history.save(watched, now: FavoriteFixture.t0)

    #expect(await FavoriteAutoRemoval.apply(record: watched, ended: true, lines: [line(numbered(12))], store: store) != nil)
    let kept = try #require(await history.record(forKey: watched.key, now: FavoriteFixture.t0))
    #expect(kept.vodRemarks == "第12集")
    #expect(kept.position == watched.position)
}

@Test func undoBringsTheFavoriteBackAsItWas() async throws {
    let store = await favoritedStore("undo", remarks: "全12集")
    let before = try #require(await store.all().first)
    let offer = try #require(await FavoriteAutoRemoval.apply(record: record("第12集"), ended: true,
                                                             lines: [line(numbered(12))], store: store,
                                                             now: FavoriteFixture.t0))
    #expect(await offer.undo(in: store, now: FavoriteFixture.t0.addingTimeInterval(3)))
    #expect(await store.all() == [before])
}

@Test func anExpiredOfferUndoesNothing() async throws {
    let store = await favoritedStore("undo-late", remarks: "全12集")
    let offer = try #require(await FavoriteAutoRemoval.apply(record: record("第12集"), ended: true,
                                                             lines: [line(numbered(12))], store: store,
                                                             now: FavoriteFixture.t0))
    #expect(!offer.isOpen(at: FavoriteFixture.t0.addingTimeInterval(FavoriteUndoOffer.window)))
    #expect(!(await offer.undo(in: store, now: FavoriteFixture.t0.addingTimeInterval(FavoriteUndoOffer.window + 1))))
    #expect(await store.all().isEmpty)
}
