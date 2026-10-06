# IOS-POC-57 — qist/tvbox `jar/` 的爬蟲盤點與移植

## Recovery anchor

- 目標（使用者 2026-10-06）：把 <https://github.com/qist/tvbox/tree/master/jar> 的全部爬蟲加進 **iOS App**。同一個類別出現在多份 JAR 時，「看哪一份支援最多」；**`fty.jar` 不用支援**；成人類**一起做**；站台由使用者在 App 裡加 qist 的設定網址（例如 `https://raw.githubusercontent.com/qist/tvbox/master/dianshi.json`）取得，不改 `wang-movie.json`。
- iOS 不能執行 JAR（Android DEX），每個類別都要用 JS adapter 重寫，或證明與既有 adapter 相同後加 alias。所以分階段：階段 0 盤點＋連線檢查，階段 1 不寫新 adapter（實測已支援的類別、加 alias），階段 2 起每批 5～8 個移植。
- Task guard：`IOS-POC-57`（`standard`），基準 `1174be8101ae63adcb7f0ba345e5311711992fd0`。路徑：本文件、`docs/current-task-state.md`、`ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift`、`ios/Tests/WebHTVCoreTests/SpiderGoldenTests.swift`。
- 狀態（2026-10-06 17:05 CST）：階段 0、階段 1 完成。5 個 alias（`ShortHema`、`ShortQimao`、`ShortHaokan`、`ShortWeiguan`、`SportsGuazi`）已加，離線與 live 都通過。**沒有發版**；Simulator／真機都沒跑。
- 唯一下一步：等使用者決定階段 2 的第一批（建議見第 6 節：先修 A 群在 qist 設定上失敗的 adapter 變體）。

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
