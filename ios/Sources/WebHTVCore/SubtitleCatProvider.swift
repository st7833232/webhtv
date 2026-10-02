import Foundation
import os

/// IOS-POC-45 — Subtitle Cat (https://www.subtitlecat.com), the first online subtitle provider.
///
/// **Plain HTTP GETs, nothing else.** The search page
/// (`index.php?search=<query>`) lists results, each linking to a result page; a result page links
/// directly to the `.srt` files it already has, one per language. Those links are all this reads.
/// No WebView, no JavaScript, no browser automation — and **never the site's Translate action**:
/// a language the page offers only to translate is not a file, is not listed, and its endpoint is
/// never called. A CAPTCHA, a challenge or a login wall is reported as the provider being
/// unavailable, never worked around.
///
/// **Reading the pages without trusting their layout.** Results are any link to a result page
/// (`/subs/<number>/<name>.html`) wherever it sits; files are any link whose path ends in `.srt`
/// on the site's own host. A file's language comes from the text the page puts next to the link,
/// then the link's own attributes, then the file name (`SubtitleLanguage.detect`). Only Subtitle
/// Cat's own host is followed, and over HTTPS.
public struct SubtitleCatProvider: SubtitleProvider {
    public static let providerID = "subtitlecat"
    public static let base = URL(string: "https://www.subtitlecat.com/")!
    public static let displayName = "Subtitle Cat"

    public let id = SubtitleCatProvider.providerID
    public let name = SubtitleCatProvider.displayName
    /// No account and no key: the direct files need neither.
    public let availability = SubtitleProviderAvailability.available

    let fetch: SubtitleFetch
    /// How many results are opened for their files. Each is one more request; the rest are
    /// counted in `SubtitleSearchResult.listedCount`, so the panel can say they were not opened.
    let maximumResults: Int
    let retryDelay: Duration

    static let log = Logger(subsystem: "com.webhtv.ios.poc", category: "subtitle")
    /// A search or result page past this is not one.
    static let maximumPageBytes = 4 << 20
    /// Pages fetched at once, out of `maximumResults`.
    static let concurrentPages = 2

    public init(fetch: @escaping SubtitleFetch = SubtitleHTTP.fetcher(), maximumResults: Int = 5,
                retryDelay: Duration = .milliseconds(600)) {
        self.fetch = fetch
        self.maximumResults = max(maximumResults, 1)
        self.retryDelay = retryDelay
    }

    // MARK: Search

    /// `https://www.subtitlecat.com/index.php?search=<query>`, the query percent-encoded byte for
    /// byte: only RFC 3986's unreserved characters stay as they are, so a space is `%20` and a `+`
    /// is `%2B` (PHP would read a bare `+` as a space), and Japanese or Chinese text goes as UTF-8.
    public static func searchURL(for query: SubtitleSearchQuery) -> URL {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = query.text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        return URL(string: "index.php?search=\(encoded)", relativeTo: base)!.absoluteURL
    }

    public func search(_ query: SubtitleSearchQuery) async throws -> SubtitleSearchResult {
        guard !query.isEmpty else { return .empty }
        let url = Self.searchURL(for: query)
        let html = try await page(url, unreadable: .searchPageUnreadable)
        let hits = try Self.searchHits(in: html, pageURL: url)
        Self.log.notice("[subtitle] subtitlecat search \"\(query.text, privacy: .public)\" results=\(hits.count)")
        guard !hits.isEmpty else { return .empty }
        let opened = Array(hits.prefix(maximumResults))

        // Opened two at a time, in result order; one result that fails does not fail the rest.
        var pages = [Int: Result<[RemoteSubtitleTrack], SubtitleProviderError>]()
        try await withThrowingTaskGroup(of: (Int, Result<[RemoteSubtitleTrack], SubtitleProviderError>).self) { group in
            var next = 0
            func add() {
                guard next < opened.count else { return }
                let index = next, hit = opened[index]
                next += 1
                group.addTask { [self] in
                    do {
                        let html = try await page(hit.url, unreadable: .detailPageUnreadable)
                        return (index, .success(try Self.tracks(in: html, pageURL: hit.url, title: hit.title)))
                    } catch {
                        let classified = SubtitleProviderError.classify(error)
                        if classified == .cancelled { throw CancellationError() }
                        return (index, .failure(classified))
                    }
                }
            }
            for _ in 0..<Self.concurrentPages { add() }
            while let (index, result) = try await group.next() {
                pages[index] = result
                add()
            }
        }
        let failures = opened.indices.compactMap { index -> SubtitleProviderError? in
            if case .failure(let error) = pages[index] { return error } else { return nil }
        }
        let tracks = opened.indices.flatMap { index -> [RemoteSubtitleTrack] in
            if case .success(let tracks) = pages[index] { return tracks } else { return [] }
        }
        Self.log.notice("[subtitle] subtitlecat opened=\(opened.count) failed=\(failures.count) files=\(tracks.count)\(failures.first.map { " first-failure=\($0.category)" } ?? "", privacy: .public)")
        // Nothing to show and something failed: the search did not work, and the reason is the
        // first failure's — "no subtitles" would hide a rate limit or a challenge.
        if tracks.isEmpty, let first = failures.first { throw first }
        return SubtitleSearchResult(tracks: SubtitleSearchResult.ordered(tracks), listedCount: hits.count,
                                    openedCount: opened.count)
    }

    /// Only the site's own host, over HTTPS — also after a redirect.
    public func acceptsDownload(from url: URL) -> Bool { Self.isOwnHost(url) }

    /// A direct GET of the file, with the result page it was found on as the referrer.
    public func downloadRequest(for track: RemoteSubtitleTrack) async throws -> URLRequest {
        var request = Self.request(track.downloadURL)
        if let detail = track.detailURL { request.setValue(detail.absoluteString, forHTTPHeaderField: "Referer") }
        request.setValue("text/plain, application/x-subrip, */*;q=0.5", forHTTPHeaderField: "Accept")
        return request
    }

    /// A page as text, once more after a transport failure or a 5xx; a status is classified, a
    /// body past `maximumPageBytes` is `unreadable`.
    private func page(_ url: URL, unreadable: SubtitleProviderError) async throws -> String {
        let response: SubtitleHTTPResponse
        do {
            response = try await SubtitleFetching.fetch(Self.request(url), limit: Self.maximumPageBytes,
                                                        using: fetch, retryDelay: retryDelay)
        } catch is SubtitleBodyTooLarge {
            throw unreadable
        } catch {
            throw SubtitleProviderError.classify(error)
        }
        Self.log.notice("[subtitle] subtitlecat GET \(url.path, privacy: .public) status=\(response.status) bytes=\(response.data.count)")
        if let failure = SubtitleFetching.failure(for: response, context: .page) { throw failure }
        // A redirect off the site, or off HTTPS, is not the page that was asked for.
        if let final = response.url, !Self.isOwnHost(final) { throw unreadable }
        return String(decoding: response.data, as: UTF8.self)
    }

    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/html,application/xhtml+xml,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: Parsing

    struct SearchHit: Equatable, Sendable {
        let title: String
        let url: URL
    }

    /// Every distinct link to a result page, in page order. No links is "no results" — unless the
    /// page is a challenge, or is not a page at all.
    static func searchHits(in html: String, pageURL: URL) throws -> [SearchHit] {
        let root = LightHTML.parse(html)
        var hits = [SearchHit]()
        var seen = Set<String>()
        for anchor in root.descendants where anchor.name == "a" {
            guard let href = anchor.attribute("href"), let url = resolve(href, against: pageURL),
                  isResultPage(url), seen.insert(url.absoluteString).inserted else { continue }
            let text = anchor.text
            hits.append(SearchHit(title: text.isEmpty ? resultName(of: url) : text, url: url))
        }
        if hits.isEmpty {
            if SubtitleContent.looksLikeChallenge(html) { throw SubtitleProviderError.blockedByChallenge }
            if !isPage(root) { throw SubtitleProviderError.searchPageUnreadable }
        }
        return hits
    }

    /// Every distinct `.srt` the page links to directly. A Translate button or link is never one,
    /// whatever its target. No files on a readable page is an empty answer, not an error: every
    /// language it lists may only be translatable.
    static func tracks(in html: String, pageURL: URL, title: String?) throws -> [RemoteSubtitleTrack] {
        let root = LightHTML.parse(html)
        var links = [(anchor: LightHTML.Element, url: URL)]()
        var seen = Set<String>()
        for anchor in root.descendants where anchor.name == "a" {
            guard let href = anchor.attribute("href"), let url = resolve(href, against: pageURL),
                  isSubtitleFile(url), !isTranslateAction(anchor),
                  seen.insert(url.absoluteString).inserted else { continue }
            links.append((anchor, url))
        }
        if links.isEmpty {
            if SubtitleContent.looksLikeChallenge(html) { throw SubtitleProviderError.blockedByChallenge }
            if !isPage(root) { throw SubtitleProviderError.detailPageUnreadable }
            return []
        }
        // How many language entries — file links and Translate controls alike — sit under each
        // element, so a link's own block, the one holding its label and no other entry, can be
        // told from the list around it. A page with one file and many Translate rows is common.
        var counts = [ObjectIdentifier: Int]()
        let translateControls = root.descendants.filter { ["a", "button"].contains($0.name) && isTranslateAction($0) }
        for entry in links.map(\.anchor) + translateControls {
            for ancestor in entry.ancestors { counts[ObjectIdentifier(ancestor), default: 0] += 1 }
        }
        return links.map { link in
            let fileName = link.url.lastPathComponent.removingPercentEncoding ?? link.url.lastPathComponent
            let context = labelContext(of: link.anchor, counts: counts)
            // Not `download=`: that is a file name, read by the file-name rule, not tokens.
            let metadata = [link.anchor.attribute("id"), link.anchor.attribute("hreflang"),
                            link.anchor.attribute("data-lang"), link.anchor.attribute("lang")]
                .compactMap { $0 } + context.metadata
            return RemoteSubtitleTrack(
                providerID: providerID, providerName: displayName,
                language: SubtitleLanguage.detect(label: context.label, metadata: metadata, fileName: fileName),
                fileName: fileName, title: title, downloadURL: link.url, detailURL: pageURL)
        }
    }

    /// The text next to a link: from the link outwards, the first block that names a language
    /// and holds no other file link, at most four levels up. Its attributes and its images' alt
    /// text are the metadata. With no language anywhere, the nearest text is still the label.
    static func labelContext(of anchor: LightHTML.Element,
                             counts: [ObjectIdentifier: Int]) -> (label: String?, metadata: [String]) {
        let own = anchor.text
        var nearest: (label: String?, metadata: [String])?
        for ancestor in anchor.ancestors.prefix(4) {
            guard counts[ObjectIdentifier(ancestor)] == 1 else { break }
            var text = ancestor.text
            if !own.isEmpty, let range = text.range(of: own) { text.removeSubrange(range) }
            for word in ["Download", "download", "DOWNLOAD", "下載", "下载"] {
                text = text.replacingOccurrences(of: word, with: " ")
            }
            text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let metadata = [ancestor.attribute("id"), ancestor.attribute("data-lang"), ancestor.attribute("lang")]
                .compactMap { $0 }
                + ancestor.descendants.filter { $0.name == "img" }
                    .flatMap { [$0.attribute("alt"), $0.attribute("title")].compactMap { $0 } }
            let label = text.isEmpty ? nil : text
            if let label, SubtitleLanguage.code(inLabel: label) != nil { return (label, metadata) }
            if nearest == nil, label != nil || !metadata.isEmpty { nearest = (label, metadata) }
        }
        return nearest ?? (nil, [])
    }

    /// The site's Translate control, as a link: its text, handler, class or id says translate.
    static func isTranslateAction(_ anchor: LightHTML.Element) -> Bool {
        let words = [anchor.text, anchor.attribute("onclick"), anchor.attribute("class"), anchor.attribute("id"),
                     anchor.attribute("title")].compactMap { $0?.lowercased() }
        return words.contains { $0.contains("translat") || $0.contains("翻譯") || $0.contains("翻译") }
    }

    /// `/subs/<number>/<name>.html` on Subtitle Cat.
    static func isResultPage(_ url: URL) -> Bool {
        guard isOwnHost(url) else { return false }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 3, parts[parts.count - 3].lowercased() == "subs",
              parts[parts.count - 2].allSatisfy(\.isNumber) else { return false }
        let name = parts[parts.count - 1].lowercased()
        return name.hasSuffix(".html") || name.hasSuffix(".htm")
    }

    static func isSubtitleFile(_ url: URL) -> Bool {
        isOwnHost(url) && url.path.lowercased().hasSuffix(".srt")
    }

    static func isOwnHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), url.scheme == "https" else { return false }
        return host == "subtitlecat.com" || host.hasSuffix(".subtitlecat.com")
    }

    /// A page link, absolute and over HTTPS. Script, anchor, mail and data links are not.
    static func resolve(_ href: String, against base: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
              !["javascript:", "mailto:", "data:", "tel:"].contains(where: { lowered.hasPrefix($0) })
        else { return nil }
        let allowed = CharacterSet.urlPathAllowed.union(CharacterSet(charactersIn: "?&=#%:+"))
        guard let url = URL(string: trimmed, relativeTo: base)
                ?? trimmed.addingPercentEncoding(withAllowedCharacters: allowed).flatMap({ URL(string: $0, relativeTo: base) }),
              var components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: false) else { return nil }
        if components.scheme?.lowercased() == "http" { components.scheme = "https" }
        components.fragment = nil
        return components.url
    }

    /// A result page's name, for a link with no text.
    static func resultName(of url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.removingPercentEncoding ?? name
    }

    /// Whether the markup is a page at all, rather than an empty or truncated body.
    static func isPage(_ root: LightHTML.Element) -> Bool {
        root.descendants.contains { ["html", "body", "head", "div", "table", "form"].contains($0.name) }
    }
}
