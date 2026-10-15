import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// W-124 (IOS-POC-59 U1): the configuration's `lives`, decoded so one bad live costs only itself
// and never the sites. AC-1 to AC-4.

private let cmsSite = #"{"key":"k","name":"n","type":1,"api":"https://example.com/api"}"#

private func config(_ lives: String?) throws -> WebHTVConfig {
    let tail = lives.map { #","lives":"# + $0 } ?? ""
    return try ConfigLoader.validate(Data((#"{"sites":["# + cmsSite + "]" + tail + "}").utf8))
}

private func siteShape(_ config: WebHTVConfig) -> [String] {
    config.sites.map { "\($0.id)|\($0.jar)|\($0.type)|\($0.api)" }
}

@Test func livesDecodeBesideUnchangedSites() throws {
    let plain = try config(nil)
    let both = try config(#"[{"name":"a","url":"http://x/a.txt","pass":"yes","timeout":"5","header":3},{"name":"b","url":"http://x/b.m3u"}]"#)
    #expect(siteShape(both) == siteShape(plain))
    #expect(both.lives.map(\.name) == ["a", "b"])
    #expect(both.lives[0].timeout == 5)
    #expect(both.lives[0].pass == false)
    #expect(both.lives[0].header.isEmpty)
    #expect(plain.lives.isEmpty)
}

@Test func oneBrokenLiveCostsOnlyItself() throws {
    let lives = try config(#"[1, null, "x", {"name":"a"}, {"name":"b","url":"http://x/b.txt"}]"#).lives
    #expect(lives.map(\.name) == ["b"])
}

@Test func aLivesValueOfTheWrongTypeLeavesTheConfigIntact() throws {
    let plain = try config(nil)
    for value in [#""oops""#, "{}", "3", "null"] {
        let decoded = try config(value)
        #expect(decoded.lives.isEmpty, "\(value)")
        #expect(siteShape(decoded) == siteShape(plain), "\(value)")
        #expect(decoded.ads == plain.ads && decoded.rules.count == plain.rules.count)
        #expect(decoded.parsing.parses.count == plain.parsing.parses.count)
    }
}

@Test func eachLiveFieldToleratesItsOwnBadType() throws {
    func live(_ fields: String) throws -> LiveSource? {
        try config(#"[{"name":"a","url":"http://x/a.txt","# + fields + "}]").lives.first
    }
    #expect(try live(#""timeout":5"#)?.timeout == 5)
    #expect(try live(#""timeout":"5""#)?.timeout == 5)
    #expect(try live(#""timeout":"abc""#)?.timeout == nil)
    #expect(try live(#""timeout":5.5"#)?.timeout == nil)
    #expect(try live(#""pass":true"#)?.pass == true)
    #expect(try live(#""pass":"true""#)?.pass == true)
    // Gson: a string is Boolean.parseBoolean, a number is != 0.
    #expect(try live(#""pass":"1""#)?.pass == false)
    #expect(try live(#""pass":1"#)?.pass == true)
    #expect(try live(#""header":{"a":"b","n":1}"#)?.header == ["a": "b"])
    #expect(try live(#""header":3"#)?.header == [:])
    #expect(try live(#""header":["a"]"#)?.header == [:])
    #expect(try live(#""type":"0""#) != nil)
    #expect(try live(#""type":null"#) != nil)
    #expect(try live(#""type":3"#) == nil)
    #expect(try live(#""type":"abc""#) == nil)
    #expect(try live(#""api":"csp_Live""#) == nil)
    #expect(try live(#""ua":"","epg":"""#)?.ua == nil)
    #expect(try config(#"[{"name":"","url":"http://x/a.txt"},{"name":"a","url":""}]"#).lives.isEmpty)
}

@Test func aRepeatedLiveNameKeepsTheFirst() throws {
    let lives = try config(#"[{"name":"a","url":"http://x/1.txt"},{"name":"a","url":"http://x/2.txt"},{"name":"b","url":"http://x/3.txt"}]"#).lives
    #expect(lives.map(\.url) == ["http://x/1.txt", "http://x/3.txt"])
}

@Test func livesAcceptJSON5() throws {
    let lives = try config("""
    [
      // a comment
      {"name":"a","url":"http://x/a.txt",},
    ]
    """).lives
    #expect(lives.map(\.name) == ["a"])
}

@Test func livesAloneStillDoNotMakeAUsableConfig() throws {
    let lives = #"[{"name":"a","url":"http://x/a.txt"}]"#
    #expect(throws: ConfigLoaderError.noSupportedSites) { try ConfigLoader.validate(Data((#"{"lives":"# + lives + "}").utf8)) }
    #expect(throws: ConfigLoaderError.noSupportedSites) { try ConfigLoader.validate(Data((#"{"sites":null,"lives":"# + lives + "}").utf8)) }
    #expect(throws: ConfigLoaderError.noSupportedSites) { try ConfigLoader.validate(Data(#"{"sites":[]}"#.utf8)) }
}

/// Guards against a `try?` around `sites`: a broken site list must still fail decoding loudly.
@Test func aBrokenSiteListStillFailsToDecode() {
    #expect(throws: DecodingError.self) { try ConfigLoader.validate(Data(#"{"sites":[{"key":1}]}"#.utf8)) }
    #expect(throws: DecodingError.self) { try ConfigLoader.validate(Data(#"{"sites":{}}"#.utf8)) }
}

@Test func lineBudgetIsTheSourceTimeoutButNeverUnderTenSeconds() {
    let budgets = [nil, 5, 10, 30, 0, -1].map { LiveSource(name: "a", url: "http://x", timeout: $0).lineBudget }
    #expect(budgets == [15, 10, 10, 30, 10, 10])
}

@Test func listHeadersPutTheNamedFieldsOverTheHeaderMap() {
    let source = LiveSource(name: "a", url: "http://x", ua: "U", origin: "O", referer: "R",
                            header: ["X": "1", "user-agent": "old"])
    #expect(source.listHeaders == ["X": "1", "User-Agent": "U", "Origin": "O", "Referer": "R"])
    #expect(LiveSource(name: "a", url: "http://x").listHeaders == [:])
}

private let realConfigPath = ProcessInfo.processInfo.environment["WANG_MOVIE_JSON"]

/// AC-1: adding `lives` and making `sites` optional must not change what the real configuration
/// decodes to. The expected value was computed on the code before this task (47c1d023).
@Test func realConfigDecodesToTheSameSitesAsBeforeLives() throws {
    guard let realConfigPath else { return }
    let config = try ConfigLoader.validate(Data(contentsOf: URL(fileURLWithPath: realConfigPath)))
    let sites = config.sites.map { "\($0.id)|\($0.jar)|\($0.type)" }.joined(separator: "\n")
    let digest = SHA256.hash(data: Data(sites.utf8)).map { String(format: "%02x", $0) }.joined()
    let fingerprint = "\(config.sites.count) \(digest) \(config.ads.count) \(config.rules.count) "
        + "\(config.parsing.parses.count) \(config.parsing.flags.count)"
    print("sites fingerprint: \(fingerprint)")
    #expect(fingerprint == "169 424a5aae3cb81bcae2a28e2bfdaedb1e2691d241ba0b8f389bddc49e51a43a57 1 10 19 0")
    // Every live in this configuration is a type-0 URL list, #20 included (it has a jar, no api).
    #expect(config.lives.count == 20)
}
