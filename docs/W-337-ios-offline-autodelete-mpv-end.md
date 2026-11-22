# W-337 MPV 播完下載集數時，看完後自動刪除沒有生效

- 分支 `claude/kind-dirac-ojjljm`，從 ios-poc `f1cc1395`（0.1.112 發版 commit）開。
- Lane：quick-fix。

## 1. 問題

使用者回報（2026-11-22）：下載的集數看完後，「看完後自動刪除」沒有生效。

## 2. 原因

- `PlaybackSession.finished(reason:)` 把 `position` 交給 `OfflineCompletionPolicy.ended`。規則（IOS-POC-52 F12）：`duration - position > 5` 秒時視為引擎提早放棄，不算看完。
- MPV 播到檔尾時會丟掉 `time-pos`，`MPVEngine.currentTime` 因此回傳 0，但 `duration` 仍在。W-261 已記錄這個行為，並為此加了 `lastPlayhead`（改用 `MPVEngine.reachedSeconds`），只是這裡沒用到。
- 結果：MPV 播完的下載集數被判為「離結尾還很遠」，沒有 `markWatched`，也就不會 `pendingAutoDelete`，看完後不刪除。
- 0.1.110（W-333）起，VVC／ByteVC2 的下載集數一律用 MPV 播放，所以紅果「未標示」的集數一定會遇到。預設引擎設成 MPV 的使用者也會遇到。
- 實際是哪個時機（`time-pos` 事件在 `END_FILE` 之前或之後到達）沒有實機 log 可確認。這是從程式碼和 W-261 的記錄推得的。

## 3. 做法

- `finished(reason:)` 改傳 `lastPlayhead`：引擎回報值大於 0 就用它，否則用 MPV 最後到達的位置 `reachedSeconds`。AVPlayer 的行為不變，因為它結束時 `currentTime` 就等於片長。
- 「拖到片尾不算」的判斷（`seekedToEnd`）、5 秒容差、「刪除要等播放器放開檔案」都沒有改。

## 4. 驗證

- 本機沒有 Swift，**尚未編譯**，只做了 diff 靜態審查。`lastPlayhead` 是同一個類別裡既有的 private 屬性。
- 實機待確認：
  1. 用 MPV 播一集已下載、而且「看完自動刪除」為開的集數（例如紅果「未標示」的集數），播到結尾或片尾自動跳下一集。
  2. 換到下一集或關閉播放器後約 1 秒，這集會從下載頁消失。log 會出現 `watched autoDelete=armed` 和 `deleted reason=watched`。
- Ponytail：unavailable / skipped（此環境沒有提供）。

## 5. 其他不會刪除的情況（設計如此，不是缺陷）

- 設定裡的「看完後自動刪除」關閉，或這集下載時選擇不自動刪除。
- 播的是線上版本，不是下載的那份。例如詳情頁選的線路和下載時不同。
- 拖到片尾、離結尾超過 5 秒就關閉、或播放失敗。
- 播完後播放器還開著、停在結尾：要等關閉播放器或換集時才刪除。

## 6. 回復

`git revert <W-337 commit>`。

## Recovery anchor

- 狀態：程式碼與文件已完成，尚未編譯。
- 下一步：取得授權後推送並發佈，實機確認 MPV 播完的下載集數會自動刪除。
