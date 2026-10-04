import Foundation

/// IOS-POC-47 — a downloaded episode as something an engine can open.
///
/// **One address for both engines.** A progressive file is opened as `file://…/media/video.mp4`; an
/// HLS package as `http://127.0.0.1:<port>/<token>/<asset-id>/playlists/index.m3u8`, served from the
/// asset's folder by `OfflineMediaServer`. AVPlayer does not read HLS from `file://` — an Apple
/// media engineer: "you can't get m3u8 from the local filesystem" — and an
/// `AVAssetResourceLoaderDelegate` may answer a segment request only with a redirect to an HTTP
/// address, so a loopback server is the one route AVPlayer takes; MPV is given the very same
/// address. The target carries no headers and the files never leave the device.
public struct OfflinePlaybackSource: Sendable, Equatable {
    public let assetID: String
    public let url: URL
    public let compatibility: OfflinePlaybackCompatibility
    /// The sidecar subtitles, as files. Subtitles inside an HLS package are the engines' own tracks.
    public let sidecars: [OfflineSubtitleInfo]
    public let folder: URL
    /// The quality menu's one entry: 「離線 1080p」.
    public let label: String
}

public enum OfflinePlaybackResolver {
    /// The address an asset is played from, or nil when it is not complete, its entry is missing,
    /// or it is an HLS package and the local server is not running.
    public static func source(for asset: OfflineAsset, layout: OfflineStorageLayout,
                              serverBase: URL?, fileManager: FileManager = .default) -> OfflinePlaybackSource? {
        guard asset.state == .completed, !asset.pendingAutoDelete, let package = asset.package else { return nil }
        let folder = layout.folder(for: asset.id)
        let entry = folder.appendingPathComponent(package.entryPath)
        guard fileManager.fileExists(atPath: entry.path) else { return nil }
        let url: URL
        switch package {
        case .progressive:
            url = entry
        case .hls(let path):
            guard let serverBase else { return nil }
            url = serverBase.appendingPathComponent(asset.id).appendingPathComponent(path)
        }
        let sidecars = asset.subtitles.filter {
            $0.kind == .sidecar && !$0.relativePath.isEmpty
                && fileManager.fileExists(atPath: folder.appendingPathComponent($0.relativePath).path)
        }
        return OfflinePlaybackSource(assetID: asset.id, url: url, compatibility: asset.compatibility,
                                     sidecars: sidecars, folder: folder,
                                     label: "離線 " + (asset.video?.resolutionLabel ?? "檔案"))
    }

    /// The target an engine is handed. The same for AVPlayer and MPV, except that an AVPlayer-only
    /// asset (FairPlay) has none for MPV: it is never decrypted into a second copy for it.
    public static func target(for source: OfflinePlaybackSource, engine: PlaybackEngineKind) -> PlaybackTarget? {
        guard source.compatibility.allows(engine) else { return nil }
        return PlaybackTarget(url: source.url, headers: [:],
                              qualities: [PlaybackQuality(name: source.label, url: source.url)])
    }

    /// The sidecar files as the engines' side-loaded subtitles.
    public static func externalSubtitles(_ source: OfflinePlaybackSource) -> [PlaybackExternalSubtitle] {
        source.sidecars.enumerated().compactMap { index, subtitle in
            let file = source.folder.appendingPathComponent(subtitle.relativePath)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let cues = SubRip.parse(text)
            guard !cues.isEmpty else { return nil }
            return PlaybackExternalSubtitle(id: PlaybackExternalSubtitle.idPrefix + "offline-\(index + 1)",
                                            title: "\(subtitle.name)（離線）", language: subtitle.language,
                                            fileURL: file, cues: cues)
        }
    }
}

/// IOS-POC-47 — when a downloaded episode counts as watched, and when it may be deleted.
///
/// **Only a real end counts**: the engine's own end of file (AVPlayer's
/// `AVPlayerItemDidPlayToEndTime`; MPV's `MPV_EVENT_END_FILE` with reason `EOF`, which `MPVEngine`
/// already alone reports as ended — stop, error and replace never do), or the app's formal
/// auto-next at the viewer's ending. `WatchHistory.isNearEnding` is not used: a seek to the last
/// seconds and closing the player reaches it too, and nothing was watched to the end. Errors,
/// stops, engine and quality switches, the background, the lock screen and a crash produce no end,
/// so none of them can delete anything.
///
/// **Deletion waits for the release.** The end only arms the delete (`pendingAutoDelete`, kept on
/// disk so a crash in between is finished at launch); it runs when the session lets the asset go —
/// another item loaded, the player stopped or closed after the end.
public struct OfflineCompletionPolicy: Sendable, Equatable {
    public enum EndReason: String, Sendable {
        /// The engine reached the end of the file.
        case endOfFile
        /// The viewer's ending was reached and the next episode was asked for.
        case formalAutoNext
    }

    public enum Decision: Equatable, Sendable {
        /// Record the episode as watched; arm the auto-delete if it is on.
        case markWatched(String)
        /// The asset is no longer held; run the armed auto-delete, if any.
        case released(String)
    }

    /// The downloaded asset loaded now, if any.
    public private(set) var current: String?
    /// Whether it really ended in this playback.
    public private(set) var ended = false

    public init() {}

    /// An item was loaded. The same asset again (a reload, an engine switch, a fallback) keeps
    /// everything; anything else releases the one before.
    public mutating func opened(_ assetID: String?) -> [Decision] {
        guard assetID != current else { return [] }
        let previous = current
        current = assetID
        ended = false
        return previous.map { [.released($0)] } ?? []
    }

    public mutating func ended(_ reason: EndReason) -> [Decision] {
        guard let current, !ended else { return [] }
        ended = true
        return [.markWatched(current)]
    }

    /// The player screen closed. The asset stays loaded (paused) as any item does — unless it
    /// ended, when it is unloaded so it can be released.
    public mutating func closed() -> (unload: Bool, decisions: [Decision]) {
        guard let current, ended else { return (false, []) }
        self.current = nil
        ended = false
        return (true, [.released(current)])
    }

    /// Playback was stopped: nothing is loaded any more.
    public mutating func stopped() -> [Decision] {
        guard let current else { return [] }
        self.current = nil
        ended = false
        return [.released(current)]
    }
}
