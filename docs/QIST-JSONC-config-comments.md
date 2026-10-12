# QIST-JSONC — 遠端設定允許 JSONC 註解

## Recovery anchor

- **目標**：`ConfigLoader.decode` 接受帶 `//`、`/* */` 註解的設定（qist `XYQ.json` 18 行註解），標準 JSON 解碼結果不變，真正無效的資料仍拒絕。
- **Lane／scope**：quick-fix，guard `QIST-JSONC`，獨立 worktree `/private/tmp/webhtv-qist-jsonc`，分支 `ios-poc-qist-jsonc`，基準 `88ea5ce9a48c2453be3df38dd60f5448db4ca4e7`。只改 `ios/Sources/WebHTVCore/ConfigLoader.swift`、`ios/Tests/WebHTVCoreTests/ConfigLoaderTests.swift` 與本文件。
- **不在範圍**：`validate` 的 type-3 規則（W-4 QIST-TYPE3）、播放器、Registry、其他 `JSONDecoder` 呼叫點。
- **狀態**：實作完成，focused proof 見第 4 節；待 Reviewer 審查，未 commit。
- **下一步（唯一）**：Reviewer 審查本 diff；通過後以 guard `finish --no-tag` 提交。

## 1. 問題證據

- qist `XYQ.json`（`https://raw.githubusercontent.com/qist/tvbox/master/XYQ.json`，2026-10-08 取得，sha256 `701eabdf0716c7be…`，與 `docs/IOS-POC-57-qist-jar-spiders.md` 記錄相同）有 18 行 `//` 註解、49 個站。
- 舊 `ConfigLoader.decode` 用嚴格 `JSONDecoder()`，遇到註解就丟「The data couldn’t be read because it isn’t in the correct format.」（IOS-POC-57 Findings 1，iOS 26／27 與 macOS 都重現）。

## 2. 呼叫端與快取

- `decode` 由 `validate` 呼叫；`validate` 由 `fetch` 與 `WebHTVApp.swift:320／341／455／577`（匯入、遠端抓取、啟動快取、還原）呼叫。快取存的是原始位元組，讀回時同樣經過 `validate`，所以帶註解的設定在抓取與快取讀回兩條路徑行為一致，不需要另外改。
- 測試端呼叫：`ConfigLoaderTests`、`ConfigSourceTests`、`CMSClientTests`、`GlobalParseTests`，全部經由同一個 `decode`。

## 3. 設計決策

| 方案 | 結論 |
| --- | --- |
| 不改 | 拒絕：qist 等帶註解的設定無法載入。 |
| regex 刪註解 | 拒絕：會截斷 `"http://…"` 這類字串裡的 `//`；任務明令禁止。 |
| 自寫 JSONC 前處理器 | 拒絕：要自己處理字串跳脫，新增程式與測試負擔，SDK 已有原生支援。 |
| **`JSONDecoder.allowsJSON5 = true`** | **採用**：Foundation 原生（iOS 15／macOS 12 起，本 package 下限 iOS 17／macOS 14），無新依賴，一行設定。 |

- JSON5 是 JSON 的超集，所以標準 JSON 的解析結果不變。2026-10-08 本機 probe（Swift／macOS 27，`/private/tmp/claude-501/…/scratchpad/json5probe.swift`）的結果：UTF-8、UTF-8 BOM、UTF-16LE BOM、UTF-16BE 無 BOM 在 strict 與 JSON5 模式都解出相同的 `http://x.com/a`；JSONC 只有 JSON5 模式能解；`not json` 與截斷的 `{"sites":[` 兩種模式都拒絕。
- 取捨：JSON5 也接受結尾逗號、單引號字串、未加引號的 key。這些都是 TVBox 生態常見的手寫格式，放寬它們不會讓任何原本能載入的設定失敗；`validate` 的「至少一個可用來源」關卡不變。
- 回滾：還原 `ConfigLoader.decode` 這一處改動即可，資料格式與快取都不受影響。

## 4. 驗證

- Focused proof（只跑一次）：`QIST_XYQ_JSON=<上述 XYQ.json> swift test --package-path ios --filter 'decodesAndClassifiesSites|decodesProvidedWangMovieConfig|classifiesType4SitesAndToleratesNonDictionaryExt|decodesCommentedConfigAndKeepsURLStrings|decodesProvidedQistXYQConfig'`，log `/private/tmp/webhtv-qist-jsonc-proof.log`。
  - `decodesCommentedConfigAndKeepsURLStrings`：標準 JSON 與帶 `//`、`/* */`、被註解掉的 `http://` 條目的 JSONC 解出相同站點，`api` 的 `http://` 完整保留；`not json` 與截斷資料仍丟錯。舊版會在 JSONC 這一步丟錯，所以這個測試在舊版失敗。
  - `decodesProvidedQistXYQConfig`：原始 qist `XYQ.json` 解出 49 站，`csp_JianPian` 的 ext `http://39.108.238.168:20000` 保留。
- 結果：見第 5 節。
- 未驗證：App GUI 載入原始 `XYQ.json`（仍被 `validate` 的 type-3 規則擋住，屬 W-4）；完整 `swift test`；真機。

## 5. 結果紀錄

- 2026-10-08 17:40 CST focused proof：exit 0，`Test run with 5 tests in 0 suites passed`。`decodesCommentedConfigAndKeepsURLStrings`、`decodesProvidedQistXYQConfig`（有設 `QIST_XYQ_JSON`）、`decodesAndClassifiesSites`、`classifiesType4SitesAndToleratesNonDictionaryExt` 實際執行；`decodesProvidedWangMovieConfig` 沒設 `WANG_MOVIE_JSON`，提早 return，不算驗證。
- 舊版失敗依據：同一份 JSONC 在 strict `JSONDecoder` 下解碼失敗（第 3 節 probe），沒有另外對舊版重跑測試。
- Ponytail review（final diff）：無 Must／Should 項，Ship。已核對：`decode` 的所有呼叫端（`validate`、`fetch`、`WebHTVApp.swift` 匯入／遠端／`rebuildSites` 快取／還原）沒有依賴「解碼失敗」去走其他格式；其他 `JSONSerialization` 呼叫點（`SiteSelection`、`GlobalParse`、`CSPSourceResolver` 等）都不讀原始設定位元組，帶註解的設定不會在別處被嚴格解析而默默失效。
