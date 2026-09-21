import Libmpv
import SwiftUI
import UIKit

/// A Debug-only surface that asks libmpv to draw a stream, and says out loud what happened.
///
/// IOS-POC-9C is the second unit of the MPV spike. IOS-POC-9B proved the interpreter-level question
/// — libmpv links and initialises — which a screenshot cannot distinguish from a black rectangle.
/// This one proves the next one: that frames reach a layer. It therefore reports the decoded size,
/// the codec and the video output mpv actually chose, because **a black video and a broken renderer
/// look identical on screen**. That is the same reasoning as `MPVBoot`'s negative control.
///
/// It is deliberately **not** wired into `PlaybackSession`, `SourceClient` or the player picker.
/// `PlayerRouter` comes after this, when there is a second engine worth routing to.
///
/// The rendering path is not invented here: it is MPVKit's own iOS demo —
/// `CAMetalLayer` as `wid`, `vo=gpu-next`, `gpu-api=vulkan`, `gpu-context=moltenvk`,
/// `hwdec=videotoolbox`.
struct MPVProbeView: View {
    /// Apple's own public HLS example. A default that is dead makes the probe useless, and this one
    /// is about as stable as a public test stream gets; paste anything else to try it.
    @State private var address =
        "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8"
    @State private var playing: URL?
    @State private var report = "尚未播放"
    /// Measured on the iOS 26.3 simulator: neither `videotoolbox` nor Vulkan video decode exists
    /// there, and mpv does **not** fall back on its own — it stalls on `h264: no frame!` and never
    /// reaches the video output. So the probe asks the question instead of assuming an answer, and
    /// a device run can flip it back.
    @State private var hardwareDecode = false

    var body: some View {
        VStack(spacing: 12) {
            if let playing {
                MPVSurface(url: playing, hwdec: hardwareDecode ? "auto-safe" : "no", report: $report)
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .background(Color.black)
            } else {
                Color.black
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .overlay(Text("按「播放」開始").foregroundStyle(.secondary))
            }

            TextField("串流網址", text: $address, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(1 ... 3)
                .textFieldStyle(.roundedBorder)

            Toggle("硬體解碼 (auto-safe)", isOn: $hardwareDecode)

            Button("播放") {
                report = "載入中…"
                playing = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines))
                if playing == nil { report = "網址無法解析" }
            }
            .buttonStyle(.borderedProminent)

            ScrollView {
                Text(report)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding()
        .navigationTitle("MPV 算繪驗證")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MPVSurface: UIViewControllerRepresentable {
    let url: URL
    let hwdec: String
    @Binding var report: String

    func makeUIViewController(context: Context) -> MPVProbeController {
        let controller = MPVProbeController()
        controller.url = url
        controller.hwdec = hwdec
        controller.onReport = { text in
            report = text
        }
        return controller
    }

    func updateUIViewController(_ controller: MPVProbeController, context: Context) {
        controller.play(url)
    }
}

/// `CAMetalLayer` with the two overrides MPVKit's demo documents, both worked around upstream bugs
/// rather than preferences, so they are kept verbatim rather than trimmed.
private final class MetalLayer: CAMetalLayer {
    // MoltenVK sets drawableSize to 1x1 to force presentation to complete, which makes the layer
    // flicker and can leave it stuck at 1x1. https://github.com/mpv-player/mpv/pull/13651
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1, Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    // MPVKit's demo also overrides `wantsExtendedDynamicRangeContent` to force EDR activation onto
    // the main thread. That override exists only to support `target-colorspace-hint`, which this
    // probe does not enable, so it is left out rather than carried as dead code. Put it back in the
    // same breath as HDR passthrough.
}

/// Everything that touches the mpv handle, deliberately **not** `@MainActor`.
///
/// mpv calls its wakeup callback on its own core thread. An earlier revision put this on the
/// `UIViewController`, which `UIViewController` makes `@MainActor`, so the callback tripped
/// `dispatch_assert_queue_fail` inside `swift_task_isCurrentExecutor` and the app died with
/// `EXC_BREAKPOINT` the moment the first event arrived. Marking the methods `nonisolated` was not
/// enough: the isolation check is on the instance, not the method. The fix is that the object mpv
/// calls back into must not be actor-isolated at all.
final class MPVProbeCore: @unchecked Sendable {
    var onReport: ((String) -> Void)?

    private var mpv: OpaquePointer?
    private let queue = DispatchQueue(label: "mpv.probe", qos: .userInitiated)
    private let lock = NSLock()
    private var lines = [String]()
    private var loaded: URL?

    deinit {
        if let mpv { mpv_terminate_destroy(mpv) }
    }

    /// `layer` is handed to mpv as the window id, so it must outlive this call; the view controller
    /// owns it.
    func start(layer: CAMetalLayer, hwdec: String) {
        guard let handle = mpv_create() else {
            say("mpv_create 失敗")
            return
        }
        mpv = handle

        // MPVKit's iOS demo, unchanged: the layer is the window id, and gpu-next renders through
        // Vulkan on MoltenVK. hwdec=videotoolbox is the only hardware decoder iOS offers.
        var wid = Unmanaged.passUnretained(layer).toOpaque()
        check(mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid), "wid")
        check(mpv_set_option_string(handle, "vo", "gpu-next"), "vo")
        check(mpv_set_option_string(handle, "gpu-api", "vulkan"), "gpu-api")
        check(mpv_set_option_string(handle, "gpu-context", "moltenvk"), "gpu-context")
        // MPVKit's demo hardcodes `videotoolbox`. Measured on the iOS 26.3 simulator, that decoder
        // does not exist there — `hwaccel initialisation returned error` — and mpv then stalled on
        // `h264: no frame!` instead of falling back, so nothing ever reached the video output.
        // `auto-safe` is mpv's own recommendation and picks VideoToolbox where it exists.
        check(mpv_set_option_string(handle, "hwdec", hwdec), "hwdec")
        check(mpv_set_option_string(handle, "video-rotate", "no"), "video-rotate")
        check(mpv_request_log_messages(handle, "warn"), "log-level")

        guard check(mpv_initialize(handle), "mpv_initialize") else { return }

        mpv_set_wakeup_callback(handle, { ctx in
            guard let ctx else { return }
            Unmanaged<MPVProbeCore>.fromOpaque(ctx).takeUnretainedValue().drainEvents()
        }, Unmanaged.passUnretained(self).toOpaque())

        say("mpv 初始化完成")
    }

    func play(_ url: URL) {
        guard let mpv, loaded != url else { return }
        loaded = url
        queue.async {
            url.absoluteString.withCString { address in
                var args: [UnsafePointer<CChar>?] = [
                    ("loadfile" as NSString).utf8String, address, ("replace" as NSString).utf8String, nil,
                ]
                self.check(mpv_command(mpv, &args), "loadfile")
            }
        }
    }

    /// mpv's event queue. The events that matter here are the ones that distinguish "it played" from
    /// "it drew nothing": `FILE_LOADED` says the demuxer accepted the stream, `VIDEO_RECONFIG` says a
    /// frame geometry reached the video output, and `END_FILE` carries the reason it stopped.
    private func drainEvents() {
        guard let mpv else { return }
        while true {
            guard let event = mpv_wait_event(mpv, 0) else { return }
            let kind = event.pointee.event_id
            if kind == MPV_EVENT_NONE { return }
            switch kind {
            case MPV_EVENT_FILE_LOADED:
                say("FILE_LOADED " + describeVideo())
            case MPV_EVENT_VIDEO_RECONFIG:
                say("VIDEO_RECONFIG " + describeVideo())
            case MPV_EVENT_END_FILE:
                let reason = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee.reason
                say("END_FILE reason=" + (reason.map { "\($0.rawValue)" } ?? "?"))
            case MPV_EVENT_LOG_MESSAGE:
                if let message = event.pointee.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee,
                   let text = message.text {
                    say("log: " + String(cString: text).trimmingCharacters(in: .newlines))
                }
            default:
                break
            }
        }
    }

    /// The numbers that make a screenshot meaningful. A black frame and a dead renderer look the
    /// same; a reported size, codec and chosen VO do not.
    private func describeVideo() -> String {
        [("width", "w"), ("height", "h"), ("video-codec", "codec"), ("current-vo", "vo"),
         ("hwdec-current", "hwdec"), ("video-out-params/w", "vow"), ("vo-configured", "cfg"),
         ("osd-dimensions/w", "osdw")]
            .compactMap { property, label -> String? in
                guard let mpv, let raw = mpv_get_property_string(mpv, property) else { return nil }
                defer { mpv_free(raw) }
                let value = String(cString: raw)
                return value.isEmpty ? nil : "\(label)=\(value)"
            }
            .joined(separator: " ")
    }

    @discardableResult
    private func check(_ status: CInt, _ what: String) -> Bool {
        guard status < 0 else { return true }
        let text = mpv_error_string(status).map { String(cString: $0) } ?? "error \(status)"
        say("\(what) 失敗：" + text)
        return false
    }

    func note(_ line: String) { say(line) }

    private func say(_ line: String) {
        print("[mpv] " + line)
        lock.lock()
        lines.append(line)
        if lines.count > 40 { lines.removeFirst(lines.count - 40) }
        let text = lines.joined(separator: "\n")
        lock.unlock()
        onReport?(text)
    }
}

final class MPVProbeController: UIViewController {
    var url: URL?
    var hwdec = "no"
    var onReport: ((String) -> Void)?

    private let metalLayer = MetalLayer()
    private let core = MPVProbeCore()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        metalLayer.frame = view.bounds
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(metalLayer)
        core.onReport = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in self.onReport?(text) }
        }
        core.start(layer: metalLayer, hwdec: hwdec)
        core.note("layer \(Int(metalLayer.bounds.width))x\(Int(metalLayer.bounds.height)) scale \(metalLayer.contentsScale)")
        if let url { core.play(url) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        metalLayer.frame = view.bounds
    }

    func play(_ url: URL) {
        core.play(url)
    }
}
