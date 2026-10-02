import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-41B: Android's `SiteHealthStore` score and colours, worked by hand from its formula, plus
// the listing weight iOS adds. `docs/IOS-POC-41-source-health-diagnostics.md`.

private func health(_ events: [(SiteHealth.Event, Bool)]) -> SiteHealth {
    var health = SiteHealth()
    for (index, event) in events.enumerated() { health.record(event.0, succeeded: event.1, at: Double(index + 1)) }
    return health
}

private func site(_ key: String) throws -> Site {
    try JSONDecoder().decode(Site.self, from: Data(#"{"key":"\#(key)","name":"\#(key)","type":3,"api":"csp_XBPQ"}"#.utf8))
}

@Test func scoresAndColoursAsAndroidDoes() {
    #expect(SiteHealth().status == .unknown && SiteHealth().score == 0)
    // A search that answered nothing in a second: 60·1/5 − 1. Android's yellow, which is all a dead
    // spider site ever got there.
    let emptySearch = health([(.search(count: 0, milliseconds: 1000), true)])
    #expect(emptySearch.score == 11 && emptySearch.status == .warn)
    // One played episode: 60·5/9 + 18.
    let played = health([(.play, true)])
    #expect(abs(played.score - (300.0 / 9 + 18)) < 1e-9 && played.status == .good)
    // A detail at 1.5 s: 60·2/6 − 1, just short of green.
    #expect(health([(.detail(milliseconds: 1500), true)]).score == 19)
    // Three failed plays, the last one most recent.
    let failing = health([(.play, false), (.play, false), (.play, false)])
    #expect(failing.status == .bad && failing.score < 0)
    // A success after failures is green again, as Android's last-play rule makes it.
    #expect(health([(.play, false), (.play, false), (.play, false), (.play, true)]).status == .good)
}

@Test func aListingThatFailedIsRed() {
    // The iOS addition: 60·(0 − 2)/(2 + 4) = −20, Android's red threshold. A site that is dead at its
    // first page is red from the first visit instead of never being recorded.
    let dead = health([(.browse, false)])
    #expect(dead.score == -20 && dead.status == .bad)
    // One listing that came back: 60·2/6 = 20, green — the site is alive, as a quick detail is.
    #expect(health([(.browse, true)]).status == .good)
}

@Test func ordersHealthiestFirstAndKeepsTheConfigurationOrderOtherwise() throws {
    let sites = try ["a", "b", "c", "d"].map(site)
    #expect(SiteHealth.ordered(sites, by: [:]).map(\.key) == ["a", "b", "c", "d"])
    let recorded = [sites[0].id: health([(.browse, false)]), sites[3].id: health([(.play, true)])]
    // d played, b and c are unrecorded at 0 in their own order, a failed.
    #expect(SiteHealth.ordered(sites, by: recorded).map(\.key) == ["d", "b", "c", "a"])
}

@Test func keepsEachConfigurationApartAndForgetsAfterNinetyDays() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    let store = SiteHealthStore(directory: directory)
    await store.record(.play, succeeded: true, siteID: "a", source: "one", now: now)
    await store.record(.browse, succeeded: false, siteID: "a", source: "two", now: now)
    await store.record(.browse, succeeded: false, siteID: "old", source: "one", now: now.addingTimeInterval(-91 * 24 * 3600))
    #expect(await store.health(in: "one")["a"]?.status == .good)
    #expect(await store.health(in: "two")["a"]?.status == .bad)

    await store.save(now: now)
    let reopened = SiteHealthStore(directory: directory)
    #expect(await reopened.health(in: "one").keys.sorted() == ["a"])

    await reopened.clear()
    #expect(await reopened.health(in: "one").isEmpty)
    #expect(await SiteHealthStore(directory: directory).health(in: "two").isEmpty)
}
