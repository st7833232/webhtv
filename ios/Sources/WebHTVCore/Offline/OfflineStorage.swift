import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// IOS-POC-47 — where offline media lives, and what the disk has room for.
///
/// **Not Caches, not the streaming cache.** Downloads the viewer asked to keep go under
/// `Application Support/OfflineMedia/<asset-id>/` — a directory iOS does not purge — and are
/// excluded from iCloud backup (Apple: "if your app downloads high-definition movies for offline
/// viewing, exclude those files"). Only transfers in flight live in the temporary directory, under
/// this feature's own `WebHTVOfflineDownloads/`, and launch cleans nothing outside it.
///
/// One asset's folder:
/// ```
/// OfflineMedia/<asset-id>/metadata.json        the record (OfflineAsset)
/// OfflineMedia/<asset-id>/download-plan.json   only while unfinished: addresses and headers
/// OfflineMedia/<asset-id>/playlists/…          the rewritten HLS playlists
/// OfflineMedia/<asset-id>/media/…              video segments, or the one progressive file
/// OfflineMedia/<asset-id>/audio/…              the chosen audio rendition
/// OfflineMedia/<asset-id>/subtitles/…          WebVTT segments and sidecar .srt files
/// OfflineMedia/<asset-id>/keys/…               clear AES-128 keys
/// OfflineMedia/<asset-id>/partial/…            resume data for an interrupted progressive file
/// ```
public struct OfflineStorageLayout: Sendable, Equatable {
    public static let directoryName = "OfflineMedia"
    public static let temporaryDirectoryName = "WebHTVOfflineDownloads"
    static let metadataName = "metadata.json"
    static let planName = "download-plan.json"
    static let requestName = "download-request.json"
    static let temporaryMarker = ".tmp-"

    public let root: URL
    public let temporaryRoot: URL

    public init(root: URL, temporaryRoot: URL) {
        self.root = root
        self.temporaryRoot = temporaryRoot
    }

    public static func standard(fileManager: FileManager = .default) -> OfflineStorageLayout {
        let support = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                            appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return OfflineStorageLayout(
            root: support.appendingPathComponent(directoryName, isDirectory: true),
            temporaryRoot: fileManager.temporaryDirectory.appendingPathComponent(temporaryDirectoryName, isDirectory: true))
    }

    public func folder(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func metadataFile(for id: String) -> URL { folder(for: id).appendingPathComponent(Self.metadataName) }
    func planFile(for id: String) -> URL { folder(for: id).appendingPathComponent(Self.planName) }
    func requestFile(for id: String) -> URL { folder(for: id).appendingPathComponent(Self.requestName) }
    func resumeDataFile(for id: String, unit: Int) -> URL {
        folder(for: id).appendingPathComponent("partial/unit-\(unit).resume")
    }
    /// Where the transport puts a finished transfer until the manager moves it into its asset.
    public var stagingDirectory: URL { temporaryRoot.appendingPathComponent("staging", isDirectory: true) }
}

public enum OfflineStorage {
    /// Never fill the device: room for the download plus the larger of this or a tenth of it.
    public static let reserveBytes: Int64 = 500_000_000
    /// Below this while downloading, the download stops as `insufficientStorage`.
    public static let minimumFreeWhileDownloading: Int64 = 200_000_000

    /// What has to be free before a download of `estimate` may start.
    public static func requiredBytes(estimate: Int64?) -> Int64 {
        let size = max(estimate ?? 0, 0)
        return size + max(reserveBytes, size / 10)
    }

    /// Whether a download fits. An unknown capacity does not block it; the check while
    /// downloading still stops it cleanly.
    public static func hasRoom(estimate: Int64?, available: Int64?) -> Bool {
        guard let available else { return true }
        return available >= requiredBytes(estimate: estimate)
    }

    /// What iOS says it can free for something the user asked for (`…ForImportantUsage`), which is
    /// also what Settings shows as available.
    public static func availableCapacity(at url: URL) -> Int64? {
        #if os(iOS) || os(macOS)
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        #endif
        let fallback = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return fallback?.volumeAvailableCapacity.map(Int64.init)
    }

    /// Creates the folder and marks it excluded from iCloud backup. Set again on every creation:
    /// Apple notes some file operations reset resource values.
    public static func prepareDirectory(_ url: URL, excludedFromBackup: Bool = true,
                                        fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        if excludedFromBackup { excludeFromBackup(url) }
    }

    public static func excludeFromBackup(_ url: URL) {
        #if canImport(Darwin)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
        #endif
    }

    public static func isExcludedFromBackup(_ url: URL) -> Bool {
        #if canImport(Darwin)
        return (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
        #else
        return false
        #endif
    }

    /// Bytes a file or folder really occupies (allocated blocks), which is what deleting it frees.
    public static func allocatedSize(of url: URL, fileManager: FileManager = .default) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue { return fileSize(url, keys: keys) }
        guard let walker = fileManager.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            total += fileSize(file, keys: keys)
        }
        return total
    }

    private static func fileSize(_ url: URL, keys: [URLResourceKey]) -> Int64 {
        let values = try? url.resourceValues(forKeys: Set(keys))
        let size = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? values?.fileSize ?? 0
        return Int64(size)
    }

    /// Writes beside the destination, then renames over it: `rename(2)` is atomic on one volume, so
    /// a crash leaves either the old file or the new one — never half of one. A leftover
    /// `.<name>.tmp-<uuid>` is the only trace, and launch removes those (`removeStaleTemporaries`).
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent)\(OfflineStorageLayout.temporaryMarker)\(UUID().uuidString)")
        try data.write(to: temporary)
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code))])
        }
    }

    /// Removes the half-written temporaries `writeAtomically` may leave in a folder, and nothing else.
    @discardableResult
    public static func removeStaleTemporaries(in folder: URL, fileManager: FileManager = .default) -> Int {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return 0 }
        var removed = 0
        for name in entries where name.hasPrefix(".") && name.contains(OfflineStorageLayout.temporaryMarker) {
            if (try? fileManager.removeItem(at: folder.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }

    /// Moves a finished transfer into place, replacing whatever an earlier attempt left there.
    public static func moveIntoPlace(_ source: URL, to destination: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: source, to: destination)
    }

    /// An error page saved as media: HTTP 200 with HTML is how a CDN says no.
    public static func looksLikeHTML(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 256)) ?? Data()
        let text = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.hasPrefix("<!doctype html") || text.hasPrefix("<html") || text.hasPrefix("<?xml")
            || text.hasPrefix("<head") || text.hasPrefix("<body")
    }

    /// Whether a file is out of space: the error a full disk gives on write or move.
    public static func isOutOfSpace(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return isOutOfSpace(underlying) }
        return false
    }
}
