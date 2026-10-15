import Foundation

/// IOS-POC-61 S3 (W-121): what the settings page's 爬蟲工具 section says (plan §2.3, §2.4). Every refusal keeps
/// the version that runs now, and the text says so.
public enum SpiderToolText {
    /// Scripts, not class names: an alias runs one of them.
    static let bundledScripts = Set(SpiderRegistry.ported.map { SpiderRegistry.aliases[$0] ?? $0 }).count

    public static func status(of official: OfficialSpiderPack?, baseline: String? = SpiderBaseline.identity) -> String {
        guard let official else { return "內建基準（\(bundledScripts) 支）" }
        // W-122: the seeded generation is this build's own content, whatever sequence carried it.
        let name = official.generation.contentIdentity == baseline ? "內建基準" : "官方包"
        return "\(name) \(official.version)（序號 \(official.generation.sequence)，\(official.scripts.count) 支）"
    }

    /// `scripts` is what runs after an install; `playing` holds an installed pack back until the player closes.
    public static func result(of outcome: RuntimePackUpdater.Outcome, scripts: Int, playing: Bool) -> String {
        switch outcome {
        case .installed where playing: "已下載，關閉播放器後套用"
        case .installed(let version, let tooNew) where tooNew.isEmpty: "已更新到 \(version)（\(scripts) 支）"
        case .installed(_, let tooNew):
            "已更新；其中 \(tooNew.count) 支需要較新的 App，暫時沿用目前版本：\(tooNew.joined(separator: "、"))"
        case .upToDate: "已是最新版本"
        // shortcut: N always has the bundled scripts; S5 (nothing bundled) adds 「無法連線，請稍後再試」.
        case .unreachable: "無法連線，繼續使用目前的版本"
        case .failed: "下載沒有完成，繼續使用目前的版本"
        case .rejected(.rollback): "伺服器版本比目前的舊，已忽略"
        case .rejected(let rejection) where rejection.requiresNewerApp: "這個版本需要較新的 App，請到 SideStore 更新"
        case .rejected: "更新包驗證失敗，沒有採用，繼續使用目前的版本"
        }
    }
}
