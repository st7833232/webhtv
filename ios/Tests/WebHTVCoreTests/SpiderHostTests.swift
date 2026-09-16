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
