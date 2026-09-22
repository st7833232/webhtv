import Foundation

public struct WebHTVConfig: Decodable, Sendable {
    public let sites: [Site]

    public var nativeCMSSites: [Site] {
        sites.filter(\.isNativeCMS)
    }

    /// The native CMS sites this app drives directly: type-0 MacCMS XML, type-1 MacCMS JSON and
    /// type-4 CatVod remote APIs.
    public var supportedSites: [Site] {
        nativeCMSSites.filter { $0.type == 0 || $0.type == 1 || $0.type == 4 }
    }

    /// Every configured `csp_*` spider site, whether or not one is ported yet.
    public var cspSpiderSites: [Site] { sites.filter(\.isCSPSpider) }

    /// Every configured drpy JavaScript site, whether or not its engine can be loaded today.
    public var drpySpiderSites: [Site] { sites.filter(\.isDrpySpider) }

    /// Every configured Python site, whether or not this build can run one.
    public var pythonSpiderSites: [Site] { sites.filter(\.isPythonSpider) }

    /// The `csp_*` sites a registry can actually run. This is the routing change that stops type-3
    /// being rejected on classification alone: membership is decided by the registry, not the type.
    public func spiderSites(resolvedBy resolver: CSPSourceResolver) -> [Site] {
        (cspSpiderSites + drpySpiderSites + pythonSpiderSites).filter(resolver.canResolve)
    }

    /// Everything browsable today — native CMS plus any spider the registry can drive.
    public func drivableSites(resolvedBy resolver: CSPSourceResolver) -> [Site] {
        supportedSites + spiderSites(resolvedBy: resolver)
    }
}

public struct Site: Decodable, Identifiable, Sendable {
    public let key: String
    public let name: String
    public let type: Int
    public let api: String
    public let ext: [String: String]?
    /// The site's `ext` exactly as CatVod hands it to `Spider.init(Context, String)`: the raw JSON
    /// text for an object or array, or the literal string when `ext` is one. Kept because the
    /// `[String: String]` form above silently drops numbers, nested objects and string `ext`s — and
    /// spiders read all of those. `csp_AppDrama` carries an RSA `publicKey`, `csp_App99` a mix of
    /// strings and numbers; decoding only the flat-string shape loses them.
    public let rawExtJSON: String

    enum CodingKeys: String, CodingKey {
        case key, name, type, api, ext
    }

    /// **Not `key` alone.** CatVod does not require site keys to be unique and this configuration
    /// proves it: four keys appear twice (`爱影`, `Bidys`, `AppV6Dxs`, `星芽短剧`), and since
    /// IOS-POC-5L both `爱影` sites are drivable, so a key-only identity would give the picker two
    /// rows that select each other. The `ext` is what distinguishes them — it is the whole
    /// definition of where a site points — which is also why `SpiderSessionStore` keys its cache on
    /// exactly this string.
    public var id: String { key + "\u{0}" + rawExtJSON }

    public var isNativeCMS: Bool {
        guard type == 0 || type == 1 || type == 4, let scheme = URL(string: api)?.scheme else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// A type-3 site whose `api` names a CatVod spider class rather than an endpoint.
    public var isCSPSpider: Bool { type == 3 && api.hasPrefix("csp_") }

    /// A type-3 site whose `api` is a JavaScript engine rather than a class name — the drpy sites.
    /// `api` is the engine (`./drpy_libs/drpy2.min.js`) and `ext` is this site's own rule script,
    /// the same split `XBPQ` and `XYQHiker` already have between an engine and a rule file.
    public var isDrpySpider: Bool { type == 3 && api.hasSuffix(".js") }

    /// Where a drpy site's **rule script** lives, which is not always the same field.
    ///
    /// IOS-POC-10N. This configuration carries two shapes and the code only understood one:
    ///
    /// - the common shape gives `api` the engine (`./drpy_libs/drpy2.min.js`) and the rule to `ext`;
    /// - `步步｜4K` gives `api` the rule itself (`./json/4k.js`) and has **no `ext` at all**;
    /// - `麻豆(js)` gives `api` the rule and sets `"ext": {}` — **an empty object, which is not an
    ///   empty string**. IOS-POC-10N only checked for emptiness, so this one got `"{}"` as its
    ///   reference and failed just as opaquely as the shape it fixed.
    ///
    /// So the test is not "is `ext` present" but **"is `ext` something `resourceURL` could
    /// resolve"** — a relative path or an absolute address. Anything else is configuration noise,
    /// and the rule is the `api`: for a `.js` site that field *is* the script, with the engine
    /// implied, exactly as a `csp_*` class name implies its runtime.
    public var drpyRuleReference: String {
        Self.isResourceReference(rawExtJSON) ? rawExtJSON.trimmingCharacters(in: .whitespaces) : api
    }

    /// Mirrors what `ConfigSource.resourceURL(for:)` will accept. Kept deliberately narrow: a
    /// value that cannot become a URL there must not be handed to it, or the failure arrives one
    /// layer later wearing the wrong name.
    static func isResourceReference(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if text.hasPrefix("./") || text.hasPrefix("../") { return true }
        guard let scheme = URL(string: text)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// A type-3 site whose `api` is a Python script — `./py/皮皮虾.py`. The script is the spider,
    /// the way a `csp_*` class name is, and `ext` is what reaches its `init`.
    public var isPythonSpider: Bool { type == 3 && api.lowercased().hasSuffix(".py") }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        name = try values.decode(String.self, forKey: .name)
        type = try values.decode(Int.self, forKey: .type)
        api = try values.decode(String.self, forKey: .api)
        // `ext` is a string, a number or absent on most sites; only the dictionary form carries query parameters.
        ext = try? values.decode([String: String].self, forKey: .ext)
        rawExtJSON = (try? values.decode(JSONValue.self, forKey: .ext))?.extendText ?? ""
    }
}

/// Any JSON value, decoded without knowing its shape. Exists so a site's `ext` survives intact:
/// CatVod passes `ext` to a spider as opaque text, and the shapes in this configuration include
/// objects, plain strings and numbers.
enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .null }
    }

    var any: Any {
        switch self {
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .object(let value): value.mapValues(\.any)
        case .array(let value): value.map(\.any)
        case .null: NSNull()
        }
    }

    /// What `Site.getExt()` returns on Android: a bare string stays a string, anything else is JSON.
    ///
    /// Scalars are rendered directly. `JSONSerialization` raises an Objective-C exception, which no
    /// `try?` can catch, when handed a top-level number or bool, and this configuration does contain
    /// sites whose `ext` is a bare number.
    var extendText: String {
        switch self {
        case .string(let value): return value
        case .null: return ""
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            return value == value.rounded() && abs(value) < 1e15
                ? String(Int64(value)) : String(value)
        case .object, .array:
            guard let data = try? JSONSerialization.data(withJSONObject: any) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
