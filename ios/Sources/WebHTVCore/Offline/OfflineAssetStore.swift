import Foundation

/// IOS-POC-47 — the offline records on disk: one `metadata.json` per asset folder, each written
/// atomically on its own, so one damaged record can never cost another asset.
///
/// **Conservative about what it cannot read.** A folder whose record does not decode (or comes from
/// a newer build) is listed as `unreadable` and left exactly as it is — its media may be complete,
/// and a single bad write must not delete it. The downloads screen offers to delete it; nothing
/// else does. A folder with no record at all is the trace of a crash between creating the folder
/// and the first write (the record is always written before any media), and is removed.
///
/// Owned by `OfflineDownloadManager` and only used inside it — a class rather than an actor of its
/// own, so a check and the write that follows it cannot be interleaved with another call (two taps
/// on 下載 must not both find "no asset yet"). The manager is also the one that cancels transfers
/// before a folder goes (`OfflineDownloadManager.delete`).
public final class OfflineAssetStore {
    public struct LoadReport: Equatable, Sendable {
        public var loaded = 0
        public var migrated = 0
        public var unreadable = [String]()
        public var removedOrphans = 0
        public var removedTemporaries = 0
    }

    public let layout: OfflineStorageLayout
    private var assets = [String: OfflineAsset]()
    /// Folder name → why it was not read. Kept, never removed automatically.
    public private(set) var unreadable = [String: String]()
    /// IOS-POC-52 (F2): records changed in memory whose write failed (a full disk).
    public private(set) var unwritten = Set<String>()
    private let fileManager = FileManager.default

    public init(layout: OfflineStorageLayout) {
        self.layout = layout
    }

    /// Reads every folder under the root. Safe to call again: it starts from the disk each time.
    @discardableResult
    public func load() -> LoadReport {
        var report = LoadReport()
        assets = [:]
        unreadable = [:]
        try? OfflineStorage.prepareDirectory(layout.root)
        let entries = (try? fileManager.contentsOfDirectory(atPath: layout.root.path)) ?? []
        for name in entries where !name.hasPrefix(".") {
            let folder = layout.root.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            report.removedTemporaries += OfflineStorage.removeStaleTemporaries(in: folder)
            let file = folder.appendingPathComponent(OfflineStorageLayout.metadataName)
            guard let data = try? Data(contentsOf: file) else {
                if !fileManager.fileExists(atPath: file.path), (try? fileManager.removeItem(at: folder)) != nil {
                    report.removedOrphans += 1
                } else {
                    unreadable[name] = "unreadable"
                    report.unreadable.append(name)
                }
                continue
            }
            do {
                switch try OfflineAssetMigration.decode(data) {
                case .current(let asset) where asset.id == name:
                    assets[name] = asset
                    report.loaded += 1
                case .migrated(let asset) where asset.id == name:
                    assets[name] = asset
                    try? write(asset)
                    report.loaded += 1
                    report.migrated += 1
                case .tooNew(let version):
                    unreadable[name] = "schema \(version)"
                    report.unreadable.append(name)
                default:
                    unreadable[name] = "id mismatch"
                    report.unreadable.append(name)
                }
            } catch {
                unreadable[name] = "decode"
                report.unreadable.append(name)
            }
        }
        report.unreadable.sort()
        return report
    }

    public func all() -> [OfflineAsset] {
        assets.values.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    public func asset(_ id: String) -> OfflineAsset? { assets[id] }

    public func asset(for identity: OfflineIdentity) -> OfflineAsset? {
        assets.values.first { $0.identity == identity && $0.state != .deleting }
    }

    /// Creates the folder (excluded from backup) on the first write, then writes the record.
    public func save(_ asset: OfflineAsset) throws {
        try OfflineStorage.prepareDirectory(layout.folder(for: asset.id))
        try write(asset)
        assets[asset.id] = asset
    }

    /// Changes one record in place and writes it. Nil when there is no such asset — a late
    /// callback for an asset already deleted changes nothing and creates nothing.
    ///
    /// IOS-POC-52 (F2): the change stands even when the write fails, as it does on a full disk. A
    /// state the disk cannot record must still move — a download left `downloading` with no
    /// transfer, or `preparing`, would stop the queue — so the record is kept as `unwritten` and
    /// goes to disk with its next write or `flushUnwritten()`. Until then the disk keeps the
    /// previous record, which a relaunch reconciles as it does after a crash.
    @discardableResult
    public func update(_ id: String, now: Date = .now, _ change: (inout OfflineAsset) -> Void) -> OfflineAsset? {
        guard var asset = assets[id] else { return nil }
        change(&asset)
        asset.updatedAt = now
        assets[id] = asset
        persist(asset)
        return asset
    }

    /// Writes again every record whose last write failed.
    public func flushUnwritten() {
        for id in unwritten {
            if let asset = assets[id] { persist(asset) } else { unwritten.remove(id) }
        }
    }

    private func persist(_ asset: OfflineAsset) {
        do {
            try write(asset)
            unwritten.remove(asset.id)
        } catch {
            unwritten.insert(asset.id)
        }
    }

    /// The in-memory record only: progress between writes, which the files on disk can rebuild.
    @discardableResult
    public func updateInMemory(_ id: String, _ change: (inout OfflineAsset) -> Void) -> OfflineAsset? {
        guard var asset = assets[id] else { return nil }
        change(&asset)
        assets[id] = asset
        return asset
    }

    public func flush(_ id: String) {
        guard let asset = assets[id] else { return }
        persist(asset)
    }

    private func write(_ asset: OfflineAsset) throws {
        let data = try JSONEncoder.offline.encode(asset)
        try OfflineStorage.writeAtomically(data, to: layout.metadataFile(for: asset.id))
    }

    // MARK: Plan and request

    public func plan(for id: String) -> OfflinePackagePlan? {
        guard let data = try? Data(contentsOf: layout.planFile(for: id)) else { return nil }
        return try? JSONDecoder.offline.decode(OfflinePackagePlan.self, from: data)
    }

    public func savePlan(_ plan: OfflinePackagePlan, for id: String) throws {
        try OfflineStorage.writeAtomically(JSONEncoder.offline.encode(plan), to: layout.planFile(for: id))
    }

    public func request(for id: String) -> OfflineDownloadRequest? {
        guard let data = try? Data(contentsOf: layout.requestFile(for: id)) else { return nil }
        return try? JSONDecoder.offline.decode(OfflineDownloadRequest.self, from: data)
    }

    public func saveRequest(_ request: OfflineDownloadRequest, for id: String) throws {
        try OfflineStorage.writeAtomically(JSONEncoder.offline.encode(request), to: layout.requestFile(for: id))
    }

    /// A finished download no longer needs its addresses or the source's headers.
    public func removeDownloadSecrets(for id: String) {
        try? fileManager.removeItem(at: layout.planFile(for: id))
        try? fileManager.removeItem(at: layout.requestFile(for: id))
        try? fileManager.removeItem(at: layout.folder(for: id).appendingPathComponent("partial"))
    }

    // MARK: Delete

    /// Removes an asset's folder — record, playlists, media, audio, subtitles, keys, partial data
    /// — and forgets it. Answers the bytes that folder occupied. Works for an unreadable folder too.
    @discardableResult
    func removeFolder(_ id: String) -> Int64 {
        let folder = layout.folder(for: id)
        let released = OfflineStorage.allocatedSize(of: folder)
        try? fileManager.removeItem(at: folder)
        let gone = !fileManager.fileExists(atPath: folder.path)
        if gone {
            assets[id] = nil
            unreadable[id] = nil
            unwritten.remove(id)
        }
        return gone ? released : 0
    }

    /// Everything under the offline root: what the downloads screen shows as used.
    public func usage() -> Int64 { OfflineStorage.allocatedSize(of: layout.root) }

    public func size(of id: String) -> Int64 { OfflineStorage.allocatedSize(of: layout.folder(for: id)) }
}
