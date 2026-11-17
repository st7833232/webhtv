import Foundation
import Testing
@testable import WebHTVCore

/// W-311: FongMi's multi-depot configuration (docs/W-311-ios-multi-repo-config.md §2, §5).
@Suite struct DepotConfigTests {
    private let depot = URL(string: "https://repo.example/lists/depot.json")!

    private func entries(_ json: String, from url: URL? = URL(string: "https://repo.example/lists/depot.json")!) throws -> DepotConfig.Entries? {
        try DepotConfig.entries(Data(json.utf8), from: url)
    }

    @Test func aDepotListsItsAddressesResolvedAgainstItself() throws {
        let found = try #require(try entries("""
        {"urls":[{"name":"影視","url":"./wang-movie.json"},{"name":"","url":"../other/x.json"},
                 {"name":"遠端","url":" https://cdn.example/y.json "}]}
        """))
        #expect(found.sources.map(\.url.absoluteString) == ["https://repo.example/lists/wang-movie.json",
                                                             "https://repo.example/other/x.json", "https://cdn.example/y.json"])
        #expect(found.sources.map(\.name) == ["影視", "", "遠端"])
        #expect(found.skippedRelative == 0)
    }

    @Test func urlsWinOverSitesAndAPlainConfigurationIsNoDepot() throws {
        // FongMi checks `urls` before anything else; `sites` beside it is ignored.
        #expect(try entries(#"{"urls":[{"url":"https://a.example/1.json"}],"sites":[{"key":"x","api":"y","type":1}]}"#)?.sources.count == 1)
        #expect(try entries(#"{"sites":[{"key":"x","name":"x","api":"https://cms.example/api","type":1}]}"#) == nil)
        // A live channel's own `urls` is nested, not a top-level list.
        #expect(try entries(#"{"lives":[{"channels":[{"name":"a","urls":["https://x/1.m3u8"]}]}],"sites":[]}"#) == nil)
        #expect(try entries(#"{"urls":"https://a.example/1.json"}"#) == nil)
    }

    @Test func blankForeignAndRepeatedEntriesAreDroppedAndNothingLeftIsAnError() throws {
        let found = try #require(try entries("""
        {"urls":[{"url":""},{"url":"ftp://x.example/a.json"},{"url":"https://a.example/1.json"},
                 {"url":"https://a.example/1.json","name":"again"},{"name":"no url"},"text"]}
        """))
        #expect(found.sources.map(\.url.absoluteString) == ["https://a.example/1.json"])
        #expect(throws: ConfigLoaderError.emptyDepot) { try entries(#"{"urls":[]}"#) }
        #expect(throws: ConfigLoaderError.emptyDepot) { try entries(#"{"urls":[{"url":""}]}"#) }
    }

    @Test func aWrappedDepotIsReadAfterUnwrapping() throws {
        let plain = #"{"urls":[{"name":"A","url":"https://a.example/1.json"}]}"#
        let wrapped = "abcdEFGH**" + Data(plain.utf8).base64EncodedString()
        #expect(try entries(wrapped)?.sources.first?.url.absoluteString == "https://a.example/1.json")
        // Comments are allowed, as for any configuration.
        #expect(try entries("{ // depot\n \"urls\":[{\"url\":\"https://a.example/1.json\"}] }")?.sources.count == 1)
    }

    @Test func anImportedDepotCountsTheRelativeEntriesItCannotResolve() throws {
        let found = try #require(try entries(#"{"urls":[{"url":"./a.json"},{"url":"https://b.example/b.json"}]}"#, from: nil))
        #expect(found.sources.map(\.url.absoluteString) == ["https://b.example/b.json"])
        #expect(found.skippedRelative == 1)
        let none = try #require(try entries(#"{"urls":[{"url":"./a.json"}]}"#, from: nil))
        #expect(none.sources.isEmpty && none.skippedRelative == 1)
    }

    @Test func anImportedDepotIsKeyedByItsContent() {
        let one = DepotConfig.importedID(Data("a".utf8)), two = DepotConfig.importedID(Data("b".utf8))
        #expect(one != two && one.hasPrefix("imported:"))
        #expect(one == DepotConfig.importedID(Data("a".utf8)))
    }
}

/// W-311: how a depot's entries join the saved list (user, 2026-11-17).
@Suite struct SavedSourceDepotTests {
    private let own = SavedSource(name: "我的", url: URL(string: "https://own.example/a.json")!)
    private let shared = URL(string: "https://repo.example/wang-movie.json")!
    private let first = SavedSource.Depot(id: "https://repo.example/d1.json", url: URL(string: "https://repo.example/d1.json")!, name: "第一倉")
    private let second = SavedSource.Depot(id: "https://repo.example/d2.json", url: URL(string: "https://repo.example/d2.json")!, name: "第二倉")

    @Test func entriesJoinUnderTheirDepotAndTheDepotAddressItselfIsDropped() {
        var list = SavedSourceList(sources: [own, SavedSource(name: "typed", url: first.url!)])
        list.adopt([SavedSource(name: "影視", url: shared), SavedSource(name: "", url: URL(string: "https://repo.example/sex.json")!)],
                   into: first, replacing: first.url)
        #expect(list.sources.map(\.id) == [own.id, shared.absoluteString, "https://repo.example/sex.json"])
        // The name typed with the depot's address names the group.
        #expect(list.source(id: shared.absoluteString)?.depot?.name == "typed")
        #expect(list.source(id: shared.absoluteString)?.depot?.id == first.id)
        // Groups: depots first, then the sources added one by one.
        #expect(list.groups.map(\.id) == [first.id, ""])
        #expect(list.groups.last?.sources == [own])
    }

    @Test func oneAddressIsListedOnceAndTheLastDepotOwnsIt() {
        var list = SavedSourceList(sources: [SavedSource(name: "我改過的名字", url: shared)])
        list.adopt([SavedSource(name: "影視", url: shared)], into: first, replacing: nil)
        list.adopt([SavedSource(name: "別名", url: shared)], into: second, replacing: nil)
        #expect(list.sources.count == 1)
        #expect(list.sources[0].depot == second)
        #expect(list.sources[0].name == "我改過的名字")
    }

    @Test func renamingADepotRenamesItsWholeGroup() {
        var list = SavedSourceList()
        list.adopt([SavedSource(name: "", url: shared), SavedSource(name: "", url: URL(string: "https://repo.example/b.json")!)],
                   into: first, replacing: nil)
        list.renameDepot(id: first.id, to: "改名")
        #expect(list.sources.allSatisfy { $0.depot?.name == "改名" })
    }

    /// Reviewer #8759 F-1: a refresh (the depot address is no longer saved) or the same file imported again keeps the
    /// group's name — the one typed when it was added, or one it was renamed to — instead of falling back to the host.
    @Test func aRefreshOrReImportKeepsTheGroupName() {
        var list = SavedSourceList(sources: [SavedSource(name: "我的多倉", url: first.url!)])
        let added = list.adopt([SavedSource(name: "", url: shared)], into: SavedSource.Depot(id: first.id, url: first.url, name: "repo.example"),
                               replacing: first.url)
        #expect(added.name == "我的多倉")
        let refreshed = list.adopt([SavedSource(name: "", url: shared)], into: SavedSource.Depot(id: first.id, url: first.url, name: "repo.example"),
                                   replacing: first.url)
        #expect(refreshed.name == "我的多倉" && list.source(id: shared.absoluteString)?.depot?.name == "我的多倉")
        list.renameDepot(id: first.id, to: "改過的名字")
        list.adopt([SavedSource(name: "", url: shared), SavedSource(name: "", url: URL(string: "https://repo.example/new.json")!)],
                   into: SavedSource.Depot(id: first.id, url: first.url, name: "repo.example"), replacing: first.url)
        #expect(list.sources.allSatisfy { $0.depot?.name == "改過的名字" })
        // Typed again with a new name: that name wins, for the whole group.
        list.upsert(SavedSource(name: "新名字", url: first.url!))
        list.adopt([SavedSource(name: "", url: shared)], into: SavedSource.Depot(id: first.id, url: first.url, name: "repo.example"),
                   replacing: first.url)
        #expect(list.sources.allSatisfy { $0.depot?.name == "新名字" })
        // A new depot with nothing typed falls back to the caller's name.
        let fresh = list.adopt([SavedSource(name: "", url: URL(string: "https://x.example/a.json")!)],
                               into: SavedSource.Depot(id: "imported:abc", url: nil, name: "file"), replacing: nil)
        #expect(fresh.name == "file")
    }

    @Test func aListSavedBeforeDepotsDecodesUnchanged() throws {
        let old = #"{"sources":[{"name":"Recha","url":"https:\/\/gitlab.example\/a\/wang-movie.json"}]}"#
        let list = try JSONDecoder().decode(SavedSourceList.self, from: Data(old.utf8))
        #expect(list.sources.count == 1 && list.sources[0].depot == nil)
        var withDepot = list
        withDepot.adopt([SavedSource(name: "", url: shared)], into: first, replacing: nil)
        let back = try JSONDecoder().decode(SavedSourceList.self, from: JSONEncoder().encode(withDepot))
        #expect(back == withDepot)
    }
}
