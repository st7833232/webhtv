import Foundation
import Testing
@testable import WebHTVCore

@Suite struct SavedSourceTests {
    private let a = SavedSource(name: "Recha", url: URL(string: "https://gitlab.example/a/wang-movie.json")!)
    private let b = SavedSource(name: "備用", url: URL(string: "https://other.example/b.json")!)

    @Test func identityIsTheAddressSoRenamingIsNotDuplicating() {
        var list = SavedSourceList()
        list.upsert(a)
        list.upsert(SavedSource(name: "改個名字", url: a.url))
        #expect(list.sources.count == 1)
        #expect(list.sources[0].name == "改個名字")
    }

    @Test func eachSourceCachesUnderItsOwnName() {
        #expect(a.cacheFileName != b.cacheFileName)
        #expect(a.cacheFileName.hasSuffix(".json"))
        // Filesystem-safe: base64url leaves no slash to be read as a directory separator.
        #expect(!a.cacheFileName.contains("/"))
        #expect(!a.cacheFileName.contains("+"))
        #expect(!a.cacheFileName.contains("="))
    }

    @Test func theCacheNameIsStableAcrossRuns() {
        #expect(a.cacheFileName == SavedSource(name: "different name", url: a.url).cacheFileName)
    }

    @Test func onlyFetchableAddressesAreKept() {
        var list = SavedSourceList()
        list.upsert(SavedSource(name: "file", url: URL(string: "file:///tmp/x.json")!))
        list.upsert(SavedSource(name: "ftp", url: URL(string: "ftp://x.example/a.json")!))
        #expect(list.sources.isEmpty)
        list.upsert(SavedSource(name: "ok", url: URL(string: "http://x.example/a.json")!))
        #expect(list.sources.count == 1)
    }

    @Test func aBlankNameFallsBackToTheHostRatherThanAnEmptyRow() {
        #expect(SavedSource(name: "   ", url: a.url).displayName == "gitlab.example")
    }

    @Test func removingAndLookingUpGoByTheSameIdentity() {
        var list = SavedSourceList(sources: [a, b])
        #expect(list.source(id: b.id)?.name == "備用")
        list.remove(id: a.id)
        #expect(list.sources.map(\.id) == [b.id])
        #expect(list.source(id: nil) == nil)
    }

    @Test func theListRoundTripsThroughJSON() throws {
        let list = SavedSourceList(sources: [a, b])
        let data = try JSONEncoder().encode(list)
        #expect(try JSONDecoder().decode(SavedSourceList.self, from: data) == list)
    }
}
