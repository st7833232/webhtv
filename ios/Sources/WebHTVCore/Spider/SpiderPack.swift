import Foundation

/// A remotely published set of spider scripts the app can adopt without being rebuilt.
///
/// **Why this exists.** A ported spider is a JavaScript reimplementation of a site's protocol. Hosts,
/// categories, filters and rule files already reach the app as data at runtime, so those change
/// without anyone touching the app. What did *not* was the protocol itself: when a site changed its
/// endpoints, signing or response shape, the fix was an edit to a script compiled into the bundle,
/// and that meant rebuilding and reinstalling. A compatibility pack moves exactly that class of fix
/// onto the same footing as the configuration.
///
/// **What it deliberately cannot do.** A pack carries JavaScript that runs against the *existing*
/// `CatVodHost` and the *existing* `Spider` ABI, and nothing else. It cannot add a native primitive,
/// change an entitlement, relax ATS, alter signing or reach any Swift behaviour — a script that
/// needs a primitive this build lacks is refused by the host-API gate below rather than failing
/// halfway through a call. iOS still never executes Android DEX or JAR bytecode; a JAR remains a
/// specification to read and a fingerprint to record.
///
/// **What it is trusted with.** A pack is executable code fetched over the network, so it is exactly
/// as trusted as the URL it comes from. The per-script SHA-256 in the manifest proves the bytes are
/// the bytes that manifest described — it does **not** prove who wrote the manifest, because both
/// come from the same origin. The pack URL is therefore required to be HTTPS even though this app
/// ships `NSAllowsArbitraryLoads` for playback hosts, and it is expected to be the same source the
/// user already trusts with `wang-movie.json`. Authenticity beyond that would need a signature
/// against a key pinned in the app, which is recorded as the upgrade path rather than built.
public struct SpiderPack: Sendable, Equatable {
    /// Bumped when the pack format itself changes shape. A manifest declaring anything else is
    /// refused outright rather than interpreted optimistically.
    public static let schema = 1

    public let version: String
    /// Class name → script source, already hash-verified.
    public let scripts: [String: String]
    /// Alias → class name, for a configured `api` whose own class carries no logic.
    public let aliases: [String: String]
    /// What the pack offered and this build declined, with a reason a human can act on.
    public let rejected: [Rejection]
    /// IOS-POC-55: configured classes that `scripts/audit_spider_jars.py compat` proved to be one of
    /// this pack's adapters under another name. Unlike `aliases` each one is scoped — one
    /// configuration, one site key, one JAR at one SHA-256, and the exact adapter bytes it was proven
    /// with — because the same class name in another JAR, or the same JAR after an update, is a
    /// different class.
    public let mappings: [ClassMapping]

    public struct Rejection: Sendable, Equatable {
        public let className: String
        public let reason: String
    }

    public struct ClassMapping: Decodable, Sendable, Equatable {
        /// The configuration's URL; its query and fragment do not take part in the match.
        public let config: String
        public let site: String
        /// The configured class, without `csp_`.
        public let className: String
        /// The JAR as the configuration resolves it, absolute and without `;md5;`.
        public let jar: String
        /// The JAR's actual bytes when it was analysed, not the configuration's declared md5.
        public let jarSha256: String
        public let adapter: String
        public let adapterSha256: String

        enum CodingKeys: String, CodingKey {
            case config, site, className = "class", jar, jarSha256, adapter, adapterSha256
        }
    }

    public init(version: String, scripts: [String: String],
                aliases: [String: String] = [:], rejected: [Rejection] = [],
                mappings: [ClassMapping] = []) {
        self.version = version
        self.scripts = scripts
        self.aliases = aliases
        self.rejected = rejected
        self.mappings = mappings
    }
}

/// The published document. Every field a pack needs to be adopted safely, and nothing that could
/// widen what a pack is allowed to do.
public struct SpiderPackManifest: Decodable, Sendable {
    public let schema: Int
    public let version: String
    /// Gate for the pack as a whole. A pack that needs a newer host than this build is not adopted.
    public let minHostApi: Int?
    public let scripts: [Script]
    /// Optional, so a schema-1 pack without it — and an older app reading one with it — is unchanged.
    public let mappings: [SpiderPack.ClassMapping]?

    public struct Script: Decodable, Sendable {
        /// The `csp_*` class this script implements, without the prefix.
        public let className: String
        /// Relative to the manifest's own URL, or absolute HTTPS.
        public let path: String
        public let sha256: String
        /// Per-script gate, for a script that needs a primitive the rest of the pack does not.
        public let minHostApi: Int?
        /// Other configured class names this script serves — `JPianAmns` → `JianPian`. A manifest's
        /// audit provenance (`originJar`, `jarSha256`, `notes`) is recorded there and never read.
        public let aliases: [String]?

        enum CodingKeys: String, CodingKey {
            case className = "class"
            case path, sha256, minHostApi, aliases
        }
    }
}

public enum SpiderPackError: Error, Equatable, LocalizedError {
    case insecureURL
    case invalidHTTPStatus(Int)
    case malformedManifest
    case unsupportedSchema(Int)
    case hostTooOld(required: Int, current: Int)
    case hashMismatch(className: String)
    case emptyPack

    public var errorDescription: String? {
        switch self {
        case .insecureURL: "相容性套件必須使用 HTTPS 網址。"
        case .invalidHTTPStatus(let code): "相容性套件回應 HTTP \(code)。"
        case .malformedManifest: "相容性套件的 manifest 無法解析。"
        case .unsupportedSchema(let value): "相容性套件的格式版本 \(value) 這個 App 不認得。"
        case .hostTooOld(let required, let current):
            "相容性套件需要 host API \(required)，這個 App 只有 \(current)；請更新 App。"
        case .hashMismatch(let name): "\(name) 的內容與 manifest 宣告的 SHA-256 不符。"
        case .emptyPack: "相容性套件沒有任何這個 App 能用的腳本。"
        }
    }
}

/// Downloads, verifies and stores compatibility packs, and keeps the last known good one.
///
/// The failure rule is the one the configuration loader already follows: **nothing is replaced until
/// everything has been verified.** A refresh writes into a scratch directory, and only a pack whose
/// manifest parsed, whose schema and host requirements this build satisfies, and every one of whose
/// scripts downloaded and hashed correctly, is swapped in — with `FileManager.replaceItemAt`, so a
/// crash mid-swap leaves either the old pack or the new one, never a mixture.
public actor SpiderPackStore {
    public static let shared = SpiderPackStore()

    /// Bumped whenever `CatVodHost` gains a primitive a script could depend on. A script declaring a
    /// higher `minHostApi` is refused by *this* build and will work once the app is updated — which
    /// is the whole point of the gate: the failure is a readable message at load time, not a
    /// spider that runs until it reaches the missing call.
    /// Since IOS-POC-12 this is `js.host`'s minor, not a second number kept by hand.
    public static let hostApiVersion = RuntimeABI.Surface.jsHost.version.minor

    /// Where a pack lives when the caller does not name one: beside the configuration, resolved by
    /// the same rule `./json/` rule files already use. Provider-agnostic — it is whatever host the
    /// user's own configuration URL is on.
    public static let defaultReference = "./spiders/manifest.json"

    private let directory: URL
    private let fetch: @Sendable (URL) async throws -> (Data, HTTPURLResponse?)

    private var installed: SpiderPack?

    public init(directory: URL? = nil,
                fetch: (@Sendable (URL) async throws -> (Data, HTTPURLResponse?))? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        self.fetch = fetch ?? { url in
            let (data, response) = try await URLSession.webHTV.data(from: url)
            return (data, response as? HTTPURLResponse)
        }
    }

    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        // Deliberately not the configuration's own file or directory: a pack and a configuration
        // fail independently and must never be able to invalidate each other's cache.
        return base.appendingPathComponent("SpiderPack", isDirectory: true)
    }

    public static func url(for source: ConfigSource, defaults: UserDefaults = .standard) -> URL? {
        if let override = defaults.string(forKey: "spiderPackURL"), let url = URL(string: override) {
            return url
        }
        return source.resourceURL(for: defaultReference)
    }

    /// The pack in force, read from disk and **re-verified** on the way in: a cache file edited on
    /// device is not a pack, and gets the same refusal a bad download would.
    @discardableResult
    public func installedPack() -> SpiderPack? {
        if let installed { return installed }
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(SpiderPackManifest.self, from: data) else { return nil }
        var sources = [String: Data]()
        for script in manifest.scripts {
            guard let body = try? Data(contentsOf: scriptURL(for: script.className)) else { continue }
            sources[script.className] = body
        }
        guard let pack = try? assemble(manifest: manifest, sources: sources) else { return nil }
        installed = pack
        InstalledSpiderPack.shared.current = pack
        return pack
    }

    /// Fetches and adopts a pack. Throws without touching the installed one if anything fails.
    @discardableResult
    public func refresh(from url: URL) async throws -> SpiderPack {
        guard url.scheme?.lowercased() == "https" else { throw SpiderPackError.insecureURL }
        let (manifestData, response) = try await fetch(url)
        if let response, !(200...299).contains(response.statusCode) {
            throw SpiderPackError.invalidHTTPStatus(response.statusCode)
        }
        guard let manifest = try? JSONDecoder().decode(SpiderPackManifest.self, from: manifestData) else {
            throw SpiderPackError.malformedManifest
        }
        guard manifest.schema == SpiderPack.schema else {
            throw SpiderPackError.unsupportedSchema(manifest.schema)
        }
        if let required = manifest.minHostApi, required > Self.hostApiVersion {
            throw SpiderPackError.hostTooOld(required: required, current: Self.hostApiVersion)
        }

        var sources = [String: Data]()
        for script in manifest.scripts {
            // A script this build cannot host is skipped here, so its bytes are never fetched and
            // never stored; `assemble` records why.
            if let required = script.minHostApi, required > Self.hostApiVersion { continue }
            guard let scriptURL = URL(string: script.path, relativeTo: url)?.absoluteURL,
                  scriptURL.scheme?.lowercased() == "https" else {
                throw SpiderPackError.insecureURL
            }
            let (body, scriptResponse) = try await fetch(scriptURL)
            if let scriptResponse, !(200...299).contains(scriptResponse.statusCode) {
                throw SpiderPackError.invalidHTTPStatus(scriptResponse.statusCode)
            }
            sources[script.className] = body
        }

        let pack = try assemble(manifest: manifest, sources: sources)
        try write(manifest: manifestData, sources: sources)
        installed = pack
        InstalledSpiderPack.shared.current = pack
        return pack
    }

    /// Verifies a manifest against the bytes that came with it. **A hash mismatch refuses the whole
    /// pack**, not just that script: a manifest that describes something other than what it served
    /// is not partially trustworthy. A host-API refusal is different in kind — the pack is honest,
    /// this build is simply older — so it only drops that script and is reported.
    func assemble(manifest: SpiderPackManifest, sources: [String: Data]) throws -> SpiderPack {
        var scripts = [String: String]()
        var aliases = [String: String]()
        var rejected = [SpiderPack.Rejection]()

        for script in manifest.scripts {
            if let required = script.minHostApi, required > Self.hostApiVersion {
                rejected.append(.init(className: script.className,
                                      reason: "需要 host API \(required)，這個 App 是 \(Self.hostApiVersion)"))
                continue
            }
            guard let body = sources[script.className] else {
                rejected.append(.init(className: script.className, reason: "manifest 列出但沒有內容"))
                continue
            }
            guard DrpyEngine.digest(body).caseInsensitiveCompare(script.sha256) == .orderedSame else {
                throw SpiderPackError.hashMismatch(className: script.className)
            }
            scripts[script.className] = String(decoding: body, as: UTF8.self)
            for alias in script.aliases ?? [] { aliases[alias] = script.className }
        }

        guard !scripts.isEmpty else { throw SpiderPackError.emptyPack }

        // A mapping was proven against one adapter's exact bytes. It stands only when this pack
        // delivers that adapter at that digest — so it can never repoint a bundled script, and an
        // adapter republished without re-running the analysis drops the mapping instead of guessing.
        var mappings = [SpiderPack.ClassMapping]()
        for mapping in manifest.mappings ?? [] {
            let declared = manifest.scripts.first { $0.className == mapping.adapter }?.sha256
            guard scripts[mapping.adapter] != nil,
                  declared?.caseInsensitiveCompare(mapping.adapterSha256) == .orderedSame else {
                rejected.append(.init(className: mapping.className,
                                      reason: "對應的 \(mapping.adapter) 不是分析時的版本，需要重新分析"))
                continue
            }
            mappings.append(mapping)
        }
        return SpiderPack(version: manifest.version, scripts: scripts, aliases: aliases, rejected: rejected,
                          mappings: mappings)
    }

    private func write(manifest: Data, sources: [String: Data]) throws {
        let staging = directory.deletingLastPathComponent()
            .appendingPathComponent("SpiderPack-staging-\(UUID().uuidString)", isDirectory: true)
        let scripts = staging.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try manifest.write(to: staging.appendingPathComponent("manifest.json"))
        for (name, body) in sources {
            try body.write(to: scripts.appendingPathComponent("\(name).js"))
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        if FileManager.default.fileExists(atPath: directory.path) {
            _ = try FileManager.default.replaceItemAt(directory, withItemAt: staging)
        } else {
            try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: staging, to: directory)
        }
    }

    /// Drops the installed pack and its cache, so the app falls back to the bundled scripts.
    public func reset() {
        installed = nil
        InstalledSpiderPack.shared.current = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
    private func scriptURL(for className: String) -> URL {
        directory.appendingPathComponent("scripts", isDirectory: true).appendingPathComponent("\(className).js")
    }
}

/// IOS-POC-55: a mapped class whose JAR could not be confirmed to be the one analysed. A statement
/// about the mapping, never about the site: it is not a `URLError`, so nothing reads it as one.
public struct ClassMappingUnverified: Error, Equatable, LocalizedError {
    public let className: String
    public let reason: String

    public var errorDescription: String? {
        "csp_\(className) 自動對應的內建爬蟲暫停使用：\(reason)。需要在電腦上重新分析 JAR。"
    }
}

/// IOS-POC-55: the SHA-256 of a JAR's actual bytes, which is what a class mapping is valid for. The
/// configuration's `;md5;` is not used: it is a cache hint, and this configuration already carries
/// one that no longer matches its JAR. The bytes are hashed and dropped — never unpacked, never
/// executed, never kept.
public actor JarFingerprints {
    public static let shared = JarFingerprints()
    static let key = "webhtv.jarFingerprints"

    private nonisolated(unsafe) let defaults: UserDefaults
    private let fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse?)

    public init(defaults: UserDefaults = .standard,
                fetch: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse?))? = nil) {
        self.defaults = defaults
        self.fetch = fetch ?? { request in
            let (data, response) = try await URLSession.webHTV.data(for: request)
            return (data, response as? HTTPURLResponse)
        }
    }

    /// What the last check saw, readable without a hop so listing can leave out a mapping already
    /// known to be stale.
    public nonisolated func known(_ url: URL) -> String? {
        (defaults.dictionary(forKey: Self.key)?[url.absoluteString] as? [String: String])?["sha256"]
    }

    /// The JAR's digest now. A conditional request keeps an unchanged JAR to a 304.
    public func sha256(of url: URL) async throws -> String {
        let stored = defaults.dictionary(forKey: Self.key)?[url.absoluteString] as? [String: String]
        var request = URLRequest(url: url)
        if let etag = stored?["etag"], !etag.isEmpty { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await fetch(request)
            if response?.statusCode == 304, let sha = stored?["sha256"] { return sha }
            if let status = response?.statusCode, !(200...299).contains(status) {
                throw URLError(.badServerResponse)
            }
            let sha = DrpyEngine.digest(data)
            var table = defaults.dictionary(forKey: Self.key) ?? [:]
            table[url.absoluteString] = ["sha256": sha, "etag": response?.value(forHTTPHeaderField: "ETag") ?? ""]
            defaults.set(table, forKey: Self.key)
            return sha
        } catch {
            // ponytail: last known good when the JAR's host cannot be reached, as the configuration
            // itself is; a JAR changed while unreachable is caught on the next successful check.
            if let sha = stored?["sha256"] { return sha }
            throw error
        }
    }
}

/// The pack the registry reads, held outside the actor because building a registry is synchronous
/// and happens on every content call. Same shape as `CookieJar`: a lock, not a queue hop.
public final class InstalledSpiderPack: @unchecked Sendable {
    public static let shared = InstalledSpiderPack()
    private var value: SpiderPack?
    private let lock = NSLock()

    public var current: SpiderPack? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
