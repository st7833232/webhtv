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
