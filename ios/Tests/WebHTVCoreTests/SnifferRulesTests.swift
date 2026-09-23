import Foundation
import Network
import WebKit
import Testing
@testable import WebHTVCore

// MARK: - Builders

private func rule(_ name: String, hosts: [String], regex: [String] = [],
                  script: [String] = [], exclude: [String] = []) -> SnifferRule {
    SnifferRule(name: name, hosts: hosts, regex: regex, script: script, exclude: exclude)
}

/// The rules actually measured in `wang-movie.json` on 2026-09-23, in the configuration's own order.
/// Ten rules: name 10, hosts 10, regex 8, script 2, exclude 2.
private let measuredRules: [SnifferRule] = [
    rule("cl", hosts: ["magnet"], regex: ["最 新", "直 播", "更 新"]),
    rule("火山嗅探", hosts: ["huoshan.com"], regex: ["item_id="]),
    rule("抖音嗅探", hosts: ["douyin.com"], regex: ["is_play_url="]),
    rule("農民嗅探", hosts: ["toutiaovod.com"], regex: ["video/tos/cn"]),
    rule("七新嗅探", hosts: ["api.52wyb.com"], regex: ["m3u8?pt=m3u8"]),
    rule("夜市", hosts: ["yeslivetv.com"],
         script: ["document.getElementsByClassName('vjs-big-play-button')[0].click()"]),
    rule("毛驢", hosts: ["www.maolvys.com"],
         script: ["document.getElementsByClassName('swal-button swal-button--confirm')[0].click()"]),
    rule("czzy", hosts: ["10086.cn"], regex: ["/storageWeb/servlet/downloadServlet"]),
    rule("bdys", hosts: ["bytetos.com", "byteimg.com", "bytednsdoc.com", "pstatp.com"],
         regex: ["/tos-cn"], exclude: [".m3u8"]),
    rule("bdys10", hosts: ["bdys10.com"], regex: ["/obj/"], exclude: [".m3u8"])
]

private func url(_ value: String) -> URL { URL(string: value)! }

// MARK: - Decoding

@Test func theConfigurationsOwnRulesDecode() throws {
    // The real shape, including the fields Gson leaves null: only `name` and `hosts` are on all ten.
    let json = """
    [
      {"name":"cl","hosts":["magnet"],"regex":["最 新","直 播","更 新"]},
      {"name":"夜市","hosts":["yeslivetv.com"],"script":["a()"]},
      {"name":"bdys10","hosts":["bdys10.com"],"regex":["/obj/"],"exclude":[".m3u8"]}
    ]
    """
    let rules = try JSONDecoder().decode([SnifferRule].self, from: Data(json.utf8))

    #expect(rules.count == 3)
    #expect(rules[0].name == "cl")
    #expect(rules[0].hosts == ["magnet"])
    #expect(rules[0].regex == ["最 新", "直 播", "更 新"])
    #expect(rules[0].script.isEmpty)
    #expect(rules[0].exclude.isEmpty)
    #expect(rules[1].script == ["a()"])
    #expect(rules[2].exclude == [".m3u8"])
}

@Test func aRuleCarryingOnlyNameAndHostsIsFine() throws {
    let rules = try JSONDecoder().decode(
        [SnifferRule].self, from: Data(#"[{"name":"x","hosts":["a.com"]}]"#.utf8)
    )

    #expect(rules.count == 1)
    #expect(rules[0].regex.isEmpty)
    #expect(rules[0].script.isEmpty)
    #expect(rules[0].exclude.isEmpty)
}

@Test func aMalformedRuleEntryDoesNotDiscardTheWholeList() throws {
    // Gson leaves a wrong-typed field null rather than failing the document, and one odd member
    // must not cost every other rule.
    let json = #"[{"name":"x","hosts":["a.com"],"regex":"not-a-list"},{"name":"y","hosts":["b.com"]}]"#
    let rules = try JSONDecoder().decode([SnifferRule].self, from: Data(json.utf8))

    #expect(rules.count == 2)
    #expect(rules[0].regex.isEmpty)
    #expect(rules[1].name == "y")
}

@Test func aConfigurationWithNoRulesIsIndistinguishableFromOneMadeBeforeThisStage() throws {
    #expect(SnifferRules.make(rules: []) == nil)
    // A rule that names no host can never be selected, so it is not carried.
    #expect(SnifferRules.make(rules: [rule("x", hosts: [])]) == nil)
    #expect(SnifferRules.make(rules: [rule("x", hosts: [""])]) == nil)
    #expect(SnifferRules.make(rules: measuredRules) != nil)
}

// MARK: - Host selection

@Test func theDirectHostSelectsARule() {
    let rules = SnifferRules(rules: measuredRules)

    #expect(rules.rule(for: url("https://huoshan.com/x?item_id=9"))?.name == "火山嗅探")
    #expect(rules.rule(for: url("https://bdys10.com/obj/a"))?.name == "bdys10")
    // A subdomain contains the configured host as a substring, which is what Android's `contains`
    // does on the host string.
    #expect(rules.rule(for: url("https://v3.douyin.com/a"))?.name == "抖音嗅探")
}

@Test func aHostInsideTheUrlQueryParameterSelectsARuleToo() {
    let rules = SnifferRules(rules: measuredRules)
    // The page is on some wrapper host, but the stream it names is on a configured one.
    let wrapped = url("https://player.example.com/vip/?url=https%3A%2F%2Fbdys10.com%2Fobj%2Fa")

    #expect(rules.rule(for: wrapped)?.name == "bdys10")
}

@Test func theDirectHostAndTheWrappedHostShareOneHaystackWithNoPrecedenceBetweenThem() {
    // Android joins them into a single string and searches that, so neither wins on position —
    // configuration order does. Proven both ways round with the same pair of hosts.
    let bdysFirst = SnifferRules(rules: [
        rule("bdys10", hosts: ["bdys10.com"], regex: ["/obj/"]),
        rule("douyin", hosts: ["douyin.com"], regex: ["is_play_url="])
    ])
    let douyinFirst = SnifferRules(rules: [
        rule("douyin", hosts: ["douyin.com"], regex: ["is_play_url="]),
        rule("bdys10", hosts: ["bdys10.com"], regex: ["/obj/"])
    ])
    // Direct host is douyin.com, wrapped host is bdys10.com.
    let mixed = url("https://douyin.com/p?url=https%3A%2F%2Fbdys10.com%2Fobj%2Fa")

    #expect(bdysFirst.rule(for: mixed)?.name == "bdys10", "the earlier rule wins, not the direct host")
    #expect(douyinFirst.rule(for: mixed)?.name == "douyin", "and the other way round")

    #expect(SnifferRules.hostHaystack(for: mixed) == "douyin.com,bdys10.com")
}

@Test func theFirstMatchingRuleInConfigurationOrderWins() {
    let rules = SnifferRules(rules: [
        rule("first", hosts: ["example.com"], regex: ["/a/"]),
        rule("second", hosts: ["example.com"], regex: ["/b/"])
    ])

    #expect(rules.rule(for: url("https://example.com/b/x"))?.name == "first")
}

@Test func aHostThatMatchesNothingSelectsNoRule() {
    let rules = SnifferRules(rules: measuredRules)

    #expect(rules.rule(for: url("https://unrelated.example/video.m3u8")) == nil)
}

@Test func hostMatchingLooksOnlyAtTheHostAndNotAtTheWholeURL() {
    // The guard against turning this into substring-anywhere matching: the configured host appears
    // in the *path*, which must not select the rule.
    let rules = SnifferRules(rules: [rule("douyin", hosts: ["douyin.com"], regex: ["x"])])

    #expect(rules.rule(for: url("https://other.example/redirect/douyin.com/a")) == nil)
    #expect(rules.rule(for: url("https://other.example/a?ref=douyin.com")) == nil)
}

@Test func aURLWithNoHostSelectsNoRule() {
    let rules = SnifferRules(rules: measuredRules)

    #expect(SnifferRules.hostHaystack(for: url("file:///tmp/a.m3u8")) == nil)
    #expect(rules.rule(for: url("file:///tmp/a.m3u8")) == nil)
}

@Test func containOrMatchIsSubstringOrWholeStringMatchAndNeverThrows() {
    // `text.contains(regex) || text.matches(regex)`, where Java's `matches` is a full-string match.
    #expect(SnifferRules.containOrMatch("a.com,b.com", "a.com"))
    #expect(SnifferRules.containOrMatch("bdys10.com,", "^bdys10\\.com,$"))
    #expect(!SnifferRules.containOrMatch("bdys10.com,", "^bdys10\\.com$"),
            "a partial pattern match is not a `matches`")
    // Android wraps this in try/catch returning false, so an unparseable host pattern is parity.
    #expect(!SnifferRules.containOrMatch("a.com,", "[unclosed"))
    #expect(!SnifferRules.containOrMatch("a.com,", ""))
}

// MARK: - exclude / regex precedence

@Test func excludeOutranksRegexEvenWhenBothMatch() {
    let rules = SnifferRules(rules: [
        rule("both", hosts: ["example.com"], regex: ["/obj/"], exclude: [".m3u8"])
    ])

    #expect(rules.verdict(for: "https://example.com/obj/a.m3u8") == .notVideo)
    #expect(rules.verdict(for: "https://example.com/obj/a.mp4") == .video)
}

@Test func excludeRejectsAndRegexAccepts() {
    let rules = SnifferRules(rules: measuredRules)

    #expect(rules.verdict(for: "https://bdys10.com/obj/a.ts") == .video)
    #expect(rules.verdict(for: "https://bdys10.com/obj/a.m3u8") == .notVideo)
    #expect(rules.verdict(for: "https://huoshan.com/v?item_id=77") == .video)
    #expect(rules.verdict(for: "https://douyin.com/v?is_play_url=1") == .video)
    #expect(rules.verdict(for: "https://toutiaovod.com/video/tos/cn/x") == .video)
}

@Test func aMatchedRuleThatSaysNothingAboutThisURLLeavesItUndecided() {
    let rules = SnifferRules(rules: measuredRules)

    // The host matches 火山嗅探, but the URL carries no `item_id=`.
    #expect(rules.verdict(for: "https://huoshan.com/nothing-here") == .undecided)
}

@Test func noMatchingRuleLeavesEveryURLExactlyWhereItWas() {
    let rules = SnifferRules(rules: measuredRules)

    #expect(rules.verdict(for: "https://unrelated.example/stream/index.m3u8") == .undecided)
    #expect(rules.verdict(for: "https://unrelated.example/page.html") == .undecided)
}

@Test func eachListIsAppliedAsALiteralPassThenAPatternPass() {
    // Android runs every entry as a literal `contains` before running any of them as a pattern, so a
    // literal hit on the second entry beats a pattern hit on the first. Folding the passes together
    // would silently change which entry decides.
    let rules = SnifferRules(rules: [
        rule("order", hosts: ["example.com"],
             exclude: ["^https://example\\.com/.*$", "/literal/"])
    ])

    // Both entries match this URL — one as a pattern, one literally — and the verdict is the same,
    // so the observable proof is that a literal-only entry still decides on its own.
    #expect(rules.verdict(for: "https://example.com/literal/a") == .notVideo)

    let literalOnly = SnifferRules(rules: [
        rule("order", hosts: ["example.com"], exclude: ["/literal/"])
    ])
    #expect(literalOnly.verdict(for: "https://example.com/literal/a") == .notVideo)

    // A pattern that is not a literal substring still matches on the second pass.
    let patternOnly = SnifferRules(rules: [
        rule("order", hosts: ["example.com"], exclude: ["/lit.ral/"])
    ])
    #expect(patternOnly.verdict(for: "https://example.com/literal/a") == .notVideo)
}

@Test func aPatternIsTriedLiterallyFirstWhichIsHowTheSevenNewRuleBehaves() {
    // `m3u8?pt=m3u8` is a literal substring for the source that wrote it, and simultaneously a valid
    // regex meaning `m3u` + optional `8` + `pt=m3u8`. Android accepts either; so does this.
    let rules = SnifferRules(rules: measuredRules)

    #expect(rules.verdict(for: "https://api.52wyb.com/x.m3u8?pt=m3u8") == .video, "literal pass")
    #expect(rules.verdict(for: "https://api.52wyb.com/xm3upt=m3u8") == .video, "pattern pass")
}

@Test func malformedPatternsAreTreatedAsNonMatchingAndNeverCrash() {
    // Android compiles these outside any try/catch, so a bad pattern throws there. There is no
    // Android fallback to port; treating it as "did not match" is the conservative reading and
    // leaves the built-in test to decide.
    let rules = SnifferRules(rules: [
        rule("bad", hosts: ["example.com"], regex: ["[unclosed", "(("], exclude: ["[also-bad"])
    ])

    #expect(rules.verdict(for: "https://example.com/a.m3u8") == .undecided)
    #expect(rules.uncompilablePatterns.count == 3)
}

@Test func aMalformedPatternStillAllowsItsWellFormedSiblingsToDecide() {
    let rules = SnifferRules(rules: [
        rule("mixed", hosts: ["example.com"], regex: ["[unclosed", "/obj/"])
    ])

    #expect(rules.verdict(for: "https://example.com/obj/a") == .video)
}

@Test func theRulesNeverTouchAPlaylist() {
    // IOS-POC-5S measured that the playlist-shaped entries in `wang-sex.json` have no HLS consumer
    // anywhere in the Android repository — `Sniffer` only ever sees URLs. They are inert there and
    // they stay inert here: against a URL they simply do not match, and there is no code path from
    // a rule to a playlist at all.
    let rules = SnifferRules(rules: [
        rule("m3u8-looking", hosts: ["example.com"],
             regex: ["#EXT-X-DISCONTINUITY", "15.1666", "16.63"])
    ])

    #expect(rules.verdict(for: "https://example.com/hls/index.m3u8") == .undecided)
    #expect(rules.verdict(for: "https://example.com/seg/00001.ts") == .undecided)
    // And the whole surface a rule exposes is three questions about strings — nothing that could
    // rewrite or re-serve media.
    #expect(rules.script(for: url("https://example.com/hls/index.m3u8")).isEmpty)
}

// MARK: - script

@Test func scriptComesFromTheRuleThatMatchesThePageNotTheCandidate() {
    let rules = SnifferRules(rules: measuredRules)

    #expect(rules.script(for: url("https://yeslivetv.com/play/1"))
        == ["document.getElementsByClassName('vjs-big-play-button')[0].click()"])
    #expect(rules.script(for: url("https://www.maolvys.com/v/2"))
        == ["document.getElementsByClassName('swal-button swal-button--confirm')[0].click()"])
}

@Test func aPageWithNoMatchingRuleGetsNoScript() {
    let rules = SnifferRules(rules: measuredRules)

    #expect(rules.script(for: url("https://unrelated.example/play")).isEmpty)
    // A rule can match and simply have no script — 8 of the 10 measured rules are like that.
    #expect(rules.script(for: url("https://bdys10.com/obj/a")).isEmpty)
}

@Test func emptyScriptEntriesAreSkippedTheWayAndroidSkipsThem() {
    let rules = SnifferRules(rules: [
        rule("blanks", hosts: ["example.com"], script: ["", "doIt()", ""])
    ])

    #expect(rules.script(for: url("https://example.com/p")) == ["doIt()"])
}

// MARK: - Configuration isolation

@Test func switchingConfigurationAThenBThenARestoresEachOnesOwnRules() {
    // The rule set is a plain value rebuilt from whichever configuration is adopted, so there is no
    // cache that could survive a switch — this pins that A's rules never answer for B.
    let a = SnifferRules.make(rules: [rule("A", hosts: ["a.example"], regex: ["/a/"])])
    let b = SnifferRules.make(rules: [rule("B", hosts: ["b.example"], regex: ["/b/"])])

    #expect(a?.verdict(for: "https://a.example/a/x") == .video)
    #expect(a?.verdict(for: "https://b.example/b/x") == .undecided, "A must not answer for B's host")
    #expect(b?.verdict(for: "https://b.example/b/x") == .video)
    #expect(b?.verdict(for: "https://a.example/a/x") == .undecided, "and B must not answer for A's")

    let aAgain = SnifferRules.make(rules: [rule("A", hosts: ["a.example"], regex: ["/a/"])])
    #expect(aAgain == a, "returning to A is deterministic, not merely similar")
}

@Test func anEmptyConfigurationClearsTheRulesRatherThanKeepingTheLastOnes() {
    let a = SnifferRules.make(rules: [rule("A", hosts: ["a.example"], regex: ["/a/"])])
    let none = SnifferRules.make(rules: [])

    #expect(a != nil)
    #expect(none == nil, "nil is what makes an empty configuration identical to having no rules")
}

// MARK: - The built-in test is untouched where no rule speaks

@Test func theBuiltInCandidateTestIsUnchanged() {
    // 5S-3 sits in front of this; it does not modify it. These are the pre-existing semantics.
    let keywords = MediaSniffer.defaultKeywords
    let exclusions = MediaSniffer.defaultExclusions

    #expect(MediaSniffer.isCandidate("https://cdn.example/a/index.m3u8",
                                     keywords: keywords, exclusions: exclusions))
    #expect(!MediaSniffer.isCandidate("https://cdn.example/a/page.html",
                                      keywords: keywords, exclusions: exclusions))
    #expect(!MediaSniffer.isCandidate("ftp://cdn.example/a.mp4",
                                      keywords: keywords, exclusions: exclusions))
}

@Test func wrapperUnwrappingStillWorksAlongsideTheRules() {
    // IOS-POC-6C's behaviour, which 5S-3 must not disturb.
    let wrapper = url("https://player.example/vip/?url=https://cdn.example/a/index.m3u8")

    #expect(MediaSniffer.embeddedMedia(in: wrapper)?.absoluteString
        == "https://cdn.example/a/index.m3u8")
}

// MARK: - The script really reaches the sniffer's web view, and only it

/// These need a page with a **real host**, because rule selection is by host: a `data:` URL has
/// none, so the offline harness the other sniffer tests use cannot exercise a rule at all.
/// Loopback is host-shaped, which is the same trick `AdBlockListTests` uses on its own server.
///
/// The page requests nothing by itself. If a stream comes back, the only thing that can have asked
/// for it is the rule's `script` — running on the sniffer's own web view.
@MainActor
@Test func theRulesScriptRunsOnTheSnifferWebViewAndItsStreamIsCaught() async throws {
    let server = try ScriptedPage()
    defer { server.stop() }

    let sniffer = MediaSniffer()
    sniffer.snifferRules = SnifferRules.make(rules: [
        rule("loopback", hosts: [server.host], script: ["fetch('/injected/index.m3u8')"])
    ])

    let found = await sniffer.sniff(page: server.pageURL, timeout: .seconds(8))

    #expect(found?.path == "/injected/index.m3u8",
            "the page asks for nothing on its own, so this can only be the injected script")
}

@MainActor
@Test func aPageWhoseHostNoRuleNamesGetsNoScriptAtAll() async throws {
    let server = try ScriptedPage()
    defer { server.stop() }

    let sniffer = MediaSniffer()
    // A rule that exists but names a different host.
    sniffer.snifferRules = SnifferRules.make(rules: [
        rule("elsewhere", hosts: ["not-this-host.example"], script: ["fetch('/injected/index.m3u8')"])
    ])

    let found = await sniffer.sniff(page: server.pageURL, timeout: .seconds(4))

    #expect(found == nil, "no rule matched, so nothing was injected and nothing was found")
    #expect(!server.requestedPaths.contains("/injected/index.m3u8"),
            "and the request never reached the socket")
}

@MainActor
@Test func aSnifferWithNoRulesBehavesExactlyAsItDidBeforeThisStage() async throws {
    let server = try ScriptedPage()
    defer { server.stop() }

    let sniffer = MediaSniffer()
    sniffer.snifferRules = nil

    let found = await sniffer.sniff(page: server.pageURL, timeout: .seconds(4))

    #expect(found == nil)
    #expect(!server.requestedPaths.contains("/injected/index.m3u8"))
}

/// Serves one page that requests nothing, and records what was asked for.
///
/// Deliberately smaller than `AdBlockListTests`' server: that one is `private` to its own file and
/// serves a page built for blocker assertions, so copying its shape here is cheaper than widening
/// this change to touch a test file it has no other business in.
private final class ScriptedPage: @unchecked Sendable {
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

    let host = "127.0.0.1"
    var pageURL: URL { URL(string: "http://127.0.0.1:\(port ?? 0)/page.html")! }
    var requestedPaths: [String] { lock.withLock { paths } }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel(); return
            }
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            self.lock.withLock { self.paths.append(path) }
            // The page is inert on purpose: it requests nothing, so anything the sniffer catches
            // came from the injected script.
            let body = path == "/page.html" ? "<html><body>nothing here</body></html>" : "ok"
            let type = path == "/page.html" ? "text/html" : "application/octet-stream"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\n"
                + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8),
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func stop() { listener.cancel() }
}
