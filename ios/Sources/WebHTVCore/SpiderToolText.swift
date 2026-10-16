import Foundation

/// IOS-POC-61 S3 (W-121): what the settings page's 爬蟲工具 section says (plan §2.3, §2.4). Every refusal keeps
/// the version that runs now, and the text says so.
public enum SpiderToolText {
    /// S5: nothing is bundled, so no generation means 未安裝. A generation the N version seeded from its bundle is an
    /// official pack like any other (plan §2.3).
    public static func status(of official: OfficialSpiderPack?) -> String {
        guard let official else { return "未安裝" }
        return "官方包 \(official.version)（序號 \(official.generation.sequence)，\(official.scripts.count) 支）"
    }

    /// The 設定檔相容包 row after a failed refresh of `./spiders/manifest.json`. Most configurations publish no pack, so
    /// a 404 with nothing installed is the normal answer and shows no row (W-138); `installed` describes a pack that
    /// is still in use, and any other failure is shown.
    public static func compatibilityRow(failure: Error, installed: String?) -> String {
        if installed == nil, failure as? SpiderPackError == .invalidHTTPStatus(404) { return "" }
        let reason = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
        return "\(installed ?? "沒有")（更新失敗：\(reason)）"
    }

    /// `scripts` is what runs after an install (0: nothing is installed, so there is no version to keep using);
    /// `playing` holds an installed pack back until the player closes.
    public static func result(of outcome: RuntimePackUpdater.Outcome, scripts: Int, playing: Bool) -> String {
        let keep = scripts == 0 ? "請稍後再試" : "繼續使用目前的版本"
        return switch outcome {
        case .installed where playing: "已下載，關閉播放器後套用"
        case .installed(let version, let tooNew) where tooNew.isEmpty: "已更新到 \(version)（\(scripts) 支）"
        case .installed(_, let tooNew):
            "已更新；其中 \(tooNew.count) 支需要較新的 App，暫時沿用目前版本：\(tooNew.joined(separator: "、"))"
        case .upToDate: "已是最新版本"
        case .unreachable: "無法連線，\(keep)"
        case .failed: "下載沒有完成，\(keep)"
        case .rejected(.rollback): "伺服器版本比目前的舊，已忽略"
        case .rejected(let rejection) where rejection.requiresNewerApp: "這個版本需要較新的 App，請到 SideStore 更新"
        case .rejected: "更新包驗證失敗，沒有採用，\(keep)"
        }
    }
}
