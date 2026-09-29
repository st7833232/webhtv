import CryptoKit
import Foundation

// IOS-POC-12. The runtime-pack contract IOS-POC-13 will build its updater on, as pure values and
// pure checks: nothing here downloads, stores, activates or schedules anything. Every function
// either returns a verdict or throws the one reason the candidate is refused — **fail closed**:
// a pack this build cannot fully understand is never partially used.
//
// Contract document: docs/IOS-POC-12-runtime-architecture-reconciliation.md.

// MARK: - Scope

/// Who a runtime pack belongs to. **Derived by the App from where it is looking, never taken from
/// the manifest**; a manifest may only confirm it.
///
/// The two scopes are two trust domains, not two folders: a global pack is maintained and signed
/// by WebHTV and is the same for everyone; a configuration pack belongs to one remote
/// configuration and is exactly as trusted as that configuration's own origin.
public enum RuntimeScope: Hashable, Sendable {
    case global
    /// Keyed by `ConfigSource.identity` byte for byte — the identity watch history already binds
    /// to — so A → B → A always comes back to A's own content.
    case configuration(identity: String)

    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case global
        case configuration = "config"
    }

    /// An imported file has no origin to fetch a pack beside, so it has no configuration scope.
    public init?(_ source: ConfigSource) {
        guard case .remote = source else { return nil }
        self = .configuration(identity: source.identity)
    }

    public var kind: Kind {
        switch self {
        case .global: .global
        case .configuration: .configuration
        }
    }

    public var key: String {
        switch self {
        case .global: "global"
        case .configuration(let identity): "config:" + identity
        }
    }

    /// The directory a scope's generations and state live under. A digest rather than the key, so
    /// no configuration URL is ever long enough to hit the file-name ceiling `SavedSource`'s
    /// base64url cache name can (G14).
    public var storageName: String { runtimeSHA256(Data(key.utf8)) }
}

// MARK: - Limits

/// Ceilings compiled into the App. A manifest may declare sizes under them, never raise them.
public enum RuntimePackLimits {
    public static let manifestBytes = 64 * 1024
    public static let signatureBytes = 1024
    /// Same as `DrpyEngine.maximumFileBytes`; the largest bundled spider is about 12 KiB.
    public static let fileBytes = 512 * 1024
    /// Same as `DrpyEngine.maximumBundleBytes`.
    public static let packBytes = 2 * 1024 * 1024
    public static let files = 64
    public static let pathBytes = 128
    public static let notesBytes = 4 * 1024
}

// MARK: - Logical types

/// Every kind of content the Dynamic Runtime is made of. Knowing a type is not the same as
/// accepting it: only a type with a native consumer can arrive through a runtime pack, and in v1
/// that is `spider.js` alone (the `SpiderRegistry` overlay). The others keep the path they already
/// have — inside the configuration, or fetched same-origin per session — and a manifest carrying
/// one is refused as needing a newer App.
public enum RuntimeAssetType: String, CaseIterable, Sendable {
    /// A `csp_*` class reimplemented in JavaScript.
    case spiderJS = "spider.js"
    case spiderPython = "spider.py"
    case drpyRule = "drpy.rule"
    /// XBPQ / XYQHiker rule files.
    case ruleData = "rule.json"
    case snifferRules = "sniffer.rules"
    case adHosts = "ads.hosts"
    case sourceMapping = "source.mapping"
    case data = "data.json"
    case text
    case image

    /// The scopes this build can activate the type in.
    public var activatableScopes: Set<RuntimeScope.Kind> {
        self == .spiderJS ? [.global, .configuration] : []
    }

    /// What a file of this type runs against; a manifest must declare each of them in
    /// `requires.abi`, so a pack can never leave the App guessing what it needs.
    public var surfaces: Set<RuntimeABI.Surface> {
        switch self {
        case .spiderJS, .drpyRule: [.jsHost, .catvodResult]
        case .spiderPython: [.pythonHost, .catvodResult]
        case .ruleData, .snifferRules, .adHosts, .sourceMapping, .data, .text, .image: []
        }
    }

    /// `native.*` is reserved for Native Core: a framework, library, executable, entitlement,
    /// `Info.plist` key or screen. Declaring one is a request for an IPA, never a runtime pack.
    static let nativeNamespace = "native."

    /// File types that are native code or native configuration whatever type a manifest claims.
    static let nativeExtensions: Set<String> = [
        "a", "app", "appex", "bundle", "dex", "dylib", "entitlements", "framework", "jar",
        "metallib", "mobileprovision", "o", "plist", "so", "swift", "swiftmodule", "xcframework",
    ]
}

// MARK: - Manifest

/// `manifest.json`, the one document a runtime pack is. Unknown optional fields are ignored so a
/// later schema-1 minor can add some; anything whose meaning a build must understand goes through
/// `requires` instead, which fails closed.
public struct RuntimePackManifest: Codable, Equatable, Sendable {
    public static let format = "webhtv.runtime-pack"
    public static let schema = 1

    public struct DeclaredScope: Codable, Equatable, Sendable {
        /// `global` or `config`.
        public let kind: String
        /// Optional pin to one configuration; when present it must equal the App's own identity.
        public let configIdentity: String?
    }

    public struct Requirement: Codable, Equatable, Sendable {
        public let major: Int
        public let minMinor: Int
    }

    public struct Requirements: Codable, Equatable, Sendable {
        /// Surface name → the version the pack was built against. Same major, minor at least this.
        public let abi: [String: Requirement]
        /// Names from `RuntimeABI.capabilities` the pack relies on.
        public fileprivate(set) var capabilities: [String]?
        public let minAppVersion: String?
        public let minAppBuild: Int?
        public let maxAppBuild: Int?
    }

    public struct File: Codable, Equatable, Sendable {
        /// Relative path inside the generation. The bytes are fetched from `blobs/sha256/<sha256>`
        /// beside the manifest, never from a URL the manifest names.
        public let path: String
        public let logicalType: String
        /// `spider.js`: the `csp_` class it implements, without the prefix.
        public let className: String?
        public fileprivate(set) var aliases: [String]?
        public let bytes: Int
        public let sha256: String

        enum CodingKeys: String, CodingKey {
            case path, logicalType, className = "class", aliases, bytes, sha256
        }
    }

    public enum Directive: String, Sendable {
        /// Withdraws a published pack without a new IPA: the scope goes back to the bundled scripts.
        case rollbackToBundled
    }

    public let format: String
    public let schema: Int
    /// `[a-z0-9.-]`, one pack per scope.
    public let packId: String
    public let scope: DeclaredScope
    /// The only thing ever compared. Strictly increasing per scope; a published sequence never
    /// changes content.
    public let sequence: UInt64
    /// For people. Shown, never compared.
    public let version: String
    public fileprivate(set) var requires: Requirements
    /// RFC 3339, required for global scope: a manifest past it is not adopted (freeze attacks),
    /// though an already active generation is never deactivated by it.
    public let expires: String?
    public let directive: String?
    /// Global scope, backup key only: keys this build must refuse from now on.
    public fileprivate(set) var revokeKeyIds: [String]?
    public fileprivate(set) var files: [File]
    /// Release notes. Untrusted plain text.
    public let notes: String?

    /// Parses and checks everything that can be decided from the manifest alone. Order and array
    /// order that carry no meaning are normalised, so equal content always encodes equally.
    public static func decode(_ data: Data) throws(RuntimePackRejection) -> RuntimePackManifest {
        guard data.count <= RuntimePackLimits.manifestBytes else { throw .manifestTooLarge(data.count) }
        let decoder = JSONDecoder()

        // Format and schema first: a future format must read as "newer", not as missing fields.
        struct Header: Decodable { let format: String?; let schema: Int? }
        guard let header = try? decoder.decode(Header.self, from: data) else { throw .malformed("manifest") }
        guard let format = header.format else { throw .missingField("format") }
        guard format == Self.format else { throw .unsupportedFormat(format) }
        guard let schema = header.schema else { throw .missingField("schema") }
        guard schema == Self.schema else { throw .unsupportedSchema(schema) }

        var manifest: RuntimePackManifest
        do {
            manifest = try decoder.decode(Self.self, from: data)
        } catch let DecodingError.keyNotFound(key, context) {
            throw .missingField(fieldPath(context.codingPath + [key]))
        } catch let DecodingError.valueNotFound(_, context) {
            throw .missingField(fieldPath(context.codingPath))
        } catch let DecodingError.typeMismatch(_, context) {
            throw .malformed(fieldPath(context.codingPath))
        } catch let DecodingError.dataCorrupted(context) {
            throw .malformed(fieldPath(context.codingPath))
        } catch {
            throw .malformed("manifest")
        }
        try manifest.checkFields()
        manifest.files.sort { $0.path < $1.path }
        for index in manifest.files.indices { manifest.files[index].aliases?.sort() }
        manifest.requires.capabilities?.sort()
        manifest.revokeKeyIds?.sort()
        return manifest
    }

    /// Same content → same identity, whatever the formatting, key order or file order; any change
    /// to what would be activated → a different one.
    public var contentIdentity: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding plain strings, numbers and arrays cannot fail.
        return runtimeSHA256((try? encoder.encode(self)) ?? Data())
    }

    /// `expires` as a date; `nil` when absent. `decode` has already refused one it cannot read.
    public var expiryDate: Date? { expires.flatMap { ISO8601DateFormatter().date(from: $0) } }

    private static func fieldPath(_ path: [CodingKey]) -> String {
        path.reduce(into: "") { text, key in
            if let index = key.intValue { text += "[\(index)]" } else { text += (text.isEmpty ? "" : ".") + key.stringValue }
        }
    }

    private func checkFields() throws(RuntimePackRejection) {
        guard packId.range(of: #"^[a-z0-9][a-z0-9.-]{0,63}$"#, options: .regularExpression) != nil else {
            throw .invalidPackId(packId)
        }
        guard RuntimeScope.Kind(rawValue: scope.kind) != nil else { throw .malformed("scope.kind") }
        guard sequence > 0 else { throw .malformed("sequence") }
        if expires != nil, expiryDate == nil { throw .malformed("expires") }
        guard !version.isEmpty, version.count <= 64, !version.contains(where: \.isNewline) else {
            throw .invalidVersion(version)
        }
        for (name, requirement) in requires.abi.sorted(by: { $0.key < $1.key })
        where requirement.major < 1 || requirement.minMinor < 0 {
            throw .invalidVersion(name)
        }
        if let minimum = requires.minAppVersion, RuntimeAppVersion(minimum) == nil {
            throw .invalidVersion(minimum)
        }
        if let build = requires.minAppBuild, build < 1 { throw .invalidVersion("minAppBuild") }
        if let build = requires.maxAppBuild, build < max(1, requires.minAppBuild ?? 1) {
            throw .invalidVersion("maxAppBuild")
        }
        for id in revokeKeyIds ?? [] where !isHex(id, count: 16) { throw .malformed("revokeKeyIds") }
        if let notes, notes.utf8.count > RuntimePackLimits.notesBytes { throw .notesTooLong(notes.utf8.count) }

        switch directive {
        case nil:
            guard !files.isEmpty else { throw .emptyPack }
        case Directive.rollbackToBundled.rawValue:
            guard files.isEmpty else { throw .malformed("files") }
        case let other?:
            throw .unsupportedDirective(other)
        }
        guard files.count <= RuntimePackLimits.files else { throw .tooManyFiles(files.count) }

        var seen = Set<String>()
        var total = 0
        for file in files {
            try Self.checkPath(file.path)
            // APFS on iOS is case-insensitive: two spellings of one path are one file.
            guard seen.insert(file.path.lowercased()).inserted else { throw .duplicatePath(file.path) }
            try Self.checkType(of: file)
            guard file.bytes > 0 else { throw .malformed("bytes") }
            guard file.bytes <= RuntimePackLimits.fileBytes else { throw .fileTooLarge(path: file.path, bytes: file.bytes) }
            guard isHex(file.sha256, count: 64) else { throw .invalidDigest(file.path) }
            total += file.bytes
        }
        guard total <= RuntimePackLimits.packBytes else { throw .packTooLarge(total) }
    }

    private static func checkPath(_ path: String) throws(RuntimePackRejection) {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.utf8.count <= RuntimePackLimits.pathBytes,
              path.range(of: #"^[A-Za-z0-9._/-]+$"#, options: .regularExpression) != nil,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw .invalidPath(path)
        }
        // Checked on every component, so `x.framework/Libmpv` is caught as well as `x.dylib`.
        for component in components {
            let suffix = component.split(separator: ".").dropFirst().last.map { $0.lowercased() }
            if let suffix, RuntimeAssetType.nativeExtensions.contains(suffix) {
                throw .nativeReleaseRequired(path)
            }
        }
    }

    private static func checkType(of file: File) throws(RuntimePackRejection) {
        if file.logicalType.hasPrefix(RuntimeAssetType.nativeNamespace) { throw .nativeReleaseRequired(file.path) }
        guard let type = RuntimeAssetType(rawValue: file.logicalType) else {
            throw .unknownAssetType(path: file.path, type: file.logicalType)
        }
        guard type == .spiderJS else { return }
        guard file.path.hasSuffix(".js") else { throw .invalidPath(file.path) }
        guard let className = file.className else { throw .missingField("files.class") }
        let reserved = Set(RuntimeABI.nativeScripts.map { ($0 as NSString).deletingPathExtension })
        for name in [className] + (file.aliases ?? []) {
            guard name.range(of: #"^[A-Za-z0-9_]{1,64}$"#, options: .regularExpression) != nil,
                  !reserved.contains(name) else {
                throw .invalidClass(path: file.path, name: name)
            }
        }
    }
}

// MARK: - Rejections

/// Why a candidate is not used. Each one leaves whatever is already active, the last known good
/// generation and the bundled scripts exactly as they were.
public enum RuntimePackRejection: Error, Equatable, Sendable {
    // The document
    case manifestTooLarge(Int)
    case malformed(String)
    /// A required field is absent: the manifest is incomplete.
    case missingField(String)
    case unsupportedFormat(String)
    case unsupportedSchema(Int)
    case unsupportedDirective(String)
    case invalidPackId(String)
    /// A display version, app version, build or ABI number that is not well formed.
    case invalidVersion(String)
    case notesTooLong(Int)
    // Origin and authenticity
    case insecureOrigin(String)
    case crossOrigin(String)
    case scopeMismatch(declared: String, expected: String)
    case signatureRequired
    case signatureMalformed
    case unknownKey(String)
    case revokedKey(String)
    case badSignature
    /// `revokeKeyIds` from anything but the backup key, or outside global scope.
    case revocationNotPermitted
    case expired
    // Compatibility with this build
    case unknownSurface(String)
    case surfaceNotRequirable(String)
    case abiMajorMismatch(surface: String, required: Int, installed: Int)
    case abiTooNew(surface: String, requiredMinor: Int, installed: Int)
    /// A file needs a surface the manifest did not declare.
    case undeclaredSurface(path: String, surface: String)
    case missingCapabilities([String])
    case appVersionTooOld(required: String, installed: String)
    case appBuildTooOld(required: Int, installed: Int)
    case appBuildTooNew(maximum: Int, installed: Int)
    // Files
    case emptyPack
    case tooManyFiles(Int)
    case invalidPath(String)
    case duplicatePath(String)
    case unknownAssetType(path: String, type: String)
    /// Native code or native configuration: only an IPA can deliver it.
    case nativeReleaseRequired(String)
    case assetTypeNotSupported(path: String, type: String)
    case invalidClass(path: String, name: String)
    case invalidDigest(String)
    case fileTooLarge(path: String, bytes: Int)
    case packTooLarge(Int)
    // The generation on disk
    case fileMissing(String)
    case sizeMismatch(path: String, expected: Int, actual: Int)
    case digestMismatch(String)
    case unexpectedFile(String)
    /// A `spider.js` that does not compile on the bundled host or assigns no `module.exports`.
    case scriptDoesNotLoad(String)
    // History of the scope
    case packIdMismatch(String)
    case rollback(sequence: UInt64, floor: UInt64)
    /// The same sequence with different content: a published sequence is immutable.
    case sequenceReused(UInt64)
    case knownBad(String)

    /// "This App is too old for the pack", which must read differently from "no update" (R24).
    public var requiresNewerApp: Bool {
        switch self {
        case .unsupportedFormat, .unsupportedSchema, .unsupportedDirective, .unknownSurface,
             .abiTooNew, .missingCapabilities, .appVersionTooOld, .appBuildTooOld,
             .unknownAssetType, .assetTypeNotSupported:
            true
        case .abiMajorMismatch(_, let required, let installed):
            required > installed
        default:
            false
        }
    }
}

// MARK: - What the installed App offers

/// The installed App as a pack sees it. `appVersion` and `appBuild` are `CFBundleShortVersionString`
/// and `CFBundleVersion` of the running bundle; the ABI and capabilities default to this build's.
public struct RuntimeHost: Equatable, Sendable {
    public let appVersion: String
    public let appBuild: Int
    public let abi: [RuntimeABI.Surface: RuntimeABI.Version]
    public let capabilities: Set<String>

    public init(appVersion: String, appBuild: Int,
                abi: [RuntimeABI.Surface: RuntimeABI.Version] = Dictionary(
                    uniqueKeysWithValues: RuntimeABI.Surface.allCases.map { ($0, $0.version) }),
                capabilities: Set<String> = RuntimeABI.capabilities) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.abi = abi
        self.capabilities = capabilities
    }
}

public extension RuntimeHost {
    /// The running App, read from its bundle; a build number that does not parse reads as 0, which
    /// satisfies no `minAppBuild`.
    static func installed(bundle: Bundle = .main) -> RuntimeHost {
        RuntimeHost(appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                    appBuild: Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0)
    }
}

/// `0.1.31`: up to three numeric components, compared numerically, missing ones read as 0.
struct RuntimeAppVersion: Comparable {
    let parts: [Int]

    init?(_ text: String) {
        guard text.range(of: #"^[0-9]{1,6}(\.[0-9]{1,6}){0,2}$"#, options: .regularExpression) != nil else { return nil }
        let numbers = text.split(separator: ".").compactMap { Int($0) }
        parts = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

// MARK: - Trust

/// The public keys a global pack must be signed with. Compiled into the App — the IPA is the trust
/// root, never the server, the bundle id or the SideStore signing identity.
public struct RuntimeTrustRoot: Sendable {
    public enum Role: String, Sendable {
        /// Signs releases.
        case active
        /// Kept offline; the only key that may revoke another and reset the sequence floor.
        case backup
    }

    public struct Key: Sendable {
        public let id: String
        public let role: Role
        let publicKey: Curve25519.Signing.PublicKey
    }

    public let keys: [String: Key]

    public init(_ keys: [(publicKey: Curve25519.Signing.PublicKey, role: Role)]) {
        self.keys = Dictionary(keys.map { key in
            let id = Self.keyId(for: key.publicKey)
            return (id, Key(id: id, role: key.role, publicKey: key.publicKey))
        }, uniquingKeysWith: { first, _ in first })
    }

    /// This build's keys. **Empty on purpose**: no WebHTV signing key has been created yet (where the
    /// private half lives is the maintainer's decision, D3), so every global pack is refused. Adding
    /// keys is an IPA change.
    public static let bundled = RuntimeTrustRoot([])

    /// The first 16 hex characters of SHA-256 over the raw 32-byte public key.
    public static func keyId(for key: Curve25519.Signing.PublicKey) -> String {
        String(runtimeSHA256(key.rawRepresentation).prefix(16))
    }
}

/// `manifest.json.sig`: a detached Ed25519 signature over the manifest's exact bytes.
public struct RuntimePackSignature: Codable, Equatable, Sendable {
    public static let algorithm = "ed25519"
    public let keyId: String
    public let alg: String
    /// Base64.
    public let sig: String

    public init(keyId: String, alg: String = Self.algorithm, sig: String) {
        self.keyId = keyId
        self.alg = alg
        self.sig = sig
    }
}

// MARK: - Validation

/// A manifest that passed every check that does not need its files.
public struct RuntimePackCandidate: Equatable, Sendable {
    public let manifest: RuntimePackManifest
    public let scope: RuntimeScope
    /// SHA-256 of the bytes fetched — what the signature covers and what a generation keeps.
    public let manifestSHA256: String
    public let contentIdentity: String
    /// Which key signed it; `nil` in configuration scope, where the origin is the only trust.
    public let signer: RuntimeTrustRoot.Role?

    public var generation: RuntimeGeneration {
        RuntimeGeneration(sequence: manifest.sequence, manifestSHA256: manifestSHA256,
                          contentIdentity: contentIdentity)
    }
}

public enum RuntimePackValidator {
    /// Everything that can be decided before one file is fetched, in the order IOS-POC-13 must run
    /// it: bounded size → origin → authenticity (before the bytes are interpreted) → shape → scope →
    /// revocation rules → freshness → compatibility with this build.
    ///
    /// - Parameters:
    ///   - url: where the manifest was fetched from. Global scope needs HTTPS; configuration scope
    ///     needs HTTPS on the configuration's own origin, the same rule drpy and Python scripts obey.
    ///   - configurationURL: the configuration the scope belongs to; ignored for global.
    ///   - revokedKeyIds: what this scope's state has revoked so far.
    public static func validate(manifest data: Data, signature: Data?, fetchedFrom url: URL,
                                scope: RuntimeScope, configurationURL: URL?, host: RuntimeHost,
                                trust: RuntimeTrustRoot = .bundled, revokedKeyIds: Set<String> = [],
                                now: Date = Date()) throws(RuntimePackRejection) -> RuntimePackCandidate {
        guard data.count <= RuntimePackLimits.manifestBytes else { throw .manifestTooLarge(data.count) }
        try checkOrigin(url, scope: scope, configurationURL: configurationURL)
        let candidate = try revalidate(manifest: data, signature: signature, scope: scope, host: host,
                                       trust: trust, revokedKeyIds: revokedKeyIds)
        if scope == .global, candidate.manifest.expires == nil { throw .missingField("expires") }
        if let expires = candidate.manifest.expiryDate, now >= expires { throw .expired }
        return candidate
    }

    /// The checks a **stored** generation must pass again at every launch: authenticity (a key may
    /// have been revoked since), shape, scope and compatibility with the build now installed. Not
    /// origin, which only means something while downloading, and not `expires`, which stops a
    /// manifest from being adopted but never deactivates one that already was (R3).
    public static func revalidate(manifest data: Data, signature: Data?, scope: RuntimeScope,
                                  host: RuntimeHost, trust: RuntimeTrustRoot = .bundled,
                                  revokedKeyIds: Set<String> = []) throws(RuntimePackRejection) -> RuntimePackCandidate {
        guard data.count <= RuntimePackLimits.manifestBytes else { throw .manifestTooLarge(data.count) }
        let signer = try authenticate(data, signature: signature, scope: scope, trust: trust,
                                      revokedKeyIds: revokedKeyIds)
        let manifest = try RuntimePackManifest.decode(data)

        guard manifest.scope.kind == scope.kind.rawValue else {
            throw .scopeMismatch(declared: manifest.scope.kind, expected: scope.kind.rawValue)
        }
        if case .configuration(let identity) = scope, let pinned = manifest.scope.configIdentity,
           pinned != identity {
            throw .scopeMismatch(declared: "config:" + pinned, expected: scope.key)
        }
        if !(manifest.revokeKeyIds ?? []).isEmpty, signer != .backup { throw .revocationNotPermitted }
        try checkCompatibility(of: manifest, in: scope.kind, host: host)

        return RuntimePackCandidate(manifest: manifest, scope: scope, manifestSHA256: runtimeSHA256(data),
                                    contentIdentity: manifest.contentIdentity, signer: signer)
    }

    /// Whether this build can run the pack. Separate from `validate` because it has to be re-run on
    /// a stored generation at every launch: SideStore can reinstall an older IPA over the container.
    public static func checkCompatibility(of manifest: RuntimePackManifest, in scope: RuntimeScope.Kind,
                                          host: RuntimeHost) throws(RuntimePackRejection) {
        var declared = Set<RuntimeABI.Surface>()
        for (name, requirement) in manifest.requires.abi.sorted(by: { $0.key < $1.key }) {
            guard let surface = RuntimeABI.Surface(rawValue: name) else { throw .unknownSurface(name) }
            guard surface.isRequirable else { throw .surfaceNotRequirable(name) }
            guard let installed = host.abi[surface] else { throw .unknownSurface(name) }
            guard requirement.major == installed.major else {
                throw .abiMajorMismatch(surface: name, required: requirement.major, installed: installed.major)
            }
            guard requirement.minMinor <= installed.minor else {
                throw .abiTooNew(surface: name, requiredMinor: requirement.minMinor, installed: installed.minor)
            }
            declared.insert(surface)
        }
        let missing = Set(manifest.requires.capabilities ?? []).subtracting(host.capabilities)
        guard missing.isEmpty else { throw .missingCapabilities(missing.sorted()) }

        if let minimum = manifest.requires.minAppVersion {
            // A version this App cannot parse is not "at least" anything.
            guard let required = RuntimeAppVersion(minimum), let installed = RuntimeAppVersion(host.appVersion),
                  required <= installed else {
                throw .appVersionTooOld(required: minimum, installed: host.appVersion)
            }
        }
        if let minimum = manifest.requires.minAppBuild, host.appBuild < minimum {
            throw .appBuildTooOld(required: minimum, installed: host.appBuild)
        }
        if let maximum = manifest.requires.maxAppBuild, host.appBuild > maximum {
            throw .appBuildTooNew(maximum: maximum, installed: host.appBuild)
        }

        for file in manifest.files {
            // `decode` already refused anything unknown or native.
            guard let type = RuntimeAssetType(rawValue: file.logicalType),
                  type.activatableScopes.contains(scope) else {
                throw .assetTypeNotSupported(path: file.path, type: file.logicalType)
            }
            for surface in type.surfaces.subtracting(declared).sorted(by: { $0.rawValue < $1.rawValue }) {
                throw .undeclaredSurface(path: file.path, surface: surface.rawValue)
            }
        }
    }

    /// A downloaded or stored generation is complete only when it holds exactly the manifest's
    /// files, each of the declared size and digest. Any gap, extra or mismatch refuses the whole
    /// generation — never "the files that happened to verify".
    public static func verifyGeneration(of manifest: RuntimePackManifest,
                                        files: [String: Data]) throws(RuntimePackRejection) {
        for file in manifest.files {
            guard let data = files[file.path] else { throw .fileMissing(file.path) }
            guard data.count == file.bytes else {
                throw .sizeMismatch(path: file.path, expected: file.bytes, actual: data.count)
            }
            guard runtimeSHA256(data) == file.sha256 else { throw .digestMismatch(file.path) }
        }
        let listed = Set(manifest.files.map(\.path))
        if let extra = files.keys.sorted().first(where: { !listed.contains($0) }) { throw .unexpectedFile(extra) }
    }

    private static func checkOrigin(_ url: URL, scope: RuntimeScope,
                                    configurationURL: URL?) throws(RuntimePackRejection) {
        guard url.scheme?.lowercased() == "https" else { throw .insecureOrigin(url.absoluteString) }
        guard case .configuration = scope else { return }
        // The same same-origin rule drpy rules and Python scripts already obey — not a third one.
        guard let configurationURL, (try? DrpyEngine.checked(url, origin: configurationURL)) != nil else {
            throw .crossOrigin(url.absoluteString)
        }
    }

    /// Global: a detached Ed25519 signature by a compiled-in key that is not revoked. Configuration:
    /// the origin is the trust, so any signature is ignored — WebHTV's keys never vouch for a
    /// user's configuration, and a user's key never becomes a WebHTV trust root.
    private static func authenticate(_ data: Data, signature: Data?, scope: RuntimeScope,
                                     trust: RuntimeTrustRoot,
                                     revokedKeyIds: Set<String>) throws(RuntimePackRejection) -> RuntimeTrustRoot.Role? {
        guard scope == .global else { return nil }
        guard let signature else { throw .signatureRequired }
        guard signature.count <= RuntimePackLimits.signatureBytes,
              let sidecar = try? JSONDecoder().decode(RuntimePackSignature.self, from: signature),
              sidecar.alg == RuntimePackSignature.algorithm,
              let bytes = Data(base64Encoded: sidecar.sig) else {
            throw .signatureMalformed
        }
        guard !revokedKeyIds.contains(sidecar.keyId) else { throw .revokedKey(sidecar.keyId) }
        guard let key = trust.keys[sidecar.keyId] else { throw .unknownKey(sidecar.keyId) }
        guard key.publicKey.isValidSignature(bytes, for: data) else { throw .badSignature }
        return key.role
    }
}

// MARK: - Per-scope state

/// One activated generation: an immutable directory of exactly the manifest's files.
public struct RuntimeGeneration: Codable, Hashable, Sendable {
    /// `gen-<sequence>-<first 16 of the content identity>`.
    public let id: String
    public let sequence: UInt64
    public let manifestSHA256: String
    public let contentIdentity: String

    public init(sequence: UInt64, manifestSHA256: String, contentIdentity: String) {
        id = "gen-\(sequence)-\(contentIdentity.prefix(16))"
        self.sequence = sequence
        self.manifestSHA256 = manifestSHA256
        self.contentIdentity = contentIdentity
    }
}

/// What a client keeps per scope (`state.json`): the anti-rollback floor, the active generation,
/// one last known good, and what failed. A pack never writes it. Every transition is a new value.
public struct RuntimeScopeState: Codable, Equatable, Sendable {
    public struct Bad: Codable, Hashable, Sendable {
        public let contentIdentity: String
        public let sequence: UInt64
        public let reason: String
    }

    public enum Admission: Equatable, Sendable {
        case accept
        /// Already what this scope accepted at this sequence: nothing to do.
        case unchanged
        case reject(RuntimePackRejection)
    }

    public let scopeKey: String
    public let packId: String
    /// The newest generation ever accepted; its sequence is the floor.
    public private(set) var latest: RuntimeGeneration?
    /// `nil` is the bundled scripts.
    public private(set) var active: RuntimeGeneration?
    public private(set) var lastKnownGood: RuntimeGeneration?
    /// Never retried automatically.
    public private(set) var bad: [Bad] = []
    public private(set) var revokedKeyIds: [String] = []

    public init(scope: RuntimeScope, packId: String) {
        scopeKey = scope.key
        self.packId = packId
    }

    public var floor: UInt64 { latest?.sequence ?? 0 }

    public func admission(of candidate: RuntimePackCandidate) -> Admission {
        guard candidate.scope.key == scopeKey else {
            return .reject(.scopeMismatch(declared: candidate.scope.key, expected: scopeKey))
        }
        guard candidate.manifest.packId == packId else { return .reject(.packIdMismatch(candidate.manifest.packId)) }
        guard !bad.contains(where: { $0.contentIdentity == candidate.contentIdentity }) else {
            return .reject(.knownBad(candidate.generation.id))
        }
        if resetsFloor(candidate) { return .accept }
        let sequence = candidate.manifest.sequence
        guard sequence >= floor else { return .reject(.rollback(sequence: sequence, floor: floor)) }
        if sequence == floor {
            return latest?.contentIdentity == candidate.contentIdentity ? .unchanged : .reject(.sequenceReused(sequence))
        }
        return .accept
    }

    /// The state after `candidate` is activated. Only call it for `.accept`.
    public func activating(_ candidate: RuntimePackCandidate) -> RuntimeScopeState {
        var next = self
        let generation = candidate.generation
        let reset = resetsFloor(candidate)
        next.latest = generation
        next.revokedKeyIds = Array(Set(revokedKeyIds).union(candidate.manifest.revokeKeyIds ?? [])).sorted()
        if candidate.manifest.directive == RuntimePackManifest.Directive.rollbackToBundled.rawValue {
            next.active = nil
            next.lastKnownGood = nil
        } else {
            // After a key compromise nothing accepted before the reset is kept as a fallback.
            next.lastKnownGood = reset ? nil : (active == generation ? lastKnownGood : active)
            next.active = generation
        }
        let keep = next.lastKnownGood?.sequence ?? next.active?.sequence ?? 0
        next.bad = bad.filter { $0.sequence >= keep }
        return next
    }

    /// A deterministic failure (hash, schema, ABI, compile or load smoke — never "the App was
    /// killed"): the generation is never started again, and the scope falls back one step.
    public func markingBad(_ generation: RuntimeGeneration, reason: String) -> RuntimeScopeState {
        var next = self
        let entry = Bad(contentIdentity: generation.contentIdentity, sequence: generation.sequence, reason: reason)
        if !bad.contains(entry) { next.bad.append(entry) }
        if active == generation {
            next.active = lastKnownGood
            next.lastKnownGood = nil
        } else if lastKnownGood == generation {
            next.lastKnownGood = nil
        }
        return next
    }

    /// TUF 5.3.11: a backup-signed manifest that revokes a key not yet revoked may lower the floor,
    /// once per revocation. Unconditional resets would let anyone replay an older backup-signed
    /// manifest to reopen rollback (D17).
    private func resetsFloor(_ candidate: RuntimePackCandidate) -> Bool {
        candidate.signer == .backup
            && !Set(candidate.manifest.revokeKeyIds ?? []).subtracting(revokedKeyIds).isEmpty
    }
}

// MARK: -

private func isHex(_ text: String, count: Int) -> Bool {
    text.utf8.count == count && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

func runtimeSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
