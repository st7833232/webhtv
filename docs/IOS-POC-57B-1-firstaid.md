# IOS-POC-57B-1: FirstAid 急救教學爬蟲

## 1. 目標
將 qist 類別 `FirstAid` 移植為 WebHTV 內建的 JS adapter (`FirstAid.js`)，提供「急救教學」類別的影音播放能力。

## 2. 適用證據 (Evidence)
1. **來源程式碼**：選用 `spider.jar` 的 `FirstAid.java` 邏輯。
   - SHA256: `391065e92e19437e73109e9d3c79feff6676baa8ed4fec3cdb04f4e7cca77314`
   - 本地解編路徑: `qist/src/spider/sources/com/github/catvod/spider/FirstAid.java`
   - 主機: 已明確標示目標主機為 `https://m.youlai.cn`。
2. **變體比較**：實際解碼 `pg_upgraded` 與 `pg23a94bb_upgraded` 兩版的位元組陣列常數，並對照 `custom_spider.jar` 與 `spider.jar`。已證明其 CSS Selector（如 `.block100`, `#video source`）與目標主機（`https://m.youlai.cn`）完全一致；差異在於 `custom_spider.jar` 與 `pg_upgraded` 分類封面主動補 `"https:"` 前綴，而 `spider.jar` 未補，以及 `User-Agent` 的 Chrome 版本號。窄適配統一採用 `host.urljoin` 處理以完整相容。
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

**整體狀態：native 離線與 Simulator 首頁／分類／詳情／播放已通過；目前整合回 `ios-poc`，待主分支 focused proof 與 final inspect。**

1. **來源恢復（IOS-POC-57B-1-FIX）**：commit `38c6795d` 的 `FirstAid.js` 與 `FirstAidSpiderTests.swift` 只有一個空行。Registry 仍會登錄該非零長度腳本，但 runtime 因缺少 `module.exports` 拒絕初始化；這是先前 final inspect 的 FA-R1 文件更正。協調者將原 AGY 修復檔逐字保存於隔離 checkout 的 `.codex/task-state/recovery/`（git-ignored），Claude 以此還原兩個 tracked 檔，只加下列已核准修正：
   - **FA-1**：`categoryContent` 回傳 `host.result.page(items, 1, 1, items.length, items.length)`；測試斷言 `pagecount == 1`（`jijiu|0` 與 `jijiu|1`）。
   - **FA-2**：fixture 加第二組 `.block100` 與 `.jj-title-li`；`tid jijiu|1` 斷言第二組封面 `https://m.youlai.cn/pic/family.jpg` 與唯一片目 `/video/301.html`「烫伤处理」。
   - **FA-6**：搜尋請求以 `URLComponents` 驗 `q == 溺水`；請求數由 `>= 4` 改為精確 `== 6`（分類 3 + 詳情 2 + 搜尋 1；首頁與播放不發請求）。
2. **離線驗證（native runtime，`JavaScriptSpiderRuntime` + bundled registry + mock `URLProtocol`）**：
   - 指令：`swift test --package-path ios --filter FirstAidSpiderTests`（2026-10-08，Claude 於隔離 checkout `/private/tmp/webhtv-claudex-resume` 執行一次）。
   - 結果：`Build complete! (54.52秒)`；`✔ Test testFirstAidSpiderFullFlow() passed after 0.046 seconds.`；`✔ Test run with 1 test in 1 suite passed after 0.046 seconds.`；0 failures。建置警告皆來自無關檔案，FirstAid 檔無警告。
   - 完整 log：Claude 端寫檔被 runner 權限拒絕，未存檔。Codex 協調者獨立執行結果：exit 0，1 test、0 failures（2026-10-08）；完整輸出：`/private/tmp/webhtv-firstaid-coordinator-proof.log`。
   - 涵蓋對照（依斷言內容，不依測試名稱）：8 分類首尾 `type_id`/`type_name`；`jijiu|0` 預設、`cateId=custom_cate` 覆寫（請求路徑 `/custom_cate`、`.block100` 自身 `src`）、`jijiu|1` 第二組；`#video source` 與 `#video` 兩種詳情 DOM；搜尋列表與 `q`；網址補齊涵蓋 `//`、`/`、`http://`、`https://`；播放 URL、`parse == 0`、播放 header UA；6 個請求全部帶 `Chrome/151.0.0.0` UA。
3. **已知限制（不在本修復範圍）**：
   - **FA-7**：詳情頁缺 `#video source` 與 `#video` 的 `src` 時，`vod_play_url` 會是 `標題$`（空網址），維持原移植行為，未擴大詳情處理。
   - FA-1 的 `pagecount` 是正確的分頁 metadata，但 iOS Swift 端目前不讀 `pagecount`；實際停止翻頁的是 `CMSClient.swift:254-260` 的 `merging(newTitlesFrom:)`（新頁沒有新片目就停）。所以 iOS 仍會多要一次第 2 頁、拿到重複清單後停止，不會無限翻頁。
4. **Ponytail 最終 diff 審查**（`ponytail:ponytail-review`，範圍：兩個 tracked 程式檔對 `38c6795d` 的 diff）：沒有必須修正項。
   - Nice to have（未套用，維持逐字匯入）：檔尾的 `typeof module !== 'undefined' && module.exports` 判斷與 `return spider` 可簡化成同層爬蟲（`MoDu.js`、`HaokanDJ.js`）的 `var spider = (function () { ... })(); module.exports = spider;`，可減少約 3 行。runtime 一定會先定義 `module`（`JavaScriptSpiderRuntime.swift:39`），所以現行寫法也正確。
   - 審查限制：未對 `m.youlai.cn` 實站驗證 DOM，fixture 依原移植的 selector 撰寫。
5. **線上驗證（2026-10-08 15:23，Claude 執行，Codex 已核對畫面與 hash 紀錄）**：先完成主 build 的 XYQHiker fixture GUI，再使用隔離 `176542d5` build；原始 qist `dianshi.json` 載入，首頁 8 分類、急救技能 19 部、家庭生活 30 部、腫脹詳情與 Qile 線路正常，原生播放器進度 00:05→00:12／04:46 並有影像。`FirstAid.js` checkout／build／安裝 hash 同為 `ab0646a5…`，binary `700a2713…`。證據 `/private/tmp/webhtv-gui-57a3-firstaid/firstaid-hashes.txt`、`f03`～`f08`；兩台設定已還原，iOS 27 裝回主 build。搜尋未做 live（設定 searchable:0），真機未驗。

## 6. 回滾計畫 (Rollback)
隔離修復 `176542d5` 可用 `git revert` 回到只有換行、無法初始化的腳本；Registry 不會略過該換行。主分支整合包含 `38c6795d` 與修復 `176542d5`，以合併前的 `88ea5ce9` 為 parent 1；若需撤回整合，使用 `git revert -m 1 <FirstAid 合併 commit>`。不包含相容包變更，不能只取含空行的 `38c6795d`。

---

## 7. 歷史 Recovery Anchor（隔離 native 修復交付時）

- **Task ID**: IOS-POC-57B-1-FIX
- **Worktree**: `/private/tmp/webhtv-claudex-resume`（隔離 checkout；原 `/private/tmp/webhtv-firstaid` 與主 workspace 唯讀保護、未修改）
- **Git Branch**: `ios-poc-firstaid`
- **Git HEAD**: `38c6795d08fde53b8247d1ce5511e5fe26fb5b51`（含空檔，必須連同本修復 commit 使用；不 reset / 不改寫）
- **Git Status（本次交付時）**:
  - M `docs/IOS-POC-57B-1-firstaid.md`
  - M `ios/Sources/WebHTVCore/Resources/Spiders/FirstAid.js`
  - M `ios/Tests/WebHTVCoreTests/FirstAidSpiderTests.swift`
- **Task Guard**: 協調者已啟動 `IOS-POC-57B-1-FIX`（quick-fix，scope 為上述 3 檔）；Claude 未另行 `check`。
- **恢復輸入**: `.codex/task-state/recovery/{FirstAid.js,FirstAidSpiderTests.swift,IOS-POC-57B-1-firstaid.md}`（git-ignored，協調者保存的 AGY 原檔）。
- **已驗證**: native focused test 1/1 通過（第 5 節）。
- **未驗證**: Simulator GUI 全流程；`m.youlai.cn` 實站 DOM。
- **授權邊界**: 不 commit、不 tag、不 push、不 merge 回原 worktree 或主 workspace。
- **下一個單一動作 (Next Single Action)**: fresh Codex inspect；PASS 後以 `task_guard.sh finish --no-tag` 提交 native-only 修復，並維持 GUI 驗收為未完成。獨立 native proof 已通過，不重跑。

### 主分支整合 checkpoint

- `ios-poc` 合併前 HEAD：`88ea5ce9a48c2453be3df38dd60f5448db4ca4e7`；incoming：`176542d5ec1aac4a96669c60b81b480f317a73f7`。`git merge --no-commit --no-ff` 已完成 tree 合併，未改兩個程式檔內容。
- Guard：`IOS-POC-57B-1-INTEGRATE`，產品範圍限 FirstAid.js、FirstAidSpiderTests.swift、Registry 登錄；同步本文件與兩份主任務紀錄。原 AGY worktree 的 3 個 dirty 檔與 guard 保留。
- GUI 證據已通過；主分支 focused proof exit 0、1/1、0 failures，build 14.42 秒，test 0.067 秒，完整 log `/private/tmp/webhtv-firstaid-main-proof.log`。這是新整合 tree 的驗證，隔離版本已成功的驗證未重跑。
- 下一個單一動作：fresh Codex inspect 整合 diff，PASS 後以 guard 產生本機 merge commit，無 tag／push／發布。

### 合併審查修正 FA-INTEGRATE-001

- 第一輪發現 Registry 固定預期清單缺 FirstAid，屬新登錄直接造成的回歸；使用者已明確核准把 SpiderGoldenTests.swift 加入 guard scope。
- Claude 僅在 Feiyu／GuaziTY 之間補 FirstAid，完整清單／alias 斷言不變；沒有修改 FirstAid 程式或重跑成功的 GUI。
- Codex 執行 registryClaimsOnlyWhatIsActuallyPorted：exit 0、1 test、0 failures（0.010 秒），完整 log `/private/tmp/webhtv-firstaid-registry-proof.log`。原 FirstAid flow 1/1 不重跑。
- 下一步：第二輪 fresh inspect，核對這一行與前輪已完成 coverage，PASS 後 guard finish --no-tag。

- 第二輪 final inspect：`APPROVED`、0 finding（`/private/tmp/webhtv-firstaid-merge-reinspect/claudex-cx03_sge/result.json`）。Ponytail 最終 diff 無必須修正項。native flow 1/1、Registry 1/1、既有原始 dianshi GUI／hash 證據均已核對；沒有重跑成功的流程。
- 本機 merge commit 由 guard `IOS-POC-57B-1-INTEGRATE` 產生，parent 1 為 `88ea5ce9`、parent 2 為 `176542d5`；整合後接續 57B-2 設計／實作，無 tag／push／發布。
