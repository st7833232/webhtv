# IOS-POC-57B-2：TuXiaoBei 兒童影音 adapter

## 目標與授權

使用者已於本 session 明確核准由 Claude 實作 TuXiaoBei，Codex 規劃、協調並以 fresh Codex session 審查最終程式。新增 qist dianshi.json／jsm.json 的 csp_TuXiaoBei 支援，保留既有來源與播放器行為。規劃審查最多 2 輪；修正與 final inspect 各最多 2 輪。runner 使用 /opt/homebrew/bin/python3.13。模型沿用各 CLI 設定，不宣稱 UI 模型等於 CLI 模型。沒有 tag／push／發布授權。

完成條件：4 大類與 44 專題有合法片單；詳情有正確名稱、海報與播放清單；有結果的搜尋關鍵字能解析，網站零結果維持零結果；原始 dianshi.json 在 Simulator 實際進入影片、播放進度前進；native 測試與 Codex final inspect 通過；本機原子提交，之後整合回 ios-poc。

## 邊界與基準

- 隔離 repo：/private/tmp/webhtv-tu-xiao-bei，branch ios-poc-tu-xiao-bei，基準 176542d5ec1aac4a96669c60b81b480f317a73f7。其 FirstAid 程式已通過 native／GUI；主 ios-poc 正在整合，不允許本 builder 修改主 checkout。
- 可寫產品／測試路徑：ios/Sources/WebHTVCore/Resources/Spiders/TuXiaoBei.js、ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift、ios/Tests/WebHTVCoreTests/TuXiaoBeiSpiderTests.swift、ios/Tests/WebHTVCoreTests/SpiderGoldenTests.swift；文件僅本檔。
- 不改 ConfigLoader、host.js、runtime、播放器引擎、選站、spider-pack 或其他 adapter。不觸碰原 AGY worktree／guard／dirty 檔。
- 本基準的 Registry 固定預期清單缺 FirstAid，是已知前置測試問題；主分支正單獨修復。此次更新清單時須同時有 FirstAid 與 TuXiaoBei，保持整份精確斷言，不改成弱斷言；不得誤稱是 TuXiaoBei 新增的回歸。

## 證據與設計判斷

存取日期 2026-10-08；完整調查 /private/tmp/webhtv-qist-next-candidate.md 第 8 節，原始資料 /private/tmp/webhtv-qist-next-candidate.work/。開發前輸入已複製至 .codex/task-state/inputs/（git-ignored，含 SHA256SUMS）。原始證據不得刪除。

| 類別／等級 | 依據與 revision | 支持的決策／限制 |
|---|---|---|
| 上游發布產物 A | https://github.com/qist/tvbox/tree/14c12ddb39dc81d5b48f62ecfffa3641ca69e3fa/jar；spider.jar SHA256 72a1f3928eca281d878e44fc57162ff6a1f3ef779a2da05a2b351b241b110d69 | 排除 fty.jar 後檢查 6 個 JAR，僅 spider.jar 有明文 TuXiaoBei；加密 payload 不在本次範圍 |
| 上游實際程式 B | jadx 1.5.6 TuXiaoBei.java，SHA256 f0ae07870e137adf06b5fbb40fd04c336ae5b1c5f73ff6b2a62e47d422c7e1d4，254 行，輸入目錄內 | 4 大類、44 專題、id|||typeId、分類／專題／詳情／搜尋／播放；明碼，不需另造解碼器 |
| 本地實作 A | host.js cut1／parseJSON／urljoin、XYQHiker categoryContent、FirstAid.js、JavaScriptSpiderRuntime、CSPSourceResolver、SpiderRegistry | 沿用 Host ABI 與模組／結果封裝；parseJSON 本身不解析 JSONP，先用 cut1；Registry 固定清單是直接消費端 |
| live B | 手機 UA：list/mip-data、subject/17、play/2156；桌機 UA 回 404 | 改為已驗證的手機 UA；不要照抄桌機 UA |
| live B | URLSession Range GET 206、video/mp4、ftyp；AVAsset 222.4 秒、isPlayable=true、1280x720 | CDN 在本機可讀；curl TLS reset 不是 App 不可播的證據。未代替 iOS 實播與真機驗收 |
| live B | 搜尋 URLSession 跟隨 302；我是巧克力＝1 筆 2156／03:42，儿歌＝0 筆 | 同上游 HTML 規則可用；正例與空結果都保存 fixture |

其他證據類別：qist 只發布 JAR，沒有可用的 TuXiaoBei 原始測試／PR／維護者討論證據；站台沒有公開 API 規格。成熟相關實作以本 repo 已驗證的 XYQHiker 同 API／cut1 與 FirstAid native HTTP／播放傳遞為依據。單站抓取無 ABI／解碼器／性能架構變更，未找到能改變設計的論文／基準；不做開放式搜尋。這些限制不宣稱等於所有相關資料不存在。

| 方案 | 判斷 |
|---|---|
| 不變更 | 可載入的 dianshi／jsm 仍無此 adapter，無完整兒童影音路徑 |
| 原样轉寫 JAR | 桌機 UA 在目前網站回 404，拒絕 |
| 手機 UA 窄適配 | 採用；保留五方法／分類／資料欄位，重用已驗證 host 功能，不加依賴或抽象 |

## 具體實作

1. 模組風格沿用同層既有 adapter；headers 使用 probe 已驗證手機 UA 與 Referer https://www.tuxiaobei.com/，不換掉既有全域預設。
2. home：4 大類 api_2／3／4／25，44 個 sub_* 名称以實際 Java 常數為準，不臆造；以 host.result.home 封裝。
3. api_* 分類：保留 callback=jsonp（省略 callback 回空）；host.get → host.cut1(body, 'jsonp(&&);') → host.parseJSON → data.items。數字 ID 轉字串，沿用 video_id|||tid；host.urljoin 補全圖片。時長／瀏覽數遵循上游；非空頁 pagecount 至少下一頁，空頁停止。
4. sub_*：用上游已驗的 HTML 規則，只支援第 1 頁；第 2 頁回空、pagecount=1。不要建立通用 HTML 引擎或 speculative fallback。
5. detail：依 play/{id} 實際 HTML／上游規則取 title、poster、video-src mp4，封裝 host.result.detail。播放清單標題沿用 Bili 已建立的 $/# 分隔符處理，避免一支影片變成多集；不改顯示標題本身。
6. search：沿用 encodeURIComponent 與 URLSession 302 跟隨；重用已驗 HTML 解析，能解析正例、維持零結果。
7. player：沿上游 id 分流，回 host.result.play(url,false,headers)，沿用現有媒體／header 流程；不改 AVPlayer 或 MPV。
8. Registry 加 TuXiaoBei，固定預期清單同步新增，保留所有既有名稱與 alias 斷言。

只缺 play/2156 与 subject/17 的原始 HTML 未留存：builder 可各取回一次（手機 UA／公開 GET）作 fixture，記錄來源及日期；失敗則明列阻塞，不造出代表 live 的測試資料。其他成功 probe 不重跑。

## 驗證與交付

- RED：新增 native 測試先證明舊 registry 無 TuXiaoBei／無法初始化；保存實際失敗，不把編譯失敗當產品 regression 證據。
- GREEN exact proof：swift test --package-path ios --filter 'TuXiaoBeiSpiderTests|registryClaimsOnlyWhatIsActuallyPorted'。一個 native flow suite，覆蓋 home 48 類、API JSONP 欄位、數字 ID、空頁／專題第 2 頁、detail/mp4/海報、$# 標題不破壞集數、搜尋正例／空例與 query、所有請求／播放的手機 UA＋Referer。復用現有 URLProtocol／runtime pattern，不新增框架。
- builder 跑一次；協調者對 final code 獨立跑此 proof 一次；相關修改或不確定結果才重試，不跑 full suite。
- GUI：CLI builder 若缺能力不猜工具可轉移。由現有 Claude pane 接續已成功的一次性 XCUITest runner，先保存設定，用 dianshi 原檔 → 兔小貝 → 1 大類＋1 專題 → detail → 播放影像／進度前進；辨別 script／binary hash，完成後還原。只在觀察到真實播放時 PASS。
- final diff 必須 Ponytail review，結果記本檔；全新 Codex inspect 覆蓋全部修改，accepted fixes 後只重跑受影響 proof，再 fresh inspect。
- builder 不 commit／merge／tag／push；待 Codex final PASS 與 GUI 接受後，以 guard finish --no-tag 本機原子 commit，再整合回 ios-poc。來源碼由 Claude，Codex 只協調／文件；若 Codex 改程式須另交 fresh Claude inspect。

## Rollout／回滾與恢復

僅增一個 source 與資源，無依賴、Host ABI 或解碼／渲染改動。先離線 → 一個 GUI 流程 → 本機 commit／main 整合；不發版。revert TuXiaoBei logical commit 退回此站未支援，其餘能力不變。

- 狀態：使用者已核准範圍；設計待獨立 review；程式尚未實作。CLI reviewer 模型未觀察前標 unresolved。
- Claude 估時 45～60 分鐘（不含前置 FirstAid 整合與 Codex 審查）；已有 sources／fixtures／runner，不再全面研究或找全機暫存。
- 唯一下一步：獨立 Claude review 本文件（最多 2 輪），APPROVED 與 check 通過後，以共用 Python 3.13 runner build 交 Claude 實作。
