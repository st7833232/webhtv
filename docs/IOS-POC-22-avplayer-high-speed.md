# IOS-POC-22 — AVPlayer 在 2.5×／3× 音訊與畫面異常

- 狀態：**已修正並在模擬器驗證**（2026-09-24，使用者選定做法，見第五節）；`53557061`，已於 2026-09-24 以 `0.1.14 (15)` 發布；真機未驗證。
- 使用者回報（2026-09-24，`0.1.13 (14)` 之前的版本）：「avplayer 在播放2.5倍跟3倍 音訊跟影片還是有問題」。
  之前 IOS-POC-15 已把 `audioTimePitchAlgorithm` 改為 `.timeDomain`（解決 2.5×／3× 沒聲音），當時就記錄「畫面會跳轉只解決了一半」。

## 一、根因

**AVPlayer 對 `canPlayFastForward == false` 的來源不支援超過 2.0×。**
SDK 標頭 `AVPlayerItem.h`（Xcode 27，iPhoneOS27.0 SDK）第 238 行：
「all AVPlayerItems with status AVPlayerItemReadyToPlay can be played at rates between 1.0 and 2.0, inclusive, even if canPlayFastForward is NO;
… canPlayFastForward indicates whether the item can be played at rates greater than 2.0.」
本專案的來源（荐片「交锋」，單一畫質、`variants=0`）`canPlayFastForward` 都是 false。超過 2.0× 時 AVPlayer 會**丟掉整段已緩衝的內容**，
改成只抓 1～4 秒的碎片、一直處在 waiting，位置跳動甚至倒退——這就是畫面跳格與聲音斷續。

## 二、模擬器實測（iPhone 17 Pro，iOS 26.3，荐片「交锋」，暫時加的每秒量測，已移除）

| 情境 | 結果 |
|---|---|
| 1×（第3集） | 5 秒內就緩衝 57 秒、之後維持約 60 秒；`observed` 約 10 Mbps（約 11 倍即時速度）；始終 playing、stalls 0、dropped 0 |
| 1× → 3×（第4集） | 設 3× 的那一秒 `loadedTimeRanges` = `1.4-107.0`（前方 60 秒）；**一秒後變成空的**；之後只剩 1～4 秒的碎片，`timeControlStatus` 一直是 waiting（`ToMinimizeStalls`／`WhileEvaluatingBufferingRate`），位置 94.1→90.1、109.3→107.0 倒退 |
| 同上，但**凍結我們的 buffer policy**（forward buffer 固定 60 秒，第5集） | 完全一樣：`0.0-111.7` 一秒後清空 ⇒ **不是我們的 policy 造成**，加大 buffer 也無效 |
| 2× | 正常：一直 playing，緩衝持續增加（`280.2-373.2` → `280.2-404.9`） |
| 2.5× | 與 3× 相同：`280.2-436.2` 立刻清空，進入 waiting／跳動 |
| **MPV 3×**（iPad mini 模擬器，第6集） | 一分鐘內始終 playing，每 5 秒前進約 15 秒（＝3.0×），cache 從 238 秒持續長到 555 秒 |

結論：網路與解碼都跟得上（1× 時下載約 11 倍即時；MPV 3× 順暢），問題是 AVPlayer 在 >2× 且 `canPlayFastForward == false` 時的降級模式。

## 三、對 ChatGPT 建議的逐點判斷（使用者 2026-09-24 貼上）

| 建議 | 判斷 |
|---|---|
| 保留 `.timeDomain` | 已是現況（IOS-POC-15），保留 |
| `defaultRate` + `rate` | 已是現況，保留 |
| 讀 `canPlayFastForward`，但不要當絕對禁止條件 | 實測與 SDK 標頭都顯示：false 時 >2× 就會壞，**這正是該用的判斷條件** |
| 2.5×／3× 加大 buffer 到 90～120 秒 | **無效**：現況在 3× 已自動把 forward buffer 升到 120 秒；凍結在 60 秒也一樣壞；AVPlayer 在這個模式下直接丟掉緩衝、只留碎片，buffer 設多大都用不到 |
| 網路跟不上時降自動畫質 | 這些來源只有單一畫質（`variants=0`），沒有可降的；而且瓶頸不是網路 |
| 記錄 rate／canPlayFastForward／buffer／stall／timeControlStatus／throughput | 這次已量過，結果見第二節；可以把其中幾項留在正式的 `[playback]` log |
| 接受 AVPlayer >2× 可能跳格；仍跳格時 MPV 較適合 | 同意，而且實測顯示「一定會壞」，不是「可能」 |

## 四、修法選項（待使用者選）

| 選項 | 內容 | 評估 |
|---|---|---|
| **A（建議）** | AVPlayer 播放中選 2.5×／3×，且 `canPlayFastForward == false` 時，**自動改用 MPV** 在同一位置、同一速度接著播（沿用 17B 手動切換核心的路徑：保留位置、速度、暫停狀態）；回到 ≤2× 時留在 MPV | 使用者要的速度真的能用；代價是換核心時約 1～3 秒重新起播；MPV 真機 3× 尚未驗（MPV parity P1） |
| B | AVPlayer 上 `canPlayFastForward == false` 時不提供 2.5×／3×（速度選單只到 2×），要高倍速請手動換 MPV | 最簡單、不會自動換核心；但高倍速要多一步 |
| C | 照 ChatGPT 加大 buffer | 實測無效，不建議 |

## 五、使用者選定的做法（2026-09-24，原文要點）

「AVPlayer 的 0.5×～2× 正常保留；使用者選 2.5×／3× 時，先等 `AVPlayerItem.status == .readyToPlay` 再檢查 `canPlayFastForward`。
若為 true，AVPlayer 原地切高倍速；若為 false，不要嘗試靠增加 buffer 強行播放，直接用既有 PlayerRouter 無縫切到 MPV，
保留同一 PlaybackTarget、position、播放／暫停狀態、集數、線路與畫質，並以使用者選的 2.5×／3× 繼續。不要限制整個 App 的 2.5×／3× 選項。」

## 六、實作

- `ios/Sources/WebHTVCore/PlaybackEngine.swift`
  - `PlaybackRateSupport.needsOtherEngine(rate:canPlayFastForward:)`：`rate > 2.0 && !canPlayFastForward`（`nativeLimit = 2`）。
  - `PlayerRouter.select(_:playing:)`：多一個可選的 `playing`，讓呼叫端帶入「使用者的播放／暫停意圖」——AVPlayer 在等資料時 `isPlaying` 是 false，但使用者沒有暫停。
    其餘沿用手動切換核心的 `handOff`：同一個 request（target、headers、history＝集數／線路／畫質）、目前位置、request 裡的速度。
- `ios/WebHTVApp/Sources/WebHTVApp.swift`
  - `AVPlayerEngine.checkRate()`：item 到 `.readyToPlay`（原本就有的 status 觀察）時、以及每次 `setRate` 後檢查；需要換核心就在下一個 main-actor 回合呼叫
    `PlaybackSession.nativeCannotPlayRate(playing: player.rate != 0)`（不在引擎自己的呼叫裡拆掉自己）。
  - `PlaybackSession.nativeCannotPlayRate(playing:)`：`router.select(.mpv, playing:)`，並記一行 `[playback] … at 3.0× — AVPlayer cannot play above 2× on this item; moved to MPV`。
  - 換過去之後這個播放 session 都留在 MPV（和手動切換一樣）；關掉播放畫面後回到預設核心，下次若仍是 >2× 會在 item ready 時再切一次。
  - 0.5×～2×、以及 `canPlayFastForward == true` 的來源：行為不變。速度選單不變。

## 七、驗證

| 檢查 | 結果 | 等級 |
|---|---|---|
| `swift test --package-path ios` | **354／354**（新增 3 條：>2× 且不能快轉才換核心、換到 MPV 保留 target／集數線路畫質／位置／3×／播放意圖、暫停中換過去仍是暫停） | 單元 |
| Simulator Debug build（iPhone 17 Pro） | BUILD SUCCEEDED | 模擬器 |
| 原生 1× 播放中，從控制列選 3× | log「at 3.0× — AVPlayer cannot play above 2× on this item; moved to MPV」；控制列變成「3×」「MPV」、繼續播放；之後每 10 秒前進 30.9 秒（3.09×） | 模擬器 |
| 關掉（第6集 729.5 秒）再開：這部作品記住 3×，預設核心是原生 | item ready 時切到 MPV，從約 729 秒接著播，之後 3.05× | 模擬器 |
| 暫停中切到 2.5×／3× | 單元測試；模擬器未實測 | 單元 |
| 2× 維持原生 | 規則的單元測試；模擬器未另外測 | 單元 |
| 真機（原生→MPV 的切換時間、MPV 3× 的聲音） | — | **未驗證** |

- 測試時暫時把 `PlayerChrome.autoHideSeconds` 改成 60，測完已還原並重新 build；iPhone 17 Pro 模擬器 App 資料測前備份、測後還原。

## Recovery anchor

- 目前：已修正、模擬器驗證完成，`0.1.14 (15)` 發布。
- 下一步（唯一）：使用者更新到 `0.1.14 (15)` 後，在真機確認選 2.5×／3× 會切到 MPV、聲音與畫面正常。
