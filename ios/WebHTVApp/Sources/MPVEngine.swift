import Accelerate
import AVKit
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
///
/// **Whether it is offered at all is `PlaybackEngines.offered`, not this type.**
@MainActor
final class MPVEngine: PlaybackEngine {
    let kind = PlaybackEngineKind.mpv
    let view = MPVVideoView()
    var onFailure: ((Error, Int?) -> Void)?
    var onEnded: (() -> Void)?
    /// True while the video is in a Picture in Picture window. The player screen must not tear
    /// playback down in that state, exactly as with AVPlayer's PiP.
    var onPictureInPictureChange: ((Bool) -> Void)?
    private var pictureInPicture: MPVPictureInPicture?

    private let core: MPVPlayerCore
    /// Raised once per load if the file loaded and no frame reached the output — the black
    /// screen the device showed before 9G, now a classified failure instead of a silent one.
    private var firstFrameWatchdog: Task<Void, Never>?
    private var observers = [NSObjectProtocol]()

    /// Long enough for a slow first segment; the watchdog only starts once the file has loaded.
    private static let firstFrameTimeout: Duration = .seconds(10)

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
                self.setDisplaySleepPrevented(self.core.snapshot.loaded && !self.core.snapshot.paused)
            }
        })
        view.onResize = { [core] in core.rebuildVideoOutput() }
        let pictureInPicture = MPVPictureInPicture(engine: self, core: core, layer: view.sampleBufferLayer)
        pictureInPicture.onActiveChange = { [weak self] active in self?.onPictureInPictureChange?(active) }
        self.pictureInPicture = pictureInPicture
    }

    func load(_ request: PlaybackLoadRequest) {
        firstFrameWatchdog?.cancel()
        pictureInPicture?.setHasVideo(false)   // until the file says otherwise
        // AVKit prevents display sleep for AVPlayer playback. MPV owns a custom Metal surface, so
        // iOS sees no system video controller and would dim/lock the screen after the normal idle
        // interval unless the app explicitly holds the idle timer while playback is intended.
        setDisplaySleepPrevented(request.autoplay)
        core.load(url: request.target.url.absoluteString,
                  headerFields: MPVRequestHeaders.fields(request.target.headers),
                  startSeconds: request.startSeconds, rate: request.rate, autoplay: request.autoplay)
    }

    func play() {
        setDisplaySleepPrevented(true)
        core.setPaused(false)
    }
    func pause() {
        core.setPaused(true)
        setDisplaySleepPrevented(false)
    }
    func seek(toSeconds seconds: Double) { core.seek(to: max(seconds, 0)) }
    func setRate(_ rate: Float) { core.setSpeed(rate) }

    var currentTime: Double { core.snapshot.position }
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

    func teardown() {
        setDisplaySleepPrevented(false)
        pictureInPicture?.invalidate()
        pictureInPicture = nil
        firstFrameWatchdog?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        onFailure = nil
        onEnded = nil
        core.shutdown()
    }

    /// `UIApplication.isIdleTimerDisabled` is app-wide, so every MPV lifecycle exit must release it.
    /// Keep buffering awake too: a non-paused MPV is still an active playback intent even when the
    /// network temporarily stops frames.
    private func setDisplaySleepPrevented(_ prevented: Bool) {
        guard UIApplication.shared.isIdleTimerDisabled != prevented else { return }
        UIApplication.shared.isIdleTimerDisabled = prevented
    }

    private func handle(_ event: MPVPlayerCore.Event) {
        switch event {
        case .fileLoaded(let hasVideo):
            setDisplaySleepPrevented(!core.snapshot.paused)
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
            if width > 0, height > 0 { pictureInPicture?.videoSizeChanged(width: width, height: height) }
        case .ended:
            setDisplaySleepPrevented(false)
            pictureInPicture?.setHasVideo(false)   // mpv is idle now; the next load says again
            onEnded?()
        case .failed(let code):
            setDisplaySleepPrevented(false)
            pictureInPicture?.setHasVideo(false)
            firstFrameWatchdog?.cancel()
            onFailure?(NSError(domain: PlaybackFailure.mpvDomain, code: Int(code)), nil)
        }
    }
}

/// The MPV player's surface: the Metal layer mpv draws into, and under it the sample buffer layer
/// Picture in Picture takes its video from (IOS-POC-17H). Both follow the view's bounds.
/// **mpv does not follow on its own** (IOS-POC-17G): see `onResize`.
final class MPVVideoView: UIView {
    private let metalView = MPVMetalView()
    private let sampleBufferView = MPVSampleBufferView()
    var metalLayer: CAMetalLayer { metalView.layer as! CAMetalLayer }
    var sampleBufferLayer: AVSampleBufferDisplayLayer { sampleBufferView.layer as! AVSampleBufferDisplayLayer }
    /// A rotation, or any other size change, once it has settled and the layer's `drawableSize`
    /// matches the new bounds.
    var onResize: (() -> Void)?
    private var laidOutSize = CGSize.zero
    private var settle: Task<Void, Never>?

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
        sampleBufferView.frame = bounds
        let size = bounds.size
        guard size.width > 1, size.height > 1, size != laidOutSize else { return }
        let firstLayout = laidOutSize == .zero
        laidOutSize = size
        // The first size is the one mpv reads when it configures its output; only changes need telling.
        guard !firstLayout else { return }
        settle?.cancel()
        settle = Task { @MainActor [weak self] in
            // Past the rotation animation, so one change is one rebuild.
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            let scale = metalLayer.contentsScale
            metalLayer.drawableSize = CGSize(width: laidOutSize.width * scale, height: laidOutSize.height * scale)
            onResize?()
        }
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
    /// The player screen's PiP flag, shared with AVPlayer's surface.
    @Binding var pictureInPicture: Bool
    func makeUIView(context: Context) -> MPVVideoView {
        let binding = $pictureInPicture
        engine.onPictureInPictureChange = { binding.wrappedValue = $0 }
        return engine.view
    }
    func updateUIView(_ view: MPVVideoView, context: Context) {}
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
    }

    var onEvent: (@Sendable (Event) -> Void)?

    private var mpv: OpaquePointer?
    private let queue = DispatchQueue(label: "mpv.engine", qos: .userInitiated)
    private let lock = NSLock()
    private var state = Snapshot()
    /// Which spelling of `vo` is current (`rebuildVideoOutput`). Read and written on `queue` only.
    private var voSpelledWithFallback = false
    /// The software output while Picture in Picture has the video (17H). `queue` only.
    private var software: MPVSoftwareRenderer?

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
        // device it picks VideoToolbox. ponytail: the device cell of this is still unmeasured.
        #if targetEnvironment(simulator)
        mpv_set_option_string(handle, "hwdec", "no")
        #else
        mpv_set_option_string(handle, "hwdec", "auto-safe")
        #endif
        mpv_set_option_string(handle, "video-rotate", "no")
        mpv_set_option_string(handle, "subs-fallback", "yes")
        // `render.h`'s advice for the software output Picture in Picture uses (17H). `sw-fast` is a
        // built-in profile (faster `sws`/`zimg` scalers, which the Metal output does not scale
        // with); as an option name it does not exist and is refused (MPV_ERROR_OPTION_NOT_FOUND).
        mpv_set_option_string(handle, "profile", "sw-fast")
        guard mpv_initialize(handle) >= 0 else {
            mpv_terminate_destroy(handle)
            return
        }
        for (name, format) in [("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE),
                               ("pause", MPV_FORMAT_FLAG), ("paused-for-cache", MPV_FORMAT_FLAG),
                               ("speed", MPV_FORMAT_DOUBLE), ("volume", MPV_FORMAT_DOUBLE),
                               ("demuxer-cache-time", MPV_FORMAT_DOUBLE)] {
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
        update { $0 = Snapshot(loading: true, speed: Double(rate), volume: $0.volume) }
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

    func setPaused(_ paused: Bool) { set("pause", paused ? "yes" : "no") }
    func setSpeed(_ rate: Float) { set("speed", String(rate)) }
    func setVolume(_ volume: Double) { set("volume", String(min(max(volume, 0), 100))) }
    func setVideoTrackEnabled(_ enabled: Bool) { set("vid", enabled ? "auto" : "no") }

    /// IOS-POC-17G — after a rotation mpv kept drawing at the old size ("跑版", reported on the
    /// device with `0.1.10 (11)`). MPVKit's `moltenvk` context reads the layer's `drawableSize` only
    /// when the video output is configured, and its `control` never reports a resize (MPVKit issue
    /// #3, still open). Setting `vo` makes mpv tear the output down and build it again at once
    /// (`UPDATE_VO` in mpv's `player/command.c`), and the new output reads the new size. mpv skips a
    /// value equal to the current one, so the same driver alternates between two spellings; the
    /// trailing comma only allows falling back to another driver if `gpu-next` ever fails to start.
    /// With the video track off (in the background) there is no output, and this only changes the
    /// option — the output built on return reads the size then.
    ///
    /// ponytail: each settled resize costs an exact seek to the current position, normally served
    /// from the demuxer cache. The free fix is a resize in the `moltenvk` context itself
    /// (edde746/MPVKit@e6b129f), which means building libmpv ourselves.
    func rebuildVideoOutput() {
        queue.async { [self] in
            // During Picture in Picture the output is the software one, which takes its size per frame.
            guard let mpv, snapshot.loaded, software == nil else { return }
            voSpelledWithFallback.toggle()
            mpv_set_property_string(mpv, "vo", voSpelledWithFallback ? "gpu-next," : "gpu-next")
        }
    }

    func seek(to seconds: Double) {
        queue.async { [self] in if let mpv { command(mpv, ["seek", String(seconds), "absolute+exact"]) } }
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
            voSpelledWithFallback = false
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
                record(property)
            case MPV_EVENT_FILE_LOADED:
                update { $0.loading = false; $0.loaded = true }
                let video = mpv_get_property_string(mpv, "current-tracks/video/id")
                defer { mpv_free(video) }
                onEvent?(.fileLoaded(hasVideo: video != nil))
            case MPV_EVENT_VIDEO_RECONFIG:
                var width: Int64 = 0, height: Int64 = 0
                mpv_get_property(mpv, "dwidth", MPV_FORMAT_INT64, &width)
                mpv_get_property(mpv, "dheight", MPV_FORMAT_INT64, &height)
                onEvent?(.videoReconfigured(width: Int(width), height: Int(height)))
            case MPV_EVENT_END_FILE:
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

    private func record(_ property: mpv_event_property) {
        let name = String(cString: property.name)
        let double = property.format == MPV_FORMAT_DOUBLE
            ? property.data?.assumingMemoryBound(to: Double.self).pointee : nil
        let flag = property.format == MPV_FORMAT_FLAG
            ? property.data.map { $0.assumingMemoryBound(to: Int32.self).pointee != 0 } : nil
        update { now in
            switch name {
            case "time-pos": now.position = double.map { $0.isFinite ? max($0, 0) : 0 } ?? 0
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
    private var context: OpaquePointer?              // `queue` only, as are the three below
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)
    private var format: CMVideoFormatDescription?

    init(output: AVSampleBufferVideoRenderer) { self.output = output }

    func setVideoSize(width: Int, height: Int) { lock.lock(); videoSize = (width, height); lock.unlock() }
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

    fileprivate func frameDue() { queue.async { [self] in render() } }

    private func render() {
        guard let context,
              mpv_render_context_update(context) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }
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
        // Nothing drawn, nothing to show: the buffer holds whatever the pool left in it.
        guard rendered >= 0 else { CVPixelBufferUnlockBaseAddress(buffer, []); return }
        // "bgr0" leaves the fourth byte undefined (`render.h`); the layer gets an opaque frame.
        var image = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                  rowBytes: stride)
        withUnsafePointer(to: &image) { image in
            _ = vImageOverwriteChannelsWithScalar_ARGB8888(255, image, image, 0x1, vImage_Flags(kvImageNoFlags))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        show(buffer)
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

/// File scope, like `requestGLDisplay` in `MPVProbeView`: mpv calls it on its own thread, and a
/// closure would inherit an actor's isolation and trap there (9G). It only schedules.
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
    private var controller: AVPictureInPictureController?
    private var foregroundRestore = PictureInPictureForegroundRestoreState()
    private var observers = [NSObjectProtocol]()
    private var tick: Task<Void, Never>?
    private var reported = (loaded: false, paused: true, duration: 0.0)
    private var possible: NSKeyValueObservation?

    init(engine: MPVEngine, core: MPVPlayerCore, layer: AVSampleBufferDisplayLayer) {
        self.engine = engine
        self.core = core
        renderer = MPVSoftwareRenderer(output: layer.sampleBufferRenderer)
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(),
                                        timebaseOut: &timebase)
        self.timebase = timebase
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
        // ponytail: a half-second poll of the engine's state; PiP only needs to hear of a change.
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
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        possible = nil
        controller?.delegate = nil
        if isActive { controller?.stopPictureInPicture() }
        controller = nil
        setActive(false)
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
        if !isActive { renderer.showPlaceholder() }
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

    /// Coming back to the app ends PiP, as AVPlayer's surface does.
    private func appDidBecomeActive() {
        guard foregroundRestore.consumeForegroundRequest(isPictureInPictureActive: isActive) else { return }
        controller?.stopPictureInPicture()
    }

    private func ended(pausingInBackground: Bool) {
        guard isActive else { return }
        setActive(false)
        let inBackground = UIApplication.shared.applicationState == .background
        // Closing the window from outside the app stops playback, as it does for AVPlayer. A window
        // that failed to open leaves the background as it was before 17H: sound on, no picture.
        if inBackground, pausingInBackground { engine?.pause() }
        core.stopSoftwareOutput(keepVideo: !inBackground)
    }

    // MARK: AVPictureInPictureControllerDelegate

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        PlaybackSession.log.notice("[pip] mpv will start — video moves to the software output")
        foregroundRestore.pictureInPictureWillStart()
        setActive(true)
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

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        PlaybackSession.log.notice("[pip] mpv did stop — video back on Metal")
        foregroundRestore.pictureInPictureDidStop()
        ended(pausingInBackground: true)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // The player screen stays presented underneath, as with AVPlayer.
        completionHandler(true)
    }

    // MARK: AVPictureInPictureSampleBufferPlaybackDelegate

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        if playing { engine?.play() } else { engine?.pause() }
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
        if let engine { engine.seek(toSeconds: engine.currentTime + skipInterval.seconds) }
        completionHandler()
    }
}
