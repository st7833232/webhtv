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

// MARK: - One hand-over per item

/// W-83: AVPlayer can halt a fraction of a second short of the end of a file it buffered only from a
/// late start (an audio episode resumed near its end), then wait for data that never comes, so
/// `didPlayToEndTime` never arrives. A wait that close to a known duration is the end.
public enum PlaybackEndStall {
    /// The halts seen were 0.1 s short of the duration.
    public static let tolerance = 1.0

    /// Whether a player waiting to minimise stalls at `position` is really at the end of `duration`.
    /// A live stream has no finite duration and never counts.
    public static func isAtEnd(waitingToMinimizeStalls: Bool, position: Double, duration: Double) -> Bool {
        waitingToMinimizeStalls && duration.isFinite && duration > 0 && position.isFinite
            && duration - position <= tolerance
    }
}

/// IOS-POC-36 — an item moves on to what comes next once. Two things end an item: the viewer's
/// ending, seen by the five-second sampler, and the engine's real end. When the ending is closer to
/// the end than the next episode takes to resolve, both arrived and each advanced, so the episode
/// after the next one started and the next one was never seen.
///
/// IOS-POC-36.1: looping is one more way to handle that end, not a way around it. A replay only asks
/// for the start; the end still on its way belongs to the playthrough that ended, and taken as the
/// replay's it replayed again — or, with loop turned off by then, skipped an episode. So the
/// replayed item may end again once the engine is back at its start, not when the replay is asked.
public struct PlaybackEndGate: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable { case handOver, replay, ignore }

    private var item = 0
    private var handedOver: Int?

    public init() {}

    /// A new item was loaded, or a replay's rewind landed on the one playing: it may end once.
    public mutating func itemLoaded() { item &+= 1 }

    /// The item ended. The first end hands over, or replays while looping; every end after it,
    /// until `itemLoaded`, is ignored.
    public mutating func end(looping: Bool) -> Outcome {
        guard handedOver != item else { return .ignore }
        handedOver = item
        return looping ? .replay : .handOver
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

    /// W-109: mpv's error or fatal message as one public line, or nil for anything milder (warn and
    /// below stay counted only, IOS-POC-45D). The level is checked before any text is touched.
    public static func mpvError(level: Int, prefix: String, text: String) -> String? {
        guard level <= 20 else { return nil }  // MPV_LOG_LEVEL_ERROR; FATAL is 10
        let module = prefix.range(of: #"^[A-Za-z0-9_/-]{1,24}$"#, options: .regularExpression) != nil ? prefix : "?"
        return "[playback] mpv error level=\(level) prefix=\(module) text=\(comment(redacted(text)))"
    }

    /// Free text with nothing left that can carry a token: header values, addresses (plain or
    /// percent-encoded, any scheme) as `urlSummary`, every `key=value` run and every multi-part path
    /// (as its extension). Distrusts by shape rather than listing token names; runs before any cut.
    static func redacted(_ text: String) -> String {
        var out = text
        for (regex, transform) in redactions {
            for match in regex.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                guard let range = Range(match.range, in: out) else { continue }
                out.replaceSubrange(range, with: transform(String(out[range])))
            }
        }
        return out
    }

    // NSRegularExpression is immutable and documented safe to share across threads.
    nonisolated(unsafe) private static let redactions: [(NSRegularExpression, (String) -> String)] = [
        // A header's whole value: a Referer's is an address, a Cookie's a list of key=value.
        (#"\b(cookie|set-cookie|authorization|proxy-authorization|referer)\s*:.*$"#,
         { String($0.prefix { $0 != ":" }) + ": <redacted>" }),
        (#"[a-z][a-z0-9+.-]*://[^\s'"]+"#, { urlSummary($0) }),
        (#"[a-z][a-z0-9+.-]*%3A%2F%2F[^\s'"]+"#, { urlSummary($0.removingPercentEncoding) }),
        (#"[^\s'"]*(=|%3D)[^\s'"]*"#, { _ in "<redacted>" }),
        (#"(?<![\w.])/[^\s'":,;)]*/[^\s'":,;)]*"#, { path in
            let ext = ((path.split(separator: "/").last.map(String.init) ?? "") as NSString).pathExtension.lowercased()
            return ext.isEmpty ? "<path>" : "<path .\(ext)>"
        }),
    ].map { pattern, transform in
        (try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines]), transform)
    }
}
