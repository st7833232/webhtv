import Foundation

/// W-212: which addresses are YouTube videos, and the 11-character id in them.
public enum YouTubeURL {
    /// youtube.com, youtu.be, youtube-nocookie.com and their subdomains. The live playlist parser uses
    /// the same rule to mark YouTube lines unsupported.
    public static func isYouTubeHost(_ host: String) -> Bool {
        let name = host.lowercased()
        return ["youtube.com", "youtu.be", "youtube-nocookie.com"].contains { name == $0 || name.hasSuffix("." + $0) }
    }

    /// An address a YouTube video plays from: its own pages, googlevideo.com (the HLS and files), or a Python
    /// spider's DASH proxy for one (W-217: with the switch off, YouTube｜PY still plays through that proxy).
    public static func isYouTubeStream(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return isYouTubeHost(host) || host == "googlevideo.com" || host.hasSuffix(".googlevideo.com")
            || proxiedVideoID(in: url) != nil
    }

    /// The video a Python spider's own DASH proxy address names (`…/proxy?do=py&type=mpd&vid=<id>`, YouTube｜PY):
    /// that route is read-capped by googlevideo after about a minute (W-202), so the video plays from YouTube's
    /// HLS instead. Only call it for an address the spider proxy serves.
    public static func proxiedVideoID(in url: URL) -> String? {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        guard value("do") == "py", value("type") == "mpd", let id = value("vid"), isVideoID(id) else { return nil }
        return id
    }

    /// The video id of `/watch?v=`, `/embed/`, `/shorts/`, `/live/`, `/v/` and `youtu.be/` addresses; nil for
    /// anything else, googlevideo.com included.
    public static func videoID(in url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, isYouTubeHost(host) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        let candidate: String?
        if host.lowercased().hasSuffix("youtu.be") {
            candidate = parts.first
        } else if parts.first == "watch" {
            candidate = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "v" }?.value
        } else if parts.count >= 2, ["embed", "shorts", "live", "v"].contains(parts[0]) {
            candidate = parts[1]
        } else {
            candidate = nil
        }
        guard let id = candidate, isVideoID(id) else { return nil }
        return id
    }

    private static func isVideoID(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
