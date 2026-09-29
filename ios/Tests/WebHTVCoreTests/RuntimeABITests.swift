import CryptoKit
import Foundation
import JavaScriptCore
import Testing
@testable import WebHTVCore

// IOS-POC-12. `RuntimeABI`'s version numbers are only worth something if they cannot drift from
// what they describe. `SpiderPackStore.hostApiVersion` did once: `7c76d5c2` changed `host.js`'s
// selectors and the number stayed 1. These tests fingerprint everything each surface is made of,
// so changing any of it without bumping the version fails here.

private let ios = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let repo = ios.deletingLastPathComponent()

private func read(_ path: String, in base: URL = ios) throws -> String {
    try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8)
}

private func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func matches(_ pattern: String, in text: String) throws -> [String] {
    let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
        Range($0.range(at: 1), in: text).map { String(text[$0]) }
    }
}

/// version → fingerprint. **A row whose version has shipped in an IPA is append-only**: change the
/// surface, bump `RuntimeABI.Surface.version`, add a row. A row may be rewritten only while its
/// version has never shipped, with the reason recorded in docs/IOS-POC-12. "The ABI did not really
/// change" is not a reason — a comment-only edit bumps too, which is the conservative price of never
/// having to judge that by hand.
private let frozen: [RuntimeABI.Surface: [RuntimeABI.Version: String]] = [
    .catvodResult: [.init(1, 0): "d62107dd0a481f15ec026a0bc6d7c5f766db1d6a3ea4c2de26ff1ff5b3021c5b"],
    .jsHost: [.init(1, 1): "3724fb8a7f10f4c4467aadc3280d616c30a1801e319ef12d45ed4deba40d798b"],
    .pythonHost: [.init(1, 0): "151b866af42baf0cde224ff3cdcf6ca501a4c6ae6dc7274f9d0c1870958769f7",
                  // IOS-POC-37: pycryptodome, lxml, bs4, pyquery; `html()`; void `init`.
                  .init(1, 1): "b93c7a05a0afe66cd35c0b3992650c582109b9b475da4e36f233a34f02b3843a"],
    .webhomeBridge: [.init(1, 0): "80325b0e8d19a32d66ab0d6d3a6e306079dd821eaf4e1a4cba0f51f60a6e2582"],
]

/// What `host.js` and the native primitives under it expose, read from a live `JSContext` — the
/// engine every spider runs in — rather than from the source text.
private func javaScriptHost() throws -> (natives: [String], exports: [String]) {
    let context = try #require(JSContext())
    let before = try #require(context.evaluateScript("JSON.stringify(Object.getOwnPropertyNames(globalThis))")?.toString())
    CatVodHost.install(into: context, storage: SpiderStorage(siteKey: "runtime-abi"), cookies: CookieJar(),
                       session: .webHTV)
    context.evaluateScript(try read("Sources/WebHTVCore/Resources/Spiders/host.js"))
    // Every global the host added, and for an object, the names on it.
    let added = try #require(context.evaluateScript("""
        (function (before) {
          return Object.getOwnPropertyNames(globalThis)
            .filter(function (n) { return before.indexOf(n) < 0 && n !== 'host'; }).sort()
            .map(function (n) {
              var v = globalThis[n];
              return n + (v !== null && typeof v === 'object' ? ':' + Object.keys(v).sort().join('|') : '');
            });
        })(\(before))
        """)?.toArray() as? [String])
    let exports = try #require(context.evaluateScript("Object.keys(host).sort()")?.toArray() as? [String])
    return (added, exports)
}

/// Everything a surface is made of, as text. Each line is a thing a script can call, a thing the
/// App reads back, or the digest of a file that implements one.
private func canonical(_ surface: RuntimeABI.Surface) throws -> String {
    var lines = [String]()
    switch surface {
    case .catvodResult:
        let runtime = try read("Sources/WebHTVCore/Spider/SpiderRuntime.swift")
        let protocolBody = try #require(try matches(#"public protocol SpiderRuntime[^{]*\{([^}]*)\}"#, in: runtime).first)
        lines += protocolBody.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("func ") }.map { "requirement " + $0 }
        let session = try read("Sources/WebHTVCore/Spider/SpiderSession.swift")
        lines += Set(try matches(#"runtime\.([A-Za-z]+)\("#, in: session)).sorted().map { "called " + $0 }
        // The JSON keys the App's decoders read back: a new key is a new output field.
        for file in ["CMSClient.swift", "PlayURL.swift", "SourceClient.swift"] {
            let text = try read("Sources/WebHTVCore/" + file)
            for block in try matches(#"enum CodingKeys: String, CodingKey \{([^}]*)\}"#, in: text) {
                let cases = block.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("//") }.joined(separator: " ")
                lines.append("keys \(file) \(cases)")
            }
        }
        lines += try matches(#"^(struct PlayResponse[^{]*\{[^}]*\})"#, in: read("Sources/WebHTVCore/CMSClient.swift"))
            .map { $0.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") }
    case .jsHost:
        for name in ["host.js", "drpy-bridge.js", "js-spider.js"] {
            lines.append("file \(name) " + sha256(try read("Sources/WebHTVCore/Resources/Spiders/" + name)))
        }
        lines.append("moduleRuntime " + sha256(DrpyEngine.moduleRuntime))
        let host = try javaScriptHost()
        lines += host.natives.map { "native " + $0 }
        lines += host.exports.map { "export " + $0 }
    case .pythonHost:
        for path in ["WebHTVApp/Python/base/spider.py", "WebHTVApp/Python/base/__init__.py",
                     "WebHTVApp/Python/webhtv_runtime.py"] {
            lines.append("file \(path) " + sha256(try read(path)))
        }
        let lock = try #require(try JSONSerialization.jsonObject(
            with: Data(read("third_party/python-ios-lock.json", in: repo).utf8)) as? [String: Any])
        let upstream = try #require(lock["upstream"] as? [String: Any])
        lines.append("cpython \(upstream["release"] ?? "")")
        let wheels = try #require((lock["python_packages"] as? [String: Any])?["wheels"] as? [[String: Any]])
        lines += wheels.map { "wheel \($0["name"] ?? "")==\($0["version"] ?? "")" }.sorted()
        // IOS-POC-37: built from source, libxml2 and libxslt included — they are what `lxml` is.
        let native = (lock["python_native_packages"] as? [String: Any])?["sources"] as? [[String: Any]] ?? []
        lines += native.map { "native \($0["name"] ?? "")==\($0["version"] ?? "")" }.sorted()
    case .webhomeBridge:
        lines.append("sdk " + sha256(WebHomeBridge.sdkScript))
        lines += Set(try matches(#"case "([a-z]+\.[A-Za-z.]+)":"#, in: read("Sources/WebHTVCore/WebHomeBridge.swift")))
            .sorted().map { "method " + $0 }
    }
    return lines.joined(separator: "\n")
}

@Test(arguments: RuntimeABI.Surface.allCases)
func everySurfaceMatchesTheFingerprintItsVersionWasFrozenWith(_ surface: RuntimeABI.Surface) throws {
    let text = try canonical(surface)
    let fingerprint = sha256(text)
    let expected = frozen[surface]?[surface.version]
    #expect(fingerprint == expected, """
        \(surface.rawValue) \(surface.version) no longer matches its frozen fingerprint.
        Bump RuntimeABI.Surface.version and add a row (see the comment on `frozen`).
        fingerprint \(fingerprint) of:
        \(text)
        """)
}

@Test func theJavaScriptHostOffersExactlyTheCapabilitiesThisBuildDeclares() throws {
    #expect(try javaScriptHost().exports == RuntimeABI.jsHostExports.sorted())
}

@Test func theCatVodCapabilitiesAreExactlyTheMethodsTheAppCalls() throws {
    let session = try read("Sources/WebHTVCore/Spider/SpiderSession.swift")
    #expect(Set(try matches(#"runtime\.([A-Za-z]+)\("#, in: session)).sorted() == RuntimeABI.catvodMethods.sorted())
    // `SpiderSession` is the only production caller (K1): nothing else may start calling a method
    // the capability set says no spider can rely on. Only the DEBUG self-check in `PythonBoot` does.
    let unsupported = ["liveContent", "isVideoFormat", "manualVideoCheck", "proxy", "action"]
    let sources = [ios.appendingPathComponent("Sources/WebHTVCore"), ios.appendingPathComponent("WebHTVApp/Sources")]
    for directory in sources {
        for case let file as URL in try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        where file.pathExtension == "swift" && file.lastPathComponent != "PythonBoot.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for method in unsupported {
                #expect(!text.contains(".\(method)("), "\(file.lastPathComponent) calls \(method)")
            }
        }
    }
}

@Test func thePythonCapabilitiesAreExactlyTheVendoredPackages() throws {
    let lock = try #require(try JSONSerialization.jsonObject(
        with: Data(read("third_party/python-ios-lock.json", in: repo).utf8)) as? [String: Any])
    let wheels = try #require((lock["python_packages"] as? [String: Any])?["wheels"] as? [[String: Any]])
    // The natively built Python packages (IOS-POC-37), not the C libraries under lxml: a script
    // imports `lxml`, never `libxml2`.
    let native = try #require((lock["python_native_packages"] as? [String: Any])?["sources"] as? [[String: Any]])
        .filter { $0["kind"] as? String == "sdist" }
    #expect((wheels + native).compactMap { $0["name"] as? String }.sorted() == RuntimeABI.pythonPackages.sorted())
}

@Test func everyCapabilityBelongsToASurfaceAPackCanRequire() {
    let requirable = RuntimeABI.Surface.allCases.filter(\.isRequirable)
    #expect(requirable == [.catvodResult, .jsHost, .pythonHost])
    for capability in RuntimeABI.capabilities {
        #expect(requirable.contains { capability.hasPrefix($0.rawValue + ".") }, "\(capability)")
    }
    #expect(RuntimeABI.capabilities.count
            == RuntimeABI.catvodMethods.count + RuntimeABI.jsHostExports.count + RuntimeABI.pythonPackages.count)
}

/// A schema-1 compatibility pack keeps working unchanged: its `minHostApi` n is `js.host` {1, n},
/// and the publisher script agrees with the App on every number and on what is not packable.
@Test func theCompatibilityPackGateIsTheJavaScriptHostMinor() throws {
    #expect(RuntimeABI.Surface.jsHost.version.major == 1)
    #expect(SpiderPackStore.hostApiVersion == RuntimeABI.Surface.jsHost.version.minor)
    #expect(SpiderPackStore.hostApiVersion == 1)

    let tool = try read("scripts/spider_pack.py", in: repo)
    #expect(try matches(#"^SCHEMA = (\d+)$"#, in: tool) == [String(SpiderPack.schema)])
    #expect(try matches(#"^HOST_API = (\d+)$"#, in: tool) == [String(SpiderPackStore.hostApiVersion)])
    let notPackable = try #require(try matches(#"^NOT_PACKABLE = \{([^}]*)\}$"#, in: tool).first)
    let names = notPackable.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
    #expect(Set(names) == RuntimeABI.nativeScripts)
    for name in RuntimeABI.nativeScripts {
        #expect(FileManager.default.fileExists(atPath: ios.appendingPathComponent("Sources/WebHTVCore/Resources/Spiders/" + name).path))
    }
}
