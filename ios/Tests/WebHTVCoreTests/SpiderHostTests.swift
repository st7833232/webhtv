import CommonCrypto
import Foundation
import JavaScriptCore
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
          hmacMD5: host.hmac('md5', 'abc', 'key'),
          hmacSHA1: host.hmac('sha1', 'abc', 'key'),
          hmacNoKey: host.hmac('sha256', 'abc', ''),
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
    #expect(out["hmac"] as? String == "9c196e32dc0175f86f4b1cb89289d6619de6bee699e4c378e68309ed97a1a6ab")
    #expect(out["hmacMD5"] as? String == "d2fe98063f876b03193afb49b4979591")
    #expect(out["hmacSHA1"] as? String == "4fd0b215276ef12f2b3e4c8ecac2811498b656fc")
    #expect(out["hmacNoKey"] as? String == "fd7adb152c05ef80dccf50a1fa4c05d5a3ec6da95575fc312ae7c5d091836351")
    #expect(out["b64"] as? String == "往返")
    #expect(out["enc"] as? String == "a b&c")
}

/// `csp_App99` ships `base64(iv‖ciphertext)` under a fresh IV per request and reads the reply the
/// same way, which is the one cipher shape the string-IV helpers cannot express.
@Test func carriesTheIVInFrontOfTheCiphertextTheWayApp99Does() async throws {
    let spider = try runtime("""
    module.exports = {
      init: function () { return ''; },
      homeContent: function () {
        // The key is a uuid with its dashes removed, so 32 bytes: AES-256.
        var key = '0f8fad5bd9cb469fa16570867728950e';
        var first = host.aesEncryptIV('{"kw":"","page":"1"}', key);
        var second = host.aesEncryptIV('{"kw":"","page":"1"}', key);
        return {
          roundTrip: host.aesDecryptIV(first, key),
          // A fresh IV every call is the point: the same plaintext must not encrypt alike twice.
          differs: first !== second,
          // 16 bytes of IV + one AES block for a 20-byte body = 48 bytes = 64 base64 characters.
          length: first.length,
          crossDecrypt: host.aesDecryptIV(second, key),
          wrongKey: host.aesDecryptIV(first, '0f8fad5bd9cb469fa16570867728950f') === '{"kw":"","page":"1"}',
          truncated: host.aesDecryptIV('c2hvcnQ=', key)
        };
      }
    };
    """)
    let out = try #require(try JSONSerialization.jsonObject(
        with: Data(try await spider.homeContent(filter: true).utf8)) as? [String: Any])

    #expect(out["roundTrip"] as? String == "{\"kw\":\"\",\"page\":\"1\"}")
    #expect(out["crossDecrypt"] as? String == "{\"kw\":\"\",\"page\":\"1\"}")
    #expect(out["differs"] as? Bool == true)
    #expect(out["length"] as? Int == 64)
    // A wrong key yields rubbish or nothing — never the plaintext — and a payload shorter than the
    // IV is an empty result rather than a crash.
    #expect(out["wrongKey"] as? Bool == false)
    #expect(out["truncated"] as? String == "")
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
}

// MARK: - errors and timeouts

@Test func surfacesScriptErrorsAndHonoursAShortTimeout() async throws {
    let spider = try runtime("""
    module.exports = {
      init: function () { return ''; },
      homeContent: function () { throw new Error('site is down'); },
      // Not categoryContent: an empty listing behind a failed request is a SiteUnreachable there
      // (IOS-POC-41A), and this checks the raw answer the host gives the spider.
      searchContent: function () {
        // 1 ms budget against a black-hole address: the host must give up, not hang.
        var res = host.get('http://10.255.255.1/never', { timeout: 1 });
        return { status: res.status, error: res.error || '' };
      }
    };
    """)
    await #expect(throws: SpiderError.self) { _ = try await spider.homeContent(filter: true) }

    let out = try await spider.searchContent(key: "x", quick: false, page: "1")
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

@Test func sharesTheMirrorListAndVideoChecksThePortsUsed() async throws {
    // IOS-POC-54: `AppGet`/`AppQi` read a mirror list and eleven ports shared one extension check;
    // both now live in host.js, and these are the cases the ports' copies handled.
    let spider = try runtime("""
    module.exports = {
      init: function () { return ''; },
      homeContent: function () {
        return {
          mirror: host.firstURL('# hosts\\n  \\n  https://a.invalid/ \\nhttps://b.invalid'),
          none: host.firstURL('ftp://x\\nnothing'),
          empty: host.firstURL(undefined),
          video: ['https://a/b.m3u8', 'b.MP4?x=1', 'c.flv', 'd.ts', 'e.mp4x', ''].map(host.isVideoFormat)
        };
      }
    };
    """)
    let out = try #require(try JSONSerialization.jsonObject(
        with: Data(try await spider.homeContent(filter: true).utf8)) as? [String: Any])
    #expect(out["mirror"] as? String == "https://a.invalid/")
    #expect(out["none"] as? String == "")
    #expect(out["empty"] as? String == "")
    #expect(out["video"] as? [Bool] == [true, true, true, false, false, false])
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

/// Jsoup's `Element.select()` collects from the element itself, so a rule read against a node can
/// match that node. 巴士动漫 selects episodes with `a` and then reads each with `a&&href`; without
/// self-matching every episode is skipped and the title lists zero flags.
@Test func matchesTheNodeItselfTheWayJsoupSelectDoes() async throws {
    let runtime = try JavaScriptSpiderRuntime(
        name: "SelfMatch",
        script: """
        module.exports = {
            init: function () { return ''; },
            action: function (a) {
                var doc = host.parse('<ul class="play_list"><li><a href="/p/1.html">117</a></li>' +
                                     '<li><a href="/p/2.html">116</a></li></ul>');
                var items = host.pdfa(doc, '.play_list&&a');
                var out = items.map(function (n) {
                    return host.pdfh(n, 'a&&Text') + '|' + host.pdfh(n, 'a&&href');
                });
                // A descendant rule must still descend, not collapse onto the scope node.
                out.push('desc=' + host.pdfa(doc, '.play_list&&li').length);
                return out.join(',');
            }
        };
        """,
        prelude: SpiderRegistry.bundled().prelude,
        storage: SpiderStorage(siteKey: "selfmatch", defaults: UserDefaults(suiteName: "selfmatch")!)
    )
    let result = try await runtime.action("")
    #expect(result.contains("117|/p/1.html"), "an <a> node must satisfy `a&&href` against itself")
    #expect(result.contains("116|/p/2.html"))
    // The `li` rule must still find the two list items, not the <ul> it was scoped to.
    #expect(result.contains("desc=2"))
    await runtime.destroy()
}

/// An undefined rule key is not a request for the node's whole text. Rule files leave 详情 fields
/// empty all the time, and returning the document text made 巴士动漫 report its year as the page.
@Test func treatsAnEmptyRuleAsNoValueRatherThanTheWholeNode() async throws {
    let runtime = try JavaScriptSpiderRuntime(
        name: "EmptyRule",
        script: """
        module.exports = {
            init: function () { return ''; },
            action: function () {
                var doc = host.parse('<div class="x"><span>hello</span></div>');
                return JSON.stringify({
                    empty: host.pdfh(doc, ''),
                    undef: host.pdfh(doc, undefined),
                    blank: host.pdfh(doc, '   '),
                    text: host.pdfh(doc, '.x&&Text'),
                    self: host.pdfh(doc, 'Text').length > 0
                });
            }
        };
        """,
        prelude: SpiderRegistry.bundled().prelude,
        storage: SpiderStorage(siteKey: "emptyrule", defaults: UserDefaults(suiteName: "emptyrule")!)
    )
    let out = try await runtime.action("")
    #expect(out.contains("\"empty\":\"\""))
    #expect(out.contains("\"undef\":\"\""))
    #expect(out.contains("\"blank\":\"\""))
    // A real rule still works, and an explicit bare `Text` still means this node's text.
    #expect(out.contains("\"text\":\"hello\""))
    #expect(out.contains("\"self\":true"))
    await runtime.destroy()
}

/// The nav filter itself, which is where the 永乐 fault actually lived.
@Test func rejectsVodPrefixedNavLinksButKeepsDetailLinks() async throws {
    let runtime = try JavaScriptSpiderRuntime(
        name: "NavFilter",
        script: """
        module.exports = {
            init: function () { return ''; },
            action: function (link) {
                var isNav = /\\/(vod)?(type|show|label|search|area|year|by|class|lang)\\//i.test(link);
                var looksIndexed = /\\/\\d+\\.html|id[=\\/]\\d+|\\/\\d+\\/?$/.test(link);
                return JSON.stringify({ nav: isNav, indexed: looksIndexed });
            }
        };
        """,
        prelude: SpiderRegistry.bundled().prelude,
        storage: SpiderStorage(siteKey: "navfilter", defaults: UserDefaults(suiteName: "navfilter")!)
    )
    // These used to pass both checks and render as titles.
    #expect(try await runtime.action("/vodtype/1/").contains("\"nav\":true"))
    #expect(try await runtime.action("/vodshow/6-----------/").contains("\"nav\":true"))
    // A detail link must survive: it is indexed and is not nav.
    let detail = try await runtime.action("/voddetail/126509/")
    #expect(detail.contains("\"nav\":false"))
    #expect(detail.contains("\"indexed\":true"))
    // The shapes the older skins use must keep working too.
    #expect(try await runtime.action("/vod/12345.html").contains("\"nav\":false"))
    #expect(try await runtime.action("/index.php?id=99").contains("\"nav\":false"))
    await runtime.destroy()
}

/// IOS-POC-36.3: the CryptoKit hashes (ponytail audit item 16, `3fd68923`) against the CommonCrypto
/// calls they replaced, through the `__crypto` functions a spider reaches: empty, Unicode and long
/// messages, and keys shorter than, as long as and longer than the hash block — HMAC hashes a long
/// key first — plus an algorithm name neither implementation knows, which both read as SHA-256.
@Test func theJSVisibleHashesMatchCommonCryptoByteForByte() throws {
    let context = try #require(JSContext())
    CryptoHost.install(into: context)
    let crypto = try #require(context.objectForKeyedSubscript("__crypto"))
    func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    func digest(_ algorithm: String, _ text: String) -> String {
        let data = Array(text.utf8)
        switch algorithm.lowercased() {
        case "md5":
            var out = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
            _ = CC_MD5(data, CC_LONG(data.count), &out)
            return hex(out)
        case "sha1":
            var out = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            _ = CC_SHA1(data, CC_LONG(data.count), &out)
            return hex(out)
        default:
            var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            _ = CC_SHA256(data, CC_LONG(data.count), &out)
            return hex(out)
        }
    }
    func hmac(_ algorithm: String, _ text: String, _ key: String) -> String {
        let (cc, length): (Int, Int32) = switch algorithm.lowercased() {
        case "md5": (kCCHmacAlgMD5, CC_MD5_DIGEST_LENGTH)
        case "sha1": (kCCHmacAlgSHA1, CC_SHA1_DIGEST_LENGTH)
        default: (kCCHmacAlgSHA256, CC_SHA256_DIGEST_LENGTH)
        }
        let data = Array(text.utf8), secret = Array(key.utf8)
        var out = [UInt8](repeating: 0, count: Int(length))
        CCHmac(CCHmacAlgorithm(cc), secret, secret.count, data, data.count, &out)
        return hex(out)
    }
    let alphabet = Array("aZ09 -_$#%往返繁體🎬\u{00e9}")
    var random = SystemRandomNumberGenerator()
    let messages = ["", "abc", "往返 🎬", String(repeating: "x", count: 1000)]
        + (0..<16).map { _ in String((0..<Int.random(in: 1...300, using: &random)).map { _ in alphabet.randomElement(using: &random)! }) }
    let keys = ["", "key", String(repeating: "k", count: 64), String(repeating: "k", count: 65),
                String(repeating: "長", count: 50), String(repeating: "k", count: 200)]
    for algorithm in ["md5", "sha1", "sha256", "SHA256", "sha512"] {
        for message in messages {
            let js = crypto.invokeMethod("digest", withArguments: [algorithm, message])?.toString()
            #expect(js == digest(algorithm, message), "digest \(algorithm) of \(message.prefix(20))")
            for key in keys {
                let js = crypto.invokeMethod("hmac", withArguments: [algorithm, message, key])?.toString()
                #expect(js == hmac(algorithm, message, key), "hmac \(algorithm) key \(key.count)")
            }
        }
    }
}

// MARK: - IOS-POC-44G: RSA, AES hex output, bytes, binary HTTP

// A throwaway 1024-bit key made with OpenSSL 3.6.4 for these tests only, in every format the host
// accepts, and a 288-byte binary message OpenSSL encrypted in 117-byte blocks (three RSA blocks).
let testPublicPEM = """
-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCT2NVcFZeDf2WlH9CeS7GCbqxI
CrSgwCoNeDYEOxxUn8jWBEIg4VmgP5yopTsZfZpk5Wqc7ZXPr38YKX+SsV8N1uy9
owSQrLrhAAiN/aS3nk/xFFCmNkbe5tqmUKLFaJmFRBeOqoS9M1LMAfgJyXHnbfRB
X9vmWhI7QyBfyId7bwIDAQAB
-----END PUBLIC KEY-----
"""
let testPrivatePKCS8 = """
-----BEGIN PRIVATE KEY-----
MIICeAIBADANBgkqhkiG9w0BAQEFAASCAmIwggJeAgEAAoGBAJPY1VwVl4N/ZaUf
0J5LsYJurEgKtKDAKg14NgQ7HFSfyNYEQiDhWaA/nKilOxl9mmTlapztlc+vfxgp
f5KxXw3W7L2jBJCsuuEACI39pLeeT/EUUKY2Rt7m2qZQosVomYVEF46qhL0zUswB
+AnJcedt9EFf2+ZaEjtDIF/Ih3tvAgMBAAECgYAXW6CJxdeELPJwHhClkavfwYBy
eU6EPxflvOI71OLq87uVJGMWMsQoLySe+EvYASINYrlvRZHvl/hqZtQC5wbvOVWQ
jLhP2Ol6UYp0Qul8TIK0Uz54eJhpByGdTgiyvBnxHLgE089PrjY3QGm6rIc0gDrH
RlhZtHZVqbSd7i4qMQJBAMSLYRI4jPrsOBgsZsHETa5FbsGUulNKCYNmwpTdyPY1
N/EjOCW9wkRMeTF0wvSWtAwEbiYGEaQOKRJGZ6rUu7sCQQDAkkUemMVO+XPe4/ie
YuGOWn9oLOupmrwuOqpuIjqVx+mqv697httY5gvWxMU3zsNxYgQnM7v3VnNoU6xj
nhHdAkEAo+mZixieeqWGIqLlD7QnFK/TLp5axht4051fqcdNUggQH4q/yLn4yfz9
FcHK1TDZ9yu6sPteuvMUTalpy46fAQJBAIDurhaRRLHetOTMD/7Dx68PCnTOdq6k
6k+tecSpaD42jk2Db9Ot9BiuVcjjEASQjCzS6mLw8W3l1PlJ5IcCI4UCQQCHQybz
2hMpN/QFeeFDyHklGBnhS8OUEmhXpv22kcJZ1H198zMmM2AGH5F95i5MEyyESd9d
SEu49bOf5naSaIFj
-----END PRIVATE KEY-----
"""
let testPrivatePKCS1 = """
-----BEGIN RSA PRIVATE KEY-----
MIICXgIBAAKBgQCT2NVcFZeDf2WlH9CeS7GCbqxICrSgwCoNeDYEOxxUn8jWBEIg
4VmgP5yopTsZfZpk5Wqc7ZXPr38YKX+SsV8N1uy9owSQrLrhAAiN/aS3nk/xFFCm
Nkbe5tqmUKLFaJmFRBeOqoS9M1LMAfgJyXHnbfRBX9vmWhI7QyBfyId7bwIDAQAB
AoGAF1ugicXXhCzycB4QpZGr38GAcnlOhD8X5bziO9Ti6vO7lSRjFjLEKC8knvhL
2AEiDWK5b0WR75f4ambUAucG7zlVkIy4T9jpelGKdELpfEyCtFM+eHiYaQchnU4I
srwZ8Ry4BNPPT642N0BpuqyHNIA6x0ZYWbR2Vam0ne4uKjECQQDEi2ESOIz67DgY
LGbBxE2uRW7BlLpTSgmDZsKU3cj2NTfxIzglvcJETHkxdML0lrQMBG4mBhGkDikS
Rmeq1Lu7AkEAwJJFHpjFTvlz3uP4nmLhjlp/aCzrqZq8LjqqbiI6lcfpqr+ve4bb
WOYL1sTFN87DcWIEJzO791ZzaFOsY54R3QJBAKPpmYsYnnqlhiKi5Q+0JxSv0y6e
WsYbeNOdX6nHTVIIEB+Kv8i5+Mn8/RXBytUw2fcrurD7XrrzFE2pacuOnwECQQCA
7q4WkUSx3rTkzA/+w8evDwp0znaupOpPrXnEqWg+No5Ng2/TrfQYrlXI4xAEkIws
0upi8PFt5dT5SeSHAiOFAkEAh0Mm89oTKTf0BXnhQ8h5JRgZ4UvDlBJoV6b9tpHC
WdR9ffMzJjNgBh+RfeYuTBMshEnfXUhLuPWzn+Z2kmiBYw==
-----END RSA PRIVATE KEY-----
"""
let testPublicPKCS1 = "MIGJAoGBAJPY1VwVl4N/ZaUf0J5LsYJurEgKtKDAKg14NgQ7HFSfyNYEQiDhWaA/nKilOxl9mmTlapztlc+vfxgpf5KxXw3W7L2jBJCsuuEACI39pLeeT/EUUKY2Rt7m2qZQosVomYVEF46qhL0zUswB+AnJcedt9EFf2+ZaEjtDIF/Ih3tvAgMBAAE="
private let opensslCiphertext = "QsRo+WSL40bLf6bwhl4/2O1A67HuYI56wXXf7NZ1/jxFz9UCJDHCmhi0d7P8o/bPzC/UQkthmFhWtVptPXDv8nypRBnqKi4GGQ1E4vC8MHFgG3ucy0qwSKYGS9lNwOZzjyQRTQBscWfAhGv87IPKVFSUgj1yL8CRKipk3k97SPgivFWioU9obtNRpMTk48QvPUnTEeqjSDW+JDNmffoaPM+SancrB5Y8/a1cVjG9PWQ26lZwxOv5AvbzBxOPsB7OP1QPFl2r8sMZWrHc5verI0TtPscT21Q0frexW8b3J/2hcGBmggHYUYiHS/3Ldik1NLX9RDd6PzwXA7cIU6tTvU2AAHCywi1hkX5VdyFNf6UHd4ZBCuTYFdyn/Y1ygi0FzYIA7h3wOs6743uA8OkP7eq9fTZAdo2+Kkax664DGz2cDCm9XfAqTXulFBpmC81yH4j0ct+JankmyltbP5FWf/J/v3Icx2luYKbFKJRZ7fbMvsmrILkdzBqp3OFL1j2V"
private let opensslPlainHex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeffe7acace4ba8ce6aeb5efbc9ae4b8ade69687e8888720656d6f6a6920f09f8eac"

@Test func rsaDecryptsOpenSSLBlocksAndRoundTripsEveryKeyFormat() async throws {
    let spider = try runtime("""
    var pub = \(jsonLiteral(testPublicPEM)), pk8 = \(jsonLiteral(testPrivatePKCS8)),
        pk1 = \(jsonLiteral(testPrivatePKCS1)), pubDer = '\(testPublicPKCS1)';
    module.exports = {
      init: function () { return ''; },
      homeContent: function () {
        var ct = '\(opensslCiphertext)', hex = '\(opensslPlainHex)';
        var mine = host.rsaEncrypt(hex, pub, { input: 'hex' });
        return {
          openssl8: host.rsaDecrypt(ct, pk8, { output: 'hex' }),
          openssl1: host.rsaDecrypt(ct, pk1, { output: 'hex' }),
          ownBlocks: host.bytes.fromBase64(mine).length,
          own: host.rsaDecrypt(mine, pk8, { output: 'hex' }),
          ownPkcs1Public: host.rsaDecrypt(host.rsaEncrypt(hex, pubDer, { input: 'hex', output: 'hex' }), pk1,
                                          { input: 'hex', output: 'hex' }),
          text: host.rsaDecrypt(host.rsaEncrypt('金鑰 key 🎬', pub), pk1),
          badKey: host.rsaEncrypt('x', 'not a key'),
          wrongKey: host.rsaDecrypt(ct, pub)
        };
      }
    };
    """)
    let out = try #require(try JSONSerialization.jsonObject(
        with: Data(try await spider.homeContent(filter: true).utf8)) as? [String: Any])
    #expect(out["openssl8"] as? String == opensslPlainHex, "PKCS#8 private key, three blocks from OpenSSL")
    #expect(out["openssl1"] as? String == opensslPlainHex, "PKCS#1 private key")
    #expect(out["ownBlocks"] as? Int == 384, "288 bytes need three 128-byte blocks")
    #expect(out["own"] as? String == opensslPlainHex)
    #expect(out["ownPkcs1Public"] as? String == opensslPlainHex, "a PKCS#1 public key, hex in and out")
    #expect(out["text"] as? String == "金鑰 key 🎬")
    #expect(out["badKey"] as? String == "")
    #expect(out["wrongKey"] as? String == "", "a public key cannot decrypt")
}

@Test func aesEncryptWritesHexOnlyWhenAsked() async throws {
    let spider = try runtime("""
    module.exports = {
      init: function () { return ''; },
      homeContent: function () {
        var k = 'ed5fdsgucxumegqa', text = 'ts1700000000000ABCDEFGHIJKLMNO';
        var hex = host.aesEncrypt(text, k, k, 'CBC', 'hex');
        return { hex: hex, legacy: host.aesEncrypt(text, k, k, 'CBC'), back: host.aesDecrypt(hex, k, k, 'CBC', 'hex') };
      }
    };
    """)
    let out = try #require(try JSONSerialization.jsonObject(
        with: Data(try await spider.homeContent(filter: true).utf8)) as? [String: Any])
    // `openssl enc -aes-128-cbc -K <hex of key> -iv <hex of key>` on the same text.
    let reference = "4cd222f7c924379acdf73cb66d70745624f82bec01750d45e248a2d95f4d9533"
    #expect(out["hex"] as? String == reference)
    #expect(out["legacy"] as? String == Data(hex: reference).base64EncodedString(), "four arguments stay base64")
    #expect(out["back"] as? String == "ts1700000000000ABCDEFGHIJKLMNO")
}

/// Answers every request with the bytes it was sent, so a round trip shows what the wire carried.
private final class EchoProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": request.value(forHTTPHeaderField: "Content-Type") ?? ""])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func binaryBodiesCrossTheBridgeByteForByte() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [EchoProtocol.self]
    let registry = SpiderRegistry.bundled()
    let spider = try JavaScriptSpiderRuntime(name: "echo", script: """
    module.exports = {
      init: function () { return ''; },
      homeContent: function () {
        var sent = [];
        for (var i = 0; i < 256; i++) sent.push(i);
        sent = sent.concat(host.bytes.fromUtf8('中文🎬'));
        var res = host.req('https://echo.invalid/', { method: 'POST', bodyBase64: host.bytes.toBase64(sent),
                                                       responseType: 'base64' });
        var text = host.req('https://echo.invalid/', { method: 'POST', body: 'a=1' });
        return { sent: host.bytes.toBase64(sent), back: host.bytes.toBase64(host.bytes.fromBase64(res.bodyBase64)),
                 body: res.body, type: res.headers['content-type'], textBody: text.body, textB64: text.bodyBase64 || '',
                 utf8: host.bytes.toUtf8(host.bytes.fromUtf8('中文🎬')),
                 b64: [0, 1, 2, 3].map(function (n) { var a = []; for (var i = 0; i < n; i++) a.push(250 + i); return host.bytes.toBase64(a); }) };
      }
    };
    """, prelude: registry.prelude, storage: SpiderStorage(siteKey: "echo"),
       session: URLSession(configuration: configuration))
    let out = try #require(try JSONSerialization.jsonObject(
        with: Data(try await spider.homeContent(filter: true).utf8)) as? [String: Any])
    #expect(Data(base64Encoded: out["sent"] as? String ?? "")?.count == 256 + 10)
    #expect(out["back"] as? String == out["sent"] as? String, "every byte 0x00–0xFF survives both directions")
    #expect(out["body"] as? String == "", "a binary reply is not also decoded as text")
    #expect(out["type"] as? String == "application/octet-stream")
    #expect(out["textBody"] as? String == "a=1", "a text request is unchanged")
    #expect(out["textB64"] as? String == "")
    #expect(out["utf8"] as? String == "中文🎬")
    #expect(out["b64"] as? [String] == ["", "+g==", "+vs=", "+vv8"], "the same padding Foundation writes")
}

private func jsonLiteral(_ text: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: [text]), as: UTF8.self).dropFirst().dropLast().description
}
