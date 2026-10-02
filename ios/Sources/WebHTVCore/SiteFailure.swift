import Foundation

/// IOS-POC-41A: why a site answered nothing, sorted from signals that are certain — a `URLError`
/// code, an HTTP status, Cloudflare's documented `cf-mitigated: challenge` header — plus the page
/// titles of challenge and redirect pages, which are the one heuristic. Anything else stays
/// unexplained rather than guessed at (`docs/IOS-POC-41-source-health-diagnostics.md`).
public enum SiteFailure: Equatable, Sendable {
    case offline
    case hostNotFound
    case timedOut
    case cannotConnect
    case insecureConnection
    /// Cloudflare's bot challenge: it needs a browser running JavaScript, which no spider is.
    case challenge
    case httpStatus(Int)
    /// A 2xx page whose title says it is a challenge or a JavaScript redirect.
    case verificationPage
    /// Any other transport failure, by its `URLError` code.
    case network(Int)

    /// `nil` for a cancelled request, which is the caller's doing, not the site's.
    public init?(error: Error) {
        guard let code = (error as? URLError)?.code else { self = .network(-1); return }
        switch code {
        case .cancelled: return nil
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive: self = .offline
        case .cannotFindHost, .dnsLookupFailed: self = .hostNotFound
        case .timedOut: self = .timedOut
        case .cannotConnectToHost: self = .cannotConnect
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired: self = .insecureConnection
        default: self = .network(code.rawValue)
        }
    }

    /// `nil` when the response is an ordinary page, whatever it contains.
    public init?(status: Int, headers: [String: String], body: String) {
        if headers["cf-mitigated"]?.lowercased() == "challenge" { self = .challenge; return }
        if status >= 400 { self = .httpStatus(status); return }
        guard (200...299).contains(status), Self.isVerificationTitle(body) else { return nil }
        self = .verificationPage
    }

    /// Cloudflare's interstitial, the fingerprinting redirect 29 of `wang-sex.json`'s dead sites
    /// serve, 天天動漫's check, and the 宝塔 pages the original XBPQ itself watches for.
    private static let verificationTitles = ["just a moment", "redirecting", "security check", "检测中", "跳转中"]

    private static func isVerificationTitle(_ body: String) -> Bool {
        guard let start = body.range(of: "<title>", options: .caseInsensitive),
              let end = body.range(of: "</title>", options: .caseInsensitive, range: start.upperBound..<body.endIndex)
        else { return false }
        let title = body[start.upperBound..<end.lowerBound].lowercased()
        return verificationTitles.contains { title.contains($0) }
    }
}

/// A listing came back empty and the request behind it failed: the reason, shown in place of
/// 「沒有內容」.
public struct SiteUnreachable: Error, Equatable, LocalizedError, Sendable {
    public let failure: SiteFailure
    public let host: String

    public init(_ failure: SiteFailure, host: String) {
        self.failure = failure
        self.host = host
    }

    public var errorDescription: String? {
        let reason = switch failure {
        case .offline: "裝置目前沒有網路連線。"
        case .hostNotFound: "找不到網域 \(host)，網域可能已經失效。"
        case .timedOut: "連線 \(host) 逾時。"
        case .cannotConnect: "無法連上 \(host)。"
        case .insecureConnection: "\(host) 的安全連線（TLS）失敗。"
        case .challenge: "\(host) 要求瀏覽器驗證（Cloudflare），App 無法通過。"
        case .httpStatus(let status): "\(host) 回應 HTTP \(status)。"
        case .verificationPage: "\(host) 回傳的是要執行 JavaScript 的驗證或跳轉頁，App 無法通過。"
        case .network(let code): "與 \(host) 的連線失敗（錯誤碼 \(code)）。"
        }
        return isSiteSide ? reason + "這是網站本身或目前網路的問題，不是 App 的錯誤。" : reason
    }

    /// A 4xx other than Cloudflare's challenge may be an address the rule has outdated, and being
    /// offline is the device's; every other case is the site's or the network's.
    private var isSiteSide: Bool {
        switch failure {
        case .offline: false
        case .httpStatus(let status): status >= 500
        default: true
        }
    }
}
