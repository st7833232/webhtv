import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-17. The router and the selection are driven here against engines that only record what
// they were asked, so every rule below is the real `PlayerRouter`, not a copy of its logic.

@MainActor
private final class FakeEngine: PlaybackEngine {
    let kind: PlaybackEngineKind
    var loads = [PlaybackLoadRequest]()
    var tornDown = false
    var currentTime: Double = 0
    var duration: Double = 0
    var rate: Float = 0
    var chosenRate: Float = 1
    var volume: Float = 1
    var isLoaded = false
    var isPlaying = false
    var state: PlaybackEngineState = .idle
    var bufferedUntil: Double?
    var onFailure: ((Error, Int?) -> Void)?
    var onEnded: (() -> Void)?
    var onMediaSelectionChange: ((PlaybackMediaSelection) -> Void)?
    var media = PlaybackMediaSelection()

    init(kind: PlaybackEngineKind) { self.kind = kind }
    func load(_ request: PlaybackLoadRequest) {
        loads.append(request)
        isLoaded = true
        isPlaying = request.autoplay
        currentTime = request.startSeconds
        chosenRate = request.rate
    }
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func seek(toSeconds seconds: Double) { currentTime = seconds }
    func setRate(_ rate: Float) { chosenRate = rate }
    func mediaSelection() async -> PlaybackMediaSelection { media }
    func selectMedia(_ kind: PlaybackMediaKind, id: String) async {
        func selected(_ track: PlaybackMediaTrack?) -> PlaybackMediaTrack? {
            guard let track, track.options.contains(where: { $0.id == id }) else { return track }
            return PlaybackMediaTrack(options: track.options, selectedID: id)
        }
        switch kind {
        case .audio: media.audio = selected(media.audio)
        case .subtitle: media.subtitle = selected(media.subtitle)
        }
        onMediaSelectionChange?(media)
    }
    func teardown() { tornDown = true; isLoaded = false; isPlaying = false }
    func fail(_ error: Error, httpStatus: Int? = nil) { onFailure?(error, httpStatus) }
}

@MainActor
private final class Harness {
    var made = [FakeEngine]()
    lazy var router = PlayerRouter(globalDefault: globalDefault, available: available) { [unowned self] kind in
        let engine = FakeEngine(kind: kind)
        made.append(engine)
        return engine
    }
    let globalDefault: PlaybackEngineKind
    let available: Set<PlaybackEngineKind>
    init(globalDefault: PlaybackEngineKind = .native, available: Set<PlaybackEngineKind> = [.native, .mpv]) {
        self.globalDefault = globalDefault
        self.available = available
    }
    var engine: FakeEngine { router.engine as! FakeEngine }
}

private let episode = WatchHistory(key: "site@@@vod", siteKey: "site", vodId: "vod", vodName: "片名",
                                   vodFlag: "線路2", vodRemarks: "EP08",
                                   episodeUrl: "https://example.com/ep8", quality: "1080p")
private let target = PlaybackTarget(
    url: URL(string: "https://cdn.example.com/ep8/index.m3u8")!,
    headers: ["Referer": "https://www.bilibili.com/", "User-Agent": "Mozilla/5.0 (KHTML, like Gecko)",
              "Cookie": "SESSDATA=x"],
    qualities: [PlaybackQuality(name: "1080p", url: URL(string: "https://cdn.example.com/ep8/index.m3u8")!),
                PlaybackQuality(name: "720p", url: URL(string: "https://cdn.example.com/ep8/720.m3u8")!)])
private let request = PlaybackLoadRequest(target: target, rate: 1.5, title: "片名 EP08", history: episode)

private func avError(_ code: Int, underlying: NSError? = nil) -> NSError {
    NSError(domain: "AVFoundationErrorDomain", code: code,
            userInfo: underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:])
}

// MARK: - Embedded track model

@Test func embeddedAudioLabelsAreSharedAcrossEngines() {
    let stereo = PlaybackMediaOption(id: "a1", title: "日語", language: "ja", codec: "mp4a",
                                     channelCount: 2, fallbackName: "音軌 1")
    let surround = PlaybackMediaOption(id: "a2", title: "國語", language: "zh", codec: "ec-3",
                                       channelCount: 6, fallbackName: "音軌 2")
    let sevenOne = PlaybackMediaOption(id: "a3", title: "English", language: "en", codec: "ac-3",
                                       channelCount: 8, fallbackName: "音軌 3")
    #expect(stereo.displayName == "日語 · AAC · Stereo")
    #expect(surround.displayName == "國語 · E-AC-3 · 5.1")
    #expect(sevenOne.channelDescription == "7.1")
}

@Test func channelLayoutsWinOverAmbiguousCounts() {
    let option = PlaybackMediaOption(id: "a1", codec: "aac", channelCount: 6,
                                     channelLayout: "stereo", fallbackName: "音軌 1")
    #expect(option.channelDescription == "Stereo")
}

@Test func mpvTrackSelectionIsOnlyAdvertisedAfterP10() {
    #expect(PlaybackEngineKind.native.capabilities.trackSelection)
    #expect(PlaybackEngineKind.mpv.capabilities.trackSelection)
}

// MARK: - Defaults and persistence

@Test func theDefaultEngineIsAVPlayerWhenNothingIsStored() throws {
    let defaults = try #require(UserDefaults(suiteName: "engine-empty-\(UUID())"))
    #expect(PlaybackEnginePreference(defaults: defaults).globalDefaultEngine == .native)
    defaults.set("vlc", forKey: PlaybackEnginePreference.key)
    #expect(PlaybackEnginePreference(defaults: defaults).globalDefaultEngine == .native)
}

@Test func theGlobalDefaultPersists() throws {
    let suite = "engine-persist-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    PlaybackEnginePreference(defaults: defaults).setGlobalDefaultEngine(.mpv)
    let again = try #require(UserDefaults(suiteName: suite))
    #expect(PlaybackEnginePreference(defaults: again).globalDefaultEngine == .mpv)
}

@MainActor @Test func anAVPlayerDefaultStartsTheSessionOnAVPlayer() {
    let harness = Harness(globalDefault: .native)
    harness.router.open(request)
    #expect(harness.engine.kind == .native)
    #expect(harness.router.selection.currentSessionEngine == .native)
}

@MainActor @Test func anMPVDefaultStartsTheSessionOnMPV() {
    let harness = Harness(globalDefault: .mpv)
    harness.router.open(request)
    #expect(harness.engine.kind == .mpv)
}

@MainActor @Test func anUnavailableMPVIsNeverUsedAndNeverSelectable() {
    let harness = Harness(globalDefault: .mpv, available: [.native])
    harness.router.open(request)
    #expect(harness.engine.kind == .native)
    #expect(harness.router.selection.isAvailable(.mpv) == false)
    #expect(harness.router.select(.mpv) == false)
    #expect(harness.made.count == 1)
    // The stored default is kept; it is only not used until MPV is available.
    #expect(harness.router.selection.globalDefaultEngine == .mpv)
}

@MainActor @Test func anAvailableMPVCanBeSelected() {
    let harness = Harness()
    harness.router.open(request)
    #expect(harness.router.select(.mpv))
    #expect(harness.engine.kind == .mpv)
}

// MARK: - Session override

@MainActor @Test func aSessionOverrideLeavesTheGlobalDefaultAlone() {
    let harness = Harness(globalDefault: .native)
    harness.router.open(request)
    harness.router.select(.mpv)
    #expect(harness.router.selection.sessionOverride == .mpv)
    #expect(harness.router.selection.currentSessionEngine == .mpv)
    #expect(harness.router.selection.globalDefaultEngine == .native)
}

@MainActor @Test func closingThePlayerClearsTheOverrideAndTheNextTitleStartsFromTheDefault() {
    let harness = Harness(globalDefault: .native)
    harness.router.open(request)
    harness.router.select(.mpv)
    let mpv = harness.engine
    harness.router.endSession()
    #expect(harness.router.selection.sessionOverride == nil)
    #expect(mpv.tornDown, "an engine the next session will not use is released")
    harness.router.open(request)
    #expect(harness.engine.kind == .native)
}

@MainActor @Test func theNextEpisodeStaysOnTheSessionsEngine() {
    let harness = Harness(globalDefault: .native)
    harness.router.open(request)
    harness.router.select(.mpv)
    harness.router.open(request)   // auto-advance inside the same session
    #expect(harness.engine.kind == .mpv)
    #expect(harness.made.count == 2)
}

@MainActor @Test func aDefaultChangedWhilePlayingWaitsForTheNextSession() {
    let harness = Harness(globalDefault: .native)
    harness.router.open(request)
    harness.router.setGlobalDefault(.mpv)
    harness.router.open(request)
    #expect(harness.engine.kind == .native)
    harness.router.endSession()
    harness.router.open(request)
    #expect(harness.engine.kind == .mpv)
}

// MARK: - Manual switch keeps everything

@MainActor @Test func switchingAVPlayerToMPVKeepsTheTargetPositionRateAndIdentity() throws {
    let harness = Harness()
    harness.router.open(request)
    let native = harness.engine
    native.currentTime = 23 * 60 + 41
    harness.router.select(.mpv)
    let mpv = harness.engine
    #expect(native.tornDown)
    #expect(mpv.kind == .mpv)
    let loaded = try #require(mpv.loads.last)
    #expect(loaded.target == target)                        // same PlaybackTarget, URL and qualities
    #expect(loaded.target.headers == target.headers)        // every header, Cookie included
    #expect(loaded.history?.vodRemarks == "EP08")           // episode
    #expect(loaded.history?.vodFlag == "線路2")             // line
    #expect(loaded.history?.quality == "1080p")             // quality
    #expect(loaded.history?.episodeUrl == episode.episodeUrl)
    #expect(loaded.startSeconds == 23 * 60 + 41)            // position
    #expect(loaded.exactStart)                              // landed on exactly (IOS-POC-26)
    #expect(loaded.rate == 1.5)                             // rate
    #expect(loaded.autoplay)
}

// MARK: - IOS-POC-22: a speed AVPlayer cannot play

@Test func onlyAboveTwiceWithoutFastForwardNeedsTheOtherEngine() {
    #expect(!PlaybackRateSupport.needsOtherEngine(rate: 2, canPlayFastForward: false))
    #expect(!PlaybackRateSupport.needsOtherEngine(rate: 0.5, canPlayFastForward: false))
    #expect(PlaybackRateSupport.needsOtherEngine(rate: 2.5, canPlayFastForward: false))
    #expect(PlaybackRateSupport.needsOtherEngine(rate: 3, canPlayFastForward: false))
    #expect(!PlaybackRateSupport.needsOtherEngine(rate: 3, canPlayFastForward: true))
}

@MainActor @Test func aSpeedAVPlayerCannotPlayMovesToMPVWithEverythingKept() throws {
    let harness = Harness()
    harness.router.open(request)
    let native = harness.engine
    native.currentTime = 812
    // Waiting for data: not `isPlaying`, but the viewer did not pause it.
    native.isPlaying = false
    harness.router.setRate(3)
    #expect(harness.router.select(.mpv, playing: true))
    let loaded = try #require(harness.engine.loads.last)
    #expect(native.tornDown)
    #expect(harness.engine.kind == .mpv)
    #expect(loaded.target == target)
    #expect(loaded.history == episode)                      // episode, line and quality
    #expect(loaded.startSeconds == 812)
    #expect(loaded.exactStart)
    #expect(loaded.rate == 3)
    #expect(loaded.autoplay)
}

@MainActor @Test func aPausedPlayerMovesPaused() throws {
    let harness = Harness()
    harness.router.open(request)
    harness.engine.currentTime = 90
    harness.router.setRate(2.5)
    harness.router.select(.mpv, playing: false)
    let loaded = try #require(harness.engine.loads.last)
    #expect(loaded.rate == 2.5)
    #expect(!loaded.autoplay)
}

@MainActor @Test func switchingMPVToAVPlayerKeepsTheSameThings() throws {
    let harness = Harness(globalDefault: .mpv)
    harness.router.open(request)
    harness.engine.currentTime = 600
    harness.router.setRate(2.5)
    harness.router.select(.native)
    let loaded = try #require(harness.engine.loads.last)
    #expect(harness.engine.kind == .native)
    #expect(loaded.target == target)
    #expect(loaded.history == episode)
    #expect(loaded.startSeconds == 600)
    #expect(loaded.exactStart)
    #expect(loaded.rate == 2.5)
}

@MainActor @Test func aPausedPlayerIsStillPausedOnTheOtherEngine() throws {
    let harness = Harness()
    harness.router.open(request)
    harness.engine.currentTime = 42
    harness.engine.pause()
    harness.router.select(.mpv)
    #expect(try #require(harness.engine.loads.last).autoplay == false)
}

// MARK: - IOS-POC-26: which starts are exact

@MainActor @Test func onlyAPositionAnEngineReportedIsLandedOnExactly() throws {
    // An opened item — a history resume point here — keeps AVPlayer's keyframe start, so opening
    // a title starts no slower than it did.
    let harness = Harness()
    harness.router.open(PlaybackLoadRequest(target: target, startSeconds: 120, history: episode))
    #expect(try #require(harness.engine.loads.last).exactStart == false)
    // Moved before the engine reported anything: still the opened start, with its precision.
    harness.engine.currentTime = 0
    #expect(harness.router.startupTimedOut())
    let moved = try #require(harness.engine.loads.last)
    #expect(moved.startSeconds == 120)
    #expect(!moved.exactStart)
    // Moved after it played: exactly where it was, fraction included.
    harness.engine.currentTime = 247.36
    harness.router.select(.native)
    let switched = try #require(harness.engine.loads.last)
    #expect(switched.startSeconds == 247.36)
    #expect(switched.exactStart)
    // A speed change keeps the stored start's precision rather than claiming one.
    harness.router.open(request)
    harness.router.setRate(2)
    harness.router.reload(at: 0, autoplay: false)
    // The next episode, and a reload at the request's own start, are not positions reached.
    #expect(try #require(harness.engine.loads.last).exactStart == false)
}

// MARK: - Classification

@Test func formatCodecAndDecoderFailuresAreEngineCapabilityFailures() {
    for code in [-11828, -11829, -11833, -11821] {
        #expect(PlaybackFailure.classify(avError(code)).allowsEngineFallback, "AVError \(code)")
    }
    for code in [-14, -15, -17, -18, PlaybackFailure.mpvNoFirstFrame] {
        let error = NSError(domain: PlaybackFailure.mpvDomain, code: code)
        #expect(PlaybackFailure.classify(error).allowsEngineFallback, "mpv \(code)")
    }
}

/// IOS-POC-17F (user decision 2026-09-24): whatever an engine could not play, the other is tried.
@Test func networkAndUnknownFailuresNowTryTheOtherEngine() {
    let cases: [(String, PlaybackFailure)] = [
        ("403 behind a format error", .classify(avError(-11828), httpStatus: 403)),
        ("404", .classify(avError(-11800), httpStatus: 404)),
        ("5xx", .classify(avError(-11800), httpStatus: 503)),
        ("timeout", .classify(avError(-11800, underlying: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))),
        ("DNS", .classify(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost))),
        ("DNS lookup", .classify(NSError(domain: NSURLErrorDomain, code: NSURLErrorDNSLookupFailed))),
        ("TLS", .classify(NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed))),
        ("certificate", .classify(NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted))),
        ("connection lost", .classify(NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost))),
        ("AVError unknown", .classify(avError(-11800))),
        ("DRM", .classify(avError(-11831))),
        ("mpv loading failed", .classify(NSError(domain: PlaybackFailure.mpvDomain, code: -13))),
        ("mpv nothing to play", .classify(NSError(domain: PlaybackFailure.mpvDomain, code: -16))),
    ]
    for (name, failure) in cases {
        #expect(failure.allowsEngineFallback, "\(name) should try the other engine")
    }
    // The kinds still decide the message: a 403 behind a format error stays a network failure.
    #expect(PlaybackFailure.classify(avError(-11828), httpStatus: 403) == .network("HTTP 403"))
}

@Test func offlineAndSourceFailuresNeverSwitchEngines() {
    for code in [NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff] {
        let failure = PlaybackFailure.classify(avError(-11800, underlying: NSError(domain: NSURLErrorDomain, code: code)))
        #expect(failure == .offline)
        #expect(!failure.allowsEngineFallback, "no engine plays through \(code)")
    }
    for failure in [PlaybackFailure.source("這一集沒有可播放的網址"), .source("嗅探逾時"), .source("Spider script error")] {
        #expect(!failure.allowsEngineFallback, "the resolver failed before any engine was involved")
    }
}

@Test func theHTTPStatusIsReadFromAnAVPlayerErrorLogEvent() {
    #expect(PlaybackFailure.httpStatus(statusCode: -12660, comment: "HTTP 403: Forbidden") == 403)
    #expect(PlaybackFailure.httpStatus(statusCode: -12938, comment: "HTTP 404: File Not Found") == 404)
    #expect(PlaybackFailure.httpStatus(statusCode: 410, comment: nil) == 410)
    #expect(PlaybackFailure.httpStatus(statusCode: -12642, comment: "Playlist parse error") == nil)
    #expect(PlaybackFailure.httpStatus(statusCode: 0, comment: "HTTP 200") == nil)
}

// MARK: - Automatic fallback

@MainActor @Test func aCapabilityFailureFallsBackOnceKeepingPositionAndTarget() throws {
    let harness = Harness()
    harness.router.open(request)
    harness.engine.currentTime = 90
    harness.engine.fail(avError(-11828))
    #expect(harness.engine.kind == .mpv)
    #expect(harness.router.selection.currentSessionEngine == .mpv)   // the bar shows the real one
    #expect(harness.router.selection.globalDefaultEngine == .native)
    let loaded = try #require(harness.engine.loads.last)
    #expect(loaded.target == target)
    #expect(loaded.startSeconds == 90)
    #expect(loaded.exactStart)
    #expect(harness.router.failure == nil)
}

@MainActor @Test func theFallbackEngineFailingDoesNotBounceBack() {
    let harness = Harness()
    var shown: PlaybackFailure?
    harness.router.onUnrecoverable = { shown = $0 }
    harness.router.open(request)
    harness.engine.fail(avError(-11833))
    let mpv = harness.engine
    mpv.fail(NSError(domain: PlaybackFailure.mpvDomain, code: -17))
    #expect(harness.engine === mpv, "no second switch")
    #expect(harness.made.count == 2)
    #expect(shown?.allowsEngineFallback == true)
    #expect(harness.router.failure != nil)
}

@MainActor @Test func mpvFallsBackToAVPlayerToo() {
    let harness = Harness(globalDefault: .mpv)
    harness.router.open(request)
    harness.engine.fail(NSError(domain: PlaybackFailure.mpvDomain, code: PlaybackFailure.mpvNoFirstFrame))
    #expect(harness.engine.kind == .native)
}

@MainActor @Test func aNetworkFailureTriesTheOtherEngineOnceThenIsShown() {
    let harness = Harness()
    var shown: PlaybackFailure?
    harness.router.onUnrecoverable = { shown = $0 }
    harness.router.open(request)
    harness.engine.fail(avError(-11800), httpStatus: 403)
    #expect(harness.engine.kind == .mpv, "a 403 on AVPlayer may be its headers; MPV sends them its own way")
    #expect(shown == nil)
    harness.engine.fail(NSError(domain: PlaybackFailure.mpvDomain, code: -13), httpStatus: 403)
    #expect(harness.engine.kind == .mpv, "no second switch")
    #expect(harness.made.count == 2)
    #expect(shown == .network("HTTP 403"))
}

@MainActor @Test func offlineIsShownWithoutSwitching() {
    let harness = Harness()
    var shown: PlaybackFailure?
    harness.router.onUnrecoverable = { shown = $0 }
    harness.router.open(request)
    harness.engine.fail(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
    #expect(harness.engine.kind == .native)
    #expect(harness.made.count == 1)
    #expect(shown == .offline)
}

@MainActor @Test func aStartThatNeverComesTriesTheOtherEngineOnce() throws {
    let harness = Harness()
    var shown: PlaybackFailure?
    harness.router.onUnrecoverable = { shown = $0 }
    harness.router.open(PlaybackLoadRequest(target: target, startSeconds: 120, history: episode))
    harness.engine.isPlaying = false
    #expect(harness.router.startupTimedOut())
    #expect(harness.engine.kind == .mpv)
    let moved = try #require(harness.engine.loads.last)
    #expect(moved.target == target && moved.startSeconds == 120 && moved.autoplay)
    // The fallback engine slow too: nothing more happens, and nothing is shown — it may still start.
    #expect(!harness.router.startupTimedOut())
    #expect(harness.engine.kind == .mpv)
    #expect(shown == nil && harness.router.failure == nil)
    // The next episode is a new attempt with its own budget.
    harness.router.open(request)
    #expect(harness.router.startupTimedOut())
    #expect(harness.engine.kind == .native)
}

@MainActor @Test func withoutASecondEngineASlowStartIsLeftAlone() {
    let harness = Harness(available: [.native])
    harness.router.open(request)
    #expect(!harness.router.startupTimedOut())
    #expect(harness.made.count == 1)
    #expect(harness.router.failure == nil)
}

@MainActor @Test func theNextEpisodeGetsItsOwnFallback() {
    let harness = Harness()
    harness.router.open(request)
    harness.engine.fail(avError(-11828))          // native → mpv
    harness.router.open(request)                   // next episode, a new attempt on mpv
    harness.engine.fail(NSError(domain: PlaybackFailure.mpvDomain, code: -17))
    #expect(harness.engine.kind == .native)
}

@MainActor @Test func withoutASecondEngineACapabilityFailureIsShown() {
    let harness = Harness(available: [.native])
    var shown: PlaybackFailure?
    harness.router.onUnrecoverable = { shown = $0 }
    harness.router.open(request)
    harness.engine.fail(avError(-11828))
    #expect(harness.engine.kind == .native)
    #expect(shown?.allowsEngineFallback == true)
}

@MainActor @Test func aRetiredEngineCannotReportIntoTheRouter() {
    let harness = Harness()
    harness.router.open(request)
    let native = harness.engine
    harness.router.select(.mpv)
    native.fail(avError(-11828))                   // late callback from the torn-down engine
    #expect(harness.engine.kind == .mpv)
    #expect(harness.made.count == 2)
}

@MainActor @Test func theRouterNeverAsksForASecondResolution() {
    let harness = Harness()
    harness.router.open(request)
    harness.router.select(.mpv)
    harness.router.select(.native)
    // Every load is the one target the session handed over — nothing resolved it again.
    #expect(harness.made.flatMap(\.loads).allSatisfy { $0.target == target })
}

// MARK: - IOS-POC-23: reloading after a suspension

@MainActor @Test func aReloadLoadsTheSameItemPausedOnTheSameEngine() throws {
    let harness = Harness()
    harness.router.open(request)
    let native = harness.engine
    harness.router.setRate(2)
    harness.router.reload(at: 1234, autoplay: false)
    // What reopening the player does: a new load on the same engine, not a new engine.
    #expect(harness.engine === native)
    #expect(harness.made.count == 1)
    #expect(!native.tornDown)
    #expect(native.loads.count == 2)
    let loaded = try #require(native.loads.last)
    #expect(loaded.target == target)
    #expect(loaded.history == episode)
    #expect(loaded.startSeconds == 1234)
    #expect(loaded.exactStart)
    #expect(loaded.rate == 2)
    #expect(!loaded.autoplay, "a reload never starts playback by itself")
}

@MainActor @Test func aReloadNeitherSpendsNorRenewsTheFallback() throws {
    let harness = Harness()
    var shown: PlaybackFailure?
    harness.router.onUnrecoverable = { shown = $0 }
    harness.router.open(request)
    harness.router.reload(at: 60, autoplay: false)
    #expect(!harness.router.selection.fallbackSpent)
    harness.engine.fail(avError(-11800), httpStatus: 403)
    #expect(harness.engine.kind == .mpv, "the reload left this attempt's one switch in place")
    #expect(try #require(harness.engine.loads.last).autoplay == false, "and the switch stays paused")
    harness.router.reload(at: 60, autoplay: false)
    harness.engine.fail(NSError(domain: PlaybackFailure.mpvDomain, code: -13))
    #expect(harness.made.count == 2, "a reload is not a new attempt: the spent switch stays spent")
    #expect(shown != nil)
}

@MainActor @Test func aReloadAtZeroIsTheStartNotTheResumePoint() throws {
    // A viewer who scrubbed back to 0:00, or a live stream going back to its edge, is not sent to
    // where the item was first opened.
    let harness = Harness()
    harness.router.open(PlaybackLoadRequest(target: target, startSeconds: 300, rate: 1.5,
                                            title: "片名 EP08", history: episode))
    harness.router.reload(at: 0, autoplay: false)
    #expect(try #require(harness.engine.loads.last).startSeconds == 0)
}

@MainActor @Test func playPressedDuringAReloadThenAFallbackComesBackPaused() throws {
    // The session's play goes straight to the engine, so the router still holds the reload's
    // autoplay; the accepted cost is that a later switch lands paused rather than playing on its own.
    let harness = Harness()
    harness.router.open(request)
    harness.router.reload(at: 60, autoplay: false)
    harness.engine.play()
    harness.engine.fail(avError(-11828))
    let loaded = try #require(harness.engine.loads.last)
    #expect(harness.engine.kind == .mpv)
    #expect(loaded.startSeconds == 60)
    #expect(!loaded.autoplay)
}

// MARK: - MPV headers

@Test func everyHeaderReachesMPVAsOneField() {
    let fields = MPVRequestHeaders.fields(target.headers)
    #expect(fields == ["Cookie: SESSDATA=x", "Referer: https://www.bilibili.com/",
                       "User-Agent: Mozilla/5.0 (KHTML, like Gecko)"])
    #expect(MPVRequestHeaders.fields(["X-Bad": "a\r\nHost: evil"]).isEmpty)
    #expect(MPVRequestHeaders.fields([:]).isEmpty)
}
