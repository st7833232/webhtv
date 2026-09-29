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

    public init(registry: SpiderRegistry = .active(),
                source: ConfigSource = .importedFile,
                defaults: UserDefaults = .standard,
                session: URLSession = .webHTV) {
        self.registry = registry
        self.source = source
        self.defaults = defaults
        self.session = session
    }

    /// True when this site is a spider the app can drive today — a registered `csp_*` class, or a
    /// drpy site whose engine this build can load.
    ///
    /// A drpy site is listed on the strength of its shape, not of a completed download: the engine
    /// is fetched when the session is built, and a failure there refuses that one site with a named
    /// error rather than quietly removing it from the picker. An imported configuration file has no
    /// origin, so it can never satisfy the same-origin rule and is not offered at all.
    public func canResolve(_ site: Site) -> Bool {
        if site.isDrpySpider { return source.baseURL != nil }
        // A Python site is listed only when this build actually has an interpreter. Without one it
        // stays hidden rather than appearing and failing on the first tap — the same rule the
        // registry applies to an unported `csp_*` class.
        if site.isPythonSpider { return PythonSpiderSupport.isAvailable && source.baseURL != nil }
        return site.isCSPSpider && registry.canDrive(site.api)
    }

    /// Builds the session. Async because a drpy site has to fetch and verify its engine first;
    /// a `csp_*` site still resolves without touching the network.
    public func session(for site: Site) async throws -> SpiderSession {
        if site.isDrpySpider { return try await drpySession(for: site) }
        if site.isPythonSpider { return try await pythonSession(for: site) }
        guard site.isCSPSpider else { throw SpiderError.notRegistered(site.api) }
        let runtime = try registry.makeRuntime(for: site.api, siteKey: site.key,
                                               defaults: defaults, session: session)
        return SpiderSession(site: site, runtime: runtime, extend: resolvedExtend(for: site))
    }

    /// A drpy site runs on **the same `JavaScriptSpiderRuntime`** every ported spider uses. The only
    /// differences are what goes in the prelude — `host.js` plus the verified engine — and that the
    /// `extend` handed to `init` is the site's rule script text rather than a path, because the
    /// engine must not do its own fetching outside the origin check.
    private func drpySession(for site: Site) async throws -> SpiderSession {
        // One download serves both contracts, and which one it is can only be known from the bytes:
        // `type 3` with a `.js` api is all the configuration says, and both TVBox runtimes wear it.
        let (name, text) = try await DrpyEngine.script(at: site.drpyRuleReference, source: source)
        if DrpyEngine.isJavaScriptSpider(text) {
            return try jsSpiderSession(for: site, named: name, script: text)
        }
        // The engine downloads on its own session: a megabyte of libraries needs a longer
        // inactivity ceiling than the 10 s a content request gets. The spider itself still runs on
        // the content session, so nothing about its own HTTP changes.
        let prelude = try await DrpyEngineStore.shared.prelude(source: source, host: registry.prelude)
        let runtime = try JavaScriptSpiderRuntime(
            name: "drpy-\(site.key)",
            script: registry.drpyBridge,
            prelude: prelude,
            storage: SpiderStorage(siteKey: site.key, defaults: defaults),
            session: session)
        return SpiderSession(site: site, runtime: runtime, extend: text)
    }

    /// A **CatVod/TVBox JS spider** (IOS-POC-10T): the script *is* the spider, so unlike drpy there
    /// is no engine to fetch — and none to download, which is the point. 麻豆's script needs exactly
    /// one global, `req`, and `moduleRuntime` has supplied it (and `pdfh`/`pdfa`/`local`/`print`) to
    /// the drpy sites all along. So the prelude is `host.js` + those globals + the script itself,
    /// rewritten out of ES-module syntax by the same rewriter drpy's libraries go through, and the
    /// bridge is the twenty lines mapping `__jsEvalReturn()`'s seven methods onto the ABI.
    ///
    /// `extend` stays the site's raw `ext`, exactly as every other spider receives it — the script
    /// is already in the prelude, so nothing has to travel through `init` to get there.
    private func jsSpiderSession(for site: Site, named name: String,
                                 script: String) throws -> SpiderSession {
        let module = (name as NSString).deletingPathExtension
        let prelude = [registry.prelude,
                       DrpyEngine.moduleRuntime,
                       "globalThis.__jsSpiderModule = \(jsonString(module));",
                       DrpyEngine.rewritten(script, named: module)].joined(separator: "\n;\n")
        let runtime = try JavaScriptSpiderRuntime(
            name: "jsspider-\(site.key)",
            script: registry.jsSpiderBridge,
            prelude: prelude,
            storage: SpiderStorage(siteKey: site.key, defaults: defaults),
            session: session)
        return SpiderSession(site: site, runtime: runtime, extend: resolvedExtend(for: site))
    }

    /// The module name reaches JavaScript as a literal, and these names are the configuration's own
    /// file names — `麻豆.min`, quotes and backslashes included in principle. Let the JSON encoder
    /// escape it rather than interpolating it raw.
    private func jsonString(_ value: String) -> String {
        (try? JSONSerialization.data(withJSONObject: [value]))
            .map { String(decoding: $0, as: UTF8.self).dropFirst().dropLast() }
            .map(String.init) ?? "\"\""
    }

    /// A Python site's script **is** the spider, so there is no engine to fetch first — one
    /// same-origin download and the interpreter has everything. `extend` travels exactly as it does
    /// for every other spider, so a script reading its host out of `ext` needs no special case.
    private func pythonSession(for site: Site) async throws -> SpiderSession {
        let script = try await PythonSpiderSource.script(for: site, source: source, session: session)
        let runtime = try PythonSpiderSupport.runtime(script: script, siteKey: site.key)
        return SpiderSession(site: site, runtime: runtime, extend: resolvedExtend(for: site))
    }

    /// A rule-engine site sets `ext` to a path like `./json/农民影视.json`. Resolve it against the
    /// configuration's own directory — the same resolver the `./jar/` and `./py/` references use —
    /// so the spider receives a URL it can fetch. Anything already absolute, or any inline JSON,
    /// passes through untouched.
    func resolvedExtend(for site: Site) -> String {
        let raw = site.rawExtJSON
        guard !raw.isEmpty else { return raw }
        // `csp_Bili` keeps the relative path one level in: `{"json": "./json/bili听书.json"}`.
        // Same rule, same resolver — a spider can only fetch what it receives as a URL.
        if raw.hasPrefix("{") { return resolvingNestedPaths(in: raw) }
        guard !raw.hasPrefix("["), !raw.lowercased().hasPrefix("http") else { return raw }
        return source.resourceURL(for: raw)?.absoluteString ?? raw
    }

    private func resolvingNestedPaths(in raw: String) -> String {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
        else { return raw }
        var changed = false
        for (name, value) in object {
            guard let text = value as? String, text.hasPrefix("./"),
                  let url = source.resourceURL(for: text) else { continue }
            object[name] = url.absoluteString
            changed = true
        }
        guard changed, let data = try? JSONSerialization.data(withJSONObject: object) else { return raw }
        return String(decoding: data, as: UTF8.self)
    }

    public func portability(of site: Site) -> SpiderPortability? {
        registry.entry(for: site.api)?.portability
    }
}
