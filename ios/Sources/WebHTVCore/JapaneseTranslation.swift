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
        return Texts(title: TaiwanTraditional.isJapanese(bare) ? title : nil,
                     synopsis: TaiwanTraditional.isJapanese(synopsis) ? synopsis : nil)
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
