import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-27A. The viewer's report: a stalled or never-starting native player showed ▶, pressing it
// did nothing, pause could not be reached, and nothing said anything was loading. Every rule below
// is one of those, so each test names the symptom it keeps from coming back.

// MARK: - The button follows intent

@Test func aPlayerWaitingForDataOffersPauseBecauseTheViewerMeantItToPlay() {
    // AVPlayer keeps `rate` at the requested speed while it waits; that is the viewer's intent.
    let waiting = PlaybackActivity(state: .buffering, rate: 2, failed: false)

    #expect(waiting.showsPause, "a stall must not show ▶, whose press does nothing on a waiting player")
    #expect(waiting.showsSpinner)
}

@Test func aSlowStartOffersPauseAndSaysItIsLoading() {
    let starting = PlaybackActivity(state: .preparing, rate: 1, failed: false)

    #expect(starting.showsPause)
    #expect(starting.showsSpinner, "a start that takes seconds must not look like a dead black screen")
}

@Test func aPausedPlayerOffersPlayAndNoSpinnerWhateverItIsDoing() {
    for state in [PlaybackEngineState.preparing, .buffering, .ready, .playing] {
        let paused = PlaybackActivity(state: state, rate: 0, failed: false)

        #expect(!paused.showsPause, "\(state): a paused player's button plays")
        #expect(!paused.showsSpinner, "\(state): nothing is on its way while the viewer has paused")
    }
}

@Test func aPlayingPlayerOffersPauseWithoutASpinner() {
    let playing = PlaybackActivity(state: .playing, rate: 1.5, failed: false)

    #expect(playing.showsPause)
    #expect(!playing.showsSpinner)
}

@Test func aFailureIsNeverCoveredByASpinner() {
    // MPV keeps `paused == false` after a file fails to load, so its rate still reads as intent.
    for state in [PlaybackEngineState.preparing, .buffering] {
        #expect(!PlaybackActivity(state: state, rate: 1, failed: true).showsSpinner,
                "\(state): the failure message is the answer, a spinner would promise one more")
    }
}

@Test func nothingLoadedOffersPlay() {
    let idle = PlaybackActivity(state: .idle, rate: 1, failed: false)

    #expect(!idle.showsPause)
    #expect(!idle.showsSpinner)
}

// MARK: - The startup watch counts only intended playback

// `timedOut` is mutating, and `#expect` wraps a call it is handed in a closure whose argument is
// immutable — the IOS-POC-25 review's compile error — so each result is taken first and then checked.

@Test func aStartThatNeverComesTimesOutOnceAfterTheTimeout() {
    var watch = PlaybackStartupWatch()
    watch.restart(at: 0)

    let early = watch.timedOut(now: 4.9, intends: true, stuck: true, timeout: 5)
    #expect(!early)
    let due = watch.timedOut(now: 5.1, intends: true, stuck: true, timeout: 5)
    #expect(due)
    // Once per engine: the hand-off that follows restarts the watch for the engine taking over.
    let again = watch.timedOut(now: 30, intends: true, stuck: true, timeout: 5)
    #expect(!again)
}

@Test func aViewerWhoPausesASlowStartIsNotSwitchedAndPlayedAnyway() {
    // IOS-POC-12 G20: pausing before the start used to switch engines after the timeout and play.
    var watch = PlaybackStartupWatch()
    watch.restart(at: 0)

    let beforePause = watch.timedOut(now: 2, intends: true, stuck: true, timeout: 5)
    #expect(!beforePause)
    for second in stride(from: 3.0, through: 60, by: 1) {
        let paused = watch.timedOut(now: second, intends: false, stuck: true, timeout: 5)
        #expect(!paused, "paused at \(second) s")
    }
}

@Test func pressingPlayAfterALongPauseStartsTheWholeTimeoutAgain() {
    // A paused item used to be switched the instant play was pressed if it had sat longer than the
    // timeout, because the clock ran from the load.
    var watch = PlaybackStartupWatch()
    watch.restart(at: 0)
    _ = watch.timedOut(now: 1, intends: false, stuck: true, timeout: 5)

    let onPlay = watch.timedOut(now: 100, intends: true, stuck: true, timeout: 5)
    #expect(!onPlay)
    let justBefore = watch.timedOut(now: 104.9, intends: true, stuck: true, timeout: 5)
    #expect(!justBefore)
    let due = watch.timedOut(now: 105.1, intends: true, stuck: true, timeout: 5)
    #expect(due)
}

@Test func anEngineThatIsReadyOrPlayingIsNotStuck() {
    var watch = PlaybackStartupWatch()
    watch.restart(at: 0)

    let ready = watch.timedOut(now: 60, intends: true, stuck: false, timeout: 5)
    #expect(!ready)
}

@Test func theEngineTakingOverGetsItsOwnTimeout() {
    var watch = PlaybackStartupWatch()
    watch.restart(at: 0)
    let first = watch.timedOut(now: 6, intends: true, stuck: true, timeout: 5)
    #expect(first)

    watch.restart(at: 6)
    let early = watch.timedOut(now: 20, intends: true, stuck: true, timeout: 20)
    #expect(!early)
    let due = watch.timedOut(now: 26.1, intends: true, stuck: true, timeout: 20)
    #expect(due)
}

@Test func aNativeStartIsGivenUpOnSoonerThanAnMPVStart() {
    // The viewer's request (2026-09-26): a line AVPlayer cannot open sat black for 20 s before MPV
    // took it. MPV, the compatibility engine, keeps its 20 s.
    #expect(PlayerRouter.startupTimeout(for: .native) == 5)
    #expect(PlayerRouter.startupTimeout(for: .mpv) == 20)
}

// MARK: - What a given-up native start says

@Test func anHTTPErrorIsTheReasonWhateverElseIsTrue() {
    #expect(PlaybackStartupReason(httpStatus: 403, ready: false, tooSlow: true, evaluating: true)
        == .http(403))
    // A status that is not an error is not evidence of one.
    #expect(PlaybackStartupReason(httpStatus: 200, ready: false, tooSlow: false, evaluating: false)
        == .neverReady)
}

@Test func anItemThatNeverBecameReadySaysSoBeforeAnyWaitingReason() {
    #expect(PlaybackStartupReason(httpStatus: nil, ready: false, tooSlow: true, evaluating: false)
        == .neverReady)
}

@Test func aReadyItemIsExplainedByWhyItWaits() {
    #expect(PlaybackStartupReason(httpStatus: nil, ready: true, tooSlow: true, evaluating: false)
        == .tooSlow)
    #expect(PlaybackStartupReason(httpStatus: nil, ready: true, tooSlow: false, evaluating: true)
        == .evaluating)
    #expect(PlaybackStartupReason(httpStatus: nil, ready: true, tooSlow: false, evaluating: false)
        == .unknown)
}

@Test func theNoticeNamesBothEnginesAndTheReason() {
    #expect(PlaybackStartupReason.http(403).notice(from: .native, to: .mpv)
        == "原生播放器無法開始播放（伺服器回應 403），已改用 MPV")
}

// MARK: - Diagnostic lines carry no tokens

@Test func aMediaAddressIsLoggedAsItsHostAndExtensionOnly() {
    let summary = PlaybackLogRedaction.urlSummary(
        "https://user:secret@cdn.example.com/path/token=abc/index.m3u8?sign=xyz#frag")

    #expect(summary == "cdn.example.com .m3u8")
    for leaked in ["secret", "token", "abc", "sign", "xyz", "frag", "path", "https"] {
        #expect(!summary.contains(leaked), "\(leaked) must not reach a public log line")
    }
    #expect(PlaybackLogRedaction.urlSummary("https://cdn.example.com/play") == "cdn.example.com")
    #expect(PlaybackLogRedaction.urlSummary(nil) == "none")
    #expect(PlaybackLogRedaction.urlSummary("not a url") == "none")
}

@Test func anErrorCommentIsOneShortLine() {
    #expect(PlaybackLogRedaction.comment("HTTP 403: Forbidden") == "HTTP 403: Forbidden")
    #expect(PlaybackLogRedaction.comment("a\nb") == "a b")
    #expect(PlaybackLogRedaction.comment(String(repeating: "x", count: 100), limit: 10)
        == String(repeating: "x", count: 10) + "…")
    #expect(PlaybackLogRedaction.comment(nil) == "none")
}
