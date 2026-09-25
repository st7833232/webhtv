import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-23. When a player paused in the background is loaded again on return. A paused audio app
// is suspended, and neither engine recovers from that by itself; reloading when it did not happen
// costs the viewer a re-buffer, and not reloading when it did leaves them a dead play button.

private let leftAt = ContinuousClock.now

/// Beats every second from `from` to `to`, the way the app does while it is still running.
private func beat(_ state: inout PausedBackgroundReload, from: Int, to: Int) {
    for second in stride(from: from, through: to, by: 1) {
        state.stillRunning(at: leftAt + .seconds(second))
    }
}

@Test func aPausedPlayerThatWasSuspendedIsReloadedWhereItWasLeft() {
    var state = PausedBackgroundReload()
    state.enteredBackground(eligible: true, position: 812, at: leftAt)
    beat(&state, from: 1, to: 2)
    // Suspended after two seconds; back ten seconds later.
    #expect(state.becameActive(at: leftAt + .seconds(12)) == 812)
}

@Test func theBeatAsleepAcrossTheSuspensionDoesNotHideIt() {
    // After a resume the sleeping beat can fire before didBecomeActive is delivered.
    var state = PausedBackgroundReload()
    state.enteredBackground(eligible: true, position: 812, at: leftAt)
    beat(&state, from: 1, to: 2)
    state.stillRunning(at: leftAt + .seconds(12))
    #expect(state.becameActive(at: leftAt + .seconds(12)) == 812)
}

@Test func anAppThatKeptRunningIsLeftAlone() {
    // Not suspended, so its connections were never taken away: reloading would only re-buffer.
    var state = PausedBackgroundReload()
    state.enteredBackground(eligible: true, position: 812, at: leftAt)
    beat(&state, from: 1, to: 60)
    #expect(state.becameActive(at: leftAt + .milliseconds(60_500)) == nil)
}

@Test func aQuickReturnBeforeAnyBeatIsLeftAlone() {
    var state = PausedBackgroundReload()
    state.enteredBackground(eligible: true, position: 812, at: leftAt)
    #expect(state.becameActive(at: leftAt + .seconds(2)) == nil)
}

@Test func onlyAnEligiblePlayerIsEverReloaded() {
    // Playing, in Picture in Picture, closed, failed or not loaded: the caller says so, and an
    // earlier record goes with it.
    var state = PausedBackgroundReload()
    state.enteredBackground(eligible: true, position: 812, at: leftAt)
    state.enteredBackground(eligible: false, position: 812, at: leftAt + .seconds(1))
    #expect(state.becameActive(at: leftAt + .seconds(600)) == nil)
}

@Test func aReturnIsDecidedOnce() {
    // Control Center pulled down and back up afterwards is not another return from the background.
    var state = PausedBackgroundReload()
    state.enteredBackground(eligible: true, position: 812, at: leftAt)
    #expect(state.becameActive(at: leftAt + .seconds(30)) == 812)
    #expect(state.becameActive(at: leftAt + .seconds(90)) == nil)
}

@Test func pressingPlayOrAnotherItemCancelsTheReload() {
    var state = PausedBackgroundReload()
    state.enteredBackground(eligible: true, position: 812, at: leftAt)
    state.cancel()
    #expect(state.becameActive(at: leftAt + .seconds(30)) == nil)
}

@Test func theNextTripReplacesTheLastOne() {
    var state = PausedBackgroundReload()
    state.enteredBackground(eligible: true, position: 812, at: leftAt)
    state.enteredBackground(eligible: true, position: 900, at: leftAt + .seconds(100))
    #expect(state.becameActive(at: leftAt + .seconds(130)) == 900)
}

@Test func anUnreadablePositionReloadsFromTheStart() {
    var state = PausedBackgroundReload()
    state.enteredBackground(eligible: true, position: .nan, at: leftAt)
    #expect(state.becameActive(at: leftAt + .seconds(30)) == 0)
}

// MARK: - The viewer's tracks across the reload

private func track(_ ids: [String], selected: String?) -> PlaybackMediaTrack {
    PlaybackMediaTrack(options: ids.map { PlaybackMediaOption(id: $0, fallbackName: $0) },
                       selectedID: selected)
}

@Test func theViewersTracksAreSelectedAgainAfterAReload() {
    let before = PlaybackMediaSelection(
        subtitle: track([PlaybackMediaOption.subtitleOffID, "native-subtitle-0"],
                        selected: PlaybackMediaOption.subtitleOffID),
        audio: track(["native-audio-0", "native-audio-1"], selected: "native-audio-1"))
    // The reloaded item came back on its defaults.
    let reloaded = PlaybackMediaSelection(
        subtitle: track([PlaybackMediaOption.subtitleOffID, "native-subtitle-0"], selected: "native-subtitle-0"),
        audio: track(["native-audio-0", "native-audio-1"], selected: "native-audio-0"))
    #expect(before.reselections(after: reloaded) == [
        .audio: "native-audio-1", .subtitle: PlaybackMediaOption.subtitleOffID,
    ])
}

@Test func aTrackTheReloadAlreadyPickedIsLeftAlone() {
    let before = PlaybackMediaSelection(audio: track(["mpv-audio-1", "mpv-audio-2"], selected: "mpv-audio-2"))
    let reloaded = PlaybackMediaSelection(audio: track(["mpv-audio-1", "mpv-audio-2"], selected: "mpv-audio-2"))
    #expect(before.reselections(after: reloaded).isEmpty)
}

@Test func aTrackTheReloadedItemDoesNotOfferIsNotForced() {
    // After a move to the other engine the ids are the other adapter's, and nothing matches.
    let before = PlaybackMediaSelection(audio: track(["native-audio-0", "native-audio-1"], selected: "native-audio-1"))
    let reloaded = PlaybackMediaSelection(audio: track(["mpv-audio-1", "mpv-audio-2"], selected: "mpv-audio-1"))
    #expect(before.reselections(after: reloaded).isEmpty)
}
