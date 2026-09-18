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

        public init(script: String, portability: SpiderPortability, origin: String,
                    source: Source = .bundled) {
            self.script = script
            self.portability = portability
            self.origin = origin
            self.source = source
        }
    }

    /// Where a script came from. Resolution order is exactly this order:
    /// a verified remote pack first, the bundled copy second, and absent means "not ported".
    public enum Source: Sendable, Equatable {
        case bundled
        case pack(version: String)
    }

    let entries: [String: Entry]
    public let prelude: String
    /// The drpy adapter — the `SpiderRuntime` names mapped onto drpy2's export. Bundled like
    /// `host.js` and, like it, **not packable**: it is part of the SDK a drpy rule runs against,
    /// not a spider a compatibility pack may replace.
    public let drpyBridge: String

    public init(entries: [String: Entry], prelude: String, drpyBridge: String = "") {
        self.entries = entries
        self.prelude = prelude
        self.drpyBridge = drpyBridge
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

    /// The registry the app actually runs on: the bundled scripts, with a verified compatibility
    /// pack overlaid on top. `CSPSourceResolver` uses this, so every call site picks up a pack
    /// without knowing one exists.
    public static func active(bundle: Bundle? = nil) -> SpiderRegistry {
        bundled(bundle: bundle, overlaying: InstalledSpiderPack.shared.current)
    }

    public static func bundled(bundle: Bundle? = nil) -> SpiderRegistry {
        bundled(bundle: bundle, overlaying: nil)
    }

    /// A pack entry replaces the bundled script for the same class, and may add a class the bundle
    /// never carried. Nothing else about the app changes: the script still runs against the same
    /// `CatVodHost` and the same `Spider` ABI, which is the boundary a pack cannot cross.
    public static func bundled(bundle: Bundle? = nil, overlaying pack: SpiderPack?) -> SpiderRegistry {
        var registry = bundledOnly(bundle: bundle)
        guard let pack else { return registry }
        var entries = registry.entries
        for (name, script) in pack.scripts {
            let existing = entries[name]
            entries[name] = Entry(script: script,
                                  portability: existing?.portability ?? .httpJSON,
                                  origin: existing?.origin ?? "compatibility pack \(pack.version)",
                                  source: .pack(version: pack.version))
        }
        // A pack alias only resolves to a script the pack itself brought, so a stale alias cannot
        // silently repoint a bundled class.
        for (alias, target) in pack.aliases {
            guard let entry = entries[target], case .pack = entry.source else { continue }
            entries[alias] = entry
        }
        registry = SpiderRegistry(entries: entries, prelude: registry.prelude,
                                  drpyBridge: registry.drpyBridge)
        return registry
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
        return SpiderRegistry(entries: entries, prelude: load("host"), drpyBridge: load("drpy-bridge"))
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
        return try JavaScriptSpiderRuntime(
            name: Self.className(from: api), script: entry.script, prelude: prelude,
            storage: SpiderStorage(siteKey: siteKey, defaults: defaults), session: session
        )
    }
}
