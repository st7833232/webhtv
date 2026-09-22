import CryptoKit
import Foundation

/// The configuration's `ads` list, turned into WebKit content-blocker rules (IOS-POC-5S-1).
///
/// **What `ads` actually is, measured rather than assumed.** It is a flat array of strings, and the
/// two configurations in use carry 63 entries between them — 1 in `wang-movie.json`, 62 in
/// `wang-sex.json`. **62 are domain-shaped and 1 is a whole URL**
/// (`https://lf1-cdn-tos.bytegoofy.com/obj/…`). Android's only consumer is
/// `CustomWebView.shouldInterceptRequest`, which calls `Util.containOrMatch(host, ad)` —
/// `host.contains(ad) || host.matches(ad)` — against the **host alone**. A whole URL can never be a
/// substring of a host, so **that entry is already inert on Android**, and it stays inert here.
/// Normalising it to its host would be inventing behaviour Android does not have.
///
/// ## Three deliberate differences from Android, each narrowing
///
/// 1. **Literal domains are escaped, not treated as patterns.** Android hands the raw string to
///    `String.matches`, so `s13.cnzz.com` is a regex whose dots match any character. Every one of
///    the 63 entries was measured to be a literal domain with **no regex metacharacter and nothing
///    six characters or shorter**, so escaping them loses no configured behaviour and removes the
///    substring-style over-blocking that a short entry would otherwise cause.
/// 2. **The host is anchored.** Android's `contains` would match `s13.cnzz.com.example.net`; the
///    rule below matches the domain and its subdomains and nothing else.
/// 3. **The top-level document is never blocked.** `resource-type` lists everything WebKit offers
///    *except* `document`, so a page the sniffer was asked to load cannot be eaten by an ad rule —
///    only the subresources it goes on to request. **This is a project-specific safety narrowing,
///    not Android parity**: Android blocks by host whatever the request is for. Sniffing a page is
///    the one thing this web view exists to do, and a rule that can cancel it would turn a blocklist
///    into a source outage.
///
/// Nothing here deletes DOM nodes, guesses at what looks like an ad, or touches an m3u8 playlist.
/// `WKContentRuleList` is WebKit's own declarative blocker — the same engine a Safari content
/// blocker uses — so the matching happens below this code entirely.
public struct AdBlockList: Sendable, Equatable {
    /// Deterministic and content-derived, so two configurations can never collide and switching
    /// away and back reuses the compiled list instead of building a different one.
    public let identifier: String
    /// The content-blocker JSON, ready for `WKContentRuleListStore.compileContentRuleList`.
    public let json: String
    /// The entries that became rules, in configuration order.
    public let blocked: [String]
    /// The entries that could not become a host rule and are carried here only so they can be
    /// reported rather than silently dropped.
    public let inert: [String]

    /// Everything WebKit's content blocker can match **except `document`** — see the note above.
    static let resourceTypes = ["image", "style-sheet", "script", "font", "raw", "svg-document",
                                "media", "popup"]

    /// Builds the list, or **nil when there is nothing to block**.
    ///
    /// Nil is the whole story: no identifier, no compile, and no rule list added to the web view —
    /// an empty `ads` must be indistinguishable from a build with no blocker in it at all.
    public static func make(ads: [String]) -> AdBlockList? {
        var blocked = [String]()
        var inert = [String]()
        for entry in ads {
            let value = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if isHostShaped(value) { blocked.append(value) } else if !value.isEmpty { inert.append(value) }
        }
        guard !blocked.isEmpty else { return nil }

        let rules = blocked.map { host -> [String: Any] in
            ["trigger": ["url-filter": filter(for: host), "resource-type": resourceTypes],
             "action": ["type": "block"]]
        }
        // `.sortedKeys` is load-bearing, not tidiness: a Swift dictionary has no order, so without it
        // the same `ads` serialise differently from one call to the next and the content-derived
        // identifier below stops being an identity at all. Measured — the first version of this
        // failed `a.identifier == aAgain.identifier` for exactly that reason.
        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }

        // The identity is the rules themselves, so it changes exactly when the blocking behaviour
        // changes — which is what keeps configuration A's list off configuration B's web view.
        let digest = SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined()
        return AdBlockList(identifier: "webhtv-ads-\(digest.prefix(32))", json: json,
                           blocked: blocked, inert: inert)
    }

    /// Is this entry something Android's `host.contains(ad)` could ever match?
    ///
    /// A host is what that test compares against, so an entry carrying a scheme, a path, a query or
    /// whitespace can never fire there and must not fire here either. Kept deliberately literal:
    /// this is a classifier, not a parser, and it decides only whether an entry becomes a rule.
    static func isHostShaped(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 253 else { return false }
        guard !value.contains("/"), !value.contains(":"), !value.contains("?"), !value.contains("#") else { return false }
        guard value.contains("."), !value.hasPrefix("."), !value.hasSuffix(".") else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    /// The narrowest rule that still blocks the domain and its subdomains.
    ///
    /// `url-filter` is a regular expression over the whole URL, so the literal has to be escaped or
    /// its dots would match any character. Anchored at the scheme and closed at `[:/]` — the end of
    /// the authority — so the domain cannot be matched inside a path or inside a longer hostname.
    ///
    /// **Two things here were measured against WebKit rather than assumed.** Closing with
    /// `([:/]|$)` is rejected — "Invalid or unsupported regular expression" — because the content
    /// blocker's subset only takes `$` at the very end of a pattern; `[:/]` alone is enough, since
    /// WebKit canonicalises `https://host` to `https://host/` before matching. And only `.` is
    /// escaped: `isHostShaped` has already limited the input to letters, digits, `.`, `-` and `_`,
    /// of which `.` is the one regex metacharacter, while escaping `-` or `/` produces an escape
    /// sequence the subset does not accept.
    static func filter(for host: String) -> String {
        let escaped = host.replacingOccurrences(of: ".", with: "\\.")
        return "^https?://([^/]+\\.)?\(escaped)[:/]"
    }
}
