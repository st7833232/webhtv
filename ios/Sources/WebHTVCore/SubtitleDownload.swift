import Foundation

/// IOS-POC-45 — fetching for the online subtitle providers, and the checks a downloaded file has
/// to pass before any engine is handed it.

/// One HTTP answer, body included — also for an error status, whose body says whether it was a
/// challenge page.
public struct SubtitleHTTPResponse: Sendable, Equatable {
    public let status: Int
    public let mimeType: String?
    public let data: Data
    public let url: URL?

    public init(status: Int, mimeType: String? = nil, data: Data, url: URL? = nil) {
        self.status = status
        self.mimeType = mimeType
        self.data = data
        self.url = url
    }
}

/// The network, as the providers and the downloader see it: a request and a byte ceiling in, an
/// answer out. Injected, so every rule here is tested against canned pages
/// (`SubtitleHTTP.fetcher` is the real one).
public typealias SubtitleFetch = @Sendable (_ request: URLRequest, _ limit: Int) async throws -> SubtitleHTTPResponse

/// A body past its ceiling, abandoned rather than buffered.
public struct SubtitleBodyTooLarge: Error, Equatable {
    public init() {}
}

enum SubtitleFetching {
    enum Context { case page, download }

    /// One request, tried once more after a transport failure or a server error (5xx that is
    /// not a challenge page) — never after anything else, and never more than once.
    static func fetch(_ request: URLRequest, limit: Int, using fetch: SubtitleFetch,
                      retryDelay: Duration) async throws -> SubtitleHTTPResponse {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let response = try await fetch(request, limit)
                if attempt == 1, SubtitleProviderError.httpStatus(response.status).isTransient,
                   !SubtitleContent.looksLikeChallenge(SubtitleContent.text(response.data)) {
                    try await Task.sleep(for: retryDelay)
                    continue
                }
                return response
            } catch {
                let classified = SubtitleProviderError.classify(error)
                guard attempt == 1, !(error is SubtitleBodyTooLarge), classified.isTransient else { throw error }
                try await Task.sleep(for: retryDelay)
            }
        }
    }

    /// What a status means. Nil for success.
    static func failure(for response: SubtitleHTTPResponse, context: Context) -> SubtitleProviderError? {
        let status = response.status
        if (200...299).contains(status) { return nil }
        if status == 429 { return .rateLimited }
        if context == .download, status == 404 || status == 410 { return .downloadUnavailable }
        if [401, 403, 503].contains(status), SubtitleContent.looksLikeChallenge(SubtitleContent.text(response.data)) {
            return .blockedByChallenge
        }
        return .httpStatus(status)
    }
}

// MARK: - Content

/// What a downloaded file must be before it is kept: a subtitle, not an error page.
public enum SubtitleContent {
    /// Far above any real SubRip file (a feature film's is a few hundred kilobytes).
    public static let maximumBytes = 8 << 20

    /// The file's text and cues, or why it is not a subtitle. HTTP 200 with an HTML body — an
    /// error page, a login wall, a challenge — is a failure, whatever its `Content-Type` says.
    public static func validate(_ response: SubtitleHTTPResponse,
                                language: SubtitleLanguage) throws -> (text: String, cues: SubtitleCues) {
        if let failure = SubtitleFetching.failure(for: response, context: .download) { throw failure }
        guard !response.data.isEmpty else { throw SubtitleProviderError.invalidSubtitle(.empty) }
        guard response.data.count <= maximumBytes else { throw SubtitleProviderError.invalidSubtitle(.tooLarge) }
        guard let text = decode(response.data, language: language) else {
            throw SubtitleProviderError.invalidSubtitle(.undecodable)
        }
        guard !text.allSatisfy(\.isWhitespace) else { throw SubtitleProviderError.invalidSubtitle(.empty) }
        if looksLikeHTML(text) {
            throw looksLikeChallenge(text) || looksLikeCaptcha(text) ? SubtitleProviderError.blockedByChallenge
                : SubtitleProviderError.invalidSubtitle(.html)
        }
        // IOS-POC-45H: WebVTT and ASS are kept as SubRip, the one format both engines are given.
        var format = SubtitleTextFormat.of(text)
        var cues = switch format {
        case .subRip: SubRip.parse(text)
        case .webVTT: WebVTT.parse(text)
        case .ssa: SSA.parse(text)
        }
        // A SubRip file that merely looks like ASS stays SubRip, as it always was.
        if cues.isEmpty, format == .ssa {
            format = .subRip
            cues = SubRip.parse(text)
        }
        guard !cues.isEmpty else { throw SubtitleProviderError.invalidSubtitle(.noCues) }
        return (format == .subRip ? text : SubRip.serialize(cues), cues)
    }

    /// UTF-8 with or without a byte order mark, UTF-16 with one; otherwise one legacy encoding
    /// chosen by the file's language — Big5 or GB 18030 for Chinese, Shift JIS for Japanese,
    /// Windows-1252 for the rest. No statistical guessing: the cue check after this is what
    /// catches a file that decoded into nonsense timings.
    public static func decode(_ data: Data, language: SubtitleLanguage) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        if let text = String(data: data, encoding: .utf8) { return text }
        for encoding in legacyEncodings(for: language) {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return nil
    }

    static func legacyEncodings(for language: SubtitleLanguage) -> [String.Encoding] {
        func core(_ encoding: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
        }
        switch language.group {
        case .traditionalChinese: return [core(.big5_HKSCS_1999), core(.GB_18030_2000)]
        case .simplifiedChinese: return [core(.GB_18030_2000), core(.big5_HKSCS_1999)]
        case .japanese: return [.shiftJIS]
        case .english: return [.windowsCP1252]
        case .other:
            // The Windows code page each script's old files were written in.
            switch language.code.map({ String($0.prefix(2)) }) {
            case "zh": return [core(.GB_18030_2000), core(.big5_HKSCS_1999)]
            case "ko": return [core(.dosKorean)]
            case "ru", "uk", "bg", "sr", "mk", "be": return [.windowsCP1251]
            case "pl", "cs", "sk", "sl", "hr", "hu", "ro": return [.windowsCP1250]
            case "el": return [.windowsCP1253]
            case "tr": return [.windowsCP1254]
            case "he": return [core(.windowsHebrew)]
            case "ar", "fa", "ur": return [core(.windowsArabic)]
            case "th": return [core(.dosThai)]
            case "vi": return [core(.windowsVietnamese)]
            default: return [.windowsCP1252]
            }
        }
    }

    /// A body's first bytes as text, for the HTML and challenge checks.
    static func text(_ data: Data) -> String {
        String(decoding: data.prefix(64 << 10), as: UTF8.self)
    }

    /// An HTML document rather than a subtitle: the markup a page starts with, near the start.
    public static func looksLikeHTML(_ text: String) -> Bool {
        let head = text.prefix(4096).lowercased()
        let start = head.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })
        if start.hasPrefix("<!doctype") || start.hasPrefix("<html") || start.hasPrefix("<?xml")
            || start.hasPrefix("<head") || start.hasPrefix("<body") {
            return true
        }
        return ["<html", "</html>", "<body", "<head>", "<script", "<meta "].contains { head.contains($0) }
    }

    /// A bot check instead of the content: Cloudflare's challenge platform and its interstitial
    /// titles, DDoS-Guard. Only ever asked of a page that has already failed to give what was
    /// asked for — an error status, a search page with no results, a result page with no files —
    /// so an ordinary page that merely mentions one of these is never refused for it.
    public static func looksLikeChallenge(_ text: String) -> Bool {
        let body = text.lowercased()
        return [
            "cf-chl", "challenge-platform", "cf_chl_opt", "just a moment...",
            "attention required! | cloudflare", "checking your browser", "ddos-guard",
            "enable javascript and cookies to continue",
        ].contains { body.contains($0) }
    }

    /// A CAPTCHA widget. Asked only of a body that should have been a subtitle file and is HTML
    /// instead — a results page can carry a CAPTCHA on a form of its own and still be a results page.
    static func looksLikeCaptcha(_ text: String) -> Bool {
        let body = text.lowercased()
        return ["captcha", "cf-turnstile"].contains { body.contains($0) }
    }
}

// MARK: - Downloading

/// Downloads a track the viewer picked, checks it, and keeps it for this playback session. The
/// same file asked for twice in one session is handed back from the session's copy without a
/// second download — only within the session: `SubtitleSessionCache` is never reused after it.
public struct SubtitleDownloadService: Sendable {
    let fetch: SubtitleFetch
    let retryDelay: Duration

    public init(fetch: @escaping SubtitleFetch = SubtitleHTTP.fetcher(), retryDelay: Duration = .milliseconds(600)) {
        self.fetch = fetch
        self.retryDelay = retryDelay
    }

    /// `label` names the file in the subtitle list instead of its language (IOS-POC-45H: a source's
    /// own name for it); `decodingLanguage` picks the legacy encodings when the track's language
    /// does not say.
    public func download(_ track: RemoteSubtitleTrack, from provider: any SubtitleProvider,
                         into cache: SubtitleSessionCache, label: String? = nil,
                         decodingLanguage: SubtitleLanguage? = nil) async throws -> PlaybackExternalSubtitle {
        if let kept = cache.existing(for: track.downloadURL) { return kept }
        let request = try await provider.downloadRequest(for: track)
        let response: SubtitleHTTPResponse
        do {
            response = try await SubtitleFetching.fetch(request, limit: SubtitleContent.maximumBytes,
                                                        using: fetch, retryDelay: retryDelay)
        } catch is SubtitleBodyTooLarge {
            throw SubtitleProviderError.invalidSubtitle(.tooLarge)
        } catch {
            throw SubtitleProviderError.classify(error)
        }
        try Task.checkCancellation()
        if let final = response.url, !provider.acceptsDownload(from: final) {
            throw SubtitleProviderError.downloadUnavailable
        }
        let content = try SubtitleContent.validate(response, language: decodingLanguage ?? track.language)
        return try cache.store(text: content.text, cues: content.cues, for: track, label: label)
    }
}
