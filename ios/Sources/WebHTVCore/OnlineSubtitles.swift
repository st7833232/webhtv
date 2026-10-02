import Foundation

/// IOS-POC-45 — online subtitles: the shared model every provider answers in.
///
/// **The layering.** A provider (Subtitle Cat first) turns a `SubtitleSearchQuery` into
/// `RemoteSubtitleTrack`s and, for one the viewer picks, a `URLRequest` for its file. Everything
/// after that is shared: `SubtitleDownloadService` fetches and validates the file,
/// `SubtitleSessionCache` keeps it for this playback only, and `OnlineSubtitleSession` holds what
/// the subtitle panel shows. The engines never see a provider: they are handed a
/// `PlaybackExternalSubtitle` — a local file and its cues — through `PlayerRouter`.

// MARK: - Language

/// What language a subtitle file is in, as far as the provider's page says.
///
/// Detection prefers what the page **labels** the file with ("Chinese (Traditional)"), then the
/// page's own metadata (an `id="download_zh-TW"`, a `hreflang`), and only then the file name's
/// suffix (`…-zh-TW.srt`) — the order the user asked for, because a file name is the least
/// reliable of the three.
public struct SubtitleLanguage: Sendable, Equatable, Hashable {
    /// The display order of the groups: Traditional Chinese, Simplified Chinese, Chinese whose
    /// script the page does not say, Japanese, English, then everything else in the provider's
    /// own order.
    public enum Group: Int, Sendable, Comparable, CaseIterable {
        case traditionalChinese = 0, simplifiedChinese, chinese, japanese, english, other

        public static func < (lhs: Group, rhs: Group) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The canonical code (`zh-TW`, `zh-CN`, `zh`, `ja`, `en`, `ko`, …), nil when nothing said.
    public let code: String?
    /// The provider's own words for it, kept for display when there is no code.
    public let label: String?

    public init(code: String?, label: String? = nil) {
        self.code = code
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = trimmed?.isEmpty == false ? trimmed : nil
    }

    public static let unknown = SubtitleLanguage(code: nil)

    public var group: Group {
        switch code {
        case "zh-TW", "zh-HK": return .traditionalChinese
        case "zh-CN": return .simplifiedChinese
        case "zh": return .chinese
        case "ja": return .japanese
        case "en": return .english
        default: return .other
        }
    }

    /// What the subtitle panel shows. The four ranked languages have fixed names, in the forms
    /// the user listed; any other language is named in Traditional Chinese where the platform
    /// knows it, and by the provider's label otherwise.
    public var displayName: String {
        switch code {
        case "zh-TW": return "繁體中文"
        case "zh-HK": return "繁體中文（香港）"
        case "zh-CN": return "簡體中文"
        case "zh": return "中文"
        case "ja": return "日本語"
        case "en": return "English"
        default:
            if let code, let name = Locale(identifier: "zh-Hant-TW").localizedString(forLanguageCode: code),
               name.lowercased() != code.lowercased() {
                return name
            }
            return label ?? code ?? "未知語言"
        }
    }

    /// Label first, then metadata, then the file name (see the type's comment).
    public static func detect(label: String?, metadata: [String] = [], fileName: String? = nil) -> SubtitleLanguage {
        if let label, let code = code(inLabel: label) { return .init(code: code, label: label) }
        for value in metadata {
            if let code = code(inMetadata: value) { return .init(code: code, label: label) }
        }
        if let fileName, let code = code(inFileName: fileName) { return .init(code: code, label: label) }
        return .init(code: nil, label: label)
    }

    /// A language **name** anywhere in the label, or the whole label being a code. Short codes are
    /// never searched for inside a label: "Download it" is not Italian.
    static func code(inLabel raw: String) -> String? {
        let text = normalized(raw)
        guard !text.isEmpty else { return nil }
        for (name, code) in names where text.contains(name) { return code }
        return codes[text]
    }

    /// An attribute such as `download_zh-TW`, `zh_TW` or `lang-ja`: its tokens, split on
    /// underscores, spaces, dots and slashes (hyphens stay, so `zh-TW` is one token).
    static func code(inMetadata raw: String) -> String? {
        let tokens = normalized(raw).split(whereSeparator: { "_ ./:#".contains($0) }).map(String.init)
        for token in tokens.reversed() {
            if let code = codes[token] { return code }
            // `lang-ja`, `sub-zh-tw`: a known code at the end of a hyphenated token.
            let parts = token.split(separator: "-").map(String.init)
            if parts.count >= 3, let code = codes[parts.suffix(2).joined(separator: "-")] { return code }
            if parts.count >= 2, let code = codes[parts[parts.count - 1]] { return code }
        }
        return nil
    }

    /// `name-zh-TW.srt`, `name.zh-CN.srt`, `name_ja.srt`, `name.cht.srt`: a known code at the end
    /// of the stem, after a separator.
    static func code(inFileName raw: String) -> String? {
        var stem = (raw.removingPercentEncoding ?? raw).lowercased()
        if let dot = stem.lastIndex(of: "."), stem.distance(from: dot, to: stem.endIndex) <= 5 {
            stem = String(stem[..<dot])
        }
        let parts = stem.split(whereSeparator: { "-_. ".contains($0) }).map(String.init)
        for length in [3, 2, 1] {
            guard parts.count > length else { continue }
            if let code = codes[parts.suffix(length).joined(separator: "-")] { return code }
        }
        return nil
    }

    /// Lower case, widths folded, and parentheses spaced one way — "Chinese(Traditional)",
    /// "Chinese ( Traditional )" and "Chinese (Traditional)" are the same label.
    static func normalized(_ raw: String) -> String {
        raw.precomposedStringWithCompatibilityMapping
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "(", with: " (")
            .replacingOccurrences(of: ")", with: ") ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .replacingOccurrences(of: "( ", with: "(")
            .replacingOccurrences(of: " )", with: ")")
    }

    /// Names, most specific first: "Chinese (Traditional)" also contains "chinese".
    static let names: [(String, String)] = [
        ("chinese (traditional)", "zh-TW"), ("traditional chinese", "zh-TW"),
        ("chinese traditional", "zh-TW"), ("chinese-traditional", "zh-TW"),
        ("chinese (taiwan)", "zh-TW"), ("chinese (hong kong)", "zh-HK"),
        ("繁體", "zh-TW"), ("繁体", "zh-TW"), ("正體", "zh-TW"), ("正体", "zh-TW"),
        ("chinese (simplified)", "zh-CN"), ("simplified chinese", "zh-CN"),
        ("chinese simplified", "zh-CN"), ("chinese-simplified", "zh-CN"),
        ("简体", "zh-CN"), ("簡體", "zh-CN"), ("簡体", "zh-CN"),
        ("chinese", "zh"), ("中文", "zh"), ("華語", "zh"), ("华语", "zh"),
        ("japanese", "ja"), ("日本語", "ja"), ("日本语", "ja"), ("日文", "ja"), ("日語", "ja"), ("日语", "ja"),
        ("english", "en"), ("英文", "en"), ("英語", "en"), ("英语", "en"),
        ("korean", "ko"), ("한국어", "ko"), ("韓文", "ko"), ("韩文", "ko"), ("韓語", "ko"), ("韩语", "ko"),
        ("french", "fr"), ("français", "fr"), ("german", "de"), ("deutsch", "de"),
        ("spanish", "es"), ("español", "es"), ("italian", "it"), ("italiano", "it"),
        ("portuguese (brazil)", "pt-BR"), ("portuguese", "pt"), ("português", "pt"),
        ("russian", "ru"), ("русский", "ru"), ("thai", "th"), ("ไทย", "th"),
        ("vietnamese", "vi"), ("tiếng việt", "vi"), ("indonesian", "id"), ("malayalam", "ml"),
        ("malay", "ms"), ("arabic", "ar"), ("hindi", "hi"), ("turkish", "tr"), ("polish", "pl"),
        ("dutch", "nl"), ("swedish", "sv"), ("ukrainian", "uk"), ("hebrew", "he"), ("greek", "el"),
        ("czech", "cs"), ("romanian", "ro"), ("hungarian", "hu"), ("danish", "da"), ("finnish", "fi"),
        ("norwegian", "no"), ("filipino", "tl"), ("tagalog", "tl"), ("persian", "fa"),
        ("croatian", "hr"), ("serbian", "sr"), ("bulgarian", "bg"), ("slovenian", "sl"), ("slovak", "sk"),
        ("estonian", "et"), ("lithuanian", "lt"), ("latvian", "lv"), ("bengali", "bn"), ("catalan", "ca"),
        ("macedonian", "mk"), ("albanian", "sq"), ("icelandic", "is"), ("urdu", "ur"), ("tamil", "ta"),
        ("telugu", "te"), ("khmer", "km"), ("burmese", "my"), ("mongolian", "mn"), ("georgian", "ka"),
        ("armenian", "hy"), ("afrikaans", "af"), ("basque", "eu"), ("galician", "gl"), ("swahili", "sw"),
    ]

    /// Codes as pages and file names write them, lower-cased, to the canonical form.
    static let codes: [String: String] = [
        "zh-tw": "zh-TW", "zh-hant": "zh-TW", "zh-hant-tw": "zh-TW", "cht": "zh-TW", "big5": "zh-TW",
        "zh-hk": "zh-HK", "zh-hant-hk": "zh-HK",
        "zh-cn": "zh-CN", "zh-hans": "zh-CN", "zh-hans-cn": "zh-CN", "zh-sg": "zh-CN", "chs": "zh-CN",
        "zh": "zh", "chi": "zh", "zho": "zh",
        "ja": "ja", "jpn": "ja", "jp": "ja",
        "en": "en", "eng": "en",
        "ko": "ko", "kor": "ko", "fr": "fr", "fre": "fr", "fra": "fr", "de": "de", "ger": "de", "deu": "de",
        "es": "es", "spa": "es", "it": "it", "ita": "it", "pt": "pt", "por": "pt", "pt-br": "pt-BR",
        "ru": "ru", "rus": "ru", "th": "th", "tha": "th", "vi": "vi", "vie": "vi", "id": "id", "ind": "id",
        "ms": "ms", "msa": "ms", "ar": "ar", "ara": "ar", "hi": "hi", "hin": "hi", "tr": "tr", "tur": "tr",
        "pl": "pl", "pol": "pl", "nl": "nl", "nld": "nl", "sv": "sv", "swe": "sv", "uk": "uk", "ukr": "uk",
        "he": "he", "iw": "he", "heb": "he", "el": "el", "cs": "cs", "ro": "ro", "hu": "hu", "da": "da",
        "fi": "fi", "no": "no", "tl": "tl", "fil": "tl", "fa": "fa", "ml": "ml",
        "hr": "hr", "sr": "sr", "bg": "bg", "sl": "sl", "sk": "sk", "et": "et", "lt": "lt", "lv": "lv",
        "bn": "bn", "ca": "ca", "mk": "mk", "sq": "sq", "is": "is", "ur": "ur", "ta": "ta", "te": "te",
        "km": "km", "my": "my", "mn": "mn", "ka": "ka", "hy": "hy", "af": "af", "eu": "eu", "gl": "gl",
        "sw": "sw", "be": "be",
    ]
}

// MARK: - Query and results

public enum SubtitleFormat: String, Sendable, Equatable {
    /// SubRip, the one format Subtitle Cat serves directly. WebVTT/ASS can be added here when a
    /// provider serves them and `SubtitleContent` learns to validate them.
    case srt
}

/// What is searched for — the viewer's text, verbatim apart from the whitespace at its ends.
///
/// Automatic recognition only ever **prefills** the editable field (`SubtitleSearchKeywords`);
/// whatever is in the field when the viewer searches is what goes out, untouched.
public struct SubtitleSearchQuery: Sendable, Equatable, Hashable {
    public let text: String

    public init(text: String) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isEmpty: Bool { text.isEmpty }
}

/// One file a provider can serve right now, in one language. Never a "translate" action: a
/// track exists only for a file the page already links to.
public struct RemoteSubtitleTrack: Sendable, Equatable, Identifiable {
    public let providerID: String
    public let providerName: String
    public let language: SubtitleLanguage
    /// The file's own name, as the panel shows it.
    public let fileName: String
    /// The provider's title for the result this file belongs to — the closest thing to release or
    /// version information a page gives. Nil when the page gives none.
    public let title: String?
    public let downloadURL: URL
    /// The page the file was found on, sent as the download's referrer.
    public let detailURL: URL?
    public let format: SubtitleFormat

    public init(providerID: String, providerName: String, language: SubtitleLanguage, fileName: String,
                title: String?, downloadURL: URL, detailURL: URL?, format: SubtitleFormat = .srt) {
        self.providerID = providerID
        self.providerName = providerName
        self.language = language
        self.fileName = fileName
        self.title = title
        self.downloadURL = downloadURL
        self.detailURL = detailURL
        self.format = format
    }

    /// The same file is the same track, whichever result page listed it.
    public var id: String { downloadURL.absoluteString }
}

/// A provider's answer to one query.
public struct SubtitleSearchResult: Sendable, Equatable {
    /// Already in display order (`SubtitleSearchResult.ordered`).
    public let tracks: [RemoteSubtitleTrack]
    /// How many results the provider listed, and how many of them were opened for files — so a
    /// cap is said out loud instead of reading as "that was everything".
    public let listedCount: Int
    public let openedCount: Int

    public init(tracks: [RemoteSubtitleTrack], listedCount: Int, openedCount: Int) {
        self.tracks = tracks
        self.listedCount = listedCount
        self.openedCount = openedCount
    }

    public static let empty = SubtitleSearchResult(tracks: [], listedCount: 0, openedCount: 0)

    /// Traditional Chinese, Simplified Chinese, Chinese of unstated script, Japanese, English, then
    /// the rest — each group in the order the provider gave. A stable sort, so nothing within a
    /// group is reordered, and nothing is dropped: a search tool shows every language it found.
    public static func ordered(_ tracks: [RemoteSubtitleTrack]) -> [RemoteSubtitleTrack] {
        tracks.enumerated()
            .sorted { lhs, rhs in
                lhs.element.language.group != rhs.element.language.group
                    ? lhs.element.language.group < rhs.element.language.group
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

// MARK: - Errors

/// Why the online subtitle feature could not do what was asked. The panel shows these; none of
/// them ever reaches the player, which keeps playing whatever happens here.
public enum SubtitleProviderError: Error, Equatable, Sendable, LocalizedError {
    /// No answer at all: DNS, timeout, TLS, offline, a dropped connection.
    case unreachable
    /// An HTTP status other than the ones below.
    case httpStatus(Int)
    /// HTTP 429.
    case rateLimited
    /// A CAPTCHA, Cloudflare challenge or login wall answered instead of the page. Never bypassed.
    case blockedByChallenge
    /// The search page came back but its results could not be read.
    case searchPageUnreadable
    /// A result's page came back but could not be read.
    case detailPageUnreadable
    /// The file the page linked to is gone (404/410).
    case downloadUnavailable
    /// The file arrived and is not a subtitle: empty, an HTML page, too large, undecodable, no cues.
    case invalidSubtitle(InvalidSubtitleReason)
    case cancelled
    /// A provider that needs a key or an account the viewer has not set up.
    case unconfigured

    public enum InvalidSubtitleReason: String, Sendable, Equatable {
        case empty, html, tooLarge, undecodable, noCues
    }

    /// The panel's line, naming the provider where that helps.
    public func message(provider: String) -> String {
        switch self {
        case .unreachable: return "\(provider) 暫時無法使用（連線失敗）"
        case .httpStatus(let status): return "\(provider) 暫時無法使用（HTTP \(status)）"
        case .rateLimited: return "\(provider) 請求過於頻繁，請稍後再試"
        case .blockedByChallenge: return "\(provider) 暫時無法使用（需要網頁驗證）"
        case .searchPageUnreadable: return "\(provider) 的搜尋結果無法解析"
        case .detailPageUnreadable: return "\(provider) 的字幕頁面無法解析"
        case .downloadUnavailable: return "字幕下載失敗：檔案已不存在"
        case .invalidSubtitle(let reason):
            switch reason {
            case .empty: return "字幕下載失敗：檔案是空的"
            case .html: return "字幕下載失敗：收到的是網頁而不是字幕"
            case .tooLarge: return "字幕下載失敗：檔案過大"
            case .undecodable: return "字幕下載失敗：無法辨識文字編碼"
            case .noCues: return "字幕下載失敗：檔案裡沒有字幕時間碼"
            }
        case .cancelled: return "已取消"
        case .unconfigured: return "\(provider) 尚未設定"
        }
    }

    public var errorDescription: String? { message(provider: "字幕來源") }

    /// A short category for the diagnostics line.
    public var category: String {
        switch self {
        case .unreachable: return "unreachable"
        case .httpStatus(let status): return "http-\(status)"
        case .rateLimited: return "rate-limited"
        case .blockedByChallenge: return "challenge"
        case .searchPageUnreadable: return "search-parse"
        case .detailPageUnreadable: return "detail-parse"
        case .downloadUnavailable: return "download-unavailable"
        case .invalidSubtitle(let reason): return "invalid-\(reason.rawValue)"
        case .cancelled: return "cancelled"
        case .unconfigured: return "unconfigured"
        }
    }

    /// Whatever was thrown, in these terms. A cancellation stays a cancellation; any other
    /// transport error is "unreachable", never a raw `NSError` for the panel to print.
    public static func classify(_ error: Error) -> SubtitleProviderError {
        if let error = error as? SubtitleProviderError { return error }
        if error is CancellationError { return .cancelled }
        if let url = error as? URLError, url.code == .cancelled { return .cancelled }
        return .unreachable
    }

    /// Worth one more try: a transport failure or a server error. Never a 403, 404, 429, a
    /// challenge, a parse failure or an invalid file — trying those again changes nothing.
    public var isTransient: Bool {
        switch self {
        case .unreachable: return true
        case .httpStatus(let status): return (500...599).contains(status)
        default: return false
        }
    }
}

// MARK: - Providers

/// Whether a provider can be used now. A provider that needs a key the viewer has not entered is
/// listed, disabled, with the reason — never offered as if it worked.
public enum SubtitleProviderAvailability: Sendable, Equatable {
    case available
    case unconfigured(String)
}

/// One online subtitle source. Implementations parse their own pages or APIs and answer in the
/// shared model; nothing above this protocol knows a provider's HTML.
public protocol SubtitleProvider: Sendable {
    var id: String { get }
    var name: String { get }
    var availability: SubtitleProviderAvailability { get }
    /// The files that can be downloaded right now, in display order. An empty result is "nothing
    /// found", not an error.
    func search(_ query: SubtitleSearchQuery) async throws -> SubtitleSearchResult
    /// The request that fetches one track's file. A provider whose API hands out download links
    /// asks for one here; Subtitle Cat's links are already direct.
    func downloadRequest(for track: RemoteSubtitleTrack) async throws -> URLRequest
    /// Whether a file may come from where the download ended up, redirects included.
    func acceptsDownload(from url: URL) -> Bool
}

public extension SubtitleProvider {
    func acceptsDownload(from url: URL) -> Bool { true }
}
