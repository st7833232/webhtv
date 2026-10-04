import Foundation

/// IOS-POC-47 — Smart Download Selection: which **one** video variant of a master playlist to keep,
/// and which audio and subtitle renditions go with it.
///
/// The rules, in the order they decide:
/// 1. Nothing larger than the mode's box: 1920×1080 (720p for 最省空間), long side × short side, so a
///    portrait 1080×1920 counts as 1080p. 1440p and 4K are never candidates.
/// 2. SDR before HDR / Dolby Vision. HDR is chosen only when the source offers nothing else, and
///    the result says so (`hdrOnly`).
/// 3. The tallest resolution left.
/// 4. At 24/25/30 fps rather than 50/60 — the other way round when the viewer asked for high frame rates.
/// 5. HEVC, then H.264, then anything else (AV1 and VP9 decode in hardware on too few iPhones).
/// 6. Among what is left — same resolution, codec and range: 智慧 1080p takes the lowest bitrate
///    that is still reasonable for the picture (`reasonableFloor`), 最省空間 the lowest, 1080p 高畫質
///    the highest. "1080p" never means "the highest bitrate labelled 1080p".
///
/// A master that declares no RESOLUTION anywhere cannot be checked against the box. Then the
/// bitrate is the only evidence: the variants above `undeclaredCeiling` are left out unless nothing
/// else exists, and the result says the resolution is unknown.
public enum OfflineMediaSelector {
    /// Bits per pixel per frame that still looks like the resolution it claims, per codec. Below
    /// this a "1080p" variant is a mislabelled or starved one, and the next-cheapest is taken.
    static func bitsPerPixel(_ codec: OfflineVideoCodec) -> Double {
        switch codec {
        case .hevc, .av1, .vp9: return 0.025
        case .h264, .unknown: return 0.04
        }
    }

    /// The bitrate below which a variant is not a reasonable copy of its resolution.
    static func reasonableFloor(_ variant: HLSVariant) -> Int {
        guard let width = variant.width, let height = variant.height, width > 0, height > 0 else { return 0 }
        let fps = min(max(variant.frameRate ?? 30, 24), 30)
        return Int(Double(width * height) * fps * bitsPerPixel(variant.codec))
    }

    /// Above this, a variant with no declared resolution is assumed to be larger than 1080p.
    static let undeclaredCeiling = 12_000_000

    public struct VideoChoice: Equatable, Sendable {
        public let variant: HLSVariant
        /// Only HDR variants fit the mode: shown to the viewer before downloading.
        public let hdrOnly: Bool
        /// No variant declared a resolution.
        public let resolutionUnknown: Bool
    }

    /// Whether a declared picture fits the mode's box.
    static func fits(_ variant: HLSVariant, mode: OfflineQualityMode) -> Bool {
        guard let width = variant.width, let height = variant.height else { return false }
        return max(width, height) <= mode.maximumLongSide && min(width, height) <= mode.maximumShortSide
    }

    static func isHighFrameRate(_ variant: HLSVariant) -> Bool { (variant.frameRate ?? 0) > 31 }

    static func codecRank(_ codec: OfflineVideoCodec) -> Int {
        switch codec {
        case .hevc: return 0
        case .h264: return 1
        case .unknown: return 2
        case .av1, .vp9: return 3
        }
    }

    public static func chooseVideo(from master: HLSMasterPlaylist, mode: OfflineQualityMode,
                                   allowHighFrameRate: Bool = false) -> VideoChoice? {
        let video = master.variants.filter { !$0.isAudioOnly }
        guard !video.isEmpty else { return nil }
        let declared = video.filter { $0.width != nil && $0.height != nil }
        if declared.isEmpty { return chooseUndeclared(video, mode: mode) }

        // 1. The box.
        var pool = declared.filter { fits($0, mode: mode) }
        guard !pool.isEmpty else { return nil }
        // 2. SDR first.
        let sdr = pool.filter { $0.dynamicRange == .sdr }
        let hdrOnly = sdr.isEmpty
        if !hdrOnly { pool = sdr }
        // 3. The tallest picture.
        let tallest = pool.map { min($0.width ?? 0, $0.height ?? 0) }.max() ?? 0
        pool = pool.filter { min($0.width ?? 0, $0.height ?? 0) == tallest }
        // 4. Frame rate: 24/25/30 unless the viewer asked for 50/60 — then those, where they exist.
        let preferred = pool.filter { isHighFrameRate($0) == allowHighFrameRate }
        if !preferred.isEmpty { pool = preferred }
        // 5. Codec.
        let bestCodec = pool.map { codecRank($0.codec) }.min() ?? 0
        pool = pool.filter { codecRank($0.codec) == bestCodec }
        // 6. Bitrate.
        guard let chosen = pickBitrate(pool, mode: mode) else { return nil }
        return VideoChoice(variant: chosen, hdrOnly: hdrOnly && chosen.dynamicRange.isHDR, resolutionUnknown: false)
    }

    static func pickBitrate(_ pool: [HLSVariant], mode: OfflineQualityMode) -> HLSVariant? {
        let ascending = pool.sorted { $0.effectiveBitrate < $1.effectiveBitrate }
        switch mode {
        case .saver:
            return ascending.first
        case .high:
            return ascending.last
        case .smart:
            // The cheapest that is still a real copy of its resolution; when every one is below
            // the floor, the best of them.
            return ascending.first { $0.effectiveBitrate >= reasonableFloor($0) } ?? ascending.last
        }
    }

    private static func chooseUndeclared(_ video: [HLSVariant], mode: OfflineQualityMode) -> VideoChoice? {
        let ascending = video.sorted { $0.effectiveBitrate < $1.effectiveBitrate }
        let ceiling = mode == .saver ? undeclaredCeiling / 3 : undeclaredCeiling
        let plausible = ascending.filter { $0.effectiveBitrate <= ceiling }
        let chosen: HLSVariant?
        switch mode {
        case .saver: chosen = ascending.first
        case .smart, .high: chosen = plausible.last ?? ascending.first
        }
        return chosen.map { VideoChoice(variant: $0, hdrOnly: $0.dynamicRange.isHDR, resolutionUnknown: true) }
    }

    // MARK: Audio

    /// The audio renditions the chosen variant can play with. An empty list means its audio is
    /// muxed into the video segments: nothing else is downloaded.
    public static func audioOptions(for variant: HLSVariant, in master: HLSMasterPlaylist) -> [HLSRendition] {
        master.renditions(type: "AUDIO", group: variant.audioGroup).filter { $0.uri != nil }
    }

    /// One rendition, never all of them: the one playing now (by language, then name), else the
    /// default, else the first. 最省空間 prefers a stereo rendition of that language to a
    /// multichannel one — never by downmixing, only by choosing the stereo rendition the source
    /// already has.
    public static func chooseAudio(_ options: [HLSRendition], preferredLanguage: String?, preferredName: String?,
                                   mode: OfflineQualityMode) -> HLSRendition? {
        guard !options.isEmpty else { return nil }
        var pool = options
        if let preferredName, let named = pool.first(where: { $0.name == preferredName }) {
            pool = pool.filter { sameLanguage($0.language, named.language) }
        } else if let preferredLanguage {
            let matching = pool.filter { sameLanguage($0.language, preferredLanguage) }
            if !matching.isEmpty { pool = matching }
        } else if let fallback = pool.first(where: \.isDefault) ?? pool.first {
            pool = pool.filter { sameLanguage($0.language, fallback.language) }
        }
        if mode == .saver, let stereo = pool.first(where: { channelCount($0) == 2 }) { return stereo }
        if let preferredName, let named = pool.first(where: { $0.name == preferredName }) { return named }
        return pool.first(where: \.isDefault) ?? pool.first
    }

    /// `CHANNELS="6"` or `"16/JOC"`: the leading count.
    static func channelCount(_ rendition: HLSRendition) -> Int? {
        rendition.channels.flatMap { Int($0.split(separator: "/").first ?? "") }
    }

    static func sameLanguage(_ lhs: String?, _ rhs: String?) -> Bool {
        PlaybackMediaOption.canonicalLanguageCode(lhs) == PlaybackMediaOption.canonicalLanguageCode(rhs)
    }

    // MARK: Subtitles

    public static func subtitleOptions(for variant: HLSVariant, in master: HLSMasterPlaylist) -> [HLSRendition] {
        master.renditions(type: "SUBTITLES", group: variant.subtitlesGroup).filter { $0.uri != nil }
    }

    /// The subtitle the sheet starts with: one in the viewer's language (Traditional Chinese
    /// first for a Chinese viewer), else the source's default, else none.
    public static func defaultSubtitle(_ options: [HLSRendition], preferredLanguage: String?) -> HLSRendition? {
        if let preferredLanguage {
            let wanted = PlaybackMediaOption.canonicalLanguageCode(preferredLanguage)
            let matching = options.filter { PlaybackMediaOption.canonicalLanguageCode($0.language) == wanted && !$0.forced }
            if let traditional = matching.first(where: { isTraditional($0) }) { return traditional }
            if let first = matching.first { return first }
        }
        return options.first { $0.isDefault && !$0.forced }
    }

    static func isTraditional(_ rendition: HLSRendition) -> Bool {
        let tag = (rendition.language ?? "").lowercased()
        return tag.contains("hant") || tag.hasSuffix("-tw") || tag.hasSuffix("-hk") || rendition.name.contains("繁")
    }

    // MARK: Size

    /// AVERAGE-BANDWIDTH × duration, or BANDWIDTH × duration marked as an upper bound. RFC 8216
    /// counts the renditions a variant plays with inside its bandwidth, so the audio is not added a
    /// second time.
    public static func estimate(_ variant: HLSVariant, duration: Double) -> OfflineSizeEstimate {
        guard duration > 0 else { return .unknown }
        if let average = variant.averageBandwidth, average > 0 {
            return OfflineSizeEstimate(bytes: Int64(Double(average) * duration / 8), basis: .averageBandwidth)
        }
        guard variant.bandwidth > 0 else { return .unknown }
        return OfflineSizeEstimate(bytes: Int64(Double(variant.bandwidth) * duration / 8), basis: .peakBandwidth)
    }
}
