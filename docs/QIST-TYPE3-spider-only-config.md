# QIST-TYPE3 — 純爬蟲設定可通過 validation

## Recovery anchor

- **目標**：`ConfigLoader.validate` 接受全為 type-3、但 registry 能驅動其中至少一個類別的設定（qist `XYQ.json` 49 站全 type-3）；未知 type-3、空來源仍拒絕，原 CMS 設定照常可用，被拒的內容不取代有效快取。
- **Lane／scope**：quick-fix，guard `QIST-TYPE3`，獨立 worktree `/private/tmp/webhtv-qist-type3`，分支 `ios-poc-qist-type3`，基準 `88ea5ce9a48c2453be3df38dd60f5448db4ca4e7`。只改 `ios/Sources/WebHTVCore/ConfigLoader.swift`、`ios/Tests/WebHTVCoreTests/ConfigSourceTests.swift` 與本文件。與 QIST-JSONC（`ios-poc-qist-jsonc`）分開，不依賴 JSONC，測試用嚴格 JSON fixture。
- **不在範圍**：`decode`、新增 adapter、播放器、App 呼叫端。
- **狀態**：實作完成，focused proof 見第 4 節；待 Reviewer 審查，未 commit。
- **下一步（唯一）**：Reviewer 審查本 diff（快取保護、效能）；通過後以 guard `finish --no-tag` 提交。

## 1. 問題證據

- `docs/IOS-POC-57-qist-jar-spiders.md` Findings 2：刪掉註解後，`validate` 仍拒絕 `XYQ.json`，因為 49 站全是 type-3，`nativeCMSSites` 為空，錯誤「此設定沒有 iOS 可用的 CMS 來源」。
- 但這些站有一部分 App 本來就能跑（例如 `csp_JianPian`，`SpiderRegistry.ported` 內建類別），`drivableSites(resolvedBy:)` 也會把它們列進站台清單；只有 validate 只看 CMS。

## 2. 呼叫端與快取保護

- `validate` 由 `fetch(from:)`（遠端）與 `WebHTVApp.swift` 的匯入（:320）、`rebuildSites`（:455）、還原（:577）呼叫。四條路徑都是「validate 失敗 → 不 adopt／不寫入」，所以被拒的設定不會取代快取；這個契約沒變。
- 判斷沿用既有的 `spiderSites(resolvedBy:)`（= `drivableSites` 的爬蟲部分）與 `CSPSourceResolver.canResolve`，不是「所有 type-3 都接受」。

## 3. 設計決策

| 方案 | 結論 |
| --- | --- |
| 不改 | 拒絕：App 能跑的純爬蟲設定無法載入。 |
| 接受任何 type-3 | 拒絕：未知類別的設定會取代有效快取，之後清單是空的。任務明令禁止。 |
| validate 加 `ConfigSource` 參數並更新 App 呼叫端 | 暫不採用：要改 `WebHTVApp.swift`，超出範圍；只對 drpy／Python／JAR mapping 這些需要設定網址的爬蟲有差，而它們今天同樣被拒。 |
| **先查 native CMS，否則用無來源的 `CSPSourceResolver()` 查 `spiderSites`** | **採用**：一個 guard，沿用既有判斷。 |

- 效能：native CMS 先判斷，CMS 設定完全不會載入 registry（`SpiderRegistry.active()` 會讀所有內建 JS）；只有沒有 CMS 的設定才多讀一次，與 App 之後 `drivableSites` 本來就做的事同量，且只在匯入／抓取／重建／還原時發生。
- 已知限制（程式內 `ponytail:` 註記）：無來源 resolver 不計 drpy、Python、JAR mapping 爬蟲。只有這些站的設定仍像以前一樣被拒；四條路徑判斷一致，不會出現「抓取接受、還原拒絕」。需要時改成傳入呼叫端的 `ConfigSource`。
- 啟動還原時，若相容性套件尚未載入，只能靠套件新增的類別撐起的設定會被拒；今天同樣被拒，不是退步。
- 錯誤訊息改為「此設定沒有 iOS 可用的來源（CMS 或已支援的爬蟲）。」，因為 type-3 現在也算。
- 回滾：還原 `validate` 的 guard 與訊息即可，資料與快取不受影響。

## 4. 驗證

- Focused proof（只跑一次）：`swift test --package-path ios --filter 'validationRefusesPayloadsThatMustNotReplaceAGoodCache|validationAcceptsASpiderOnlyConfigTheRegistryDrives|countsTheSupportedSitesOfTheSuppliedConfig'`，log `/private/tmp/webhtv-qist-type3-proof.log`。
  - `validationRefusesPayloadsThatMustNotReplaceAGoodCache`：CMS 設定可用；只有未知 `csp_Test` 加 type-2 的設定、`{"sites":[]}` 拋 `noSupportedSites`；`not json` 拋錯。
  - `validationAcceptsASpiderOnlyConfigTheRegistryDrives`：`csp_JianPian` 加未知類別的純 type-3 設定通過，可驅動的爬蟲只有 `csp_JianPian`。舊版會在這裡拋 `noSupportedSites`。
- 結果：見第 5 節。
- 未驗證：原始 `XYQ.json` 經 App 載入（還需要 QIST-JSONC 的註解支援，兩個分支合併後才能端到端驗證）；完整 `swift test`；真機。

## 5. 結果紀錄

- 2026-10-08 17:52 CST focused proof：exit 0，`Test run with 3 tests in 0 suites passed`。`validationAcceptsASpiderOnlyConfigTheRegistryDrives`、`validationRefusesPayloadsThatMustNotReplaceAGoodCache` 實際執行；`countsTheSupportedSitesOfTheSuppliedConfig` 沒設 `WANG_MOVIE_JSON`，提早 return，不算驗證。
- Ponytail review（final diff）：無 Must／Should 項，Ship。已核對：四個 `validate` 呼叫端失敗時都不 adopt；`CSPSourceResolver()` 預設 `.importedFile`，drpy／Python 因 `baseURL == nil`、JAR mapping 因 `mapping(for:in:)` 需要 `baseURL` 而不計入，與 `ponytail:` 註記一致；`CSPSourceResolver` 是 `Sendable`，`InstalledSpiderPack.shared.current` 有 lock，從 async `fetch` 呼叫安全。
