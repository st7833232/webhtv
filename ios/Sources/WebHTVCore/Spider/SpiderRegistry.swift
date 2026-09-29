import Foundation

/// Maps a `csp_*` class name to the JavaScript that reimplements it, plus what the JAR audit found
/// about that class. Absence means "not ported"; `portability` says whether porting is even the
/// right question, and `SpiderPortability.resourceMissing` keeps a missing download from being
/// mistaken for a technical verdict.
public struct SpiderRegistry: Sendable {
    public struct Entry: Sendable {
        public let script: String
        public let portability: SpiderPortability
        /// The JAR the original shipped in, so the audit stays traceable from the code.
        public let origin: String
        /// Which copy of the script this is. The app shows it; the tests assert on it.
        public let source: Source
        /// The bundled script for the same class, when a runtime pack replaced it: what runs if the
        /// pack's copy does not load (IOS-POC-13, D9), so a bad pack never removes a working spider.
        public let fallback: String?

        public init(script: String, portability: SpiderPortability, origin: String,
                    source: Source = .bundled, fallback: String? = nil) {
            self.script = script
            self.portability = portability
            self.origin = origin
            self.source = source
            self.fallback = fallback
        }
    }

    /// Where a script came from. Resolution order is exactly this order: the configuration's runtime
    /// pack, then WebHTV's global one, then the bundled copy; absent means "not ported".
    public enum Source: Sendable, Equatable {
        case bundled
        case pack(RuntimeScope.Kind, version: String)
    }

    let entries: [String: Entry]
    public let prelude: String
    /// The drpy adapter — the `SpiderRuntime` names mapped onto drpy2's export. Bundled like
    /// `host.js` and, like it, **not packable**: it is part of the SDK a drpy rule runs against,
    /// not a spider a compatibility pack may replace.
    public let drpyBridge: String
    /// The **CatVod JS spider** adapter (IOS-POC-10T), the sibling of `drpyBridge` for TVBox's other
    /// JavaScript contract. Bundled and not packable for exactly the same reason.
    public let jsSpiderBridge: String

    public init(entries: [String: Entry], prelude: String, drpyBridge: String = "",
                jsSpiderBridge: String = "") {
        self.entries = entries
        self.prelude = prelude
        self.drpyBridge = drpyBridge
        self.jsSpiderBridge = jsSpiderBridge
    }

    /// Adding a port is a new `.js` resource plus one line here — never a Swift rewrite.
    static let ported: [String: (SpiderPortability, String)] = [
        "AppGet": (.httpCrypto, "river-fman.jar, xiaosa-0807.jar"),
        // The rest of the 苹果CMS App-API family, ported in IOS-POC-5L.
        "AppQi": (.httpCrypto, "river-fman.jar, xiaosa-0807.jar, 愛影.jar"),
        "App99": (.httpCrypto, "river-fman.jar, xiaosa-0807.jar"),
        "App3Q": (.httpCrypto, "river-fman.jar, xiaosa-0807.jar"),
        "Bili": (.httpJSON, "river-fman.jar"),
        "JianPian": (.httpJSON, "river-fman.jar"),
        // 薦片 is configured as `csp_JPianAmns`, which in `aowu.jar` is an empty shim over a
        // native-encrypted payload — nothing to port. `JianPian` drives the same API unprotected,
        // and the site's own `ext` proves they are the same one: its categories 1/2/3/4/67 and keys
        // type/area/year/sort are exactly what `JianPian` substitutes into its request template,
        // including 67 being the category that goes to `shortList`. See docs/IOS-POC-5M-jianpian.md.
        "JPianAmns": (.httpJSON, "river-fman.jar (as JianPian; aowu.jar's own class is a shim)"),
        // Rule engines: one port serves every site configured for them, now and later.
        "XBPQ": (.httpCrypto, "xyqxbpq.jar, xiaosa-0807.jar"),
        "XYQHiker": (.httpJSON, "xyqxbpq.jar, river-fman.jar"),
    ]

    /// A configured class name that a *different* script drives, because the named class carries no
    /// logic of its own. Only ever for a pair proven to be the same site.
    static let aliases = ["JPianAmns": "JianPian"]

    /// The registry the app actually runs on for one configuration: the bundled scripts, then
    /// WebHTV's global runtime pack, then that configuration's own pack, the last one winning.
    /// `CSPSourceResolver` builds this for the source it is given, so every call site picks up the
    /// right packs without knowing one exists — and configuration B never sees A's.
    public static func active(for source: ConfigSource = .importedFile, bundle: Bundle? = nil) -> SpiderRegistry {
        let packs = ActiveRuntimePacks.shared
        let layers = [packs.pack(for: .global), RuntimeScope(source).flatMap { packs.pack(for: $0) }]
        return bundled(bundle: bundle, overlaying: layers.compactMap { $0 })
    }

    public static func bundled(bundle: Bundle? = nil) -> SpiderRegistry {
        bundledOnly(bundle: bundle)
    }

    /// A pack entry replaces the bundled script for the same class, and may add a class the bundle
    /// never carried. Nothing else about the app changes: the script still runs against the same
    /// `CatVodHost` and the same `Spider` ABI, which is the boundary a pack cannot cross.
    public static func bundled(bundle: Bundle? = nil, overlaying packs: [RuntimeSpiderPack]) -> SpiderRegistry {
        let registry = bundledOnly(bundle: bundle)
        guard !packs.isEmpty else { return registry }
        var entries = registry.entries
        for pack in packs {
            var brought = [String: Entry]()
            for (name, script) in pack.scripts {
                let existing = entries[name]
                let entry = Entry(script: script,
                                  portability: existing?.portability ?? .httpJSON,
                                  origin: existing?.origin ?? "runtime pack \(pack.version)",
                                  source: .pack(pack.scope.kind, version: pack.version),
                                  fallback: registry.entries[name]?.script)
                entries[name] = entry
                brought[name] = entry
            }
            // A pack alias only resolves to a script the pack itself brought, so a stale alias cannot
            // silently repoint a bundled class or another pack's.
            for (alias, target) in pack.aliases {
                guard let entry = brought[target] else { continue }
                entries[alias] = entry
            }
        }
        return SpiderRegistry(entries: entries, prelude: registry.prelude,
                              drpyBridge: registry.drpyBridge,
                              jsSpiderBridge: registry.jsSpiderBridge)
    }

    private static func bundledOnly(bundle: Bundle? = nil) -> SpiderRegistry {
        let bundle = bundle ?? .module
        func load(_ name: String) -> String {
            guard let url = bundle.url(forResource: name, withExtension: "js", subdirectory: "Spiders"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
            return text
        }
        var entries = [String: Entry]()
        for (name, meta) in ported {
            let script = load(aliases[name] ?? name)
            if !script.isEmpty {
                entries[name] = Entry(script: script, portability: meta.0, origin: meta.1, source: .bundled)
            }
        }
        return SpiderRegistry(entries: entries, prelude: load("host"), drpyBridge: load("drpy-bridge"),
                              jsSpiderBridge: load("js-spider"))
    }

    public var portedClasses: [String] { entries.keys.sorted() }
    public func entry(for api: String) -> Entry? { entries[Self.className(from: api)] }
    public func canDrive(_ api: String) -> Bool { entry(for: api) != nil }

    /// `csp_AppGet` → `AppGet`; a bare class name passes through unchanged.
    public static func className(from api: String) -> String {
        api.hasPrefix("csp_") ? String(api.dropFirst(4)) : api
    }

    public func makeRuntime(for api: String, siteKey: String,
                            defaults: UserDefaults = .standard,
                            session: URLSession = .webHTV) throws -> SpiderRuntime {
        guard let entry = entry(for: api) else { throw SpiderError.notRegistered(api) }
        func runtime(_ script: String) throws -> SpiderRuntime {
            try JavaScriptSpiderRuntime(
                name: Self.className(from: api), script: script, prelude: prelude,
                storage: SpiderStorage(siteKey: siteKey, defaults: defaults), session: session
            )
        }
        do {
            return try runtime(entry.script)
        } catch {
            // A pack's copy that passed the install smoke test but still will not load here falls
            // back to the bundled one rather than taking the class away.
            guard let fallback = entry.fallback else { throw error }
            print("[runtime-pack] \(api) did not load from \(entry.source); using the bundled script: \(error)")
            return try runtime(fallback)
        }
    }
}
