import Foundation

/// IOS-POC-17 — the two internal playback engines, and everything about choosing between them that
/// can be decided without touching AVFoundation or libmpv.
///
/// **The engines only execute media.** Resolution (`SourceClient`, CSP, Python, drpy, JS spiders,
/// `MediaSniffer`), line, quality, `WatchHistory`, resume, opening/ending, auto-next and the next
/// episode's prefetch all stay above them in `PlaybackSession`. An engine is handed a resolved
/// `PlaybackTarget` and asked to play it; it never resolves one.

// MARK: - Engines

public enum PlaybackEngineKind: String, CaseIterable, Sendable, Codable {
    /// AVPlayer / AVFoundation — the primary engine, and the default.
    case native
    /// libmpv through MPVKit — the compatibility engine.
    case mpv

    /// The full name, for the settings row and the menu.
    public var displayName: String { self == .native ? "原生播放器" : "MPV" }
    /// The control bar's label: the engine **actually** playing, not the configured default.
    public var shortName: String { self == .native ? "原生" : "MPV" }
    public var other: PlaybackEngineKind { self == .native ? .mpv : .native }

    /// Whether the control bar offers AirPlay while this engine plays: the bar hides what the
    /// running engine cannot do instead of drawing a dead control. MPV's AirPlay Audio remains a
    /// later stage.
    public var supportsAirPlay: Bool { self == .native }
}

// MARK: - The global default

/// `globalDefaultEngine`, kept in the same `UserDefaults` the rest of the app's settings use.
///
/// Only the global default is stored. A session's override is deliberately never written anywhere:
/// it ends with the player.
public struct PlaybackEnginePreference: Sendable {
    public static let key = "webhtv.playback.defaultEngine"
    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The stored choice, or AVPlayer when nothing (or something unreadable) is stored.
    public var globalDefaultEngine: PlaybackEngineKind {
        defaults.string(forKey: Self.key).flatMap(PlaybackEngineKind.init(rawValue:)) ?? .native
    }

    public func setGlobalDefaultEngine(_ kind: PlaybackEngineKind) {
        defaults.set(kind.rawValue, forKey: Self.key)
    }
}

// MARK: - Which engine plays now

/// `globalDefaultEngine`, the session's manual override, and `currentSessionEngine` — the one
/// actually playing — kept apart, because each answers a different question.
///
/// - The global default decides how a **new** session starts.
/// - A manual choice in the control bar overrides it **for this session only** and is cleared when
///   the player closes.
/// - An automatic fallback moves `currentSessionEngine` too, at most **once per attempt**.
public struct PlaybackEngineSelection: Sendable, Equatable {
    public private(set) var globalDefaultEngine: PlaybackEngineKind
    public private(set) var currentSessionEngine: PlaybackEngineKind
    /// Whether this attempt already fell back. The loop guard: AVPlayer → MPV → AVPlayer → … is
    /// impossible because the second failure finds this set.
    public private(set) var fallbackSpent = false

    /// Both engines in every build since IOS-POC-17E, so there is no availability to consult.
    public init(globalDefault: PlaybackEngineKind) {
        globalDefaultEngine = globalDefault
        currentSessionEngine = globalDefault
    }

    /// A player opened from closed: the session starts from the global default.
    public mutating func startSession() {
        currentSessionEngine = globalDefaultEngine
        fallbackSpent = false
    }

    /// Another item inside the same session — the next episode, a picked episode. The engine the
    /// session is on stays; only the fallback budget is new.
    public mutating func beginAttempt() { fallbackSpent = false }

    /// The control bar's choice. Returns whether anything changed.
    @discardableResult
    public mutating func choose(_ kind: PlaybackEngineKind) -> Bool {
        guard kind != currentSessionEngine else { return false }
        currentSessionEngine = kind
        fallbackSpent = false
        return true
    }

    /// The engine to fall back to after `failure`, or nil when this failure must be shown instead.
    public mutating func fallback(after failure: PlaybackFailure) -> PlaybackEngineKind? {
        guard failure.allowsEngineFallback, !fallbackSpent else { return nil }
        let next = currentSessionEngine.other
        fallbackSpent = true
        currentSessionEngine = next
        return next
    }

    /// The player closed. The override goes with it; the next session starts from the default.
    public mutating func endSession() {
        fallbackSpent = false
    }

    /// The settings page. Takes effect at the next session, never under a playing one.
    public mutating func setGlobalDefault(_ kind: PlaybackEngineKind) { globalDefaultEngine = kind }
}

// MARK: - Failures

/// Why a playback attempt failed, in the kinds that decide what happens next.
///
/// **Whatever an engine could not play, the other engine is tried — once per attempt**
/// (IOS-POC-17F, the user's decision on 2026-09-24, replacing 17B's "capability failures only").
/// 17B reasoned that a network failure fails the same way in either engine. It often does, but not
/// reliably enough to give up on: AVPlayer sends a source's headers through an undocumented asset
/// option that has never been confirmed on a device, while MPV sends them as `http-header-fields`,
/// so a 403 on one may play on the other; their HLS, TLS and HTTP stacks (CFNetwork against
/// FFmpeg) are different code. What makes trying cheap is that the attempt is bounded: one switch,
/// never back again (`PlaybackEngineSelection.fallback(after:)`).
///
/// Two kinds never switch: **offline**, which no engine can play through, and **source**, which is
/// the resolver's failure before any engine was involved. The kinds still pick the message.
public enum PlaybackFailure: Sendable, Equatable {
    /// The media arrived and this engine cannot handle it: container, codec, decoder, or an output
    /// that never produced a picture.
    case engineCapability(String)
    /// DNS, timeout, TLS/certificate, a dropped connection, or an HTTP status.
    case network(String)
    /// No connection at all (IOS-POC-17F) — the one engine failure the other engine cannot fix.
    case offline
    /// No usable `PlaybackTarget`: resolver, `SourceClient`, spider or sniffer.
    case source(String)
    /// Anything the classifier cannot place. It may fall back like the rest; the once-per-attempt
    /// budget is what stops it bouncing between engines.
    case unclassified(String)

    public var allowsEngineFallback: Bool {
        switch self {
        case .engineCapability, .network, .unclassified: return true
        case .offline, .source: return false
        }
    }

    /// One line for the player's error overlay.
    public var message: String {
        switch self {
        case .engineCapability(let detail): return "這個播放器無法播放此影片（\(detail)）"
        case .network(let detail): return "網路錯誤：\(detail)"
        case .offline: return "沒有網路連線"
        case .source(let detail): return detail
        case .unclassified(let detail): return "無法播放：\(detail)"
        }
    }

    /// The error domain `MPVEngine` reports libmpv's own codes under.
    public static let mpvDomain = "mpv"
    /// `MPVEngine`'s own code: the file loaded but no frame ever reached the video output.
    public static let mpvNoFirstFrame = 1

    /// `AVError` codes that mean "the bytes arrived and AVFoundation cannot play them"
    /// (`AVFoundation/AVError.h`): decode failed, file format not recognized, failed to parse,
    /// decoder not found. `Unknown`, DRM, `FailedToLoadMediaData` and `ServerIncorrectlyConfigured`
    /// are deliberately absent — none of them is something the other engine can fix.
    static let avCapabilityCodes: Set<Int> = [-11821, -11828, -11829, -11833]
    /// libmpv (`client.h`): AO/VO init failed, unknown format, unsupported — plus this app's own
    /// "no first frame". `LOADING_FAILED` and `NOTHING_TO_PLAY` are absent: an HTML page or a 403
    /// produces those just as readily as a real codec gap does.
    static let mpvCapabilityCodes: Set<Int> = [-14, -15, -17, -18, mpvNoFirstFrame]

    /// Classifies what an engine reported.
    ///
    /// `httpStatus` is evidence the engine gathered alongside the error (AVPlayer's error log). It
    /// is checked **first**: a 403 that comes back as an HTML page also makes AVFoundation say
    /// "format not recognized", and that must stay a network failure.
    public static func classify(_ error: Error, httpStatus: Int? = nil) -> PlaybackFailure {
        if let httpStatus, (400...599).contains(httpStatus) { return .network("HTTP \(httpStatus)") }
        let chain = Self.chain(error as NSError)
        if let url = chain.first(where: { $0.domain == NSURLErrorDomain }) {
            if [NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed,
                NSURLErrorInternationalRoamingOff].contains(url.code) { return .offline }
            return .network(networkDetail(url.code))
        }
        if let av = chain.first(where: { $0.domain == "AVFoundationErrorDomain" }),
           avCapabilityCodes.contains(av.code) {
            return .engineCapability("AVFoundation \(av.code)")
        }
        if let mpv = chain.first(where: { $0.domain == mpvDomain }), mpvCapabilityCodes.contains(mpv.code) {
            return .engineCapability(mpv.code == mpvNoFirstFrame ? "沒有畫面" : "mpv \(mpv.code)")
        }
        return .unclassified((error as NSError).localizedDescription)
    }

    /// The HTTP status an `AVPlayerItemErrorLogEvent` carries, if any. AVFoundation reports HTTP
    /// failures under `CoreMediaErrorDomain` with its own negative code and the status only in the
    /// comment (`"HTTP 403: Forbidden"`), so both are read. The one string parse in the whole
    /// classifier, and it lives here rather than anywhere near the UI.
    public static func httpStatus(statusCode: Int, comment: String?) -> Int? {
        if (400...599).contains(statusCode) { return statusCode }
        guard let comment, let range = comment.range(of: #"HTTP (\d{3})"#, options: .regularExpression)
        else { return nil }
        return Int(comment[range].dropFirst(5)).flatMap { (400...599).contains($0) ? $0 : nil }
    }

    /// The error and everything under it, outermost first.
    private static func chain(_ error: NSError) -> [NSError] {
        var errors = [error]
        var next = error.userInfo[NSUnderlyingErrorKey] as? NSError
        while let current = next, errors.count < 8 {
            errors.append(current)
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return errors
    }

    private static func networkDetail(_ code: Int) -> String {
        switch code {
        case NSURLErrorTimedOut: return "連線逾時"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "找不到主機"
        case NSURLErrorNetworkConnectionLost: return "網路中斷"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorClientCertificateRejected:
            return "安全連線失敗"
        default: return "NSURLError \(code)"
        }
    }
}

// MARK: - The engine contract

/// What one load asks of an engine. The target is the one `SourceClient` resolved — URL, headers
/// and quality menu unchanged — and `history` rides along untouched so a switch provably keeps the
/// same title, line, episode and quality.
public struct PlaybackLoadRequest: Sendable, Equatable {
    public let target: PlaybackTarget
    /// Seconds from the start. Zero plays from the beginning.
    public let startSeconds: Double
    public let rate: Float
    public let autoplay: Bool
    public let title: String
    public let history: WatchHistory?
    /// IOS-POC-26: `startSeconds` is a position an engine actually reported — a switch, a fallback
    /// or a reload after the item had played — so AVPlayer lands on it exactly instead of on the
    /// keyframe before it (04:07 became 04:00 in IOS-POC-17). mpv's `start` is exact either way.
    /// An opened item (history resume, opening skip, quality change) keeps the cheaper start, and so
    /// does a move made before the engine reported anything: its start is still the opened one.
    public let exactStart: Bool

    public init(target: PlaybackTarget, startSeconds: Double = 0, rate: Float = 1,
                autoplay: Bool = true, title: String = "", history: WatchHistory? = nil,
                exactStart: Bool = false) {
        self.target = target
        self.startSeconds = startSeconds
        self.rate = rate
        self.autoplay = autoplay
        self.title = title
        self.history = history
        self.exactStart = exactStart
    }

    /// The same media, somewhere else and possibly at another speed — what a switch loads.
    func resumed(at seconds: Double, rate: Float, autoplay: Bool, exact: Bool) -> PlaybackLoadRequest {
        .init(target: target, startSeconds: seconds, rate: rate, autoplay: autoplay,
              title: title, history: history, exactStart: exact)
    }

    /// IOS-POC-52 (F12): the same request at another address — a downloaded episode whose loopback
    /// server came back on another port. The quality entry that named the old address names the new.
    func moved(to url: URL) -> PlaybackLoadRequest {
        let qualities = target.qualities.map { $0.url == target.url ? PlaybackQuality(name: $0.name, url: url) : $0 }
        let moved = PlaybackTarget(url: url, headers: target.headers, qualities: qualities, position: target.position,
                                   defaultIndex: target.defaultIndex, subtitles: target.subtitles)
        return .init(target: moved, startSeconds: startSeconds, rate: rate, autoplay: autoplay,
                     title: title, history: history, exactStart: exactStart)
    }
}

/// The states `player.status` reports, and nothing finer.
public enum PlaybackEngineState: Sendable, Equatable {
    case idle, preparing, ready, playing, buffering
}

/// One engine. Seconds throughout, zero when a value is unknown or the stream is live.
@MainActor
public protocol PlaybackEngine: AnyObject {
    var kind: PlaybackEngineKind { get }
    func load(_ request: PlaybackLoadRequest)
    func play()
    func pause()
    /// `landed` once the engine is there — or once a later seek or another item took its place,
    /// which moves the playhead away from where it was just as well (IOS-POC-36.1).
    func seek(toSeconds seconds: Double, landed: @escaping @MainActor () -> Void)
    var currentTime: Double { get }
    var duration: Double { get }
    /// What is playing now: zero while paused.
    var rate: Float { get }
    func setRate(_ rate: Float)
    var volume: Float { get set }
    var isLoaded: Bool { get }
    var isPlaying: Bool { get }
    var state: PlaybackEngineState { get }
    /// The end of the buffered range that contains the playhead, on the media's timeline.
    var bufferedUntil: Double? { get }
    /// The engine reports; `PlayerRouter` classifies and decides. The `Int` is HTTP-status
    /// evidence the engine found alongside the error, if any.
    var onFailure: ((Error, Int?) -> Void)? { get set }
    var onEnded: (() -> Void)? { get set }
    /// Embedded audio/subtitle choices changed (initial load, selection, or engine-driven change).
    var onMediaSelectionChange: ((PlaybackMediaSelection) -> Void)? { get set }
    /// Engine-neutral embedded track metadata used by the shared player panels.
    func mediaSelection() async -> PlaybackMediaSelection
    /// Select one embedded audio/subtitle option. The option id is opaque outside the engine adapter.
    func selectMedia(_ kind: PlaybackMediaKind, id: String) async
    /// IOS-POC-45: the playback session's downloaded subtitles, and the one to show (nil keeps the
    /// engine's own selection). Kept across every load of this engine — a reload or a quality
    /// switch puts them back — and listed after the embedded ones in `mediaSelection()`. An empty
    /// list takes them all away. `PlayerRouter` hands a fresh engine the same list before its load.
    func setExternalSubtitles(_ subtitles: [PlaybackExternalSubtitle], selectedID: String?)
    /// IOS-POC-45B: the viewer's timing correction (`SubtitleDelay`), for every subtitle the engine
    /// draws itself and every file it loads after this. `PlayerRouter` hands a fresh engine the
    /// same value before its load.
    func setSubtitleDelay(_ seconds: Double)
    /// IOS-POC-45E: hide the subtitles the engine draws itself, while the playhead is inside an ad
    /// a downloaded file has no lines for.
    func setSubtitleHidden(_ hidden: Bool)
    /// Stops and releases everything. The engine is not used again afterwards.
    func teardown()
}

public extension PlaybackEngine {
    func seek(toSeconds seconds: Double) { seek(toSeconds: seconds) {} }
    /// An engine that cannot show a side-loaded subtitle ignores the list.
    func setExternalSubtitles(_ subtitles: [PlaybackExternalSubtitle], selectedID: String?) {}
    /// An engine that draws no subtitle it could move ignores the correction (AVPlayer: the
    /// player screen's overlay applies it to the downloaded file).
    func setSubtitleDelay(_ seconds: Double) {}
    func setSubtitleHidden(_ hidden: Bool) {}
}

// MARK: - IOS-POC-22: speeds AVPlayer cannot play

/// Which speeds need the other engine. `AVPlayerItem.h`: every ready item plays at 1.0–2.0× even
/// when `canPlayFastForward` is NO, and that property is what says whether it can go above 2.0×.
/// Without it, measured on the simulator (2026-09-24), AVPlayer drops its whole buffer at 2.5× and
/// 3× and keeps waiting and jumping, however large the forward buffer is.
public enum PlaybackRateSupport {
    public static let nativeLimit: Float = 2

    public static func needsOtherEngine(rate: Float, canPlayFastForward: Bool) -> Bool {
        rate > nativeLimit && !canPlayFastForward
    }
}

// MARK: - The router

/// Opens a request on the engine the selection says, moves it to the other engine on a manual
/// switch or a classified failure, and keeps the request identical across the move — same target,
/// headers and history; the position and speed it had reached.
///
/// It resolves nothing. When a target has become unusable, that is the failure it reports; asking
/// `SourceClient` again is the session's decision, not the router's.
@MainActor
public final class PlayerRouter {
    public private(set) var selection: PlaybackEngineSelection
    public private(set) var engine: PlaybackEngine?
    public private(set) var request: PlaybackLoadRequest?
    public private(set) var failure: PlaybackFailure?
    /// Whether a player session is open. `open` starts one when it is not.
    public private(set) var sessionActive = false
    /// IOS-POC-36: why the engine now under the request was handed it — `open`, `viewer`,
    /// `startup-timeout` or the classified failure — for the `[playback]` line the session writes.
    public private(set) var switchReason = ""

    public var onEngineChange: ((PlaybackEngineKind) -> Void)?
    public var onEnded: (() -> Void)?
    public var onMediaSelectionChange: ((PlaybackMediaSelection) -> Void)?
    /// A failure that will be shown rather than recovered from.
    public var onUnrecoverable: ((PlaybackFailure) -> Void)?

    private let makeEngine: (PlaybackEngineKind) -> PlaybackEngine

    public init(globalDefault: PlaybackEngineKind,
                makeEngine: @escaping (PlaybackEngineKind) -> PlaybackEngine) {
        selection = PlaybackEngineSelection(globalDefault: globalDefault)
        self.makeEngine = makeEngine
    }

    /// A new item: a title opened from the list, the next episode, a picked episode.
    public func open(_ request: PlaybackLoadRequest) {
        if sessionActive {
            selection.beginAttempt()
        } else {
            selection.startSession()
            sessionActive = true
        }
        failure = nil
        self.request = request
        switchReason = "open"
        run(request)
    }

    /// The control bar's choice, or the session's when the engine cannot play the speed asked
    /// (IOS-POC-22). Changes this session only. `playing` is the play/pause state to carry when the
    /// caller knows it better than `isPlaying` does — a player waiting for data is not playing, but
    /// the viewer did not pause it.
    @discardableResult
    public func select(_ kind: PlaybackEngineKind, playing: Bool? = nil) -> Bool {
        guard request != nil, selection.choose(kind) else { return false }
        failure = nil
        switchReason = "viewer"
        handOff(autoplay: playing ?? engine?.isPlaying ?? true)
        return true
    }

    /// IOS-POC-17F: how long an engine may take, from being handed a request, to actually playing
    /// before the other engine is tried. Long enough for a slow resolve-to-first-segment on a weak
    /// line; short enough that a stream that will never start is not waited on for a minute.
    ///
    /// IOS-POC-27A: **5 s for AVPlayer, at the viewer's request (2026-09-26)** — a line AVPlayer
    /// cannot open sat black for 20 s before MPV took it. The one start measured so far took about
    /// 6 s on a slow simulator network (IOS-POC-15), so a slow AVPlayer start that would have
    /// played can now go to MPV instead; the viewer chose that trade. MPV keeps 20 s: it is the
    /// compatibility engine, and its slow start is not handed to the engine less likely to play it.
    /// IOS-POC-27A-1: **10 s for AVPlayer, at the viewer's request (2026-10-06)** — 5 s gave up on
    /// lines AVPlayer would have started.
    /// Only time the viewer means it to play counts (`PlaybackStartupWatch`).
    ///
    /// `nonisolated`: it reads no state, and `PlayerRouter` is main-actor isolated.
    nonisolated public static func startupTimeout(for kind: PlaybackEngineKind) -> Double {
        kind == .native ? 10 : 20
    }

    /// The session saw the engine not start playing within `startupTimeout(for:)`: try the other
    /// engine, if this attempt has not already switched. Answers whether it did.
    ///
    /// **Never shown as a failure.** The engine may still start — a slow start is not an error — so
    /// when no switch is possible nothing happens, and playback is left to begin when it can.
    @discardableResult
    public func startupTimedOut() -> Bool {
        guard request != nil,
              selection.fallback(after: .engineCapability("沒有開始播放")) != nil else { return false }
        switchReason = "startup-timeout"
        handOff(autoplay: true)
        return true
    }

    /// The speed the viewer picked, so a switch carries it even while paused.
    public func setRate(_ rate: Float) {
        if let request { self.request = request.resumed(at: request.startSeconds, rate: rate,
                                                         autoplay: request.autoplay,
                                                         exact: request.exactStart) }
        engine?.setRate(rate)
    }

    /// IOS-POC-36: the viewer's play or pause, so a fallback after a failure keeps it. The engine
    /// that failed cannot say: AVPlayer's rate is already zero by the time its item reports the
    /// failure, and a pause pressed while the item was still starting left `autoplay` saying play.
    public func setIntendsToPlay(_ playing: Bool) {
        guard let request, request.autoplay != playing else { return }
        self.request = request.resumed(at: request.startSeconds, rate: request.rate, autoplay: playing,
                                       exact: request.exactStart)
    }

    public func setGlobalDefault(_ kind: PlaybackEngineKind) { selection.setGlobalDefault(kind) }

    /// IOS-POC-23: the same request again on the engine it is on, at `seconds` — what closing and
    /// reopening the player does, without closing it. Zero is a real position here (the start, or a
    /// live stream's edge), not "unknown": the caller already chose. The selection is left alone,
    /// so this attempt's fallback is neither spent nor renewed. `url` replaces the address when the
    /// one loaded no longer answers (IOS-POC-52 F12).
    public func reload(at seconds: Double, autoplay: Bool, url: URL? = nil) {
        guard var request else { return }
        if let url { request = request.moved(to: url) }
        failure = nil
        // IOS-POC-26: the session passes the request's own start back for an item still preparing;
        // any other position is one the engine reached.
        let exact = seconds == request.startSeconds ? request.exactStart : seconds > 0
        let again = request.resumed(at: max(seconds, 0), rate: request.rate, autoplay: autoplay,
                                    exact: exact)
        self.request = again
        run(again)
    }

    /// The player closed. A running engine the next session would not start on is released.
    public func endSession() {
        sessionActive = false
        selection.endSession()
        var next = selection
        next.startSession()
        if let engine, engine.kind != next.currentSessionEngine {
            engine.teardown()
            self.engine = nil
        }
    }

    /// IOS-POC-45: the playback session's downloaded subtitles. Held here, not in an engine, so
    /// that an engine switch, a fallback or a startup timeout hands the engine taking over the
    /// same files and the same choice — the viewer never downloads one twice for one video.
    public private(set) var externalSubtitles = [PlaybackExternalSubtitle]()
    public private(set) var selectedExternalSubtitleID: String?

    /// The subtitle session's list changed: a file was added (and, with `selectedID`, chosen), or
    /// the session ended (an empty list).
    public func setExternalSubtitles(_ subtitles: [PlaybackExternalSubtitle], selectedID: String?) {
        externalSubtitles = subtitles
        selectedExternalSubtitleID = subtitles.contains(where: { $0.id == selectedID }) ? selectedID : nil
        engine?.setExternalSubtitles(subtitles, selectedID: selectedExternalSubtitleID)
        // The session ended: the next video starts on its own timing.
        if subtitles.isEmpty {
            // The session ended: the next video starts on its own timing.
            subtitleDelay = 0
            subtitleDelayLinedUp = false
            subtitleAdMapping = true
        }
        refreshSubtitleTiming()
    }

    /// IOS-POC-45B: the viewer's timing correction for this video's subtitles, kept here for the
    /// same reason as the files: the engine taking over keeps it. Always the viewer's own value,
    /// on the programme's clock; what an engine is given is `effectiveSubtitleTiming`.
    public private(set) var subtitleDelay = 0.0

    public func setSubtitleDelay(_ seconds: Double) {
        subtitleDelay = SubtitleDelay.clamped(seconds)
        subtitleDelayLinedUp = selectedExternalSubtitleID != nil
        refreshSubtitleTiming()
    }

    /// The viewer set the value for this video against the downloaded file, by eye on the file's
    /// clock of that moment.
    private var subtitleDelayLinedUp = false

    /// IOS-POC-45E: the item's ads, as far as the engine's clock is the ad plan's (`.none`
    /// otherwise). The session sets it from 智慧去廣's plan.
    public private(set) var subtitleClock = SubtitleAdClock.none
    /// The viewer's switch for this video: off for a file timed to a copy that had the ads in.
    public private(set) var subtitleAdMapping = true
    private var appliedSubtitleTiming: (delay: Double, hidden: Bool)?

    /// The clock a subtitle is looked up on now: the ads' for a downloaded file, unless the viewer
    /// turned it off; `.none` for an embedded track, which is timed to the stream itself.
    public var activeSubtitleClock: SubtitleAdClock {
        subtitleAdMapping && selectedExternalSubtitleID != nil ? subtitleClock : .none
    }

    /// The item's ads changed (a plan arrived, a new item cleared it, an engine's clock stopped
    /// matching). A value the viewer lined up against the downloaded file is rebased so the file
    /// keeps the timing it had, whichever track is on screen now, and a plan arriving late does not
    /// undo that; it is not rounded, so a clock cleared and restored (a quality switch) gives the
    /// same value back. A value nobody lined up is left alone: then the mapping is the whole
    /// correction.
    ///
    /// Inside an ad: the clock being left counts that whole ad, as the engine was given it; the
    /// clock arriving counts only the ads already over, since a value lined up by eye without the
    /// mapping was lined up before this ad.
    public func setSubtitleClock(_ clock: SubtitleAdClock) {
        guard clock != subtitleClock else { return }
        let position = subtitlePosition
        let before = fileSubtitleClock.engineDelay(user: 0, at: position)
        subtitleClock = clock
        let after = fileSubtitleClock.adSeconds(endedBy: position)
        if subtitleDelayLinedUp, before != after {
            subtitleDelay = min(max(subtitleDelay + before - after, -SubtitleDelay.limit), SubtitleDelay.limit)
        }
        refreshSubtitleTiming()
    }

    /// The clock the downloaded file is looked up on, whichever track is selected now.
    private var fileSubtitleClock: SubtitleAdClock { subtitleAdMapping ? subtitleClock : .none }

    /// Where the engine is, or — while it has reported nothing since a load (MPV reads 0 until
    /// its file opens) — where it was asked to start, as `PlaybackSession.position` reads it.
    private var subtitlePosition: Double {
        guard let engine else { return 0 }
        let reported = engine.currentTime
        return reported > 0 || engine.duration > 0 ? reported : request?.startSeconds ?? 0
    }

    /// Not rebased: turning it over has to show its effect.
    public func setSubtitleAdMapping(_ enabled: Bool) {
        subtitleAdMapping = enabled
        refreshSubtitleTiming()
    }

    /// What the engine is given at `position`: the viewer's correction plus the ads already begun,
    /// hidden inside one.
    public func effectiveSubtitleTiming(at position: Double) -> (delay: Double, hidden: Bool) {
        let clock = activeSubtitleClock
        return (clock.engineDelay(user: subtitleDelay, at: position), clock.isInsideAd(position))
    }

    /// Hands the engine the timing for `position` (`subtitlePosition`, when nil) if it changed. The
    /// session calls this as the playhead moves and before every seek, so an ad crossed by playing
    /// on or by a seek moves the subtitles with it.
    public func refreshSubtitleTiming(at position: Double? = nil) {
        guard let engine else { return }
        let timing = effectiveSubtitleTiming(at: position ?? subtitlePosition)
        if let applied = appliedSubtitleTiming, applied.delay == timing.delay, applied.hidden == timing.hidden { return }
        appliedSubtitleTiming = timing
        engine.setSubtitleDelay(timing.delay)
        engine.setSubtitleHidden(timing.hidden)
    }

    /// The panel's choice, through here so the online one is remembered for the next engine.
    /// Choosing an embedded track or 「關閉」 forgets it.
    public func selectMedia(_ kind: PlaybackMediaKind, id: String) async {
        if kind == .subtitle {
            selectedExternalSubtitleID = externalSubtitles.contains(where: { $0.id == id }) ? id : nil
            refreshSubtitleTiming()
        }
        await engine?.selectMedia(kind, id: id)
    }

    /// `player.control("stop")`: drop what is loaded.
    public func stop() {
        engine?.teardown()
        engine = nil
        appliedSubtitleTiming = nil
        onMediaSelectionChange?(PlaybackMediaSelection())
    }

    // MARK: Internals

    private func run(_ request: PlaybackLoadRequest) {
        let kind = selection.currentSessionEngine
        if engine?.kind != kind {
            engine?.teardown()
            let fresh = makeEngine(kind)
            fresh.onFailure = { [weak self, weak fresh] error, status in
                guard let self, let fresh, self.engine === fresh else { return }
                self.engineFailed(error, httpStatus: status)
            }
            fresh.onEnded = { [weak self, weak fresh] in
                guard let self, let fresh, self.engine === fresh else { return }
                self.onEnded?()
            }
            fresh.onMediaSelectionChange = { [weak self, weak fresh] selection in
                guard let self, let fresh, self.engine === fresh else { return }
                self.onMediaSelectionChange?(selection)
            }
            engine = fresh
            // IOS-POC-45: before the load, so the engine has them when its file opens.
            fresh.setExternalSubtitles(externalSubtitles, selectedID: selectedExternalSubtitleID)
            appliedSubtitleTiming = nil
            refreshSubtitleTiming(at: request.startSeconds)
            onEngineChange?(kind)
        }
        engine?.load(request)
    }

    private func engineFailed(_ error: Error, httpStatus: Int?) {
        let classified = PlaybackFailure.classify(error, httpStatus: httpStatus)
        guard selection.fallback(after: classified) != nil else {
            failure = classified
            onUnrecoverable?(classified)
            return
        }
        // Playing or paused as the viewer last left it (IOS-POC-36, `setIntendsToPlay`).
        switchReason = "failure: \(classified.message)"
        handOff(autoplay: request?.autoplay ?? true)
    }

    /// Carries the request to `selection.currentSessionEngine` at the position it had reached.
    private func handOff(autoplay: Bool) {
        guard let request else { return }
        // Zero is "nothing reported yet", as it always was here; the request's own start stands
        // then, with its own precision (IOS-POC-26). IOS-POC-36 (IOS-POC-26 RC2): the position is
        // read whether or not the engine still counts as loaded — MPV marks a file that failed
        // mid-play unloaded before it reports the failure, and the fallback went back to where the
        // item had been opened instead of where it failed. An engine keeps no position from a file
        // before the one it is loading (`MPVPlayerCore`), so a stale one cannot be carried either.
        let reached = engine.flatMap { $0.currentTime > 0 ? $0.currentTime : nil }
        let resumed = request.resumed(at: reached ?? request.startSeconds,
                                      rate: request.rate, autoplay: autoplay,
                                      exact: reached != nil || request.exactStart)
        self.request = resumed
        run(resumed)
    }
}

// MARK: - MPV request headers

/// The headers a target needs, as libmpv's `http-header-fields` entries.
///
/// **Every header goes into that one list, `User-Agent` and `Referer` included.** FFmpeg only adds
/// its own `User-Agent`/`Referer` when the custom headers do not already carry them, and its HLS
/// demuxer copies the same `headers` option onto every playlist and segment request. Using mpv's
/// separate `user-agent`/`referrer` options instead would leave a previous source's values set on
/// the next load, since neither has a reset.
public enum MPVRequestHeaders {
    public static func fields(_ headers: [String: String]) -> [String] {
        headers
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .compactMap { key, value in
                // A CR or LF would end the header early and inject whatever follows. Scalars, not
                // `Character`s: Swift reads "\r\n" as one grapheme that equals neither "\r" nor "\n".
                guard !key.isEmpty,
                      !(key + value).unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" })
                else { return nil }
                return "\(key): \(value)"
            }
    }
}
