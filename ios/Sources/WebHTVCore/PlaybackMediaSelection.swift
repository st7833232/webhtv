import Foundation

/// Engine-neutral metadata for the embedded audio/subtitle choices shown by WebHTV.
/// Engine-specific selectors (AVMediaSelectionOption, mpv aid/sid) never escape their adapters.
public enum PlaybackMediaKind: String, Sendable, Equatable {
    case audio
    case subtitle
}

public struct PlaybackMediaOption: Sendable, Equatable, Identifiable {
    public static let subtitleOffID = "subtitle-off"

    public let id: String
    public let title: String?
    public let language: String?
    public let codec: String?
    public let channelCount: Int?
    public let channelLayout: String?
    public let isOff: Bool
    public let fallbackName: String

    public init(id: String, title: String? = nil, language: String? = nil, codec: String? = nil,
                channelCount: Int? = nil, channelLayout: String? = nil, isOff: Bool = false,
                fallbackName: String) {
        self.id = id
        self.title = Self.trimmed(title)
        self.language = Self.trimmed(language)
        self.codec = Self.trimmed(codec)
        self.channelCount = channelCount
        self.channelLayout = Self.trimmed(channelLayout)
        self.isOff = isOff
        self.fallbackName = fallbackName
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

    /// One presentation contract for both engines: title/language · codec · channel layout.
    public var displayName: String {
        if isOff { return title ?? fallbackName }
        let base = title ?? Self.localizedLanguageName(language) ?? fallbackName
        var parts = [base]
        for value in [codecDisplayName, channelDescription].compactMap({ $0 }) {
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
