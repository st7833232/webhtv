import Foundation

/// A verified generation loaded into memory: what `SpiderRegistry` lays over the bundled scripts.
public struct RuntimeSpiderPack: Sendable, Equatable {
    public let scope: RuntimeScope
    public let generation: RuntimeGeneration
    public let version: String
    public let notes: String?
    /// Class name → script.
    public let scripts: [String: String]
    /// Alias → class name, only ever to a script this same pack brought.
    public let aliases: [String: String]
}

/// The packs the registry reads, held outside the store because building a registry is
/// synchronous and happens on every content call. A lock, not an actor hop — the shape
/// `CookieJar` has.
public final class ActiveRuntimePacks: @unchecked Sendable {
    public static let shared = ActiveRuntimePacks()
    private var packs = [String: RuntimeSpiderPack]()
    private let lock = NSLock()

    public init() {}

    public func pack(for scope: RuntimeScope) -> RuntimeSpiderPack? {
        lock.withLock { packs[scope.key] }
    }

    public func set(_ pack: RuntimeSpiderPack?, for scope: RuntimeScope) {
        lock.withLock { packs[scope.key] = pack }
    }
}

/// IOS-POC-13. Every scope's generations on disk, and the choice that matters at launch: which of
/// them, if any, runs.
///
///     Application Support/RuntimePacks/<RuntimeScope.storageName>/
///       state.json                  RuntimeScopeState: the floor, active, last known good, bad list
///       generations/<generation>/   immutable: manifest.json, manifest.json.sig (global), files/…
///       staging-<uuid>/             a generation being written; anything left over is removed
///
/// **Nothing is modified in place.** A generation is written to staging, verified, renamed into
/// `generations/` on the same volume, and only then is `state.json` rewritten atomically — so a
/// crash leaves the old state or the new one, never a mixture, and at worst an orphan directory the
/// next prune removes. Choosing what runs never touches the network.
public actor RuntimePackStore {
    public static let shared = RuntimePackStore()

    private let root: URL
    private let files = FileManager.default

    public init(root: URL? = nil) {
        self.root = root ?? Self.defaultRoot()
    }

    private static func defaultRoot() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("RuntimePacks", isDirectory: true)
    }

    // MARK: Reading

    public func state(for scope: RuntimeScope) -> RuntimeScopeState? {
        guard let data = try? Data(contentsOf: stateURL(scope)), data.count <= Self.stateBytes,
              let state = try? JSONDecoder().decode(RuntimeScopeState.self, from: data),
              state.scopeKey == scope.key else { return nil }
        return state
    }

    /// The generation this scope runs, re-verified on the way in: the active one, else the last
    /// known good, else `nil` — the bundled scripts.
    ///
    /// A generation that fails for a deterministic reason (edited files, a bad or revoked signature,
    /// a manifest that no longer parses) is marked bad and never tried again. One this build cannot
    /// run — an older IPA reinstalled over the container, or one without the key it was signed
    /// with — is skipped but kept, so updating the App again brings it back.
    public func load(_ scope: RuntimeScope, host: RuntimeHost,
                     trust: RuntimeTrustRoot = .bundled) -> RuntimeSpiderPack? {
        guard var state = state(for: scope) else { return nil }
        var changed = false
        defer { if changed { try? write(state, for: scope) } }
        for generation in [state.active, state.lastKnownGood].compactMap({ $0 }) {
            do {
                return try read(generation, in: scope, host: host, trust: trust,
                                revoked: Set(state.revokedKeyIds))
            } catch let rejection where Self.keeps(rejection) {
                continue
            } catch {
                state = state.markingBad(generation, reason: String(describing: error))
                changed = true
            }
        }
        return nil
    }

    // MARK: Writing

    /// Writes a verified generation and makes it this scope's active one. Throws without touching the
    /// scope's state if anything is missing, mismatched or does not load; returns `nil` for a
    /// `rollbackToBundled` directive, which leaves the scope on the bundled scripts.
    @discardableResult
    public func install(_ candidate: RuntimePackCandidate, manifest: Data, signature: Data?,
                        files contents: [String: Data]) throws -> RuntimeSpiderPack? {
        let scope = candidate.scope
        let current = state(for: scope) ?? RuntimeScopeState(scope: scope, packId: candidate.manifest.packId)
        switch current.admission(of: candidate) {
        case .accept: break
        case .unchanged: throw RuntimePackRejection.sequenceReused(candidate.manifest.sequence)
        case .reject(let rejection): throw rejection
        }
        guard runtimeSHA256(manifest) == candidate.manifestSHA256 else {
            throw RuntimePackRejection.digestMismatch("manifest.json")
        }
        try RuntimePackValidator.verifyGeneration(of: candidate.manifest, files: contents)
        let pack = try Self.assemble(candidate, files: contents)
        if let pack { try Self.smokeTest(pack) }

        if pack != nil {
            let staging = scopeURL(scope).appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
            defer { try? files.removeItem(at: staging) }
            try files.createDirectory(at: staging, withIntermediateDirectories: true)
            try manifest.write(to: staging.appendingPathComponent("manifest.json"))
            if let signature { try signature.write(to: staging.appendingPathComponent("manifest.json.sig")) }
            for (path, data) in contents {
                let url = staging.appendingPathComponent("files", isDirectory: true).appendingPathComponent(path)
                try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
            var generations = scopeURL(scope).appendingPathComponent("generations", isDirectory: true)
            try files.createDirectory(at: generations, withIntermediateDirectories: true)
            // Downloadable again at any time, so it does not belong in a backup (R19).
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? generations.setResourceValues(values)
            let target = generationURL(candidate.generation, in: scope)
            // Same id is same content: an earlier copy is only ever a leftover of a crash.
            if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
            try files.moveItem(at: staging, to: target)
        }

        let next = current.activating(candidate)
        try write(next, for: scope)
        prune(scope, keeping: next)
        return pack
    }

    /// A generation that failed deterministically after it was activated — for example a script that
    /// would not load. The scope falls back one step and never retries it.
    public func markBad(_ generation: RuntimeGeneration, in scope: RuntimeScope, reason: String) throws {
        guard let current = state(for: scope) else { return }
        let next = current.markingBad(generation, reason: reason)
        try write(next, for: scope)
        prune(scope, keeping: next)
    }

    /// Forgetting a configuration forgets its runtime content too, floor included.
    public func forget(_ scope: RuntimeScope) {
        try? files.removeItem(at: scopeURL(scope))
    }

    /// Staging left by a download that never finished. Called once per launch, before anything else.
    public func removeStaging() {
        guard let scopes = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for scope in scopes {
            for entry in (try? files.contentsOfDirectory(at: scope, includingPropertiesForKeys: nil)) ?? []
            where entry.lastPathComponent.hasPrefix("staging-") {
                try? files.removeItem(at: entry)
            }
        }
    }

    // MARK: Internals

    static let stateBytes = 64 * 1024

    /// Rejections that mean "not with this build", not "broken".
    private static func keeps(_ error: Error) -> Bool {
        guard let rejection = error as? RuntimePackRejection else { return false }
        switch rejection {
        case .unknownKey, .appBuildTooNew, .abiMajorMismatch: return true
        default: return rejection.requiresNewerApp
        }
    }

    private func read(_ generation: RuntimeGeneration, in scope: RuntimeScope, host: RuntimeHost,
                      trust: RuntimeTrustRoot, revoked: Set<String>) throws -> RuntimeSpiderPack {
        let directory = generationURL(generation, in: scope)
        let manifest = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        guard runtimeSHA256(manifest) == generation.manifestSHA256 else {
            throw RuntimePackRejection.digestMismatch("manifest.json")
        }
        let signature = try? Data(contentsOf: directory.appendingPathComponent("manifest.json.sig"))
        let candidate = try RuntimePackValidator.revalidate(manifest: manifest, signature: signature, scope: scope,
                                                            host: host, trust: trust, revokedKeyIds: revoked)
        var contents = [String: Data]()
        for file in candidate.manifest.files {
            contents[file.path] = try? Data(contentsOf: directory.appendingPathComponent("files", isDirectory: true)
                .appendingPathComponent(file.path))
        }
        try RuntimePackValidator.verifyGeneration(of: candidate.manifest, files: contents)
        guard let pack = try Self.assemble(candidate, files: contents) else {
            throw RuntimePackRejection.emptyPack
        }
        return pack
    }

    /// The scripts a generation brings, keyed as the registry keys them.
    static func assemble(_ candidate: RuntimePackCandidate,
                         files contents: [String: Data]) throws -> RuntimeSpiderPack? {
        guard candidate.manifest.directive == nil else { return nil }
        var scripts = [String: String]()
        var aliases = [String: String]()
        for file in candidate.manifest.files where file.logicalType == RuntimeAssetType.spiderJS.rawValue {
            guard let name = file.className, let data = contents[file.path],
                  let text = String(data: data, encoding: .utf8) else {
                throw RuntimePackRejection.fileMissing(file.path)
            }
            scripts[name] = text
            for alias in file.aliases ?? [] { aliases[alias] = name }
        }
        return RuntimeSpiderPack(scope: candidate.scope, generation: candidate.generation,
                                 version: candidate.manifest.version, notes: candidate.manifest.notes,
                                 scripts: scripts, aliases: aliases)
    }

    /// Type validation for `spider.js`: each script must compile on the bundled host and assign
    /// `module.exports`, in a throwaway context, before anything is activated. Nothing runs beyond
    /// the script's own top level; no spider method is called and nothing is fetched.
    static func smokeTest(_ pack: RuntimeSpiderPack) throws {
        let prelude = SpiderRegistry.bundled().prelude
        for (name, script) in pack.scripts.sorted(by: { $0.key < $1.key }) {
            do {
                _ = try JavaScriptSpiderRuntime(name: name, script: script, prelude: prelude,
                                                storage: SpiderStorage(siteKey: "runtime-pack-smoke"),
                                                session: .webHTV)
            } catch {
                throw RuntimePackRejection.scriptDoesNotLoad(name)
            }
        }
    }

    private func write(_ state: RuntimeScopeState, for scope: RuntimeScope) throws {
        try files.createDirectory(at: scopeURL(scope), withIntermediateDirectories: true)
        // Readable after the first unlock, because PiP, background audio and auto-next can build a
        // spider while the phone is locked (R19). Kept in backups so the floor survives a restore.
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        try JSONEncoder().encode(state).write(to: stateURL(scope), options: options)
    }

    /// Only the active generation and one last known good are kept.
    private func prune(_ scope: RuntimeScope, keeping state: RuntimeScopeState) {
        let directory = scopeURL(scope).appendingPathComponent("generations", isDirectory: true)
        let keep = Set([state.active, state.lastKnownGood].compactMap { $0?.id })
        for entry in (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where !keep.contains(entry.lastPathComponent) {
            try? files.removeItem(at: entry)
        }
    }

    private func scopeURL(_ scope: RuntimeScope) -> URL {
        root.appendingPathComponent(scope.storageName, isDirectory: true)
    }

    private func stateURL(_ scope: RuntimeScope) -> URL {
        scopeURL(scope).appendingPathComponent("state.json")
    }

    private func generationURL(_ generation: RuntimeGeneration, in scope: RuntimeScope) -> URL {
        scopeURL(scope).appendingPathComponent("generations", isDirectory: true)
            .appendingPathComponent(generation.id, isDirectory: true)
    }
}
