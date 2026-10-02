import Foundation

/// IOS-POC-45 — where one playback session's downloaded subtitles live, and for how long.
///
/// **Session-scoped, never a library.** Each playback session gets
/// `<tmp>/WebHTVOnlineSubtitles/session-<UUID>/`, holding only the files the viewer actually
/// picked. It lasts through everything that keeps the same video playing — pause, seek, a quality
/// or engine switch, a fallback, a reload, the background, Picture in Picture — because nothing
/// but `end()` removes it, and only `OnlineSubtitleCoordinator` calls that: when the player
/// closes, or a different video starts. A crash or a force quit skips `end()`, so launch sweeps
/// whatever sessions a previous run left (`removeStaleSessions`). Nothing is carried from one
/// session to the next: watching again searches and downloads again, which takes a second.
///
/// A class behind a lock rather than an actor: `end()` must take the files away **now**, from
/// the main actor, and every operation here is a few small file calls.
public final class SubtitleSessionCache: @unchecked Sendable {
    public static let directoryName = "WebHTVOnlineSubtitles"
    public static let sessionPrefix = "session-"

    /// The app's temporary directory's own folder for this feature. Nothing outside it is touched.
    public static var defaultRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    public let directory: URL
    private let lock = NSLock()
    private var kept = [String: PlaybackExternalSubtitle]()
    private var count = 0
    private var ended = false

    public init(root: URL = SubtitleSessionCache.defaultRoot, id: UUID = UUID()) {
        directory = root.appendingPathComponent(Self.sessionPrefix + id.uuidString, isDirectory: true)
    }

    /// This session's copy of a file it already downloaded, if the file is still there.
    public func existing(for url: URL) -> PlaybackExternalSubtitle? {
        lock.lock(); defer { lock.unlock() }
        guard !ended, let subtitle = kept[url.absoluteString],
              FileManager.default.fileExists(atPath: subtitle.fileURL.path) else { return nil }
        return subtitle
    }

    /// Writes a validated file as UTF-8 (whatever it arrived in, so both engines read the same
    /// text) and hands back what the engines are given. Refused once the session has ended.
    public func store(text: String, cues: SubtitleCues, for track: RemoteSubtitleTrack) throws -> PlaybackExternalSubtitle {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { throw SubtitleProviderError.cancelled }
        if let subtitle = kept[track.downloadURL.absoluteString],
           FileManager.default.fileExists(atPath: subtitle.fileURL.path) { return subtitle }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        count += 1
        let file = directory.appendingPathComponent("\(count)-\(Self.safeName(track.fileName))")
        try Data(text.utf8).write(to: file, options: .atomic)
        let base = "\(track.language.displayName)（\(track.providerName)）"
        let taken = kept.values.filter { $0.title.hasPrefix(base) }.count
        let subtitle = PlaybackExternalSubtitle(
            id: PlaybackExternalSubtitle.idPrefix + String(count),
            title: taken == 0 ? base : "\(base) \(taken + 1)",
            language: track.language.code,
            fileURL: file,
            cues: cues
        )
        kept[track.downloadURL.absoluteString] = subtitle
        return subtitle
    }

    /// The session is over: its files go, and nothing more is written.
    public func end() {
        lock.lock(); defer { lock.unlock() }
        ended = true
        kept = [:]
        try? FileManager.default.removeItem(at: directory)
    }

    public var hasEnded: Bool {
        lock.lock(); defer { lock.unlock() }
        return ended
    }

    /// Launch: every session folder a previous run left behind — and only those. Anything else
    /// in the temporary directory, or in this feature's folder without the session prefix, stays.
    /// Answers how many were removed.
    @discardableResult
    public static func removeStaleSessions(root: URL = defaultRoot, except active: Set<URL> = []) -> Int {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                               options: [.skipsHiddenFiles]) else { return 0 }
        let keep = Set(active.map { $0.standardizedFileURL.path })
        var removed = 0
        for entry in entries where entry.lastPathComponent.hasPrefix(sessionPrefix) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  !keep.contains(entry.standardizedFileURL.path) else { continue }
            if (try? manager.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }

    /// A file name mpv and the file system both take: letters, digits, dot, hyphen and underscore,
    /// at most 80 characters, ending in `.srt`.
    static func safeName(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        var name = String((raw.removingPercentEncoding ?? raw).map { allowed.contains($0) ? $0 : "_" })
        if name.lowercased().hasSuffix(".srt") { name = String(name.dropLast(4)) }
        name = String(name.prefix(76)).trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        return (name.isEmpty ? "subtitle" : name) + ".srt"
    }
}
