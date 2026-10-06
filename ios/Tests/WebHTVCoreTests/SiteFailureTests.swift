import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-41A: an empty listing behind a failed request says why. The causes are the ones
// IOS-POC-39 section 7 found on real dead sites; the integration tests drive the bundled `XBPQ.js`
// through `SourceClient` against canned answers, each on its own `.invalid` host.

/// Answers by exact URL with a page or a transport error; anything unlisted is an empty 200.
private final class FailingSite: URLProtocol, @unchecked Sendable {
    enum Answer { case page(Int, [String: String], String), error(URLError.Code) }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: Answer] = [:]

    static func serve(_ served: [String: Answer]) {
        lock.withLock { served.forEach { answers[$0.key] = $0.value } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".invalid") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let answer = Self.lock.withLock { Self.answers[request.url!.absoluteString] } ?? .page(200, [:], "")
        switch answer {
        case .error(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code, userInfo: [NSURLErrorFailingURLErrorKey: request.url!]))
        case .page(let status, let headers, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: headers.merging(["Content-Type": "text/html"]) { a, _ in a })!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

private func client(_ extend: String) throws -> SourceClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FailingSite.self]
    let registry = SpiderRegistry.bundled()
    let runtime = try JavaScriptSpiderRuntime(
        name: "XBPQ", script: try #require(registry.entry(for: "csp_XBPQ")?.script), prelude: registry.prelude,
        storage: SpiderStorage(siteKey: "site-failure", defaults: UserDefaults(suiteName: "site-failure")!),
        session: URLSession(configuration: configuration))
    let site = try JSONDecoder().decode(Site.self, from: Data(#"{"key":"f","name":"f","type":3,"api":"csp_XBPQ"}"#.utf8))
    return .spider(SpiderSession(site: site, runtime: runtime, extend: extend), site)
}

private func rule(_ host: String) -> String {
    #"{"分类url":"https://\#(host)/t/{cateId}/{catePg}.html","分类":"国产$1#日韩$2"}"#
}

@Test func sortsTransportErrorsIntoCauses() {
    let cases: [(URLError.Code, SiteFailure)] = [
        (.cannotFindHost, .hostNotFound), (.dnsLookupFailed, .hostNotFound), (.timedOut, .timedOut),
        (.cannotConnectToHost, .cannotConnect), (.secureConnectionFailed, .insecureConnection),
        (.serverCertificateUntrusted, .insecureConnection), (.notConnectedToInternet, .offline),
        (.networkConnectionLost, .network(-1005)),
    ]
    for (code, cause) in cases { #expect(SiteFailure(error: URLError(code)) == cause, "\(code)") }
    // Cancelling is the caller's doing, never the site's.
    #expect(SiteFailure(error: URLError(.cancelled)) == nil)
}

@Test func sortsResponsesIntoCausesAndLeavesOrdinaryPagesAlone() {
    // Cloudflare documents `cf-mitigated: challenge` as the marker; IOS-POC-41 measured it with 403.
    #expect(SiteFailure(status: 403, headers: ["cf-mitigated": "challenge"], body: "") == .challenge)
    #expect(SiteFailure(status: 503, headers: [:], body: "") == .httpStatus(503))
    #expect(SiteFailure(status: 200, headers: [:], body: "<html><TITLE>Redirecting...</TITLE>") == .verificationPage)
    #expect(SiteFailure(status: 200, headers: [:], body: "<title>Security Check</title>") == .verificationPage)
    // An ordinary page is not a failure, even one that talks about checks in its body.
    #expect(SiteFailure(status: 200, headers: [:], body: "<title>国产</title><p>Security Check</p>") == nil)
    #expect(SiteFailure(status: 302, headers: [:], body: "") == nil)
}

@Test func blamesTheSiteOnlyWhenItIsTheSites() {
    let gone = SiteUnreachable(.hostNotFound, host: "a.example").localizedDescription
    #expect(gone.contains("a.example") && gone.contains("不是 App 的錯誤"))
    // A 404 may be an address the rule has outdated: no claim either way.
    #expect(!SiteUnreachable(.httpStatus(404), host: "a.example").localizedDescription.contains("不是 App 的錯誤"))
    #expect(SiteUnreachable(.offline, host: "a.example").localizedDescription.contains("裝置"))
}

/// 傳媒二区 and 色花堂: the categories come from the rule, every page is Cloudflare's challenge.
@Test func aChallengedCategorySaysSoAndKeepsTheCategories() async throws {
    FailingSite.serve(["https://f1.invalid/t/1/1.html":
        .page(403, ["cf-mitigated": "challenge"], "<title>Just a moment...</title>")])
    let site = try client(rule("f1.invalid"))
    let home = try await site.home()
    #expect(home.classes.count == 2 && home.list.isEmpty)
    #expect(home.failure == SiteUnreachable(.challenge, host: "f1.invalid"))
    await #expect(throws: SiteUnreachable(.challenge, host: "f1.invalid")) {
        try await site.category(id: "1")
    }
}

/// The 34 entries whose domain no longer exists.
@Test func aVanishedDomainSaysSo() async throws {
    FailingSite.serve(["https://f2.invalid/t/1/1.html": .error(.cannotFindHost)])
    let home = try await client(rule("f2.invalid")).home()
    #expect(home.failure == SiteUnreachable(.hostNotFound, host: "f2.invalid"))
}

/// A site that answers normally with nothing must still read 「沒有內容」, not a network problem.
@Test func anEmptyButHealthyCategoryIsNotExplained() async throws {
    FailingSite.serve(["https://f3.invalid/t/1/1.html": .page(200, [:], "<html><title>国产</title><body></body></html>")])
    let site = try client(rule("f3.invalid"))
    let home = try await site.home()
    #expect(home.failure == nil && home.list.isEmpty)
    #expect(try await site.category(id: "1").list.isEmpty)
}

/// 41 sites keep their rules in a file `init` downloads; when it cannot, everything after is empty
/// for that reason, so the reason outlives the `init` call.
@Test func aRuleFileThatCannotBeFetchedExplainsTheEmptyHome() async throws {
    FailingSite.serve(["https://f4.invalid/json/a.json": .error(.timedOut)])
    await #expect(throws: SiteUnreachable(.timedOut, host: "f4.invalid")) {
        try await client("https://f4.invalid/json/a.json").home()
    }
}

// MARK: - IOS-POC-41C: 檢查來源

/// Where the check stops is where the app's own path stops: the listing behind Cloudflare.
@Test func aCheckStopsAtAChallengedListing() async throws {
    FailingSite.serve(["https://f5.invalid/t/1/1.html": .page(403, ["cf-mitigated": "challenge"], "")])
    let outcome = await SourceCheck.check(try client(rule("f5.invalid")))
    #expect(outcome.verdict == .unreachable(SiteUnreachable(.challenge, host: "f5.invalid")))
}

/// Titles that open to a detail with nothing to play: 看AV, 歐視 and AG動漫 in IOS-POC-39.
@Test func aCheckWithTitlesButNoEpisodesSaysSo() async throws {
    FailingSite.serve(["https://f6.invalid/t/1/1.html":
        .page(200, [:], #"<ul><li><a href="https://f6.invalid/v/1.html" title="片一">片一</a></li></ul>"#)])
    let extend = #"{"分类url":"https://f6.invalid/t/{cateId}/{catePg}.html","分类":"国产$1","数组":"<li&&</li>","标题":"title=\"&&\"","链接":"href=\"&&\""}"#
    let outcome = await SourceCheck.check(try client(extend))
    #expect(outcome.verdict == .noEpisodes)
    #expect(outcome.trail.contains("cat=1") || outcome.trail.contains("home=1"))
}

private func result(_ name: String, _ verdict: SourceCheck.Verdict, index: Int = 0) throws -> SourceCheck.Result {
    let site = try JSONDecoder().decode(Site.self, from: Data(#"{"key":"\#(name)","name":"\#(name)","type":1,"api":"https://x"}"#.utf8))
    return SourceCheck.Result(index: index, site: site, verdict: verdict, trail: "", detailMilliseconds: 0)
}

@Test func aCheckRecordsTheStagesItGotThrough() throws {
    #expect(try result("a", .playable).healthEvents.map(\.1) == [true, true, true])
    #expect(try result("a", .unreachable(SiteUnreachable(.hostNotFound, host: "x"))).healthEvents.map(\.1) == [false])
    #expect(try result("a", .noEpisodes).healthEvents.map(\.1) == [true, false])
    #expect(try result("a", .notMedia).healthEvents.map(\.1) == [true, true, false])
    // Neither says anything about the site's health.
    #expect(try result("a", .noTitles).healthEvents.isEmpty)
    #expect(try result("a", .timedOut).healthEvents.isEmpty)
}

@Test func theReportGroupsSitesAndSaysWhenAndWhere() throws {
    let results = [try result("活站", .playable, index: 1),
                   try result("死站", .unreachable(SiteUnreachable(.hostNotFound, host: "gone.example")), index: 0)]
    let text = SourceCheck.report(results, of: 3, source: "https://x/c.json", at: Date(timeIntervalSince1970: 0))
    #expect(text.contains("設定：https://x/c.json"))
    #expect(text.contains("已檢查 2／3 站：可以播放 1、網站連不上 1"))
    #expect(text.contains("取決於檢查當下的網路"))
    #expect(text.contains("【網站連不上】\n死站：找不到網域 gone.example，網域可能已經失效。"))
    #expect(text.contains("【可以播放】\n活站"))
}
