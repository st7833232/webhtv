# IOS-POC-57B-2：TuXiaoBei 兒童影音 adapter

## 目標與授權

使用者已於本 session 明確核准由 Claude 實作 TuXiaoBei，Codex 規劃、協調並以 fresh Codex session 審查最終程式。新增 qist dianshi.json／jsm.json 的 csp_TuXiaoBei 支援，保留既有來源與播放器行為。規劃審查最多 2 輪；修正與 final inspect 各最多 2 輪。runner 使用 /opt/homebrew/bin/python3.13。模型沿用各 CLI 設定，不宣稱 UI 模型等於 CLI 模型。沒有 tag／push／發布授權。

完成條件（TXB-02）：首頁宣告 4 大類＋44 專題共 48 個入口，ID／名稱與上游 Java 常數（TuXiaoBei.java:20–23、215–232）逐一精確相同；代表流程以大類 `api_2` 與專題 `sub_17` 的片單、詳情、搜尋、播放驗收；原始 dianshi.json 在 Simulator 實際進入影片、播放進度前進；native 測試與 Codex final inspect 通過；本機原子提交，之後整合回 ios-poc。其他 3 大類與 43 專題的 live 可用性**未逐一驗證**，不宣稱全站可用。

## 邊界與基準

- 隔離 repo：/private/tmp/webhtv-tu-xiao-bei，branch ios-poc-tu-xiao-bei，目前 HEAD `d09c7c339558ea1355e0bd911902d6d440c8fa27`（merge：`0ede8b7f`＝FirstAid `176542d5`＋本工單，與 57A-3 `88ea5ce9a48c2453be3df38dd60f5448db4ca4e7`）。
- 可寫產品／測試路徑：ios/Sources/WebHTVCore/Resources/Spiders/TuXiaoBei.js、ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift、ios/Tests/WebHTVCoreTests/TuXiaoBeiSpiderTests.swift、ios/Tests/WebHTVCoreTests/SpiderGoldenTests.swift；文件僅本檔。
- 不改 ConfigLoader、host.js、runtime、播放器引擎、選站、spider-pack 或其他 adapter；不新增通用 parser／helper。不觸碰主 checkout、原 AGY worktree／guard／dirty 檔。
- **FirstAid 基準前置（TXB-03）**：本 HEAD 的 SpiderGoldenTests.swift:197–201 固定清單缺 FirstAid；主 checkout 的修正（FA-INTEGRATE-001）已審查 APPROVED，但仍是未提交的 merge（W-1 因權限 blocked）。**目前不能宣稱 main 已完成 merge。** 順序：W-1 在 ios-poc 產生 FirstAid merge commit → Claude 在原授權內把該 commit 同步（merge）進本隔離 branch，記錄完整 hash → 才開始 TuXiaoBei 程式。TuXiaoBei 的功能 commit 只新增 TuXiaoBei，不順帶修 FirstAid；清單保持整份精確斷言。
- 同步後完成基準 hash：**待 W-1**（同步時填入）。

## 證據與設計判斷

存取日期 2026-10-08；完整調查 /private/tmp/webhtv-qist-next-candidate.md 第 8 節，原始資料 /private/tmp/webhtv-qist-next-candidate.work/。開發前輸入在 .codex/task-state/inputs/（git-ignored，含 SHA256SUMS）。原始證據不得刪除；CDN 與 44 專題不再重測。

| 類別／等級 | 依據與 revision | 支持的決策／限制 |
|---|---|---|
| 上游發布產物 A | https://github.com/qist/tvbox/tree/14c12ddb39dc81d5b48f62ecfffa3641ca69e3fa/jar；spider.jar SHA256 72a1f3928eca281d878e44fc57162ff6a1f3ef779a2da05a2b351b241b110d69 | 排除 fty.jar 後檢查 6 個 JAR，僅 spider.jar 有明文 TuXiaoBei；加密 payload 不在本次範圍 |
| 上游實際程式 B | jadx 1.5.6 TuXiaoBei.java，SHA256 f0ae07870e137adf06b5fbb40fd04c336ae5b1c5f73ff6b2a62e47d422c7e1d4，254 行，輸入目錄內 | 4 大類、44 專題、id\|\|\|typeId、分類／專題／詳情／搜尋／播放；明碼，不需另造解碼器 |
| 本地實作 A | host.js parseJSON（host:474 可回 null）／urljoin／match（host:137–139）、XYQHiker、FirstAid.js、JavaScriptSpiderRuntime（runtime:153–154 page 為 String）、HTTPHost（:64–78 回 body／status）、SpiderRegistry、WatchHistory（:125–126 以 siteID＋vodId 為 key） | 沿用 Host ABI 與結果封裝；不新增 host 能力 |
| subject/17 primary gate（TXB-01） | `tuxiaobei-subject-17.mobile.html`：HTTP 200、218540 B、SHA256 e20c2e5713e340e0de56b38f1cbb45755a897e40a0d93d97fee2d43a98bd9ef6；手機 UA 取得一次 | Java pattern b 解析 **266** 筆、266 個不同 ID；首筆 3840／小闹钟／02:38／封面 https://resource-cdn.tuxiaobei.com/video/FlhBb795EmKVu9xMqcJPX5qcIEmI.jpg。多出的 1 個 `class="title"` 是頁面 :122 的 h3。站台自報 270 部，不等於解析出 270；native 以此 fixture 驗 primary 結果 |
| play/2156 gate（TXB-01） | `tuxiaobei-play-2156.mobile.html`：HTTP 200、48222 B、SHA256 c9f759177692ec6a16e0038ec6d20618278b4057a42ad9e2d4c5bb2b775eda82 | h1「我是巧克力」；video-src https://resource-cdn.tuxiaobei.com/video/8a/0b/8a0bfeedbda1edea3e5f04b4fbba46ac.mp4；poster web_poster.jpg 是站台通用圖，只證明解析來源 |
| live B（TXB-04） | 手機 UA：list/mip-data、subject/17、play/2156 皆 200；上游 Java:38／242 的桌機 UA 讓列表與專題回 404 | 固定 WebHTV 適配 UA 與 Referer（見實作 1），非照抄上游 |
| live B | URLSession Range GET 206、video/mp4、ftyp；AVAsset 222.4 秒、isPlayable=true、1280x720 | CDN 在本機可讀；curl TLS reset 不是 App 不可播的證據。未代替 iOS 實播與真機驗收 |
| live B | 搜尋 URLSession 跟隨 302；我是巧克力＝1 筆 2156／03:42，儿歌＝0 筆 | 正例與空結果都保存 fixture；離線測試不驗證 302 redirect headers |

其他證據類別：qist 只發布 JAR，沒有可用的 TuXiaoBei 原始測試／PR／維護者討論證據；站台沒有公開 API 規格。成熟相關實作以本 repo 已驗證的 XYQHiker 同 API 與 FirstAid native HTTP／播放傳遞為依據。單站抓取無 ABI／解碼器／性能架構變更，未找到能改變設計的論文／基準；不做開放式搜尋。這些限制不宣稱等於所有相關資料不存在。

前例更正（TXB-08）：57A-3 `88ea5ce9` 已在本 HEAD 歷史；XYQHiker.js:219–223 目前用 JSON category 與 `cut1`。`cut1`（host:397–430）的切割契約不能證明 JSONP 字串內含 `);` 時安全，所以本 adapter **不用 cut1 取 JSONP**，改用下方 lastIndexOf 決策，並以含 `);` 名稱的 native case 證明。

| 方案 | 判斷 |
|---|---|
| 不變更 | 可載入的 dianshi／jsm 仍無此 adapter，無完整兒童影音路徑 |
| 原样轉寫 JAR | 桌機 UA 在目前網站回 404，拒絕 |
| 手機 UA 窄適配 | 採用；保留五方法／分類／資料欄位，重用已驗證 host 功能，不加依賴或抽象 |

## 具體實作

1. **Headers（TXB-04）**：所有站台請求與播放 header 固定為 UA `Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1`、Referer `https://www.tuxiaobei.com/`；測試逐字比較。不換掉既有全域預設。
2. **home（TXB-02）**：4 大類 api_2／3／4／25＋44 個 sub_*，ID 與名稱照 Java 常數逐一寫入，以 host.result.home 封裝；測試對 48 個入口做精確比較。
3. **api_* 分類（TXB-05）**：page 先轉整數、下限 1，URL 與回傳分頁用同一數值；保留 callback=jsonp。HTTP 非 200 回空。JSONP 取 `jsonp(` 之後到**最後一個 `)`** 之前（lastIndexOf），避免名稱內 `);` 提早截斷；body 空／畸形、parseJSON 回 null、data／items 為 null 或 items 不是 array，全部回空。跳過 null／非物件項目，以及沒有合法非零 video_id 的項目。remarks 一律正規化成字串；duration_string 空時改用 play_num。非空頁 pagecount 至少下一頁，空頁停止。
4. **sub_* 專題（TXB-06）**：只支援第 1 頁，第 2 頁回空、pagecount=1；HTTP 非 200 回空，不解析錯誤頁。primary 規則（Java pattern b）以 adapter 內局部 RegExp（全域＋忽略大小寫）收集，保留上游「首見 ID」去重與順序；**只有 primary 全空時**才啟用上游既有的 bare `href="/play/(\d+)"` fallback，名稱／海報／remarks 依上游。不建立通用 HTML 引擎。
5. **canonical ID（TXB-09）**：列表、專題、搜尋、detail 輸出的 vod_id 一律是 canonical video_id（不帶分類 tid 後綴），讓同一影片跨大類／專題／搜尋共用續播紀錄。detail／player 照上游（Java:159／235）接受舊 id 取 `split('|||')[0]`；不加歷史遷移，不加公共 helper。
6. **detail**：依 play/{id} HTML／上游規則取 h1（缺時 title）、poster、video-src mp4，封裝 host.result.detail；非 200 不解析錯誤頁。播放清單標題沿用 Bili 已建立的 $/# 分隔符處理，避免一支影片變成多集；不改顯示標題本身。
7. **search**：key 以 encodeURIComponent 編碼，沿用 URLSession 302 跟隨；重用已驗 HTML 解析，正例可解析、零結果維持零結果；非 200 回空。
8. **player**：依上游 id 分流，回 host.result.play(url, false, headers)，沿用現有媒體／header 流程；不改 AVPlayer 或 MPV。
9. **Registry**：加 TuXiaoBei；固定預期清單在已同步的 FirstAid 基準上只新增 TuXiaoBei，保留所有既有名稱與 alias 斷言。

## 驗證與交付

- **Fixtures**：live fixture 只用 inputs/ 內已保存的檔案（list-api2-p1.jsonp、subject-17／play-2156 mobile HTML、search-qiaokeli／erge HTML）。edge 變體（名稱含 `);`、空 body、畸形 JSONP、`data: null`、404、非法／零 video_id、numeric remarks、page='2'／非法 page、primary 全空只剩 href）在測試內**明標為合成資料**，不得稱為 live。`list-nocallback.txt` 是空檔，只作「省略 callback 回空」的證據。
- **Mock（TXB-07）**：TuXiaoBei 專用、狀態隔離的 URLProtocol mock，記錄每個請求並精確斷言：list 的 typeId／page／callback=jsonp，search 的 key 解碼後等於「我是巧克力」且 URL 正確編碼，以及每個請求的 UA／Referer。不能像 FirstAidSpiderTests.swift:41 只按 path 回 fixture。離線不驗證 302 redirect headers；既有 URLSession live redirect 證據保留，GUI 作代表驗收；不新增 runtime 改動。
- **RED**：新增 native 測試先證明舊 registry 無 TuXiaoBei（`canDrive` 為 false）；保存實際失敗，不把編譯失敗當產品 regression 證據。
- **GREEN exact proof**：swift test --package-path ios --filter 'TuXiaoBeiSpiderTests|registryClaimsOnlyWhatIsActuallyPorted'。一個 native flow suite 覆蓋：home 48 入口精確比較；api_2 JSONP 欄位、數字 ID、page 整數化與 pagecount、空頁、`);` 名稱、各種空／畸形／null／404；sub_17 primary 266 筆與首筆、sub_17 非 200 回空、首見去重、primary 存在時不混入 bare href、primary 全空時 href fallback 去重、專題第 2 頁；detail/mp4/海報與 $# 標題不破壞集數；搜尋正例／空例與 query；canonical ID：同一影片由大類／專題／搜尋／detail 回同一 ID，舊 `2156|||sub_17` 詳情仍取 play/2156 並輸出 canonical ID；所有請求／播放的手機 UA＋Referer。復用現有 runtime pattern，不新增框架。
- builder 跑一次；協調者對 final code 獨立跑此 proof 一次；相關修改或不確定結果才重試，不跑 full suite。
- GUI：由現有 Claude pane 接續已成功的一次性 XCUITest runner，先保存設定，用 dianshi 原檔 → 兔小貝 → 大類 api_2＋專題 sub_17 → detail → 播放影像／進度前進；辨別 script／binary hash，完成後還原。只在觀察到真實播放時 PASS。
- final diff 必須 Ponytail review，結果記本檔；全新 Codex inspect 覆蓋全部修改，accepted fixes 後只重跑受影響 proof，再 fresh inspect。
- builder 不 commit／merge／tag／push；待 Codex final PASS 與 GUI 接受後，以 guard finish --no-tag 本機原子 commit，再整合回 ios-poc。來源碼由 Claude，Codex 只協調／文件；若 Codex 改程式須另交 fresh Claude inspect。

## Rollout／回滾與恢復

僅增一個 source 與資源，無依賴、Host ABI 或解碼／渲染改動。先離線 → 一個 GUI 流程 → 本機 commit／main 整合；不發版。回滾只 revert TuXiaoBei 的 logical commit：此站回到未支援，FirstAid 基準與其精確斷言保留，其餘能力不變。

- 狀態（2026-10-08 18:25 CST）：第一輪 REVISE；第二輪 W-5 REVISE（Reviewer-2，`.herdr-synapse/webhtv-dev/artifacts/w5-tuxiaobei-round2-review-2026-10-08.md`）的 TXB-01～09 已套入本檔。程式尚未實作；FirstAid 基準尚未提交（W-1 blocked）。
- Claude 估時 45～60 分鐘（不含 FirstAid 基準同步與 Codex 審查）；已有 sources／fixtures／runner，不再全面研究或找全機暫存。
- 唯一下一步：Reviewer-2 復核本檔短 diff；W-1 產生 FirstAid merge commit 後，Claude 同步該基準並回報完整 hash 與 Registry 精確斷言，兩項成立後 plan PASS，才開始實作。
