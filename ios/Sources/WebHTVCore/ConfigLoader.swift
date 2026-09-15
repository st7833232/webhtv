import Foundation

public enum ConfigLoaderError: Error, Equatable {
    case invalidHTTPStatus(Int)
}

public enum ConfigLoader {
    public static func decode(_ data: Data) throws -> WebHTVConfig {
        try JSONDecoder().decode(WebHTVConfig.self, from: data)
    }

    public static func load(from url: URL) async throws -> WebHTVConfig {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            throw ConfigLoaderError.invalidHTTPStatus(response.statusCode)
        }
        return try decode(data)
    }
}
