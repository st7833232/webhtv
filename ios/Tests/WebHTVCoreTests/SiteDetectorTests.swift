import Foundation
import Testing
@testable import WebHTVCore

// W-277: the site detector (design W-275 §4.1–4.3) against offline MacCMS servers on `.invalid` hosts.

/// Answers `<scheme>://<host><path>` (query ignored, except that `ids=` picks the detail) from `routes`; records every
/// URL. Tests run in parallel, so each uses its own host and `serve` only adds routes.
private final class CMSServer: URLProtocol, @unchecked Sendable {
    enum Reply { case body(Int, String), fail(URLError.Code) }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Reply] = [:]
    nonisolated(unsafe) private static var seen: [URL] = []

    static func serve(_ served: [String: Reply]) { lock.withLock { routes.merge(served) { $1 } } }
    static func requests(host: String) -> [URL] { lock.withLock { seen }.filter { $0.host == host } }
    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CMSServer.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let detail = components.queryItems?.contains { $0.name == "ids" } == true
        let key = url.scheme! + "://" + url.host! + components.percentEncodedPath + (detail ? "#detail" : "")
        let reply = Self.lock.withLock { () -> Reply in
            Self.seen.append(url)
            return Self.routes[key] ?? .body(404, "")
        }
        switch reply {
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .body(let status, let body):
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                                                   headerFields: ["Content-Type": "text/html"])!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

private let jsonHome = #"{"code":1,"msg":"数据列表","class":[{"type_id":1,"type_name":"电影"},{"type_id":2,"type_name":"剧集"}],"list":[{"vod_id":7,"vod_name":"測試片"}]}"#
private let jsonDetail = #"{"code":1,"list":[{"vod_id":7,"vod_name":"測試片","vod_play_from":"m3u8$$$web","vod_play_url":"第1集$https://m.invalid/1.m3u8#第2集$https://m.invalid/2.m3u8$$$第1集$https://m.invalid/p.html"}]}"#
private let xmlHome = #"<?xml version="1.0"?><rss><list page="1"><video><id>9</id><name><![CDATA[XML片]]></name><dl><dd flag="w"><![CDATA[第1集$https://m.invalid/v.html]]></dd></dl></video></list><class><ty id="1">电影</ty></class></rss>"#

private func detector(budget: Duration = .seconds(45)) -> SiteDetector { SiteDetector(session: CMSServer.session, budget: budget) }

@Test func candidatesFollowTheDesignOrder() throws {
    let bare = try #require(SiteDetector.candidates(for: " example.com "))
    #expect(bare.map(\.url.absoluteString) == [
        "https://example.com/api.php/provide/vod/", "https://example.com/api.php/provide/vod/at/xml/",
        "https://example.com/inc/apijson_vod.php", "https://example.com/inc/api.php",
        "http://example.com/api.php/provide/vod/", "http://example.com/api.php/provide/vod/at/xml/",
        "http://example.com/inc/apijson_vod.php", "http://example.com/inc/api.php",
    ])
    #expect(bare.map(\.type) == [1, 0, 1, 0, 1, 0, 1, 0])

    // A typed API goes first as given and is not tried twice.
    let given = try #require(SiteDetector.candidates(for: "http://x.com:8080/api.php/provide/vod/at/xml/#a"))
    #expect(given.map(\.format) == [.given, .v10JSON, .v8JSON, .v8XML])
    #expect(given.first?.type == 0 && given.first?.url.absoluteString == "http://x.com:8080/api.php/provide/vod/at/xml/")
    let v8 = try #require(SiteDetector.candidates(for: "https://x.com/inc/api.php")?.first)
    #expect(v8.format == .given && v8.type == 0)
    #expect(SiteDetector.candidates(for: "https://x.com/api.php/provide/vod/?ac=list")?.first?.type == 1)

    #expect(SiteDetector.candidates(for: "ftp://x.com") == nil)
    #expect(SiteDetector.candidates(for: "javascript://alert(1)") == nil)
    #expect(SiteDetector.candidates(for: "") == nil)
}

@Test func repliesThatAreNotTheAPISayWhy() {
    func judge(_ body: String, _ status: Int = 200, xml: Bool = false) -> SiteDetector.Failure? {
        SiteDetector.judge(Data(body.utf8), status: status, xml: xml)
    }
    #expect(judge(jsonHome) == nil)
    #expect(judge(#"{"list":[]}"#) == nil)
    #expect(judge(xmlHome, xml: true) == nil)
    #expect(judge(" closed\n") == .closed)
    #expect(judge("域名未授权，请联系QQ") == .unauthorized)
    #expect(judge("<html><title>Just a moment...</title><script src=/cdn-cgi/challenge-platform/x></script>", 403) == .challenge)
    #expect(judge("<html>请输入验证码</html>") == .challenge)
    #expect(judge("") == .empty)
    #expect(judge("", 502) == .http(502))
    #expect(judge("<html>Not Found</html>", 404) == .http(404))
    #expect(judge(#"{"code":0,"msg":"err","list":[]}"#) == .notCMS)
    #expect(judge("<html><body>影視首頁</body></html>") == .notCMS)
    #expect(judge(jsonHome, xml: true) == .notCMS)
}

@Test func aV10JSONSiteIsFoundFirstAndNothingElseIsAsked() async throws {
    let api = "https://v10.invalid/api.php/provide/vod/"
    CMSServer.serve([api: .body(200, jsonHome), api + "#detail": .body(200, jsonDetail)])
    guard case .found(let found) = await detector().detect("v10.invalid") else { Issue.record("not found"); return }
    #expect(found.candidate.format == .v10JSON && found.candidate.type == 1)
    #expect(found.categoryCount == 2 && found.firstTitle.id == "7" && found.lineCount == 2 && found.episodeCount == 2)
    #expect(found.isDirect && !found.isInsecure)
    let asked = CMSServer.requests(host: "v10.invalid")
    #expect(asked.count == 4 && asked.allSatisfy { $0.absoluteString.hasPrefix(api) })
    // Never a search (E8).
    #expect(!asked.contains { $0.query?.contains("wd=") == true })
}

@Test func anXMLOnlySiteOverHTTPIsAddedAsTypeZeroAndMarkedInsecure() async throws {
    CMSServer.serve(["http://xml.invalid/api.php/provide/vod/at/xml/": .body(200, xmlHome),
                     "http://xml.invalid/api.php/provide/vod/at/xml/#detail": .body(200, xmlHome)])
    let heard = Heard()
    guard case .found(let found) = await detector().detect("http://xml.invalid", progress: { heard.add($0) })
    else { Issue.record("not found"); return }
    #expect(found.candidate.format == .v10XML && found.candidate.type == 0)
    #expect(found.isInsecure && !found.isDirect && found.firstTitle.name == "XML片")
    #expect(heard.all.map(\.failure) == [.http(404), nil])
}

@Test func aV8SiteIsFoundAfterTheV10PathsFail() async throws {
    CMSServer.serve(["https://v8.invalid/api.php/provide/vod/": .body(200, "closed"),
                     "https://v8.invalid/inc/apijson_vod.php": .body(200, jsonHome),
                     "https://v8.invalid/inc/apijson_vod.php#detail": .body(200, jsonDetail)])
    guard case .found(let found) = await detector().detect("https://v8.invalid/") else { Issue.record("not found"); return }
    #expect(found.candidate.format == .v8JSON)
}

@Test func everyFailureIsReportedPerCandidate() async throws {
    CMSServer.serve(["https://shut.invalid/api.php/provide/vod/": .body(200, "closed"),
                     "https://shut.invalid/api.php/provide/vod/at/xml/": .body(200, "域名未授权"),
                     "https://shut.invalid/inc/apijson_vod.php": .body(403, "<title>Just a moment...</title>")])
    guard case .failed(let attempts) = await detector().detect("https://shut.invalid") else { Issue.record("found"); return }
    #expect(attempts.map(\.failure) == [.closed, .unauthorized, .challenge, .http(404)])
}

@Test func aTitleWithoutEpisodesFailsTheCandidate() async throws {
    let api = "https://bare.invalid/api.php/provide/vod/"
    CMSServer.serve([api: .body(200, jsonHome), api + "#detail": .body(200, #"{"code":1,"list":[{"vod_id":7,"vod_name":"x"}]}"#)])
    guard case .failed(let attempts) = await detector().detect("https://bare.invalid") else { Issue.record("found"); return }
    #expect(attempts.first?.failure == .noEpisodes)
}

@Test func aTimedOutOriginIsNotAskedAgainAndTheBudgetStopsTheRound() async throws {
    CMSServer.serve(["https://slow.invalid/api.php/provide/vod/": .fail(.timedOut)])
    guard case .failed(let attempts) = await detector().detect("slow.invalid") else { Issue.record("found"); return }
    // https timed out once and its other paths were skipped; the http round still ran.
    #expect(attempts.map(\.failure) == [.timeout, .http(404), .http(404), .http(404), .http(404)])

    guard case .failed(let none) = await detector(budget: .zero).detect("slow.invalid") else { Issue.record("found"); return }
    #expect(none.map(\.failure) == [.timeout])
}

@Test func anAddressThatIsNotHTTPIsRefused() async {
    guard case .invalidInput = await detector().detect("file:///etc/hosts") else { Issue.record("accepted"); return }
}

private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [SiteDetector.Attempt] = []
    func add(_ attempt: SiteDetector.Attempt) { lock.withLock { list.append(attempt) } }
    var all: [SiteDetector.Attempt] { lock.withLock { list } }
}
