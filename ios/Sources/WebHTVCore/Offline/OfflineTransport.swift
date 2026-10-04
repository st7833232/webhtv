import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// IOS-POC-47 — names one transfer: which asset, under which generation, which unit. Written into
/// the task's description, so a background task the system hands back after a relaunch still says
/// what it was for — and a stale one (an older generation, a deleted asset) is recognised as such.
public struct OfflineTransferTag: Hashable, Codable, Sendable, CustomStringConvertible {
    public let assetID: String
    public let generation: Int
    public let unit: Int

    public init(assetID: String, generation: Int, unit: Int) {
        self.assetID = assetID
        self.generation = generation
        self.unit = unit
    }

    public var description: String { "\(assetID)|\(generation)|\(unit)" }

    public init?(description: String?) {
        guard let parts = description?.split(separator: "|"), parts.count == 3,
              let generation = Int(parts[1]), let unit = Int(parts[2]) else { return nil }
        assetID = String(parts[0])
        self.generation = generation
        self.unit = unit
    }
}

public struct OfflineTransferRequest: Sendable, Equatable {
    public let tag: OfflineTransferTag
    public let url: URL
    /// Already filtered for this URL (`OfflineRequestPolicy`).
    public let headers: [String: String]
    public let byteRange: HLSByteRange?
    public let allowsCellular: Bool
    /// Carries headers meant only for the stream's origin. Such a transfer must not follow a
    /// redirect blindly, and a background session cannot be asked (Apple: its tasks "automatically
    /// follow redirects"), so the transport runs it where redirects can be inspected.
    public let credentialed: Bool
    /// The origin those headers belong to, for the redirect check.
    public let origin: URL
    public let resumeData: Data?
    /// A single large file: report bytes as they arrive.
    public let reportsProgress: Bool

    public init(tag: OfflineTransferTag, url: URL, headers: [String: String], byteRange: HLSByteRange?,
                allowsCellular: Bool, credentialed: Bool, origin: URL, resumeData: Data?, reportsProgress: Bool) {
        self.tag = tag
        self.url = url
        self.headers = headers
        self.byteRange = byteRange
        self.allowsCellular = allowsCellular
        self.credentialed = credentialed
        self.origin = origin
        self.resumeData = resumeData
        self.reportsProgress = reportsProgress
    }

    public var urlRequest: URLRequest {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let byteRange { request.setValue(byteRange.httpHeader, forHTTPHeaderField: "Range") }
        request.allowsCellularAccess = allowsCellular
        return request
    }
}

public enum OfflineTransferEvent: Sendable {
    case progress(written: Int64, expected: Int64?)
    /// The body is at `file`, in the staging directory; the receiver moves or deletes it.
    case finished(file: URL, status: Int)
    case failed(OfflineTransferFailure)
}

public struct OfflineTransferFailure: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case network(String)
        case http(Int)
        case cancelled
        case noSpace
    }

    public let kind: Kind
    public let resumeData: Data?

    public init(_ kind: Kind, resumeData: Data? = nil) {
        self.kind = kind
        self.resumeData = resumeData
    }
}

/// Moves bytes. The real one is a background `URLSession` (`URLSessionOfflineTransport`); tests use
/// a fake. It knows nothing about assets beyond the tag.
public protocol OfflineTransport: Sendable {
    /// Where finished transfers are reported.
    func attach(_ sink: @escaping @Sendable (OfflineTransferTag, OfflineTransferEvent) async -> Void) async
    func submit(_ requests: [OfflineTransferRequest]) async
    /// Cancels every transfer of an asset. With `producingResumeData`, answers what a resumable
    /// transfer left to continue from.
    func cancel(assetID: String, producingResumeData: Bool) async -> [OfflineTransferTag: Data]
    /// Transfers still alive, including the ones a background session reconnected after a relaunch.
    func activeTags() async -> Set<OfflineTransferTag>
}

/// Which of a source's headers go to which address — the rule the source's subtitles already use
/// (`SourceSubtitleProvider.forwarded`): User-Agent and Referer anywhere, everything else (Cookie,
/// Authorization, tokens) only to the stream's own origin, never from https down to http.
public enum OfflineRequestPolicy {
    public static func headers(_ headers: [String: String], for url: URL, origin: URL) -> [String: String] {
        Dictionary(SourceSubtitleProvider.forwarded(headers, to: url, media: origin), uniquingKeysWith: { first, _ in first })
    }

    /// Whether the forwarded set holds anything beyond User-Agent and Referer.
    public static func isCredentialed(_ forwarded: [String: String]) -> Bool {
        forwarded.keys.contains { !SourceSubtitleProvider.anyHost.contains($0.lowercased()) }
    }

    /// The headers to keep when a credentialed transfer is redirected to `url`.
    public static func redirected(_ original: [String: String], to url: URL, origin: URL) -> [String: String] {
        headers(original, for: url, origin: origin)
    }
}

/// Fetches a playlist or probes a progressive file in the foreground. Injected so the manager can
/// be tested without a network.
public typealias OfflineFetch = @Sendable (URLRequest) async throws -> (data: Data, status: Int, url: URL?, headers: [String: String])

public enum OfflineHTTP {
    /// Playlists are small; anything larger is not one.
    public static let playlistLimit = 8 * 1024 * 1024

    /// URLSession with redirects checked the way a credentialed transfer's are.
    public static func fetcher(origin: URL, originalHeaders: [String: String]) -> OfflineFetch {
        { request in
            let delegate = RedirectPolicy(origin: origin, headers: originalHeaders)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            var headers = [String: String]()
            for (key, value) in http?.allHeaderFields ?? [:] {
                if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
            }
            return (data, http?.statusCode ?? 200, response.url, headers)
        }
    }

    final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let origin: URL
        let headers: [String: String]

        init(origin: URL, headers: [String: String]) {
            self.origin = origin
            self.headers = headers
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(OfflineHTTP.redirect(request, headers: headers, origin: origin))
        }
    }

    /// A redirect keeps only the headers its new address may have; the ones it may not are
    /// removed, not just left unset.
    static func redirect(_ request: URLRequest, headers: [String: String], origin: URL) -> URLRequest {
        guard let url = request.url else { return request }
        var redirected = request
        let allowed = OfflineRequestPolicy.redirected(headers, to: url, origin: origin)
        for name in headers.keys where allowed[name] == nil {
            redirected.setValue(nil, forHTTPHeaderField: name)
        }
        for (name, value) in allowed { redirected.setValue(value, forHTTPHeaderField: name) }
        return redirected
    }
}
