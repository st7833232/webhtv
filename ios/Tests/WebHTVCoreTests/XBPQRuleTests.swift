import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-39: the XBPQ rule semantics recovered from `xyqxbpq.jar`
// (docs/IOS-POC-39-xbpq-rule-coverage.md, section 4), driven through the bundled `XBPQ.js` against
// canned pages. Every test owns its own `.invalid` host, so they can run side by side.

/// Answers from `pages` by exact URL (404 otherwise) and remembers every URL it was asked for.
/// A test that only checks the address asked for calls `categoryContent` with `try?`: an unserved
/// page's 404 behind an empty listing is a `SiteUnreachable` since IOS-POC-41A.
private final class RuleSite: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pages: [String: String] = [:]
    nonisolated(unsafe) private static var asked: [String] = []

    static func serve(_ served: [String: String]) {
        lock.withLock { served.forEach { pages[$0.key] = $0.value } }
    }

    static func requests(on host: String) -> [String] {
        lock.withLock { asked.filter { URL(string: $0)?.host == host } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".invalid") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!.absoluteString
        let body = Self.lock.withLock { () -> String? in
            Self.asked.append(url)
            return Self.pages[url]
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: body == nil ? 404 : 200,
                                       httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func xbpq(_ extend: String) async throws -> JavaScriptSpiderRuntime {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RuleSite.self]
    let registry = SpiderRegistry.bundled()
    let script = try #require(registry.entry(for: "csp_XBPQ")?.script)
    let runtime = try JavaScriptSpiderRuntime(
        name: "XBPQ", script: script, prelude: registry.prelude,
        storage: SpiderStorage(siteKey: "xbpq-test", defaults: UserDefaults(suiteName: "xbpq-test")!),
        session: URLSession(configuration: configuration))
    try await runtime.initialize(extend: extend)
    return runtime
}

private func classes(_ runtime: JavaScriptSpiderRuntime) async throws -> [String] {
    let home = try #require(try JSONSerialization.jsonObject(
        with: Data(try await runtime.homeContent(filter: false).utf8)) as? [String: Any])
    return (home["class"] as? [[String: Any]] ?? []).map {
        "\($0["type_name"] as? String ?? "")=\($0["type_id"] as? String ?? "")"
    }
}

// MARK: - S1: rules and URLs

/// 41 sites point `ext` at `./json/x.json`; the resolver hands the spider an https URL, which the
/// original downloads. Parsing the URL itself as JSON is what left all 41 with no rules at all.
@Test func downloadsARuleFileExtAndReadsItsCommentedJSON() async throws {
    RuleSite.serve(["https://s1.invalid/json/a.json": """
    \u{FEFF}{
      // 作者的說明
      "分类url": "https://s1.invalid/t/{cateId}-{catePg}/;;z",
      "分类": "国产$1#日韩$2"
    }
    """])
    let spider = try await xbpq("https://s1.invalid/json/a.json")
    #expect(try await classes(spider) == ["国产=1", "日韩=2"])

    // `;;z` is the original's flag string, not part of the address: 45 sites carry one.
    _ = try? await spider.categoryContent(tid: "2", page: "1", filter: false, extend: [:])
    #expect(RuleSite.requests(on: "s1.invalid").last == "https://s1.invalid/t/2-1/")
    await spider.destroy()
}

@Test func takesAnExtURLWithACategoryPlaceholderAsTheCategoryURL() async throws {
    let spider = try await xbpq("https://s2.invalid/list/{cateId}/{catePg}.html")
    _ = try? await spider.categoryContent(tid: "7", page: "3", filter: false, extend: [:])
    // Nothing was downloaded as a rule file: the URL *is* the rule.
    #expect(RuleSite.requests(on: "s2.invalid") == ["https://s2.invalid/list/7/3.html"])
    await spider.destroy()
}

@Test func readsTheKeyValueExtShape() async throws {
    let spider = try await xbpq(#"分类url:https://s3.invalid/v/{cateId}-{catePg},分类:甲$1#乙\,丙$2"#)
    #expect(try await classes(spider) == ["甲=1", "乙,丙=2"])
    await spider.destroy()
}

/// `空` means "not configured", so the alias after it is used.
@Test func treatsTheWordEmptyAsUnset() async throws {
    let spider = try await xbpq(#"{"分类url":"空","分类链接":"https://s4.invalid/c/{cateId}_{catePg}.html","分类":"一$1"}"#)
    _ = try? await spider.categoryContent(tid: "1", page: "1", filter: false, extend: [:])
    #expect(RuleSite.requests(on: "s4.invalid") == ["https://s4.invalid/c/1_1.html"])
    await spider.destroy()
}

@Test func buildsCategoryURLsTheWayTheOriginalDoes() async throws {
    // An unfilled placeholder goes, and so does the `/名/` segment named after it.
    let filters = try await xbpq(#"{"分类url":"https://s5.invalid/vod/show/area/{area}/by/{by}/id/{cateId}/page/{catePg}/year/{year}.html","分类":"一$1"}"#)
    _ = try? await filters.categoryContent(tid: "5", page: "1", filter: false, extend: [:])
    #expect(RuleSite.requests(on: "s5.invalid") == ["https://s5.invalid/vod/show/id/5/page/1.html"])
    await filters.destroy()

    // The first page may have an address of its own, in brackets.
    let firstPage = try await xbpq(#"{"分类url":"https://s6.invalid/t/{cateId}_{catePg}.html[firstPage=https://s6.invalid/t/{cateId}.html]","分类":"一$1"}"#)
    _ = try? await firstPage.categoryContent(tid: "9", page: "1", filter: false, extend: [:])
    _ = try? await firstPage.categoryContent(tid: "9", page: "2", filter: false, extend: [:])
    #expect(RuleSite.requests(on: "s6.invalid") == ["https://s6.invalid/t/9.html", "https://s6.invalid/t/9_2.html"])
    await firstPage.destroy()

    // Pages count from `起始页`, and a relative template joins the site.
    let offset = try await xbpq(#"{"主页url":"https://s7.invalid/","分类url":"/list/{cateId}/{catePg}","起始页":"2","分类":"一$1"}"#)
    _ = try? await offset.categoryContent(tid: "3", page: "1", filter: false, extend: [:])
    #expect(RuleSite.requests(on: "s7.invalid") == ["https://s7.invalid/list/3/2"])
    await offset.destroy()
}

@Test func pairsCategoryNamesWithTheirValues() async throws {
    let paired = try await xbpq(#"{"分类url":"https://s8.invalid/{cateId}","分类":"自拍&国产","分类值":"11&12"}"#)
    #expect(try await classes(paired) == ["自拍=11", "国产=12"])
    await paired.destroy()

    // Without values each name is its own id — the three `金陵撸铁汉`-style sites.
    let named = try await xbpq(#"{"分类url":"https://s8.invalid/{cateId}","分类":"自拍&国产"}"#)
    #expect(try await classes(named) == ["自拍=自拍", "国产=国产"])
    await named.destroy()
}

/// 24 sites slice their categories out of the home page with `分类数组`/`分类标题`/`分类ID`.
@Test func slicesCategoriesOutOfTheHomePage() async throws {
    RuleSite.serve(["https://s9.invalid/": """
    <div class="top"><a href="/">首页</a></div>
    <ul class="nav"><li><a href="/vodtype/20.html">国产</a></li><li><a href="/vodtype/21.html"><b>日本</b></a></li></ul>
    <ul class="foot"><li><a href="/vodtype/99.html">友链</a></li></ul>
    """])
    let spider = try await xbpq(#"""
    {"主页url":"https://s9.invalid/","分类url":"https://s9.invalid/vodtype/{cateId}-{catePg}.html",
     "分类二次截取":"class=\"nav\">&&</ul>","分类数组":"<li&&</li>","分类标题":">&&</a","分类ID":"/vodtype/&&.html"}
    """#)
    #expect(try await classes(spider) == ["国产=20", "日本=21"])
    await spider.destroy()
}

// MARK: - S2: the slicing grammar

/// Each case is a real rule shape from `wang-sex.json`, run through the category slicer so the
/// whole path — `hide`, `sliceAll`, `replaceIn`, `+` joining — is what gets exercised.
@Test func slicesWithTheOriginalGrammar() async throws {
    RuleSite.serve(["https://s10.invalid/": """
    <li><a class="n" href="/vodtype/20.html?v=20&x=1" title="国产">国产</a></li>
    <li><a class="n" href="/vodtype/21.html?v=21&x=1" title="日本">日本</a></li>
    <li><a class="n" href="/vodtype/22.html?v=22&x=1" title="广告">广告</a></li>
    <li><a class="n" href="/vodtype/23.html?v=23&x=1" title="下一页">下一页</a></li>
    """])
    func categories(_ title: String, _ id: String) async throws -> [String] {
        let rules: [String: String] = [
            "主页url": "https://s10.invalid/", "分类url": "https://s10.invalid/{cateId}",
            "分类数组": "<li&&</li>", "分类标题": title, "分类ID": id]
        let spider = try await xbpq(String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self))
        defer { Task { await spider.destroy() } }
        return try await classes(spider)
    }

    // `[不包含:a#b]` is two values, not one containing `#` (纤纤倫理, 小幺女).
    #expect(try await categories(#"title="&&"[不包含:广告#下一页]"#, "/vodtype/&&.html")
            == ["国产=20", "日本=21"])
    // `*` spans an attribute without crossing `>`; the content after it is the value.
    #expect(try await categories(#"<a class="*" href="*">&&</a>[包含:国#日]"#, "/vodtype/&&.html")
            == ["国产=20", "日本=21"])
    // `+` joins, and a part without `&&` is literal text (18j's `🌹+alt="&&"`). Modifiers belong
    // to their own part.
    #expect(try await categories(#"【+title="&&"[不包含:广告#下一页]+】"#, "/vodtype/&&.html").prefix(2)
            == ["【国产】=20", "【日本】=21"])
    // `[替换:]` pairs split on `#`; `>>空` deletes; `\&` is a literal `&` (魔法少女's `?v=&&\&`).
    #expect(try await categories(#"title="&&"[不包含:广告#下一页]"#, #"href="&&"[替换:/vodtype/>>空#.html>>]"#).prefix(1)
            == ["国产=20?v=20&x=1"])
    #expect(try await categories(#"title="&&"[不包含:广告#下一页]"#, #"?v=&&\&"#)
            == ["国产=20", "日本=21"])
}

@Test func replacesTheWayTheOriginalDoes() async throws {
    RuleSite.serve(["https://s11.invalid/": #"<b><a href="/voddetail/5.html">片</a></div><i></i></b>"#])
    func id(_ rule: String) async throws -> String? {
        let rules = ["主页url": "https://s11.invalid/", "分类url": "https://s11.invalid/{cateId}",
                     "分类数组": "<b>&&</b>", "分类标题": ">&&</a>", "分类ID": rule]
        let spider = try await xbpq(String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self))
        defer { Task { await spider.destroy() } }
        return try await classes(spider).first.map { String($0.dropFirst(2)) }
    }
    // 水果派: detail pages become play pages.
    #expect(try await id(#"href="&&"[替换:voddetail>>vodplay#.html>>-1-1.html]"#) == "/vodplay/5-1-1.html")
    // 天天's `</div>>></a>` is `</div>` → `</a>`, not `</div` → `></a>`.
    #expect(try await id(#"">&&<i>[替换:</div>>></a>]"#) == "片</a></a>")
    // A pair without `>>` (金陵撸铁汉's `play#.html>>…`) makes the original keep the text as it was.
    #expect(try await id(#"href="&&"[替换:play#.html>>/sid/1/nid/1.html]"#) == "/voddetail/5.html")
}

// MARK: - S3: the list

private func titles(_ json: String) throws -> [[String: String]] {
    let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    return (object["list"] as? [[String: Any]] ?? []).map { item in
        item.compactMapValues { $0 as? String }
    }
}

private func category(_ spider: JavaScriptSpiderRuntime, _ tid: String = "1") async throws -> [[String: String]] {
    try titles(try await spider.categoryContent(tid: tid, page: "1", filter: false, extend: [:]))
}

/// 18j's rule, verbatim apart from the host: `数组`, `标题`, `图片`, a literal-prefixed `副标题`.
@Test func listsWithTheOriginalListKeys() async throws {
    RuleSite.serve(["https://s12.invalid/t/1-1/": """
    <div class="video-list">
    <div class="item"><a href="/v/48829/" title="片一"><img data-original="/p/1.jpg" alt="10分钟"></a></div>
    <div class="item"><a href="/v/48830/" title="片二&amp;"><img data-original="https://cdn.invalid/2.jpg" alt="20分钟"></a></div>
    """])
    let spider = try await xbpq(#"""
    {"主页url":"https://s12.invalid/","分类url":"https://s12.invalid/t/{cateId}-{catePg}/;;z","分类":"国产$1",
     "数组":"class=\"&&</div>","标题":"title=\"&&\"","图片":"data-original=\"&&\"","副标题":"🌹+alt=\"&&\"","链接":"href=\"&&\""}
    """#)
    let list = try await category(spider)
    #expect(list.map { $0["vod_id"] } == ["https://s12.invalid/v/48829/", "https://s12.invalid/v/48830/"])
    #expect(list.map { $0["vod_name"] } == ["片一", "片二"])
    #expect(list.map { $0["vod_pic"] } == ["https://s12.invalid/p/1.jpg", "https://cdn.invalid/2.jpg"])
    #expect(list.map { $0["vod_remarks"] } == ["🌹10分钟", "🌹20分钟"])
    await spider.destroy()
}

/// Only `数组` set: every other key falls back to the original's default, and the default link
/// rule's [不包含:] keeps navigation out. `二次截取` narrows first; prefix and suffix wrap the link.
@Test func fallsBackToTheOriginalDefaultsForUnsetListKeys() async throws {
    RuleSite.serve(["https://s13.invalid/list/1/1": """
    <ul class="nav"><li><a href="/type/2.html" title="电影">电影</a></li></ul>
    <ul class="vod"><li><a href="/id/7" title="片七"><img original="/7.jpg"><span class="pic-text x">更新至3集</span></a></li>
    <li><a href="/type/9.html" title="导航">导航</a></li></ul>
    """])
    let spider = try await xbpq(#"""
    {"分类url":"https://s13.invalid/list/{cateId}/{catePg}","分类":"一$1","二次截取":"class=\"vod\">&&</ul>",
     "数组":"<li&&</li>","链接前缀":"/play","链接后缀":"-1-1"}
    """#)
    let list = try await category(spider)
    #expect(list.count == 1)
    #expect(list.first?["vod_id"] == "https://s13.invalid/play/id/7-1-1")
    #expect(list.first?["vod_name"] == "片七")
    #expect(list.first?["vod_pic"] == "https://s13.invalid/7.jpg")
    #expect(list.first?["vod_remarks"] == "更至3集")
    await spider.destroy()
}

/// `分类数组`/`分类标题`/`分类链接` find the categories on the home page; they are not list rules.
@Test func keepsCategoryKeysOutOfTheList() async throws {
    RuleSite.serve([
        "https://s14.invalid/": #"<li><a href="/vodtype/5.html">国产</a></li>"#,
        "https://s14.invalid/vodtype/5-1.html": """
        <div class="stui-vodlist"><li><a href="/voddetail/88.html" title="片八八" data-original="/88.jpg"></a></li></div>
        """])
    let spider = try await xbpq(#"""
    {"主页url":"https://s14.invalid/","分类url":"https://s14.invalid/vodtype/{cateId}-{catePg}.html",
     "分类数组":"<li&&</li>","分类标题":">&&</a","分类ID":"/vodtype/&&.html"}
    """#)
    #expect(try await classes(spider) == ["国产=5"])
    // No `数组`, so the 苹果CMS template reads the listing — before, `分类数组` was misread as one.
    #expect(try await category(spider, "5").map { $0["vod_name"] } == ["片八八"])
    await spider.destroy()
}

/// No `数组`, and links the 苹果CMS template does not take for detail pages (no trailing number):
/// the original's automatic `<li*>&&</li>` mode, whose [不包含:首页…] drops the navigation.
@Test func usesTheOriginalAutomaticModeWhenNoTemplateMatches() async throws {
    RuleSite.serve(["https://s15.invalid/c/1": """
    <ol><li class="nav"><a href="/c/two" title="首页">首页</a></li>
    <li class="card"><a href="/watch/abc" title="自动片">x</a></li></ol>
    """])
    let spider = try await xbpq(#"{"分类url":"https://s15.invalid/c/{cateId}","分类":"一$1"}"#)
    #expect(try await category(spider).map { $0["vod_name"] } == ["自动片"])
    await spider.destroy()
}

@Test func readsTheHomeSettingTheWayTheOriginalDoes() async throws {
    RuleSite.serve([
        "https://s16.invalid/": #"<i><a href="/v/1" title="首一"></a></i><i><a href="/v/2" title="首二"></a></i><i><a href="/v/3" title="首三"></a></i>"#,
        "https://s16.invalid/c/7": #"<i><a href="/v/9" title="分九"></a></i>"#])
    func home(_ setting: String?) async throws -> [String?] {
        var rules = ["主页url": "https://s16.invalid/", "分类url": "https://s16.invalid/c/{cateId}",
                     "分类": "甲$7", "数组": "<i>&&</i>"]
        if let setting { rules["首页"] = setting }
        let spider = try await xbpq(String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self))
        defer { Task { await spider.destroy() } }
        return try titles(try await spider.homeVideoContent()).map { $0["vod_name"] }
    }
    #expect(try await home("2") == ["首一", "首二"])        // a count of the home page's titles
    #expect(try await home("0") == [])                      // off
    #expect(try await home("甲$5") == ["分九"])             // a named category
    #expect(try await home("无圣光$abc") == [])             // not a count: the original shows nothing
    #expect(try await home(nil) == ["分九"])                // unset: the first category, as before
}

/// The original's fetch removes every whitespace character but the plain space before a rule sees
/// the page. 野鸡資源's `vod-img&&/div></div>` is written against that: the site sends
/// `</div>\n</div>`, and without the normalisation not one title matched.
@Test func readsListPagesWithTheOriginalWhitespaceRemoved() async throws {
    RuleSite.serve(["https://s17.invalid/yj/1/1.html": """
    <div class="vod">
    <div class="vod-img" id="content12">
    <a href="/yj/detail/id/1473126.html" target="_self">
    <img class="lazy" data-original="https://img.invalid/1.jpg">
    </a>
    </div>
    <div class="vod-txt" id="sui12">
    <a href="/yj/detail/id/1473126.html" target="_self">CJOD-525 叔母さん</a>
    </div>
    </div>
    """])
    let spider = try await xbpq(#"""
    {"分类url":"https://s17.invalid/yj/{cateId}/{catePg}.html","分类":"一$1",
     "数组":"vod-img&&/div></div>","标题":"🐔+vod-txt*\">&&</a","链接":"href=\"&&\"","图片":"data-original=\"&&\""}
    """#)
    let list = try await category(spider)
    #expect(list.map { $0["vod_name"] } == ["🐔CJOD-525 叔母さん"])
    #expect(list.first?["vod_id"] == "https://s17.invalid/yj/detail/id/1473126.html")
    #expect(list.first?["vod_pic"] == "https://img.invalid/1.jpg")
    await spider.destroy()
}

/// The whitespace removal is for the rules only. A 苹果CMS page whose attributes sit on their own
/// lines would lose the break between `<a` and `href` and no longer parse, so the templates keep
/// the page as sent.
@Test func keepsThePageAsSentForTheTemplates() async throws {
    RuleSite.serve(["https://s18.invalid/i/1-1.html": """
    <ul class="stui-vodlist"><li><a
    href="/voddetail/5.html"
    title="片五"><span>推荐</span></li></ul>
    """])
    // Only the template can read this one: the automatic `<li*>` mode excludes 推荐 and there is
    // no `</a>` for `<a&&</a>`, so a squashed `<ahref=` would leave nothing at all.
    let spider = try await xbpq(#"{"分类url":"https://s18.invalid/i/{cateId}-{catePg}.html","分类":"重生$1"}"#)
    #expect(try await category(spider).map { $0["vod_name"] } == ["片五"])
    await spider.destroy()
}

// MARK: - S4: detail and play

private func detail(_ spider: JavaScriptSpiderRuntime, _ id: String) async throws -> [String: String] {
    let object = try #require(try JSONSerialization.jsonObject(
        with: Data(try await spider.detailContent(ids: [id]).utf8)) as? [String: Any])
    let item = try #require((object["list"] as? [[String: Any]])?.first)
    return item.compactMapValues { $0 as? String }
}

private func play(_ spider: JavaScriptSpiderRuntime, _ id: String) async throws -> (url: String, parse: Int) {
    let object = try #require(try JSONSerialization.jsonObject(
        with: Data(try await spider.playerContent(flag: "", id: id, vipFlags: []).utf8)) as? [String: Any])
    return (object["url"] as? String ?? "", (object["parse"] as? NSNumber)?.intValue ?? -1)
}

/// 35 sites set 直接播放 and 45 carry the `z` flag: the listing's link is the play page, so the
/// detail is one line the original calls 直播列表, with the title as its only episode.
@Test func givesADirectPlaySiteOneEpisode() async throws {
    RuleSite.serve(["https://s19.invalid/v/1/": "<h1>片一</h1><p>no episode list here</p>"])
    for rules in [#"{"分类url":"https://s19.invalid/t/{cateId}-{catePg}/;;z","分类":"一$1"}"#,
                  #"{"分类url":"https://s19.invalid/t/{cateId}-{catePg}/","分类":"一$1","直接播放":"1"}"#] {
        let spider = try await xbpq(rules)
        let item = try await detail(spider, "https://s19.invalid/v/1/")
        #expect(item["vod_play_from"] == "直播列表")
        #expect(item["vod_play_url"] == "片一$https://s19.invalid/v/1/")
        await spider.destroy()
    }
}

/// `播放数组` per line, `播放列表`/`播放标题`/`播放链接` per episode, `线路数组`/`线路标题` for the names,
/// on the page with its line breaks removed; then 倒序 and 线路合并.
@Test func readsEpisodesWithTheOriginalDetailRules() async throws {
    RuleSite.serve(["https://s20.invalid/d/1.html": """
    <div class="tabs"><a class="tab">线路甲</a>
    <a class="tab">线路乙</a></div>
    <ul class="pl"><li><a href="/p/1-1.html">第1集</a></li><li><a href="/p/1-2.html">第2集</a></li>
    </ul>
    <ul class="pl"><li><a href="/p/2-1.html">HD</a></li>
    </ul>
    """])
    let base = #""分类url":"https://s20.invalid/{cateId}","分类":"一$1","线路数组":"class=\"tab\"&&</a>","线路标题":">&&","播放数组":"class=\"pl\">&&</ul>","播放列表":"<li>&&</li>","播放标题":">&&</a>","播放链接":"href=\"&&\"""#
    let plain = try await xbpq("{\(base)}")
    var item = try await detail(plain, "https://s20.invalid/d/1.html")
    #expect(item["vod_play_from"] == "线路甲$$$线路乙")
    #expect(item["vod_play_url"] == "第1集$https://s20.invalid/p/1-1.html#第2集$https://s20.invalid/p/1-2.html$$$HD$https://s20.invalid/p/2-1.html")
    await plain.destroy()

    let reversedMerged = try await xbpq("{\(base),\"倒序\":\"1\",\"线路合并\":\"1\",\"播放链接后缀\":\"?x=1\"}")
    item = try await detail(reversedMerged, "https://s20.invalid/d/1.html")
    #expect(item["vod_play_from"] == "线路甲")
    #expect(item["vod_play_url"] == "第2集$https://s20.invalid/p/1-2.html?x=1#第1集$https://s20.invalid/p/1-1.html?x=1#HD$https://s20.invalid/p/2-1.html?x=1")
    await reversedMerged.destroy()
}

/// `跳转播放链接`, the rule 22 sites use: `var player_*"url":"&&"` against a JSON-escaped address,
/// the `urlDecode(…)` wrapper, and a second hop through an intermediate page.
@Test func followsTheJumpRulesToTheStream() async throws {
    RuleSite.serve([
        "https://s21.invalid/play/1.html": #"<script>var player_aaaa={"flag":"play","url":"https:\/\/cdn.invalid\/a\/index.m3u8"}</script>"#,
        "https://s21.invalid/play/2.html": #"<script>var player_aaaa={"url":"https%3A%2F%2Fcdn.invalid%2Fb%2Findex.m3u8"}</script>"#,
        "https://s21.invalid/play/3.html": #"<iframe src="/jx/3.html"></iframe>"#,
        "https://s21.invalid/jx/3.html": #"<script>var src = "https://cdn.invalid/c/index.m3u8";</script>"#])
    let jump = try await xbpq(#"{"分类url":"https://s21.invalid/{cateId}","跳转播放链接":"var player_*\"url\":\"&&\""}"#)
    #expect(try await play(jump, "https://s21.invalid/play/1.html") == ("https://cdn.invalid/a/index.m3u8", 0))
    await jump.destroy()

    let decoded = try await xbpq(#"{"分类url":"https://s21.invalid/{cateId}","跳转播放链接":"urlDecode(var player*url\":\"&&\")"}"#)
    #expect(try await play(decoded, "https://s21.invalid/play/2.html") == ("https://cdn.invalid/b/index.m3u8", 0))
    await decoded.destroy()

    let hops = try await xbpq(#"{"分类url":"https://s21.invalid/{cateId}","跳转播放链接":"<iframe src=\"&&\"","二次跳转播放链接":"var src = \"&&\""}"#)
    #expect(try await play(hops, "https://s21.invalid/play/3.html") == ("https://cdn.invalid/c/index.m3u8", 0))
    await hops.destroy()
}

/// 免嗅 reads the `player_*` JSON, including encrypt 2 (base64 of the escaped address); `嗅探词` decides
/// what counts as a stream, so a site that only accepts `.mp4` hands an m3u8 page to the sniffer.
@Test func readsThePlayerJSONAndHonoursTheSniffWords() async throws {
    RuleSite.serve([
        "https://s22.invalid/play/e2.html": #"<script>var player_aaaa={"encrypt":2,"url":"aHR0cHMlM0ElMkYlMkZjZG4uaW52YWxpZCUyRmUyJTJGaW5kZXgubTN1OA=="}</script>"#])
    let mac = try await xbpq(#"{"分类url":"https://s22.invalid/{cateId}"}"#)
    #expect(try await play(mac, "https://s22.invalid/play/e2.html") == ("https://cdn.invalid/e2/index.m3u8", 0))
    await mac.destroy()

    let mp4Only = try await xbpq(#"{"分类url":"https://s22.invalid/{cateId}","嗅探词":".mp4"}"#)
    #expect(try await play(mp4Only, "https://s22.invalid/play/e2.html") == ("https://s22.invalid/play/e2.html", 1))
    await mp4Only.destroy()
}

/// No `播放数组` and no 苹果CMS play list: no episodes, rather than the original's automatic rules
/// turning the page's other links into episodes — on 歐視 those were its introduction pages.
@Test func makesNoEpisodesOutOfUnrelatedLinks() async throws {
    RuleSite.serve(["https://s23.invalid/d/9.html": """
    <h1>片九</h1><a href="/introduction/index/1/1.html">简介1</a><a href="/introduction/index/1/2.html">第2集介绍</a>
    """])
    let spider = try await xbpq(#"{"分类url":"https://s23.invalid/{cateId}","分类":"一$1"}"#)
    let item = try await detail(spider, "https://s23.invalid/d/9.html")
    #expect(item["vod_play_from"] == "")
    #expect(item["vod_play_url"] == "")
    await spider.destroy()
}

// MARK: - S5: search

private func search(_ spider: JavaScriptSpiderRuntime, _ key: String, page: String = "1") async throws -> [[String: String]] {
    try titles(try await spider.searchContent(key: key, quick: false, page: page))
}

/// 45 sites put the page in `{pg}` and 6 in `{catePg}`; the port only knew `{SearchPg}`, so the
/// page segment came out empty. 天美 keeps its address in `搜索链接`, which the original accepts too.
@Test func fillsTheSearchPagePlaceholders() async throws {
    let pg = try await xbpq(#"{"分类url":"https://s24.invalid/{cateId}","搜索url":"https://s24.invalid/search/{wd}/page/{pg}.html;;z"}"#)
    _ = try await search(pg, "片", page: "2")
    let catePg = try await xbpq(#"{"分类url":"https://s24.invalid/{cateId}","搜索链接":"/vod/search/page/{catePg}/wd/{wd}.html"}"#)
    _ = try await search(catePg, "片")
    #expect(RuleSite.requests(on: "s24.invalid") == [
        "https://s24.invalid/search/%E7%89%87/page/2.html",
        "https://s24.invalid/vod/search/page/1/wd/%E7%89%87.html"])
    await pg.destroy()
    await catePg.destroy()
}

@Test func readsSearchResultsWithTheSearchKeysOrTheListOnes() async throws {
    RuleSite.serve(["https://s26.invalid/s/%E7%89%87": """
    <div class="nav"><a href="/type/1.html" title="电影">电影</a></div>
    <div class="result"><div class="r"><a href="/detail/7.html" title="片七"><img original="/7.jpg"></a><em>HD</em></div></div>
    """])
    // `搜索数组` set: the search keys, their defaults, a prefix, and `搜索链接` as the link rule
    // because the address came from `搜索url`.
    let own = try await xbpq(#"""
    {"分类url":"https://s26.invalid/{cateId}","搜索url":"https://s26.invalid/s/{wd}","搜索二次截取":"class=\"result\">&&</div></div>",
     "搜索数组":"class=\"r\">&&</em>","搜索链接":"href=\"/detail/&&\"","搜索链接前缀":"/play/","搜索副标题":"<em>&&"}
    """#)
    var list = try await search(own, "片")
    #expect(list.map { $0["vod_name"] } == ["片七"])
    #expect(list.first?["vod_id"] == "https://s26.invalid/play/7.html")
    #expect(list.first?["vod_pic"] == "https://s26.invalid/7.jpg")
    #expect(list.first?["vod_remarks"] == "HD")
    await own.destroy()

    // No `搜索数组`: the page is read like a listing, with the list's `数组`.
    let listing = try await xbpq(#"{"分类url":"https://s26.invalid/{cateId}","搜索url":"https://s26.invalid/s/{wd}","数组":"class=\"r\">&&</div>"}"#)
    list = try await search(listing, "片")
    #expect(list.map { $0["vod_id"] } == ["https://s26.invalid/detail/7.html"])
    await listing.destroy()
}

/// 妻妹 sets `搜索链接` to a slicing rule and has no address: nothing to search, rather than
/// requesting the rule as if it were a URL.
@Test func doesNotTakeALinkRuleForTheSearchAddress() async throws {
    let spider = try await xbpq(#"{"分类url":"https://s27.invalid/{cateId}","搜索链接":"/vodplay/+/voddetail/&&.html+-1-1.html"}"#)
    #expect(try await search(spider, "片").isEmpty)
    #expect(RuleSite.requests(on: "s27.invalid").isEmpty)
    await spider.destroy()
}
