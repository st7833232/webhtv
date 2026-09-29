import CryptoKit
import Foundation
import WebHTVCore

// webhtv-runtime-pack — builds and verifies runtime packs (IOS-POC-13) with the App's own
// validator, so a pack this tool accepts is exactly a pack the App accepts.
//
//   swift run --package-path ios webhtv-runtime-pack build --scope config --pack-id recha.spiders \
//       --sequence 1 --version 2026.09.29-1 --spiders ios/Sources/WebHTVCore/Resources/Spiders \
//       --alias JPianAmns=JianPian --out build/runtime
//   swift run --package-path ios webhtv-runtime-pack verify --dir build/runtime --scope config
//
// Global packs are signed (IOS-POC-13D). The maintainer runs `keygen` once, locally; the tool
// never uploads anything:
//
//   swift run --package-path ios webhtv-runtime-pack keygen --out ~/webhtv-runtime-keys
//   swift run --package-path ios webhtv-runtime-pack sign --dir build/runtime   # key from
//       --key FILE or the WEBHTV_RUNTIME_SIGNING_KEY environment variable
//
// If the active key leaks: build with `--revoke <its keyId>` (any sequence, even a lower one) and
// sign with `--key backup.key`; the App then refuses the leaked key and resets its floor once.
//
// The output directory is what gets published: `manifest.json` and `blobs/sha256/<hex>`, placed at
// `./runtime/` beside the configuration (config scope) or at `runtime/global/` (global scope).

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Arguments {
    private var values = [String: [String]]()
    private(set) var flags = Set<String>()

    init(_ arguments: ArraySlice<String>) throws {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            guard argument.hasPrefix("--") else { throw Failure("unexpected argument \(argument)") }
            let name = String(argument.dropFirst(2))
            if Self.switches.contains(name) { flags.insert(name); continue }
            guard let value = iterator.next() else { throw Failure("\(argument) needs a value") }
            values[name, default: []].append(value)
        }
    }

    static let switches: Set<String> = ["rollback"]

    func one(_ name: String) throws -> String {
        guard let value = values[name]?.last else { throw Failure("--\(name) is required") }
        return value
    }

    func optional(_ name: String) -> String? { values[name]?.last }
    func all(_ name: String) -> [String] { values[name] ?? [] }
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func scope(_ arguments: Arguments) throws -> (RuntimeScope, String) {
    switch try arguments.one("scope") {
    case "global": return (.global, "global")
    case "config":
        // A pack pinned to one configuration is only valid for that identity; an unpinned one is
        // bound to whichever configuration it is published beside.
        let identity = arguments.optional("config-identity") ?? "https://unpinned.invalid/"
        return (.configuration(identity: identity), "config")
    case let other: throw Failure("--scope must be global or config, not \(other)")
    }
}

func build(_ arguments: Arguments) throws {
    let out = URL(fileURLWithPath: try arguments.one("out"), isDirectory: true)
    let (_, kind) = try scope(arguments)
    let sequence: UInt64
    if let after = arguments.optional("after") {
        let previous = try RuntimePackManifest.decode(Data(contentsOf: URL(fileURLWithPath: after)))
        sequence = previous.sequence + 1
    } else {
        guard let value = UInt64(try arguments.one("sequence")) else { throw Failure("--sequence must be a number") }
        sequence = value
    }

    var aliases = [String: [String]]()
    for pair in arguments.all("alias") {
        let parts = pair.split(separator: "=").map(String.init)
        guard parts.count == 2 else { throw Failure("--alias is ALIAS=CLASS, not \(pair)") }
        aliases[parts[1], default: []].append(parts[0])
    }

    var files = [[String: Any]]()
    let blobs = out.appendingPathComponent("blobs/sha256", isDirectory: true)
    try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
    if !arguments.flags.contains("rollback") {
        let directory = URL(fileURLWithPath: try arguments.one("spiders"), isDirectory: true)
        let scripts = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".js") && !RuntimeABI.nativeScripts.contains($0) }.sorted()
        guard !scripts.isEmpty else { throw Failure("no spider scripts in \(directory.path)") }
        for name in scripts {
            let body = try Data(contentsOf: directory.appendingPathComponent(name))
            let digest = sha256(body)
            try body.write(to: blobs.appendingPathComponent(digest))
            let className = (name as NSString).deletingPathExtension
            var entry: [String: Any] = ["path": "spiders/\(name)", "logicalType": "spider.js",
                                        "class": className, "bytes": body.count, "sha256": digest]
            if let names = aliases[className] { entry["aliases"] = names.sorted() }
            files.append(entry)
        }
    }

    // A pack needs exactly the host it was built against, or newer.
    let jsHost = RuntimeABI.Surface.jsHost.version, catvod = RuntimeABI.Surface.catvodResult.version
    var requires: [String: Any] = ["abi": [
        "js.host": ["major": jsHost.major, "minMinor": jsHost.minor],
        "catvod.result": ["major": catvod.major, "minMinor": catvod.minor],
    ]]
    if let build = arguments.optional("min-app-build") { requires["minAppBuild"] = Int(build) }
    if let version = arguments.optional("min-app-version") { requires["minAppVersion"] = version }

    var scopeObject: [String: Any] = ["kind": kind]
    if let identity = arguments.optional("config-identity") { scopeObject["configIdentity"] = identity }
    var manifest: [String: Any] = [
        "format": RuntimePackManifest.format, "schema": RuntimePackManifest.schema,
        "packId": try arguments.one("pack-id"), "scope": scopeObject, "sequence": sequence,
        "version": try arguments.one("version"), "requires": requires, "files": files,
    ]
    if arguments.flags.contains("rollback") { manifest["directive"] = RuntimePackManifest.Directive.rollbackToBundled.rawValue }
    if let notes = arguments.optional("notes") { manifest["notes"] = notes }
    // Key compromise: a manifest signed with the offline backup key that revokes the active one.
    // The App accepts it only from the backup key, and it lowers the sequence floor once.
    if !arguments.all("revoke").isEmpty { manifest["revokeKeyIds"] = arguments.all("revoke").sorted() }
    if kind == "global" || arguments.optional("expires-days") != nil {
        let days = Double(arguments.optional("expires-days") ?? "30") ?? 30
        let formatter = ISO8601DateFormatter()
        manifest["expires"] = formatter.string(from: Date().addingTimeInterval(days * 86_400))
    }

    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    _ = try RuntimePackManifest.decode(data) // the App's own shape checks, before anything is published
    try data.write(to: out.appendingPathComponent("manifest.json"))
    print("manifest \(out.appendingPathComponent("manifest.json").path): sequence \(sequence), \(files.count) file(s)")
    for file in files { print("  \(file["class"] ?? "")  \(file["bytes"] ?? 0) bytes  \(file["sha256"] ?? "")") }
}

func verify(_ arguments: Arguments) throws {
    let directory = URL(fileURLWithPath: try arguments.one("dir"), isDirectory: true)
    let manifest = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
    let signature = try? Data(contentsOf: directory.appendingPathComponent("manifest.json.sig"))
    var (scope, _) = try scope(arguments)
    if case .configuration = scope, let pinned = try RuntimePackManifest.decode(manifest).scope.configIdentity {
        scope = .configuration(identity: arguments.optional("config-identity") ?? pinned)
    }
    // The App's own compiled-in keys, plus any given here for a key not yet in a build.
    var keys = RuntimeTrustRoot.bundled.keys.values.map { (publicKey: $0.publicKey, role: $0.role) }
    for key in arguments.all("public-key") {
        guard let raw = Data(base64Encoded: key) else { throw Failure("--public-key is base64") }
        keys.append((try Curve25519.Signing.PublicKey(rawRepresentation: raw), .active))
    }
    let host = RuntimeHost(appVersion: arguments.optional("app-version") ?? "999.0.0",
                           appBuild: Int(arguments.optional("app-build") ?? "") ?? Int.max)
    let candidate = try RuntimePackValidator.revalidate(manifest: manifest, signature: signature, scope: scope,
                                                        host: host, trust: RuntimeTrustRoot(keys))
    var files = [String: Data]()
    for file in candidate.manifest.files {
        files[file.path] = try? Data(contentsOf: directory.appendingPathComponent("blobs/sha256/\(file.sha256)"))
    }
    try RuntimePackValidator.verifyGeneration(of: candidate.manifest, files: files)
    let expiry = candidate.manifest.expires.map { ", expires \($0)" } ?? ""
    print("ok: \(candidate.manifest.packId) sequence \(candidate.manifest.sequence) (\(candidate.manifest.version)), "
          + "\(candidate.manifest.files.count) file(s), generation \(candidate.generation.id)\(expiry)")
}

/// Creates the active and backup key pairs. Private keys are written 0600 and never printed; the
/// public halves are printed for `RuntimeTrustRoot.bundledKeys`. Refuses to overwrite a key.
func keygen(_ arguments: Arguments) throws {
    let out = URL(fileURLWithPath: try arguments.one("out"), isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    for role in ["active", "backup"] {
        let file = out.appendingPathComponent("\(role).key")
        guard !FileManager.default.fileExists(atPath: file.path) else { throw Failure("\(file.path) already exists") }
        let key = Curve25519.Signing.PrivateKey()
        guard FileManager.default.createFile(atPath: file.path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw Failure("cannot write \(file.path)")
        }
        print("\(role)  keyId \(RuntimeTrustRoot.keyId(for: key.publicKey))  public \(key.publicKey.rawRepresentation.base64EncodedString())")
    }
    print("""

    Private keys: \(out.path)/active.key and backup.key (mode 600). Give the two public lines above to the
    App (RuntimeTrustRoot.bundledKeys). Put active.key in the Actions secret yourself:
      gh secret set WEBHTV_RUNTIME_ACTIVE_KEY < \(out.path)/active.key
    and keep backup.key offline — it is the only key that can revoke the active one.
    """)
}

/// Signs `manifest.json` in `--dir` as it is, byte for byte, into `manifest.json.sig`.
func sign(_ arguments: Arguments) throws {
    let directory = URL(fileURLWithPath: try arguments.one("dir"), isDirectory: true)
    let encoded: String
    if let file = arguments.optional("key") {
        encoded = try String(contentsOfFile: file, encoding: .utf8)
    } else if let value = ProcessInfo.processInfo.environment["WEBHTV_RUNTIME_SIGNING_KEY"], !value.isEmpty {
        encoded = value
    } else {
        throw Failure("give --key FILE or set WEBHTV_RUNTIME_SIGNING_KEY")
    }
    guard let raw = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw Failure("the signing key is not base64")
    }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    let manifest = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
    let signature = RuntimePackSignature(keyId: RuntimeTrustRoot.keyId(for: key.publicKey),
                                         sig: try key.signature(for: manifest).base64EncodedString())
    try JSONEncoder().encode(signature).write(to: directory.appendingPathComponent("manifest.json.sig"))
    print("signed with keyId \(signature.keyId)")
}

let commands: [String: (Arguments) throws -> Void] = ["build": build, "verify": verify, "keygen": keygen, "sign": sign]
let argv = CommandLine.arguments
guard argv.count >= 2, let command = commands[argv[1]] else {
    FileHandle.standardError.write(Data("usage: webhtv-runtime-pack \(commands.keys.sorted().joined(separator: "|")) --option value …\n".utf8))
    exit(2)
}
do {
    try command(Arguments(argv.dropFirst(2)))
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
