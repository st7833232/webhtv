import Foundation
import Testing
@testable import WebHTVCore

// W-317 (`docs/W-317-ios-site-order.md`): the sites the viewer dragged come first in their order; the rest
// follow by health or in configuration order; a new site joins the rest, a removed one is dropped.

private func site(_ key: String) throws -> Site {
    try JSONDecoder().decode(Site.self, from: Data(#"{"key":"\#(key)","name":"\#(key)","type":1,"api":"https://e/\#(key)"}"#.utf8))
}

private func keys(_ sites: [Site]) -> [String] { sites.map(\.key) }

@Test func pinnedSitesComeFirstAndTheRestKeepTheirOrder() throws {
    let a = try site("a"), b = try site("b"), c = try site("c"), d = try site("d")
    #expect(keys(SiteOrder.apply([a, b, c, d], pinned: [], health: nil)) == ["a", "b", "c", "d"])
    #expect(keys(SiteOrder.apply([a, b, c, d], pinned: [d.id, b.id], health: nil)) == ["d", "b", "a", "c"])
    // A site the configuration dropped is skipped; one it added lands among the rest.
    let gone = try site("gone"), new = try site("new")
    #expect(keys(SiteOrder.apply([a, b, new], pinned: [gone.id, b.id], health: nil)) == ["b", "a", "new"])
}

@Test func healthMovesOnlyTheSitesNotPinned() throws {
    let a = try site("a"), b = try site("b"), c = try site("c"), d = try site("d")
    var good = SiteHealth(), bad = SiteHealth()
    good.record(.search(count: 10, milliseconds: 500), succeeded: true, at: 1)
    bad.record(.search(count: 0, milliseconds: 30000), succeeded: false, at: 1)
    // c is pinned though it is failing; among the rest the healthy d goes before a and b.
    let health = [c.id: bad, d.id: good, a.id: bad]
    #expect(keys(SiteOrder.apply([a, b, c, d], pinned: [c.id], health: health)) == ["c", "d", "b", "a"])
}

@Test func aDraggedSiteIsPinnedWhereItLandsUpToTheEndOfThePinned() throws {
    let a = try site("a"), b = try site("b"), c = try site("c"), d = try site("d"), e = try site("e")
    let pinned = [a.id, b.id]
    let shown = SiteOrder.apply([a, b, c, d, e], pinned: pinned, health: nil)
    // e dropped between a and b.
    #expect(SiteOrder.moved(shown, from: 4, to: 1, pinned: pinned) == [a.id, e.id, b.id])
    // a dropped after b.
    #expect(SiteOrder.moved(shown, from: 0, to: 2, pinned: pinned) == [b.id, a.id])
    // d dropped at the very end: pinned after b, c stays unpinned.
    #expect(SiteOrder.moved(shown, from: 3, to: 5, pinned: pinned) == [a.id, b.id, d.id])
    // The first drag with nothing pinned.
    #expect(SiteOrder.moved(SiteOrder.apply([a, b, c], pinned: [], health: nil), from: 2, to: 0, pinned: []) == [c.id])
}

@Test func aSitePutBackWhereItWasIsNotPinned() throws {
    let a = try site("a"), b = try site("b"), c = try site("c"), d = try site("d")
    let pinned = [a.id]
    let shown = SiteOrder.apply([a, b, c, d], pinned: pinned, health: nil)
    // SwiftUI's destination for "back in place" is the index itself or the one after it.
    #expect(SiteOrder.moved(shown, from: 2, to: 2, pinned: pinned) == pinned)
    #expect(SiteOrder.moved(shown, from: 2, to: 3, pinned: pinned) == pinned)
    #expect(SiteOrder.moved(shown, from: 0, to: 1, pinned: pinned) == pinned)
    // One slot up is a real move: c is pinned after a.
    #expect(SiteOrder.moved(shown, from: 2, to: 1, pinned: pinned) == [a.id, c.id])
}

@Test func aSourceNeverPickedFromOpensOnTheFirstOfTheViewersOrder() throws {
    let a = try site("a"), b = try site("b"), c = try site("c"), gone = try site("gone")
    // Nothing remembered or showing: the first pinned site the configuration still has.
    #expect(SiteSelection.choose(remembered: nil, current: nil, in: [a, b, c], pinned: [gone.id, c.id, b.id]) == c.id)
    #expect(SiteSelection.choose(remembered: nil, current: nil, in: [a, b, c], pinned: []) == a.id)
    // A site the viewer picked, or the one showing, still wins.
    #expect(SiteSelection.choose(remembered: SiteSelection.token(for: b.id), current: nil, in: [a, b, c], pinned: [c.id]) == b.id)
    #expect(SiteSelection.choose(remembered: nil, current: a.id, in: [a, b, c], pinned: [c.id]) == a.id)
}

@Test func theOrderIsKeptPerConfigurationAndForgetsRemovedSites() throws {
    let defaults = try #require(UserDefaults(suiteName: "W-317-\(UUID())"))
    let a = try site("a"), b = try site("b"), gone = try site("gone")
    SiteOrderStore(defaults: defaults).set([gone.id, b.id, a.id], in: "one", keeping: [a, b])
    let reopened = SiteOrderStore(defaults: defaults)
    #expect(reopened.pinned(in: "one") == [b.id, a.id])
    #expect(reopened.pinned(in: "two").isEmpty)
    reopened.set([], in: "one", keeping: [a, b])
    #expect(SiteOrderStore(defaults: defaults).pinned(in: "one").isEmpty)
}
