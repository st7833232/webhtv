import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-42: the XYQHiker rule semantics recovered from `xyqxbpq.jar`
// (docs/IOS-POC-42-xyqhiker-detail-episodes.md, section 3), driven through the bundled
// `XYQHiker.js` against canned pages served by `XBPQRuleTests`' `RuleSite`. Every test owns its own
// `.invalid` host, so they can run side by side.

private func xyq(_ rules: String) async throws -> JavaScriptSpiderRuntime { try await ruleSpider("XYQHiker", rules) }

// MARK: - 42A: direct play

/// 44 of the 47 adult rule files set 链接是否直接播放. The original then never reads the playlist rules
/// — not even one that matches, as this page's does — and plays the listing's link as the only episode.
@Test func givesADirectPlayPageItsTitleAsTheOnlyEpisode() async throws {
    RuleSite.serve(["https://h1.invalid/v/1": """
    <title>片一 - 站名</title><ul class="line"><li><a href="/p/1">第1集</a></li></ul>
    """])
    let spider = try await xyq(#"{"链接是否直接播放":"1","播放列表数组规则":".line"}"#)
    let vod = try await detail(spider, "https://h1.invalid/v/1")
    #expect(vod["vod_name"] == "片一")
    #expect(vod["vod_play_from"] == "片一")
    #expect(vod["vod_play_url"] == "片一$https://h1.invalid/v/1")
}

/// AVbebe's titles carry "#", which split its one episode in two. `force_play` is the English key
/// the original falls back to, and 是 counts as on.
@Test func aDirectPlayTitleCannotSplitTheEpisodeList() async throws {
    RuleSite.serve(["https://h2.invalid/v/2": "<title>A#B$C</title>",
                    "https://h2.invalid/v/3": "<p>no title</p>"])
    let spider = try await xyq(#"{"force_play":"是"}"#)
    #expect(try await detail(spider, "https://h2.invalid/v/2")["vod_play_url"] == "ABC$https://h2.invalid/v/2")
    #expect(try await detail(spider, "https://h2.invalid/v/3")["vod_play_url"] == "播放$https://h2.invalid/v/3")
}

/// 农民, 巴士动漫 and 動漫巴士 set 链接是否直接播放 to 0 and keep reading their playlists.
@Test func aPlaylistSiteStillReadsItsEpisodes() async throws {
    RuleSite.serve(["https://h3.invalid/v/4": """
    <title>片四</title><ul class="play_list"><li><a href="/p/4-1">第1集</a></li><li><a href="/p/4-2">第2集</a></li></ul>
    """])
    let spider = try await xyq(#"{"链接是否直接播放":"0","播放列表数组规则":".play_list"}"#)
    let vod = try await detail(spider, "https://h3.invalid/v/4")
    #expect(vod["vod_play_from"] == "线路1")
    #expect(vod["vod_play_url"] == "第1集$https://h3.invalid/p/4-1#第2集$https://h3.invalid/p/4-2")
}

// MARK: - 42B: playing a direct-play page

/// A direct-play link that already is a stream plays as it is, with the rule's suffix.
@Test func playsADirectLinkThatIsAlreadyAStream() async throws {
    let spider = try await xyq(#"{"链接是否直接播放":"1","直接播放链接加后缀":"?t=1"}"#)
    let played = try await play(spider, "https://h4.invalid/v/1.m3u8")
    #expect(played.url == "https://h4.invalid/v/1.m3u8?t=1")
    #expect(played.parse == 0)
}

/// 鲨鱼av and 黄色仓库123 name the stream in the page itself; jiedm and HOHOJ only inside their embed
/// frame, and jiedm wraps it in a parse URL. The iOS sniffer caught none of them.
@Test func readsTheStreamOutOfADirectPlayPageAndItsEmbedFrame() async throws {
    RuleSite.serve([
        "https://h5.invalid/v/1": #"<script>var player={"url":"https:\/\/cdn.h5.invalid\/1\/index.m3u8"}</script>"#,
        "https://h5.invalid/v/2": #"<iframe src="/embed/2.html"></iframe>"#,
        "https://h5.invalid/embed/2.html": "<script>src: 'https://jx.h5.invalid/?url=https://cdn.h5.invalid/2/index.m3u8'</script>",
    ])
    let spider = try await xyq(#"{"链接是否直接播放":"1"}"#)
    let page = try await play(spider, "https://h5.invalid/v/1")
    #expect(page.url == "https://cdn.h5.invalid/1/index.m3u8")
    #expect(page.parse == 0)
    let framed = try await play(spider, "https://h5.invalid/v/2")
    #expect(framed.url == "https://cdn.h5.invalid/2/index.m3u8")
    #expect(framed.parse == 0)
}

/// 正妹AV's page carries its pre-roll ad before the stream and PPP's a thumbnail named
/// "preview.m3u8.jpg"; neither is the video, so the page goes to the app's sniffer instead.
@Test func leavesAdsAndThumbnailsToTheSniffer() async throws {
    RuleSite.serve([
        "https://h6.invalid/v/1": #"<video src="https://cdn.h6.invalid/media/preroll/ad_17sec.mp4"></video>"#,
        "https://h6.invalid/v/2": #"<img src="https://cdn.h6.invalid/32085/preview.m3u8.jpg">"#,
    ])
    let spider = try await xyq(#"{"链接是否直接播放":"1"}"#)
    for id in ["https://h6.invalid/v/1", "https://h6.invalid/v/2"] {
        let played = try await play(spider, id)
        #expect(played.url == id)
        #expect(played.parse == 1)
    }
}

/// A rule whose prefix is only the site's origin, on a site that now writes absolute links, gave
/// "https://a.comhttps://…" (小嫂子, Ujizzcn). A prefix with a path, such as a parse API, stays.
@Test func doesNotPrefixAnAbsoluteLinkWithAnOrigin() async throws {
    RuleSite.serve([
        "https://h7.invalid/c/1/1": """
        <ul><li><a href="https://cdn2.h7.invalid/v/1">片一</a></li><li><a href="/v/2">片二</a></li></ul>
        """,
        "https://jx.h7.invalid/?url=https://cdn2.h7.invalid/v/1": "<p>a parse page</p>",
    ])
    let spider = try await xyq(#"""
    {"分类链接":"https://h7.invalid/c/{cateId}/{catePg}","分类列表数组规则":"li","分类片单标题":"a&&Text",
     "分类片单链接":"a&&href","分类片单链接加前缀":"https://h7.invalid",
     "链接是否直接播放":"1","直接播放链接加前缀":"https://jx.h7.invalid/?url="}
    """#)
    let listing = try titles(try await spider.categoryContent(tid: "1", page: "1", filter: false, extend: [:]))
    #expect(listing.map { $0["vod_id"] } == ["https://cdn2.h7.invalid/v/1", "https://h7.invalid/v/2"])
    #expect(try await play(spider, "https://cdn2.h7.invalid/v/1").url == "https://jx.h7.invalid/?url=https://cdn2.h7.invalid/v/1")
}

/// The playlist sites' play pages go through the same reading: a player config's "url" plays,
/// anything else is sniffed.
@Test func aPlaylistSitesPlayPageIsReadTheSameWay() async throws {
    RuleSite.serve([
        "https://h8.invalid/p/1": #"<script>var player_aaaa={"url":"https:\/\/cdn.h8.invalid\/1.mp4"}</script>"#,
        "https://h8.invalid/p/2": "<p>a player we cannot read</p>",
    ])
    let spider = try await xyq(#"{"链接是否直接播放":"0"}"#)
    let read = try await play(spider, "https://h8.invalid/p/1")
    #expect(read.url == "https://cdn.h8.invalid/1.mp4")
    #expect(read.parse == 0)
    let sniffed = try await play(spider, "https://h8.invalid/p/2")
    #expect(sniffed.url == "https://h8.invalid/p/2")
    #expect(sniffed.parse == 1)
}
