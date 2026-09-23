import Foundation

/// IOS-POC-5S-3 — the configuration's `rules`, ported from Android's `Sniffer`.
///
/// **All of this is pure.** Host extraction, rule selection, `exclude`/`regex` precedence and the
/// script lookup are arithmetic over strings, so `swift test` drives every branch without a web
/// view. The WebKit layer does nothing but call into here and evaluate what comes back.
///
/// ## The Android contract, read from the source rather than summarised
///
/// `app/src/main/java/com/fongmi/android/tv/utils/Sniffer.java`:
///
/// ```java
/// private static Rule getRule(Uri uri) {
///     if (uri.getHost() == null) return Rule.empty();
///     String hosts = TextUtils.join(",", Arrays.asList(UrlUtil.host(uri),
///                                                      UrlUtil.host(uri.getQueryParameter("url"))));
///     for (Rule rule : RuleConfig.get().getRules())
///         for (String host : rule.getHosts())
///             if (Util.containOrMatch(hosts, host)) return rule;
///     return Rule.empty();
/// }
///
/// public static boolean isVideoFormat(String url) {
///     Rule rule = getRule(UrlUtil.uri(url));
///     for (String exclude : rule.getExclude()) if (url.contains(exclude)) return false;
///     for (String exclude : rule.getExclude()) if (Pattern.compile(exclude).matcher(url).find()) return false;
///     for (String regex : rule.getRegex()) if (url.contains(regex)) return true;
///     for (String regex : rule.getRegex()) if (Pattern.compile(regex).matcher(url).find()) return true;
///     …built-in SNIFFER pattern…
/// }
/// ```
///
/// Four things in there are easy to paraphrase wrongly, so they are spelled out:
///
/// 1. **The haystack is one joined string**, `"<direct host>,<url= param host>"`. There is therefore
///    **no precedence between the direct host and the wrapped one** — a rule matches if its host
///    appears anywhere in that pair. Precedence lives at the *rule* level: configuration order,
///    first match wins.
/// 2. **`containOrMatch` is substring-or-full-match, and only against the host string.** It is
///    `text.contains(regex) || text.matches(regex)`, where Java's `matches` requires the *whole*
///    string to match. It is **not** matching against the URL, and not fuzzy.
/// 3. **Each of `exclude` and `regex` is applied in two passes** — every entry as a literal
///    substring first, then every entry as a regular expression. A literal hit on the second entry
///    therefore beats a pattern hit on the first, and porting it as one pass per entry would change
///    which rule wins.
/// 4. **`exclude` outranks `regex`**, and both outrank the built-in pattern.
///
/// ## What this deliberately does not do
///
/// `regex` and `exclude` are tested **against the URL string**. They never open, parse or rewrite an
/// m3u8 playlist. IOS-POC-5S measured that the nine playlist-shaped entries in `wang-sex.json`
/// (`#EXT-X-DISCONTINUITY`, `15.1666`, `16.63`) have **no HLS consumer anywhere in the Android
/// repository** — `Rule.getRegex/getExclude/getScript` is read only by `Sniffer`, which sees URLs.
/// They are inert on Android and they stay inert here. Inventing a playlist-rewriting meaning for
/// them would be making up a contract, which this project forbids.

// MARK: - One rule

/// One entry of the configuration's `rules`, shaped exactly like Android's `Rule.java`.
///
/// Every list is absent-tolerant for the same reason Android's getters return an empty list on null:
/// Gson leaves a missing field null, and 8 of the 10 rules measured in `wang-movie.json` are missing
/// at least one of `regex`, `script` and `exclude`.
public struct SnifferRule: Sendable, Equatable, Decodable {
    public let name: String
    public let hosts: [String]
    public let regex: [String]
    public let script: [String]
    public let exclude: [String]

    public init(name: String = "", hosts: [String] = [], regex: [String] = [],
                script: [String] = [], exclude: [String] = []) {
        self.name = name
        self.hosts = hosts
        self.regex = regex
        self.script = script
        self.exclude = exclude
    }

    enum CodingKeys: String, CodingKey { case name, hosts, regex, script, exclude }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func strings(_ key: CodingKeys) -> [String] {
            ((try? values.decodeIfPresent([String].self, forKey: key)) ?? nil) ?? []
        }
        name = ((try? values.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? ""
        hosts = strings(.hosts)
        regex = strings(.regex)
        script = strings(.script)
        exclude = strings(.exclude)
    }
}

// MARK: - What a rule says about one URL

/// What the configured rules decided about a candidate URL.
public enum SnifferVerdict: Sendable, Equatable {
    /// A `regex` entry matched: the rules say this is the stream.
    case video
    /// An `exclude` entry matched: the rules say it is not.
    case notVideo
    /// No rule matched this host, or the matched rule said nothing about this URL. The built-in
    /// candidate test decides, exactly as it did before IOS-POC-5S-3.
    case undecided
}

// MARK: - The rule set

/// The active configuration's `rules`, and the three questions the sniffer asks them.
///
/// Value semantics and no caching, so a configuration switch cannot leave anything behind: the whole
/// set is rebuilt from whichever configuration is adopted, exactly the way `AdBlockList` is
/// (IOS-POC-5S-1).
public struct SnifferRules: Sendable, Equatable {
    /// In the configuration's own order, because first match wins.
    public let rules: [SnifferRule]

    public init(rules: [SnifferRule]) {
        self.rules = rules
    }

    /// Builds the set, or **nil when there is nothing configured**.
    ///
    /// Nil is the whole story, the same way it is for `AdBlockList`: no rule lookup happens at all,
    /// so a configuration without `rules` is indistinguishable from a build made before this stage.
    /// A rule with no `hosts` can never be selected, so it is dropped rather than carried.
    public static func make(rules: [SnifferRule]) -> SnifferRules? {
        let usable = rules.filter { rule in rule.hosts.contains { !$0.isEmpty } }
        return usable.isEmpty ? nil : SnifferRules(rules: usable)
    }

    /// `Sniffer.getRule(uri)` — the first rule, in configuration order, whose host matches.
    ///
    /// The haystack is the direct host and the host of the `url=` query parameter, joined with a
    /// comma, exactly as Android joins them. That is why neither takes precedence over the other.
    public func rule(for url: URL) -> SnifferRule? {
        guard let haystack = Self.hostHaystack(for: url) else { return nil }
        for rule in rules {
            for host in rule.hosts where Self.containOrMatch(haystack, host) {
                return rule
            }
        }
        return nil
    }

    /// The rule half of `Sniffer.isVideoFormat`, with Android's exact four-pass order.
    ///
    /// The rule is selected by the **candidate's own** host — this is the one place Android passes
    /// the request URL rather than the page URL.
    public func verdict(for candidate: String) -> SnifferVerdict {
        guard let url = URL(string: candidate), let rule = rule(for: url) else { return .undecided }
        // Literal pass first, across every entry, then the pattern pass across every entry. Folding
        // these into one loop per entry would change which entry decides.
        if rule.exclude.contains(where: { !$0.isEmpty && candidate.contains($0) }) { return .notVideo }
        if rule.exclude.contains(where: { Self.find($0, in: candidate) }) { return .notVideo }
        if rule.regex.contains(where: { !$0.isEmpty && candidate.contains($0) }) { return .video }
        if rule.regex.contains(where: { Self.find($0, in: candidate) }) { return .video }
        return .undecided
    }

    /// `Sniffer.getScript(uri)` — the scripts for the **page** that just finished loading.
    ///
    /// A different URI from `verdict(for:)`: Android calls this from `onPageFinished` with the page
    /// address, and `isVideoFormat` with each subresource address. Using one for the other would
    /// inject the wrong page's scripts.
    public func script(for page: URL) -> [String] {
        (rule(for: page)?.script ?? []).filter { !$0.isEmpty }
    }

    // MARK: Android's string helpers

    /// `TextUtils.join(",", [UrlUtil.host(uri), UrlUtil.host(uri.getQueryParameter("url"))])`.
    ///
    /// Nil when the URL has no host at all, which is Android's `Rule.empty()` early return.
    /// `UrlUtil.host` lowercases and trims, and answers `""` for a missing value — so a URL with no
    /// `url=` parameter yields `"example.com,"`, trailing comma and all. Reproduced rather than
    /// tidied, because a rule host could in principle contain a comma.
    static func hostHaystack(for url: URL) -> String? {
        guard let direct = host(of: url), !direct.isEmpty else { return nil }
        let wrapped = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "url" }?.value
            .flatMap { URL(string: $0) }
            .flatMap { host(of: $0) } ?? ""
        return direct + "," + wrapped
    }

    private static func host(of url: URL) -> String? {
        url.host?.lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// `Util.containOrMatch(text, regex)`: `text.contains(regex) || text.matches(regex)`.
    ///
    /// Java's `matches` requires the **entire** string to match, which is why this compares the match
    /// range against the whole range rather than simply asking whether one was found.
    ///
    /// Android wraps this in `try { … } catch (Exception e) { return false; }`, so an unparseable
    /// host pattern is already a non-match there. **This one is parity, not a narrowing.**
    static func containOrMatch(_ text: String, _ pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        if text.contains(pattern) { return true }
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let whole = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: whole) else { return false }
        return match.range == whole
    }

    /// `Pattern.compile(p).matcher(text).find()` — a match anywhere.
    ///
    /// **Here the fail-safe is a deliberate iOS narrowing.** Android's `isVideoFormat` compiles these
    /// patterns *outside* any try/catch, so a malformed `regex` or `exclude` entry throws
    /// `PatternSyntaxException` and takes the sniff — or the app — down with it. There is no Android
    /// fallback to port. Treating an uncompilable pattern as "did not match" is the most
    /// conservative reading available: it leaves the built-in candidate test to decide, which is the
    /// behaviour that existed before this stage.
    static func find(_ pattern: String, in text: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The patterns that could not be compiled, for a one-off diagnostic when a set is adopted.
    ///
    /// Reported once per configuration rather than once per URL: a malformed entry would otherwise
    /// log on every candidate of every sniff, which is exactly the permanent verbose logger this
    /// project keeps saying it does not want.
    public var uncompilablePatterns: [String] {
        rules.flatMap { rule in
            (rule.regex + rule.exclude).filter { pattern in
                !pattern.isEmpty && (try? NSRegularExpression(pattern: pattern)) == nil
            }
        }
    }
}
