import Foundation
import Testing
@testable import WebHTVCore

/// `SourceClient` is the routing layer that finally lets a ported spider reach the app UI, so what
/// matters here is the routing and the decoding — the spider ports themselves have golden tests.

private func site(_ json: String) throws -> Site {
    try JSONDecoder().decode(Site.self, from: Data(json.utf8))
}

@Test func routesNativeCMSSitesToTheCMSClientAndSpidersToTheRegistry() async throws {
    let resolver = CSPSourceResolver()

    let cms = try site(#"{"key":"t1","name":"CMS","type":1,"api":"https://example.com/api.php/provide/vod"}"#)
    guard case .cms = try await SourceClient.make(site: cms, resolver: resolver) else {
        Issue.record("a type-1 site must stay on CMSClient"); return
    }

    // A registered class routes to the spider; the app no longer decides on `type == 3` alone.
    let ported = try site(#"{"key":"sp","name":"Spider","type":3,"api":"csp_AppGet","ext":{"url":"https://example.invalid"}}"#)
    guard case .spider = try await SourceClient.make(site: ported, resolver: resolver) else {
        Issue.record("a registered csp_* class must route to the spider runtime"); return
    }

    // An unregistered class must not silently become a CMS request against a class name.
    let unported = try site(#"{"key":"no","name":"Nope","type":3,"api":"csp_NotPortedAtAll"}"#)
    await #expect(throws: (any Error).self) {
        _ = try await SourceClient.make(site: unported, resolver: resolver)
    }
}

/// One session per site, reused. A rule-engine spider downloads its rule file inside `init`, and the
/// app builds a client on every listing, page, search and episode — without reuse a single browse
/// would re-fetch the rules a dozen times.
@Test func reusesOneSpiderSessionPerSiteAndDropsThemOnReset() async throws {
    let store = SpiderSessionStore()
    let resolver = CSPSourceResolver()
    let spider = try site(#"{"key":"reuse","name":"Spider","type":3,"api":"csp_AppGet","ext":{"url":"https://example.invalid"}}"#)

    let first = try await store.session(for: spider, resolver: resolver)
    let second = try await store.session(for: spider, resolver: resolver)
    #expect(first === second, "a second call must reuse the cached session, not re-init the spider")

    await store.reset()
    let third = try await store.session(for: spider, resolver: resolver)
    #expect(first !== third, "reset must drop cached sessions so a new config cannot reuse a stale one")
}

/// The spider ports were written to emit the CatVod shape the app already parsed, so the whole
/// spider branch is a decode. These are the exact shapes the three ported spiders return.
@Test func decodesTheCatVodShapesTheSpidersActuallyReturn() throws {
    let home = try JSONDecoder().decode(CMSResponse.self, from: Data(#"""
    {"class":[{"type_id":"1","type_name":"电影"},{"type_id":"2","type_name":"电视剧"}],"list":[]}
    """#.utf8))
    #expect(home.classes.map(\.name) == ["电影", "电视剧"])
    // XBPQ always returns an empty home list, which is why SourceClient.home falls back to listing
    // the first category instead of rendering an empty grid.
    #expect(home.list.isEmpty)
    #expect(home.firstListableCategory?.id == "1")

    let detail = try JSONDecoder().decode(CMSResponse.self, from: Data(#"""
    {"list":[{"vod_id":"9","vod_name":"抓特务","vod_pic":"http://x/p.jpg",
      "vod_play_from":"线路①$$$线路②","vod_play_url":"01$a.m3u8#02$b.m3u8$$$01$c.m3u8"}]}
    """#.utf8))
    let vod = try #require(detail.list.first)
    #expect(vod.flags.map(\.name) == ["线路①", "线路②"])
    #expect(vod.flags[0].episodes.map(\.name) == ["01", "02"])
    #expect(vod.flags[0].episodes[1].url == "b.m3u8")
    #expect(vod.flags[1].episodes.count == 1)
}

/// `parse` decides whether the app gets a URL or an honest failure, so both encodings a CatVod
/// source may use are accepted, and `parse:1` must never reach AVPlayer as if it were media.
@Test func readsThePlayEnvelopeIncludingTheStringEncodedParseFlag() throws {
    func play(_ json: String) throws -> SpiderPlayResponse {
        try JSONDecoder().decode(SpiderPlayResponse.self, from: Data(json.utf8))
    }
    #expect(try play(#"{"parse":0,"url":"https://a/x.m3u8"}"#).parse == 0)
    // Some CatVod sources send parse as a string; failing that decode would break playback outright.
    #expect(try play(#"{"parse":"0","url":"https://a/x.m3u8"}"#).parse == 0)
    #expect(try play(#"{"parse":1,"url":"https://a/page.html"}"#).parse == 1)
    // A missing url is not a decode failure — it is an unplayable episode, reported as one.
    #expect(try play(#"{"parse":0}"#).url.isEmpty)
}

/// The whole point of the stage: the configured spider sites must actually appear in the list the
/// app builds. Gated on the real config, like every other live-data check in this suite.
@Test func listsThePortedSpiderSitesAlongsideTheNativeCMSSites() throws {
    guard let path = ProcessInfo.processInfo.environment["WANG_MOVIE_JSON"] else { return }
    let config = try JSONDecoder().decode(WebHTVConfig.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let resolver = CSPSourceResolver()

    let native = config.supportedSites
    let drivable = config.drivableSites(resolvedBy: resolver)
    let spiders = config.spiderSites(resolvedBy: resolver)

    #expect(native.count == 30, "2 type-0 + 22 type-1 + 6 type-4")
    #expect(spiders.count == 15, "AppGet 5 + XBPQ 7 + XYQHiker 3")
    #expect(drivable.count == native.count + spiders.count)
    // The app selects a site by key, so a duplicate would make the picker ambiguous.
    #expect(Set(drivable.map(\.key)).count == drivable.count)
    // Every listed spider must be one the registry can genuinely drive.
    #expect(spiders.allSatisfy { resolver.canResolve($0) })
    print("[sources] app list: \(drivable.count) = \(native.count) native + \(spiders.count) spider")
}
