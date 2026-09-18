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
    public static let defaultKeywords = [".m3u8", ".mp4", ".flv", ".mkv", ".ts?", "video/tos", "/videoplayback"]
    /// Fragments that look like a hit but never are.
    public static let defaultExclusions = [".html", ".css", ".js?", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".ico", ".woff"]

    private var collector: Collector?

    public init() {}

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
        // One sniff at a time: a second concurrent web view competes for the main actor and the
        // network, and no caller needs it.
        if let live = collector { live.cancel() }
        let collector = Collector(keywords: keywords, exclusions: exclusions)
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

        init(keywords: [String], exclusions: [String]) {
            self.keywords = keywords.map { $0.lowercased() }
            self.exclusions = exclusions.map { $0.lowercased() }
        }

        func run(page: URL, referer: String?, timeout: Duration) async -> URL? {
            await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                self.continuation = continuation

                let configuration = WKWebViewConfiguration()
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
            let lower = candidate.lowercased()
            guard lower.hasPrefix("http") else { return }
            guard keywords.contains(where: lower.contains) else { return }
            guard !exclusions.contains(where: lower.contains) else { return }
            guard let url = URL(string: candidate) else { return }
            finish(with: url)
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
