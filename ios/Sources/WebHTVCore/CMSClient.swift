import Foundation

public struct CMSResponse: Decodable, Sendable {
    public let classes: [CMSCategory]
    public let list: [Vod]
    /// Per-category filter rows, keyed by `type_id`, exactly as CatVod publishes them. Empty for
    /// every MacCMS source: the protocol has no filter call, so only spiders whose API exposes one
    /// (`AppGet`'s `filter_type_list`) ever fill this.
    public let filters: [String: [CMSFilter]]

    enum CodingKeys: String, CodingKey {
        case classes = "class"
        case list
        case filters
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        classes = try values.decodeIfPresent([CMSCategory].self, forKey: .classes) ?? []
        list = try values.decodeIfPresent([Vod].self, forKey: .list) ?? []
        filters = try values.decodeIfPresent([String: [CMSFilter]].self, forKey: .filters) ?? [:]
    }

    /// MacCMS `class` is at most a two-level tree. Grouping keeps the parent names a flat leaf list
    /// would throw away. Sites that omit `type_pid` — every type-4 source, and some type-1 ones such
    /// as 天涯 — come back as childless groups, which render as a single row.
    public var categoryGroups: [CategoryGroup] {
        let children = classes.filter { $0.parentID != 0 }
        guard !children.isEmpty else { return classes.map { CategoryGroup(parent: $0, children: []) } }
        let byParent = Dictionary(grouping: children, by: \.parentID)
        return classes.filter { $0.parentID == 0 }.map {
            CategoryGroup(parent: $0, children: byParent[Int($0.id) ?? 0] ?? [])
        }
    }

    /// The category a caller should list first. A parent with no children lists by its own id —
    /// 360zy's 伦理片 and 如意's 电影解说 both return titles that way.
    public var firstListableCategory: CMSCategory? {
        guard let group = categoryGroups.first else { return nil }
        return group.children.first ?? group.parent
    }

    init(classes: [CMSCategory], list: [Vod], filters: [String: [CMSFilter]] = [:]) {
        self.classes = classes
        self.list = list
        self.filters = filters
    }
}

/// One row of filter chips — CatVod's `{key, name, value: [{n, v}]}`.
///
/// `key` is what `categoryContent`'s `extend` is keyed by, so it travels back to the spider
/// unchanged; `name` is only ever shown to the user.
public struct CMSFilter: Decodable, Identifiable, Sendable {
    public let key: String
    public let name: String
    public let options: [Option]

    public struct Option: Decodable, Identifiable, Sendable {
        /// Display name; CatVod calls it `n`.
        public let name: String
        /// The value sent back in `extend`; CatVod calls it `v`. Empty means "no constraint".
        public let value: String

        public var id: String { value }

        enum CodingKeys: String, CodingKey { case name = "n", value = "v" }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            // Both halves are strings in practice, but a year filter sometimes ships numbers.
            name = (try? values.decodeString(forKey: .name)) ?? ""
            value = (try? values.decodeString(forKey: .value)) ?? ""
        }

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public var id: String { key }

    enum CodingKeys: String, CodingKey { case key, name, value }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decodeIfPresent(String.self, forKey: .key) ?? ""
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        options = try values.decodeIfPresent([Option].self, forKey: .value) ?? []
    }

    public init(key: String, name: String, options: [Option]) {
        self.key = key
        self.name = name
        self.options = options
    }
}

public struct CategoryGroup: Identifiable, Sendable {
    public let parent: CMSCategory
    public let children: [CMSCategory]

    public var id: String { parent.id }
}

public struct CMSCategory: Decodable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let parentID: Int

    enum CodingKeys: String, CodingKey {
        case id = "type_id"
        case name = "type_name"
        case parentID = "type_pid"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeString(forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        parentID = Int((try? values.decodeString(forKey: .parentID)) ?? "0") ?? 0
    }

    /// MacCMS XML carries `<ty id="1">名稱</ty>`, which has no parent, so these decode as top level.
    init(id: String, name: String, parentID: Int) {
        self.id = id
        self.name = name
        self.parentID = parentID
    }
}

public struct Vod: Decodable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let picture: String
    public let remarks: String
    public let playFrom: String
    public let playURL: String

    enum CodingKeys: String, CodingKey {
        case id = "vod_id"
        case name = "vod_name"
        case picture = "vod_pic"
        case remarks = "vod_remarks"
        case playFrom = "vod_play_from"
        case playURL = "vod_play_url"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // A detail response may carry only the playback fields, so identity is optional here.
        id = (try? values.decodeString(forKey: .id)) ?? ""
        name = (try? values.decode(String.self, forKey: .name)) ?? ""
        picture = try values.decodeIfPresent(String.self, forKey: .picture) ?? ""
        remarks = try values.decodeIfPresent(String.self, forKey: .remarks) ?? ""
        playFrom = try values.decodeIfPresent(String.self, forKey: .playFrom) ?? ""
        playURL = try values.decodeIfPresent(String.self, forKey: .playURL) ?? ""
    }

    /// Built rather than decoded: `player.playVod` names a vod by id, and the MacCMS XML decoder
    /// assembles one from parsed elements. The playback fields default to empty because `playVod`
    /// has none — `VodView` fetches the real detail by id — while the XML decoder passes all three.
    public init(
        id: String, name: String, picture: String,
        remarks: String = "", playFrom: String = "", playURL: String = ""
    ) {
        self.id = id
        self.name = name
        self.picture = picture
        self.remarks = remarks
        self.playFrom = playFrom
        self.playURL = playURL
    }

    public var flags: [Flag] {
        zip(playFrom.components(separatedBy: "$$$"), playURL.components(separatedBy: "$$$"))
            .filter { !$0.0.isEmpty && !$0.1.isEmpty }
            .map { Flag(name: $0.0, episodes: Episode.parse($0.1)) }
    }
}

public extension Array where Element == Vod {
    /// Pagination stops when a page adds nothing. That covers both the end of a list and a source
    /// that ignores `pg` and keeps returning the same page — `爱瓜TV` reports pagecount 9999 and
    /// total 999999, so the page metadata cannot be used as the stop signal.
    func merging(newTitlesFrom page: [Vod]) -> [Vod] {
        let known = Set(map(\.id))
        return self + page.filter { !known.contains($0.id) }
    }
}

public struct Flag: Equatable, Sendable {
    public let name: String
    public let episodes: [Episode]
}

public struct Episode: Equatable, Sendable {
    public let name: String
    public let url: String

    public var mediaURL: URL? {
        guard let value = URL(string: url), value.scheme == "http" || value.scheme == "https" else { return nil }
        return value
    }

    static func parse(_ value: String) -> [Episode] {
        split(value).enumerated().map { index, item in
            let parts = item.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
            return Episode(
                name: parts.count == 2 && !parts[0].isEmpty ? String(parts[0]).trimmingCharacters(in: .whitespaces) : String(format: "%02d", index + 1),
                url: String(parts.last ?? "")
            )
        }
    }

    private static func split(_ value: String) -> [String] {
        var result = [String]()
        var start = value.startIndex
        var depth = 0
        for index in value.indices {
            switch value[index] {
            case "[", "(", "（", "【", "《": depth += 1
            case "]", ")", "）", "】", "》": depth = max(0, depth - 1)
            case "#" where depth == 0:
                result.append(String(value[start..<index]))
                start = value.index(after: index)
            default: break
            }
        }
        if start < value.endIndex { result.append(String(value[start...])) }
        return result
    }
}

struct PlayResponse: Decodable, Sendable {
    let url: String
}

public enum CMSClientError: Error, Equatable {
    case unsupportedSiteType(Int)
    case invalidURL
    case invalidHTTPStatus(Int)
}

public struct CMSClient: Sendable {
    public let site: Site

    public init(site: Site) throws {
        guard site.type == 0 || site.type == 1 || site.type == 4 else { throw CMSClientError.unsupportedSiteType(site.type) }
        self.site = site
    }

    public func home(page: Int = 1) async throws -> CMSResponse {
        guard site.type == 4 else {
            // The ac=detail form is the only one carrying vod_pic, but it drops `class`, so the
            // categories come from a concurrent plain request rather than a second round trip.
            async let categories = request([])
            async let listing = request(listingQuery(categoryID: nil, page: page))
            return CMSResponse(classes: try await categories.classes, list: try await listing.list)
        }
        // A type-4 home returns categories without titles, so the first category fills the poster grid.
        let categories = try await request([URLQueryItem(name: "filter", value: "true")])
        // Match what the caller will offer for browsing, so the listed category is the highlighted one.
        guard let first = categories.firstListableCategory else { return categories }
        let listing = try await category(id: first.id, page: page)
        return CMSResponse(classes: categories.classes, list: listing.list)
    }

    /// Both type-1 and type-4 list a category with the same `t=` / `pg=` contract.
    public func category(id: String, page: Int = 1) async throws -> CMSResponse {
        try await request(listingQuery(categoryID: id, page: page))
    }

    /// `SiteApi.ac(int)`: XML sites want `videolist`, everything else `detail`. Both configured
    /// type-0 endpoints also accept `detail`, but `videolist` is what Android sends.
    var detailAction: String { site.type == 0 ? "videolist" : "detail" }

    /// A MacCMS listing omits the picture unless the detailed form is asked for, which is why type-1
    /// posters were blank; a type-4 listing already carries it, so it is left alone. type-0 has the
    /// same split — the detailed form carries `<pic>` and drops `<class>`.
    func listingQuery(categoryID: String?, page: Int) -> [URLQueryItem] {
        var query = [URLQueryItem]()
        if site.type == 0 || site.type == 1 { query.append(URLQueryItem(name: "ac", value: detailAction)) }
        if let categoryID { query.append(URLQueryItem(name: "t", value: categoryID)) }
        if categoryID != nil || page > 1 { query.append(URLQueryItem(name: "pg", value: String(page))) }
        return query
    }

    /// A type-4 episode may address a web page instead of media; `?play=` returns the playable URL.
    public func playbackURL(for episode: Episode, flag: String) async throws -> URL? {
        guard let direct = episode.mediaURL else { return nil }
        guard site.type == 4, !Self.isDirectMedia(direct) else { return direct }
        let data = try await data(for: [URLQueryItem(name: "play", value: episode.url), URLQueryItem(name: "flag", value: flag)])
        guard let resolved = try? JSONDecoder().decode(PlayResponse.self, from: data) else { return nil }
        return URL(string: resolved.url)
    }

    // ponytail: path-extension heuristic; probe the content type only if a real site needs it.
    static func isDirectMedia(_ url: URL) -> Bool {
        ["m3u8", "mp4", "flv", "mkv", "ts", "mov"].contains(url.pathExtension.lowercased())
    }

    public func search(_ keyword: String, page: Int = 1) async throws -> CMSResponse {
        var query = [URLQueryItem(name: "wd", value: keyword), URLQueryItem(name: "quick", value: "false"), URLQueryItem(name: "extend", value: "")]
        if site.type == 0 || site.type == 1 { query.append(URLQueryItem(name: "ac", value: detailAction)) }
        if page > 1 { query.append(URLQueryItem(name: "pg", value: String(page))) }
        return try await request(query)
    }

    public func detail(id: String) async throws -> Vod? {
        try await request([URLQueryItem(name: "ac", value: detailAction), URLQueryItem(name: "ids", value: id)]).list.first
    }

    func requestURL(_ query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(string: site.api) else { throw CMSClientError.invalidURL }
        let added = query + (site.ext ?? [:]).map { URLQueryItem(name: $0.key, value: $0.value) }.sorted { $0.name < $1.name }
        let names = Set(added.map(\.name))
        components.queryItems = (components.queryItems ?? []).filter { !names.contains($0.name) } + added
        guard let url = components.url else { throw CMSClientError.invalidURL }
        return url
    }

    private func data(for query: [URLQueryItem]) async throws -> Data {
        let url = try requestURL(query)
        let (data, response) = try await URLSession.webHTV.data(from: url)
        if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            throw CMSClientError.invalidHTTPStatus(response.statusCode)
        }
        return data
    }

    private func request(_ query: [URLQueryItem]) async throws -> CMSResponse {
        let data = try await data(for: query)
        // The only structural difference between type-0 and the rest: the payload is XML.
        guard site.type != 0 else { return MacCMSXMLDecoder.decode(data) }
        return try JSONDecoder().decode(CMSResponse.self, from: data)
    }
}

private extension KeyedDecodingContainer {
    func decodeString(forKey key: Key) throws -> String {
        if let value = try? decode(String.self, forKey: key) { return value }
        return String(try decode(Int.self, forKey: key))
    }
}
