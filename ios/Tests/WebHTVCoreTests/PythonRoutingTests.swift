import Foundation
import Testing
@testable import WebHTVCore

/// IOS-POC-7H. The half of the Python work that is platform-neutral: which sites count as Python,
/// when one is offered, and what the transport rules refuse.
///
/// These run on macOS, where the interpreter does not exist — deliberately. Everything that needs
/// CPython is driven in the Simulator instead; nothing here pretends otherwise, and the runtime is
/// stood in for by a stub so the routing can be tested without one.

private func site(_ json: String) throws -> Site {
    try JSONDecoder().decode(Site.self, from: Data(json.utf8))
}

private let origin = URL(string: "https://config.example/base/wang-movie.json")!

/// Stands in for `PythonSpiderRuntime`, which cannot exist here. Records what it was handed.
private final class StubRuntime: SpiderRuntime, @unchecked Sendable {
    nonisolated(unsafe) static var lastScript = ""
    nonisolated(unsafe) static var lastSiteKey = ""

    init(script: String, siteKey: String) {
        Self.lastScript = script
        Self.lastSiteKey = siteKey
    }

    func initialize(extend: String) async throws {}
    func homeContent(filter: Bool) async throws -> String { "{}" }
    func categoryContent(tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> String { "{}" }
    func detailContent(ids: [String]) async throws -> String { "{}" }
    func searchContent(key: String, quick: Bool, page: String) async throws -> String { "{}" }
    func playerContent(flag: String, id: String, vipFlags: [String]) async throws -> String { "{}" }
}

/// Installs a stub for the duration of one test and takes it away again, so a test that runs after
/// one of these does not inherit an interpreter that is not there.
private func withRuntime<T>(_ body: () async throws -> T) async rethrows -> T {
    PythonSpiderSupport.makeRuntime = { script, key in StubRuntime(script: script, siteKey: key) }
    defer { PythonSpiderSupport.makeRuntime = nil }
    return try await body()
}

/// Serialized on purpose. `PythonSpiderSupport.makeRuntime` is process-global — that is what lets
/// the app install an interpreter core cannot construct — so two of these tests running at once
/// would see each other's stub, or each other's teardown. The global is the seam, not an accident,
/// and this is the cost of having one.
@Suite(.serialized) struct PythonRoutingTests {
    @Test func aPythonSiteIsATypeThreeWhoseApiIsAScript() throws {
        #expect(try site(#"{"key":"p","name":"p","type":3,"api":"./py/皮皮虾.py"}"#).isPythonSpider)
        #expect(try site(#"{"key":"p","name":"p","type":3,"api":"./PY/Upper.PY"}"#).isPythonSpider)
        // Not a Python site: another engine, another type, or a name that merely contains the letters.
        #expect(try site(#"{"key":"c","name":"c","type":3,"api":"csp_AppGet"}"#).isPythonSpider == false)
        #expect(try site(#"{"key":"d","name":"d","type":3,"api":"./drpy_libs/drpy2.min.js"}"#).isPythonSpider == false)
        #expect(try site(#"{"key":"m","name":"m","type":1,"api":"https://host/api.py"}"#).isPythonSpider == false)
        #expect(try site(#"{"key":"x","name":"x","type":3,"api":"./py/thing.python"}"#).isPythonSpider == false)
    }

    @Test func aPythonSiteIsHiddenUntilTheBuildHasAnInterpreter() throws {
        let resolver = CSPSourceResolver(source: .remote(origin))
        let target = try site(#"{"key":"p","name":"p","type":3,"api":"./py/皮皮虾.py"}"#)
        // macOS has no interpreter, and no stub is installed here.
        #expect(PythonSpiderSupport.isAvailable == false)
        #expect(resolver.canResolve(target) == false)
    }

    @Test func aPythonSiteIsOfferedOnceAnInterpreterIsInstalled() async throws {
        let target = try site(#"{"key":"p","name":"p","type":3,"api":"./py/皮皮虾.py"}"#)
        await withRuntime {
            #expect(CSPSourceResolver(source: .remote(origin)).canResolve(target))
            // An imported file has no origin, so it can never satisfy the same-origin rule and the site
            // is not offered even with an interpreter present.
            #expect(CSPSourceResolver(source: .importedFile).canResolve(target) == false)
        }
    }

    @Test func anImportedConfigurationRefusesAPythonScriptOutright() async throws {
        let target = try site(#"{"key":"p","name":"p","type":3,"api":"./py/皮皮虾.py"}"#)
        await #expect(throws: PythonSpiderSource.Failure.noRemoteConfiguration) {
            _ = try await PythonSpiderSource.script(for: target, source: .importedFile)
        }
    }

    @Test func aCrossOriginOrCleartextScriptIsRefusedBeforeAnyRequest() async throws {
        // Each of these is a real shape from the user's configuration: two of the three cross-origin
        // scripts there are plain HTTP. None of them may be fetched, and coverage is not a reason to
        // relax that — IOS-POC-6B set the rule and this reuses its implementation.
        for api in ["http://itv666.cc/py/thing.py", "https://git.yylx.win/py/thing.py"] {
            let target = try site(#"{"key":"p","name":"p","type":3,"api":"\#(api)"}"#)
            await #expect(throws: PythonSpiderSource.Failure.self) {
                _ = try await PythonSpiderSource.script(for: target, source: .remote(origin))
            }
        }
    }

    @Test func aCleartextConfigurationCannotServeAPythonScriptEither() async throws {
        // The origin itself is http, so even a same-host script fails the HTTPS half of the rule.
        let target = try site(#"{"key":"p","name":"p","type":3,"api":"./py/thing.py"}"#)
        await #expect(throws: PythonSpiderSource.Failure.self) {
            _ = try await PythonSpiderSource.script(
                for: target, source: .remote(URL(string: "http://config.example/base/config.json")!))
        }
    }

    @Test func anOversizedScriptIsAbandonedRatherThanLoaded() async throws {
        let target = try site(#"{"key":"p","name":"p","type":3,"api":"./py/huge.py"}"#)
        await #expect(throws: PythonSpiderSource.Failure.self) {
            _ = try await PythonSpiderSource.script(
                for: target, source: .remote(URL(string: "https://py.invalid/base/config.json")!),
                session: stubbedSession())
        }
    }

    @Test func aScriptFromTheConfigurationsOwnOriginReachesTheRuntime() async throws {
        let target = try site(#"{"key":"pipi","name":"p","type":3,"api":"./py/small.py","ext":"HOST"}"#)
        try await withRuntime {
            _ = try await CSPSourceResolver(
                source: .remote(URL(string: "https://py.invalid/base/config.json")!),
                session: stubbedSession()).session(for: target)
            // The script the server sent is the script the runtime was handed, under the site's own key.
            // `ext` is not asserted here because it travels through the same `resolvedExtend` every
            // other spider uses, which the drpy and csp tests already cover.
            #expect(StubRuntime.lastScript.contains("class Spider"))
            #expect(StubRuntime.lastSiteKey == "pipi")
        }
    }
}

// MARK: - a server that answers two scripts, one of them far too big

private final class ScriptServer: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "py.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.lastPathComponent ?? ""
        let body = path == "huge.py"
            ? Data(repeating: UInt8(ascii: "#"), count: PythonSpiderSource.maximumScriptBytes + 1)
            : Data("from base.spider import Spider\nclass Spider(Spider):\n    pass\n".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/plain"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func stubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ScriptServer.self]
    return URLSession(configuration: configuration)
}
