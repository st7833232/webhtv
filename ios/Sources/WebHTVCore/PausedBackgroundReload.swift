import Foundation

/// IOS-POC-23 — whether a player left paused in the background has to be loaded again when the
/// app returns.
///
/// A paused audio app is suspended shortly after it leaves the foreground. While it is suspended
/// the system may reclaim or silence its sockets (TN2277), and on return neither engine recovers by
/// itself: a seek queues behind mpv's blocked read, and AVPlayer waits without failing. Closing and
/// reopening the player recovers because it loads the item again; this decides when to do that for
/// the viewer.
///
/// **A suspension is detected, not assumed.** iOS reports none: the audio session's
/// `appWasSuspended` interruption reason is deprecated since iOS 16 ("no longer present"). So the
/// app beats while it is in the background, and a gap in the beats longer than `suspensionGap` is a
/// process that did not run — suspended, or the device asleep, which also drops Wi-Fi.
///
/// UIKit stays in the app target. This is the state alone, so the decision is testable — the same
/// split as `PictureInPictureForegroundRestoreState`.
public struct PausedBackgroundReload: Sendable {
    /// How often the app reports that it is still running while in the background.
    public static let heartbeat: Duration = .seconds(1)
    /// Longer than this without a beat means the process was not running.
    public static let suspensionGap: Duration = .seconds(3)

    private struct Pending: Sendable {
        let position: Double
        var lastAlive: ContinuousClock.Instant
        var suspended = false

        mutating func observe(_ now: ContinuousClock.Instant) {
            if now - lastAlive > PausedBackgroundReload.suspensionGap { suspended = true }
            lastAlive = now
        }
    }

    private var pending: Pending?
    /// From `didEnterBackground` to `didBecomeActive`.
    private var inBackground = false

    public init() {}

    /// Whether a player may be loaded again on return: open, loaded or still loading, paused, not in
    /// Picture in Picture, and not showing a failure — the one state a reload puts back exactly as
    /// it was. Engine-neutral: AVPlayer and MPV are judged by this one rule.
    public static func eligible(sessionOpen: Bool, failed: Bool, loaded: Bool, paused: Bool,
                                pictureInPicture: Bool) -> Bool {
        sessionOpen && !failed && loaded && paused && !pictureInPicture
    }

    /// `didEnterBackground`. `eligible` is the caller's to judge (`eligible(…)`). Anything else
    /// clears an earlier record.
    public mutating func enteredBackground(eligible: Bool, position: Double,
                                           at now: ContinuousClock.Instant) {
        inBackground = true
        pending = eligible
            ? Pending(position: position.isFinite ? max(position, 0) : 0, lastAlive: now) : nil
    }

    /// IOS-POC-36.2 (PL-14): still in the background, something `eligible` reads has changed — the
    /// Picture in Picture window closed, or the player was paused or played without the app on
    /// screen (the window, the lock screen, an interruption). Judged again, from now: a player paused
    /// in the window and closed there is suspended like any other paused one, and judged only as the
    /// app left it was never armed. Engines report the window closing and the pause in either
    /// order, so each change is judged on its own. True when this armed a record — the caller
    /// starts beating; a record already running keeps its beats. Back in the app, nothing changes.
    public mutating func eligibilityChanged(eligible: Bool, position: Double,
                                            at now: ContinuousClock.Instant) -> Bool {
        guard inBackground else { return false }
        guard eligible else {
            pending = nil
            return false
        }
        guard pending == nil else { return false }
        pending = Pending(position: position.isFinite ? max(position, 0) : 0, lastAlive: now)
        return true
    }

    /// One background beat. A late beat is evidence too: the beat asleep across a suspension can
    /// fire before `didBecomeActive` is delivered, and must not hide the gap it slept through.
    public mutating func stillRunning(at now: ContinuousClock.Instant) {
        pending?.observe(now)
    }

    /// `didBecomeActive`: the position to reload at, or nil. The record is consumed either way, so
    /// only the first return after a trip decides. Control Center and the notification shade make
    /// the app inactive without sending it to the background, so they find nothing here.
    public mutating func becameActive(at now: ContinuousClock.Instant) -> Double? {
        inBackground = false
        guard var pending else { return nil }
        self.pending = nil
        pending.observe(now)
        return pending.suspended ? pending.position : nil
    }

    /// The viewer pressed play, or another item loaded: there is nothing left to reload.
    public mutating func cancel() { pending = nil }
}

extension PlaybackMediaSelection {
    /// IOS-POC-23 — the embedded tracks to select again after a reload: each choice made on this
    /// selection that `reloaded` still offers but has not picked by itself. The ids are the engine
    /// adapter's own, so after a move to the other engine nothing matches and nothing is selected.
    public func reselections(after reloaded: PlaybackMediaSelection) -> [PlaybackMediaKind: String] {
        let tracks: [(PlaybackMediaKind, PlaybackMediaTrack?, PlaybackMediaTrack?)] = [
            (.audio, audio, reloaded.audio),
            (.subtitle, subtitle, reloaded.subtitle),
        ]
        var choices = [PlaybackMediaKind: String]()
        for (kind, before, after) in tracks {
            guard let id = before?.selectedID, let after, after.selectedID != id,
                  after.options.contains(where: { $0.id == id }) else { continue }
            choices[kind] = id
        }
        return choices
    }
}
