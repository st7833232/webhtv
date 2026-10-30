# W-232 設定 → 爬蟲工具顯示官方爬蟲包版本說明

## Recovery anchor
- 目標：在 App「設定 → 爬蟲工具」顯示官方爬蟲包的版本說明（manifest `notes`），沒有說明的包不顯示空區塊。
- 狀態：實作、測試、Simulator 驗證完成，送 Reviewer。
- 分支：`task/W-232`，以 `origin/ios-poc` `5ef74c91` 為底。
- 下一步：等 Reviewer 審查。

## 範圍
- `ios/Sources/WebHTVCore/RuntimePackStore.swift`：新增 `RuntimePackReleaseNote`、`RuntimePackStore.releaseNotes()`。
- `ios/WebHTVApp/Sources/WebHTVApp.swift`：`loadOfficialPack()` 一併讀說明；`SettingsView.spiderToolSection` 在「狀態」下方列出。
- `ios/Tests/WebHTVCoreTests/RuntimePackStoreTests.swift`：測試用 manifest 可帶 `notes`，新增一個測試。
- 沒有改 manifest 格式、驗證規則、更新流程，也沒有從網路另抓 CHANGELOG。

## 設計
- 手機上只保留兩代：使用中（active）和上一代備援（last known good），見 `prune(keeping:)`。`releaseNotes()` 依序讀這兩代的 `manifest.json`，先比對 SHA-256，再解析，取出非空的 `notes`。
- 順序：active 一定比 last known good 新（序號只會往上；壞掉時 last known good 會被清掉），所以不用另外排序。
- 顯示：每一代一列可展開的 `DisclosureGroup`，標題是「版本說明 <version>（序號 <sequence>）」，預設收合。說明最長 4 KB，收合後不會把按鈕擠下去。內文用 `Text(verbatim:)`，不渲染 Markdown 或連結（notes 是不受信任的純文字）。
- 更新時機：安裝、重設、關閉播放器後套用，都走 `applyOfficialPack()` → `loadOfficialPack()`，說明和狀態列一起更新。

## 驗證
- 完整 `swift test`：1426 個全過（`artifacts/w232-pack-notes-ui/swift-test-all.txt`）。
- 新測試 `releaseNotesListTheKeptGenerationsNewestFirst`：空的 store 回傳空陣列；兩代都有說明時新的在前，前後空白會去掉；沒有說明的那一代不列。
- Simulator（webhtv-w202，iOS，Debug build，裝上的 `WebHTVApp.debug.dylib` 和建置產物 sha256 相同：`installed-hashes.txt`）：
  - `1-no-notes-seq13.png`：原本裝的序號 13（2026-10-28.1）沒有說明，畫面只有狀態列，沒有空白區塊。
  - `3-notes-seq14-expanded.png`：按「檢查更新」裝上 2026-10-29.1（序號 14）後，出現「版本說明 2026-10-29.1（序號 14）」，展開後顯示該包的說明全文。序號 13 現在是備援，但沒有說明，所以不列。
  - 操作方式：`axe tap` 在冷開機後沒有反應（團隊已知問題 F-3），改用 XCUITest 單次腳本（`oneshot-Driver.swift`、`driver-run.log`）。
- Ponytail：Ship，沒有發現問題。

## 限制
- 如果裝回比較舊的 App，而 active 那一代這個 App 跑不動，清單仍會列出 active 的說明，但狀態列顯示的是實際在跑的上一代。兩列各自標出序號，分得出來。
- 只驗了 iOS，這件工作不涉及 Android。

## 回復
- 還原 `task/W-232` 這個 commit 即可，沒有資料格式變動。
