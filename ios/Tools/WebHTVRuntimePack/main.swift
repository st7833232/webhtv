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
    var keys = [(publicKey: Curve25519.Signing.PublicKey, role: RuntimeTrustRoot.Role)]()
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

let commands: [String: (Arguments) throws -> Void] = ["build": build, "verify": verify]
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
