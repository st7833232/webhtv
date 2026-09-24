import CoreGraphics

/// IOS-POC-16B — the player's second-level selections, and whether its control bar is showing.
///
/// **Why this is ours and not SwiftUI's `Menu`.** The player redraws four times a second (position,
/// buffer, rate, engine) and hides its bar after five seconds. A `Menu` gives no callback when it
/// opens or closes, so the auto-hide could not be paused around it: the bar faded — opacity 0, hit
/// testing off — under an open menu and took its anchor with it, and the per-tick redraws made the
/// menu flicker (reported on the device, 2026-09-24). A panel we present ourselves is state we own,
/// so "a panel is open" can simply mean "do not hide".
///
/// Pure state, like `PictureInPictureForegroundRestoreState`: SwiftUI draws it in the app target,
/// `swift test` checks the rules here. One value covers AVPlayer and MPV alike.
public enum PlayerPanel: Sendable {
    case speed, quality, engine, subtitle, audio, opening, ending

    public var title: String {
        switch self {
        case .speed: return "播放速度"
        case .quality: return "畫質"
        case .engine: return "播放器"
        case .subtitle: return "字幕"
        case .audio: return "音軌"
        case .opening: return "片頭"
        case .ending: return "片尾"
        }
    }
}

public struct PlayerChrome: Equatable, Sendable {
    /// Restarted by every interaction, and only ever counting while no panel is open.
    public static let autoHideSeconds: Double = 5

    public private(set) var controlsVisible = true
    /// At most one — opening another replaces it.
    public private(set) var panel: PlayerPanel?

    public init() {}

    /// Whether the five-second countdown may run. **Never while a panel is open**: that is the
    /// whole fix — the bar cannot fade out from under a selection the viewer is making.
    public var autoHideArmed: Bool { controlsVisible && panel == nil }

    /// A bar button: opens its panel, or closes it when it is the one already open.
    public mutating func toggle(_ panel: PlayerPanel) {
        self.panel = self.panel == panel ? nil : panel
        // A panel is never shown over a hidden bar.
        if self.panel != nil { controlsVisible = true }
    }

    public mutating func dismissPanel() { panel = nil }

    /// Brings the bar back without a tap — for a VoiceOver user, who cannot reach the tap surface.
    public mutating func show() { controlsVisible = true }

    /// A tap on the picture. With a panel open it only closes the panel — the viewer is dismissing
    /// what they opened, not asking for the bar to go.
    public mutating func tapBackground() {
        if panel != nil { panel = nil } else { controlsVisible.toggle() }
    }

    /// The countdown ran out. A paused player keeps its bar — hiding the controls of something that
    /// is not moving leaves a still frame with no sign it is paused — and so does an open panel.
    public mutating func autoHideFired(isPlaying: Bool) {
        if autoHideArmed && isPlaying { controlsVisible = false }
    }
}

/// Where a panel sits, from the safe area the control bar is laid out in.
///
/// - Portrait: a sheet from the bottom, no taller than the letterbox under a centred 16:9 picture,
///   so it covers neither the picture nor its subtitles. The picture is centred on the *whole*
///   screen, and on every iPhone the portrait top inset is at least the bottom one, so reading the
///   letterbox from the safe area errs towards more clearance, never less.
/// - Landscape: a drawer on the trailing side, 260–320 pt wide, keeping most of the picture visible.
/// - Landscape too narrow for that (the drawer would leave under 55 % of the width — on iPhone only
///   iPhone SE with Display Zoom gets here): a low panel from the bottom that stops **above** the
///   bottom fifth of the screen, where subtitles are drawn.
///
/// ponytail: the picture is assumed to be 16:9. A 4:3, 2.39:1 or vertical source is placed as if it
/// were; read the item's `presentationSize` if that ever misplaces a sheet enough to matter.
public enum PlayerPanelPlacement: Equatable, Sendable {
    /// `clearance` is kept free below the panel.
    case bottom(maxHeight: Double, clearance: Double)
    case trailing(width: Double)

    static let drawerWidth: ClosedRange<Double> = 260...320
    /// A drawer is used only if it leaves at least this share of the width to the picture.
    static let minimumPictureShare = 0.55
    /// A header and two rows — the least a panel can usefully be, however little letterbox there is.
    static let minimumSheetHeight: Double = 144
    /// The part of the screen, from the bottom, that subtitles occupy.
    static let subtitleBand = 0.2

    public static func placement(in size: CGSize) -> PlayerPanelPlacement {
        let width = Double(size.width)
        let height = Double(size.height)
        guard width > height else {
            let letterbox = (height - width * 9 / 16) / 2
            return .bottom(maxHeight: max(letterbox, minimumSheetHeight), clearance: 0)
        }
        let drawer = min(max(width * 0.34, drawerWidth.lowerBound), drawerWidth.upperBound)
        if width - drawer >= width * minimumPictureShare { return .trailing(width: drawer) }
        return .bottom(maxHeight: height * 0.4, clearance: height * subtitleBand)
    }
}
