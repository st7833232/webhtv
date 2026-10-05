import Foundation
import Testing
@testable import WebHTVCore

/// IOS-POC-53: 清除無效檔案 must never take what the app still uses — saved sources, history,
/// favourites, downloads, caches the viewer chose to keep — and 初始化 must leave nothing behind.
struct StorageMaintenanceTests {
    static let bundle = "com.example.webhtv"
    static let savedURL = URL(string: "https://example.invalid/repo/wang-movie.json")!
    static let removedURL = URL(string: "https://example.invalid/old/config.json")!

    private func scratch() throws -> StorageLocations {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("storage-\(UUID().uuidString)")
        let locations = StorageLocations(applicationSupport: base.appendingPathComponent("Support"),
                                         caches: base.appendingPathComponent("Caches"),
                                         temporary: base.appendingPathComponent("tmp"),
                                         documents: base.appendingPathComponent("Documents"))
        for folder in [locations.applicationSupport, locations.caches, locations.temporary, locations.documents] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return locations
    }

    private func make(_ url: URL, bytes: Int = 10, age: TimeInterval = 0) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        if age > 0 {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
        }
    }

    /// Everything an install of this build has, plus what older builds and interrupted runs left.
    private func populate(_ locations: StorageLocations) throws -> (kept: [URL], leftovers: [URL], busy: [URL]) {
        let support = locations.applicationSupport, caches = locations.caches, tmp = locations.temporary
        let kept = [
            support.appendingPathComponent("saved-sources.json"),
            support.appendingPathComponent("WatchHistory/history.json"),
            support.appendingPathComponent("Favorites/favorites.json"),
            support.appendingPathComponent("OfflineMedia/asset/metadata.json"),
            support.appendingPathComponent("site-health.json"),
            support.appendingPathComponent("SpiderPack/manifest.json"),
            support.appendingPathComponent("wang-movie.json"),
            support.appendingPathComponent(SavedSource(name: "", url: Self.savedURL).cacheFileName),
            caches.appendingPathComponent("python-spider/site.json"),
            caches.appendingPathComponent("\(Self.bundle)/Cache.db"),
            caches.appendingPathComponent("WebKit/data"),
            tmp.appendingPathComponent("\(OfflineStorageLayout.temporaryDirectoryName)/staging/x.part"),
            tmp.appendingPathComponent("\(SubtitleSessionCache.directoryName)/session-1/a.srt"),
        ]
        let leftovers = [
            support.appendingPathComponent(SavedSource(name: "", url: Self.removedURL).cacheFileName),
            support.appendingPathComponent("SpiderPack-staging-1234"),
            support.appendingPathComponent(".saved-sources.json.tmp-5678"),
            support.appendingPathComponent("old-feature.plist"),
            caches.appendingPathComponent("python-selfcheck-cache"),
            caches.appendingPathComponent("OldImageCache"),
            tmp.appendingPathComponent("old.tmp"),
            locations.documents.appendingPathComponent("Inbox"),
        ]
        // Partial files a paused download may still resume from, and a temporary file in use.
        let busy = [
            caches.appendingPathComponent("com.apple.nsurlsessiond/Downloads/\(Self.bundle)/CFNetworkDownload_a.tmp"),
            tmp.appendingPathComponent("CFNetworkDownload_b.tmp"),
        ]
        for url in kept + busy { try make(url) }
        for url in leftovers {
            if ["SpiderPack-staging-1234", "python-selfcheck-cache", "OldImageCache", "Inbox"].contains(url.lastPathComponent) {
                try make(url.appendingPathComponent("inner"))
            } else {
                try make(url, age: url.lastPathComponent == "old.tmp" ? 3_600 : 0)
            }
        }
        try make(tmp.appendingPathComponent("fresh.tmp"))
        return (kept, leftovers, busy)
    }

    private var keepConfig: Set<String> { [SavedSource(name: "", url: Self.savedURL).cacheFileName] }

    @Test func cleanupListsOnlyLeftoversAndKeepsWhatTheAppUses() throws {
        let locations = try scratch()
        let (kept, leftovers, busy) = try populate(locations)

        let items = StorageMaintenance.invalidItems(in: locations, keepConfigFiles: keepConfig, bundleIdentifier: Self.bundle,
                                                    downloadsIdle: false)
        #expect(Set(items.map(\.url.standardizedFileURL.path)) == Set(leftovers.map(\.standardizedFileURL.path)))
        #expect(items.first { $0.url.lastPathComponent == SavedSource(name: "", url: Self.removedURL).cacheFileName }?.reason
                == .removedSourceCache)

        let freed = StorageMaintenance.remove(items)
        #expect(freed > 0)
        for url in kept + busy { #expect(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) must stay") }
        for url in leftovers { #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) must go") }
        #expect(FileManager.default.fileExists(atPath: locations.temporary.appendingPathComponent("fresh.tmp").path))
    }

    // The download session's partial files are leftovers only when no download is unfinished.
    @Test func partialDownloadFilesGoOnlyWhenNoDownloadIsUnfinished() throws {
        let locations = try scratch()
        let (_, leftovers, busy) = try populate(locations)
        let items = StorageMaintenance.invalidItems(in: locations, keepConfigFiles: keepConfig, bundleIdentifier: Self.bundle,
                                                    downloadsIdle: true)
        #expect(Set(items.map(\.url.standardizedFileURL.path)) == Set((leftovers + busy).map(\.standardizedFileURL.path)))
    }

    // 初始化: nothing a fresh install would not have, hidden files included; the folders stay.
    @Test func resetLeavesTheAppsFoldersEmpty() throws {
        let locations = try scratch()
        _ = try populate(locations)
        try make(locations.applicationSupport.appendingPathComponent(".hidden"))

        #expect(StorageMaintenance.clearAll(locations) > 0)
        for folder in [locations.applicationSupport, locations.caches, locations.temporary, locations.documents] {
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        }
    }

    // Inside the offline folders: a folder with no record, half-written files, a finished
    // download's addresses, a staged body nothing will claim — never a download.
    @Test func offlineLeftoversNeverIncludeADownload() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (running, requests) = await harness.startSimpleDownload(identity: Fixture.identity("ep1"))
        try #require(requests.count == 4)
        let (done, _) = await harness.startSimpleDownload(identity: Fixture.identity("ep2"))
        #expect(await harness.completeAll(done.id)?.state == .completed)
        let root = harness.layout.root
        let orphan = root.appendingPathComponent(UUID().uuidString)
        try make(orphan.appendingPathComponent("media/v00001.ts"))
        let halfWritten = harness.layout.folder(for: running.id).appendingPathComponent("playlists/.index.m3u8.tmp-1")
        try make(halfWritten)
        let leftoverPlan = harness.layout.planFile(for: done.id)
        try make(leftoverPlan)
        let staleBody = harness.layout.stagingDirectory.appendingPathComponent(
            OfflineStagedBody.name(tag: OfflineTransferTag(assetID: UUID().uuidString, generation: 0, unit: 0), status: 200))
        let liveBody = harness.layout.stagingDirectory.appendingPathComponent(OfflineStagedBody.name(tag: requests[1].tag, status: 200))
        try make(staleBody)
        try make(liveBody)

        let items = await harness.manager.invalidFiles()
        #expect(Set(items.map(\.url.standardizedFileURL.path))
                == Set([orphan, halfWritten, leftoverPlan, staleBody].map(\.standardizedFileURL.path)))
        StorageMaintenance.remove(items)
        #expect(harness.folderExists(running.id) && harness.folderExists(done.id))
        #expect(FileManager.default.fileExists(atPath: liveBody.path))
        #expect(await harness.manager.hasUnfinishedDownloads())
    }

    @Test func resetDeletesEveryDownloadThroughTheDeletePath() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (running, _) = await harness.startSimpleDownload(identity: Fixture.identity("ep1"))
        let result = await harness.manager.deleteEverything()
        #expect(result.deleted == 1)
        #expect(!harness.folderExists(running.id))
        #expect(await harness.transport.cancelled.contains(running.id))
        #expect(await harness.manager.snapshot().assets.isEmpty)
    }
}
