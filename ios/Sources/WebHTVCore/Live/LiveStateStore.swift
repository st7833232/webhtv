import Foundation

/// IOS-POC-59 U4 (D§6.5): where a live source was last watched, and its favourite channels — per configuration
/// (`ConfigSource.identity`) and live source name, in `Application Support/LiveTV/live-state.json`.
///
/// No address is stored (X-10): a channel is found again by its group and name, a line by its label or index.
/// A favourite is a channel name within one configuration's one live source (X-9). Failures cost live only, as
/// `FavoriteStore` does it: a file that is not this format is moved aside (`live-state.corrupt-….json`) and a new
/// one started; a newer schema's file is copied aside once and read as empty; a file that cannot be read now, or
/// moved aside, loads nothing and writes nothing.
public actor LiveStateStore {
    public static let shared = LiveStateStore()
    public static let currentSchemaVersion = 1
    static let fileName = "live-state.json"

    struct Config: Codable, Equatable {
        var lastLive: String?
        var last: [String: LiveLastChannel] = [:]
        var favorites: [String: [String]] = [:]
    }

    struct File: Codable {
        var schemaVersion: Int
        var configs: [String: Config]
    }

    private let directory: URL
    private var file: URL { directory.appendingPathComponent(Self.fileName) }
    /// Nil until a load succeeds.
    private var configs: [String: Config]?
    /// What the last load moved or copied aside.
    public private(set) var setAside: String?
    public private(set) var backedUp: String?

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("LiveTV", isDirectory: true)
    }

    // MARK: Reading

    public func lastLive(config: String) -> String? { loaded()?[config]?.lastLive }

    public func last(config: String, live: String) -> LiveLastChannel? { loaded()?[config]?.last[live] }

    /// In the order they were favourited.
    public func favorites(config: String, live: String) -> [String] { loaded()?[config]?.favorites[live] ?? [] }

    // MARK: Writing

    public func setLastLive(_ live: String, config: String) {
        update(config) { $0.lastLive = live }
    }

    /// A line that started (D§6.5: never one that did not); its live source becomes the one to open on.
    public func setLast(_ last: LiveLastChannel, config: String, live: String) {
        update(config) {
            $0.lastLive = live
            $0.last[live] = last
        }
    }

    /// Adds or removes it; answers the favourites as they are now (unchanged when nothing could be saved).
    @discardableResult
    public func toggleFavorite(_ channel: String, config: String, live: String) -> [String] {
        update(config) {
            var names = $0.favorites[live] ?? []
            if let index = names.firstIndex(of: channel) { names.remove(at: index) } else { names.append(channel) }
            $0.favorites[live] = names.isEmpty ? nil : names
        }
        return favorites(config: config, live: live)
    }

    // MARK: The file

    /// Writes first and only then adopts the change, so memory never runs ahead of the disk.
    private func update(_ config: String, _ change: (inout Config) -> Void) {
        guard var all = loaded() else { return }
        var entry = all[config] ?? Config()
        change(&entry)
        guard entry != all[config] else { return }
        all[config] = entry
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(File(schemaVersion: Self.currentSchemaVersion, configs: all)).write(to: file, options: .atomic)
        } catch {
            return
        }
        configs = all
    }

    private func loaded() -> [String: Config]? {
        if let configs { return configs }
        guard FileManager.default.fileExists(atPath: file.path) else {
            configs = [:]
            return [:]
        }
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let stored = try? JSONDecoder().decode(File.self, from: data) else {
            let name = "live-state.corrupt-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json"
            guard (try? FileManager.default.moveItem(at: file, to: directory.appendingPathComponent(name))) != nil
            else { return nil }
            setAside = name
            configs = [:]
            return [:]
        }
        if stored.schemaVersion > Self.currentSchemaVersion {
            let name = "live-state.schema\(stored.schemaVersion).backup.json"
            let target = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: target.path)
                    || (try? FileManager.default.copyItem(at: file, to: target)) != nil else { return nil }
            backedUp = name
            configs = [:]
            return [:]
        }
        configs = stored.configs
        return stored.configs
    }
}

/// Where a live source was last watched: no address (X-10).
public struct LiveLastChannel: Codable, Equatable, Sendable {
    public var group: String
    public var channel: String
    public var lineLabel: String?
    public var lineIndex: Int

    public init(group: String, channel: String, lineLabel: String?, lineIndex: Int) {
        self.group = group
        self.channel = channel
        self.lineLabel = lineLabel
        self.lineIndex = lineIndex
    }

    /// D§6.5's order: the channel in its own group, else in the first other shown group that has it; its line by
    /// label, else by index, else the first. Nil when no shown group has it with a line iOS can try — there is
    /// then nothing to continue, and the screen opens on its first group as usual.
    public func locate(in groups: [LiveGroup]) -> LivePosition? {
        let found = groups.firstIndex { $0.name == group }.flatMap { g in index(in: groups[g]).map { (g, $0) } }
            ?? groups.indices.lazy.compactMap { g in index(in: groups[g]).map { (g, $0) } }.first
        guard let (g, c) = found else { return nil }
        let lines = groups[g].channels[c].lines
        let line = lineLabel.flatMap { label in lines.firstIndex { $0.label == label } }
            ?? (lines.indices.contains(lineIndex) ? lineIndex : 0)
        return LivePosition(group: g, channel: c, line: line)
    }

    private func index(in group: LiveGroup) -> Int? {
        group.channels.firstIndex { $0.name == channel && !$0.isUnsupported }
    }
}

public struct LivePosition: Equatable, Sendable {
    public var group: Int
    public var channel: Int
    public var line: Int
}

extension LiveGroup {
    /// The group the favourites show in, first in the group column (D§6.4.2).
    public static let favoritesName = "收藏"
}

extension Array where Element == LiveGroup {
    /// These shown groups with 「收藏」 first when any favourite is in them: each favourite once, its first
    /// occurrence (X-11), in the order favourited. Hidden groups must already be gone, so a password group's
    /// channel never surfaces here; a favourite missing from the list stays stored for when it comes back.
    public func withFavorites(_ names: [String]) -> [LiveGroup] {
        let channels = names.compactMap { name in lazy.flatMap(\.channels).first { $0.name == name } }
        guard !channels.isEmpty else { return self }
        return [LiveGroup(name: LiveGroup.favoritesName, password: nil, channels: channels)] + self
    }
}
