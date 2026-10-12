# IOS-POC-57B-4：贝乐虎（qist `csp_BeiLeHu`）

> Recovery anchor（2026-10-12 15:10 CST）：已實作並驗證（W-58，guard `QIST-BEILEHU-IMPL`，`--no-tag`）。設計：`.herdr-synapse/webhtv-dev/artifacts/qist-beilehu-gate-2026-10-12.md` D1–D6（W-56 PASS，sha256 `1fbc0430…`）；資料閘門 W-48 PASS；使用者 2026-10-12 核准實作。下一步：Reviewer code review。

## 來源

- 設定：dianshi:112、jsm:113。JAR：qist/tvbox `spider.jar` sha256 `72a1f3928eca281d878e44fc57162ff6a1f3ef779a2da05a2b351b241b110d69`；`<S>BeiLeHu.java` 141 行，sha256 `5f246551eaaa2f3a6eba6e6369acd7671a16a07a033a51b2ccee56dc8d6a1d06`。

## 改動

| 檔案 | 內容 |
|---|---|
| `ios/Sources/WebHTVCore/Resources/Spiders/BeiLeHu.js`（新） | 設計 D3／D4：JSON POST 先 `JSON.stringify` 再 `host.post`（欄位與順序照上游）；`errorCode !== 0`／`result` 不是物件／`items` 不是陣列 → 0 筆；列表只收不含 `$`、`#` 的 http(s) 網址，任何欄位含 `@@` 跳過，空標題用 `贝乐虎`；`vod_id`＝`url@@title@@image`；首頁推薦用分類 56 第 1 頁前 20 筆；詳情不發請求；播放照上游兩步、parse 0、帶 UA；沒有搜尋 |
| `ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift` | `ported` 加 `BeiLeHu` |
| `ios/Tests/WebHTVCoreTests/SpiderGoldenTests.swift` | 預期清單加 `BeiLeHu` |
| `ios/Tests/WebHTVCoreTests/BeiLeHuSpiderTests.swift`（新） | D5 八組測試；fixture 為 W-48 的 `cat56-t0.json`（38 筆，sha256 `679afa1e…14b7`，raw deflate＋base64 內嵌，載入時驗 sha256）與手寫邊界項目 |
| `scripts/spider_pack.py`、`spider-pack/` | `DEFAULT_ORIGINS` 加 `BeiLeHu`（`spider.jar` `72a1f392…`，只用 base host API，不帶 `minHostApi`）；相容包重建為 `2026-10-12.3`（25 支） |

## 驗證

| 項目 | 結果 | 證據 |
|---|---|---|
| 單元測試＋spider 回歸 | `swift test --filter 'BeiLeHuSpiderTests\|GuluSpiderTests\|RuntimeABITests\|…\|registryClaimsOnlyWhatIsActuallyPorted'` → 125 個全過（BeiLeHu 8 個） | `artifacts/w58-logs/w58-tests.log` `a9f0d4960c1b7891`… |
| 相容包 | build 0；舊 24 個 entry 不變；pack 與內建 `BeiLeHu.js` 同 blob `9d25e412…`；`verify` 25 支 0 problems | `w58-pack-build.log` `28abf90dd03006e9`…、`w58-pack-checks.log` `214a2ebbee3b3081`… |
| Ponytail review | Ship，沒有 finding | — |
| Simulator 實播（iPhone 18 Pro／iOS 27.0，checkout＝`282aa692`＋本次修改） | `BeiLeHu.js` 在 checkout／.app／容器三處 sha256 `7a595ae0…`；選來源 → 6 類順序正確、首頁推薦 20 部、**海報 20/20 顯示**（網址帶 `@c_1…`，W48-02）→ 兒歌 38 部 → res1《小兔子乖乖》原生 00:12→00:22 → resvd《Bingo》原生 00:08→00:17（W48-01）→ 從觀看紀錄重開《小兔子乖乖》從 0:43 續播 00:42→00:50；Simulator 已逐檔還原 | `/private/tmp/webhtv-gui-57b4-beilehu/RESULT.md`（66 檔 SHA256SUMS 全 OK；備份 `artifacts/w58-gui-evidence/`） |

## 觀察（未改程式）

- 清單的時間不是片長：照上游 `endInterval/10` 換算，《小兔子乖乖》顯示 4:50、實際 2:09，《Bingo》顯示 12:30、實際 1:56（設計 D6 的未驗項）。**已修正（Manager #1178，guard `QIST-BEILEHU-REMARKS`）**：偏離設計 D3，`vod_remarks` 一律用 `brand`（不是字串就空），不再換算 `endInterval`，避免每筆都顯示錯的時間；測試 2、5 的備註斷言跟著改，相容包重建為 `2026-10-12.4`。
- 首頁大圖在選來源後約 15 秒才載入；海報被裁成 4:3 放進直式卡片（App 既有版面）。

## 未驗證

- MPV 播放、其他 4 個分類與翻頁、實機。

## 回滾

一個 commit；`git revert` 移除 adapter、Registry 行、測試與相容包列，不影響其他來源。
