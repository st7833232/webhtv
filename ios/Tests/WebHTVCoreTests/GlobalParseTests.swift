import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-56: the configuration's global parse services, read the way Android's `ParseJob` reads a
// play result. Everything here is offline: the services are a URLProtocol on `.invalid` hosts and
// the web pages are `data:` pages.

/// A parse service. Answers each URL from `routes` (by prefix), after `delay`; records every request.
private final class ParseService: URLProtocol, @unchecked Sendable {
    struct Route: Sendable { var body: String; var delay: Duration = .zero }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Route] = [:]
    nonisolated(unsafe) private static var seen: [URLRequest] = []

    static func serve(_ served: [String: Route]) { lock.withLock { routes = served; seen = [] } }
    /// What the services were asked, leaving out the media check on the stream itself.
    static var requests: [URLRequest] { lock.withLock { seen }.filter { $0.url?.host != "media.invalid" } }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ParseService.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var reply: DispatchWorkItem?
    override func stopLoading() { reply?.cancel() }

    override func startLoading() {
        let url = request.url!.absoluteString
        let route: Route? = Self.lock.withLock {
            Self.seen.append(request)
            // The stream itself, for the media check every answer gets: a playlist head.
            if url.hasPrefix("https://media.invalid/") { return Route(body: "#EXTM3U\n#EXT-X-VERSION:3\n") }
            return Self.routes.first { url.hasPrefix($0.key) }?.value
        }
        let status = route == nil ? 404 : 200, body = Data((route?.body ?? "").utf8)
        let reply = DispatchWorkItem { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        self.reply = reply
        let delay = route?.delay ?? .zero
        DispatchQueue.global().asyncAfter(deadline: .now() + Double(delay.components.seconds)
                                          + Double(delay.components.attoseconds) / 1e18, execute: reply)
    }
}

private let longMedia = "https://media.invalid/0123456789/0123456789/0123456789/index.m3u8"

private func config(_ json: String) throws -> WebHTVConfig {
    try JSONDecoder().decode(WebHTVConfig.self, from: Data(json.utf8))
}

/// Two JSON services, two web services, one JAR-only type and one service on the device itself.
private let parses = #"""
"flags": ["qq", "腾讯"],
"parses": [
  {"name": "聚合", "type": 3, "url": "Demo"},
  {"name": "网页A", "type": 0, "url": "https://web-a.invalid/?url=", "ext": {"header": {"User-Agent": "UA-A"}}},
  {"name": "网页B", "type": 0, "url": "https://web-b.invalid/?url=", "ext": {"flag": ["qiyi"]}},
  {"name": "接口A", "type": "1", "url": "https://json-a.invalid/?url=", "ext": {"flag": ["qq"], "header": {"User-Agent": "okhttp/4.9.1"}}},
  {"name": "接口B", "type": 1, "url": "https://json-b.invalid/?url="},
  {"name": "接口A", "type": 1, "url": "https://duplicate.invalid/?url="},
  {"name": "本机", "type": 1, "url": "http://127.0.0.1:10079/parse/?url="},
  "not an entry"
]
"""#

@Test func decodesTheConfigurationsParsesIntoEverySite() throws {
    let decoded = try config(#"{"sites":[{"key":"a","name":"A","type":1,"api":"https://cms.invalid/api.php","playUrl":"json:https://json-b.invalid/?url="},{"key":"b","name":"B","type":3,"api":"csp_AppGet"}],"#
                             + parses + "}")
    let names = decoded.parsing.parses.map(\.name)
    #expect(names == ["聚合", "网页A", "网页B", "接口A", "接口B", "本机"], "distinct by name, first kept; a broken entry costs itself")
    let json = try #require(decoded.parsing.parses.first { $0.name == "接口A" })
    #expect(json.type == 1 && json.flags == ["qq"] && json.header == ["User-Agent": "okhttp/4.9.1"], "a string type and ext")
    #expect(decoded.parsing.flags == ["qq", "腾讯"])
    #expect(decoded.sites.allSatisfy { $0.parsing == decoded.parsing })
    #expect(decoded.sites[0].playUrl == "json:https://json-b.invalid/?url=" && decoded.sites[1].playUrl.isEmpty)
    // A configuration without them decodes exactly as before.
    let bare = try config(#"{"sites":[{"key":"a","name":"A","type":1,"api":"https://cms.invalid/api.php"}],"parses":"x","flags":3}"#)
    #expect(bare.parsing == ParseSettings() && bare.sites[0].parsing.parses.isEmpty)
}

@Test func plansTheWayParseJobDoes() throws {
    let settings = try config(#"{"sites":[],"# + parses + "}").parsing
    let header = ["Referer": "https://source.invalid/"]
    func plan(parse: Int = 0, jx: Int = 0, playUrl: String = "", flag: String = "线路") -> ParsePlan {
        GlobalParse.plan(parse: parse, jx: jx, playUrl: playUrl, flag: flag, header: header, settings: settings)
    }
    func names(_ plan: ParsePlan) -> [String] {
        guard case .run(let json, let web, _) = plan else { return [] }
        return (json + web).map(\.name)
    }

    #expect(plan() == .none, "a plain result plays as before")
    #expect(plan(parse: 1) == .none, "parse:1 with nothing named sniffs the address itself, as before")
    #expect(GlobalParse.plan(parse: 1, jx: 1, playUrl: "", flag: "x", header: [:], settings: ParseSettings()) == .none,
            "no parses configured: jx:1 is the old sniff")

    // jx:1 → Android's default selection, 超级解析: type 1 then type 0, filtered by line, JAR and
    // device-local ones left out.
    #expect(names(plan(jx: 1)) == ["接口A", "接口B", "网页A", "网页B"], "no service names 线路, so every one of each type")
    #expect(names(plan(jx: 1, flag: "qq")) == ["接口A", "网页A", "网页B"], "接口A is meant for qq")
    #expect(names(plan(jx: 1, flag: "qiyi")) == ["接口A", "接口B", "网页B"], "per type: only 网页B names qiyi")
    guard case .run(_, _, let godHeader) = plan(jx: 1) else { Issue.record("expected a run"); return }
    #expect(godHeader == header, "the media falls back to the result's own header")

    // A VIP line with no playUrl uses the parse too; with a playUrl the playUrl decides.
    #expect(names(plan(flag: "腾讯")) == ["接口A", "接口B", "网页A", "网页B"])
    #expect(names(plan(parse: 1, playUrl: "https://own.invalid/?v=", flag: "qq")) == [""])

    // playUrl prefixes.
    guard case .run(let json, let web, let used) = plan(parse: 1, playUrl: "json:https://site.invalid/jx?url=") else {
        Issue.record("json: must run"); return
    }
    #expect(json.map(\.url) == ["https://site.invalid/jx?url="] && web.isEmpty && used == header,
            "a parse with no header of its own is asked with the result's")
    guard case .run(let named, _, let namedHeader) = plan(parse: 1, playUrl: "parse:接口A") else {
        Issue.record("parse: must run"); return
    }
    #expect(named.map(\.url) == ["https://json-a.invalid/?url="] && namedHeader == ["User-Agent": "okhttp/4.9.1"],
            "its own header wins over the result's")
    guard case .run(_, let page, _) = plan(parse: 1, playUrl: "https://own.invalid/?v=") else {
        Issue.record("a bare playUrl is a web parse"); return
    }
    #expect(page.map(\.url) == ["https://own.invalid/?v="])

    // What is not run, and says so.
    guard case .unsupported(let jar) = plan(parse: 1, playUrl: "parse:聚合") else { Issue.record("type 3"); return }
    #expect(jar.contains("type 3"))
    guard case .unsupported(let local) = plan(parse: 1, playUrl: "json:http://127.0.0.1:10079/parse/?url=") else {
        Issue.record("loopback"); return
    }
    #expect(local.contains("本機"))
    guard case .unsupported = plan(parse: 1, playUrl: "parse:不存在") else { Issue.record("unknown name"); return }
    let jarOnly = ParseSettings(parses: [ParseEntry(name: "聚合", type: 3, url: "Demo")])
    guard case .unsupported = GlobalParse.plan(parse: 0, jx: 1, playUrl: "", flag: "x", header: [:], settings: jarOnly) else {
        Issue.record("nothing runnable"); return
    }
}

/// Through `SourceClient`, the way a play, a prefetch and a download all reach it.
private func spiderClient(script: String, site: Site) throws -> SourceClient {
    let runtime = try JavaScriptSpiderRuntime(name: "t", script: script, prelude: SpiderRegistry.bundled().prelude,
                                              storage: SpiderStorage(siteKey: "t", defaults: .standard))
    return .spider(SpiderSession(site: site, runtime: runtime), site)
}

private let jxSpider = """
module.exports = {
  init: function () { return ''; },
  playerContent: function (flag, id, vipFlags) {
    if (id === 'file') return { parse: 0, url: 'https://cdn.invalid/a/index.m3u8' };
    if (id === 'menu') return { parse: 1, jx: '1', url: ['标清', 'https://v.qq.com/x/sd.html', '高清', 'https://v.qq.com/x/hd.html'],
                                header: { Referer: 'https://source.invalid/' },
                                subs: [{ url: 'https://cdn.invalid/a.vtt', name: '中文', lang: 'zh', format: 'text/vtt' }] };
    if (id === 'vip') return { parse: 0, url: 'https://v.qq.com/x/vip.html' };
    return { parse: 1, jx: 1, url: id };
  }
};
"""

/// Every test here answers for the services through one shared stub, so they run one at a time.
@Suite(.serialized) struct GlobalParseServiceTests {
    @Test func aJSONServiceAnswersWithItsOwnHeadersOrTheFallback() async throws {
        ParseService.serve([
            "https://json-a.invalid/": .init(body: #"{"code":200,"url":"\#(longMedia)","ua":"Agent/1","Referer":"https://ref.invalid/"}"#),
            "https://json-b.invalid/": .init(body: #"{"data":{"url":"\#(longMedia)"}}"#),
            "https://short.invalid/": .init(body: #"{"url":"https://m.invalid/a.m3u8"}"#),
            "https://relative.invalid/": .init(body: #"{"url":"/mizhicdn/video/error.mp4?padding-padding-padding-padding"}"#),
        ])
        let session = ParseService.session
        let asked = ParseEntry(name: "A", type: 1, url: "https://json-a.invalid/?url=", header: ["User-Agent": "okhttp/4.9.1"])
        let a = try #require(await GlobalParser.json(asked, "https://v.qq.com/x/1.html", fallback: ["Referer": "fb"], session: session))
        #expect(a.url.absoluteString == longMedia)
        #expect(a.headers == ["User-Agent": "Agent/1", "Referer": "https://ref.invalid/"], "the answer's headers, ua meaning User-Agent")
        let request = try #require(ParseService.requests.first)
        #expect(request.url?.absoluteString == "https://json-a.invalid/?url=https://v.qq.com/x/1.html")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "okhttp/4.9.1", "the service is asked with its own header")
        #expect(request.value(forHTTPHeaderField: "Referer") == nil, "never with the media's")

        let b = try #require(await GlobalParser.json(ParseEntry(type: 1, url: "https://json-b.invalid/?url="), "x",
                                                     fallback: ["Referer": "fb"], session: session))
        #expect(b.url.absoluteString == longMedia && b.headers == ["Referer": "fb"], "data.url, and the fallback header")
        #expect(await GlobalParser.json(ParseEntry(type: 1, url: "https://short.invalid/?url="), "x", fallback: [:], session: session) == nil,
                "Android's length check")
        #expect(await GlobalParser.json(ParseEntry(type: 1, url: "https://relative.invalid/?url="), "x", fallback: [:], session: session) == nil)
        #expect(await GlobalParser.json(ParseEntry(type: 1, url: "https://missing.invalid/?url="), "x", fallback: [:], session: session) == nil)
        // A dead service's own error clip, on a host that answers nothing, is not an answer.
        ParseService.serve(["https://clip.invalid/": .init(body: #"{"url":"https://gone.invalid/packs/player/404_2.mp4?padding-padding"}"#)])
        #expect(await GlobalParser.json(ParseEntry(type: 1, url: "https://clip.invalid/?url="), "x", fallback: [:], session: session) == nil)
        #expect(ParseService.requests.map(\.url?.host) == ["clip.invalid", "gone.invalid"], "checked with the stream's own request")
    }

    @Test func theFirstServiceToAnswerWinsAndTheWholeParseIsBounded() async throws {
        ParseService.serve([
            "https://slow.invalid/": .init(body: #"{"url":"\#(longMedia)?slow"}"#, delay: .seconds(5)),
            "https://fast.invalid/": .init(body: #"{"url":"\#(longMedia)?fast"}"#, delay: .milliseconds(100)),
            "https://broken.invalid/": .init(body: "<html>"),
            "https://hung.invalid/": .init(body: #"{"url":"\#(longMedia)"}"#, delay: .seconds(30)),
        ])
        let session = ParseService.session
        let entries = ["slow", "broken", "fast"].map { ParseEntry(name: $0, type: 1, url: "https://\($0).invalid/?url=") }
        let clock = ContinuousClock()
        var began = clock.now
        let won = try #require(await GlobalParser.resolve("x", json: entries, web: [], header: [:], session: session))
        #expect(won.url.absoluteString.hasSuffix("?fast") && clock.now - began < .seconds(3), "the slow one is not waited for")

        began = clock.now
        let none = await GlobalParser.resolve("x", json: [ParseEntry(type: 1, url: "https://hung.invalid/?url=")], web: [],
                                              header: [:], budget: .seconds(1), session: session)
        #expect(none == nil && clock.now - began < .seconds(3), "a service that never answers costs the budget, no more")

        began = clock.now
        #expect(await GlobalParser.resolve("x", json: [ParseEntry(type: 1, url: "https://broken.invalid/?url=")], web: [],
                                           header: [:], session: session) == nil)
        #expect(clock.now - began < .seconds(3), "when every service has failed there is nothing left to wait for")
    }

    @Test func aCancelledPlayStopsAskingTheServices() async throws {
        ParseService.serve(["https://hung.invalid/": .init(body: #"{"url":"\#(longMedia)"}"#, delay: .seconds(30))])
        let session = ParseService.session
        let clock = ContinuousClock()
        let began = clock.now
        let task = Task {
            await GlobalParser.resolve("x", json: [ParseEntry(type: 1, url: "https://hung.invalid/?url=")], web: [],
                                       header: [:], session: session)
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        #expect(await task.value == nil && clock.now - began < .seconds(3))
    }

    @Test func aSpidersJxResultIsResolvedByTheConfigurationsServices() async throws {
        let decoded = try config(#"{"sites":[{"key":"t","name":"t","type":3,"api":"csp_T"}],"flags":["qq"],"parses":[{"name":"接口","type":1,"url":"https://json-b.invalid/?url="}]}"#)
        let client = try spiderClient(script: jxSpider, site: decoded.sites[0])
        ParseService.serve(["https://json-b.invalid/": .init(body: #"{"url":"\#(longMedia)"}"#)])

        let target = try #require(try await GlobalParser.session.withValue(ParseService.session) {
            try await client.playbackURL(for: Episode(name: "01", url: "menu"), flag: "线路")
        })
        #expect(target.url.absoluteString == longMedia)
        #expect(target.headers == ["Referer": "https://source.invalid/"], "the service named none, so the result's own")
        #expect(target.qualities.map(\.name) == ["标清", "高清"] && target.defaultIndex == 1, "the quality menu is kept")
        #expect(target.subtitles.map(\.url) == ["https://cdn.invalid/a.vtt"], "and the source's subtitles")
        #expect(ParseService.requests.map { $0.url?.absoluteString } == ["https://json-b.invalid/?url=https://v.qq.com/x/hd.html"],
                "only the default entry is parsed, as only it is probed or sniffed today")

        // A VIP line reaches the service too, and the spider is handed the configuration's flags.
        ParseService.serve(["https://json-b.invalid/": .init(body: #"{"url":"\#(longMedia)"}"#)])
        _ = try await GlobalParser.session.withValue(ParseService.session) {
            try await client.playbackURL(for: Episode(name: "01", url: "vip"), flag: "qq")
        }
        #expect(ParseService.requests.count == 1)

        // A direct media address never waits for a service, not even on a VIP line.
        ParseService.serve([:])
        let direct = try #require(try await GlobalParser.session.withValue(ParseService.session) {
            try await client.playbackURL(for: Episode(name: "01", url: "file"), flag: "qq")
        })
        #expect(direct.url.absoluteString == "https://cdn.invalid/a/index.m3u8" && ParseService.requests.isEmpty)

        // Every service failing is the services' failure, named, and not a missing address.
        ParseService.serve([:])
        await #expect(throws: GlobalParseError.unresolved(["接口"])) {
            _ = try await GlobalParser.session.withValue(ParseService.session) {
                try await client.playbackURL(for: Episode(name: "02", url: "opaque-id"), flag: "线路")
            }
        }
    }

    @Test func aParseTheAppCannotRunIsReportedAndNotGuessedAt() async throws {
        let decoded = try config(#"{"sites":[{"key":"t","name":"t","type":3,"api":"csp_T"}],"parses":[{"name":"聚合","type":3,"url":"Demo"}]}"#)
        let client = try spiderClient(script: jxSpider, site: decoded.sites[0])
        ParseService.serve([:])
        await #expect(throws: GlobalParseError.self) {
            _ = try await GlobalParser.session.withValue(ParseService.session) {
                try await client.playbackURL(for: Episode(name: "01", url: "opaque-id"), flag: "线路")
            }
        }
        #expect(ParseService.requests.isEmpty)
    }

    /// A spider session is cached by `Site.id`, which two configurations can share. The parses used are
    /// the ones of the configuration the client was made for, never the session's.
    @Test func theParsesBelongToTheConfigurationTheClientWasMadeFor() async throws {
        let siteJSON = #"{"key":"t","name":"t","type":3,"api":"csp_T"}"#
        let a = try config(#"{"sites":[\#(siteJSON)],"parses":[{"name":"A","type":1,"url":"https://json-a.invalid/?url="}]}"#)
        let b = try config(#"{"sites":[\#(siteJSON)],"parses":[{"name":"B","type":1,"url":"https://json-b.invalid/?url="}]}"#)
        #expect(a.sites[0].id == b.sites[0].id, "the same site as far as identity goes")
        let runtime = try JavaScriptSpiderRuntime(name: "t", script: jxSpider, prelude: SpiderRegistry.bundled().prelude,
                                                  storage: SpiderStorage(siteKey: "t", defaults: .standard))
        let session = SpiderSession(site: a.sites[0], runtime: runtime)
        let client = SourceClient.spider(session, b.sites[0])
        ParseService.serve(["https://json-a.invalid/": .init(body: #"{"url":"\#(longMedia)?a"}"#),
                            "https://json-b.invalid/": .init(body: #"{"url":"\#(longMedia)?b"}"#)])
        let target = try #require(try await GlobalParser.session.withValue(ParseService.session) {
            try await client.playbackURL(for: Episode(name: "01", url: "opaque"), flag: "线路")
        })
        #expect(target.url.absoluteString.hasSuffix("?b"))
        #expect(ParseService.requests.allSatisfy { $0.url?.host == "json-b.invalid" })

        // `make` pairs the cached session with the site it was asked for.
        let resolver = CSPSourceResolver()
        let ported = #"{"key":"sp","name":"S","type":3,"api":"csp_AppGet","ext":{"url":"https://example.invalid"}}"#
        let first = try config(#"{"sites":[\#(ported)]}"#).sites[0]
        let second = try config(#"{"sites":[\#(ported)],"parses":[{"name":"B","type":0,"url":"https://web.invalid/?url="}]}"#).sites[0]
        _ = try await SourceClient.make(site: first, resolver: resolver)
        guard case .spider(_, let paired) = try await SourceClient.make(site: second, resolver: resolver) else {
            Issue.record("expected a spider"); return
        }
        #expect(paired.parsing == second.parsing)
    }

    @Test func aCMSSitesPlayUrlAndVIPLinesFollowSiteApi() async throws {
        // `playUrl` on a type-1 site: every page address goes to the named service; a file never does.
        let decoded = try config(#"{"sites":[{"key":"c","name":"C","type":1,"api":"https://cms.invalid/api.php","playUrl":"json:https://json-b.invalid/?url="}]}"#)
        let client = SourceClient.cms(try CMSClient(site: decoded.sites[0]))
        ParseService.serve(["https://json-b.invalid/": .init(body: #"{"url":"\#(longMedia)"}"#)])
        let parsed = try #require(try await GlobalParser.session.withValue(ParseService.session) {
            try await client.playbackURL(for: Episode(name: "01", url: "https://share.invalid/share/abc"), flag: "云播")
        })
        #expect(parsed.url.absoluteString == longMedia)
        ParseService.serve([:])
        let file = try #require(try await GlobalParser.session.withValue(ParseService.session) {
            try await client.playbackURL(for: Episode(name: "01", url: "https://cdn.invalid/1/index.m3u8"), flag: "m3u8")
        })
        #expect(file.url.absoluteString == "https://cdn.invalid/1/index.m3u8" && ParseService.requests.isEmpty)

        // A `json:` service an Android JAR runs on the device: a file still plays, a page says why not.
        let local = try config(#"{"sites":[{"key":"c","name":"C","type":1,"api":"https://cms.invalid/api.php","playUrl":"json:http://127.0.0.1:10079/parse/?thread=0&proxy=&url="}]}"#)
        let localClient = SourceClient.cms(try CMSClient(site: local.sites[0]))
        let kept = try #require(try await localClient.playbackURL(for: Episode(name: "01", url: "https://cdn.invalid/2/index.m3u8"), flag: "m3u8"))
        #expect(kept.url.absoluteString == "https://cdn.invalid/2/index.m3u8")
        await #expect(throws: GlobalParseError.self) {
            _ = try await localClient.playbackURL(for: Episode(name: "01", url: "https://share.invalid/share/abc"), flag: "云播")
        }
    }
}

@Test func theSourceCheckDoesNotBlameASourceForItsParseServices() {
    let site = try! JSONDecoder().decode(Site.self, from: Data(#"{"key":"t","name":"t","type":3,"api":"csp_T"}"#.utf8))
    let result = SourceCheck.Result(index: 0, site: site, verdict: .needsParse("x"), trail: "", detailMilliseconds: 10)
    #expect(result.category == .needsParse && result.detail == "x")
    #expect(result.healthEvents.map(\.1) == [true, true], "browse and detail went through; no play failure is recorded")
}

// The web side: Android's `parse.html` — several services in one page of iframes — as a `data:` page.

@MainActor @Test func severalWebServicesShareOnePageAndTheFirstStreamWins() async throws {
    func page(_ body: String) -> String {
        "data:text/html;charset=utf-8;base64," + Data("<html><body>\(body)</body></html>".utf8).base64EncodedString()
    }
    let silent = page("<p>nothing here</p>")
    let playing = page("<script>setTimeout(function(){ fetch('https://cdn.invalid/frame/index.m3u8').catch(function(){}); }, 300);</script>")
    let combined = try #require(GlobalParser.framesPage([silent, playing]))
    let found = await MediaSniffer().sniff(page: combined, timeout: .seconds(6))
    #expect(found?.absoluteString == "https://cdn.invalid/frame/index.m3u8", "a stream requested inside an iframe is caught")
}

@MainActor @Test func aSniffEndsWhenItsCallerGivesUp() async throws {
    let sniffer = MediaSniffer()
    let quiet = try #require(URL(string: "data:text/html;charset=utf-8;base64," + Data("<p>quiet</p>".utf8).base64EncodedString()))
    let clock = ContinuousClock()
    let began = clock.now
    let task = Task { await sniffer.sniffWithSubtitles(page: quiet, timeout: .seconds(20)) }
    try await Task.sleep(for: .milliseconds(500))
    task.cancel()
    #expect(await task.value == nil && clock.now - began < .seconds(5))
}

@MainActor @Test func aWebServicesPageIsOpenedWithItsUserAgent() async throws {
    let html = "<script>fetch('https://cdn.invalid/' + encodeURIComponent(navigator.userAgent) + '/index.m3u8').catch(function(){});</script>"
    let page = try #require(URL(string: "data:text/html;charset=utf-8;base64," + Data(html.utf8).base64EncodedString()))
    let found = await MediaSniffer().sniffWithSubtitles(page: page, headers: ["user-agent": "ParseUA/1"], timeout: .seconds(6))
    #expect(found?.mediaURL.absoluteString == "https://cdn.invalid/ParseUA%2F1/index.m3u8")
}

/// Live, opt-in: every runnable service of a real configuration against one real address, one at a
/// time and then all together the way a play asks them, each hit then probed for media bytes.
///
///     WANG_MOVIE_JSON=<config> GLOBAL_PARSE_LIVE_URL='https://v.qq.com/x/cover/…/….html' \
///       swift test --package-path ios --filter liveParseServices
@MainActor @Test func liveParseServices() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["WANG_MOVIE_JSON"], let address = env["GLOBAL_PARSE_LIVE_URL"] else { return }
    let settings = try ConfigLoader.decode(Data(contentsOf: URL(fileURLWithPath: path))).parsing
    func report(_ label: String, _ parsed: GlobalParser.Parsed?, since began: ContinuousClock.Instant) async {
        let seconds = (ContinuousClock.now - began).components.seconds
        guard let parsed else { print("[parse-live] \(label): nothing in \(seconds)s"); return }
        let kind = await MediaProbe.classify(parsed.url, headers: parsed.headers)
        print("[parse-live] \(label): \(parsed.url.absoluteString.prefix(110)) headers=\(parsed.headers) [\(kind)] in \(seconds)s")
    }
    for entry in settings.parses where entry.type == 0 || entry.type == 1 {
        if let reason = entry.unusableReason { print("[parse-live] \(entry.name) (type \(entry.type)): skipped, \(reason)"); continue }
        let began = ContinuousClock.now
        let parsed = entry.type == 1
            ? await GlobalParser.json(entry, address, fallback: [:], session: .webHTV)
            : await GlobalParser.web([entry], address, header: entry.header, budget: GlobalParser.budget)
        await report("\(entry.name) (type \(entry.type))", parsed, since: began)
    }
    guard case .run(let json, let web, let header) = GlobalParse.plan(parse: 1, jx: 1, playUrl: "", flag: "",
                                                                       header: [:], settings: settings) else { return }
    let began = ContinuousClock.now
    await report("超级解析 \(json.count) JSON + \(web.count) web", await GlobalParser.resolve(address, json: json, web: web, header: header),
                 since: began)
}
