import Foundation

public extension URLSession {
    /// Shared session for every WebHTV API call. The default 60 s inactivity timeout left an
    /// unreachable source hanging the screen, and a type-4 home issues two sequential requests.
    static let webHTV: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        // IOS-POC-10L: no HTTP cache on this session, and that is measured rather than assumed.
        //
        // The user asked whether pull to refresh actually runs, because it returned instantly and
        // nothing changed. It ran — but `URLSessionConfiguration.default` carries a `URLCache`,
        // and the simulator's cache held **67 listing requests**, `api/crumb/list?…&page=1` among
        // them. The refresh was being answered from disk.
        //
        // Every request on this session is live content or code: CMS listings, a spider's own
        // HTTP, the configuration JSON, drpy's engine and the compatibility pack. Caching any of
        // them buys a little bandwidth and costs correctness — and for the hash-pinned downloads
        // it is worse than that, because a stale cached copy fails the pin and refuses the site
        // outright. AVPlayer does not use this session, so video is unaffected.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Not storing either. Keeping a cache that is never read is just disk.
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
}

public enum ConfigLoaderError: Error, Equatable, LocalizedError {
    case invalidHTTPStatus(Int)
    case noSupportedSites

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPStatus(let code): "設定來源回應 HTTP \(code)。"
        case .noSupportedSites: "此設定沒有 iOS 可用的來源（CMS 或已支援的爬蟲）。"
        }
    }
}

public enum ConfigLoader {
    public static func decode(_ data: Data) throws -> WebHTVConfig {
        let decoder = JSONDecoder()
        // QIST-JSONC: shared configs such as qist XYQ.json carry `//` comments. JSON5 is a superset
        // of JSON, so standard configs decode exactly as before and invalid data is still rejected.
        decoder.allowsJSON5 = true
        return try decoder.decode(WebHTVConfig.self, from: data)
    }

    /// Decodes and requires at least one usable source, so a syntactically valid but useless payload
    /// can never replace a cached copy that still works.
    public static func validate(_ data: Data) throws -> WebHTVConfig {
        let config = try decode(data)
        // QIST-TYPE3: a spider-only config (qist XYQ.json) is usable when the registry drives one of
        // its classes. Native CMS is checked first so a CMS config never loads the registry.
        // ponytail: source-less resolver, so drpy, Python and JAR-mapped spiders (they need the
        // config's own address) do not count; a config with only those is still refused, as before.
        // Pass the caller's ConfigSource here if one of those ever has to stand alone.
        guard !config.nativeCMSSites.isEmpty || !config.spiderSites(resolvedBy: CSPSourceResolver()).isEmpty else {
            throw ConfigLoaderError.noSupportedSites
        }
        return config
    }

    /// Downloads and validates a configuration. The bytes come back so the caller can cache exactly
    /// what it verified rather than re-encoding the decoded model.
    public static func fetch(from url: URL) async throws -> (data: Data, config: WebHTVConfig) {
        let (data, response) = try await URLSession.webHTV.data(from: url)
        if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            throw ConfigLoaderError.invalidHTTPStatus(response.statusCode)
        }
        return (data, try validate(data))
    }
}
