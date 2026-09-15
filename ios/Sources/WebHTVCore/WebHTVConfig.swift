import Foundation

public struct WebHTVConfig: Decodable, Sendable {
    public let sites: [Site]

    public var nativeCMSSites: [Site] {
        sites.filter(\.isNativeCMS)
    }

}

public struct Site: Decodable, Identifiable, Sendable {
    public let key: String
    public let name: String
    public let type: Int
    public let api: String

    public var id: String { key }

    public var isNativeCMS: Bool {
        guard type == 0 || type == 1, let scheme = URL(string: api)?.scheme else { return false }
        return scheme == "http" || scheme == "https"
    }
}
