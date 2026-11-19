import Foundation
import Testing
@testable import WebHTVCore

// W-313 方案 B — following a title's new episodes (docs/W-313-ios-update-notifications.md §4, §9).

private let identity = FavoriteIdentity(configSourceID: "cfg", siteID: "site", vodID: "v1")

private func episodes(_ range: ClosedRange<Int>) -> [String] { range.map { "第\($0)集" } }

private func flag(_ names: [String], name: String = "A") -> Flag {
    Flag(name: name, episodes: names.map { Episode(name: $0, url: "u/\($0)") })
}

private func follow(_ names: [String]) -> Follow {
    Follow(identity: identity, vodName: "劇", vodPic: "", siteName: "站", remarks: "",
           listing: EpisodeListing(flags: [flag(names)]), now: Date(timeIntervalSince1970: 0))
}

private func listing(_ names: [String]) -> EpisodeListing { EpisodeListing(flags: [flag(names)]) }

private func site(_ key: String) throws -> Site {
    try JSONDecoder().decode(Site.self, from: Data(#"{"key":"\#(key)","name":"\#(key)","type":1,"api":"https://x/\#(key)"}"#.utf8))
}

// MARK: - Comparing

@Test func aLongerListAddsItsNewEpisodes() {
    let next = follow(episodes(1...3)).updated(with: listing(episodes(1...5)), remarks: "更新至5集")
    #expect(next.unseen == ["第4集", "第5集"])
    #expect(next.latestCount == 5)
    #expect(next.latestEpisodeName == "第5集")
    #expect(next.remarks == "更新至5集")
}

@Test func aShorterListResetsTheBaselineWithoutABadge() {
    let next = follow(episodes(1...5)).updated(with: listing(episodes(1...4)), remarks: "")
    #expect(next.unseen.isEmpty)
    #expect(next.latestCount == 4)
}

@Test func theLongestLineDecides() {
    let start = follow(episodes(1...3))
    let next = start.updated(with: EpisodeListing(flags: [flag(episodes(1...2), name: "slow"),
                                                          flag(episodes(1...4), name: "fast")]), remarks: "")
    #expect(next.unseen == ["第4集"])
}

@Test func aRollingListOfFixedLengthStillCountsTheNewEpisode() {
    let next = follow(episodes(1...20)).updated(with: listing(episodes(2...21)), remarks: "")
    #expect(next.unseen == ["第21集"])
}

@Test func aTrailerReplacedByTheEpisodeCounts() {
    let next = follow(episodes(1...11) + ["预告"]).updated(with: listing(episodes(1...12)), remarks: "")
    #expect(next.unseen == ["第12集"])
}

@Test func dateNamedVarietyEpisodesFollowTheListLength() {
    let next = follow(["20261115期", "20261116期"]).updated(with: listing(["20261115期", "20261116期", "20261117期"]),
                                                            remarks: "更新至20261117期")
    #expect(next.unseen == ["20261117期"])
}

@Test func aNewestFirstListIsReadFromItsStart() {
    let start = follow(Array(episodes(1...10).reversed()))
    #expect(start.latestEpisodeName == "第10集")
    let next = start.updated(with: listing(Array(episodes(1...12).reversed())), remarks: "")
    #expect(next.unseen == ["第11集", "第12集"])
    #expect(next.latestEpisodeName == "第12集")
}

/// Review N-4: a trailer heading a newest-first list does not flip it.
@Test func anUnnumberedHeadDoesNotHideANewestFirstOrder() {
    let start = follow(["预告"] + Array(episodes(1...12).reversed()))
    #expect(start.latestEpisodeName == "预告")
    let next = start.updated(with: listing(["预告"] + Array(episodes(1...13).reversed())), remarks: "")
    #expect(next.unseen == ["第13集"])
    #expect(next.playing("第13集")?.unseen == [])
}

@Test func endsWithoutNumbersReadOldestFirst() {
    #expect(EpisodeListing(flags: [flag(["上", "下"])]).newestFirst == ["下", "上"])
}

@Test func renamingEveryEpisodeResetsTheBaselineWithoutABadge() {
    let next = follow(episodes(1...20)).updated(with: listing((1...20).map { "EP\($0)" }), remarks: "")
    #expect(next.unseen.isEmpty)
    #expect(next.knownTail.first == SeriesCompletion.normalized("EP20"))
}

/// Review N-4: a short drama dropping thirty episodes at once is thirty, not a rename.
@Test func aBulkDropIsCountedInFull() {
    let next = follow(episodes(1...10)).updated(with: listing(episodes(1...40)), remarks: "")
    #expect(next.unseen.count == 30)
    #expect(next.unseen.first == "第11集")
    #expect(next.unseen.last == "第40集")
}

@Test func remarksThatLieDecideNothing() {
    let next = follow(["正片"]).updated(with: listing(["正片"]), remarks: "更新全集")
    #expect(next.unseen.isEmpty)
}

@Test func newEpisodesAccumulateAcrossChecks() {
    let once = follow(episodes(1...3)).updated(with: listing(episodes(1...4)), remarks: "")
    let twice = once.updated(with: listing(episodes(1...6)), remarks: "")
    #expect(twice.unseen == ["第4集", "第5集", "第6集"])
}

@Test func threeFailuresInARowAreShownAndOneAnswerClearsThem() {
    let failing = follow(episodes(1...3)).failed().failed().failed()
    #expect(failing.isFailing)
    #expect(!follow(episodes(1...3)).failed().failed().isFailing)
    #expect(!failing.updated(with: listing(episodes(1...3)), remarks: "").isFailing)
    #expect(follow(episodes(1...3)).missing().notFound)
}

// MARK: - Clearing by playing (2b)

@Test func playingANewEpisodeSettlesItAndOlderOnes() throws {
    let waiting = follow(episodes(1...10)).updated(with: listing(episodes(1...13)), remarks: "")
    let partly = try #require(waiting.playing("第11集"))
    #expect(partly.unseen == ["第12集", "第13集"])
    let all = try #require(partly.playing("第13集"))
    #expect(all.unseen.isEmpty)
}

@Test func playingAnOldEpisodeLeavesTheBadge() {
    let waiting = follow(episodes(1...10)).updated(with: listing(episodes(1...12)), remarks: "")
    #expect(waiting.playing("第3集") == nil)
    #expect(follow(episodes(1...3)).playing("第3集") == nil)
}

// MARK: - Store

@Test func theStoreKeepsFollowsAndMatchesPlaysOnTheSameTitleOnly() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = FollowStore(directory: directory)
    let waiting = follow(episodes(1...2)).updated(with: listing(episodes(1...4)), remarks: "")
    #expect(await store.add(waiting) == .added)
    #expect(await store.add(waiting) == .alreadyFollowing)

    var other = WatchHistory(key: identity.historyKey, siteKey: "site", sourceID: "another", vodId: "v1",
                             vodRemarks: "第4集", position: 1)
    #expect(await store.played(other) == nil)
    other.sourceID = "cfg"
    let played = try #require(await store.played(other))
    #expect(played.unseen.isEmpty)

    let reread = FollowStore(directory: directory)
    #expect(await reread.all().map(\.unseen) == [[]])
    #expect(await reread.remove(identity))
    #expect(await reread.all().isEmpty)
}

@Test func anEntryThisBuildCannotReadIsKeptAndALimitApplies() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(#"{"schemaVersion":1,"follows":[{"future":true}]}"#.utf8)
        .write(to: directory.appendingPathComponent("follows.json"))
    let store = FollowStore(directory: directory)
    #expect(await store.all().isEmpty)
    for index in 0..<FollowStore.limit {
        let item = Follow(identity: FavoriteIdentity(configSourceID: "cfg", siteID: "s", vodID: "\(index)"),
                          vodName: "", vodPic: "", siteName: "", remarks: "", listing: listing(episodes(1...2)))
        #expect(await store.add(item) == .added)
    }
    #expect(await store.add(follow(episodes(1...2))) == .full)
    let written = try String(contentsOf: directory.appendingPathComponent("follows.json"), encoding: .utf8)
    #expect(written.contains("\"future\":true"))
}

// MARK: - Scheduling (§4.3, review F-2)

@Test func onlyDueFollowsOfTheLoadedConfigurationAreChecked() throws {
    let here = try site("site")
    let fresh = Follow(identity: FavoriteIdentity(configSourceID: "cfg", siteID: here.id, vodID: "a"),
                       vodName: "", vodPic: "", siteName: "", remarks: "", listing: listing(episodes(1...2)),
                       now: Date(timeIntervalSince1970: 1_000))
    let elsewhere = Follow(identity: FavoriteIdentity(configSourceID: "other", siteID: here.id, vodID: "b"),
                           vodName: "", vodPic: "", siteName: "", remarks: "", listing: listing(episodes(1...2)),
                           now: .distantPast)
    let gone = Follow(identity: FavoriteIdentity(configSourceID: "cfg", siteID: "missing", vodID: "c"),
                      vodName: "", vodPic: "", siteName: "", remarks: "", listing: listing(episodes(1...2)),
                      now: .distantPast)
    let soon = Date(timeIntervalSince1970: 1_000 + 60)
    let late = Date(timeIntervalSince1970: 1_000 + FollowSchedule.interval + 1)
    func due(_ forced: Bool, _ now: Date, waiting: Set<Site.ID> = []) -> [String] {
        FollowSchedule.due([fresh, elsewhere, gone], sourceID: "cfg", sites: [here], waiting: waiting, spiders: [],
                           health: [:], forced: forced, now: now).map(\.follow.identity.vodID)
    }
    #expect(due(false, soon).isEmpty)
    #expect(due(true, soon) == ["a"])
    #expect(due(false, late) == ["a"])
    #expect(due(true, soon, waiting: [here.id]).isEmpty)
}

@Test func aSlowSpiderSiteIsLeftOut() throws {
    let here = try site("site")
    var slow = SiteHealth()
    slow.record(.detail(milliseconds: 8_000), succeeded: true, at: 0)
    let item = Follow(identity: FavoriteIdentity(configSourceID: "cfg", siteID: here.id, vodID: "a"),
                      vodName: "", vodPic: "", siteName: "", remarks: "", listing: listing(episodes(1...2)),
                      now: .distantPast)
    #expect(FollowSchedule.due([item], sourceID: "cfg", sites: [here], waiting: [], spiders: [here.id],
                               health: [here.id: slow], forced: false).isEmpty)
    // A pull still reaches it: only a detail call rewrites the time it is judged by (Ponytail finding 1).
    #expect(FollowSchedule.due([item], sourceID: "cfg", sites: [here], waiting: [], spiders: [here.id],
                               health: [here.id: slow], forced: true).count == 1)
    #expect(FollowSchedule.due([item], sourceID: "cfg", sites: [here], waiting: [], spiders: [],
                               health: [here.id: slow], forced: false).count == 1)
}

@Test func aSpiderCallIsNeverMadeWhereTheViewerIs() {
    let now = Date(timeIntervalSince1970: 10_000)
    func may(spider: Bool = true, busy: Bool = false, touched: Date? = nil, player: Bool = false,
             screen: Bool = false, forced: Bool = false) -> Bool {
        FollowSchedule.mayStart(isSpider: spider, busy: busy, lastTouched: touched, playerOpen: player,
                                onFollowScreen: screen, forced: forced, now: now)
    }
    #expect(may())
    #expect(!may(busy: true))
    #expect(!may(busy: true, forced: true))
    #expect(!may(player: true))
    #expect(!may(screen: true))
    #expect(may(screen: true, forced: true))
    #expect(!may(touched: now.addingTimeInterval(-60)))
    #expect(may(touched: now.addingTimeInterval(-FollowSchedule.touchWindow - 1)))
    #expect(may(spider: false, touched: now, screen: true))
}

@Test func onlyTheViewersCallsCountAsUsingASite() async {
    let activity = SiteActivity()
    await SiteActivity.$background.withValue(true) { await activity.begin("a") }
    #expect(await activity.isBusy("a"))
    #expect(await activity.lastTouched("a") == nil)
    await activity.end("a")
    #expect(!(await activity.isBusy("a")))
    await activity.begin("a")
    #expect(await activity.lastTouched("a") != nil)
}

// MARK: - Checking

private actor Calls {
    var asked = [String]()
    var spiderEnded = false
    func add(_ vod: String) { asked.append(vod) }
    func endSpider() { spiderEnded = true }
}

@Test func aSpiderPastItsTimeoutIsNoLongerWaitedForAndEndsItsLane() async throws {
    let spiderSite = try site("spider"), cmsSite = try site("cms")
    func candidate(_ vod: String, _ site: Site, spider: Bool) -> FollowSchedule.Candidate {
        FollowSchedule.Candidate(follow: Follow(identity: FavoriteIdentity(configSourceID: "cfg", siteID: site.id, vodID: vod),
                                                vodName: "", vodPic: "", siteName: "", remarks: "",
                                                listing: listing(episodes(1...2))),
                                 site: site, isSpider: spider)
    }
    let calls = Calls()
    var checker = FollowChecker(activity: SiteActivity(),
                                conditions: { .init(playerOpen: false, onFollowScreen: false) }) { site, vod in
        await calls.add(vod)
        if site.key == "spider" {
            try? await Task.sleep(for: .seconds(5))
            await calls.endSpider()
        }
        return Vod(id: vod, name: "", picture: "", playFrom: "A", playURL: "第1集$a#第2集$b#第3集$c")
    }
    checker.timeout = .milliseconds(300)
    let found = await checker.run([candidate("s1", spiderSite, spider: true), candidate("s2", spiderSite, spider: true),
                                   candidate("c1", cmsSite, spider: false)], forced: false)
    // Not waited for: the round is over while the spider call is still running.
    #expect(!(await calls.spiderEnded))
    #expect(found.outcomes.count == 2)
    #expect(found.outcomes.values.contains(.failed))
    #expect(!(await calls.asked.contains("s2")))
    if case .listed(let listed, _, _)? = found.outcomes[FavoriteIdentity(configSourceID: "cfg", siteID: cmsSite.id, vodID: "c1")] {
        #expect(listed.count == 3)
    } else {
        Issue.record("the CMS follow was not listed")
    }
}

@Test func nothingIsAskedWhileThePlayerIsOpen() async throws {
    let cmsSite = try site("cms")
    let item = FollowSchedule.Candidate(follow: follow(episodes(1...2)), site: cmsSite, isSpider: false)
    let calls = Calls()
    let checker = FollowChecker(activity: SiteActivity(),
                                conditions: { .init(playerOpen: true, onFollowScreen: false) }) { _, vod in
        await calls.add(vod)
        return nil
    }
    #expect(await checker.run([item], forced: true).outcomes.isEmpty)
    #expect(await calls.asked.isEmpty)
}

// MARK: - A later season (方案 C)

private func named(_ name: String, vod: String = "v1") -> Follow {
    Follow(identity: FavoriteIdentity(configSourceID: "cfg", siteID: "site", vodID: vod), vodName: name, vodPic: "",
           siteName: "", remarks: "", listing: listing(episodes(1...2)), now: Date(timeIntervalSince1970: 0))
}

@Test func onlyASeriesWithASearchableNameLooksForLaterSeasons() {
    #expect(named("慶餘年 第一季").seasonKeyword == "慶餘年")
    #expect(named("慶餘年").seasonKeyword == "慶餘年")
    #expect(named("鬼滅之刃 劇場版").seasonKeyword == nil)
    #expect(named("家").seasonKeyword == nil)
    let item = named("慶餘年")
    #expect(item.seasonDue(now: Date(timeIntervalSince1970: 10)))
    let searched = item.searched([], now: Date(timeIntervalSince1970: 10))
    #expect(!searched.seasonDue(now: Date(timeIntervalSince1970: 10 + 3_600)))
    #expect(searched.seasonDue(now: Date(timeIntervalSince1970: 10 + Follow.seasonInterval)))
}

@Test func theHighestStrongLaterSeasonIsHintedAndOpeningItClearsIt() throws {
    let results = [Vod(id: "v1", name: "慶餘年", picture: ""),
                   Vod(id: "a", name: "庆余年2", picture: ""),
                   Vod(id: "b", name: "庆余年第二季", picture: ""),
                   Vod(id: "c", name: "庆余年 第三季", picture: ""),
                   Vod(id: "d", name: "庆余年第四季 特别篇", picture: ""),
                   Vod(id: "e", name: "庆余年之帝王业 第五季", picture: "")]
    let hinted = named("慶餘年").searched(results)
    #expect(hinted.newSeason == Follow.NewSeason(vodID: "c", name: "庆余年 第三季", season: 3))
    // A later search that misses it keeps the hint; a higher one replaces it.
    #expect(hinted.searched([]).newSeason?.vodID == "c")
    #expect(hinted.searched([Vod(id: "f", name: "慶餘年 第四季", picture: "")]).newSeason?.season == 4)
    #expect(hinted.seasonOpened(vodID: "b") == nil)
    #expect(try #require(hinted.seasonOpened(vodID: "c")).newSeason == nil)
}

@Test func aRemakeOlderThanTheFollowedTitleIsNoNewSeason() {
    let item = named("某劇 第一季(2020)")
    #expect(item.searched([Vod(id: "x", name: "某劇 第二季(2008)", picture: "")]).newSeason == nil)
    #expect(item.searched([Vod(id: "y", name: "某劇 第二季(2022)", picture: "")]).newSeason?.vodID == "y")
    #expect(named("某劇 第二季").searched([Vod(id: "z", name: "某劇 第二季", picture: "")]).newSeason == nil)
}

// W-332: the viewer followed 青蛙軍曹 of 2026 and was told of 青蛙軍曹 第七季 of 2010. Neither name carries a
// year; the sources' vod_year does, and an older later season is no new season.
@Test func aLaterSeasonOlderByTheSourcesYearIsNoNewSeason() {
    let item = Follow(identity: identity, vodName: "青蛙軍曹", vodPic: "", siteName: "", remarks: "", year: "2026",
                      listing: listing(episodes(1...2)))
    #expect(item.year == 2026)
    let older = Vod(id: "s7", name: "青蛙軍曹 第七季", picture: "", year: "2010")
    #expect(item.searched([older]).newSeason == nil)
    #expect(item.searched([Vod(id: "s2", name: "青蛙軍曹 第二季", picture: "", year: "2027")]).newSeason?.vodID == "s2")
    // A year on one side only decides nothing: the names do, as before.
    #expect(item.searched([Vod(id: "s3", name: "青蛙軍曹 第三季", picture: "")]).newSeason?.vodID == "s3")
    #expect(named("青蛙軍曹").searched([older]).newSeason?.vodID == "s7")
    #expect(Follow.year(in: "2010-2011") == 2010)
    #expect(Follow.year(in: "") == nil)
    #expect(Follow.year(in: "12345") == nil)
}

// W-332: a follow made before the fix has no year and may already hold the wrong hint. Its next detail
// gives the year, and the next search that lists the hint as older drops it.
@Test func aFollowLearnsItsYearAndDropsAnOlderHint() {
    let older = Vod(id: "s7", name: "青蛙軍曹 第七季", picture: "", year: "2010")
    let stale = named("青蛙軍曹").searched([older])
    #expect(stale.newSeason?.vodID == "s7")
    let learned = stale.updated(with: listing(episodes(1...2)), remarks: "", year: "2026")
    #expect(learned.year == 2026)
    #expect(learned.updated(with: listing(episodes(1...2)), remarks: "").year == 2026)
    #expect(learned.searched([older]).newSeason == nil)
    // One search that does not list it keeps it, as any kept hint.
    #expect(learned.searched([]).newSeason?.vodID == "s7")
}

@Test func aDueFollowIsSearchedOnItsOwnSiteAfterItsDetail() async throws {
    let cmsSite = try site("cms")
    let item = FollowSchedule.Candidate(follow: Follow(identity: FavoriteIdentity(configSourceID: "cfg", siteID: cmsSite.id, vodID: "v1"),
                                                       vodName: "慶餘年", vodPic: "", siteName: "", remarks: "",
                                                       listing: listing(episodes(1...2))),
                                        site: cmsSite, isSpider: false)
    let calls = Calls()
    let checker = FollowChecker(activity: SiteActivity(), conditions: { .init(playerOpen: false, onFollowScreen: false) },
                                search: { _, keyword in
                                    await calls.add("search:\(keyword)")
                                    return [Vod(id: "s2", name: "慶餘年 第二季", picture: "")]
                                }) { _, vod in
        await calls.add("detail:\(vod)")
        return nil
    }
    let report = await checker.run([item], forced: false)
    #expect(await calls.asked == ["detail:v1", "search:慶餘年"])
    #expect(report.seasons[item.follow.identity]?.first?.id == "s2")
    let searchedToday = FollowSchedule.Candidate(follow: item.follow.searched([]), site: cmsSite, isSpider: false)
    _ = await checker.run([searchedToday], forced: false)
    #expect(await calls.asked.count == 3)
}

/// Review N-6: a failed season search still counts as today's look.
@Test func aFailedSeasonSearchWaitsUntilTomorrow() async throws {
    let cmsSite = try site("cms")
    struct Down: Error {}
    let item = FollowSchedule.Candidate(follow: Follow(identity: FavoriteIdentity(configSourceID: "cfg", siteID: cmsSite.id, vodID: "v1"),
                                                       vodName: "慶餘年", vodPic: "", siteName: "", remarks: "",
                                                       listing: listing(episodes(1...2))),
                                        site: cmsSite, isSpider: false)
    let checker = FollowChecker(activity: SiteActivity(), conditions: { .init(playerOpen: false, onFollowScreen: false) },
                                search: { _, _ in throw Down() }) { _, _ in nil }
    let report = await checker.run([item], forced: false)
    let results = try #require(report.seasons[item.follow.identity])
    #expect(results.isEmpty)
    #expect(!item.follow.searched(results).seasonDue())
}
