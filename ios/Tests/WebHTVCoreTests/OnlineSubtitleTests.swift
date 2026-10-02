import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-45. Search keywords, Subtitle Cat's pages, downloads and the session folder — everything
// below runs against the fixtures in `SubtitleCatFixtures.swift` and a canned fetch, never the
// live site, so a site change or a rate limit cannot fail CI. A live check is a manual smoke test.

// MARK: - Helpers

/// A fetch that answers from a table and counts what it was asked.
private final class CannedFetch: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: [SubtitleHTTPResponse]]
    private var thrown: [String: Error]
    private(set) var asked = [URLRequest]()

    init(_ answers: [String: [SubtitleHTTPResponse]] = [:], thrown: [String: Error] = [:]) {
        self.answers = answers
        self.thrown = thrown
    }

    func count(_ url: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return asked.filter { $0.url?.absoluteString == url }.count
    }

    var fetch: SubtitleFetch {
        { [self] request, _ in try respond(request) }
    }

    /// The next canned answer for the address; the last one repeats, an unknown address is a 404.
    private func respond(_ request: URLRequest) throws -> SubtitleHTTPResponse {
        lock.lock(); defer { lock.unlock() }
        asked.append(request)
        let key = request.url?.absoluteString ?? ""
        if let error = thrown[key] { throw error }
        var queue = answers[key] ?? []
        let answer = queue.isEmpty ? SubtitleHTTPResponse(status: 404, data: Data()) : queue.removeFirst()
        if queue.isEmpty, let last = answers[key]?.last { answers[key] = [last] } else { answers[key] = queue }
        return answer
    }
}

private func ok(_ text: String, mime: String = "text/html") -> SubtitleHTTPResponse {
    SubtitleHTTPResponse(status: 200, mimeType: mime, data: Data(text.utf8))
}

private let detailURL = URL(string: "https://www.subtitlecat.com/subs/1234/FC2-PPV-4159457.html")!

private func track(_ code: String?, _ name: String) -> RemoteSubtitleTrack {
    RemoteSubtitleTrack(providerID: SubtitleCatProvider.providerID, providerName: "Subtitle Cat",
                        language: SubtitleLanguage(code: code), fileName: name, title: nil,
                        downloadURL: URL(string: "https://www.subtitlecat.com/subs/1/\(name)")!, detailURL: detailURL)
}

private func temporaryRoot(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("online-subtitles-\(name)-\(UUID().uuidString)",
                                                                   isDirectory: true)
}

// MARK: - Keywords (cases 1–6)

/// Case 1. The FC2 spellings a viewer meets are one code, offered in the forms sites index it under.
@Test func fc2PPVWithAHyphenGivesEveryUsefulSpelling() {
    let keywords = SubtitleSearchKeywords.make(title: "FC2PPV-1234567 某某標題")
    #expect(keywords.code?.family == .fc2)
    #expect(keywords.prefill == "FC2-PPV-1234567")
    #expect(Array(keywords.candidates.prefix(4)) == ["FC2-PPV-1234567", "FC2PPV-1234567", "FC2PPV1234567", "1234567"])
    // The title itself stays one tap away, in case the code finds nothing.
    #expect(keywords.candidates.last == "FC2PPV-1234567 某某標題")
}

/// Case 2. The canonical spelling goes through untouched — not doubled, not split.
@Test func theCanonicalFC2SpellingIsNotBroken() {
    let code = SubtitleReleaseCode.recognize("FC2-PPV-1234567")
    #expect(code?.canonical == "FC2-PPV-1234567")
    #expect(code?.searchForms == ["FC2-PPV-1234567", "FC2PPV-1234567", "FC2PPV1234567", "1234567"])
}

/// Case 3. Run together, spaced out, lower case or full width: still the same code.
@Test(arguments: ["FC2PPV1234567", "FC2 PPV 1234567", "fc2-ppv-1234567", "[FHD] FC2PPV1234567.mp4", "ＦＣ２－ＰＰＶ－１２３４５６７"])
func everyFC2SpellingIsRecognized(_ title: String) {
    #expect(SubtitleReleaseCode.recognize(title)?.canonical == "FC2-PPV-1234567")
}

/// Case 4. A label-and-number code is written the way it is catalogued: upper case, one hyphen.
@Test(arguments: ["DLDSS553", "DLDSS-553", "dldss-553", "dldss_553", "【中字】DLDSS-553-C 標題"])
func labelNumberCodesNormalizeToOneForm(_ title: String) {
    let code = SubtitleReleaseCode.recognize(title)
    #expect(code?.family == .labelNumber)
    #expect(code?.canonical == "DLDSS-553")
    #expect(code?.searchForms == ["DLDSS-553", "DLDSS553"])
}

/// Case 5. Ordinary film and series titles are searched as titles. A code needs letters and digits
/// joined by at most a hyphen, so "Blade Runner 2049" is not "RUNNER-2049".
@Test(arguments: ["Blade Runner 2049", "進擊的巨人 第1集", "Friends S01E01", "Spider-Man 2", "WALL-E",
                  "Interstellar 2014 1080p WEB-DL x264", "COVID-19 紀錄片", "Episode-100", "第100集", "鬼滅之刃 遊郭篇 EP-101",
                  "Dune-2021", "Avatar2009"])
func ordinaryTitlesAreNotForcedIntoCodes(_ title: String) {
    let keywords = SubtitleSearchKeywords.make(title: title)
    #expect(keywords.code == nil)
    #expect(keywords.prefill == title)
}

/// No code: the title prefills, and the title without its episode is the next candidate.
@Test func aTitleWithoutACodePrefillsItselfAndOffersItsAlternatives() {
    let keywords = SubtitleSearchKeywords.make(title: "  進擊的巨人   第1集 ", alternatives: ["進擊的巨人", "進擊的巨人"])
    #expect(keywords.prefill == "進擊的巨人 第1集")
    #expect(keywords.candidates == ["進擊的巨人 第1集", "進擊的巨人"])
}

/// Case 6 (the pipeline half; the session half is in `OnlineSubtitleSessionTests`). Whatever the
/// viewer typed is the query — only the whitespace at its ends goes.
@Test func whatTheViewerTypedIsTheQueryVerbatim() {
    let typed = "  演員 名字 & Title+2 「日本語」#1 "
    #expect(SubtitleSearchQuery(text: typed).text == "演員 名字 & Title+2 「日本語」#1")
    #expect(SubtitleSearchQuery(text: " \n ").isEmpty)
}

// MARK: - Search URL (case 7)

/// Case 7. Byte-for-byte percent-encoding: a `+` must not reach PHP as a space, `&` and `#` must
/// not cut the query short, and CJK goes as UTF-8.
@Test func theSearchAddressEncodesEveryCharacterThatIsNotUnreserved() {
    func url(_ text: String) -> String { SubtitleCatProvider.searchURL(for: SubtitleSearchQuery(text: text)).absoluteString }
    #expect(url("FC2-PPV-4159457") == "https://www.subtitlecat.com/index.php?search=FC2-PPV-4159457")
    #expect(url("日本語") == "https://www.subtitlecat.com/index.php?search=%E6%97%A5%E6%9C%AC%E8%AA%9E")
    #expect(url("進擊 巨人") == "https://www.subtitlecat.com/index.php?search=%E9%80%B2%E6%93%8A%20%E5%B7%A8%E4%BA%BA")
    #expect(url("C++ & A#1/2 100% a=b?") == "https://www.subtitlecat.com/index.php?search=C%2B%2B%20%26%20A%231%2F2%20100%25%20a%3Db%3F")
    #expect(url("dldss_553~.") == "https://www.subtitlecat.com/index.php?search=dldss_553~.")
}

// MARK: - Search page (cases 8–9)

/// Case 8. Every distinct result-page link, wherever and however it is written; navigation,
/// scripts, duplicates and other hosts are not results.
@Test func theSearchPageGivesEveryResultPageOnce() throws {
    let page = SubtitleCatProvider.searchURL(for: SubtitleSearchQuery(text: "FC2-PPV-4159457"))
    let hits = try SubtitleCatProvider.searchHits(in: SubtitleCatFixture.searchPage, pageURL: page)
    #expect(hits.map(\.url.absoluteString) == [
        "https://www.subtitlecat.com/subs/1234/FC2-PPV-4159457.html",
        "https://www.subtitlecat.com/subs/998/FC2PPV-4159457-part2.html",
        "https://www.subtitlecat.com/subs/77/fc2-ppv-4159457-alt.html",
    ])
    #expect(hits.map(\.title) == ["FC2-PPV-4159457", "FC2PPV 4159457 & part 2", "fc2-ppv-4159457 alt"])
}

/// Case 9. No results is an empty answer the panel shows as 找不到字幕 — not an error, not a crash.
@Test func aSearchWithNoResultsAnswersEmpty() async throws {
    let query = SubtitleSearchQuery(text: "zzzzzzzz")
    let canned = CannedFetch([SubtitleCatProvider.searchURL(for: query).absoluteString: [ok(SubtitleCatFixture.noResultsPage)]])
    let result = try await SubtitleCatProvider(fetch: canned.fetch, retryDelay: .zero).search(query)
    #expect(result == .empty)
    #expect(try SubtitleCatProvider.searchHits(in: SubtitleCatFixture.noResultsPage,
                                               pageURL: SubtitleCatProvider.base).isEmpty)
}

/// A body that is no page at all is a parse failure, and a challenge is reported as one.
@Test func anUnreadableOrChallengedSearchPageIsAnError() {
    #expect(throws: SubtitleProviderError.searchPageUnreadable) {
        try SubtitleCatProvider.searchHits(in: "garbage without markup", pageURL: SubtitleCatProvider.base)
    }
    #expect(throws: SubtitleProviderError.blockedByChallenge) {
        try SubtitleCatProvider.searchHits(in: SubtitleCatFixture.cloudflareChallenge, pageURL: SubtitleCatProvider.base)
    }
}

// MARK: - Result page (cases 10–14)

/// Cases 10, 11, 13 and 14 on one page: every direct file, its language from the label beside it,
/// every link made absolute over HTTPS — and nothing the page only offers to translate.
@Test func theResultPageGivesItsDirectFilesWithTheirLanguages() throws {
    let tracks = try SubtitleCatProvider.tracks(in: SubtitleCatFixture.detailPage, pageURL: detailURL,
                                                title: "FC2-PPV-4159457")
    let byCode = Dictionary(tracks.map { ($0.language.code ?? "?", $0) }, uniquingKeysWith: { first, _ in first })
    #expect(tracks.map { $0.language.code ?? "?" } == ["ko", "ja", "en", "zh-CN", "zh-TW"])
    // Case 10: zh-TW, from "Chinese (<b>Traditional</b>)", a root-relative link.
    #expect(byCode["zh-TW"]?.downloadURL.absoluteString
            == "https://www.subtitlecat.com/subs/1234/FC2-PPV-4159457-zh-TW.srt")
    #expect(byCode["zh-TW"]?.fileName == "FC2-PPV-4159457-zh-TW.srt")
    #expect(byCode["zh-TW"]?.title == "FC2-PPV-4159457")
    #expect(byCode["zh-TW"]?.detailURL == detailURL)
    // Case 11: zh-CN, ja, en.
    #expect(byCode["zh-CN"]?.downloadURL.absoluteString
            == "https://www.subtitlecat.com/subs/1234/FC2-PPV-4159457-zh-CN.srt")
    // Case 13: a page-relative link resolves against the result page; http is taken over https.
    #expect(byCode["ja"]?.downloadURL.absoluteString
            == "https://www.subtitlecat.com/subs/1234/FC2-PPV-4159457-ja.srt")
    #expect(byCode["en"]?.downloadURL.absoluteString
            == "https://www.subtitlecat.com/subs/1234/FC2-PPV-4159457-en.srt")
    // Case 14: French is only a Translate button; German's Translate link points at an .srt and is
    // still a Translate action. Neither is a file, and the other host's link is not either.
    #expect(byCode["fr"] == nil)
    #expect(byCode["de"] == nil)
    #expect(!tracks.contains { $0.downloadURL.host != "www.subtitlecat.com" })
    #expect(!tracks.contains { $0.fileName.contains("script-only") })
}

/// Case 13 on its own: the three ways a page writes a link.
@Test func relativeSubtitleLinksResolveAgainstTheResultPage() {
    #expect(SubtitleCatProvider.resolve("FC2-ja.srt", against: detailURL)?.absoluteString
            == "https://www.subtitlecat.com/subs/1234/FC2-ja.srt")
    #expect(SubtitleCatProvider.resolve("/subs/9/x-en.srt", against: detailURL)?.absoluteString
            == "https://www.subtitlecat.com/subs/9/x-en.srt")
    #expect(SubtitleCatProvider.resolve("../5/y.srt#top", against: detailURL)?.absoluteString
            == "https://www.subtitlecat.com/subs/5/y.srt")
    #expect(SubtitleCatProvider.resolve("javascript:void(0)", against: detailURL) == nil)
    #expect(SubtitleCatProvider.resolve("#", against: detailURL) == nil)
}

/// The label beats the file name; with no label anywhere the file name is the fallback.
@Test func aLabelBeatsTheFileNameWhichIsOnlyTheFallback() throws {
    let page = URL(string: "https://www.subtitlecat.com/subs/55/Movie.2020.html")!
    let tracks = try SubtitleCatProvider.tracks(in: SubtitleCatFixture.tableDetailPage, pageURL: page, title: nil)
    #expect(tracks.map { $0.language.code } == ["zh-TW", "en", "ja"])
}

/// Every language only translatable: nothing to list, and no error either.
@Test func aPageWithOnlyTranslateButtonsHasNoFiles() throws {
    #expect(try SubtitleCatProvider.tracks(in: SubtitleCatFixture.translateOnlyPage, pageURL: detailURL, title: nil).isEmpty)
    #expect(throws: SubtitleProviderError.detailPageUnreadable) {
        try SubtitleCatProvider.tracks(in: "", pageURL: detailURL, title: nil)
    }
}

/// The ways pages and file names spell languages.
@Test func languagesAreReadFromLabelsMetadataAndFileNames() {
    #expect(SubtitleLanguage.detect(label: "Traditional Chinese").code == "zh-TW")
    #expect(SubtitleLanguage.detect(label: "中文（繁體）").code == "zh-TW")
    #expect(SubtitleLanguage.detect(label: "简体中文").code == "zh-CN")
    #expect(SubtitleLanguage.detect(label: "日本語").code == "ja")
    #expect(SubtitleLanguage.detect(label: "zh-TW").code == "zh-TW")
    // Short codes are never found inside words: "Download it" is no language.
    #expect(SubtitleLanguage.detect(label: "Download it").code == nil)
    #expect(SubtitleLanguage.detect(label: nil, metadata: ["download_zh-TW"]).code == "zh-TW")
    #expect(SubtitleLanguage.detect(label: nil, metadata: ["download_pt-BR"]).code == "pt-BR")
    #expect(SubtitleLanguage.detect(label: nil, fileName: "Movie.2020.cht.srt").code == "zh-TW")
    #expect(SubtitleLanguage.detect(label: nil, fileName: "Movie_zh_CN.srt").code == "zh-CN")
    #expect(SubtitleLanguage.detect(label: nil, fileName: "FC2-PPV-4159457.srt").code == nil)
    #expect(SubtitleLanguage.detect(label: "Chinese (Traditional)", fileName: "x-zh-CN.srt").code == "zh-TW")
}

// MARK: - Order (case 12)

/// Case 12. zh-TW, zh-CN, ja, en, then everything else in the provider's order — nothing hidden.
/// Chinese whose script the page does not say is neither of the first two, so it is "the rest".
@Test func resultsAreOrderedTraditionalSimplifiedJapaneseEnglishThenTheRest() {
    let tracks = [track("ko", "a-ko.srt"), track("en", "a-en.srt"), track(nil, "a.srt"), track("ja", "a-ja.srt"),
                  track("zh-CN", "a-zh-CN.srt"), track("fr", "a-fr.srt"), track("zh-TW", "a-zh-TW.srt"),
                  track("zh-TW", "b-zh-TW.srt"), track("zh", "a-zh.srt")]
    #expect(SubtitleSearchResult.ordered(tracks).map(\.fileName) == [
        "a-zh-TW.srt", "b-zh-TW.srt", "a-zh-CN.srt", "a-ja.srt", "a-en.srt", "a-ko.srt", "a.srt", "a-fr.srt", "a-zh.srt",
    ])
}

/// The whole provider: one search page, result pages opened, files listed in display order.
@Test func aSearchOpensTheResultPagesAndListsTheirFilesInOrder() async throws {
    let query = SubtitleSearchQuery(text: "FC2-PPV-4159457")
    let canned = CannedFetch([
        SubtitleCatProvider.searchURL(for: query).absoluteString: [ok(SubtitleCatFixture.searchPage)],
        detailURL.absoluteString: [ok(SubtitleCatFixture.detailPage)],
        "https://www.subtitlecat.com/subs/998/FC2PPV-4159457-part2.html": [ok(SubtitleCatFixture.translateOnlyPage)],
        // The third result fails; the others still count.
        "https://www.subtitlecat.com/subs/77/fc2-ppv-4159457-alt.html": [SubtitleHTTPResponse(status: 404, data: Data())],
    ])
    let result = try await SubtitleCatProvider(fetch: canned.fetch, maximumResults: 5, retryDelay: .zero).search(query)
    #expect(result.listedCount == 3)
    #expect(result.openedCount == 3)
    #expect(result.tracks.map { $0.language.code ?? "?" } == ["zh-TW", "zh-CN", "ja", "en", "ko"])
    // Searching downloads no subtitle: only pages were fetched.
    #expect(!canned.asked.contains { $0.url?.path.hasSuffix(".srt") == true })
}

/// A cap on opened results is reported, not silent.
@Test func resultsBeyondTheCapAreCountedAsNotOpened() async throws {
    let query = SubtitleSearchQuery(text: "FC2-PPV-4159457")
    let canned = CannedFetch([
        SubtitleCatProvider.searchURL(for: query).absoluteString: [ok(SubtitleCatFixture.searchPage)],
        detailURL.absoluteString: [ok(SubtitleCatFixture.detailPage)],
    ])
    let result = try await SubtitleCatProvider(fetch: canned.fetch, maximumResults: 1, retryDelay: .zero).search(query)
    #expect(result.listedCount == 3)
    #expect(result.openedCount == 1)
    #expect(canned.asked.count == 2)
}

// MARK: - HTTP failures and retry (case 15)

/// Case 15. 403, 404 and 429 are answered once and classified; a 5xx is tried exactly once more.
@Test(arguments: [(403, SubtitleProviderError.httpStatus(403), 1), (404, .httpStatus(404), 1),
                  (429, .rateLimited, 1), (500, .httpStatus(500), 2), (503, .httpStatus(503), 2)])
func searchStatusesAreClassifiedAndOnlyServerErrorsRetried(_ status: Int, _ expected: SubtitleProviderError,
                                                           _ attempts: Int) async {
    let query = SubtitleSearchQuery(text: "x")
    let url = SubtitleCatProvider.searchURL(for: query).absoluteString
    let canned = CannedFetch([url: [SubtitleHTTPResponse(status: status, data: Data("<html><body>error</body></html>".utf8))]])
    await #expect(throws: expected) {
        try await SubtitleCatProvider(fetch: canned.fetch, retryDelay: .zero).search(query)
    }
    #expect(canned.count(url) == attempts)
}

/// A 5xx that recovers on the retry is a normal answer.
@Test func aServerErrorThatRecoversOnTheRetryIsAnAnswer() async throws {
    let query = SubtitleSearchQuery(text: "zzzzzzzz")
    let url = SubtitleCatProvider.searchURL(for: query).absoluteString
    let canned = CannedFetch([url: [SubtitleHTTPResponse(status: 502, data: Data()), ok(SubtitleCatFixture.noResultsPage)]])
    #expect(try await SubtitleCatProvider(fetch: canned.fetch, retryDelay: .zero).search(query) == .empty)
    #expect(canned.count(url) == 2)
}

/// No answer at all is "unreachable" after one more try — never a raw NSError.
@Test func aTransportFailureIsUnreachableAfterOneRetry() async {
    let query = SubtitleSearchQuery(text: "x")
    let url = SubtitleCatProvider.searchURL(for: query).absoluteString
    let canned = CannedFetch(thrown: [url: URLError(.timedOut)])
    await #expect(throws: SubtitleProviderError.unreachable) {
        try await SubtitleCatProvider(fetch: canned.fetch, retryDelay: .zero).search(query)
    }
    #expect(canned.count(url) == 2)
}

/// A challenge is never retried and never worked around.
@Test func aChallengeIsReportedAndNotRetried() async {
    let query = SubtitleSearchQuery(text: "x")
    let url = SubtitleCatProvider.searchURL(for: query).absoluteString
    let canned = CannedFetch([url: [SubtitleHTTPResponse(status: 503, data: Data(SubtitleCatFixture.cloudflareChallenge.utf8))]])
    await #expect(throws: SubtitleProviderError.blockedByChallenge) {
        try await SubtitleCatProvider(fetch: canned.fetch, retryDelay: .zero).search(query)
    }
    #expect(canned.count(url) == 1)
}

// MARK: - Downloads (cases 15–19)

private func download(_ response: SubtitleHTTPResponse, code: String = "zh-TW", root: URL,
                      canned given: CannedFetch? = nil) async throws -> (PlaybackExternalSubtitle, SubtitleSessionCache, CannedFetch) {
    let file = track(code, "FC2-PPV-4159457-\(code).srt")
    let canned = given ?? CannedFetch([file.downloadURL.absoluteString: [response]])
    let cache = SubtitleSessionCache(root: root)
    let service = SubtitleDownloadService(fetch: canned.fetch, retryDelay: .zero)
    let subtitle = try await service.download(file, from: SubtitleCatProvider(fetch: canned.fetch), into: cache)
    return (subtitle, cache, canned)
}

/// Case 15, for a file: gone is "unavailable", a refusal is its status, and none is retried.
@Test func downloadStatusesAreClassified() async {
    let root = temporaryRoot("status")
    defer { try? FileManager.default.removeItem(at: root) }
    await #expect(throws: SubtitleProviderError.downloadUnavailable) {
        try await download(SubtitleHTTPResponse(status: 404, data: Data()), root: root)
    }
    await #expect(throws: SubtitleProviderError.httpStatus(403)) {
        try await download(SubtitleHTTPResponse(status: 403, data: Data()), root: root)
    }
    await #expect(throws: SubtitleProviderError.rateLimited) {
        try await download(SubtitleHTTPResponse(status: 429, data: Data()), root: root)
    }
}

/// Case 15, the retry rule for files: a refusal is asked once, a server error once more — and
/// never more than that.
@Test(arguments: [([403], 1, false), ([404], 1, false), ([429], 1, false), ([503, 200], 2, true), ([503], 2, false)])
func downloadsAreRetriedOnlyOnceAndOnlyAfterAServerError(_ statuses: [Int], _ attempts: Int, _ succeeds: Bool) async {
    let root = temporaryRoot("retry")
    defer { try? FileManager.default.removeItem(at: root) }
    let address = track("zh-TW", "FC2-PPV-4159457-zh-TW.srt").downloadURL.absoluteString
    let canned = CannedFetch([address: statuses.map {
        SubtitleHTTPResponse(status: $0, data: $0 == 200 ? Data(SubtitleCatFixture.srt.utf8) : Data())
    }])
    let outcome = try? await download(SubtitleHTTPResponse(status: 0, data: Data()), root: root, canned: canned)
    #expect((outcome != nil) == succeeds)
    #expect(canned.count(address) == attempts)
}

/// Case 16. HTTP 200 with a page is never handed to a player as a subtitle.
@Test func aPageServedAsTheFileIsRejected() async {
    let root = temporaryRoot("html")
    defer { try? FileManager.default.removeItem(at: root) }
    await #expect(throws: SubtitleProviderError.blockedByChallenge) {
        try await download(ok(SubtitleCatFixture.cloudflareChallenge, mime: "application/x-subrip"), root: root)
    }
    await #expect(throws: SubtitleProviderError.invalidSubtitle(.html)) {
        try await download(ok(SubtitleCatFixture.htmlErrorPage, mime: "text/plain"), root: root)
    }
    await #expect(throws: SubtitleProviderError.invalidSubtitle(.noCues)) {
        try await download(ok("just some text\nno timings here\n", mime: "text/plain"), root: root)
    }
    // Nothing invalid was ever written.
    #expect((try? FileManager.default.contentsOfDirectory(atPath: root.path))?.isEmpty ?? true)
}

/// Case 17. An empty file, or one of only whitespace, is not a subtitle.
@Test func anEmptyFileIsRejected() async {
    let root = temporaryRoot("empty")
    defer { try? FileManager.default.removeItem(at: root) }
    await #expect(throws: SubtitleProviderError.invalidSubtitle(.empty)) {
        try await download(SubtitleHTTPResponse(status: 200, data: Data()), root: root)
    }
    await #expect(throws: SubtitleProviderError.invalidSubtitle(.empty)) {
        try await download(ok(" \n\r\n ", mime: "text/plain"), root: root)
    }
}

/// Case 18. A valid file lands in this session's own folder, as UTF-8, with its cues.
@Test func aValidFileIsKeptInTheSessionFolder() async throws {
    let root = temporaryRoot("valid")
    defer { try? FileManager.default.removeItem(at: root) }
    let (subtitle, cache, _) = try await download(ok(SubtitleCatFixture.srt, mime: "application/x-subrip"), root: root)
    #expect(subtitle.fileURL.deletingLastPathComponent() == cache.directory)
    #expect(cache.directory.deletingLastPathComponent() == root)
    #expect(cache.directory.lastPathComponent.hasPrefix(SubtitleSessionCache.sessionPrefix))
    #expect(try String(contentsOf: subtitle.fileURL, encoding: .utf8) == SubtitleCatFixture.srt)
    #expect(subtitle.cues.cues.count == 2)
    #expect(subtitle.language == "zh-TW")
    #expect(subtitle.title == "繁體中文（Subtitle Cat）")
    #expect(PlaybackExternalSubtitle.isExternalID(subtitle.id))
}

/// Case 19. A UTF-8 byte order mark is read through and not written back.
@Test func aByteOrderMarkIsHandled() async throws {
    let root = temporaryRoot("bom")
    defer { try? FileManager.default.removeItem(at: root) }
    let bom = Data([0xEF, 0xBB, 0xBF]) + Data(SubtitleCatFixture.srt.utf8)
    let (subtitle, _, _) = try await download(SubtitleHTTPResponse(status: 200, mimeType: "text/plain", data: bom), root: root)
    #expect(subtitle.cues.cues.first?.text == "你好，這是第一句。")
    let written = try Data(contentsOf: subtitle.fileURL)
    #expect(!written.starts(with: [0xEF, 0xBB, 0xBF]))
}

/// UTF-16 with its byte order mark decodes too.
@Test func utf16WithAByteOrderMarkDecodes() {
    let data = Data([0xFF, 0xFE]) + SubtitleCatFixture.srt.data(using: .utf16LittleEndian)!
    #expect(SubtitleContent.decode(data, language: SubtitleLanguage(code: "zh-TW")) == SubtitleCatFixture.srt)
}

/// The same file twice in one session is one download.
@Test func theSameFileTwiceInASessionIsDownloadedOnce() async throws {
    let root = temporaryRoot("dedupe")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = track("zh-TW", "a-zh-TW.srt")
    let canned = CannedFetch([file.downloadURL.absoluteString: [ok(SubtitleCatFixture.srt, mime: "text/plain")]])
    let cache = SubtitleSessionCache(root: root)
    let service = SubtitleDownloadService(fetch: canned.fetch, retryDelay: .zero)
    let provider = SubtitleCatProvider(fetch: canned.fetch)
    let first = try await service.download(file, from: provider, into: cache)
    let second = try await service.download(file, from: provider, into: cache)
    #expect(first == second)
    #expect(canned.count(file.downloadURL.absoluteString) == 1)
    // The request names the page the file was found on.
    #expect(canned.asked.first?.value(forHTTPHeaderField: "Referer") == detailURL.absoluteString)
}

/// A second file in the same language gets its own name in the list.
@Test func twoFilesInOneLanguageAreToldApart() throws {
    let root = temporaryRoot("names")
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = SubtitleSessionCache(root: root)
    let cues = SubRip.parse(SubtitleCatFixture.srt)
    let first = try cache.store(text: SubtitleCatFixture.srt, cues: cues, for: track("zh-TW", "a-zh-TW.srt"))
    let second = try cache.store(text: SubtitleCatFixture.srt, cues: cues, for: track("zh-TW", "b-zh-TW.srt"))
    #expect(first.title == "繁體中文（Subtitle Cat）")
    #expect(second.title == "繁體中文（Subtitle Cat） 2")
    #expect(first.id != second.id)
}

// MARK: - Session folder (cases 22–23)

/// Case 22, the folder's half: ending the session deletes its files, and nothing more is written.
@Test func endingTheSessionDeletesItsFolder() throws {
    let root = temporaryRoot("end")
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = SubtitleSessionCache(root: root)
    let subtitle = try cache.store(text: SubtitleCatFixture.srt, cues: SubRip.parse(SubtitleCatFixture.srt),
                                   for: track("ja", "a-ja.srt"))
    #expect(FileManager.default.fileExists(atPath: subtitle.fileURL.path))
    cache.end()
    #expect(!FileManager.default.fileExists(atPath: cache.directory.path))
    #expect(cache.existing(for: URL(string: "https://www.subtitlecat.com/subs/1/a-ja.srt")!) == nil)
    #expect(throws: SubtitleProviderError.cancelled) {
        try cache.store(text: SubtitleCatFixture.srt, cues: SubRip.parse(SubtitleCatFixture.srt), for: track("ja", "b-ja.srt"))
    }
}

/// Case 23. Launch removes the session folders a crash or force quit left — only those: not the
/// rest of the temporary directory, not other files in this feature's folder, not a live session.
@Test func launchCleanupRemovesOnlyThisFeaturesStaleSessionFolders() throws {
    let manager = FileManager.default
    let tmp = temporaryRoot("launch")
    defer { try? manager.removeItem(at: tmp) }
    let root = tmp.appendingPathComponent(SubtitleSessionCache.directoryName, isDirectory: true)
    let stale = [root.appendingPathComponent("session-\(UUID().uuidString)"),
                 root.appendingPathComponent("session-\(UUID().uuidString)")]
    let live = root.appendingPathComponent("session-\(UUID().uuidString)")
    let other = root.appendingPathComponent("not-a-session")
    let neighbour = tmp.appendingPathComponent("session-belongs-to-someone-else")
    for folder in stale + [live, other, neighbour] {
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("1\n00:00:01,000 --> 00:00:02,000\nx\n".utf8).write(to: folder.appendingPathComponent("a.srt"))
    }
    let looseFile = root.appendingPathComponent("session-file.srt")
    try Data("x".utf8).write(to: looseFile)

    #expect(SubtitleSessionCache.removeStaleSessions(root: root, except: [live]) == 2)
    for folder in stale { #expect(!manager.fileExists(atPath: folder.path)) }
    #expect(manager.fileExists(atPath: live.path))
    #expect(manager.fileExists(atPath: other.path))
    #expect(manager.fileExists(atPath: neighbour.path))
    #expect(manager.fileExists(atPath: looseFile.path))
    // No folder at all is nothing to do.
    #expect(SubtitleSessionCache.removeStaleSessions(root: tmp.appendingPathComponent("missing")) == 0)
}

/// Names the file system and mpv both take.
@Test func storedFileNamesAreSafe() {
    #expect(SubtitleSessionCache.safeName("FC2-PPV-4159457-zh-TW.srt") == "FC2-PPV-4159457-zh-TW.srt")
    #expect(SubtitleSessionCache.safeName("../../etc/passwd") == "etc_passwd.srt")
    #expect(SubtitleSessionCache.safeName("進擊 巨人.srt") == "subtitle.srt")
    #expect(SubtitleSessionCache.safeName(String(repeating: "a", count: 300) + ".srt").count == 80)
}

// MARK: - SubRip

/// The cues the AVPlayer overlay draws: tags gone, lines kept, gaps empty.
@Test func subRipCuesAreFoundByTime() {
    let cues = SubRip.parse(SubtitleCatFixture.srt)
    #expect(cues.cues.count == 2)
    #expect(cues.text(at: 0.5) == nil)
    #expect(cues.text(at: 1) == "你好，這是第一句。")
    #expect(cues.text(at: 3.5) == nil)
    #expect(cues.text(at: 5) == "第二句\n第二行")
    #expect(cues.text(at: 6) == nil)
}

/// CRLF, no counters, a dot before the milliseconds; overlapping cues show together.
@Test func subRipIsReadTheWayPlayersReadIt() {
    #expect(SubRip.parse(SubtitleCatFixture.srtCRLFNoCounters).cues.map(\.text) == ["One", "Two"])
    let overlapping = SubRip.parse("1\n00:00:01,000 --> 00:00:05,000\nA\n\n2\n00:00:02,000 --> 00:00:03,000\n{\\an8}B\n")
    #expect(overlapping.text(at: 2.5) == "A\nB")
    #expect(overlapping.text(at: 4) == "A")
    // A block that lost its blank line still ends where the next timing starts.
    let squashed = SubRip.parse("1\n00:00:01,000 --> 00:00:02,000\nA\n2\n00:00:03,000 --> 00:00:04,000\nB\n")
    #expect(squashed.cues.map(\.text) == ["A", "B"])
    #expect(SubRip.parse("00:00:05,000 --> 00:00:04,000\nbackwards\n").isEmpty)
}

// MARK: - The panel's list

/// Online subtitles follow the embedded ones in one list; with nothing embedded there is still a
/// 「關閉」, and an online selection is the selection.
@Test func onlineSubtitlesJoinTheEmbeddedList() {
    let file = URL(fileURLWithPath: "/tmp/a.srt")
    let online = PlaybackExternalSubtitle(id: "online-subtitle-1", title: "繁體中文（Subtitle Cat）", language: "zh-TW",
                                          fileURL: file, cues: SubtitleCues([]))
    let embedded = PlaybackMediaTrack(options: [
        .init(id: PlaybackMediaOption.subtitleOffID, title: "關閉", isOff: true, fallbackName: "關閉"),
        .init(id: "native-subtitle-0", title: "English", fallbackName: "字幕 1"),
    ], selectedID: "native-subtitle-0")
    let merged = PlaybackMediaTrack.subtitles(embedded: embedded, external: [online], selectedExternalID: nil)
    #expect(merged?.options.map(\.id) == [PlaybackMediaOption.subtitleOffID, "native-subtitle-0", "online-subtitle-1"])
    #expect(merged?.selectedID == "native-subtitle-0")
    let chosen = PlaybackMediaTrack.subtitles(embedded: embedded, external: [online], selectedExternalID: "online-subtitle-1")
    #expect(chosen?.selectedID == "online-subtitle-1")
    let alone = PlaybackMediaTrack.subtitles(embedded: nil, external: [online], selectedExternalID: nil)
    #expect(alone?.options.map(\.id) == [PlaybackMediaOption.subtitleOffID, "online-subtitle-1"])
    #expect(alone?.selectedID == PlaybackMediaOption.subtitleOffID)
    #expect(PlaybackMediaTrack.subtitles(embedded: embedded, external: [], selectedExternalID: nil) == embedded)
}

// MARK: - Review hardening

/// Untrusted pages: thousands of tags that never close still parse, on a concurrency thread's
/// small stack, and the file inside is still found.
@Test func deeplyNestedMarkupIsBoundedAndStillRead() async throws {
    let html = String(repeating: "<span>", count: 5000)
        + #"Japanese <a href="/subs/1/x-ja.srt">Download</a>"# + String(repeating: "</i>", count: 5000)
    let tracks = try await Task.detached {
        try SubtitleCatProvider.tracks(in: html, pageURL: detailURL, title: nil)
    }.value
    #expect(tracks.map(\.downloadURL.path) == ["/subs/1/x-ja.srt"])
}

/// One file among Translate rows — a common Subtitle Cat page — keeps its own row's label, even
/// for a language the name table does not know: it is never given a Translate row's language.
@Test func aSingleFileAmongTranslateRowsKeepsItsOwnLanguage() throws {
    let html = #"""
    <div class="all-sub">
      <div class="sub-single"><span>Croatian</span><span><a id="download_hr" href="/subs/1/Movie-hr.srt">Download</a></span></div>
      <div class="sub-single"><span>Chinese (Traditional)</span><span><button onclick="translate_from_server_folder('zh-TW','Movie.srt','/subs/1/')">Translate</button></span></div>
      <div class="sub-single"><span>Tok Pisin</span><span><a id="download_tpi" href="/subs/1/Movie-tpi.srt">Download</a></span></div>
      <div class="sub-single"><span>English</span><span><button onclick="translate_from_server_folder('en','Movie.srt','/subs/1/')">Translate</button></span></div>
    </div>
    """#
    let tracks = try SubtitleCatProvider.tracks(in: html, pageURL: detailURL, title: nil)
    #expect(tracks.map { $0.language.code } == ["hr", nil])
    #expect(tracks.last?.language.displayName == "Tok Pisin")
    #expect(tracks.last?.language.group == .other)
}

/// A file name in `download=` is a file name: "El.Camino.2019" is not Greek.
@Test func aDownloadAttributeIsNotReadAsLanguageTokens() throws {
    let html = #"<div><a download="El.Camino.2019.srt" href="/subs/1/El.Camino.2019.srt">Download</a></div>"#
    #expect(try SubtitleCatProvider.tracks(in: html, pageURL: detailURL, title: nil).first?.language.code == nil)
}

/// Results that loaded with nothing to download, beside results that were refused, is the
/// refusal — not "no subtitles", which would hide a rate limit.
@Test func refusedResultsAreNotReportedAsNoSubtitles() async {
    let query = SubtitleSearchQuery(text: "FC2-PPV-4159457")
    let canned = CannedFetch([
        SubtitleCatProvider.searchURL(for: query).absoluteString: [ok(SubtitleCatFixture.searchPage)],
        detailURL.absoluteString: [ok(SubtitleCatFixture.translateOnlyPage)],
        "https://www.subtitlecat.com/subs/998/FC2PPV-4159457-part2.html": [SubtitleHTTPResponse(status: 429, data: Data())],
        "https://www.subtitlecat.com/subs/77/fc2-ppv-4159457-alt.html": [SubtitleHTTPResponse(status: 429, data: Data())],
    ])
    await #expect(throws: SubtitleProviderError.rateLimited) {
        try await SubtitleCatProvider(fetch: canned.fetch, retryDelay: .zero).search(query)
    }
}

/// A redirect off the site is neither the page nor the file that was asked for.
@Test func aRedirectOffTheSiteIsRefused() async {
    let query = SubtitleSearchQuery(text: "x")
    let url = SubtitleCatProvider.searchURL(for: query).absoluteString
    let elsewhere = URL(string: "https://login.example/wall")!
    let page = CannedFetch([url: [SubtitleHTTPResponse(status: 200, data: Data(SubtitleCatFixture.searchPage.utf8), url: elsewhere)]])
    await #expect(throws: SubtitleProviderError.searchPageUnreadable) {
        try await SubtitleCatProvider(fetch: page.fetch, retryDelay: .zero).search(query)
    }
    let root = temporaryRoot("redirect")
    defer { try? FileManager.default.removeItem(at: root) }
    await #expect(throws: SubtitleProviderError.downloadUnavailable) {
        try await download(SubtitleHTTPResponse(status: 200, data: Data(SubtitleCatFixture.srt.utf8),
                                                url: URL(string: "http://www.subtitlecat.com/subs/1/x.srt")!), root: root)
    }
}

/// A word joined to a year is a title; a code written in capitals with a year-like number is
/// still a code.
@Test func yearsJoinedToWordsAreTitlesNotCodes() {
    #expect(SubtitleReleaseCode.recognize("Dune-2021") == nil)
    #expect(SubtitleReleaseCode.recognize("Avatar2009 1080p") == nil)
    #expect(SubtitleReleaseCode.recognize("SSNI-1999")?.canonical == "SSNI-1999")
}

/// An old Cyrillic file decodes in its own code page, not as Latin mojibake.
@Test func legacyFilesDecodeInTheirLanguagesCodePage() throws {
    let timing = "1\n00:00:01,000 --> 00:00:02,000\n"
    // "Привет" in Windows-1251, which is not valid UTF-8.
    let data = Data(timing.utf8) + Data([0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2, 0x0A])
    #expect(SubtitleContent.decode(data, language: SubtitleLanguage(code: "ru")) == timing + "Привет\n")
}

// MARK: - IOS-POC-45B: 時間軸校正

/// Positive means later, the way mpv's `sub-delay` reads, so the overlay and mpv move a line the
/// same way for the same value: a cue at 10–12 s with +0.5 s shows from 10.5 s until 12.5 s.
@Test func aPositiveDelayShowsTheSameLineLaterOnBothEngines() {
    let cues = SubtitleCues([SubtitleCue(start: 10, end: 12, text: "台詞")])
    #expect(cues.text(at: 10.4, delay: 0.5) == nil)
    #expect(cues.text(at: 10.5, delay: 0.5) == "台詞")
    #expect(cues.text(at: 12.4, delay: 0.5) == "台詞")
    #expect(cues.text(at: 12.5, delay: 0.5) == nil)
    #expect(cues.text(at: 9.5, delay: -0.5) == "台詞")
    #expect(cues.text(at: 11.5, delay: -0.5) == nil)
}

/// Ten taps of +0.1 must read +1.0, not +0.9999; a runaway value stops at the limit; and the
/// label shows the direction the viewer moved.
@Test func theDelayStaysOnTenthsAndWithinItsLimit() {
    var delay = 0.0
    for _ in 0..<10 { delay = SubtitleDelay.clamped(delay + 0.1) }
    #expect(delay == 1.0)
    #expect(SubtitleDelay.label(delay) == "+1.0 秒")
    #expect(SubtitleDelay.label(SubtitleDelay.clamped(delay - 2.2)) == "-1.2 秒")
    #expect(SubtitleDelay.label(0) == "0.0 秒")
    #expect(SubtitleDelay.clamped(10_000) == SubtitleDelay.limit)
    #expect(SubtitleDelay.clamped(-10_000) == -SubtitleDelay.limit)
    #expect(SubtitleDelay.clamped(.nan) == 0)
}

/// The control is offered only where it moves what is on screen: under AVPlayer an embedded
/// track cannot be moved, so offering it there would be a button that does nothing.
@Test func theCorrectionIsOfferedOnlyWhereItMovesTheSubtitleOnScreen() {
    let online = "online-subtitle-1"
    #expect(PlaybackExternalSubtitle.isExternalID(online))
    #expect(SubtitleDelay.applies(to: .mpv, selectedSubtitleID: "2"))
    #expect(SubtitleDelay.applies(to: .mpv, selectedSubtitleID: online))
    #expect(SubtitleDelay.applies(to: .native, selectedSubtitleID: online))
    #expect(!SubtitleDelay.applies(to: .native, selectedSubtitleID: "embedded-0"))
    #expect(!SubtitleDelay.applies(to: .mpv, selectedSubtitleID: PlaybackMediaOption.subtitleOffID))
    #expect(!SubtitleDelay.applies(to: .mpv, selectedSubtitleID: nil))
}
