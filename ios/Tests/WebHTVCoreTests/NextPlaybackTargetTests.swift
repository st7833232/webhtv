import Foundation
import Testing
@testable import WebHTVCore

// MARK: - Builders

private func identity(flag: String = "普快线路",
                      episode: String = "https://example.test/ep2",
                      quality: String = "",
                      site: String = "爱瓜TV\u{0}{\"url\":\"a\"}",
                      vod: String = "194093",
                      config: String = "https://example.test/wang-movie.json")
    -> PlaybackTargetIdentity {
    PlaybackTargetIdentity(configID: config, siteID: site, vodId: vod,
                           flag: flag, episodeURL: episode, quality: quality)
}

private func target(_ address: String = "https://cdn.test/ep2/index.m3u8",
                    headers: [String: String] = [
                        "Referer": "https://www.bilibili.com",
                        "User-Agent": "Mozilla/5.0"
                    ]) -> PlaybackTarget {
    PlaybackTarget(url: URL(string: address)!, headers: headers)
}

private func resolved(_ id: PlaybackTargetIdentity, at moment: Date,
                      address: String = "https://cdn.test/ep2/index.m3u8",
                      headers: [String: String] = [
                          "Referer": "https://www.bilibili.com",
                          "User-Agent": "Mozilla/5.0"
                      ]) -> NextPlaybackTarget {
    NextPlaybackTarget(identity: id, target: target(address, headers: headers),
                       episodeName: "02", resolvedAt: moment)
}

// MARK: - The happy path

@Test func aPrefetchedEpisodeIsHandedBackToTheAutoAdvanceThatAskedForIt() {
    let now = Date()
    let wanted = identity()
    var prefetch = PlaybackTargetPrefetch()

    let claimed = prefetch.beginResolving(for: wanted)
    #expect(claimed)
    prefetch.store(resolved(wanted, at: now))

    let taken = prefetch.take(matching: wanted, now: now.addingTimeInterval(80))
    #expect(taken?.target.url.absoluteString == "https://cdn.test/ep2/index.m3u8")
    #expect(taken?.episodeName == "02")
}

@Test func theRequestHeadersSurviveTheRoundTrip() {
    // A prefetch that dropped these would turn a working bilibili line into a 403 on exactly the
    // episodes it was meant to speed up (IOS-POC-5P).
    let now = Date()
    let wanted = identity()
    var prefetch = PlaybackTargetPrefetch()
    _ = prefetch.beginResolving(for: wanted)
    prefetch.store(resolved(wanted, at: now))

    let taken = prefetch.take(matching: wanted, now: now)

    #expect(taken?.target.headers["Referer"] == "https://www.bilibili.com")
    #expect(taken?.target.headers["User-Agent"] == "Mozilla/5.0")
}

// MARK: - Exactly one

@Test func onlyOneEpisodeIsHeldAtATime() {
    let now = Date()
    let first = identity(episode: "https://example.test/ep2")
    var prefetch = PlaybackTargetPrefetch()

    let claimed = prefetch.beginResolving(for: first)
    let claimedAgain = prefetch.beginResolving(for: first)
    #expect(claimed)
    #expect(!claimedAgain, "already on its way")

    prefetch.store(resolved(first, at: now))
    #expect(prefetch.isHolding)
    let claimedWhileHeld = prefetch.beginResolving(for: first)
    #expect(!claimedWhileHeld, "already held")
}

@Test func takingConsumesTheTargetSoItCannotBeOpenedTwice() {
    let now = Date()
    let wanted = identity()
    var prefetch = PlaybackTargetPrefetch()
    _ = prefetch.beginResolving(for: wanted)
    prefetch.store(resolved(wanted, at: now))

    #expect(prefetch.take(matching: wanted, now: now) != nil)
    #expect(prefetch.take(matching: wanted, now: now) == nil)
    #expect(!prefetch.isHolding)
}

// MARK: - Invalidation

@Test func everyIdentityChangeInvalidatesWhatWasResolvedForEpisodeB() {
    // A is playing and B was resolved ahead. Each of these is a different next episode, so B is
    // wrong and must not be opened.
    let now = Date()
    let forB = identity(episode: "https://example.test/ep2")
    let changes: [(String, PlaybackTargetIdentity)] = [
        ("a different episode — the viewer jumped to C",
         identity(episode: "https://example.test/ep3")),
        ("a different line", identity(flag: "高速线路")),
        ("a different quality", identity(quality: "1080P 蓝光")),
        ("a different site", identity(site: "other\u{0}{}")),
        ("a different title", identity(vod: "999999")),
        ("a different configuration", identity(config: "https://other.test/config.json"))
    ]

    for (reason, wanted) in changes {
        var prefetch = PlaybackTargetPrefetch()
        _ = prefetch.beginResolving(for: forB)
        prefetch.store(resolved(forB, at: now))

        #expect(prefetch.take(matching: wanted, now: now) == nil, "B survived \(reason)")
    }
}

@Test func aMismatchIsConsumedRatherThanLeftForLater() {
    let now = Date()
    let forB = identity(episode: "https://example.test/ep2")
    var prefetch = PlaybackTargetPrefetch()
    _ = prefetch.beginResolving(for: forB)
    prefetch.store(resolved(forB, at: now))

    _ = prefetch.take(matching: identity(episode: "https://example.test/ep3"), now: now)

    #expect(!prefetch.isHolding, "a target for an episode we are not about to play is simply wrong")
    #expect(prefetch.take(matching: forB, now: now) == nil)
}

@Test func beginningToResolveSomethingElseDropsWhatWasHeld() {
    let now = Date()
    let forB = identity(episode: "https://example.test/ep2")
    let forC = identity(episode: "https://example.test/ep3")
    var prefetch = PlaybackTargetPrefetch()
    _ = prefetch.beginResolving(for: forB)
    prefetch.store(resolved(forB, at: now))

    let claimedByC = prefetch.beginResolving(for: forC)
    #expect(claimedByC, "a new identity is allowed to claim the slot")
    #expect(prefetch.take(matching: forB, now: now) == nil)
}

@Test func aResultThatArrivesAfterTheViewerMovedIsDropped() {
    let now = Date()
    let forB = identity(episode: "https://example.test/ep2")
    var prefetch = PlaybackTargetPrefetch()
    _ = prefetch.beginResolving(for: forB)

    // The viewer closes the picker, or switches line, while the request is still in flight.
    prefetch.invalidate()
    prefetch.store(resolved(forB, at: now))

    #expect(!prefetch.isHolding)
    #expect(prefetch.take(matching: forB, now: now) == nil)
}

@Test func invalidateClearsBothTheHeldTargetAndTheOneInFlight() {
    let now = Date()
    let wanted = identity()
    var prefetch = PlaybackTargetPrefetch()
    _ = prefetch.beginResolving(for: wanted)
    prefetch.store(resolved(wanted, at: now))
    prefetch.invalidate()

    #expect(!prefetch.isHolding)
    #expect(prefetch.take(matching: wanted, now: now) == nil)
}

// MARK: - Freshness

@Test func anExpiredTargetIsRefusedRatherThanOpened() {
    let now = Date()
    let wanted = identity()
    var prefetch = PlaybackTargetPrefetch()
    _ = prefetch.beginResolving(for: wanted)
    prefetch.store(resolved(wanted, at: now))

    let late = now.addingTimeInterval(PlaybackTargetPrefetch.maximumAge + 1)
    #expect(prefetch.take(matching: wanted, now: late) == nil,
            "a source that meant its address to be short-lived must not be opened stale")
}

@Test func aTargetInsideItsWindowIsStillGood() {
    let now = Date()
    let wanted = identity()
    var prefetch = PlaybackTargetPrefetch()
    _ = prefetch.beginResolving(for: wanted)
    prefetch.store(resolved(wanted, at: now))

    let inTime = now.addingTimeInterval(PlaybackTargetPrefetch.maximumAge - 1)
    #expect(prefetch.take(matching: wanted, now: inTime) != nil)
}

@Test func theFreshnessWindowComfortablyCoversTheLeadTheGateAllows() {
    // The gate is what keeps the exposure short; the ceiling only catches a long pause.
    #expect(PlaybackTargetPrefetch.maximumAge > PlaybackPrefetchGate.leadSeconds)
}

@Test func aClockThatWentBackwardsIsNotTreatedAsFresh() {
    let now = Date()
    let wanted = identity()
    var prefetch = PlaybackTargetPrefetch()
    _ = prefetch.beginResolving(for: wanted)
    prefetch.store(resolved(wanted, at: now))

    #expect(prefetch.take(matching: wanted, now: now.addingTimeInterval(-60)) == nil)
}

// MARK: - Failure is a miss, not a fault

@Test func aFailedPrefetchLeavesNothingBehindAndCanBeRetried() {
    let wanted = identity()
    var prefetch = PlaybackTargetPrefetch()
    _ = prefetch.beginResolving(for: wanted)

    prefetch.failed()

    #expect(!prefetch.isHolding)
    #expect(prefetch.take(matching: wanted) == nil,
            "the auto-advance falls back to resolving normally")
    let reclaimed = prefetch.beginResolving(for: wanted)
    #expect(reclaimed, "and the slot is free again")
}

@Test func anEmptyStoreSimplyAnswersNothing() {
    var prefetch = PlaybackTargetPrefetch()

    #expect(!prefetch.isHolding)
    #expect(prefetch.take(matching: identity()) == nil)
}

// MARK: - IOS-POC-15D: why a handoff missed

@Test func aMissSaysWhyItMissed() {
    let now = Date()
    let wanted = identity()
    var store = PlaybackTargetPrefetch()
    #expect(store.miss(for: wanted, now: now) == .notRequested)

    let claimed = store.beginResolving(for: wanted)
    #expect(claimed)
    #expect(store.miss(for: wanted, now: now) == .stillResolving)
    #expect(store.miss(for: identity(episode: "https://example.test/ep3"), now: now) == .identityChanged)

    store.failed()
    #expect(store.miss(for: wanted, now: now) == .failed)

    let reclaimed = store.beginResolving(for: wanted)
    #expect(reclaimed)
    store.store(resolved(wanted, at: now))
    #expect(store.miss(for: wanted, now: now) == nil, "a hit")
    #expect(store.miss(for: identity(quality: "1080P"), now: now) == .identityChanged)
    #expect(store.miss(for: wanted, now: now.addingTimeInterval(PlaybackTargetPrefetch.maximumAge + 1))
            == .expired)

    // Asking does not consume: the hit is still there to take.
    let taken = store.take(matching: wanted, now: now)
    #expect(taken != nil)
    #expect(store.miss(for: wanted, now: now) == .notRequested)
}
