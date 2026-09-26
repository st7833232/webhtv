import Foundation

/// IOS-POC-29 — the speed a **new** title starts at, from the settings page.
///
/// IOS-POC-14B's rule is unchanged: a speed chosen in the player carries across episodes of the same
/// title, and only a different title (or one with no identity) starts over. What it starts over at
/// used to be 1×; now it is this. A speed chosen in the player never writes back here — the setting
/// changes only when the viewer changes it (Android's `play_speed` does write back; the user chose
/// the settings page's value instead, 2026-09-26).
///
/// Kept in the same `UserDefaults` the other playback settings use (`HLSAdSkipPreference`).
public struct PlaybackSpeedPreference: Sendable {
    public static let key = "webhtv.playback.defaultSpeed"
    /// The player's speed menu, so the setting can only name a speed the player offers.
    public static let choices: [Float] = [0.5, 1, 1.25, 1.5, 2, 2.5, 3]

    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The stored speed, or 1× when nothing — or nothing the menu offers — is stored.
    public var defaultSpeed: Float {
        guard let stored = defaults.object(forKey: Self.key) as? Double,
              let choice = Self.choices.first(where: { Double($0) == stored }) else { return 1 }
        return choice
    }

    /// Stores a speed the menu offers; anything else is ignored.
    public func setDefaultSpeed(_ speed: Float) {
        guard Self.choices.contains(speed) else { return }
        defaults.set(Double(speed), forKey: Self.key)
    }
}
