import Foundation

/// Why a live list could not be fetched, worded without its address or headers (D§6.7): a list address can carry
/// a token such as `sid=`.
public enum LiveListError: Error, Equatable, LocalizedError {
    case badAddress
    case httpStatus(Int)
    case timedOut
    case unreachable
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .badAddress: "直播源網址無效"
        case .httpStatus(let code): "HTTP \(code)"
        case .timedOut: "逾時"
        case .unreachable: "無法連線"
        case .tooLarge: "清單太大"
        }
    }
}

/// Fetches and parses a live source's list (IOS-POC-59 U2). Android's list task has one 30-second limit for the whole
/// fetch (`LiveViewModel.java:115`, `Constant.TIMEOUT_LIVE`), so this has one deadline too, not the configuration
/// session's 10-second idle timeout. A list is kept in memory until refreshed.
public actor LiveListLoader {
    public static let shared = LiveListLoader()
    /// Like `HLSAdSkip.maximumPlaylistBytes`; the largest W-92 list is about 800 KB.
    public static let maximumBytes = 8 << 20

    private let session: URLSession
    private let limit: TimeInterval
    private var cache: [String: LivePlaylist] = [:]

    public init(configuration: URLSessionConfiguration = .ephemeral, limit: TimeInterval = 30) {
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        self.limit = limit
    }

    /// `base` is the configuration's own address, for a `./` or `../` list (Android rewrites those in the JSON text,
    /// `Decoder.java:42-48`). It is not `ConfigSource.resourceURL`: that cuts at the first `;`, which a list may have.
    public func playlist(for source: LiveSource, base: URL?, refresh: Bool = false) async throws -> LivePlaylist {
        guard let url = Self.address(source.url, base: base) else { throw LiveListError.badAddress }
        let headers = source.listHeaders
        let pairs: [String] = headers.keys.sorted().map { "\($0)=\(headers[$0] ?? "")" }
        let key = ([url.absoluteString] + pairs).joined(separator: "\n")
        if !refresh, let cached = cache[key] { return cached }
        var request = URLRequest(url: url, timeoutInterval: limit)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let data = try await fetch(request)
        let playlist = try LivePlaylistParser.parse(data, source: source)
        cache[key] = playlist
        return playlist
    }

    static func address(_ text: String, base: URL?) -> URL? {
        if text.hasPrefix("./") || text.hasPrefix("../") {
            return base.flatMap { URL(string: text, relativeTo: $0)?.absoluteURL }
        }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        let session = session, limit = limit
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                do {
                    let (data, response) = try await session.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else { throw LiveListError.httpStatus(status) }
                    guard data.count <= Self.maximumBytes else { throw LiveListError.tooLarge }
                    return data
                } catch let error as URLError {
                    throw error.code == .timedOut ? LiveListError.timedOut : LiveListError.unreachable
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(limit))
                throw LiveListError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
