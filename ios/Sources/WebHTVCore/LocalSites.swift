import Foundation

/// W-277 (design W-275 §4.4): a site the viewer added on this device by typing its address, kept beside
/// the configuration source it was added under (the user chose 1b: local sites follow the source).
///
/// Stored in the shape of a configuration's site (`key name type api`), so it decodes into a `Site` and
/// every screen treats it like any other type-0/1 site.
public struct LocalSite: Codable, Equatable, Identifiable, Sendable {
    public let key: String
    public var name: String
    public let type: Int
    public let api: String
    /// W-278: a web-template site's XBPQ rules (`主页url`, `分类url`, `分类`) as JSON text; nil for an API site.
    public let ext: String?
    /// W-278: the address a web-template site was found at; it, not `api` (`csp_XBPQ`), names the site.
    public let home: String?
    public let addedAt: Date
    /// The detector's format label, e.g. 苹果CMS v10 JSON. Shown in settings only.
    public let detectedFrom: String

    public var id: String { key }

    /// Nil when neither `home` nor `api` is an http(s) address, which the detector never produces.
    public init?(name: String, type: Int, api: String, ext: String? = nil, home: String? = nil, detectedFrom: String,
                 addedAt: Date = Date()) {
        guard let key = LocalSites.key(forAPI: home ?? api) else { return nil }
        self.key = key
        self.name = name
        self.type = type
        self.api = api
        self.ext = ext
        self.home = home
        self.addedAt = addedAt
        self.detectedFrom = detectedFrom
    }

    public var site: Site? {
        var object: [String: Any] = ["key": key, "name": name, "type": type, "api": api]
        if let ext, let rules = try? JSONSerialization.jsonObject(with: Data(ext.utf8)) { object["ext"] = rules }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(Site.self, from: data)
    }

    /// Where the site is, for settings: the web address of a web-template site, else its api.
    public var address: String { home ?? api }

    public var isInsecure: Bool { URL(string: address)?.scheme?.lowercased() == "http" }
}

public enum LocalSites {
    public static let keyPrefix = "local_"

    public static func isLocal(_ site: Site) -> Bool { site.key.hasPrefix(keyPrefix) }

    /// `local_` + the first 10 hex digits of SHA-256 over `normalizedAPI`: never a configuration's key, and
    /// the same api always gets it back, so a site removed and added again finds its favourites and history.
    public static func key(forAPI api: String) -> String? {
        normalizedAPI(api).map { keyPrefix + runtimeSHA256(Data($0.utf8)).prefix(10) }
    }

    /// The protocol's own parameters; they say what to fetch, not which site it is (W-275 §4.4.1 rule 5).
    static let protocolQueryNames: Set<String> = ["at", "ac", "t", "pg", "wd", "h", "ids", "f", "quick", "extend"]

    /// W-275 §4.4.1: one api written several ways is one site. Scheme-blind, lower-case host, no default
    /// port, path case kept, slashes collapsed, no trailing slash or `/at/xml`·`/at/json`, protocol query
    /// parameters dropped and the rest sorted, no fragment. Nil when it is not an http(s) address.
    public static func normalizedAPI(_ text: String) -> String? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        var result = "//" + host
        if let port = components.port, port != (scheme == "http" ? 80 : 443) { result += ":\(port)" }
        var path = components.percentEncodedPath
        while path.contains("//") { path = path.replacingOccurrences(of: "//", with: "/") }
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/at/xml", "/at/json"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
            while path.hasSuffix("/") { path.removeLast() }
        }
        result += path
        let kept = (components.percentEncodedQueryItems ?? [])
            .filter { !protocolQueryNames.contains($0.name) }
            .sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        if !kept.isEmpty { result += "?" + kept.map { item in item.value.map { "\(item.name)=\($0)" } ?? item.name }.joined(separator: "&") }
        return result
    }

    /// The listed sites: the configuration's, then this source's local ones that it does not already carry
    /// (W-275 §4.4: a remote site with the same api wins; the local one stays stored and settings says why).
    /// `runnable` is the rule the configuration's own sites were listed by (W-275 §9.3, Reviewer N-1), so a
    /// local XBPQ site waits for the spider tool exactly as a remote one does.
    public static func merged(_ remote: [Site], with local: [LocalSite], runnable: (Site) -> Bool) -> [Site] {
        let taken = remoteAPIs(remote)
        return remote + local.filter { !isShadowed($0, by: taken) }.compactMap(\.site).filter(runnable)
    }

    public static func remoteAPIs(_ remote: [Site]) -> Set<String> {
        Set(remote.filter(\.isNativeCMS).compactMap { normalizedAPI($0.api) })
    }

    /// A web-template site has no api to compare (W-275 §9.3) and is never shadowed.
    public static func isShadowed(_ local: LocalSite, by remoteAPIs: Set<String>) -> Bool {
        guard local.ext == nil else { return false }
        return normalizedAPI(local.api).map(remoteAPIs.contains) ?? true
    }
}

/// `local-sites.json`: each configuration source's local sites, keyed by `ConfigSource.identity`.
public struct LocalSiteStore: Codable, Equatable, Sendable {
    public var bySource: [String: [LocalSite]]

    public init(bySource: [String: [LocalSite]] = [:]) { self.bySource = bySource }

    public func sites(for source: String) -> [LocalSite] { bySource[source] ?? [] }

    /// The same api added again keeps its place and takes the new name, like `SavedSourceList.upsert`.
    public mutating func upsert(_ site: LocalSite, for source: String) {
        var list = sites(for: source)
        if let index = list.firstIndex(where: { $0.key == site.key }) { list[index].name = site.name } else { list.append(site) }
        bySource[source] = list
    }

    public mutating func rename(key: String, to name: String, for source: String) {
        guard var list = bySource[source], let index = list.firstIndex(where: { $0.key == key }) else { return }
        list[index].name = name
        bySource[source] = list
    }

    public mutating func remove(key: String, for source: String) {
        bySource[source]?.removeAll { $0.key == key }
        if bySource[source]?.isEmpty == true { bySource[source] = nil }
    }

    /// A source the viewer forgets takes its local sites with it.
    public mutating func forget(source: String) { bySource[source] = nil }

    /// A missing or unreadable file is an empty store: nothing else depends on it.
    public static func load(from url: URL) -> LocalSiteStore {
        guard let data = try? Data(contentsOf: url), let store = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return store
    }

    public func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
