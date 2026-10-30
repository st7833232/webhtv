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
        return try decoder.decode(WebHTVConfig.self, from: unwrapped(data))
    }

    /// W-228: FongMi's `Decoder.verify` — a configuration that is not already a JSON object may be
    /// wrapped as `<8 alphanumerics>**<base64>`, as `2423…` hex AES-CBC, or the first around the
    /// second. Anything else is returned untouched and left for the JSON decoder to judge.
    static func unwrapped(_ data: Data) -> Data {
        if (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) is [String: Any] { return data }
        guard var text = String(data: data, encoding: .utf8) else { return data }
        // `Decoder.extract`: everything after the first marker; a body that will not decode is kept as is.
        if text.contains("**"), let marker = text.range(of: "[A-Za-z0-9]{8}\\*\\*", options: .regularExpression),
           let decoded = Data(base64Encoded: String(text[marker.upperBound...]), options: .ignoreUnknownCharacters),
           let plain = String(data: decoded, encoding: .utf8) {
            text = plain
        }
        if text.hasPrefix("2423"), let plain = cbc(text.filter { !$0.isWhitespace }) { text = plain }
        return Data(text.utf8)
    }

    /// `Decoder.cbc`: the hex spells `$#key#$ … <13-character IV>`; key and IV are padded with `0` to 16,
    /// and the ciphertext runs from after the first `2324` to 26 hex digits (the IV) before the end.
    static func cbc(_ hex: String) -> String? {
        let spelled = String(decoding: Data(hex: hex), as: UTF8.self).lowercased()
        guard let open = spelled.range(of: "$#"), let close = spelled.range(of: "#$"), open.upperBound <= close.lowerBound,
              let body = hex.range(of: "2324"), hex.distance(from: body.upperBound, to: hex.endIndex) >= 26
        else { return nil }
        let pad = { (value: String) in value.count >= 16 ? value : value + String(repeating: "0", count: 16 - value.count) }
        let key = pad(String(spelled[open.upperBound..<close.lowerBound]))
        let iv = pad(String(spelled.suffix(13)))
        let cipher = String(hex[body.upperBound..<hex.index(hex.endIndex, offsetBy: -26)])
        let plain = CryptoHost.run(algorithm: "aes", encrypt: false, input: cipher, key: key, iv: iv,
                                   mode: "CBC", inputEncoding: "hex")
        return plain.isEmpty ? nil : plain
    }

    /// Decodes and requires at least one usable source, so a syntactically valid but useless payload
    /// can never replace a cached copy that still works.
    public static func validate(_ data: Data, resolvedBy resolver: CSPSourceResolver = CSPSourceResolver()) throws -> WebHTVConfig {
        let config = try decode(data)
        // QIST-TYPE3: a spider-only config (qist XYQ.json) is usable when the registry drives one of
        // its classes. Native CMS is checked first so a CMS config never loads the registry.
        // ponytail: source-less resolver, so drpy, Python and JAR-mapped spiders (they need the
        // config's own address) do not count; a config with only those is still refused, as before.
        // Pass the caller's ConfigSource here if one of those ever has to stand alone.
        // IOS-POC-61 S3 (Manager #2112 ①): a site that only waits for the 爬蟲工具 counts too, so the App can
        // load the configuration and offer the download instead of refusing it.
        guard !config.nativeCMSSites.isEmpty || !config.spiderSites(resolvedBy: resolver).isEmpty
                || !config.sitesNeedingSpiderTool(resolvedBy: resolver).isEmpty else {
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
