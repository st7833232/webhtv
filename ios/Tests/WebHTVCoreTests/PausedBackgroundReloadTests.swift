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

// MARK: - IOS-POC-36.2: a Picture in Picture window closed in the background (PL-14)

// Whether the app would reload, by the one rule both engines are judged by.
private func eligible(open: Bool = true, failed: Bool = false, loaded: Bool = true,
                      paused: Bool, inWindow: Bool) -> Bool {
    PausedBackgroundReload.eligible(sessionOpen: open, failed: failed, loaded: loaded,
                                    paused: paused, pictureInPicture: inWindow)
}

@Test func onlyAnOpenLoadedPausedPlayerOutsideTheWindowIsEligible() {
    // One rule for AVPlayer and MPV alike: the session asks it whichever engine is drawing.
    var yes = 0
    for open in [false, true] {
        for failed in [false, true] {
            for loaded in [false, true] {
                for paused in [false, true] {
                    for inWindow in [false, true] {
                        let verdict = PausedBackgroundReload.eligible(
                            sessionOpen: open, failed: failed, loaded: loaded, paused: paused,
                            pictureInPicture: inWindow)
                        if verdict { yes += 1 }
                        #expect(verdict == (open && !failed && loaded && paused && !inWindow))
                    }
                }
            }
        }
    }
    #expect(yes == 1)
}

@Test func playingInTheWindowIsNotArmedWhenTheAppLeaves() {
    var state = PausedBackgroundReload()
    state.enteredBackground(eligible: eligible(paused: false, inWindow: true), position: 300, at: leftAt)
    #expect(state.becameActive(at: leftAt + .seconds(600)) == nil)
}

@Test func pausedInTheWindowAndClosedThereIsReloadedAfterASuspension() {
    // PL-14: playing in the window as the app left, paused in the window, the window closed while
    // the app was still in the background, suspended afterwards. Nothing judged the player again
    // after the window closed, so the return found no record and kept the dead engine.
    var state = PausedBackgroundReload()
    state.enteredBackground(eligible: eligible(paused: false, inWindow: true), position: 300, at: leftAt)
    let pausedInWindow = state.eligibilityChanged(eligible: eligible(paused: true, inWindow: true),
                                                  position: 310, at: leftAt + .seconds(10))
    let closed = state.eligibilityChanged(eligible: eligible(paused: true, inWindow: false),
                                          position: 310, at: leftAt + .seconds(20))
    let again = state.eligibilityChanged(eligible: eligible(paused: true, inWindow: false),
                                         position: 310, at: leftAt + .seconds(21))
    beat(&state, from: 21, to: 23)
    #expect(!pausedInWindow, "still in the window: a paused window keeps the app running")
    #expect(closed, "the window closing is when the paused player becomes one to reload")
    #expect(!again, "a record already running keeps its beats")
    #expect(state.becameActive(at: leftAt + .seconds(120)) == 310)
}

@Test func aWindowClosedBeforeItsPauseArrivesIsArmedByThePause() {
    // MPV's own order when the window is closed while playing: the window reports closed, then
    // playback is paused. AVKit's order is not documented, so either order has to arm.
    var state = PausedBackgroundReload()
    state.enteredBackground(eligible: eligible(paused: false, inWindow: true), position: 300, at: leftAt)
    let closed = state.eligibilityChanged(eligible: eligible(paused: false, inWindow: false),
                                          position: 320, at: leftAt + .seconds(20))
    let paused = state.eligibilityChanged(eligible: eligible(paused: true, inWindow: false),
                                          position: 320, at: leftAt + .seconds(20))
    beat(&state, from: 21, to: 22)
    #expect(!closed, "closed while still playing: a playing app is not suspended")
    #expect(paused)
    #expect(state.becameActive(at: leftAt + .seconds(90)) == 320)
}

@Test func aWindowStillOpenIsNeverArmed() {
    var state = PausedBackgroundReload()
    state.enteredBackground(eligible: eligible(paused: false, inWindow: true), position: 300, at: leftAt)
    let pausedInWindow = state.eligibilityChanged(eligible: eligible(paused: true, inWindow: true),
                                                  position: 310, at: leftAt + .seconds(10))
    #expect(!pausedInWindow)
    #expect(state.becameActive(at: leftAt + .seconds(600)) == nil, "IOS-POC-23 T6 stays as it was")
}

@Test func aWindowClosedWhilePlayingIsNotReloaded() {
    var state = PausedBackgroundReload()
    state.enteredBackground(eligible: eligible(paused: false, inWindow: true), position: 300, at: leftAt)
    let closed = state.eligibilityChanged(eligible: eligible(paused: false, inWindow: false),
                                          position: 320, at: leftAt + .seconds(20))
    #expect(!closed)
    #expect(state.becameActive(at: leftAt + .seconds(600)) == nil)
}

@Test func theWindowsBackToTheAppButtonIsNotABackgroundClose() {
    // The window's own button returns to the app; its stop can reach the session either side of
    // didBecomeActive. Before: armed that moment, with no gap since, so nothing to reload. After:
    // not in the background any more, so nothing is armed at all.
    var stopFirst = PausedBackgroundReload()
    stopFirst.enteredBackground(eligible: eligible(paused: false, inWindow: true), position: 300, at: leftAt)
    _ = stopFirst.eligibilityChanged(eligible: eligible(paused: true, inWindow: true),
                                     position: 310, at: leftAt + .seconds(10))
    _ = stopFirst.eligibilityChanged(eligible: eligible(paused: true, inWindow: false),
                                     position: 310, at: leftAt + .seconds(300))
    #expect(stopFirst.becameActive(at: leftAt + .milliseconds(300_200)) == nil)

    var activeFirst = PausedBackgroundReload()
    activeFirst.enteredBackground(eligible: eligible(paused: false, inWindow: true), position: 300, at: leftAt)
    #expect(activeFirst.becameActive(at: leftAt + .seconds(300)) == nil)
    let lateStop = activeFirst.eligibilityChanged(eligible: eligible(paused: true, inWindow: false),
                                                  position: 310, at: leftAt + .milliseconds(300_100))
    #expect(!lateStop, "back in the app: a window stopping now is no trip to the background")
    #expect(activeFirst.becameActive(at: leftAt + .seconds(900)) == nil)
}

@Test func aFailureOrAClosedPlayerIsNeverArmed() {
    var failed = PausedBackgroundReload()
    failed.enteredBackground(eligible: eligible(paused: false, inWindow: true), position: 300, at: leftAt)
    let afterFailure = failed.eligibilityChanged(
        eligible: eligible(failed: true, paused: true, inWindow: false), position: 310, at: leftAt + .seconds(20))
    #expect(!afterFailure)
    #expect(failed.becameActive(at: leftAt + .seconds(600)) == nil)

    var closed = PausedBackgroundReload()
    closed.enteredBackground(eligible: eligible(paused: false, inWindow: true), position: 300, at: leftAt)
    let afterClose = closed.eligibilityChanged(
        eligible: eligible(open: false, paused: true, inWindow: false), position: 310, at: leftAt + .seconds(20))
    #expect(!afterClose)
    #expect(closed.becameActive(at: leftAt + .seconds(600)) == nil)
}

@Test func aPlayerPlayedAgainInTheBackgroundIsJudgedAgainWhenItPauses() {
    // Played from the lock screen, then paused there: the record is where it paused the second time.
    var state = PausedBackgroundReload()
    state.enteredBackground(eligible: true, position: 812, at: leftAt)
    _ = state.eligibilityChanged(eligible: eligible(paused: false, inWindow: false),
                                 position: 812, at: leftAt + .seconds(5))
    let pausedAgain = state.eligibilityChanged(eligible: eligible(paused: true, inWindow: false),
                                               position: 900, at: leftAt + .seconds(93))
    beat(&state, from: 94, to: 95)
    #expect(pausedAgain)
    #expect(state.becameActive(at: leftAt + .seconds(200)) == 900)
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
