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

    /// What the control bar may offer while this engine plays. The engines do not need parity on
    /// day one; the bar hides what the running engine cannot do instead of drawing dead controls.
    public var capabilities: PlaybackEngineCapabilities {
        switch self {
        case .native:
            return .init(airPlay: true, trackSelection: true)
        case .mpv:
            // Subtitle/audio track selection is the MPV engine's second stage. AirPlay (and Picture
            // in Picture, which only the AVKit surface can start) belong to AVKit.
            return .init(airPlay: false, trackSelection: false)
        }
    }
}

public struct PlaybackEngineCapabilities: Sendable, Equatable {
    public let airPlay: Bool
    /// The subtitle and audio menus.
    public let trackSelection: Bool
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
///
/// An engine that is not available (MPV before it has passed its device gate) can be stored as the
/// default but is never *used*: the session resolves it to AVPlayer, which is always available.
public struct PlaybackEngineSelection: Sendable, Equatable {
    public private(set) var globalDefaultEngine: PlaybackEngineKind
    public private(set) var sessionOverride: PlaybackEngineKind?
    public private(set) var currentSessionEngine: PlaybackEngineKind
    public let available: Set<PlaybackEngineKind>
    /// Whether this attempt already fell back. The loop guard: AVPlayer → MPV → AVPlayer → … is
    /// impossible because the second failure finds this set.
    public private(set) var fallbackSpent = false

    public init(globalDefault: PlaybackEngineKind, available: Set<PlaybackEngineKind>) {
        let available = available.union([.native])
        self.available = available
        globalDefaultEngine = globalDefault
        currentSessionEngine = available.contains(globalDefault) ? globalDefault : .native
    }

    public func isAvailable(_ kind: PlaybackEngineKind) -> Bool { available.contains(kind) }

    /// A player opened from closed: the session starts from the global default.
    public mutating func startSession() {
        sessionOverride = nil
        currentSessionEngine = isAvailable(globalDefaultEngine) ? globalDefaultEngine : .native
        fallbackSpent = false
    }

    /// Another item inside the same session — the next episode, a picked episode. The engine the
    /// session is on stays; only the fallback budget is new.
    public mutating func beginAttempt() { fallbackSpent = false }

    /// The control bar's choice. Returns whether anything changed.
    @discardableResult
    public mutating func choose(_ kind: PlaybackEngineKind) -> Bool {
        guard isAvailable(kind), kind != currentSessionEngine else { return false }
        sessionOverride = kind
        currentSessionEngine = kind
        fallbackSpent = false
        return true
    }

    /// The engine to fall back to after `failure`, or nil when this failure must be shown instead.
    public mutating func fallback(after failure: PlaybackFailure) -> PlaybackEngineKind? {
        guard failure.allowsEngineFallback, !fallbackSpent else { return nil }
        let next = currentSessionEngine.other
        guard isAvailable(next) else { return nil }
        fallbackSpent = true
        currentSessionEngine = next
        return next
    }

    /// The player closed. The override goes with it; the next session starts from the default.
    public mutating func endSession() {
        sessionOverride = nil
        fallbackSpent = false
    }

    /// The settings page. Takes effect at the next session, never under a playing one.
    public mutating func setGlobalDefault(_ kind: PlaybackEngineKind) { globalDefaultEngine = kind }
}

// MARK: - Failures

/// Why a playback attempt failed, in the four kinds that decide what happens next.
///
/// **Only an engine capability failure may change engines.** Everything upstream of the engine —
/// DNS, timeouts, TLS, an HTTP status, an expired address, a resolver, a spider, the sniffer, a
/// missing `Referer` — fails the same way in either engine, so switching would only hide it.
public enum PlaybackFailure: Sendable, Equatable {
    /// The media arrived and this engine cannot handle it: container, codec, decoder, or an output
    /// that never produced a picture.
    case engineCapability(String)
    /// DNS, timeout, TLS/certificate, offline, or an HTTP status.
    case network(String)
    /// No usable `PlaybackTarget`: resolver, `SourceClient`, spider or sniffer.
    case source(String)
    /// Anything the classifier cannot place. Never a fallback — guessing would be how a 403 ends up
    /// bouncing between engines.
    case unclassified(String)

    public var allowsEngineFallback: Bool {
        if case .engineCapability = self { return true }
        return false
    }

    /// One line for the player's error overlay.
    public var message: String {
        switch self {
        case .engineCapability(let detail): return "這個播放器無法播放此影片（\(detail)）"
        case .network(let detail): return "網路錯誤：\(detail)"
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
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return "網路中斷"
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

    public init(target: PlaybackTarget, startSeconds: Double = 0, rate: Float = 1,
                autoplay: Bool = true, title: String = "", history: WatchHistory? = nil) {
        self.target = target
        self.startSeconds = startSeconds
        self.rate = rate
        self.autoplay = autoplay
        self.title = title
        self.history = history
    }

    /// The same media, somewhere else and possibly at another speed — what a switch loads.
    func resumed(at seconds: Double, rate: Float, autoplay: Bool) -> PlaybackLoadRequest {
        .init(target: target, startSeconds: seconds, rate: rate, autoplay: autoplay,
              title: title, history: history)
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
    func seek(toSeconds seconds: Double)
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
    /// Stops and releases everything. The engine is not used again afterwards.
    func teardown()
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

    public var onEngineChange: ((PlaybackEngineKind) -> Void)?
    public var onEnded: (() -> Void)?
    /// A failure that will be shown rather than recovered from.
    public var onUnrecoverable: ((PlaybackFailure) -> Void)?

    private let makeEngine: (PlaybackEngineKind) -> PlaybackEngine

    public init(globalDefault: PlaybackEngineKind, available: Set<PlaybackEngineKind>,
                makeEngine: @escaping (PlaybackEngineKind) -> PlaybackEngine) {
        selection = PlaybackEngineSelection(globalDefault: globalDefault, available: available)
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
        run(request)
    }

    /// The control bar's choice. Changes this session only.
    @discardableResult
    public func select(_ kind: PlaybackEngineKind) -> Bool {
        guard request != nil, selection.choose(kind) else { return false }
        failure = nil
        handOff(autoplay: engine?.isPlaying ?? true)
        return true
    }

    /// The speed the viewer picked, so a switch carries it even while paused.
    public func setRate(_ rate: Float) {
        if let request { self.request = request.resumed(at: request.startSeconds, rate: rate,
                                                         autoplay: request.autoplay) }
        engine?.setRate(rate)
    }

    public func setGlobalDefault(_ kind: PlaybackEngineKind) { selection.setGlobalDefault(kind) }

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

    /// `player.control("stop")`: drop what is loaded.
    public func stop() {
        engine?.teardown()
        engine = nil
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
            engine = fresh
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
        // The attempt meant to play, so the fallback plays.
        handOff(autoplay: request?.autoplay ?? true)
    }

    /// Carries the request to `selection.currentSessionEngine` at the position it had reached.
    private func handOff(autoplay: Bool) {
        guard let request else { return }
        let reached = engine.map { $0.isLoaded ? $0.currentTime : request.startSeconds }
            ?? request.startSeconds
        let resumed = request.resumed(at: reached > 0 ? reached : request.startSeconds,
                                      rate: request.rate, autoplay: autoplay)
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
