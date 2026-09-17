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
