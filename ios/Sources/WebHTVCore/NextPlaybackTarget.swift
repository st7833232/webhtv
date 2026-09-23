import Foundation

/// IOS-POC-15C — one pre-resolved next episode, and the identity that has to still be true for it.
///
/// **No second player and no download.** What is held here is the result of the *resolution* work —
/// the `playerContent` call, the probe, the sniff, the headers — which is the part of a handoff that
/// costs seconds. Opening it is still an ordinary `AVPlayerItem` on the one `AVPlayer` this app has.

// MARK: - Identity

/// Everything that has to match for a pre-resolved address to be the right one to open.
///
/// Each field is an identity this project already uses rather than a new key:
/// `ConfigSource.identity` for the configuration, `Site.id` (key *and* `ext`) for the provider
/// because this configuration has four duplicate keys, the CatVod flag for the line, and the
/// episode's **address** for the episode — IOS-POC-14's rule, because a line here may print the
/// same episode name twice.
public struct PlaybackTargetIdentity: Sendable, Equatable {
    public let configID: String
    public let siteID: String
    public let vodId: String
    /// The line, as the source names it.
    public let flag: String
    /// The episode, by address.
    public let episodeURL: String
    /// The quality remembered for this title (IOS-POC-5Q/5R). Held so that a viewer who changed it
    /// between the prefetch and the handoff gets a fresh resolution rather than the old one.
    public let quality: String

    public init(configID: String, siteID: String, vodId: String,
                flag: String, episodeURL: String, quality: String) {
        self.configID = configID
        self.siteID = siteID
        self.vodId = vodId
        self.flag = flag
        self.episodeURL = episodeURL
        self.quality = quality
    }
}

/// A resolved next episode, with enough to prove it is still the right one.
public struct NextPlaybackTarget: Sendable, Equatable {
    public let identity: PlaybackTargetIdentity
    /// The whole `PlaybackTarget`, so the **headers travel with it**. A prefetch that dropped them
    /// would turn a working bilibili line into a 403 on exactly the episodes it was meant to speed
    /// up (IOS-POC-5P).
    public let target: PlaybackTarget
    /// What the source calls this episode, for the player's title.
    public let episodeName: String
    public let resolvedAt: Date

    public init(identity: PlaybackTargetIdentity, target: PlaybackTarget,
                episodeName: String, resolvedAt: Date = .now) {
        self.identity = identity
        self.target = target
        self.episodeName = episodeName
        self.resolvedAt = resolvedAt
    }

    public func isFresh(now: Date = .now, maximumAge: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(resolvedAt)
        return age >= 0 && age <= maximumAge
    }
}

// MARK: - The store

/// Holds at most one pre-resolved next episode, and refuses to hand back a wrong or stale one.
///
/// A value type with no tasks and no clock of its own, so every rule below is a test rather than a
/// race: `swift test` drives the whole lifecycle by passing a `now`.
public struct PlaybackTargetPrefetch: Sendable, Equatable {
    /// How long a resolved address may be held before it is refused.
    ///
    /// Five minutes is deliberately far longer than `PlaybackPrefetchGate.leadSeconds`, because the
    /// gate is what actually keeps the exposure short: a target is created inside the last ninety
    /// seconds of an episode and used at the end of it. This ceiling only catches the cases the gate
    /// cannot — a long pause, a Picture in Picture session left running, a screen locked mid-episode
    /// — where an address a source meant to be short-lived would otherwise be opened stale.
    /// **No source in this configuration publishes a TTL**, so this is a conservative bound rather
    /// than a measured one, and the identity check runs with it rather than instead of it.
    public static let maximumAge: TimeInterval = 5 * 60

    private var stored: NextPlaybackTarget?
    /// What is being resolved right now, if anything. Held as the identity rather than a flag so a
    /// result that arrives after the viewer has moved on can be recognised and dropped.
    private var resolving: PlaybackTargetIdentity?

    public init() {}

    /// Whether anything is held or on its way, which is what stops a second episode being resolved.
    public var isHolding: Bool { stored != nil || resolving != nil }

    /// Claims the right to resolve `identity`, or refuses because something else already has it.
    ///
    /// Anything held for a different identity is dropped here: if the viewer changed line, episode,
    /// quality, title, site or configuration, what was stored is about the old one.
    public mutating func beginResolving(for identity: PlaybackTargetIdentity) -> Bool {
        if let stored, stored.identity != identity { self.stored = nil }
        if let resolving, resolving != identity { self.resolving = nil }
        guard !isHolding else { return false }
        resolving = identity
        return true
    }

    /// Records a finished resolution. A result whose identity is no longer the one being resolved is
    /// dropped — that is a viewer who moved while the request was in flight.
    public mutating func store(_ value: NextPlaybackTarget) {
        guard resolving == value.identity else { return }
        resolving = nil
        stored = value
    }

    /// A resolution that did not produce an address. **This is an optimization miss, not a playback
    /// failure** — the caller goes on to resolve normally when the episode actually ends.
    public mutating func failed() {
        resolving = nil
    }

    /// Drops everything. Called whenever the screen stops owning this playback.
    public mutating func invalidate() {
        stored = nil
        resolving = nil
    }

    /// Hands back the held target if it is the right one and still fresh, and **consumes it either
    /// way**.
    ///
    /// Consuming on a mismatch is the point: a target for an episode we are no longer about to play
    /// is wrong, and keeping it would only let it be reconsidered later.
    public mutating func take(matching identity: PlaybackTargetIdentity,
                              now: Date = .now) -> NextPlaybackTarget? {
        let held = stored
        stored = nil
        resolving = nil
        guard let held, held.identity == identity,
              held.isFresh(now: now, maximumAge: Self.maximumAge) else { return nil }
        return held
    }
}
