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
/// **Whether it is offered at all is `PlaybackEngines.offered`, not this type.**
@MainActor
final class MPVEngine: PlaybackEngine {
    let kind = PlaybackEngineKind.mpv
    let view = MPVVideoView()
    var onFailure: ((Error, Int?) -> Void)?
    var onEnded: (() -> Void)?

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
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [core] _ in core.setVideoTrackEnabled(false) })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [core] _ in core.setVideoTrackEnabled(true) })
        view.onResize = { [core] in core.rebuildVideoOutput() }
    }

    func load(_ request: PlaybackLoadRequest) {
        firstFrameWatchdog?.cancel()
        core.load(url: request.target.url.absoluteString,
                  headerFields: MPVRequestHeaders.fields(request.target.headers),
                  startSeconds: request.startSeconds, rate: request.rate, autoplay: request.autoplay)
    }

    func play() { core.setPaused(false) }
    func pause() { core.setPaused(true) }
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
        firstFrameWatchdog?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        onFailure = nil
        onEnded = nil
        core.shutdown()
    }

    private func handle(_ event: MPVPlayerCore.Event) {
        switch event {
        case .fileLoaded(let hasVideo):
            guard hasVideo else { return }   // audio only: there will never be a frame to wait for
            firstFrameWatchdog?.cancel()
            firstFrameWatchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.firstFrameTimeout)
                guard !Task.isCancelled, let self else { return }
                self.onFailure?(NSError(domain: PlaybackFailure.mpvDomain,
                                        code: PlaybackFailure.mpvNoFirstFrame), nil)
            }
        case .videoReconfigured:
            firstFrameWatchdog?.cancel()
        case .ended:
            onEnded?()
        case .failed(let code):
            firstFrameWatchdog?.cancel()
            onFailure?(NSError(domain: PlaybackFailure.mpvDomain, code: Int(code)), nil)
        }
    }
}

/// A view whose own layer is the Metal layer mpv draws into, so the layer follows the view's bounds.
/// **mpv does not follow on its own** (IOS-POC-17G): see `onResize`.
final class MPVVideoView: UIView {
    override class var layerClass: AnyClass { MPVMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
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
    }

    required init?(coder: NSCoder) { fatalError("not used from a storyboard") }

    override func layoutSubviews() {
        super.layoutSubviews()
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
        case videoReconfigured
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
            guard let mpv, snapshot.loaded else { return }
            voSpelledWithFallback.toggle()
            mpv_set_property_string(mpv, "vo", voSpelledWithFallback ? "gpu-next," : "gpu-next")
        }
    }

    func seek(to seconds: Double) {
        queue.async { [self] in if let mpv { command(mpv, ["seek", String(seconds), "absolute+exact"]) } }
    }

    /// Releases the handle off the main thread: `mpv_terminate_destroy` can block while the
    /// playloop winds down. The wakeup callback is removed first, under the same lock libmpv
    /// holds while calling it, so none is in flight afterwards.
    func shutdown() {
        queue.async { [self] in
            guard let handle = mpv else { return }
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
                onEvent?(.videoReconfigured)
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
