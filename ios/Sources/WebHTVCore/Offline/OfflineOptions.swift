import Foundation

/// IOS-POC-47 — what the download sheet offers, and what the viewer picked in it.

/// Names a variant by what it declares, so preparing again with freshly signed addresses picks the
/// same rendition the sheet showed rather than whatever the selector would pick now.
public struct OfflineVariantKey: Codable, Equatable, Hashable, Sendable {
    public let width: Int?
    public let height: Int?
    public let codecs: [String]
    public let bandwidth: Int
    public let frameRate: Double?
    public let videoRange: String?

    public init(_ variant: HLSVariant) {
        width = variant.width
        height = variant.height
        codecs = variant.codecs
        bandwidth = variant.bandwidth
        frameRate = variant.frameRate
        videoRange = variant.videoRange
    }

    public func matches(_ variant: HLSVariant) -> Bool { self == OfflineVariantKey(variant) }
}

/// One audio rendition the sheet lists. `muxed` is the audio already inside the video segments.
public struct OfflineAudioOption: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let language: String?
    public let channels: Int?
    public let muxed: Bool

    public var info: OfflineAudioInfo { OfflineAudioInfo(name: name, language: language, codec: nil, channels: channels) }
}

public struct OfflineSubtitleOption: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let language: String?
    public let kind: OfflineSubtitleInfo.Kind
    public let forced: Bool
}

/// What one quality mode would download.
public struct OfflineModeOption: Equatable, Sendable {
    public let video: OfflineVideoInfo?
    public let variant: OfflineVariantKey?
    public let estimate: OfflineSizeEstimate
    public let hdrOnly: Bool
    public let resolutionUnknown: Bool
    public let audio: [OfflineAudioOption]
    public let defaultAudioID: String?
    public let subtitles: [OfflineSubtitleOption]
    public let defaultSubtitleIDs: [String]
}

/// The sheet's whole input, read once from the stream before anything is downloaded.
public struct OfflineDownloadOptions: Equatable, Sendable {
    public enum Kind: String, Sendable { case hls, progressive }

    public let kind: Kind
    public let durationSeconds: Double?
    public let modes: [OfflineQualityMode: OfflineModeOption]
    /// Set when the stream cannot be downloaded at all (DRM, live, unsupported encryption).
    public let refusal: OfflineFailure?
    public let compatibility: OfflinePlaybackCompatibility

    public func option(for mode: OfflineQualityMode) -> OfflineModeOption? { modes[mode] }
}

/// The viewer's picks, kept with the download so preparing (again) makes the same package.
public struct OfflineDownloadChoice: Codable, Equatable, Sendable {
    public var mode: OfflineQualityMode
    public var allowHighFrameRate: Bool
    public var variant: OfflineVariantKey?
    /// An `OfflineAudioOption.id`; nil keeps the stream's own audio.
    public var audioID: String?
    public var subtitleIDs: [String]

    public init(mode: OfflineQualityMode, allowHighFrameRate: Bool = false, variant: OfflineVariantKey? = nil,
                audioID: String? = nil, subtitleIDs: [String] = []) {
        self.mode = mode
        self.allowHighFrameRate = allowHighFrameRate
        self.variant = variant
        self.audioID = audioID
        self.subtitleIDs = subtitleIDs
    }
}

/// What a queued download was asked for: the resolved stream (address and headers) and the
/// choices. Lives in `download-request.json` until the download completes; nothing in it is logged.
public struct OfflineDownloadRequest: Codable, Equatable, Sendable {
    public var mediaURL: URL
    public var headers: [String: String]
    public var choice: OfflineDownloadChoice
    public var sidecars: [OfflineSidecarRequest]
    /// The last attempt failed because the addresses stopped working: resolve the episode again.
    public var needsFreshSource: Bool

    public init(mediaURL: URL, headers: [String: String], choice: OfflineDownloadChoice,
                sidecars: [OfflineSidecarRequest], needsFreshSource: Bool = false) {
        self.mediaURL = mediaURL
        self.headers = headers
        self.choice = choice
        self.sidecars = sidecars
        self.needsFreshSource = needsFreshSource
    }
}

public enum OfflineOptionsBuilder {
    static func audioID(_ rendition: HLSRendition) -> String {
        "audio|\(rendition.groupID)|\(rendition.name)|\(rendition.language ?? "")"
    }

    static func subtitleID(_ rendition: HLSRendition) -> String {
        "hls|\(rendition.groupID)|\(rendition.name)|\(rendition.language ?? "")"
    }

    static func audioOption(_ rendition: HLSRendition) -> OfflineAudioOption {
        OfflineAudioOption(id: audioID(rendition), name: rendition.name, language: rendition.language,
                           channels: OfflineMediaSelector.channelCount(rendition), muxed: rendition.uri == nil)
    }

    /// The source's own subtitle files that can be fetched, numbered as the play result listed them.
    public static func sidecars(_ subtitles: [SourceSubtitle]) -> [OfflineSidecarRequest] {
        subtitles.enumerated().compactMap { index, subtitle in
            guard let url = SourceSubtitles.url(subtitle.url), SourceSubtitleProvider.isFetchable(url) else { return nil }
            return OfflineSidecarRequest(id: "sidecar|\(index)", url: url,
                                         name: subtitle.name.isEmpty ? "字幕 \(index + 1)" : subtitle.name,
                                         language: subtitle.language.isEmpty ? nil : subtitle.language,
                                         format: subtitle.format)
        }
    }

    static func sidecarOptions(_ sidecars: [OfflineSidecarRequest]) -> [OfflineSubtitleOption] {
        sidecars.map { OfflineSubtitleOption(id: $0.id, name: $0.name, language: $0.language, kind: .sidecar, forced: false) }
    }

    /// Every mode's choice over one master playlist. `duration` comes from one media playlist (all
    /// renditions of a programme share it).
    public static func options(master: HLSMasterPlaylist, duration: Double?, sidecars: [OfflineSidecarRequest],
                               allowHighFrameRate: Bool, preferredAudioLanguage: String?, preferredAudioName: String?,
                               preferredSubtitleLanguage: String?) -> OfflineDownloadOptions {
        var modes = [OfflineQualityMode: OfflineModeOption]()
        for mode in OfflineQualityMode.allCases {
            guard let choice = OfflineMediaSelector.chooseVideo(from: master, mode: mode,
                                                                allowHighFrameRate: allowHighFrameRate) else { continue }
            let variant = choice.variant
            let audio = master.renditions(type: "AUDIO", group: variant.audioGroup)
            let chosenAudio = OfflineMediaSelector.chooseAudio(audio, preferredLanguage: preferredAudioLanguage,
                                                               preferredName: preferredAudioName, mode: mode)
            let subtitles = OfflineMediaSelector.subtitleOptions(for: variant, in: master)
            let defaultSubtitle = OfflineMediaSelector.defaultSubtitle(subtitles, preferredLanguage: preferredSubtitleLanguage)
            let sidecarOptions = sidecarOptions(sidecars)
            let defaultSidecar = defaultSubtitle == nil
                ? sidecarOptions.first { PlaybackMediaOption.canonicalLanguageCode($0.language)
                    == PlaybackMediaOption.canonicalLanguageCode(preferredSubtitleLanguage) }
                : nil
            modes[mode] = OfflineModeOption(
                video: variant.info, variant: OfflineVariantKey(variant),
                estimate: OfflineMediaSelector.estimate(variant, duration: duration ?? 0),
                hdrOnly: choice.hdrOnly, resolutionUnknown: choice.resolutionUnknown,
                audio: audio.map(audioOption), defaultAudioID: chosenAudio.map(audioID),
                subtitles: subtitles.map { OfflineSubtitleOption(id: subtitleID($0), name: $0.name, language: $0.language,
                                                                 kind: .hlsRendition, forced: $0.forced) } + sidecarOptions,
                defaultSubtitleIDs: [defaultSubtitle.map(subtitleID), defaultSidecar?.id].compactMap { $0 })
        }
        return OfflineDownloadOptions(kind: .hls, durationSeconds: duration, modes: modes, refusal: nil,
                                      compatibility: .bothEngines)
    }

    /// A single file: the same choice in every mode — there is nothing to choose between.
    public static func progressive(size: Int64?, sidecars: [OfflineSidecarRequest],
                                   preferredSubtitleLanguage: String?) -> OfflineDownloadOptions {
        let subtitles = sidecarOptions(sidecars)
        let preferred = PlaybackMediaOption.canonicalLanguageCode(preferredSubtitleLanguage)
        let option = OfflineModeOption(
            video: nil, variant: nil,
            estimate: size.map { OfflineSizeEstimate(bytes: $0, basis: .exact) } ?? .unknown,
            hdrOnly: false, resolutionUnknown: true, audio: [], defaultAudioID: nil, subtitles: subtitles,
            defaultSubtitleIDs: subtitles.first { PlaybackMediaOption.canonicalLanguageCode($0.language) == preferred }
                .map { [$0.id] } ?? [])
        return OfflineDownloadOptions(kind: .progressive, durationSeconds: nil,
                                      modes: Dictionary(uniqueKeysWithValues: OfflineQualityMode.allCases.map { ($0, option) }),
                                      refusal: nil, compatibility: .bothEngines)
    }

    public static func refused(_ failure: OfflineFailure, compatibility: OfflinePlaybackCompatibility) -> OfflineDownloadOptions {
        OfflineDownloadOptions(kind: .hls, durationSeconds: nil, modes: [:], refusal: failure, compatibility: compatibility)
    }
}

/// The groups the bulk actions act on, so 刪除已看完 can never take an unfinished episode.
public enum OfflineBulkSelection {
    public static func all(_ assets: [OfflineAsset], historyKey: String) -> [OfflineAsset] {
        assets.filter { $0.identity.historyKey == historyKey }
    }

    /// Completed **and** really watched to the end. A download still running, paused or failed is
    /// never in it, however far it was watched.
    public static func watched(_ assets: [OfflineAsset], historyKey: String) -> [OfflineAsset] {
        all(assets, historyKey: historyKey).filter { $0.state == .completed && $0.watched }
    }

    public static func failed(_ assets: [OfflineAsset], historyKey: String) -> [OfflineAsset] {
        all(assets, historyKey: historyKey).filter { $0.state == .failed }
    }

    /// What a selection would free, for 「已選 3 項 · 1.69 GB」: measured bytes where known.
    public static func bytes(_ assets: [OfflineAsset]) -> Int64 {
        assets.reduce(0) { $0 + ($1.displayBytes ?? 0) }
    }
}
