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
    #expect(item["opening"] as? Int == 0)
    #expect(item["ending"] as? Int == 0)
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
