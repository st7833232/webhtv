import Foundation

public struct CMSResponse: Decodable, Sendable {
    public let classes: [CMSCategory]
    public let list: [Vod]

    enum CodingKeys: String, CodingKey {
        case classes = "class"
        case list
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        classes = try values.decodeIfPresent([CMSCategory].self, forKey: .classes) ?? []
        list = try values.decodeIfPresent([Vod].self, forKey: .list) ?? []
    }
}

public struct CMSCategory: Decodable, Identifiable, Sendable {
    public let id: String
    public let name: String

    enum CodingKeys: String, CodingKey {
        case id = "type_id"
        case name = "type_name"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeString(forKey: .id)
        name = try values.decode(String.self, forKey: .name)
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
        id = try values.decodeString(forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        picture = try values.decodeIfPresent(String.self, forKey: .picture) ?? ""
        remarks = try values.decodeIfPresent(String.self, forKey: .remarks) ?? ""
        playFrom = try values.decodeIfPresent(String.self, forKey: .playFrom) ?? ""
        playURL = try values.decodeIfPresent(String.self, forKey: .playURL) ?? ""
    }

    public var flags: [Flag] {
        zip(playFrom.components(separatedBy: "$$$"), playURL.components(separatedBy: "$$$"))
            .filter { !$0.0.isEmpty && !$0.1.isEmpty }
            .map { Flag(name: $0.0, episodes: Episode.parse($0.1)) }
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

public enum CMSClientError: Error, Equatable {
    case unsupportedSiteType(Int)
    case invalidURL
    case invalidHTTPStatus(Int)
}

public struct CMSClient: Sendable {
    public let site: Site

    public init(site: Site) throws {
        guard site.type == 1 else { throw CMSClientError.unsupportedSiteType(site.type) }
        self.site = site
    }

    public func home() async throws -> CMSResponse {
        try await request([])
    }

    public func search(_ keyword: String, page: Int = 1) async throws -> CMSResponse {
        var query = [URLQueryItem(name: "wd", value: keyword), URLQueryItem(name: "quick", value: "false"), URLQueryItem(name: "extend", value: "")]
        if page > 1 { query.append(URLQueryItem(name: "pg", value: String(page))) }
        return try await request(query)
    }

    public func detail(id: String) async throws -> Vod? {
        try await request([URLQueryItem(name: "ac", value: "detail"), URLQueryItem(name: "ids", value: id)]).list.first
    }

    private func request(_ query: [URLQueryItem]) async throws -> CMSResponse {
        guard var components = URLComponents(string: site.api) else { throw CMSClientError.invalidURL }
        let names = Set(query.map(\.name))
        components.queryItems = (components.queryItems ?? []).filter { !names.contains($0.name) } + query
        guard let url = components.url else { throw CMSClientError.invalidURL }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            throw CMSClientError.invalidHTTPStatus(response.statusCode)
        }
        return try JSONDecoder().decode(CMSResponse.self, from: data)
    }
}

private extension KeyedDecodingContainer {
    func decodeString(forKey key: Key) throws -> String {
        if let value = try? decode(String.self, forKey: key) { return value }
        return String(try decode(Int.self, forKey: key))
    }
}
