import Foundation

/// Turns a configured type-3 site whose `api` is a `csp_*` class name into a running session.
///
/// This is the routing change: the decision is no longer "type 3, therefore unsupported" but
/// "is this class in the registry". Everything above it keeps consuming CatVod JSON and never
/// learns whether a spider is Swift, JavaScript or anything else.
///
///     wang-movie.json → api: csp_AppGet → CSPSourceResolver → SpiderRegistry
///       → AppGet.js → JavaScriptCore → CatVodHost → CatVod JSON → existing UI
public struct CSPSourceResolver: Sendable {
    public let registry: SpiderRegistry
    private nonisolated(unsafe) let defaults: UserDefaults
    private let session: URLSession
    /// Where the configuration came from, so a spider's `ext` can point at a sibling rule file.
    private let source: ConfigSource

    public init(registry: SpiderRegistry = .bundled(),
                source: ConfigSource = .importedFile,
                defaults: UserDefaults = .standard,
                session: URLSession = .webHTV) {
        self.registry = registry
        self.source = source
        self.defaults = defaults
        self.session = session
    }

    /// True when this site is a `csp_*` spider the app can actually drive today.
    public func canResolve(_ site: Site) -> Bool {
        site.isCSPSpider && registry.canDrive(site.api)
    }

    public func session(for site: Site) throws -> SpiderSession {
        guard site.isCSPSpider else { throw SpiderError.notRegistered(site.api) }
        let runtime = try registry.makeRuntime(for: site.api, siteKey: site.key,
                                               defaults: defaults, session: session)
        return SpiderSession(site: site, runtime: runtime, extend: resolvedExtend(for: site))
    }

    /// A rule-engine site sets `ext` to a path like `./json/农民影视.json`. Resolve it against the
    /// configuration's own directory — the same resolver the `./jar/` and `./py/` references use —
    /// so the spider receives a URL it can fetch. Anything already absolute, or any inline JSON,
    /// passes through untouched.
    func resolvedExtend(for site: Site) -> String {
        let raw = site.rawExtJSON
        guard !raw.isEmpty, !raw.hasPrefix("{"), !raw.hasPrefix("["),
              !raw.lowercased().hasPrefix("http") else { return raw }
        return source.resourceURL(for: raw)?.absoluteString ?? raw
    }

    public func portability(of site: Site) -> SpiderPortability? {
        registry.entry(for: site.api)?.portability
    }
}
