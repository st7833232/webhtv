# IOS-POC-22 — AVPlayer 在 2.5×／3× 音訊與畫面異常

- 狀態：**已查明原因（模擬器實測＋SDK 標頭），修法待使用者選擇**；程式沒有改。
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

## Recovery anchor

- 目前：原因已確認、修法待使用者選 A／B；程式沒有改。
- 下一步（唯一）：使用者選定後實作（A：播放中改速時在 AVPlayer 且 `canPlayFastForward == false` 就切到 MPV）。
