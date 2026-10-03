import Foundation
import os

/// IOS-POC-45G — 射手網(偽)'s website (`https://2.assrt.net`), without a token.
///
/// The viewer asked for it (2026-10-02, 「新增網頁版來源」), lifting the API-only rule for this one
/// site; `AssrtProvider` stays the API way in. Plain HTTP GETs, like `SubtitleCatProvider`: the
/// search page links to detail pages (`/xml/sub/<bucket>/<id>.xml`), and a detail page lists each
/// file of an upload with its own `onthefly("<id>","<part>","<name>")` handler, which is the
/// website's `/download/<id>/-/<part>/<name>`: one `.srt` out of an archive, never the archive.
/// Links are recognised by their URL pattern, never by the page's layout.
///
/// The patterns come from scrapers of the site (TVBox `SubtitleViewModel`, tokimo `assrt.rs`,
/// ShootingCodeTalker, scrapy_l, AdultScraperX; IOS-POC-45 §17), none of them checked live from
/// here. A challenge, a login page or the site's error page is reported, never worked around: no
/// cookie warm-up, no retry after a block, no browser User-Agent.
public struct AssrtWebProvider: SubtitleProvider {
    public static let providerID = "assrt-web"
    public static let displayName = "射手網（網頁）"
    public static let base = URL(string: "https://2.assrt.net/")!
    /// The website's hosts, which serve the same paths. Pages and their links stay on these.
    static let pageHosts: Set<String> = ["2.assrt.net", "assrt.net", "secure.assrt.net"]

    public let id = AssrtWebProvider.providerID
    public let name = AssrtWebProvider.displayName
    public let availability = SubtitleProviderAvailability.available

    let fetch: SubtitleFetch
    /// Detail pages opened per search, two at a time (the site limits concurrent requests).
    let maximumResults: Int
    let retryDelay: Duration

    static let log = Logger(subsystem: "com.webhtv.ios.poc", category: "subtitle")
    static let maximumPageBytes = 4 << 20
    static let concurrentPages = 2

    public init(fetch: @escaping SubtitleFetch = SubtitleHTTP.fetcher(), maximumResults: Int = 5,
                retryDelay: Duration = .milliseconds(600)) {
        self.fetch = fetch
        self.maximumResults = max(maximumResults, 1)
        self.retryDelay = retryDelay
    }

    // MARK: Search

    /// `https://2.assrt.net/sub/?searchword=<query>&sort=rank&no_redir=1`, the query
    /// percent-encoded byte for byte outside RFC 3986's unreserved set. `no_redir` keeps a single
    /// hit on the results page; a jump to the detail page is still handled.
    public static func searchURL(for query: SubtitleSearchQuery) -> URL {
        URL(string: "sub/?searchword=\(SubtitleAPI.encode(query.text))&sort=rank&no_redir=1", relativeTo: base)!
            .absoluteURL
    }

    public func search(_ query: SubtitleSearchQuery) async throws -> SubtitleSearchResult {
        guard !query.isEmpty else { return .empty }
        let searchURL = Self.searchURL(for: query)
        let (html, final) = try await page(searchURL, referer: nil, unreadable: .searchPageUnreadable)
        // A single hit the site opened directly.
        if let id = Self.detailID(final) {
            let hit = Hit(id: id, url: final, title: Self.pageTitle(html), label: nil, srtHint: nil)
            let tracks = try Self.tracks(in: html, pageURL: final, hit: hit)
            return SubtitleSearchResult(tracks: SubtitleSearchResult.ordered(tracks), listedCount: 1, openedCount: 1)
        }
        let hits = try Self.searchHits(in: html, pageURL: final)
        Self.log.notice("[subtitle] assrtweb search results=\(hits.count)")
        guard !hits.isEmpty else { return .empty }
        let opened = Array(Self.openingOrder(hits).prefix(maximumResults))

        var pages = [Int: Result<[RemoteSubtitleTrack], SubtitleProviderError>]()
        try await withThrowingTaskGroup(of: (Int, Result<[RemoteSubtitleTrack], SubtitleProviderError>).self) { group in
            var next = 0
            func add() {
                guard next < opened.count else { return }
                let index = next, hit = opened[index]
                next += 1
                group.addTask { [self] in
                    do {
                        let (html, final) = try await page(hit.url, referer: searchURL, unreadable: .detailPageUnreadable)
                        return (index, .success(try Self.tracks(in: html, pageURL: final, hit: hit)))
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
        var seen = Set<String>()
        let tracks = opened.indices.flatMap { index -> [RemoteSubtitleTrack] in
            if case .success(let tracks) = pages[index] { return tracks } else { return [] }
        }.filter { seen.insert($0.downloadURL.absoluteString).inserted }
        Self.log.notice("[subtitle] assrtweb opened=\(opened.count) failed=\(failures.count) files=\(tracks.count)\(failures.first.map { " first-failure=\($0.category)" } ?? "", privacy: .public)")
        if tracks.isEmpty, let first = failures.first { throw first }
        return SubtitleSearchResult(tracks: SubtitleSearchResult.ordered(tracks), listedCount: hits.count,
                                    openedCount: opened.count)
    }

    // MARK: Download

    /// The website's per-file link, fetched fresh each time (it answers with a short-lived signed
    /// redirect, which is never stored), with its detail page as the referrer.
    public func downloadRequest(for track: RemoteSubtitleTrack) async throws -> URLRequest {
        var request = URLRequest(url: track.downloadURL)
        if let detail = track.detailURL { request.setValue(detail.absoluteString, forHTTPHeaderField: "Referer") }
        request.setValue("text/plain, application/x-subrip, */*;q=0.5", forHTTPHeaderField: "Accept")
        return request
    }

    /// The website itself over HTTPS, or its file hosts (`file0.assrt.net`…), which the site
    /// documents as plain HTTP. What arrives is checked as SubRip before it is kept.
    public func acceptsDownload(from url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if url.scheme == "https", Self.pageHosts.contains(host) { return true }
        guard url.scheme == "https" || url.scheme == "http" else { return false }
        return host.range(of: #"^file\d+\.assrt\.net$"#, options: .regularExpression) != nil
    }

    // MARK: Pages

    /// A page as text and where it ended up. A redirect off the site, onto its error page or its
    /// login pages is an answer of its own.
    private func page(_ url: URL, referer: URL?, unreadable: SubtitleProviderError) async throws -> (String, URL) {
        var request = SubtitleCatProvider.request(url)
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        let response: SubtitleHTTPResponse
        do {
            response = try await SubtitleFetching.fetch(request, limit: Self.maximumPageBytes, using: fetch,
                                                        retryDelay: retryDelay)
        } catch is SubtitleBodyTooLarge {
            throw unreadable
        } catch {
            throw SubtitleProviderError.classify(error)
        }
        Self.log.notice("[subtitle] assrtweb GET \(url.path, privacy: .public) status=\(response.status) bytes=\(response.data.count)")
        if let failure = SubtitleFetching.failure(for: response, context: .page) { throw failure }
        let final = response.url ?? url
        guard Self.isPageHost(final) else { throw unreadable }
        if let blocked = Self.blockedPath(final) { throw blocked }
        return (String(decoding: response.data, as: UTF8.self), final)
    }

    /// The site's error page (`/errpage/…`, what scrapers see as HTTP 493) or its login pages.
    static func blockedPath(_ url: URL) -> SubtitleProviderError? {
        let path = url.path.lowercased()
        if path.hasPrefix("/errpage/") { return .rejected(493) }
        if path.hasPrefix("/user/") || path == "/usercp.php" { return .blockedByChallenge }
        return nil
    }

    static func isPageHost(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return pageHosts.contains(host)
    }

    /// A link on a page, absolute, on the website and over HTTPS.
    static func resolve(_ href: String, against base: URL) -> URL? {
        guard let url = SubtitleCatProvider.resolve(href, against: base), isPageHost(url) else { return nil }
        return url
    }

    // MARK: Search results

    struct Hit: Equatable, Sendable {
        let id: String
        let url: URL
        let title: String?
        /// The card's 语言 value, when it gives one.
        let label: String?
        /// From the card's 格式 or its package link: true for SubRip, false for only other formats,
        /// nil when the card does not say.
        let srtHint: Bool?
    }

    /// `/xml/sub/<bucket>/<id>.xml` → the id. The bucket is never computed, only read.
    static func detailID(_ url: URL) -> String? {
        guard isPageHost(url) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[0].lowercased() == "xml", parts[1].lowercased() == "sub",
              (1...4).contains(parts[2].count), parts[2].allSatisfy(isDigit) else { return nil }
        let file = parts[3].lowercased()
        guard file.hasSuffix(".xml") else { return nil }
        let id = String(file.dropLast(4))
        return (1...9).contains(id.count) && id.allSatisfy(isDigit) ? id : nil
    }

    static func isDigit(_ character: Character) -> Bool { character.isASCII && character.isNumber }

    /// Every distinct detail page in page order, with what its card says. None on a readable page
    /// is "no results"; a challenge, the site's error page or no page at all is not.
    static func searchHits(in html: String, pageURL: URL) throws -> [Hit] {
        let root = LightHTML.parse(html)
        var links = [(anchor: LightHTML.Element, id: String, url: URL)]()
        for anchor in root.descendants where anchor.name == "a" {
            guard let href = anchor.attribute("href"), let url = resolve(href, against: pageURL),
                  let id = detailID(url) else { continue }
            links.append((anchor, id, url))
        }
        if links.isEmpty {
            try checkBlocked(html, root: root, unreadable: .searchPageUnreadable)
            return []
        }
        // How many distinct ids each element's subtree links to, so a card (the highest ancestor
        // holding one) can be told from the list around it.
        var ids = [ObjectIdentifier: Set<String>]()
        for link in links {
            for ancestor in link.anchor.ancestors { ids[ObjectIdentifier(ancestor), default: []].insert(link.id) }
        }
        var seen = Set<String>()
        var hits = [Hit]()
        for link in links where seen.insert(link.id).inserted {
            let card = link.anchor.ancestors.prefix(6).last { ids[ObjectIdentifier($0)]?.count == 1 }
            let canonical = URL(string: "https://\(link.url.host!.lowercased())\(link.url.path)")!
            let display = link.anchor.attribute("title").flatMap(nonEmpty) ?? nonEmpty(link.anchor.text)
            let release = card.flatMap { card in
                card.descendants.first { $0.attribute("id") == "meta_top" }?.descendants.first { $0.name == "b" }
            }.flatMap { nonEmpty($0.text) }
            let fields = card.map { labelFields($0.text) } ?? [:]
            hits.append(Hit(id: link.id, url: canonical, title: release ?? display.map(joinHan),
                            label: fields["语言"], srtHint: srtHint(format: fields["格式"], card: card, pageURL: pageURL)))
        }
        return hits
    }

    /// SubRip cards and cards that do not say first, cards naming only other formats last, each
    /// group in page order. None is dropped: an upload's archive may still hold an `.srt`.
    static func openingOrder(_ hits: [Hit]) -> [Hit] {
        hits.filter { $0.srtHint != false } + hits.filter { $0.srtHint == false }
    }

    /// 格式：Subrip(srt) / SSA …, or the card's package link ending in `.srt`.
    static func srtHint(format: String?, card: LightHTML.Element?, pageURL: URL) -> Bool? {
        if let card {
            for element in card.descendants {
                for value in [element.attribute("href"), element.attribute("onclick").flatMap(locationTarget)] {
                    guard let value, let url = resolve(value, against: pageURL),
                          url.path.lowercased().hasPrefix("/download/") else { continue }
                    if url.path.lowercased().hasSuffix(".srt") { return true }
                }
            }
        }
        guard let format = format?.lowercased(), !format.isEmpty else { return nil }
        return format.contains("srt") || format.contains("subrip")
    }

    static let fieldNames = ["格式", "语言", "来源", "日期", "查阅次数", "下载次数"]

    /// `格式：… 语言：…` in a card's text.
    static func labelFields(_ text: String) -> [String: String] {
        let names = fieldNames.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: "(\(names))\\s*[：:]\\s*(.+?)(?=\\s*(?:\(names))\\s*[：:]|$)") else { return [:] }
        var fields = [String: String]()
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let name = Range(match.range(at: 1), in: text), let value = Range(match.range(at: 2), in: text) else { continue }
            fields[String(text[name])] = String(text[value]).trimmingCharacters(in: .whitespaces)
        }
        return fields
    }

    /// Search highlighting splits CJK titles; the spaces between two Han characters go.
    static func joinHan(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?<=\p{Han})\s+(?=\p{Han})"#, with: "", options: .regularExpression)
    }

    /// `<title>Daria S01 字幕 - 射手网(伪)</title>` → `Daria S01`.
    static func pageTitle(_ html: String) -> String? {
        let root = LightHTML.parse(html)
        guard let title = root.descendants.first(where: { $0.name == "title" }).flatMap({ nonEmpty($0.text) }) else { return nil }
        for suffix in [" 字幕 - 射手网(伪)", " - 射手网(伪)"] where title.hasSuffix(suffix) {
            return nonEmpty(String(title.dropLast(suffix.count)))
        }
        return title
    }

    // MARK: Detail pages

    /// The page's `.srt` files: each `onthefly` entry that names one, else a direct single-file
    /// link. An archive with no `.srt` is an empty answer; a page with no download reference at
    /// all is unreadable (a changed page should not read as "no subtitles").
    static func tracks(in html: String, pageURL: URL, hit: Hit) throws -> [RemoteSubtitleTrack] {
        let root = LightHTML.parse(html)
        let pageID = detailID(pageURL) ?? hit.id
        guard let host = pageURL.host?.lowercased() else { throw SubtitleProviderError.detailPageUnreadable }
        var files = [(name: String, url: URL)]()
        var referencesDownload = false

        // A: onthefly("<id>","<part>","<name>"), one call per handler.
        for element in root.descendants {
            guard let handler = element.attribute("onclick"), let entry = ontheflyEntry(handler) else { continue }
            referencesDownload = true
            guard entry.id == pageID, entry.part >= 1, isSubRip(entry.name) else { continue }
            let (display, segment) = pathSegment(for: entry.name)
            guard let url = URL(string: "https://\(host)/download/\(entry.id)/-/\(entry.part)/\(segment)") else { continue }
            files.append((display, url))
        }
        // B and C: per-file or single-file links written as hrefs or `location.href=` handlers.
        var singles = [(name: String, url: URL)]()
        for element in root.descendants {
            for value in [element.attribute("href"), element.attribute("onclick").flatMap(locationTarget)] {
                guard let value, let url = resolve(value, against: pageURL) else { continue }
                let parts = url.path.split(separator: "/").map(String.init)
                guard parts.count >= 3, parts[0].lowercased() == "download" else { continue }
                referencesDownload = true
                let name = parts.last!.removingPercentEncoding ?? parts.last!
                guard parts[1] == pageID, isSubRip(name) else { continue }
                if parts.count >= 5, parts[2] == "-" {
                    files.append((name, url))
                } else if parts.count == 3, parts[2] != "-" {
                    singles.append((name, url))
                }
            }
        }
        if files.isEmpty { files = singles }
        var seen = Set<String>()
        files = files.filter { seen.insert($0.url.absoluteString).inserted }
        if files.isEmpty {
            if referencesDownload {
                log.notice("[subtitle] assrtweb detail id=\(pageID, privacy: .public) archive-or-no-srt")
                return []
            }
            try checkBlocked(html, root: root, unreadable: .detailPageUnreadable)
            throw SubtitleProviderError.detailPageUnreadable
        }
        let cardLanguage = singleLanguage(hit.label)
        return files.map { file in
            // The file's own name first: one upload often holds several languages.
            var language = SubtitleLanguage.detect(label: nil, fileName: file.name)
            if language.code == nil, let cardLanguage { language = SubtitleLanguage(code: cardLanguage) }
            return RemoteSubtitleTrack(providerID: providerID, providerName: displayName, language: language,
                                       fileName: file.name, title: hit.title, downloadURL: file.url, detailURL: pageURL)
        }
    }

    /// `onthefly("710863","2","[Fan&Sub] S01E02.chs.srt")`, from one decoded handler. The name is
    /// greedy to the last quote, so quotes inside it survive; `\\ \" \' \/` are undone.
    static func ontheflyEntry(_ handler: String) -> (id: String, part: Int, name: String)? {
        let pattern = #"onthefly\(\s*(["'])(\d+)\1\s*,\s*(["'])(\d+)\3\s*,\s*(["'])(.*)\5\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: handler, range: NSRange(handler.startIndex..., in: handler)),
              let id = Range(match.range(at: 2), in: handler), let part = Range(match.range(at: 4), in: handler),
              let name = Range(match.range(at: 6), in: handler), let number = Int(handler[part]) else { return nil }
        var unescaped = ""
        var escaping = false
        for character in handler[name] {
            if escaping {
                if !"\\\"'/".contains(character) { unescaped.append("\\") }
                unescaped.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                unescaped.append(character)
            }
        }
        if escaping { unescaped.append("\\") }
        return (String(handler[id]), number, unescaped)
    }

    /// The display name and the URL path segment for an `onthefly` name. Already percent-encoded
    /// (an escape and nothing raw): kept as it is. Otherwise encoded as `encodeURIComponent` does,
    /// each folder level on its own.
    static func pathSegment(for name: String) -> (display: String, segment: String) {
        let escaped = name.range(of: "%[0-9A-Fa-f]{2}", options: .regularExpression) != nil
        let raw = name.contains { $0 == " " || $0 == "[" || $0 == "]" || $0 == "\"" || !$0.isASCII }
        if escaped, !raw { return (name.removingPercentEncoding ?? name, name) }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!'()*")
        let segment = name.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
        return (name, segment)
    }

    /// `location.href='/download/…';return false;` → its target.
    static func locationTarget(_ handler: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"location\.href\s*=\s*['"]([^'"]+)['"]"#),
              let match = regex.firstMatch(in: handler, range: NSRange(handler.startIndex..., in: handler)),
              let range = Range(match.range(at: 1), in: handler) else { return nil }
        return String(handler[range])
    }

    static func isSubRip(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasSuffix(".srt")
    }

    /// The card's 语言 when it names exactly one language (简, 繁, 英, or only 双语), for a file
    /// whose name says nothing; nil for a mixed upload.
    static func singleLanguage(_ value: String?) -> String? {
        guard let value else { return nil }
        let codes = ["简": "zh-CN", "繁": "zh-TW", "英": "en", "双语": "zh"]
        let tokens = value.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count == 1 else { return nil }
        return codes[tokens[0]]
    }

    /// No expected content: a challenge, the site's error page, or no page at all.
    static func checkBlocked(_ html: String, root: LightHTML.Element, unreadable: SubtitleProviderError) throws {
        if SubtitleContent.looksLikeChallenge(html) { throw SubtitleProviderError.blockedByChallenge }
        if html.contains("/errpage/40") { throw SubtitleProviderError.rejected(493) }
        if !SubtitleCatProvider.isPage(root) { throw unreadable }
    }

    static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
