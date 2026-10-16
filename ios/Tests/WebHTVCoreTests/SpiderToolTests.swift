import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-61 S3 (W-121): what the settings page says after a check, and which sites the 爬蟲工具 banner counts.

private func config(_ sites: String) throws -> WebHTVConfig {
    try ConfigLoader.decode(Data(#"{"sites":[\#(sites)]}"#.utf8))
}

private let cms = #"{"key":"cms","name":"CMS","type":1,"api":"https://example.com/api"}"#
private let ported = #"{"key":"app","name":"App","type":3,"api":"csp_AppGet"}"#
private let unported = #"{"key":"no","name":"No","type":3,"api":"csp_NeverPorted"}"#
private let drpy = #"{"key":"js","name":"Js","type":3,"api":"https://example.com/drpy2.min.js","ext":"https://example.com/a.js"}"#
private let python = #"{"key":"py","name":"Py","type":3,"api":"https://example.com/a.py"}"#

/// The N+1 state: nothing bundled, no pack yet.
private let nothingInstalled = CSPSourceResolver(registry: SpiderRegistry(entries: [:], prelude: ""),
                                                 source: .remote(URL(string: "https://example.com/c.json")!))

@Suite struct SpiderToolTests {
    // Plan §2.4, one row each. "Needs a newer App" must never read as "already up to date" (IOS-POC-12 R24).
    @Test func everyOutcomeHasItsOwnSentence() {
        func text(_ outcome: RuntimePackUpdater.Outcome, playing: Bool = false) -> String {
            SpiderToolText.result(of: outcome, scripts: 33, playing: playing)
        }
        #expect(text(.installed(version: "2026-10-20.1", needsNewerApp: [])) == "已更新到 2026-10-20.1（33 支）")
        #expect(text(.upToDate) == "已是最新版本")
        #expect(text(.unreachable("offline")) == "無法連線，繼續使用目前的版本")
        #expect(text(.failed("HTTP 503")) == "下載沒有完成，繼續使用目前的版本")
        #expect(text(.rejected(.digestMismatch("spiders/AppGet.js"))) == "更新包驗證失敗，沒有採用，繼續使用目前的版本")
        #expect(text(.rejected(.sequenceReused(12))) == "更新包驗證失敗，沒有採用，繼續使用目前的版本")
        #expect(text(.rejected(.knownBad("gen-12-x"))) == "更新包驗證失敗，沒有採用，繼續使用目前的版本")
        #expect(text(.rejected(.rollback(sequence: 3, floor: 12))) == "伺服器版本比目前的舊，已忽略")
        #expect(text(.installed(version: "v2", needsNewerApp: ["Gulu", "Uvod"]))
                == "已更新；其中 2 支需要較新的 App，暫時沿用目前版本：Gulu、Uvod")
        let tooOld = text(.rejected(.abiTooNew(surface: "js.host", requiredMinor: 9, installed: 5)))
        #expect(tooOld == "這個版本需要較新的 App，請到 SideStore 更新")
        #expect(tooOld != text(.upToDate))
        #expect(text(.installed(version: "v2", needsNewerApp: []), playing: true) == "已下載，關閉播放器後套用")
    }

    @Test func theStatusLineNamesWhatRuns() {
        // S5: nothing bundled, so no generation is 未安裝, and a generation the N version seeded is an official pack.
        #expect(SpiderToolText.status(of: nil) == "未安裝")
        let generation = RuntimeGeneration(sequence: 12, manifestSHA256: "a", contentIdentity: "b")
        let pack = OfficialSpiderPack(generation: generation, version: "2026-10-20.1",
                                      scripts: ["AppGet": "", "Bili": ""], aliases: ["Jys": "AppGet"])
        #expect(SpiderToolText.status(of: pack) == "官方包 2026-10-20.1（序號 12，2 支）")
    }

    // Plan §2.4: with nothing installed there is no version to keep using.
    @Test func nothingInstalledHasNoVersionToKeep() {
        func text(_ outcome: RuntimePackUpdater.Outcome) -> String { SpiderToolText.result(of: outcome, scripts: 0, playing: false) }
        #expect(text(.unreachable("offline")) == "無法連線，請稍後再試")
        #expect(text(.failed("HTTP 503")) == "下載沒有完成，請稍後再試")
        #expect(text(.rejected(.digestMismatch("spiders/AppGet.js"))) == "更新包驗證失敗，沒有採用，請稍後再試")
    }

    // W-138: most configurations publish no compatibility pack, so their 404 is the normal answer and shows no row;
    // a pack that was installed, or any other failure, still says what went wrong.
    @Test func theCompatibilityRowHidesOnlyAConfigurationWithoutAPack() {
        #expect(SpiderToolText.compatibilityRow(failure: SpiderPackError.invalidHTTPStatus(404), installed: nil) == "")
        #expect(SpiderToolText.compatibilityRow(failure: SpiderPackError.invalidHTTPStatus(404), installed: "相容性套件 v1，3 支腳本")
                == "相容性套件 v1，3 支腳本（更新失敗：相容性套件回應 HTTP 404。）")
        #expect(SpiderToolText.compatibilityRow(failure: SpiderPackError.invalidHTTPStatus(503), installed: nil)
                == "沒有（更新失敗：相容性套件回應 HTTP 503。）")
        #expect(SpiderToolText.compatibilityRow(failure: SpiderPackError.malformedManifest, installed: nil)
                == "沒有（更新失敗：相容性套件的 manifest 無法解析。）")
    }

    // The banner counts only what the 爬蟲工具 could bring: a class the pack provides that does not run today.
    @Test func onlyAProvidableClassThatDoesNotRunCountsAsNeedingTheTool() throws {
        let mixed = try config([cms, ported, unported, drpy, python].joined(separator: ","))
        // Everything providable runs (the tool installed; the repository scripts stand in), so there is no banner.
        #expect(mixed.sitesNeedingSpiderTool(resolvedBy: CSPSourceResolver(registry: .bundled(bundle: .repoSpiders))).isEmpty)
        // N+1 before a download: only the ported class counts, never an unported one, drpy or Python.
        #expect(mixed.sitesNeedingSpiderTool(resolvedBy: nothingInstalled).map(\.key) == ["app"])
        // An alias counts as the class it is.
        let alias = try config(#"{"key":"jys","name":"Jys","type":3,"api":"csp_Jys"}"#)
        #expect(alias.sitesNeedingSpiderTool(resolvedBy: nothingInstalled).map(\.key) == ["jys"])
    }

    // Manager #2112 ①: a configuration whose sites only wait for the tool loads (and shows the banner); one with
    // nothing this App could ever run is still refused, so a useless payload never replaces a cache.
    @Test func aConfigurationThatOnlyWaitsForTheToolStillLoads() throws {
        let waiting = Data(#"{"sites":[\#(ported)]}"#.utf8)
        #expect(try ConfigLoader.validate(waiting, resolvedBy: nothingInstalled).sites.count == 1)
        let useless = Data(#"{"sites":[\#(unported)]}"#.utf8)
        #expect(throws: ConfigLoaderError.noSupportedSites) { try ConfigLoader.validate(useless, resolvedBy: nothingInstalled) }
        #expect(throws: ConfigLoaderError.noSupportedSites) { try ConfigLoader.validate(useless) }
    }
}
