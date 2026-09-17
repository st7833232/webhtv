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

        public init(script: String, portability: SpiderPortability, origin: String) {
            self.script = script
            self.portability = portability
            self.origin = origin
        }
    }

    private let entries: [String: Entry]
    public let prelude: String

    public init(entries: [String: Entry], prelude: String) {
        self.entries = entries
        self.prelude = prelude
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

    public static func bundled(bundle: Bundle? = nil) -> SpiderRegistry {
        let bundle = bundle ?? .module
        func load(_ name: String) -> String {
            guard let url = bundle.url(forResource: name, withExtension: "js", subdirectory: "Spiders"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
            return text
        }
        var entries = [String: Entry]()
        for (name, meta) in ported {
            let script = load(aliases[name] ?? name)
            if !script.isEmpty { entries[name] = Entry(script: script, portability: meta.0, origin: meta.1) }
        }
        return SpiderRegistry(entries: entries, prelude: load("host"))
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
