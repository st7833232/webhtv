import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-48 A11 — `FavoriteStore`, `WatchHistoryStore` and `OfflineDownloadManager` are three
// owners. Each may read the others; each deletes only its own. One title is set up in all three
// (the offline fixture's title is `site\0{}@@@vod1`), then each delete is made and the other two
// are checked.

private let identity = FavoriteIdentity(configSourceID: "config", siteID: "site\u{0}{}", vodID: "vod1")

private func watched(_ episode: String = "第01集") -> WatchHistory {
    WatchHistory(key: identity.historyKey, siteKey: "site", siteName: "站", sourceID: "config", vodId: "vod1",
                 vodName: "片", vodFlag: "線路①", vodRemarks: episode, episodeUrl: "https://source.example/ep1",
                 position: 1_195_000, duration: 1_200_000)
}

private struct Owners {
    let favorites: FavoriteStore
    let history: WatchHistoryStore
    let offline: OfflineHarness
    let asset: OfflineAsset

    func favoriteKept() async -> Bool { await favorites.contains(identity) }
    func historyKept() async -> Bool { await history.record(forKey: identity.historyKey) != nil }
    func downloadKept() async -> Bool {
        await offline.manager.asset(asset.id)?.state == .completed && offline.folderExists(asset.id)
    }
}

private func owners(_ name: String, remarks: String = "全2集", autoDelete: Bool = false) async throws -> Owners {
    let (favorites, _) = FavoriteFixture.store(name)
    await favorites.add(identity, snapshot: FavoriteFixture.snapshot(remarks: remarks))
    let history = WatchHistoryStore(directory: FavoriteFixture.directory("\(name)-history"))
    await history.save(watched())
    let offline = OfflineHarness(network: Fixture.simpleNetwork())
    let (asset, _) = try await offline.startSimpleDownload(autoDelete: autoDelete)
    let completed = try #require(await offline.completeAll(asset.id))
    #expect(Fixture.identity().historyKey == identity.historyKey, "the fixture's download must be this title's")
    return Owners(favorites: favorites, history: history, offline: offline, asset: completed)
}

@Test func unfavoritingKeepsTheHistoryAndTheDownloads() async throws {
    let owners = try await owners("unfavorite")
    #expect(await owners.favorites.remove(identity) != nil)
    #expect(await owners.historyKept())
    #expect(await owners.downloadKept())
}

/// The rule IOS-POC-47 had the other way round: removing a title from the watch history used to
/// delete its downloads. The history store never could; the screen did, and no longer does
/// (`FavoriteAppWiringTests.deletingWatchHistoryNeverDeletesDownloads`).
@Test func clearingTheHistoryKeepsTheFavoriteAndTheDownloads() async throws {
    let owners = try await owners("clear-history")
    await owners.history.remove(key: identity.historyKey, for: "config")
    #expect(!(await owners.historyKept()))
    await owners.history.save(watched())
    await owners.history.clear(for: "config")
    #expect(!(await owners.historyKept()))
    #expect(await owners.favoriteKept())
    #expect(await owners.downloadKept())
}

@Test func deletingADownloadKeepsTheFavoriteAndTheHistory() async throws {
    let owners = try await owners("delete-download")
    await owners.offline.manager.delete([owners.asset.id])
    #expect(await owners.offline.manager.asset(owners.asset.id) == nil)
    #expect(await owners.favoriteKept())
    #expect(await owners.historyKept())
}

@Test func theWatchedAutoDeleteKeepsTheFavorite() async throws {
    let owners = try await owners("auto-delete", autoDelete: true)
    await owners.offline.manager.playbackEnded(owners.asset.id)
    #expect(await owners.offline.manager.playbackReleased(owners.asset.id))
    #expect(!owners.offline.folderExists(owners.asset.id))
    #expect(await owners.favoriteKept())
    #expect(await owners.historyKept())
}

@Test func anAutomaticUnfavoriteAndItsUndoTouchOnlyTheFavorite() async throws {
    let owners = try await owners("auto-unfavorite", remarks: "全2集")
    let final = watched("第2集")
    let offer = try #require(await FavoriteAutoRemoval.apply(record: final, ended: true, lines: nil,
                                                             store: owners.favorites))
    #expect(!(await owners.favoriteKept()))
    #expect(await owners.historyKept())
    #expect(await owners.downloadKept())

    #expect(await offer.undo(in: owners.favorites))
    #expect(await owners.favoriteKept())
    #expect(await owners.history.record(forKey: identity.historyKey)?.vodRemarks == "第01集")
    #expect(await owners.downloadKept())
}
