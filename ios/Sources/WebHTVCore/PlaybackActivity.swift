import Foundation

/// IOS-POC-27A — what the player screen shows about playback, when a start counts as stuck, and
/// what a stuck native start is reported as. Plain values in and out, so `swift test` covers every
/// combination without a player.

// MARK: - The bar's play/pause button and the spinner

/// **Intent, not activity.** An engine's `rate` is what the viewer asked for: non-zero while playing
/// *or while waiting for data*, zero once paused (`AVPlayer.h`'s `rate`; MPV reports zero only when
/// paused). The button used to follow `isPlaying`, so a stall showed ▶, pressing it changed nothing,
/// and pause could not be reached at all — while AVPlayer accepts `pause()` in any state.
public struct PlaybackActivity: Sendable, Equatable {
    /// The button shows pause, and pauses, while the viewer means it to play.
    public let showsPause: Bool
    /// Something is on its way: the viewer means it to play, the engine is preparing or waiting for
    /// data, and nothing has failed — a failure has its own message, which a spinner must not cover.
    public let showsSpinner: Bool

    public init(state: PlaybackEngineState, rate: Float, failed: Bool) {
        let intends = rate != 0 && state != .idle
        showsPause = intends
        showsSpinner = intends && !failed && (state == .preparing || state == .buffering)
    }
}

// MARK: - The startup watch's clock

/// IOS-POC-17F's startup watch, counting **only the time the viewer means it to play**.
///
/// The watch hands a start that never comes to the other engine, and the other engine starts playing.
/// Counted from the moment the engine was handed the item, a viewer who paused a slow start was
/// switched and played anyway (IOS-POC-12 G20), and a paused item that sat longer than the timeout
/// was switched the instant play was pressed. Now a pause stops the clock and play starts it again
/// from zero.
///
/// Seconds are the caller's monotonic clock; nothing here reads the time.
public struct PlaybackStartupWatch: Sendable, Equatable {
    /// When the current stretch of intended playback began, if one is running.
    public private(set) var since: Double?
    /// Whether this engine's start has already been given up on. Checked once per engine: the
    /// hand-off that follows restarts the watch for the engine taking over.
    public private(set) var fired = false

    public init() {}

    /// The engine was handed the item — a load, or another engine taking over.
    public mutating func restart(at now: Double) {
        since = now
        fired = false
    }

    /// One tick of the watch. True, once, when the engine has been preparing or waiting for data for
    /// `timeout` seconds of intended playback.
    public mutating func timedOut(now: Double, intends: Bool, stuck: Bool, timeout: Double) -> Bool {
        guard !fired else { return false }
        guard intends else {
            since = nil
            return false
        }
        guard let since else {
            self.since = now
            return false
        }
        guard stuck, now - since > timeout else { return false }
        fired = true
        return true
    }
}

// MARK: - Why a native start was given up on

/// What the player screen says when AVPlayer's start is handed to MPV (IOS-POC-27A), from the
/// evidence the item still holds at that moment. The app target reads AVFoundation; this only
/// decides which evidence wins and how it is worded.
public enum PlaybackStartupReason: Sendable, Equatable {
    /// The item's error log holds an HTTP error status — the clearest evidence there is.
    case http(Int)
    /// The item never became ready to play.
    case neverReady
    /// Ready, and waiting because playing at this speed would likely stall (`toMinimizeStalls`).
    case tooSlow
    /// Ready, and still measuring whether it can keep up (`evaluatingBufferingRate`).
    case evaluating
    case unknown

    public init(httpStatus: Int?, ready: Bool, tooSlow: Bool, evaluating: Bool) {
        if let httpStatus, (400...599).contains(httpStatus) { self = .http(httpStatus) }
        else if !ready { self = .neverReady }
        else if tooSlow { self = .tooSlow }
        else if evaluating { self = .evaluating }
        else { self = .unknown }
    }

    /// One line for the player screen, e.g. 「原生播放器無法開始播放（伺服器回應 403），已改用 MPV」.
    public func notice(from: PlaybackEngineKind, to: PlaybackEngineKind) -> String {
        let why: String
        switch self {
        case .http(let status): why = "伺服器回應 \(status)"
        case .neverReady: why = "影片一直沒有準備好"
        case .tooSlow: why = "資料下載太慢"
        case .evaluating: why = "仍在評估網速"
        case .unknown: why = "沒有開始播放"
        }
        return "\(from.displayName)無法開始播放（\(why)），已改用 \(to.shortName)"
    }
}

// MARK: - What a diagnostic line may carry

/// IOS-POC-27A. The `[playback]` lines are `.public`, so what goes into them is decided here: a
/// media address carries its tokens in the path and the query, and an error comment is free text.
public enum PlaybackLogRedaction {
    /// Host and path extension only — `cdn.example.com .m3u8`. No scheme, credentials, path, query
    /// or fragment.
    public static func urlSummary(_ string: String?) -> String {
        guard let string, let url = URL(string: string), let host = url.host, !host.isEmpty
        else { return "none" }
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? host : "\(host) .\(ext)"
    }

    /// A free-text comment on one line, cut to `limit` characters.
    public static func comment(_ text: String?, limit: Int = 80) -> String {
        guard let text, !text.isEmpty else { return "none" }
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }
}
