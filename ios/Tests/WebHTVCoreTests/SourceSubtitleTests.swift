import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-45H. Subtitles a source lists with its play result (`subs`). What these pin: a broken
// entry costs only itself, nothing is fetched that iOS cannot or must not fetch, the stream's
// credentials stay with the stream's host, the default follows FongMi/TV's newer rule, WebVTT and
// ASS reach both engines as SubRip, and the viewer's own pick is never overridden.

// MARK: - Decoding

private struct Play: Decodable {
    let subs: [SourceSubtitle]
    enum CodingKeys: String, CodingKey { case subs }
    init(from decoder: Decoder) throws {
        subs = SourceSubtitle.list(in: try decoder.container(keyedBy: CodingKeys.self), forKey: .subs)
    }
}

private func play(_ json: String) throws -> [SourceSubtitle] {
    try JSONDecoder().decode(Play.self, from: Data(json.utf8)).subs
}

/// Android's Gson decode loses the whole play result over one odd entry; here only that entry goes.
@Test func aBrokenEntryCostsOnlyItself() throws {
    let subs = try play("""
    {"subs": [
      {"url": "https://cdn.example/a.srt", "name": "简体", "lang": "zh-CN", "format": "application/x-subrip", "flag": 1},
      {"name": "no address"},
      5,
      {"url": " https://cdn.example/b.vtt ", "lang": 123, "flag": "2"},
      {"url": "https://cdn.example/c.ass", "flag": true}
    ]}
    """)
    #expect(subs == [
        SourceSubtitle(url: "https://cdn.example/a.srt", name: "简体", language: "zh-CN", format: "application/x-subrip", flag: 1),
        SourceSubtitle(url: "https://cdn.example/b.vtt", language: "123", flag: 2),
        SourceSubtitle(url: "https://cdn.example/c.ass"),
    ])
    #expect(try play(#"{"subs": "https://cdn.example/a.srt"}"#).isEmpty)
    #expect(try play(#"{}"#).isEmpty)
}

// MARK: - What is fetched

/// Only http(s) away from this device: iOS has no local server for `file://`, `proxy://` or a
/// TVBox `127.0.0.1:9978` address, and a numeric host written oddly still reaches loopback.
@Test func onlyAddressesThisDeviceCanFetchAreKept() {
    let listed = [
        "file:///sdcard/a.srt", "proxy://do=csp&siteKey=dav&url=/a.srt", "http://127.0.0.1:9978/proxy?a.srt",
        "http://localhost/a.srt", "http://[::1]/a.srt", "http://2130706433/a.srt", "http://127.1/a.srt",
        "sub/a.srt", "https://cdn.example/a.srt", "https://cdn.example/a.srt", "http://192.168.1.5:5244/d/a.ass",
    ].map { SourceSubtitle(url: $0) }
    let plan = SourceSubtitles.plan(listed, preferredLanguage: "zh-Hant-TW")
    #expect(plan.tracks.map(\.downloadURL.absoluteString) == ["https://cdn.example/a.srt", "http://192.168.1.5:5244/d/a.ass"])
    #expect(plan.listed == 11 && plan.skipped == 9)
    #expect(plan.tracks.allSatisfy { $0.providerID == SourceSubtitleProvider.providerID })
}

@Test func atMostEightAreFetchedForOneVideo() {
    let listed = (1...12).map { SourceSubtitle(url: "https://cdn.example/\($0).srt", flag: $0 == 10 ? 1 : 0) }
    let plan = SourceSubtitles.plan(listed, preferredLanguage: nil)
    #expect(plan.tracks.count == SourceSubtitles.maximumFiles && plan.skipped == 4)
    // The only flagged one was past the limit: as with no flags at all, the first is the default.
    #expect(plan.chosenID == "https://cdn.example/1.srt")
}

/// The stream's credentials go only to the stream's host; Referer and User-Agent (what a CDN
/// checks) go anywhere; the transfer's own headers never.
@Test func credentialsStayWithTheStreamsHost() async throws {
    let headers = ["Cookie": "sid=1", "Authorization": "Bearer t", "X-Token": "t", "User-Agent": "WebHTV",
                   "Referer": "https://site.example/", "Range": "bytes=0-", "Accept-Encoding": "br", "X-Bad": "a\r\nb"]
    let provider = SourceSubtitleProvider(headers: headers, mediaURL: URL(string: "https://CDN.example/v.m3u8"))
    func request(_ url: String) async throws -> URLRequest {
        try await provider.downloadRequest(for: SourceSubtitles.track(for: SourceSubtitle(url: url), url: URL(string: url)!))
    }
    let same = try await request("https://cdn.example/a.srt")
    #expect(same.value(forHTTPHeaderField: "Cookie") == "sid=1" && same.value(forHTTPHeaderField: "X-Token") == "t")
    #expect(same.value(forHTTPHeaderField: "Authorization") == "Bearer t")
    #expect(same.value(forHTTPHeaderField: "Range") == nil && same.value(forHTTPHeaderField: "X-Bad") == nil)
    #expect(same.value(forHTTPHeaderField: "Accept-Encoding") == nil)
    let other = try await request("https://subs.example/a.srt")
    #expect(other.value(forHTTPHeaderField: "Cookie") == nil && other.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(other.value(forHTTPHeaderField: "X-Token") == nil)
    #expect(other.value(forHTTPHeaderField: "Referer") == "https://site.example/")
    #expect(other.value(forHTTPHeaderField: "User-Agent") == "WebHTV")
    await #expect(throws: SubtitleProviderError.downloadUnavailable) { _ = try await request("http://127.0.0.1/a.srt") }
    #expect(!provider.acceptsDownload(from: URL(string: "http://localhost/a.srt")!))
    #expect(provider.acceptsDownload(from: URL(string: "https://files.example/a.srt")!))
}

// MARK: - The default (FongMi/TV c616c0aa `MediaItemFactory.SubtitleFlags`)

private func chosen(_ subs: [SourceSubtitle], device: String?) -> String? {
    let plan = SourceSubtitles.plan(subs, preferredLanguage: device)
    return plan.tracks.first { $0.id == plan.chosenID }?.downloadURL.lastPathComponent
}

/// One entry is shown unless the source marks it autoselect-only; several with explicit flags
/// keep them (forced counts as shown); several with none show the best match for the device's
/// language, the first when none matches, and that one is downloaded first.
@Test func theDefaultFollowsTheSourcesFlagsThenTheDevicesLanguage() {
    #expect(chosen([SourceSubtitle(url: "https://c.example/one.srt")], device: nil) == "one.srt")
    #expect(chosen([SourceSubtitle(url: "https://c.example/one.srt", flag: 4)], device: nil) == nil)
    #expect(chosen([SourceSubtitle(url: "https://c.example/a.srt"), SourceSubtitle(url: "https://c.example/b.srt", flag: 2),
                    SourceSubtitle(url: "https://c.example/c.srt", language: "zh-TW")], device: "zh-Hant-TW") == "b.srt")
    #expect(chosen([SourceSubtitle(url: "https://c.example/a.srt", flag: 4), SourceSubtitle(url: "https://c.example/b.srt")],
                   device: "zh-Hant-TW") == nil)
    let three = [SourceSubtitle(url: "https://c.example/en.srt", language: "en"),
                 SourceSubtitle(url: "https://c.example/chs.srt", language: "zh-CN"),
                 SourceSubtitle(url: "https://c.example/cht.srt", name: "繁體中文")]
    #expect(chosen(three, device: "zh-Hant-TW") == "cht.srt")
    #expect(chosen(three, device: "zh-Hans-CN") == "chs.srt")
    #expect(chosen(three, device: "en-US") == "en.srt")
    #expect(chosen(three, device: "ja-JP") == "en.srt")
    let plan = SourceSubtitles.plan(three, preferredLanguage: "zh-Hant-TW")
    #expect(plan.tracks.map(\.downloadURL.lastPathComponent) == ["cht.srt", "en.srt", "chs.srt"])
}

@Test func languageScoresMatchUpstream() {
    #expect(SourceSubtitles.languageScore("zh-TW", preferred: "zh-TW") == 400)
    #expect(SourceSubtitles.languageScore("zh-HK", preferred: "zh-Hant-TW") == 300)
    #expect(SourceSubtitles.languageScore("zh", preferred: "zh-Hant-TW") == 200)
    #expect(SourceSubtitles.languageScore("zh-CN", preferred: "zh-Hant-TW") == 100)
    #expect(SourceSubtitles.languageScore("en", preferred: "en-US") == 300)
    #expect(SourceSubtitles.languageScore("ja", preferred: "zh-Hant-TW") == 0)
    #expect(SourceSubtitles.languageScore(nil, preferred: "zh-Hant-TW") == 0)
}

// MARK: - Formats

private let vtt = """
\u{FEFF}WEBVTT - 片源

NOTE 註解 不是字幕

1
00:01.000 --> 00:03.500 align:start position:10%
<v 甲>第一句 &amp; <c.yellow>黃</c>

00:00:04.000 --> 00:00:05.000
第二句
"""

private let ass = """
[Script Info]
ScriptType: v4.00+

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour
Style: Default,微软雅黑,20,&H00FFFFFF

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Comment: 0,0:00:00.00,0:00:09.00,Default,,0,0,0,,不顯示
Dialogue: 1,0:00:01.50,0:00:03.00,Default,,0,0,0,,{\\bord3}描邊, 第一句
Dialogue: 0,0:00:01.50,0:00:03.00,Default,,0,0,0,,{\\bord3}描邊, 第一句
Dialogue: 0,0:00:04.00,0:00:06.25,Default,,0,0,0,,{\\an8}上\\N下\\h句
Dialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,{\\p1}m 0 0 l 100 0 100 100{\\p0}
"""

/// The content decides, not `format` or the file name; both readers give the cues the overlay
/// draws, and what is stored is SubRip, so mpv draws it in the bundled font.
@Test func webVTTAndASSArriveAsSubRip() throws {
    #expect(SubtitleTextFormat.of(vtt) == .webVTT && SubtitleTextFormat.of(ass) == .ssa)
    #expect(SubtitleTextFormat.of("1\n00:00:01,000 --> 00:00:02,000\nhi\n") == .subRip)

    let fromVTT = try SubtitleContent.validate(SubtitleHTTPResponse(status: 200, data: Data(vtt.utf8)), language: .unknown)
    #expect(fromVTT.cues.cues.map(\.text) == ["第一句 & 黃", "第二句"])
    #expect(fromVTT.cues.cues.first?.start == 1 && fromVTT.cues.cues.first?.end == 3.5)
    #expect(fromVTT.text.hasPrefix("1\n00:00:01,000 --> 00:00:03,500\n第一句 & 黃\n"))
    #expect(SubRip.parse(fromVTT.text) == fromVTT.cues)

    let fromASS = try SubtitleContent.validate(SubtitleHTTPResponse(status: 200, data: Data(ass.utf8)), language: .unknown)
    // The comment and the drawing are left out; the two layers of one line show once.
    #expect(fromASS.cues.cues.map(\.text) == ["描邊, 第一句", "上\n下 句"])
    #expect(fromASS.cues.cues.map(\.start) == [1.5, 4] && fromASS.cues.cues.map(\.end) == [3, 6.25])
    #expect(SubRip.parse(fromASS.text) == fromASS.cues)

    // A SubRip file is kept exactly as it came.
    let srt = "1\n00:00:01,000 --> 00:00:02,000\n<i>hi</i>\n"
    #expect(try SubtitleContent.validate(SubtitleHTTPResponse(status: 200, data: Data(srt.utf8)), language: .unknown).text == srt)
}

/// A Format line that orders the fields differently is followed, and Text keeps its commas.
@Test func anASSFormatLineDecidesTheColumns() {
    let cues = SSA.parse("""
    [Events]
    Format: Start, End, Text
    Dialogue: 0:00:02.00,0:00:03.00,一, 二, 三
    """)
    #expect(cues.cues == [SubtitleCue(start: 2, end: 3, text: "一, 二, 三")])
}

// MARK: - The session

private final class Files: @unchecked Sendable {
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
            guard let answer = answers[request.url!.absoluteString] else { throw URLError(.cannotFindHost) }
            return answer
        }
    }

    private func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        asked.append(request)
    }
}

private func srt(_ text: String) -> SubtitleHTTPResponse {
    SubtitleHTTPResponse(status: 200, data: Data("1\n00:00:01,000 --> 00:00:02,000\n\(text)\n".utf8))
}

private let identity = OnlineSubtitleIdentity(titleKey: "site@@@vod", line: "線路一", episode: "ep1", address: "https://cdn.example/v.m3u8")
private let stream = URL(string: "https://cdn.example/v.m3u8")!

@MainActor
private func coordinator(_ files: Files) -> (OnlineSubtitleCoordinator, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("source-subtitles-\(UUID().uuidString)")
    return (OnlineSubtitleCoordinator(providers: { [] }, downloader: SubtitleDownloadService(fetch: files.fetch, retryDelay: .zero),
                                      root: root), root)
}

@MainActor
private func settle(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<500 where !condition() {
        try? await Task.sleep(for: .milliseconds(2))
    }
}

private let listed = [
    SourceSubtitle(url: "https://cdn.example/en.srt", name: "英文 SDH", language: "en"),
    SourceSubtitle(url: "https://cdn.example/cht.srt", name: "繁中特效", language: "zh-TW"),
    SourceSubtitle(url: "https://cdn.example/x.srt"),
]

/// Every usable entry is attached, the default first and shown once, named by the source (or by
/// its language, unknown here, when it gives no name); none of it is an online choice, so no online
/// callback fires.
@MainActor @Test func theSourcesSubtitlesAreAttachedAndItsDefaultShownOnce() async throws {
    var answers = ["https://cdn.example/en.srt": srt("hello"), "https://cdn.example/cht.srt": srt("你好"),
                   "https://cdn.example/x.srt": srt("無名")]
    for (url, file) in answers { answers[url + "?sign=2"] = file }
    let files = Files(answers)
    let (coordinator, root) = coordinator(files)
    defer { try? FileManager.default.removeItem(at: root) }
    var events = [([String], String?)]()
    var onlineEvents = 0
    coordinator.onSourceAttachmentsChange = { subtitles, shown in events.append((subtitles.map(\.title), shown)) }
    coordinator.onAttachmentsChange = { _, _ in onlineEvents += 1 }
    let session = coordinator.playbackOpened(identity, title: "片名")
    session.loadSourceSubtitles(listed, provider: SourceSubtitleProvider(headers: [:], mediaURL: stream),
                                preferredLanguage: "zh-Hant-TW")
    await settle { events.count == 3 }
    #expect(files.requests.map(\.url!.lastPathComponent) == ["cht.srt", "en.srt", "x.srt"])
    #expect(events.map { $0.0.last } == ["繁中特效（片源）", "英文 SDH（片源）", "未知語言（片源）"])
    #expect(events[0].1 == session.attached.first?.id && events[0].1 != nil)
    #expect(events[1].1 == nil && events[2].1 == nil)
    #expect(onlineEvents == 0)
    // The same video opened again (a quality switch, the prefetch retry), here with freshly signed
    // copies of the same files, asks nothing more and lists nothing twice.
    let resigned = listed.map { SourceSubtitle(url: $0.url + "?sign=2", name: $0.name, language: $0.language) }
    session.loadSourceSubtitles(resigned, provider: SourceSubtitleProvider(headers: [:], mediaURL: stream),
                                preferredLanguage: "zh-Hant-TW")
    try await Task.sleep(for: .milliseconds(30))
    #expect(files.requests.count == 3 && session.attached.count == 3)
}

/// The viewer's pick stands: a default arriving after it is listed, not shown.
@MainActor @Test func aSubtitleTheViewerPickedIsNeverReplacedByTheSourcesDefault() async {
    let files = Files(["https://cdn.example/cht.srt": srt("你好")])
    let (coordinator, root) = coordinator(files)
    defer { try? FileManager.default.removeItem(at: root) }
    var shown = [String?]()
    coordinator.onSourceAttachmentsChange = { _, id in shown.append(id) }
    let session = coordinator.playbackOpened(identity, title: "片名")
    session.noteSubtitleChoice()
    session.loadSourceSubtitles([listed[1]], provider: SourceSubtitleProvider(headers: [:], mediaURL: stream),
                                preferredLanguage: "zh-Hant-TW")
    await settle { shown.count == 1 }
    #expect(shown == [nil] && session.attached.count == 1)
}

/// An empty list is not "this video's list": a later open that brings one still loads it.
@MainActor @Test func anEmptyListLeavesRoomForALaterOne() async {
    let files = Files(["https://cdn.example/cht.srt": srt("你好")])
    let (coordinator, root) = coordinator(files)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = coordinator.playbackOpened(identity, title: "片名")
    let provider = SourceSubtitleProvider(headers: [:], mediaURL: stream)
    session.loadSourceSubtitles([], provider: provider, preferredLanguage: nil)
    session.loadSourceSubtitles([listed[1]], provider: provider, preferredLanguage: nil)
    await settle { session.attached.count == 1 }
    #expect(session.attached.count == 1)
}

/// A source that names no language is read as Chinese when the file is not UTF-8.
@MainActor @Test func aFileOfUnknownLanguageIsDecodedAsChinese() async throws {
    // 「中文字幕」 in GB 18030, which is not valid UTF-8.
    let body = Data("1\n00:00:01,000 --> 00:00:02,000\n".utf8) + Data([0xD6, 0xD0, 0xCE, 0xC4, 0xD7, 0xD6, 0xC4, 0xBB, 0x0A])
    let files = Files(["https://cdn.example/x.srt": SubtitleHTTPResponse(status: 200, data: body)])
    let (coordinator, root) = coordinator(files)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = coordinator.playbackOpened(identity, title: "片名")
    session.loadSourceSubtitles([listed[2]], provider: SourceSubtitleProvider(headers: [:], mediaURL: stream),
                                preferredLanguage: nil)
    await settle { session.attached.count == 1 }
    #expect(session.attached.first?.cues.cues.first?.text == "中文字幕")
}

/// The next video ends the session: what was still to download is never asked for or attached.
@MainActor @Test func theNextVideoDropsWhatIsStillDownloading() async throws {
    let files = Files(["https://cdn.example/cht.srt": srt("你好"), "https://cdn.example/en.srt": srt("hello")])
    let (coordinator, root) = coordinator(files)
    defer { try? FileManager.default.removeItem(at: root) }
    var attachedAfterEnd = 0
    let session = coordinator.playbackOpened(identity, title: "片名")
    session.loadSourceSubtitles(Array(listed.prefix(2)), provider: SourceSubtitleProvider(headers: [:], mediaURL: stream),
                                preferredLanguage: nil)
    _ = coordinator.playbackOpened(OnlineSubtitleIdentity(titleKey: "site@@@vod", line: "線路一", episode: "ep2",
                                                          address: "https://cdn.example/v2.m3u8"), title: "片名")
    coordinator.onSourceAttachmentsChange = { _, _ in attachedAfterEnd += 1 }
    try await Task.sleep(for: .milliseconds(50))
    #expect(attachedAfterEnd == 0 && session.hasEnded)
    #expect(files.requests.isEmpty)
}
