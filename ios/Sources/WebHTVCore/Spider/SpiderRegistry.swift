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
    ]

    public static func bundled(bundle: Bundle? = nil) -> SpiderRegistry {
        let bundle = bundle ?? .module
        func load(_ name: String) -> String {
            guard let url = bundle.url(forResource: name, withExtension: "js", subdirectory: "Spiders"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
            return text
        }
        var entries = [String: Entry]()
        for (name, meta) in ported {
            let script = load(name)
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
