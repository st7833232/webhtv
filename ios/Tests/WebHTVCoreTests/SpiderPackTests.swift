import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// MARK: - helpers

private func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private let packURL = URL(string: "https://example.invalid/spiders/manifest.json")!

/// A spider small enough to assert on, shaped like a real one: it answers the CatVod contract.
private func script(marking name: String) -> String {
    """
    var spider = {
      init: function () { return ''; },
      homeContent: function () {
        return host.result.home([{ type_id: '1', type_name: '\(name)' }], []);
      }
    };
    module.exports = spider;
    """
}

private func manifest(version: String = "1", schema: Int = SpiderPack.schema,
                      minHostApi: Int? = nil, entries: [(String, String, String, [String]?, Int?)]) -> String {
    let scripts = entries.map { name, path, hash, aliases, gate -> String in
        var fields = ["\"class\": \"\(name)\"", "\"path\": \"\(path)\"", "\"sha256\": \"\(hash)\""]
        if let aliases { fields.append("\"aliases\": [\(aliases.map { "\"\($0)\"" }.joined(separator: ", "))]") }
        if let gate { fields.append("\"minHostApi\": \(gate)") }
        return "{ \(fields.joined(separator: ", ")) }"
    }
    var top = ["\"schema\": \(schema)", "\"version\": \"\(version)\""]
    if let minHostApi { top.append("\"minHostApi\": \(minHostApi)") }
    top.append("\"scripts\": [\(scripts.joined(separator: ", "))]")
    return "{ \(top.joined(separator: ", ")) }"
}

/// Serves canned bytes, so every failure mode is reachable without a network or a server.
private func store(_ responses: [String: Result<(Data, Int), Error>],
                   directory: URL) -> SpiderPackStore {
    SpiderPackStore(directory: directory) { url in
        switch responses[url.absoluteString] {
        case .success(let (data, status)):
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        case .failure(let error): throw error
        case nil: throw URLError(.fileDoesNotExist)
        }
    }
}

private func scratch() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("packtests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("SpiderPack", isDirectory: true)
    return url
}

private func ok(_ text: String) -> Result<(Data, Int), Error> { .success((Data(text.utf8), 200)) }

// MARK: - adoption

@Test func adoptsAVerifiedPackAndPrefersItOverTheBundledScript() async throws {
    let body = script(marking: "from-pack")
    let subject = store([
        packURL.absoluteString: ok(manifest(version: "2026-09-17.1",
                                            entries: [("AppGet", "./AppGet.js", sha256(body), nil, nil)])),
        "https://example.invalid/spiders/AppGet.js": ok(body)
    ], directory: scratch())

    let pack = try await subject.refresh(from: packURL)
    #expect(pack.version == "2026-09-17.1")
    #expect(pack.scripts["AppGet"] == body)

    // The registry must prefer it, and must say so rather than looking identical to the bundle.
    let registry = SpiderRegistry.bundled(overlaying: pack)
    let entry = try #require(registry.entry(for: "csp_AppGet"))
    #expect(entry.source == .pack(version: "2026-09-17.1"))
    #expect(entry.script == body)
    // Everything the pack did not mention stays bundled.
    #expect(registry.entry(for: "csp_XBPQ")?.source == .bundled)
    await subject.reset()
}

@Test func aPackScriptActuallyRunsOnTheRuntime() async throws {
    let body = script(marking: "pack-driven")
    let subject = store([
        packURL.absoluteString: ok(manifest(entries: [("AppGet", "./AppGet.js", sha256(body), nil, nil)])),
        "https://example.invalid/spiders/AppGet.js": ok(body)
    ], directory: scratch())
    let pack = try await subject.refresh(from: packURL)

    let registry = SpiderRegistry.bundled(overlaying: pack)
    let runtime = try registry.makeRuntime(for: "csp_AppGet", siteKey: "t")
    let home = try await runtime.homeContent(filter: true)
    #expect(home.contains("pack-driven"), "the remote script, not the bundled one, must be what ran")
    await subject.reset()
}

/// `JPianAmns` has no logic of its own; a pack may point it at the script that does.
@Test func aPackAliasResolvesAConfiguredClassToTheScriptThatDrivesIt() async throws {
    let body = script(marking: "jianpian")
    let subject = store([
        packURL.absoluteString: ok(manifest(entries: [("JianPian", "./JianPian.js", sha256(body),
                                                       ["JPianAmns"], nil)])),
        "https://example.invalid/spiders/JianPian.js": ok(body)
    ], directory: scratch())
    let pack = try await subject.refresh(from: packURL)
    let registry = SpiderRegistry.bundled(overlaying: pack)

    #expect(registry.canDrive("csp_JPianAmns"))
    #expect(registry.entry(for: "csp_JPianAmns")?.script == body)
    #expect(registry.entry(for: "csp_JPianAmns")?.source == .pack(version: "1"))
    let runtime = try registry.makeRuntime(for: "csp_JPianAmns", siteKey: "薦片")
    #expect(try await runtime.homeContent(filter: true).contains("jianpian"))
    await subject.reset()
}

// MARK: - refusals

@Test func refusesAPackWhoseScriptDoesNotMatchItsDeclaredHash() async throws {
    let body = script(marking: "served")
    let subject = store([
        packURL.absoluteString: ok(manifest(entries: [("AppGet", "./AppGet.js",
                                                       sha256(script(marking: "promised")), nil, nil)])),
        "https://example.invalid/spiders/AppGet.js": ok(body)
    ], directory: scratch())

    await #expect(throws: SpiderPackError.hashMismatch(className: "AppGet")) {
        try await subject.refresh(from: packURL)
    }
    // Nothing adopted, so the app is still on the bundled scripts.
    #expect(await subject.installedPack() == nil)
    #expect(SpiderRegistry.bundled(overlaying: nil).entry(for: "csp_AppGet")?.source == .bundled)
    await subject.reset()
}

@Test func refusesAManifestThatIsNotValidJSON() async throws {
    let subject = store([packURL.absoluteString: ok("{ not json ")], directory: scratch())
    await #expect(throws: SpiderPackError.malformedManifest) { try await subject.refresh(from: packURL) }
    await subject.reset()
}

@Test func refusesASchemaThisBuildDoesNotKnow() async throws {
    let body = script(marking: "x")
    let subject = store([
        packURL.absoluteString: ok(manifest(schema: 99,
                                            entries: [("AppGet", "./AppGet.js", sha256(body), nil, nil)]))
    ], directory: scratch())
    await #expect(throws: SpiderPackError.unsupportedSchema(99)) { try await subject.refresh(from: packURL) }
    await subject.reset()
}

/// The gate that matters for the future: a pack written for an app with RSA or `proxy` in the host
/// must be refused by an app that lacks them, at load time and with a reason.
@Test func refusesAPackThatNeedsANewerHostThanThisBuild() async throws {
    let body = script(marking: "x")
    let subject = store([
        packURL.absoluteString: ok(manifest(minHostApi: SpiderPackStore.hostApiVersion + 1,
                                            entries: [("AppGet", "./AppGet.js", sha256(body), nil, nil)]))
    ], directory: scratch())
    await #expect(throws: SpiderPackError.hostTooOld(required: SpiderPackStore.hostApiVersion + 1,
                                                     current: SpiderPackStore.hostApiVersion)) {
        try await subject.refresh(from: packURL)
    }
    await subject.reset()
}

@Test func skipsOneScriptThatNeedsANewerHostAndKeepsTheRest() async throws {
    let usable = script(marking: "usable"), future = script(marking: "future")
    let subject = store([
        packURL.absoluteString: ok(manifest(entries: [
            ("AppGet", "./AppGet.js", sha256(usable), nil, nil),
            ("AppDrama", "./AppDrama.js", sha256(future), nil, SpiderPackStore.hostApiVersion + 1)
        ])),
        "https://example.invalid/spiders/AppGet.js": ok(usable)
    ], directory: scratch())

    let pack = try await subject.refresh(from: packURL)
    #expect(pack.scripts["AppGet"] == usable)
    #expect(pack.scripts["AppDrama"] == nil)
    let rejection = try #require(pack.rejected.first)
    #expect(rejection.className == "AppDrama")
    #expect(rejection.reason.contains("host API"), "the reason has to name the cause: \(rejection.reason)")
    await subject.reset()
}

@Test func refusesAPackServedOverPlainHTTP() async throws {
    let subject = store([:], directory: scratch())
    await #expect(throws: SpiderPackError.insecureURL) {
        try await subject.refresh(from: URL(string: "http://example.invalid/spiders/manifest.json")!)
    }
    await subject.reset()
}

// MARK: - last known good

@Test func aFailedRefreshLeavesTheWorkingPackExactlyWhereItWas() async throws {
    let directory = scratch()
    let good = script(marking: "good")
    let first = store([
        packURL.absoluteString: ok(manifest(version: "good",
                                            entries: [("AppGet", "./AppGet.js", sha256(good), nil, nil)])),
        "https://example.invalid/spiders/AppGet.js": ok(good)
    ], directory: directory)
    _ = try await first.refresh(from: packURL)

    // Every way a refresh can fail, against the same directory, one after another.
    let broken = script(marking: "broken")
    for responses in [
        [packURL.absoluteString: Result<(Data, Int), Error>.failure(URLError(.timedOut))],
        [packURL.absoluteString: .success((Data("{}".utf8), 404))],
        [packURL.absoluteString: ok("{ not json ")],
        [packURL.absoluteString: ok(manifest(version: "bad",
                                             entries: [("AppGet", "./AppGet.js", sha256(good), nil, nil)])),
         "https://example.invalid/spiders/AppGet.js": ok(broken)]
    ] {
        let attempt = store(responses, directory: directory)
        _ = try? await attempt.refresh(from: packURL)
        let surviving = try #require(await attempt.installedPack(), "the last good pack must survive")
        #expect(surviving.version == "good")
        #expect(surviving.scripts["AppGet"] == good)
    }

    // And offline, with nothing served at all, the cache is still what runs.
    let offline = store([:], directory: directory)
    _ = try? await offline.refresh(from: packURL)
    let cached = try #require(await offline.installedPack())
    #expect(cached.scripts["AppGet"] == good)
    await offline.reset()
}

@Test func aCacheEditedOnDeviceIsNotAPack() async throws {
    let directory = scratch()
    let good = script(marking: "good")
    let subject = store([
        packURL.absoluteString: ok(manifest(entries: [("AppGet", "./AppGet.js", sha256(good), nil, nil)])),
        "https://example.invalid/spiders/AppGet.js": ok(good)
    ], directory: directory)
    _ = try await subject.refresh(from: packURL)

    // Rewrite the cached script behind the store's back; the manifest's hash no longer describes it.
    try Data(script(marking: "tampered").utf8)
        .write(to: directory.appendingPathComponent("scripts/AppGet.js"))
    let reopened = store([:], directory: directory)
    #expect(await reopened.installedPack() == nil, "a hash that no longer matches is not a pack")
    await reopened.reset()
}

@Test func withoutAPackTheBundledScriptsAreWhatRun() throws {
    let registry = SpiderRegistry.bundled(overlaying: nil)
    #expect(registry.entry(for: "csp_AppGet")?.source == .bundled)
    #expect(registry.canDrive("csp_JPianAmns"), "the bundled alias still resolves without a pack")
    #expect(!registry.prelude.isEmpty)
}

// MARK: - IOS-POC-55 scoped class mappings

private let mappedConfig = URL(string: "https://example.invalid/cfg/wang-movie.json")!
private let mappedJar = "https://example.invalid/cfg/jar/renamed.jar"
private let jarBytes = Data("dex bytes as analysed".utf8)

/// A pack carrying the `GuaziTY` adapter and one mapping of the renamed class `GuaziTZ` onto it,
/// scoped the way `audit_spider_jars.py compat` writes it.
private func mappingPack(adapter body: String, analysedAdapter: String? = nil) async throws -> SpiderPack {
    let manifest = """
    {"schema": 1, "version": "map", "scripts": [
      {"class": "GuaziTY", "path": "./GuaziTY.js", "sha256": "\(sha256(body))"}],
     "mappings": [{"config": "\(mappedConfig.absoluteString)", "site": "瓜子-改名", "class": "GuaziTZ",
                   "jar": "\(mappedJar)", "jarSha256": "\(DrpyEngine.digest(jarBytes))", "adapter": "GuaziTY",
                   "adapterSha256": "\(analysedAdapter ?? sha256(body))",
                   "evidence": {"baseline": "GuaziTY@river-fman.jar", "runtime": "live golden"}}]}
    """
    return try await store([packURL.absoluteString: ok(manifest),
                            "https://example.invalid/spiders/GuaziTY.js": ok(body)],
                           directory: scratch()).refresh(from: packURL)
}

private func csp(_ key: String, _ api: String, jar: String? = "./jar/renamed.jar;md5;0123") throws -> Site {
    var object: [String: Any] = ["key": key, "name": key, "type": 3, "api": api]
    if let jar { object["jar"] = jar }
    return try JSONDecoder().decode(Site.self, from: JSONSerialization.data(withJSONObject: object))
}

private func isolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "packtests-\(UUID().uuidString)")!
}

@Test func aMappingAppliesOnlyInsideItsWholeScope() async throws {
    let pack = try await mappingPack(adapter: script(marking: "adapter"))
    #expect(pack.mappings.count == 1)
    let registry = SpiderRegistry.bundled(overlaying: pack)
    let source = ConfigSource.remote(mappedConfig)

    #expect(registry.mapping(for: try csp("瓜子-改名", "csp_GuaziTZ"), in: source)?.adapter == "GuaziTY")
    // The configuration's own query string is not a different configuration.
    let queried = ConfigSource.remote(URL(string: mappedConfig.absoluteString + "?ref_type=heads")!)
    #expect(registry.mapping(for: try csp("瓜子-改名", "csp_GuaziTZ"), in: queried) != nil)

    // Every other scope is a different class as far as the mapping is concerned.
    let sibling = ConfigSource.remote(URL(string: "https://example.invalid/cfg/wang-sex.json")!)
    #expect(registry.mapping(for: try csp("瓜子-改名", "csp_GuaziTZ"), in: sibling) == nil, "another configuration")
    #expect(registry.mapping(for: try csp("瓜子-改名", "csp_GuaziTZ"), in: .importedFile) == nil, "no origin")
    #expect(registry.mapping(for: try csp("別的站", "csp_GuaziTZ"), in: source) == nil, "another site key")
    #expect(registry.mapping(for: try csp("瓜子-改名", "csp_GuaziTZ", jar: "./jar/other.jar"), in: source) == nil,
            "the same class name in another JAR")
    #expect(registry.mapping(for: try csp("瓜子-改名", "csp_GuaziTZ", jar: nil), in: source) == nil, "no JAR at all")
    #expect(registry.mapping(for: try csp("瓜子-改名", "csp_GuaziTW"), in: source) == nil, "another class")

    // A name the registry already drives keeps its existing binding; a mapping never overrides it.
    #expect(registry.mapping(for: try csp("瓜子-改名", "csp_GuaziTY"), in: source) == nil)
    #expect(registry.canDrive("csp_GuaziTY"))
    // Without the pack nothing maps at all.
    #expect(SpiderRegistry.bundled(overlaying: nil).mapping(for: try csp("瓜子-改名", "csp_GuaziTZ"), in: source) == nil)
}

@Test func aMappingIsDroppedWhenTheAdapterIsNotTheAnalysedVersion() async throws {
    let pack = try await mappingPack(adapter: script(marking: "adapter v2"), analysedAdapter: sha256("adapter v1"))
    #expect(pack.mappings.isEmpty)
    #expect(pack.rejected.map(\.className) == ["GuaziTZ"])
    #expect(pack.scripts["GuaziTY"] != nil, "the adapter itself is still delivered")
}

@Test func aMappedSiteRunsTheAdapterOnlyOnTheAnalysedJar() async throws {
    let pack = try await mappingPack(adapter: script(marking: "adapter-ran"))
    let served = LockedBox(jarBytes)
    let requests = LockedBox([String]())
    let jars = JarFingerprints(defaults: isolatedDefaults()) { request in
        requests.value.append(request.value(forHTTPHeaderField: "If-None-Match") ?? "-")
        if request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"", served.value == jarBytes {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: nil, headerFields: nil))
        }
        return (served.value, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                              headerFields: ["ETag": served.value == jarBytes ? "\"v1\"" : "\"v2\""]))
    }
    let resolver = CSPSourceResolver(registry: SpiderRegistry.bundled(overlaying: pack),
                                     source: .remote(mappedConfig), defaults: isolatedDefaults(), jars: jars)
    let site = try csp("瓜子-改名", "csp_GuaziTZ")

    #expect(resolver.canResolve(site))
    let session = try await resolver.session(for: site)
    #expect(try await session.home().contains("adapter-ran"))
    // The site keeps its own identity: same key, same `ext`, so its storage is its own.
    #expect(await session.site.id == site.id)
    // A second check of an unchanged JAR is a 304, not a second download.
    _ = try await resolver.session(for: site)
    #expect(requests.value == ["-", "\"v1\""])

    // The JAR is updated: the mapping stops applying, with a reason that is not a site failure.
    served.value = Data("dex bytes after an update".utf8)
    await #expect(throws: ClassMappingUnverified.self) { try await resolver.session(for: site) }
    #expect(!resolver.canResolve(site), "a JAR known to have changed is not listed until it is analysed again")
}

@Test func aSiteWithoutItsOwnJarUsesTheConfigurationsSpider() throws {
    let config = try JSONDecoder().decode(WebHTVConfig.self, from: Data("""
    {"spider": "./jar/renamed.jar;md5;0123", "sites": [
      {"key": "a", "name": "a", "type": 3, "api": "csp_GuaziTZ"},
      {"key": "b", "name": "b", "type": 3, "api": "csp_GuaziTZ", "jar": "./jar/other.jar"},
      {"key": "c", "name": "c", "type": 1, "api": "https://example.invalid/api.php/provide/vod"}]}
    """.utf8))
    #expect(config.sites.map(\.jar) == ["./jar/renamed.jar;md5;0123", "./jar/other.jar", "./jar/renamed.jar;md5;0123"])
    // Identity is untouched by it: watch history, favourites and site memory stay attached.
    #expect(config.sites[0].id == (try csp("a", "csp_GuaziTZ", jar: nil)).id)
}

/// IOS-POC-55: a generated pack, read from its directory exactly as the app would fetch it, against a
/// real configuration. Every mapped site must be listed and must reach a play address through the
/// adapter it was mapped to. Gated, like the golden tests, because it goes to the live sites:
///
///     SPIDER_PACK_DIR=build/spider-pack SPIDER_PACK_CONFIG=https://…/wang-movie.json \
///       swift test --package-path ios --filter aGeneratedPackDrivesEveryMappedSite
@Test func aGeneratedPackDrivesEveryMappedSite() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let directory = environment["SPIDER_PACK_DIR"], let configURL = environment["SPIDER_PACK_CONFIG"]
        .flatMap(URL.init(string:)) else { return }
    let root = URL(fileURLWithPath: directory)
    let store = SpiderPackStore(directory: scratch()) { url in
        (try Data(contentsOf: root.appendingPathComponent(String(url.path.dropFirst()))),
         HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    }
    let pack = try await store.refresh(from: URL(string: "https://pack.invalid/manifest.json")!)
    let config = try JSONDecoder().decode(WebHTVConfig.self, from: Data(contentsOf: configURL))
    let source = ConfigSource.remote(configURL)
    let resolver = CSPSourceResolver(registry: .bundled(overlaying: pack), source: source,
                                     jars: JarFingerprints(defaults: isolatedDefaults()))
    let mapped = config.sites.filter { resolver.registry.mapping(for: $0, in: source) != nil }
    print("[pack] \(pack.version): \(pack.mappings.count) mapping(s), \(mapped.count) in this configuration, "
          + "rejected \(pack.rejected.map(\.className))")
    for site in mapped {
        #expect(resolver.canResolve(site))
        let session = try await resolver.session(for: site)
        func object(_ text: String) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        let home = try object(await session.home())
        let tid = try #require((home["class"] as? [[String: Any]])?.first?["type_id"] as? String)
        let list = try object(await session.category(tid: tid, page: "1"))["list"] as? [[String: Any]]
        let id = try #require(list?.first?["vod_id"] as? String, "\(site.key): empty listing")
        let detail = try object(await session.detail(ids: [id]))["list"] as? [[String: Any]]
        let urls = try #require(detail?.first?["vod_play_url"] as? String)
        let flag = (detail?.first?["vod_play_from"] as? String)?.components(separatedBy: "$$$").first ?? ""
        let first = urls.components(separatedBy: "$$$")[0].components(separatedBy: "#")[0]
        let play = try await session.player(flag: flag, id: String(first.drop(while: { $0 != "$" }).dropFirst()))
        #expect(play.contains("http"), "\(site.key): no play address")
        print("[pack] \(site.key) csp_\(SpiderRegistry.className(from: site.api)) → "
              + "\(resolver.registry.mapping(for: site, in: source)!.adapter): \(play.prefix(120))")
    }
    await store.reset()
}

/// Mutable state a `@Sendable` fetch closure can touch from a test.
private final class LockedBox<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
