# Plan — IOS-POC-5Q 多畫質選擇 + IOS-POC-5R 播放記錄

- 狀態：**Ready for Dev**（審查通過，尚未實作）
- 建立：2026-09-18
- 基線 HEAD：`0414c032`（IOS-POC-5P 之後），branch `ios-poc`
- 下一步：`$execute-from-plan`

## 這份文件在這個 repo 裡的位置（偏離說明）

`$plan-from-requirement` 預設的骨架（`docs/template/plan.template.md`、`docs/todo.md`、`docs/specs/*`、
`docs/decisions/*`）在本 repo **不存在**，而 `AGENTS.md` §8 明文要求「一個任務一份
`docs/<TASK-ID>-<slug>.md`，不得為同一任務另開平行的 plan / assessment / implementation 檔」。

因此：

- **計畫階段**的產物就是這一份 `docs/plans/*`（使用者全域規則指定的路徑）。
- **穩定規格**在實作時寫進既有的長青文件：`docs/IOS_SPIDER_RUNTIME_SPEC.md`（ABI 與 host 契約）、
  `docs/current-task-state.md`、`docs/AGENT_HANDOFF.md`。
- **實作紀錄**寫進 `docs/IOS-POC-5Q-*.md` 與 `docs/IOS-POC-5R-*.md`，不回頭膨脹這份計畫。
- 沒有 `docs/todo.md`，階段狀態表就放在本文件最後，由 `$plan-review` 與 `$execute-from-plan` 更新。
- **本檔原本要放在 `docs/plans/`（使用者全域規則指定的路徑），但放不進去**：`.gitignore:30` 有一條
  `plans/`，那是目錄比對規則，`docs/plans/` 一併被忽略（root 的 `plans/*.md` 之所以還在，是因為它們
  在該規則之前就已入庫）。而 task guard 內部用的 `git add` 沒有 `-f`，碰到被忽略的路徑會讓腳本
  `set -e` 直接中止，等於那個位置的檔案無法用正規流程提交。
  因此本檔改放 `docs/`，沿用 AGENTS.md §8 的 `docs/<TASK-ID>-<slug>.md` 慣例。
  要讓 `docs/plans/` 長期可用，乾淨的做法是在 `.gitignore` 加一行 `!docs/plans/`——那是 repo 層設定
  變更，留給擁有者決定，不在本計畫範圍內。

## Problem Type

既有專案的**功能新增**，兩個相鄰但可獨立驗收的需求。不涉及新的 Spider class、Python、CarPlay、
release 或跨裝置同步。

## 需求基線

### 問題

1. **畫質選不了，而且會靜默壞掉。** CatVod 的 `playerContent` 允許 `url` 是三種形狀
   （字串／`[名稱, 網址, …]` 交替陣列／`{"values":[{"n","v"}],"position"}`，權威定義在
   `app/src/main/java/com/fongmi/android/tv/gson/UrlAdapter.java`）。iOS 的 `SpiderPlayResponse`
   只認字串，**而且兩條路徑壞的方式還不一樣**：spider 路徑的
   `decodeIfPresent(String.self)`（`SourceClient.swift:158`）遇到陣列會 **throw**
   `DecodingError.typeMismatch`，一路傳到 `WebHTVApp.swift:844` 變成一行原始解碼錯誤字串；
   CMS 路徑（`CMSClient.swift:295`）用 `try?` 把同一個錯誤吞成 `nil`，才是顯示
   「這一集沒有可播放的網址」的那條。兩種都不是站壞了，是我們讀不懂。
   `Bili.js` 因此只取 `accept_quality` 的第一項，等於主動放棄 B 站的畫質選擇。
   **同一個缺陷也在 CMS 路徑上**：`ios/Sources/WebHTVCore/CMSClient.swift:236` 的
   `struct PlayResponse { let url: String }` 是 type-4 `?play=` 解析用的，形狀限制一模一樣。
   只修 spider 那一邊就是補症狀不補根因。
2. **沒有播放記錄。** 看到哪裡、上次看哪一集、用哪條線路，全部不記。`WebHomeBridge.swift` 的
   `app.history` 是一個寫明原因的 stub，固定回傳空陣列。

### 目標

- 一集有多個畫質時可以選，且選擇不會讓既有單一網址的來源產生任何行為變化。
- 每部片記住看到哪一集、看到幾分幾秒、用哪條線路與畫質，下次自動接續。
- `app.history` 回傳與 Android 同形狀的真資料。

### 成功條件（可測）

| # | 條件 | 怎麼驗 |
|---|---|---|
| S1 | `url` 的三種形狀都解得出來，單一字串行為與現在逐位元組相同 | 單元測試（三形狀 + 既有 62 站掃描不變） |
| S2 | 多畫質時播放器出現畫質選單，單畫質時不出現 | 單元測試（選單資料）＋ 模擬器截圖 |
| S3 | B 站一集回傳 >1 個畫質 | 針對 `csp_Bili` 的 live golden |
| S4 | 播放 10 秒後離開再進入，從該位置續播 | 單元測試（續播判斷）＋ 模擬器實測 |
| S5 | 記錄分頁列出看過的片，詳情頁標出上次那一集 | 模擬器截圖 |
| S6 | `app.history` 回傳的 JSON 欄位與 Android `History` 相同 | bridge 測試（改寫既有那條「回傳空陣列」的斷言） |
| S7 | 60 天前或超過 500 筆的記錄會被清掉 | 單元測試 |
| S8 | 既有 CMS／type-0／1／4／WebHome／playback 全數無退步 | `swift test` 全綠 + xcodebuild |

### 範圍

**做**：`url` 三形狀解析、畫質選單、`Bili.js` 全畫質、本機 `WatchHistory`、續播、記錄分頁、
詳情頁標記、`app.history` 補洞、記住線路與畫質。

**不做**：新的 Spider class、Python／drpy、CarPlay、跨裝置同步（Android 走它自己的本機 HTTP server
`PlaybackProgressApi`，iOS 無等價物）、外部播放器的續播回寫（URL scheme 沒有回傳管道）、
`opening`/`ending` 片頭片尾跳過（欄位保留但不實作）。

### 限制

- `AGENTS.md`：不改 Android `main` 或 `app/`（唯讀，作為契約來源）；未授權不得 push；commit 不打 tag；
  改動前後各跑一次 Ponytail；task guard 的 scope 一次宣告齊全。
- 不得引入資料庫或第三方相依：記錄用 JSON 檔 + 原子寫入，沿用 config／compatibility pack 既有模式。
- 不得放寬傳輸安全，不得改 entitlement／簽章。
- 實機從未驗證；所有驗收都在 iPhone 17 Pro 模擬器。

### 主要情境

使用者在 `bili靜聽歌` 點一集 → 播放器出現「1080P／720P／360P」→ 選 720P → 看 3 分鐘離開 →
回到首頁「記錄」分頁看到這部片 → 再點進去，詳情頁標著上次那一集，播放直接從 3:00 開始、畫質仍是 720P。

## 決策表

| # | 決策 | 選擇 | 理由 |
|---|---|---|---|
| D1 | 記錄入口 | 「記錄」分頁 + 詳情頁標記 | 使用者選定；最接近 Android，看過很久的片也找得到 |
| D2 | 保留策略 | 60 天 + 上限 500 筆 | 使用者選定；60 天照 `Constant.HISTORY_TIME`，筆數上限避免檔案無限長 |
| D3 | 記住畫質／線路 | 記住 | 使用者選定；`History.vodFlag` 本來就是為此存在 |
| D4 | 續播行為 | 自動跳（position > 10s 且不在 near-end 區間內） | 使用者選定；near-end 的判斷照抄 `History.isNearEnding()`，見 D12 |
| D5 | 儲存形式 | Application Support 的單一 JSON + 原子寫入 | 沿用 config／pack 已驗證的模式；數百筆資料不值得引入 SwiftData |
| D6 | 記錄主鍵 | 內部用 `Site.id`（key+ext），對外 `app.history` 用 `<siteKey>@@@<vodId>` | 設定檔有 4 組重複 key（IOS-POC-5L 的 `爱影`），只用 siteKey 會把兩個不同站的記錄混在一起；但 bridge 必須維持 Android 形狀 |
| D7 | 畫質選單位置 | 既有的播放器選擇 sheet 內，**播放開始前**選定 | 不新增畫面；該 sheet 已經是「決定怎麼播」的地方。**播放中切換畫質不在範圍**，因此不存在「切換要重新 seek」的問題 |
| D8 | 多畫質預設項 | manifest 的 `position`，沒有就第 0 項；若有記錄則用記錄的 | 與 CatVod `Url.position` 一致 |
| D9 | 不實作 `opening`/`ending` | 欄位保留、值為 0 | 跳片頭片尾是獨立需求，沒有人要求 |
| D10 | **B 站的畫質用「線路」表達，不用 `url` 陣列** | `detailContent` 產生 `B站 1080P$$$B站 720P$$$…`，每集的 id 帶自己的 `qn` | `accept_quality` 只是清單，**每個畫質的真實網址要各自打一次 `playurl`**。用陣列形狀等於每次開一集就多打 4–8 次 API（實測每次 0.3–0.5 秒）。做成線路則選擇發生在 `playerContent` 之前，**額外請求為零**，而且直接沿用詳情頁已經能用的線路 UI |
| D11 | 記錄 store 放在 `WebHTVCore`，不放 App target | 與 `SpiderPack.swift` 同層 | `WebHomeBridge` 在 WebHTVCore，App target 只能單向 import core；放錯層 R5 會做不出來 |
| D12 | 續播門檻用 Android 的真實公式 | `min(30s, max(5s, duration/100))` | `History.isNearEnding()` 就是這條，照抄比自己定一個 flat 30s 更省事也更準 |

## 切片與阻擋關係

```
Q1 ──► Q2      Q1 ──► Q3
 │                │
 │                └──────┐
 └──────────────► R6     ▼
R1 ─────────────────────► R2 ──► R3
R1 ──► R4
R1 ──► R5
```

R2 必須知道「這次用了哪條線路、哪個畫質」才能寫進記錄（D3），所以它同時卡在 Q1 與 Q3 之後。

| 切片 | 內容 | 阻擋於 | 驗證 |
|---|---|---|---|
| **Q1** | `SpiderPlayResponse.url` **與 `CMSClient.PlayResponse.url`** 都支援三形狀；`PlaybackTarget` 增加 `qualities: [(n, v)]` 與 `position`；單一字串時 `qualities` 只有一項。**同時修掉既有 golden 測試 `SpiderGoldenTests.swift:95` 把 `url` 硬轉 `String` 的斷言**，否則任何回傳陣列的來源都會讓那條測試爆掉 | — | 單元測試三形狀 + 空值 + 畸形值（spider 與 CMS 各一組）；既有測試全綠 |
| **Q2** | `Bili.js` 把 `accept_quality` 攤成多條線路（見 D10），每集 id 帶自己的 `qn`；`playerContent` 用 id 裡的 `qn` 請求 | Q1 | **新增**一條 `csp_Bili` 專屬 golden（自己的 `--filter` 目標）：一集 >1 條線路、每條線路的 id 帶不同 `qn`、第一條可播且取得媒體位元組 |
| **Q3** | 播放器 sheet 的畫質選單，只有當來源回傳多值 `url`（陣列／物件）時才出現；選定後才開始播 | Q1 | 單元測試選單資料；模擬器截圖。**B 站不走這條**（它走線路），所以這一片的實測對象是任何回傳陣列的來源，目前 62 站中沒有，先以單元測試為準 |
| **R1** | `WatchHistory` 模型（照 Android 欄位）+ store，**建在 `ios/Sources/WebHTVCore/`**（見 D11）：載入／upsert／prune(60d,500)／原子寫入／壞檔不致命 | — | 單元測試：round-trip、prune、壞 JSON、並發寫入 |
| **R2** | 開播寫一筆（含線路與畫質）；播放中每 5 秒更新 position；離開播放器與進背景各寫一次 | R1、**Q1**、**Q3** | 單元測試更新邏輯；模擬器實測 |
| **R3** | 續播：>10s 且距結尾 >30s 才 seek | R2 | 單元測試判斷函式；模擬器實測 |
| **R4** | 「記錄」分頁 + 詳情頁標記上次那一集 | R1 | 模擬器截圖 |
| **R5** | `app.history` 回傳真資料（Android 欄位形狀） | R1 | 改寫 `WebHomeBridgeTests` 既有的空陣列斷言 |
| **R6** | 再次開啟同一部片時沿用記錄裡的線路與畫質 | Q1 + R1 | 單元測試；模擬器實測 |

建議提交順序：`Q1+Q2+Q3` 一個 commit（同一件事的三段），`R1+R2+R3+R5` 一個，`R4+R6` 一個。

## 驗證計畫

```bash
WANG_MOVIE_JSON=<config> swift test --package-path ios
# 既有的 generic golden（任何站），證明單一字串的行為沒變
CSP_GOLDEN_SITE='<site json>' swift test --package-path ios --filter appGetDrivesTheWholeCatVodFlow
# Q2 新增的專屬 golden，這一條才是 S3 的閘門
CSP_GOLDEN_SITE='<bili site json>' swift test --package-path ios --filter biliOffersMultipleQualityLines
xcodebuild -project ios/WebHTVApp/WebHTVApp.xcodeproj -scheme WebHTVApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
```

**S2 的閘門是單元測試，不是截圖。** Q3 自己承認目前 62 站沒有任何來源回傳陣列形狀的 `url`，所以
沒有真實資料可以觸發畫質選單；模擬器截圖列為 best effort（若之後出現這種來源再補），可驗收的部分
是選單資料的單元測試。

模擬器實測（續播、記錄分頁、畫質切換）以截圖存證。全站掃描**不列為驗收條件**：它量的是 provider
當天的狀態，2026-09-17／18 已兩次落在 TLS 憑證失效的壞窗（`ERROR=18`），不能當回歸證據。

## 回滾

- 未 commit 的改動：直接丟棄（`git restore`），task guard 的 `finish` 在驗證失敗時本來就拒絕 commit。
- 已 commit 但尚未 push 的切片群組：用新的 `git revert` 提交，**不要 amend、不要改寫歷史**。
- 已 push（需另外授權才會發生）：同樣用 `git revert`，並在階段文件記錄原因。
- 資料層：`WatchHistory` 的 JSON 檔可以直接刪除，App 會當成沒有記錄重新開始；壞檔本身就已列入 R1 的
  驗證項目（壞檔不致命）。

## 風險

| # | 風險 | 影響 | 對策 |
|---|---|---|---|
| K1 | App 被殺掉時最後的 position 沒寫入 | 續播差幾秒 | 每 5 秒寫一次 + 進背景寫一次；差幾秒可接受 |
| K2 | 設定檔重複 site key 讓記錄互相污染 | 兩個不同站的記錄混一起 | D6：內部用 `Site.id` |
| K3 | B 站 >80 的畫質需要登入，選單可能只有低畫質 | 使用者以為功能壞了 | 選單只呈現 API 實際回傳的；文件寫明 cookie 過期的影響 |
| K4 | ~~切畫質要重建 `AVPlayerItem`~~ | — | **已消除**：D7 定案為播放前選定，播放中不切換 |
| K5 | 既有 bridge 測試斷言 `app.history` 為空 | 測試會紅 | R5 一併改寫該斷言，並在 commit 說明這是行為改變不是放寬 |
| K6 | 外部播放器沒有回寫管道 | 用 Infuse 看的不會被記錄 | 已知限制，寫進文件；只記錄內建播放器 |

## Design review（skill 要求的 gate）

2026-09-18，以 `architect-reviewer` 子代理對本計畫做一次 bounded、read-only 的設計審查，對照實際程式碼。
七項發現，四項改變了設計並已寫回上表：

| 發現 | 處置 |
|---|---|
| Q2 的驗證沿用既有 generic golden，而那條測試在 `SpiderGoldenTests.swift:95` 把 `url` 硬轉 `String`，一旦回傳陣列就會爆 | **採納**：Q1 併入修該斷言，Q2 改為自帶專屬 golden |
| `CMSClient.PlayResponse.url` 有一模一樣的 String-only 缺陷，只修 spider 是補症狀 | **採納**：Q1 範圍擴到兩處（已用 `CMSClient.swift:236` 核實） |
| R1 放錯 target 會讓 R5 做不出來（bridge 在 core，UI 在 app） | **採納**：新增 D11 |
| R2 缺少對 Q1／Q3 的阻擋邊 | **採納**：圖與表已補 |
| D4 宣稱沿用 Android 的 5s/30s，實際公式是 `min(30s, max(5s, duration/100))` | **採納**：新增 D12，照抄真公式（已用 `History.java:364` 核實） |
| D7 與 K4 互相矛盾：sheet 在播放前，不存在中斷問題 | **採納**：D7 定案播放前選定，K4 消除 |
| Q2 被低估：要嘛每集多打 4–8 次 API，要嘛改走 DASH `fnval=16` | **不採納這兩個選項**，改用第三條：把畫質做成線路（D10），額外請求為零，且沿用既有 UI |

## Plan Review

- **Review State**：`PASS`
- **Verdict**：`PASS`（先前一輪為 `REVISE`，已修正並清除）
- **Review Basis**：2026-09-18，基線 HEAD `0414c032`，branch `ios-poc` clean。兩次 bounded read-only
  子代理審查：`architect-reviewer`（設計軸，7 項發現／6 項改變設計）與 `qa-expert`（執行就緒軸，
  1 項 BLOCKING／3 項 ADVISORY）。兩者的每一項主張都由主代理親自對程式碼核實後才採納。
- **Intent Alignment**：`Pass` — 目標、範圍、成功條件 S1–S8 與決策 D1–D12 均可追溯到實際檔案
  （`UrlAdapter.java`、`History.java:32,364`、`Constant.java:20`、`CMSClient.swift:236`、
  `WebHomeBridge.swift:340`、`Bili.js:110,132`），且未越出「不新增 Spider class／不碰 Python／
  CarPlay／不做跨裝置同步」的邊界。
- **Execution Readiness**：`Pass`（修正後）— S1–S8 各有切片與可執行驗證；Q1 與 R1 無未解阻擋可立即
  開工；回滾路徑已寫明。
- **Key Decision Point**：D10（B 站畫質用線路而非 `url` 陣列）。它把「每開一集多打 4–8 次 API」換成
  零額外請求，是整份計畫裡唯一一個改變成本量級的決定。
- **Blocking Findings（已解）**：S3 在主驗證區塊沒有對應的可執行指令——既有 generic golden 不檢查
  畫質數量，指向 Bili 也會通過而沒有真的驗到。已在驗證計畫加入 Q2 專屬 golden 的
  `--filter biliOffersMultipleQualityLines`。
- **Advisory Findings（已處理）**：S2 沒有真實資料可截圖 → 閘門改為單元測試、截圖降為 best effort；
  計畫原本沒有回滾章節 → 已補；需求基線把 spider 路徑的症狀寫成「靜默變空字串」，實際是 throw
  `DecodingError.typeMismatch`（`decodeIfPresent` 對型別不符是拋錯不是回 nil）→ 已改寫，並區分
  CMS 路徑用 `try?` 吞掉的差異。
- **Blocking Decision**：None
- **Next Governed Action**：`$execute-from-plan`，從 Q1 或 R1 起手
- **Invalidation Reason**：N/A

## 阻塞事項

無。所有需要的人為決定（D1–D4）已於 2026-09-18 取得；設計層的 D5–D12 由主代理定案並經上述審查。

## 階段狀態

| 階段 | 狀態 | 下一步 |
|---|---|---|
| IOS-POC-5Q | **Ready for Dev** | `$execute-from-plan`（Q1 → Q2 → Q3） |
| IOS-POC-5R | **Ready for Dev** | `$execute-from-plan`（R1 → R2／R4／R5 → R3 → R6） |

本 repo 沒有 `docs/todo.md`，這張表就是那一行 todo；狀態由 `$execute-from-plan` 推進。
