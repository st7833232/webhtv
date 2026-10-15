import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-57B-16 (W-42): Djuu.js against m.djuu.com pages. Manager #2158 B1: the gate's own copies were lost, so
// these are W-117's live copies of 2026-10-13 (the library list and the out-of-range page are byte-identical to the
// gate's; folder page 1 had new songs) and a search page fetched once on 2026-10-15 08:14:05 UTC. Expected values
// come from those pages through a separate parser (task document §3), plus hand-made edge replies.

/// Answers m.djuu.com by path and remembers every request, its method, headers and body.
final class DjuuSite: URLProtocol, @unchecked Sendable {
    struct Seen { let url: URL; let method: String; let headers: [String: String]; let body: String }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) private static var seen: [Seen] = []

    static func serve(_ served: [String: Data], status: [String: Int] = [:]) {
        lock.withLock { replies = served.mapValues { (200, $0) }.merging(status.mapValues { ($0, Data()) }) { _, new in new }; seen = [] }
    }
    static var requests: [Seen] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        let reply = Self.lock.withLock { () -> (status: Int, body: Data) in
            Self.seen.append(Seen(url: url, method: request.httpMethod ?? "GET", headers: request.allHTTPHeaderFields ?? [:],
                                  body: String(decoding: body, as: UTF8.self)))
            return Self.replies[url.path] ?? (404, Data())
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil,
                                                               headerFields: ["Content-Type": "text/html"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private struct FixtureMismatch: Error {}

/// A fetched page, raw-deflated and base64-encoded, checked against the SHA-256 recorded when it was fetched.
private func fixture(_ packed: String, sha256: String) throws -> Data {
    guard let deflated = Data(base64Encoded: packed, options: .ignoreUnknownCharacters) else { throw FixtureMismatch() }
    let data = try (deflated as NSData).decompressed(using: .zlib) as Data
    guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else { throw FixtureMismatch() }
    return data
}

/// The gate's own djlist.html (a11672a5…), returned again byte for byte on 2026-10-13.
private func library() throws -> Data { try fixture(djlistPacked, sha256: "a11672a5747e91995e30ca7de2b3054c7053004316aa47395d968794d1d7ad76") }
private func folder() throws -> Data { try fixture(folderPacked, sha256: "2afe44f77ff0be0cb054e68e29ab39619af0efca78157f86974cbf277a0b1e69") }
/// The gate's own folder-p9999.html (a0c3aded…): 200, the list name, nine stray data-bs-id, no song.
private func emptyPage() throws -> Data { try fixture(emptyPagePacked, sha256: "a0c3aded529e2e431b08782069bad503d82a8208a7777263d0d8b573af6cca2b") }
private func searchPage() throws -> Data { try fixture(searchPacked, sha256: "6f723b88f74a9818c25154a326382f3cca041f8a27b0a9f265137b97f383ebde") }
private func play() throws -> Data { try fixture(playPacked, sha256: "0072248cf2174e4c228ca1cf25f0896145c8559d84a732e1d110a9af90d38e8e") }

private let site = "https://m.djuu.com"
private let chrome = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"
/// Requests send the Referer without a trailing slash, images and playback with one (Djuu.java:45, :57, :234).
private let requestHeaders = ["User-Agent": chrome, "Referer": site]
private func image(_ path: String) -> String { site + path + #"@Headers={"User-Agent":"\#(chrome)","Referer":"https://m.djuu.com/"}"# }
private let logo = image("/static/mobile/images/play/logo.png")
private let firstFolder = "/djlist/115_0_1_{pg}.html"

private func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DjuuSite.self]
    return URLSession(configuration: configuration)
}

private let suite = "Djuu-test"

private func spider() async throws -> JavaScriptSpiderRuntime {
    let registry = SpiderRegistry.bundled()
    let runtime = try JavaScriptSpiderRuntime(
        name: "Djuu", script: try #require(registry.entry(for: "csp_Djuu")?.script), prelude: registry.prelude,
        storage: SpiderStorage(siteKey: suite, defaults: UserDefaults(suiteName: suite)!), session: session())
    try await runtime.initialize(extend: "")
    return runtime
}

private func client() async throws -> SourceClient {
    let site = try JSONDecoder().decode(Site.self, from: Data(#"{"key":"dj","name":"呦呦 • DJ","type":3,"api":"csp_Djuu"}"#.utf8))
    return .spider(SpiderSession(site: site, runtime: try await spider()), site)
}

private func object(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}
private func list(_ text: String) throws -> [[String: Any]] { try #require(try object(text)["list"] as? [[String: Any]]) }
private func strings(_ items: [[String: Any]], _ key: String) -> [String] { items.map { $0[key] as? String ?? "<none>" } }
private func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
private var urls: [String] { DjuuSite.requests.map(\.url.absoluteString) }

/// A hand-made folder page: the list name and songs as (data-bs-id, name); `nil` leaves the attribute out.
private func folderPage(_ name: String, _ songs: [(String?, String)]) -> Data {
    let items = songs.map { id, title in
        #"<div class="container djuu-list-item"\#(id.map { #" data-bs-id="\#($0)""# } ?? "")><div class="me-2"><span>\#(title)</span><div>ID:\#(id ?? "")</div></div></div>"#
    }.joined()
    return Data(#"<html><body><div class="fs-4">\#(name)</div><div id="djuu-musiclist-djlist">\#(items)</div></body></html>"#.utf8)
}

@Suite(.serialized) struct DjuuSpiderTests {
    // D22: the registry drives csp_Djuu from its own file (RED before this task).
    @Test func registryDrivesDjuu() {
        #expect(SpiderRegistry.bundled().canDrive("csp_Djuu"))
        #expect(SpiderRegistry.aliases["Djuu"] == nil)
    }

    // D02: one category, 曲库, and no filters, without a request.
    @Test func homeIsTheLibraryAlone() async throws {
        DjuuSite.serve([:])
        let home = try object(try await spider().homeContent(filter: true))
        #expect((home["class"] as? [[String: String]]) == [["type_id": "djlist", "type_name": "曲库"]])
        #expect(home["filters"] == nil)
        #expect(DjuuSite.requests.isEmpty)
    }

    // D01, D03, D04, D06, DJ-04: the eleven playlists of div.my-3 div.mb-2, in order, as folders with header images.
    @Test func theLibraryListsElevenFolders() async throws {
        DjuuSite.serve(["/djlist": try library()])
        let items = try list(try await spider().categoryContent(tid: "djlist", page: "1", filter: false, extend: [:]))
        let ids = ["115", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10"]
        #expect(strings(items, "vod_id") == ids.map { "/djlist/\($0)_0_1_{pg}.html" })
        #expect(strings(items, "vod_name") == ["独家舞曲", "迪高串烧", "慢摇串烧", "慢歌串烧", "中文Remix", "外文Remix", "HOUSE",
                                               "霓虹风格", "Mashup", "中文DISCO", "外文DISCO"])
        #expect(strings(items, "vod_pic") == ids.map { image("/static/mobile/images/sort/e\($0).png") })
        #expect(strings(items, "vod_tag") == Array(repeating: "folder", count: 11))
        let poster = try #require(ImageRequest.parse(strings(items, "vod_pic")[0]))
        #expect(poster.url.absoluteString == "https://m.djuu.com/static/mobile/images/sort/e115.png")
        #expect(poster.headers == ["User-Agent": chrome, "Referer": "https://m.djuu.com/"])
        #expect(urls == ["https://m.djuu.com/djlist"])
        #expect(DjuuSite.requests.first?.headers == requestHeaders)
    }

    // DJ-04: only the playlists inside div.my-3 count, even if the same markup appears elsewhere on the page.
    @Test func onlyTheLibraryBlockCounts() async throws {
        let entry = #"<div class="mb-2"><img src="/e.png"><div class="fs-5" onclick="djuuSwitch.djlist('/djlist/%@_0_1_1.html')">%@</div></div>"#
        func block(_ id: String, _ name: String) -> String { entry.replacingOccurrences(of: "%@_0", with: id + "_0").replacingOccurrences(of: ">%@<", with: ">" + name + "<") }
        DjuuSite.serve(["/djlist": Data("<html><body><div class=\"side\">\(block("99", "side"))</div><div class=\"my-3\">\(block("1", "in"))</div></body></html>".utf8)])
        let items = try list(try await spider().categoryContent(tid: "djlist", page: "1", filter: false, extend: [:]))
        #expect(strings(items, "vod_id") == ["/djlist/1_0_1_{pg}.html"] && strings(items, "vod_name") == ["in"])
    }

    // D05: the library has one page; asking for another sends nothing.
    @Test func theLibraryHasOnePage() async throws {
        DjuuSite.serve(["/djlist": try library()])
        #expect(try list(try await spider().categoryContent(tid: "djlist", page: "2", filter: false, extend: [:])).isEmpty)
        #expect(DjuuSite.requests.isEmpty)
    }

    // D07, D08, D09, DJ-02, DJ-03: a folder page lists its own songs, each id carrying the page it came from.
    @Test func aFolderPageListsItsSongs() async throws {
        DjuuSite.serve(["/djlist/115_0_1_1.html": try folder()])
        let page = try object(try await spider().categoryContent(tid: firstFolder, page: "1", filter: false, extend: [:]))
        let items = try #require(page["list"] as? [[String: Any]])
        try #require(items.count == 30)
        #expect(strings(items, "vod_id")[0] == "/djlist/115_0_1_1.html#326050")
        #expect(strings(items, "vod_name")[0] == "【DJUU私货】Taylor Swift - Love Story(Dj阿衍 Electro Rmx 2026)")
        #expect(strings(items, "vod_id")[29] == "/djlist/115_0_1_1.html#325776")
        #expect(strings(items, "vod_name")[29] == "【DJUU独家】海伦 - 桥边姑娘(DJ阿翔 FunkyHouse Rmx 2026)")
        // All thirty, as the separate parser read them.
        #expect(digest(strings(items, "vod_id").joined(separator: "\n")) == "430266dcba29cc6960c486586f36bf15ac0922388a8859f7c0056c39ef288f49")
        #expect(digest(strings(items, "vod_name").joined(separator: "\n")) == "846f0b032492ebf37042c6b833f81e85e1597e1df05566cc36e03277ce55951c")
        #expect(!strings(items, "vod_name").contains { $0.contains("ID:") })
        #expect(Set(strings(items, "vod_pic")) == [logo] && Set(strings(items, "vod_tag")) == ["file"])
        #expect(page["pagecount"] as? Int == 2147483647)
        #expect(urls == ["https://m.djuu.com/djlist/115_0_1_1.html"])
        #expect(DjuuSite.requests.first?.headers == requestHeaders)
    }

    // D04 through the App's own decoder: the library's items are folders, a folder's songs are not.
    @Test func theAppSeesFoldersAndFiles() async throws {
        DjuuSite.serve(["/djlist": try library(), "/djlist/115_0_1_1.html": try folder()])
        let source = try await client()
        let library = try await source.category(id: "djlist", page: 1, extend: [:])
        #expect(library.list.count == 11 && library.list.allSatisfy(\.isFolder))
        let songs = try await source.category(id: firstFolder, page: 1, extend: [:])
        #expect(songs.list.count == 30 && songs.list.allSatisfy { !$0.isFolder })
    }

    // D07, D10 (DJUU-D-01): the page number goes into the path; a page past the end is a 200 with no song, which is
    // an empty list (the nine stray data-bs-id on it are not songs), so the App stops loading more.
    @Test func pagesFollowThePathAndStopPastTheEnd() async throws {
        DjuuSite.serve(["/djlist/115_0_1_2.html": folderPage("独家舞曲", [("1", "a")]), "/djlist/115_0_1_9999.html": try emptyPage()])
        let runtime = try await spider()
        #expect(strings(try list(try await runtime.categoryContent(tid: firstFolder, page: "2", filter: false, extend: [:])), "vod_id")
                == ["/djlist/115_0_1_2.html#1"])
        #expect(try list(try await runtime.categoryContent(tid: firstFolder, page: "9999", filter: false, extend: [:])).isEmpty)
        #expect(urls == ["https://m.djuu.com/djlist/115_0_1_2.html", "https://m.djuu.com/djlist/115_0_1_9999.html"])
    }

    // D11: a folder id that is not one, a song without an id, and a failing page.
    @Test func malformedFoldersAreEmpty() async throws {
        DjuuSite.serve(["/djlist/9_0_1_1.html": folderPage("x", [(nil, "no id"), ("7", "seven")])], status: ["/djlist/8_0_1_1.html": 500])
        let runtime = try await spider()
        for tid in ["/other/115_0_1_{pg}.html", "/djlist/115_0_1_1.html", "djlist/115_0_1_{pg}.html"] {
            #expect(try list(try await runtime.categoryContent(tid: tid, page: "1", filter: false, extend: [:])).isEmpty, "\(tid)")
        }
        #expect(DjuuSite.requests.isEmpty)
        #expect(strings(try list(try await runtime.categoryContent(tid: "/djlist/9_0_1_{pg}.html", page: "1", filter: false, extend: [:])), "vod_name")
                == ["seven"])
        // A failing page is an empty list, which the runtime reports as the failed request (DJ-20).
        await #expect(throws: (any Error).self) {
            try await runtime.categoryContent(tid: "/djlist/8_0_1_{pg}.html", page: "1", filter: false, extend: [:])
        }
    }

    // D12, DJ-11: search by encodeURIComponent, page 2 by &page=; songs keep their bare id.
    @Test func searchListsSongsByTheirId() async throws {
        DjuuSite.serve(["/search": try searchPage()])
        let runtime = try await spider()
        let items = try list(try await runtime.searchContent(key: "冰吻", quick: false, page: "1"))
        try #require(items.count == 30)
        #expect(strings(items, "vod_id")[0] == "326041" && strings(items, "vod_name")[0] == "王键 - 冰吻(肇庆GonBe拾三 Electro Rmx 2026)")
        #expect(strings(items, "vod_id")[29] == "130894" && strings(items, "vod_name")[29] == "王键 - 冰吻(Dj夜猫Music ProgHouse Mix国语男)")
        #expect(digest(strings(items, "vod_id").joined(separator: "\n")) == "d839b99285667d306f0a7a4f30fee9512b813426d09234de9ee1fc602fe24a5a")
        #expect(digest(strings(items, "vod_name").joined(separator: "\n")) == "58512f9f7da6ea72cd1cd9338d6383592a9249fce6f4a6519e294b0ce51bbb53")
        #expect(Set(strings(items, "vod_pic")) == [logo] && Set(strings(items, "vod_tag")) == ["file"])
        #expect(urls == ["https://m.djuu.com/search?musicname=%E5%86%B0%E5%90%BB"])
        #expect(DjuuSite.requests.first?.headers == requestHeaders)
        _ = try await runtime.searchContent(key: "a b", quick: false, page: "2")
        #expect(urls.last == "https://m.djuu.com/search?musicname=a%20b&page=2")
        DjuuSite.serve([:])
        #expect(try list(try await runtime.searchContent(key: "  ", quick: false, page: "1")).isEmpty)
        #expect(DjuuSite.requests.isEmpty)
    }

    // D13 ②, D14, D18: a folder song opens its page's whole playlist, fetched again (no state kept between calls).
    @Test func aFolderSongOpensItsPagesPlaylist() async throws {
        DjuuSite.serve(["/djlist/115_0_1_1.html": try folder()])
        let vod = try #require(try list(try await spider().detailContent(ids: ["/djlist/115_0_1_1.html#326050"])).first)
        #expect(vod["vod_id"] as? String == "/djlist/115_0_1_1.html#326050")
        #expect(vod["vod_name"] as? String == "独家舞曲" && vod["vod_play_from"] as? String == "DJ呦呦网")
        let playlist = try #require(vod["vod_play_url"] as? String)
        #expect(digest(playlist) == "733509866e9a878cfe126c775645428d97d5506e63bb4466eb8b71a421a7caa5")
        let episodes = Episode.parse(playlist)
        #expect(episodes.count == 30)
        #expect(episodes.first == Episode(name: "【DJUU私货】Taylor Swift - Love Story(Dj阿衍 Electro Rmx 2026)", url: "326050"))
        #expect(urls == ["https://m.djuu.com/djlist/115_0_1_1.html"])
    }

    // D15 (DJUU-D-02): a song the page no longer has is put back last, so playing and resuming still find it.
    @Test func aSongThePageLostIsPutBackLast() async throws {
        DjuuSite.serve(["/djlist/115_0_1_1.html": try folder()])
        let vod = try #require(try list(try await spider().detailContent(ids: ["/djlist/115_0_1_1.html#999999"])).first)
        let episodes = Episode.parse(try #require(vod["vod_play_url"] as? String))
        #expect(episodes.count == 31 && episodes.last == Episode(name: "999999", url: "999999"))
    }

    // D13 ①③④, D16, D17, DJ-08: every other id form is decided without a request, in this order.
    @Test func otherIdsAreDecidedWithoutARequest() async throws {
        DjuuSite.serve([:], status: ["/djlist/7_0_1_1.html": 500])
        let runtime = try await spider()
        func detail(_ id: String) async throws -> [String: Any]? { try list(try await runtime.detailContent(ids: [id])).first }
        let search = try #require(try await detail("326041"))
        #expect(search["vod_play_url"] as? String == "326041$326041" && search["vod_play_from"] as? String == "DJ呦呦网")
        let old = try #require(try await detail("325541$$$王键 - 冰吻$$$pic$$$独家舞曲"))
        #expect(old["vod_id"] as? String == "325541" && old["vod_name"] as? String == "王键 - 冰吻")
        #expect(old["vod_play_url"] as? String == "王键 - 冰吻$325541")
        // Upstream's search id ends in an empty part.
        #expect(try await detail("325541$$$王键 - 冰吻$$$pic$$$")?["vod_play_url"] as? String == "王键 - 冰吻$325541")
        // A '#' inside an old id's name is not a folder id.
        #expect(try await detail("325541$$$歌#名$$$pic$$$清单")?["vod_play_url"] as? String == "歌#名$325541")
        for id in ["/djlist/x.html#abc", "/other/1.html#2", "abc", ""] {
            #expect(try await detail(id) == nil, "\(id)")
        }
        #expect(DjuuSite.requests.isEmpty)
        #expect(try await detail("/djlist/7_0_1_1.html#5") == nil)
        #expect(urls == ["https://m.djuu.com/djlist/7_0_1_1.html"])
    }

    // D19: no song list survives between calls — a search or another folder in between changes nothing.
    @Test func nothingIsKeptBetweenCalls() async throws {
        DjuuSite.serve(["/djlist/115_0_1_1.html": try folder(), "/djlist/1_0_1_1.html": folderPage("迪高串烧", [("11", "x"), ("12", "y")]),
                        "/search": try searchPage()])
        let runtime = try await spider()
        _ = try await runtime.categoryContent(tid: firstFolder, page: "1", filter: false, extend: [:])
        _ = try await runtime.categoryContent(tid: "/djlist/1_0_1_{pg}.html", page: "1", filter: false, extend: [:])
        _ = try await runtime.searchContent(key: "冰吻", quick: false, page: "1")
        let first = try #require(try list(try await runtime.detailContent(ids: ["/djlist/115_0_1_1.html#326050"])).first)
        #expect(Episode.parse(try #require(first["vod_play_url"] as? String)).count == 30)
        let other = try #require(try list(try await runtime.detailContent(ids: ["/djlist/1_0_1_1.html#11"])).first)
        #expect(other["vod_play_url"] as? String == "x$11#y$12" && other["vod_name"] as? String == "迪高串烧")
        #expect(try list(try await runtime.detailContent(ids: ["326041"])).first?["vod_play_url"] as? String == "326041$326041")
    }

    // D20, DJ-12, DJ-13: playback posts the form id and plays data.url with the player headers.
    @Test func playbackPostsTheIdAndPlaysTheAudio() async throws {
        DjuuSite.serve(["/play/music": try play()])
        let result = try object(try await spider().playerContent(flag: "DJ呦呦网", id: "325541", vipFlags: []))
        #expect(result["url"] as? String == "https://mp4.djuu.com/c115/166615/116/2026/3f70e1223b32f5e1.m4a")
        #expect(result["parse"] as? Int == 0)
        #expect(result["header"] as? [String: String] == ["User-Agent": chrome, "Referer": "https://m.djuu.com/"])
        let request = try #require(DjuuSite.requests.first)
        #expect(request.url.absoluteString == "https://m.djuu.com/play/music" && request.method == "POST")
        #expect(request.body == "id=325541")
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(request.headers["User-Agent"] == chrome && request.headers["Referer"] == site)
    }

    // D21: a refused, empty, broken or failing reply plays nothing.
    @Test func aBadPlayReplyPlaysNothing() async throws {
        let runtime = try await spider()
        let replies = [#"{"code":1,"data":{"url":"https://x/a.m4a"}}"#, #"{"code":0,"data":{}}"#, #"{"code":"","data":{"url":"https://x/a.m4a"}}"#,
                       #"{"data":{"url":"https://x/a.m4a"}}"#, "<html>not json</html>"]
        for reply in replies {
            DjuuSite.serve(["/play/music": Data(reply.utf8)])
            #expect(try object(try await runtime.playerContent(flag: "", id: "1", vipFlags: []))["url"] as? String == "", "\(reply)")
        }
        DjuuSite.serve([:], status: ["/play/music": 500])
        #expect(try object(try await runtime.playerContent(flag: "", id: "1", vipFlags: []))["url"] as? String == "")
    }
}

// djuu-djlist.html: 61608 B, sha256 a11672a5747e91995e30ca7de2b3054c7053004316aa47395d968794d1d7ad76
private let djlistPacked = """
7T1pk9tUtp95Ve8/CDM1touWvPSejkORhYGZhGRIZl5NvXqVJ0vXttKypGjpBSZVMBDSCYROIARIwkBm5oXUAElYJglZ4M+03N3/4p17ryRrteXujro90JXY
lnSXc89+7nK0++n9h/cd+9ORA0zLbMt7/vM/duNvRuaVZi33aovd93KO3ES8CN8M/O1uI5OH0qbGopOWNFfL7VMVEykme2xRQzlGoFe1nIkWzBJubYYRWrxu
ILNmmQ12KlcKtKTwbVTL6UgRkY50X/15VJ+VzJxb2JRMGe3pXP3WfvABu/+39sUb8G/9s+9Wfriw+vhi5+w7nWsPVs8uMW1OPGFZnKC2d5donWhvs2hxXtVF
w9dbLFQiMgRd0kxJVfoV5TVNRmxbrUvwBaCzcIMl/ftqumB70OYSWpIEHnfK4jup6suSMsvoSHYBMVVLaLES1GQ1HQEyNNVAYo4xpFeRUctVy+UF+J9jWjpq
1HIlw4T+hBIFvyS1+SYySprML5ZktalymtLMJY6ZdtWwZBmQhZAfU4vIiKsXwpLAa3w9gKeEenMSmtdU3fQziSSarZqI5iQBGsQXI5IimRIvs4bAy6hWGWnD
jbbV7l7zC/7rWGqaLdRGrKDKqp8jnymTv1xa8mOsWgZb53X4uRgYYbgpymeMoQsRapwwSqYiqCLiYCTcCeO5uVp1rFKpTlWqo+PjOcYEsXOk7QQ/x9OWcp7M
5ajQ7dldok+iHENgM1oImYHGBMNI4A94UhIJRLhMaYtarKuqaZg6r5FxBlrujZ1uxbqliPLOwpNm1UGa8XBC8MShrQXMLVgmg+U2oc0GP4efcvCRFj8nTlpI
X9wyrOx+mmVT9Ao6pw1wbk2vLJtuqE6nprl19O/dIdaRSHdRfIJebi0DpgLA6XiLO3Wu8J/UYAqFPHSviLysKijPSAozLymiOs8pwJNN3lT1IvPrX0duct1K
Rea1bov4T0Ymo6iiuDgCEtBWTWQwNabBywaaCRYUVcFqg+bkeFE8MAc/DkoGaFKkF/ICyNdsfoRpWIqAjSZTQLhApC/8R/qCLkgJzuT1JjJnosXmW4BdpkBK
c/CJXgYlzzxdqzH55/N4jHFPXjx26GC+GG3M3y+tp/Hg7pgvQ+2YvjGi81j0CYZpRa9HfJ8D/KKFww0oBU5Yvkh6Zyu4UCGmlIc5WaVOBddSDdOr9ec/u5gv
xmIM/1FsgR+Bv/ejBm/JZqE4E184pj8Axxs7voipeSp469QI5QJ/J04RvyYqOX7p7roqLmJmxbpp/frd9TdvEo1B/FakM4LMG+D1AEuCLWboF4sWNOBLpi6y
zn0DJGt2EfwZjcEuJFtvsrS+Z6WhoNsWtuS8BAyIG2hapgm/GjJaYBV1HkxRzic6GCjsRnlKjNwUpbkgXGxdB3j8FUk5qd2MlX3HSaN1u24aw8s+RzHndkEG
REdDYGGgWbYhWxL4hKpCRIgWOjovmUKLck+hGBhGCUBOGIHI4rFHYLfk0BDhK1zIxVBn6eLqlbcCOPIey5KvHVYyUTuulRi0ssS4UuiYExZQuLHIOk4YK8AH
jjjixm8ZoFqKSb0MQBgwBchHGDrKWLJABWOuyegqODFIZAVJF7DLKInBYsQ3SBp9iETd+7KUgHb7vbft5W/Xbt2xH3+YFvmMqKsa6HiFQtcCVazqi6x3dwtp
I/Imz9YNEMpmE7z1nNpoCLwCdsz3iGhxcKnbliEBJQ3zcLcQr0s8aVRXZeg2rghpB99jqa10hrMFtHda8pHfj+0eTLCF9O1cuLb6/d+2Q6zCpINoSuY1A8VQ
zn10FPG60HKoRvUzAgYjpiBCy1ClzZPLIA35hZXgLiM6Xf3e/seVTdOJf8Iy5j3bh/uI0CT0eAvUp6oH1CfB0oYowqcmye6SJSfYvd0YLs/zQLoTDvmEzC8p
6hzSG7I6z7YkUUQK43JsyL1gKeOxDWkBT9FglRrP21GLG99SLsFKez4LtfwuX+DgwHFbAMtSUyEsZjj8kcQ2YaQ1VL0dcgfAlmF+MhIFdLekaBDuOrVwCy4v
MW3EVt3oxWmAgSBHQC1VhpF2hZNwoMzXcQDt3sMopJWOz6JYTb67Di4bxApO13VTYeA/q1omSAwCsWm2vCifFo33E2gv4Clkru7oWOMYmsIbYWqM3kS2pr+9
b+wYPPrBPvNgbfmaff7DKGe7cs54v1gEzjRhR5/+MPk68SRrObZCyRKrQAj5ZCTWF8MFDuIncfzf7Tfoo4fLeX4uhQ37vlXvp6TQGz7aBqKWWr6Ux7FxyPF1
eCfIHV1OYgVZ9dNdlIy2FIA5yLX26e/WP/oa9xOgXIBAsSPHUQ+jsWVGM9kqoxnsWBIWqJpQdeL+A4Mz2iI7xrTr7GhEjn21qEC2kDDLkJ8G4fnYaknSjCuz
5L4rTeRWXe1qB9IoZQ5NYNsQFcc2TpAV0zi5n8MA+urbS2c65/9mL91ZvfSvtbcurp5dAj2PC0akImoV+mPgyQxewTpnc+P3N2H/49r6R993bl63Hy2nG3z/
AI+Qnoa5oI6sNnH1n3rqqST0ObV8FZgIJ0KTwLtY28eN2k8Lg50gpeM1sXgC+/CFfIn+KFUq48fLxyvHKxxeg8pDLLf6zlf2rbtrS3/tXP020UNLgJ4YR7+h
JIDQ0QfH3+vP3zoYuNG0I5kIjeRP648+KByQkQC2oegOJRNIJsM4vbGMYTmiq80XVQias4VmKgSN/f4VDM0LljK7uA3gTIfB+cflzuUzWYJQrYZAWLt7zj7/
EUbKHyWFLx3kZzNFSbUcgmffwT/szRSA0RAAnb+/v3L/08IhJJf2qpYiZMsi1UoInP0vHd13OFMIwlpxr4742b2IN5kS84oyOHFiTWi3kR1pGsJC8tM/17/8
eOX+t6tvfjFUhiHM3Cv3vwaFExxIFnCMRRXf2u2vM4djeiKKj7V3vskeH2EtbF8+t/7gxgbhGEIBC4+/c/pvnYtnhlDAJnaIgE3uEAGb2hkCNh3Gx/rp9+0L
X2RPl/GfuaCPxgj61+8OoaBPxQo6HU6WDDUdK+iZwxHx26mgbxCOIWTssVh+eAW1pYVh4utIvLFPtupZ8lHYE3AmLbIEIWzDvbmKLOW6HLZYbjieNSTTYQ3T
nSzJkihhwwnxeF21dCVTIMJCTicESg6P0qss4RmNF5asiTMWiY8f31h7/JhMomeHjIjLu3xj9ZuHHMf9HMzPeOxM4vCZnxi3yr76eP3v75EZ49IL2c5GVso7
bHY0rIA6l+/Yj35Yu/fdNs1PVqe3TPKHUOjCjsKLh/9w9MAwidtoOd6AlAh374XWMuSl0Uq8df0dm7lhHQ1Tdj9CWvYuYHkneF6j4zvAHR6diuWNzMFIcLj2
W1A6SzgSoqTtcIpHwzbpqIaQWMJxY+bkCbuAx5DQIkCU/qgKvJwlKGHD+LIlSoaglvbjz8wd9KgmMS0dlfZKTV1V26UDYjtLaKqxnjo4eZ3PH/1M/PXIfPS1
D9Y++YGiYJg8iLGwRnxRAkOpZTk/EdY/G1mT3gQCxuKMdOkVPkscjIXN4zE90/7Hw/rlFVWYzXL8YW17JFMWHAu7SK+gZpNHpUOgW+t8lo7BWMRxteqGiTJF
Rli17eexp8bLWZrf6cRNK1lKRTig6Vy5bF97kCUEkd1dH3y6dufNLCGI33GSJQSRORNyJORn4meEDcMh3mhZ2jB5GOPjPYeQBQSRBSFeNxeJRsl0OiBMywPc
fu5QlniYjJi5trSADCZLGCI7eJc/Xn/9s5K9fN6+dytLQKZ/zmplOlarB/amDoNumQj7rS/yupghE01sze7eYdxRW45dsBo6DqpEtrJmzUJhF49MMJUgACJ+
d5aQjEaDMDwBp2S5eWNiLGYKUFFLEBBnjI3xrOyDr5W0B7LiBDqmrF+mupLmSlc/PPXQBgbS53AmnhL+IQmoBCWQYqDuKaFLNztL9zrXztvnrtvnl9du3Uqj
FAbtVdOlOV5Y7E7CXbmw+sUbnUs/rX59+Un0J6jaoo5P3HXHeXap8+mba7e/73z83pPoEc85y7zURnpX0Z4+v/b93+2/33lCXfJ11TJ9vX238uC9ztLFlYdf
PRmUKiYvdPtbe+PS6ncPn1x/htVsIsPrjyEp3shZa1XfxTxTHxurTvAzIO3nPly7fdZ++ABYN+7IdbJEDyDLfsvtyTUDlliSZQsnuDNRCin3JSFyZLtz7avV
Lz+h5x7tT8+s3H+w/7f2e5/ZS1dXHl+zP3hjxP7h7tqZf3be+mnl/rmVR5/bS3dolRH79N3O2dc7184CV9Nqy+fghv3NX+3TX9nL9zvv/B88HLFv/AW+Vn78
1+q521B55fHnq1fegiqrV8+NrN2+5yciN9j528Qx7XNlj/k1FsOZark6xkSygm6SCAT/Wn1zRPBxopMZTdWQQpN3GbtKpTqSeJwmTzK5pjrHCUopX5zBDtSZ
zvUle/nertULj17adwSuYYwT5fLk5Og03Gar6fktcrw/kN3NS9jVROYBGeGfexdfEgt55zR1vsg5I8C52bwka4FsYThpmdmSDI6cSUYieQiWzGtbUNVZCUED
0GqtMqPxZqtWmhHVNi8pNS9jaz6UGSycQsxD2vz8fGwlJ0cYfPUZW/ek9IaHFwZUPmqqOt9EoGXMl0zULuRJFtH8CJMnfrjI67Ph/HAefO4PB0jcxvOmqUt1
y0SFvJdBomeDpxgkG2gjoJF0F1sKW6TFLmW8BG4M/Kan5t3ESzhLCj0Mj1O97sXn5Od42YJnOTcBBemOdIGL1NUFeBa9yVq6jCvhLhN6idah+TncHqnjlwsl
vvBSqPTIydJejB6STxv8JKdhSYjl6n1cP1zLUHWTxfl2iHnM7emXeweXL6FKZZxm3olrKpoVo78+TRFzjjONebaNRMlqM9rGT/rH5wDyn/9PY8IHCVJ7pTrq
67BsYqT26Zvrb95Mgv5JQJAqF0EWgKRORZAFMOkzEWQBTe9EBBlAMEgegizA6ZWGIIv+02chyAKantOUWQCQMgfBZmdTNqrcd5IRHhITnMoA+/MsDKkB3m7z
mybjQwZgpEn48OTBSJXvIQt9luIU+C+6DFWHQ5dVU+kyf0qL4dRl1e3WZRM7Q5dN7gxdNrUjdFmqzBoZEGX8F5WaRqWODodKHU2tUt3kIcOpUke3W6WmSWOS
ARhpsphkYODSJDH5RYmgseFQImOplIgvUctw6pCxbdYhPVPGZNB9n4wxGUDQN2FMBho0Xb6YDPzB/uliMqBI32wxGcAwSLKYDMBJkysmA2XVN1VMBqjomynm
FxuPhmQpN91Cri8bznDa+O1exR0gL08Wy5XlnbVYOFBWngyINb0VOvbfXL9NDId+m0il30jioeHUbBPbrNnSp0DKAJaUGZAygKRvAqQsQpryDggl+qc/ygCG
FNmPMoAiTfKjDMBIm/soA1BSpj7KAJKUmY8ygCR94qMMos30eY8yACZl2qNfnDM0ORzO2WQq58yf2mk4fbTJbfbR+iSZymBSs0eOqQyG3zfFVAYw9MowlcH8
R68EUxmMvkd+qQx6T5deKgNA+mSXygCCvsmlMlAGfXNLZSAPvVNLZQBA78xSGQDQO7FUBgD0zSv1iyOHpobDkZtK5cjRxFPD6cJNbbML1yeLVwYA9E/ilcWU
Vs8cXhlgoV8KrwxASJXBKwM4pn/R33319/Rw6O/pAXZ6kbNrw6nEp7dZifdMl5ZB95s+hvjvfvavPCSH/8oD7NoYYnmNJrnL/PD92PZKbLrkdBkA0jc3XQYw
pEpNlwEc49vp+ERSC5HvwHDqqmmqbbaFcEoYmt0leMtTZf5aCj9X53WGfrFoQeMVEZBSZhrg4IosbcHRyU0Wimkyv4i1NFUTUf1Ne/YKxuVv8ZK7MH5lo6vz
AdNwwjJMqbHI4tLQMltH5jxCSlyXfuQ9zbL21R9Xz55h2XAGKgwYGQkFjer3vppdVy1FBFQIki7IiAk1EAHTsWJxiHGyntV5YbZJWmWJHdrFWLqMk6XFmSjc
U0lWmyq2UTh1mserbcuQBA4/LxRzMdwXHi3+qpvx1qmPnSRA4A9qKHnZrOU673/dufRj0GoC1f29scZcFMH9UoUB/VZ+ut5543aUfmH2AfpYEuXW9gJbYdQ5
pDdkdZ5dYJ3sQwPZ7QDNAA+62c/2haw6GTMhi8K3Ea2sq7Kci9DCKxSvewhR8QcwBlb/4XxrnbPvdK49WD27xLS99FwJZ70++rxz/rP1Lz+Gumvf39z/W5qW
Z+X+O3hr2+OLq19+skV59oBunXfPrr9/K0o3h+/nJdFs7WIqZR21Z1KQJixZPJGZWJdRVzVLo2h2MOzc2iizK0A7H7MDvlbuv75+43Iiv2NWD8smbqRQ3DAM
2OxEBM5e+mjt+s3eYHipwtRmEyNebTQEXpnjDd8jkoOrlnuGQIp7OuwVSrBkvC7xhBbA0oYzxFQVSZ+4JEszg2FQ3ZxfaVksYv9gzD1NWKz5aqO2FWeQnKqk
Tc821UW2aZmYvXpZJcqUYQu0cv/h+vV/JWowTDDMwP7saG2kWLWcBKZmoZds4KoQFc0yCUKSaH4CEUqs1iF9J/Craz4xlGxLxYrLz4HkNtH2aUIMUJW4Al58
wGjasLq5+q394IMNILmbcm4bsOz4lSnQ7EnYluCaYmvDuL5xzT7/4QZwbaraNiEaek6DZQzgluCXYGij+F25/8Hajxc3gF9erlvtbcIw6TsNjnU8Xb5FGgPj
acNcvHRx9cpbG8CyZQSjjAyRjLtOpS3AaG0NIxMkDYriroEGXLgxJnEZZGkOG31VhnHn6C0ejLIEzo+pW12YNdWQcE5Y4BYZXKI5NDgy59lKuRxn4E2VB/ej
a9u9voibQP0DUgaCiVHqR5LLP0po3hc3x8TPnm/FeL8CXkf3LlHnBMWMydeJsa3l2ArtjTw8RB5SpPF1JMtIrC/6nh3EN+OG1+2khXgxhBsSyQQclNZEtKIp
mTIKweL054QMJCjbXWpN+Juqg4ekKk7KV3rhERSCTVaQVQN13U5RMtpSoGP/eGu5faQ4IJw2FeKt5GHXVXExMERLdgsRxxOH21E7JEvRQgRplHQewajzWm8y
zqx02eHMnkLpAXcE3F3VL5uJMycJc0iRae4uYIBiPNddpQDzokgeJQs8CQlJHOFmbu4f98nS9uDtaEud3wfRMyKZogeLarxn/gZCAUxsGbclDEkGFMOy2Yda
l+6ufbS886m1X51XZJUXo3RqqyIvx9BIdGocos9D1Ak9zZgubu9YbnuSh06kbJA8u0uWnCp1PKAFTJOnl5lacsJ1r5CbFNy7wYF6ODAHBQ8CnZGC389ggIhx
dYPzqJgfYRAuwtT2hPObUxgcfV+jxThiqpF4jNA0rnx3Nqzm1MUQx6Q1n29BQ3NID2dHp81IYr/6khhf0xvaMWzgoJUuPk5aSF88irDsq4CMZ4J2DzcXbDDY
FIen9/ZRlwSa/d9fvSaJp7hfveaN+NT/hhugEGnUHvQEJWw8wmNz2vBl1C8UY2jm0Z9zKhQksRgtUldVE79yQeO8uRyM5cP6Ph0BVV4CqPFaS8GDt8i1JBEV
Qk2dihutEdDi6QYd1PzhsQdbTMiSD+wwwkQGG2IJV2elg8otHYYnUiA1SA7Cir5c/Zt2Lqtx3mWyOfT7mTGlnrzHuYcaODqt+Yt3mcbu9rV+G3OVnhfFNN5S
qFjAMG+BA9vHG7r30D73uesTbc7kJlMySWaw4fwNpfWApjumMVA6v/Krl6jCi3kECn+rrfYMeYEMLSe7A0wGzsNBvjiTaPB95vq5vlab2dXtl8MPwInB90PN
41fSFHIlPB1SEig4z/EEpBpGiHMrN/LaqRHf62V0ZLjvyHkKv10GrjlBFcH61piy98QZvm4A2LgEhsJ5MsfrBDz8Vpy8c6+h6kwBP5AYSYFa3XaeIkWfhbJb
IP4phd2bNBK6bAKCdAh3UMgzzwKA/y39Dwc0eZbJj+AbLo3guhjqppd0NlRZRF640m2ZKHLcGH1AJC4/42DklPPdJTHeP1HAl0UftUccmIpOve47dkhtMhnD
IV0Hk4wJ1DaabsmndGRauuKwtqaT7/2owVuyWfCaC3kqI3lNNUzAxgkDy9tMP5uM5w59qofMID6BWaCeujjWVAcKZmGtL9+xHz6gWBgWaw3i2mZ4y1QFta3J
yKQGsdd0Ln4rXKz5JaAx0KBf2l7mfcthcJvFHdJR5PY4a/ZX37cvnF/94s4ukA78IHZN2Pf2JBxceG2S9hxTTBkl1PmeFG97i6VOjO4AjioU/XRjMO00XWrz
+iKdYWXaJt6MaS9dBV4I0Yf2jyEewDzyfi4O254Ai7u20bFrwYdQU0HzceFMIdCDF9l5diI0fL8VnSNLyySAxWAFMe+PBbB5wQW5OV4uFDkZKU2zxexmKpG3
mDkay6/U8mu379nXv7Tf/iTEMHHKqY85hLF61pB5ra4uYKh2MV3YkixksoGkoBqWICDDCGtgCHeOSW2kWmYh9F43op9DROKoU4qDR/LYAyuf91R62oA0xj8p
ctgbcFuHkVboz6BBiaFAcFA+TCcYi1OJURuZ8GIaoGidjT/Bqayg2o+o9kBpqtFpIbqlyVk0idGApFvQqrysNhn/heMpoOAuhUhNZ3mlu1mCgNtLS5JqYXU7
wIYeFNw4EajdtUG0G+pkeDu8/O+wC2DsODGwVCuGDFR/dZjCWLV9s5U9DdWm913j/ZDwHy8OGuCCgc4dTRVgRTfZxy+g9drMHfEJXRzj9cTQPCmLXzLZO2xz
m9xz6Mhor3I9n23rGE2pjdKNMcCSlBv7V05kkH9rxjGkVzeO1P6Vdy431bX2hsc9W9ey4SX3Dcm92KerpXuu1VM9fexopbdO7m8xUtKB9lbNBk8Oywwodb2G
0Mc2RR3yoB08jnd5h1bM3KtZtIgvuxtN3Dlr/KNA8gHgBa0etiyNZG12cPO8rkhK0z84S2vqxKOKf8szdYTnJI2cFzp/ZvXBFxscw8Y3vsTFNzhkCPgn5DXI
3Tk84k48mVW3ja+Z+RftIgPoOli9ZgCxyQvV7trCXhVBvcXWg/u9qmFrEFsPP0ioCPrIqQK/EstUvTLVnnOSuFtJaag45nLwv8slRGzAFTmvERt9xbFuzGzl
THxJqVHQDU4yjhsaEiAYKL6WLJl4kI6UAZOSWbq8ffq0/fojuOSBewp5R/byI3HCp/GLIHzFBEhO4fBr0N6JHKfrnYp+Yu/xtz1Gpx0CqkiYUexRGvOvV1q0
dN6ZUEisAIzrDGe0Wv7dXs3I9yqN2dVrvsvZzzL5Q/V80uiAfclqNB2AZhyvFJMKVn0jhYJV5jkmvxt7KAttWQENjDnaee/7/Cin6s1StVwul8ixAnc2Chs9
o6VLyiw+eINwFBs44VHmpvAJD3rqzL2CwM2UBAjkyNTjLoYtc5XqODxoSLK8ixEsXQfVBsZT1WdyjPNa8lquzJSZygT8y4FxxV3gM1uB6Ou/qK3YBcYeByIM
2IpDU9z0VJWpcOMTE3yFq4wy5AO3VWYr3PQEUz7IVSbGmcooVx0dFVhubHySm5yc4srTFSg7OTEJDdAfLSgzWRkVuKmpaQwLNzY6xXLT01CAJQUO+jp79dAU
My5w46PjUJSbHh/jxiaqHJSdHpdZDu6OcuPlSZ4bH6/i/wSiCjRTAYAm4XMcl3yemy6P4//0MQNNvtrmyuUqA4OBa3wPf1adb3xdZquv5krg7gChnJl5l8C7
mHwSxwW0JdjdvDsj765W+yblIxJF51PCSqtSnk5UW5FNrfHFes7nJwKS0GfCDM9W9BteUmDyRw4fPQZYS7uo8IR2kQbP5CRsJw0U2sS6AT6XXxl4c2lc7zt4
NYHRFkDTaWZopCnWjskiXHfZ2IPW0IAQwAnkcGDykjxdGwyXM9qqarac2+58YMyCdDRoUcg+1ACEgS78o+OZlo4aAI3vQKeED6P5DtnRamTnO4aAT+0SR7kg
5Bc/uR1pwDvHgKeIV0frulrPO6KWcidZ/EC8zWNh387ruMbkW1BD1cFfitNboX1mji/03tv28rdrt+7Yjz+M0+fkGKjTbIGgIrw7q6uw/ZBg/T8AGJ1rX9kX
b9IgsXPjWiIkpqqRY04EkhGnw3QQ6UhQ26DhxEHAeu/m2vkLWwRQ6k59BzLj+qU777q9Jm+X62sfwksKstqUlHTrCd2im1xMaFiyDMCh4LHqnb6OsKPn+d1z
P97xcEKseIzFYm6RHWN8FXGegLSTlOBIO+fn3QbUSFPdyRZZFUikwxGjkC/lNzH1StbjPS5+Aa5yjKLOgW8BVED9V+p7rdozkVNE/XLW+Nf0yQr8H8A3VfxL
+v7l/NVLNztL9+wL55PX8Teypt/mF+h6cS03Xs6RpVp66IwCAuZWQC2y/aaWW/v+hr18r0RzAOBf63+5tXrrGwiQ0ElL0pHYDyYfynAXxyBOSDEbnWa2emsJ
cQQam1d1MZYQ9u23Vz9/YwNU0GJbjaNEpepSolsnQAkKw4YQ77aYFfIZHKBBRO2F6qDosBO3i8E+4czAtNmnivECsv7Pd9duv5GeNH6NhBumbjRDRtEC99RR
C3gbVIoUO2nljZJVUOmEMqkE/TcK0JuFnK0be8aK5LJGbxqgCFGhPDJWTE3wHgNkCXBpkwZ52SKoqYBLF/R9VD3/BhGK4I07JFfE6l9+sM88tJfudS7fSYW3
lCmMgmlYRJSOfVOx8KAsTgnaQsLsBlSNn01IG3V1IcQq+C5Ly5HfL+Gfzu4r79pIL/xUgqJdOJKFY0IeXAG6t8zXQQqqdJYu2ve+Xf/49Nrth/YPd+0L73be
WvYiuHwJlPwcMG8Jc7BiUPc1zzjhZv54XeaV2byrGMgU3C7mmXJ5egzbXmrxOtfO2+eu2+eX127d6gZ6vf7s999NwU8RGDVdmuOFxcFgXL9yYfWLNzqXflr9
+nI66FavvNX59Hrnqx/7ce2gSoyQbou0eu8te8R74shnwYTIj8NMlW7n3uonDyGM7LtA5tvF12vIpqQdp+rMPn3XvvUmOCjAMW4fA63B98+u0lMvLCSvuabN
vHPypC/lzu9/T0cRPFdPHWTAbcRHxgQ5eZKSpNjTqA6k7rZgWFrLn0mIpo8aYGgGmbY9prqrLW1SMDkH5XYMcR4JLd6fMMn+8dbKT9cHp+D8wmYpuEmu9ydC
paAa5Dwalt6xvsKQSDQdNUnewu9u2m+/S6OIQWikERr9OVWVxLiRANKQFBECSPunj/F8luPIb81GjYFW6v05AXEyVt6X6iEwZRlIkiTRYwX4Pl44kZRm8Cad
9jEWDe/uU3jUpNDzczyYNK+ou47pnkIMbZ8NTGCBHXxB0g2Tnusoxm5CxS5E2MHvzvniy5ZkEsuES+5hcG0870KQgi3unv8H
"""

// djuu-folder-p1.html: 85761 B, sha256 2afe44f77ff0be0cb054e68e29ab39619af0efca78157f86974cbf277a0b1e69
private let folderPacked = """
7T35cxNXmj9nq/Z/eNFMjeQad+vwbTBTXEkgEJhAZmt2ayvbkp6lxq1upbvlIxmqYLjMaXOE04SQEPAk4QghYAyG/2XX3ZL/i/3ee61Wd6slS7KRZcUusPt4
x/e++/ve0Zvf37Fv+8G/79+J0npG2vLv/7aZ/EWSIKeGAl+mue2fBOhDLCThL4KfzRmsC1Baz3L4i5w4OhTYrsg6lnXu4EQWB1CC3Q0FdDyuh0lrm1AiLaga
1ody+jDXHwi7WpKFDB4KqFhOYhWrjvpjOD4i6oFiYV3UJbwlf/Zn49Hz/IOjhWcPOtmNMXXRmDvWufj6ev7BkR27C5PfmLeedu7Y/dln7H3Zg78vvb7suP1I
yWnYauuDjzeHWUflII7giTFFTWoOEH2HksRaQhWzuqjIyxUVslkJcxklLsIfGC8HDzjav6Pmjt3Gxfvwzzx91pyZz5+eDFRoSUwIpFOOPKmpviTKI0jFUhEQ
Xckl0pwINbmsihNKJqtoOBlAmvgl1oYCsUhkHP4HUFrFw0OBsKZDf4kwAz8sZoQU1sJZSZgIS0pK4bNyKlBxzKyr4ZwkAbIwdmJqAmt+9TxYSghZIe7CU4V6
oyIeyyqq7uQsMamnh5J4VExAg+SmU5RFXRQkTksIEh6KdmbgQSaXKd0L4857X2rqaZzBXEKRFCcb/yFCfwK1kp9gNadxcUGFywnXCL1NMT5Dmpooo8YhLazL
CSWJeRgJf0j7y+hQrDsajfVHY109PQGkg6xaInpIGBVYSwFbUANMUrdsDrM35RxDYdPSGOuuxhKaVoE/4E04SSEiZcKr1GJcUXRNV4UsHaer5erYKVWM5+Sk
1Fp4yubiIM1kOB54/NCWBuZO5HRE5LZCm8PCKHnLw69a8XPoixxWJ1YNK5vf57gaegWdkwE4V6dXjqttqFanur569K/eIdGRWC2i+BC7XV0GrAkAq+NV7tS6
Iz/iMAqFgtC9nBQkRcZBJMpoTJSTyhgvA0+mBF1RO9Cf/lT2kC9V6kBflVokPxLWkawkkxOdIAEZRccaGkLDgqThTe6CSSWRy4Dm5IVkcucoXOwRNdCkWA0F
EyBfI8FONJyTE8RoohAmBcr6Ij+0L+iCluB1QU1hfVN5sbE0YBeFaGkefuNPQMmj94eGUHBrkIzR781HB/fuCXaUN+bsl9XLCuAj6Z9AbZ++CaKDRPQphllF
u0fynAf84vF9w1AKPLdgB+2di5JCIZ9SNuYkhTkVfFrRdLvWP/5RxHyHL8bID8MW+BHk7w48LOQkPdSxyb+wT38Ajj12cuNT87D70eFOxgXOTqwiTk0UtpzZ
zXElOUGYleimpbvPl47NUo1BnV2sooQkaOD1AEuCLUbsD4fHs8CXKJ7krOcaSNbIBPgzWZQ8lMtx8RTH6ttWGgoW2yKWXBCBAUkDqZyuw9WwhMc5WRkDUxRw
iA4BirhRthKjD5PiqBsuLq4CPM6KtJyYSfnKvuWksbolNw0JksNRDBS7oANio6GwIGiWG5ZyIviEikxFiBU6MCbqiTTjnlCHaxhhALnCCJIcGXsZ7DnJM0T4
4y1UxJA5eTF/87gLR/ZrSXS0w4k6zvi14oNWjhpXBh06lAMKD09wlhPGJeAXCVP8xg9xhOoefllPtREGTAF2EIaN0pcsUEEbTSFVAScGJ7mEqCaIyygm3cWo
b1Bp9B4SlZ5LYgW0GxdOGlNPC4+eGAtf14p8lFSVLOh4mUGXBlWsqBOc/XQVaZMUdIGLayCUqRR46wFleDghyGDHHK+oFgeXOpPTRKCkpu8rFRJUUaCNqooE
3foVoe2QZxyzldZwVoH2VksO8juxXYUJVpG+5vRM/tl3ayFWXtJBNCUJWQ37UK746gAW1ETaohrTzxgYjJqCMlp6Kq2cXBptyCmsFHdNotOtZ8a9myumk/CO
Zcx+t530UUYTz+tVUJ+K6lKfFEsNUUSomSSbwzmpgt3bTOCyPQ+sWuGQQ8ickqKMYnVYUsa4tJhMYhkVOdbjXnCM8bhhcZykaIhK9eftcovr31KggpW2fRZm
+Yt8QYIDy20BLIspmbKYZvFHJbbxIm1YUTMedwBsGeEnraKAbhblLIS7Vi3SQpGXUAZzsWL0YjWAIMhJ4LQiwUhLwkk5UBLiJIAuPiMoZJU+H8G+mnxzHFw2
iBWsruO6jOA/p+R0kBgMYpNK21E+K+rvJ7BewFNourpjY/VjaAZvGVMT9FZka3Zt/yWOweuXxqn5wtSMcf7rcs4uyjmyrzgMzjRlR4f+0IU49SSHAlyUkcVX
gVDySTgZn/AW2EPe+PF/qV+3j+4tZ/u5DDbi+8bsS1FmDxy0dUUtQ8FwkMTGHsfX4h03d5Q4iUtIipPuSVHLiC6Y3VxrnPh16dpD0o+Lci4C+Y6cRD0oy0VQ
VudiKKtx3ZWwwNSEolL3HxgcZSe4bpSJc11lcuyoxQQyjRMjiF5qlOd9q1WSZlKZo8+L0kQfxZWSdqCNMubIJrgMRMW+jVNk+TROnwcIgI76xuQp8/x3xuST
/JXfCscv5k9Pgp4nBcukotwqLI+BdzN4meiclY3f2YRxb2bp2jNz9q7xeqq2wS8f4FHSszAX1FEuQ1399957rxL6rFqOCqiME6FJ4F2i7f1G7aSFxvXS0v6a
OHmI+PChYJhdhKPRns8jn0c/j/Jk4ioIsZxzDqmih1YBemocnYaSAsJG7x5/tR9n62DgumodSa9nJGTaK7RTwgmwDR3FoTQFkj4vTu9PEVj2q0qKTr41F5p+
DzTGpZsEmg9y8sjEGoAz4AXn3lXz6qlmghCLeUAoPD9jnL9GkPI3URbCe4SRpqIkFvHAs33PZ9uaCkCXBwDz+0uLc7dDe7EU3qbk5ERzWSQW9YCzY9eB7fua
CoFXK25TsTCyDQs6CqNP5fqJ42tCS420pGnwCsnbH5d+ur449zR/7MG6Mgxe5l6cewgKxz2QZsDRXa74Co8fNh2Ogd5yfBTO/tJ8fHi1sHH1zNL8/QbhWIcC
5h2/eeI78+KpdShgvS0iYH0tImD9rSFgA158LJ24ZEw/aD5den7ngt7lI+gPz61DQe/3FXQ2nGYy1ICvoDcdjjK/nQl6g3CsQ8bu9uWHT3FGHF9PfF0Wb2yX
cvFm8pHXE7CSFs0EwWvD7VxFM+U64rVYxXC82ZAMeDVMKVnSTKJ4DSfE43Elp8pNBcIr5CwhELZ4lN01E54uf2FpNnG6y+LjhfuFhQWaRG8eMspc3qn7+V9e
8Tz/ezA/Pb6ZxPVnfnzcKuPWwtL3F2jGOPxBc7OR0UiLZUe9Csi8+sR4/bLw4tc1yk/GBlZN8teh0HkdhY/2fXZg53oSt66IvwEJU+7eBq01kZe6ov7W9WOu
6Ya1y0vZHRhnm+8CRlrB8+rqaQF3uKvflzeaDkYFh2tHDko3E44KUdJaOMVdXpt0IItxMkzixqaTx+sCHsSJNAUi/DclIUjNBMVrGD/JJUUtoYR3kN9Nd9DL
NYmeU3F4m5hSFSUT3pnMNBOamK+nDk6e+e3r34m/XpaPnrlcuPGSoWA9eRDdXo34kQiGMtvM/IRX/zQyJ70CBHT7Genwp0IzcdDtNY8H1ab23+PVL58qiZFm
jt+rbfc3lQW7vS7SpziVEnB4L+jWuNBMx6C7zHHNxTUdNxUZXtW2QyCemiA10/wOVFy00kyp8AY05s2rxsx8MyEoW911+XbhybFmQuC/4qSZEJTlTOiWkN+J
n+E1DHsFLZ3LricPo6en6hCaAUHZhJCg6hNUozQ1HeCl5U5+B7+3mXjoKzNzGXEca6iZMJSt4J26vnTkTtiYOm+8eNRMQAZ+z2plwFeru9amrgfd0uv1Wz8S
1GQTmah3dVb3rscVtRHfCat1x0HRsqWszWYhr4tHE0xhCICo391MSLrKgzCSgJObuXijt9snBSgrYQiIm4yNnmbZB0crtW7I8hNon7JOmSpJWlG6lsNTFW2g
YXWUnMQTJhdiAoehBJY1XNoldGXWnHxhzpw3ztw1zk8VHj2qRSnU22tWFUeFxEQpCXdzOv/gqHnlbf7h1XfRX0LJTqhkx11pnKcnzdvHCo+fmdcvvIseSc5Z
EsQMVkuK9sT5wrPvje+fvKMuhbiS0x29/bo4f8GcvLj46ud3g1JZFxKl/gpHr+R/ffXu+tNyqRTW7P4QPeKN7rVW1EH0h3h3d6xX2ATSfubrwuPTxqt5YF2/
LdeVJboOWXZabluuEVhiUZJy5IA7Hdcg5Y5DiCzZNmd+zv90g+17NG6fWpyb37HbuHDHmLy1uDBjXD7aabx8Xjj1o3n87eLcmcXX3xqTT1iVTuPEc/P0EXPm
NHA1qzZ1Bh4Yv3xjnPjZmJozz/4ALzuN+/+EP4tvfsufeQyVFxe+zd88DlXyt850Fh6/cBKRr2//bcUxbS/KHvoTEcNNsUisGxVPPVq68+viy+n8wsUVEoHi
PxtfGREcnGidjKZkscwO79IGw+E4FgVyTJ6o8ylllE/I4WDHJuJAnTLvThpTLwbz0693bd8P9zDG3kikr69rAB5zsdr5rWx7v+t0N/vArhTWd0qYXG6b2JUM
Ba3d1MEO3hoBOZvNPmTNdVoYObRMT4saT/ck4yR9CZbMbjuhKCMihgag1aHopqygp4fCm5JKRhDlIZ6IKBTJBD0ng3mPELORNjY25lvJOiMM/iwzttJO6YaH
5wVUOqArqpDCoGX0XTrOhIL0FNFgJwpSPzwpqCPe8+Fs+IoXFpCkja26rorxnI5DQfsEiaoNHkZY0nAjoNHjLlYVtrIWS5SxD3BDcM12zRcPXiKnpLDN8OSo
121kn/yoIOXgXaB4AAXtjnZBisSVcXhX/pDLqRKpRLqs0Et5HXY+R7FH5vgFPAdf2Eeo+J1J4T1fhR7NMOF2ryopC1UZq+XwFQ2A1H19Nk/01l19v3udmtAJ
GQPB/1QYdhKFxQEagEtWMJSfC0eOF5k8mf/lVdl5R77oRF5EOT1Zqp+z41y0hpAWwMEJEAV6ugxaHv21HIflGixHTnCDxqNuHHBE35UfJOL8YfiozbfwgmCf
MzTOgWgpknVMxAF6XcsYxrhoJIJKh/i9VzWYcdYExHchJ2bpuNkdLjtbEEtUjXZKipAU5RSfBZ20B64PKCrEWloWJ0QgQjLYGY32dFAreGJ26disf3RUF1gr
gKSXQlL5yIWmA9RHAap+8kLTgepn9Kp+AEPToRpgUJWfw9BsSGIxCslyC46bDlaEglV2KkPT4eiicCxzOEPToYpSqMqzuE0HhGnDakc1vFdrqqnWgLVoqM1r
EOPd+b0Yal3M4OqGmuHjd22oM0DvNGHMyFoaaRuKKAMjGjFnJtcOCmZqBtYUBmaE+9cUBuad9K0pDMxl611TGJjK7llTGLopDN1rCgOz7F1rCgNzvmJrCgPz
JaJrCwNDRHSNMWGhYm1xEYtYXhW5MF4+W1NIuouQdK81JF1FSLrWGpJYEZLYWkMSLUISXWtIIkVIImsMiRVZk4u1hqS/CEn/WkPSV4SkryZIVhKd+U3v1JSQ
XvZscLSS9K8380vivQjKTFRPV7Oopu7gqFoq3RF4Vl069K5CpPhEyeabM0fMq0/Y3Gq1yPIdcyoDiWnV/NM3xuWj5oXZwvnpNQfJyv3M/GxcnM0fe2heemje
n1lzqJhJBqq1FFQ9RVyB79Q6UPUWcdVSUDF1DKrYmL/fOlD1O6BanDtbWFioE6qGVpuQT1ARtez6BJU1D0ug3Q+Q/leQzXkG/xsNoa8I7IMo1olEbQ8bziD7
Jtdhz7fifLW547tF9jd3uNKUqjfJWCrDVftmiK+9oiYmq5FUXvlqEa+dimN9DGPZb6q1ZLvYN47s23gqFvABqjjxTQbaFeuN9ETqMVKWZXUmSL2fC2GfwLA5
jOKIJx/6o0sTCaNV/EDVZi0ryFv+78g0/TYu/cTu/x25eBCqAtceGBOHdcShPdAhIisDJkI7Di1df1u4ex5ZM1zo08w4IutNOoDYpKka0qv+H5lh7kLtGVvf
rG1G4ggUgS27dgwyVC8nMJWb+GjXwcHI/x4/1ngLB3ft3TlIkBOORsLRrmoN1ePiLb9qs84s92jKwcTkQzpU+ur/pNZeLOf8v6RF31TRWsX2xtKCjkfJV1tW
gyUDvqLXiDddZTV9U/VLtBb90j3Q6vql8Ggu/+bC0u0bQMmlo9fMk2+AisaTqcWXt9eJYuke2FAs7aFY6uLFgK+wrWeNUpPH0t3f6hrFmD9uvD1m3D8PVMxP
/mLcurnuNEr/hkZpD41SFy8GfIWt7X2UWG+rahS6FhaomL81bf4yDSRcnDtt3Fowj55F4+S68OCS+exp4e4548yssXA//8PVwttbcEv2TLw+YszM509Phnbs
Bnobpx6vE90T612h7uG7NrTPGmufd8y3AV8RbnvPJ9bT6nqqcHbKeHu9MHsESG7OHMlfmQXjk795fOnYgnn98dKVG3ANdDVvXzSPvFov+qhnpfoouqGPWkQf
rZA/A74i2f7+UXerR1z5C2fN209I0Hzi0tLJ0/T3pcqOLso/vVd4/LBF9U33hr5pl+irQb4M+Ipg+/s3Xa2uZ5buvs1PfWuePW08OElMyORFY/rnxfl5cnjC
kdvG29+MY1NL319YnDtifvuC0PnOy8VXV9aLo9O1oXjaRfGsFqMGfIW0/T2eWMvnmC/Omi9+AdIa9x6Y3903Fi6tO3UT28gxt0mOuR5eDPgKW/v7NtGW1yjT
z4wfTi3dPEnTdUeMe/9iv/MPTy/OnTUuvGJ+69KbG+ssnopu6Jk20TMr59CAr2C2vz8TafXMsXH+jDE9a5w4bry+Q6Yqr8yax06Eduxeuv7WfHUX7VcVmZ0Y
0epezcYivzbJFTfAkQFfwWt73yY60OraZU9mWFCAiAfw+ATaKifRLvQx9I126WAyPvpSEFHp8JeSzfjr0uvLrallogMbqZp20TMr4M2Aryi2uTfTM9DV3fLr
df45Zz6+lb/xypi6Qm3HC+P4W2PhcuHUj8breWZE4O16CqQI2leqdHpXUenENpTOShbmrJBBA75C2eaeDgyyq+XjqIuz5p2pwi8/knTck6n8jQUg5qf9A75G
hBGzZf0cgu+VqpzuDZXTKvFUo5wZ8BXD9vdyYq2ua8xvri2+PcMWOCzOnV+cmy88OVo4cs44epMcpf7wnLWE896/kH3gZ0unbwjSV6pwYhsKp0UUzsrYM+Ar
kO3v4URbP1N8oXDhAtB0qzQmTGjoU5zBmTgM/TMNHYTm0H8IE4Syj57nb53xMy4tqnmirbTtYUPzrCx1vFIWDfgKZvv7PC0/T7VNymG0dXhYEFWg798FtC8p
C+tR3UQ2HJ12UTcN8GTAV/Ta3ruJtfxM1VY5hSUBbc1kFFkrWZAPsa6Lcgrtg/7R35XcOtQ4sYENjdMuGmdVuDTgK55t7+PE+lvfxxESI2jnBE6i/Vgg9N2F
PlR0XUAfYOBGOUXoem8mf+6nvaSvdTV3TvC/EWi1j+ezSpwa8BXTdveH+iMtv7OzML1gXvvBePNo6eQ8mTg4d828+jJ/87gxfcH87YX59C75zudv62yvFUF8
Kymh6IYSWsGy5JWzaMBXMNvdE+qPtPx+z8WFr5eOnvpImMihUQ1tVyfiopok0wkv7xQezRkzs4tzZ5duzRr3/rXuFFBXK0VjGwpoJQpoVbg04Cue7e8BtfxO
z9270zI7vM08cmHx5eTi/Mn1dZwgQfKGt9MuyqY+dgz4Clz7ezbR9XTqsXn9Qv7OD+bXJ/JnHq/LQ3MIwltpoeCGhlmtQ5DrY82AryC2vw/T8t9w+FBQsZ7m
DxLDceFV/tKx9fXtBoLiDQ+mXfRLPcwY8BW2dvdf+gZa/qsNxpVp88blwrnf2Gryxfl549YCEPJjQVPkdeW7ALI3UjFtc0RFQ2wZ8BXAdvdb+gZa/ksO5sJ1
cEULb6wl5IX7Rwu/PbEvKh830qKKpn9D0bSLommYMwO+Ytj+Hk1fy59hfO914fkZclbs9xfMmUlj+lV+5rT53XdAy8W5Gfi3XjZRAa5b6XSKDT2zohOMG+HK
gK/4tb0/09fyq4uN19+aR26bz4l7Wnh7ynj03fr6OgzB8Up1S8+GbmmVbVL1cGPAV9za3m/pa/nVwuZ3s8bD6cKZHwpTM9ZR028mjbc/Lb6cDu1V+f8UMjYx
aczb4vplI0Zqnw3gjXJmwFcM299/6VsPp9vcfrL4+j5Z6GTens1f/Gbx1fdsOQL5jM/335CPiF37ofDoSZXDRVp2bwJQYGMau53Ou1klXg34imr7+z4t/11O
87cXhMBgW+7+UHjz0nhw0Zi9bp2e9vbKutmbCZjemN5uG6+nfp4M+IreauiX9zmODosijHNUcjZSvLb/EuQTSChUDOGKkBTlFNwwjFeXkTL9g+UkynJdAaTp
E4RASVEjYj+IZEXG6H0xk1VUXZD1TYEtHGc+/N6YmTXOfFtYWOA4N3Auxogruq5kuDQWU2mAiUDsfrTFNSKrliyMxgUVsT8cHgcBIMBF0LA4jpMca4HBHk9x
UIxASkbDxuoj+bRnu2CRpf11u1NjqspYg6rdKTaExsatN/nTp9wEtolIRsJA48RMyitxPvKpKjk5CahIiGpCwsjTQCVq+yHGIndcSIykaKvQgJDCgyinSqFg
GHSpLibCGSUuSjhMX2lh0lNYUlIKn5VTwQ5fexHq8JNR72jJn7gu+xoxMhBNTQwFqgBBfhEgQFNIoDrMSw/NK28CLrUEVHf2RjRUoIJoVrwH+i2+vWsefVxO
Py/7AH1yIuPWzDj4B7aBHbdMbA3UdRprJ82YYVtGNzvbG9bYmClZZCGDWWVQplKgjBZ2IQc9yfsDY6KeSDOikl/AGOAD7NhtXLwP/5bu/ArBYn7honn6rEm/
SowyPKnGJ5SMv5Y2r31rnr+z9NN1qFt4Nrtjd2HyG/PW08W5s6BOoKX8TzfqU6nV6GaeO7106VE53Sy+HxOTenoQRSMqzmyqgTReyRKozPi6dqqSzWUZmi0M
W48aZXYZaOdgdsDX4tyRpftXK/I7YXWvbJJGQh0Nw0BsRZnAGZPXCndnq4NRtwNAetpnF6pg7/38g5oq0j6p4dMnsphRiNrNOliszCjDmKuaMF/zlcGZnJ9B
sqrSNm3bFE9yqZxO2KuaVWJM6bVAi3Ovlu7+VlGDEYIRBrbowbxPcLWGAiKYmvFqskGqSqI8gqo7Gz5C4tB0/lqH9l2BX4vmk0DJpRWiuFyuM3lMtX0tji+o
SlIhsIWhqWF1c+upMX+5ASRbbtvaYJl1XguabQlbFVwzbDWM6/szxvmvG8C1rmTXCNHQcy1YJgCuCn4phhrF7+Lc5cKbiw3gV5DiucwaYZj2XQuOweCL46uk
MQieGubiyYv5m8cbwDLEp+oaIZl0XZO2AKO1OoxMkVQviksGGnBRjDGpyyCJo8ToKxKM28oyCGCURXB+dDVXgjmraKIuKjJwiwQu0SiuH5ljXLS0+8Q5OF0R
wP1w5BSLfVE3gfkHtAyLywlS6e3fRDzmiJt94mfbt0L2lcvrKD2l6pyiGOlCnBrboQAXZb158zCSEMeShJPxCce7PeSh3/BKnaSxkPTghkYyLgcl3VteURd1
CXtgsfqzQgYalG0Op3udTcXBQ1JkxBw7dmMTFIJNLiEpGi65nUlRy4iujp3jHQpsp8UB4awpD29VHnZcSU64hpiTioWo40nC7XI7JInlhRzJYZtgxTQxiisq
YBfCTcaZVYXSBm4/uLuKUzYrZk5qzf6VAAMU0zQyA1hIJumrygJPQ0IaR/z7v9Ua90ni2uDtQFoZ2w7RM04QSa0vqrHfORvwBDC+ZZyZxyZQjMjmMtS68rxw
bar1qbVDGZNJWrScThklKUg+NEpaNfay9x7qeN42mS7F3oncViUPS6Q0SJ7N4ZxUKb7VEqqY1a23gBYwTbZeRkMoqSRyALfOAy53SphcbpvYlQwF7ULBDlbX
fsCDetg5CgX3AJ0xWMFQUAMR4+Mab1Mx2IkwKYKGtqCv3LAzGCx9P8SK8dRU4+RBSlO/8qVs2JBVl0C8VddVEW5xKOidQSiC7W5GTC5XX0z617SHdpAYOGil
hI8vclidOICJ7CuAjD+47R5pzt2guymepPe2M5cEmv2fP34lJg/zf/zKHvHh//E2wCDKMntQFRSv8fCOzWqDtxxGaCvU4UMzm/68VSEkJjvKi8QVRdd0Vcjy
di6HYHmful3FQJVdALUgJ3DIhreDT4tJHPI0ddhvtJpLi9c2aLfm947d3SKvVWKHTlQ2WA9LFHVWbVAVS3vhKStQM0gWwjqI2NvyvkLnMubnXVY2h04/06fU
u/c4tzADx9KaG95lLXZ3WevXmKu0NZmsxVvyFHMZ5lVwYJfxhl68Ms58W/SJVmZyK1OykswQw/kho3WdptunMVA6f3Sql3KF5/MKFP5qW+1NdJqclZOKA6wM
nI2DYMemigbfYa7/sqzVRoOlfnnyApwY8tzTfFrXs6FAmKRDwgkGzl8ECtIQQYj1KND51eFONJyTGY5DKtY6CE5giO+Jw/SeTyhJsL5DKGK/sYavagA2KUGg
sN6MCioFD94Eg9azYUVFIfJCRKIMtUrtvEeL/hnKroL41yjsdtIoUWITECR6xGwoiP4MAP6X+N880OTPKNhJHhRpBPcdnm6qSeewIiWxHa6UWqaKnDTGXlCJ
C26yMHLY+lsicVrPSCFy2+GgdqcFU4dV7zDCkoZtvNJkDI9VFUwyIVBGSxVLvqdiPafKFmtnVfp3Bx4WcpIespvzeCqdwayi6YCNQxqRt03L2WSSO3SoHppB
fAdZoKq62NdUuwo2w1pffWK8mmdYWC/WGsQ1g4ScriSUTFbCOjOI1dK5mTjnfxgoBQ1Bg05p+0RwTIfBY450yEYR2GLN2d+6ZEyfzz94MgjSQV74zgnL2Zxu
oY8EF3abtD3LFDNG8XS+TJ62MnV8dAdwVKjDSTdEaJdVxYygTrAMK8roXCywxZi8BbzgoQ/rn0Bch3kUnFzstT0uFi/aRsuuuV9CTRmP+YUzIVcPdmRn2wnP
8J1WdJROLdMAloDlxrwzFiDmhRTkRwUp1MFLWE7pabQZRTu8RtnSWE6lFiw8fmHc/ck4ecPDMH7KaRlzCGO1rSH6Kq6ME6gGUQm2ShaysoFkoGq5RAJrmlcD
Q7hzUMxgJaeHSs2WbKKHSDxzSknwSF/bYAWDtkqvNSD18U86eOINFFuHkUbZpdug+FDAPSgHpisYi8MVozaa8ELDoGithT/uVJZb7ZepdldpptFZIbakyZo0
8dGAtFvQqoKkpJDzxvIUsHuVQllNa3qltFiCgltNS9JqXnVbx4Ie7F444apdskGsG+ZkeJZQ++D3c2pgmVb0GKjl1WENxirjyFZWNVQNrgam84F0pQlZDwn/
yeSgBi4Y6NyuQO0LtautWWlgiXYRx3TRsTtPymUFPV09bCs2uWXv/q5GVlOv/Rh1MYNrG6OLJRk3Ll95FZaRr0PG0cQvG0fq8pVbl5vi2UzD4x6JZ5vDS9ai
2KrsU9LSVefqmZ4+eCBaXScvbzFqpAPrLdYcPFksU6fUVRvCMrap3CF328HPySpvz4xZ8W4ET5Db0kKTYs6aXJBlJmxCq4otq0WyVjq4MUGVyZe7HIPLZVMq
9ahs0MfAi1LGeCWL5VCQOcKjYpZkNIzzp/LzDxocQ+MLX/ziGxIyuPyTYIcrh0fdiXcz69b4nJlz0q5sACUHq1oGkJg8T+2SLaxWEdSbbz14Xq0asQa+9ciL
ChVBH1lV4KpimZhdJlY1J0m6FeVhhcRcFv4Hi4TwDbjK9mv4Rl9+rOuTrdzkX1IcDqkaL2qfa1mcgGCg46vKkkkGaUkZMCnN0gWNEyeMI6/hVgDuCQUt2Qt2
+glfVpgA4euoAMlhEn7V2zuV49p6Z6JfsXf/xzajsw4BVTTM6KhSmvCvXTqZUwUroVCxAjCuNZyuWOTjbVktWK00YVe7+RJn/xkF98aDlUYH7Etno9kAstrn
0Y5KBWOOkULBGPoLCm4mHsp4RpJBAxOOHgyHx8bG+LEuXlFT4VgkEgnTbQXFbBQxelpaFeURsvEGkyjWtcMjwveTHR5s11nxDgI3XUxAIEdTj4OIi/DRWA+8
GBYlaRAlcqoKqg2Mp6JuCqBREY9tUyBEjqAIivbCvwAYV9IF2bPlir7+g9mKQTD2JBBBYCv29vMD/TEU5Xt6e4UoH+1C9BdpK8JF+YFeFNnDR3t7ULSLj3V1
JTi+u6eP7+vr5yMDUSjb19sHDbCLNJTpi3Yl+P7+AQIL393Vz/EDA1CAowX2ODr7cm8/6knwPV09UJQf6Onmu3tjPJQd6JE4Hp528T2RPoHv6YmR/xSiKDQT
BYD64HcPKbmVH4j0kP/sNYImv8zwkUgMwWDgnjwjv2PWX3If4WJfBsLg7gChrMx8kcCDKFiJ41zaEuxusJiRL85WO5LyZRLF8ilepRWNDFRUW2WLWv2LVc3n
VwSkQp8VMjyr0a93SgEF9+87cBCwVuukwjtaRerek1NhOamr0ArmDVA2zkXrXlzq13sLzyZYRxDonpHWMHdMJ+FK08Y2tFoWCAGcQDcHVp6St/Z5e8ppGUXR
09bjYj7QZ0K6PGiR6TpUF4SuLpyjE1BaxcMAjWNDp0g2ozk22bFqdOU7gUCo2SUu5wKPX/zuVqQB7xwEnqJeHatb1Hr2FrUaV5L5D8RePOb17eyOh1AwDTUU
FfwlP73lWWdm+UIXThpTTwuPnhgLX/vpc7oN1Go2RFHhXZ1VUthOSIj+rwMMc+Zn4+IsCxLN+zMVIdGVLN3mRCHptDqsDSIVJ5QMaLhkPWBdmC2cn14lgGru
1LEh069ftvKu1Gvl5XLL2gfvlIKkpES5tvmEUtEVTiYM5yQJgMPubdWtPo/Q0nn+4r4fe3s4JZY/xnwxN8F1I0dFck5ArUlKcKSt/fPFBpSypkrJFklJ0EiH
p0YhGA6uIPVK5+NtLv4A7gJIVkbBtwAq4OVn6qvN2qOyXUTVanvn9OkM/Gfgm8rOKX3ndH7+yqw5+cKYPl95Hr+ROf2MMM7mi4cCPZEAnaplm84YIGBuEzhN
l98MBQrP7htTL8LsDABytfTPR/lHv0CAhL/IiSpOLgeTA2Wki4MQJ9SQja7jNJ1VIsR+aGxMUZO+hDAen8x/e7QBKmR9W/WjRDRWpESpjosSDIaGEF9ssVnI
RyRAg4ja/8yZTXXTZruS9BeQpR/PFR4frZ00To1EGmZuNKKjSIN7aqkFsgxqmabqkTdG1oTCEsq0EvQ/HILecthaurGlu4PeDrGHGihCHIp0dnfUTPAqA+Qo
cDXUd58WwUwF3BZB387U84eYUoQs3KFnReT/+dI49cqYfGFefVIT3pZhMP9jWJK4NvatiYXrZXFG0DROjDSgapxsQtuIK+MeViFPOVaOXu8il9bqK/teq134
mQSVd2FJlsbOHrPWljk6qIEq5CjRF0+Xrp8oPH5lvHxuTJ8zj0/ZEVwwDEp+FJg3TDhY1pj7GkRWuBn8PC4J8kiwqBhoCm4Q/SESGegmtpdZPHPmvHHmrnF+
qvDoUSnQq/ZjXDpXAz+VwZhVxVEhMVEfjEs3p/MPjppX3uYfXq0NuvzN4+btu+bPb5bj2nqVGCXdKmn16kv2qPfE09/0sECeMFVtK/fyN15BGLnsBJljFV+1
Ieti9nOmzowTz41Hx8BBAY4p9lHXHPzyp6tU1Qvjledcaz1554svHEfu/PWvbBTuffXMQQbclvnIhCBffMFI0lHVqNal7lZhWNm08yQhdnxUHUPTaNr2oFKc
bcnQgsGOVhriGE6kBeeBScabR4tv79ZPwbHxlVJwhVzvOjCQgqrR/WhEeruXFYaKRFMxOUBui/nrrHHyHIsi6qFRltLoHzVVqRg3UkCGRTkJAaTx9jrJZ1mO
/Oos1Khrpt55JmAGJ0XBcdSDK2XpOiRJZNsKyHPrHEj3Q5b20SY0++l7ZNS00NZRAUyaXbQ4j1nchehZPutKYIEd/EBUNZ3t6+jwXYRKXAivg1/K+ZLbtKhT
y0RPfUWkNsm7UKQQi7vl/wE=
"""

// djuu-folder-p9999.html: 51845 B, sha256 a0c3aded529e2e431b08782069bad503d82a8208a7777263d0d8b573af6cca2b
private let emptyPagePacked = """
7T1pk9NWtp95Ve8/KJ6psV1pyVuvNE0qNGSSDCRMIPNqamqKJ1u3bdGyZCS5l2SoCkMIDQlpyEIWyCTMzANqkgAhDDvJn2m5u//FO+deSdZqqxfUzcvrAtu6
usu5Z7/bubue2/v65OE/HtzHNcymsvs//2MXfnOKqNYnMm81+MnXMjSRiBJ8c/C3q0lMEXKbLZ4ca8szE5lJTTWJavKH51skw9XY00TGJHNmAWsb52oNUTeI
OdE2p/jRTMFXkyo2yURGJ6pEdKJ7ys+S6rRsZpzMpmwqZPfy+99ZN+4uXzuxcufaAHuwFi9Y908OLD3+fPnaO3tfXVn4W+fS7YG9r775JnsfSvjj6uOPPY8v
a22D2HW99LtdBdZQGMRpMj+r6ZLhATGyKxIxarrcMmVN7ZdVbLUUwje1qgxf0F8eEnjavqfk3letC1fhX+fM+53LD5fPLGRiapJrIjbKY0qi8oqsTnM6URxA
TK1da/AylORbOqlpzZZmECnDGfJbxJjIlIvFOfif4Ro6mZrIFAwT2qsVGPgFuSnWiVFoKeJ8QdHqmtBS65nYPrOmptqKAsgixIupeWJElQtgqSa2xKoPTzHl
ZmQy29J008tZsmQ2JiQyI9egQnwYkFXZlEWFN2qiQiZKA01IaLab3WdxzvscSU2zQZqEr2mK5mXjXxXpXyYp+RGrbYOvijr8nPf1MFgV4zPO0Gshahw1CqZa
0yQiQE+Eo8YLMxPlwVKpPFoqV4aGMpwJsmqL6FFxRmQ1ZVxBzTBJ3b2rwN6EOYbCZjQIMX2V1Qwjhj/gTUGiEGGewibVWNU00zB1sUX76au5N3a6BattVVK2
F55a7SpIM3YnAE8U2hrA3LW2yaHcxtQ5Jc7gWwE+kuLn6LE20ec3DSu7nuP5BK2CzmkCnJvTKs8n66rdqGluHv17N4g6kugOio+yx81lwEQA2A1vcqP2E/7J
U1wul4XmVUlUNJVkOVnlZmVV0mYFFXiyLpqanud+85tQotAtlOfe7taIfwoxOVWTpPkBkICmZhKDm+CmRMUg4/6MklZrN0FzCqIk7ZuBH/tlAzQp0XPZGsjX
dHaAm2qrNTSaXI5ghlBb+EfbgiZoDsEU9Toxx8PZZhuAXS5HcwvwSV4DJc89NzHBZV/MYh+j3rx8+MD+bD5cmbddVq4lgo9kvgalI9pGRGdR9CmGWUG3RUwX
AL9k7vUpyAWeWzZPW+dLmCkXkcvFnKIxp0JoaIbplvrLXxzM5yMxhn8MW+BH4PdeMiW2FTOXH4/OHNEegOP2HR8iSh73Jx0fYFzgbcTO4tVEBduZ3VXVpHlk
VtRNq1furp68TjUGdXaJztUU0QCvB1gSbDHHvngy1wK+5KoSb6cbIFnT8+DPtDjpaLvNV+s8K+9aacjo1IWWXJSBAbGCets04deUQuZ4VZsFU5TxiA4ChW6U
q8RooiTP+OHiqzrA4y1I88nNeqTs204aK9t10zhR8TiKGacJ2iHWGwoLB9XyU0pbBp9QU6kIsUyHZmWz1mDck8v7ulEAkGN6IPHY9xDsbSXQRfgKZnIw1Fm4
sPzluz4cua8V2VMPL5ukGVVLBFp5alwZdNzRNlB4ap63nTC+Bh84TInqP4wjdH/3Qy0lIwyYAuIhDOtlJFmggDFT53QNnBgi8TVZr6HLKEv+bNQ3iOt9gETd
dEWOQbv14XvW4u2VG7esJ58mRT4n6VoLdLzKoGuAKtb0ed5N3UTaSKIp8lUDhLJeB289o01N1UQV7JjnFdXi4FI324YMlDTM17uZRF0WaaW6pkCzUVloPZjG
M1tpd2cTaG/X5CG/F9s9mGAT6ds5f3n5zt+3QqyCpIPRlCK2DBJBOefVISLqtYZNNaafCTAYNQUhWgYKbZxcBq3IK6wUdynR6dId659fbphO4lOWMffdJLYR
okng9SaoT033qU+KpXVRRExMkl2FthJj93YhXK7nQXR7OOQRMq+kaDNEn1K0Wb4hSxJROYdjA+4FzxiPn5LncIoGVWo0b4ctbnRNmRgr7foszPI7fIGDA9tt
ASzLdZWymGHzRxzbBJE2penNgDsAtgz5yYgV0F2y2oLhrl0Ka3B4iWsSvuyMXuwKOBjk1EhDU6CnXeGkHKiIVRxAO2mIQlboyDSJ1OS7quCywVjBbrpqqhz8
57W2CRJDQGzqDXeUz7JG+wmsFfAUUld3rK9RDM3gDTE1ojeWrdlv9xsdg8cPrNMPVxYvW+c+DXO2I+ec+4sn4ExTdvToD1OsUk9yIsOXGFkiFQgln0Kk6nww
w358E8X/3Xb9Pnown+vnMtjQ9y27P2WVJXho6xu1TGQLWRwbBxxfm3f83NHlJL6maF66S7LRlH0w+7nWOvXj6mffYzs+yvkIFNlzHPVwLb7ItUy+zLUMfjAO
C0xNaDp1/4HBudY8P8g1q3wlJMeeUkwgG6Q2zdGfBuX5yGJx0oyFeZruSBNNqmpd7UArZczRqvFNGBVHVk6RFVE5Tc8ggJ7y1sLpzrm/Wwu3lj/598q7F5bP
LICex4whqQhbhf4YeDqdV1HnbKz/3iqsf15e/exO5/oV6/Fiss73H+BR0rNhLqijdpO6+jt27IhDn13KU4ALcSJUCbyL2j6q115aGPwwzR2tiaWj6MPnsgX2
o1AqDR0pHikdKQm4cJWFsZx3DSnWQ4uBnhpHr6GkgLDe+/vf689bOxi4StKeDAd6gsteuX0KqYFtyDtdSQWSkSBOry4iLAd1rU4X39KFZjQAjfXRlwjNS211
en4LwBkLgvPPi52Lp9MEoVwOgLBy96x17jNEyh9kVSzsF6dTRUm5GIBncv+be1IFoBIAoPOPj5buf5U7QJTCHq2t1tJlkXIpAM7eVw5Nvp4qBEGtuEcn4vQe
IppcgXtDXTtxIk1ot5JtaRqCQvLzv1a//Xzp/u3lk9eeKcMQZO6l+9+DwvF3JA04BsOKb+Xm96nDMTYcxsfK+z+kj4+gFrYunl19eHWdcDyDAhbsf+fU3zsX
Tj+DAja8TQRsZJsI2Oj2ELCxID5WT31knb+WPl2GfuGCXokQ9O8/eAYFfTRS0Fl30mSosUhBTx2OkN/OBH2dcDyDjD0YyQ9vkKY89yzxdWi8Mam0q2nyUdAT
sCct0gQhaMPduYo05boYtFjOcDxtSMaCGqY7WZImUYKGE8bjVa2tq6kCERRyNiFQsHmUPaUJTyVaWNImzmBofPzk6sqTJ3QSPT1khFzexavLPzwSBOGXYH6G
ImcSnz3zE+FWWZeerP7jQzpjXHgp3dnIUnGbzY4GFVDn4i3r8YOVez9u0fxkeWzTJP8ZFLqgo/Dy628e2vcsiVulGG1ACpS790BtKfJSpRRtXX/Hp25YK0HK
7iWklb4LWNwOnldlaBu4w5XRSN5IHYwYh2tvG3KnCUfMKGkrnOJK0CYdahEiFXDcmDp5gi7gYVJrUCAKf9BqopImKEHD+Fpbko2aVtiLn6k76GFNYrZ1Utgj
13VNaxb2Sc00oSlHeurg5HW+efwL8ddD89GXP1754gFDwbPkQQwGNeLLMhjKVprzE0H9s5416Q0gYDDKSBfeENPEwWDQPB7WU21/KKhf3tBq02n2P6htD6bK
goNBF+kNUq+LpHAAdGtVTNMxGAw5ru2qYZJUkRFUbXtF9NREJU3zOxa7aSVNqQgOaDpfXrQuP0wTgtDuro+/Wrl1Mk0IonecpAlBaM6EHgn5hfgZQcNwQDQa
7daz5GEMDfXsQhoQhBaERN2cpxol1emAIC33CXuFA2niYSRk5pryHDG4NGEI7eBd/Hz1na8L1uI5696NNAEZ+yWrlbFIre7bm/os6JbhoN/6sqhLKTLR8Obs
7n0Wd9QWIxesnjkOKoW2sqbNQkEXj04wFWAARP3uNCGphAdhOAGnprl5Y3gwYgpQ1QowIE4ZG0Np2QdPLUkPZEUJdERer0x1Jc2Rrn546qENDKLPYCSeAv6Q
a6QAOYhqkO4poU+udxbudS6fs85esc4trty4kUQprLXVli7PiLX57iTcl+eXr53ofPLz8vcXn0Z7Na01r+OJu24/zyx0vjq5cvNO5/MPn0aLOOesiHKT6F1F
e+rcyp1/WP+49ZSaFKta2/S09uPSww87CxeWHn33dFCqmmKt297KiU+Wf3z09Noz2vU6Mdz2OBrijZ611vSd3K+qg4PlYXEcpP3spys3z1iPHgLrRh25jpfo
Nciy13K7cs2BJZYVpY0B7kySQMo9QYhs2e5c/m752y/YuUfrq9NL9x/ufdX68Gtr4dLSk8vWxycGrAd3V07/q/Puz0v3zy49/sZauMWKDFin7nbOvNO5fAa4
mhVbPAsJ1g9/s059Zy3e77z/P/BywLr6V/ha+unfy2dvQuGlJ98sf/kuFFm+dHZg5eY9LxGFtZ2/je3TpCN73G9QDMfLxfIg50Q9Wv36x6UH55efXNggESj+
W9WNEcHDiXZkNK1FVBa8y9hZKFSJLGKYPNkU6tqMUFML2fw4OlCnO1cWrMV7O5fPP35l8iA8Qx+Hi8WRkcoYJPPl5PwWOt7vi+7mBuyqE3OfQvDnnvlXpFzW
Pk2dzQt2DzA2mxtkzRctDIOWmQ3ZEOiZZCLRl2DJ3LprmjYtE6gAap0ojbdEszFRGJe0piirEwKKKGRpZgORwYIhxFykzc7ORhayY4TBV5++dU9Kr7t7QUCV
Q6ami3UCWsZ8xSTNXJZGEc0OcFnqh0uiPh2MD+fC5/ywgcQ6XjRNXa62TZLLuhEkelZ4nCOKQdYDGg13samwhWrsUsYN4MbBb3Zq3gm8hFFS2GF4DPW6B8/J
z4hKG95lnAAUtDnaBGapanPwLpzIt3UFC2GTMa2Ey7D4HE6LzPHLBAJfuCFUomJSBOOr0NAM8373Kk5Z6NpskuArBgBpRvpsgdHbYO/z7mvUhF7IGAjRUWFY
JAqbAwwAF3cwhOPCYXiRhfeWf3gUincUiU4uiCivJ0v1c2uOLyUY0gI4pAaiQKPLcP3RnyQclq+zPEZwg8pLfhzwqO/CgUS8fwwfyXyLIAhunKE5HkRLU+ww
EYfo7yR9mOVLxSLXDeK3o+dgxlsSEF/hvJil/WZPJBRbkChUjQ4omijJal1ogU7aD78PaTqMtYwWqclABCk7UCoN5akVPHV99eT16NHRmsDaACTDFJL4kAup
AzRCAeodeSF1oEYZvXoHYEgdqjEGVTgOQ9qQlMsUkn4bjlMHq0jBCkVlSB2OCoWjT3CG1KEqUajCs7ipA8K0Ya9QDTuSTjUlHbA6hrrzGYzxvv6lGGpTbpLe
hprh4xdtqJtA7wYyZnErjbQLRYmBUSp2Li9sHRTM1IxtKQzMCI9uKQzMOxnZUhiYyza8pTAwlT20pTAMUhgGtxQGZtkrWwoDc77KWwoD8yVKWwsDQ0RpizFh
o2JrcVEu2l4V/rAe3NlSSAYdSAa3GpKKA0llqyEpO5CUtxqSkgNJaashKTqQFLcYEntkjT+2GpJRB5LRrYZkxIFkJBEkGxmdRS3vJJqQ7hsbnNvI9G9w5hfH
e0WuOd97upqNatY8OOo1le4ZePbcOvS0hkjV+a7N71x+p3PxFltb7TWyfMqcykBiWnX59k/Wxyc6H15fOXd+y0Gy534uf2dduL588vvOR993rl7ecqiYSQaq
bSuohhxcge+0faAadnC1raBi6hhUsfXw6vaBatQD1dL991eePFkjVOvabYJXUKFa9l1BZa/DIrQHAdI/ZdmaZ/bP3AT3NsK+kyvhLZUDnGzsZ13ayZl6mxwP
XBcXqdA9Vxe51+7w3VXV4DxjNw/f69qQXiarr1HCKwpaGLye5zu3r+C+FrqLb+nhezzfjwTxMPbcaoHwUjy4y802czioCFiwxH1w9ipJsoGX/+3kVE0l3HNy
E29IFVVzvGcv2bcPnVXNNLUm3yDs7gsE2p+029epXneq4cI3vc2EZzW415RANnZToUOyiKlcFgzfydhznT00M+zdKBTEZJWYs4SofWaP6dr0pZ+Wz5wOX9fm
8jMDjZeb9QR7gfwXenGBCuIIHoUYm+JVsTZdp7Xy9LKcnVxbV3BTW99LfHGLm6uxKDML+D6Xz0TwfbC3+FU11ejLD3pf5kOBwA/vVT6gjj/5yX+VD95Y5GmN
j7jQJ4mmW/r5SufEzdjr9qK2aTTn+JLXA7V3iSTc6RXrJgfc0D6rHrTPlCx4qTArTJ3fEC3cTNH7HClR8QMYA/eQB/fFufdHc013G1Xcasc3nXNfr377OZRd
uXPduZObGS6oafnbLzZpPyQuNX1wZvWjG2G62XxPr3dGk6ST5ngC0gQlS6QyE7XLBm+ua7fsO0gYhu2k9TK7CrTzMDvga+n+O6tXL8byO7J6UDaxkuhLCBPB
gOYiJHDWwmcrV673BmODl+7F2ND+V/HFFAxe0IegRnoRa9kC6bnKM9KERZqvJmm2owxS93ZLrs+9oDFMGbRAS/cfrV75d68LQ9k1cJ5dbE2iticy9LalXrKR
7FK4KCHxXvuS9M7QkPlEKPmGRm+193AgTabaPskyKqhKLIAjDkTTutXNpdvWw4/XgeQYJzYdLNsnUxKg2ZWwTcE1w9a6cX3VvUdsbbg2tdYWIRpaToJlBHBT
8EsxtF78Lt3/eOWnC+vAr6hU280twjBtOwmOdTyZvEkaA/G0bi4O31GcDMt4nfAWITn+JuOAtgCjtTmMTJG03kls94ZNrJrdkifPoNHXFOi3fXGeCEZZBucH
5yJcmFuaIePefeAWBVyiGbJ2ZLJ5iwgDb2oiuB9d2+62Rd0E5h/QPGxojkilj3+Qyaxn3Bwxfo66SdHrdXRTqTqnKI64VpG+PEBfhm5UdN8lvkwxPJLxOSiN
4XBBUzad26qD7dlDBjoo21VoDD/FqxQnafb13aTo62L35nLqeOJwO2yHuvfydjPZF2S7s15UiOjrap2zj2J7d3DFCqUL3EFwdzWvbMbOnCTdBNcFDO89ZVvs
MF2UJPqqzwY4Oo5wlpv6j/vC9+umg7dDDW12EkbPhJ7oWe81x54KYu86jmgEIUmBYiibfaj1yd2Vzxa3P7X2arMqzoyG6dTUJFGJoJFklzjA3geoE3ibMl2c
1lFue5KHTaSskzyei6p7H/EDtIBpcvUyNxF/MM7N5BzechMEUA/7ZiDjfqAzUfEcrQEiJlQNwaVidoAjmIWb2B08h8ZgsPX9BMsmUFNNpMOUplH5u7NhE3ZZ
hDji+NlsAyqaIXrwFBurRpb6lZel6JJu1w6jgYNauvg41ib6/CF7LSiX/ZXf7mF1/gr9VQk4vTfJXBKo9r9//bYsHRd+/bbb4+P/HayAQdRi9qAnKEHjEeyb
XYfn5GMuH0Ezl/6CXSAnS/lwlqqmmXg0tiW4czmI5df1SZ0AVV4BqDFcQ86FNy80ZInkAlUdj+qt4dPiyTrt1/zBvvtrjDnNiCt1XKizAZZwdFYyqJzcQXhC
GRKDZCMs7zlTuWHnstz70u6gOYy+udvN9fQ9zt3MwLFpzf/3LpPY3b7Wb32u0ouSlMRbCmTzGeZNcGD7eEP3Hllnv3F8oo2Z3HhKxskMGs7fMlqv0XRHVAZK
59de9RJWeBGvQOFvttUep7urWD7F6WA8cC4OsvnxWIPvMdcv9LXa3M5uuwK+ACcG0wPVY+iAXKaA0yGFGgPnBZGCNIEIsZMyA28fH/CEAdCJ4cQy2IFRAOBZ
qGkSWN8Jrui+sbuvGwA25kAo7Dczok7Bw+gFWTttStO5HL6QOVmFUt16dtCsz0PeTRD/hMLuThrVumwCgnQAG8hluecBwD/JfxaAJs9z2QFMcGgEz/lAM72k
c0pTJOIOV7o1U0WOlbEXVOKy4zZGjtvfXRJjrJYcPuY91B6wYcrb5bqxEGhpOhkjEF0Hk4wEahp1J+cOnZhtXbVZu6XT771kSmwrZs6tLuCpDGRbmmECNo4a
KG/j/Wwyzh16VA+dQXwKs0A9dXGkqfZlTMNaX7xlPXrIsPCsWGsQ1yYntk2tpjVbCjGZQew1nYvReyLNLwWNgwq90vaa6FkOg2QeG2S9yOy21+wvfWSdP7d8
7dZOkA58Ebkm7IlygYMLt05an22KGaMEGk9yFDSSOhG6Azgql/fSjUPatXS5KerzbIaVa5q4IdhauAS8EKAPax8hXoN5FL1cHLQ9PhZ3bKNt1/wvoaRKZqOG
MzlfC+7IzrUTge57regMXVqmA1gEy49571gAzQtmFGZEJZcXFKLWzQa3iyuFos3YGsur1LIrN+9ZV7613vsiwDBRyqmPOYS+utaQe7uqzSFUO7kubHEWMt5A
MlCNdq1GDCOogWG4c1huEq1t5gLxd6h+DhBJYE4pDh7paxesbNZV6UkHpBH+SV5Ab8CpHXpaYj/9BiWCAv5OeTAdYyyOx47a6IQXNwWK1t7445/K8qv9kGr3
5WYanWViW5rsRZMIDUibBa0qKlqd8z7YngKR4s4OsMz28kp3swQFt5eWpMWC6nYNG3qIf+OEr3TXBrFmmJPh7vDyxhryYewINbBMKwYMVH91mMBYNT2zlT0N
1VrPlodCqOJ+SPiPi4MGuGCgcyuJBljhkGvRC2iZhNt0fROizrl7zzxpguA4TpW7Dxys9MrX892W9rF/XAH/LlO7KsaN/Quv5SjR/x3GMeS31o/U/oW3LzdV
W81193u62kqHl5xIlr3Yp6ule67VMz19+FCpt07ubzES0oG1Vk4HTzbLrFHqenWhj20KO+R+O3gEd3kHVsycp2kyj4/djSbOnDX+yNHQ8big1cOWJZGsjXZu
VtRVWa17O9du1XXqUUVH42SO8IzcolFuz51efnhtnX1Y/8aXqPENDhl8/gkNV9mdw6PuxNNZdVv/mpl30S7Uga6D1WsGEE1eoHTXFvYqCOotshyk9yqG1iCy
HL6IKQj6yC4Cv2LzlN085Z5zktisrE5pOOay8b/TIUTkgCt0XiNy9BXFuhGzlePROeWpnG4IsnHEjkaVfzteMrGTtpQBk9JZuqx16pT1zmN4FIF7cllb9rID
UcLXEudB+PIxkBzH4ddaW6dynKx1JvqxrUcnu4zOGgRU0WFGvkdu5F83t9TWRXtCIbYAMK7dnUq5+Ls9LSPbKzeyq1t9l7Of57IHqtm43gH70tVo1oGWcaSU
j8tY9vQUMpa5F7jsLvRQ5pqKChoYOdqOzztbETS9XigXi8UCPVbgzEah0TMauqxO48EbgqNY3wmPojCKJzzYqTPnCQZuplyDgRydetzJ8UWhVB6CF1Oyouzk
am1dB9VGA3ePZzg7fOxEpsgVudIw/MuAccUm8MyWb/T1X8xW7ARjjwMRDmzFgVFhbLTMlYSh4WGxJJQqHP3Auop8SRgb5or7hdLwEFeqCOVKpcYLg0MjwsjI
qFAcK0HekeERqID9aECekVKlJoyOjiEswmBllBfGxiADTzPs9zT21oFRbqgmDFWGIKswNjQoDA6XBcg7NqTwAqRWhKHiiCgMDZXxP4WoBNWUAKAR+BzCnC8K
Y8Uh/M9ec1DlW02hWCxz0Bl4xjT8LNvf+Fzky29lCuDuAKHsmXmHwDu5bBzH+bQl2N2sMyPvrFZ7JuVDEsXmU4JKq1Qci1VboU2t0dl6zufHAhLTZswMz2a0
G1xS4LIHXz90GCMoJ1xUeEq7SP1ncmK2k/oybWDdAKMClta8uTSq9W28msCiYLTMQE8TrB3TRbjusrELrdECQrAoGb2W5O1QHIF8RlPTzIad7MwHRixIhwct
Kt2H6oPQ14S3dyKHQdsBGs+BThkPo3kO2bFidOc7QiAmdonDXBDwi5/ejjTgncPAU9SrY2UdreceUUu4kyy6I+7msaBv5zaMcfChhKaDvxSltwL7zGxf6MP3
rMXbKzduWU8+jdLn9BioXW2OoiK4O6ursL2QoP5fAxgsyocb9yAWElNr0WNOFJIBu8FkEOmkpjVBw0lrAYtGQtkkgBI36jmQGdUu23nXbTV+u1xf+xBcUlC0
uqwmW0/oZt3gYsJUW1EAOOI/Vr3d1xG29Ty/c+7HPR5OiRWNsUjMzfODnKcgxglIOkkJjrR9ft6pQAtV1Z1s8d3kMZEtZDcw9UrX410ufgmeMpyqzWCsZFDd
/Vfqe63ac6FTRJk+YVm8a/p0Bf5N8E1V75K+dzmf3YRlnT8Xv46/njX9pjjH1osnMkPFDF2qZYfOGCBgbmukQbffTGRW7ly1Fu8VWAwA/LX61xvLN36AARI5
1pZ1IvWDyYMybOIwjBMSzEYnma3eXEIchMpmNV2KJIR1873lb06sgwqtyFqjKFEqO5TolvFRgsGwLsQ7NaaFfA4HaPRClqiwM+Nrps2kJkULyOq/Pli5eSI5
abwaCStmbjS7P6sB7qmtFnAbVIL4SknljZG1prEJZVoI2p/K0btj7K0buwfz7CoZlmjgpXi54sBgPjHBe3SQp8AljRjlRotgpgIeHdAnmXr+LaEUwY07NFbE
8l8fWKcfWQv3OhdvJcJbwvhV/jAsEknGvolYeK0szgiK9zmtQ9V42YTWgbfc+FkFU3mWj/5+BX/au6/cZyO58DMJCjdhSxaOCUVwBdjeMk8DCajSWbhg3bu9
+vmplZuPrAd3rfMfdN5ddEdwMdc6cvZwM3ukqojqdDZ4d16xODaItjfq7kcxAVDWRx8k4KcQjL5LIJPC6L8pMgl09IK7K53vfurHtWtVYpR0m6TVe2/Zo96T
QD/Z5WbIVMl27i1/8QiGkX0XyDy7+Hp12ZRbR5g6s07dtW6cBAcFOMZpY01r8P2jq/TUC3Pxa65JI+8cO+YJufP737Ne+M/VMwcZcBvykZEgx44xkuR7GtU1
qbtN6Far4Y0kxMJHraFrBp22Paw5qy1NmjGb305dnCW1hugNmGT9dGPp5ytrp+Ds3EYpuEGu98UMpKCyiJUovYN9hSGWaDqp05uPf7xuvfcBG0WshUYtSqO/
JCoSO26kgEzJqgQDSOvnz3E+y3bkN2ejxppW6r0xAZtEkkVPqAf/FZveIEkyO1aA6U6cUF8im/Yx5g03dQf2mmZ6cUYEk+ZmddYxnVOIMddX0gkssIMvybph
snMd+chNqOhCBB387pwvPjZkk1omzEkvcCzgvAtFClrc3f8L
"""

// djuu-search-bingwen.html: 81213 B, sha256 6f723b88f74a9818c25154a326382f3cca041f8a27b0a9f265137b97f383ebde
private let searchPacked = """
7V17k9NGtv+brdrvoGi31nbtSH57HjBsBYbdkIWEG8je2nvrFle2emwxsuRI8jySpYpsQhhICJAQksBkEza7hLsJj4RsIBDCd9k7sme+xT3dLcuS3PL4hWPf
mSkYW1I/Tp/H75zT3erZ88zci/uP/fHIAa5kldW9P//ZHvzJqZJWnOVfLQn7X+DJTSTJ8MnBz54ysiQobVUE9EpVWZzl9+uahTRLOLZSQTxXoFezvIWWrThu
bTdXKEmGiazZqjUvTPFxX0uaVEazvIE0GRnI8NRfQvkFxeIbhS3FUtFe+6279sVHXO3iWv3bv9YfvV/7y5ow97x96Qb82/z03vr3F+uPL+2J08Kt3SyglSXd
kE1PN0xyZGQWDKViKbq2VVGpUlGRUNbzCnwAzQLcEEj/npoNEmtn366tPayfXeVDWlIKEu5UwHc6qq8q2gJnILVBiKVXCyVBgZpCxUAFvVzRTSTznKm8isxZ
PpVILMN/nisZaH6Wj5sW9FeIU/LjSlkqIjNeUaWVuKoXdbGiFfnQMdOu5quqCsxCyMupFWSy6gW4VJAqUt7Hp5B6iwpaquiG5dUORbZKszJaVArQIL6YUDTF
UiRVMAuSimaTE2W4Ua6Wm9fSsveaKU2rhMpIKOiq7lXFXyTID9+p+DFXq6aQlwz4uuIbYbApqmecaRRapHHCjFtaQZeRCCMRT5i/WZxNZZLJ1FQylc5mec4C
e3PM7IS0KNGWeNfYeGpte/fE6ZNWjSG0mSWELF9jBdMM0Q94EpcJRbhMfEAt5nXdMi1DqpBx+lpuz51mxXxVk9XR4lOlmgdrxsMJ0MNiWwmUu1C1OGy3IW3O
S4v4qQi/OuXPiVeqyFgZGFf2PCMIHfQKmFMGOgfTqyB0NlSnU8sanPzbd4gxEhkNFp+gl4NVwI4IcDoecKfOFf5R5rloNALda7Kk6hqKcIrGLSmarC+JGuhk
UbJ0I8b96lctN8VmpRj3WrNF/KMii9N0WV6ZAAso6xYyuVluXlJNtNtfUNYL1TIgpyjJ8oFF+HJIMQFJkRGNFMC+FiIT3HxVK2CnyUURLtDSF/4hfUEXpIRo
SUYRWbtbiy2VgLtclJQW4Td6AUCee2Z2los8G8FjZD157tjhQ5FYa2Pefmm9igRxjvUC1Gb0jRkdwaZPOEwruj3i+yLwFy2/OA+lIPqKxEjvQhIXijJKuZxT
dRpUiCXdtNxaf/pTg/MxJsfwD+UWxBH4cw7NS1XVisZ2swsz+gNy3LHjC0bNk/5bJyeoFng7cYp4kSjuBKR78rq8gpUVY9Pm9e8237hJEIMErMjgCqpkQtQD
Kgm+mKMfAlqugF5yeVlw7ptgWQsrEM9UOPlEtSrkiwKt73ppKNhoC3tySQEFxA0Uq5YF3+ZVtCxo+hK4It5jOpgoHEa5IEZuysqiny4hbwA93oqknFIuMm3f
CdJo3WaYxkmqJ1DkG12QAdHREFo4aFaYV6sKxIS6RkyIFjq6pFiFEtWeaMw3jDiQHDICWcBjb6G9qgaGCB/BQg0O1VYv1a++6eOR+1hVPO0IioXKrFYYbBWI
c6XUcSeqIOH5FcEJwoQC/MKpBmv8VROgJRbWSxeCAVeAPIKho2SKBSqYi0XO0CGIQbJQUIwCDhkV2V+MxAZhow+IqHlfVULYbr/7ln3hm43bd+3HH3TKfE42
9ApgvEapKwEU68aK4N4doGxkyZKEvAlGWSxCtM7r8/MFSQM/5nlEUBxC6nLVVECSpvVis5BkKBJp1NBV6JZVhLSD7wnUVzrDGYDsnZY84vdyu40SDFC+NEX+
KcwqKDrIplSpYiKG5BqPjiLJKJQcqVF8RqBgxBW0yDJQqX9xmaQhr7ES3g1JTte+tf92tW85SU/Zxtxn+3EfLTIJPB4AfOqGDz4Jl3qSiNSxSPbEq2qI39uD
6XIjD2Q46ZDHyLyWoi8iY17Vl4SSIstI4xoaGwgvBKp4wryyjKdoMKSydbvV47Jb4kO8tBuzUM/f0AucHDhhC3BZKWpExUxHP8LUJsi0ed0oB8IB8GVYn8xQ
A92jaBVId51auIWGLnFlJKQa2YvTAAdJTgGVdBVG2jROooGqlMcJdOMeZiGtdHwBMZF8Tx5CNsgVnK7zlsbBf0GvWmAxCMymWHKzfFqUHSfQXiBSGDrc0bGy
FJrS26LUmL2hak2/u584MPjhe/vMw40La/b5D1o1u2HnnPtNQBBME3X04Icl5UkkOcsLSSoWJoAQ8alIzq8ECxzCT1j63+zXH6MHy7lxLqUNx74p96ui0Rse
2fqyltlIPIJz40Dg6+iOXzuamiQUVN0rd1kxy4qPZr/W2qfvbX54C/fjk5xPQMyR46yHqwgJrmIJKa5iCpkwLlCY0A0S/oOCc5UVIcOV80K6xY49tahBllBh
gSNfTaLzzGph1owrC+R+w5rIrbzeRAfSKFWOSkEoQ1bMbJwwi9E4uc9jAj317dUztfN/tVfv1i//c+PNS/Wzq4DzuGCLVbR6ha058HQGr2HM6W/83ibsv61t
fvht7eZ1+4cLnQ1+6wSPiJ6muQBH1TIJ9Xft2hXGPqeWpwLXoonQJOguRnvWqL2yMIUcKc1GYvkEjuGjkTj9Ek8ms8cTx5PHkyJefIpALld/+yv79ncbq3+p
XfsmNEILoZ44R6+jJITQ0fvH3+7H2zo4uHSnI8kFRvLHzR/ejx5QUQF8Q6wxlKFQMhnk6Y0LmJYjhl58ToekebjUTAWosd+7iqn5bVVbWPkJyJkOkvO3K7Ur
Z4ZJQioVIGHju3P2+Q8xU/6gaFL8kLQwVJakEgF69h96ed9QCUgHCKh9/t76g0+ih5Ea36dXtcJwVSSVDJAzd/Do/heHSkEQFfcZSFrYhySLi3Mvad0Lh+lC
m42MpGsIGsmTf2x++dH6g2/qb3wxVo4hqNzrD24B4PgHMgw6Mq3At3Hn1tDpmM618mPj7a+Hz48gCttXzm0+vNEjHWNoYMHx107/tXbpzBgaWG5EDGxyRAxs
ajQMbDrIj83T79kXvxi+XLLb3NDTDEO/9c4YGvoU09DpcIapUNNMQx86HS1xOzX0HukYQ8XOMPXhJVRWlsdJr1vyjf1qNT9MPQpGAs6kxTBJCPpwd65imHad
CHqsRjo+bEqmgwjTnCwZplCCjhPy8bxeNbShEhE0cjohEHd0lF4Nk54021iGLZxMS378+MbG48dkEn14zGgJeS/cqH/9SBTF7eB+ssyZxPFzP4ywyr72ePPz
d8mMcfy3w52NTCZGbHY0CEC1K3ftH77fuH/vJ5qfTE0PzPLH0OiCgcJzL7589MA4mVs6wXYgcaLd+6C1IepSOsn2rr8Xhu5Y00HJziFUGX4ImBiFyCudHYFw
OD3F1I2hkxEScM1VofQw6QjJkn6KoDgd9ElHKwjJcZw3Dl08wRDwGCqUCBHxP+gFSR0mKUHH+EJVVsyCHp/Dv4ceoLciiVU1UHyfUjR0vRw/IJeHSU2KGalD
kFf77IdtEq+3zEevvb/x8feUBeMUQWSCiPicAo6yMsz5iSD+9LIm3QcDMiwnHX9JGiYPMkH3eMwYav/ZIL68pBcWhjn+INoeGaoKZoIh0kuoWJRQ/DBga14a
ZmCQaQlcq3nTQkNlRhDa5iQcqUnqMN3vdOimlWFaRTChqV29Yq89HCYFLbu73v9k4+4bw6SAveNkmBS0zJmQV0K2SZwRdAyHJbNUrYxThJHNth3CMChoWRCS
DGuFIMpQpwOCsjwgzomHh8mHyRY3V1aWkckNk4aWHbwXPto89WncvnDevn97mIRMb2dYmWaium9v6jhgSy4Ytz4nGfIQlSg3mN2947ijNsFcsBo7DUq2bGUd
tgoFQzwywRSHBIjE3cOkJN2ahOEJOG2YmzdyGcYUoKbHISEeMjeyw/IPnlY6fSGLZdCMsl6balpaw7q24lMbNDCRsYhP4onjL0oBxaEE0kzUfEvo8s3a6v3a
2nn73HX7/IWN27c7AYVue60YyqJUWGlOwl29WP/i9drlJ/VbV55GfwW9smLgN+6a4zy7WvvkjY0739Y+evdp9IjnnFVJKSOjCbSnz298+7n9+d2n1KWU16uW
p7d76w/fra1eWn/01dNhqWZJhWZ/G69frt979PT6M6vFIjLd/jhyxBt511o3Zrhf5DOZVE7aDdZ+7oONO2ftRw9BdVmvXIdbdBe27PXcrl1z4IkVVa3iA+4s
1IGVew4hcmy7tvZV/cuP6XuP9idn1h88nHvefvdTe/Xa+uM1+/3XJ+zvv9s484/am0/WH5xb/+Eze/UurTJhn/6udvZUbe0saDWtduEc3LC//ot9+iv7woPa
23+HhxP2jT/Dx/qP/6yfuwOV1x9/Vr/6JlSpXzs3sXHnvleIYnfv34aOaX/D9rhfYTPcnUqkMhzjBNC+hED4X8n3JwSPJjono+kVpNHDu8yZeDyPFAkfk6dY
YlFfFAtaPBLbjQOoM7Xrq/aF+zP1iz8c3H8ErmGMuURicjI9DbeFVOf61vJ6v+90N/fAriKyDqgIf923clCORpy3qSMx0RkBPpvNPWTNd1oYPrTMKimmSN5J
RjJ5CJ7Mbbug6wsKggag1dnk7opklWbju2W9LCnarIhNFIqUI4GTwYJHiLlMW1paYlZyzgiDjy3G1nxTuufhBQlVj1q6IRURoIx10ELlaIScIhqZ4CIkDpcl
YyF4PpxLX+OLQyRu41nLMpR81ULRiHuCRNsGT3JINVEvpJHjLgZKW0uLTcm4B7hx8J2+Nd84eAmfkkJfhsdHve7D78kvSmoVnvGNAyhId6QLXCSvL8Oz1ptC
1VBxJaL9rD5aa9DTORr9Nc8sYR6gwjqRIni6CjmYYcUfXIVBhaEvdXL0iglEWsyILZC7ZRrng/SJgF6aaOfs02DoCRSO5E0gFO9caD0PDh8rcvre5uXb9q0P
W446YvKSC3LJG8QSaK4sC8kOslmgCBXACsjBMtzWvO/kJCzfeAV8eBs0nvSzQSAH0ITFLvjH5UhngUWQCPeQoWUB7EpXnTMijpLvnYxiSUgmEhz7BL9OGcrv
/depNXoo979OfdJutOFHY20dQ7k6tPpW/etH20WBsK/cQoMIP8ZIfYDlac7LUzJieoVaTqREKnG+E6ouyYpWFCvgyQ7Bd3oSUjRSUOTIRCJGoqbTNzffuMnO
prshqCcSksksIYJ1zsiwSSGEsN5rHzIhKUII6/3fIROSdgkJvp84ZEIyhBDG+2RDpoPqKuPFgiHTkSN0+PZaD5mCSUIBa8vWkAmZIoQwFkSHR8K0RztbVy+G
CGAJj3p2SMggQov6rWubp85ul9Aiv6LI7UMLyo9tG1pgTjW8aW3tVO3K3XbMGrQl0N5Tjd7rb9x6WpE1a7aoswy35aBzrFu+g86dbB8P8ggM8D8jNLeO/Bc3
y72GhzzDpSY4xTxEuTBDT34/GfiLBEzd8JyO7Z7sLLCPG8W0NcsIHUqwaesgywQ+YjHJMeYkg0lxHllLCGmslL5pgPQkbfcyX0zyDKIa0yt4oOlULpHZElAY
abwXmIKH0tKDVl3FJDwS8Z+TIAtgWD9Dj0HfY1YkbW/93bchf+UEjuZ/0Y0/n7EfvvU7XduHam//uP7gLOe8zsC9VF7m8CRmDGSLa3aAYuyTi+lUROfAyATH
MsAiUMHvPTg3QznbjW37m3ju4LGZhDj5rzff6L2NYwcPH5jB7IknE/FkelCmvvViYJfuBFxJ8wqfz4y/9HBS+2GkVdkHtJMn4Sx021sqSRZaxIcB96CDPNO0
+o0hxgVIstnRA5L/PXVx7vmXX6bp8/+euhQU6tzzL9X++Y+xQBPM3n7RZGpwaJKY3kGTLtCkV0XkmUa2XSAlNTk98pBi3/p4c+0bryQ3P3pSf3KZa76LO9K4
gnncL67kBoQriel4MrWDK33gSlfayDPNbZuAS3Iyk0uMOrjUvn279uPa+oNTXonady/Y574Zh6CF8LhfcJkeFLhMxlOJHXDpA1y60kaeaW7bBVwgTBs5cKl/
fW/z2mmP7E6Ab6h9eo/lGzj3mJ5RhBXM3X5hJTU4WEkkd2Clm5mV3vSQZ5rYdgGUdDYxPWqAYl+7tv7D1bkTta++2HzvrmCfvmlfe7xx55bjC+ieWfuLS/bN
j+zVL+33b9XufV67/7V9+u9U8v41/JFDGczy/lAmI2YHhTK5eDK3gzJdoMwglZNnGuM2gZ7EdDaXGb+J3fUHEKmujUOWRBjcH9AkBwc02XgyswM0A53aDVNF
nmlo2wVWMsnJ7KgvPM+dsG9dtC9eG5PJXMLTkZlvyewkRv0tObfVPp5pTtsDPFLTidRkauxikhPrD96w715iiDM7emBCedwfmKTE5EDABGKSZDw5tQMmgwxL
2mkjzzS3bQIuU4nk6IFLy8LeCfvuhc1Hl7hFk4Pvn767/uhyMMIcRVQhzO032ZkcEKokpgBYdlClm1mVntSQZxrYNoGTyfRkZuzmTw4X/ijpK5I+DpBCGNwv
pKQHBSl4RWgHUgYYqISrIs80tG0EK+O33/bEYUM8tPk/Dzb/5yvsMsYNZkZkp9wOzDyNfKhT1eSZhrhNYCebS02N4Tb/Z1VV0oKizHCLqREEGsLi0XhxKEMm
XnYWnge7HhSujDzT2LYLtGSyif830DKKuIL522eeNChUScRTO9O5w0CVFkihRrZNICWTS2dTo7/I/B+ltPY7jv7FulFGEMLO/hAkO6CXEDNkP/8OhvS3vsxW
PJ5pRNsFMjJT6eyor/4cktJl3QX7MQAOzNT+gCM9oC1uBDh2Vn36WvVpr34806C2CXykJydzudGPODY/erL+8DaH/4qzb+l/FMGDsLQ/8MgNbD4kkYmnd94i
7C/qCFc+nmlM2wQ6UtO5yfQ4brQn24jGYAKEMLjfKGRgQJLcSV8Gv9GerYo809C2C6zkUtnJMdhof/fC+vefBGWXHkUYwQztcx41OaD3j9PxZCqe2lkJ7nOb
fYju8UxL2ia4kZzKjeAZBizZbX7/ZBxwgzC03xeKk4OCjUQ8sRN+9A0bTNXjmYa0TWAjkcumx3AV1779of33x+MAI4TB/cJIbkAwgl8Xzu7AyECzmDBV5JmG
tl1gJZtLj3w0ErZnMD2aG80IT/tMZLKDA5LEzgHV/cQjbZWPZ1rT9sCO5PTkVHIUz7i3X/+7F/c5Ohl+xNCLvmnx9CgfxkaZ2284MqjJkERq58yBrlGkBzXk
mQa2XeAkm53OjN+x1L9PjUF2Q5nb72LvwLKb5E5QMujzqFlqyDMNbLvASTqVHodl34CbeF5v3W2cGkVAweztd8/qYGZdU3ixJrHzNk2f0yUdKSLPNLJtAilT
iWRyeuQTnhNz0qIijwOGEH72m+NkBoQhiamdoKTPHCdM83imGW0T0MilM4kxWO/dPHNp485VT3p6WBlZ3CAs7Q83pgeFGul4agc1+ty3Gqp6PNOUtglwZDKJ
dHYsNorUH3/olx49Erx++f4Iggdha5+rM4nEQOAjSV7Y3TkWuu/tIm0UkGca1TaBkHQ6OzUGb834Us0Rhw/C0lGBj0QuntrZJtIffIQrH880pu0CHYmp0VuN
YYD/39bq73x5GLc0PiEI4e0IYcjOvEe/IcjWWsgzzWugYPKMIJAREV4JnpLemo3v7ifmOyaJkEd5rUuyohUFE0lGocRvYR4tYIM0masIaZ4zrRUsG1kxsY3P
cJquIe4ZpVzRDUvSrN38XkGo3frcXrtpn/ts4/FjQfAT59OJvG5ZelkoIaVYAgXAFPtv7fWNyKmlSYt5yeDoh4CWQfcxcQluXllGskBboLTniwIUw5Ti0dCx
Moye9OwWbGgzG8i98GjoSz3iuNdisIztaz/Wz57xC9gVIh4JJU1QysWgsTFM09CrmgysKChGQUVcoIEwabMY44g7LxUWiqRVaEAqohmuaqjRSBxg1FIK8bKe
V1QUJ4/MOO4prupFXaxoxUiM6RyiMZZ5BkeLP/KWxvRYeCCmUZjl2xCBf2EiACRUQI3ae7dql3/kfYgEUvf2hsGJ38JGW65BfutPrtdev9Mqv6D6gHyqCtXW
8jIEA643XXb8aQfS9Xpmr8yoT9sClr3tzZt0zEQsmlRGtDLgqMq3yMIt5JEnfn50SbEKJSpU/AsUAxz+3PP2pRvwj/7psPrjS7Wzb9fWHtbPrnJlEVcTC3qZ
DXu1Dz+rnf9088uPoO7Gtzfnnt9Y/Uvt2jfrD97GG2oeX6p/+XFv2MqSW+2ds5vv3W6Vm6P3S4pslWa4ZMJA5d0diCZoWRKxGWYcZ+iVaoWy2eGwc6tXZddA
dh5lB36tPzi1eeNKqL5jVQ/aJm4kGuuZBuwrWgzOXv1w4/rN9mR07ftxTy+6hUIcKCs06Kgi6ZM4PmulgqiESJDShYq1OGUYc1sXxnRfZVSushySU5W06fqm
vCwUqxZWr3ZeiSpl0AOtP3i0ef2foQiGBYYV2JEHDTwhyprlFXA1y+1sA1dVFW2Bax9sMIzEg3Rs1CF9h+hrw31iKoWSjoHLFzXj2wTtO4l5ASpxBX4vZVPP
cHPtG/vh+z0wWT7BVL/hcJl23gmbXQsbCK8pt3rm9Y01+/wHPfDa0is/EaOh5064jAkcCH8Jh3rl7/qD9zd+vNQDfyU1Xy3/RBwmfXfCY3D4yvKAEAPzqWct
Xr1Uv/pmD1yGZNX4iZiMu+4ILcBpDUaRCZO6ZXHTQQMvGjkmCRlUZRE7fV2FcTsTDBI4ZQWCH8uoNmmu6KZiKboG2qJCSLSIumfmkpBs7iTwDs7SJQg/PBOI
jb5ImEDjA1KG5uWYqeTyDwpa8uTNjPzZja0495sv6mjeJXBOWMxZUp4421leSNLeglMwqpRHqork/Irn2SF8kzW8ZiclJMkB3pBMxheglHKtFS3FUlGAFqc/
J2UgSdmeeCnnbSoPEZKucTSwoxeuQCHZFAqqbqJm2CkrZlnxdewd7yy/nxQHhtOmAroVPuy8Lq/4hlhVG4VI4InT7VY/pCqthTwzwa7AGnPCXF43gLuQblLN
bGuULnFHINzVvbYZOnPS6cRfkzBgMZkzpgRLskwehRs8SQlJHvHzn3Wa96nKT8O3oyV9aT9kz6iALbW7rMZ95m0gkMAwy3inIIcgMWybW0jr8ncbH14YfWnN
6UsanhZtlVNZlyWVISPZqXGYPg9IJ/B0yHJp9I7ttq146ERKj+LZE6+qYfmtWTCUiuU8BbaAa3JxmZvlZL1QBbotEXh5QEX4676Vg3I04haKxGhd94YI8HBg
EQoeAjkj8ILRiAkmJuZN0ZViZIJDuAg3u5d7zU87pcHB+1laTCSuGsnHiExZ5ZuzYbNOXUzxs5ZlKHCJopHg4kGDbH8zirxVfUVm13SHdgw7OGilyY9XqshY
OYqw7evAjF/4/R5uzt+gvykRT+/tpyEJNPvfv3xNkU+Kv3zNHfHJ/w42QCmqUH/QlpSg8wiOzWlDdAJGaCsaY8jMlb/oVIgqcqy1SF7XLdMypIrozuVgLr9o
7DcQSOUgUC1pBRR16Y2JJUVG0UBTJ1mjNX0o3tmg/cgfHLu/RdEMU4cJrmWwAZVoYFZnVDVKB+lpKdAxSQ7DYtjsXXvvM7hMsaLLcHfojTMZpZ5+xLmXOjg6
rbkTXXbid7f0fr2FSs/KcifRUqCYzzEPIIDdIhq6/8g+91kjJurP5YZLMsxmsOP8HZV1l66b0RiAzi+98NIKeIxHAPiD9tq7f/6zXbt20XJqY4DhxLk8iMR2
hzp8j7v+zZZem5tp9iviBxDE4PuB5kuWVYnycTwdEi9Qcn4jEZJmMUOcW/zEaycnuPmqRnkcNZAZwzyBIe5S5sm1WNBl8L6zXMJ94gzfMIFsXAJT4TxZlAxC
HjyJRJx787rBRfEDhVM0qNVsZxcp+msoOwDz79DY3UmjQlNNwJDIXotohPs1EPifyn+JIJNfc5EJfKMhI7iOBbppZ53zuiojN11ptkyAHDdGHxCLi+x2OHLS
+WyKuGSV1Si+jHmkPeHQFHPqneSQaiKXr2QyRkSGAS4ZC6hsFhsldxnIqhqao9oVg3zOoXmpqlpRt7lApDIRqeimBdw4YWJ7272VT8Zzhx7oITOIT2EWqC0W
M121r+AwvPWVu/ajh5QL4+KtwVzLnFS19IJerqjIog6x3XRuOS+wX4wmpHHQoNfaXpA8y2FwW8Ad0lHwe501+2vv2RfP17+4OwPWgR8w14S1StVy2IeTC7dN
0p7jiqmiBDrvYB8UWzoM7ACNisa8cuOw7CqGUpaMFTrDypUtIcXvtVevgS4E5EP7xxR34R4lrxYHfY9PxRu+0fFr/odQU0NLrHQm6uvBzexcPxEYvteLLpKl
ZZLAYrL8nPfmAti94ILioqRGY6KKtKJV4vZwyVjQKTuI5QW1yMad+/b1L+23Pg4oDAuctnCHMFbXG3Kv5fVlTNUM16QtzEOGO0hKqlktFJBpBhEY0p1jShnp
VSvabLbpEwNCEmlQipNH8tglKxJxIb3ThJQRn8REHA00WoeRJulXv0NhSMA/KA+nQ5zFydCsjUx4cfMAtM7GH/9Ulh/2W6DdV5oiOi1EtzQ5iyYMBCTdAqpK
ql7kvBdOpID8uxRaajrLK83NEoTcdihJqgXhtosNPci/ccJXu+mDaDc0yAjsl2bw9zhxsBQVAw5qazjswFmVPbOVbR1VjxuByXog2WmC90PCf7w4aEIIBpib
5jvfo91uz0oPu7MbPCb7jf3zpEJFskrt07ZGk3sPH+lpI/VPP0ZLKaPOxuhTSaqNW1cewA7yMVQcU3m1d6ZuXXl0tSlfKfc87oV8ZTi65GyKbas+TZRuu1ZP
cfrY0WR7TN7aY3QoB9pbajh8clSmS6trN4QtfFNrQO73g8fxLu/AilnjagGt4MvmRpPGnDX+greZ0AWtNr6sE8vqd3BLkqEpWtE7uGqlaJCIyiV9CaIofUnU
K0iLRmggvKhU8IyGff5M/eEXPY6h940vrPwGpwy++CQS883hkXDi6ay69b5m5l20axlAM8BqNwOIXV6gdtMXtqsI8MasB/fbVcPegFkPPwipCHjkVIFvoWVS
bplU2zlJ3K2izes453L4P9MQBDPhanlfg5l9sVSXMVu5m11SmY8apqiYx80KKkAyEHst3DLxIB0rAyUls3QR+/Rp+9QPcCmB9kQjju1FJljGV5FWwPhiIZSc
xOlXt70TO+6sd2r6ob2zb7uKTjsEVpE0I9amNNZft7RcNSRnQiG0AiiuM5x0KvH7fRUz0q40Vle3+aZm/5qLHM5HwkYH6ktWo+kAKubxZCysYMozUiiY4n7D
RfbgCGW5rGqAwFijZ+LxpaUlcSkt6kYxnkokEnHyWkFjNgo7PbNkKNoCfvEG4SzW94ZHQpzCb3jQt84aV5C4WUoBEjky9TjDCQkxmcrCg3lFVWe4QtUwANrA
eerGbp5bVNDSPh1S5ASX4JI5+MeDc8Vd4He2fNnXv1NfMQPOHiciHPiKw1Pi9FSKS4rZXE5Kisk0R37hthJCUpzOcYlDYjKX5ZJpMZVOFwQxk50UJyenxMR0
EspO5iahAfqlBGUmk+mCODU1jWkRM+kpQZyehgICKXDI09mrh6e4bEHMprNQVJzOZsRMLiVC2emsKohwNy1mE5OSmM2m8H9CURKaSQJBk/A7i0s+K04nsvg/
fcxBk6+WxUQixcFg4Brfw79Tzie+TgipV/k4hDsgKGdmviHgGS4SpnE+tAS/G2nMyDdWqz2T8i0WRedTgqCVTEyHwlbLplZ2sbbz+aGEhPQZMsMziH6DSwpc
5MiLR48B1zpdVHhKu0j97+SEbCf1Fepj3YCr5IVk15tLWb2P8GqCc96AFRhpB2vHZBGuuWzsUmtWQBCgCeTlwPAleecV70A5s6zrVsm53ZgPZCxItyYtGtmH
6qPQ14V3dBJXMtA8UON5oVPBL6N5XrKj1cjOd0yB1HFI3KoFgbj46e1IA905BjpFojpat4F67itqHe4kYw/E3TwWjO3cjme5SAlq6AbESyzcCuwzc2Khd9+y
L3yzcfuu/fgDFp6T10CdZqOEFcHdWU3A9lKC8b8LMmprX9mXbtIksXZjLZQSS6+Q15wIJRNOh51RZKCCXgaEk7sh692bG+cvDoigjjv1vJDJ6pfuvGv2Gr5d
bkv/EFxSUPWionW2ntAs2udiwnxVVYE45H+tetTXEUZ6nr/x3o/7ejgRFptjTM6tCBnOUxGfE9DpJCUE0s77840G9JammpMtql4gmY5InEIkHulj6pWsx7ta
/Fu44jlNX4TYAqSAtl6pb7dqz7W8RdSudnBNn6zAvwyxqeZd0vcu59cv36yt3rcvng9fx+9lTb8sLdP14lk+m+DJUi196YwSAu62gEpk+80sv/HtDfvC/Tg9
AwB/2/zz7frtryFBQq9UFQPJW9HkYRnu4hjkCR3MRndxkM6ABHEEGlvSDZkpCPvOW/XPXu9BChVmqyxJJFMNSTTr+CRBaeiJ8Y0Wh8V8DidokFGzz5zZ3bVs
9usy20A2//HOxp3XOxeNF5FwwzSM5sgoShCeOrCAt0Ft0VQ39kbFWtDphDKpBP3PR6G3KnK2buzNxMjlLL1pAhCiaGIC/1HvDgXeZoACIa6D+v7TIqirgMsG
6fspPP8OEYngjTvkrIj6n7+3zzyyV+/XrtztiG9bKBj7GBYZdaa+HalwtypOBVpChYUeoMarJqSNvL4cUBV8V6DlyPeD+Kuz+8q9Njs3fmpBrV04lmXSY8ec
vWWeDjqQSm31kn3/m82PTm/ceWR//5198Z3amxfcDC4SB5BfBOWNYw3WTBq+Rjgn3Ywcz6uSthBpAAOZgpvhfpFITGew76Uer7Z23j533T5/YeP27Wai1+7H
fu+dDvSphcaKoSxKhZXuaNy8erH+xeu1y0/qt650Rl396pu1T67XvvpxK63tFsSI6AaE6u237JHoSSS/ycmAIlaqznbu1T9+BGnklgtknl187YZsKZXjFM7s
09/Zt9+AAAU0ptFHV2vwW5+u0hYXlsPXXDs9eeeVVzxH7vzbv9FR+N+rpwEy8LYlRsYCeeUVKpJYW6faFdwNYFiVkvckIXp8VBdDM8m07TG9sdpSJgUjsVEa
4hIqlCTvgUn2j7fXn1zvXoJLy/1KsE+t9x0YSEg1yfto2HozWxpDqNAMhA+Q21u7d9N+6x2aRXQjowqR0Z86qhKaNxJC5hVNhgTSfvIRns9yAvnBbNToaqXe
eyZgGcmK5DnqwTdl6TskSaGvFeD7zjmQ/pt02sdcMd27u/CoSaFnFyVwaW7Rxjpm4y3EwPZZ3wQW+MHfKoZp0fc6YsxNqDiECAb4zTlffFlSLOKZyIGvHK6N
510IU7DH3ft/
"""

// djuu-play.json: 646 B, sha256 0072248cf2174e4c228ca1cf25f0896145c8559d84a732e1d110a9af90d38e8e
private let playPacked = """
lZHPSsNAEMZfJexJoWZ3s0lqc9ZLjwVvCyHdbNNtkyYkm/qnFDx5EUTBpxARL3rxcUotvoWzWZB6EbxkycfMN7/5ZoVEmUoUkR4qmgxFCPVQmugERSukCiNM
ta6aiGOO4d9NZ23rirLguGrHuRIcN7qsk0xyLMqlrDn2iMcoIZRjJkSQkkE/HqvMnVUZWKsURcwLAp/2kFY6h8loc31/Mjw7290+b1/eN9cPu7vbr8cX58jZ
3rxu7z8OToajz7cn5zSXQtelMyouHJgRHoJdW+e/CIvK3yMUlAYc0zAMu5eGHRx82aRPJPU8NmbeJJDULfzEuDWyjg2hbTGEhQG0TZRwTAZQNlW6iRdtgaI+
g6K0PF/EolQL6DMpto0SjbqCRuq7vtdDItEyK2slrTcN96XKauDTxdeVhLQPSTWxmEoxlyCASZKPzcQV+s1nE7QJAVqyhNPVoOydxWp2dQJ7pMfhhMHO9iAC
bjgH/HahDX8QMPKD8r/z/z1HX1aGVF6IHAJaSrRemzndWLL+Bg==
"""
