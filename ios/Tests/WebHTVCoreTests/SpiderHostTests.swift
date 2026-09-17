import Foundation
import Testing
@testable import WebHTVCore

private func site(_ json: String) throws -> Site {
    try JSONDecoder().decode(Site.self, from: Data(json.utf8))
}

private func runtime(_ script: String, siteKey: String = "t") throws -> JavaScriptSpiderRuntime {
    let registry = SpiderRegistry.bundled()
    #expect(!registry.prelude.isEmpty, "host.js must be bundled as a resource")
    return try JavaScriptSpiderRuntime(
        name: "test", script: script, prelude: registry.prelude,
        storage: SpiderStorage(siteKey: siteKey, defaults: .standard)
    )
}

// MARK: - routing

@Test func routesCSPSitesThroughTheRegistryRatherThanRejectingTypeThree() throws {
    let appGet = try site(#"{"key":"猎豹","name":"猎豹","type":3,"api":"csp_AppGet","ext":{"url":"https://e.example","dataKey":"k","dataIv":"i"}}"#)
    let unported = try site(#"{"key":"x","name":"x","type":3,"api":"csp_NotPortedYet"}"#)
    let python = try site(#"{"key":"p","name":"p","type":3,"api":"./py/x.py"}"#)

    #expect(appGet.isCSPSpider)
    #expect(unported.isCSPSpider)
    // A python type-3 is not a csp_ spider and must not be routed to the registry.
    #expect(!python.isCSPSpider)

    let resolver = CSPSourceResolver()
    #expect(resolver.canResolve(appGet))
    #expect(!resolver.canResolve(unported))
    #expect(resolver.portability(of: appGet) == .httpCrypto)
    #expect(throws: SpiderError.notRegistered("csp_NotPortedYet")) {
        _ = try resolver.registry.makeRuntime(for: unported.api, siteKey: "x")
    }
    #expect(SpiderRegistry.className(from: "csp_AppGet") == "AppGet")
    #expect(SpiderRegistry.className(from: "AppGet") == "AppGet")
}

@Test func preservesEveryExtShapeInsteadOfFlatteningToStringPairs() throws {
    // csp_App99 mixes strings and numbers, csp_AppDrama carries an RSA key, and some sites make ext
    // a bare string. The old `[String: String]` decode dropped all but the first shape.
    let mixed = try site(#"{"key":"a","name":"a","type":3,"api":"csp_App99","ext":{"host":"https://h","port":8080,"vip":true,"tags":["a","b"],"nested":{"k":"v"},"none":null}}"#)
    let decoded = try #require(try JSONSerialization.jsonObject(with: Data(mixed.rawExtJSON.utf8)) as? [String: Any])
    #expect(decoded["host"] as? String == "https://h")
    #expect(decoded["port"] as? Double == 8080)
    #expect(decoded["vip"] as? Bool == true)
    #expect((decoded["tags"] as? [Any])?.count == 2)
    #expect((decoded["nested"] as? [String: Any])?["k"] as? String == "v")

    // A string ext reaches the spider verbatim, as Site.getExt() gives it on Android.
    let asString = try site(#"{"key":"b","name":"b","type":3,"api":"csp_X","ext":"https://cfg.example/a.json"}"#)
    #expect(asString.rawExtJSON == "https://cfg.example/a.json")

    let absent = try site(#"{"key":"c","name":"c","type":3,"api":"csp_X"}"#)
    #expect(absent.rawExtJSON.isEmpty)
}

// MARK: - JS bridge

@Test func bridgesValuesAndErrorsBetweenSwiftAndJavaScript() async throws {
    let spider = try runtime("""
    module.exports = {
      init: function (e) { this.ext = e; return ''; },
      homeContent: function (filter) { return { list: [], filter: filter, ext: this.ext }; },
      searchContent: function (k, q, p) { return JSON.stringify({ k: k, q: q, p: p }); },
      isVideoFormat: function (u) { return /m3u8/.test(u); },
      boom: function () { throw new Error('exploded'); }
    };
    """)

    try await spider.initialize(extend: #"{"a":1}"#)
    // An object return is serialised; a string return passes through. Both reach the app as JSON.
    let home = try await spider.homeContent(filter: true)
    let decodedHome = try #require(try JSONSerialization.jsonObject(with: Data(home.utf8)) as? [String: Any])
    #expect(decodedHome["filter"] as? Bool == true)
    // `ext` reaches the spider as the verbatim string CatVod passes, so it nests as a string.
    #expect(decodedHome["ext"] as? String == #"{"a":1}"#)
    let search = try await spider.searchContent(key: "仙逆", quick: false, page: "2")
    let decoded = try #require(try JSONSerialization.jsonObject(with: Data(search.utf8)) as? [String: Any])
    #expect(decoded["k"] as? String == "仙逆")
    #expect(decoded["p"] as? String == "2")
    #expect(try await spider.isVideoFormat(url: "https://a/b.m3u8"))
    #expect(try await spider.isVideoFormat(url: "https://a/b.html") == false)

    // A missing optional method degrades to empty rather than throwing, as Spider.java's no-op does.
    #expect(try await spider.liveContent(url: "x").isEmpty)
    await #expect(throws: SpiderError.self) { _ = try await spider.detailContent(ids: ["1"]) }
}

@Test func rejectsAScriptThatNeverExportsASpider() throws {
    let registry = SpiderRegistry.bundled()
    #expect(throws: SpiderError.self) {
        _ = try JavaScriptSpiderRuntime(name: "bad", script: "var x = 1;", prelude: registry.prelude,
                                        storage: SpiderStorage(siteKey: "bad"))
    }
}

// MARK: - host: crypto

@Test func reproducesTheExactCipherTheDecompiledSpidersUse() async throws {
    // C0393a.a() is Cipher.getInstance("AES/CBC/PKCS7Padding") with a String key and IV, which is
    // what csp_AppGet's `dataKey`/`dataIv` are. Round-trip plus a fixed vector.
    let spider = try runtime("""
    module.exports = {
      init: function () { return ''; },
      homeContent: function () {
        var key = '#getapp@TMD@2025';
        var cipher = host.aesEncrypt('hello spider', key, key, 'CBC');
        return {
          cipher: cipher,
          roundTrip: host.aesDecrypt(cipher, key, key, 'CBC', 'base64'),
          ecb: host.aesDecrypt(host.aesEncrypt('ecb text', key, '', 'ECB'), key, '', 'ECB', 'base64'),
          md5: host.md5('abc'),
          sha1: host.sha1('abc'),
          sha256: host.sha256('abc'),
          hmac: host.hmac('sha256', 'abc', 'key'),
          b64: host.base64.decode(host.base64.encode('往返')),
          enc: host.dec(host.enc('a b&c'))
        };
      }
    };
    """)
    let out = try #require(try JSONSerialization.jsonObject(
        with: Data(try await spider.homeContent(filter: true).utf8)) as? [String: Any])

    #expect(out["roundTrip"] as? String == "hello spider")
    #expect(out["ecb"] as? String == "ecb text")
    // Known vectors, so a broken CommonCrypto binding cannot pass by round-tripping itself.
    #expect(out["md5"] as? String == "900150983cd24fb0d6963f7d28e17f72")
    #expect(out["sha1"] as? String == "a9993e364706816aba3e25717850c26c9cd0d89d")
    #expect(out["sha256"] as? String == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(out["b64"] as? String == "往返")
    #expect(out["enc"] as? String == "a b&c")
}

// MARK: - host: HTML

@Test func selectsNodesAndAttributesTheWayDrpyRulesExpect() async throws {
    let spider = try runtime("""
    module.exports = {
      init: function () { return ''; },
      homeContent: function () {
        var html = '<html><body><div class="vod list" id="main">' +
                   '<a class="item" href="/v/1"><span class="title">First</span><img src="/p/1.jpg"></a>' +
                   '<a class="item" href="/v/2"><span class="title">Second</span><img src="/p/2.jpg"></a>' +
                   '</div><script>var junk = "<a class=\\'item\\'>";</script></body></html>';
        var items = host.pdfa(html, '.vod a.item');
        return {
          count: items.length,
          firstTitle: host.pdfh(items[0], '.title&&Text'),
          secondHref: host.pdfh(items[1], 'a&&href') || items[1].attrs.href,
          pic: host.pdfh(items[0], 'img&&src'),
          joined: host.pd(items[1], 'img&&src', 'https://e.example/list/'),
          byId: host.pdfh(html, '#main .title&&Text'),
          eq: host.pdfh(html, '.item:eq(1) .title&&Text'),
          attrSel: host.pdfa(html, 'a[href^=/v/]').length,
          text: host.pdfh(html, '.title&&Text')
        };
      }
    };
    """)
    let out = try #require(try JSONSerialization.jsonObject(
        with: Data(try await spider.homeContent(filter: true).utf8)) as? [String: Any])

    // A <script> body holding markup must not become elements.
    #expect(out["count"] as? Double == 2)
    #expect(out["firstTitle"] as? String == "First")
    #expect(out["pic"] as? String == "/p/1.jpg")
    #expect(out["joined"] as? String == "https://e.example/p/2.jpg")
    #expect(out["byId"] as? String == "First")
    #expect(out["eq"] as? String == "Second")
    #expect(out["attrSel"] as? Double == 2)
}

// MARK: - host: storage and session isolation

@Test func keepsTwoSitesOnTheSameSpiderClassFullyIsolated() async throws {
    let script = """
    module.exports = {
      init: function (e) { this.tag = e; return ''; },
      homeContent: function () {
        host.local.set('token', this.tag);
        return { token: host.local.get('token'), tag: this.tag };
      }
    };
    """
    let defaults = try #require(UserDefaults(suiteName: "spider.isolation"))
    defaults.removePersistentDomain(forName: "spider.isolation")

    let one = try JavaScriptSpiderRuntime(name: "a", script: script, prelude: SpiderRegistry.bundled().prelude,
                                          storage: SpiderStorage(siteKey: "siteA", defaults: defaults))
    let two = try JavaScriptSpiderRuntime(name: "b", script: script, prelude: SpiderRegistry.bundled().prelude,
                                          storage: SpiderStorage(siteKey: "siteB", defaults: defaults))
    try await one.initialize(extend: "A")
    try await two.initialize(extend: "B")

    // Run both concurrently: separate JSContexts on separate queues must not see each other's state.
    async let first = one.homeContent(filter: true)
    async let second = two.homeContent(filter: true)
    let (a, b) = try await (first, second)
    #expect(a.contains("\"token\":\"A\""))
    #expect(b.contains("\"token\":\"B\""))
    #expect(defaults.string(forKey: "spider_siteA_token") == "A")
    #expect(defaults.string(forKey: "spider_siteB_token") == "B")

    await one.destroy()
    defaults.removePersistentDomain(forName: "spider.isolation")
}

@Test func cookiesAreScopedPerHostAndPerSession() {
    let jar = CookieJar()
    let a = try! #require(URL(string: "https://one.example/x"))
    let b = try! #require(URL(string: "https://two.example/x"))
    jar.store("sid=111; Path=/; HttpOnly", for: a)
    jar.store("sid=222; Path=/", for: b)
    #expect(jar.header(for: a) == "sid=111")
    #expect(jar.header(for: b) == "sid=222")

    // A second session starts empty — no shared login between two sites on one spider class.
    #expect(CookieJar().header(for: a).isEmpty)
    jar.clear()
    #expect(jar.header(for: a).isEmpty)
}

// MARK: - errors and timeouts

@Test func surfacesScriptErrorsAndHonoursAShortTimeout() async throws {
    let spider = try runtime("""
    module.exports = {
      init: function () { return ''; },
      homeContent: function () { throw new Error('site is down'); },
      categoryContent: function () {
        // 1 ms budget against a black-hole address: the host must give up, not hang.
        var res = host.get('http://10.255.255.1/never', { timeout: 1 });
        return { status: res.status, error: res.error || '' };
      }
    };
    """)
    await #expect(throws: SpiderError.self) { _ = try await spider.homeContent(filter: true) }

    let out = try await spider.categoryContent(tid: "1", page: "1", filter: false, extend: [:])
    let decoded = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    #expect(decoded["status"] as? Double == 0)
    #expect((decoded["error"] as? String)?.isEmpty == false)
}

// MARK: - host: rule-engine primitives

@Test func slicesTextTheWayXBPQRulesDo() async throws {
    // XBPQ rules slice between markers instead of querying a DOM, with [包含:]/[不包含:]/[替换:]
    // modifiers. Recovered by decoding the engine's obfuscated string table (hex + XOR "wxEesU").
    let spider = try runtime("""
    module.exports = {
      init: function () { return ''; },
      homeContent: function () {
        var html = '<i>A1</i><i>B2</i><i>A3</i>';
        return {
          all: host.cut(html, '<i>&&</i>'),
          first: host.cut1(html, '<i>&&</i>'),
          include: host.cut(html, '<i>&&</i>[包含:A]'),
          exclude: host.cut(html, '<i>&&</i>[不包含:A]'),
          replaced: host.cut1(html, '<i>&&</i>[替换:A>>Z]'),
          missing: host.cut(html, '<b>&&</b>'),
          stripped: host.stripTags('<p>hello &amp; <b>world</b></p>')
        };
      }
    };
    """)
    let out = try #require(try JSONSerialization.jsonObject(
        with: Data(try await spider.homeContent(filter: true).utf8)) as? [String: Any])
    #expect(out["all"] as? [String] == ["A1", "B2", "A3"])
    #expect(out["first"] as? String == "A1")
    #expect(out["include"] as? [String] == ["A1", "A3"])
    #expect(out["exclude"] as? [String] == ["B2"])
    #expect(out["replaced"] as? String == "Z1")
    #expect(out["missing"] as? [String] == [])
    #expect(out["stripped"] as? String == "hello & world")
}

@Test func followsHikerRuleSyntaxIncludingFirstMatchDescent() async throws {
    let spider = try runtime("""
    module.exports = {
      init: function () { return ''; },
      homeContent: function () {
        // Two lists inside one container: the line tabs, then the episodes. Hiker's `&&` descends
        // into the *first* match at each step, so "#box&&ul&&li" must yield only the tabs.
        var html = '<div id="box"><div class="hd"><ul><li><a>线路A</a></li><li><a>线路B</a></li></ul></div>' +
                   '<div class="numList"><ul><li><a href="/p/1">第01集</a></li><li><a href="/p/2">第02集</a></li></ul></div></div>' +
                   '<span class="d">简介:实际内容</span>' +
                   '<div class="pic"style="x"><img data-echo="/e.jpg"></div>' +
                   '<ul class="m"><li>no image</li><li><img src="/y.jpg">has image</li></ul>';
        return {
          tabs: host.pdfa(html, '#box&&ul&&li').length,
          tabText: host.pdfh(host.pdfa(html, '#box&&ul&&li')[0], 'Text'),
          episodes: host.pdfa(html, '#box&&.numList&&li').length,
          fallbackAttr: host.pdfh(html, '.pic&&img&&data-echo||data-src||src'),
          strip: host.pdfh(html, '.d&&Text!简介:'),
          hasImage: host.pdfa(html, '.m li:has(img)').length,
          index: host.pdfh(html, '#box .numList li,-1&&Text')
        };
      }
    };
    """)
    let out = try #require(try JSONSerialization.jsonObject(
        with: Data(try await spider.homeContent(filter: true).utf8)) as? [String: Any])
    // The whole point: 2, not 4 — descending into every ul would sweep the episodes in as well.
    #expect(out["tabs"] as? Double == 2)
    #expect(out["tabText"] as? String == "线路A")
    #expect(out["episodes"] as? Double == 2)
    // Malformed `class="pic"style="x"` with no separating space must still parse.
    #expect(out["fallbackAttr"] as? String == "/e.jpg")
    #expect(out["strip"] as? String == "实际内容")
    #expect(out["hasImage"] as? Double == 1)
    #expect(out["index"] as? String == "第02集")
}

@Test func resolvesARuleFileExtAgainstTheConfigurationDirectory() throws {
    // A rule-engine site points ext at a sibling file rather than inlining its rules; it must be
    // resolved the same way ./jar/ and ./py/ references already are.
    let remote = try #require(URL(string: "https://cfg.example/user/repo/wang-movie.json"))
    let resolver = CSPSourceResolver(source: .remote(remote))
    let hiker = try JSONDecoder().decode(Site.self, from: Data(
        #"{"key":"n","name":"n","type":3,"api":"csp_XYQHiker","ext":"./json/农民影视.json"}"#.utf8))
    // Percent-encoded, because the result is a URL the spider will fetch.
    #expect(resolver.resolvedExtend(for: hiker)
        == "https://cfg.example/user/repo/json/%E5%86%9C%E6%B0%91%E5%BD%B1%E8%A7%86.json")

    // Inline rules and absolute URLs are handed over untouched.
    let inline = try JSONDecoder().decode(Site.self, from: Data(
        #"{"key":"i","name":"i","type":3,"api":"csp_XYQHiker","ext":{"分类名称":"电影"}}"#.utf8))
    #expect(resolver.resolvedExtend(for: inline).hasPrefix("{"))
    let absolute = try JSONDecoder().decode(Site.self, from: Data(
        #"{"key":"a","name":"a","type":3,"api":"csp_XYQHiker","ext":"https://x.example/r.json"}"#.utf8))
    #expect(resolver.resolvedExtend(for: absolute) == "https://x.example/r.json")
}

/// `host.parseJSON` is Gson-lenient because real rule files are: `巴士动漫.json` and `動漫巴士.json`
/// comment keys out with `//`, and a strict `JSON.parse` turned both sites into an empty home.
@Test func parsesTheLenientJSONRealRuleFilesActuallyContain() async throws {
    let runtime = try JavaScriptSpiderRuntime(
        name: "LenientJSON",
        script: """
        module.exports = {
            init: function (extend) { return ''; },
            action: function (a) { var r = host.parseJSON(a); return r === null ? 'NULL' : JSON.stringify(r); }
        };
        """,
        prelude: SpiderRegistry.bundled().prelude,
        storage: SpiderStorage(siteKey: "lenient", defaults: UserDefaults(suiteName: "lenient")!)
    )

    // Strict JSON still parses unchanged.
    #expect(try await runtime.action(#"{"a":"1"}"#) == #"{"a":"1"}"#)

    // Line comments, the exact shape the two 巴士 rule files use.
    let commented = """
    {
        "分类链接": "https://dm84.net/list-{cateId}-{catePg}.html",
        "筛选数据": {},
        //"筛选数据": "ext",
        //{cateId}
        "筛选子分类名称": ""
    }
    """
    let decoded = try await runtime.action(commented)
    #expect(decoded.contains("dm84.net"), "a commented rule file must still yield its rules")
    #expect(!decoded.contains("ext"), "the commented-out key must not come back")

    // A `//` inside a string is part of the value, not a comment — every URL has one.
    #expect(try await runtime.action(#"{"u":"https://a.b/c"}"#).contains("https://a.b/c"))
    // Block comments and trailing commas.
    #expect(try await runtime.action("{/* hi */\"a\":1,}") == #"{"a":1}"#)
    // Genuinely unparseable text is reported, not silently turned into an empty object.
    #expect(try await runtime.action("not json at all") == "NULL")

    await runtime.destroy()
}
