import Foundation

/// Where the active configuration came from.
///
/// A remote source doubles as the anchor for config-relative resource references: the archive keeps
/// `jar/`, `py/`, `json/`, `drpy_libs/` and `drpy_js/` beside the configuration file, so the
/// configuration's own directory is the base URL. An imported file has no such anchor.
///
/// Deliberately provider-agnostic: a remote source is an HTTP(S) URL and nothing more. No hosting
/// service is recognised, special-cased or named here.
public enum ConfigSource: Equatable, Sendable {
    /// A file picked out of Files. `id` is its configuration identity (IOS-POC-48): an imported file
    /// has no address, so the identity is given to its content when it is imported
    /// (`ImportedConfigIdentities`) and never derived from where the file happened to be.
    case imported(id: String)
    case remote(URL)

    /// The one identity every imported file shared before IOS-POC-48. The file imported then keeps
    /// it, so its watch history, site memory and health records stay attached.
    public static let legacyImportedIdentity = "imported"

    /// The imported file from before IOS-POC-48, and the default wherever no configuration is known.
    public static let importedFile = ConfigSource.imported(id: legacyImportedIdentity)

    /// A stable identity for the configuration itself, used to bind watch history to the source
    /// it was watched on (IOS-POC-10E). An imported file's is its own since IOS-POC-48; before that
    /// every imported configuration shared one bucket.
    public var identity: String {
        switch self {
        case .imported(let id): id
        case .remote(let url): url.absoluteString
        }
    }

    /// The directory the configuration lives in, which relative references resolve against.
    public var baseURL: URL? {
        switch self {
        case .imported: nil
        case .remote(let url): url
        }
    }

    /// Turns a config-relative reference into the resource's own URL.
    ///
    /// - A `jar` reference carries a `;md5;<hash>` suffix that is not part of the path, so
    ///   everything from the first `;` is dropped. **The hash is not verified here; this resolves
    ///   locations and does not download, validate or execute anything.**
    /// - An already-absolute reference is returned unchanged.
    /// - Anything that is not a relative path is not a resource. `csp_*` values are Spider class
    ///   names, and `URL(string:relativeTo:)` would otherwise turn them into plausible-looking URLs.
    public func resourceURL(for reference: String) -> URL? {
        let path = reference.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !path.isEmpty else { return nil }
        if let absolute = URL(string: path), absolute.scheme != nil { return absolute }
        guard path.hasPrefix("./") || path.hasPrefix("../"), let baseURL else { return nil }
        // RFC 3986 resolution: drops the base query, percent-encodes non-ASCII names, honours `../`.
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }
}

/// IOS-POC-48 — which identity an imported configuration file has.
///
/// An imported file has no address to be its identity, and before IOS-POC-48 every one of them
/// shared `"imported"`: two different files' watch history, site memory and favourites all landed
/// in one bucket. Now each **content** gets its own: the first time a file's bytes are imported they
/// are given `imported:<UUID>`, and the same bytes imported again get that identity back. That is
/// the only "same configuration" this can prove; a file name or a picked path would be a guess, and
/// an edited file is a different configuration whose records start fresh (the old ones are kept).
///
/// **The table is the only state.** The identity of the file on disk is looked up from its own bytes
/// every time, so there is no separate "current identity" that a crash between two writes could leave
/// pointing at the wrong file. The importer records the new bytes first and writes the file second:
/// a crash in between leaves an unused entry and the old file with its old identity.
///
/// A file imported before IOS-POC-48 has no entry and keeps `ConfigSource.legacyImportedIdentity`.
public struct ImportedConfigIdentities: Sendable {
    static let key = "webhtv.importedConfig.identities"
    static let prefix = "imported:"
    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The identity of an imported file with exactly these bytes.
    public func identity(of data: Data) -> String {
        known()[Self.fingerprint(data)] ?? ConfigSource.legacyImportedIdentity
    }

    /// Records the identity `data` will have once it replaces `previous`, the file imported now (if
    /// any), and answers it. Call before the file is written.
    ///
    /// `previous` is recorded first under the identity it has now: a file imported before IOS-POC-48
    /// has no entry, and once it is replaced its bytes would otherwise come back as a new
    /// configuration if they were ever imported again.
    public func register(_ data: Data, replacing previous: Data?) -> String {
        var table = known()
        if let previous {
            let old = Self.fingerprint(previous)
            if table[old] == nil { table[old] = ConfigSource.legacyImportedIdentity }
        }
        let fingerprint = Self.fingerprint(data)
        let identity = table[fingerprint] ?? Self.prefix + UUID().uuidString
        table[fingerprint] = identity
        defaults.set(table, forKey: Self.key)
        return identity
    }

    private func known() -> [String: String] {
        defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    static func fingerprint(_ data: Data) -> String { runtimeSHA256(data) }
}
