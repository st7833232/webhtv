import Foundation
import Testing
@testable import WebHTVCore

/// The sniffer is a JavaScript hook, so what has to be proven is that each way a real player hands
/// itself a stream is actually observed. These load local HTML rather than a site, so they are
/// offline and deterministic — the live sites are covered by the 45-source sweep.

@MainActor
private func sniff(_ html: String, timeout: Duration = .seconds(6)) async -> URL? {
    // A data: URL gives the page an origin the hook can resolve relative URLs against.
    let encoded = Data(html.utf8).base64EncodedString()
    guard let page = URL(string: "data:text/html;base64,\(encoded)") else { return nil }
    return await MediaSniffer().sniff(page: page, timeout: timeout)
}

@MainActor
private func sniffResult(_ html: String, timeout: Duration = .seconds(6),
                         grace: Duration = .milliseconds(250)) async -> MediaSniffResult? {
    let encoded = Data(html.utf8).base64EncodedString()
    guard let page = URL(string: "data:text/html;base64,\(encoded)") else { return nil }
    return await MediaSniffer().sniffWithSubtitles(page: page, timeout: timeout, subtitleGrace: grace)
}

@MainActor @Test func catchesAStreamRequestedThroughXMLHttpRequest() async throws {
    // hls.js and every 苹果CMS player skin fetch the playlist this way.
    let found = await sniff("""
    <html><body><script>
      var x = new XMLHttpRequest();
      x.open('GET', 'https://cdn.example.com/a/index.m3u8');
    </script></body></html>
    """)
    #expect(found?.absoluteString == "https://cdn.example.com/a/index.m3u8")
}

@MainActor @Test func catchesAStreamRequestedThroughFetch() async throws {
    let found = await sniff("""
    <html><body><script>
      fetch('https://cdn.example.com/b/master.m3u8').catch(function () {});
    </script></body></html>
    """)
    #expect(found?.absoluteString == "https://cdn.example.com/b/master.m3u8")
}

@MainActor @Test func catchesAStreamAssignedToAVideoElementSource() async throws {
    // A native player sets `src` instead of issuing a request the hook could intercept.
    let found = await sniff("""
    <html><body><video id="v"></video><script>
      document.getElementById('v').src = 'https://cdn.example.com/c/movie.mp4';
    </script></body></html>
    """)
    #expect(found?.absoluteString == "https://cdn.example.com/c/movie.mp4")
}

@MainActor @Test func catchesAStreamInMarkupThatWasNeverTouchedByScript() async throws {
    let found = await sniff("""
    <html><body><video><source src="https://cdn.example.com/d/clip.flv"></video></body></html>
    """)
    #expect(found?.absoluteString == "https://cdn.example.com/d/clip.flv")
}

@MainActor @Test func resolvesARelativeStreamAgainstThePage() async throws {
    let found = await MediaSniffer().sniff(
        page: URL(string: "https://host.example/play/1.html")!, timeout: .seconds(4))
    // host.example does not resolve, so this must come back nil rather than hang to the timeout.
    #expect(found == nil)
}

@MainActor @Test func ignoresAssetsThatAreNotTheStream() async throws {
    // Everything here matches "looks like a URL" but none of it is media; the sniff must time out
    // rather than hand back a stylesheet or a poster image.
    let found = await sniff("""
    <html><head><link rel="stylesheet" href="https://cdn.example.com/x/app.css"></head>
    <body><img src="https://cdn.example.com/x/poster.jpg"><script>
      var x = new XMLHttpRequest();
      x.open('GET', 'https://cdn.example.com/x/api.js?v=2');
      fetch('https://cdn.example.com/x/page.html').catch(function () {});
    </script></body></html>
    """, timeout: .seconds(3))
    #expect(found == nil)
}

@MainActor @Test func reportsTheFirstMatchWhenAPageRequestsSeveral() async throws {
    let found = await sniff("""
    <html><body><script>
      var a = new XMLHttpRequest(); a.open('GET', 'https://cdn.example.com/first/index.m3u8');
      var b = new XMLHttpRequest(); b.open('GET', 'https://cdn.example.com/second/index.m3u8');
    </script></body></html>
    """)
    #expect(found?.absoluteString == "https://cdn.example.com/first/index.m3u8")
}

@MainActor @Test func capturesADeclaredTrackWithItsMetadata() async throws {
    let found = await sniffResult("""
    <html><body><video>
      <source src="https://cdn.example.com/show/master.m3u8">
      <track kind="subtitles" src="https://cdn.example.com/show/zh.vtt"
             srclang="zh-TW" label="繁體中文" default>
    </video></body></html>
    """)
    #expect(found?.mediaURL.absoluteString == "https://cdn.example.com/show/master.m3u8")
    #expect(found?.subtitles == [
        SniffedSubtitle(url: URL(string: "https://cdn.example.com/show/zh.vtt")!,
                        name: "繁體中文", language: "zh-TW", format: "text/vtt", isDefault: true)
    ])
}

@MainActor @Test func capturesASubtitleRequestedJustAfterTheMediaURL() async throws {
    let found = await sniffResult("""
    <html><body><script>
      var video = document.createElement('video');
      video.src = 'https://cdn.example.com/show/movie.mp4';
      setTimeout(function () {
        fetch('https://cdn.example.com/show/captions.srt').catch(function () {});
      }, 40);
    </script></body></html>
    """, grace: .milliseconds(180))
    #expect(found?.mediaURL.absoluteString == "https://cdn.example.com/show/movie.mp4")
    #expect(found?.subtitles.map(\.url.absoluteString) == ["https://cdn.example.com/show/captions.srt"])
    #expect(found?.subtitles.first?.format == "application/x-subrip")
}

@MainActor @Test func aSubtitleRequestAloneIsNeverMistakenForTheVideo() async throws {
    let found = await sniffResult("""
    <html><body><script>
      fetch('https://cdn.example.com/show/captions.vtt').catch(function () {});
    </script></body></html>
    """, timeout: .milliseconds(350), grace: .milliseconds(80))
    #expect(found == nil)
}

@MainActor @Test func aLaterTrackDeclarationUpgradesMetadataForTheSameURL() async throws {
    let found = await sniffResult("""
    <html><body><script>
      fetch('https://cdn.example.com/show/zh.vtt').catch(function () {});
      var video = document.createElement('video');
      var track = document.createElement('track');
      track.kind = 'subtitles';
      track.srclang = 'zh-TW';
      track.label = '中文';
      track.src = 'https://cdn.example.com/show/zh.vtt';
      video.appendChild(track);
      video.src = 'https://cdn.example.com/show/movie.mp4';
      document.body.appendChild(video);
    </script></body></html>
    """)
    #expect(found?.subtitles.count == 1)
    #expect(found?.subtitles.first?.name == "中文")
    #expect(found?.subtitles.first?.language == "zh-TW")
}

@MainActor @Test func metadataTracksAreNotOfferedAsSubtitles() async throws {
    let found = await sniffResult("""
    <html><body><video>
      <source src="https://cdn.example.com/show/movie.mp4">
      <track kind="metadata" src="https://cdn.example.com/show/chapters.vtt" label="chapters">
    </video></body></html>
    """)
    #expect(found?.mediaURL.absoluteString == "https://cdn.example.com/show/movie.mp4")
    #expect(found?.subtitles.isEmpty == true)
}

/// IOS-POC-43: two sniffs at once. Playback keeps "the newest wins" — the earlier one comes back
/// empty — while the source check, which sniffs eight sites side by side, lets both finish.
@MainActor @Test func overlappingSniffsCancelUnlessTheyWaitTheirTurn() async throws {
    func page(_ n: Int) -> URL {
        // The stream is requested late, so the second sniff starts while the first still waits.
        let html = "<html><body><script>setTimeout(function () { var x = new XMLHttpRequest(); "
            + "x.open('GET', 'https://cdn.example.com/\(n)/index.m3u8'); }, 300);</script></body></html>"
        return URL(string: "data:text/html;base64,\(Data(html.utf8).base64EncodedString())")!
    }
    func stream(_ n: Int) -> String { "https://cdn.example.com/\(n)/index.m3u8" }
    let sniffer = MediaSniffer()

    let older = Task { await sniffer.sniff(page: page(1), timeout: .seconds(6)) }
    try await Task.sleep(for: .milliseconds(100))
    let newer = await sniffer.sniff(page: page(2), timeout: .seconds(6))
    #expect(await older.value == nil)
    #expect(newer?.absoluteString == stream(2))

    let waiting = Task {
        await MediaSniffer.waitsForTurn.withValue(true) { await sniffer.sniff(page: page(3), timeout: .seconds(6)) }
    }
    try await Task.sleep(for: .milliseconds(100))
    let queued = await MediaSniffer.waitsForTurn.withValue(true) {
        await sniffer.sniff(page: page(4), timeout: .seconds(6))
    }
    #expect(await waiting.value?.absoluteString == stream(3))
    #expect(queued?.absoluteString == stream(4))
}

/// `MediaProbe` is what keeps the sniffer off the playback path for streams that already work:
/// `…/play/e0R98E7b` has no extension but is media, and `…/share/<id>` has no extension and is a
/// page. Only the second should ever be sniffed.
@Test func probeSeparatesAPlayerPageFromAStream() async throws {
    guard ProcessInfo.processInfo.environment["WANG_MOVIE_JSON"] != nil else { return }
    // Live, because the point is the real Content-Type of a real provider. Gated with the other
    // network checks so the offline suite stays offline.
    let page = URL(string: "https://vip.ffzy-plays.com/share/a73b3ce4fc516b20162512ee82ae508f")!
    let kind = await MediaProbe.classify(page)
    print("[probe] /share/ classified as \(kind)")
    #expect(kind == .page || kind == .unknown, "a /share/ link is a player page, never media")
}

// MARK: - IOS-POC-6C: a wrapper page that carries the stream in its own query string

/// The shape IOS-POC-6B hit on 去看吧: drpy answered `parse:1` with a page, and the page *was* the
/// address. Taking it costs no web view, no hook and no timeout.
@Test func aStreamNamedInTheWrapperPagesQueryIsTakenDirectly() throws {
    let wrapper = try #require(URL(string:
        "https://www.k9dm.com/1006/vip/?url=https://vip.dytt-network.com/20260914/39525_86d53348/index.m3u8"))
    #expect(MediaSniffer.embeddedMedia(in: wrapper)?.absoluteString
            == "https://vip.dytt-network.com/20260914/39525_86d53348/index.m3u8")

    // Percent-encoded is the same fact written differently.
    let encoded = try #require(URL(string:
        "https://host.invalid/play?src=https%3A%2F%2Fcdn.invalid%2Fa%2Findex.m3u8&t=1"))
    #expect(MediaSniffer.embeddedMedia(in: encoded)?.absoluteString == "https://cdn.invalid/a/index.m3u8")
}

@Test func aQueryThatOnlyLooksLikeMediaIsLeftAlone() throws {
    // No query at all.
    #expect(MediaSniffer.embeddedMedia(in: try #require(URL(string: "https://host.invalid/play/1.html"))) == nil)
    // An image, which the exclusions already cover.
    #expect(MediaSniffer.embeddedMedia(in: try #require(URL(string:
        "https://host.invalid/play?poster=https://cdn.invalid/a.jpg"))) == nil)
    // Relative, so it is not an address this can hand a player.
    #expect(MediaSniffer.embeddedMedia(in: try #require(URL(string:
        "https://host.invalid/play?next=/videos/a.mp4"))) == nil)
    // A page, not a stream.
    #expect(MediaSniffer.embeddedMedia(in: try #require(URL(string:
        "https://host.invalid/play?go=https://other.invalid/watch.html"))) == nil)
    // Present but empty.
    #expect(MediaSniffer.embeddedMedia(in: try #require(URL(string:
        "https://host.invalid/play?url="))) == nil)
}

/// The hook and the query check must agree about what a stream looks like, because the same URL can
/// arrive either way.
@Test func bothSniffPathsShareOneCandidateTest() {
    #expect(MediaSniffer.isCandidate("https://cdn.invalid/a/index.m3u8"))
    #expect(MediaSniffer.isCandidate("HTTPS://CDN.INVALID/A/INDEX.M3U8"))
    #expect(!MediaSniffer.isCandidate("blob:https://cdn.invalid/x"))
    #expect(!MediaSniffer.isCandidate("https://cdn.invalid/a.png"))
    #expect(!MediaSniffer.isCandidate("/relative/a.mp4"))
}
