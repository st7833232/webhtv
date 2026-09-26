# IOS-POC-29 — 設定頁的預設播放速度

- 狀態：**研究與規劃完成（2026-09-26），等待使用者核准；核准前不實作。**
- 使用者原始要求（2026-09-26，`0.1.25 (26)` 發布後）：「幫我在設定頁多一個預設速度的設定」。背景：使用者一律用 2 倍速觀看（IOS-POC-27）。
- 本文件依 AGENTS.md §7 記錄研究、現況審查、方案比較、建議、驗收標準與回滾。

## 一、要實現的能力

開一部新片時，直接以設定頁選的速度開始播放，不必每部片都手動調到 2 倍。

## 二、研究（2026-09-26）

| # | 來源 | 等級 | 論點 | 對決策的影響 |
|---|---|---|---|---|
| R1 | `origin/main` `app/src/main/java/com/fongmi/android/tv/setting/PlayerSetting.java:298-304` | B（本專案 Android 版） | Android 有 `getDefaultSpeed`／`putDefaultSpeed`（鍵 `play_speed`，預設 1，範圍 0.5～5） | 已有對應功能，iOS 補上屬於 parity |
| R2 | `origin/main` `app/src/mobile/.../VideoActivity.java:3823-3838, 4402` | B | 點播開片時 `setSpeed(getDefaultSpeed())`；在播放器調速度時 `saveDefaultSpeed()` 自動寫回預設 | Android 的預設是「上次用的速度」，沒有獨立設定列 |
| R3 | `origin/main` `app/src/mobile/.../LiveActivity.java:1221` | B | 直播只有回看時才用預設速度，否則 1 倍 | 直播不適合倍速 |
| R4 | `docs/IOS-POC-14-autoplay-next-episode.md:128-141`（IOS-POC-14B） | 本專案決定 | 使用者指定：速度只在同一部片內沿用；開另一部片回到 1 倍 | 本任務把「回到 1 倍」改成「回到預設速度」，同一部片內沿用不變 |
| R5 | `AVPlayer.defaultRate`（iOS 16+，developer.apple.com/documentation/avfoundation/avplayer/defaultrate） | A | `play()` 以 `defaultRate` 開始播放 | 既有的 `loadNative` 已用 `defaultRate = request.rate`，新設定只要改變 `request.rate` 的來源 |

不適用的證據類別：不涉及上游合併、原生相依或效能；成熟專案的做法以 R1～R3（本專案 Android 版）為準，已足以決定。

## 三、現況審查

| 位置 | 內容 |
|---|---|
| `ios/WebHTVApp/Sources/WebHTVApp.swift:2271` | `open(url:…)`：新片（`WatchHistory.key` 不同或沒有 key）時 `chosenRate = 1` |
| `WebHTVApp.swift:2438` | `open(_ vod: InlineVod)`（WebHome 內嵌播放清單）：`chosenRate = 1` |
| `WebHTVApp.swift:2097-2101` | `rate` 觀察者把非零速度寫回 `chosenRate`（播放器調速度） |
| `WebHTVApp.swift:2358-2362` | `setRate`：播放器選單設定速度 |
| `WebHTVApp.swift` `PlayerControlBar.speeds` | 播放器選單：0.5、1、1.25、1.5、2、2.5、3 |
| `ios/Sources/WebHTVCore/HLSAdSkip.swift:522-531` | `HLSAdSkipPreference`：設定值放在 `UserDefaults` 的既有寫法 |
| `WebHTVApp.swift` `SettingsView`（約 `:1211-1270`） | 設定頁已有「預設播放器」與「智慧去廣」兩區 |
| `ios/Sources/WebHTVCore/PlaybackEngine.swift:343-347` | IOS-POC-22：2 倍以上、項目不能快轉時改用 MPV |

## 四、方案比較

| 方案 | 內容 | 優點 | 缺點與風險 |
|---|---|---|---|
| O0 不改 | 每部片手動調速度 | 無 | 使用者每部片都要調 |
| O1 設定頁一列，選項同播放器選單（建議） | 新片以預設速度開始；同一部片內沿用你調的速度（14B 不變）；播放器調速度**不**改預設 | 行為可預期；設定頁的值只有你自己改 | 與 Android 不同（Android 會自動記住上次速度） |
| O2 Android 做法 | 播放器調速度就自動寫回預設 | 與 Android 一致 | 推翻 14B 的「只在同一部片內」；設定頁的值會在背後被改掉 |
| O3 O1 加上「直播回到 1 倍」 | 項目確定是直播或長度未知時改回 1 倍 | 直播不會以 2 倍追到直播點後反覆卡住 | 多一段跨兩個核心的判斷；長度未知的點播會被誤判；本 App 目前沒有直播專區 |

## 五、建議

採用 **O1**。

1. **WebHTVCore**：新增 `PlaybackSpeedPreference`（寫法同 `HLSAdSkipPreference`），鍵 `webhtv.playback.defaultSpeed`，選項 0.5、1、1.25、1.5、2、2.5、3，預設 1；讀到不在選項內的值一律當 1。
2. **PlaybackSession**：兩處 `chosenRate = 1` 改為讀預設速度。其餘（同一部片內沿用、播放器選單、`defaultRate`）不變。
3. **設定頁**：「預設播放器」下方新增「預設播放速度」區，列出各速度，勾選目前值；說明：「開新的影片時使用。同一部片換集沿用播放中調整的速度；播放中調整不會改變這裡的設定。2.5×、3× 在原生播放器不支援的影片上會改用 MPV。」
4. **測試**：預設值、每個選項的儲存與讀回、不合法的值當 1。

## 六、驗收標準

1. 單元測試（有 Mac 時執行）：新增的 `PlaybackSpeedPreference` 測試全部通過；既有測試不修改。
2. Release workflow 第一次即編譯成功。
3. 真機：
   - T1：設定頁選 2×，開一部新片，播放器顯示 2×，而且真的以 2 倍播放。
   - T2：播放中改成 1.5×，自動接下一集仍是 1.5×（14B 不變）。
   - T3：再開另一部片，回到設定頁的 2×。
   - T4：設定頁選 1×，行為與 `0.1.25 (26)` 相同。
   - T5：設定頁選 3×，原生不能快轉的影片照舊改用 MPV（IOS-POC-22）。
   - T6：設定在重開 App 後保留。

## 七、回滾

1. 單一 commit，`git revert` 即可。
2. 使用者端：設定頁選回 1×，即恢復現況行為。

## 八、未解與後續

1. 直播或長度未知的影片也會以預設速度開始（O3 未採用）。本 App 目前沒有直播專區；若之後出現，再評估 O3。

## Recovery anchor

- 目標：設定頁新增「預設播放速度」，新片以此速度開始。
- 狀態（2026-09-26）：研究與規劃完成，未實作；使用者尚未核准。
- 相關檔案：`ios/Sources/WebHTVCore/HLSAdSkip.swift`（寫法參考）、`ios/WebHTVApp/Sources/WebHTVApp.swift`（`PlaybackSession.open`、`SettingsView`）。
- 下一步（唯一）：等使用者核准 O1（或選 O2、O3）。
