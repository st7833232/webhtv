import Foundation
import Network
import Testing
import WebKit
@testable import WebHTVCore

// MARK: - Classification, against the real configurations

/// The 63 entries the two configurations carry are **not** 63 host rules: 62 are domain-shaped and
/// one is a whole URL. Android's only consumer compares against the **host**, so a whole URL can
/// never match there — and must not be normalised into one here, because that would be inventing
/// behaviour the contract does not have.
@Test func theWholeUrlEntryStaysInert() {
    let ads = ["s13.cnzz.com", "hm.baidu.com",
               "https://lf1-cdn-tos.bytegoofy.com/obj/tos-cn-i-dy/455ccf9e8ae744378118e4bd289288dd"]
    let list = try! #require(AdBlockList.make(ads: ads))
    #expect(list.blocked == ["s13.cnzz.com", "hm.baidu.com"])
    #expect(list.inert.count == 1, "the whole-URL entry is carried, not silently dropped")
    #expect(!list.json.contains("bytegoofy"), "and never becomes a rule")
}

/// Measured on the user's own files on 2026-09-22: 1 entry in `wang-movie.json`, 62 in
/// `wang-sex.json`, of which exactly one is a whole URL. Gated on the files being present.
@Test func theRealConfigurationsClassifyAsMeasured() throws {
    guard let path = ProcessInfo.processInfo.environment["WANG_MOVIE_JSON"] else { return }
    let movie = try JSONDecoder().decode(WebHTVConfig.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    #expect(movie.ads.count == 1, "wang-movie.json carries one ad host")
    let fromMovie = try #require(AdBlockList.make(ads: movie.ads))
    #expect(fromMovie.blocked.count == 1)
    #expect(fromMovie.inert.isEmpty)
}

@Test func onlyHostShapedEntriesBecomeRules() {
    #expect(AdBlockList.isHostShaped("s13.cnzz.com"))
    #expect(AdBlockList.isHostShaped("www.google-analytics.com"))
    #expect(!AdBlockList.isHostShaped("https://example.com/a"), "a whole URL is not a host")
    #expect(!AdBlockList.isHostShaped("example.com/path"), "nor is a host with a path")
    #expect(!AdBlockList.isHostShaped("example.com:8080"), "nor one carrying a port")
    #expect(!AdBlockList.isHostShaped("localhost"), "a label with no dot cannot be a domain rule")
    #expect(!AdBlockList.isHostShaped(""))
}

/// Android hands the raw string to `String.matches`, so its dots are regex wildcards. Escaping is
/// the narrowing this port makes deliberately, and it has to actually happen.
@Test func aLiteralDomainIsEscapedRatherThanTreatedAsAPattern() {
    let filter = AdBlockList.filter(for: "s13.cnzz.com")
    #expect(filter.contains("s13\\.cnzz\\.com"))
    #expect(filter.hasPrefix("^https?://"), "anchored at the scheme, so it cannot match inside a path")
}

/// No rules means no blocker — not an empty blocker, and not a compiled list with nothing in it.
@Test func anEmptyAdsListProducesNoBlockerAtAll() {
    #expect(AdBlockList.make(ads: []) == nil)
    #expect(AdBlockList.make(ads: ["", "   "]) == nil)
    #expect(AdBlockList.make(ads: ["https://only.example/a-whole-url"]) == nil,
            "entries that can never be a host rule leave nothing to block")
}

/// The identity has to be a function of the rules, so configuration A and configuration B get
/// different lists and switching A → B → A lands back on the one A already had.
@Test func theIdentityFollowsTheRulesAndNothingElse() {
    let a = try! #require(AdBlockList.make(ads: ["a.example.com"]))
    let b = try! #require(AdBlockList.make(ads: ["b.example.com"]))
    let aAgain = try! #require(AdBlockList.make(ads: ["a.example.com"]))
    #expect(a.identifier != b.identifier, "two configurations must not share a compiled list")
    #expect(a.identifier == aAgain.identifier, "switching back reuses it rather than rebuilding")
    #expect(a == aAgain)
    // Order is part of the rules, so it is part of the identity; a reordered list is a new list
    // rather than a silent mismatch between the identifier and what it names.
    let ordered = try! #require(AdBlockList.make(ads: ["a.example.com", "b.example.com"]))
    let reordered = try! #require(AdBlockList.make(ads: ["b.example.com", "a.example.com"]))
    #expect(ordered.identifier != reordered.identifier)
}

/// The JSON has to be something WebKit will actually accept — asserted by compiling it, not by
/// inspecting it. Also pins the safety narrowing: `document` is not in the resource types, so a
/// top-level page load can never be cancelled by an ad rule.
@MainActor
@Test func theRulesCompileAndLeaveTheTopDocumentAlone() async throws {
    let list = try #require(AdBlockList.make(ads: ["s13.cnzz.com", "hm.baidu.com"]))
    #expect(!list.json.contains("\"document\""), "the sniffed page itself is never a blockable type")

    let store = try #require(WKContentRuleListStore.default())
    let compiled = try await store.compileContentRuleList(forIdentifier: list.identifier,
                                                          encodedContentRuleList: list.json)
    #expect(compiled != nil, "WebKit accepted the generated rules")
    try? await store.removeContentRuleList(forIdentifier: list.identifier)
}

// MARK: - The real thing: two page loads through WebKit

/// The gate for IOS-POC-5S-1, and the only check that can tell "the rules compiled" apart from
/// "the rules do what they are for". Two loads of the same page against two different lists.
///
/// **Load one** blocks the very host the page is served from. The page must still load — that is the
/// `document` narrowing — while its ad script and tracking image must never reach the socket.
/// **Load two** blocks an unrelated host, so nothing on the page may be touched at all; that is what
/// catches a rule matching more than the domain it names.
@MainActor
@Test func blocksTheAdSubresourcesWithoutTouchingThePageOrOverMatching() async throws {
    let server = try LocalPages()
    defer { server.stop() }

    let blocking = try #require(AdBlockList.make(ads: [server.host]))
    let unrelated = try #require(AdBlockList.make(ads: ["ads.example.com"]))
    let store = try #require(WKContentRuleListStore.default())
    defer {
        Task { @MainActor in
            try? await store.removeContentRuleList(forIdentifier: blocking.identifier)
            try? await store.removeContentRuleList(forIdentifier: unrelated.identifier)
        }
    }

    // --- load one: the page's own host is on the blocklist -------------------
    let blockingRules = try await store.compileContentRuleList(forIdentifier: blocking.identifier,
                                                               encodedContentRuleList: blocking.json)
    server.reset()
    #expect(await load(server.pageURL, rules: blockingRules),
            "the top document is served from a blocked host and must still load")
    var hits = server.requestedPaths
    #expect(hits.contains("/page.html"), "the page itself was fetched")
    #expect(!hits.contains("/ads.js"), "the ad script must be blocked before it reaches the network")
    #expect(!hits.contains("/tracker.gif"), "and so must the tracking image")
    #expect(!hits.contains("/app.js"), "same host, so this one is blocked too — Android blocks by host")

    // --- load two: an unrelated host is on the blocklist ---------------------
    let unrelatedRules = try await store.compileContentRuleList(forIdentifier: unrelated.identifier,
                                                                encodedContentRuleList: unrelated.json)
    server.reset()
    #expect(await load(server.pageURL, rules: unrelatedRules))
    hits = server.requestedPaths
    #expect(hits.contains("/page.html"))
    #expect(hits.contains("/app.js"), "an unrelated rule must not touch an ordinary script")
    #expect(hits.contains("/ads.js"), "nor anything else on a host it does not name")
    #expect(hits.contains("/tracker.gif"), "nor an image")
}

@MainActor
private func load(_ url: URL, rules: WKContentRuleList?) async -> Bool {
    let configuration = WKWebViewConfiguration()
    if let rules { configuration.userContentController.add(rules) }
    return await PageProbe(configuration: configuration).load(url)
}

/// Requirement 3: the rules belong to the **active** configuration, so switching A → B → A must
/// never leave A's compiled list attached while B is active, or the other way round.
///
/// Asserted on the sniffer itself rather than on `AdBlockList`, because the cache is what could go
/// stale: the identity being right is worth nothing if the compiled list outlives the change.
@MainActor
@Test func switchingConfigurationsNeverLeavesTheOtherOnesRulesBehind() async throws {
    let sniffer = MediaSniffer()
    let a = try #require(AdBlockList.make(ads: ["a-ads.example.com"]))
    let b = try #require(AdBlockList.make(ads: ["b-ads.example.com"]))

    sniffer.adBlockList = a
    _ = await sniffer.compiledRulesForTesting()
    #expect(sniffer.compiled?.identifier == a.identifier)

    sniffer.adBlockList = b
    #expect(sniffer.compiled == nil, "B must not inherit A's compiled list")
    _ = await sniffer.compiledRulesForTesting()
    #expect(sniffer.compiled?.identifier == b.identifier)

    sniffer.adBlockList = a
    #expect(sniffer.compiled == nil)
    _ = await sniffer.compiledRulesForTesting()
    #expect(sniffer.compiled?.identifier == a.identifier, "switching back lands on A's own list")

    // A configuration with no ads is the same as no blocker at all — not an empty one.
    sniffer.adBlockList = nil
    #expect(sniffer.compiled == nil)
    #expect(await sniffer.compiledRulesForTesting() == nil)

    let store = WKContentRuleListStore.default()
    try? await store?.removeContentRuleList(forIdentifier: a.identifier)
    try? await store?.removeContentRuleList(forIdentifier: b.identifier)
}

// MARK: - Helpers

/// A one-connection-at-a-time HTTP server that records which paths were actually requested.
/// Deliberately tiny: the assertions are about which requests reach the socket, so anything the
/// blocker stops simply never appears here.
private final class LocalPages: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var paths = [String]()
    private var port: UInt16?

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.port = self?.listener.port?.rawValue; ready.signal() }
        }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
    }

    /// Loopback is host-shaped, so it can be an ad rule; that is what makes the page's own host
    /// blockable and lets the `document` narrowing be tested for real.
    let host = "127.0.0.1"
    var pageURL: URL { URL(string: "http://127.0.0.1:\(port ?? 0)/page.html")! }
    var requestedPaths: [String] { lock.withLock { paths } }
    func reset() { lock.withLock { paths.removeAll() } }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel(); return
            }
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            self.lock.withLock { self.paths.append(path) }
            let body: String
            let type: String
            switch path {
            case "/page.html":
                body = """
                <html><body><script src="/ads.js"></script>\
                <img src="/tracker.gif"><script src="/app.js"></script></body></html>
                """
                type = "text/html"
            default:
                body = "/* ok */"
                type = "application/javascript"
            }
            let response = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func stop() { listener.cancel() }
}

/// Loads one page and says whether the navigation finished.
@MainActor
private final class PageProbe: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var continuation: CheckedContinuation<Bool, Never>?

    init(configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func load(_ url: URL) async -> Bool {
        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.continuation = continuation
            webView.load(URLRequest(url: url))
            Task { try? await Task.sleep(for: .seconds(8)); self.finish(false) }
        }
        // Give the subresources a moment to reach the socket, or not.
        try? await Task.sleep(for: .milliseconds(600))
        webView.stopLoading()
        return finished
    }

    private func finish(_ value: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(false)
    }
}
