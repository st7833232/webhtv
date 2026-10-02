import Foundation

/// IOS-POC-32 D: which detail-screen strings are Japanese enough to offer for translation, and the
/// setting that decides whether to. The translation itself is Apple's on-device Translation
/// framework, driven by the app; nothing here talks to it, so this part is testable anywhere.
public enum JapaneseTranslation {
    /// 關／詢問／自動. `ask` offers a button; `auto` translates when the language is already on the
    /// device and offers the button (which starts the system download prompt) when it is not.
    public enum Mode: String, CaseIterable, Sendable {
        case off, ask, auto

        public var label: String {
            switch self {
            case .off: "關"
            case .ask: "詢問"
            case .auto: "自動"
            }
        }
    }

    /// What to send, each part only when it is Japanese. The two go as separate requests: a Chinese
    /// site often pairs a Chinese title with a Japanese synopsis, and one batch must be one language.
    public struct Texts: Hashable, Sendable {
        public var title: String?
        public var synopsis: String?

        /// Also the translation's result: the same two parts, each only when it was sent.
        public init(title: String? = nil, synopsis: String? = nil) {
            self.title = title
            self.synopsis = synopsis
        }

        public var isEmpty: Bool { title == nil && synopsis == nil }
    }

    /// Bracketed asides are left out of the title's test — 海贼王（ワンピース） is a Chinese title
    /// with its Japanese name attached, not a Japanese title. Cast and director are never sent: a
    /// translated name is almost always wrong.
    public static func texts(title: String, synopsis: String) -> Texts {
        let bare = title.replacingOccurrences(of: #"[\[【(（][^\]】)）]*[\]】)）]"#, with: "",
                                              options: .regularExpression)
        return Texts(title: isJapanese(bare) ? title : nil,
                     synopsis: isJapanese(synopsis) ? synopsis : nil)
    }

    /// Mostly kana, by the ratio of kana to Han characters rather than by any kana at all: a Chinese
    /// synopsis may quote a Japanese title. The katakana middle dot and the prolonged sound mark
    /// (・ ー ･ ゠) are not counted, because Chinese writes foreign names with them (湯姆・克魯斯).
    /// The Taiwan display conversion leaves what this calls Japanese alone; it lives here because
    /// nothing else in Core may name that conversion (the display-only rule, IOS-POC-32).
    public static func isJapanese(_ text: String) -> Bool {
        var kana = 0
        var han = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3041...0x3096, 0x309D...0x309F, 0x30A1...0x30FA, 0x30FD...0x30FF, 0x31F0...0x31FF,
                 0xFF66...0xFF6F, 0xFF71...0xFF9D:
                kana += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F:
                han += 1
            default:
                break
            }
        }
        return kana >= 2 && kana * 4 >= kana + han
    }
}

/// The 日文翻譯 setting. Off until the user turns it on (2026-09-28).
public struct JapaneseTranslationPreference: Sendable {
    public static let key = "webhtv.translation.japanese"

    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var mode: JapaneseTranslation.Mode {
        defaults.string(forKey: Self.key).flatMap(JapaneseTranslation.Mode.init(rawValue:)) ?? .off
    }

    public func setMode(_ mode: JapaneseTranslation.Mode) {
        defaults.set(mode.rawValue, forKey: Self.key)
    }
}
