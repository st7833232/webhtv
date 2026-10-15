import Foundation
import JavaScriptCore
import Testing
@testable import WebHTVCore

// IOS-POC-57B-13 (W-104): qist 0825's `csp_Jianpian` (lower-case p) is 荐片 on the API JianPian.js already drives
// (W-99 gate: its own old API host is dead; its list parameters and filter ids answer on the new one).

/// 0825's site line as published (`jianpian-gate-fixtures/qist-0825.json`:67).
private let site0825 = #"{"key":"荐片弹幕版","name":"荐片","type":3,"api":"csp_Jianpian","searchable":1,"quickSearch":1,"filterable":1,"ext":"./json/jianpian.json$$$1","timeout":60}"#

/// host.js and JianPian.js in a bare JSContext whose `__http` answers in JS and records every address, so
/// what `init` and `categoryContent` ask for is visible without a network or a URLProtocol.
private func jianPian(extend: String) throws -> (run: (String) -> String?, asked: () -> [String]) {
    let registry = SpiderRegistry.bundled()
    let context = try #require(JSContext())
    context.evaluateScript("""
        var asked = [], store = {};
        var __store = { get: function (k) { return store[k] || ''; }, set: function (k, v) { store[k] = v; }, del: function (k) { delete store[k]; } };
        var __util = { urlencode: encodeURIComponent, urldecode: decodeURIComponent, now: function () { return 0; } };
        var __crypto = {};
        var __http = { request: function (url, o) {
          asked.push(url);
          function json(v) { return { status: 200, body: JSON.stringify(v), headers: {} }; }
          if (url.indexOf('dns.alidns.com') >= 0) return json({ Answer: [{ data: '"api.invalid"' }] });
          if (url.indexOf('resourceDomainConfig') >= 0) return json({ data: { imgDomain: 'img.invalid' } });
          if (url.indexOf('jianpian.json') >= 0) return json({ '0': [], '1': [{ key: 'area' }, { key: 'year' }, { key: 'by' }] });
          if (url.indexOf('/api/crumb/') >= 0) return json({ data: [] });
          return { status: 200, body: '', headers: {} };
        } };
        var module = { exports: {} };
        """)
    context.evaluateScript(registry.prelude)
    context.evaluateScript(try #require(registry.entry(for: "csp_Jianpian")?.script))
    let spider = try #require(context.evaluateScript("module.exports"))
    spider.invokeMethod("init", withArguments: [extend])
    return ({ context.evaluateScript($0)?.toString() }, { context.evaluateScript("asked")?.toArray() as? [String] ?? [] })
}

@Suite(.serialized) struct JianpianAliasTests {
    // Not through the bundle: macOS resolves "Jianpian.js" to JianPian.js case-insensitively, a phone does not.
    @Test func csp_JianpianIsAnAliasOfJianPianNotAFileOfItsOwn() throws {
        #expect(SpiderRegistry.ported.contains("Jianpian"))
        #expect(SpiderRegistry.aliases["Jianpian"] == "JianPian")
        // Every ported name, aliased or not, is a file the bundle holds under exactly that spelling.
        let folder = try #require(Bundle.module.url(forResource: "Spiders", withExtension: nil))
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        for name in SpiderRegistry.ported {
            let file = (SpiderRegistry.aliases[name] ?? name) + ".js"
            #expect(files.contains(file), "\(name) needs \(file), spelled exactly")
        }
    }

    @Test func the0825SiteResolvesToJianPianAndItsRelativeExt() throws {
        let site = try JSONDecoder().decode(Site.self, from: Data(site0825.utf8))
        let resolver = CSPSourceResolver(registry: .bundled(),
                                         source: .remote(URL(string: "https://raw.githubusercontent.com/qist/tvbox/master/0825.json")!))
        #expect(resolver.resolvedExtend(for: site) == "https://raw.githubusercontent.com/qist/tvbox/master/json/jianpian.json$$$1")
        let registry = SpiderRegistry.bundled()
        #expect(registry.entry(for: "csp_Jianpian")?.script == registry.entry(for: "csp_JianPian")?.script)
    }

    // The "$$$1" after 0825's ext is its danmaku switch, which iOS has no use for; the filter file is before it.
    @Test func initFetchesTheFilterFileWithoutItsDanmakuSuffix() throws {
        let suffixed = try jianPian(extend: "https://x.invalid/json/jianpian.json$$$1")
        let filterFile = suffixed.asked().filter { $0.contains("jianpian.json") }
        #expect(filterFile == ["https://x.invalid/json/jianpian.json"])
        #expect(suffixed.run("JSON.stringify(Object.keys(module.exports.homeContent().filters))") == #"["0","1"]"#)
        // Any other ext goes out exactly as given, a "$" inside it included.
        for ext in ["https://x.invalid/json/jianpian.json", "https://x.invalid/a$b/jianpian.json"] {
            #expect(try jianPian(extend: ext).asked().filter { $0.contains("jianpian.json") } == [ext])
        }
    }

    // 0825's rows sort with "by"; JianPian's own with "sort", which wins when both are there.
    @Test func aCategorySortsWithSortElseBy() throws {
        let spider = try jianPian(extend: "https://x.invalid/json/jianpian.json")
        func asked(_ tid: String, _ extend: String) -> String {
            _ = spider.run("module.exports.categoryContent('\(tid)', '1', true, \(extend))")
            return spider.asked().last { $0.contains("/api/crumb/") } ?? ""
        }
        let byOnly = asked("1", "{area: '3', year: '153', by: 'hot'}")
        #expect(byOnly.contains("area=3&year=153") && byOnly.contains("&sort=hot&page=1"))
        #expect(asked("1", "{sort: 'x', by: 'hot'}").contains("&sort=x&page=1"))
        #expect(asked("1", "{}").contains("&sort=&page=1"))
        #expect(asked("67", "{}").contains("&sort=update&page=1"))
    }
}
