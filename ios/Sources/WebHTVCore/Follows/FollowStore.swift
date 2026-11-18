import Foundation

/// W-313 — the followed titles on disk: `Application Support/Follows/follows.json`, rewritten whole
/// and atomically, as `FavoriteStore` writes its file.
///
/// A follow that a later build wrote and this one cannot read is kept verbatim and written back, so a
/// downgrade never drops it. A file that is not JSON at all is moved aside and following starts over:
/// losing which titles were followed is an inconvenience, and nothing else depends on this file.
public actor FollowStore {
    public static let shared = FollowStore()
    public static let currentSchemaVersion = 1
    /// More than this many follows would make every launch check a crowd of sites.
    public static let limit = 50
    static let fileName = "follows.json"

    private let directory: URL
    private var file: URL { directory.appendingPathComponent(Self.fileName) }
    private var follows: [Follow]?
    private var unreadable = [FavoriteFile.Entry.Raw]()

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Follows", isDirectory: true)
    }

    /// Every follow, the most recently followed first.
    public func all() -> [Follow] { loaded() }

    public func follow(_ identity: FavoriteIdentity) -> Follow? {
        loaded().first { $0.identity == identity }
    }

    public enum AddResult: Equatable, Sendable { case added, alreadyFollowing, full, notSaved }

    public func add(_ follow: Follow) -> AddResult {
        var list = loaded()
        guard !list.contains(where: { $0.identity == follow.identity }) else { return .alreadyFollowing }
        guard list.count < Self.limit else { return .full }
        list.insert(follow, at: 0)
        return store(list) ? .added : .notSaved
    }

    @discardableResult
    public func remove(_ identity: FavoriteIdentity) -> Bool {
        var list = loaded()
        guard let index = list.firstIndex(where: { $0.identity == identity }) else { return false }
        list.remove(at: index)
        return store(list)
    }

    /// Replaces one follow with what `change` makes of it; nil when it is not followed or nothing changed.
    @discardableResult
    public func update(_ identity: FavoriteIdentity, _ change: @Sendable (Follow) -> Follow?) -> Follow? {
        var list = loaded()
        guard let index = list.firstIndex(where: { $0.identity == identity }),
              let next = change(list[index]), next != list[index] else { return nil }
        list[index] = next
        return store(list) ? next : nil
    }

    /// An episode of a title started playing (the player's history save): settles the new episodes up to
    /// it (`Follow.playing`). Matched on the history's own key and configuration — the same site and
    /// title, never the same name on another site. Cheap when nothing is waiting, which is almost
    /// always: the player calls this every few seconds.
    @discardableResult
    public func played(_ record: WatchHistory) -> Follow? {
        let list = loaded()
        guard let sourceID = record.sourceID,
              let match = list.first(where: {
                  !$0.unseen.isEmpty && $0.identity.configSourceID == sourceID && $0.identity.historyKey == record.key
              })
        else { return nil }
        return update(match.identity) { $0.playing(record.vodRemarks) }
    }

    private func loaded() -> [Follow] {
        if let follows { return follows }
        var list = [Follow]()
        unreadable = []
        if let data = try? Data(contentsOf: file) {
            if let contents = try? JSONDecoder().decode(FollowFile.self, from: data) {
                for entry in contents.follows {
                    switch entry {
                    case .follow(let follow) where !list.contains(where: { $0.identity == follow.identity }):
                        list.append(follow)
                    case .follow: break
                    case .unreadable(let raw): unreadable.append(raw)
                    }
                }
            } else {
                let name = "follows.corrupt-\(Int(Date().timeIntervalSince1970)).json"
                try? FileManager.default.moveItem(at: file, to: directory.appendingPathComponent(name))
            }
        }
        follows = list
        return list
    }

    /// Writes the list and only then adopts it, so memory never runs ahead of the disk.
    private func store(_ list: [Follow]) -> Bool {
        let contents = FollowFile(schemaVersion: Self.currentSchemaVersion,
                                  follows: list.map { .follow($0) } + unreadable.map { .unreadable($0) })
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(contents).write(to: file, options: .atomic)
        } catch {
            return false
        }
        follows = list
        return true
    }
}

/// `{"follows":[…],"schemaVersion":1}`.
struct FollowFile: Codable {
    var schemaVersion: Int
    var follows: [Entry]

    enum Entry: Codable {
        case follow(Follow)
        case unreadable(FavoriteFile.Entry.Raw)

        init(from decoder: Decoder) throws {
            if let follow = try? Follow(from: decoder) {
                self = .follow(follow)
            } else {
                self = .unreadable(try FavoriteFile.Entry.Raw(from: decoder))
            }
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .follow(let follow): try follow.encode(to: encoder)
            case .unreadable(let raw): try raw.encode(to: encoder)
            }
        }
    }
}
