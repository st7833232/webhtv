import Accelerate
import AVKit
import CoreText
import Libmpv
import SwiftUI
import UIKit
import WebHTVCore

/// IOS-POC-17 — libmpv as the second playback engine.
///
/// The render path is MPVKit 1.0.0's own iOS demo, the one IOS-POC-9G proved on the simulator:
/// the view's `CAMetalLayer` is mpv's `wid`, `vo=gpu-next` on Vulkan/MoltenVK. It executes media
/// and nothing else — the target arrives resolved, and history, resume, the ending and auto-next
/// stay in `PlaybackSession`.
///
/// Picture in Picture (IOS-POC-17H) is the one exception to "Metal only": see `MPVPictureInPicture`.
@MainActor
final class MPVEngine: PlaybackEngine {
    let kind = PlaybackEngineKind.mpv
    let view = MPVVideoView()
    var onFailure: ((Error, Int?) -> Void)?
    var onEnded: (() -> Void)?
    var onMediaSelectionChange: ((PlaybackMediaSelection) -> Void)?
    private var pictureInPicture: MPVPictureInPicture?

    private let core: MPVPlayerCore
    /// Raised once per load if the file loaded and no frame reached the output — the black
    /// screen the device showed before 9G, now a classified failure instead of a silent one.
    private var firstFrameWatchdog: Task<Void, Never>?
    private var observers = [NSObjectProtocol]()
    /// User playback intent, independent of transient buffering and libmpv property callback timing.
    /// The app-wide idle timer follows this only while the app is in the foreground.
    private var playbackIntendsToRun = false
    private var lastAudioDiagnostic = ""
    /// IOS-POC-36: a seek asked for and not yet landed (mpv restarts playback once it has). Until
    /// then it is the position, as AVPlayer's `currentTime()` is: a second ±10 s pressed before
    /// mpv's `time-pos` caught up counted from where the first one started, not where it went.
    /// Bounded, because a seek mpv refuses (a live stream) restarts nothing; by then mpv's own
    /// `time-pos` reads the target of any seek it did take.
    private var seekAsked: (seconds: Double, at: ContinuousClock.Instant)?
    private static let seekAskedLimit: Duration = .seconds(2)
    private var seeksLanding = [@MainActor () -> Void]()

    /// Long enough for a slow first segment; the watchdog only starts once the file has loaded.
    private static let firstFrameTimeout: Duration = .seconds(10)
    /// IOS-POC-17H-2: the Metal picture waits for mpv's first frame after Picture in Picture…
    private(set) var awaitingMetalFrame = false
    private var metalReveal: Task<Void, Never>?
    /// …or this long once the app is active, if that frame is never announced (the user's choice,
    /// 2026-09-29; the simulator's rebuild took 0.4-0.7 s).
    private static let metalRevealTimeout: Duration = .seconds(1)

    init() {
        core = MPVPlayerCore(layer: view.metalLayer)
        core.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        // MPVKit's demo: a Metal layer that goes to the background comes back black unless the
        // video track is released and taken again.
        // Not while Picture in Picture has the video: that window is fed on the CPU (17H), and
        // releasing the track would freeze it.
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self, core] _ in
            MainActor.assumeIsolated {
                // MPV draws into our own Metal view, so unlike AVPlayerViewController it does not
                // automatically keep the display awake. Release the app-wide idle-timer override
                // while backgrounded; PiP has its own system-managed playback presentation.
                self?.setDisplaySleepPrevented(false)
                guard self?.pictureInPicture?.isActive != true else { return }
                core.setVideoTrackEnabled(false)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self, core] _ in
            MainActor.assumeIsolated {
                core.setVideoTrackEnabled(true)
                guard let self else { return }
                self.setDisplaySleepPrevented(self.playbackIntendsToRun)
            }
        })
        let pictureInPicture = MPVPictureInPicture(engine: self, core: core, layer: view.sampleBufferLayer)
        pictureInPicture.onActiveChange = { active in
            // IOS-POC-36.2: the session hears it now, not when SwiftUI next updates the screen.
            PlaybackSession.shared.pictureInPictureActive = active
        }
        self.pictureInPicture = pictureInPicture
    }

    func load(_ request: PlaybackLoadRequest) {
        firstFrameWatchdog?.cancel()
        lastAudioDiagnostic = ""
        seekAsked = nil
        seeksLanding = []
        onMediaSelectionChange?(PlaybackMediaSelection())
        pictureInPicture?.setHasVideo(false)   // until the file says otherwise
        // AVKit prevents display sleep for AVPlayer playback. MPV owns a custom Metal surface, so
        // iOS sees no system video controller and would dim/lock the screen after the normal idle
        // interval unless the app explicitly holds the idle timer while playback is intended.
        setPlaybackIntent(request.autoplay)
        // IOS-POC-24: an engine switch that keeps playing reaches here without the session's play.
        if request.autoplay { PlaybackSession.activateAudioSession() }
        core.load(url: request.target.url.absoluteString,
                  headerFields: MPVRequestHeaders.fields(request.target.headers),
                  startSeconds: request.startSeconds, rate: request.rate, autoplay: request.autoplay)
    }

    func play() {
        // IOS-POC-24: mpv no longer activates the session itself, and the Picture in Picture
        // window's play button comes here without passing through the session.
        PlaybackSession.activateAudioSession()
        setPlaybackIntent(true)
        core.setPaused(false)
    }
    func pause() {
        core.setPaused(true)
        setPlaybackIntent(false)
    }
    /// IOS-POC-36.1: `PLAYBACK_RESTART` says the seeks asked so far have landed. A seek on an mpv
    /// that already reached EOF has nothing to land on and never calls back; the next load drops it.
    func seek(toSeconds seconds: Double, landed: @escaping @MainActor () -> Void) {
        seeksLanding.append(landed)
        seekAsked = (max(seconds, 0), .now)
        core.seek(to: max(seconds, 0))
    }
    func setRate(_ rate: Float) { core.setSpeed(rate) }

    /// IOS-POC-36: nothing while a file loads — a playhead still queued from the file before it is
    /// not this one's (IOS-POC-26 RC4 read it as 0:00 or worse) — and, once a file failed, where it
    /// had got to, so the fallback resumes there (RC2) rather than where the item was opened.
    var currentTime: Double {
        let now = core.snapshot
        if now.loading { return 0 }
        if let seekAsked, ContinuousClock.now - seekAsked.at < Self.seekAskedLimit { return seekAsked.seconds }
        return now.loaded ? now.position : now.reached
    }
    var duration: Double { core.snapshot.duration }
    var rate: Float { core.snapshot.paused ? 0 : Float(core.snapshot.speed) }
    var isLoaded: Bool { core.snapshot.loaded }
    var isPlaying: Bool { core.snapshot.loaded && !core.snapshot.paused && !core.snapshot.buffering }
    var bufferedUntil: Double? { core.snapshot.cacheEnd }
    var volume: Float {
        get { Float(core.snapshot.volume / 100) }
        set { core.setVolume(Double(newValue) * 100) }
    }
    var state: PlaybackEngineState {
        let now = core.snapshot
        if !now.loaded { return now.loading ? .preparing : .idle }
        if now.buffering { return .buffering }
        return now.paused ? .ready : .playing
    }

    func mediaSelection() async -> PlaybackMediaSelection { core.snapshot.mediaSelection }

    func selectMedia(_ kind: PlaybackMediaKind, id: String) async {
        await core.selectMedia(kind, id: id)
    }

    /// IOS-POC-45: mpv draws a downloaded subtitle itself, libass included (`sub-add`).
    func setExternalSubtitles(_ subtitles: [PlaybackExternalSubtitle], selectedID: String?) {
        core.setExternalSubtitles(subtitles, selectedID: selectedID)
    }

    func setSubtitleDelay(_ seconds: Double) {
        core.setSubtitleDelay(seconds)
    }

    func setSubtitleHidden(_ hidden: Bool) {
        core.setSubtitleHidden(hidden)
    }

    func teardown() {
        setPlaybackIntent(false)
        pictureInPicture?.invalidate()
        pictureInPicture = nil
        firstFrameWatchdog?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        onFailure = nil
        onEnded = nil
        onMediaSelectionChange = nil
        core.shutdown()
    }

    /// IOS-POC-36.5 (D12): the player screen closed with the window open. The engine outlives the
    /// screen while MPV is the default engine, and so would its window.
    func endPictureInPicture() { pictureInPicture?.end() }

    /// Keep buffering awake too: playback intent remains active while the network temporarily stops
    /// frames. Do not infer this from libmpv's snapshot — its property callbacks are asynchronous.
    private func setPlaybackIntent(_ running: Bool) {
        playbackIntendsToRun = running
        setDisplaySleepPrevented(running && UIApplication.shared.applicationState != .background)
    }

    /// IOS-POC-17H-2: Picture in Picture is taking the video. The Metal layer keeps its last frame
    /// and stretches it over any new bounds, so it is hidden, and AVKit's placeholder shows — the
    /// black screen with a line of text AVPlayer's own PiP leaves in the app.
    func coverMetalForPictureInPicture() {
        metalReveal?.cancel()
        metalReveal = nil
        awaitingMetalFrame = false
        view.showsMetal = false
    }

    /// Picture in Picture ended and the Metal output is being rebuilt: until mpv restarts playback
    /// on it, PiP's latest frame (under the Metal layer, at the right aspect) shows instead of the
    /// frame from before PiP. In the background the rebuild waits for the foreground, so the
    /// timeout does too.
    func revealMetalAfterPictureInPicture() {
        awaitingMetalFrame = true
        metalReveal?.cancel()
        metalReveal = Task { @MainActor [weak self] in
            while UIApplication.shared.applicationState != .active {
                guard (try? await Task.sleep(for: .milliseconds(100))) != nil else { return }
            }
            guard (try? await Task.sleep(for: Self.metalRevealTimeout)) != nil else { return }
            self?.revealMetal()
        }
    }

    /// Faded in over a few frames: the picture underneath is the software output's last frame,
    /// rendered for the PiP window, and a cut to the GPU's would read as a flash.
    private func revealMetal() {
        metalReveal?.cancel()
        metalReveal = nil
        awaitingMetalFrame = false
        view.showsMetal = true
        // Only once Metal is opaque may the layer take the black frame it holds ready for the next
        // window (IOS-POC-17H-3: enqueued any earlier, it showed through as a black flash).
        view.fadeMetalIn { [weak self] in self?.pictureInPicture?.refreshPlaceholder() }
    }

    /// `UIApplication.isIdleTimerDisabled` is app-wide, so every MPV lifecycle exit must release it.
    private func setDisplaySleepPrevented(_ prevented: Bool) {
        guard UIApplication.shared.isIdleTimerDisabled != prevented else { return }
        UIApplication.shared.isIdleTimerDisabled = prevented
    }

    private func handle(_ event: MPVPlayerCore.Event) {
        switch event {
        case .fileLoaded(let hasVideo):
            pictureInPicture?.setHasVideo(hasVideo)
            guard hasVideo else { return }   // audio only: there will never be a frame to wait for
            firstFrameWatchdog?.cancel()
            firstFrameWatchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.firstFrameTimeout)
                guard !Task.isCancelled, let self else { return }
                self.onFailure?(NSError(domain: PlaybackFailure.mpvDomain,
                                        code: PlaybackFailure.mpvNoFirstFrame), nil)
            }
        case .videoReconfigured(let width, let height):
            firstFrameWatchdog?.cancel()
            // Zero is the track being released, not a new shape: the last shape stays.
            if width > 0, height > 0 {
                pictureInPicture?.videoSizeChanged(width: width, height: height)
                view.videoSize = CGSize(width: width, height: height)
            }
        case .playbackRestarted:
            if awaitingMetalFrame { revealMetal() }
            let landing = seeksLanding
            seeksLanding = []
            landing.forEach { $0() }
            if let asked = seekAsked {
                seekAsked = nil
                let landed = String(format: "%.1f", core.snapshot.position)
                PlaybackSession.log.notice("[playback] seek landed \(landed, privacy: .public)s asked \(String(format: "%.1f", asked.seconds), privacy: .public)s on MPV")
            }
        case .mediaSelectionChanged(let selection):
            onMediaSelectionChange?(selection)
            reportAudioDiagnostics(selection)
        case .ended:
            // IOS-POC-36: the file before this load reaching its end after `loadfile … replace` was
            // sent. Taken as the new file's, it advanced once more and skipped the new episode.
            guard !core.snapshot.loading else {
                PlaybackSession.log.notice("[playback] mpv end of the previous file ignored: the next one is loading")
                return
            }
            seekAsked = nil
            setPlaybackIntent(false)
            pictureInPicture?.setHasVideo(false)   // mpv is idle now; the next load says again
            onEnded?()
        case .failed(let code):
            setPlaybackIntent(false)
            pictureInPicture?.setHasVideo(false)
            firstFrameWatchdog?.cancel()
            onFailure?(NSError(domain: PlaybackFailure.mpvDomain, code: Int(code)), nil)
        }
    }

    private func reportAudioDiagnostics(_ selection: PlaybackMediaSelection) {
        guard let selected = selection.audio?.selectedOption else { return }
        let codec = selected.codecDisplayName ?? "unknown"
        let count = selected.channelCount.map(String.init) ?? "unknown"
        let layout = selected.channelLayout ?? selected.channelDescription ?? "unknown"
        let line = "[audio] engine=MPV selected=\(selected.displayName)"
            + " id=\(selected.id) language=\(selected.language ?? "n/a")"
            + " codec=\(codec) channels=\(count) layout=\(layout)"
        guard line != lastAudioDiagnostic else { return }
        lastAudioDiagnostic = line
        PlaybackSession.log.notice("\(line, privacy: .public)")
    }
}

/// The MPV player's surface: the Metal layer mpv draws into, and under it the sample buffer layer
/// Picture in Picture takes its video from (IOS-POC-17H). Both follow the view's bounds, and mpv
/// follows the Metal layer's `drawableSize` (IOS-POC-17I): see `layoutSubviews`.
final class MPVVideoView: UIView {
    private let metalView = MPVMetalView()
    private let sampleBufferView = MPVSampleBufferView()
    var metalLayer: CAMetalLayer { metalView.layer as! CAMetalLayer }
    var sampleBufferLayer: AVSampleBufferDisplayLayer { sampleBufferView.layer as! AVSampleBufferDisplayLayer }
    private var laidOutSize = CGSize.zero
    /// IOS-POC-17H-2: whether mpv's Metal picture is on top. Off while Picture in Picture has the
    /// video and until the rebuilt output draws (`MPVEngine.coverMetalForPictureInPicture`).
    var showsMetal = true {
        didSet { metalView.isHidden = !showsMetal }
    }
    /// IOS-POC-17H-3: the video's display size (mpv's `dwidth`/`dheight`), which gives the
    /// sample-buffer layer the rectangle the picture actually occupies. AVKit animates the PiP
    /// window to and from that layer's whole frame: over the full bounds a 16:9 picture was blown
    /// up to fill a portrait screen and then snapped back into its bars. Nil until mpv says.
    var videoSize: CGSize? {
        didSet { if videoSize != oldValue { setNeedsLayout() } }
    }

    /// IOS-POC-17H-3: from transparent to opaque over 0.15 s, on top of the sample-buffer picture.
    func fadeMetalIn(completion: @escaping () -> Void) {
        metalView.alpha = 0
        UIView.animate(withDuration: 0.15, animations: { self.metalView.alpha = 1 }, completion: { _ in completion() })
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        sampleBufferLayer.videoGravity = .resizeAspect
        // Under the Metal layer, so inline it is covered; it is in the window, which is what lets
        // PiP start from it automatically.
        addSubview(sampleBufferView)
        addSubview(metalView)
    }

    required init?(coder: NSCoder) { fatalError("not used from a storyboard") }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalView.frame = bounds
        sampleBufferView.frame = videoSize.map { AVMakeRect(aspectRatio: $0, insideRect: bounds) } ?? bounds
        let size = bounds.size
        guard size.width > 1, size.height > 1, size != laidOutSize else { return }
        laidOutSize = size
        // WebHTV's Libmpv compares `drawableSize` on every pass of its video-output loop, at most
        // 100 ms apart even while paused, and on a change resizes its swapchain and redraws: no
        // rebuild and no seek (IOS-POC-17I, `third_party/mpv-ios/`).
        let scale = metalLayer.contentsScale
        metalLayer.drawableSize = CGSize(width: size.width * scale, height: size.height * scale)
    }
}

private final class MPVMetalView: UIView {
    override class var layerClass: AnyClass { MPVMetalLayer.self }
}

private final class MPVSampleBufferView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
}

/// MPVKit's demo layer override: MoltenVK sets `drawableSize` to 1×1 to force a presentation to
/// complete, which flickers and can leave the layer stuck there (mpv PR 13651).
private final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1, Int(newValue.height) > 1 { super.drawableSize = newValue }
        }
    }
}

struct MPVVideoSurface: UIViewRepresentable {
    let engine: MPVEngine
    func makeUIView(context: Context) -> MPVVideoView { engine.view }
    func updateUIView(_ view: MPVVideoView, context: Context) {}
    func makeCoordinator() -> MPVEngine { engine }
    /// IOS-POC-36.5 (D12), as with AVPlayer's surface: going away with the window open means the
    /// screen closed in Picture in Picture. An engine switch takes this surface down only after the
    /// engine itself, and its window, are torn down.
    static func dismantleUIView(_ view: MPVVideoView, coordinator engine: MPVEngine) {
        engine.endPictureInPicture()
    }
}

/// IOS-POC-45D — diagnosis only: what iOS keeps for PingFang, which IOS-POC-45A named as the
/// subtitle font. On iOS 18+ it resolves to `PingFangUI.ttc`, whose outlines are only in Apple's
/// `hvgl` table, so FreeType (and with it libass) cannot draw it. Logged once, as table flags.
enum MPVSubtitleFontCheck {
    static func pingFangTables() -> String {
        let font = CTFontCreateWithName("PingFang TC" as CFString, 12, nil)
        guard let tables = CTFontCopyAvailableTables(font, CTFontTableOptions(rawValue: 0)) else { return "none" }
        var tags = Set<UInt32>()
        for index in 0..<CFArrayGetCount(tables) {
            tags.insert(UInt32(UInt(bitPattern: CFArrayGetValueAtIndex(tables, index))))
        }
        func flag(_ name: String) -> String {
            let tag = name.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return "\(name.trimmingCharacters(in: .whitespaces))=\(tags.contains(tag) ? 1 : 0)"
        }
        return ["glyf", "CFF ", "CFF2", "hvgl"].map(flag).joined(separator: " ")
    }

    /// `iPhone16,2 iOS 26.0`, for the same line.
    static var device: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(machine) iOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

/// Everything that touches the mpv handle. Deliberately **not** actor-isolated: mpv calls back on
/// its own threads, and IOS-POC-9C/9G each crashed once for letting a callback inherit
/// `@MainActor`.
///
/// **The wakeup callback only schedules.** Draining events — or calling any other client API —
/// inside it is forbidden by `client.h` and is what kept the device black before IOS-POC-9G: the
/// callback runs under libmpv's own `wakeup_lock`. Every call into mpv, reads included, happens on
/// `queue`; the main actor only ever reads `snapshot`.
final class MPVPlayerCore: @unchecked Sendable {
    enum Event: Sendable {
        case fileLoaded(hasVideo: Bool)
        /// The display size, zero when there is no video output (the track was released).
        case videoReconfigured(width: Int, height: Int)
        case mediaSelectionChanged(PlaybackMediaSelection)
        /// Playback restarted after a seek, including the one an output rebuild makes: the first
        /// frame on the new output (IOS-POC-17H-2).
        case playbackRestarted
        case ended
        case failed(Int32)
    }

    struct Snapshot: Sendable {
        var loading = false
        var loaded = false
        var position: Double = 0
        var duration: Double = 0
        var paused = false
        var buffering = false
        var speed: Double = 1
        var volume: Double = 100
        var cacheEnd: Double?
        var mediaSelection = PlaybackMediaSelection()
        /// The last playhead the loaded file reported (IOS-POC-36); reset by every load.
        var reached: Double = 0
    }

    var onEvent: (@Sendable (Event) -> Void)?

    private var mpv: OpaquePointer?
    private let queue = DispatchQueue(label: "mpv.engine", qos: .userInitiated)
    private let lock = NSLock()
    private var state = Snapshot()
    /// The software output while Picture in Picture has the video (17H). `queue` only.
    private var software: MPVSoftwareRenderer?
    /// IOS-POC-45: the playback session's downloaded subtitles, added to every file this core
    /// loads — a `sub-add` belongs to the file, and `loadfile … replace` drops it — and the one to
    /// show. `queue` only.
    private var externals = [PlaybackExternalSubtitle]()
    private var selectedExternal: String?
    /// Every file this core has added, so one taken out of the list is taken off the file too.
    private var addedExternalPaths = Set<String>()
    /// IOS-POC-45D: this file's libass font failures and audio underruns, from mpv's warnings.
    /// `queue` only.
    private var fontErrors = 0
    private var fallbackMisses = 0
    private var underruns = 0

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// `layer` is mpv's window id and must outlive the handle; `MPVEngine.view` owns it.
    init(layer: CAMetalLayer) {
        guard let handle = mpv_create() else { return }
        var wid = Unmanaged.passUnretained(layer).toOpaque()
        mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid)
        mpv_set_option_string(handle, "vo", "gpu-next")
        mpv_set_option_string(handle, "gpu-api", "vulkan")
        mpv_set_option_string(handle, "gpu-context", "moltenvk")
        // The simulator has no VideoToolbox, and `auto-safe` does not fall back there (9C); on a
        // device it picks VideoToolbox. ponytail: the device cell of this is still unmeasured;
        // read `hwdec-current` on a device (MPV parity P1; logged per file as
        // `[playback] mpv hwdec-current=…`) and pin the decoder if `auto-safe` ends up in software.
        #if targetEnvironment(simulator)
        mpv_set_option_string(handle, "hwdec", "no")
        #else
        mpv_set_option_string(handle, "hwdec", "auto-safe")
        #endif
        mpv_set_option_string(handle, "video-rotate", "no")
        mpv_set_option_string(handle, "subs-fallback", "yes")
        // IOS-POC-45D: libass draws through FreeType, which cannot read iOS 18+'s PingFang (hvgl
        // outlines only): Chinese was boxes, and each missing character re-ran the font search on
        // every frame (the stutter). The bundled CFF subset is the style font of text subtitles and
        // the default for every ASS font not found; CoreText stays for what it does not cover.
        // Before `mpv_initialize`, so the renderer is set up with them once.
        var fontOptions = [String]()
        if let fonts = SubtitleFont.directory {
            fontOptions.append("dir=\(mpv_set_option_string(handle, "sub-fonts-dir", fonts.path))")
            fontOptions.append("font=\(mpv_set_option_string(handle, "sub-font", SubtitleFont.family))")
        }
        fontOptions.append("provider=\(mpv_set_option_string(handle, "sub-font-provider", "auto"))")
        let fontLine = "[subtitle] libass font bundled=\(SubtitleFont.directory == nil ? "missing" : "ok")"
            + " family=\(SubtitleFont.family) setopt \(fontOptions.joined(separator: " "))"
            + " device=\(MPVSubtitleFontCheck.device) pingfang \(MPVSubtitleFontCheck.pingFangTables())"
        Task { @MainActor in PlaybackSession.log.notice("\(fontLine, privacy: .public)") }
        // `render.h`'s advice for the software output Picture in Picture uses (17H). `sw-fast` is a
        // built-in profile (faster `sws`/`zimg` scalers, which the Metal output does not scale
        // with); as an option name it does not exist and is refused (MPV_ERROR_OPTION_NOT_FOUND).
        mpv_set_option_string(handle, "profile", "sw-fast")
        // IOS-POC-17H-4: the one screenshot the app takes (the still a PiP window opens on) comes
        // from the decoded frame on the CPU. gpu-next's own reads the picture back through
        // MoltenVK, and on the simulator that read-back trapped in the Metal driver
        // (`pl_tex_download` → `MTLSimDevice newBuffer…`).
        mpv_set_option_string(handle, "screenshot-sw", "yes")
        // IOS-POC-24: the app owns the one audio session both engines share. Left to itself, every
        // audio output mpv creates makes that session mixable and every one it drops deactivates it,
        // AVPlayer's playback included after a switch. WebHTV's Libmpv patch 0004 adds these options.
        for option in ["audiounit-skip-session-management", "avfoundation-skip-session-management"] {
            if mpv_set_option_string(handle, option, "yes") < 0 {
                Task { @MainActor in PlaybackSession.log.notice("[audio] mpv refused \(option, privacy: .public)") }
            }
        }
        guard mpv_initialize(handle) >= 0 else {
            mpv_terminate_destroy(handle)
            return
        }
        // IOS-POC-45D: warnings carry libass's font failures and the audio output's underruns;
        // they are counted per file (`countLogMessage`), never stored or logged as text.
        mpv_request_log_messages(handle, "warn")
        for (name, format) in [("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE),
                               ("pause", MPV_FORMAT_FLAG), ("paused-for-cache", MPV_FORMAT_FLAG),
                               ("speed", MPV_FORMAT_DOUBLE), ("volume", MPV_FORMAT_DOUBLE),
                               ("demuxer-cache-time", MPV_FORMAT_DOUBLE),
                               ("aid", MPV_FORMAT_STRING), ("sid", MPV_FORMAT_STRING),
                               ("track-list/count", MPV_FORMAT_INT64),
                               ("hwdec-current", MPV_FORMAT_STRING)] {
            mpv_observe_property(handle, 0, name, format)
        }
        mpv = handle
        mpv_set_wakeup_callback(handle, { ctx in
            guard let ctx else { return }
            let core = Unmanaged<MPVPlayerCore>.fromOpaque(ctx).takeUnretainedValue()
            core.queue.async { [weak core] in core?.drain() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func load(url: String, headerFields: [String], startSeconds: Double, rate: Float, autoplay: Bool) {
        // IOS-POC-23: the pause state this load sets, not the default. mpv reports `pause` only when
        // it changes, so a paused load onto a paused core would otherwise read as playing for good.
        update { $0 = Snapshot(loading: true, paused: !autoplay, speed: Double(rate), volume: $0.volume) }
        queue.async { [self] in
            guard let mpv else { return }
            // Headers are per source: clear the list, then append one entry at a time —
            // `change-list … append` takes the value whole, so a comma inside a User-Agent is safe.
            command(mpv, ["change-list", "http-header-fields", "clr", ""])
            for field in headerFields { command(mpv, ["change-list", "http-header-fields", "append", field]) }
            mpv_set_property_string(mpv, "start", startSeconds > 0 ? String(startSeconds) : "none")
            mpv_set_property_string(mpv, "speed", String(rate))
            mpv_set_property_string(mpv, "pause", autoplay ? "no" : "yes")
            command(mpv, ["loadfile", url, "replace"])
        }
    }

    func selectMedia(_ kind: PlaybackMediaKind, id: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                guard let mpv else { continuation.resume(); return }
                // IOS-POC-45: an online subtitle is shown by its track on this file, added first
                // if this file does not have it yet; choosing anything else forgets it.
                if kind == .subtitle {
                    if externals.contains(where: { $0.id == id }) {
                        selectedExternal = id
                        if snapshot.loaded { attachExternals(mpv, select: true) }
                        refreshMediaSelection(mpv)
                        continuation.resume()
                        return
                    }
                    selectedExternal = nil
                }
                let property = kind == .audio ? "aid" : "sid"
                let prefix = "mpv-\(kind.rawValue)-"
                let value: String
                if kind == .subtitle, id == PlaybackMediaOption.subtitleOffID {
                    value = "no"
                } else {
                    guard id.hasPrefix(prefix) else { continuation.resume(); return }
                    value = String(id.dropFirst(prefix.count))
                }
                mpv_set_property_string(mpv, property, value)
                refreshMediaSelection(mpv)
                continuation.resume()
            }
        }
    }

    /// IOS-POC-45B: `sub-delay` is an option, so it holds for every subtitle and every later file.
    /// IOS-POC-45E: the router sends the viewer's value plus the ads begun, so it changes as the
    /// playhead crosses an ad; a refusal is logged (fixed notation: mpv parses no exponent here).
    func setSubtitleDelay(_ seconds: Double) {
        queue.async { [self] in
            guard let mpv else { return }
            let value = String(format: "%.3f", seconds)
            let status = mpv_set_property_string(mpv, "sub-delay", value)
            if status < 0 {
                Task { @MainActor in PlaybackSession.log.notice("[subtitle] mpv refused sub-delay=\(value, privacy: .public) status=\(status)") }
            }
        }
    }

    /// IOS-POC-45E: hidden while the playhead is inside an ad a downloaded file has no lines for.
    func setSubtitleHidden(_ hidden: Bool) {
        set("sub-visibility", hidden ? "no" : "yes")
    }

    /// IOS-POC-45. With a file loaded the change applies now; otherwise at the next file's load.
    func setExternalSubtitles(_ subtitles: [PlaybackExternalSubtitle], selectedID: String?) {
        queue.async { [self] in
            externals = subtitles
            if let selectedID {
                selectedExternal = selectedID
            } else if !subtitles.contains(where: { $0.id == selectedExternal }) {
                selectedExternal = nil
            }
            guard let mpv, snapshot.loaded else { return }
            attachExternals(mpv, select: selectedID != nil)
            refreshMediaSelection(mpv)
        }
    }

    func setPaused(_ paused: Bool) { set("pause", paused ? "yes" : "no") }
    func setSpeed(_ rate: Float) { set("speed", String(rate)) }
    func setVolume(_ volume: Double) { set("volume", String(min(max(volume, 0), 100))) }
    func setVideoTrackEnabled(_ enabled: Bool) { set("vid", enabled ? "auto" : "no") }

    func seek(to seconds: Double) {
        queue.async { [self] in if let mpv { command(mpv, ["seek", String(seconds), "absolute+exact"]) } }
    }

    /// IOS-POC-17H-4 — the frame on screen now, subtitles included (`screenshot-raw`'s default flags,
    /// `player/screenshot.c`), onto `renderer`'s layer. A window opening next shows it until the
    /// software output's first frame, instead of the black placeholder. Only while Metal has the video.
    func showCurrentFrame(on renderer: MPVSoftwareRenderer) {
        queue.async { [self] in
            guard let mpv, software == nil else { return }
            var result = mpv_node()
            let status = "screenshot-raw".withCString { name in
                var args: [UnsafePointer<CChar>?] = [name, nil]
                return mpv_command_ret(mpv, &args, &result)
            }
            guard status >= 0 else { return }
            defer { mpv_free_node_contents(&result) }
            guard result.format == MPV_FORMAT_NODE_MAP, let map = result.u.list?.pointee,
                  let keys = map.keys, let values = map.values else { return }
            var width = 0, height = 0, stride = 0
            var bytes: UnsafeRawPointer?
            for index in 0..<Int(map.num) {
                guard let key = keys[index] else { continue }
                let value = values[index]
                switch String(cString: key) {
                case "w": width = Int(value.u.int64)
                case "h": height = Int(value.u.int64)
                case "stride": stride = Int(value.u.int64)
                case "data": bytes = value.u.ba.flatMap { UnsafeRawPointer($0.pointee.data) }
                default: break
                }
            }
            guard let bytes, stride >= width * 4 else { return }
            renderer.showStill(width: width, height: height, stride: stride, bytes: bytes)
        }
    }

    /// IOS-POC-17H — Picture in Picture is starting: move the video from Metal to `renderer`.
    ///
    /// The render context has to exist before `vo=libmpv`, or that output refuses to start
    /// (`vo_libmpv.c`: "No render context set."). Setting `vo` rebuilds the output at once, as in
    /// 17G. `vid=auto` covers the order in which iOS may deliver the two events: if the app already
    /// went to the background and released the track, this takes it again, on the CPU this time.
    func startSoftwareOutput(_ renderer: MPVSoftwareRenderer) {
        queue.async { [self] in
            guard let mpv, software == nil, renderer.attach(to: mpv) else { return }
            software = renderer
            mpv_set_property_string(mpv, "vo", "libmpv")
            mpv_set_property_string(mpv, "vid", "auto")
        }
    }

    /// Picture in Picture ended: back to Metal, then release the render context — in that order,
    /// because freeing it under a running `libmpv` output would disable video.
    ///
    /// In the background the GPU is off limits (Apple: "the system prevents those commands from
    /// executing"), so there the track is released first and `vo` only changes the option; the
    /// foreground observer takes the track again and the Metal output is built then.
    func stopSoftwareOutput(keepVideo: Bool) {
        queue.async { [self] in
            guard let mpv, let renderer = software else { return }
            if !keepVideo { mpv_set_property_string(mpv, "vid", "no") }
            mpv_set_property_string(mpv, "vo", "gpu-next")
            renderer.detach()
            software = nil
        }
    }

    /// Releases the handle off the main thread: `mpv_terminate_destroy` can block while the
    /// playloop winds down. The wakeup callback is removed first, under the same lock libmpv
    /// holds while calling it, so none is in flight afterwards.
    func shutdown() {
        queue.async { [self] in
            guard let handle = mpv else { return }
            // The render API requires its context freed before the core is destroyed.
            software?.detach()
            software = nil
            mpv = nil
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
            update { $0 = Snapshot() }
        }
    }

    // MARK: Internals (all on `queue`)

    private func set(_ name: String, _ value: String) {
        queue.async { [self] in if let mpv { mpv_set_property_string(mpv, name, value) } }
    }

    private func update(_ change: (inout Snapshot) -> Void) {
        lock.lock(); change(&state); lock.unlock()
    }

    private func drain() {
        while let mpv, let event = mpv_wait_event(mpv, 0), event.pointee.event_id != MPV_EVENT_NONE {
            switch event.pointee.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let property = event.pointee.data?.assumingMemoryBound(to: mpv_event_property.self).pointee
                else { break }
                let name = String(cString: property.name)
                record(property)
                // MPV parity P1: the decoder `hwdec` picked, once per file ("no" is software);
                // unavailable, and so not logged, between files.
                if name == "hwdec-current", property.format == MPV_FORMAT_STRING,
                   let value = property.data?.assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self).pointee {
                    let decoder = String(cString: value)
                    Task { @MainActor in PlaybackSession.log.notice("[playback] mpv hwdec-current=\(decoder, privacy: .public)") }
                }
                if name == "aid" || name == "sid" || name == "track-list/count" {
                    refreshMediaSelection(mpv)
                }
            case MPV_EVENT_FILE_LOADED:
                update { $0.loading = false; $0.loaded = true }
                // IOS-POC-45: the session's online subtitles go onto every file, the chosen one shown.
                if !externals.isEmpty { attachExternals(mpv, select: true) }
                refreshMediaSelection(mpv)
                let video = mpv_get_property_string(mpv, "current-tracks/video/id")
                defer { mpv_free(video) }
                onEvent?(.fileLoaded(hasVideo: video != nil))
            case MPV_EVENT_PLAYBACK_RESTART:
                onEvent?(.playbackRestarted)
            case MPV_EVENT_VIDEO_RECONFIG:
                var width: Int64 = 0, height: Int64 = 0
                mpv_get_property(mpv, "dwidth", MPV_FORMAT_INT64, &width)
                mpv_get_property(mpv, "dheight", MPV_FORMAT_INT64, &height)
                onEvent?(.videoReconfigured(width: Int(width), height: Int(height)))
            case MPV_EVENT_LOG_MESSAGE:
                if let message = event.pointee.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee,
                   let text = message.text {
                    countLogMessage(String(cString: text))
                }
            case MPV_EVENT_END_FILE:
                reportSubtitleHealth(mpv)
                guard let end = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                else { break }
                if end.reason == MPV_END_FILE_REASON_EOF {
                    onEvent?(.ended)
                } else if end.reason == MPV_END_FILE_REASON_ERROR {
                    update { $0.loading = false; $0.loaded = false }
                    onEvent?(.failed(end.error))
                }
            default:
                break
            }
        }
    }

    /// P10 — map mpv's native track-list to the engine-neutral WebHTV model. The id stored in
    /// each option is opaque to the UI; only this adapter turns it back into aid/sid.
    private func refreshMediaSelection(_ mpv: OpaquePointer) {
        let count = max(Int(intProperty(mpv, "track-list/count") ?? 0), 0)
        var audio = [PlaybackMediaOption]()
        var subtitles = [PlaybackMediaOption]()
        var selectedAudioFromList: String?
        var selectedSubtitleFromList: String?
        // IOS-POC-45: this session's online files, listed under their own ids after the embedded
        // tracks (`PlaybackMediaTrack.subtitles`), so an id means the same under either engine.
        let externalByPath = Dictionary(externals.map { (Self.comparablePath($0.fileURL.path), $0.id) },
                                        uniquingKeysWith: { first, _ in first })
        var externalByTrack = [Int64: String]()

        for index in 0..<count {
            let base = "track-list/\(index)"
            guard let type = stringProperty(mpv, "\(base)/type"),
                  let trackID = intProperty(mpv, "\(base)/id") else { continue }
            let selected = flagProperty(mpv, "\(base)/selected") ?? false
            let title = stringProperty(mpv, "\(base)/title")
            let language = stringProperty(mpv, "\(base)/lang")
            let codec = stringProperty(mpv, "\(base)/codec")
            let channelCount = intProperty(mpv, "\(base)/demux-channel-count").map(Int.init)
            let channelLayout = stringProperty(mpv, "\(base)/demux-channels")

            if type == "audio" {
                let id = "mpv-audio-\(trackID)"
                audio.append(.init(id: id, title: title, language: language, codec: codec,
                                   channelCount: channelCount, channelLayout: channelLayout,
                                   fallbackName: PlaybackMediaOption.localizedLanguageName(language)
                                       ?? "音軌 \(audio.count + 1)"))
                if selected { selectedAudioFromList = id }
            } else if type == "sub" {
                if flagProperty(mpv, "\(base)/external") == true,
                   let path = stringProperty(mpv, "\(base)/external-filename"),
                   let online = externalByPath[Self.comparablePath(path)] {
                    externalByTrack[trackID] = online
                    continue
                }
                let id = "mpv-subtitle-\(trackID)"
                subtitles.append(.init(id: id, title: title, language: language, codec: codec,
                                       fallbackName: PlaybackMediaOption.localizedLanguageName(language)
                                           ?? "字幕 \(subtitles.count + 1)"))
                if selected { selectedSubtitleFromList = id }
            }
        }

        let aid = stringProperty(mpv, "aid").flatMap(Int64.init)
            .map { "mpv-audio-\($0)" } ?? selectedAudioFromList
        let rawSID = stringProperty(mpv, "sid")
        let sid = rawSID.flatMap(Int64.init).map { "mpv-subtitle-\($0)" } ?? selectedSubtitleFromList
        if !subtitles.isEmpty {
            subtitles.insert(.init(id: PlaybackMediaOption.subtitleOffID, title: "關閉",
                                   isOff: true, fallbackName: "關閉"), at: 0)
        }

        let embedded = subtitles.isEmpty ? nil : PlaybackMediaTrack(
            options: subtitles,
            selectedID: sid ?? (rawSID == "no" ? PlaybackMediaOption.subtitleOffID : nil)
        )
        let selection = PlaybackMediaSelection(
            subtitle: .subtitles(embedded: embedded, external: externals,
                                 selectedExternalID: rawSID.flatMap(Int64.init).flatMap { externalByTrack[$0] }),
            audio: audio.isEmpty ? nil : PlaybackMediaTrack(options: audio, selectedID: aid)
        )
        var changed = false
        update {
            changed = $0.mediaSelection != selection
            $0.mediaSelection = selection
        }
        if changed { onEvent?(.mediaSelectionChanged(selection)) }
    }

    /// IOS-POC-45, on `queue` with a file loaded. Each wanted file the loaded one lacks is added, one
    /// no longer wanted is removed, and the chosen one is shown when `select` says so or a file was
    /// just added. Adding never changes what is shown otherwise: `subs-fallback` lets mpv pick an
    /// added track by itself, so the selection from before the add is put back.
    private func attachExternals(_ mpv: OpaquePointer, select: Bool) {
        let before = stringProperty(mpv, "sid")
        var present = externalTracks(mpv)
        let wanted = Set(externals.map { Self.comparablePath($0.fileURL.path) })
        for (path, id) in present where addedExternalPaths.contains(path) && !wanted.contains(path) {
            command(mpv, ["sub-remove", String(id)])
        }
        var added = false
        for external in externals where present[Self.comparablePath(external.fileURL.path)] == nil {
            // `auto`: added without being selected; the selection is set below, deliberately.
            var words = ["sub-add", external.fileURL.path, "auto", external.title]
            if let language = external.language { words.append(language) }
            command(mpv, words)
            addedExternalPaths.insert(Self.comparablePath(external.fileURL.path))
            added = true
        }
        if added { present = externalTracks(mpv) }
        if select || added, let chosen = selectedExternal,
           let file = externals.first(where: { $0.id == chosen }),
           let id = present[Self.comparablePath(file.fileURL.path)] {
            mpv_set_property_string(mpv, "sid", String(id))
        } else if added, let before {
            mpv_set_property_string(mpv, "sid", before)
        }
        let line = "[subtitle] mpv external files=\(externals.count) added=\(added) shown=\(selectedExternal ?? "none")"
        Task { @MainActor in PlaybackSession.log.notice("\(line, privacy: .public)") }
    }

    /// The loaded file's external subtitle tracks, by file.
    private func externalTracks(_ mpv: OpaquePointer) -> [String: Int64] {
        let count = max(Int(intProperty(mpv, "track-list/count") ?? 0), 0)
        var tracks = [String: Int64]()
        for index in 0..<count {
            let base = "track-list/\(index)"
            guard stringProperty(mpv, "\(base)/type") == "sub", flagProperty(mpv, "\(base)/external") == true,
                  let path = stringProperty(mpv, "\(base)/external-filename"),
                  let id = intProperty(mpv, "\(base)/id") else { continue }
            tracks[Self.comparablePath(path)] = id
        }
        return tracks
    }

    /// iOS's temporary directory is reached through the `/var` → `/private/var` link; mpv may
    /// report either spelling, so both sides are compared resolved.
    private static func comparablePath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func stringProperty(_ mpv: OpaquePointer, _ name: String) -> String? {
        guard let value = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }

    /// IOS-POC-45D: counts, and the first font file that failed (its name only). No line text.
    private func countLogMessage(_ text: String) {
        if text.contains("Error opening font") {
            fontErrors += 1
            if fontErrors == 1 {
                let path = text.split(separator: "'").dropFirst().first.map(String.init) ?? ""
                let name = (path as NSString).lastPathComponent
                Task { @MainActor in PlaybackSession.log.notice("[subtitle] libass could not open font \(name, privacy: .public)") }
            }
        } else if text.contains("failed to find any fallback") {
            fallbackMisses += 1
        } else if text.localizedCaseInsensitiveContains("underrun") {
            underruns += 1
        }
    }

    /// Once per file: whether subtitles cost fonts or audio, beside the frames dropped.
    private func reportSubtitleHealth(_ mpv: OpaquePointer) {
        let line = "[subtitle] mpv health fontErrors=\(fontErrors) fallbackMisses=\(fallbackMisses)"
            + " underruns=\(underruns) frameDrops=\(intProperty(mpv, "frame-drop-count").map(String.init) ?? "n/a")"
            + " decoderDrops=\(intProperty(mpv, "decoder-frame-drop-count").map(String.init) ?? "n/a")"
            + " sid=\(stringProperty(mpv, "sid") ?? "n/a")"
        fontErrors = 0
        fallbackMisses = 0
        underruns = 0
        Task { @MainActor in PlaybackSession.log.notice("\(line, privacy: .public)") }
    }

    private func intProperty(_ mpv: OpaquePointer, _ name: String) -> Int64? {
        var value: Int64 = 0
        return mpv_get_property(mpv, name, MPV_FORMAT_INT64, &value) >= 0 ? value : nil
    }

    private func flagProperty(_ mpv: OpaquePointer, _ name: String) -> Bool? {
        var value: Int32 = 0
        return mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &value) >= 0 ? value != 0 : nil
    }

    private func record(_ property: mpv_event_property) {
        let name = String(cString: property.name)
        let double = property.format == MPV_FORMAT_DOUBLE
            ? property.data?.assumingMemoryBound(to: Double.self).pointee : nil
        let flag = property.format == MPV_FORMAT_FLAG
            ? property.data.map { $0.assumingMemoryBound(to: Int32.self).pointee != 0 } : nil
        update { now in
            switch name {
            case "time-pos":
                now.position = double.map { $0.isFinite ? max($0, 0) : 0 } ?? 0
                // IOS-POC-36: what the loaded file reached, kept after it fails — mpv reports the
                // playhead gone once the file stops, sometimes before the failure itself.
                if now.loaded, now.position > 0 { now.reached = now.position }
            case "duration": now.duration = double.map { $0.isFinite ? max($0, 0) : 0 } ?? 0
            case "pause": now.paused = flag ?? now.paused
            case "paused-for-cache": now.buffering = flag ?? false
            case "speed": now.speed = double ?? now.speed
            case "volume": now.volume = double ?? now.volume
            // How far ahead the demuxer holds media, turned into a point on the timeline.
            case "demuxer-cache-time": now.cacheEnd = double
            default: break
            }
        }
    }

    private func command(_ mpv: OpaquePointer, _ words: [String]) {
        var args: [UnsafePointer<CChar>?] = words.map { strdup($0).map { UnsafePointer($0) } } + [nil]
        defer { for arg in args where arg != nil { free(UnsafeMutablePointer(mutating: arg!)) } }
        mpv_command(mpv, &args)
    }
}

// MARK: - IOS-POC-17H: Picture in Picture

/// The Picture in Picture window's video while it is open: mpv's software output, rendered into
/// BGRA pixel buffers and queued on the MPV view's sample buffer layer.
///
/// **Why the CPU.** PiP normally starts as the app goes to the background, and iOS stops a
/// background app's GPU work (Apple, "Preparing your Metal app to run in the background"), so
/// the Metal output would freeze in the window. libmpv's render API offers OpenGL and a software
/// renderer only (`render.h`); the window is fed by the latter — the same shape VLC uses on Apple
/// platforms (`VLCSampleBufferDisplay.m`). That renderer is slow by design, which is why it runs
/// only while the window is open, at the window's width, capped.
///
/// Every `mpv_render_*` call happens on `queue`, one at a time, never inside mpv's callback, and
/// `queue` calls no other libmpv function (`render.h`, "Threading").
final class MPVSoftwareRenderer: @unchecked Sendable {
    /// Frames are as wide as the PiP window in pixels, or the video if it is narrower; this only
    /// bounds a window wider than any a 3× iPhone shows (about 400 points), i.e. an iPad's.
    /// ponytail: a fixed cap on CPU time; per-device limits once measured (P1).
    private static let maximumWidth = 1280

    private let output: AVSampleBufferVideoRenderer
    private let queue = DispatchQueue(label: "mpv.software-render", qos: .userInitiated)
    private let lock = NSLock()
    private var videoSize = (width: 0, height: 0)   // under `lock`
    private var windowWidth = 0                      // under `lock`
    private var frameShown: (@Sendable () -> Void)?  // under `lock`
    private var context: OpaquePointer?              // `queue` only, as are the four below
    private var showsPicture = false                 // a decoded frame has gone out since `attach`
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)
    private var format: CMVideoFormatDescription?

    init(output: AVSampleBufferVideoRenderer) { self.output = output }

    func setVideoSize(width: Int, height: Int) { lock.lock(); videoSize = (width, height); lock.unlock() }
    /// Called once, from the render queue, when the next decoded frame has gone to the layer (IOS-POC-17H-3:
    /// the Metal picture stays up until the software output has something to show in its place).
    func onNextFrame(_ handler: (@Sendable () -> Void)?) { lock.lock(); frameShown = handler; lock.unlock() }
    /// The window's width in pixels. Our frames set the window's shape, and rounding them to even
    /// pixels nudges it by a point, which comes back as a new size: a loop that resized every frame
    /// and rebuilt the buffer pool (17H). Only a real resize — a pinch, more than a tenth — passes.
    func setWindowWidth(_ width: Int) {
        lock.lock(); defer { lock.unlock() }
        guard windowWidth == 0 || abs(width - windowWidth) * 10 > windowWidth else { return }
        windowWidth = width
    }

    /// Creates the render context. On the core's queue, before `vo=libmpv`.
    func attach(to mpv: OpaquePointer) -> Bool {
        queue.sync {
            guard context == nil else { return true }
            return MPV_RENDER_API_TYPE_SW.withCString { api in
                var params = [mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: api)),
                              mpv_render_param()]
                var created: OpaquePointer?
                guard mpv_render_context_create(&created, mpv, &params) >= 0, let created else { return false }
                context = created
                showsPicture = false
                mpv_render_context_set_update_callback(created, softwareFrameDue, Unmanaged.passUnretained(self).toOpaque())
                return true
            }
        }
    }

    /// Releases the render context. On the core's queue, after `vo` has left `libmpv`.
    func detach() {
        queue.sync {
            guard let context else { return }
            mpv_render_context_set_update_callback(context, nil, nil)
            mpv_render_context_free(context)
            self.context = nil
            pool = nil
            format = nil
        }
    }

    /// A black frame in the video's shape. The layer shows it — under the Metal layer, so never
    /// inline — until the window's first real frame, which takes an output rebuild to arrive.
    func showPlaceholder() {
        queue.async { [self] in
            let (width, height) = targetSize(maximum: 160)
            var created: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &created)
            guard let buffer = created else { return }
            CVPixelBufferLockBaseAddress(buffer, [])
            var image = vImage_Buffer(data: CVPixelBufferGetBaseAddress(buffer), height: vImagePixelCount(height),
                                      width: vImagePixelCount(width), rowBytes: CVPixelBufferGetBytesPerRow(buffer))
            let black: [UInt8] = [0, 0, 0, 255]   // B, G, R, A — the buffer's byte order
            vImageBufferFill_ARGB8888(&image, black, vImage_Flags(kvImageNoFlags))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            show(buffer)
        }
    }

    /// IOS-POC-17H-4 — the frame on screen (`bytes`: bgr0, `stride` bytes a row, valid only during
    /// the call) in place of the black placeholder, for a window about to open. Scaled to the size
    /// the window's frames have: the layer keeps it for as long as nothing replaces it, and a 4K
    /// source's full frame is some 33 MB. On the core's queue, like `attach`.
    func showStill(width: Int, height: Int, stride: Int, bytes: UnsafeRawPointer) {
        guard width > 1, height > 1 else { return }
        let (targetWidth, targetHeight) = targetSize(maximum: Self.maximumWidth)
        queue.sync {
            var created: CVPixelBuffer?
            CVPixelBufferCreate(nil, targetWidth, targetHeight, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &created)
            guard let buffer = created else { return }
            CVPixelBufferLockBaseAddress(buffer, [])
            var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: bytes), height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: stride)
            var target = vImage_Buffer(data: CVPixelBufferGetBaseAddress(buffer), height: vImagePixelCount(targetHeight),
                                       width: vImagePixelCount(targetWidth), rowBytes: CVPixelBufferGetBytesPerRow(buffer))
            let scaled = vImageScale_ARGB8888(&source, &target, nil, vImage_Flags(kvImageNoFlags))
            // The undefined fourth byte of "bgr0" set opaque, as `render()` does.
            vImageOverwriteChannelsWithScalar_ARGB8888(255, &target, &target, 0x1, vImage_Flags(kvImageNoFlags))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            if scaled == kvImageNoError { show(buffer) }
        }
    }

    fileprivate func frameDue() { queue.async { [self] in render() } }

    private func render() {
        guard let context,
              mpv_render_context_update(context) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }
        var info = mpv_render_frame_info()
        _ = withUnsafeMutablePointer(to: &info) {
            mpv_render_context_get_info(context, mpv_render_param(type: MPV_RENDER_PARAM_NEXT_FRAME_INFO,
                                                                  data: UnsafeMutableRawPointer($0)))
        }
        let redraw = info.flags & UInt64(MPV_RENDER_FRAME_INFO_REDRAW.rawValue) != 0
        let (width, height) = targetSize(maximum: Self.maximumWidth)
        guard let buffer = pixelBuffer(width: width, height: height) else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)
        var stride = CVPixelBufferGetBytesPerRow(buffer)
        var size: [Int32] = [Int32(width), Int32(height)]
        let rendered = "bgr0".withCString { pixelFormat in
            size.withUnsafeMutableBufferPointer { size in
                withUnsafeMutablePointer(to: &stride) { stride in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(size.baseAddress)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(mutating: pixelFormat)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stride)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: base),
                        mpv_render_param(),
                    ]
                    return mpv_render_context_render(context, &params)
                }
            }
        }
        // Nothing drawn, nothing to show: the buffer holds whatever the pool left in it. Nor a redraw
        // before the new output's first decoded frame (IOS-POC-17H-4): there is no picture to redraw,
        // the software renderer clears it to black (`libmpv_sw.c`), and on the device that black
        // hid the Metal picture and opened the window before the real frame came.
        guard rendered >= 0, showsPicture || !redraw else { CVPixelBufferUnlockBaseAddress(buffer, []); return }
        // "bgr0" leaves the fourth byte undefined (`render.h`); the layer gets an opaque frame.
        var image = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                  rowBytes: stride)
        withUnsafePointer(to: &image) { image in
            _ = vImageOverwriteChannelsWithScalar_ARGB8888(255, image, image, 0x1, vImage_Flags(kvImageNoFlags))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        show(buffer)
        showsPicture = true
        lock.lock()
        let shown = frameShown
        frameShown = nil
        lock.unlock()
        shown?()
    }

    /// The video's shape at no more than `maximum` (and the window's) width, in even pixels, so
    /// mpv fills the frame instead of adding bars.
    private func targetSize(maximum: Int) -> (Int, Int) {
        lock.lock(); let video = videoSize; let window = windowWidth; lock.unlock()
        let cap = window > 0 ? min(window, maximum) : maximum
        guard video.width > 0, video.height > 0 else { return (cap & ~1, max(cap * 9 / 16, 2) & ~1) }
        let width = max(min(video.width, cap), 2)
        let height = max(Int((Double(width) * Double(video.height) / Double(video.width)).rounded()), 2)
        return (width & ~1, height & ~1)
    }

    private func pixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                // `render.h`: a 64-byte aligned stride keeps mpv on its SIMD path.
                kCVPixelBufferBytesPerRowAlignmentKey: 64,
                kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
            pool = created
            poolSize = (width, height)
        }
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess else { return nil }
        return buffer
    }

    private func show(_ buffer: CVPixelBuffer) {
        if format.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: buffer) }) ?? true {
            format = nil
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard let format,
              CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        // Shown as it arrives: mpv already waited for the frame's time (`render.h`,
        // `MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME`). The layer's control timebase only carries the
        // position the PiP window shows. The SDK advises against pairing a control timebase with this
        // attachment (`AVSampleBufferVideoRenderer.h`), but stamping frames on that polled clock
        // instead let it pace them — about two a second on the simulator — and KSPlayer ships the
        // same pairing.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        // A failed renderer shows nothing until flushed (VLC, `VLCSampleBufferDisplay.m`), and neither
        // does one whose decoder the system took back, behind the lock screen (Apple forums 745840).
        if output.status == .failed || output.requiresFlushToResumeDecoding { output.flush() }
        output.enqueue(sample)
    }
}

/// File scope: mpv calls it on its own thread, and a closure would inherit an actor's isolation and
/// trap there (9G). It only schedules.
private func softwareFrameDue(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    Unmanaged<MPVSoftwareRenderer>.fromOpaque(ctx).takeUnretainedValue().frameDue()
}

/// IOS-POC-17H — Picture in Picture for MPV, behaving as AVPlayer's does (`PlayerSurface`): no
/// button of its own, it starts when the viewer leaves the app during playback, and coming back
/// to the app ends it. Inline the video stays on Metal; only while the window is open does it
/// move to `MPVSoftwareRenderer`.
///
/// ponytail: moving between the two outputs rebuilds mpv's video output at both ends of a PiP
/// session, each an exact seek to the current position — a short stall going in and coming back.
/// A render path that could draw inline and in the background alike would remove it; libmpv on
/// iOS has none today.
@MainActor
final class MPVPictureInPicture: NSObject, @preconcurrency AVPictureInPictureControllerDelegate,
                                 @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    private(set) var isActive = false
    var onActiveChange: ((Bool) -> Void)?

    private weak var engine: MPVEngine?
    private let core: MPVPlayerCore
    private let renderer: MPVSoftwareRenderer
    private let timebase: CMTimebase?
    /// The window's content, given back after `end()` takes it away.
    private let layer: AVSampleBufferDisplayLayer
    private var controller: AVPictureInPictureController?
    private var foregroundRestore = PictureInPictureForegroundRestoreState()
    private var observers = [NSObjectProtocol]()
    private var tick: Task<Void, Never>?
    private var reported = (loaded: false, paused: true, duration: 0.0)
    private var possible: NSKeyValueObservation?
    private var foregroundStop: Task<Void, Never>?
    /// How long the app waits, once active, to hear that the system is ending the window itself.
    /// ponytail: a fixed guess at iOS's ordering (the device recording could not show it); the
    /// `[pip]` log lines give the real gap, which is what to set this from.
    private static let foregroundStopDelay: Duration = .milliseconds(300)

    init(engine: MPVEngine, core: MPVPlayerCore, layer: AVSampleBufferDisplayLayer) {
        self.engine = engine
        self.core = core
        renderer = MPVSoftwareRenderer(output: layer.sampleBufferRenderer)
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(),
                                        timebaseOut: &timebase)
        self.timebase = timebase
        self.layer = layer
        super.init()
        // The window reads the position it shows from the layer's timebase.
        layer.controlTimebase = timebase
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let controller = AVPictureInPictureController(
            contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: self))
        controller.delegate = self
        self.controller = controller
        // Whether the system would start PiP from here: the first thing to read on a device that
        // leaves the app and gets no window.
        possible = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor in PlaybackSession.log.notice("[pip] mpv possible=\(possible)") }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.appDidBecomeActive() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.appWillResignActive() } })
        // ponytail: a half-second poll of the engine's state; PiP only needs to hear of a change.
        // Report it from mpv's property events instead if the window's play state visibly lags.
        tick = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    self.reportPlayback()
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// The engine is going away.
    func invalidate() {
        tick?.cancel()
        foregroundStop?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        possible = nil
        controller?.delegate = nil
        if isActive { controller?.stopPictureInPicture() }
        controller = nil
        setActive(false)
    }

    /// The player screen closed with the window open (IOS-POC-36.5). With the app in the background
    /// `stopPictureInPicture()` does nothing — measured on the iPad simulator, the window still open
    /// 0.8 s later. Taking the content away ends it there too, through the usual will- and did-stop,
    /// which then end it as the window's own ✕ does and give the content back.
    func end() {
        guard isActive else { return }
        PlaybackSession.log.notice("[pip] mpv player screen closed with the window open — ending it")
        controller?.contentSource = nil
    }

    /// Only a loaded file with video opens the window by itself: for sound alone, a failed load or a
    /// finished file it would stay black, and AVPlayer's PiP does not start then either.
    func setHasVideo(_ hasVideo: Bool) {
        controller?.canStartPictureInPictureAutomaticallyFromInline = hasVideo
    }

    /// A new output configuration: remember the shape for the window, and while the window is
    /// closed put a black frame of that shape on the layer rather than a stale picture.
    func videoSizeChanged(width: Int, height: Int) {
        renderer.setVideoSize(width: width, height: height)
        refreshPlaceholder()
    }

    /// The black frame the window opens on, kept in the layer while it is covered by Metal — not
    /// while the window has the video, and not while the layer is what the viewer sees after it
    /// (`MPVEngine.awaitingMetalFrame`, IOS-POC-17H-3).
    func refreshPlaceholder() {
        guard !isActive, engine?.awaitingMetalFrame != true else { return }
        renderer.showPlaceholder()
    }

    private func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        onActiveChange?(active)
    }

    private func reportPlayback() {
        guard let engine else { return }
        if let timebase {
            // The clock runs at the playback rate by itself; it is moved only on a jump (a seek), since
            // every move is a timing discontinuity for the layer — the 1 s Soupy-dev/MPVKit uses.
            let rate = engine.isPlaying ? Double(engine.rate) : 0
            if CMTimebaseGetRate(timebase) != rate { CMTimebaseSetRate(timebase, rate: rate) }
            if abs(CMTimebaseGetTime(timebase).seconds - engine.currentTime) > 1 {
                CMTimebaseSetTime(timebase, time: CMTime(seconds: engine.currentTime, preferredTimescale: 1000))
            }
        }
        let now = (loaded: engine.isLoaded, paused: core.snapshot.paused, duration: engine.duration)
        guard now != reported else { return }
        reported = now
        controller?.invalidatePlaybackState()
    }

    /// Coming back to the app ends PiP, as AVPlayer's surface does — unless the system is already
    /// ending it (the window's own button), which it may say only after the app is active.
    private func appDidBecomeActive() {
        foregroundStop?.cancel()
        foregroundStop = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: Self.foregroundStopDelay)) != nil, let self,
                  self.foregroundRestore.consumeForegroundRequest(isPictureInPictureActive: self.isActive) else { return }
            PlaybackSession.log.notice("[pip] mpv back in the app with the window open — stopping it")
            self.controller?.stopPictureInPicture()
        }
    }

    /// IOS-POC-17H-4: the window may open as the app leaves, and it opens on whatever the layer holds.
    private func appWillResignActive() {
        guard !isActive, controller?.canStartPictureInPictureAutomaticallyFromInline == true else { return }
        core.showCurrentFrame(on: renderer)
    }

    private func ended(pausingInBackground: Bool) {
        guard isActive else { return }
        setActive(false)
        let inBackground = UIApplication.shared.applicationState == .background
        // Closing the window from outside the app stops playback, as it does for AVPlayer. A window
        // that failed to open leaves the background as it was before 17H: sound on, no picture.
        // IOS-POC-36.2: through the session, so the pause is the viewer's and is judged for a
        // reload on return — it comes after the window reported closed (`setActive` above).
        if inBackground, pausingInBackground { PlaybackSession.shared.control("pause") }
        renderer.onNextFrame(nil)
        core.stopSoftwareOutput(keepVideo: !inBackground)
        engine?.revealMetalAfterPictureInPicture()
    }

    // MARK: AVPictureInPictureControllerDelegate

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        PlaybackSession.log.notice("[pip] mpv will start — video moves to the software output")
        foregroundRestore.pictureInPictureWillStart()
        setActive(true)
        // Metal keeps its picture up until the layer under it has the first software frame: hidden
        // any sooner, the layer's black placeholder showed for a frame (IOS-POC-17H-3).
        renderer.onNextFrame { [weak self] in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.engine?.coverMetalForPictureInPicture()
            }
        }
        core.startSoftwareOutput(renderer)
        // The window does not read the time range on its own when it opens (VLC,
        // `VLCPictureInPictureController.m`).
        pictureInPictureController.invalidatePlaybackState()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        PlaybackSession.log.notice("[pip] mpv failed to start: \(error.localizedDescription, privacy: .public)")
        ended(pausingInBackground: false)
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        PlaybackSession.log.notice("[pip] mpv will stop")
        foregroundRestore.pictureInPictureWillStop()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        PlaybackSession.log.notice("[pip] mpv did stop — video back on Metal")
        foregroundRestore.pictureInPictureDidStop()
        ended(pausingInBackground: true)
        // `end()` took the content away; the engine outlives the screen, and its next window needs it.
        if pictureInPictureController.contentSource == nil {
            pictureInPictureController.contentSource = .init(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // The player screen stays presented underneath, as with AVPlayer.
        PlaybackSession.log.notice("[pip] mpv restoring the app (app state \(UIApplication.shared.applicationState.rawValue))")
        foregroundRestore.pictureInPictureWillStop()
        completionHandler(true)
    }

    // MARK: AVPictureInPictureSampleBufferPlaybackDelegate

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        // Through the session, like the control bar's toggle (IOS-POC-36): a pause here is the
        // viewer's, and a fallback after it must stay paused.
        PlaybackSession.shared.control(playing ? "play" : "pause")
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // The SDK's forms (`AVPictureInPictureController_AVSampleBufferDisplayLayerSupport.h`):
        // invalid for nothing to play, an infinite duration for live content. (-∞, +∞) keeps AVKit's
        // timer busy (UIPiPView issue #17).
        guard let engine, engine.isLoaded else { return .invalid }
        let duration = engine.duration
        guard duration > 0 else { return CMTimeRange(start: .zero, duration: .positiveInfinity) }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 1000))
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        // A failed or unloaded file is not playing, whatever mpv's `pause` still says.
        !(engine?.isLoaded ?? false) || core.snapshot.paused
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        // The header says pixels, but it arrives in points: the iPad simulator's 327.5-point window
        // reported 330. Rendering that many pixels was the blurry PiP window the device showed.
        renderer.setWindowWidth(Int((Double(newRenderSize.width) * UIScreen.main.nativeScale).rounded()))
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        // Through the session, like the control bar's ±10 s: its ad rules see the seek, which a jump
        // straight on the engine would look like a broken timeline to (IOS-POC-25-5).
        if let engine { PlaybackSession.shared.seek(toSeconds: engine.currentTime + skipInterval.seconds) }
        completionHandler()
    }
}
