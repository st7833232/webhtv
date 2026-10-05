import Foundation

/// IOS-POC-53 — 設定 › 儲存空間: what 清除無效檔案 may remove, and what 初始化 clears.
///
/// **清除無效檔案 keeps everything the app still uses** — saved sources, the watch history,
/// favourites, settings, every offline download (finished or not), the spider caches, the site
/// health record and the web login data — and lists the rest for the viewer to confirm: what an
/// older build or an interrupted write left behind. A name this build does not write is listed,
/// never removed unseen; the screen shows every item before anything goes.
public struct StorageCleanupItem: Identifiable, Hashable, Sendable {
    public enum Reason: String, Sendable, CaseIterable {
        /// A configuration cached for a source that is no longer saved or in use.
        case removedSourceCache
        /// Half-written files and staging folders an interrupted write left.
        case interruptedWrite
        /// Temporary files nothing is using any more.
        case staleTemporary
        /// What an unfinished download left: partial files, staged bodies, addresses kept after it
        /// finished.
        case downloadLeftover
        /// A name this build never writes.
        case unknown
    }

    public var id: String { url.path }
    public let url: URL
    public let bytes: Int64
    public let reason: Reason

    public init(url: URL, bytes: Int64, reason: Reason) {
        self.url = url
        self.bytes = bytes
        self.reason = reason
    }
}

/// The app's own folders.
public struct StorageLocations: Sendable {
    public var applicationSupport: URL
    public var caches: URL
    public var temporary: URL
    public var documents: URL

    public init(applicationSupport: URL, caches: URL, temporary: URL, documents: URL) {
        self.applicationSupport = applicationSupport
        self.caches = caches
        self.temporary = temporary
        self.documents = documents
    }

    public static func standard(fileManager: FileManager = .default) -> StorageLocations {
        func folder(_ directory: FileManager.SearchPathDirectory) -> URL {
            fileManager.urls(for: directory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        }
        return StorageLocations(applicationSupport: folder(.applicationSupportDirectory), caches: folder(.cachesDirectory),
                                temporary: fileManager.temporaryDirectory, documents: folder(.documentDirectory))
    }
}

public enum StorageMaintenance {
    /// Application Support entries this build writes: saved sources, the watch history,
    /// favourites, offline downloads, the site health record, the spider pack, the imported
    /// configuration. Remote sources' cached configurations are kept by name (`keepConfigFiles`).
    static let supportKeep: Set<String> = ["saved-sources.json", "WatchHistory", "Favorites", "OfflineMedia",
                                           "site-health.json", "SpiderPack", "wang-movie.json"]
    /// Caches entries kept: the spider caches (rebuildable, kept by the viewer's choice), the
    /// system's own folders, WebKit's.
    static let cachesKeep: Set<String> = ["python-spider", "WebKit", "Snapshots"]
    /// Caches entries that are only ever leftovers.
    static let cachesLeftovers: Set<String> = ["python-selfcheck-cache"]
    /// The background download session's own folder under Caches.
    static let backgroundSessionFolder = "com.apple.nsurlsessiond"
    /// A temporary entry younger than this may still be in use.
    static let temporaryGrace: TimeInterval = 10 * 60

    /// What 清除無效檔案 would remove, outside the offline downloads (whose leftovers
    /// `OfflineDownloadManager.invalidFiles()` lists).
    ///
    /// - `keepConfigFiles`: cached configuration files of the saved sources and the one in use.
    /// - `downloadsIdle`: no download is unfinished. Only then are the download session's partial
    ///   files leftovers — a paused or failed one resumes from them.
    ///
    /// The online subtitles' session folders are not listed: a player may still hold one, and
    /// every launch clears them (`SubtitleSessionCache.removeStaleSessions`).
    public static func invalidItems(in locations: StorageLocations, keepConfigFiles: Set<String>, bundleIdentifier: String,
                                    downloadsIdle: Bool, now: Date = .now,
                                    fileManager: FileManager = .default) -> [StorageCleanupItem] {
        var items = [StorageCleanupItem]()
        func add(_ url: URL, _ reason: StorageCleanupItem.Reason) {
            items.append(StorageCleanupItem(url: url, bytes: OfflineStorage.allocatedSize(of: url, fileManager: fileManager),
                                            reason: reason))
        }

        for (name, url) in entries(of: locations.applicationSupport, includingHidden: true, fileManager: fileManager) {
            if supportKeep.contains(name) || keepConfigFiles.contains(name) { continue }
            // A hidden name is the system's or a half-written file: only the latter is listed —
            // this app's atomic writes (`.name.tmp-…`) and Foundation's (`.dat.nosync…`).
            if name.hasPrefix(".") {
                if name.contains(OfflineStorageLayout.temporaryMarker) || name.hasPrefix(".dat.nosync") { add(url, .interruptedWrite) }
                continue
            }
            if name.hasPrefix("SpiderPack-staging-") {
                add(url, .interruptedWrite)
            } else if isConfigCacheName(name) {
                add(url, .removedSourceCache)
            } else {
                add(url, .unknown)
            }
        }

        for (name, url) in entries(of: locations.caches, fileManager: fileManager) {
            if name == backgroundSessionFolder {
                if downloadsIdle {
                    for (_, file) in deepFiles(of: url, fileManager: fileManager) { add(file, .downloadLeftover) }
                }
                continue
            }
            if cachesKeep.contains(name) || name == bundleIdentifier || name.hasPrefix("com.apple.") { continue }
            add(url, cachesLeftovers.contains(name) ? .staleTemporary : .unknown)
        }

        for (name, url) in entries(of: locations.temporary, fileManager: fileManager) {
            if name == OfflineStorageLayout.temporaryDirectoryName || name == SubtitleSessionCache.directoryName { continue }
            if name.hasPrefix("CFNetworkDownload_") {
                if downloadsIdle { add(url, .downloadLeftover) }
                continue
            }
            if let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               now.timeIntervalSince(modified) < temporaryGrace { continue }
            add(url, .staleTemporary)
        }

        // This build keeps nothing in Documents and does not share it with the Files app.
        for (_, url) in entries(of: locations.documents, fileManager: fileManager) { add(url, .unknown) }
        return items
    }

    /// Removes what the viewer confirmed. Answers the bytes the removed items occupied.
    @discardableResult
    public static func remove(_ items: [StorageCleanupItem], fileManager: FileManager = .default) -> Int64 {
        items.reduce(0) { total, item in
            (try? fileManager.removeItem(at: item.url)) != nil ? total + item.bytes : total
        }
    }

    /// 初始化: everything inside the app's own folders goes, leaving the folders as a fresh
    /// install has them. Answers the bytes freed. Settings, web data, cookies and the Keychain are
    /// the app's to clear through their own interfaces.
    @discardableResult
    public static func clearAll(_ locations: StorageLocations, fileManager: FileManager = .default) -> Int64 {
        var freed: Int64 = 0
        for root in [locations.applicationSupport, locations.caches, locations.temporary, locations.documents] {
            for (_, url) in entries(of: root, includingHidden: true, fileManager: fileManager) {
                let bytes = OfflineStorage.allocatedSize(of: url, fileManager: fileManager)
                if (try? fileManager.removeItem(at: url)) != nil { freed += bytes }
            }
        }
        return freed
    }

    /// `SavedSource.cacheFileName`: base64url of the address, then `.json`.
    static func isConfigCacheName(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        let stem = name.dropLast(".json".count)
        guard stem.count >= 8 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return stem.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func entries(of folder: URL, includingHidden: Bool = false,
                                fileManager: FileManager) -> [(String, URL)] {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { includingHidden || !$0.hasPrefix(".") }.sorted()
            .map { ($0, folder.appendingPathComponent($0)) }
    }

    private static func deepFiles(of folder: URL, fileManager: FileManager) -> [(String, URL)] {
        guard let walker = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var files = [(String, URL)]()
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            files.append((url.lastPathComponent, url))
        }
        return files
    }
}
