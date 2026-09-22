import Foundation
import JavaScriptCore
import Testing
@testable import WebHTVCore

private let origin = ConfigSource.remote(URL(string: "https://example.invalid/repo/raw/main/wang-movie.json")!)

// MARK: - G1: the four ES module shapes, and what happens to anything else

/// Runs a rewritten module graph in a real `JSContext` — the same engine that will run the real
/// thing — because the residual check for module syntax *is* the parser.
private func evaluate(_ parts: [String]) throws -> JSContext {
    let context = try #require(JSContext())
    var thrown: String?
    context.exceptionHandler = { _, value in thrown = value?.toString() ?? "unknown" }
    context.evaluateScript(DrpyEngine.moduleRuntime)
    for part in parts { context.evaluateScript(part) }
    if let thrown { throw DrpyTestFailure.script(thrown) }
    return context
}

private enum DrpyTestFailure: Error { case script(String) }

private func object(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

/// The addresses in a `playerContent` result's `url`, whichever CatVod shape it used.
private func playURL(_ value: Any?) -> [String] {
    if let text = value as? String { return [text] }
    if let pairs = value as? [Any] {
        return stride(from: 1, to: pairs.count, by: 2).compactMap { pairs[$0] as? String }
    }
    if let object = value as? [String: Any], let values = object["values"] as? [[String: Any]] {
        return values.compactMap { $0["v"] as? String }
    }
    return []
}

@Test func aDefaultExportBecomesAModuleAnyImporterCanRead() throws {
    let lib = DrpyEngine.rewritten("export default {greet: function(){ return 'hi'; }};", named: "lib")
    let app = DrpyEngine.rewritten(#"import lib from "./lib.js"; globalThis.out = lib.greet();"#, named: "app")
    let context = try evaluate([lib, app])
    #expect(context.objectForKeyedSubscript("out")?.toString() == "hi")
}

/// cheerio's shape: a named-export clause at the end of a minified line, one entry aliased to
/// `default`.
@Test func anExportClauseMapsEveryAliasIncludingDefault() throws {
    let lib = DrpyEngine.rewritten(
        "var a=1,b=2,c=3;export{a as first,b as default,c as third};", named: "lib")
    let app = DrpyEngine.rewritten(
        #"import whole from "./lib.js"; import{first,third}from "./lib.js"; globalThis.out=[whole,first,third].join(",");"#,
        named: "app")
    let context = try evaluate([lib, app])
    // `import whole` takes the alias called default; the named import takes the others.
    #expect(context.objectForKeyedSubscript("out")?.toString() == "2,1,3")
}

/// gbk.js's shape.
@Test func anExportedFunctionIsRegisteredUnderItsOwnName() throws {
    let lib = DrpyEngine.rewritten("export function gbkTool(){ return 'gbk'; }", named: "gbk")
    let app = DrpyEngine.rewritten(#"import{gbkTool}from "./gbk.js"; globalThis.out = gbkTool();"#, named: "app")
    let context = try evaluate([lib, app])
    #expect(context.objectForKeyedSubscript("out")?.toString() == "gbk")
}

/// A side-effect-only import: the library is already in the prelude, so the statement is dropped and
/// the global it set is simply there.
@Test func aSideEffectImportIsDroppedAndTheGlobalSurvives() throws {
    let lib = DrpyEngine.rewritten("globalThis.CryptoJS = {name: 'crypto'};", named: "crypto-js")
    let app = DrpyEngine.rewritten(#"import "./crypto-js.js"; globalThis.out = CryptoJS.name;"#, named: "app")
    let context = try evaluate([lib, app])
    #expect(context.objectForKeyedSubscript("out")?.toString() == "crypto")
}

/// Each module keeps its own top-level names. Without this, cheerio's minified `var e,t` would
/// collide with the engine's.
@Test func twoModulesDoNotShareTopLevelNames() throws {
    let first = DrpyEngine.rewritten("var e = 'first'; export default {value: e};", named: "one")
    let second = DrpyEngine.rewritten("var e = 'second'; export default {value: e};", named: "two")
    let app = DrpyEngine.rewritten(
        #"import a from "./one.js"; import b from "./two.js"; globalThis.out = a.value + "/" + b.value;"#,
        named: "app")
    let context = try evaluate([first, second, app])
    #expect(context.objectForKeyedSubscript("out")?.toString() == "first/second")
}

/// Fail closed: a module that was never loaded must raise, not resolve to undefined and fail later
/// somewhere unrecognisable.
@Test func importingAModuleThatIsNotLoadedThrows() throws {
    let app = DrpyEngine.rewritten(#"import missing from "./nope.js"; globalThis.out = missing;"#, named: "app")
    #expect(throws: DrpyTestFailure.self) { try evaluate([app]) }
}

/// The residual check is the parser: anything the rewrite does not handle stays module syntax and
/// the engine refuses it, rather than being evaluated as something half-rewritten.
@Test func unrewritableModuleSyntaxIsASyntaxErrorRatherThanSilentlyAccepted() throws {
    // A form the rewriter deliberately does not cover.
    let exotic = DrpyEngine.rewritten("export * from \"./other.js\";", named: "app")
    #expect(throws: DrpyTestFailure.self) { try evaluate([exotic]) }
}

// MARK: - G6 and the boundary rules: every refusal is closed

@Test func aNonHTTPSResourceIsRefused() throws {
    let insecure = URL(string: "http://example.invalid/repo/raw/main/drpy_libs/x.js")!
    #expect(throws: DrpyError.insecureURL(insecure.absoluteString)) {
        _ = try DrpyEngine.checked(insecure, origin: #require(origin.baseURL))
    }
}

@Test func aResourceOutsideTheConfigurationsOriginIsRefused() throws {
    let base = try #require(origin.baseURL)
    for elsewhere in ["https://evil.invalid/x.js", "https://example.invalid:8443/x.js"] {
        let url = try #require(URL(string: elsewhere))
        #expect(throws: DrpyError.crossOrigin(elsewhere)) { _ = try DrpyEngine.checked(url, origin: base) }
    }
    // The configuration's own origin is the one thing allowed.
    let allowed = try #require(URL(string: "https://example.invalid/repo/raw/main/drpy_libs/x.js"))
    #expect(try DrpyEngine.checked(allowed, origin: base) == allowed)
}

/// An imported file has no origin, so there is nothing to be same-origin with and drpy is refused
/// rather than defaulting to "anywhere".
@Test func anImportedConfigurationCannotLoadADrpyEngine() throws {
    #expect(throws: DrpyError.noRemoteConfiguration) {
        _ = try DrpyEngine.url(for: "drpy2.min.js", source: .importedFile)
    }
    let resolver = CSPSourceResolver(source: .importedFile)
    let site = try JSONDecoder().decode(Site.self, from: Data(
        #"{"key":"d","name":"d","type":3,"api":"./drpy_libs/drpy2.min.js","ext":"./drpy_js/x.js"}"#.utf8))
    #expect(site.isDrpySpider)
    #expect(resolver.canResolve(site) == false)
}

@Test func theEngineFilesResolveUnderTheConfigurationsOwnDirectory() throws {
    let url = try DrpyEngine.url(for: "cheerio.min.js", source: origin)
    #expect(url.absoluteString == "https://example.invalid/repo/raw/main/drpy_libs/cheerio.min.js")
}

// MARK: - The pinned set itself

/// The allowlist is the whole point: it must be complete, self-consistent and within the caps that
/// bound what can be downloaded.
@Test func everyPinnedDependencyIsWellFormedAndWithinTheLimits() {
    let pinned = DrpyEngine.dependencies
    #expect(pinned.count == 10)
    // The engine is evaluated last, because every other file is something it imports.
    #expect(pinned.last?.file == "drpy2.min.js")
    #expect(Set(pinned.map(\.file)).count == pinned.count)
    for dependency in pinned {
        #expect(dependency.sha256.count == 64, "\(dependency.file) hash is not SHA-256")
        #expect(dependency.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(dependency.bytes > 0 && dependency.bytes <= DrpyEngine.maximumFileBytes,
                "\(dependency.file) is outside the per-file limit")
    }
    #expect(pinned.reduce(0) { $0 + $1.bytes } <= DrpyEngine.maximumBundleBytes)
}

@Test func theDigestIsAPlainLowercaseSHA256() {
    // The published vector for the empty string, so a wrong algorithm cannot pass.
    #expect(DrpyEngine.digest(Data()) ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}

// MARK: - The bridge is an adapter, not a second engine

@Test func theBridgeAnswersTheSpiderABIByDelegatingToTheLoadedEngine() async throws {
    let bridge = SpiderRegistry.bundled().drpyBridge
    #expect(!bridge.isEmpty, "drpy-bridge.js must be bundled")

    // A stand-in for the real engine, registered exactly where DrpyEngine would put it.
    let stub = """
    globalThis.__drpyModules = {"drpy2.min": {
      init: function (ext) { return "init:" + ext; },
      home: function (filter) { return {class: [{type_id: "1", type_name: "首頁"}]}; },
      category: function (tid, pg) { return {list: [{vod_id: tid + "/" + pg}]}; },
      detail: function (id) { return {list: [{vod_id: id, vod_name: "片"}]}; },
      search: function (wd) { return {list: [{vod_id: wd}]}; },
      play: function (flag, id) { return {parse: 0, url: "https://a/" + id + ".m3u8"}; },
      isVideo: function (url) { return /\\.m3u8$/.test(url); }
    }};
    """
    let runtime = try JavaScriptSpiderRuntime(
        name: "drpy-test", script: bridge, prelude: stub,
        storage: SpiderStorage(siteKey: "t", defaults: .standard))

    // `initialize` returns nothing by ABI — what matters is that it reaches the engine at all.
    try await runtime.initialize(extend: "rule-text")
    #expect(try await runtime.homeContent(filter: true).contains("首頁"))
    #expect(try await runtime.categoryContent(tid: "5", page: "2", filter: false, extend: [:]).contains("5/2"))
    #expect(try await runtime.detailContent(ids: ["77"]).contains("\"vod_id\":\"77\""))
    #expect(try await runtime.searchContent(key: "我", quick: false, page: "1").contains("我"))
    #expect(try await runtime.playerContent(flag: "f", id: "9", vipFlags: []).contains("https://a/9.m3u8"))
    #expect(try await runtime.isVideoFormat(url: "https://a/9.m3u8"))
    #expect(try await runtime.isVideoFormat(url: "https://a/9.html") == false)
}

/// Fail closed: the bridge without an engine must name the problem, not answer emptiness.
@Test func theBridgeWithoutAnEngineRefusesRatherThanAnsweringNothing() async throws {
    let runtime = try JavaScriptSpiderRuntime(
        name: "drpy-empty", script: SpiderRegistry.bundled().drpyBridge, prelude: "",
        storage: SpiderStorage(siteKey: "t", defaults: .standard))
    await #expect(throws: (any Error).self) { _ = try await runtime.homeContent(filter: true) }
}

// MARK: - G2/G3: a real drpy source, end to end, against the live provider

/// The gate for IOS-POC-6B. Everything above runs offline; this one fetches the real engine from the
/// user's own configuration origin, verifies all ten dependencies against the pinned hashes, loads a
/// real site's rule script and drives `home → category → detail → search → player` — then fetches
/// the first bytes of what it resolved, because a URL existing and a stream existing are different
/// things.
///
///     DRPY_GOLDEN_BASE='https://…/wang-movie.json' \
///     DRPY_GOLDEN_SITE='{"key":"drpy_js_去看吧","name":"去看动漫","type":3,
///       "api":"./drpy_libs/drpy2.min.js","ext":"./drpy_js/去看吧.js"}' \
///       swift test --package-path ios --filter drpyDrivesARealSourceEndToEnd
@Test func drpyDrivesARealSourceEndToEnd() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let raw = environment["DRPY_GOLDEN_SITE"],
          let base = environment["DRPY_GOLDEN_BASE"].flatMap({ URL(string: $0) }) else { return }
    let site = try JSONDecoder().decode(Site.self, from: Data(raw.utf8))
    #expect(site.isDrpySpider)

    let source = ConfigSource.remote(base)
    let resolver = CSPSourceResolver(source: source)
    #expect(resolver.canResolve(site))

    let session = try await resolver.session(for: site)
    print("[drpy] engine verified and loaded for \(site.key)")

    let home = try await object(session.home())
    let classes = try #require(home["class"] as? [[String: Any]])
    #expect(!classes.isEmpty, "home returned no categories")
    print("[drpy] home: \(classes.compactMap { $0["type_name"] as? String })")

    let tid = try #require(classes.first?["type_id"].map { "\($0)" })
    let category = try await object(session.category(tid: tid, page: "1"))
    let list = try #require(category["list"] as? [[String: Any]])
    #expect(!list.isEmpty, "category \(tid) returned nothing")
    print("[drpy] category \(tid): \(list.count) items, first=\(list[0]["vod_name"] ?? "")")

    var detail: [String: Any]?
    for candidate in list.prefix(4) {
        guard let id = candidate["vod_id"].map({ "\($0)" }) else { continue }
        let decoded = try await object(session.detail(ids: [id]))
        if let first = (decoded["list"] as? [[String: Any]])?.first,
           (first["vod_play_url"] as? String)?.isEmpty == false {
            detail = first
            break
        }
    }
    let vod = try #require(detail, "no listed title produced a playable detail")
    let froms = (vod["vod_play_from"] as? String ?? "").components(separatedBy: "$$$")
    let urls = (vod["vod_play_url"] as? String ?? "").components(separatedBy: "$$$")
    #expect(froms.count == urls.count)
    let episodes = try #require(urls.first).components(separatedBy: "#")
    #expect(episodes.allSatisfy { $0.contains("$") })
    print("[drpy] detail \(vod["vod_name"] ?? ""): flags=\(froms), episodes=\(episodes.count)")

    let search = try await object(session.search(key: "我"))
    print("[drpy] search 我: \((search["list"] as? [[String: Any]])?.count ?? 0) results")

    let episode = try #require(episodes.first)
    let target = String(episode.drop(while: { $0 != "$" }).dropFirst())
    let play = try await object(session.player(flag: froms.first ?? "", id: target))
    let address = try #require(playURL(play["url"]).first)
    print("[drpy] player: parse=\(play["parse"] ?? "") url=\(address.prefix(90))")

    // G3: the stream has to serve bytes, not merely parse — and it has to do so through the path
    // the app really uses. `parse:1` means the spider handed back a page, so `SourceClient` is what
    // turns it into media; asserting on the raw address here would pass while the app still failed.
    let vodId = try #require(vod["vod_id"].map { "\($0)" })
    let client = try await SourceClient.make(site: site, resolver: resolver)
    let detailVod = try #require(try await client.detail(id: vodId))
    let flag = try #require(detailVod.flags.first)
    let firstEpisode = try #require(flag.episodes.first)
    let playback = try #require(try await client.playbackURL(for: firstEpisode, flag: flag.name))
    print("[drpy] playback: \(playback.url.absoluteString.prefix(110)) +hdr\(playback.headers.count)")
    // Naming what has to deliver this: drpy's job ends at the `parse:1` page above, and turning
    // that page into a stream is `MediaSniffer`'s. A failure here is a sniffing gap, not a loader one.
    #expect(await MediaProbe.classify(playback.url, headers: playback.headers) == .media,
            "the sniffer did not reduce the spider's page to a stream: \(playback.url)")

    await session.destroy()
}

/// IOS-POC-10N: a drpy site's rule script is not always in `ext`.
@Suite struct DrpyRuleReferenceTests {
    private func site(api: String, ext: String?) throws -> Site {
        let extField = ext.map { #","ext":"\#($0)""# } ?? ""
        let json = #"{"key":"k","name":"n","type":3,"api":"\#(api)"\#(extField)}"#
        return try JSONDecoder().decode(Site.self, from: Data(json.utf8))
    }

    @Test func theEngineAndRuleShapeReadsItsExt() throws {
        let one = try site(api: "./drpy_libs/drpy2.min.js", ext: "./drpy_js/去看吧.js")
        #expect(one.isDrpySpider)
        #expect(one.drpyRuleReference == "./drpy_js/去看吧.js")
    }

    /// 步步｜4K, verbatim from the user's configuration: the rule is the api and there is no ext.
    /// Before this, that produced an empty reference and an error message with nothing in it.
    @Test func theRuleAsApiShapeFallsBackToTheApi() throws {
        let one = try site(api: "./json/4k.js", ext: nil)
        #expect(one.isDrpySpider)
        #expect(one.drpyRuleReference == "./json/4k.js")
        #expect(!one.drpyRuleReference.isEmpty, "an empty reference is what caused the blank error")
    }

    @Test func whitespaceOnlyExtIsTreatedAsAbsent() throws {
        #expect(try site(api: "./json/4k.js", ext: "   ").drpyRuleReference == "./json/4k.js")
    }

    /// 麻豆(js), verbatim from `wang-sex.json`: the rule is the api and `ext` is an empty **object**.
    /// IOS-POC-10N's emptiness check passed `"{}"` straight through as if it were a path.
    @Test func anEmptyExtObjectIsNotAReference() throws {
        let json = #"{"key":"js_madou","name":"麻豆","type":3,"api":"./drpy_js/麻豆.min.js","ext":{}}"#
        let one = try JSONDecoder().decode(Site.self, from: Data(json.utf8))
        #expect(one.isDrpySpider)
        #expect(one.rawExtJSON == "{}", "the raw form is what fooled the emptiness check")
        #expect(one.drpyRuleReference == "./drpy_js/麻豆.min.js")
    }

    @Test func onlyThingsResourceURLCouldResolveCountAsReferences() throws {
        #expect(Site.isResourceReference("./drpy_js/a.js"))
        #expect(Site.isResourceReference("../a.js"))
        #expect(Site.isResourceReference("https://x.example/a.js"))
        // Configuration noise, every one of which used to be taken for a path.
        #expect(!Site.isResourceReference("{}"))
        #expect(!Site.isResourceReference("[]"))
        #expect(!Site.isResourceReference(""))
        #expect(!Site.isResourceReference("   "))
        #expect(!Site.isResourceReference("{\"key\":\"value\"}"))
    }
}

/// IOS-POC-10P: two JavaScript spider contracts share the `.js` extension.
@Suite struct JavaScriptSpiderDetectionTests {
    /// The tail of `drpy_js/麻豆.min.js`, which is what an obfuscated TVBox JS spider looks like.
    @Test func theJsSpiderEntryPointIsRecognised() {
        let script = "function __jsEvalReturn(){var o={};o['category']=category;o['search']=search;return o;}"
        #expect(DrpyEngine.isJavaScriptSpider(script))
    }

    @Test func aDrpyRuleIsNot() {
        #expect(!DrpyEngine.isJavaScriptSpider("var rule = { title: 'x', host: 'https://a.example' }"))
        #expect(!DrpyEngine.isJavaScriptSpider(""))
    }

    /// `rule(at:source:)` still refuses one, because the branch that routes a JS spider happens in
    /// `CSPSourceResolver` — anything reaching the drpy path by another route is a mistake, not a
    /// silent fall-through to the other runtime.
    @Test func theFailureSaysWhichContractItIs() {
        let shown = (DrpyError.notADrpyRule("麻豆.min.js") as Error).localizedDescription
        #expect(shown.contains("__jsEvalReturn"))
        #expect(!shown.contains("couldn’t be completed"))
    }
}

// MARK: - IOS-POC-10T: the JS spider contract, offline

/// The two facts that made 麻豆 answer nothing, pinned without a network.
///
/// The live gate is `drpyDrivesARealSourceEndToEnd` driven with 麻豆's site JSON; these are the
/// units underneath it, so a regression names itself instead of arriving as an empty screen.
@Suite struct JavaScriptSpiderRuntimeTests {
    /// The real blocker: **every JS spider method is `async`.** drpy2 contains no `async` at all, so
    /// the runtime never had to settle a promise — `invokeMethod` handed back the promise itself and
    /// `JSON.stringify` made it `{}`. Thirteen methods answering nothing, no error anywhere. This
    /// drives the whole path: bridge, `__jsEvalReturn`, async methods, and a **synchronous** host
    /// call inside them, exactly as `host.req` is synchronous.
    @Test func anAsyncSpiderMethodReachesTheAbiAsItsValue() async throws {
        let script = """
        export function __jsEvalReturn() {
          return {
            init: async function (ext) { globalThis.__seen = ext; },
            home: async function (filter) {
              var stamp = host.md5('x');
              return JSON.stringify({ class: [{ type_id: '1', type_name: 'a' }],
                                      filter: filter, stamp: stamp.length });
            },
            detail: async function (id) { return JSON.stringify({ list: [{ vod_id: id }] }); }
          };
        }
        """
        let runtime = try runtimeDriving(script)
        try await runtime.initialize(extend: #"{"stype":"3"}"#)

        let home = try await runtime.homeContent(filter: true)
        #expect(home.contains("type_name"), "an async method must not arrive as an empty promise")
        #expect(home.contains(#""filter":true"#))
        #expect(home.contains(#""stamp":32"#), "the host is reachable from inside the promise")

        // `detail` takes one id, not the array `Spider.java` passes — the bridge unwraps it.
        let detail = try await runtime.detailContent(ids: ["77"])
        #expect(detail.contains(#""vod_id":"77""#))
    }

    /// The second difference: **`init` is handed an object, not text.** 麻豆's `init` writes
    /// `extend.stype = '3'`; on a string primitive that is a silent no-op in sloppy mode and a
    /// TypeError in strict, which is why the bridge parses before it calls.
    @Test func initReceivesAnObjectItCanWriteTo() async throws {
        let script = """
        export function __jsEvalReturn() {
          return {
            init: async function (ext) { ext.stype = '3'; globalThis.__seen = ext; },
            home: async function () { return JSON.stringify(globalThis.__seen); }
          };
        }
        """
        let runtime = try runtimeDriving(script)
        try await runtime.initialize(extend: #"{"site":"a"}"#)
        let seen = try await runtime.homeContent(filter: false)
        #expect(seen.contains(#""stype":"3""#), "init must be able to write to what it was given")
        #expect(seen.contains(#""site":"a""#))

        // A plain-string `ext` is not JSON, and must still arrive as something writable.
        let plain = try runtimeDriving(script)
        try await plain.initialize(extend: "https://example.invalid/")
        let wrapped = try await plain.homeContent(filter: false)
        #expect(wrapped.contains("https://example.invalid/"))
    }

    /// A rejected promise must surface as a named failure, not as an empty list — the whole point of
    /// IOS-POC-10P was that silence is the worst available outcome.
    @Test func aRejectedPromiseBecomesAnError() async throws {
        let script = """
        export function __jsEvalReturn() {
          return { home: async function () { throw new Error('provider said no'); } };
        }
        """
        let runtime = try runtimeDriving(script)
        await #expect(throws: (any Error).self) { try await runtime.homeContent(filter: true) }
    }

    /// Builds the runtime the way `CSPSourceResolver.jsSpiderSession` does, out of the same bundled
    /// pieces — so this exercises the wiring rather than a copy of it.
    private func runtimeDriving(_ script: String) throws -> JavaScriptSpiderRuntime {
        let registry = SpiderRegistry.bundled()
        #expect(!registry.jsSpiderBridge.isEmpty, "js-spider.js must be bundled")
        let prelude = [registry.prelude, DrpyEngine.moduleRuntime,
                       #"globalThis.__jsSpiderModule = "probe";"#,
                       DrpyEngine.rewritten(script, named: "probe")].joined(separator: "\n;\n")
        return try JavaScriptSpiderRuntime(
            name: "jsspider-test", script: registry.jsSpiderBridge, prelude: prelude,
            storage: SpiderStorage(siteKey: "jsspider-test", defaults: .standard))
    }
}
