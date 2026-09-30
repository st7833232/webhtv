import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-39: the XBPQ rule semantics recovered from `xyqxbpq.jar`
// (docs/IOS-POC-39-xbpq-rule-coverage.md, section 4), driven through the bundled `XBPQ.js` against
// canned pages. Every test owns its own `.invalid` host, so they can run side by side.

/// Answers from `pages` by exact URL (404 otherwise) and remembers every URL it was asked for.
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
    _ = try await spider.categoryContent(tid: "2", page: "1", filter: false, extend: [:])
    #expect(RuleSite.requests(on: "s1.invalid").last == "https://s1.invalid/t/2-1/")
    await spider.destroy()
}

@Test func takesAnExtURLWithACategoryPlaceholderAsTheCategoryURL() async throws {
    let spider = try await xbpq("https://s2.invalid/list/{cateId}/{catePg}.html")
    _ = try await spider.categoryContent(tid: "7", page: "3", filter: false, extend: [:])
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
    _ = try await spider.categoryContent(tid: "1", page: "1", filter: false, extend: [:])
    #expect(RuleSite.requests(on: "s4.invalid") == ["https://s4.invalid/c/1_1.html"])
    await spider.destroy()
}

@Test func buildsCategoryURLsTheWayTheOriginalDoes() async throws {
    // An unfilled placeholder goes, and so does the `/名/` segment named after it.
    let filters = try await xbpq(#"{"分类url":"https://s5.invalid/vod/show/area/{area}/by/{by}/id/{cateId}/page/{catePg}/year/{year}.html","分类":"一$1"}"#)
    _ = try await filters.categoryContent(tid: "5", page: "1", filter: false, extend: [:])
    #expect(RuleSite.requests(on: "s5.invalid") == ["https://s5.invalid/vod/show/id/5/page/1.html"])
    await filters.destroy()

    // The first page may have an address of its own, in brackets.
    let firstPage = try await xbpq(#"{"分类url":"https://s6.invalid/t/{cateId}_{catePg}.html[firstPage=https://s6.invalid/t/{cateId}.html]","分类":"一$1"}"#)
    _ = try await firstPage.categoryContent(tid: "9", page: "1", filter: false, extend: [:])
    _ = try await firstPage.categoryContent(tid: "9", page: "2", filter: false, extend: [:])
    #expect(RuleSite.requests(on: "s6.invalid") == ["https://s6.invalid/t/9.html", "https://s6.invalid/t/9_2.html"])
    await firstPage.destroy()

    // Pages count from `起始页`, and a relative template joins the site.
    let offset = try await xbpq(#"{"主页url":"https://s7.invalid/","分类url":"/list/{cateId}/{catePg}","起始页":"2","分类":"一$1"}"#)
    _ = try await offset.categoryContent(tid: "3", page: "1", filter: false, extend: [:])
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
