# IOS-POC-57B-1: FirstAid 急救教學爬蟲

## 1. 目標
將 qist 類別 `FirstAid` 移植為 WebHTV 內建的 JS adapter (`FirstAid.js`)，提供「急救教學」類別的影音播放能力。

## 2. 適用證據 (Evidence)
1. **來源程式碼**：選用 `spider.jar` 的 `FirstAid.java` 邏輯。
   - SHA256: `391065e92e19437e73109e9d3c79feff6676baa8ed4fec3cdb04f4e7cca77314`
   - 本地解編路徑: `qist/src/spider/sources/com/github/catvod/spider/FirstAid.java`
   - 主機: 已明確標示目標主機為 `https://m.youlai.cn`。
2. **變體比較**：實際解碼 `pg_upgraded` 與 `pg23a94bb_upgraded` 兩版的位元組陣列常數後，確認所有 CSS Selector（如 `.block100`, `#video source`）與主機（`https://m.youlai.cn`）均與 `spider.jar` 和 `custom_spider.jar` 版本完全一致。四個非 fty 版本的差異僅在於 `User-Agent` 的 Chrome 版本號（介於 122 到 151 之間）。
3. **基礎設施支援**：`ios/Sources/WebHTVCore/Resources/Spiders/host.js` 提供了 `pdfh`、`pdfa`、`pd` 與 `urljoin` 等工具，已確認可支援 `FirstAid.java` 的 DOM 操作。
4. **不足證據**：目前無外部 API 官方文件，依賴原 JAR 逆向結果；未全面探測該主機的反爬蟲機制（如頻率限制）。

## 3. 設計決策 (Design)
*   **No-change (不變更)**：不處理此需求，保留現有未支援狀態。優點是不增加維護成本；缺點是使用者無法觀看此類急救教學影片。由於此源穩定且依賴單一明碼主機，適合移植。
*   **Upstream (上游完整移植)**：不適用，iOS 端不跑 Java，也無直接的 JSoup 環境，必須改寫為 JavaScript 爬蟲。
*   **Narrow Adapt (窄適配，選定方案)**：
    *   新增 `ios/Sources/WebHTVCore/Resources/Spiders/FirstAid.js`。
    *   使用 `host.pdfa` 和 `host.pdfh` 轉譯 JSoup 呼叫。
    *   實作 5 個 CSP 方法：`homeContent`, `categoryContent`, `detailContent`, `searchContent`, `playerContent`。
    *   影片來源 `#video source` 抓不到時，降級抓 `#video`。
    *   圖片與連結網址處理：不再判斷「是否 https 開頭」，一律改用 `host.urljoin(base, path)` 以支援絕對、協定相對、根相對網址等各種情境。

## 4. 驗收條件 (Acceptance Criteria)
1. **離線驗證**：在 `ios/Tests/WebHTVCoreTests` 建立單元測試驗證：
    *   8 個分類。
    *   分類列表與 `cateId` 覆寫。
    *   詳情解析（涵蓋 `#video source` 與 `#video` 兩種結構）。
    *   搜尋列表解析。
    *   相對網址補齊（必須涵蓋 `https://`, `http://`, `//`, `/` 等多種情況，驗證 `host.urljoin` 行為）。
    *   Header 包含適當的 `User-Agent`。
2. **線上驗證**：在 Simulator 中實際走訪「首頁 → 分類 → 詳情 → 播放」，若出現網路或解析失敗，區分環境、外部阻擋或程式回歸。只有成功播放才算通過。

## 5. 驗證結果 (Verification)
1. **離線驗證**：已完成。`FirstAidSpiderTests.swift` 涵蓋了全部 8 個分類、`cateId` 解析、搜尋、詳細資訊及 `host.urljoin` 處理，單元測試執行全數通過（`0.025 seconds`）。
2. **線上驗證**：Simulator 測試需由 Claude 執行。

## 6. 回滾計畫 (Rollback)
若有嚴重回歸或外部阻礙，執行 `git revert <commit-hash>` 退回此任務的 atomic commit，確保乾淨移除 `FirstAid.js`、單元測試、Registry 註冊項及任何相容包的變更。
