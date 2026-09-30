# IOS-POC-39 — XBPQ 規則涵蓋：讓 `wang-sex.json` 的 104 個 XBPQ 站能用

## Recovery anchor

- 目標：使用者 2026-09-30「修 XBPQ 讓 wang-sex 那 104 站能用」。讓 `ios/Sources/WebHTVCore/Resources/Spiders/XBPQ.js` 支援這些站實際用到的規則，站數以 sweep 的「可用」（讀到影片位元組）為準。
- 狀態：**只做完診斷（2026-09-30 14:15），尚未研究原版語意、尚未改程式。** 屬 AGENTS.md §7 的 material requirement（規則引擎的新能力）：實作前要完成原版語意研究、寫進本文件的方案與驗收標準，並經使用者核准。
- 唯一下一步：反編譯 `xyqxbpq.jar` 的 XBPQ，解碼它的字串表，逐一寫下第二節缺少的規則鍵的語意（第四節），再提出分階段方案給使用者核准。

## 1. 診斷（2026-09-30，證據在 `docs/SITE-AVAILABILITY-2026-09-30.md`）

sweep（`swift test --filter sweepsEveryDrivableSource`，走 App 的 `SourceClient`）結果：`wang-sex.json` 的 106 個 XBPQ 站 104 站「首頁與第一個分類都沒有片」、1 站 DEAD-MEDIA、1 站 NO-EPISODE；`wang-movie.json` 的 7 個 XBPQ 站 1 站可用（果果短剧，只設 4 個鍵、靠預設模板）。

抽查網站本身（curl）：麻豆（gcmd.cc）200、分類頁有 20 筆詳情連結；SEAJAV 200、60 張封面；野鸡資源 200、16 筆；AG動漫 500。**網站有正常回片單而 iOS 取到 0 部**，所以是 iOS 這邊的問題。

三層原因（同一批站會同時碰到好幾層）：

| 情況 | 站數 | 原因 |
|---|---:|---|
| `ext` 是 `./json/*.json` 規則檔 | 41 | **分類數全部是 0**：規則沒讀進來。規則檔是帶 `//` 註解的 JSON（Python `re.sub('(?m)^\s*//.*$','',…)` 後可解析）；`XBPQ.js` 的 `init` 用 `host.parseJSON(extend)`，推斷解析失敗而 `rule={}`。未確認 `ext` 路徑是否有被 `CSPSourceResolver.resolvedExtend` 下載成內容（XYQHiker 的規則檔同樣帶註解，但它的分類讀得到，可以對照 `XYQHiker.js` 第 139 行附近的處理） |
| `ext` 內嵌、分類 0 | 19 | 分類不是用 `分类`（`名$id#…`）給，而是 `分类ID`、`首页`、`起始页` 等 iOS 不認得的鍵 |
| `ext` 內嵌、有分類但沒片 | 45 | 列表規則 `数组`／`标题`／`图片`／`链接`／`副标题` 完全沒實作，只好落到 `defaultList` 的蘋果 CMS 模板，對不上 |

## 2. 規則鍵盤點（101 個失敗站；`*` ＝ `XBPQ.js` 已實作）

| 站數 | 鍵 | | 站數 | 鍵 |
|---:|---|---|---:|---|
| 101 | * 分类url | | 22 | 跳转播放链接 |
| 81 | * 分类 | | 14 | * 线路标题 |
| 81 | 图片 | | 13 | * 线路数组 |
| 78 | 标题 | | 12 | 免嗅 |
| 78 | 数组 | | 12 | 播放数组 |
| 73 | * 主页url | | 12 | 嗅探词 |
| 72 | 链接 | | 11 | * 搜索链接 |
| 64 | 副标题 | | 11 | 二次截取 |
| 56 | * 搜索url | | 10 | 播放标题 |
| 51 | * 请求头 | | 9 | 搜索图片、搜索标题 |
| 42 | 站名 | | 7 | 类型、播放链接、搜索链接前缀／后缀、分类二次截取、链接前缀／后缀 |
| 37 | 编码 | | 6 | 搜索副标题、搜索数组 |
| 35 | 直接播放 | | 5 | 播放列表、分类值 |
| 33 | * 简介 | | 4 | 线路二次截取、防丢url |
| 32 | 作者 | | 3 | 图片代理、* 分类链接 |
| 28 | 搜索模式 | | 2 | 剧情、搜索后缀、导演、主演、过滤词、发布地址、排序 |
| 24 | 首页、* 分类数组、* 分类标题、分类ID | | 1 | 規則名、規則作者、規則日期、图片是否需要代理、是否开启获取首页数据、首页推荐链接 |
| 23 | 起始页 | | | |

注意：`XBPQ.js` 把 `分类链接` 同時當成「分類網址模板」（`categoryList`）與「列表區塊裡的連結規則」（`listFrom`），兩者語意不同，研究時要確認原版的用法。`站名`、`作者`、`規則*` 是說明用，不影響行為。

## 3. 規格來源

- 原版：`com.github.catvod.spider.XBPQ`，在使用者 GitLab `st7833232/recha` 的 `jar/xyqxbpq.jar`（2026-09-30 抓到 635,660 bytes，內含單一 `classes.dex`）；`wang-sex.json` 的全域 `spider` 就是 `./jar/xyqxbpq.jar`。`docs/CSP_PORTABILITY_MATRIX.md` 記載反編譯後 8,140 行（`xiaosa-0807.jar` 另有 43,768 行的版本）。
- 字串經 hex＋XOR(`"wxEesU"`) 混淆（`merge/xbpq/HaB.d`，見 `XBPQ.js` 檔頭註解），反編譯後要先解碼才讀得懂規則鍵。本機有 `jadx 1.5.6`（`/opt/homebrew/bin/jadx`）。
- 101 個站的規則（內嵌的 `ext` 與 `./json/*.json`）都能從 `wang-sex.json` 與 `https://gitlab.com/st7833232/recha/-/raw/main/json/<名稱>.json` 重抓。

## 4. 原版語意（待研究）

（尚未開始。每個第二節的缺漏鍵記：原版行為、在這批站的實際寫法範例、iOS 要怎麼做、測試。）

## 5. 驗收（草案，待核准）

- 以 `SWEEP_CONFIG=wang-sex.json` 的 sweep 為準：XBPQ 站的「可用」由 0 提高到研究後定的目標；任何原本可用的站（兩份設定檔）不得變成不可用。
- `swift test --package-path ios` 全過（含 `SpiderGoldenTests` 裡既有的 XBPQ 案例）；新增以真實規則與存下來的 HTML 片段為輸入的單元測試。
