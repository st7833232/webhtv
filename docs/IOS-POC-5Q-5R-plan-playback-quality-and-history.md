# Plan — IOS-POC-5Q 多畫質選擇 + IOS-POC-5R 播放記錄 + IOS-POC-5S 嗅探層廣告與站點規則

- 狀態：**5Q 與 5R（R1–R6）已實作**（2026-09-18）。**IOS-POC-5S 與 5R 的 R7 由使用者
  2026-09-18 明確指示 deferred**——設計保留在本文件中，不刪除，但不在目前主線。
- 建立：2026-09-18
- 基線 HEAD：`0414c032`（IOS-POC-5P 之後），branch `ios-poc`。5Q 實作於 `d571f3a7` 之上，
  5R 實作於 `0ab06a3c` 之上。
- 下一步：**不是本計畫的任何一段**。使用者指定的主線是
  `durable docs reconciliation → drpy JavaScript loader → Python runtime 最小 POC → 第一次真機驗證`，
  之後才回頭做 5S。實作紀錄：`docs/IOS-POC-5Q-playback-quality.md`、
  `docs/IOS-POC-5R-watch-history.md`，兩份都列出與本計畫的偏離。

## Deferred（2026-09-18，使用者指示）

以下**設計有效但不實作**，等 drpy + Python POC + 真機主線完成後再排：

- **IOS-POC-5S 整段**：V0（`WebHTVConfig` 解碼 `ads`／`rules`）、V1（`ads` 兩層攔截）、
  V2（`rules.script` 注入）。
- **R7 片頭／片尾跳過**（D9／D13／D14／S9／S10），與 5S 同一批 deferred。
- 任何 m3u8 中插廣告過濾——本來就在「不做」清單裡，此處再確認一次。

理由（使用者原話的意思）：這些屬於 Android parity / UX refinement，不是原 roadmap 的當前主線。
D9 把「不實作 `opening`/`ending`」反轉成實作的那個決定，因此**暫時反轉回去**；D9 的論證本身沒有
被推翻，只是排序在後。

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
3. **廣告完全沒處理，而 Android 的那套我們一條都沒接。** 三件獨立的事：
   - **站方片頭廣告**：Android 的解法是每部片手動標 `opening`/`ending`，之後
     `seek(max(opening, position))`（`app/src/leanback/.../VideoActivity.java:5603`），剩餘時間
     ≤ `ending` 就當播完跳下一集（同檔 `:5550`）。欄位在 `History` 裡，主鍵是整部片而非單集，所以
     一部劇標一次全劇受益。iOS 完全沒有。
   - **嗅探時的廣告請求**：Android 在嗅探用的 WebView 裡直接擋掉
     （`CustomWebView.java:131` → `isAd(host)` → 回空回應），清單來自**設定檔自己的 `ads` 欄位**
     （`VodConfig.java:176`）。**這不是一個設定開關**，它一直開著，擋什麼由清單決定；使用者的
     `wang-movie.json` 目前只有一條 `mozai.4gtv.tv`。網路上流傳的「切換播放核心來增強去廣告」在這個
     fork 裡是錯的——攔截在 WebView 那一層，核心只負責播嗅探出來的流。
   - **站點嗅探規則**：設定檔的 `rules`（使用者有 10 條）是 `hosts + regex`，其中幾條還帶 `script`
     去自動點掉播放按鈕（例如 `yeslivetv.com` 點 `vjs-big-play-button`）。它的用途是幫忙找到流，
     順帶解決「要先點一下、或先跳一段廣告才播」的頁面。
   **前置事實**：`ios/Sources/WebHTVCore/WebHTVConfig.swift` 目前**只解碼 `sites`**，`ads` 與 `rules`
   從來沒進過 model；`MediaSniffer` 也拿不到 config。所以這一段有一個必須先做的解碼切片。

### 目標

- 一集有多個畫質時可以選，且選擇不會讓既有單一網址的來源產生任何行為變化。
- 每部片記住看到哪一集、看到幾分幾秒、用哪條線路與畫質，下次自動接續。
- `app.history` 回傳與 Android 同形狀的真資料。

### 成功條件（可測）

| # | 條件 | 怎麼驗 |
|---|---|---|
| S1 | `url` 的三種形狀都解得出來，單一字串行為與現在逐位元組相同 | 單元測試（三形狀 + 既有 62 站掃描不變） |
| S2 | 多畫質時播放器出現畫質選單，單畫質時不出現，且**預設選中的是最高畫質** | 單元測試（選單資料與預設索引）＋ 模擬器截圖 |
| S3 | B 站一集回傳 >1 條畫質線路，且**第一條是 API 回報的最高畫質** | 針對 `csp_Bili` 的 live golden |
| S4 | 播放 10 秒後離開再進入，從該位置續播 | 單元測試（續播判斷）＋ 模擬器實測 |
| S5 | 記錄分頁列出看過的片，詳情頁標出上次那一集 | 模擬器截圖 |
| S6 | `app.history` 回傳的 JSON 欄位與 Android `History` 相同 | bridge 測試（改寫既有那條「回傳空陣列」的斷言） |
| S7 | 60 天前或超過 500 筆的記錄會被清掉 | 單元測試 |
| S8 | 既有 CMS／type-0／1／4／WebHome／playback 全數無退步 | `swift test` 全綠 + xcodebuild |
| S9 | 標了片頭之後，同一部片的下一集自動從該位置開始 | 單元測試（seek 決策）＋ 模擬器實測 |
| S10 | 標了片尾之後，剩餘時間進入該區間就視為播完 | 單元測試 |
| S11 | `ads` 清單命中的請求在嗅探時不會被當成候選，也不會被載入 | 單元測試（注入 HTML 含廣告 host 的請求，斷言不回報）＋ 規則清單編譯成功 |
| S12 | `rules` 的 `script` 會對符合的 host 注入並執行 | 單元測試（本地 HTML + 需點擊才出現的 video src） |
| S13 | 設定檔的 `ads`／`rules` 解得出來，且沒有這兩個欄位的設定檔行為不變 | 單元測試（有／無欄位各一組） |

### 範圍

**做**：`url` 三形狀解析、畫質選單、`Bili.js` 全畫質、本機 `WatchHistory`、續播、記錄分頁、
詳情頁標記、`app.history` 補洞、記住線路與畫質、**片頭／片尾標記與自動跳過**、
**設定檔 `ads`／`rules` 解碼**、**嗅探層的廣告封鎖與 `script` 注入**。

**不做**：新的 Spider class、Python／drpy、CarPlay、跨裝置同步（Android 走它自己的本機 HTTP server
`PlaybackProgressApi`，iOS 無等價物）、外部播放器的續播回寫（URL scheme 沒有回傳管道）、
**m3u8 中插廣告片段過濾**（要寫 `AVAssetResourceLoaderDelegate` 代理整條 HLS，Android 這邊也沒做；
先量出「62 站裡有幾站真的中插廣告」再談）、**燒進畫面的浮水印廣告**（不可能，設定檔那些站名自己就寫著
「浮水印廣告」）、`rules` 的 `hosts`/`regex` 用於嗅探候選判斷（只接 `script`，見 D17）。

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
| D8 | 多畫質預設項 | **預設挑最高畫質**。優先順序：①該片的記錄（R6）②標籤排序出的最高畫質 ③來源自己的 `position`／第 0 項 | 使用者 2026-09-18 要求預設最高。記錄仍優先於它——使用者上次親手選的不該被「預設」推翻；沒有記錄時才由排序決定 |
| D18 | 「最高」怎麼判斷 | 從標籤文字抽一個等級：`4K`/`2160` > `1440`/`2K` > `1080`/`藍光`/`蓝光`/`超清` > `720`/`高清` > `480`/`標清` > `360`/`流暢` > `240`；B 站另外認 `qn` 數字（127 > 126 > 125 > 120 > 116 > 112 > 80 > 64 > 32 > 16）。**一個都對不上就保持來源自己的順序**，不自作聰明 | 標籤是站方自由文字，不可能有權威表。用 `ponytail:` 註記寫明這是啟發式與升級路徑 |
| D9 | ~~不實作 `opening`/`ending`~~ → **反轉** | 實作，成為切片 R7 | 使用者 2026-09-18 明確要求「跳開廣告」。它是站方片頭廣告唯一有效的解法，而且 5R 已經帶來它需要的兩樣東西（欄位 + 位置取樣器），所以增量極小 |
| D10 | **B 站的畫質用「線路」表達，不用 `url` 陣列** | `detailContent` 產生 `B站 1080P$$$B站 720P$$$…`，每集的 id 帶自己的 `qn` | `accept_quality` 只是清單，**每個畫質的真實網址要各自打一次 `playurl`**。用陣列形狀等於每次開一集就多打 4–8 次 API（實測每次 0.3–0.5 秒）。做成線路則選擇發生在 `playerContent` 之前，**額外請求為零**，而且直接沿用詳情頁已經能用的線路 UI |
| D11 | 記錄 store 放在 `WebHTVCore`，不放 App target | 與 `SpiderPack.swift` 同層 | `WebHomeBridge` 在 WebHTVCore，App target 只能單向 import core；放錯層 R5 會做不出來 |
| D12 | 續播門檻用 Android 的真實公式 | `min(30s, max(5s, duration/100))` | `History.isNearEnding()` 就是這條，照抄比自己定一個 flat 30s 更省事也更準 |
| D13 | 片頭／片尾的按鍵放在播放畫面 | 播放中按下即以當下位置設定，並提供 ±1 秒微調 | 照 Android：`onOpening()`（`VideoActivity.java:3287`）以當下位置設定，`onOpeningAdd()`（`:3293`）才是 ±1 秒微調。片頭剛結束那一秒按下才準；放詳情頁要自己估秒數 |
| D14 | 片頭／片尾以**整部片**為單位 | 主鍵與記錄相同（D6） | 照 Android 契約。站方片頭每集一樣，這正是它有效的原因 |
| D15 | `ads` 用兩層攔截 | ①`WKContentRuleListStore` 原生封鎖規則（連載入都省）②嗅探 JS hook 內再過濾一次 | 原生規則是 WKWebView 唯一能在請求發出前擋掉的機制（`WKWebView` 沒有 `shouldInterceptRequest`，IOS-POC-5G 已記錄）；hook 那層負責「就算載入了也不要當成候選」 |
| D16 | `ads`／`rules` 以 process 層政策物件供給 sniffer | `SnifferPolicy`（`NSLock` box，照 `InstalledSpiderPack` 的形狀），在 config adopt 時填 | `MediaSniffer` 拿不到 config，而 `resolveMedia` 是 static；沿用 pack 已驗證的形狀比新增一條注入鏈便宜 |
| D17 | `rules` 的 `regex` **不用於嗅探候選判斷**；`hosts` 仍用來挑對應站的 `script` | 候選判斷維持現有的 keyword／exclusion 清單 | `script` 是能直接提高嗅探成功率的那一半；把 `regex` 接進候選判斷要重做那段邏輯，收益未經量測 |

## 切片與阻擋關係

```
Q1 ──► Q2      Q1 ──► Q3
 │                │
 │                └──────┐
 └──────────────► R6     ▼
R1 ─────────────────────► R2 ──► R3 ──► R7
R1 ──► R4
R1 ──► R5

V0 ──► V1
V0 ──► V2
```

R2 必須知道「這次用了哪條線路、哪個畫質」才能寫進記錄（D3），所以它同時卡在 Q1 與 Q3 之後。

| 切片 | 內容 | 阻擋於 | 驗證 |
|---|---|---|---|
| **Q1** | `SpiderPlayResponse.url` **與 `CMSClient.PlayResponse.url`** 都支援三形狀；`PlaybackTarget` 增加 `qualities: [(n, v)]` 與 `position`；單一字串時 `qualities` 只有一項。**同時修掉既有 golden 測試 `SpiderGoldenTests.swift:95` 把 `url` 硬轉 `String` 的斷言**，否則任何回傳陣列的來源都會讓那條測試爆掉 | — | 單元測試三形狀 + 空值 + 畸形值（spider 與 CMS 各一組）；既有測試全綠 |
| **Q2** | `Bili.js` 把 `accept_quality` 攤成多條線路（見 D10），每集 id 帶自己的 `qn`；`playerContent` 用 id 裡的 `qn` 請求；**線路依畫質由高到低排序**（`accept_quality` 實測本來就是最佳優先，仍明確排序不靠巧合） | Q1 | **新增**一條 `csp_Bili` 專屬 golden（自己的 `--filter` 目標）：一集 >1 條線路、每條線路的 id 帶不同 `qn`、**第一條的 `qn` 是最大值**、且第一條可播並取得媒體位元組 |
| **Q3** | 播放器 sheet 的畫質選單，只有當來源回傳多值 `url`（陣列／物件）時才出現；**預設選中依 D8 決定**；選定後才開始播。**預設索引的計算是一個純函式，記錄以參數注入**（`preferred: String?`），因此不相依於 R1 | Q1 | 單元測試：選單資料、預設索引（注入偏好／不注入各一組）、D18 的排序函式（含全部對不上時保持原序）。模擬器截圖。**B 站不走這條**（它走線路），所以實測對象是任何回傳陣列的來源，目前 62 站中沒有，先以單元測試為準 |
| **R1** | `WatchHistory` 模型（照 Android 欄位）+ store，**建在 `ios/Sources/WebHTVCore/`**（見 D11）：載入／upsert／prune(60d,500)／原子寫入／壞檔不致命 | — | 單元測試：round-trip、prune、壞 JSON、並發寫入 |
| **R2** | 開播寫一筆（含線路與畫質）；播放中每 5 秒更新 position；離開播放器與進背景各寫一次。**前置：`Playback` 與 `PlaybackSession.open` 目前只帶 `url/headers/title/artwork`，完全沒有站與片的身分**（`WebHTVApp.swift:864`、`:969`），必須先把 `Site.id` + vodId 這一對串進去，R7 也靠它 | R1、**Q1**、**Q3** | 單元測試更新邏輯；模擬器實測 |
| **R3** | 續播：>10s 且距結尾 >30s 才 seek | R2 | 單元測試判斷函式；模擬器實測 |
| **R4** | 「記錄」分頁 + 詳情頁標記上次那一集 | R1 | 模擬器截圖 |
| **R5** | `app.history` 回傳真資料（Android 欄位形狀） | R1 | 改寫 `WebHomeBridgeTests` 既有的空陣列斷言 |
| **R6** | 再次開啟同一部片時沿用記錄裡的線路與畫質 | Q1 + R1 | 單元測試；模擬器實測 |
| **R7** *(deferred)* | 片頭／片尾：播放畫面兩顆鍵（設定為當下位置、±1 秒微調）；載入時 `seek(max(opening, position))`；剩餘 ≤ `ending` 視為播完 | R3 | 單元測試 seek 與播完決策（純函式）；模擬器實測標記後換一集是否生效 |
| **V0** *(deferred)* | `WebHTVConfig` 解碼 `ads: [String]` 與 `rules: [{name, hosts, regex, script}]`；缺欄位時行為不變 | — | 單元測試：有欄位、無欄位、畸形欄位各一組 |
| **V1** *(deferred)* | `SnifferPolicy` + `ads` 兩層攔截（原生規則清單 + hook 內過濾） | V0 | 單元測試三項：①注入含廣告 host 的 HTML，斷言該 URL 不被回報（hook 層）②**真的沒有送出請求**——用 IOS-POC-5P 已經寫好的 `NWListener` 本地伺服器當廣告 host，斷言命中計數為 0（原生規則層）③**餵一份畸形規則**，斷言編譯失敗時退回只用 hook 過濾且嗅探仍可運作（K8 的那條路） |
| **V2** *(deferred)* | 符合 host 的 `rules.script` 在嗅探時注入執行 | V0 | 單元測試：本地 HTML，`src` 只在點擊後出現，斷言注入後抓得到 |

建議提交順序：`Q1+Q2+Q3` 一個 commit（同一件事的三段），`R1+R2+R3+R5` 一個，`R4+R6+R7` 一個，
`V0+V1+V2` 一個。5S 與 5Q／5R 之間沒有相依，可以先後任意，但 R7 必須在 R3 之後。

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
| K7 | `ads` 清單在使用者的設定檔只有一條 | 做完了感受不到差別 | 這是資料不是程式；文件寫明「要更多就自己往 `ads` 加」，並在設定頁顯示目前載入幾條 |
| K8 | `WKContentRuleList` 編譯失敗會讓整個嗅探壞掉 | 比不做還糟 | 編譯失敗就退回只用 hook 過濾，並記錄原因；列入 V1 的驗證 |
| K10 | 「最高畫質」不一定最能播：B 站 `qn > 80` 需要有效 SESSDATA（使用者設定檔那三個 bili 站的 cookie 2025 年就過期），某些站最高的那條線路是解析線而不是直鏈 | 預設選了一個播不動的 | 選單只呈現來源實際回報的項目；B 站 API 對無權限的 `qn` 會靜默降級，所以不會出現「選了 4K 卻拿到空結果」。若最高畫質解析失敗，使用者可在同一個選單改選——**不做自動回退**，那會掩蓋站方的真實狀態 |
| K9 | 注入站方提供的 `script` 等於執行設定檔裡的任意 JS | 信任邊界擴大 | 它只跑在嗅探用的 WKWebView 裡（無 `host.*`、無 native bridge），與 compatibility pack 的信任層級一致：設定檔本來就被信任。文件寫明 |

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
- **Verdict**：`PASS`（歷程：`REVISE` → `PASS` → 新增 5S/R7/最高畫質使前一次 basis 失效 → 重審 → `PASS`）
- **Review Basis**：2026-09-18，基線 HEAD `0414c032`，branch `ios-poc` clean。**三次** bounded read-only
  子代理審查：`architect-reviewer`（設計軸，7 項發現／6 項改變設計）、`qa-expert`（執行就緒軸，
  1 項 BLOCKING／3 項 ADVISORY），以及新增範圍的 delta 重審 `architect-reviewer`
  （3 項 BLOCKING／3 項 ADVISORY）。每一項主張都由主代理親自對程式碼核實後才採納——例如
  delta 重審指出 D13 應引 `VideoActivity.java:3287`（`onOpening` 設當下位置）而非 `:3294`
  （`onOpeningAdd` 的 ±1 秒），核對後照改。
- **Intent Alignment**：`Pass` — 目標、範圍、成功條件 S1–S8 與決策 D1–D12 均可追溯到實際檔案
  （`UrlAdapter.java`、`History.java:32,364`、`Constant.java:20`、`CMSClient.swift:236`、
  `WebHomeBridge.swift:340`、`Bili.js:110,132`），且未越出「不新增 Spider class／不碰 Python／
  CarPlay／不做跨裝置同步」的邊界。
- **Execution Readiness**：`Pass`（修正後）— S1–S8 各有切片與可執行驗證；Q1 與 R1 無未解阻擋可立即
  開工；回滾路徑已寫明。
- **Key Decision Point**：D10（B 站畫質用線路而非 `url` 陣列）。它把「每開一集多打 4–8 次 API」換成
  零額外請求，是整份計畫裡唯一一個改變成本量級的決定。次要但同級重要的是 D8——預設最高畫質，但
  **使用者上次親手選的優先於它**，否則「預設」會反覆推翻使用者的選擇。
- **Blocking Findings（已解）**：
  1. S3 在主驗證區塊沒有對應的可執行指令——既有 generic golden 不檢查畫質數量，指向 Bili 也會通過
     而沒有真的驗到。已加入 Q2 專屬 golden 的 `--filter biliOffersMultipleQualityLines`。
  2. K8 宣稱「規則編譯失敗會退回 hook 過濾」已列入 V1 驗證，但 V1 只寫了「編譯不拋錯」——那是成功
     路徑，不是失敗路徑。V1 的驗證改為三項，第三項專測畸形規則。
  3. S11 同時宣稱「不會被當成候選」與「不會被載入」，但 V1 原本的驗證只能證明前者。改為用
     IOS-POC-5P 已經寫好的 `NWListener` 本地伺服器當廣告 host、斷言命中計數為 0，把後者也變成
     可證明的——**保留 S11 的強度，而不是把條件寫弱**。
  4. Q3 的「預設索引（有記錄）」測試在建議的提交順序下不可能成立，因為那時 R1 還不存在。Q3 的預設
     索引改為純函式、偏好以參數注入，因此完全不相依於 R1。
- **Advisory Findings（已處理）**：S2 沒有真實資料可截圖 → 閘門改為單元測試、截圖降為 best effort；
  計畫原本沒有回滾章節 → 已補；需求基線把 spider 路徑的症狀寫成「靜默變空字串」，實際是 throw
  `DecodingError.typeMismatch`（`decodeIfPresent` 對型別不符是拋錯不是回 nil）→ 已改寫，並區分
  CMS 路徑用 `try?` 吞掉的差異；D13 引錯行號 → 改為 `:3287`；D17 的標題會被讀成連 `hosts` 都不用 →
  改寫為「`regex` 不用於候選判斷，`hosts` 仍用來挑 script」；`Playback`／`PlaybackSession.open`
  完全沒有站與片的身分（`WebHTVApp.swift:864`、`:969`），R2／R7 都要靠它 → 已寫進 R2 當前置。
- **Blocking Decision**：None
- **Next Governed Action**：`$execute-from-plan`，從 Q1 或 R1 起手
- **Invalidation Reason**：2026-09-18 第二次修訂新增 IOS-POC-5S（V0/V1/V2）、R7、D8 改為預設最高畫質、
  D9 反轉、D13–D18、S9–S13、K7–K10，使第一次 `PASS` 的 Review Basis 不再涵蓋全部範圍；已就新增範圍
  重跑 gate，verdict 維持 `PASS`。

## 阻塞事項

無。所有需要的人為決定（D1–D4）已於 2026-09-18 取得；設計層的 D5–D12 由主代理定案並經上述審查。

## 階段狀態

| 階段 | 狀態 | 下一步 |
|---|---|---|
| IOS-POC-5Q | **Done**（2026-09-18，Q1+Q2+Q3 一個 commit） | 無；紀錄在 `docs/IOS-POC-5Q-playback-quality.md` |
| IOS-POC-5R | **Done — R1–R6**（2026-09-18）；**R7 deferred** | 無；紀錄在 `docs/IOS-POC-5R-watch-history.md` |
| IOS-POC-5S | **Deferred**（2026-09-18，使用者指示；設計保留） | 等 drpy + Python POC + 真機主線完成後再排 |

本 repo 沒有 `docs/todo.md`，這張表就是那一行 todo；狀態由 `$execute-from-plan` 推進。
