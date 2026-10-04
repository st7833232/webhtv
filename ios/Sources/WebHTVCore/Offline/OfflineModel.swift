import Foundation

// IOS-POC-47 — offline downloads: the records, and nothing that touches the network or the disk.
//
// **One `OfflineAsset` per episode, for both engines.** The asset is the episode's identity
// (`OfflineIdentity`), the one rendition that was chosen, and where its files are. AVPlayer and MPV
// are both handed the same local address for it (`OfflinePlaybackResolver`), so switching engine
// can never download it again or keep a second copy.

/// What makes two downloads the same episode: the title (`WatchHistory.key`, which is `Site.id`
/// plus the vod id), the line, and the episode **as the detail listing names it** — the source's
/// own identifier (`Episode.url`, `WatchHistory.episodeUrl`), never the resolved, signed media
/// address. A refreshed signature, another quality or another engine is still the same episode.
public struct OfflineIdentity: Codable, Hashable, Sendable {
    public let historyKey: String
    public let flag: String
    public let episodeURL: String

    public init(historyKey: String, flag: String, episodeURL: String) {
        self.historyKey = historyKey
        self.flag = flag
        self.episodeURL = episodeURL
    }
}

/// What the download screens show and what offline playback writes into the watch history: the
/// same fields `VodView.record(for:flag:)` builds a `WatchHistory` from.
public struct OfflineTitleInfo: Codable, Equatable, Sendable {
    public var siteKey: String
    public var siteName: String
    public var sourceID: String?
    public var vodId: String
    public var vodName: String
    public var vodPic: String
    public var episodeName: String
    /// The episode's place in its line when it was downloaded, so the downloads screen lists a
    /// series in order and offline auto-next knows which one follows.
    public var episodeIndex: Int

    public init(siteKey: String, siteName: String, sourceID: String?, vodId: String, vodName: String,
                vodPic: String, episodeName: String, episodeIndex: Int) {
        self.siteKey = siteKey
        self.siteName = siteName
        self.sourceID = sourceID
        self.vodId = vodId
        self.vodName = vodName
        self.vodPic = vodPic
        self.episodeName = episodeName
        self.episodeIndex = episodeIndex
    }
}

public enum OfflineAssetState: String, Codable, Sendable, CaseIterable {
    case queued, preparing, downloading, paused, failed, completed, deleting

    /// Work the scheduler may still pick up or is doing.
    public var isActive: Bool { self == .queued || self == .preparing || self == .downloading }
    /// 「需要處理」: stopped, and the viewer has to decide what happens next.
    public var needsAttention: Bool { self == .failed || self == .paused }
}

/// Why a download stopped. The kind decides what retry does; `detail` is a short, address-free
/// line for the screen and the log.
public struct OfflineFailure: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// The device is (or would be) too full. Partial data stays and can be deleted or resumed.
        case insufficientStorage
        /// DNS, timeout, a dropped connection.
        case network
        /// The server answered with an error status.
        case httpStatus
        /// The source's addresses stopped working (401/403/404/410): retry resolves the episode again.
        case expiredSource
        /// Something downloaded is missing or not what was asked for.
        case integrity
        /// FairPlay or another DRM: only Apple's own offline flow may store it.
        case drmProtected
        /// A format or encryption this version does not package (SAMPLE-AES, a live stream).
        case unsupported
        /// The app stopped while it was preparing, and nothing was left to resume.
        case interrupted
        case unknown
    }

    public var kind: Kind
    public var httpStatus: Int?
    public var detail: String

    public init(_ kind: Kind, httpStatus: Int? = nil, detail: String = "") {
        self.kind = kind
        self.httpStatus = httpStatus
        self.detail = detail
    }

    /// One line for the downloads screen.
    public var message: String {
        switch kind {
        case .insufficientStorage: return "裝置空間不足"
        case .network: return detail.isEmpty ? "網路錯誤" : "網路錯誤：\(detail)"
        case .httpStatus: return "伺服器錯誤（HTTP \(httpStatus ?? 0)）"
        case .expiredSource: return "來源網址已失效（HTTP \(httpStatus ?? 0)），重試會重新取得"
        case .integrity: return detail.isEmpty ? "下載內容不完整" : "下載內容不完整：\(detail)"
        case .drmProtected: return "此影片受 DRM 保護，無法下載"
        case .unsupported: return detail.isEmpty ? "不支援的格式" : detail
        case .interrupted: return "下載中斷"
        case .unknown: return detail.isEmpty ? "下載失敗" : detail
        }
    }

    /// A status that says the address itself is gone, rather than a passing server error.
    public static func forHTTP(_ status: Int) -> OfflineFailure {
        [401, 403, 404, 410].contains(status)
            ? OfflineFailure(.expiredSource, httpStatus: status)
            : OfflineFailure(.httpStatus, httpStatus: status)
    }
}

/// Which engines may play an asset. Everything this version stores is both: a DRM stream is
/// refused before anything is downloaded (`OfflineFailure.Kind.drmProtected`), never decrypted for
/// MPV. `avPlayerOnly` is what Apple's FairPlay offline flow would produce, should a source ever
/// supply the license it needs.
public enum OfflinePlaybackCompatibility: String, Codable, Sendable {
    case bothEngines
    case avPlayerOnly

    public func allows(_ engine: PlaybackEngineKind) -> Bool {
        self == .bothEngines || engine == .native
    }
}

/// The capacity modes the download sheet offers. Every one of them stops at 1080p.
public enum OfflineQualityMode: String, Codable, Sendable, CaseIterable {
    /// 最省空間: at most 720p, HEVC first, the lowest bitrate.
    case saver
    /// 智慧 1080p, the default: at most 1080p, HEVC first, SDR first, the lowest reasonable bitrate.
    case smart
    /// 1080p 高畫質: still at most 1080p; at the same resolution the higher bitrate.
    case high

    public var label: String {
        switch self {
        case .saver: return "最省空間"
        case .smart: return "智慧 1080p"
        case .high: return "1080p 高畫質"
        }
    }

    /// The largest picture this mode may download: long side × short side.
    public var maximumLongSide: Int { self == .saver ? 1280 : 1920 }
    public var maximumShortSide: Int { self == .saver ? 720 : 1080 }
}

public enum OfflineVideoCodec: String, Codable, Sendable {
    case hevc, h264, av1, vp9, unknown

    public var label: String {
        switch self {
        case .hevc: return "HEVC"
        case .h264: return "H.264"
        case .av1: return "AV1"
        case .vp9: return "VP9"
        case .unknown: return "未標示"
        }
    }
}

public enum OfflineDynamicRange: String, Codable, Sendable {
    case sdr, hdr10, hlg, dolbyVision

    public var isHDR: Bool { self != .sdr }
    public var label: String {
        switch self {
        case .sdr: return "SDR"
        case .hdr10: return "HDR10"
        case .hlg: return "HLG"
        case .dolbyVision: return "Dolby Vision"
        }
    }
}

/// The video rendition that was (or will be) downloaded.
public struct OfflineVideoInfo: Codable, Equatable, Sendable {
    /// Zero when the source did not say.
    public var width: Int
    public var height: Int
    public var codec: OfflineVideoCodec
    public var dynamicRange: OfflineDynamicRange
    public var frameRate: Double?
    /// Bits per second, as the master playlist declared them.
    public var bandwidth: Int?
    public var averageBandwidth: Int?

    public init(width: Int, height: Int, codec: OfflineVideoCodec, dynamicRange: OfflineDynamicRange,
                frameRate: Double? = nil, bandwidth: Int? = nil, averageBandwidth: Int? = nil) {
        self.width = width
        self.height = height
        self.codec = codec
        self.dynamicRange = dynamicRange
        self.frameRate = frameRate
        self.bandwidth = bandwidth
        self.averageBandwidth = averageBandwidth
    }

    /// 「1080p」, from the short side so a portrait video reads the way a landscape one does.
    public var resolutionLabel: String {
        let short = min(width, height)
        return short > 0 ? "\(short)p" : "解析度未標示"
    }

    /// 「1080p HEVC SDR」, plus the frame rate above 30.
    public var summary: String {
        var parts = [resolutionLabel, codec.label, dynamicRange.label]
        if let frameRate, frameRate > 31 { parts.append("\(Int(frameRate.rounded()))fps") }
        return parts.joined(separator: " ")
    }
}

public struct OfflineAudioInfo: Codable, Equatable, Sendable {
    public var name: String
    public var language: String?
    public var codec: String?
    public var channels: Int?

    public init(name: String, language: String? = nil, codec: String? = nil, channels: Int? = nil) {
        self.name = name
        self.language = language
        self.codec = codec
        self.channels = channels
    }

    /// 「國語 · AAC · Stereo」, leaving out what is not known.
    public var summary: String {
        var parts = [name.isEmpty ? (language ?? "音軌") : name]
        if let codec { parts.append(codec) }
        if let channels { parts.append(channels == 1 ? "Mono" : channels == 2 ? "Stereo" : "\(channels) 聲道") }
        return parts.joined(separator: " · ")
    }
}

/// A subtitle kept with the asset. An HLS subtitle rendition lives inside the package, where both
/// engines list it as an embedded track; a source's own file is a sidecar in `subtitles/`.
public struct OfflineSubtitleInfo: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case hlsRendition, sidecar }

    public var id: String
    public var name: String
    public var language: String?
    public var kind: Kind
    /// Inside the asset's folder. Empty until the file is there.
    public var relativePath: String

    public init(id: String, name: String, language: String?, kind: Kind, relativePath: String = "") {
        self.id = id
        self.name = name
        self.language = language
        self.kind = kind
        self.relativePath = relativePath
    }
}

/// What the asset's playable entry point is, inside its folder.
public enum OfflinePackageKind: Codable, Equatable, Sendable {
    /// One media file (MP4, MKV, WebM, …), at `media/<name>`.
    case progressive(relativePath: String)
    /// A rewritten HLS package; the entry is a playlist under `playlists/`.
    case hls(entryPath: String)

    public var entryPath: String {
        switch self {
        case .progressive(let path), .hls(let path): return path
        }
    }

    public var isHLS: Bool {
        if case .hls = self { return true }
        return false
    }
}

/// The size shown before the download. Kept apart from the measured size on purpose: the
/// estimate is never shown as what the download actually occupies.
public struct OfflineSizeEstimate: Codable, Equatable, Sendable {
    public enum Basis: String, Codable, Sendable {
        /// Byte ranges or a server's Content-Length: the real size.
        case exact
        /// HLS `AVERAGE-BANDWIDTH` × duration.
        case averageBandwidth
        /// HLS `BANDWIDTH` (a peak) × duration: an upper bound.
        case peakBandwidth
        case unknown
    }

    public var bytes: Int64?
    public var basis: Basis

    public init(bytes: Int64?, basis: Basis) {
        self.bytes = bytes
        self.basis = basis
    }

    public static let unknown = OfflineSizeEstimate(bytes: nil, basis: .unknown)
    public var isApproximate: Bool { basis != .exact }
}

/// How far a download got. Units are files (segments, init sections, keys, the one progressive
/// file); bytes are what arrived for this asset, not what is on disk.
public struct OfflineProgress: Codable, Equatable, Sendable {
    public var completedUnits: Int
    public var totalUnits: Int
    public var receivedBytes: Int64
    /// The progressive file's own progress (bytes written / expected), which units cannot show.
    public var expectedBytes: Int64?

    public init(completedUnits: Int = 0, totalUnits: Int = 0, receivedBytes: Int64 = 0, expectedBytes: Int64? = nil) {
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
    }

    /// 0…1. A single progressive file reports by bytes; a package by files.
    public var fraction: Double {
        if totalUnits <= 1, let expectedBytes, expectedBytes > 0 {
            return min(Double(receivedBytes) / Double(expectedBytes), 1)
        }
        guard totalUnits > 0 else { return 0 }
        return min(Double(completedUnits) / Double(totalUnits), 1)
    }
}

/// One downloaded (or downloading) episode.
public struct OfflineAsset: Codable, Equatable, Sendable, Identifiable {
    /// The `metadata.json` format. Bump it, and add a step to `OfflineAssetMigration`, whenever a
    /// change could not be read by the decoder below.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// A UUID; also the asset's folder name. Not derived from any address.
    public let id: String
    public let identity: OfflineIdentity
    public var title: OfflineTitleInfo
    public var state: OfflineAssetState
    public var failure: OfflineFailure?
    /// Bumped by every pause, resume, retry and delete. A transfer reports with the generation it
    /// was started under, and an older one is ignored: a late callback can never revive a deleted
    /// asset or overwrite a newer state.
    public var generation: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var mode: OfflineQualityMode
    public var video: OfflineVideoInfo?
    public var audio: OfflineAudioInfo?
    public var subtitles: [OfflineSubtitleInfo]
    public var package: OfflinePackageKind?
    public var compatibility: OfflinePlaybackCompatibility
    public var estimate: OfflineSizeEstimate
    public var progress: OfflineProgress
    /// Measured from the disk when the download completed (and again after any change). Nil
    /// until then: the estimate is never shown in its place.
    public var actualBytes: Int64?
    public var durationSeconds: Double?
    public var autoDeleteAfterWatching: Bool
    /// The episode really finished playing (EOF, or the formal auto-next) at least once.
    public var watched: Bool
    /// Set at that moment when auto-delete is on, cleared by the delete itself. Survives a crash
    /// between the two: launch finishes the delete.
    public var pendingAutoDelete: Bool
    public var allowsCellular: Bool

    public init(id: String = UUID().uuidString, identity: OfflineIdentity, title: OfflineTitleInfo,
                mode: OfflineQualityMode, autoDeleteAfterWatching: Bool, allowsCellular: Bool,
                now: Date = .now) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.identity = identity
        self.title = title
        state = .queued
        failure = nil
        generation = 0
        createdAt = now
        updatedAt = now
        self.mode = mode
        video = nil
        audio = nil
        subtitles = []
        package = nil
        compatibility = .bothEngines
        estimate = .unknown
        progress = OfflineProgress()
        actualBytes = nil
        durationSeconds = nil
        self.autoDeleteAfterWatching = autoDeleteAfterWatching
        watched = false
        pendingAutoDelete = false
        self.allowsCellular = allowsCellular
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, identity, title, state, failure, generation, createdAt, updatedAt, mode
        case video, audio, subtitles, package, compatibility, estimate, progress, actualBytes
        case durationSeconds, autoDeleteAfterWatching, watched, pendingAutoDelete, allowsCellular
    }

    /// The identity fields are required; everything else falls back to a default, so a field added
    /// later never makes an older record unreadable — an unreadable record would otherwise look
    /// like a download that is not there.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try values.decode(String.self, forKey: .id)
        identity = try values.decode(OfflineIdentity.self, forKey: .identity)
        title = try values.decode(OfflineTitleInfo.self, forKey: .title)
        state = (try? values.decode(OfflineAssetState.self, forKey: .state)) ?? .failed
        failure = try? values.decodeIfPresent(OfflineFailure.self, forKey: .failure)
        generation = (try? values.decode(Int.self, forKey: .generation)) ?? 0
        createdAt = (try? values.decode(Date.self, forKey: .createdAt)) ?? .distantPast
        updatedAt = (try? values.decode(Date.self, forKey: .updatedAt)) ?? createdAt
        mode = (try? values.decode(OfflineQualityMode.self, forKey: .mode)) ?? .smart
        video = try? values.decodeIfPresent(OfflineVideoInfo.self, forKey: .video)
        audio = try? values.decodeIfPresent(OfflineAudioInfo.self, forKey: .audio)
        subtitles = (try? values.decode([OfflineSubtitleInfo].self, forKey: .subtitles)) ?? []
        package = try? values.decodeIfPresent(OfflinePackageKind.self, forKey: .package)
        compatibility = (try? values.decode(OfflinePlaybackCompatibility.self, forKey: .compatibility)) ?? .bothEngines
        estimate = (try? values.decode(OfflineSizeEstimate.self, forKey: .estimate)) ?? .unknown
        progress = (try? values.decode(OfflineProgress.self, forKey: .progress)) ?? OfflineProgress()
        actualBytes = try? values.decodeIfPresent(Int64.self, forKey: .actualBytes)
        durationSeconds = try? values.decodeIfPresent(Double.self, forKey: .durationSeconds)
        autoDeleteAfterWatching = (try? values.decode(Bool.self, forKey: .autoDeleteAfterWatching)) ?? false
        watched = (try? values.decode(Bool.self, forKey: .watched)) ?? false
        pendingAutoDelete = (try? values.decode(Bool.self, forKey: .pendingAutoDelete)) ?? false
        allowsCellular = (try? values.decode(Bool.self, forKey: .allowsCellular)) ?? false
    }

    /// What the downloads list shows as the size: the measured bytes once there are any, else the
    /// bytes received so far, else the estimate — labelled as such by the caller.
    public var displayBytes: Int64? { actualBytes ?? (progress.receivedBytes > 0 ? progress.receivedBytes : nil) }
}

/// Reads a `metadata.json` written by any version, oldest first. A record from a **newer** schema
/// is refused rather than guessed at: the store keeps its folder untouched (`unreadable`) so a
/// downgrade never deletes what a newer build downloaded.
public enum OfflineAssetMigration {
    public enum Outcome: Equatable {
        case current(OfflineAsset)
        case migrated(OfflineAsset)
        case tooNew(Int)
    }

    public static func decode(_ data: Data) throws -> Outcome {
        struct Header: Decodable { let schemaVersion: Int? }
        let version = (try JSONDecoder.offline.decode(Header.self, from: data)).schemaVersion ?? 1
        guard version <= OfflineAsset.currentSchemaVersion else { return .tooNew(version) }
        var asset = try JSONDecoder.offline.decode(OfflineAsset.self, from: data)
        guard version < OfflineAsset.currentSchemaVersion else { return .current(asset) }
        // No older schema exists yet; each future step upgrades one version here.
        asset.schemaVersion = OfflineAsset.currentSchemaVersion
        return .migrated(asset)
    }
}

/// Dates as Foundation's own reference-date seconds, which read back to the identical `Date`.
extension JSONDecoder {
    static var offline: JSONDecoder { JSONDecoder() }
}

extension JSONEncoder {
    static var offline: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

/// The settings page's offline choices, in the same `UserDefaults` as the rest of the app's.
public struct OfflineDownloadPreferences: Sendable {
    static let modeKey = "webhtv.offline.qualityMode"
    static let autoDeleteKey = "webhtv.offline.autoDeleteAfterWatching"
    static let cellularKey = "webhtv.offline.allowsCellular"
    static let highFrameRateKey = "webhtv.offline.prefersHighFrameRate"
    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// 智慧 1080p unless changed.
    public var mode: OfflineQualityMode {
        get { defaults.string(forKey: Self.modeKey).flatMap(OfflineQualityMode.init(rawValue:)) ?? .smart }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.modeKey) }
    }

    /// On unless changed: the user asked for 看完後自動刪除 to default to on.
    public var autoDeleteAfterWatching: Bool {
        get { defaults.object(forKey: Self.autoDeleteKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.autoDeleteKey) }
    }

    /// Off unless changed: a few GB over a metered connection is the viewer's decision to make.
    public var allowsCellular: Bool {
        get { defaults.object(forKey: Self.cellularKey) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Self.cellularKey) }
    }

    /// 60 fps only when asked for: at the same resolution it roughly doubles the size.
    public var prefersHighFrameRate: Bool {
        get { defaults.object(forKey: Self.highFrameRateKey) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Self.highFrameRateKey) }
    }
}

/// Byte counts for the screens: 「742 MB」「1.69 GB」, decimal units as Files and Settings show them.
public enum OfflineByteFormat {
    public static func string(_ bytes: Int64) -> String {
        let value = Double(max(bytes, 0))
        if value >= 1_000_000_000 { return String(format: "%.2f GB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.0f MB", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0f KB", value / 1_000) }
        return "\(Int(value)) B"
    }
}
