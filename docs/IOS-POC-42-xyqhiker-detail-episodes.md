# IOS-POC-42 — XYQHiker 詳情頁沒有集數（assessment）

## Recovery anchor

- 目標：使用者 2026-10-02「開始 IOS-POC-42 assessment」。起因是 41C 的 `SourceCheck` sweep：`wang-sex.json` 的 NO-EPISODE 29 項中有 28 項是 XYQHiker，首頁都有片，詳情全部 `flags=0 eps=0`。
- 範圍：只做 assessment（`AGENTS.md` §7 design-research gate），**不改程式**。task guard `IOS-POC-42`（`assessment`），路徑：本文件、`docs/current-task-state.md`。
- 結論：根因已由原版反編譯確認（第 3 節）；原型在 scratchpad 副本量過（第 6 節，未 commit）；建議 42A → 42B，42C 待決定（第 8、12 節）。
- 唯一下一步：等使用者核准第 12 節；沒有核准前不改 `XYQHiker.js`。

## 1. 問題與現況量測

- 量測方式：`SWEEP_CONFIG=<設定檔> SWEEP_BASE=https://gitlab.com/st7833232/recha/-/raw/main/<設定檔> swift test --package-path ios --filter sweepsEveryDrivableSource`（41C 的 `SourceCheck`：首頁或第一個分類 → 第一部詳情 → 第一集播放網址 → `MediaProbe` 讀到影片位元組），個人熱點，設定檔與規則檔是當天從 GitLab `st7833232/recha` 抓的。
- 2026-10-02 11:3x 基準線：`wang-sex.json` 220 站 PLAYABLE 39；其中 58 個 XYQHiker 項目（51 份 `./json/*.json` 規則檔加 1 個內嵌規則）**可以播放 0**：NO-EPISODE 28、EMPTY 11、ERROR 19。`wang-movie.json` 67 站 PLAYABLE 28，XYQHiker 3 站（农民、巴士动漫可以播放；動漫巴士 NO-PLAY）。
- 13:3x 重測（與原型背對背）見第 6 節。

## 2. 證據與方法（2026-10-02 存取）

| 證據類別 | 來源 | 等級 | 用途 |
|---|---|---|---|
| 原版程式 | `xyqxbpq.jar`（GitLab `recha` `jar/xyqxbpq.jar`，635,660 bytes，SHA-256 `7b732f2289236619b791d9c5a0d862d42c9bf3e5bb6123a6982736329bbe9e16`，與 IOS-POC-39 第 4.0 節同一版，`wang-sex.json` 的全域 `spider`）的 `com.github.catvod.spider.XYQHiker`；jadx 1.5.6 反編譯 23,487 行，`merge.xyq0208.WJz.d` 的 hex＋XOR（金鑰 `ZySGzj`）字串以腳本還原 3,495 處 | 高：`detailContent`、`playerContent`、`getText*`、`C0282` 是正常 Java；`m176`（搜尋）與 `m163` jadx 只能 fallback，鍵名與取值順序是從指令直接讀到的 | 原版語意（第 3 節） |
| 規則檔 | `wang-sex.json` 58 個 XYQHiker 項目引用的 51 份 `./json/*.json`（`youjizz.json` 在 GitLab 是 404）與 1 個內嵌規則（直播2），`wang-movie.json` 3 份 | 高（實際資料） | 鍵使用統計、受影響站數 |
| 網站實測 | curl（PC UA）抓首頁、分類、詳情與 embed 頁 | 中：curl 與 App 的 TLS／標頭不同，Cloudflare 判斷可能不一樣 | 逐站歸因（第 5 節） |
| App 路徑原型 | scratchpad 的 `git archive HEAD ios` 副本套原型後跑同一個 sweep | 高（同一套檢查器、同一時段） | 可救回站數（第 6 節） |
| 官方規格／上游 PR、issue／maintainer 討論 | 不適用：XYQHiker 是閉源 jar，沒有公開 repo 或規格 | — | — |
| 成熟相關專案／技術文章 | 未查：海阔视界規則教學只描述規則寫法，反編譯的原版程式已能直接決定行為 | — | — |

反編譯工作檔（`X.java` 字串還原、`XF.java` fallback、`rules.all.json`、sweep log、原型 diff）在 session scratchpad，不 commit；需要時照上表重做。

## 3. 原版語意（與 `XYQHiker.js` 逐鍵對照）

### 3.1 詳情：直接播放模式（根因）

- 原版 `detailContent` 一開始讀 `链接是否直接播放`（空的話改讀 `force_play`）；值是 `1` 或 `是` 時，**整段抓詳情頁、解析線路與選集的程式（反編譯第 1802～17024 行的 `if (!z2)` 區塊）都不執行**，直接輸出一集：`vod_play_from = 片名`、`vod_play_url = 片名$詳情網址`。原版的 `vod_id` 是 `片名$$$圖片$$$網址`，所以這個模式連詳情頁都不用抓。
- 非直接模式才讀 `播放列表数组规则`（`list_arr_rule`）、`选集列表数组规则`（`epi_arr_rule`）、`选集标题`（`epi_title`）、`选集链接`（`epi_url`）、`选集链接加前缀／后缀`（`epiurl_prefix／suffix`）、`是否反转选集序列`（`epi_reverse`）、`线路列表数组规则`（`tab_arr_rule`）、`线路标题`（`tab_title`）；每個鍵都是「中文鍵有值就用中文，否則英文」。
- `XYQHiker.js` `detailContent`（第 169～212 行）只有非直接模式，而且只認中文鍵；**沒有直接播放模式**，所以規則檔沒寫選集規則（18AV 等 14 份）或寫的是範本預設值（`.line` 29 份、kanav 的 `.playlist_notfull` 1 份）時一律 0 集。

### 3.2 播放：直接播放模式

- 原版 `playerContent`：`链接是否直接播放`（`force_play`）是 `1` 或 `2` 時，網址＝`直接播放链接加前缀`（`play_prefix`）＋id＋`直接播放链接加后缀`（`play_suffix`）；標頭用 `直接播放直链视频请求头`（`play_header`），沒有就用 `请求头参数`。
- 判斷：網址是影片（`C0282.m1119`：含 `.m3u8`、`.mp4`、`.flv` 等且不是 `=http`、`.html` 這類解析網址）→ `parse:0`；是愛奇藝、騰訊等 16 個 VIP 平台 → `parse:1, jx:1`；**其他一律 `parse:1`，交給播放器的 WebView 嗅探**（Android 的 `shouldInterceptRequest` 看得到所有子資源請求，包含 iframe 裡的）。
- `XYQHiker.js` `playerContent`（第 228～232 行）：只認 `链接是否直接播放 === '1'`，標頭只用 `直接播放直链视频请求头`，一律 `parse:false`。iOS 的 `SourceClient.resolveMedia`（`SourceClient.swift` 第 153～160 行）會先探測、是網頁再交給 `MediaSniffer`，所以「網頁 → 嗅探」這一步實際上仍會發生；但 `MediaSniffer` 是 JavaScript hook，**best effort**（`MediaSniffer.swift` 第 54～64 行），抓不到 Android 抓得到的部分情況。

### 3.3 片單連結前綴

- 原版首頁／分類 `vod_id` 的網址是無條件的「前綴＋連結＋後綴」（反編譯 `homeVideoContent`：`strReplaceAll3 = str7 + strM1140 + str8`），與 `XYQHiker.js` `extract`（第 110 行）相同。網站改成輸出完整網址後，前綴只有網域的規則（ujizzcn、小嫂子）在原版也會組出 `https://a.comhttps://…`。

### 3.4 搜尋（順帶發現，不是本任務的症狀）

- 原版 `m176`（搜尋）先讀 `搜索链接`，空的才讀 `search_url`；列表先讀 `搜索列表数组规则`，空的才讀 `sea_arr_rule`；`POST请求数据`／`sea_PtBody`、`搜索片单*` 同樣中文優先（fallback 指令直接讀到，`classes.dex` 中兩組鍵各自只出現一次）。
- `XYQHiker.js` `searchContent`（第 214～226 行）與 `SEARCH`（第 132～133 行）**只讀英文鍵**。47 份可解析的成人規則檔中 45 份（沒有一份用 `search_url`）與 `wang-movie.json` 的巴士动漫、動漫巴士用中文鍵，搜尋一律空；只有农民（`search_url`）有結果。

### 3.5 選擇器與取值

- 原版用完整 Jsoup（`C0241.m959` 解析、`m274` 選取），`:not()`、`:contains()`、`:has()` 都支援；`getTextByRule` 支援 `+`／`＋` 串接（`'📽️'+'在线播放'`）；`*截取模式`、`*是否Jsoup写法` 為 `0` 時改用 JSON 路徑或前後字串截取。
- `host.js` 的選擇器（第 136～170 行）支援 `:has`、`:eq/gt/lt`，**不支援 `:not`、`:contains`**，而且 `:not(:has(script))` 會被 `:has` 的正規式抓成「必須含 script」；`XYQHiker.js` 只有 Jsoup 寫法，沒有截取模式與 `+` 串接。

## 4. 規則檔的鍵使用（51 份成人規則檔＋3 份影視；可解析的成人規則檔 47 份）

| 情況 | 份數 | 備註 |
|---|---:|---|
| `链接是否直接播放=1`（直接播放模式） | 44 | 14 份沒寫選集規則；30 份另寫了 `播放列表数组规则`（29 份是範本值 `.line`），原版在這個模式下不讀 |
| `链接是否直接播放=0` | 3 | MOTV、色库TV、动漫PRO |
| 不是 XYQHiker 格式／讀不到 | 4 | xHamster 是 XBPQ 格式的鍵；tktube、杏吧视频的 JSON 有語法問題（App 的 `host.parseJSON` 讀得到）；youjizz 404 |
| 用中文搜尋鍵 `搜索链接` | 45 | 加上巴士动漫、動漫巴士 |
| 用 `:not(`／`:contains(` | 7 | p影院、sexsex、正妹av、热骚、紫色成人、酷爱成人网、黄色仓库啦 |
| 截取模式／非 Jsoup | 4 | 直播1、直播大全、直播2（內嵌；分類 JSON `zhubo`）、动漫PRO（選集前後截取） |
| `wang-movie.json` 3 站 | 3 | 全部 `链接是否直接播放=0`，直接播放模式的修改碰不到 |

## 5. 逐站歸因（`wang-sex.json` XYQHiker 58 項）

### 5.1 NO-EPISODE 28 項（24 站）

- **23 站是 3.1 的根因**（直接播放模式）：18AV、300分类（×2）、AirAV、亞洲情色網、HOHOJ、IXXXJ、KANAV、OWOAV、PPP、ThisAV、xgroovy、正妹AV、鲨鱼av、AVbebe（×2）、bongacams直播、jiedmAV（×2）、Qinav、Ujizzcn、亚色影库、好色TV、黄色仓库123、黄色仓库啦、小嫂子。
- **1 站是 3.5**：动漫PRO（×2）`链接是否直接播放=0`，選集是前後截取（`选集链接: video_url: '&&',`），線路標題是 `+` 串接。

### 5.2 EMPTY 11 項

| 站 | 歸因 | 類別 |
|---|---|---|
| 朱古力 | curl 是 Cloudflare `cf-mitigated: challenge` 403（App 沒標出 41A 原因，未查） | 網站 |
| Hanime1 | 首頁、分類 HTTP 400 | 網站 |
| 中国性味 | 網域轉到停放頁 `urldance.com` | 網站 |
| 热骚 | 首頁、分類都是 1.2KB 的跳轉頁 | 網站 |
| ACG漫画网（×2） | 分類頁正常但已沒有 `#list`（網站改版），原版也取不到 | 規則過時 |
| xHamster | 規則檔是 XBPQ 格式 | 設定 |
| 直播1、直播2、直播大全 | 分類是 JSON（`分类截取模式=0`、`zhubo`），未實作 | 程式缺口（3.5） |
| 酷爱成人网 | 網頁正常；`.videoPost:not(:has(script)):not(:contains(播放器))` 被讀成「必須含 script」 | 程式缺口（3.5） |

### 5.3 ERROR 19 項：全部是網站或設定

找不到網域 8（tktube、小丑撸、有爱爱、p影院、sexsex、色库TV、Xtoons×2）、JS 驗證／跳轉頁 3（台湾kiss×2、杏吧视频）、Cloudflare 2（444咖啡、playav）、HTTP 錯誤 3（MOTV 404、丽丽AV 522、亚洲色吧 502）、TLS 1（紫色成人）、連不上 1（170av，規則檔註明已搬到 190av.cc）、規則檔 404 1（youjizz）。

## 6. 原型量測（scratchpad 副本，未 commit）

- 原型一＝只補 3.1（詳情的直接播放模式：不解析選集，一集 `片名$詳情網址`；片名取 `详情标题`／`<title>`）。播放沿用現有程式（`parse:false` → `SourceClient` 探測 → 網頁就嗅探），效果等同原版的 `parse:1`。
- 原型二＝原型一＋直接播放模式的播放端 WebHTV 窄版：網址是影片就直接播；否則先抓頁面，用現有三條擷取規則（`"url":"…"`、`var now=`、影片網址）找，找不到再進第一個 `src` 含 `embed` 的 iframe 一層；拆掉 `…?url=https://…` 的解析外層；副檔名必須在結尾（`preview.m3u8.jpg` 不算）；都找不到才 `parse:1` 嗅探。另加：片名去掉 `$`、`#`（AVbebe 片名含 `#`，被拆成兩集）；連結已是完整網址而前綴只是網域時不加前綴；`force_play`、`2` 照原版也算直接播放；標頭沒設 `直接播放直链视频请求头` 時用 `请求头参数`。
- 原型三＝原型二＋靜態擷取排除路徑含 `/ad/`、`/ads/`、`/preroll/` 的網址（原型二的正妹AV 抓到頁面裡的 `media/preroll/…` 廣告而 DEAD-MEDIA；原型一靠嗅探反而取到正片）。原型三的 diff 在附錄 A（全在 `XYQHiker.js`，以 `b785502e` 為基準）。

| PLAYABLE（同一熱點） | 11:3x 基準 | 11:40 原型一 | 13:3x 基準 | 13:3x 原型二 | 13:38 原型三 |
|---|---:|---:|---:|---:|---:|
| `wang-sex.json` 全部（220 站） | 39 | 45 | 38 | 57 | **59** |
| 其中 XYQHiker 項目（58） | 0 | 6 | 0 | 16 | **18** |
| `wang-movie.json` 全部（67 站） | 28 | 28 | 24 | 25 | 未重跑（差異只在直接播放模式，影視 3 站都不是） |

- 13:3x 基準與原型背對背跑（基準 sex → 原型 sex → 基準 movie → 原型 movie）。非 XYQHiker 站逐站 diff：`wang-sex.json` 只有奥斯卡、奥斯卡资源、精东资源（type-1）ERROR → PLAYABLE，`wang-movie.json` 只有虎牙（type-1）DEAD-MEDIA → PLAYABLE，都是 CMS 站、與 `XYQHiker.js` 無關，是網路波動；**沒有任何站退步**。`wang-movie.json` 的农民、巴士动漫兩次都 PLAYABLE，動漫巴士兩次都 NO-PLAY。
- 11:40 原型一的 6 項：300分类（×2）、xgroovy、正妹AV、亚色影库、好色TV（5 站）。非 XYQHiker 站與同時段基準逐站相同；`wang-movie.json` 差 3 站（咕噜 504、非凡、爱弹幕），都不是 XYQHiker。
- 原型三的 XYQHiker 18 項逐站：
  - PLAYABLE 18：18AV、300分类（×2）、AirAV、HOHOJ（embed）、PPP、Ujizzcn（前綴）、jiedmAV（×2，embed＋拆 `155jx.com/?url=`）、xgroovy、亚色影库、亞洲情色網、好色TV、小嫂子（前綴）、正妹AV（廣告排除）、鲨鱼av（靜態擷取）、黄色仓库123（靜態擷取，HLS 清單有 `EXTINF`）、bongacams直播。
  - **bongacams直播不算救回**：取到的 `i.bgicdn.com/images/chat/video/video.mp4` 只有 3,753 bytes，是佔位影片，不是直播內容。
  - NO-PLAY 6：KANAV（curl 是 Cloudflare 403）、IXXXJ（1.2KB 跳轉頁）、黄色仓库啦（片單連結抓到網站首頁，規則問題）、OWOAV（第一部是頻道頁；頁面裡的 KVS `get_file/…mp4/` 結尾多一個 `/`，副檔名檢查不收）、AVbebe（×2，未查）。
  - DEAD-MEDIA 2：Qinav（取到 m3u8，探測 `unknown`，未查是 CDN 失效還是要 Referer）、ThisAV（missav 系，`surrit.com` 探測 `unknown`）。
  - NO-EPISODE 2：动漫PRO（×2，3.5 的截取模式，不在 42A／42B）。
- **結論**：42A 單獨可救回 **5 站**（11:40 單次量測）；42A＋42B 可救回 **15 站（17 項）**（13:38 量測，扣掉 bongacams）。PLAYABLE 是「讀到影片位元組」，片子是否正片只核對了黄色仓库123、正妹AV、bongacams；其餘未核對。

## 7. 方案比較

| 選項 | 內容 | 評估 |
|---|---|---|
| A. 不改 | — | XYQHiker 在 `wang-sex.json` 0 站可播；搜尋也全空。不建議 |
| B. 照搬原版 | 3.1 詳情直接播放模式＋3.2 播放端交給嗅探（＝原型一） | 實測 +5 站，零退步；但 iOS 嗅探是 best effort，網頁型的 15 項停在 DEAD-MEDIA |
| **C. WebHTV 窄版（建議）** | B＋3.2 的播放端先靜態擷取（排除廣告路徑）、進一層 embed、拆解析外層，再嗅探（＝原型三） | 實測 +15 站（17 項），兩份設定零退步；播放多 1～2 個 HTTP GET，命中時省掉 WebView 嗅探（數秒）；擷取規則是非直接模式已在用的那三條 |
| D. 補齊原版全部規則能力 | C＋中文搜尋鍵、Jsoup 偽類、截取模式、`+` 串接、原版 `vod_id` 格式 | 搜尋鍵值得做（另列 42C）；其餘各救 0～3 站，`host.js` 選擇器是 drpy 共用、風險較大；改 `vod_id` 格式會讓 XYQHiker 站現有的觀看記錄對不上。不建議一次做 |

C 的取捨：

- **正確性**：直接播放模式只在規則檔明寫 `1`／`是`（詳情）、`1`／`2`（播放）時啟用，照原版；靜態擷取只接受副檔名在結尾的網址，找不到就退回嗅探，不會比現在差。
- **與原版的刻意差異**：(1) `vod_id` 仍是網址，所以詳情頁照樣抓一次取片名（原版從 `vod_id` 拿），抓失敗也照樣有一集；(2) 播放端先靜態擷取再嗅探（原版直接嗅探），因為 iOS 沒有 `shouldInterceptRequest`；(3) 前綴只是網域且連結已完整時不加前綴（原版會組出無效網址）。
- **相容性**：`wang-movie.json` 三站都是 `链接是否直接播放=0`，走的程式不變；`js.host` ABI 不變；不改 Swift。
- **效能**：直接播放模式的詳情少了選集解析；播放多 1～2 個 GET，命中時省掉 WebView。
- **維護與驗證**：改動集中在 `XYQHiker.js` 的 `detailContent`／`playerContent`；用 `SourceCheck` sweep 量，加 `SpiderHostTests` 風格的離線單元測試（固定 HTML 與規則）。
- **回滾**：每段一個 commit，`git revert` 即可，不影響其他 spider。

## 8. 建議方案與分段

### 42A 詳情的直接播放模式（照原版，建議先做）

- `XYQHiker.js` `detailContent`：`链接是否直接播放`（`force_play`）為 `1`／`是` 時不解析線路與選集，輸出一集 `片名$詳情網址`；片名用 `详情标题`，沒有就用 `<title>`，再沒有用「播放」；片名去掉 `$`、`#`；片名與 `vod_name` 共用同一次計算（Ponytail）。
- 測試：直接播放模式（有／沒有 `播放列表数组规则` 都只有一集）、片名含 `#`、`链接是否直接播放=0` 時行為不變。

### 42B 直接播放模式的播放端（WebHTV 窄版）

- `playerContent`：`1`／`2` 與 `force_play` 照原版；標頭 fallback 到 `请求头参数`；網址是影片 → `parse:0`；否則抓頁面靜態擷取 → 第一個 embed iframe → 拆 `?url=` → 都沒有才 `parse:1`。
- `extract`：連結已是完整網址而前綴只是網域時不加前綴。
- 影片副檔名的正規式只寫一次，`mediaIn`、`playerContent`、`isVideoFormat` 共用（Ponytail）。
- 非直接模式的三條擷取規則改呼叫同一個 `mediaIn`（刪掉重複，Ponytail）：以 `wang-movie.json` 的农民、巴士动漫不退步為條件，退步就維持原樣。
- 靜態擷取排除路徑含 `/ad/`、`/ads/`、`/preroll/` 的網址，以 `ponytail:` 註明這是啟發式、漏網的廣告仍會被播（升級條件：出現實際誤抓的站時改成收集全部候選再挑）。
- 嗅探也失敗時回 `parse:1`，`SourceClient` 回 nil（使用者看到「無法播放」）；現在是把網頁丟給播放器失敗，結果一樣是播不了。
- 測試：影片網址直通、頁面內擷取、embed 一層、解析外層、`preview.m3u8.jpg` 不算、廣告路徑不算、前綴規則、找不到時 `parse:1`。
- 不做：KVS `get_file/…mp4/`（結尾 `/`）放寬（OWOAV 第一部是頻道頁，放寬也不一定救得回；出現第二個站再做）。

### 42C 搜尋讀中文鍵（待決定）

- `searchContent`：`搜索链接`→`search_url`、`POST请求数据`→`sea_PtBody`、`搜索列表数组规则`→`sea_arr_rule`、`搜索片单标题／链接／图片／副标题／链接加前缀／后缀`→英文，照原版中文優先。做法是把 `SEARCH` 的各欄改成 `ruleFor` 已支援的陣列（例 `['搜索片单标题', 'sea_title']`），`extract` 的 `array` 改用 `ruleFor`，不另寫 fallback（Ponytail）。
- 影響：47 份規則檔（含 `wang-movie.json` 巴士动漫、動漫巴士）的搜尋從全空變成可能有結果。`SourceCheck` 不檢查搜尋，驗收要另外用全站台搜尋實測幾個關鍵字。
- 預估 30～45 分鐘。

### 暫緩（各救 0～3 站，記錄不做）

- 截取模式 JSON（直播1、直播2、直播大全）、選集前後截取與 `+` 串接（动漫PRO）、`host.js` 的 `:not`／`:contains`（酷爱成人网；drpy 共用）。
- 規則檔自己的問題（使用者 GitLab）：ACG漫画网 `#list`、xHamster 格式、170av 搬到 190av.cc、youjizz 404、小嫂子／ujizzcn 的前綴（42B 會繞過）、黄色仓库啦的片單連結抓到網站首頁、亞洲情色網詳情 404。

## 9. 驗收標準

- 兩份設定在同一時段、同一網路下背對背跑基準與修改後的 sweep：`wang-sex.json` XYQHiker 可以播放站數，42A 後 ≥ 5 站、42B 後 ≥ 15 站（第 6 節；當下網站不通的站要逐站說明）；`wang-movie.json` PLAYABLE 不少於基準，农民、巴士动漫維持 PLAYABLE，動漫巴士不比基準差。
- 非 XYQHiker 站逐站 diff 只允許可說明的網路波動。
- `swift test` 全過（含新測試）；模擬器 Debug 與 generic iOS Release build；模擬器實看至少 2 站（例：亚色影库、鲨鱼av）從首頁點到播放。
- 真機：未驗證就寫未驗證。

## 10. 回滾

- 42A、42B、42C 各一個 commit，`git revert <commit>`；只動 `XYQHiker.js` 與它的測試，不動 Swift、ABI、設定檔，其他 spider 不受影響。

## 11. 風險與未決

- 網站狀態每小時在變（11:3x 與 13:3x 的差異見第 6 節），站數只能當當下的量測。
- 靜態擷取可能抓到廣告或預告片：「副檔名在結尾」排除截圖，廣告路徑排除救回正妹AV，只取第一個 embed iframe；仍可能有站抓到不在這些路徑的廣告或佔位影片（bongacams 的 3.7KB `video.mp4`），sweep 會算成 PLAYABLE，只能靠抽查。
- iOS 嗅探抓不到的站（Cloudflare、要點擊才載入）即使 42B 也救不回，屬網站問題。
- 朱古力：curl 是 Cloudflare challenge，App 卻沒有顯示 41A 的原因，原因未查（41A 範圍，不在本任務）。

## 12. 待使用者決定

1. 是否核准 42A＋42B（建議：核准，兩段各自 commit）。
2. 42C 搜尋中文鍵：一起做（建議，影響 47 份規則檔的搜尋）／另開任務／不做。
3. 第 8 節「暫緩」與規則檔問題：照建議不做（建議）／指定要做的項目。

## 13. 狀態

- 2026-10-02 assessment 完成，只改文件。等使用者回覆第 12 節。
- Ponytail：`ponytail:ponytail-review` 對附錄 A 與第 8 節，4 項 shrink（片名算一次、影片副檔名正規式共用、非直接分支重用 `mediaIn`、42C 用 `ruleFor` 陣列），net −7 行，已寫進第 8 節的設計；附錄 A 保留量測時的原樣。

## 附錄 A：原型三 diff（scratchpad，未 commit；實作時拆成 42A／42B 並補測試，`PROTOTYPE` 註解要改寫）

```diff
--- a/ios/Sources/WebHTVCore/Resources/Spiders/XYQHiker.js
+++ b/ios/Sources/WebHTVCore/Resources/Spiders/XYQHiker.js
@@ -87,6 +87,19 @@
     return '';
   }

+  function joinPrefix(prefix, link) {
+    return /^https?:\/\//i.test(link) && /^https?:\/\/[^\/?#]+\/?$/i.test(prefix) ? link : prefix + link;
+  }
+
+  function mediaIn(html) {
+    var url = host.match(html, '"url"\\s*:\\s*"([^"]+)"').replace(/\\\//g, '/');
+    if (!url) url = host.match(html, 'var\\s+now\\s*=\\s*"([^"]+)"');
+    if (!url) url = host.match(html, '(https?:[^"\'\\s\\\\$#]+\\.(?:m3u8|mp4|mkv|flv)(?=[?"\'\\s\\\\]|$)[^"\'\\s\\\\$#]*)');
+    url = url.replace(/^https?:\/\/[^?#]*\?url=(https?:)/i, '$1');
+    // Pre-roll ads sit in the page beside the real stream (正妹AV: /media/ads/…, /media/preroll/…).
+    return /\.(m3u8|mp4|mkv|flv)(\?|$)/i.test(url) && !/\/(ads?|preroll)\//i.test(url) ? url : '';
+  }
+
   function extract(html, keys) {
     var scope = html;
     if (keys.outer && text(keys.outer)) {
@@ -107,7 +120,7 @@
       var title = host.pdfh(nodes[i], titleRule);
       if (!link || !title) continue;
       out.push({
-        vod_id: prefix + link + suffix,
+        vod_id: joinPrefix(prefix, link) + suffix,
         vod_name: title,
         vod_pic: host.urljoin(prefix, host.pdfh(nodes[i], picRule)),
         vod_remarks: remarkRule ? host.pdfh(nodes[i], remarkRule) : ''
@@ -195,6 +208,13 @@
         }
       }

+      // PROTOTYPE (IOS-POC-42): Hiker's direct-play mode skips the playlist rules entirely.
+      var direct = text('链接是否直接播放') || text('force_play');
+      var name = host.pdfh(html, text('详情标题') || 'title&&Text').split(/[-_|]/)[0].trim();
+      if (direct === '1' || direct === '是') {
+        froms = [name || '播放'];
+        urls = [(name || '播放').replace(/[$#]/g, '') + '$' + url];
+      }
       return host.result.detail({
         vod_id: url,
         // These pages put a breadcrumb in <h1>, so the document title is the better fallback
@@ -226,9 +246,19 @@
     },

     playerContent: function (flag, id) {
-      if (text('链接是否直接播放') === '1') {
-        return host.result.play(text('直接播放链接加前缀') + id + text('直接播放链接加后缀'),
-                                false, parseHeaders(text('直接播放直链视频请求头')));
+      var direct = text('链接是否直接播放') || text('force_play');
+      if (direct === '1' || direct === '2') {
+        var target = joinPrefix(text('直接播放链接加前缀'), String(id)) + text('直接播放链接加后缀');
+        var playHeaders = text('直接播放直链视频请求头') ? parseHeaders(text('直接播放直链视频请求头')) : headers;
+        if (/\.(m3u8|mp4|mkv|flv)(\?|$)/i.test(target)) return host.result.play(target, false, playHeaders);
+        var page = fetch(target);
+        var found = mediaIn(page);
+        if (!found) {
+          var embed = host.match(page, '<iframe[^>]+src=["\']([^"\']*embed[^"\']*)');
+          if (embed) found = mediaIn(fetch(host.urljoin(target, embed)));
+        }
+        if (found) return host.result.play(found, false, playHeaders);
+        return host.result.play(target, true, playHeaders);
       }
       var html = fetch(String(id));
       var url = host.match(html, '"url"\\s*:\\s*"([^"]+)"').replace(/\\\//g, '/');
```
