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
