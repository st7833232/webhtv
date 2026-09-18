import AVFoundation
import Foundation
import Network
import Testing
@testable import WebHTVCore

/// `SourceClient` is the routing layer that finally lets a ported spider reach the app UI, so what
/// matters here is the routing and the decoding — the spider ports themselves have golden tests.

private func site(_ json: String) throws -> Site {
    try JSONDecoder().decode(Site.self, from: Data(json.utf8))
}

@Test func routesNativeCMSSitesToTheCMSClientAndSpidersToTheRegistry() async throws {
    let resolver = CSPSourceResolver()

    let cms = try site(#"{"key":"t1","name":"CMS","type":1,"api":"https://example.com/api.php/provide/vod"}"#)
    guard case .cms = try await SourceClient.make(site: cms, resolver: resolver) else {
        Issue.record("a type-1 site must stay on CMSClient"); return
    }

    // A registered class routes to the spider; the app no longer decides on `type == 3` alone.
    let ported = try site(#"{"key":"sp","name":"Spider","type":3,"api":"csp_AppGet","ext":{"url":"https://example.invalid"}}"#)
    guard case .spider = try await SourceClient.make(site: ported, resolver: resolver) else {
        Issue.record("a registered csp_* class must route to the spider runtime"); return
    }

    // An unregistered class must not silently become a CMS request against a class name.
    let unported = try site(#"{"key":"no","name":"Nope","type":3,"api":"csp_NotPortedAtAll"}"#)
    await #expect(throws: (any Error).self) {
        _ = try await SourceClient.make(site: unported, resolver: resolver)
    }
}

/// One session per site, reused. A rule-engine spider downloads its rule file inside `init`, and the
/// app builds a client on every listing, page, search and episode — without reuse a single browse
/// would re-fetch the rules a dozen times.
@Test func reusesOneSpiderSessionPerSiteAndDropsThemOnReset() async throws {
    let store = SpiderSessionStore()
    let resolver = CSPSourceResolver()
    let spider = try site(#"{"key":"reuse","name":"Spider","type":3,"api":"csp_AppGet","ext":{"url":"https://example.invalid"}}"#)

    let first = try await store.session(for: spider, resolver: resolver)
    let second = try await store.session(for: spider, resolver: resolver)
    #expect(first === second, "a second call must reuse the cached session, not re-init the spider")

    await store.reset()
    let third = try await store.session(for: spider, resolver: resolver)
    #expect(first !== third, "reset must drop cached sessions so a new config cannot reuse a stale one")
}

/// The spider ports were written to emit the CatVod shape the app already parsed, so the whole
/// spider branch is a decode. These are the exact shapes the three ported spiders return.
@Test func decodesTheCatVodShapesTheSpidersActuallyReturn() throws {
    let home = try JSONDecoder().decode(CMSResponse.self, from: Data(#"""
    {"class":[{"type_id":"1","type_name":"电影"},{"type_id":"2","type_name":"电视剧"}],"list":[]}
    """#.utf8))
    #expect(home.classes.map(\.name) == ["电影", "电视剧"])
    // XBPQ always returns an empty home list, which is why SourceClient.home falls back to listing
    // the first category instead of rendering an empty grid.
    #expect(home.list.isEmpty)
    #expect(home.firstListableCategory?.id == "1")

    let detail = try JSONDecoder().decode(CMSResponse.self, from: Data(#"""
    {"list":[{"vod_id":"9","vod_name":"抓特务","vod_pic":"http://x/p.jpg",
      "vod_play_from":"线路①$$$线路②","vod_play_url":"01$a.m3u8#02$b.m3u8$$$01$c.m3u8"}]}
    """#.utf8))
    let vod = try #require(detail.list.first)
    #expect(vod.flags.map(\.name) == ["线路①", "线路②"])
    #expect(vod.flags[0].episodes.map(\.name) == ["01", "02"])
    #expect(vod.flags[0].episodes[1].url == "b.m3u8")
    #expect(vod.flags[1].episodes.count == 1)
}

/// `parse` decides whether the app gets a URL or an honest failure, so both encodings a CatVod
/// source may use are accepted, and `parse:1` must never reach AVPlayer as if it were media.
@Test func readsThePlayEnvelopeIncludingTheStringEncodedParseFlag() throws {
    func play(_ json: String) throws -> SpiderPlayResponse {
        try JSONDecoder().decode(SpiderPlayResponse.self, from: Data(json.utf8))
    }
    #expect(try play(#"{"parse":0,"url":"https://a/x.m3u8"}"#).parse == 0)
    // Some CatVod sources send parse as a string; failing that decode would break playback outright.
    #expect(try play(#"{"parse":"0","url":"https://a/x.m3u8"}"#).parse == 0)
    #expect(try play(#"{"parse":1,"url":"https://a/page.html"}"#).parse == 1)
    // A missing url is not a decode failure — it is an unplayable episode, reported as one.
    #expect(try play(#"{"parse":0}"#).url.isEmpty)
}

// MARK: - playback headers (IOS-POC-5P)

/// A CDN that answers 403 to a bare request and 206 to one carrying a Referer — which is exactly
/// what bilibili's `upos-*` mirrors do, measured on 2026-09-17.
private final class RefererGate: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var seenHeaders: [String: String] = [:]

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "gate.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let headers = request.allHTTPHeaderFields ?? [:]
        Self.seenHeaders = headers
        let allowed = headers["Referer"] != nil
        let response = HTTPURLResponse(
            url: request.url!, statusCode: allowed ? 206 : 403, httpVersion: nil,
            headerFields: allowed ? ["Content-Type": "video/mp4"] : ["Content-Type": "text/plain"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: allowed ? Data(repeating: 0, count: 512) : Data("forbidden".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func gatedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RefererGate.self]
    return URLSession(configuration: configuration)
}

@Test func theProbeSendsTheHeadersTheSourceAskedFor() async throws {
    let url = URL(string: "https://gate.invalid/upgcxcode/clip.mp4")!

    // Without them the CDN's 403 is indistinguishable from a dead link — which is how four working
    // bilibili sources were being reported as DEAD-MEDIA.
    #expect(await MediaProbe.classify(url, session: gatedSession()) == .unknown)

    let kind = await MediaProbe.classify(url, headers: ["Referer": "https://www.bilibili.com",
                                                        "User-Agent": "WebHTV"], session: gatedSession())
    #expect(kind == .media)
    #expect(RefererGate.seenHeaders["Referer"] == "https://www.bilibili.com")
    #expect(RefererGate.seenHeaders["User-Agent"] == "WebHTV")
    // The range request the probe already made must survive the addition.
    #expect(RefererGate.seenHeaders["Range"] == "bytes=0-1023")
}

/// The contract end to end: what a spider writes into `header` is what the player is handed.
@Test func aSpidersHeadersReachThePlaybackTarget() async throws {
    let runtime = try JavaScriptSpiderRuntime(
        name: "t", script: """
        module.exports = {
          init: function () { return ''; },
          playerContent: function (flag, id) {
            return host.result.play('https://cdn.invalid/' + id + '.m3u8', false,
                                    { Referer: 'https://www.bilibili.com', 'User-Agent': 'WebHTV' });
          }
        };
        """,
        prelude: SpiderRegistry.bundled().prelude,
        storage: SpiderStorage(siteKey: "t", defaults: .standard))
    let site = try JSONDecoder().decode(Site.self, from: Data(
        #"{"key":"t","name":"t","type":3,"api":"csp_Bili"}"#.utf8))
    let client = SourceClient.spider(SpiderSession(site: site, runtime: runtime))

    let target = try #require(try await client.playbackURL(for: Episode(name: "01", url: "ep1"), flag: "B站"))
    #expect(target.url.absoluteString == "https://cdn.invalid/ep1.m3u8")
    #expect(target.headers["Referer"] == "https://www.bilibili.com")
    #expect(target.headers["User-Agent"] == "WebHTV")
}

/// A CMS source has no header protocol, and must not grow one by accident.
@Test func aCMSSourceResolvesWithNoHeaders() throws {
    let target = PlaybackTarget(url: URL(string: "https://example.invalid/a.m3u8")!)
    #expect(target.headers.isEmpty)
}

/// `header` is whatever the spider wrote. A spider that writes something that is not a string map
/// must cost its own headers, never the play result.
@Test func anUnusableHeaderFieldIsNoHeadersRatherThanNoPlayback() throws {
    func decode(_ json: String) throws -> SpiderPlayResponse {
        try JSONDecoder().decode(SpiderPlayResponse.self, from: Data(json.utf8))
    }
    #expect(try decode(#"{"parse":0,"url":"https://a/x.m3u8","header":{"Referer":"https://b"}}"#)
        .header?["Referer"] == "https://b")
    #expect(try decode(#"{"parse":0,"url":"https://a/x.m3u8","header":false}"#).header == nil)
    #expect(try decode(#"{"parse":0,"url":"https://a/x.m3u8","header":{"n":1}}"#).header == nil)
    #expect(try decode(#"{"parse":0,"url":"https://a/x.m3u8"}"#).header == nil)
    #expect(try decode(#"{"parse":0,"url":"https://a/x.m3u8","header":false}"#).url.values.map(\.v)
        == ["https://a/x.m3u8"])
}

/// Proves the part of IOS-POC-5P that no stub can: that `AVURLAsset` really sends the headers it is
/// given, through **AVFoundation's own networking**, which does not go near `URLSession` and so
/// cannot be intercepted by a `URLProtocol`. The key it takes them under,
/// `AVURLAssetHTTPHeaderFieldsKey`, is undocumented; this test is what turns "everyone uses it" into
/// something this repository has actually observed.
///
/// A real socket, a real HTTP request, and an assertion on the bytes that arrived.
@Test func avURLAssetSendsTheHeadersItWasGiven() async throws {
    let server = try OneShotHTTPServer()
    defer { server.stop() }
    let asset = AVURLAsset(url: server.url, options: ["AVURLAssetHTTPHeaderFieldsKey": [
        "Referer": "https://www.bilibili.com",
        "User-Agent": "WebHTV/IOS-POC-5P"
    ]])
    // Loading any property makes AVFoundation open the URL; the load itself is expected to fail,
    // because the reply is deliberately not media. The request is the whole point.
    _ = try? await asset.load(.isPlayable)

    let request = try #require(await server.firstRequest(timeout: .seconds(10)),
                               "AVURLAsset never opened the URL")
    #expect(request.contains("Referer: https://www.bilibili.com"),
            "the Referer a spider attaches must reach the CDN:\n\(request)")
    #expect(request.contains("User-Agent: WebHTV/IOS-POC-5P"),
            "and it must be able to override AVFoundation's own User-Agent:\n\(request)")
}

/// The smallest thing that can answer one HTTP request and remember what it was asked.
private final class OneShotHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var request: String?

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                if let data { self?.record(String(decoding: data, as: UTF8.self)) }
                let body = "not media"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
    }

    private func record(_ text: String) { lock.withLock { if request == nil { request = text } } }

    var url: URL {
        // The port is assigned asynchronously; it is ready before the first load in practice, and a
        // nil port would fail the test loudly rather than silently pass.
        for _ in 0..<200 {
            if let port = listener.port?.rawValue, port != 0,
               let url = URL(string: "http://127.0.0.1:\(port)/clip.mp4") { return url }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return URL(string: "http://127.0.0.1:0/clip.mp4")!
    }

    func firstRequest(timeout: Duration) async -> String? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let value = lock.withLock({ request }) { return value }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return lock.withLock { request }
    }

    func stop() { listener.cancel() }
}

/// The whole point of the stage: the configured spider sites must actually appear in the list the
/// app builds. Gated on the real config, like every other live-data check in this suite.
@Test func listsThePortedSpiderSitesAlongsideTheNativeCMSSites() throws {
    guard let path = ProcessInfo.processInfo.environment["WANG_MOVIE_JSON"] else { return }
    let config = try JSONDecoder().decode(WebHTVConfig.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let resolver = CSPSourceResolver()

    let native = config.supportedSites
    let drivable = config.drivableSites(resolvedBy: resolver)
    let spiders = config.spiderSites(resolvedBy: resolver)

    // drpy needs an origin to load its engine from, so an imported file lists none of them and a
    // remote configuration lists all four. `./json/4k.js` is a fifth configured drpy source whose
    // file is a 404 in the repository — a missing resource, counted here because listing is about
    // shape, and refused at session build like any other unreachable engine.
    let remote = ConfigSource.remote(URL(string: "https://example.invalid/raw/main/wang-movie.json")!)
    let withOrigin = config.drivableSites(resolvedBy: CSPSourceResolver(source: remote))
    #expect(config.drpySpiderSites.count == 5)
    #expect(withOrigin.count == drivable.count + 5,
            "a remote configuration also lists the drpy sources")

    #expect(native.count == 30, "2 type-0 + 22 type-1 + 6 type-4")
    #expect(spiders.count == 32,
            "AppGet 5 + AppQi 6 + App99 4 + App3Q 2 + Bili 4 + JianPian 1 + XBPQ 7 + XYQHiker 3")
    #expect(drivable.count == native.count + spiders.count)
    // The app selects a site by `id`, so a duplicate would make the picker ambiguous. This
    // configuration does repeat site *keys* — `爱影` names two different AppQi sites — which is why
    // `Site.id` is the key together with the `ext`.
    #expect(Set(drivable.map(\.id)).count == drivable.count)
    #expect(Set(drivable.map(\.key)).count < drivable.count, "the config really does repeat a key")
    // Every listed spider must be one the registry can genuinely drive.
    #expect(spiders.allSatisfy { resolver.canResolve($0) })
    print("[sources] app list: \(drivable.count) = \(native.count) native + \(spiders.count) spider")
}

/// Sweeps **every source the app lists** — native CMS and ported spider alike — through
/// `SourceClient`, the same path the app itself uses, and reports where each one stops.
///
/// This is a diagnostic, not a gate: it asserts nothing about individual sites, because provider
/// reachability is volatile and a dead host is not a defect. It exists because IOS-POC-5D was first
/// reported as "15 spider sites work" on the strength of four hand-checked ones, and the only cheap
/// way to know the real number is to drive all of them.
///
///     SWEEP_CONFIG=/path/wang-movie.json SWEEP_BASE=https://…/wang-movie.json \
///       swift test --package-path ios --filter sweepsEveryDrivableSource
@Test func sweepsEveryDrivableSourceThroughTheAppPath() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["SWEEP_CONFIG"] else { return }
    let config = try JSONDecoder().decode(WebHTVConfig.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    // A rule-engine spider resolves a relative `ext` against the config's own directory, so the
    // sweep must carry the same remote source the app had or those sites fail for the wrong reason.
    let source: ConfigSource = env["SWEEP_BASE"].flatMap { URL(string: $0) }.map { .remote($0) } ?? .importedFile
    let resolver = CSPSourceResolver(source: source)

    enum Stop: String, CaseIterable {
        case played = "PLAYABLE", deadMedia = "DEAD-MEDIA", noPlay = "NO-PLAY"
        case noEpisode = "NO-EPISODE", empty = "EMPTY", failed = "ERROR"
    }
    var tally = [Stop: Int]()

    for site in config.drivableSites(resolvedBy: resolver) {
        let kind = site.isCSPSpider ? SpiderRegistry.className(from: site.api) : "type-\(site.type)"
        var line = "[sweep] \(kind.padded(12)) \(site.key.padded(22))"
        var stop = Stop.failed
        do {
            let client = try await SourceClient.make(site: site, resolver: resolver)
            let home = try await client.home()
            line += " classes=\(home.classes.count) home=\(home.list.count)"
            if let vod = home.list.first {
                let detail = try await client.detail(id: vod.id)
                let flags = detail?.flags ?? []
                line += " flags=\(flags.count) eps=\(flags.first?.episodes.count ?? 0)"
                if let episode = flags.first?.episodes.first, let flag = flags.first?.name {
                    let target = try await client.playbackURL(for: episode, flag: flag)
                    line += " play=\(target?.url.absoluteString.prefix(58) ?? "nil")"
                    // Resolving a URL is not the same as the media existing: AG動漫 resolves cleanly
                    // and then 404s. Fetch the first bytes so the tally means "playable", not "parsed".
                    if let target {
                        if !target.headers.isEmpty { line += " +hdr\(target.headers.count)" }
                        // Same classifier and the same headers the playback path uses, so the sweep
                        // and the app agree — including on a CDN that answers 403 to a bare request.
                        let kind = await MediaProbe.classify(target.url, headers: target.headers)
                        line += " [\(kind)]"
                        stop = kind == .media ? .played : .deadMedia
                    } else {
                        stop = .noPlay
                    }
                } else {
                    stop = .noEpisode
                }
            } else {
                stop = .empty
            }
        } catch {
            line += "  \(error)"
        }
        tally[stop, default: 0] += 1
        print("\(line)  -> \(stop.rawValue)")
    }

    let total = tally.values.reduce(0, +)
    print("[sweep] ---- \(total) sources: " + Stop.allCases.map { "\($0.rawValue)=\(tally[$0] ?? 0)" }.joined(separator: " "))
}

private extension String {
    /// Keeps the sweep output in columns so 45 lines stay readable.
    func padded(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}

/// Filters are CatVod's own `{key, name, value:[{n,v}]}` shape, keyed by `type_id`. `AppGet` is the
/// only ported class whose API publishes them (`filter_type_list`); MacCMS has no filter protocol,
/// so a type-1 response must decode to an empty set rather than failing.
@Test func decodesTheCatVodFilterRowsAndToleratesTheirAbsence() throws {
    let withFilters = try JSONDecoder().decode(CMSResponse.self, from: Data(#"""
    {"class":[{"type_id":"1","type_name":"电影"}],
     "filters":{"1":[
        {"key":"class","name":"類型","value":[{"n":"全部","v":""},{"n":"剧情","v":"剧情"}]},
        {"key":"by","name":"排序","value":[{"n":"全部","v":""},{"n":"最新","v":"time"}]}]}}
    """#.utf8))
    let rows = try #require(withFilters.filters["1"])
    #expect(rows.map(\.key) == ["class", "by"])
    #expect(rows[0].name == "類型")
    #expect(rows[0].options.map(\.name) == ["全部", "剧情"])
    // An empty value is how "no constraint" travels, and it must survive decoding.
    #expect(rows[0].options[0].value.isEmpty)
    #expect(rows[1].options[1].value == "time")

    // A MacCMS response has no `filters` key at all.
    let plain = try JSONDecoder().decode(CMSResponse.self, from: Data(#"{"class":[],"list":[]}"#.utf8))
    #expect(plain.filters.isEmpty)

    // A year row ships numbers rather than strings on some sources.
    let numeric = try JSONDecoder().decode(CMSResponse.self, from: Data(#"""
    {"filters":{"2":[{"key":"year","name":"年代","value":[{"n":2026,"v":2026}]}]}}
    """#.utf8))
    #expect(numeric.filters["2"]?.first?.options.first?.value == "2026")
}

/// The whole point of the filter rows: the chosen values must reach the spider's `extend`, keyed as
/// the row named itself. Gated on the real site because only a live API publishes filter rows.
@Test func sendsChosenFilterValuesBackToTheSpider() async throws {
    guard let raw = ProcessInfo.processInfo.environment["CSP_GOLDEN_SITE"] else { return }
    let site = try JSONDecoder().decode(Site.self, from: Data(raw.utf8))
    let client = try await SourceClient.make(site: site, resolver: CSPSourceResolver())
    let home = try await client.home()
    guard let category = home.classes.first(where: { !($0.id == "0") }),
          let rows = home.filters[category.id], let row = rows.first,
          let option = row.options.first(where: { !$0.value.isEmpty }) else {
        print("[filters] this site publishes none; nothing to assert")
        return
    }
    print("[filters] \(category.name): rows=\(rows.map(\.key)), applying \(row.key)=\(option.value)")
    let filtered = try await client.category(id: category.id, extend: [row.key: option.value])
    // The listing must still come back — a rejected filter would empty it.
    #expect(!filtered.list.isEmpty, "filtering \(row.key)=\(option.value) returned nothing")
}
