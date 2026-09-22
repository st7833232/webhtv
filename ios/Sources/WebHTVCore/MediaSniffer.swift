import Foundation
import WebKit

/// What a URL turns out to be when asked for its first bytes.
public enum MediaKind: Sendable {
    /// Bytes that are not a web page — a playlist, a container, anything playable.
    case media
    /// An HTML document. A player page, not a stream.
    case page
    /// Unreachable, or an answer too ambiguous to judge.
    case unknown
}

/// Classifies a URL by fetching its first bytes.
///
/// Exists because the extension heuristic cuts both ways: `…/share/<id>` is a player page with no
/// extension, and `…/play/e0R98E7b` is a real stream with no extension either. Guessing from the
/// path alone would either miss the pages or send every extensionless stream through the sniffer
/// and add seconds to playback that already worked.
public enum MediaProbe {
    /// `headers` are the ones the source says the stream needs. Probing without them reports a
    /// referer-checked CDN's 403 as `.unknown`, which reads as "dead media" when the stream is fine.
    public static func classify(_ url: URL, headers: [String: String] = [:],
                                session: URLSession = .webHTV) async -> MediaKind {
        var request = URLRequest(url: url)
        // A range request keeps this cheap on a large file, and is how a player opens one anyway.
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(code) else { return .unknown }
            let type = ((response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if type.contains("text/html") { return .page }
            let head = String(decoding: data.prefix(64), as: UTF8.self).lowercased()
            if head.contains("<html") || head.contains("<!doc") || head.contains("<script") { return .page }
            return data.isEmpty ? .unknown : .media
        } catch {
            return .unknown
        }
    }
}

/// Loads a player page off-screen and reports the first media URL it requests.
///
/// **Why a JavaScript hook and not request interception.** Android's sniffer overrides
/// `WebViewClient.shouldInterceptRequest`, which sees every subresource request. `WKWebView` has no
/// equivalent: `WKNavigationDelegate` only sees navigations, and `WKURLSchemeHandler` cannot be
/// registered for http(s). So the only route is to hook the APIs a player uses — `XMLHttpRequest`,
/// `fetch`, and the `src` of media elements — and have the page report them back.
///
/// That makes this **best effort, not a guarantee**: a player that gets its stream inside a Worker,
/// through WASM, or from a source this hook does not cover will not be caught. It recovers the
/// common cases (hls.js and friends go through XHR/fetch; native players set a `src`) and returns
/// nil otherwise so the caller can fall back rather than hang.
@MainActor
public final class MediaSniffer {
    public static let shared = MediaSniffer()

    /// Extensions and fragments that mark a request as the stream itself. `video/tos` is in here
    /// because the rule files list it — some CDNs serve media from a path rather than a file name.
    nonisolated public static let defaultKeywords = [".m3u8", ".mp4", ".flv", ".mkv", ".ts?", "video/tos", "/videoplayback"]
    /// Fragments that look like a hit but never are.
    nonisolated public static let defaultExclusions = [".html", ".css", ".js?", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".ico", ".woff"]

    private var collector: Collector?

    /// The **active configuration's** ad rules, or nil for none (IOS-POC-5S-1).
    ///
    /// Set when a configuration is adopted and cleared when it has no `ads`, so switching source
    /// A → B → A can never leave A's rules on B's web view: the property carries one list at a time
    /// and its identity is derived from the rules themselves.
    ///
    /// **This is the only web view these rules ever reach.** They are added to the `Collector`'s own
    /// `WKWebViewConfiguration`, which is built per sniff and thrown away with it — not to the
    /// WebHome bridge's web view, not to any shared configuration, and not to a process-wide default.
    public var adBlockList: AdBlockList? {
        didSet { if adBlockList != oldValue { compiled = nil } }
    }

    /// The last compiled list, kept so a sniff does not recompile the same rules every time.
    /// Cleared whenever `adBlockList` changes, which is what stops a stale list surviving a switch.
    /// Internal rather than private so a test can assert that clearing actually happens — the whole
    /// point of configuration-scoped rules is that A → B → A never runs B's list on A's web view.
    var compiled: WKContentRuleList?

    public init() {}

    /// Compiles the active list once, and answers nil for every reason that should mean
    /// "no blocking" rather than "no sniffing": no list, or a compile this build cannot do.
    ///
    /// A compile failure is deliberately not an error. The sniffer's job is to find a stream; losing
    /// the ad rules costs some wasted requests, while refusing to sniff would cost the source.
    /// ponytail: a compiled list stays in `WKContentRuleListStore` after the configuration that
    /// needed it is gone, so the store grows by one entry per distinct `ads` set ever seen. That is
    /// a few kilobytes per configuration and it is what makes switching back free, so it is left
    /// alone; sweep `getAvailableIdentifiers` for the `webhtv-ads-` prefix if a user ever
    /// accumulates enough configurations for it to matter.
    private func contentRules() async -> WKContentRuleList? {
        guard let adBlockList else { return nil }
        if let compiled { return compiled }
        let store = WKContentRuleListStore.default()
        let list = try? await store?.compileContentRuleList(forIdentifier: adBlockList.identifier,
                                                            encodedContentRuleList: adBlockList.json)
        compiled = list
        return list
    }

    /// The same compile the sniffer performs, reachable from a test. Exists because the caching is
    /// the part that can be wrong, and it is unobservable from `sniff` without a network.
    func compiledRulesForTesting() async -> WKContentRuleList? { await contentRules() }

    /// Whether a URL the page mentioned is the stream itself.
    ///
    /// One predicate, two callers: the JavaScript hook's reports and the query-string check below.
    /// They used to be able to disagree, which is the kind of drift that makes a sniffer behave
    /// differently depending on which way it found the same URL.
    nonisolated static func isCandidate(_ value: String, keywords: [String], exclusions: [String]) -> Bool {
        let lower = value.lowercased()
        guard lower.hasPrefix("http") else { return false }
        guard keywords.contains(where: { lower.contains($0.lowercased()) }) else { return false }
        return !exclusions.contains(where: { lower.contains($0.lowercased()) })
    }

    /// The stream a wrapper page carries in its own query string.
    ///
    /// A player page frequently *is* the address: `…/vip/?url=https://cdn/…/index.m3u8` hands the
    /// stream over in plain sight, and 去看吧 resolves to exactly that shape (IOS-POC-6B). Reading
    /// it needs no web view, no injected hook and no timeout — which also means this path cannot be
    /// missed the way a hook can when a player fetches inside a Worker.
    ///
    /// Only an absolute http(s) value that passes the same candidate test is taken, so a `?poster=`
    /// or a relative `?next=` is left alone.
    nonisolated public static func embeddedMedia(
        in page: URL,
        keywords: [String] = defaultKeywords,
        exclusions: [String] = defaultExclusions
    ) -> URL? {
        guard let items = URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        for item in items {
            guard let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  isCandidate(value, keywords: keywords, exclusions: exclusions),
                  let url = URL(string: value) else { continue }
            return url
        }
        return nil
    }

    /// The stream a URL stands for: itself, or the one its query string names.
    ///
    /// Applied wherever a candidate is accepted, because a wrapper matches the keyword test on the
    /// strength of the very address it is wrapping — `…/vip/?url=…/index.m3u8` contains `.m3u8`, so
    /// the hook reports the wrapper and the player is handed a page. One level only: a doubly
    /// wrapped address has never been seen, and unwrapping blindly could walk somewhere unintended.
    nonisolated static func unwrapped(_ url: URL,
                                      keywords: [String] = defaultKeywords,
                                      exclusions: [String] = defaultExclusions) -> URL {
        embeddedMedia(in: url, keywords: keywords, exclusions: exclusions) ?? url
    }

    /// Returns the first URL the page requests that matches `keywords`, or nil on timeout.
    ///
    /// Serialised on the main actor, so two sniffs never share a web view. `referer` is set because
    /// a player page commonly refuses to load its stream without one.
    public func sniff(
        page: URL,
        referer: String? = nil,
        keywords: [String] = MediaSniffer.defaultKeywords,
        exclusions: [String] = MediaSniffer.defaultExclusions,
        timeout: Duration = .seconds(12)
    ) async -> URL? {
        // A page that names the stream in its own query string needs no web view at all. Checked
        // first because it is both cheaper and more reliable than loading the page and hoping the
        // player asks for it somewhere the hook can see.
        if let embedded = Self.embeddedMedia(in: page, keywords: keywords, exclusions: exclusions) {
            return embedded
        }

        // One sniff at a time: a second concurrent web view competes for the main actor and the
        // network, and no caller needs it.
        if let live = collector { live.cancel() }
        let rules = await contentRules()
        let collector = Collector(keywords: keywords, exclusions: exclusions, rules: rules)
        self.collector = collector
        defer { if self.collector === collector { self.collector = nil } }

        let found = await collector.run(page: page, referer: referer, timeout: timeout)
        return found
    }

    /// Owns one web view and one continuation for the duration of a single sniff.
    @MainActor
    private final class Collector: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let keywords: [String]
        private let exclusions: [String]
        private var webView: WKWebView?
        private var continuation: CheckedContinuation<URL?, Never>?
        private var timeoutTask: Task<Void, Never>?

        /// `rules` is the active configuration's ad blocker, or nil for none.
        private let rules: WKContentRuleList?

        init(keywords: [String], exclusions: [String], rules: WKContentRuleList?) {
            self.keywords = keywords.map { $0.lowercased() }
            self.exclusions = exclusions.map { $0.lowercased() }
            self.rules = rules
        }

        func run(page: URL, referer: String?, timeout: Duration) async -> URL? {
            await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                self.continuation = continuation

                let configuration = WKWebViewConfiguration()
                // The ad rules, on this sniff's own configuration and nowhere else.
                if let rules { configuration.userContentController.add(rules) }
                configuration.userContentController.add(self, name: Self.channel)
                configuration.userContentController.addUserScript(
                    WKUserScript(source: Self.hook, injectionTime: .atDocumentStart, forMainFrameOnly: false)
                )
                #if os(iOS)
                // Sniffing must not start playing anything or take over the audio session; the page
                // only has to *request* the stream for the hook to see it.
                configuration.allowsInlineMediaPlayback = true
                configuration.mediaTypesRequiringUserActionForPlayback = .all
                #endif

                let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 300),
                                        configuration: configuration)
                webView.navigationDelegate = self
                self.webView = webView

                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.finish(with: nil)
                }

                var request = URLRequest(url: page)
                if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
                webView.load(request)
            }
        }

        func cancel() { finish(with: nil) }

        private func finish(with url: URL?) {
            guard let continuation else { return }
            self.continuation = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            // Stop the page before handing back, or it keeps loading media in the background.
            webView?.stopLoading()
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.channel)
            webView?.navigationDelegate = nil
            webView = nil
            continuation.resume(returning: url)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let raw = message.body as? String else { return }
            let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard MediaSniffer.isCandidate(candidate, keywords: keywords, exclusions: exclusions),
                  let url = URL(string: candidate) else { return }
            // The reported URL may be a wrapper around the real one — that is how 去看吧's player
            // page resolves (IOS-POC-6B/6C), and the wrapper only matched because of the address
            // inside it.
            finish(with: MediaSniffer.unwrapped(url, keywords: keywords, exclusions: exclusions))
        }

        /// A page that fails to load will never report anything, so stop waiting for the timeout.
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finish(with: nil)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finish(with: nil)
        }

        private static let channel = "webhtvSniff"

        /// Injected at document start into every frame. Reports candidate URLs; Swift does the
        /// matching, so this stays the same for every site and rule set.
        private static let hook = """
        (function () {
          'use strict';
          var seen = Object.create(null);
          function report(value) {
            if (!value) return;
            var url = String(value);
            if (url.indexOf('blob:') === 0 || url.indexOf('data:') === 0) return;
            try { url = new URL(url, location.href).href; } catch (e) { return; }
            if (seen[url]) return;
            seen[url] = 1;
            try { window.webkit.messageHandlers.\(channel).postMessage(url); } catch (e) {}
          }

          var open = XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open = function (method, url) {
            report(url);
            return open.apply(this, arguments);
          };

          var fetcher = window.fetch;
          if (fetcher) {
            window.fetch = function (input) {
              report(typeof input === 'string' ? input : (input && input.url));
              return fetcher.apply(this, arguments);
            };
          }

          // A native player sets `src` rather than issuing a request we can hook, so watch the
          // property itself as well as the attribute.
          ['HTMLVideoElement', 'HTMLAudioElement', 'HTMLSourceElement'].forEach(function (name) {
            var type = window[name];
            if (!type) return;
            var descriptor = Object.getOwnPropertyDescriptor(type.prototype, 'src');
            if (!descriptor || !descriptor.set) return;
            Object.defineProperty(type.prototype, 'src', {
              get: function () { return descriptor.get ? descriptor.get.call(this) : ''; },
              set: function (value) { report(value); return descriptor.set.call(this, value); },
              configurable: true
            });
          });

          function scan(root) {
            var nodes = (root.querySelectorAll ? root.querySelectorAll('video,audio,source') : []);
            for (var i = 0; i < nodes.length; i++) {
              report(nodes[i].getAttribute('src') || nodes[i].src);
            }
          }

          if (window.MutationObserver) {
            new MutationObserver(function (records) {
              for (var i = 0; i < records.length; i++) {
                var record = records[i];
                if (record.type === 'attributes') { report(record.target.getAttribute('src')); continue; }
                for (var j = 0; j < record.addedNodes.length; j++) {
                  var node = record.addedNodes[j];
                  if (node.nodeType !== 1) continue;
                  if (/^(VIDEO|AUDIO|SOURCE)$/.test(node.tagName)) report(node.getAttribute('src') || node.src);
                  scan(node);
                }
              }
            }).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['src'] });
          }

          document.addEventListener('DOMContentLoaded', function () { scan(document); });
          scan(document);
        })();
        """
    }
}
