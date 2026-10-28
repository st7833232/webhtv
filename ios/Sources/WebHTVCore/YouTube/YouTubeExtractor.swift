import Foundation

/// W-212 (design: docs/W-209-ios-youtube-native-design.md §10): plays a YouTube video the way FongMi's
/// NewPipe-based extractor does — ask YouTube's InnerTube API as its visionOS app — and opens the HLS it
/// returns. Only when the user plays; nothing is stored. No PO Token, no account, no content-check flags,
/// no signature or `n` solving: a video that needs any of them stops with a message (§10.6).
public actor YouTubeExtractor {
    public static let shared = YouTubeExtractor()
    /// Settings toggle; on unless the user turned it off. Off, YouTube addresses go back to page sniffing.
    public static let enabledKey = "youtubeExtractorEnabled"

    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Set while the next episode is resolved ahead of time: YouTube is only asked when the user plays.
    @TaskLocal public static var prefetching = false

    // NewPipe Extractor v0.26.5 ClientsConstants: when YouTube refuses this client, update all four together.
    static let clientVersion = "1.02"
    static let deviceModel = "RealityDevice14,1"
    static let osVersion = "25.6.0.23O471"
    static let userAgent = "com.google.visionos.youtube/1.02(RealityDevice14,1; U; CPU visionOS 25_6_0 like Mac OS X; TW)"
    static let cooldown: TimeInterval = 600

    public typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let send: Send
    private let now: @Sendable () -> Date
    private var visitorData: String?
    private var coolingUntil: Date?

    public init(send: Send? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.send = send ?? { request in
            let (data, response) = try await URLSession.webHTV.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw YouTubeError.badResponse }
            return (data, http)
        }
        self.now = now
    }

    /// The address to play for `videoID`: the HLS master, else the best single-file stream. A stop carries
    /// the video so the player can offer it to the YouTube app (W-217).
    public func stream(videoID: String) async throws -> URL {
        do {
            if let coolingUntil, now() < coolingUntil { throw YouTubeError.rateLimited }
            let visitor = try await visitor()
            var body = Self.context(visitorData: visitor)
            body["videoId"] = videoID
            body["cpn"] = Self.random(16)
            let url = URL(string: "https://youtubei.googleapis.com/youtubei/v1/player?prettyPrint=false&t=\(Self.random(12))&id=\(videoID)")!
            return try Self.stream(fromPlayerResponse: try await post(url, body))
        } catch let error as YouTubeError {
            throw YouTubeStopped(reason: error, videoID: videoID)
        }
    }

    /// Reads a player response. Internal so tests can feed recorded replies.
    static func stream(fromPlayerResponse data: Data) throws -> URL {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw YouTubeError.badResponse }
        let playability = json["playabilityStatus"] as? [String: Any] ?? [:]
        let status = playability["status"] as? String ?? ""
        if status != "OK" { throw YouTubeError(status: status, reason: playability["reason"] as? String ?? "") }
        let streaming = json["streamingData"] as? [String: Any] ?? [:]
        if let hls = streaming["hlsManifestUrl"] as? String, let url = URL(string: hls) { return url }
        // No HLS: a single file carrying both picture and sound. Split adaptive streams are not merged here.
        let single = (streaming["formats"] as? [[String: Any]] ?? [])
            .compactMap { format -> (height: Int, url: URL)? in
                guard let address = format["url"] as? String, let url = URL(string: address) else { return nil }
                return (format["height"] as? Int ?? 0, url)
            }
            .max { $0.height < $1.height }
        guard let single else { throw YouTubeError.noStream }
        return single.url
    }

    private func visitor() async throws -> String {
        if let visitorData { return visitorData }
        let reply = try await post(URL(string: "https://www.youtube.com/youtubei/v1/visitor_id?prettyPrint=false")!,
                                   Self.context(visitorData: nil))
        guard let json = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let value = (json["responseContext"] as? [String: Any])?["visitorData"] as? String, !value.isEmpty
        else { throw YouTubeError.badResponse }
        visitorData = value
        return value
    }

    private func post(_ url: URL, _ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("2", forHTTPHeaderField: "X-Goog-Api-Format-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await send(request)
        if response.statusCode == 429 {
            // Wait it out; never another client, address or proxy (§10.6).
            coolingUntil = now().addingTimeInterval(Self.cooldown)
            throw YouTubeError.rateLimited
        }
        guard response.statusCode == 200 else { throw YouTubeError.badResponse }
        return data
    }

    /// NewPipe's `prepareJsonBuilder` for the visionOS client. `contentCheckOk`/`racyCheckOk` are left out
    /// on purpose: they skip YouTube's content warnings (§10.4).
    static func context(visitorData: String?) -> [String: Any] {
        var client: [String: Any] = [
            "clientName": "VISIONOS", "clientVersion": clientVersion, "clientScreen": "WATCH", "platform": "MOBILE",
            "deviceMake": "Apple", "deviceModel": deviceModel, "osName": "visionOS", "osVersion": osVersion,
            "hl": "zh-TW", "gl": "TW", "utcOffsetMinutes": TimeZone.current.secondsFromGMT() / 60,
        ]
        if let visitorData { client["visitorData"] = visitorData }
        return ["context": ["client": client,
                            "request": ["internalExperimentFlags": [] as [Any], "useSsl": true],
                            "user": ["lockedSafetyMode": false]]]
    }

    private static func random(_ count: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<count).map { _ in alphabet.randomElement()! })
    }
}

/// Why a YouTube video did not play here, and where it can be watched instead.
public struct YouTubeStopped: LocalizedError, Equatable {
    public let reason: YouTubeError
    public let videoID: String

    /// Opens in the YouTube app when installed (universal link), else in Safari.
    public var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(videoID)")! }
    public var errorDescription: String? { reason.errorDescription }
}

public enum YouTubeError: LocalizedError, Equatable {
    case verificationRequired, ageRestricted, contentCheckRequired, membersOnly, rateLimited, noStream, badResponse
    case unplayable(String)

    /// A playability status other than OK. Age, content warnings and verification all stop here; none is retried.
    init(status: String, reason: String) {
        let text = reason.lowercased()
        if status.hasPrefix("AGE_") || ["your age", "age-restricted", "age restricted"].contains(where: text.contains) {
            self = .ageRestricted
        } else if status == "CONTENT_CHECK_REQUIRED" || text.contains("content warning") || text.contains("inappropriate") {
            self = .contentCheckRequired
        } else if status == "LOGIN_REQUIRED" || text.contains("bot") || text.contains("sign in") {
            self = .verificationRequired
        } else if text.contains("member") || text.contains("purchase") {
            self = .membersOnly
        } else {
            self = .unplayable(reason)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .verificationRequired: "YouTube 要求驗證，暫時無法在 App 內播放，請用 YouTube App 開啟。"
        case .ageRestricted: "這部影片有年齡限制，App 內不播放，請用 YouTube App 開啟。"
        case .contentCheckRequired: "這部影片需要在 YouTube 確認內容警告，請用 YouTube App 開啟。"
        case .membersOnly: "這部影片限會員或付費觀看，App 內不播放。"
        case .rateLimited: "YouTube 暫時限制了請求，請稍後再試。"
        case .noStream: "YouTube 沒有提供這部影片可直接播放的串流。"
        case .badResponse: "YouTube 回應無法解析，請稍後再試。"
        case .unplayable(let reason): reason.isEmpty ? "YouTube 表示這部影片無法播放。" : "YouTube：\(reason)"
        }
    }
}
