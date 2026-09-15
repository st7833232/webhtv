import Foundation

public enum ExternalPlayer: String, CaseIterable, Sendable {
    case infuse = "Infuse"
    case fileball = "Fileball"
    case senPlayer = "SenPlayer"
    case vidHub = "VidHub"

    public var displayName: String { rawValue }

    public func playbackURL(for mediaURL: URL) -> URL? {
        var components = URLComponents()
        switch self {
        case .infuse:
            components.scheme = "infuse"
            components.host = "x-callback-url"
            components.path = "/play"
        case .fileball:
            components.scheme = "filebox"
            components.host = "play"
        case .senPlayer:
            components.scheme = "senplayer"
            components.host = "x-callback-url"
            components.path = "/play"
        case .vidHub:
            components.scheme = "open-vidhub"
            components.host = "x-callback-url"
            components.path = "/play"
        }
        components.queryItems = [URLQueryItem(name: "url", value: mediaURL.absoluteString)]
        return components.url
    }
}
