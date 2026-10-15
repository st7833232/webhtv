import Foundation

/// A parsed live list (IOS-POC-59 U1). Hidden groups stay in it: hiding them is the list screen's
/// job, and L2's unlock needs them.
public struct LivePlaylist: Equatable, Sendable {
    public var groups: [LiveGroup]
    /// The m3u header's `x-tvg-url`/`url-tvg`, kept only when the source has no `epg` (L2).
    public var tvgURL: String?
    /// The m3u header's catchup, raw (L2).
    public var catchup: LiveCatchupRaw?

    public init(groups: [LiveGroup], tvgURL: String? = nil, catchup: LiveCatchupRaw? = nil) {
        self.groups = groups
        self.tvgURL = tvgURL
        self.catchup = catchup
    }

    /// Android's `setting_live`, the name of a group that has none.
    public static let defaultGroupName = "直播"
}

public struct LiveGroup: Equatable, Sendable {
    /// Cut at the first `_`, whether or not the source passes the password.
    public var name: String
    /// What followed the `_`, unless the source sets `pass`.
    public var password: String?
    public var channels: [LiveChannel]

    public var isHidden: Bool { password != nil }
}

public struct LiveChannel: Equatable, Sendable {
    public var name: String
    public var lines: [LiveLine]
    public var tvgID: String?
    public var tvgName: String?
    public var logo: String?
    public var catchup: LiveCatchupRaw?

    /// No line iOS can even try: the channel is shown greyed out and skipped when switching.
    public var isUnsupported: Bool { !lines.contains { $0.support.isTried } }
}

public struct LiveLine: Equatable, Sendable {
    /// The address before the first `$`, trimmed.
    public var url: String
    /// The line's name after `$`; nil when there is none.
    public var label: String?
    /// The headers to play it with, inheritance already applied (X-5: per line, not per channel).
    public var headers: [String: String]
    public var support: LineSupport

    public init(url: String, label: String?, headers: [String: String], support: LineSupport) {
        self.url = url
        self.label = label
        self.headers = headers
        self.support = support
    }
}

public enum LineSupport: Equatable, Sendable {
    case playable
    /// rtmp/rtsp: handed to the player and tried, never promised (R-16).
    case attempt
    case unsupported(Reason)

    public enum Reason: Equatable, Sendable {
        case drm, parse, youtube, p2p, sniff, proxy
        /// Any other address with `://` (`abc://`, `ttp://`, `,http://`): Android keeps it (B-2).
        case other
    }

    /// Whether automatic line switching tries it.
    public var isTried: Bool {
        if case .unsupported = self { return false }
        return true
    }
}

public struct LiveCatchupRaw: Equatable, Sendable {
    public var type: String
    public var source: String
    public var replace: String

    public init(type: String, source: String, replace: String) {
        self.type = type
        self.source = source
        self.replace = replace
    }
}
