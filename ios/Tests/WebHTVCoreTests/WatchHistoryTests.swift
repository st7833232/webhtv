import Foundation
import Testing
@testable import WebHTVCore

private func scratchStore(_ name: String) throws -> (WatchHistoryStore, URL) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("watch-history-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (WatchHistoryStore(directory: directory), directory)
}

private func record(_ vodId: String, siteKey: String = "s", siteID: String = "s\u{0}{}",
                    name: String = "片", flag: String = "線路①", episode: String = "01",
                    quality: String = "", position: Double = 60_000,
                    duration: Double = 1_200_000) -> WatchHistory {
    WatchHistory(key: WatchHistory.key(siteID: siteID, vodId: vodId),
                 siteKey: siteKey, siteName: "站", vodId: vodId,
                 vodName: name, vodPic: "https://a/p.jpg", vodFlag: flag,
                 vodRemarks: episode, episodeUrl: "https://a/\(vodId).m3u8",
                 quality: quality, position: position, duration: duration)
}

// MARK: - R1: the store round-trips, prunes and survives a bad file

@Test func aSavedRecordComesBackWithEverythingItWasGiven() async throws {
    let (store, _) = try scratchStore("roundtrip")
    await store.save(record("1", quality: "720P"))

    let all = await store.records()
    #expect(all.count == 1)
    let saved = try #require(all.first)
    #expect(saved.vodName == "片")
    #expect(saved.vodFlag == "線路①")
    #expect(saved.vodRemarks == "01")
    #expect(saved.quality == "720P")
    #expect(saved.position == 60_000)
    #expect(saved.createTime > 0)
    // A second store over the same directory reads what the first one wrote.
    #expect(await store.record(forKey: saved.key)?.quality == "720P")
}

@Test func savingTheSameTitleTwiceUpdatesItRatherThanAppending() async throws {
    let (store, _) = try scratchStore("upsert")
    await store.save(record("1", flag: "線路①", episode: "01", position: 30_000))
    await store.save(record("1", flag: "線路②", episode: "05", quality: "1080P", position: 90_000))

    let all = await store.records()
    #expect(all.count == 1)
    #expect(all.first?.vodFlag == "線路②")
    #expect(all.first?.vodRemarks == "05")
    #expect(all.first?.position == 90_000)
}

/// K2 and D6: the configuration carries four duplicate site keys, so the key has to be `Site.id`.
@Test func twoSitesSharingAKeyKeepSeparateRecords() async throws {
    let (store, _) = try scratchStore("dupes")
    await store.save(record("1", siteKey: "爱影", siteID: "爱影\u{0}{\"url\":\"a\"}", name: "A"))
    await store.save(record("1", siteKey: "爱影", siteID: "爱影\u{0}{\"url\":\"b\"}", name: "B"))

    let all = await store.records()
    #expect(all.count == 2)
    #expect(Set(all.map(\.vodName)) == ["A", "B"])
    // They collapse only on the way out, because Android's key has no room for the ext.
    #expect(Set(all.map(\.androidKey)) == ["爱影@@@1"])
}

/// `History.canSave()`: the app opens a record the moment playback starts, before any position.
@Test func aRecordWithNoPositionIsNotStored() async throws {
    let (store, _) = try scratchStore("nopos")
    await store.save(record("1", position: 0))
    #expect(await store.records().isEmpty)
}

@Test func recordsOlderThanSixtyDaysArePruned() async throws {
    let (store, _) = try scratchStore("age")
    let now = Date()
    await store.save(record("fresh"), now: now)
    await store.save(record("stale"), now: now.addingTimeInterval(-WatchHistoryStore.retention - 3600))

    let all = await store.records(now: now)
    #expect(all.map(\.vodId) == ["fresh"])
}

@Test func theListIsCappedAtFiveHundredNewestFirst() async throws {
    let (store, _) = try scratchStore("limit")
    let now = Date()
    for index in 0..<(WatchHistoryStore.limit + 20) {
        await store.save(record("v\(index)"), now: now.addingTimeInterval(Double(index)))
    }
    let all = await store.records(now: now.addingTimeInterval(Double(WatchHistoryStore.limit + 20)))
    #expect(all.count == WatchHistoryStore.limit)
    // Newest first, so the ones dropped are the oldest.
    #expect(all.first?.vodId == "v\(WatchHistoryStore.limit + 19)")
    #expect(!all.contains { $0.vodId == "v0" })
}

@Test func aCorruptFileCostsTheHistoryAndNothingElse() async throws {
    let (store, directory) = try scratchStore("corrupt")
    try Data("not json at all".utf8).write(to: directory.appendingPathComponent("history.json"))

    let fresh = WatchHistoryStore(directory: directory)
    #expect(await fresh.records().isEmpty)
    // And the next save replaces it wholesale rather than failing.
    await fresh.save(record("1"))
    #expect(await fresh.records().count == 1)
    #expect(await WatchHistoryStore(directory: directory).records().count == 1)
}

@Test func removingAndClearingTakeEffectOnDisk() async throws {
    let (store, directory) = try scratchStore("remove")
    await store.save(record("1"))
    await store.save(record("2"))
    await store.remove(key: WatchHistory.key(siteID: "s\u{0}{}", vodId: "1"))
    #expect(await WatchHistoryStore(directory: directory).records().map(\.vodId) == ["2"])

    await store.clear()
    #expect(await WatchHistoryStore(directory: directory).records().isEmpty)
}

@Test func concurrentSavesAllLand() async throws {
    let (store, directory) = try scratchStore("concurrent")
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<40 {
            group.addTask { await store.save(record("v\(index)")) }
        }
    }
    #expect(await WatchHistoryStore(directory: directory).records().count == 40)
}

// MARK: - R3: where playback resumes to (D4), on Android's own near-end formula (D12)

@Test func resumeSkipsTheFirstTenSecondsAndTheLastStretch() {
    // Under ten seconds is not a place worth resuming to.
    #expect(record("1", position: 9_000, duration: 1_200_000).resumePosition == nil)
    #expect(record("1", position: 10_001, duration: 1_200_000).resumePosition == 10_001)
    // Watched to the end: replay from the start rather than open on the closing seconds.
    #expect(record("1", position: 1_199_000, duration: 1_200_000).resumePosition == nil)
}

/// `History.isNearEnding()`: one percent of the runtime, clamped between 5 and 30 seconds.
@Test func theNearEndingWindowIsOnePercentClampedToFiveAndThirtySeconds() {
    // 20 minutes → 12 s window.
    #expect(record("1", position: 1_200_000 - 11_000, duration: 1_200_000).isNearEnding)
    #expect(!record("1", position: 1_200_000 - 13_000, duration: 1_200_000).isNearEnding)
    // 3 hours → clamped to 30 s, not 108 s.
    let long: Double = 3 * 3_600_000
    #expect(record("1", position: long - 29_000, duration: long).isNearEnding)
    #expect(!record("1", position: long - 31_000, duration: long).isNearEnding)
    // 2 minutes → clamped up to 5 s, not 1.2 s.
    #expect(record("1", position: 120_000 - 4_000, duration: 120_000).isNearEnding)
    #expect(!record("1", position: 120_000 - 6_000, duration: 120_000).isNearEnding)
    // No duration yet, or nothing watched: not a verdict either way.
    #expect(!record("1", position: 5_000, duration: 0).isNearEnding)
    #expect(!record("1", position: 0, duration: 1_000).isNearEnding)
}

// MARK: - R6: the remembered quality outranks the default

@Test func aRememberedQualityDecidesWhereTheMenuOpens() async throws {
    let (store, _) = try scratchStore("quality")
    await store.save(record("1", quality: "720P"))

    let menu = ["360P", "720P", "1080P"].enumerated().map {
        PlaybackQuality(name: $1, url: URL(string: "https://a/\($0).m3u8")!)
    }
    let remembered = await store.record(forKey: WatchHistory.key(siteID: "s\u{0}{}", vodId: "1"))?.quality
    #expect(PlaybackQuality.defaultIndex(in: menu, preferred: remembered) == 1)
    // Nothing remembered falls back to the highest, which is what a first viewing gets.
    #expect(PlaybackQuality.defaultIndex(in: menu, preferred: nil) == 2)
}

// MARK: - R5: the payload `app.history` hands a page

@Test func theHistoryPayloadCarriesEveryFieldAndroidDeclares() throws {
    let text = WebHomeBridge.historyText([record("101", quality: "1080P", position: 42_000)])
    let items = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
    let item = try #require(items.first)

    // `History.java`'s @SerializedName set, all seventeen of them.
    #expect(Set(item.keys) == ["key", "vodPic", "wallPic", "vodName", "vodFlag", "vodRemarks",
                               "episodeUrl", "revSort", "revPlay", "createTime", "opening", "ending",
                               "position", "duration", "speed", "scale", "cid"])
    // `getSiteKey()` / `getVodId()` split this on @@@, so it must not be the internal key.
    #expect(item["key"] as? String == "s@@@101")
    #expect(item["vodName"] as? String == "片")
    #expect(item["vodFlag"] as? String == "線路①")
    #expect(item["vodRemarks"] as? String == "01")
    #expect(item["position"] as? Double == 42_000)
    #expect(item["duration"] as? Double == 1_200_000)
    // Android's own defaults for the two fields it initialises non-zero.
    #expect(item["speed"] as? Double == 1)
    #expect(item["scale"] as? Int == -1)
    // The fields iOS cannot fill are present and falsy rather than absent.
    #expect(item["wallPic"] as? String == "")
    #expect(item["revSort"] as? Bool == false)
    #expect(item["revPlay"] as? Bool == false)
    // Unset stays zero, which is what a page written against Android's `C.TIME_UNSET` already
    // reads as unset. `openingAndEndingReachAppHistory` below covers the set case.
    #expect(item["opening"] as? Double == 0)
    #expect(item["ending"] as? Double == 0)
    #expect(item["cid"] as? Int == 0)
    // `quality` has no Android counterpart and must not leak into a reproduction of its payload.
    #expect(item["quality"] == nil)

    #expect(WebHomeBridge.historyText([]) == "[]")
}

/// IOS-POC-10E: history is bound to the configuration it was watched on, without discarding what
/// was recorded before the field existed.
@Suite struct WatchHistorySourceBindingTests {
    private func record(key: String, sourceID: String?) -> WatchHistory {
        WatchHistory(key: key, siteKey: "s", sourceID: sourceID, vodId: "v", createTime: 1)
    }

    @Test func aRecordWrittenBeforeThisFieldStillDecodes() throws {
        // Exactly the shape already on people's phones: no sourceID at all. A non-optional field
        // would throw here, and the store treats a throw as "no history".
        let legacy = #"{"key":"k","siteKey":"s","siteName":"","vodId":"v","vodName":"","vodPic":"","vodFlag":"","vodRemarks":"","episodeUrl":"","quality":"","position":0,"duration":0,"createTime":1}"#
        let decoded = try JSONDecoder().decode(WatchHistory.self, from: Data(legacy.utf8))
        #expect(decoded.sourceID == nil)
        #expect(decoded.key == "k")
    }

    @Test func theFieldRoundTripsWhenItIsThere() throws {
        let one = record(key: "k", sourceID: "https://a.example/c.json")
        let data = try JSONEncoder().encode(one)
        #expect(try JSONDecoder().decode(WatchHistory.self, from: data).sourceID == "https://a.example/c.json")
    }
}

// MARK: - IOS-POC-5S-2: the opening and the ending

/// The viewer's own millisecond offsets, ported from `History.opening` / `History.ending` and the
/// four places `VideoActivity` and `PlayerManager` consume them. Nothing here comes from the
/// configuration: IOS-POC-5S measured `ads` and `rules` and neither carries an intro or an outro.
@Suite struct WatchHistoryOpeningEndingTests {
    private func watched(opening: Double? = nil, ending: Double? = nil,
                         position: Double = 60_000, duration: Double = 2_400_000) -> WatchHistory {
        WatchHistory(key: "k", siteKey: "s", vodId: "v",
                     position: position, duration: duration, opening: opening, ending: ending)
    }

    // MARK: Migration

    @Test func aHistoryFileWrittenBeforeTheseFieldsStillDecodes() throws {
        // Byte for byte the shape already on people's phones. The synthesized `Codable` throws
        // `keyNotFound` on a missing non-optional, and `WatchHistoryStore` reads a throw as "no
        // history at all" — so this assertion is the difference between adding two fields and
        // deleting somebody's viewing record.
        let legacy = #"{"key":"k","siteKey":"s","siteName":"","vodId":"v","vodName":"","vodPic":"","vodFlag":"","vodRemarks":"","episodeUrl":"","quality":"","position":44292,"duration":2796399,"createTime":1}"#
        let decoded = try JSONDecoder().decode(WatchHistory.self, from: Data(legacy.utf8))
        #expect(decoded.opening == nil)
        #expect(decoded.ending == nil)
        #expect(decoded.openingOffset == 0)
        #expect(decoded.endingOffset == 0)
        // Everything the record already carried survives untouched.
        #expect(decoded.position == 44292)
        #expect(decoded.duration == 2796399)
    }

    @Test func aWholeLegacyListStillDecodes() throws {
        // The store decodes `[WatchHistory]`, not one record, and one throw loses the whole file.
        let legacy = #"[{"key":"a","siteKey":"s","siteName":"","vodId":"1","vodName":"","vodPic":"","vodFlag":"","vodRemarks":"","episodeUrl":"","quality":"","position":1,"duration":2,"createTime":1},{"key":"b","siteKey":"s","siteName":"","vodId":"2","vodName":"","vodPic":"","vodFlag":"","vodRemarks":"","episodeUrl":"","quality":"","position":3,"duration":4,"createTime":2}]"#
        let decoded = try JSONDecoder().decode([WatchHistory].self, from: Data(legacy.utf8))
        #expect(decoded.count == 2)
        #expect(decoded.allSatisfy { $0.opening == nil && $0.ending == nil })
    }

    @Test func bothFieldsRoundTripThroughTheStore() async throws {
        let (store, _) = try scratchStore("op-ed")
        await store.save(watched(opening: 91_000, ending: 45_000))

        let saved = try #require(await store.record(forKey: "k"))
        #expect(saved.opening == 91_000)
        #expect(saved.ending == 45_000)
        #expect(saved.openingOffset == 91_000)
        #expect(saved.endingOffset == 45_000)
    }

    // MARK: The start position — `VideoActivity.setPosition()`

    @Test func theOpeningWinsWhenItIsPastWhereTheViewerStopped() {
        // `max(getOpening(), getPosition())`. Watched 60 s in, opening marked at 91 s.
        #expect(watched(opening: 91_000, position: 60_000).startPosition() == 91_000)
    }

    @Test func whereTheViewerStoppedWinsWhenItIsPastTheOpening() {
        #expect(watched(opening: 91_000, position: 600_000).startPosition() == 600_000)
    }

    @Test func anUnsetOpeningChangesNothingAboutResuming() {
        let record = watched(position: 600_000)
        #expect(record.startPosition() == record.resumePosition)
        #expect(record.startPosition() == 600_000)
        // And under D4's ten-second floor the answer is still "from the beginning".
        #expect(watched(position: 4_000).startPosition() == 0)
        #expect(watched(position: 4_000).resumePosition == nil)
    }

    @Test func aNegativeOrNonFiniteOpeningIsIgnoredRatherThanSeekedTo() {
        #expect(watched(opening: -5_000, position: 600_000).startPosition() == 600_000)
        #expect(watched(opening: .nan, position: 4_000).startPosition() == 0)
        #expect(watched(opening: .infinity, position: 4_000).startPosition() == 0)
    }

    @Test func theNextEpisodeTakesTheOpeningButNotThePreviousEpisodePosition() {
        // IOS-POC-14: one record covers a whole title, so an auto-advance must not resume into the
        // new episode — but the opening belongs to the title and still applies.
        let record = watched(opening: 91_000, position: 600_000)
        #expect(record.startPosition(resuming: false) == 91_000)
        #expect(watched(position: 600_000).startPosition(resuming: false) == 0)
    }

    @Test func aTitleWatchedToTheEndReplaysFromItsOpening() {
        // `isNearEnding` kills the resume; the opening is all that is left, exactly as Android's
        // `setPosition` computes it after `resetPlaybackPosition`.
        let record = watched(opening: 91_000, position: 2_395_000, duration: 2_400_000)
        #expect(record.isNearEnding)
        #expect(record.resumePosition == nil)
        #expect(record.startPosition() == 91_000)
    }

    // MARK: The ending — `VideoActivity.onTimeChanged()`

    @Test func theEndingFiresOnAndroidsOwnFormula() {
        // `ending + position >= duration`: 45 s of ending on a 40-minute episode means 39:15.
        let record = watched(ending: 45_000, duration: 2_400_000)
        #expect(record.hasReachedEnding(position: 2_354_000, duration: 2_400_000) == false)
        #expect(record.hasReachedEnding(position: 2_355_000, duration: 2_400_000))
        #expect(record.hasReachedEnding(position: 2_399_000, duration: 2_400_000))
    }

    @Test func anUnsetEndingNeverFires() {
        #expect(watched().hasReachedEnding(position: 2_399_999, duration: 2_400_000) == false)
        #expect(watched(ending: 0).hasReachedEnding(position: 2_399_999, duration: 2_400_000) == false)
        #expect(watched(ending: -45_000).hasReachedEnding(position: 2_399_999, duration: 2_400_000) == false)
    }

    @Test func anUnknownDurationNeverFires() {
        // A live stream reports no runtime, and `PlaybackSession.milliseconds` answers 0 for a
        // non-finite `CMTime`. Without an end there is nothing to measure the ending back from.
        let record = watched(ending: 45_000)
        #expect(record.hasReachedEnding(position: 600_000, duration: 0) == false)
        #expect(record.hasReachedEnding(position: 600_000, duration: -1) == false)
        #expect(record.hasReachedEnding(position: 0, duration: 0) == false)
    }

    // MARK: Marking — `PlayerManager.canSetOpening` / `canSetEnding`, `Constant.getOpEdLimit`

    @Test func theMarkableWindowFollowsTheRuntime() {
        #expect(WatchHistory.openingEndingLimit(duration: 10 * 60_000) == 3 * 60_000)
        #expect(WatchHistory.openingEndingLimit(duration: 20 * 60_000) == 6 * 60_000)
        #expect(WatchHistory.openingEndingLimit(duration: 40 * 60_000) == 10 * 60_000)

        // A 40-minute episode: an opening may be marked in the first ten minutes, and an ending in
        // the last ten.
        #expect(WatchHistory.canSetOpening(position: 91_000, duration: 2_400_000))
        #expect(WatchHistory.canSetOpening(position: 1_200_000, duration: 2_400_000) == false)
        #expect(WatchHistory.canSetEnding(position: 2_355_000, duration: 2_400_000))
        #expect(WatchHistory.canSetEnding(position: 1_200_000, duration: 2_400_000) == false)
        // Nothing is markable before playback has a position or a runtime.
        #expect(WatchHistory.canSetOpening(position: 0, duration: 2_400_000) == false)
        #expect(WatchHistory.canSetEnding(position: 91_000, duration: 0) == false)
    }

    // MARK: Clamping

    @Test func anOpeningCannotBeMarkedPastTheEnd() {
        // Android floors at zero and never caps, so holding its remote's up key walks the opening
        // past the runtime and `setPosition` then seeks beyond the end.
        var record = watched(duration: 2_400_000)
        record.setOpening(9_999_000, duration: 2_400_000)
        #expect(record.openingOffset == 2_400_000)
        #expect(record.startPosition() == 2_400_000)
    }

    @Test func anEndingCannotEatTheOpening() {
        // `duration - ending` must stay above the opening, or the episode would skip the instant it
        // started.
        var record = watched(opening: 91_000, duration: 2_400_000)
        record.setEnding(9_999_000, duration: 2_400_000)
        #expect(record.endingOffset == 2_400_000 - 91_000)
        #expect(record.hasReachedEnding(position: 91_000, duration: 2_400_000))
        #expect(record.hasReachedEnding(position: 90_999, duration: 2_400_000) == false)
    }

    @Test func anOpeningCannotBeMarkedInsideTheEnding() {
        var record = watched(ending: 45_000, duration: 2_400_000)
        record.setOpening(2_400_000, duration: 2_400_000)
        #expect(record.openingOffset == 2_400_000 - 45_000)
    }

    @Test func bothClampAtZeroTheWayAndroidsResetDoes() {
        // `max(0, max(0, opening) - 1000)` from the last second, and the reset button's plain 0.
        var record = watched(opening: 500, ending: 500, duration: 2_400_000)
        record.setOpening(record.openingOffset - 1000, duration: 2_400_000)
        record.setEnding(record.endingOffset - 1000, duration: 2_400_000)
        #expect(record.openingOffset == 0)
        #expect(record.endingOffset == 0)
        #expect(record.startPosition(resuming: false) == 0)
        #expect(record.hasReachedEnding(position: 2_399_999, duration: 2_400_000) == false)
    }

    @Test func anUnknownRuntimeClampsOnlyAtZero() {
        // The runtime is not known while the item is still loading, and refusing the edit outright
        // would lose it. The ceiling arrives with the duration on the next write.
        var record = watched(duration: 0)
        record.setOpening(91_000, duration: 0)
        record.setEnding(-1, duration: 0)
        #expect(record.openingOffset == 91_000)
        #expect(record.endingOffset == 0)
    }

    @Test func aNonFiniteEditIsRefusedRatherThanStored() {
        var record = watched(duration: 2_400_000)
        record.setOpening(.nan, duration: 2_400_000)
        record.setEnding(.infinity, duration: .nan)
        #expect(record.openingOffset == 0)
        #expect(record.endingOffset == 0)
    }

    // MARK: Nothing crosses a title, an episode or a source

    @Test func theSettingsBelongToOneRecordAndDoNotCrossToAnother() async throws {
        // `WatchHistory.key` is `Site.id` plus vod, so two titles, two providers of the same title,
        // or the same title on two configurations are different records — and the store is keyed on
        // exactly that. A second title must read its own zero, not the first one's 91 s.
        let (store, _) = try scratchStore("op-ed-isolation")
        await store.save(WatchHistory(key: WatchHistory.key(siteID: "siteA", vodId: "1"),
                                      siteKey: "a", sourceID: "configA", vodId: "1",
                                      position: 60_000, duration: 2_400_000,
                                      opening: 91_000, ending: 45_000))
        await store.save(WatchHistory(key: WatchHistory.key(siteID: "siteB", vodId: "1"),
                                      siteKey: "b", sourceID: "configB", vodId: "1",
                                      position: 60_000, duration: 2_400_000))

        let first = try #require(await store.record(forKey: WatchHistory.key(siteID: "siteA", vodId: "1")))
        let second = try #require(await store.record(forKey: WatchHistory.key(siteID: "siteB", vodId: "1")))
        #expect(first.openingOffset == 91_000)
        #expect(first.endingOffset == 45_000)
        #expect(second.openingOffset == 0)
        #expect(second.endingOffset == 0)
        #expect(second.startPosition(resuming: false) == 0)
    }

    @Test func oneRecordCoversEveryEpisodeAndLineOfItsTitle() async throws {
        // Switching episode or line inside a title keeps the key, so the setting follows the viewer
        // from 第1集 to 第2集 — the Android behaviour, and the reason the record is not keyed on the
        // episode. The upsert that records 第2集 must not drop what 第1集 set.
        let (store, _) = try scratchStore("op-ed-episodes")
        let key = WatchHistory.key(siteID: "siteA", vodId: "1")
        await store.save(WatchHistory(key: key, siteKey: "a", vodId: "1", vodFlag: "普快线路",
                                      vodRemarks: "01", position: 60_000, duration: 2_400_000,
                                      opening: 91_000, ending: 45_000))

        // What the detail screen would hand over for the next episode: the same key, a fresh
        // template with neither field set.
        var next = WatchHistory(key: key, siteKey: "a", vodId: "1", vodFlag: "极速线路",
                                vodRemarks: "02", position: 7_000, duration: 2_400_000)
        let stored = try #require(await store.record(forKey: key))
        next.opening = stored.opening
        next.ending = stored.ending
        await store.save(next)

        let after = try #require(await store.record(forKey: key))
        #expect(after.vodRemarks == "02")
        #expect(after.vodFlag == "极速线路")
        #expect(after.openingOffset == 91_000)
        #expect(after.endingOffset == 45_000)
    }

    // MARK: The payload

    @Test func openingAndEndingReachAppHistory() throws {
        // Android declares both fields, so filling them in is completing its payload rather than
        // extending it with something iOS invented.
        let text = WebHomeBridge.historyText([watched(opening: 91_000, ending: 45_000)])
        let items = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        let item = try #require(items.first)
        #expect(item["opening"] as? Double == 91_000)
        #expect(item["ending"] as? Double == 45_000)
        // A value that was never set reads zero rather than a negative sentinel.
        let bare = WebHomeBridge.historyText([watched(opening: -1)])
        let bareItems = try #require(try JSONSerialization.jsonObject(with: Data(bare.utf8)) as? [[String: Any]])
        #expect(bareItems.first?["opening"] as? Double == 0)
    }
}
