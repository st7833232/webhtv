# W-332 追更新季提示：片名沒有年份時改用來源的 vod_year 比對

- 分支 `claude/kind-dirac-ojjljm`，接在 W-331（`66f0db6f`）之後。
- Lane：quick-fix，屬於 W-313 方案 C 既有設計內的修正。

## 1. 問題

使用者回報（2026-11-19）：追蹤 2026 年的《青蛙軍曹》，卻被提示《青蛙軍曹 第七季》，那一季是 2010 年。使用者要求：能比對時間時就要比對。

## 2. 原因

`Follow.searched(_:)` 只用片名裡的年份標記（例如「(2020)」）排除比追蹤作品更舊的「新季」，而且兩邊片名都有年份才比對。這兩部片名都沒有年份，所以沒有被排除。來源提供的 `vod_year` 有年份，但 App 沒有用到。

## 3. 做法

- `Follow` 新增可選欄位 `year: Int?`，存追蹤作品的 `vod_year`。舊檔沒有這個欄位，讀進來是 `nil`，用合成的 `Codable` 讀取，不需要遷移。
- 寫入時機：
  - 按鈴鐺建立追更時（`toggle`）。
  - 每次詳情檢查時（`FollowChecker.Outcome.listed` 多帶 `year`），包括使用者自己開啟詳情頁時（`detailLoaded`）。
  - 所以 W-332 之前建立的追更，在下一次詳情檢查後就會補上年份。
- `searched`：兩邊的年份都是先取片名裡的年份，沒有才用 `vod_year`。兩邊都有年份、而且候選比較舊時就排除。只有一邊有年份時照舊只看片名，符合「能比對才比對」。
- 已經存著的錯誤提示：如果下一次新季搜尋把它列為比較舊，就移除。新季搜尋一天一次，所以錯誤提示最晚約一天後消失；使用者點開那一季也會照舊清除。
- `Follow.year(in:)` 取 `vod_year` 裡第一個 4 位數、介於 1900 到 2100 的年份，例如「2010-2011」取 2010。

## 4. 驗證

- 新增測試：
  - `aLaterSeasonOlderByTheSourcesYearIsNoNewSeason`：重現青蛙軍曹 2026 對上第七季 2010 的情況，也涵蓋只有一邊有年份、比較新的一季、`year(in:)` 的邊界。
  - `aFollowLearnsItsYearAndDropsAnOlderHint`：舊追更在詳情檢查後補上年份，下一次搜尋移除錯誤提示。
- 已更新既有測試的 pattern：`.listed(let listed, _, _)`。
- 本機沒有 Swift／Xcode，**以上測試尚未執行**，也還沒編譯。只做了 diff 靜態審查，並用 grep 確認所有呼叫點都已更新：`Follow(identity:`、`.listed(`、`updated(with:`。
- Ponytail：unavailable / skipped（此環境沒有提供）。

## 5. 風險

- 來源的 `vod_year` 填錯時，可能漏掉真正的新季。只有兩邊都有年份、而且候選比較舊才會排除。
- 追更檔多了一個欄位。舊版 App 讀新檔時，合成的 `Decodable` 會忽略不認得的鍵，不會失敗。

## 6. 回復

`git revert <W-332 commit>`。回退後，新檔裡多出的 `year` 鍵會被忽略。

## Recovery anchor

- 狀態：程式碼、測試與文件已完成，尚未編譯也尚未執行測試。
- 下一步：取得推送授權後，在 macOS 上執行 `swift test --filter FollowTests` 並編譯 App。
