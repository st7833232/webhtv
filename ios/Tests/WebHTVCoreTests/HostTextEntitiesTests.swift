import Foundation
import Testing
@testable import WebHTVCore

// W-286: a selector's `Text` decodes character references the way Jsoup's text() does, so `&amp;` never reaches a
// title, a synopsis or a rule engine's field as is (docs/W-286-hostjs-text-entities.md).

private func texts(_ cases: [String: String]) async throws -> [String: String] {
    let body = cases.map { key, rule in "\(key): host.pdfh(html, '\(rule)')" }.joined(separator: ",\n")
    let runtime = try JavaScriptSpiderRuntime(
        name: "w286", script: """
        module.exports = {
          init: function () { return ''; },
          homeContent: function () {
            var html = '<h1>第二&amp;第三 &lt;b&gt; &quot;x&quot; &#39;y&#39;</h1>' +
                       '<p class="n">A&nbsp;&nbsp;B</p>' +
                       '<p class="num">&#25105;&#x4E00;&#X4e8c; &#128512;</p>' +
                       '<p class="bad">&#0;|&#xD800;|&#1114112;</p>' +
                       '<p class="keep">&amp;lt; &unknown; &amp AT&T</p>' +
                       '<p class="more">&hellip;&mdash;&middot;&copy;</p>' +
                       '<a class="u" href="/v?a=1&amp;b=2">x</a>';
            return JSON.stringify({ \(body), raw: host.text(host.pdfa(html, 'h1')[0]),
                                    href: host.pdfh(html, 'a.u&&href') });
          }
        };
        """, prelude: SpiderRegistry.bundled(bundle: .repoSpiders).prelude,
        storage: SpiderStorage(siteKey: "w286", defaults: .standard))
    let out = try #require(try JSONSerialization.jsonObject(
        with: Data(try await runtime.homeContent(filter: false).utf8)) as? [String: String])
    return out
}

@Test func textDecodesCharacterReferencesLikeJsoup() async throws {
    let out = try await texts(["named": "h1&&Text", "nbsp": "p.n&&Text", "numeric": "p.num&&Text",
                               "bad": "p.bad&&Text", "keep": "p.keep&&Text", "more": "p.more&&Text"])
    #expect(out["named"] == #"第二&第三 <b> "x" 'y'"#)
    // A non-breaking space is whitespace to Jsoup's text(): the run collapses to one space.
    #expect(out["nbsp"] == "A B")
    #expect(out["numeric"] == "我一二 😀")
    #expect(out["bad"] == "\u{FFFD}|\u{FFFD}|\u{FFFD}")
    // One pass only (`&amp;lt;` is the text `&lt;`); an unknown name or a reference without `;` stays as written.
    #expect(out["keep"] == "&lt; &unknown; &amp AT&T")
    #expect(out["more"] == "…—·©")
    // Unchanged on purpose: `host.text` stays raw (rule engines cut its markers), and so do attributes.
    #expect(out["raw"] == #"第二&amp;第三 &lt;b&gt; &quot;x&quot; &#39;y&#39;"#)
    #expect(out["href"] == "/v?a=1&amp;b=2")
}
