# W-263 iOS 點播播放失敗自動換線：實作

- 工單：herdr W-263（Manager 派，使用者 2026-11-09 選實作）。設計：`docs/W-259-ios-auto-line-switch.md` 方案 C（本分支含 W-259 兩個文件 commit）。
- 分支：`task/W-263`，自 ios-poc `c3d99bab`（含 W-261）。

## 做了什麼

所有既有的恢復機制都用完之後，才自動換線。既有機制包括：引擎互換、預解析位址失敗後即時重解析一次（IOS-POC-15D）、抓取副本重試（W-243 C3）、W-253 起播放棄與已知失敗。換線規則：

- 換到下一條**有同一集**的線路，從失敗線路的下一條開始、繞回一輪，每條最多試一次。
- 播放器上顯示「「線路1」無法播放，正在切換線路至「線路2」」，下面有「停止換線」按鈕。
- 第一階段不換站、不加設定；離線下載的集數不換線。

| 位置 | 內容 |
|---|---|
| `ios/Sources/WebHTVCore/VodLineSwitcher.swift`（新） | `VodLineSwitcher`：一輪的順序、時間上限（120 秒）、略過沒有同一集或不可播的線。`Flag.sameEpisode(as:in:)`：同一集對應。 |
| `ios/Tests/WebHTVCoreTests/VodLineSwitcherTests.swift`（新） | 10 個測試（見下）。 |
| `WebHTVApp.swift` `PlaybackSession` | `vodLineObserver`：在既有 `lineObserver` 的 3 個最終失敗點和 1 個起播點一起通知；關閉播放器時清掉。不共用 `lineObserver`，因為它存在時會開啟直播的起播預算。另有 `onLineSwitch`（提示＋停止）、`holdPositionForLineSwitch()`。 |
| `WebHTVApp.swift` `VodView` | `play(_:flag:switching:)`、`observeLine`、`switchLine`、`showSwitchFailure`。手選集數或線路、`start()`（換集）都會重設這一輪。 |
| `WebHTVApp.swift` `PlayerView` | 換線提示下的「停止換線」按鈕；提示消失或換成其他提示時，按鈕一起拿掉。 |

### Reviewer 三條件

1. **同一集對應**（`Flag.sameEpisode`）：依序比對，對不到就跳過該線。
   1. 集名相同（不分大小寫、去頭尾空白）。
   2. 集名中第一段數字相同，而且該線只有一集是這個數字。
   3. 兩條線集數相同時，才用同一個位置。
2. **時間上限與停止**：一輪 120 秒（`VodLineSwitcher.roundLimit`），超過就不再換，直接顯示失敗。換線提示有「停止換線」按鈕，按下後這一集不再換線；關閉播放器同樣會停止。
3. **新線路重新解析和預熱**：`play(switching: true)` 會 `prefetch.invalidate()`＋`nextContent.dropAll()`，舊線的抓取副本和 `knownFailing` 都清掉；新線路即時解析，下一集的預載照常從頭來。

### 位置

- 已起播後失敗：`lineSwitchPosition()` 取 `max(lastPlayhead, router.request.startSeconds)`。後者是為了引擎互換後新引擎開不起來、讀到 0 的情況。
  - `VodView.lineResume` 保存這個位置，整輪每條線開檔前都用 `resumeNextOpen(at:)` 交給 `open`（沿用 W-243 的 `retryResumeSeconds`；每次 `open` 都會用掉它）。
- 這一集從沒起播過（`startupMilliseconds == nil`，例如 W-253 已知失敗在開引擎前就放棄，router 還留著上一集）：不取位置，新線路照一般續播（同集名才續播）。

### 與既有行為

- W-253 已知失敗（預熱連兩次 5xx）走 `router.giveUp` → `onUnrecoverable`，會通知換線；新線路的預熱重新開始。
- 預解析位址失敗：先即時重解析一次（`retryWithoutPrefetch`），失敗才換線。
- 解析失敗（詳情頁 `play` 沒有網址或丟錯）也換線；YouTube 停止（`YouTubeStopped`）不換。
- 換線中最後一條也解析失敗：原因顯示在播放器上（`onFailure(.source)`），不跳回詳情頁。
- 換線時先清掉上一條線的錯誤泡泡，避免蓋在新線路起播的畫面上。
- 直播不受影響：直播仍只用 `lineObserver`，`liveBudgetCounting` 的判斷沒變。

## 驗證

- `swift test --filter VodLineSwitcherTests`：10 個測試全過。
  - 一輪繞回、每條一次
  - 只有一條線
  - 集名優先
  - 集數數字
  - 集數不同時不用位置
  - 數字重複時只靠位置
  - 略過沒有該集的線
  - 略過不可播的集
  - 時間上限
  - 數字解析
- 完整 `swift test`：1478 個測試，只有 `AdBlockListTests.blocksTheAdSubresourcesWithoutTouchingThePageOrOverMatching` 失敗（WKWebView 本機 socket 逾時 21 秒）。這是既有的不穩定測試，`docs/IOS-POC-48-favorites.md:184` 有記錄，與本次改動的模組無關。
- Simulator（webhtv-w202，Debug build）：
  - 測試爬蟲：`artifacts/w243/work/srv/py/w263.py`
  - 設定：`w263-test.json`（18445）
  - 驅動：`artifacts/w263/w263.sh`
  - 證據：`artifacts/w263/`

| 情境 | 結果 | 證據 |
|---|---|---|
| W263換線：線路1 第1集固定回 500 | 原生 -1008 → MPV 失敗 → `line 線路1 failed — switching to 線路2` → 線路2 第1集 0.6 秒起播，之後自動接第2、3集（都在線路2）。結束畫面在 43 秒處正常播放，沒有錯誤泡泡 | `sw-key.txt`、`sw-end.png` |
| W263全壞：兩條線第1集都 500 | 換到線路2 一次，畫面顯示提示和「停止換線」按鈕；線路2 也失敗後顯示原因、播放鍵停住，沒有再換線、沒有轉圈 | `all-key.txt`、`all-notice.png`、`all-later.png` |
| W263換線（修正後重跑）：線路1 第1集從歷史紀錄的 19.6 秒開始，起播前就失敗 | 換到線路2 第1集，從約 19.6 秒起播（點播後 16 秒截圖，畫面時間 34.8 秒）| `sw2-key.txt`、`sw2-notice.png`、`sw2-end.png` |
| W263中途：線路1 第1集在 30 秒後的分段失敗 | 第一次跑的時候，原生在 29.8 秒碰到 HTTP 500，交 MPV 從 29.8 秒續播；MPV 遇到 500 分段當成「播完」，接到第2集（既有 MPV 行為，沒有走到換線）。改成接手時播放清單也失敗之後，App 內 proxy 兩次都把第 5 段以後回 200，注入沒生效（原因未查明，測試工具問題） | `mid-key.txt`、`mid2-key.txt` |

**未驗證**：

- 「已起播後失敗 → 換線後從原位置續播」沒有在 Simulator 走通：注入不穩，只有讀程式碼和上面的推論。
- 「停止換線」按鈕的點擊效果沒有實測，只看到按鈕出現。
- 實機沒有測（依規則只在 Simulator）。

## 回退

單一 commit，`git revert <commit>`。不改設定格式、不改紀錄格式（換線成功後紀錄的 `vodFlag` 是新線路，和手動換線相同）。

## Ponytail

`ponytail:ponytail-review` 審查未提交的完整 diff，找到 2 個必修，都已修正：

1. W-253 已知失敗在開引擎前就放棄時，`router.request` 和 `lastPlayhead` 還是上一集的（例如第1集播完的 60 秒），新線路的下一集會從結尾開始。修正：只有這一集真的起播過才取位置；位置存在 `VodView.lineResume`，整輪共用。
2. 手選集數、所有線路都解析失敗、播放器從沒打開時，`showSwitchFailure` 走 `onFailure`（沒有接收者），錯誤被吞掉。修正：沒有播放器時改設 `playbackError`。

修正後重新編譯，並重跑換線情境（上表「修正後重跑」）。審查沒有實測的：「停止換線」按鈕的點擊、播放中途失敗後的續播。

## REVISE 1（Reviewer #6937／#6938，2026-11-09）

- **C1 假起播會重設一輪**：`vodLineObserver?(.started)` 從 `isPlaying` 那一刻移到 `firstAdvance` 成功之後，也就是播放位置真的前進、`[playback] started` 那一行。直播的 `lineObserver?(.started)` 不變。
  - 理由：AVPlayer 可能沒拿到資料就回報 playing（W-246：72 ms playing，14 秒後 -1008）。在那個時點清掉 `lineRound`／`lineResume`，兩條壞線就可能來回跳，超過 120 秒上限。
- **C2 集數比對可能對到錯集**：集數規則加了條件，這個數字在**來源線**也必須只對到一集。`S01E05` 讀成 1，而同一季每集都讀成 1，所以不用集數規則，改走「兩線集數相同才用位置」或跳過。
  - 新測試 `aNumberSharedOnTheSourceLineDoesNotMatch`：S01E01…S01E10 對 第1集…第10集 → 第5集（位置）；對 12 集的線 → nil。修正前會得到第1集。
- 驗證：
  - `VodLineSwitcherTests` 11/11。
  - 重新編譯（Debug，Simulator）成功。
  - Simulator 重跑換線：線路1 -1008 → 換線路2 → 畫面前進後才記 started（`sw3-key.txt`、`sw3-notice.png`、`sw3-end.png`）。
