import Foundation
import os

/// IOS-POC-45C — 射手網（Assrt, assrt.net）through its API (`https://api.assrt.net/v1/`), with
/// the viewer's own token. No scraping: `sub/search` lists results, `sub/detail` lists a result's
/// files, each with its own direct link (an archive's files are listed one by one, so nothing is
/// unpacked here). Only SubRip files are offered, as for every provider.
///
/// Requests and answers follow Bazarr's Assrt provider
/// (`morpheus65535/bazarr` master, `custom_libs/subliminal_patch/providers/assrt.py`, read
/// 2026-10-02): `token` as a query parameter, `status`/`errmsg` for the API's own errors,
/// `sub.subs[]` with `id`, `videoname`, `native_name` and `lang.langlist`, and
/// `sub.subs[0].filelist[]` with `f` and `url`.
///
/// **The token rides in the URL**, so the search and detail URLs are never logged and never sent
/// on as a referrer; a file's own link is fetched without it.
public struct AssrtProvider: SubtitleProvider {
    public static let providerID = "assrt"
    public static let displayName = "射手網（Assrt）"
    static let api = URL(string: "https://api.assrt.net/v1/")!

    public let id = AssrtProvider.providerID
    public let name = AssrtProvider.displayName
    let token: String?
    let fetch: SubtitleFetch
    /// Results opened for their files, one request each, one after another: the API counts
    /// requests per minute.
    let maximumResults: Int
    let retryDelay: Duration

    static let log = Logger(subsystem: "com.webhtv.ios.poc", category: "subtitle")

    public init(token: String?, fetch: @escaping SubtitleFetch = SubtitleHTTP.fetcher(), maximumResults: Int = 4,
                retryDelay: Duration = .milliseconds(600)) {
        let value = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.token = value.isEmpty ? nil : value
        self.fetch = fetch
        self.maximumResults = max(maximumResults, 1)
        self.retryDelay = retryDelay
    }

    public var availability: SubtitleProviderAvailability {
        token == nil ? .unconfigured("請到「設定 › 線上字幕來源」輸入你自己的射手網 API token") : .available
    }

    static func searchURL(for query: SubtitleSearchQuery, token: String) -> URL {
        URL(string: "sub/search?q=\(SubtitleAPI.encode(query.text))&token=\(SubtitleAPI.encode(token))",
            relativeTo: api)!.absoluteURL
    }

    static func detailURL(id: String, token: String) -> URL {
        URL(string: "sub/detail?id=\(SubtitleAPI.encode(id))&token=\(SubtitleAPI.encode(token))",
            relativeTo: api)!.absoluteURL
    }

    struct Hit: Equatable {
        let id: String
        let title: String?
        /// From the result's `lang.langlist`, for a file whose name says nothing.
        let language: SubtitleLanguage
    }

    // MARK: Search

    public func search(_ query: SubtitleSearchQuery) async throws -> SubtitleSearchResult {
        guard !query.isEmpty else { return .empty }
        guard let token else { throw SubtitleProviderError.unconfigured }
        let root = try await answer(Self.searchURL(for: query, token: token), unreadable: .searchPageUnreadable)
        let hits = try Self.hits(in: root)
        guard !hits.isEmpty else { return .empty }
        let opened = Array(hits.prefix(maximumResults))
        var tracks = [RemoteSubtitleTrack]()
        var failures = [SubtitleProviderError]()
        for hit in opened {
            try Task.checkCancellation()
            do {
                let detail = try await answer(Self.detailURL(id: hit.id, token: token), unreadable: .detailPageUnreadable)
                tracks += try Self.tracks(in: detail, hit: hit)
            } catch {
                let classified = SubtitleProviderError.classify(error)
                if classified == .cancelled { throw CancellationError() }
                failures.append(classified)
                // The rest would be refused for the same reason.
                if classified == .rateLimited || classified == .unauthorized { break }
            }
        }
        Self.log.notice("[subtitle] assrt results=\(hits.count) opened=\(opened.count) failed=\(failures.count) files=\(tracks.count)\(failures.first.map { " first-failure=\($0.category)" } ?? "", privacy: .public)")
        if tracks.isEmpty, let first = failures.first { throw first }
        return SubtitleSearchResult(tracks: SubtitleSearchResult.ordered(tracks), listedCount: hits.count,
                                    openedCount: opened.count)
    }

    /// The API's own error (`status` other than 0) before anything else.
    private func answer(_ url: URL, unreadable: SubtitleProviderError) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let root = try await SubtitleAPI.object(request, fetch: fetch, retryDelay: retryDelay, unreadable: unreadable)
        if let status = SubtitleAPI.integer(root["status"]), status != 0 { throw SubtitleProviderError.rejected(status) }
        return root
    }

    static func hits(in root: [String: Any]) throws -> [Hit] {
        guard let sub = root["sub"] as? [String: Any] else { throw SubtitleProviderError.searchPageUnreadable }
        let subs = sub["subs"] as? [[String: Any]] ?? []
        return subs.compactMap { item in
            guard let id = SubtitleAPI.integer(item["id"]).map(String.init) ?? SubtitleAPI.text(item["id"]) else {
                return nil
            }
            return Hit(id: id, title: title(of: item), language: language(of: item))
        }
    }

    /// `videoname`, unless it is the site's 「不知道」; else the first `native_name`.
    static func title(of item: [String: Any]) -> String? {
        if let name = SubtitleAPI.text(item["videoname"]), name != "不知道" { return name }
        if let name = SubtitleAPI.text(item["native_name"]) { return name }
        return (item["native_name"] as? [Any])?.lazy.compactMap(SubtitleAPI.text).first
    }

    /// `langlist` keys are `lang<code>`: `cht`/`twn` Traditional, `chs`/`chn` Simplified, `eng`.
    /// Both Chinese scripts is a bilingual or mixed file: Chinese, script unknown.
    static func language(of item: [String: Any]) -> SubtitleLanguage {
        let list = (item["lang"] as? [String: Any])?["langlist"] as? [String: Any] ?? [:]
        let codes = Set(list.keys.map { $0.lowercased() })
        let traditional = !codes.isDisjoint(with: ["langcht", "langtwn"])
        let simplified = !codes.isDisjoint(with: ["langchs", "langchn"])
        switch (traditional, simplified) {
        case (true, true): return SubtitleLanguage(code: "zh")
        case (true, false): return SubtitleLanguage(code: "zh-TW")
        case (false, true): return SubtitleLanguage(code: "zh-CN")
        default: return SubtitleLanguage(code: codes.contains("langeng") ? "en" : nil)
        }
    }

    /// The SubRip files of one result: every `.srt` in `filelist`, or the result's own file when
    /// it is a single one. A file's name decides its language when it says one.
    static func tracks(in root: [String: Any], hit: Hit) throws -> [RemoteSubtitleTrack] {
        guard let sub = root["sub"] as? [String: Any], let detail = (sub["subs"] as? [[String: Any]])?.first else {
            throw SubtitleProviderError.detailPageUnreadable
        }
        var files = (detail["filelist"] as? [[String: Any]] ?? []).compactMap { file -> (String, URL)? in
            guard let link = SubtitleAPI.text(file["url"]).flatMap(URL.init(string:)) else { return nil }
            return (SubtitleAPI.text(file["f"]) ?? link.lastPathComponent, link)
        }
        if files.isEmpty, let link = SubtitleAPI.text(detail["url"]).flatMap(URL.init(string:)) {
            files = [(SubtitleAPI.text(detail["filename"]) ?? link.lastPathComponent, link)]
        }
        return files.compactMap { name, link in
            guard link.scheme == "https" || link.scheme == "http",
                  name.lowercased().hasSuffix(".srt") || link.pathExtension.lowercased() == "srt" else { return nil }
            var language = SubtitleLanguage.detect(label: nil, fileName: name)
            // 「繁體」「简体」「日本語」 anywhere in the name; the Latin names are not searched for
            // inside one ("malay" is in "Himalaya").
            let lowered = name.lowercased()
            if language.code == nil, let named = SubtitleLanguage.names.first(where: { entry in
                !entry.0.allSatisfy(\.isASCII) && lowered.contains(entry.0)
            }) {
                language = SubtitleLanguage(code: named.1)
            }
            if language.code == nil { language = hit.language }
            return RemoteSubtitleTrack(providerID: providerID, providerName: displayName, language: language,
                                       fileName: name, title: hit.title, downloadURL: link, detailURL: nil)
        }
    }

    // MARK: Download

    /// The file's own link: no token, no referrer.
    public func downloadRequest(for track: RemoteSubtitleTrack) async throws -> URLRequest {
        guard token != nil else { throw SubtitleProviderError.unconfigured }
        var request = URLRequest(url: track.downloadURL)
        request.setValue("text/plain, application/x-subrip, */*;q=0.5", forHTTPHeaderField: "Accept")
        return request
    }
}
