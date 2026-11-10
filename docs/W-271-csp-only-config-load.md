# W-271 只有 csp 站的設定檔在 iOS 不會載入

- 工單：W-271（CSP-ONLY-CONFIG-LOAD），quick-fix；W-266 Simulator 實測時發現。
- 分支：`task/W-271`（worktree `/Users/chengchenchih/GIT/webhtv-w271`，自 origin/ios-poc `b168c4eb`）。
- 證據：`.herdr-synapse/webhtv-dev/artifacts/w271/`（`diagnosis.md`、`red.log`、`green.log`、Simulator 截圖）。

## 1. 現象

遠端設定檔裡只有 `csp_*` 站，而這些類別只在該設定檔旁邊的相容包（`./spiders/manifest.json`）裡、App 本身與官方爬蟲包都沒有時，App 停在「尚未載入設定」。設定檔加一個 type 1 站就正常，相容包也有被下載。

## 2. 根因

1. `ConfigLoader.fetch(from:)` → `validate(_:)` 用預設 resolver（`SpiderRegistry.active()` ＝ 官方包＋**目前已安裝**的相容包）判斷有沒有可用的站。新設定檔的相容包還沒安裝，它的類別三種判斷（原生 CMS、可驅動的爬蟲站、等爬蟲工具的站）都不算 → `noSupportedSites`。
2. `WebHTVApp.load(remote:)` 因此不 `adopt`：設定檔不寫入磁碟、`source` 不切換。
3. 啟動流程接著 `refreshSpiderPack()` 照樣下載相容包，但 `rebuildSites()` 讀不到設定檔就返回；使用者從設定頁加網址的路徑則根本不抓相容包。結果 `sites` 永遠是空的。

## 3. 修法（最小）

- `SpiderPackStore.refresh(from:)` 拆成 `download(from:)`（抓＋驗證，不安裝）與 `install(_:)`（寫入磁碟並生效）；`refresh` = 兩者相加，行為不變。
- `ConfigLoader` 新增 `validate(_:from:packs:)`，`fetch(from:)` 改呼叫它：一般情況與原本相同；只有 `noSupportedSites` 時，才下載**該設定檔自己的**相容包，用「官方包＋這個相容包」再驗一次，**通過才安裝**相容包並回傳設定檔。相容包幫不上忙（沒有那些類別、下載或驗證失敗）就照舊拒絕，且不安裝，目前來源的相容包不受影響。
- App 端不用改：`adopt` 之後 `show(config)` 用的 `.active()` 已含剛安裝的相容包，站點直接列出；下次啟動的 `refreshSpiderPack()` 照常更新。

比較過的其他做法：
- 驗證時一律接受 csp 形狀的站：會讓完全不能用的設定檔取代快取中能用的那份（`validate` 註解明確要防這件事），不採用。
- 在 App 的 `load(remote:)` 先安裝相容包再驗證：設定檔最後仍被拒時，會把目前來源的相容包換掉，不採用。

## 4. 驗證

- 紅燈（只加入新入口、行為不變時）：`CspOnlyConfigLoadTests.aConfigDrivenOnlyByItsOwnPackLoadsAndInstallsThatPack` 失敗，`Caught error: .noSupportedSites`（`artifacts/w271/red.log`）。
- 綠燈：兩個測試都通過（`green.log`）——只靠自身相容包的設定檔通過驗證、相容包被安裝、`drivableSites` 列出該站；相容包沒有該類別時仍拒絕且不安裝。
- 完整 `swift test`：1507 個／63 suites 全過。
- Simulator：見第 6 節。

## 5. 回滾

單一 commit，revert 即可；`refresh` 的對外行為不變，其他呼叫端（App 啟動與設定頁的更新）不受影響。

## 6. Simulator 驗證（2026-11-10，w202，熱點網路）

測試設定 `artifacts/w271/served/w271-test.json`：只有一個站 `csp_W271Giri`，類別只在旁邊的 `spiders/manifest.json`（內容借 AnimeGiri.js，類別名稱獨一無二，確保 App 已裝的任何相容包都沒有它）。都從「設定 → 加入設定來源」輸入網址按「載入」。

| App | 結果 | 證據 |
| --- | --- | --- |
| 修正前（已裝的 0.1.82） | 跳出「無法載入：遠端設定載入失敗：此設定沒有 iOS 可用的來源（CMS 或已支援的爬蟲）」，來源不變；伺服器只收到設定檔請求，**沒有**抓相容包 | `old-result.png`、`https.log` 10:42:34 |
| 修正後（task/W-271 Debug 建置） | 直接切到「W271 只有爬蟲站」，分類（日番、美番…）與首頁 12 部列出；伺服器依序收到設定檔、`spiders/manifest.json`、`W271Giri.js` | `new-result.png`、`https.log` 10:53:58 |

備註：第一次重現時用的是 W-266 的 7 支類別，舊 App 啟動時已從 w266 來源裝了同樣的相容包，所以「載入成功」——這也說明此 bug 只在「設定檔的類別不在目前已安裝的相容包／官方包裡」時出現。模擬器目前裝的是 W-271 Debug 建置。

## 7. Ponytail

2026-11-10 對最終 diff 跑 `ponytail:ponytail-review`：Ship，無必修／應修。一項小建議未做（不在本單宣告路徑，記錄給後續）：新路徑在「加入設定來源」時安裝相容包，但設定頁「設定檔相容包」那一列（`WebHTVApp.packStatus`）只在啟動與 `refreshSpiderPack()` 更新，所以到下次啟動前會顯示前一個相容包的名稱；站點列出與播放不受影響。未驗：安裝相容包後寫入設定檔失敗（磁碟錯誤）時，舊來源到下次啟動前會用到新相容包，極少見。

## 8. 狀態

完成，待審。commit 見 guard finish。
