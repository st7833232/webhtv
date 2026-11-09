# W-260 新爬蟲包不必下拉重新整理就生效

- 工單：herdr W-260（Manager 派，W-250 附帶發現）；quick-fix；分支 `task/W-260` 自 ios-poc `ad6a66a0`。
- 範圍：`ios/WebHTVApp/Sources/WebHTVApp.swift`；順手兩處註解（`PlaybackEngine.swift` 的 `startupTimedOut`、`VodMetadataTests.swift` 擠在同一行的註解）。不改爬蟲包格式與驗證。

## 根因

啟動流程（`ContentView` 的 `.task`）原本是：
1. `loadOfficialPack()`、`restore()` → 首頁 `CMSView` 出現，`.task` 只在片單為空時載入一次 —— 這時用的是**正式工具包**的腳本。
2. `adoptCachedSpiderPack()` 才讀快取的相容包（`SpiderPackStore.installedPack()` 會把它設為 `InstalledSpiderPack.shared.current`），並 `rebuildSites()`。
3. `refreshSpiderPack()` 下載新相容包、重設 session、`rebuildSites()`。

`rebuildSites()` 只重算站清單；首頁 `CMSView` 的身分是 `selectedSite.id`，沒變就不會重建，片單也不會再載入。所以快取包和新下載的包都要等使用者下拉（`.refreshable`）才會用到。官方工具包經「檢查更新」或「重設」套用（`applyOfficialPack`）也是同樣情形。

## 修正（兩者都做，互補）

1. **首頁載入前先套用快取包**：`restore()` 之前呼叫 `SpiderPackStore.shared.installedPack()`（純磁碟讀取，原本啟動就會做，只是提早），移除之後的 `adoptCachedSpiderPack()`（`restore()` 的 `show()` 已用到在用中的包，原本那次 `rebuildSites()` 變多餘）。離線啟動照樣先用最後一個驗證過的包。
2. **新包套用後重新載入正在顯示的片單**：`refreshSpiderPack()` 比對下載前後的 `SpiderPack`（`Equatable`），不同才 `scriptRevision += 1`；`applyOfficialPack()` 每次都換了腳本，一律 +1。`scriptRevision` 經 `HomeView` 傳給 `CMSView`，`onChangeCompat(of: scriptRevision)` 執行和下拉相同的 `reloadListing()`（搜尋中就重跑搜尋）。不重建 view，所以不會把使用者已經點進的詳情頁彈回。

取捨：只做 2 會讓每次啟動（有快取包時）先用正式腳本載一次、再重載一次，畫面閃動也多一次請求；只做 1 則新下載的包仍要下拉。兩者合起來：快取包第一次就用上，只有包真的變了才多載一次。

## 驗證

- 單元測試：`swift test --filter 'VodMetadataTests|SpiderPack'` 24/24 通過。沒有新增測試：改動是呼叫順序與一個 `!=`；`InstalledSpiderPack.shared` 是全域單例，對它斷言會被平行測試干擾。行為以 Simulator 證明。
- Debug build：BUILD SUCCEEDED。
- Simulator（webhtv-w202；證據 `.herdr-synapse/webhtv-dev/artifacts/w260/`）：測試設定 `w260-test.json` 加一個 `csp_FirstAid` 站；18445 伺服器在設定同目錄提供 `spiders/manifest.json` 相容包，FirstAid 被換成首頁只列一部「W260 版本 n」的探測腳本（`mkpack.sh n`）。正式工具包 seq 14 也有 FirstAid（會連 m.youlai.cn 列出真實片單）。
  - 修正前（舊 build）：快取 v1、伺服器 v2，啟動 15 秒後首頁是「已載入 19 部」= 正式 FirstAid 的片單，不是相容包（`old2.png`）。重現 W-250 的描述。
  - 修正後：快取 v2、伺服器 v2，啟動 4 秒首頁就是「W260 版本 2」（`new2.png`）；伺服器改 v3，啟動 15 秒不下拉就是「W260 版本 3」，log 有兩次片單載入（快取 v2，下載完 40 ms 後自動重載 v3，`new3-applog.txt`）；包沒變再啟動，只載入一次（`same3`）。
  - 「site list ready」啟動時間：修正後 271～281 ms（安裝後第一次冷啟動 700 ms），修正前 221～349 ms，沒有明顯變慢。
- 測試完已把探測包移出伺服器目錄（`artifacts/w260/served-spiders-v3/`），以免共用的 18445 設定被套用。
- 未驗證：真機；官方工具包「檢查更新」路徑（`applyOfficialPack` 的 +1）只讀碼，沒有在 Simulator 實際下載新官方包。

## Ponytail

`ponytail:ponytail-review` 審 7accd7c1（Reviewer #6802 指出第一次送審漏了這個必要步驟，補跑）：Looks good. Ship.，沒有需要修改的發現。檢查了 `refreshSpiderPack`（只在啟動呼叫）與 `applyOfficialPack` 三個呼叫端（關播放器、檢查更新、重設；站清單空時首頁不顯示，+1 無作用）、已刪的 `adoptCachedSpiderPack` 沒有其他呼叫端、`onChangeCompat` 只在初值之後變化才觸發（新建的首頁不會多載一次）、重載與第一次載入重疊時由既有 `listingGeneration` 丟掉舊結果、離線啟動仍先用快取包、資料夾片單預設 0 行為不變。未查：真機、官方包「檢查更新」實際下載路徑。

## 回退

單一 commit，`git revert` 即可。

## 狀態

已送審（Reviewer：webhtv-dev-codex-reviewer-2）。
