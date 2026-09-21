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
    case importedFile
    case remote(URL)

    /// A stable identity for the configuration itself, used to bind watch history to the source
    /// it was watched on (IOS-POC-10E). An imported file has no address, so every imported
    /// configuration shares one bucket — the honest answer, since nothing distinguishes them.
    public var identity: String {
        switch self {
        case .importedFile: "imported"
        case .remote(let url): url.absoluteString
        }
    }

    /// The directory the configuration lives in, which relative references resolve against.
    public var baseURL: URL? {
        switch self {
        case .importedFile: nil
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
