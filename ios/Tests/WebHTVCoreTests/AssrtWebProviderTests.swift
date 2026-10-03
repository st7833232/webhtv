import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-45G. 射手網's website, read as its scrapers read it. Every page below is reconstructed
// from those scrapers (IOS-POC-45 §17), not captured: the site cannot be reached from where this
// was written. What they pin is the reading — links by URL pattern, one `.srt` out of an archive,
// and every block reported rather than worked around.

private let searchURL = AssrtWebProvider.searchURL(for: SubtitleSearchQuery(text: "Daria"))
private let darias = URL(string: "https://2.assrt.net/xml/sub/710/710863.xml")!
private let ironMan = URL(string: "https://2.assrt.net/xml/sub/678/678767.xml")!
private let ironManZh = URL(string: "https://2.assrt.net/xml/sub/31/31971.xml")!

/// S1, reconstructed: three cards; a cover link repeating the first; an SSA-only card.
private let searchPage = """
<html><head><title>Daria 字幕 - 射手网(伪)</title></head><body>
<div id="resultsdiv"><div class="resultcard">
 <div class="subitem" onmouseover="addclass(this,'subitem_hover')">
  <div class="sublist_box_title"><span class="sublist_box_title_l">
   <a class="introtitle" title="钢铁侠" href="/xml/sub/31/31971.xml">钢 铁 侠</a></span></div>
  <div id="sublist_div"><span>格式：SSA</span><span>语言：繁</span></div>
 </div>
 <div class="subitem" onmouseover="addclass(this,'subitem_hover')">
  <a class="introtitle" title="Daria" href="/xml/sub/710/710863.xml">Daria</a>
  <div id="meta_top"><b>Daria S01</b></div>
  <div id="sublist_div"><span>格式：Subrip(srt)</span><span>语言：英 简 双语</span>
   <span>日期：2025-03-01 10:20:30</span><span>下载次数：1234次</span></div>
  <a id="downsubbtn" href="#" onclick="location.href='/download/710863/Daria%20S01.zip';return false;">下载</a>
  <a href="/xml/sub/710/710863.xml?suggest_from=678767"><img alt="cover"></a>
 </div>
 <div class="subitem" onmouseover="addclass(this,'subitem_hover')">
  <a class="introtitle" title="Iron.Man.2008" href="/xml/sub/678/678767.xml">Iron.Man.2008</a>
  <div id="meta_top"><b>Iron.Man.2008.720p.BluRay</b></div>
  <div id="sublist_div"><span>格式：Subrip(srt)</span><span>语言：简</span></div>
  <a id="downsubbtn" href="#" onclick="location.href='/download/678767/movie.srt';return false;">下载</a>
 </div>
</div></div>
<div class="pagelinkcard"><a id="pl-current">1</a><a href="/sub/?searchword=Daria&amp;page=2">2</a></div>
</body></html>
"""

/// D1, reconstructed: an archive's file list, quoting varied, an `.ass` row, an encoded name.
private let archivePage = """
<?xml version="1.0" encoding="utf-8"?>
<html><head><title>Daria S01 字幕 - 射手网(伪)</title></head><body>
<div class="download"><a id="btn_download" class="waves-effect" href="/download/710863/Daria%20S01.zip">下载</a></div>
<span id="detail-filelist">
 <div class="waves-effect" onclick='onthefly("710863","1","Daria.S01E01.Esteemsters.srt")'>
  <span id="filelist-name">Daria.S01E01.Esteemsters.srt</span><span id="filelist-size">31KB</span></div>
 <div class="waves-effect" onclick='onthefly("710863","2","[Fan&amp;Sub] Daria S01E02.chs.srt")'>
  <span id="filelist-name">[Fan&amp;Sub] Daria S01E02.chs.srt</span></div>
 <div class="waves-effect" onclick='onthefly("710863","3","Daria.S01E03.ass")'>
  <span id="filelist-name">Daria.S01E03.ass</span></div>
 <div class="waves-effect" onclick="onthefly(&quot;710863&quot;,&quot;4&quot;,&quot;Daria&#39;s Diary S01E04.srt&quot;)">
  <span id="filelist-name">Daria's Diary S01E04.srt</span></div>
 <div class="waves-effect" onclick='onthefly("710863","5","Daria%20S01E05.srt")'></div>
 <div class="waves-effect" onclick='onthefly("999999","1","Elsewhere.srt")'></div>
</span></body></html>
"""

/// D2, reconstructed: a single-file upload.
private let singlePage = """
<html><body><div class="download">
 <a id="btn_download" class="waves-effect" href="/download/678767/movie.srt">下载</a></div></body></html>
"""

/// N1, reconstructed: an archive with nothing listed.
private let archiveOnlyPage = """
<html><body><div class="download"><a id="btn_download" href="/download/31971/Iron.Man.rar">下载</a></div>
<span id="detail-filelist"></span></body></html>
"""

private let challengePage = """
<html><head><title>Just a moment...</title></head><body>
<script>window._cf_chl_opt={cType:'managed'};</script><div id="challenge-platform">Checking your browser</div></body></html>
"""

private final class Pages: @unchecked Sendable {
    private let lock = NSLock()
    private var asked = [URLRequest]()
    let answers: [String: SubtitleHTTPResponse]

    init(_ answers: [String: SubtitleHTTPResponse]) { self.answers = answers }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return asked
    }

    var fetch: SubtitleFetch {
        { [self] request, _ in
            record(request)
            let key = request.url!.absoluteString
            guard let answer = answers[key] else { throw URLError(.cannotFindHost) }
            return answer
        }
    }

    private func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        asked.append(request)
    }
}

private func page(_ html: String, at url: URL, status: Int = 200) -> SubtitleHTTPResponse {
    SubtitleHTTPResponse(status: status, mimeType: "text/html", data: Data(html.utf8), url: url)
}

// MARK: - Reading the pages

@Test func theSearchIsTheSitesOwnQueryEncodedByteForByte() {
    let url = AssrtWebProvider.searchURL(for: SubtitleSearchQuery(text: "FC2-PPV 4159457+中"))
    #expect(url.absoluteString == "https://2.assrt.net/sub/?searchword=FC2-PPV%204159457%2B%E4%B8%AD&sort=rank&no_redir=1")
}

/// Results are links to detail pages, wherever they sit: one per id, the card's release name as
/// the title, SubRip cards opened before a card naming only other formats.
@Test func searchResultsAreDetailLinksOncePerIdWithSubRipCardsFirst() throws {
    let hits = try AssrtWebProvider.searchHits(in: searchPage, pageURL: searchURL)
    #expect(hits.map(\.id) == ["31971", "710863", "678767"])
    #expect(hits.map(\.url) == [ironManZh, darias, ironMan])
    #expect(hits.map(\.title) == ["钢铁侠", "Daria S01", "Iron.Man.2008.720p.BluRay"])
    #expect(hits.map(\.srtHint) == [false, true, true])
    #expect(AssrtWebProvider.openingOrder(hits).map(\.id) == ["710863", "678767", "31971"])
    #expect(hits[1].label == "英 简 双语")
    // The last field ends with its own element, not in the 下载 button after it.
    #expect(hits[2].label == "简")
}

/// A single hit kept on the results page (`no_redir`): its card is the block holding its fields,
/// not the whole page, so the filter bar's 格式 is not the card's. The title comes from whichever
/// link carries one, and the path is read lower-cased.
@Test func aLoneHitsCardIsItsOwnBlockNotThePage() throws {
    let html = """
    <html><body><div id="filter"><span>格式：SSA</span></div>
    <div id="resultsdiv"><div class="subitem">
     <a href="/XML/Sub/678/678767.XML"><img alt="cover"></a>
     <a class="introtitle" title="Iron.Man.2008" href="/xml/sub/678/678767.xml">Iron.Man.2008</a>
     <div id="sublist_div"><span>格式：Subrip(srt)</span><span>语言：简</span></div>
    </div></div></body></html>
    """
    let hits = try AssrtWebProvider.searchHits(in: html, pageURL: searchURL)
    #expect(hits.map(\.url) == [ironMan])
    #expect(hits.map(\.title) == ["Iron.Man.2008"])
    #expect(hits.map(\.srtHint) == [true] && hits.map(\.label) == ["简"])
}

/// A package link counts for its own upload only: a card linking another upload's `.srt` says
/// nothing about this one.
@Test func anotherUploadsPackageLinkSaysNothingAboutThisCard() {
    let card = LightHTML.parse(#"<div><a onclick="location.href='/download/31971/other.srt'">相關</a></div>"#)
    #expect(AssrtWebProvider.srtHint(format: "SSA", card: card, id: "678767", pageURL: searchURL) == false)
    #expect(AssrtWebProvider.srtHint(format: "SSA", card: card, id: "31971", pageURL: searchURL) == true)
}

/// One `.srt` out of an archive: each `onthefly` row naming one, built as the site's per-file
/// link; `.ass` and another upload's rows left out; names encoded as the site expects.
@Test func anArchivesSubRipFilesBecomeOneLinkEach() throws {
    let hit = AssrtWebProvider.Hit(id: "710863", url: darias, title: "Daria S01", label: "英 简 双语", srtHint: true)
    let tracks = try AssrtWebProvider.tracks(in: archivePage, pageURL: darias, hit: hit)
    #expect(tracks.map(\.downloadURL.absoluteString) == [
        "https://2.assrt.net/download/710863/-/1/Daria.S01E01.Esteemsters.srt",
        "https://2.assrt.net/download/710863/-/2/%5BFan%26Sub%5D%20Daria%20S01E02.chs.srt",
        "https://2.assrt.net/download/710863/-/4/Daria's%20Diary%20S01E04.srt",
        "https://2.assrt.net/download/710863/-/5/Daria%20S01E05.srt",
    ])
    #expect(tracks.map(\.fileName)[1] == "[Fan&Sub] Daria S01E02.chs.srt")
    #expect(tracks.map(\.fileName)[3] == "Daria S01E05.srt")
    // A mixed upload: the file's own name decides, not the card.
    #expect(tracks[1].language.code == "zh-CN" && tracks[0].language.code == nil)
    #expect(tracks.allSatisfy { $0.detailURL == darias && $0.title == "Daria S01" })
}

@Test func aSingleFileUploadIsItsOwnLinkAndTheCardsOneLanguageFillsIn() throws {
    let hit = AssrtWebProvider.Hit(id: "678767", url: ironMan, title: nil, label: "简", srtHint: true)
    let tracks = try AssrtWebProvider.tracks(in: singlePage, pageURL: ironMan, hit: hit)
    #expect(tracks.map(\.downloadURL.absoluteString) == ["https://2.assrt.net/download/678767/movie.srt"])
    #expect(tracks.first?.language.code == "zh-CN")
}

/// An archive with no `.srt` is no files, not an error: the archive itself is never fetched.
/// A page with no download reference at all is unreadable, so a changed page is not hidden.
@Test func anArchiveWithoutSubRipIsEmptyAndAPageWithoutDownloadsIsUnreadable() throws {
    let hit = AssrtWebProvider.Hit(id: "31971", url: ironManZh, title: nil, label: nil, srtHint: false)
    #expect(try AssrtWebProvider.tracks(in: archiveOnlyPage, pageURL: ironManZh, hit: hit).isEmpty)
    #expect(throws: SubtitleProviderError.detailPageUnreadable) {
        try AssrtWebProvider.tracks(in: "<html><body><div>改版了</div></body></html>", pageURL: ironManZh, hit: hit)
    }
}

/// Only this page's own upload counts: a page whose only download references are another
/// upload's is unreadable, not an archive without SubRip.
@Test func anotherUploadsLinksAreNotThisPagesDownloads() {
    let hit = AssrtWebProvider.Hit(id: "31971", url: ironManZh, title: nil, label: nil, srtHint: nil)
    for html in [#"<html><body><div onclick='onthefly("999999","1","Elsewhere.srt")'></div></body></html>"#,
                 #"<html><body><a href="/download/999999/Elsewhere.zip">下载</a></body></html>"#] {
        #expect(throws: SubtitleProviderError.detailPageUnreadable) {
            try AssrtWebProvider.tracks(in: html, pageURL: ironManZh, hit: hit)
        }
    }
}

/// A file name inside an archive is written by its uploader. One that climbs out of its path,
/// carries a query or names part 0 is dropped; a `#` is encoded, never a fragment; a Chinese
/// language word in it outranks the card's language.
@Test func uploaderWrittenNamesStayOnTheirOwnPath() throws {
    let html = """
    <html><body>
    <div onclick='onthefly("31971","1","../../../usercp.php/x.srt")'></div>
    <div onclick='onthefly("31971","2","%2E%2E/%2E%2E/x.srt")'></div>
    <div onclick='onthefly("31971","3","Iron%20Man#2.srt")'></div>
    <div onclick='onthefly("31971","0","Zero.srt")'></div>
    <div onclick='onthefly("31971","5","钢铁侠.繁体.srt")'></div>
    <a href="/download/31971/-/0/Zero.srt">0</a>
    <a href="/download/31971/-/4/Query.srt?next=/usercp.php">q</a>
    </body></html>
    """
    let hit = AssrtWebProvider.Hit(id: "31971", url: ironManZh, title: nil, label: "简", srtHint: nil)
    let tracks = try AssrtWebProvider.tracks(in: html, pageURL: ironManZh, hit: hit)
    #expect(tracks.map(\.downloadURL.absoluteString) == [
        "https://2.assrt.net/download/31971/-/3/Iron%20Man%232.srt",
        "https://2.assrt.net/download/31971/-/5/%E9%92%A2%E9%93%81%E4%BE%A0.%E7%B9%81%E4%BD%93.srt",
    ])
    #expect(tracks.allSatisfy { $0.downloadURL.fragment == nil })
    #expect(tracks.map(\.fileName) == ["Iron Man#2.srt", "钢铁侠.繁体.srt"])
    #expect(tracks.map(\.language.code) == ["zh-CN", "zh-TW"])
}

/// A challenge, the site's error page and its login pages are reported as what they are.
@Test func blocksAreReportedNotWorkedAround() {
    #expect(throws: SubtitleProviderError.blockedByChallenge) {
        try AssrtWebProvider.searchHits(in: challengePage, pageURL: searchURL)
    }
    #expect(throws: SubtitleProviderError.rejected(493)) {
        try AssrtWebProvider.searchHits(in: #"<html><body><a href="/errpage/40x">x</a></body></html>"#, pageURL: searchURL)
    }
    #expect(AssrtWebProvider.blockedPath(URL(string: "https://2.assrt.net/errpage/403")!) == .rejected(493))
    #expect(AssrtWebProvider.blockedPath(URL(string: "https://2.assrt.net/usercp.php")!) == .blockedByChallenge)
    #expect((try? AssrtWebProvider.searchHits(in: "<html><body><div id=\"resultsdiv\"></div></body></html>",
                                              pageURL: searchURL))?.isEmpty == true)
}

/// Files come from the site or its file hosts (documented as plain HTTP) and nowhere else; the
/// API host is the other provider's.
@Test func downloadsComeFromTheSiteOrItsFileHostsOnly() {
    let provider = AssrtWebProvider(fetch: { _, _ in throw URLError(.cannotFindHost) })
    #expect(provider.acceptsDownload(from: URL(string: "https://2.assrt.net/download/1/-/1/a.srt")!))
    #expect(provider.acceptsDownload(from: URL(string: "http://file0.assrt.net/onthefly/1/-/1/a.srt?_=1")!))
    #expect(!provider.acceptsDownload(from: URL(string: "http://2.assrt.net/download/1/a.srt")!))
    #expect(!provider.acceptsDownload(from: URL(string: "https://api.assrt.net/v1/x")!))
    #expect(!provider.acceptsDownload(from: URL(string: "https://evil.example/assrt.net/a.srt")!))
}

// MARK: - A whole search

/// The search opens SubRip cards first, sends each detail page the search as its referrer, and
/// lists every file found; an archive-only card adds nothing and fails nothing.
@Test func aSearchOpensTheDetailPagesAndListsTheirFiles() async throws {
    let pages = Pages([
        searchURL.absoluteString: page(searchPage, at: searchURL),
        darias.absoluteString: page(archivePage, at: darias),
        ironMan.absoluteString: page(singlePage, at: ironMan),
        ironManZh.absoluteString: page(archiveOnlyPage, at: ironManZh),
    ])
    let provider = AssrtWebProvider(fetch: pages.fetch, retryDelay: .zero)
    let result = try await provider.search(SubtitleSearchQuery(text: "Daria"))
    #expect(result.listedCount == 3 && result.openedCount == 3)
    #expect(result.tracks.count == 5)
    #expect(Set(pages.requests.dropFirst().map { $0.value(forHTTPHeaderField: "Referer") }) == [searchURL.absoluteString])
    let download = try await provider.downloadRequest(for: try #require(result.tracks.first))
    #expect(download.value(forHTTPHeaderField: "Referer") == download.url.flatMap { url in
        result.tracks.first { $0.downloadURL == url }?.detailURL?.absoluteString })
}

/// The site opening the only hit directly: read as that detail page.
@Test func aSingleHitTheSiteOpensDirectlyIsReadAsItsDetailPage() async throws {
    let pages = Pages([searchURL.absoluteString: page(singlePage, at: ironMan)])
    let result = try await AssrtWebProvider(fetch: pages.fetch, retryDelay: .zero).search(SubtitleSearchQuery(text: "Daria"))
    #expect(result.tracks.map(\.downloadURL.absoluteString) == ["https://2.assrt.net/download/678767/movie.srt"])
    #expect(pages.requests.count == 1)
}

/// A challenge on the search page stops there: no detail page is asked for.
@Test func aChallengeStopsTheSearchAtOnce() async {
    let pages = Pages([searchURL.absoluteString: page(challengePage, at: searchURL, status: 503)])
    await #expect(throws: SubtitleProviderError.blockedByChallenge) {
        _ = try await AssrtWebProvider(fetch: pages.fetch, retryDelay: .zero).search(SubtitleSearchQuery(text: "Daria"))
    }
    #expect(pages.requests.count == 1)
}

/// A block on a detail page opens nothing more: the page already in flight finishes, the rest
/// are never asked for.
@Test func aBlockOnADetailPageOpensNothingMore() async {
    let pages = Pages([
        searchURL.absoluteString: page(searchPage, at: searchURL),
        darias.absoluteString: page(challengePage, at: darias, status: 403),
        ironMan.absoluteString: page(challengePage, at: ironMan, status: 403),
        ironManZh.absoluteString: page(archiveOnlyPage, at: ironManZh),
    ])
    await #expect(throws: SubtitleProviderError.blockedByChallenge) {
        _ = try await AssrtWebProvider(fetch: pages.fetch, retryDelay: .zero).search(SubtitleSearchQuery(text: "Daria"))
    }
    #expect(pages.requests.count == 3)
    #expect(!pages.requests.contains { $0.url == ironManZh })
}

/// Landing on the site's error page is its answer, even behind a server error: asked once, never
/// retried.
@Test func theErrorPageIsAskedForOnce() async {
    let errpage = URL(string: "https://2.assrt.net/errpage/403.html")!
    let pages = Pages([searchURL.absoluteString: SubtitleHTTPResponse(
        status: 503, mimeType: "text/html", data: Data("<html><body>busy</body></html>".utf8), url: errpage)])
    await #expect(throws: SubtitleProviderError.rejected(493)) {
        _ = try await AssrtWebProvider(fetch: pages.fetch, retryDelay: .zero).search(SubtitleSearchQuery(text: "Daria"))
    }
    #expect(pages.requests.count == 1)
}
