import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-12. The runtime-pack manifest contract: every way a candidate can be refused, and the
// per-scope state that decides rollback, duplicates and the last known good. Pure values only —
// no network, no disk — which is why each case is one call.

// MARK: - helpers

private let configA = URL(string: "https://example.invalid/repo/raw/main/wang-movie.json")!
private let configB = URL(string: "https://mirror.invalid/other/wang-movie.json")!
private let manifestA = URL(string: "https://example.invalid/repo/raw/main/runtime/manifest.json")!
private let manifestB = URL(string: "https://mirror.invalid/other/runtime/manifest.json")!
private let globalURL = URL(string: "https://releases.invalid/webhtv/runtime/manifest.json")!
private let host = RuntimeHost(appVersion: "0.1.31", appBuild: 32)
private let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09
private let later = "2027-01-01T00:00:00Z"

private func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private let spiderBody = "var spider = { homeContent: function () { return '{}'; } }; module.exports = spider;"

private func spiderFile(path: String = "spiders/JianPian.js", className: String = "JianPian",
                        body: String = spiderBody) -> [String: Any] {
    ["path": path, "logicalType": "spider.js", "class": className, "aliases": ["JPianAmns"],
     "bytes": Data(body.utf8).count, "sha256": digest(body)]
}

/// A configuration-scope manifest that passes; each test breaks one thing.
private func document(_ edit: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
    var object: [String: Any] = [
        "format": "webhtv.runtime-pack", "schema": 1, "packId": "recha.spiders",
        "scope": ["kind": "config"], "sequence": 3, "version": "2026.09.29-1",
        "requires": ["abi": ["js.host": ["major": 1, "minMinor": 1],
                             "catvod.result": ["major": 1, "minMinor": 0]]],
        "files": [spiderFile()],
        "notes": "修正薦片的站台位址",
    ]
    edit(&object)
    return object
}

private func data(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func requires(_ edit: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) -> Void {
    { object in
        var requires = object["requires"] as! [String: Any]
        edit(&requires)
        object["requires"] = requires
    }
}

private func file(_ edit: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) -> Void {
    { object in
        var file = (object["files"] as! [[String: Any]])[0]
        edit(&file)
        object["files"] = [file]
    }
}

private func validateConfig(_ object: [String: Any], url: URL = manifestA, configuration: URL = configA,
                            host: RuntimeHost = host) throws -> RuntimePackCandidate {
    try RuntimePackValidator.validate(manifest: data(object), signature: nil, fetchedFrom: url,
                                      scope: RuntimeScope(.remote(configuration))!,
                                      configurationURL: configuration, host: host, now: now)
}

/// The rejection a candidate gets, or `nil` if it was accepted.
private func rejection(_ body: () throws -> Any) -> RuntimePackRejection? {
    do {
        _ = try body()
        return nil
    } catch let error as RuntimePackRejection {
        return error
    } catch {
        Issue.record("unexpected error \(error)")
        return nil
    }
}

private struct Signer {
    let key = Curve25519.Signing.PrivateKey()
    var id: String { RuntimeTrustRoot.keyId(for: key.publicKey) }

    func sign(_ manifest: Data) throws -> Data {
        let signature = try key.signature(for: manifest)
        return try JSONEncoder().encode(RuntimePackSignature(keyId: id, sig: signature.base64EncodedString()))
    }
}

private func globalDocument(_ edit: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
    document { object in
        object["scope"] = ["kind": "global"]
        object["packId"] = "webhtv.spiders"
        object["expires"] = later
        edit(&object)
    }
}

// MARK: - compatibility with this build

@Test func aPackBuiltAgainstExactlyThisABIIsAccepted() throws {
    let candidate = try validateConfig(document())
    #expect(candidate.manifest.files.map(\.path) == ["spiders/JianPian.js"])
    #expect(candidate.signer == nil)
    #expect(candidate.generation.id.hasPrefix("gen-3-"))
}

@Test func aNewerMinorOrAnotherMajorIsRefusedAsNeedingANewerApp() {
    let installed = RuntimeABI.Surface.jsHost.version.minor
    let minor = rejection { try validateConfig(document(requires { $0["abi"] = ["js.host": ["major": 1, "minMinor": installed + 1], "catvod.result": ["major": 1, "minMinor": 0]] })) }
    #expect(minor == .abiTooNew(surface: "js.host", requiredMinor: installed + 1, installed: installed))
    #expect(minor?.requiresNewerApp == true)

    let major = rejection { try validateConfig(document(requires { $0["abi"] = ["js.host": ["major": 2, "minMinor": 0], "catvod.result": ["major": 1, "minMinor": 0]] })) }
    #expect(major == .abiMajorMismatch(surface: "js.host", required: 2, installed: 1))
    #expect(major?.requiresNewerApp == true)

    // An older major than this build is the pack being too old, not the App.
    let newerApp = RuntimeHost(appVersion: "0.1.31", appBuild: 32, abi: [.jsHost: .init(2, 0), .catvodResult: .init(1, 0)])
    let old = rejection { try validateConfig(document(), host: newerApp) }
    #expect(old == .abiMajorMismatch(surface: "js.host", required: 1, installed: 2))
    #expect(old?.requiresNewerApp == false)
}

@Test func anUnknownSurfaceOrTheWebHomeBridgeCannotBeRequired() {
    #expect(rejection { try validateConfig(document(requires { $0["abi"] = ["lua.host": ["major": 1, "minMinor": 0]] })) }
            == .unknownSurface("lua.host"))
    #expect(rejection { try validateConfig(document(requires { $0["abi"] = ["webhome.bridge": ["major": 1, "minMinor": 0]] })) }
            == .surfaceNotRequirable("webhome.bridge"))
}

@Test func anAppOlderOrNewerThanThePackAllowsIsRefused() {
    #expect(rejection { try validateConfig(document(requires { $0["minAppVersion"] = "0.1.40" })) }
            == .appVersionTooOld(required: "0.1.40", installed: "0.1.31"))
    #expect(rejection { try validateConfig(document(requires { $0["minAppBuild"] = 40 })) }
            == .appBuildTooOld(required: 40, installed: 32))
    let tooNew = rejection { try validateConfig(document(requires { $0["maxAppBuild"] = 30 })) }
    #expect(tooNew == .appBuildTooNew(maximum: 30, installed: 32))
    #expect(tooNew?.requiresNewerApp == false)
    // Numeric, not lexical: 0.1.9 is older than 0.1.31.
    #expect(rejection { try validateConfig(document(requires { $0["minAppVersion"] = "0.1.9"; $0["minAppBuild"] = 32 })) } == nil)
}

@Test func aMissingNativeCapabilityRefusesThePackBeforeAnyFileIsFetched() {
    // `js.host.rsaDecrypt` played the missing capability here until IOS-POC-44G gave the host one.
    let missing = rejection { try validateConfig(document(requires { $0["capabilities"] = ["js.host.webview", "js.host.aesDecryptIV", "catvod.result.proxy"] })) }
    #expect(missing == .missingCapabilities(["catvod.result.proxy", "js.host.webview"]))
    #expect(missing?.requiresNewerApp == true)
    #expect(rejection { try validateConfig(document(requires { $0["capabilities"] = ["js.host.aesDecryptIV", "catvod.result.playerContent"] })) } == nil)
}

@Test func aFileThatNeedsASurfaceTheManifestDidNotDeclareIsIncomplete() {
    #expect(rejection { try validateConfig(document(requires { $0["abi"] = ["js.host": ["major": 1, "minMinor": 1]] })) }
            == .undeclaredSurface(path: "spiders/JianPian.js", surface: "catvod.result"))
}

@Test func aKnownDynamicTypeWithoutAConsumerInThisBuildNeedsANewerApp() {
    let python = rejection { try validateConfig(document(file { $0["logicalType"] = "spider.py"; $0["path"] = "py/a.py" })) }
    #expect(python == .assetTypeNotSupported(path: "py/a.py", type: "spider.py"))
    #expect(python?.requiresNewerApp == true)
}

// MARK: - the document itself

@Test func anUnsupportedFormatOrSchemaIsRefusedBeforeAnythingElseIsRead() {
    #expect(rejection { try validateConfig(document { $0["schema"] = 2; $0["files"] = "a later shape" }) } == .unsupportedSchema(2))
    #expect(rejection { try validateConfig(document { $0["format"] = "webhtv.spider-pack" }) } == .unsupportedFormat("webhtv.spider-pack"))
    #expect(rejection { try validateConfig(document { $0["directive"] = "wipeEverything" }) } == .unsupportedDirective("wipeEverything"))
}

@Test func anIncompleteOrMalformedManifestIsRefused() throws {
    #expect(rejection { try validateConfig(document { $0.removeValue(forKey: "requires") }) } == .missingField("requires"))
    #expect(rejection { try validateConfig(document { $0.removeValue(forKey: "sequence") }) } == .missingField("sequence"))
    #expect(rejection { try validateConfig(document(file { $0.removeValue(forKey: "class") })) } == .missingField("files.class"))
    #expect(rejection { try validateConfig(document { $0["sequence"] = "3" }) } == .malformed("sequence"))
    #expect(rejection { try validateConfig(document { $0["sequence"] = 0 }) } == .malformed("sequence"))
    #expect(rejection { try validateConfig(document { $0["scope"] = ["kind": "device"] }) } == .malformed("scope.kind"))
    #expect(rejection { try validateConfig(document { $0["expires"] = "next year" }) } == .malformed("expires"))
    #expect(rejection { try validateConfig(document { $0["files"] = [] }) } == .emptyPack)
    #expect(rejection { try validateConfig(document { $0["packId"] = "Recha Spiders" }) } == .invalidPackId("Recha Spiders"))
    let notJSON = rejection {
        try RuntimePackValidator.validate(manifest: Data("<html>".utf8), signature: nil, fetchedFrom: manifestA,
                                          scope: RuntimeScope(.remote(configA))!, configurationURL: configA,
                                          host: host, now: now)
    }
    #expect(notJSON == .malformed("manifest"))
}

@Test func aMalformedVersionIsRefused() {
    #expect(rejection { try validateConfig(document(requires { $0["minAppVersion"] = "0.1.x" })) } == .invalidVersion("0.1.x"))
    #expect(rejection { try validateConfig(document(requires { $0["minAppVersion"] = "0.1.31.2" })) } == .invalidVersion("0.1.31.2"))
    #expect(rejection { try validateConfig(document { $0["version"] = "" }) } == .invalidVersion(""))
    #expect(rejection { try validateConfig(document(requires { $0["abi"] = ["js.host": ["major": 0, "minMinor": 1]] })) } == .invalidVersion("js.host"))
    #expect(rejection { try validateConfig(document(requires { $0["minAppBuild"] = 30; $0["maxAppBuild"] = 20 })) } == .invalidVersion("maxAppBuild"))
}

@Test func aPathIsARelativeNameInsideTheGenerationAndNothingElse() {
    for path in ["../JianPian.js", "spiders/../../JianPian.js", "/spiders/JianPian.js", "spiders//JianPian.js",
                 "./JianPian.js", "spiders/", "spiders/薦片.js", "spiders/Jian Pian.js",
                 "https://evil.invalid/JianPian.js", String(repeating: "a", count: 126) + ".js"] {
        #expect(rejection { try validateConfig(document(file { $0["path"] = path })) } == .invalidPath(path), "\(path)")
    }
    // A spider must be a script, whatever else it claims to be.
    #expect(rejection { try validateConfig(document(file { $0["path"] = "spiders/JianPian.txt" })) } == .invalidPath("spiders/JianPian.txt"))
}

@Test func twoSpellingsOfOnePathAreOneFile() {
    let upper = spiderFile(path: "spiders/JIANPIAN.js", className: "Other")
    #expect(rejection { try validateConfig(document { $0["files"] = [spiderFile(), upper] }) } == .duplicatePath("spiders/JIANPIAN.js"))
}

@Test func anUnknownLogicalTypeIsRefused() {
    let unknown = rejection { try validateConfig(document(file { $0["logicalType"] = "spider.lua" })) }
    #expect(unknown == .unknownAssetType(path: "spiders/JianPian.js", type: "spider.lua"))
    #expect(unknown?.requiresNewerApp == true)
}

@Test func nativeCodeOrConfigurationCanOnlyArriveInAnIPA() {
    #expect(rejection { try validateConfig(document(file { $0["logicalType"] = "native.framework" })) }
            == .nativeReleaseRequired("spiders/JianPian.js"))
    for path in ["Frameworks/Libmpv.framework/Libmpv", "lib/libavformat.dylib", "Info.plist",
                 "WebHTVApp.entitlements", "python/lib-dynload/_ssl.so", "Python.xcframework/x.js"] {
        #expect(rejection { try validateConfig(document(file { $0["path"] = path })) } == .nativeReleaseRequired(path), "\(path)")
    }
}

@Test func aSpiderCannotClaimToBeTheSDKOrAnUnsafeName() {
    for name in ["host", "js-spider", "../x", "", "Jian.Pian"] {
        #expect(rejection { try validateConfig(document(file { $0["class"] = name })) } == .invalidClass(path: "spiders/JianPian.js", name: name), "\(name)")
    }
    #expect(rejection { try validateConfig(document(file { $0["aliases"] = ["drpy-bridge"] })) }
            == .invalidClass(path: "spiders/JianPian.js", name: "drpy-bridge"))
}

@Test func aDigestIsSixtyFourLowercaseHexCharactersAndIsRequired() {
    #expect(rejection { try validateConfig(document(file { $0.removeValue(forKey: "sha256") })) } == .missingField("files[0].sha256"))
    for bad in [digest(spiderBody).uppercased(), String(digest(spiderBody).dropLast()), "md5;" + String(repeating: "0", count: 60)] {
        #expect(rejection { try validateConfig(document(file { $0["sha256"] = bad })) } == .invalidDigest("spiders/JianPian.js"))
    }
}

@Test func theSizeCeilingsAreTheApps() {
    #expect(rejection { try validateConfig(document(file { $0["bytes"] = RuntimePackLimits.fileBytes + 1 })) }
            == .fileTooLarge(path: "spiders/JianPian.js", bytes: RuntimePackLimits.fileBytes + 1))
    let big = (0..<5).map { index -> [String: Any] in
        var entry = spiderFile(path: "spiders/S\(index).js", className: "S\(index)")
        entry["bytes"] = 500 * 1024
        return entry
    }
    #expect(rejection { try validateConfig(document { $0["files"] = big }) } == .packTooLarge(5 * 500 * 1024))
    let many = (0...RuntimePackLimits.files).map { spiderFile(path: "spiders/S\($0).js", className: "S\($0)") }
    #expect(rejection { try validateConfig(document { $0["files"] = many }) } == .tooManyFiles(RuntimePackLimits.files + 1))
    #expect(rejection { try validateConfig(document { $0["notes"] = String(repeating: "字", count: 2000) }) } == .notesTooLong(6000))
    let huge = Data(count: RuntimePackLimits.manifestBytes + 1)
    #expect(rejection {
        try RuntimePackValidator.validate(manifest: huge, signature: nil, fetchedFrom: manifestA,
                                          scope: RuntimeScope(.remote(configA))!, configurationURL: configA,
                                          host: host, now: now)
    } == .manifestTooLarge(RuntimePackLimits.manifestBytes + 1))
}

// MARK: - identity

@Test func theSameContentHasTheSameIdentityHoweverItIsWritten() throws {
    let second = spiderFile(path: "spiders/AppGet.js", className: "AppGet", body: "var a = 1;")
    let one = try RuntimePackManifest.decode(data(document { $0["files"] = [spiderFile(), second] }))
    // Reordered files, reordered aliases, pretty-printed: the same pack.
    var reordered = document { $0["files"] = [second, spiderFile()] }
    reordered["requires"] = ["abi": ["catvod.result": ["major": 1, "minMinor": 0], "js.host": ["major": 1, "minMinor": 1]]]
    let two = try RuntimePackManifest.decode(JSONSerialization.data(withJSONObject: reordered, options: [.prettyPrinted]))
    #expect(one.contentIdentity == two.contentIdentity)
    #expect(one == two)

    let changed = try RuntimePackManifest.decode(data(document { $0["files"] = [spiderFile(body: spiderBody + " "), second] }))
    #expect(changed.contentIdentity != one.contentIdentity)
    #expect(one.contentIdentity.count == 64)
}

@Test func theScopeIsDerivedFromTheConfigurationAndNeverNormalised() throws {
    #expect(RuntimeScope.global.key == "global")
    #expect(RuntimeScope(.importedFile) == nil)
    let scope = try #require(RuntimeScope(.remote(configA)))
    #expect(scope.key == "config:https://example.invalid/repo/raw/main/wang-movie.json")
    #expect(scope.key == "config:" + ConfigSource.remote(configA).identity)
    // Host case and a trailing slash are different addresses, exactly as watch history treats them.
    let other = try #require(RuntimeScope(.remote(URL(string: "https://EXAMPLE.invalid/repo/raw/main/wang-movie.json")!)))
    #expect(other != scope)
    #expect(scope.storageName == digest(scope.key))
    #expect(RuntimeScope.global.storageName != scope.storageName)
}

// MARK: - origin, trust and scope

@Test func aConfigurationPackMustComeFromTheConfigurationsOwnHTTPSOrigin() {
    let http = URL(string: "http://example.invalid/repo/raw/main/runtime/manifest.json")!
    #expect(rejection { try validateConfig(document(), url: http) } == .insecureOrigin(http.absoluteString))
    #expect(rejection { try validateConfig(document(), url: manifestB) } == .crossOrigin(manifestB.absoluteString))
}

@Test func aConfigurationPackCanNeverRevokeKeysOrClaimGlobalScope() {
    #expect(rejection { try validateConfig(document { $0["revokeKeyIds"] = ["0123456789abcdef"] }) } == .revocationNotPermitted)
    #expect(rejection { try validateConfig(document { $0["scope"] = ["kind": "global"] }) }
            == .scopeMismatch(declared: "global", expected: "config"))
}

@Test func aGlobalPackIsAuthenticOnlyWithACompiledInKey() throws {
    let active = Signer()
    let trust = RuntimeTrustRoot([(active.key.publicKey, .active)])
    let body = try data(globalDocument())
    func validate(_ manifest: Data, _ signature: Data?, trust: RuntimeTrustRoot = trust,
                  revoked: Set<String> = []) throws -> RuntimePackCandidate {
        try RuntimePackValidator.validate(manifest: manifest, signature: signature, fetchedFrom: globalURL,
                                          scope: .global, configurationURL: nil, host: host, trust: trust,
                                          revokedKeyIds: revoked, now: now)
    }

    let candidate = try validate(body, active.sign(body))
    #expect(candidate.signer == .active)
    #expect(candidate.manifestSHA256 == SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined())

    #expect(rejection { try validate(body, nil) } == .signatureRequired)
    // This build ships no key yet, so nothing global is accepted.
    #expect(rejection { try validate(body, active.sign(body), trust: .bundled) } == .unknownKey(active.id))
    #expect(rejection { try validate(body, Signer().sign(body)) } != nil)
    #expect(rejection { try validate(body, active.sign(body), revoked: [active.id]) } == .revokedKey(active.id))
    // The digest inside a manifest proves nothing about who wrote it: one changed byte, same signature.
    let tampered = try data(globalDocument { $0["notes"] = "修正薦片的站台位址！" })
    #expect(rejection { try validate(tampered, active.sign(body)) } == .badSignature)
    #expect(rejection { try validate(body, Data("{\"keyId\":\"x\",\"alg\":\"rsa\",\"sig\":\"\"}".utf8)) } == .signatureMalformed)
    // An active key cannot revoke; only the offline backup can.
    let revoking = try data(globalDocument { $0["revokeKeyIds"] = ["0123456789abcdef"] })
    #expect(rejection { try validate(revoking, active.sign(revoking)) } == .revocationNotPermitted)
}

@Test func aGlobalPackMustBeFreshAndSayWhenItStopsBeing() throws {
    let active = Signer()
    let trust = RuntimeTrustRoot([(active.key.publicKey, .active)])
    func validate(_ object: [String: Any]) throws -> RuntimePackCandidate {
        let body = try data(object)
        return try RuntimePackValidator.validate(manifest: body, signature: active.sign(body), fetchedFrom: globalURL,
                                                 scope: .global, configurationURL: nil, host: host, trust: trust, now: now)
    }
    #expect(rejection { try validate(globalDocument { $0.removeValue(forKey: "expires") }) } == .missingField("expires"))
    #expect(rejection { try validate(globalDocument { $0["expires"] = "2026-01-01T00:00:00Z" }) } == .expired)
}

@Test func switchingConfigurationsAToBToAComesBackToAsOwnGeneration() throws {
    let scopeA = try #require(RuntimeScope(.remote(configA)))
    let scopeB = try #require(RuntimeScope(.remote(configB)))
    let candidateA = try validateConfig(document())
    var states = [scopeA.key: RuntimeScopeState(scope: scopeA, packId: "recha.spiders").activating(candidateA)]

    // B sees nothing of A's: its own scope has no state, and A's manifest cannot be used for B —
    // not from B's host, and not even from A's host when it is pinned to A.
    #expect(states[scopeB.key] == nil)
    #expect(rejection { try validateConfig(document(), url: manifestA, configuration: configB) } == .crossOrigin(manifestA.absoluteString))
    let sameHostB = URL(string: "https://example.invalid/b/wang-movie.json")!
    let pinned = document { $0["scope"] = ["kind": "config", "configIdentity": configA.absoluteString] }
    #expect(rejection { try validateConfig(pinned, url: manifestA, configuration: sameHostB) }
            == .scopeMismatch(declared: "config:" + configA.absoluteString, expected: "config:" + sameHostB.absoluteString))
    // …and a candidate validated for B cannot enter A's state.
    let candidateB = try validateConfig(document(), url: manifestB, configuration: configB)
    #expect(states[scopeA.key]?.admission(of: candidateB) == .reject(.scopeMismatch(declared: scopeB.key, expected: scopeA.key)))
    states[scopeB.key] = RuntimeScopeState(scope: scopeB, packId: "recha.spiders").activating(candidateB)

    #expect(states[scopeA.key]?.active == candidateA.generation)
    #expect(states[scopeB.key]?.active == candidateB.generation)
}

// MARK: - generation and history

@Test func aGenerationIsCompleteOnlyWithExactlyTheManifestsFiles() throws {
    let manifest = try RuntimePackManifest.decode(data(document()))
    let path = "spiders/JianPian.js"
    let good = Data(spiderBody.utf8)
    try RuntimePackValidator.verifyGeneration(of: manifest, files: [path: good])
    #expect(rejection { try RuntimePackValidator.verifyGeneration(of: manifest, files: [:]) } == .fileMissing(path))
    #expect(rejection { try RuntimePackValidator.verifyGeneration(of: manifest, files: [path: good + Data("x".utf8)]) }
            == .sizeMismatch(path: path, expected: good.count, actual: good.count + 1))
    var flipped = good
    flipped[0] ^= 1
    #expect(rejection { try RuntimePackValidator.verifyGeneration(of: manifest, files: [path: flipped]) } == .digestMismatch(path))
    #expect(rejection { try RuntimePackValidator.verifyGeneration(of: manifest, files: [path: good, "spiders/x.js": good]) }
            == .unexpectedFile("spiders/x.js"))
}

@Test func theSameGenerationTwiceIsNothingAndAReusedSequenceIsRefused() throws {
    let scope = try #require(RuntimeScope(.remote(configA)))
    let first = try validateConfig(document())
    let state = RuntimeScopeState(scope: scope, packId: "recha.spiders").activating(first)
    #expect(state.admission(of: try validateConfig(document())) == .unchanged)
    let reused = try validateConfig(document { $0["notes"] = "different" })
    #expect(state.admission(of: reused) == .reject(.sequenceReused(3)))
    #expect(state.admission(of: try validateConfig(document { $0["packId"] = "other.pack" })) == .reject(.packIdMismatch("other.pack")))
}

@Test func anOlderSequenceIsARollbackAndIsRefused() throws {
    let scope = try #require(RuntimeScope(.remote(configA)))
    let state = RuntimeScopeState(scope: scope, packId: "recha.spiders").activating(try validateConfig(document()))
    #expect(state.admission(of: try validateConfig(document { $0["sequence"] = 2 })) == .reject(.rollback(sequence: 2, floor: 3)))
    #expect(state.admission(of: try validateConfig(document { $0["sequence"] = 4 })) == .accept)
}

@Test func theActiveGenerationBecomesTheLastKnownGoodAndABadOneIsNeverRetried() throws {
    let scope = try #require(RuntimeScope(.remote(configA)))
    let three = try validateConfig(document())
    let four = try validateConfig(document { $0["sequence"] = 4 })
    var state = RuntimeScopeState(scope: scope, packId: "recha.spiders").activating(three).activating(four)
    #expect(state.active == four.generation)
    #expect(state.lastKnownGood == three.generation)
    #expect(state.floor == 4)

    state = state.markingBad(four.generation, reason: "load smoke failed")
    #expect(state.active == three.generation)
    #expect(state.lastKnownGood == nil)
    #expect(state.floor == 4)
    #expect(state.admission(of: four) == .reject(.knownBad(four.generation.id)))

    // The state is plain data a client can persist and read back unchanged.
    let decoded = try JSONDecoder().decode(RuntimeScopeState.self, from: JSONEncoder().encode(state))
    #expect(decoded == state)
}

@Test func withdrawingAPackGoesBackToTheBundledScripts() throws {
    let scope = try #require(RuntimeScope(.remote(configA)))
    let withdraw = try validateConfig(document { $0["sequence"] = 5; $0["directive"] = "rollbackToBundled"; $0["files"] = [] })
    let state = RuntimeScopeState(scope: scope, packId: "recha.spiders")
        .activating(try validateConfig(document())).activating(withdraw)
    #expect(state.active == nil)
    #expect(state.lastKnownGood == nil)
    #expect(state.floor == 5)
    #expect(rejection { try validateConfig(document { $0["directive"] = "rollbackToBundled" }) } == .malformed("files"))
}

@Test func theBackupKeyResetsTheFloorOncePerRevocationAndNeverOnReplay() throws {
    let active = Signer()
    let backup = Signer()
    let trust = RuntimeTrustRoot([(active.key.publicKey, .active), (backup.key.publicKey, .backup)])
    func candidate(_ object: [String: Any], by signer: Signer, revoked: [String] = []) throws -> RuntimePackCandidate {
        let body = try data(object)
        return try RuntimePackValidator.validate(manifest: body, signature: signer.sign(body), fetchedFrom: globalURL,
                                                 scope: .global, configurationURL: nil, host: host, trust: trust,
                                                 revokedKeyIds: Set(revoked), now: now)
    }
    // A stolen active key pushed the floor to the top.
    let attack = try candidate(globalDocument { $0["sequence"] = 9_000_000_000_000 }, by: active)
    var state = RuntimeScopeState(scope: .global, packId: "webhtv.spiders").activating(attack)
    let recovery = try candidate(globalDocument { $0["sequence"] = 7; $0["revokeKeyIds"] = [active.id] }, by: backup)
    #expect(state.admission(of: recovery) == .accept)
    state = state.activating(recovery)
    #expect(state.floor == 7)
    #expect(state.revokedKeyIds == [active.id])
    #expect(state.lastKnownGood == nil)

    // Replaying the same backup-signed manifest later does not reset anything a second time.
    let replay = try candidate(globalDocument { $0["sequence"] = 6; $0["revokeKeyIds"] = [active.id] },
                               by: backup, revoked: state.revokedKeyIds)
    #expect(state.admission(of: replay) == .reject(.rollback(sequence: 6, floor: 7)))
    // And the revoked key is refused outright.
    #expect(rejection { try candidate(globalDocument { $0["sequence"] = 8 }, by: active, revoked: state.revokedKeyIds) }
            == .revokedKey(active.id))
}
