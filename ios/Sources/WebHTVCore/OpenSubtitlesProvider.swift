import Foundation
import os

/// IOS-POC-45C — OpenSubtitles.com through its REST API (`https://api.opensubtitles.com/api/v1/`),
/// with the viewer's own API key. No scraping: a search is `GET subtitles`, a download is
/// `POST download` for a one-time link to the file, converted to SubRip by the server
/// (`sub_format: srt`). Without a login the account's downloads are limited per day; running out
/// is reported as such (HTTP 406), never worked around.
///
/// Requests and answers follow OpenSubtitles' own Kodi add-on
/// (`opensubtitles/service.subtitles.opensubtitles-com` 7acfa8f2932a0155ba921212882baa0fade05890,
/// `resources/lib/osclient/provider.py`): `Api-Key` and an application `User-Agent` on every API
/// call, `data[].attributes.files[].file_id`, and a download link in `link`.
public struct OpenSubtitlesProvider: SubtitleProvider {
    public static let providerID = "opensubtitles"
    public static let displayName = "OpenSubtitles"
    static let api = URL(string: "https://api.opensubtitles.com/api/v1/")!
    /// The four groups the panel orders by, sorted as other clients send them.
    static let languages = "en,ja,zh-cn,zh-tw"

    /// The application name the API asks every client to send.
    public static var defaultUserAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return "WebHTV v\(version)"
    }

    public let id = OpenSubtitlesProvider.providerID
    public let name = OpenSubtitlesProvider.displayName
    let apiKey: String?
    let userAgent: String
    let fetch: SubtitleFetch
    let retryDelay: Duration

    static let log = Logger(subsystem: "com.webhtv.ios.poc", category: "subtitle")

    public init(apiKey: String?, userAgent: String = OpenSubtitlesProvider.defaultUserAgent,
                fetch: @escaping SubtitleFetch = SubtitleHTTP.fetcher(), retryDelay: Duration = .milliseconds(600)) {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.apiKey = key.isEmpty ? nil : key
        self.userAgent = userAgent
        self.fetch = fetch
        self.retryDelay = retryDelay
    }

    public var availability: SubtitleProviderAvailability {
        apiKey == nil ? .unconfigured("請到「設定 › 線上字幕來源」輸入你自己的 OpenSubtitles API key") : .available
    }

    // MARK: Search

    /// Parameters in alphabetical order, as the API expects them.
    public static func searchURL(for query: SubtitleSearchQuery) -> URL {
        URL(string: "subtitles?languages=\(SubtitleAPI.encode(languages))&query=\(SubtitleAPI.encode(query.text))",
            relativeTo: api)!.absoluteURL
    }

    /// Stands for one file: the session's copy is kept under it, and `downloadRequest` reads the
    /// id back from it. Carries no key.
    static func fileURL(_ fileID: Int) -> URL {
        URL(string: "download?file_id=\(fileID)", relativeTo: api)!.absoluteURL
    }

    public func search(_ query: SubtitleSearchQuery) async throws -> SubtitleSearchResult {
        guard !query.isEmpty else { return .empty }
        let key = try requireKey()
        let root = try await SubtitleAPI.object(apiRequest(Self.searchURL(for: query), key: key), fetch: fetch,
                                                retryDelay: retryDelay, unreadable: .searchPageUnreadable)
        guard let data = root["data"] as? [[String: Any]] else { throw SubtitleProviderError.searchPageUnreadable }
        let tracks = data.flatMap(Self.tracks(in:))
        Self.log.notice("[subtitle] opensubtitles results=\(data.count) files=\(tracks.count)")
        return SubtitleSearchResult(tracks: SubtitleSearchResult.ordered(tracks), listedCount: data.count,
                                    openedCount: data.count)
    }

    /// One result's files. A result without a numeric file id has nothing to download.
    static func tracks(in item: [String: Any]) -> [RemoteSubtitleTrack] {
        guard let attributes = item["attributes"] as? [String: Any],
              let files = attributes["files"] as? [[String: Any]] else { return [] }
        let code = (attributes["language"] as? String)?.lowercased()
        let language = SubtitleLanguage(code: code.map { SubtitleLanguage.codes[$0] ?? $0 })
        let release = SubtitleAPI.text(attributes["release"])
        return files.compactMap { file in
            guard let fileID = SubtitleAPI.integer(file["file_id"]), fileID > 0 else { return nil }
            return RemoteSubtitleTrack(providerID: providerID, providerName: displayName, language: language,
                                       fileName: SubtitleAPI.text(file["file_name"]) ?? release ?? "OpenSubtitles \(fileID)",
                                       title: release, downloadURL: fileURL(fileID), detailURL: nil)
        }
    }

    // MARK: Download

    public func downloadRequest(for track: RemoteSubtitleTrack) async throws -> URLRequest {
        let key = try requireKey()
        guard let fileID = URLComponents(url: track.downloadURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "file_id" })?.value.flatMap(Int.init) else {
            throw SubtitleProviderError.downloadUnavailable
        }
        var request = apiRequest(URL(string: "download", relativeTo: Self.api)!.absoluteURL, key: key)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["file_id": fileID, "sub_format": "srt"])
        // Asked once, never retried: an answered request can count against the day's downloads.
        let root = try await SubtitleAPI.object(request, fetch: fetch, retryDelay: retryDelay, retries: false,
                                                unreadable: .downloadUnavailable,
                                                special: { $0 == 406 ? .quotaExceeded : nil })
        guard let link = SubtitleAPI.text(root["link"]).flatMap(URL.init(string:)),
              link.scheme == "https" || link.scheme == "http" else {
            throw SubtitleProviderError.downloadUnavailable
        }
        Self.log.notice("[subtitle] opensubtitles download link issued")
        // The link is the file itself; the key stays with the API.
        var file = URLRequest(url: link)
        file.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        file.setValue("text/plain, application/x-subrip, */*;q=0.5", forHTTPHeaderField: "Accept")
        return file
    }

    private func requireKey() throws -> String {
        guard let apiKey else { throw SubtitleProviderError.unconfigured }
        return apiKey
    }

    private func apiRequest(_ url: URL, key: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "Api-Key")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

/// IOS-POC-45C — what the JSON API providers share. Their URLs can carry the viewer's key (Assrt
/// takes it as a query parameter), so nothing here logs a URL, a header or a body.
enum SubtitleAPI {
    /// An API answer past this is not one.
    static let maximumBytes = 2 << 20

    /// RFC 3986's unreserved characters stay; everything else, UTF-8 percent-encoded.
    static func encode(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// One JSON object. With `retries`, a transport failure or a 5xx is tried once more; a status
    /// is classified (`special` first); a body that is not a JSON object is `unreadable`.
    static func object(_ request: URLRequest, fetch: SubtitleFetch, retryDelay: Duration, retries: Bool = true,
                       unreadable: SubtitleProviderError,
                       special: (Int) -> SubtitleProviderError? = { _ in nil }) async throws -> [String: Any] {
        let response: SubtitleHTTPResponse
        do {
            response = retries
                ? try await SubtitleFetching.fetch(request, limit: maximumBytes, using: fetch, retryDelay: retryDelay)
                : try await fetch(request, maximumBytes)
        } catch is SubtitleBodyTooLarge {
            throw unreadable
        } catch {
            throw SubtitleProviderError.classify(error)
        }
        if let failure = failure(for: response, special: special) { throw failure }
        guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw unreadable
        }
        return object
    }

    /// A challenge page and a rate limit read the same on every API; then the provider's own
    /// codes; then a refused key; then the status.
    static func failure(for response: SubtitleHTTPResponse,
                        special: (Int) -> SubtitleProviderError?) -> SubtitleProviderError? {
        guard let generic = SubtitleFetching.failure(for: response, context: .page) else { return nil }
        if generic == .blockedByChallenge || generic == .rateLimited { return generic }
        if let specific = special(response.status) { return specific }
        if response.status == 401 || response.status == 403 { return .unauthorized }
        return generic
    }

    static func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// A string with something in it.
    static func text(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }
}
