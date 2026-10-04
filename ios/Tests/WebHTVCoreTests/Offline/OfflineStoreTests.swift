import Foundation
import Testing
@testable import WebHTVCore

/// IOS-POC-47: the records on disk. A download the viewer kept must survive a crash, a bad write
/// and a newer build's record — losing the record would hide files nobody could then delete.
struct OfflineStoreTests {
    private func asset(_ id: String = UUID().uuidString, state: OfflineAssetState = .completed) -> OfflineAsset {
        var asset = OfflineAsset(id: id, identity: Fixture.identity(id), title: Fixture.title(), mode: .smart,
                                 autoDeleteAfterWatching: true, allowsCellular: false)
        asset.state = state
        asset.package = .progressive(relativePath: "media/video.mp4")
        return asset
    }

    // 32. A crash in the middle of a write leaves the previous record readable.
    @Test func anInterruptedWriteLeavesThePreviousRecord() throws {
        let layout = OfflineHarness.scratchLayout()
        let store = OfflineAssetStore(layout: layout)
        let saved = asset()
        try store.save(saved)
        // What a crash between writing the temporary and renaming it leaves behind.
        let leftover = layout.folder(for: saved.id).appendingPathComponent(".metadata.json.tmp-\(UUID().uuidString)")
        try Data("{\"schemaVersion\":1,\"id\":".utf8).write(to: leftover)

        let reloaded = OfflineAssetStore(layout: layout)
        let report = reloaded.load()
        #expect(report.loaded == 1)
        #expect(report.removedTemporaries == 1)
        #expect(reloaded.asset(saved.id) == saved)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    // A record that does not decode keeps its folder — and its media — untouched.
    @Test func anUnreadableRecordNeverCostsItsMedia() throws {
        let layout = OfflineHarness.scratchLayout()
        let id = UUID().uuidString
        let folder = layout.folder(for: id)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("media"), withIntermediateDirectories: true)
        try Fixture.segment().write(to: folder.appendingPathComponent("media/video.mp4"))
        try Data("not json".utf8).write(to: folder.appendingPathComponent("metadata.json"))
        let store = OfflineAssetStore(layout: layout)
        let report = store.load()
        #expect(report.unreadable == [id])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("media/video.mp4").path))
    }

    @Test func aRecordFromANewerBuildIsKeptNotGuessed() throws {
        let layout = OfflineHarness.scratchLayout()
        var newer = asset()
        newer.schemaVersion = OfflineAsset.currentSchemaVersion + 1
        let store = OfflineAssetStore(layout: layout)
        try store.save(newer)
        let reloaded = OfflineAssetStore(layout: layout)
        #expect(reloaded.load().unreadable == [newer.id])
        #expect(FileManager.default.fileExists(atPath: layout.folder(for: newer.id).path))
    }

    @Test func aFieldAddedLaterDoesNotMakeAnOldRecordUnreadable() throws {
        let saved = asset()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder.offline.encode(saved)) as! [String: Any]
        json["pendingAutoDelete"] = nil
        json["allowsCellular"] = nil
        json["schemaVersion"] = nil
        let data = try JSONSerialization.data(withJSONObject: json)
        guard case .current(let decoded) = try OfflineAssetMigration.decode(data) else {
            Issue.record("not current")
            return
        }
        #expect(decoded.id == saved.id)
        #expect(decoded.pendingAutoDelete == false)
    }

    // A folder with no record is a crash before the first write (records come before media): removed.
    @Test func aFolderWithoutARecordIsAnOrphan() throws {
        let layout = OfflineHarness.scratchLayout()
        let orphan = layout.folder(for: UUID().uuidString)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        let report = OfflineAssetStore(layout: layout).load()
        #expect(report.removedOrphans == 1)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    // 33. Launch cleans this feature's own leftovers and nothing else in the temporary directory.
    @Test func launchCleansOnlyItsOwnStagingFiles() async throws {
        let harness = OfflineHarness()
        let manager = FileManager.default
        try manager.createDirectory(at: harness.layout.stagingDirectory, withIntermediateDirectories: true)
        let stale = harness.layout.stagingDirectory.appendingPathComponent("\(UUID().uuidString)|0|3.\(UUID().uuidString).part")
        try Data("x".utf8).write(to: stale)
        let neighbour = harness.layout.temporaryRoot.deletingLastPathComponent().appendingPathComponent("someone-else.tmp")
        try Data("keep".utf8).write(to: neighbour)
        await harness.manager.start()
        #expect(!manager.fileExists(atPath: stale.path))
        #expect(manager.fileExists(atPath: neighbour.path))
    }

    // 34. Offline media is excluded from iCloud backup (only Apple platforms have the flag).
    @Test func offlineFoldersAreExcludedFromBackup() throws {
        #if canImport(Darwin)
        let layout = OfflineHarness.scratchLayout()
        let store = OfflineAssetStore(layout: layout)
        let saved = asset()
        try store.save(saved)
        #expect(OfflineStorage.isExcludedFromBackup(layout.folder(for: saved.id)))
        #endif
    }

    @Test func diskSpaceRuleKeepsAMargin() {
        #expect(OfflineStorage.requiredBytes(estimate: 1_000_000_000) == 1_500_000_000)
        #expect(OfflineStorage.requiredBytes(estimate: 10_000_000_000) == 11_000_000_000)
        #expect(!OfflineStorage.hasRoom(estimate: 1_000_000_000, available: 1_200_000_000))
        #expect(OfflineStorage.hasRoom(estimate: 1_000_000_000, available: 2_000_000_000))
    }
}
