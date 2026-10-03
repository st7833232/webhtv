import Foundation

/// Engine-neutral metadata for the embedded audio/subtitle choices shown by WebHTV.
/// Engine-specific selectors (AVMediaSelectionOption, mpv aid/sid) never escape their adapters.
public enum PlaybackMediaKind: String, Sendable, Equatable {
    case audio
    case subtitle
}

/// IOS-POC-45F: what a subtitle option is, beyond its language — so a closed-caption track is not
/// an unlabelled twin of the subtitles in the same language.
public enum PlaybackSubtitleRole: String, Sendable, Equatable {
    case normal
    /// CEA-608/708 captions: AVFoundation's `.closedCaption` media type, mpv's `eia_608`.
    case closedCaptions
    /// Subtitles for the deaf and hard of hearing: dialogue transcribed and sounds described.
    case sdh
    /// Only the forced lines (foreign dialogue, signs).
    case forced

    var label: String? {
        switch self {
        case .normal: return nil
        case .closedCaptions: return "CC"
        case .sdh: return "SDH"
        case .forced: return "強制"
        }
    }
}

public struct PlaybackMediaOption: Sendable, Equatable, Identifiable {
    public static let subtitleOffID = "subtitle-off"
    /// IOS-POC-45F: subtitle codecs the bundled FFmpeg has no decoder for (MPVKit's build enables
    /// none for teletext or ARIB). Listed, labelled, never hidden: the list may drift from the build.
    public static let unsupportedSubtitleCodecs: Set<String> = ["dvb_teletext", "arib_caption"]

    public let id: String
    public let title: String?
    public let language: String?
    public let codec: String?
    public let channelCount: Int?
    public let channelLayout: String?
    public let isOff: Bool
    public let fallbackName: String
    public let subtitleRole: PlaybackSubtitleRole

    public init(id: String, title: String? = nil, language: String? = nil, codec: String? = nil,
                channelCount: Int? = nil, channelLayout: String? = nil, isOff: Bool = false,
                fallbackName: String, subtitleRole: PlaybackSubtitleRole = .normal) {
        self.id = id
        self.title = Self.trimmed(title)
        self.language = Self.trimmed(language)
        self.codec = Self.trimmed(codec)
        self.channelCount = channelCount
        self.channelLayout = Self.trimmed(channelLayout)
        self.isOff = isOff
        self.fallbackName = fallbackName
        // A caption codec says what the track is, whichever engine listed it.
        self.subtitleRole = subtitleRole == .normal && Self.isClosedCaptionCodec(codec) ? .closedCaptions : subtitleRole
    }

    /// The FFmpeg build cannot decode it: choosing it falls back to 「關閉」.
    public var isUnsupportedSubtitle: Bool {
        codec.map { Self.unsupportedSubtitleCodecs.contains($0.lowercased()) } ?? false
    }

    static func isClosedCaptionCodec(_ raw: String?) -> Bool {
        guard let key = trimmed(raw)?.lowercased().replacingOccurrences(of: "_", with: "-") else { return false }
        return ["eia-608", "eia-708", "cea-608", "cea-708", "c608", "c708"].contains(key)
    }

    public var codecDisplayName: String? { Self.normalizedCodec(codec) }

    public var channelDescription: String? {
        if let raw = channelLayout?.lowercased() {
            if raw.contains("7.1") { return "7.1" }
            if raw.contains("5.1") { return "5.1" }
            if raw.contains("stereo") { return "Stereo" }
            if raw.contains("mono") { return "Mono" }
        }
        guard let channelCount else { return nil }
        switch channelCount {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channelCount)ch"
        }
    }

    /// One presentation contract for both engines: title/language · codec · channel layout, then
    /// what kind of subtitle it is (CC, SDH, 強制) and 不支援 for a codec the build cannot decode.
    public var displayName: String {
        if isOff { return title ?? fallbackName }
        let base = title ?? Self.localizedLanguageName(language) ?? fallbackName
        var parts = [base]
        for value in [codecDisplayName, channelDescription, subtitleRole.label,
                      isUnsupportedSubtitle ? "不支援" : nil].compactMap({ $0 }) {
            if !parts.contains(where: {
                $0.caseInsensitiveCompare(value) == .orderedSame ||
                $0.localizedCaseInsensitiveContains(value)
            }) {
                parts.append(value)
            }
        }
        return parts.joined(separator: " · ")
    }

    public static func normalizedCodec(_ raw: String?) -> String? {
        guard let raw = trimmed(raw) else { return nil }
        return raw.split(separator: "/", omittingEmptySubsequences: true)
            .map { normalizedCodecComponent(String($0)) }
            .joined(separator: "/")
    }

    public static func localizedLanguageName(_ raw: String?) -> String? {
        guard let code = canonicalLanguageCode(raw), code != "und" else { return nil }
        return Locale.autoupdatingCurrent.localizedString(forLanguageCode: code)
            ?? Locale.current.localizedString(forLanguageCode: code)
            ?? raw
    }

    public static func canonicalLanguageCode(_ raw: String?) -> String? {
        guard var value = trimmed(raw)?.lowercased() else { return nil }
        value = value.replacingOccurrences(of: "_", with: "-")
        let root = value.split(separator: "-", maxSplits: 1).first.map(String.init) ?? value
        let map = [
            "eng": "en", "jpn": "ja", "zho": "zh", "chi": "zh", "cmn": "zh",
            "kor": "ko", "spa": "es", "fra": "fr", "fre": "fr",
            "deu": "de", "ger": "de", "ita": "it", "por": "pt", "rus": "ru",
            "tha": "th", "vie": "vi"
        ]
        return map[root] ?? root
    }

    private static func normalizedCodecComponent(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed.lowercased().replacingOccurrences(of: "_", with: "-")
        switch key {
        case "aac", "mp4a": return "AAC"
        case "ac3", "ac-3": return "AC-3"
        case "eac3", "e-ac-3", "ec-3": return "E-AC-3"
        case "truehd", "mlpa": return "TrueHD"
        case "dts", "dca": return "DTS"
        case "opus": return "Opus"
        case "flac": return "FLAC"
        case "alac": return "ALAC"
        case "lpcm", "pcm", "sowt", "twos", "in24", "in32", "fl32", "fl64": return "PCM"
        // IOS-POC-45F: closed captions read as what they are, not as `EIA_608`.
        case "eia-608", "eia-708", "cea-608", "cea-708", "c608", "c708": return "CC"
        default:
            if key.hasPrefix("pcm-") { return "PCM" }
            return trimmed.uppercased()
        }
    }

    private static func trimmed(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        return value
    }
}

public struct PlaybackMediaTrack: Sendable, Equatable {
    public let options: [PlaybackMediaOption]
    public let selectedID: String?

    public init(options: [PlaybackMediaOption], selectedID: String?) {
        self.options = options
        self.selectedID = selectedID
    }

    public var selectedOption: PlaybackMediaOption? {
        guard let selectedID else { return nil }
        return options.first { $0.id == selectedID }
    }
}

public struct PlaybackMediaSelection: Sendable, Equatable {
    public var subtitle: PlaybackMediaTrack?
    public var audio: PlaybackMediaTrack?

    public init(subtitle: PlaybackMediaTrack? = nil, audio: PlaybackMediaTrack? = nil) {
        self.subtitle = subtitle
        self.audio = audio
    }
}

// MARK: - IOS-POC-45: online subtitles

/// A subtitle file this playback session downloaded, as both engines are handed it: a local file
/// for mpv's `sub-add`, and its cues for the overlay AVPlayer needs. Its id is opaque like every
/// other option id, and the same under either engine, so a selection survives an engine switch.
public struct PlaybackExternalSubtitle: Sendable, Equatable, Identifiable {
    public static let idPrefix = "online-subtitle-"

    public let id: String
    public let title: String
    public let language: String?
    public let fileURL: URL
    public let cues: SubtitleCues

    public init(id: String, title: String, language: String?, fileURL: URL, cues: SubtitleCues) {
        self.id = id
        self.title = title
        self.language = language
        self.fileURL = fileURL
        self.cues = cues
    }

    public static func isExternalID(_ id: String?) -> Bool { id?.hasPrefix(idPrefix) == true }

    public var option: PlaybackMediaOption {
        PlaybackMediaOption(id: id, title: title, language: language, fallbackName: title)
    }
}

public extension PlaybackMediaTrack {
    /// An engine's embedded subtitles with the session's online ones after them, for the one
    /// subtitle list the panel shows. With nothing embedded the list still gets its 「關閉」, so the
    /// viewer can turn an online subtitle off again. The online selection, when there is one, is
    /// the selection: the engine has already turned its embedded track off for it.
    static func subtitles(embedded: PlaybackMediaTrack?, external: [PlaybackExternalSubtitle],
                          selectedExternalID: String?) -> PlaybackMediaTrack? {
        guard !external.isEmpty else { return embedded }
        var options = embedded?.options
            ?? [PlaybackMediaOption(id: PlaybackMediaOption.subtitleOffID, title: "關閉", isOff: true, fallbackName: "關閉")]
        for subtitle in external where !options.contains(where: { $0.id == subtitle.id }) {
            options.append(subtitle.option)
        }
        let selected = external.contains(where: { $0.id == selectedExternalID }) ? selectedExternalID
            : embedded?.selectedID ?? PlaybackMediaOption.subtitleOffID
        return PlaybackMediaTrack(options: options, selectedID: selected)
    }
}

// MARK: - IOS-POC-45F: when no embedded subtitle is listed

/// What the subtitle panel says when the engine lists no embedded subtitle. Never "this video has
/// none": MPV adds a caption track only once captions arrive, and AVPlayer does not list captions a
/// stream carries without declaring them, which MPV reads.
public enum SubtitleEmptyState: Sendable, Equatable {
    /// Embedded subtitles are listed.
    case none
    /// None listed yet.
    case provisional
    /// AVPlayer listed none: offer MPV.
    case tryMPV

    public static func state(engine: PlaybackEngineKind, subtitles: PlaybackMediaTrack?) -> SubtitleEmptyState {
        let embedded = subtitles?.options.contains { !$0.isOff && !PlaybackExternalSubtitle.isExternalID($0.id) } ?? false
        if embedded { return .none }
        return engine == .native ? .tryMPV : .provisional
    }
}

/// IOS-POC-45F: one log line for an engine's subtitle list — counts, kinds and codecs, never a
/// title, a language name or an address, so a device log says why nothing could be chosen.
public enum SubtitleTrackSummary {
    public static func line(engine: String, status: String, options: [PlaybackMediaOption]) -> String {
        let listed = options.filter { !$0.isOff && !PlaybackExternalSubtitle.isExternalID($0.id) }
        func count(_ role: PlaybackSubtitleRole) -> Int { listed.filter { $0.subtitleRole == role }.count }
        let codecs = Set(listed.compactMap { $0.codec?.lowercased() }).sorted()
            .map { $0.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" } }
        return "[subtitle] engine=\(engine) list=\(status) options=\(listed.count) cc=\(count(.closedCaptions))"
            + " sdh=\(count(.sdh)) forced=\(count(.forced)) unsupported=\(listed.filter(\.isUnsupportedSubtitle).count)"
            + " codecs=\(codecs.isEmpty ? "-" : codecs.joined(separator: ","))"
    }
}
