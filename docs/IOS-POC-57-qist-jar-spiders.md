# IOS-POC-57 — qist/tvbox `jar/` 的爬蟲盤點與移植

## Recovery anchor

- 目標（使用者 2026-10-06）：把 <https://github.com/qist/tvbox/tree/master/jar> 的全部爬蟲加進 **iOS App**。同一個類別出現在多份 JAR 時，「看哪一份支援最多」；**`fty.jar` 不用支援**；成人類**一起做**；站台由使用者在 App 裡加 qist 的設定網址（例如 `https://raw.githubusercontent.com/qist/tvbox/master/dianshi.json`）取得，不改 `wang-movie.json`。
- iOS 不能執行 JAR（Android DEX），每個類別都要用 JS adapter 重寫，或證明與既有 adapter 相同後加 alias。所以分階段：階段 0 盤點＋連線檢查，階段 1 不寫新 adapter（實測已支援的類別、加 alias），階段 2 起每批 5～8 個移植。
- Task guard：`IOS-POC-57`（`standard`），基準 `1174be8101ae63adcb7f0ba345e5311711992fd0`。路徑：本文件、`docs/current-task-state.md`、`ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift`、`ios/Tests/WebHTVCoreTests/SpiderGoldenTests.swift`。
- 狀態（2026-10-08 上午）：
  - 階段 0、階段 1 完成：5 個 alias（`ShortHema`、`ShortQimao`、`ShortHaokan`、`ShortWeiguan`、`SportsGuazi`）已加，commit `91364cd6`。
  - 階段 2A 完成（第 8 節，Task-Guard `IOS-POC-57A`，commit `c7512240`）：`App99` 支援沒有 `appkey` 的 qist 版；`Bili` 支援 `ext.n` 內建分類、XYQ 版 `ext`，並且不再抓 TVBox 本機 cookie。`App3Q`、`AppQi` 查證後是站方問題，不改。
  - 2A 第一輪審查修正完成（第 9 節，Task-Guard `IOS-POC-57A-1`，commit `50b31b79`）：Bili 本機 cookie 判斷補齊邊界、App99／Bili 檔頭、2A 研究紀錄（第 8.6 節）、測試並行時取錯請求（P2）。
  - Bili 分集標題含 `$`／`#`（第 10 節，Task-Guard `IOS-POC-57A-2`）：已實作並驗證，審查通過（2026-10-08），已 commit。`spider-pack/` 為 `2026-10-08.1`。
  - **沒有發版**；Simulator、真機都沒跑。
- 唯一下一步：等使用者決定下一批（第 8.5 節：XYQHiker 的 JSON 分類模式、2B 新類別移植）。

## 1. 方法（2026-10-06 16:40～17:00 CST，台灣家用網路）

- 8 個檔案經 GitHub raw 下載到 session scratchpad，只用 jadx 反編譯做靜態分析，**沒有執行任何 JAR**。13 份 qist 根目錄設定一起下載，用來對照「哪些類別有站在用」。
- 每個 `com.github.catvod.spider.*` 類別：用 `scripts/audit_spider_jars.py` 的 `classify`（依賴分類）、`Fingerprinter`＋`decide`（與 `scripts/spider_baselines.json` 的 21 個基準比對，IOS-POC-55 的演算法），再加上實作的 CatVod 方法、程式行數、被哪些設定引用。
- **重複類別選版本（使用者規則「看哪一份支援最多」）**：依序比實作的 CatVod 方法數（home／category／detail／search／player／live…）、qist 設定裡引用它的設定檔數、程式行數，取最大的一份。這是靜態的初步選擇；正式移植某個類別時，還要再確認篩選、搜尋、線路等實際功能。
- 連線檢查：主機取自 qist 設定的 `ext` 與類別原始碼的網址常數。pg 系列 JAR 的字串全部用循環 XOR 藏起來（`x.a(資料, 金鑰)`／`x.b(資料, 金鑰)`），先在電腦端靜態解開再取網址。每個主機用 Android UA 發 GET（10 秒逾時），有 HTTP 回應（含 401／403／404／405）就算「連得上」。**連得上不代表爬蟲能用**，只用來排優先順序。
- 腳本與原始結果留在 scratchpad（`analyze.py`、`probe.py`、`golden.py`、`rows.json`、`liveness.json`、`golden_results.jsonl`），不 commit。重複的 jadx 與 compat 邏輯已在 `scripts/audit_spider_jars.py`，這次沒有改它。

### 1.1 JAR

| 檔案 | 大小 | SHA-256（前 16） | spider 類別 |
|---|---:|---|---:|
| `XBPQ_upgraded.jar` | 659,007 | `598342d4588cc55c` | 15 |
| `XYQ.jar` | 393,490 | `ace8cb39979597ea` | 38 |
| `custom_spider.jar` | 266,777 | `646c5449e06bceea` | 40 |
| `fan.txt`（實際是 JAR，帶 `ftyguard_v7/v8.so`） | 1,254,310 | `10fdea77dc14ecc3` | 48 |
| `fty.jar`（**使用者排除**） | 640,982 | `c967eee542bb5dd8` | 66 |
| `pg23a94bb_upgraded.jar`（藏 6 個 .so：ffmpeg、磁力、迅雷 SDK） | 11,725,653 | `33a924d01062a5a8` | 153 |
| `pg_upgraded.jar` | 2,912,031 | `9e87df36ac8048c5` | 147 |
| `spider.jar` | 1,859,860 | `391065e92e19437e` | 113 |

## 2. 盤點結果（排除 `fty.jar` 後 270 個類別，129 個跨 JAR 重複）

- 沒有任何兩份重複的類別是相同版本；也沒有任何類別是 21 個基準的改名副本（IOS-POC-55 意義上的 `candidate`＝0）。
- 選用版本的大致傾向：`pg_upgraded.jar` 多半比 `pg23a94bb_upgraded.jar` 完整（例如 `Jable` 多了 `Config.addSingBoxSubConfigVod`）；`Bili`、`XBPQ`、`Ikanbot`、`SeedHub` 等以 `spider.jar` 最多；`XYQHiker`、`XPathMac`、`XPath`、`XYQBiu` 以 `XYQ.jar` 最多；`AppYsV2` 原本 `fty.jar` 最多，排除後用 `pg_upgraded.jar`。
- 只存在於 `fty.jar`、因此移除的 27 個類別：`Anime1`、`AppMr`、`Auete`、`Bttwoo`、`Cokemv`、`Ddrk`、`DouDou`、`Dovx`、`Itv`、`Jianying`、`Kunyu77`、`MLYS`、`MYYS`、`Mtv`、`Nmys`、`Opnxng`、`Qtv`、`SP33`、`SixV`、`Tangrenjie`、`Voflix`、`WoGG`、`XBiu`、`Xinsj`、`YTVIP`、`Ysgc`、`Zxzj`。這 27 個 qist 設定裡沒有站在用（以 `fty.jar` 為來源的站）。

| 群組 | 類別數 | qist 設定有站在用 | iOS 做法 |
|---|---:|---:|---|
| A 已支援（名稱已綁定） | 13 | 11 | 已能跑，實測見第 4 節 |
| H 一般影音站 | 125 | 81 | 逐個 JS 移植 |
| I 網頁嗅探 | 5 | 4 | 逐個移植，用既有 `MediaSniffer` |
| F 直播／體育 | 9 | 8 | 逐個移植 |
| G 音訊 | 2 | 2 | 逐個移植 |
| B `fan.txt` 的 `*Guard` 加密殼 | 45 | 37 | **不做**：邏輯在加密的原生 .so，靜態看不到 |
| C 網盤（阿里、夸克、UC、百度、115、PikPak、天翼、迅雷、123，及只回分享連結的搜尋站） | 51 | 37 | **不做**：要先有整套網盤功能（帳號登入、分享 token、轉碼），另立案 |
| D 本機／推送／WebDAV／Samba | 8 | 6 | **不做**：屬於 App 功能，不是站台 |
| E 磁力／BT | 6 | 5 | **不做**：需要 BT 引擎 |
| D2 輔助類別（`Config`、`Market`、`Proxy`、`Notice`、`JSDemo`、`XBPQParser`） | 6 | 2 | 不是站台 |

分類靠類別名稱與程式特徵，少數會分錯（例如 `TGYunPan`、`YunSo`、`YunPanOne` 歸在 H，實際較像網盤；`Danmu`、`Wallpaper` 不是影音站）。移植前逐個確認。

## 3. 階段 0：連線檢查（141 個可移植類別：F、G、H、I）

`*`＝qist 設定有站在用。

**連得上（105）**
- F：`Iktv*`、`Kanqiu*`、`Sports88*`、`SportsFeiqiu*`、`SportsGuazi*`、`SportsKafei*`、`Youtube*`
- G：`Kugou*`、`QingtingFM*`
- I：`Gaoqing*`、`Libvio*`、`SeHuaTang*`、`Taohuazu`、`Xinshijue*`
- H：`AmuBiliV2`、`AppLY*`、`AvTime*`、`Baiku*`、`Bdys`、`Bdys01*`、`BeiLeHu*`、`BiliYS*`、`BLSGod`、`Czsapp*`、`Danmu`、`Djuu*`、`Dm84*`、`Doll*`、`Douban*`、`Duanju`、`Duboku*`、`Eighteen*`、`FengYe*`、`FirstAid*`、`GuiGui*`、`Gulu*`、`Gxqvlj`、`Gz360*`、`Hanime*`、`Hdh*`、`Hdhive`、`Hxq*`、`Ikanbot*`、`Iqiyi`、`Jable*`、`JavBus*`、`JavDb*`、`Jianpian*`、`Jike*`、`Jiohub`、`Jojo`、`KuLe*`、`Kuwo`、`Mayiys*`、`MeijuMi*`、`Meijumi*`、`Miss*`、`MmYs`、`NanGua*`、`Netflav*`、`New6v*`、`NiNi*`、`Olevod`、`Ppxzy*`、`PTT`、`Qianfan*`、`QiShui`、`RenRen*`、`SaoHuo*`、`ShortHaokan*`、`ShortQimao*`、`ShortWeiguan*`、`ShortXingya*`、`ShuangXing*`、`Sou4K`、`SP360`、`Star*`、`TGYunPan*`、`TGYunPanLocal*`、`TingBokan*`、`TingJinxia*`、`TongQu*`、`Top888*`、`TuXiaoBei*`、`TZFile*`、`Wallpaper`、`Web1905*`、`Wobg*`、`Xb6v*`、`XBPQPlay`、`XiaoZhang*`、`XiaoZhiTiao*`、`Xojav*`、`YGP*`、`Yidong4K*`、`Ying*`、`YingSo*`、`Yinyuetai*`、`YouKu`、`Ysj*`、`YST*`、`YunDuo*`、`YunPanOne*`、`YunSo*`、`Zuise`

**連不上（19）**：`JustLive*`、`AiKan`、`AppRJ*`、`Clg`、`Ddys*`、`EightEight*`、`FourKHDR*`、`HuaDu`、`Kuaikan*`、`KubaCL`、`Maolv`、`MeijuTT*`、`Moli*`、`TingShijie*`、`TTian*`、`Xpanpan*`、`YingShi*`、`YQKan`、`YunPan*`（這次不移植；之後再測一次才判定）

**沒有固定主機（17）**：`ALLLive`、`AppFox`、`AppSy`、`AppYs`、`DDMJ`、`LvDou`、`Mp4Mov`、`PPMag`、`QQ`、`ShortHema*`（主機在 helper，`freevideo.zqqds.cn`）、`XPath*`、`XPathMac`、`XYQBiu`、`XYQBiuAL`、`XYQHikerAL`、`YD*`、`Yj1211`（多半是規則引擎，主機在規則檔或 `ext`）

## 4. 階段 1：不寫新 adapter

### 4.1 A 群在 qist 設定上的 live 實測

用既有 live golden（`SpiderGoldenTests.appGetDrivesTheWholeCatVodFlowAgainstTheLiveSite`：首頁→分類→詳情→搜尋→播放網址），每個「類別＋JAR」抽 1～3 個 `ext` 不同的站，站的 `ext` 照 qist 原樣（相對路徑以設定網址解析）。`AppYsV2`、以 `fty.jar` 為來源的站不測（前者 qist 設定沒有站用，後者使用者排除）；`橘汁` 是 IOS-POC-44G 已知的供應端錯誤，不測。

| 類別 | 站（設定／JAR） | 結果 | 原因 |
|---|---|---|---|
| XBPQ | fyyy、果果短剧（dianshi／spider.jar） | 通過 | |
| XBPQ | 面包影视（dianshi／spider.jar）；小白、BT天堂、布谷tv（0825／XBPQ_upgraded.jar） | 失敗 | 站方回驗證頁／防護頁（`challenge`、`verificationPage`），布谷網域查不到：外部 |
| AppYQK | 一起影视 | 通過 | |
| AppDrama | 天堂、华谊 | 通過 | |
| AppGet | 王子 | 通過 | |
| AppGet | 世界、魔方 | 失敗 | 主機連不上（外部） |
| Feiyu | 飞娱影视 | 通過 | |
| Jpys | 金牌影视 | 通過 | |
| JianPian | 荐片（dianshi／spider.jar、XYQ.json／XYQ.jar） | 通過 | |
| Bili | 0825／pg_upgraded.jar、0827／custom_spider.jar | 通過 | |
| Bili | 哔哩合集、哔哩哔哩音乐（dianshi／spider.jar） | 失敗 | `ext.cookie` 指向 `http://127.0.0.1:9978/file/…`（Android TVBox 本機檔案服務），iOS 沒有；adapter 遇到抓不到就整站失敗 |
| Bili | csp_Bili、csp_Bili幼儿（XYQ.json／XYQ.jar） | 失敗 | 首頁分類空：XYQ 版的 `ext` 格式和現有 adapter 不同 |
| App3Q | 马猴影视 | 失敗 | 詳情空：`ext` 是新版格式（`finger`／`sk`／`pkg`／`updateId`），現有 adapter 不認得 |
| App99 | 剧圈99、半日99 | 失敗 | `ext` 沒有 `appkey`，現有 adapter 要求它，init 直接放棄（請求網址變成相對路徑） |
| AppQi | 蓝鹰 | 失敗 | 首頁、分類正常，前 4 部都沒有可播的詳情：待查是變體還是站方 |
| XYQHiker | 哔嘀影视（XYQ.json／XYQ.jar） | 失敗 | 首頁正常，之後站方回驗證頁（`www.yjys02.com`）：外部 |
| XYQHiker | 影搜（XYQ.json／XYQ.jar） | 失敗 | 首頁分類空：待查規則格式 |

小計：28 次 A 群實測，12 次通過；16 次失敗裡 7 次是外部（連不上、防護頁、網域查不到），9 次是 adapter 與 qist 版本不同（App3Q、App99×2、AppQi、Bili×2〔XYQ 版〕、XYQHiker 影搜）或 iOS 缺本機檔案服務（Bili×2 cookie）。

### 4.2 alias：`spider.jar` 改名的 5 個類別

`ShortHema`／`ShortQimao`／`ShortHaokan`／`ShortWeiguan`／`SportsGuazi` 的特徵和基準「字串相同、結構不同」，不是 IOS-POC-55 的完全相同；但呼叫的主機與既有 adapter 相同（`freevideo.zqqds.cn`、`*.qmplaylet.com`、`sv.baidu.com`、`api.drama.9ddm.com`、`api.46d5umpk.com`）。依 IOS-POC-44C（`Jys→Jpys`）的做法，用該站自己的 `ext`（皆為 `null`）讓既有 adapter 跑完整 live golden：

| alias | 目標 | 經目標名稱 | 經 alias 名稱（改動後，`api` 不改寫） |
|---|---|---|---|
| ShortHema | HemaDJ | 通過 | 通過：55 集，m3u8／mp4 直連 |
| ShortQimao | QimaoDJ | 通過 | 通過 |
| ShortHaokan | HaokanDJ | 通過 | 通過：70 集（搜尋 0 筆，HaokanDJ 原本就是上游搜尋失效） |
| ShortWeiguan | WeiguanDJ | 通過 | 通過：34 集 |
| SportsGuazi | GuaziTY | 通過 | 通過：直播 m3u8 |

`ShortXingya` 連的是 `u.shytkjgs.com`、`app.whjzjx.cn`，跟 `WeiguanDJ` 不同，是另一套 API：**不加 alias**，留在階段 2。

### 4.3 改動

| 檔案 | 內容 |
|---|---|
| `ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift` | `ported` 加 5 個名稱；`aliases` 加 5 組（維持單行：`scripts/audit_spider_jars.py` 的 `registry_names` 用單行正規式讀它） |
| `ios/Tests/WebHTVCoreTests/SpiderGoldenTests.swift` | `registryClaimsOnlyWhatIsActuallyPorted` 名單加 5 個；改成逐一檢查 `SpiderRegistry.aliases` 每個 alias 載入的腳本與目標相同（取代原本只查 `Jys` 的一行） |

### 4.4 驗證

| 項目 | 方法 | 結果 |
|---|---|---|
| registry 與相關離線測試 | `swift test --filter 'registryClaimsOnlyWhatIsActuallyPorted\|SpiderPackTests\|ShortDramaSpiderTests\|RuntimePackManifestTests'` | 62／62 通過；Ponytail 修改後 `registryClaimsOnlyWhatIsActuallyPorted` 重跑通過 |
| 電腦端工具仍讀得到 registry | `registry_names()` | `ported` 28、`aliases` 7 組 |
| alias 端到端 | 5 個 qist 站以原本的 `csp_Short*`／`csp_SportsGuazi` 跑 live golden | 5／5 通過 |
| Ponytail | `ponytail:ponytail-review` 最終 diff | 1 項（測試改用 `SpiderRegistry.aliases`，-3 行）已套用 |

**未驗證**：iOS Simulator、真機都沒跑；App 介面上加 qist 設定網址後的列表與播放沒看過。沒有發版。

### 4.5 加 qist 設定後的覆蓋（只算名稱，不代表能用）

排除 `fty.jar` 與外部 JAR（`367.json` 等用的 `moyu*.php`），qist 設定共 632 個 `csp_` 站，App 認得類別名稱的有 115 個：`dianshi.json` 39／102、`jsm.json` 39／102、`XYQ.json` 20／42、`0825.json` 16／106、`0827.json` 1／26；`0821`、`0826`、`fty.json`（全部 `fan.txt` 加密殼）、`9918`、`99188`、`js.json` 是 0。實際能用的比例看第 4.1 節。

## 5. 回滾

一個 commit。`git revert` 後 5 個名稱回到「尚未移植」，其他行為不變。

## 6. 階段 2 建議（待使用者決定）

1. **2A：A 群 adapter 變體**（影響最多 qist 站，不新增類別）：`App99` 沒有 `appkey` 的版本、`App3Q` 新版 `ext`、`Bili` 的 cookie 抓不到時改為不帶 cookie，以及 `Bili` 的 XYQ 版 `ext`、`AppQi` 蓝鹰、`XYQHiker` 影搜規則。每項先照 qist 的 JAR 版本核對原版邏輯，再決定是補參數還是另做 adapter。
2. **2B 之後：連得上且有站在用的 H／I／F／G 類別**，每批 5～8 個，依 `dianshi.json`／`0825.json` 的站數排序。成人類照使用者決定一起排。
3. 不做：B、C、D、D2、E 群（第 2 節）；C 網盤與 D 網路儲存之後可另立案。

## 7. 狀態

- 2026-10-06 16:40～16:55：盤點、使用者確認範圍（iOS、加 qist 設定網址、成人類一起做、先做階段 0＋1、排除 `fty.jar`）。
- 2026-10-06 16:55～17:05：階段 0、階段 1 完成；alias 已加，等使用者決定階段 2。
- 2026-10-06 17:05～18:20：使用者「開始做 2A」；2A 完成（第 8 節）。
- 2026-10-07 14:15～2026-10-08 上午：第一輪審查 3 項成立並修正；審查追加的 P2（測試並行時取錯請求）也修正（第 9 節）。
- 2026-10-08 09:58～：使用者同意先修第 8.5 節第 2 項（Bili 分集標題含 `$`／`#`），第 10 節。

## 8. 階段 2A：A 群在 qist 設定上的 adapter 變體（Task-Guard `IOS-POC-57A`，`standard`，基準 `91364cd6`）

### 8.1 每項查證（17:05～17:40 CST）

| 項目 | qist 原版（反編譯）對照 | 結論 |
|---|---|---|
| App99（剧圈99、半日99、双星99） | `spider.jar` 版的 `init` 不要求 `appkey`；`g()` 的簽章是 `sha256(body:timestamp:nonce:token)`（四段），header 不送 `appkey`；`version` 預設 `versionName`。回應解密後是 zlib：照原版重做（python3＋openssl），`systemInit`、`/vod/search` 都回 zlib，而 host 的 `aesDecryptIV` 早已自動解壓（`CryptoHost.ivPrefixed`） | **改 JS**；不用改 host |
| App3Q（马猴影视） | 原版邏輯與現有 JS 相同；照原版重做請求，首頁、分類正常，`get_detail` 不論 time／nonce／`x-update-id` 都回 HTTP 403「请求异常，请重启应用后重试」 | 站方問題，**不改**（原版送的請求一樣會被拒） |
| AppQi（蓝鹰） | 原版邏輯與現有 JS 相同；照原版重做，`vodDetail` 回 `code 1`，但前 3 部的 `vod_play_list` 都是空的 | 站方問題，**不改** |
| Bili（`spider.jar`） | `ext.n` 選用原版寫死的 6 份首頁（哔哩合集／听书／戏曲／相声／小品／音乐）；`ext.cookie` 是 `http://127.0.0.1:9978/file/…`（TVBox 本機檔案服務）。原本的失敗：不支援 `ext.n` → 首頁空 → 空頁面被歸因到 init 時失敗的 cookie 請求 | **改 JS** |
| Bili（`XYQ.jar`） | `ext` 是字串 `./biliext/*.json`，內容 `{"cookie":"clan://…","classes":[…],"filter":{…}}`；原版抓這份 JSON 當首頁 | **改 JS** |
| XYQHiker 影搜 | 規則只有搜尋，結果是阿里雲盤分享連結 | 屬網盤（C 群），**不做** |
| XYQHiker 另外 5 站 | 农民影视（網域查不到）、七新影视（404）、可可影视（850）都是站方；兔小贝的規則是「分类截取模式 0」（JSON）＋「分类Json数据二次截取」`jsonp(&&);`，現有 `XYQHiker.js` 分類只有 HTML 模式；河马短剧只有一個 `type_id` 0 的分類，golden 會跳過 0（測試條件，不代表 App 不能用） | 兔小贝要補規則引擎的 JSON 分類模式：**另列後續**（第 8.5 節） |

### 8.2 改動

| 檔案 | 內容 |
|---|---|
| `ios/Sources/WebHTVCore/Resources/Spiders/App99.js` | `appkey` 不再是必要欄位；沒有 `appkey` 時，簽章用四段、不送 `appkey` header、`version` 預設 `versionName`。有 `appkey` 的站行為不變 |
| `ios/Sources/WebHTVCore/Resources/Spiders/Bili.js` | `BUILTIN`：原版 6 份首頁（哔哩合集拿掉需要登入帳號的 我的关注／最新动态／历史记录，剩 20 類）；`ext.n` 命中就用它；`ext` 是網址字串時抓 `{classes, filter}` 當首頁，並讀它的 `cookie`；cookie 是 `127.0.0.1`／`localhost`／`clan://` 時不抓、改用匿名 buvid3 |
| `ios/Tests/WebHTVCoreTests/ShortDramaSpiderTests.swift` | 2 個離線測試：App99 兩種簽章；Bili 的 `ext.n`、XYQ 版 `ext`、本機 cookie 不被請求、`clan://` 改用匿名 cookie。stub 加上 `api.bilibili.com`、`127.0.0.1` 兩個主機 |
| `spider-pack/` | 重建為 `2026-10-06.4`：只有 App99、Bili 兩支腳本與版本號不同（`mappings: []` 照舊）；**未發布** |

### 8.3 驗證

| 項目 | 方法 | 結果 |
|---|---|---|
| qist App99 | live golden：剧圈99、半日99、双星99（dianshi） | 3／3 通過（m3u8／flv 播放網址） |
| qist Bili | live golden：哔哩合集、哔哩哔哩音乐、哔哩哔哩听书、少儿教育（dianshi／spider.jar）、csp_Bili、csp_Bili幼儿（XYQ.json／XYQ.jar） | 6／6 通過；Ponytail 修改後哔哩合集再跑一次也通過 |
| `wang-movie.json` 回歸 | live golden：App99 剧圈99、听心99、橙子99、双星99；Bili bili、bilitingshu、bilimanhua、biligequ | 剧圈99、听心99、bili、bilimanhua、biligequ 通過。橙子99、双星99 主機逾時（站方）。bilitingshu 失敗：今天列表第一部的分集標題含 `#`（`《似水小弟》#七猫小说…`），把 CatVod 的集數切壞。走的是 `ext.json` 路徑、詳情程式沒動，**是原本就有的問題**（第 8.5 節） |
| 離線 | `ShortDramaSpiderTests`、`SpiderHostTests`、`SpiderPackTests`、`SourceClientTests`、`ContractFreezeTests`、`RuntimeABITests`、`registryClaimsOnlyWhatIsActuallyPorted` | 84／84 通過；Ponytail 修改後相關 49 個重跑通過 |
| 突變 | App99 一律帶 `appkey` 簽；拿掉 Bili 的本機 cookie 判斷 | 2／2 被抓到（3 個斷言失敗），之後已還原 |
| 相容包 | `spider_pack.py verify --url spider-pack`；App99、Bili 與內建腳本逐位元組相同 | 21 支、0 問題 |
| Ponytail | `ponytail:ponytail-review` 最終 diff | 1 項（刪掉 Bili 一行用不到的 `ext` 型別檢查）已套用 |

**未驗證**：Simulator、真機都沒跑；App 介面加 qist 設定後的畫面沒看過。沒有發版。

### 8.4 回滾

一個 commit。`git revert` 後 App99 回到一定要有 `appkey`、Bili 回到只認 `ext.json`；`spider-pack/` 一起回到 `2026-10-06.3`。

### 8.5 後續候選（未做，待使用者決定）

1. **XYQHiker 的 JSON 分類模式**（「分类截取模式 0」＋「分类Json数据二次截取」）：qist 的兔小贝要用。這會改動規則引擎，影響所有 XYQHiker 站，要先對照 `XYQ.jar` 原版的實作。
2. **Bili 分集標題含 `$`／`#`**：`wang-movie.json` 的 bilitingshu 今天就踩到。原本就有的問題，修法是詳情組集數時把這兩個字元換掉（`acceptedQualities` 已經這樣處理線路名稱）。由 IOS-POC-57A-2 處理（第 10 節）。
3. **2B：移植新類別**：依第 3 節「連得上＋有站在用」的清單，每批 5～8 個。

### 8.6 設計研究、方案比較與驗收條件（2026-10-07 補記，IOS-POC-57A-1）

2A 實作前只有第 6 節的建議和第 8.1 節的查證，缺 AGENTS.md 研究關卡要求的來源釘選、證據等級、方案比較與驗收條件。本節依 2026-10-06 已取得的證據補記，**不是實作前完成的紀錄**。qist 的爬蟲不是播放器依賴，不走第 8 節的 upstream-integration-governor；適用的是第 7 節對相容性需求的研究關卡。

**來源**：2026-10-06 16:41～17:18 CST 經 GitHub contents API（`ref=master`）與 raw 取得。當時沒有記下 qist 的 commit，改以下載檔的 Git blob SHA（與 API 回傳的相同）和 SHA-256 釘選內容。

| 來源 | 版本釘選 | 證據等級 | 支持的結論 | 對決策的影響 |
|---|---|---|---|---|
| [qist/tvbox `jar/spider.jar`](https://github.com/qist/tvbox/blob/master/jar/spider.jar) 的 `App99`、`Bili` | blob `94fe284cc245b400e8a3503e23d1187774d19fa8`；SHA-256 `391065e92e19437e73109e9d3c79feff6676baa8ed4fec3cdb04f4e7cca77314` | 一手：qist 設定實際載入的發布產物（jadx 反編譯） | App99 `init` 不要求 `appkey`，`g()` 簽四段，header 不送 `appkey`，`version` 預設 `versionName`；Bili 以 `ext.n` 選 6 份內建首頁，`ext.cookie` 指向 `127.0.0.1:9978` | App99 四段簽章；Bili `BUILTIN` 的內容；本機 cookie 不抓 |
| [qist/tvbox `jar/XYQ.jar`](https://github.com/qist/tvbox/blob/master/jar/XYQ.jar) 的 `Bili` | blob `9d13b15af5965165d3f356051e2e0b7351c4f4eb`；SHA-256 `ace8cb39979597eaa8121b540994a31d9b78ebe965613d13dad6a3da07003137` | 一手（同上） | `ext` 是 `./biliext/*.json` 網址，內容 `{cookie, classes, filter}`，cookie 是 `clan://` | URL 型 `ext` 當首頁；`clan://` 不抓 |
| qist/tvbox `dianshi.json`、`XYQ.json` | blob `dd835a21d812a5a72d162126cd7823000c03407e`、`b9b77924ef8045af1dae9eec5443bf8dc0eecfac`（依下載內容計算） | 一手 | 哪些站用哪份 JAR、`ext` 的實際格式 | 測試用的站與 `ext` 樣本 |
| 照原版重做的請求（第 8.1 節；腳本在 session scratchpad，未 commit） | 2026-10-06 17:05～17:40 | 一手實測，結果會隨站方變動 | 四段簽章的請求得到加密的 zlib 回應；App3Q 詳情 403、AppQi 播放清單空 | App99 不必改 host；App3Q、AppQi 不改 |
| WebHTV 既有移植的來源 `river-fman.jar`（`spider-pack/manifest.json` 的 `jarSha256` `3133519d…`；`docs/IOS-POC-5L-appqi-app99-app3q-bili.md`） | 同左 | 一手：相關版本 | 帶 `appkey` 的五段簽章；`ext.json` 首頁 | 這兩條路徑要保持不變 |

**證據類別**
- 上游原始碼／提交／測試：用了上表的 qist JAR。qist 只發布編譯後的 JAR，沒有這些類別的原始碼、提交歷史或測試。
- 官方規格與文件：不適用。CatVod／TVBox 的 `ext` 沒有規格文件，反編譯的 JAR 就是事實上的規格（與 IOS-POC-55 第 1 節的判斷相同）；bilibili 網頁 API 沒有公開的官方文件。
- 上游 PR／issue／revert／維護者討論：未查。qist/tvbox 只轉發 JAR，沒有對應這段邏輯的 PR 或提交；相容的目標是 qist 設定實際載入的那份 JAR，討論內容不會改變這個目標。
- 成熟相關專案的程式：用了 WebHTV 既有移植所根據的 `river-fman.jar`（上表最後一列）當另一個版本的對照；其他 TVBox fork 未查，理由同上。
- 論文、技術文章、benchmark、實地報告：論文與 benchmark 不適用（協定相容問題，沒有演算法或效能取捨）；實地證據是第 8.1 節照原版重做的請求與第 8.3 節的 live golden。

**2A 之前的實作**
- `App99.js` 的 `init` 缺 `appkey` 就 `return ''`；`headers()` 固定五段簽章並送 `appkey`。
- `Bili.js` 的 `init`／`homeContent` 只認 `ext.json`；`ext.cookie` 是網址就去抓，包含 `127.0.0.1`。
- 呼叫端：`SpiderRegistry.ported`（`ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift:47`）以類別名稱綁定腳本，`CSPSourceResolver`（`ios/Sources/WebHTVCore/Spider/CSPSourceResolver.swift:11`）經由它取腳本，`spider-pack/` 可覆蓋同名腳本。`wang-movie.json` 的 App99 4 站（帶 `appkey`）、Bili 4 站（`ext.json`）與 qist 的站共用同一支腳本。
- 既有防護：`CryptoHost.ivPrefixed`（`ios/Sources/WebHTVCore/Spider/Host/CryptoHost.swift:182`）解密後自動解壓 zlib；離線測試 `ShortDramaSpiderTests`；live golden `SpiderGoldenTests`。

**方案比較**

| 方案 | App99 | Bili | 取捨 |
|---|---|---|---|
| 不改 | qist 3 站 init 就失敗 | qist 6 站首頁空；`127.0.0.1` 的 cookie 請求失敗後被當成失敗原因 | 沒有回歸風險，但使用者加 qist 設定後這些站不能用，不符需求 |
| 照原版（不修改） | iOS 不能執行 JAR。最接近的是另寫一支照抄 qist 版的腳本，但 registry 只看類別名稱，要依 JAR 選腳本得靠 IOS-POC-55 的對應機制，而且兩份程式幾乎相同 | 原版從 TVBox 本機檔案服務（`127.0.0.1:9978`）或 `clan://` 拿 cookie，iOS 兩者都沒有，做不到 | 做不到，或維護成本高 |
| **WebHTV 適配（採用）** | 同一支腳本：沒有 `appkey` 就簽四段、不送 header、`version` 用 `versionName`；有 `appkey` 完全照舊 | `ext.n` 用內建的 6 份首頁（拿掉 3 個需要登入的分類）；URL 型 `ext` 抓 `{classes, filter}`；本機與 `clan://` 的 cookie 不抓，用匿名 `buvid3` | 見下 |
| 另做 cookie 匯入介面 | — | 讓使用者在 App 貼 bilibili cookie | 是新功能（帳號資料），超出 2A；需要時另立案 |

採用方案的取捨：
- 正確性：照反編譯的 qist 版本。相容性：帶 `appkey` 與 `ext.json` 的路徑不變，離線測試鎖住。
- 效能：XYQ 版的站 init 多一次請求（逾時 20 秒）。畫質：匿名 cookie 拿不到 qn 80 以上，與原版未登入時相同。
- 安全：不對設定指定的本機位址發 cookie 請求。維護：兩支腳本各多一處分支；`BUILTIN` 是照抄的資料。
- 驗證：離線測試＋live golden。推出與回滾：沒有發版；`git revert` 一個 commit，相容包版本跟著回去（第 8.4 節）。

決定：採用 WebHTV 適配，保留 qist 的行為，修正 iOS 上不存在的本機依賴。使用者 2026-10-06 以「開始做 2A」核准，第 8.1 節逐項查證後實作。

**驗收條件**（證據見第 8.3 節與第 9 節）
1. App99 的 `ext` 沒有 `appkey`：init 不放棄；`sign = sha256(body:timestamp:nonce:token)`；不送 `appkey` header；`version` 預設 `versionName`。
2. App99 的 `ext` 有 `appkey`：五段簽章、送 `appkey`、`version` 預設 `0b4328287a5d953e`，和改動前相同。
3. Bili 的 `ext.n` 對到內建首頁時用內建的；哔哩合集 20 類，不含 我的关注／最新动态／历史记录。
4. Bili 的 `ext` 是網址字串時，抓 `{cookie, classes, filter}` 當首頁並讀它的 cookie。
5. Bili 的 cookie 網址主機是 `127.0.0.1` 或 `localhost`（後面接 `:`、`/`、`?`、`#` 或結尾），或是 `clan:`：不發請求，改用匿名 `buvid3`。其他 http(s) cookie 網址照舊抓取（邊界在第 9 節補齊）。
6. 只用 `ext.json` 的 Bili 站行為不變。
7. `spider-pack/` 的 App99、Bili 與內建腳本逐位元組相同，manifest 的 sha256 相符，`spider_pack.py verify` 0 問題。
8. 不在範圍：App3Q、AppQi（站方問題）、XYQHiker 影搜（網盤）。

## 9. 2A 第一輪審查修正（Task-Guard `IOS-POC-57A-1`，`quick-fix`，基準 `c7512240`）

### 9.1 審查意見與處置（2026-10-07～08）

| # | 意見 | 核對 | 處置 |
|---|---|---|---|
| 1 | Bili 本機 cookie 判斷 `[:/]` 只接受主機後接冒號或斜線 | 成立：node 實測 `http://127.0.0.1`、`https://localhost`、`http://localhost?x=1` 都是 false，會落到抓取分支 | 改成 `([:/?#]\|$)`；補測試 |
| 2 | 2A 缺研究關卡的來源釘選、證據類別、方案比較、驗收條件 | 成立（AGENTS.md 第 7 節的相容性需求；不是第 8 節的播放器依賴） | 補第 8.6 節 |
| 3 | `App99.js` 檔頭仍寫固定五段簽章；`Bili.js` 檔頭仍寫只支援 4 個 `ext.json` 站 | 成立 | 只改檔頭，鏡像同步 |
| P2 | 新測試的「搞笑」搜尋與既有測試的「球星」搜尋並行，共用 `ShortDramaSite.asked`；既有測試取路徑的 `.last`，可能拿到 `SESSDATA=remote` | 成立：修正前重複執行，既有測試在第 93 輪的匿名 `buvid3` 斷言失敗 | 既有測試改以 `keyword=球星` 挑自己的請求 |

### 9.2 改動

| 檔案 | 內容 |
|---|---|
| `ios/Sources/WebHTVCore/Resources/Spiders/Bili.js` | 本機 cookie 判斷改為 `/^https?:\/\/(127\.0\.0\.1\|localhost)([:/?#]\|$)/i`；註解與檔頭（三種首頁來源） |
| `ios/Sources/WebHTVCore/Resources/Spiders/App99.js` | 檔頭補四段簽章的版本（只改註解） |
| `ios/Tests/WebHTVCoreTests/ShortDramaSpiderTests.swift` | stub 加 `requests(host:)`、攔截 `localhost`；新測試 `biliFetchesNoCookieURLOnALocalHostButStillFetchesARemoteOne`；既有 Bili 測試以 keyword 挑請求 |
| `spider-pack/` | 重建為 `2026-10-07.1`：只有 App99、Bili 兩支腳本與 sha256、版本號不同（`mappings: []` 照舊）；**未發布** |
| 本文件、`docs/current-task-state.md` | 第 8.6 節、本節、交接 |

### 9.3 驗證

| 項目 | 指令 | 結果 |
|---|---|---|
| 新測試在舊 regex 下失敗 | `swift test --package-path ios --filter biliFetchesNoCookieURLOnALocalHostButStillFetchesARemoteOne` | 失敗 2 項：`127.0.0.1`、`localhost` 被請求；遠端 cookie 的斷言通過 |
| 新 regex 的邊界 | node 直接測 | 本機主機單獨、帶 port／路徑／query／fragment、大寫 → 是；`localhost.evil.com`、`127.0.0.1.nip.io`、`localhost.invalid` → 否 |
| 聚焦測試 | `swift test --package-path ios --filter 'ShortDramaSpiderTests\|SpiderPackTests\|RuntimePackManifestTests\|registryClaimsOnlyWhatIsActuallyPorted'` | 65／65 通過（P2 修改前） |
| P2 重現與修正 | `swift test --package-path ios --filter 'biliServesQistsBuiltInAndXYQHomesWithoutFetchingTVBoxsOwnCookieFile\|biliFetchesNoCookieURLOnALocalHostButStillFetchesARemoteOne' --maximum-repetitions 500 --repeat-until fail` | 修正前：既有測試第 93 輪失敗；修正後：兩個測試各 500 輪通過 |
| 檔案全部測試 | `swift test --package-path ios --filter ShortDramaSpiderTests` | 17／17 通過（P2 修改後） |
| 相容包 | `python3 scripts/spider_pack.py verify --url spider-pack` | 21 支、0 問題 |
| Ponytail | `ponytail:ponytail-review` 最終程式 diff；審查者另行複查 | 0 項（Lean already）；審查者也未見需刪除的複雜度 |

**未驗證**：Simulator、真機、iOS App build 都沒做；live golden 沒重跑；完整 `swift test` 沒跑；P2 修改後沒有重跑 65 個那組（P2 只改這個測試檔，已由 17／17 涵蓋）；`[::1]` 與其他 `127.x` 位址照舊會發請求（不在 B5 範圍）。沒有發版。

### 9.4 回滾

一個 commit。`git revert` 後 regex 回到 `[:/]`，檔頭與測試回到 2A 版本，`spider-pack/` 回到 `2026-10-06.4`。

## 10. Bili 分集標題含 `$`／`#`（Task-Guard `IOS-POC-57A-2`，`quick-fix`，基準 `50b31b79`）

- 問題：`detailContent` 直接用 bilibili 的分集標題 `page.part` 組 CatVod 播放清單。標題含 `#` 會多切出集數，含 `$` 會把標題後半當成網址（第 8.3 節 `wang-movie.json` bilitingshu 的 `《似水小弟》#七猫小说…`）。App 的 `Episode.parse`（`ios/Sources/WebHTVCore/CMSClient.swift:327`）在括號外的 `#` 切集數、以第一個 `$` 分開名稱與網址；這個標題的 `#` 在 `》` 之後，照樣被切。
- 改動：`Bili.js` 的 `detailContent` 對分集標題沿用 `acceptedQualities` 的處理：`$`、`#` 換成空白後 trim，空了就用原本的 `P<頁碼>`。代價是標題裡的這兩個字元顯示成空白。`spider-pack/` 重建為 `2026-10-08.1`（只有 Bili 與版本號不同，`mappings: []` 照舊），**未發布**。
- 測試 `biliPageTitlesCarryingCatVodSeparatorsKeepEveryEpisodeAndAddress`：分集標題 `《似水小弟》#七猫小说`、`第2集$番外`、`普通标题`、`#$`，兩個畫質；經 `CMSResponse`＋`Vod.flags`（App 實際的解析）檢查線路名稱，以及每條線 4 集的名稱與 `aid+cid+qn`。

| 項目 | 指令 | 結果（log 在 session scratchpad） |
|---|---|---|
| 新測試在舊版失敗 | `swift test --package-path ios --filter biliPageTitlesCarryingCatVodSeparatorsKeepEveryEpisodeAndAddress` | 失敗 4 項：兩條線的集數名稱與網址（`57A-2-red.log`） |
| 回歸（一次） | `swift test --package-path ios --filter 'ShortDramaSpiderTests\|SpiderPackTests\|RuntimePackManifestTests\|registryClaimsOnlyWhatIsActuallyPorted'` | 66／66 通過（`57A-2-regression.log`） |
| 相容包 | `python3 -I scripts/spider_pack.py build --out spider-pack --version 2026-10-08.1 --mappings <scratchpad>/empty-mappings.json`；`python3 -I scripts/spider_pack.py verify --url spider-pack` | 21 支、0 問題；Bili 鏡像與內建腳本相同（`57A-2-pack-build.log`、`57A-2-pack-verify.log`） |
| Ponytail | `ponytail:ponytail-review` 程式 diff | 0 項 |

- 未驗證：Simulator、真機、live golden（bilitingshu 實際的標題）都沒跑；完整 `swift test` 沒跑。
- 審查：2026-10-08 Codex 唯讀審查 PASS（Spec、Standards、Ponytail 都沒有 finding）。
- 回滾：一個 commit。`git revert` 後標題回到原樣，`spider-pack/` 回到 `2026-10-07.1`。
