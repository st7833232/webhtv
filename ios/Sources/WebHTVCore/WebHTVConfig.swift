import Foundation

public struct WebHTVConfig: Decodable, Sendable {
    public let sites: [Site]

    public var nativeCMSSites: [Site] {
        sites.filter(\.isNativeCMS)
    }

    /// The sites this app can actually drive today: type-0 MacCMS XML, type-1 MacCMS JSON and
    /// type-4 CatVod remote APIs. Type-3 Spider entries are classified but not usable.
    public var supportedSites: [Site] {
        nativeCMSSites.filter { $0.type == 0 || $0.type == 1 || $0.type == 4 }
    }

}

public struct Site: Decodable, Identifiable, Sendable {
    public let key: String
    public let name: String
    public let type: Int
    public let api: String
    public let ext: [String: String]?

    enum CodingKeys: String, CodingKey {
        case key, name, type, api, ext
    }

    public var id: String { key }

    public var isNativeCMS: Bool {
        guard type == 0 || type == 1 || type == 4, let scheme = URL(string: api)?.scheme else { return false }
        return scheme == "http" || scheme == "https"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        name = try values.decode(String.self, forKey: .name)
        type = try values.decode(Int.self, forKey: .type)
        api = try values.decode(String.self, forKey: .api)
        // `ext` is a string, a number or absent on most sites; only the dictionary form carries query parameters.
        ext = try? values.decode([String: String].self, forKey: .ext)
    }
}
