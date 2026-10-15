import Foundation

/// IOS-POC-61 S1 (W-119). A verified generation of the official spider pack, loaded: what `SpiderRegistry`
/// lays between a configuration's compatibility pack and the bundled scripts.
public struct OfficialSpiderPack: Sendable, Equatable {
    public let generation: RuntimeGeneration
    public let version: String
    /// Class name → script.
    public let scripts: [String: String]
    /// Alias → class name, only ever to a script this same pack brought.
    public let aliases: [String: String]
}

/// IOS-POC-61 S4 (W-122): the bundled scripts as the official pack describes them — `Resources/SpiderBaseline/
/// manifest.json`, written by `scripts/runtime_pack.py build` from `Resources/Spiders` with the same `packId`
/// and sequence space as a published pack. A new baseline always needs a new, higher sequence
/// (`SpiderBaselineTests.shipped`).
public struct SpiderBaseline: Sendable {
    public let manifest: Data
    public let candidate: RuntimePackCandidate
    /// Path in the manifest → the bundled file's bytes; a missing one is left out and `install` refuses it.
    public let files: [String: Data]

    /// `nil` when this build carries no baseline. shortcut: S5 removes the bundled scripts and this file with them.
    public init?(bundle: Bundle? = nil, host: RuntimeHost = .installed()) throws {
        let bundle = bundle ?? .module
        guard let url = Self.manifestURL(in: bundle) else { return nil }
        manifest = try Data(contentsOf: url)
        // The bundle's own bytes; the compiled-in address only stands where the origin check expects one.
        candidate = try RuntimePackValidator.validateOfficial(manifest: manifest, fetchedFrom: RuntimePackUpdater.manifestURL,
                                                              host: host)
        var files = [String: Data]()
        for file in candidate.manifest.files {
            files[file.path] = bundle.url(forResource: (file.path as NSString).lastPathComponent, withExtension: nil,
                                          subdirectory: "Spiders").flatMap { try? Data(contentsOf: $0) }
        }
        self.files = files
    }

    /// What the settings page calls 內建基準: a generation with exactly this build's bundled content. The manifest
    /// alone says it, so drawing the page never reads the scripts.
    public static let identity: String? = manifestURL(in: .module).flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? RuntimePackManifest.decode($0).contentIdentity }

    private static func manifestURL(in bundle: Bundle) -> URL? {
        bundle.url(forResource: "manifest", withExtension: "json", subdirectory: "SpiderBaseline")
    }
}

/// The official pack the registry reads, held outside the store because building a registry is synchronous
/// and happens on every content call — the lock box `InstalledSpiderPack` is for the compatibility pack.
public final class ActiveOfficialPack: @unchecked Sendable {
    public static let shared = ActiveOfficialPack()
    private var pack: OfficialSpiderPack?
    private let lock = NSLock()

    public var current: OfficialSpiderPack? { lock.withLock { pack } }
    public func set(_ pack: OfficialSpiderPack?) { lock.withLock { self.pack = pack } }
}

/// The official pack's generations on disk, and the choice that matters at launch: which of them, if any, runs.
///
///     Application Support/RuntimePacks/<RuntimeScope.global.storageName>/
///       state.json                  RuntimeScopeState: the floor, active, last known good, bad list
///       generations/<generation>/   immutable: manifest.json, files/…
///       staging-<uuid>/             a generation being written; a leftover is removed at launch
///
/// **Nothing is modified in place.** A generation is written to staging, verified, renamed into
/// `generations/` on the same volume, and only then is `state.json` rewritten atomically — the one switch.
/// A crash leaves the old state or the new one, and at worst an orphan directory no state names.
/// Unsigned by the user's 2026-10-15 decision (fixed HTTPS address, SHA-256, sequence floor): nothing here
/// reads or asks for a signature. Choosing what runs never touches the network.
public actor RuntimePackStore {
    public static let shared = RuntimePackStore()

    private let root: URL
    private let files = FileManager.default
    private let scope = RuntimeScope.global

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

    public func state() -> RuntimeScopeState? {
        guard let data = try? Data(contentsOf: stateURL), data.count <= Self.stateBytes,
              let state = try? JSONDecoder().decode(RuntimeScopeState.self, from: data),
              state.scopeKey == scope.key else { return nil }
        return state
    }

    /// The generation that runs, re-verified on the way in: the active one, else the last known good, else
    /// `nil` — the bundled scripts. One that fails for a deterministic reason (edited files, a manifest that
    /// no longer parses) is marked bad and never tried again; one this build cannot run — an older IPA
    /// reinstalled over the container — is skipped but kept, so updating the App brings it back.
    ///
    /// A class the running generation has but this build is too old for (its own `minHostApi`) keeps the last
    /// known good's copy of it, when that one runs here; otherwise it stays bundled (plan §5.1, §5.3).
    public func load(host: RuntimeHost) -> OfficialSpiderPack? {
        guard var state = state() else { return nil }
        var changed = false
        defer { if changed { try? write(state) } }
        var running: (pack: OfficialSpiderPack, tooNew: Set<String>)?
        for generation in [state.active, state.lastKnownGood].compactMap({ $0 }) {
            // generations/ is excluded from backups but state.json is not: after a restore a generation is
            // simply absent, which says nothing about its content. Installing it again brings it back.
            guard files.fileExists(atPath: generationURL(generation).appendingPathComponent("manifest.json").path) else {
                continue
            }
            do {
                let loaded = try read(generation, host: host)
                guard let newer = running else {
                    if loaded.tooNew.isEmpty { return loaded.pack }
                    running = loaded
                    continue
                }
                return Self.keeping(newer.tooNew, from: loaded.pack, in: newer.pack)
            } catch let rejection as RuntimePackRejection where Self.keeps(rejection) {
                continue
            } catch {
                state = state.markingBad(generation, reason: String(describing: error))
                changed = true
            }
        }
        return running?.pack
    }

    /// `pack` with the classes in `names` (and the aliases to them) taken from `older`, where it has them.
    private static func keeping(_ names: Set<String>, from older: OfficialSpiderPack,
                                in pack: OfficialSpiderPack) -> OfficialSpiderPack {
        var scripts = pack.scripts
        var aliases = pack.aliases
        for name in names { scripts[name] = older.scripts[name] ?? scripts[name] }
        for (alias, target) in older.aliases where names.contains(target) && older.scripts[target] != nil {
            aliases[alias] = target
        }
        return OfficialSpiderPack(generation: pack.generation, version: pack.version, scripts: scripts, aliases: aliases)
    }

    /// Whether `generation`'s files are on disk (a restore leaves them out).
    public func has(_ generation: RuntimeGeneration) -> Bool {
        files.fileExists(atPath: generationURL(generation).appendingPathComponent("manifest.json").path)
    }

    // MARK: Writing

    /// Writes a verified generation and makes it the active one. Throws without touching `state.json` if
    /// anything is missing, mismatched or does not compile; returns `nil` when the pack is already the one
    /// accepted at its sequence (nothing to do) or for a `rollbackToBundled` directive.
    @discardableResult
    public func install(_ candidate: RuntimePackCandidate, manifest: Data, files contents: [String: Data],
                        host: RuntimeHost = .installed()) throws -> OfficialSpiderPack? {
        guard candidate.scope == scope else {
            throw RuntimePackRejection.scopeMismatch(declared: candidate.scope.key, expected: scope.key)
        }
        let current = state() ?? RuntimeScopeState(scope: scope, packId: candidate.manifest.packId)
        switch current.admission(of: candidate) {
        case .accept: break
        // The one already accepted at this sequence; written again only if a restore left its files out.
        case .unchanged where has(candidate.generation): return nil
        case .unchanged: break
        case .reject(let rejection): throw rejection
        }
        guard runtimeSHA256(manifest) == candidate.manifestSHA256 else {
            throw RuntimePackRejection.digestMismatch("manifest.json")
        }
        try RuntimePackValidator.verifyGeneration(of: candidate.manifest, files: contents)
        let pack = try Self.assemble(candidate.manifest, generation: candidate.generation, files: contents,
                                     hostApi: host.abi[.jsHost]?.minor ?? 0).pack
        do {
            if let pack { try Self.smokeTest(pack) }
        } catch {
            // Deterministic: the same bytes never compile, so the next check must not fetch them again.
            try write(current.markingBad(candidate.generation, reason: String(describing: error)))
            throw error
        }

        if pack != nil {
            let staging = scopeURL.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
            defer { try? files.removeItem(at: staging) }
            let stagedFiles = staging.appendingPathComponent("files", isDirectory: true)
            try files.createDirectory(at: stagedFiles, withIntermediateDirectories: true)
            try manifest.write(to: staging.appendingPathComponent("manifest.json"))
            for (path, data) in contents {
                // `decode` already refused `..`, `.`, empty segments and absolute paths; this keeps it that way.
                let url = stagedFiles.appendingPathComponent(path).standardizedFileURL
                guard url.path.hasPrefix(stagedFiles.standardizedFileURL.path + "/") else {
                    throw RuntimePackRejection.invalidPath(path)
                }
                try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
            var generations = scopeURL.appendingPathComponent("generations", isDirectory: true)
            try files.createDirectory(at: generations, withIntermediateDirectories: true)
            // Downloadable again at any time, so it does not belong in a backup (R19).
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? generations.setResourceValues(values)
            let target = generationURL(candidate.generation)
            // Same id is same content: one already there was renamed in whole from a verified staging. A directory
            // without its manifest (W-120 review N-3) is not one, and is replaced.
            if !has(candidate.generation) {
                try? files.removeItem(at: target)
                try files.moveItem(at: staging, to: target)
            }
        }

        let next = current.activating(candidate)
        try write(next)
        prune(keeping: next)
        return pack
    }

    /// A generation that failed deterministically after it was activated. The scope falls back one step and
    /// never retries it.
    public func markBad(_ generation: RuntimeGeneration, reason: String) throws {
        guard let current = state() else { return }
        let next = current.markingBad(generation, reason: reason)
        try write(next)
        prune(keeping: next)
    }

    /// IOS-POC-61 S4 (W-122): the bundled scripts become a generation of the official pack, at launch and without
    /// the network. Through `install`, so the sequence floor decides (Manager #2112 ①): it lands on a first launch
    /// and whenever a new IPA brings a baseline above what was downloaded — an IPA's spider fixes are never hidden
    /// under an older download. The same baseline again writes nothing; a lower one throws `.rollback` and leaves
    /// everything as it is. Any failure only means the bundled scripts keep running; nothing is marked bad.
    @discardableResult
    public func seedBaseline(bundle: Bundle? = nil, host: RuntimeHost = .installed()) throws -> OfficialSpiderPack? {
        guard let baseline = try SpiderBaseline(bundle: bundle, host: host) else { return nil }
        return try install(baseline.candidate, manifest: baseline.manifest, files: baseline.files, host: host)
    }

    /// 重設 (W-121): forgets the official pack entirely — generations, last known good, the bad list and the
    /// sequence floor — so the bundled scripts run and the next check installs whatever is published, even the
    /// same sequence. The floor going back is the user's own choice here. An actor method, so it never lands
    /// in the middle of an install.
    public func reset() throws {
        guard files.fileExists(atPath: scopeURL.path) else { return }
        try files.removeItem(at: scopeURL)
    }

    /// Staging left by an install that never finished. Called at launch, before any install.
    public func removeStaging() {
        for entry in (try? files.contentsOfDirectory(at: scopeURL, includingPropertiesForKeys: nil)) ?? []
        where entry.lastPathComponent.hasPrefix("staging-") {
            try? files.removeItem(at: entry)
        }
    }

    // MARK: Internals

    static let stateBytes = 64 * 1024

    /// Rejections that mean "not with this build", not "broken".
    private static func keeps(_ rejection: RuntimePackRejection) -> Bool {
        switch rejection {
        case .appBuildTooNew, .abiMajorMismatch: true
        default: rejection.requiresNewerApp
        }
    }

    private func read(_ generation: RuntimeGeneration,
                      host: RuntimeHost) throws -> (pack: OfficialSpiderPack, tooNew: Set<String>) {
        let directory = generationURL(generation)
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        guard runtimeSHA256(data) == generation.manifestSHA256 else {
            throw RuntimePackRejection.digestMismatch("manifest.json")
        }
        let manifest = try RuntimePackManifest.decode(data)
        guard manifest.scope.kind == scope.kind.rawValue else {
            throw RuntimePackRejection.scopeMismatch(declared: manifest.scope.kind, expected: scope.key)
        }
        try RuntimePackValidator.checkCompatibility(of: manifest, in: scope.kind, host: host)
        var contents = [String: Data]()
        for file in manifest.files {
            contents[file.path] = try? Data(contentsOf: directory.appendingPathComponent("files", isDirectory: true)
                .appendingPathComponent(file.path))
        }
        try RuntimePackValidator.verifyGeneration(of: manifest, files: contents)
        let assembled = try Self.assemble(manifest, generation: generation, files: contents,
                                          hostApi: host.abi[.jsHost]?.minor ?? 0)
        guard let pack = assembled.pack else { throw RuntimePackRejection.emptyPack }
        return (pack, assembled.tooNew)
    }

    /// The scripts a generation brings, keyed as the registry keys them. A script whose `minHostApi` is above
    /// `hostApi` is left out with its aliases and named in `tooNew`; `load` gives that class the last known
    /// good's copy, else it stays bundled.
    static func assemble(_ manifest: RuntimePackManifest, generation: RuntimeGeneration, files contents: [String: Data],
                         hostApi: Int) throws -> (pack: OfficialSpiderPack?, tooNew: Set<String>) {
        guard manifest.directive == nil else { return (nil, []) }
        var scripts = [String: String]()
        var aliases = [String: String]()
        var tooNew = Set<String>()
        for file in manifest.files where file.logicalType == RuntimeAssetType.spiderJS.rawValue {
            guard let name = file.className, let data = contents[file.path],
                  let text = String(data: data, encoding: .utf8) else {
                throw RuntimePackRejection.fileMissing(file.path)
            }
            guard (file.minHostApi ?? 0) <= hostApi else { tooNew.insert(name); continue }
            scripts[name] = text
            for alias in file.aliases ?? [] { aliases[alias] = name }
        }
        return (OfficialSpiderPack(generation: generation, version: manifest.version, scripts: scripts, aliases: aliases),
                tooNew)
    }

    /// Each script must compile on the bundled host and assign `module.exports`, in a throwaway context,
    /// before anything is activated. Nothing runs beyond the script's own top level and nothing is fetched.
    static func smokeTest(_ pack: OfficialSpiderPack) throws {
        let prelude = SpiderRegistry.bundled().prelude
        for (name, script) in pack.scripts.sorted(by: { $0.key < $1.key }) {
            do {
                _ = try JavaScriptSpiderRuntime(name: name, script: script, prelude: prelude,
                                                storage: SpiderStorage(siteKey: "runtime-pack-smoke"))
            } catch {
                throw RuntimePackRejection.scriptDoesNotLoad(name)
            }
        }
    }

    private func write(_ state: RuntimeScopeState) throws {
        try files.createDirectory(at: scopeURL, withIntermediateDirectories: true)
        // Readable after the first unlock: PiP, background audio and auto-next build a spider while the phone
        // is locked (R19). Kept in backups so the floor survives a restore.
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        try JSONEncoder().encode(state).write(to: stateURL, options: options)
    }

    /// Only the active generation and one last known good are kept.
    private func prune(keeping state: RuntimeScopeState) {
        let directory = scopeURL.appendingPathComponent("generations", isDirectory: true)
        let keep = Set([state.active, state.lastKnownGood].compactMap { $0?.id })
        for entry in (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where !keep.contains(entry.lastPathComponent) {
            try? files.removeItem(at: entry)
        }
    }

    private var scopeURL: URL { root.appendingPathComponent(scope.storageName, isDirectory: true) }
    private var stateURL: URL { scopeURL.appendingPathComponent("state.json") }

    private func generationURL(_ generation: RuntimeGeneration) -> URL {
        scopeURL.appendingPathComponent("generations", isDirectory: true)
            .appendingPathComponent(generation.id, isDirectory: true)
    }
}
