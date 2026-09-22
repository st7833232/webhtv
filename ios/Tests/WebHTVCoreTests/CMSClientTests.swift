import Foundation
import Testing
@testable import WebHTVCore

@Test func buildsExternalPlayerURLsWithoutChangingMediaURL() throws {
    let mediaURL = try #require(URL(string: "https://example.com/video.m3u8?token=a+b&quality=1080p"))
    let expected = [
        (ExternalPlayer.infuse, "infuse", "x-callback-url", "/play"),
        (ExternalPlayer.fileball, "filebox", "play", ""),
        (ExternalPlayer.senPlayer, "senplayer", "x-callback-url", "/play"),
        (ExternalPlayer.vidHub, "open-vidhub", "x-callback-url", "/play"),
    ]

    for (player, scheme, host, path) in expected {
        let url = try #require(player.playbackURL(for: mediaURL))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == scheme)
        #expect(components.host == host)
        #expect(components.path == path)
        #expect(components.queryItems == [URLQueryItem(name: "url", value: mediaURL.absoluteString)])
    }
}

@Test func decodesPlaybackGroupsAndBracketedEpisodeNames() throws {
    let data = Data(#"{"class":[{"type_id":1,"type_name":"電影"}],"list":[{"vod_id":7,"vod_name":"測試","vod_play_from":"line1$$$line2","vod_play_url":"第1集$https://example.com/1.m3u8#花絮(上#下)$https://example.com/2.mp4$$$備用$custom://2"}]}"#.utf8)
    let response = try JSONDecoder().decode(CMSResponse.self, from: data)

    #expect(response.classes.first?.id == "1")
    #expect(response.list.first?.id == "7")
    #expect(response.list.first?.flags.first?.episodes.map(\.name) == ["第1集", "花絮(上#下)"])
    #expect(response.list.first?.flags.first?.episodes.first?.mediaURL?.scheme == "https")
    #expect(response.list.first?.flags.last?.episodes.first?.mediaURL == nil)
}

@Test func completesLiveCMSFlowFromProvidedConfig() async throws {
    guard let path = ProcessInfo.processInfo.environment["WANG_MOVIE_JSON"] else { return }
    let config = try ConfigLoader.decode(Data(contentsOf: URL(fileURLWithPath: path)))
    let site = try #require(config.sites.first { $0.api.contains("cj.rycjapi.com/api.php/provide/vod/at/json") })
    let client = try CMSClient(site: site)
    let home = try await client.home()
    let first = try #require(home.list.first)
    let search = try await client.search(first.name)
    let detail = try #require(try await client.detail(id: first.id))

    #expect(!home.classes.isEmpty)
    #expect(search.list.contains { $0.id == first.id })
    #expect(detail.flags.flatMap(\.episodes).contains { $0.mediaURL != nil })
}

private func site(key: String, type: Int, api: String, ext: String = "null") throws -> Site {
    let json = #"{"key":"\#(key)","name":"\#(key)","type":\#(type),"api":"\#(api)","ext":\#(ext)}"#
    return try JSONDecoder().decode(Site.self, from: Data(json.utf8))
}

@Test func keepsType1RequestsUnchangedAndMergesType4Ext() throws {
    // A5 regression: every type-1 site in the shipped config has a null `ext`, so its URLs must not move.
    let type1 = try CMSClient(site: site(key: "cms", type: 1, api: "https://example.com/api.php/provide/vod"))
    // The empty-query build has always emitted a bare trailing "?"; keeping it is what makes this a regression test.
    #expect(try type1.requestURL([]).absoluteString == "https://example.com/api.php/provide/vod?")
    #expect(try type1.requestURL([URLQueryItem(name: "ac", value: "detail"), URLQueryItem(name: "ids", value: "7")]).absoluteString
        == "https://example.com/api.php/provide/vod?ac=detail&ids=7")

    let type4 = try CMSClient(site: site(key: "php", type: 4, api: "https://example.com/php/", ext: #"{"module_name":"CmsSuggest"}"#))
    #expect(try type4.requestURL([URLQueryItem(name: "filter", value: "true")]).absoluteString
        == "https://example.com/php/?filter=true&module_name=CmsSuggest")

    // A non-ASCII type-4 endpoint must survive percent-encoding rather than fail to build.
    let unicode = try CMSClient(site: site(key: "fl", type: 4, api: "http://192.0.2.1:5757/api/枫林影视?pwd=dzyyds"))
    #expect(try unicode.requestURL([URLQueryItem(name: "t", value: "movie")]).absoluteString
        == "http://192.0.2.1:5757/api/%E6%9E%AB%E6%9E%97%E5%BD%B1%E8%A7%86?pwd=dzyyds&t=movie")

    #expect(throws: CMSClientError.unsupportedSiteType(3)) { try CMSClient(site: site(key: "s", type: 3, api: "csp_Test")) }
}

@Test func parsesType4DetailAndResolvesPlaybackURLs() throws {
    // A3: a type-4 detail uses the same $$$ / # / $ separators the type-1 parser already handles.
    let data = Data(#"{"list":[{"vod_id":"2@194093","vod_name":"蓮花樓","vod_play_from":"普快线路$$$愛看線路","vod_play_url":"01$https://cdn.example.com/a/index.m3u8#02$https://cdn.example.com/b/index.m3u8$$$第01集$https://play.example.com/play/PrXC-2-1.html"}]}"#.utf8)
    let vod = try #require(try JSONDecoder().decode(CMSResponse.self, from: data).list.first)

    #expect(vod.flags.map(\.name) == ["普快线路", "愛看線路"])
    #expect(vod.flags.first?.episodes.map(\.name) == ["01", "02"])

    // A4: a direct episode needs no resolution; a web-page episode must not be treated as media.
    let direct = try #require(vod.flags.first?.episodes.first?.mediaURL)
    let page = try #require(vod.flags.last?.episodes.first?.mediaURL)
    #expect(CMSClient.isDirectMedia(direct))
    #expect(!CMSClient.isDirectMedia(page))

    // `url` is a menu, not a string — one entry here, and `PlayURLTests` covers the other shapes.
    let resolved = try JSONDecoder().decode(PlayResponse.self, from: Data(#"{"parse":0,"url":"https://v.example.com/2960/index.m3u8"}"#.utf8))
    #expect(resolved.url.values.map(\.v) == ["https://v.example.com/2960/index.m3u8"])
}

@Test func decodesDetailCarryingOnlyPlaybackFields() throws {
    // 爱瓜TV answers `ac=detail` without vod_id or vod_name; requiring them dropped the whole record.
    let data = Data(#"{"list":[{"vod_play_from":"普快线路","vod_play_url":"01$https://cdn.example.com/a/index.m3u8"}]}"#.utf8)
    let vod = try #require(try JSONDecoder().decode(CMSResponse.self, from: data).list.first)

    #expect(vod.id.isEmpty)
    #expect(vod.name.isEmpty)
    #expect(vod.flags.first?.episodes.first?.mediaURL?.absoluteString == "https://cdn.example.com/a/index.m3u8")
}

@Test func buildsTheSameCategoryRequestForBothSupportedTypes() throws {
    // Probed 2026-09-15: type-1 (cj.rycjapi.com) and type-4 (aigua1.php) both list a category with t=/pg=.
    for type in [1, 4] {
        let client = try CMSClient(site: site(key: "s", type: type, api: "https://example.com/api.php/provide/vod"))
        #expect(try client.requestURL([URLQueryItem(name: "t", value: "20"), URLQueryItem(name: "pg", value: "1")]).absoluteString
            == "https://example.com/api.php/provide/vod?t=20&pg=1")
    }
}

@Test func groupsCategoriesIntoParentsAndChildren() throws {
    // Probed 2026-09-15: 360zy answers t=2 (a parent with children) with total 0, so its children
    // are what can be listed, while the childless 伦理片 returns 1641 titles under its own id.
    let tree = Data(#"{"class":[{"type_id":1,"type_name":"电影","type_pid":0},{"type_id":6,"type_name":"动作片","type_pid":1},{"type_id":7,"type_name":"喜剧片","type_pid":"1"},{"type_id":5,"type_name":"伦理片","type_pid":0}]}"#.utf8)
    let grouped = try JSONDecoder().decode(CMSResponse.self, from: tree).categoryGroups

    #expect(grouped.map(\.parent.name) == ["电影", "伦理片"])
    #expect(grouped.first?.children.map(\.name) == ["动作片", "喜剧片"])
    #expect(grouped.last?.children.isEmpty == true)

    // Type-4 sites, and flat type-1 ones such as 天涯, omit type_pid; each entry becomes its own group.
    let flat = Data(#"{"class":[{"type_id":"2","type_name":"电视剧"},{"type_id":"1","type_name":"电影"}]}"#.utf8)
    let flatGroups = try JSONDecoder().decode(CMSResponse.self, from: flat).categoryGroups
    #expect(flatGroups.map(\.parent.name) == ["电视剧", "电影"])
    #expect(flatGroups.allSatisfy { $0.children.isEmpty })
}

@Test func picksTheFirstListableCategoryPerShape() throws {
    let tree = Data(#"{"class":[{"type_id":1,"type_name":"电影","type_pid":0},{"type_id":6,"type_name":"动作片","type_pid":1}]}"#.utf8)
    #expect(try JSONDecoder().decode(CMSResponse.self, from: tree).firstListableCategory?.name == "动作片")

    // A leading parent with no children is listable by its own id rather than skipped.
    let childless = Data(#"{"class":[{"type_id":5,"type_name":"伦理片","type_pid":0},{"type_id":1,"type_name":"电影","type_pid":0},{"type_id":6,"type_name":"动作片","type_pid":1}]}"#.utf8)
    #expect(try JSONDecoder().decode(CMSResponse.self, from: childless).firstListableCategory?.name == "伦理片")

    let flat = Data(#"{"class":[{"type_id":"2","type_name":"电视剧"}]}"#.utf8)
    #expect(try JSONDecoder().decode(CMSResponse.self, from: flat).firstListableCategory?.name == "电视剧")
}

@Test func stopsPagingWhenAPageAddsNothingNew() throws {
    func titles(_ ids: [String]) throws -> [Vod] {
        let items = ids.map { #"{"vod_id":"\#($0)","vod_name":"t\#($0)"}"# }.joined(separator: ",")
        return try JSONDecoder().decode(CMSResponse.self, from: Data(#"{"list":[\#(items)]}"#.utf8)).list
    }
    let first = try titles(["1", "2"])

    // A genuine next page appends only what is new.
    #expect(first.merging(newTitlesFrom: try titles(["2", "3"])).map(\.id) == ["1", "2", "3"])

    // 爱瓜TV reports pagecount 9999, so a source repeating a page must be detected by content:
    // the merge adds nothing and the caller stops instead of looping forever.
    #expect(first.merging(newTitlesFrom: try titles(["1", "2"])).count == first.count)
    #expect(first.merging(newTitlesFrom: []).count == first.count)
}

@Test func addsAPageParameterOnlyBeyondTheFirstPage() throws {
    // Probed 2026-09-15: 如意 paginates its default home listing with a bare pg=.
    let client = try CMSClient(site: site(key: "cms", type: 1, api: "https://example.com/api.php/provide/vod"))
    #expect(try client.requestURL([]).absoluteString == "https://example.com/api.php/provide/vod?")
    #expect(try client.requestURL([URLQueryItem(name: "pg", value: "2")]).absoluteString
        == "https://example.com/api.php/provide/vod?pg=2")
    #expect(try client.requestURL([URLQueryItem(name: "t", value: "6"), URLQueryItem(name: "pg", value: "3")]).absoluteString
        == "https://example.com/api.php/provide/vod?t=6&pg=3")
}

@Test func asksForTheDetailFormOnlyWhereItSuppliesThePoster() throws {
    // Probed 2026-09-15 against 360zy: the plain listing has no vod_pic at all, while ac=detail
    // carries it on every item. A type-4 listing already includes the picture, so it stays plain.
    let macCMS = try CMSClient(site: site(key: "cms", type: 1, api: "https://example.com/api.php/provide/vod"))
    #expect(macCMS.listingQuery(categoryID: "6", page: 1).map(\.name) == ["ac", "t", "pg"])
    #expect(macCMS.listingQuery(categoryID: nil, page: 1).map(\.name) == ["ac"])
    #expect(macCMS.listingQuery(categoryID: nil, page: 2).map(\.name) == ["ac", "pg"])

    let remote = try CMSClient(site: site(key: "t4", type: 4, api: "https://example.com/php/"))
    #expect(remote.listingQuery(categoryID: "2", page: 1).map(\.name) == ["t", "pg"])
    #expect(remote.listingQuery(categoryID: nil, page: 1).isEmpty)

    // 天涯 ships ac=list inside its configured api, so the detail form has to win.
    let preset = try CMSClient(site: site(key: "ty", type: 1, api: "https://example.com/api.php/provide/vod/?ac=list"))
    #expect(try preset.requestURL(preset.listingQuery(categoryID: "6", page: 1)).absoluteString
        == "https://example.com/api.php/provide/vod/?ac=detail&t=6&pg=1")
}

@Test func usesABoundedRequestTimeout() {
    // Guards the fix for unreachable sources hanging the screen; the URLSession default is 60 s.
    #expect(URLSession.webHTV.configuration.timeoutIntervalForRequest == 10)
}

/// Live smoke over every type-4 site in the supplied config. Remote reachability is volatile, so an
/// unreachable host is reported and skipped; only a host that answers is held to the contract.
@Test func reportsLiveType4SitesFromProvidedConfig() async throws {
    guard let path = ProcessInfo.processInfo.environment["WANG_MOVIE_JSON"] else { return }
    let config = try ConfigLoader.decode(Data(contentsOf: URL(fileURLWithPath: path)))
    let sites = config.nativeCMSSites.filter { $0.type == 4 }
    #expect(sites.count == 6)

    for site in sites {
        let client = try CMSClient(site: site)
        guard let home = try? await client.home() else {
            print("type-4 \(site.key): unreachable at \(site.api)")
            continue
        }
        print("type-4 \(site.key): classes=\(home.classes.count) list=\(home.list.count)")
        guard let first = home.list.first,
              let detail = try? await client.detail(id: first.id),
              let flag = detail.flags.first, let episode = flag.episodes.first else { continue }
        let play = try? await client.playbackURL(for: episode, flag: flag.name)
        let resolved = (play?.values.first?.v).flatMap { URL(string: $0) }
        print("type-4 \(site.key): \(first.name) / \(episode.name) -> \(resolved?.absoluteString ?? "unresolved")")
        if let resolved { #expect(CMSClient.isDirectMedia(resolved)) }
    }
}

/// IOS-POC-14: what plays after this episode, and when there is nothing left.
///
/// The rule matches on the episode's **address**. A name cannot be trusted — this configuration has
/// a line that merges episodes and prints the same label twice (IOS-POC-8J) — and an index held by
/// the caller can be stale by the time the player asks for the next one.
@Suite struct NextEpisodeTests {
    private func flag(_ pairs: [(String, String)]) -> Flag {
        Flag(name: "line", episodes: pairs.map { Episode(name: $0.0, url: $0.1) })
    }

    @Test func theNextEpisodeOnTheSameLine() {
        let line = flag([("第01集", "https://a/1.m3u8"), ("第02集", "https://a/2.m3u8"),
                         ("第03集", "https://a/3.m3u8")])
        #expect(line.episode(after: line.episodes[0])?.name == "第02集")
        #expect(line.episode(after: line.episodes[1])?.name == "第03集")
    }

    /// The last episode is what ends the player, so this answering nil is the whole close path.
    @Test func theLastEpisodeHasNoNext() {
        let line = flag([("第01集", "https://a/1.m3u8"), ("第02集", "https://a/2.m3u8")])
        #expect(line.episode(after: line.episodes[1]) == nil)
    }

    @Test func aSingleEpisodeLineEndsImmediately() {
        let line = flag([("全集", "https://a/1.m3u8")])
        #expect(line.episode(after: line.episodes[0]) == nil)
    }

    /// An episode from a different line, or one the source has since dropped, must not silently
    /// start something unrelated — there is no position to advance from.
    @Test func anEpisodeThatIsNotOnThisLineHasNoNext() {
        let line = flag([("第01集", "https://a/1.m3u8"), ("第02集", "https://a/2.m3u8")])
        #expect(line.episode(after: Episode(name: "第01集", url: "https://elsewhere/1.m3u8")) == nil)
    }

    /// Repeated names are real in this configuration; the address is what tells them apart.
    @Test func repeatedNamesDoNotConfuseIt() {
        let line = flag([("第01-02集", "https://a/1.m3u8"), ("第01-02集", "https://a/2.m3u8"),
                         ("第03集", "https://a/3.m3u8")])
        #expect(line.episode(after: line.episodes[1])?.name == "第03集")
    }

    @Test func anEmptyLineHasNothingToAdvanceTo() {
        #expect(flag([]).episode(after: Episode(name: "x", url: "https://a/1.m3u8")) == nil)
    }
}
