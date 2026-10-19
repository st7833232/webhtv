import Foundation

/// Maps a `csp_*` class name to the JavaScript that reimplements it. Absence means "not ported";
/// what the JAR audit (`scripts/audit_spider_jars.py`) found about each class stays beside `ported`.
public struct SpiderRegistry: Sendable {
    public struct Entry: Sendable {
        public let script: String
        /// Which copy of the script this is. The app shows it; the tests assert on it.
        public let source: Source

        public init(script: String, source: Source = .bundled) {
            self.script = script
            self.source = source
        }
    }

    /// Where a script came from. Resolution order is exactly this order: a configuration's verified
    /// compatibility pack first, the official pack second (IOS-POC-61), a bundle's copy last, and absent
    /// means "not driven". Since S5 the App's own bundle carries no spider, so only the tests' `bundle:` has one.
    public enum Source: Sendable, Equatable {
        case bundled
        case pack(version: String)
        case official(version: String)
    }

    let entries: [String: Entry]
    public let prelude: String
    /// The drpy adapter — the `SpiderRuntime` names mapped onto drpy2's export. Bundled like
    /// `host.js` and, like it, **not packable**: it is part of the SDK a drpy rule runs against,
    /// not a spider a compatibility pack may replace.
    public let drpyBridge: String
    /// The **CatVod JS spider** adapter (IOS-POC-10T), the sibling of `drpyBridge` for TVBox's other
    /// JavaScript contract. Bundled and not packable for exactly the same reason.
    public let jsSpiderBridge: String
    /// IOS-POC-55: the installed pack's scoped class mappings; see `mapping(for:in:)`.
    let mappings: [SpiderPack.ClassMapping]

    public init(entries: [String: Entry], prelude: String, drpyBridge: String = "",
                jsSpiderBridge: String = "", mappings: [SpiderPack.ClassMapping] = []) {
        self.entries = entries
        self.prelude = prelude
        self.drpyBridge = drpyBridge
        self.jsSpiderBridge = jsSpiderBridge
        self.mappings = mappings
    }

    /// The classes the 爬蟲工具 (official pack) brings: a new port is a new `ios/Spiders/*.js` plus one line here.
    /// IOS-POC-61 S5: only names — what runs, and under which alias, is whatever an installed pack carries; this list
    /// counts the sites a download would bring before any pack is installed (`sitesNeedingSpiderTool`) and feeds
    /// the pack tools and the JAR audit. It must name exactly what the official pack built from `ios/Spiders` drives
    /// (`scripts/test_pack_exclusions.py`, W-141 M-3): withdrawing a spider from the pack means removing it here too,
    /// in an IPA, or every App would keep asking to download a class no pack brings. Each line names the audit category
    /// and the JAR the original shipped in.
    static let ported: Set = [
        "AppGet",     // http-crypto: river-fman.jar, xiaosa-0807.jar
        // The rest of the 苹果CMS App-API family, ported in IOS-POC-5L.
        "AppQi",      // http-crypto: river-fman.jar, xiaosa-0807.jar, 愛影.jar
        "App99",      // http-crypto: river-fman.jar, xiaosa-0807.jar
        "App3Q",      // http-crypto: river-fman.jar, xiaosa-0807.jar
        "Bili",       // http-json: river-fman.jar
        "JianPian",   // http-json: river-fman.jar
        // 薦片 is configured as `csp_JPianAmns`, which in `aowu.jar` is an empty shim over a
        // native-encrypted payload — nothing to port. `JianPian` drives the same API unprotected,
        // and the site's own `ext` proves they are the same one: its categories 1/2/3/4/67 and keys
        // type/area/year/sort are exactly what `JianPian` substitutes into its request template,
        // including 67 being the category that goes to `shortList`. See docs/IOS-POC-5M-jianpian.md.
        "JPianAmns",  // http-json: river-fman.jar (as JianPian; aowu.jar's own class is a shim)
        // IOS-POC-57B-13: qist 0825's 荐片 (W-99: its own old API host is dead; its list parameters and
        // filter ids answer on JianPian's). The "$$$1" danmaku switch in its ext is dropped: no danmaku on iOS.
        "Jianpian",   // http-json: qist 0825 Jianpian (as JianPian)
        // Rule engines: one port serves every site configured for them, now and later.
        "XBPQ",       // http-crypto: xyqxbpq.jar, xiaosa-0807.jar
        "XYQHiker",   // http-json: xyqxbpq.jar, river-fman.jar
        // IOS-POC-44A: short-drama app APIs, both live when ported (docs/IOS-POC-44-csp-portable-sites.md).
        "WeiguanDJ",  // http-crypto: xiaosa-0807.jar (only an md5 client id; no cipher)
        "HemaDJ",     // http-json: xiaosa-0807.jar (AES-CBC envelope)
        // IOS-POC-44B: two more short-drama APIs.
        "QimaoDJ",    // http-json: xiaosa-0807.jar (md5-signed GETs, a substituted-base64 header)
        "HaokanDJ",   // http-json: xiaosa-0807.jar (form POSTs; search is dead upstream)
        // IOS-POC-44C: the mw-movie API, one script for both classes.
        "Jpys",       // http-crypto: river-fman.jar
        "Jys",        // http-crypto: river-fman.jar (as Jpys: the same body apart from a line label)
        // IOS-POC-44D: a doubly HMAC-signed API and a DoH-located, AES-ECB envelope API.
        "Feiyu",      // http-crypto: xiaosa-0807.jar (HMAC-SHA256 secret, then HMAC-SHA256 per request)
        "MiaoWu",     // http-crypto: xiaosa-0807.jar (DoH TXT host, AES-256-ECB replies, vod/parse)
        // IOS-POC-44E: an md5-signed API with per-quality play addresses, and the `.vod` dialect of AppYsV2.
        "AppYQK",     // http-crypto: xiaosa-0807.jar (md5-signed JSON POSTs; only `canPlay` qualities)
        "AppYsV2",    // http-json: river-fman.jar (the `.vod` dialect only)
        // IOS-POC-44F: an AES-CBC live-match API, and a plain 苹果CMS JSON API.
        "GuaziTY",    // http-crypto: river-fman.jar (AES-128-CBC form POSTs; live matches only)
        "MoDu",       // http-json: xiaosa-0807.jar (苹果CMS `ac=detail`)
        // IOS-POC-44G: the first two ports on js.host 1.3 (RSA, binary HTTP, AES hex output).
        "AppDrama",   // http-crypto: river-fman.jar (protobuf POSTs, RSA-signed public params)
        "Uvod",       // http-crypto: custom_spider.jar (AES bodies whose key travels RSA-encrypted)
        // IOS-POC-57: qist/tvbox `spider.jar` renames of five ported APIs (same hosts, live golden passed).
        "ShortHema",    // http-json: qist spider.jar (as HemaDJ)
        "ShortQimao",   // http-json: qist spider.jar (as QimaoDJ)
        "ShortHaokan",  // http-json: qist spider.jar (as HaokanDJ)
        "ShortWeiguan", // http-crypto: qist spider.jar (as WeiguanDJ)
        "SportsGuazi",  // http-crypto: qist spider.jar (as GuaziTY)
        // IOS-POC-57B-1: FirstAid 急救教學
        "FirstAid",     // http-html: spider.jar
        // IOS-POC-57B-2: 兔小贝 兒童影音
        "TuXiaoBei",    // http-html: spider.jar (mobile UA; JSONP lists, HTML subjects)
        // IOS-POC-57B-3: 咕噜, the first port on js.host 1.4 (P-256, HKDF, AES-GCM/CBC, zlib).
        "Gulu",         // http-crypto: spider.jar (private protobuf API; direct lines only)
        // IOS-POC-57B-4: 贝乐虎 兒童影音
        "BeiLeHu",      // http-json: spider.jar (JSON POST; static mp4)
        // IOS-POC-57B-5: 独播库 影視
        "Duboku",       // http-json: spider.jar (Java-Random-signed GET; HLS)
        // IOS-POC-57B-9: 博看听书, the first audio-only source (plain-HTTP m4a)
        "TingBokan",    // http-json: spider.jar (paged album units; no expiry)
        // IOS-POC-57B-10: 蜻蜓FM live radio (fixed MP3 streams)
        "QingtingFM",   // http-json: spider.jar (GraphQL lists; integer-checked query)
        // IOS-POC-57B-6: 戏曲多多 opera videos (HLS with a per-play auth_key)
        "AppLY",        // http-json: spider.jar (JSON POST with a fixed md5 header)
        // IOS-POC-57B-7: 星芽短剧 short dramas (AES-ECB login token; signed plain-HTTP mp4)
        "ShortXingya",  // http-json: spider.jar (token-gated JSON API; four-hour media links)
        // IOS-POC-57B-11: 咖啡体育 live football/basketball (one card per streamer room)
        "SportsKafei",  // http-json: spider.jar (live HLS or rtmp signals; nothing stored but the room id)
        // IOS-POC-57B-12: 堇夏听书 audiobooks (m4a that needs the site's Referer)
        "TingJinxia",   // http-html: spider.jar (chapter page meta, then a form POST for the audio)
        // IOS-POC-57B-14: 88看球 live sports; qist 0825's Kanqiu is the same site on a mirror (W-102: same match ids,
        // identical lines), so it runs this script. Only the HLS inside 88player wrapper pages is listed.
        "Sports88",     // http-html: spider.jar (HTML lists, base64-wrapped JSON lines per match)
        "Kanqiu",       // http-html: qist pg jar (as Sports88; its own detail route answers 404)
        // IOS-POC-57B-15: 爱看 • 影视 (Ikanbot), the first port whose 片单 lists are folders (IOS-POC-60).
        "Ikanbot",      // http-html: qist j-spider.jar (HTML lists, getResN JSON lines; official pack only since IOS-POC-61 S5)
        // IOS-POC-57B-16: 呦呦 • DJ (Djuu), audio; its 曲库 playlists are folders (IOS-POC-60).
        "Djuu",         // http-html: qist j-spider.jar (HTML lists, POST /play/music JSON; official pack only since IOS-POC-61 S5)
        // IOS-POC-57B-17: 旺旺 • 影视 (Wwys); only line ② (lzm3u8, standard HLS) is listed.
        "Wwys",         // http-html: qist spider.jar (maccms HTML lists, mac_url m3u8 lines; no relay)
        // IOS-POC-57B-18: 世界听书 audiobooks (m4a its CDN serves only to an okhttp User-Agent)
        "TingShijie",   // http-json: qist spider.jar (md5-signed chapter address; some chapters never resolve)
    ]

    /// A configured class name that a *different* script drives, because the named class carries no
    /// logic of its own, or none the other lacks. Only ever for a pair proven to be the same site:
    /// `Jys` decompiles to `Jpys` with a different line label and one header fewer, and its host serves
    /// the same listing, detail and episode ids as `Jpys`'s (IOS-POC-44C). The `Short*`/`SportsGuazi`
    /// classes of qist/tvbox's `spider.jar` call the same hosts as their targets, and each target
    /// drove the qist-configured site through home, category, detail, search and play (IOS-POC-57).
    /// One line on purpose: `scripts/audit_spider_jars.py` (`registry_names`) reads it with a single-line regex.
    static let aliases = ["JPianAmns": "JianPian", "Jianpian": "JianPian", "Jys": "Jpys", "ShortHema": "HemaDJ", "ShortQimao": "QimaoDJ", "ShortHaokan": "HaokanDJ", "ShortWeiguan": "WeiguanDJ", "SportsGuazi": "GuaziTY", "Kanqiu": "Sports88"]

    /// The registry the app actually runs on: the official pack, a verified compatibility pack over it, and
    /// nothing else since S5 — with neither, no `csp_*` class is driven. `CSPSourceResolver` uses this, so every
    /// call site picks up a pack without knowing one exists.
    public static func active(bundle: Bundle? = nil) -> SpiderRegistry {
        bundled(bundle: bundle, official: ActiveOfficialPack.shared.current, overlaying: InstalledSpiderPack.shared.current)
    }

    public static func bundled(bundle: Bundle? = nil) -> SpiderRegistry {
        bundled(bundle: bundle, overlaying: nil)
    }

    /// A pack entry replaces the bundled script for the same class, and may add a class the bundle
    /// never carried. Nothing else about the app changes: the script still runs against the same
    /// `CatVodHost` and the same `Spider` ABI, which is the boundary a pack cannot cross.
    public static func bundled(bundle: Bundle? = nil, overlaying pack: SpiderPack?) -> SpiderRegistry {
        bundled(bundle: bundle, official: nil, overlaying: pack)
    }

    /// IOS-POC-61: the three layers, class by class. A class neither pack brings stays bundled; mappings
    /// come from the compatibility pack alone.
    public static func bundled(bundle: Bundle? = nil, official: OfficialSpiderPack?,
                               overlaying pack: SpiderPack?) -> SpiderRegistry {
        let base = bundledOnly(bundle: bundle)
        var entries = base.entries
        if let official { overlay(&entries, official.scripts, official.aliases, as: .official(version: official.version)) }
        if let pack { overlay(&entries, pack.scripts, pack.aliases, as: .pack(version: pack.version)) }
        return SpiderRegistry(entries: entries, prelude: base.prelude, drpyBridge: base.drpyBridge,
                              jsSpiderBridge: base.jsSpiderBridge, mappings: pack?.mappings ?? [])
    }

    private static func overlay(_ entries: inout [String: Entry], _ scripts: [String: String],
                                _ aliases: [String: String], as source: Source) {
        for (name, script) in scripts { entries[name] = Entry(script: script, source: source) }
        // An alias only resolves to a script its own layer brought, so a stale alias cannot silently repoint
        // another layer's class.
        for (alias, target) in aliases {
            guard let entry = entries[target], entry.source == source else { continue }
            entries[alias] = entry
        }
    }

    /// The SDK (`host.js` and the two bridges) is always the App's own; `bundle` only says where spiders come from,
    /// and the App's bundle has none since S5 (the tests pass the repository's `ios/Spiders`).
    private static func bundledOnly(bundle: Bundle? = nil) -> SpiderRegistry {
        func load(_ name: String, from bundle: Bundle) -> String {
            guard let url = bundle.url(forResource: name, withExtension: "js", subdirectory: "Spiders"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
            return text
        }
        var entries = [String: Entry]()
        for name in ported {
            let script = load(aliases[name] ?? name, from: bundle ?? .module)
            if !script.isEmpty { entries[name] = Entry(script: script, source: .bundled) }
        }
        return SpiderRegistry(entries: entries, prelude: load("host", from: .module),
                              drpyBridge: load("drpy-bridge", from: .module), jsSpiderBridge: load("js-spider", from: .module))
    }

    public func entry(for api: String) -> Entry? { entries[Self.className(from: api)] }
    public func canDrive(_ api: String) -> Bool { entry(for: api) != nil }

    /// IOS-POC-55: the adapter a pack proved this site's class to be, for a class the registry does
    /// not drive by name (a name it does drive keeps its existing binding). Every part of the scope
    /// must match — configuration, site key, class, and the JAR this configuration resolves for the
    /// site. The JAR's actual bytes are checked against `jarSha256` before the session is built
    /// (`CSPSourceResolver`); `pack.assemble` already pinned the adapter's bytes.
    public func mapping(for site: Site, in source: ConfigSource) -> SpiderPack.ClassMapping? {
        guard site.isCSPSpider, !canDrive(site.api), !mappings.isEmpty,
              let config = source.baseURL.flatMap({ Self.withoutQuery($0.absoluteString) }),
              let jar = source.resourceURL(for: site.jar)?.absoluteString else { return nil }
        let className = Self.className(from: site.api)
        return mappings.first {
            $0.className == className && $0.site == site.key && Self.withoutQuery($0.config) == config
                && URL(string: $0.jar)?.absoluteString == jar
        }
    }

    private static func withoutQuery(_ text: String) -> String? {
        guard var parts = URLComponents(string: text) else { return nil }
        parts.query = nil
        parts.fragment = nil
        return parts.url?.absoluteString
    }

    /// `csp_AppGet` → `AppGet`; a bare class name passes through unchanged.
    public static func className(from api: String) -> String {
        api.hasPrefix("csp_") ? String(api.dropFirst(4)) : api
    }

    public func makeRuntime(for api: String, siteKey: String,
                            defaults: UserDefaults = .standard,
                            session: URLSession = .webHTV) throws -> SpiderRuntime {
        guard let entry = entry(for: api) else { throw SpiderError.notRegistered(api) }
        return try JavaScriptSpiderRuntime(
            name: Self.className(from: api), script: entry.script, prelude: prelude,
            storage: SpiderStorage(siteKey: siteKey, defaults: defaults), session: session
        )
    }
}
