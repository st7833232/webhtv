import Foundation

/// One site's content source, whether it is a native CMS endpoint or a ported `csp_*` spider.
///
/// This exists because the app had `CMSClient(site:)` hard-coded at every content call, so a
/// registered spider could never reach the UI no matter how well it worked. The five methods below
/// are the same five `CMSClient` already exposed, with the same signatures, so the call sites swap
/// one type name and nothing else.
///
/// **No new model types.** `SpiderSession` answers in CatVod JSON and `CMSResponse` / `Vod` /
/// `Flag` / `Episode` already decode exactly that — the spider ports were written to produce the
/// shape the app was already parsing. The spider branch therefore only decodes; it never reshapes.
public enum SourceClient: Sendable {
    case cms(CMSClient)
    case spider(SpiderSession)

    /// Builds the right client for a site. A `csp_*` site the registry can drive becomes a spider;
    /// anything else falls back to `CMSClient`, which rejects unsupported types as it always did.
    ///
    /// Spider sessions are cached per site by `SpiderSessionStore`, because a spider is stateful:
    /// a rule-engine site downloads its rule file during `init`, and building a fresh session per
    /// call would re-fetch it on every page, every search and every episode.
    public static func make(site: Site, resolver: CSPSourceResolver) async throws -> SourceClient {
        guard resolver.canResolve(site) else { return .cms(try CMSClient(site: site)) }
        return .spider(try await SpiderSessionStore.shared.session(for: site, resolver: resolver))
    }

    public func home(page: Int = 1) async throws -> CMSResponse {
        switch self {
        case .cms(let client):
            return try await client.home(page: page)
        case .spider(let session):
            let home = try await decode(CMSResponse.self, from: session.home())
            // XBPQ always returns an empty home list and XYQHiker only fills one when its rule file
            // sets 首页推荐链接, so a spider home would otherwise render an empty grid. This is the
            // same fallback a type-4 home already uses: list the first browsable category.
            guard home.list.isEmpty, let first = home.firstListableCategory else { return home }
            let listing = try await category(id: first.id, page: page)
            // Keep the home response's filters: the fallback only borrows the category's titles.
            return CMSResponse(classes: home.classes, list: listing.list, filters: home.filters)
        }
    }

    /// `extend` carries the chosen filter values, keyed exactly as the source's own filter rows
    /// name them. A MacCMS endpoint has no filter protocol, so it ignores them.
    public func category(id: String, page: Int = 1,
                         extend: [String: String] = [:]) async throws -> CMSResponse {
        switch self {
        case .cms(let client):
            return try await client.category(id: id, page: page)
        case .spider(let session):
            return try await decode(CMSResponse.self,
                                    from: session.category(tid: id, page: String(page), extend: extend))
        }
    }

    public func search(_ keyword: String, page: Int = 1) async throws -> CMSResponse {
        switch self {
        case .cms(let client):
            return try await client.search(keyword, page: page)
        case .spider(let session):
            return try await decode(CMSResponse.self, from: session.search(key: keyword, page: String(page)))
        }
    }

    public func detail(id: String) async throws -> Vod? {
        switch self {
        case .cms(let client):
            return try await client.detail(id: id)
        case .spider(let session):
            return try await decode(CMSResponse.self, from: session.detail(ids: [id])).list.first
        }
    }

    /// Resolves an episode to something `AVPlayer` can open, or nil when it cannot.
    ///
    /// The spider branch deliberately does **not** pre-check `episode.mediaURL` the way the CMS
    /// branch does: a spider episode target is frequently not a URL at all (`parse_api=…&url=…`),
    /// and `playerContent` is the thing that turns it into one.
    ///
    /// **The headers travel with the URL now.** A spider attaches them to its play result because
    /// the CDN behind that URL often refuses a request without them — bilibili's `upos-*` mirrors
    /// answer 403 to a bare request and 206 to one carrying a Referer, and that difference is the
    /// whole gap between "resolves" and "plays". They are used for the probe, for the sniff and by
    /// the player itself.
    public func playbackURL(for episode: Episode, flag: String) async throws -> PlaybackTarget? {
        switch self {
        case .cms(let client):
            // A MacCMS endpoint has no header protocol, so these are the app's own defaults: none.
            guard let play = try await client.playbackURL(for: episode, flag: flag) else { return nil }
            return await Self.target(from: play, headers: [:], parse: 0)
        case .spider(let session):
            let play = try await decode(SpiderPlayResponse.self, from: session.player(flag: flag, id: episode.url))
            return await Self.target(from: play.url, headers: play.header ?? [:], parse: play.parse)
        }
    }

    /// The one place a CatVod `url` becomes something the player can open, so the CMS and spider
    /// paths cannot drift apart again — reading that field was already broken in two different ways
    /// precisely because each path decoded it for itself.
    ///
    /// Only the default entry is resolved. A menu of five qualities would otherwise cost five
    /// probes, or five web views for a `parse:1` result, to open one episode.
    ///
    /// ponytail: switching quality in the picker therefore opens that entry's URL exactly as the
    /// source gave it, with no probe or sniff hop. Resolve the others lazily if a real multi-value
    /// source ever needs it — none of the 62 listed sources answers with a `url` array today.
    private static func target(from play: PlayURL, headers: [String: String], parse: Int) async -> PlaybackTarget? {
        let qualities = play.values.compactMap { value in
            URL(string: value.v).map { PlaybackQuality(name: value.n ?? "", url: $0) }
        }
        guard !qualities.isEmpty else { return nil }
        let index = PlaybackQuality.defaultIndex(in: qualities, position: play.position)
        let chosen = qualities[index].url
        let resolved: URL?
        if parse != 0 {
            // parse:1 is the spider saying outright "this is a page, sniff it" — no need to probe.
            resolved = await MediaSniffer.shared.sniff(page: chosen,
                                                       referer: headers["Referer"] ?? headers["referer"])
        } else {
            resolved = await Self.resolveMedia(chosen, headers: headers)
        }
        guard let resolved else { return nil }
        return PlaybackTarget(url: resolved, headers: headers,
                              qualities: qualities, position: play.position, defaultIndex: index)
    }

    /// A resolved URL may still be a player page rather than a stream: three type-1 sources hand
    /// back `…/share/<id>`. But the extension heuristic cuts both ways — `…/play/e0R98E7b` has no
    /// extension and *is* media — so probe first and only sniff what comes back as HTML. That keeps
    /// the web view off the playback path for every source that already worked.
    ///
    /// Sniffing is best effort, so a miss hands back the original URL rather than nil: a page that
    /// at least opens is not made worse by us failing to improve it.
    private static func resolveMedia(_ url: URL, headers: [String: String]) async -> URL? {
        if CMSClient.isDirectMedia(url) { return url }
        // Probing without the spider's headers is what made a referer-checked stream look dead:
        // the probe got the CDN's 403 and reported `.unknown`, never `.media`.
        guard await MediaProbe.classify(url, headers: headers) == .page else { return url }
        return await MediaSniffer.shared.sniff(page: url,
                                               referer: headers["Referer"] ?? headers["referer"]) ?? url
    }

    private func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }
}

/// A resolved episode: what to open, and what to send when opening it.
///
/// Two fields rather than a bare `URL` because a stream and the headers that make it play are one
/// fact, not two — every path that forgot the second half is a site that resolves and then 403s.
public struct PlaybackTarget: Sendable, Equatable {
    /// The stream to open: `qualities[defaultIndex]` after the probe/sniff hop.
    public let url: URL
    /// Request headers the source requires. Empty for every CMS source; `Referer` and `User-Agent`
    /// for the spiders that need them.
    public let headers: [String: String]
    /// The source's quality menu, in the source's own order — exactly one entry when it answered
    /// with a single URL, which is every source in this configuration today.
    public let qualities: [PlaybackQuality]
    /// The source's own preferred index, carried so a remembered choice can re-run
    /// `PlaybackQuality.defaultIndex` with the same inputs (IOS-POC-5R R6).
    public let position: Int
    /// The entry `url` was resolved from.
    public let defaultIndex: Int

    public init(url: URL, headers: [String: String] = [:],
                qualities: [PlaybackQuality] = [], position: Int = 0, defaultIndex: Int = 0) {
        self.url = url
        self.headers = headers
        // A single-URL source still has a one-entry menu, so callers never special-case emptiness.
        self.qualities = qualities.isEmpty ? [PlaybackQuality(name: "", url: url)] : qualities
        self.position = position
        self.defaultIndex = defaultIndex
    }
}

/// CatVod `playerContent`: `{"parse": 0, "url": "…"}`. `parse` is an int in every ported spider, but
/// some CatVod sources send it as a string, so both are accepted rather than failing the decode.
struct SpiderPlayResponse: Decodable, Sendable {
    let parse: Int
    /// All three shapes CatVod allows — see `PlayURL`. This was `String`, and an array made the
    /// decode throw rather than offering the qualities it was listing.
    let url: PlayURL
    /// CatVod calls it `header`, singular, and every ported spider fills it with the headers the
    /// stream needs. It was decoded away until IOS-POC-5P; a source whose CDN checks Referer could
    /// not play without it.
    let header: [String: String]?

    enum CodingKeys: String, CodingKey { case parse, url, header }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        url = try values.decodeIfPresent(PlayURL.self, forKey: .url) ?? PlayURL(values: [])
        // A spider may emit a non-string value here (a number, or `false` for "none"); one odd
        // header must not cost the whole play result, so anything undecodable is simply no headers.
        header = try? values.decodeIfPresent([String: String].self, forKey: .header)
        if let number = try? values.decode(Int.self, forKey: .parse) {
            parse = number
        } else if let text = try? values.decode(String.self, forKey: .parse) {
            parse = Int(text) ?? 0
        } else {
            parse = 0
        }
    }
}

/// Keeps one `SpiderSession` per site for the process lifetime.
///
/// A spider is stateful in a way `CMSClient` is not: `SpiderSession` guarantees `init(extend)` runs
/// exactly once, and that call is where a rule-engine site downloads and parses its rule file. The
/// app creates a client on every listing, page, search and episode, so without this store a single
/// XBPQ browse would re-download the rules a dozen times.
public actor SpiderSessionStore {
    public static let shared = SpiderSessionStore()

    private var sessions = [String: SpiderSession]()

    public init() {}

    /// Async since IOS-POC-6B: a drpy site fetches and verifies its engine before it has a runtime.
    /// A `csp_*` site still builds without touching the network.
    public func session(for site: Site, resolver: CSPSourceResolver) async throws -> SpiderSession {
        // `Site.id` is the site's key *and* its `ext`: a reloaded configuration may keep a key and
        // change what it points at, and a session caches the `ext` it was initialised with. Keying
        // on both means a changed site simply misses the cache, so correctness does not depend on
        // `reset()` having run first — which, being an actor hop from the reload, is not ordered
        // against the next lookup.
        let identity = site.id
        if let existing = sessions[identity] { return existing }
        let session = try await resolver.session(for: site)
        sessions[identity] = session
        return session
    }

    /// Drops every cached session. This reclaims the sessions a reloaded configuration orphaned; it
    /// is not what makes the reload correct — the cache key already is.
    ///
    /// **It must not `destroy()` them, and used to (IOS-POC-10Z).** A caller that already holds a
    /// session goes on using it: `SourceClient` takes one, then calls `home()`, `category()` and the
    /// rest on that value. The launch configuration refresh calls this method, so a reset routinely
    /// lands in the middle of somebody's first listing — and `destroy()` is a **spider** call, which
    /// every ported class implements by clearing the state `init` just built.
    ///
    /// Traced on the simulator, 荐片: `init` began, `reset()` ran while it was still fetching, the
    /// serial queue put `destroy` between `init` and `homeContent`, and `homeContent` then answered
    /// from a wiped `cfg` — no filter rows, after a rule-file fetch that had returned HTTP 200. The
    /// screen showed category chips with nothing under them, and switching source and back "fixed"
    /// it only because the second session had no reset racing it. Any spider that keeps state in
    /// `init` could lose it the same way; JianPian was merely the one slow enough to lose the race
    /// nearly every launch.
    ///
    /// Dropping the references is all this ever needed to do. ARC frees the `JSContext` when the
    /// last holder lets go, which is exactly the right moment — later than this method, on purpose.
    public func reset() async {
        sessions.removeAll()
    }
}
