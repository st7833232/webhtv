import Foundation

public extension URLSession {
    /// Shared session for every WebHTV API call. The default 60 s inactivity timeout left an
    /// unreachable source hanging the screen, and a type-4 home issues two sequential requests.
    static let webHTV: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()
}

public enum ConfigLoaderError: Error, Equatable {
    case invalidHTTPStatus(Int)
}

public enum ConfigLoader {
    public static func decode(_ data: Data) throws -> WebHTVConfig {
        try JSONDecoder().decode(WebHTVConfig.self, from: data)
    }

    public static func load(from url: URL) async throws -> WebHTVConfig {
        let (data, response) = try await URLSession.webHTV.data(from: url)
        if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            throw ConfigLoaderError.invalidHTTPStatus(response.statusCode)
        }
        return try decode(data)
    }
}
