# IOS-POC-44 — `wang-movie.json` 可以移植、還沒做的 `csp_*` 站（assessment）

## Recovery anchor

- 目標：使用者 2026-10-02「開始 IOS-POC-44 assessment」。對象是 `docs/current-task-state.md`「Current handoff — 2026-10-02 下午」列的 23 站（19 個類別）：可以移植、iOS 還沒有 port 的 `csp_*` 站。
- 範圍：只做 assessment，**不改程式**。task guard `IOS-POC-44`（`assessment`），路徑：本文件、`docs/current-task-state.md`、`docs/CSP_PORTABILITY_MATRIX.md`。探測腳本與回應都在 session scratchpad，不 commit。
- 結論：23 站裡 **18 站後端今天活著、5 站死了**。活著的 18 站裡 13 站只要寫 JS，不必改 Swift；3 站（AppDrama×2、Uvod）要先在 host 補 RSA 和二進位 HTTP；Douban×2 要另做 App 功能。建議與分段見第 7 節，待決定事項見第 9 節。
- 44A（`WeiguanDJ`＋`HemaDJ`）見第 11 節；44B（`QimaoDJ`＋`HaokanDJ`）見第 12 節；44C（`Jpys`＋`Jys`）見第 13 節；44D（`Feiyu`＋`MiaoWu`）見第 14 節；44E（`AppYQK`＋`AppYsV2`）見第 15 節；44F（`GuaziTY`＋`MoDu`）見第 16 節。44A～44F 六段都已完成。44D～44F 還沒發版，真機未驗證。
- 唯一下一步：等使用者決定下一段（第 7 節的 44G：host 補 RSA／hex／二進位 HTTP 後做 `AppDrama`＋`Uvod`，要發新版 App）；沒有核准不改程式。`QmdjAmns`／`HHkkAmns` 的 alias（第 6 節、第 9 節第 2 項）仍待使用者決定。

## 1. 問題與範圍

- `docs/CSP_PORTABILITY_MATRIX.md` 是 2026-09-16 的靜態分析，只看程式能不能移植，沒看站還在不在。2026-10-02 用當天的 `wang-movie.json` 對照，未提供的 `csp_*` 站有 58 站：**可移植 23 站**、原生保護（H）34 站、不在矩陣裡 1 站（`AppV6`）。這和 `docs/CSP_MIGRATION_STATUS.md` 的「portable, not yet ported：19 類、23 站」一致。
- 這份文件回答三件事：23 站今天哪些活著；每類要多少工作、要不要補 host 能力；先做哪些。

## 2. 方法（2026-10-02 16:15～16:55 CST，台灣家用網路）

- 設定：當天從 `gitlab.com/st7833232/recha` 下載的 `wang-movie.json`（127,425 bytes）。
- JAR：`river-fman.jar`（md5 `ca48f92e…`，與設定一致）、`custom_spider.jar`（`5e53c8f9…`，一致）、`xiaosa-0807.jar`（**`d8f71fc8…`，設定寫的是 `4d263271…`**，表示 JAR 在設定檔之後更新過）。19 個類別的行數都和矩陣一致。以 jadx 反編譯後完整讀過。
- 探測：照 Java 的請求格式（UA、header、簽章、加密）用 python3／curl／openssl 重做，從首頁或分類開始，盡量一路做到詳情、播放網址，再抓媒體的第一段 bytes。加密回應都解開確認是真的資料。連不上的重試一次才判定死站。
- 分工：AppDrama 由我探測；A／B 類 10 個類別、C 類其餘 8 個類別交給兩個 subagent 探測，我抽查了它們存下來的回應檔，內容與回報一致。
- 限制：站況每小時在變；連不上的站，可能是只限中國大陸連線，也可能已經下線，無法區分；**全部是 Mac 上的探測，沒有在 iOS 跑過**。

## 3. 結果總表（23 站）

「活」＝實際請求一路拿到媒體；「部分」＝部分端點壞；「死」＝連不上或伺服器拒絕。工時是 AI agent 的估計，不含 sweep 與發版。

| 類別 | 站 | 類 | 後端 | 加密／host 缺口 | 播放 | 2026-10-02 實測 | JS 行數 | 工時 |
|---|---|---|---|---|---|---|---:|---:|
| `WeiguanDJ` | 围观短剧 | C | `api.drama.9ddm.com` | 無加密；**不缺** | 直接 mp4，多畫質 | **活**：標籤、搜尋、詳情 30／30 集、mp4 206 | ~90 | 1 |
| `HemaDJ` | 河马短剧 | A | `freevideo.zqqds.cn` | AES-128-CBC（UTF-8 鍵）；**不缺** | 直接 mp4 | **活**：5 個端點都解得開，mp4 206 | ~150 | 1.5 |
| `QimaoDJ` | 七猫短剧 | B | `neptune.qmplaylet.com` 取網域 | md5 簽章＋base64 字元替換；**不缺** | 直接 m3u8 | **活**：網域、首頁、分類、詳情 80 集、搜尋，m3u8 206 | ~140 | 1.5 |
| `HaokanDJ` | 好看短剧 | A | `sv.baidu.com` | 無；固定 cookie；**不缺** | 直接 mp4（http） | **部分**：首頁、分類、詳情 70 集、播放可以；**搜尋回空**（「猜空了」） | ~110 | 1 |
| `Jpys` | 金牌影视 | C | ext 6 個鏡像，取第一個 HEAD 通的 | sha1(md5(…))；**不缺** | 直接 m3u8 | **活**：整條路通，`.ts` 200。鏡像 5／6 通（`m.sizhengxt.com` 被 WAF 擋） | ~130（兩類共用） | 1.5（兩類合計） |
| `Jys` | 異界 | C | ext `www.ndhfiohk.com` | 同 Jpys；**不缺** | 直接 m3u8 | **活**：整條路通（和 Jpys 同一套後端） | +10 | （含在上一列） |
| `Feiyu` | 飛魚 | C | `4kyszx.top` | HMAC-SHA256 兩層；**不缺** | `parseApi` 空就直接播 | **活**：全部 200，簽章錯回 403；5 條線 4 條 m3u8 200 | ~120 | 1.5 |
| `MiaoWu` | 喵呜动漫 | C | DoH TXT 解出 `app.nyafun.vip` | AES-256-ECB（UTF-8 鍵）；**不缺** | 直接，或 POST `vod/parse` | **活**：DoH、設定、篩選、詳情、解析、搜尋都解得開，m3u8 200 | ~130 | 1.5 |
| `AppYQK` | 一起影视 | B | `yzy0916.n0z6fkpuk.com` | md5 簽章；**不缺** | 多畫質 m3u8 | **活**：全部端點有資料，m3u8 200；超清「APP独享」，只有标清能播 | ~150 | 1.5 |
| `AppYsV2` | 奴娜 | A | ext `www.nntv.in/api.php/v1.vod` | 無；**不缺**（只做 `.vod` 方言） | 直接 m3u8 | **活**：類型、列表、詳情、搜尋、排行，m3u8 200 | ~180 | 2～3 |
| `GuaziTY` | 瓜子体育 | A | `api.46d5umpk.com` | AES-128-CBC（UTF-8 鍵）；**不缺** | 直播 m3u8 | **活**：解出 40／36／40 場賽事，直播中那場 m3u8 200 | ~90 | 1 |
| `MoDu` | 魔都动漫 | A | `www.mdzyapi.com`（苹果CMS JSON） | 無；**不缺** | 直接 m3u8 | **活**：列表、詳情、搜尋，m3u8 200 | ~70 | 0.5 |
| `Wwys` | 农民影视 | A | ext `vip.wwgz.cn:5200` | 無加密；選擇器用 XOR 混淆過（已解）。**`host.js` 不支援 `:nth-child()`**，要改寫成 `:eq` 或正則 | 集數網址本身就是 m3u8 | **活**，但第 1 條線的 HLS 分段是**偽裝成 PNG 的 TS**（前 107 bytes 是 PNG 標頭），AVPlayer 能不能播未驗證 | ~130 | 1.5～2 |
| `AppDrama` | 天堂、苹果 | C | ext `site` 檔取網域（兩站同一台後端） | **缺**：RSA PKCS#1 公鑰加密、AES 輸出 hex、HTTP 傳收二進位（protobuf） | 直接 m3u8 | **活**：分類 21 筆、詳情 63 集、搜尋 18 筆、播放網址，m3u8 200。初始化握手回「RSA解密失败」，但原版也忽略這個錯誤，之後照常可用 | ~250＋Swift ~60 | 3 |
| `AppDrama` | 橘汁 | C | `juziapp.hzhcbkj.cn` | 同上 | — | **死**：首頁分類可以，列表回「二级私钥为空,请配置」（對方伺服器設定問題） | （同上） | — |
| `AppDrama` | 薯条 | C | `site` 檔在 `…cos.ap-guangzhou.myqcloud.com` | 同上 | — | **死**：網域檔主機 DNS 解析到 `0.0.0.1`（被封），而且 `host` 是空的，沒有備援 | （同上） | — |
| `Uvod` | Uvod | C | `api-h5.uvod.tv`（寫死，ext 沒用） | **缺**：RSA PKCS#1 私鑰解密（回應的 AES 鍵是伺服器隨機產生的）；請求端可以用固定的密文，不必 RSA 加密（已實測） | 直接 m3u8，各畫質 | **活**：最新、列表、詳情、來源、搜尋都解得開，m3u8 200 | ~150＋Swift ~50 | 3 |
| `Douban` | 豆瓣、豆瓣-搜索 | A | `frodo.douban.com/api/v2` | 無；要微信 UA＋Referer | **沒有詳情／播放／搜尋**：`vod_id` 是 `msearch:<id>`，靠 App 拿片名去別站搜 | **活**：5 個端點 200。**App 缺**：`msearch:` 轉成全站搜尋（iOS 完全沒有）、海報要 Referer（`doubanio` 沒 Referer 回 418） | ~170＋App 功能 | 1.5＋功能 |
| `PianKu8` | 山楂 | C | `qkys.qukanwh.com` | **缺**：RSA 公鑰加密＋私鑰分段解密 | — | **死**：DNS 有解析，80／443 連線逾時（重試過） | ~170 | — |
| `AppSy` | 漫国动漫 | B | ext `114.66.27.208:806` | AES-128-ECB（UTF-8 鍵）；不缺 | — | **死**：806 與 80 連線逾時（重試過） | ~170 | — |
| `Hxq` | 韩圈 | C | ext `www.小不点.com/…/fishhxq.php` | 簽章與解密**都在對方的 PHP 裡做**，JAR 只是轉送；播放要本機 proxy 拼 m3u8 | — | **死**：網域 NXDOMAIN（系統 DNS、8.8.8.8、223.5.5.5、DoH 都一樣） | — | 不可行 |

合計：**活 18 站**（只寫 JS 就行的 13 站＋要補 host 的 3 站＋要做 App 功能的 Douban 2 站），**死 5 站**（橘汁、薯条、山楂、漫国动漫、韩圈）。好看短剧的搜尋壞了，算在活的 13 站裡。

## 4. 各類重點（實作時要注意的地方）

- **Jpys／Jys**：用 `vodId@nid` 當播放 id。原版用 HEAD 測鏡像，但 HEAD 不準（`m.jiabaide.cn` HEAD 403、API 卻 200；`m.sizhengxt.com` HEAD 200、API 403），**改用簽章過的 `hotSearch` 測**。播放網址綁用戶端 IP。1080／720 標 `needLogin:true`，但 m3u8 和 `.ts` 實測可抓。
- **Feiyu**：`secret = HMAC-SHA256(key=固定鹽, msg=deviceId)`，再用 `secret` 簽 `GET\n路徑\n查詢\n秒\nnonce\n版本`。簽章用原始值，網址用 encode 過的值。
- **MiaoWu**：`data` 是長度大於 16、不是 `{`／`[` 開頭的字串時才要解密；DoH 失敗時備援 `http://app.nyafun.vip/app/api/`。
- **WeiguanDJ**：播放 id 是 JSON 陣列的 base64；畫質陣列 iOS 的 `PlayURL` 已經會處理。
- **HemaDJ**：code 8 時重產 `datas` 再試一次；詳情有 3 組一模一樣的網址，只輸出一組。
- **QimaoDJ**：搜尋結果標題帶 `<font>` 標籤要拿掉。
- **AppYQK**：只有标清能播（伺服器端限制）；回應裡的廣告清單不用理。
- **AppYsV2**：反編譯出來的詳情轉換函式有 jadx 造成的 fall-through，要照每種方言各寫 if／else；這站只要 `.vod` 方言。
- **GuaziTY**：只保留 24 小時內、`m_status<2` 的賽事；沒有搜尋；第 2 頁以後回空。
- **MoDu**：就是一般苹果CMS API，JS 版 70 行。
- **AppDrama**：protobuf 欄位號碼已從 JAR 的 `com/base/model/proto/*` 讀出，探測腳本照這些號碼手寫編解碼，可以直接用在 JS。`dataKey`／`dataIv` 是 32 字元 UTF-8 字串，當 AES-256 金鑰用，host 現有的 AES 可以做。真正缺的是 RSA、hex 輸出與二進位 HTTP（第 5 節）。
- **Uvod**：欄位名稱拼錯（`video_soruce`）要照抄。回應用伺服器自己的隨機 AES 鍵，一定要 RSA 解密。
- **共通**：Wwys、AppYsV2、MoDu、AppSy、AppYQK 會附一個指向 Android 本機 proxy 的彈幕網址，iOS 沒有這個 proxy、播放也不需要，直接拿掉。

## 5. host 能力缺口

目前的 host（`host.js`、`CryptoHost.swift`、`HTTPHost.swift`）：HTTP GET／POST 可以帶 header，有 cookie、不跟隨轉址、回應 header；AES／DES 只吃 UTF-8 字串當金鑰，只輸出 base64；有 md5／sha1／sha256、HMAC、UTF-8 base64、key-value 儲存、簡易 CSS 選擇器、JSON。

| 缺口 | 需要的類別 | 估計 | 備註 |
|---|---|---|---|
| RSA PKCS#1 v1.5 公鑰加密（SPKI base64） | AppDrama、PianKu8 | Swift ~30 行 | `SecKeyCreateWithData`；要先剝 ASN.1 標頭 |
| RSA PKCS#1 v1.5 私鑰解密（PKCS#8 base64，可分段） | Uvod、PianKu8 | Swift ~40 行 | 同上 |
| AES 輸出 hex | AppDrama | 數行 | `symmetric` 加一個輸出編碼參數 |
| HTTP 傳送／接收二進位（base64 進出） | AppDrama | Swift ~20 行 | 現在 body 是字串，protobuf 會壞掉 |
| `:nth-child()` 選擇器 | Wwys | JS 數十行 | 也可以在 spider 裡改寫成 `:eq`，就不必動 `host.js` |
| `msearch:` → 全站搜尋、海報 Referer | Douban | App 功能 | 不是 host 能力，是 App 行為，要另開任務 |

**這會影響發版方式**：依 IOS-POC-5O，只改 spider 腳本的話，可以用相容包在執行時替換，不必重新安裝 App；但新的 host 能力只能隨新版 App 發布。13 個只寫 JS 的站不必動 Swift，AppDrama／Uvod 一定要發新版 App。

## 6. 和設定裡其他站重疊

- **农民影视**：設定裡已經有 XYQHiker 規則版（key `csp_Wwys`、`./json/农民影视.json`；`docs/CSP_MIGRATION_STATUS.md` 記為 live golden）和 `./py/农民影视.py`。Wwys 是同一個站的第三個入口，又有偽裝分段的風險，**增加的價值最低**。
- **金牌／異界**：`./py/又是一個金牌.py` 的「金牌系列」（其中 `py_文才` 用同一組 `hkybqufgh` 網域）已經在 App 內可用。Jpys／Jys 和這些站內容重疊，但它們是 Swift／JS 這條路、啟動不必經過 Python，而且 `swift test` 測得到。
- **魔都**：另有 type-0 `caiji.moduapi.cc` 和 type-1 `moduzy.com` 兩個魔都來源；MoDu 用的是第三個網域 `mdzyapi.com`。
- **連帶好處（未證實，要另外核准 alias）**：IOS-POC-5N 認為 `QmdjAmns`（七猫短剧）和 `HHkkAmns`（好看短剧）這兩個被保護的站，可能是 `QimaoDJ`、`HaokanDJ` 的同品牌版本（brand-level）。兩站的 `ext` 都是 null，port 完以後可以像 `JPianAmns → JianPian` 那樣加 alias，多帶起 2 站；但同品牌不等於同站，要先比對兩邊回傳的資料。

## 7. 方案比較與建議

| 方案 | 內容 | 收益 | 缺點 |
|---|---|---|---|
| 不做 | 維持現狀 | 零風險 | 18 個活站繼續用不到 |
| 照原版全部移植 | 19 類一次做，含 host RSA／二進位、Douban 的 msearch | 能拿的都拿 | 5 站死的白做；Hxq 根本做不出來；一次動太多，回歸很難找原因；要發新版 App |
| **分段移植（建議）** | 先做活的、只寫 JS 的站，每段 2 個類別、各自 commit；host 能力集中成一段；死站和重疊站暫緩 | 每段都獨立可退，前幾段不碰 Swift | 總工時一樣，只是拆開做 |

**建議的分段**（每段：寫 JS port、在 `SpiderRegistry.ported` 加一行、補測試、跑 sweep、各自 commit）：

| 段 | 內容 | 站 | 估計 | 理由 |
|---|---|---:|---:|---|
| **44A** | `WeiguanDJ`＋`HemaDJ` | 2 | 2.5 小時 | 兩站都活，各自獨有內容（短劇），沒有重疊，不缺 host 能力 |
| 44B | `QimaoDJ`＋`HaokanDJ` | 2（＋alias 可能 2） | 2.5 小時 | 同上；好看短剧的搜尋壞了，照實回空；alias 要另外核准 |
| 44C | `Jpys`＋`Jys` | 2 | 1.5 小時 | 一支腳本帶兩站，最省；和 py 金牌系列重疊 |
| 44D | `Feiyu`＋`MiaoWu` | 2 | 3 小時 | 簽章／DoH 比較複雜，但 host 都做得到 |
| 44E | `AppYQK`＋`AppYsV2` | 2 | 3.5～4.5 小時 | AppYsV2 只做 `.vod` 方言 |
| 44F | `GuaziTY`＋`MoDu` | 2 | 1.5 小時 | 體育直播只在有比賽時有內容；MoDu 和兩個既有魔都來源重疊 |
| 44G | host：RSA 加解密、AES hex 輸出、二進位 HTTP → `AppDrama`＋`Uvod` | 3 活（＋橘汁、薯条若復活） | 6 小時，**要發新版 App** | 動 Swift 的唯一一段，集中處理 |
| 暫緩 | `Wwys`（重疊＋偽裝分段）、`Douban`（要做 msearch 功能，另開任務） | 3 | — | — |
| 不做 | `Hxq`（邏輯在對方 PHP、網域已撤）；`PianKu8`、`AppSy`（連不上，等復活再評估） | 3 | — | — |

44A～44F 合計 12 站、約 14.5～15.5 小時；44G 另加 3 站。順序是依「活著、內容沒有重疊、不碰 Swift、工時少」排的，你可以照自己想先看到的內容調整。

## 8. 驗收與回滾（每段都一樣）

- 測試：每個類別一個 `SpiderGoldenTests` 即時 golden（`CSP_GOLDEN_SITE`，走 首頁 → 分類 → 詳情 → 搜尋 → 播放 → 媒體前段 bytes）；簽章／加密用固定時間戳的單元測試（不必連網，CI 也能跑）；`swift test --package-path ios` 全部通過。
- sweep：`SourceCheck` 對 `wang-movie.json` 量可播站數，新站要算進去，**原有站不能退步**；`wang-sex.json` 也要跑一次確認沒有退步（這幾類不在那份設定裡，預期不變）。
- App：模擬器裝 Debug 版，實際點進新站看列表、詳情、播放。**真機未驗證**，由使用者用 SideStore 測。
- 本機 Xcode 27、CI 是 Xcode 26.6：44G 動到 Swift，發版前要先確認 CI 建置成功。
- 回滾：每段一個 commit，`git revert` 就會拿掉腳本和 registry 那一行，其他站不受影響。

## 9. 待使用者決定

1. 核不核准 **44A**（`WeiguanDJ`＋`HemaDJ`）？還是要改順序，例如先做 44C（金牌／異界）？
2. 44B 做完後，要不要另外評估 `QmdjAmns`／`HHkkAmns` 的 alias？
3. 44G 要動 Swift、要發新版 App：要排進來，還是等 44A～44F 做完再說？
4. Douban 的 `msearch`（點推薦片名去所有站搜尋）要不要另開任務？

## 10. 狀態

- 2026-10-02：assessment 完成，未改程式。等使用者核准。
- 2026-10-02 17:05：使用者「開始 44A」。實作見第 11 節。
- 2026-10-02 17:24：使用者「開始 44B」。實作見第 12 節。
- 2026-10-02 17:41：使用者「開始 44C」。實作見第 13 節。
- 2026-10-06：使用者要求直接實作 44D（飛魚、喵呜动漫），只交付程式與文件，發版另行處理。實作見第 14 節。
- 2026-10-06：使用者要求直接實作 44E（一起影视、奴娜），只交付程式與文件，發版另行處理。實作見第 15 節。
- 2026-10-06：使用者要求直接實作 44F（瓜子体育、魔都动漫），只交付程式與文件，發版另行處理。實作見第 16 節。

## 11. 44A 實作紀錄（2026-10-02，Task-Guard `IOS-POC-44A`，`standard`）

- 改動：
  - 新增 `ios/Sources/WebHTVCore/Resources/Spiders/WeiguanDJ.js`、`HemaDJ.js`，在 `SpiderRegistry.ported` 加兩行。不碰 Swift host，資源靠 `Package.swift` 的 `.copy("Resources/Spiders")` 自動帶進 App，Xcode 專案不用改。
  - 測試：
    - 新增 `ShortDramaSpiderTests.swift`，兩個離線測試。stub 只掛在測試自建的 `URLSession` 上，回覆兩個寫死的主機。
    - `SpiderGoldenTests.registryClaimsOnlyWhatIsActuallyPorted` 的清單加上兩類。
    - `SourceClientTests` 的 spider 站數由 32 改成 34。
    - 相容包 golden 的播放網址改用既有的 `playURL()` 讀。原本只收字串，围观回的是畫質陣列（`PlayURL` 本來就支援）；這是測試預期過時，不是退步。
- 和原版刻意不同的地方：
  - 河马的詳情只輸出一組集數。原版把同一串寫三次，卻只有一個線路名，線路和網址的組數對不上。
  - 回應的錯誤碼回 `{}`，不丟例外，跟 `AppGet.js` 一樣；空結果由 41A 的 `SiteUnreachable` 說明。
  - 围观的裝置型號／品牌寫死成 `Pixel7`／`Google`，原版用 `Build.MODEL`。API 只記錄這兩個值。
- 驗證：
  - `swift test --package-path ios` 656／656（本機 Xcode 27.0）。
  - 即時 golden（`CSP_GOLDEN_SITE`，2026-10-02 17:1x，家用網路）：
    - 围观短剧：30 個分類 → 逆袭 30 筆 → 詳情 30 集 → 搜尋「我」30 筆 → `parse:0` mp4 畫質陣列。
    - 河马短剧：8 個分類 → 159 分類 12 筆 → 詳情 71 集（線路「河马」）→ 搜尋「我」15 筆 → `parse:0` mp4。
    - 兩站的相容包 golden 也都通過。
  - `WANG_MOVIE_JSON`（當天設定）：`listsThePortedSpiderSitesAlongsideTheNativeCMSSites` 通過，App 列表 64 站＝30 原生＋34 spider。
  - sweep（`sweepsEveryDrivableSource`，當天 `wang-movie.json`＋GitLab `SWEEP_BASE`）：基準是 HEAD `d790ea4a` 用 `git archive` 匯出的 scratchpad 副本，與修改後的版本背對背跑，17:12～17:16，家用網路。
    - PLAYABLE：基準 28／67 站，修改後 29／69 站。
    - 新的兩站都是 PLAYABLE，而且有讀到影片 bytes：
      - 河马：8 個分類、60 集、mp4。
      - 围观：30 個分類、30 集、mp4。
    - 原有站逐站比對，唯一差異是 Bili 的 bilbil合集 PLAYABLE → DEAD-MEDIA：兩輪抽到首頁不同的影片，這次那支的媒體讀不到可辨識的 bytes。`Bili.js` 沒改，IOS-POC-42 也記過 Bili 一樣的翻轉，判定為網站內容變動，不是 44A 造成的。
    - 驗收（新站可播、原有站不退步）通過。
  - 模擬器（iPhone 17 Pro Max `05934376`，iOS 26.0，Debug，Xcode 27.0）：
    - 設定：本機 `127.0.0.1:8766/config.json`，內容是这兩站＋虎牙。`ConfigLoader.validate` 規定至少要有一個原生 CMS 站，所以帶上虎牙。
    - 围观短剧：首頁 30 個標籤、列表與海報 → 詳情（簡介、30 集）→ 立即播放，原生播放器播出直式短劇。
    - 河马短剧：首頁分類、「類型」篩選列、「已完結/40集」標記 → 詳情（一條「河马」線路、40 集）→ 立即播放，原生播放器播放中（00:02／02:22）。
    - 有一次重開 App 後，围观首頁短暫顯示「沒有內容」，當時我在 App 重新載入設定的過程中點了畫面。之後照同樣情境（上次選围观、重開、不碰畫面）重現一次，正常載入，沒有再出現，原因未查。
    - 模擬器 App 的設定快取現在是這份測試設定（伺服器已關）。
  - **真機未驗證**。
  - `wang-sex.json` 沒有任何站用到這兩類（`grep` 0 筆），App 列出的站不變，所以不跑 sweep。
- Ponytail（`ponytail:ponytail-review`，對 sweep 時的 diff）：提出 3 項，都在 `HemaDJ.js`，已全部套用：
  - `Array.isArray` 取代 `Object.prototype.toString`。
  - 媒體網址的挑選改成一個候選陣列跑一次迴圈。
  - `cipher` 的判斷改為一行。
  - 測試的 stub 和 `RuleSite` 很像，但要另外記錄 POST body、header，還要能排隊回覆，所以保留。
  - 套用後重跑：`swift test` 656／656，河马即時 golden 通過（詳情 118 集、mp4）。sweep 與模擬器量測的是套用前的版本，套用的修改不改行為。

## 12. 44B 實作紀錄（2026-10-02，Task-Guard `IOS-POC-44B`，`standard`）

- 改動：
  - 新增 `QimaoDJ.js`、`HaokanDJ.js`，在 `SpiderRegistry.ported` 加兩行，不碰 Swift host。
  - 測試：
    - `ShortDramaSpiderTests.swift` 加兩個離線測試，stub 多攔截 `neptune`／`api-store`／`api-read.qmplaylet.com` 與 `sv.baidu.com`。
      - 七猫：查詢參數 `sign` 是排序後 `k=v` 加鹽的 md5；`qm-params` 照原版的字元表還原回 base64 後，就是裝置資料；header 的 `sign` 正確；網域檔的結尾 `/` 會拿掉；標題的 `<font>` 會拿掉；沒有網址的集數不列。
      - 好看：兩段式詳情；畫質依 1080p → sc → 第一個挑選；搜尋回空。
    - `SpiderGoldenTests.registryClaimsOnlyWhatIsActuallyPorted` 的清單加上兩類。
    - `SourceClientTests` 的 spider 站數由 34 改成 36。
    - golden 的「分類不得出現 伦理／福利／小影院」改成只對 `csp_AppGet` 檢查。那是 AppGet 原版的隱藏清單；七猫原版會列出「伦理」這個一般劇情分類，所以這是測試預期太廣，不是 port 的錯。
- 和原版刻意不同的地方：
  - 好看的分類頁，原版把總頁數報成 `Integer.MAX_VALUE`；這裡改成一頁不滿 9 筆就是最後一頁，跟 WeiguanDJ 一樣。
  - 好看的搜尋照原版的參數送；上游回「猜空了」，就照實回空清單，不另外猜參數。
  - host 的表單編碼會把 `_` 也編成 `%5F`，OkHttp 不會；伺服器解碼後一樣，即時 golden 也通過。
- 驗證：
  - `swift test --package-path ios` 658／658（本機 Xcode 27.0）。
  - 即時 golden（`CSP_GOLDEN_SITE`，17:2x，家用網路；相容包 golden 兩站也都通過）：
    - 七猫短剧：150 個分類 → 分類 -1 共 16 筆 → 詳情 69 集（線路「七猫」）→ 搜尋「我」10 筆 → `parse:0` m3u8。
    - 好看短剧：29 個分類 → 分類 3 共 9 筆 → 詳情 70 集 → 搜尋 0 筆（上游壞了）→ `parse:0` 1080p mp4（http）。
  - `WANG_MOVIE_JSON`：App 列表 66 站＝30 原生＋36 spider。
  - sweep：HEAD `216bf4de` 的 `git archive` 副本當基準，背對背跑，17:29～17:33。
    - PLAYABLE：基準 32／69，修改後 34／71。
    - 兩個新站都 PLAYABLE，而且有讀到影片 bytes：七猫 150 個分類、80 集、m3u8；好看 29 個分類、70 集、mp4。
    - 原有站逐站的判定完全相同，差異只在抽到的影片網址或集數。
    - 驗收通過。
  - `wang-sex.json` 沒有站用到這兩類，不跑。
  - 模擬器（同 44A 的機器與方式，設定是七猫、好看＋虎牙）：
    - 七猫：首頁分類、海報、集數 → 詳情（簡介、第 1 集起）→ 立即播放，原生播放器播放中。
    - 好看：首頁 29 個分類與列表 → 兩段式詳情（70 集）→ 立即播放，原生播放器播出 http 的 1080p mp4（`NSAllowsArbitraryLoads` 本來就開著）。
    - 好看的海報（`pic.rmb.bdstatic.com` 的 webp）在這個熱點上很慢：
      - App 的 log 裡有一條連線拖了 143 秒，最後被取消。
      - 用 curl 抓，一張要 1.6～13 秒，跟 User-Agent 無關，伺服器都回 200 webp。
      - 判定是網路到這個 CDN 很慢，不是 port 的問題。
    - 模擬器 App 的設定快取現在是這份測試設定（伺服器已關）。
  - **真機未驗證**。
- Ponytail（`ponytail:ponytail-review`，對 sweep 時的 diff）：提出 1 項，已套用：刪掉 `HaokanDJ.js` 詳情裡多餘的 `vod_actor: ''`、`vod_director: ''`。套用後重跑 `swift test` 658／658，好看的即時 golden 也通過。

## 13. 44C 實作紀錄（2026-10-02，Task-Guard `IOS-POC-44C`，`standard`）

- 新發現（assessment 時沒有）：異界（`csp_Jys`）唯一的網域 `www.ndhfiohk.com`，**TLS 憑證在 2026-08-07 就過期了**。
  - agent 當初探測時關掉了憑證檢查，所以沒有發現。
  - `URLSession` 對它回 -1202，curl 回 60；App 沒有自訂憑證信任，也不該為這件事加。
  - 原版 `init` 用 `HttpURLConnection` 做 HEAD 檢查，會照常驗證憑證，所以在 Android 上同樣失敗，會留在類別寫死的預設網域 `www.hkybqufgh.com`。
  - 實測 `ndhfiohk`（跳過憑證檢查）、`hkybqufgh`、`y2s52n7` 三個網域回的列表、詳情與集數 id 完全相同，是同一套後端。
- 改動：
  - 新增 `Jpys.js`，一支腳本服務兩個類別。
  - `SpiderRegistry` 的 `ported` 加 `Jpys`、`Jys`，`aliases` 加 `Jys → Jpys`，並補寫 alias 的說明：Jys 反編譯出來就是 Jpys，只差線路名和一個 header，而且同一套後端已實測。
  - 測試：
    - `ShortDramaSpiderTests.swift` 加一個離線測試，stub 多接受 `*.invalid` 與 `www.hkybqufgh.com`。
      - 跳過不回應的鏡像、拿掉結尾的 `/`。
      - `sign = sha1(md5(…))`：首頁的 `key=…&t=…`，以及分類「原始值、原版順序」的簽法。
      - 篩選的年份列、詳情的 `vodId@nid`、播放取第一個網址並帶 Origin、搜尋去掉「伦理」。
      - Jys 唯一的鏡像失敗時，回退到預設網域。
    - registry 測試加上兩類，並檢查 `csp_Jys` 跑的就是 `Jpys` 的腳本。
    - `SourceClientTests` 的 spider 站數由 36 改成 38。
- 和原版刻意不同的地方：
  - 鏡像的判斷，原版用 HEAD 回 200～399，這裡改成簽章過的 `hotSearch` 有回 `data`。當天 HEAD 在 6 個鏡像裡有 2 個跟 API 的結果相反。
  - 異界的線路名顯示「在线播放」（原版是「星河」），播放也多帶 Origin／Referer。它實際跑在 `hkybqufgh`，金牌本來就是這樣送，媒體實測可播。
  - 原版約 4 KB 的篩選 JSON 改用程式產生，內容相同。
  - 分類的總頁數用 API 回的 `totalPage`。
  - 彈幕需要 Android 的本機 proxy，不做。
- 驗證：
  - `swift test --package-path ios` 659／659（本機 Xcode 27.0）。
  - 即時 golden（用設定檔原本的 ext，17:4x，相容包 golden 兩站也都通過）：
    - 金牌：4 個分類 → 電影 48 筆 → 詳情（線路「在线播放」）→ 搜尋「我」8 筆 → `parse:0` m3u8。
    - 異界：結果相同（回退到預設網域）。
  - `WANG_MOVIE_JSON`：App 列表 68 站＝30 原生＋38 spider。
  - sweep：HEAD `3e3657d6` 的副本當基準，背對背跑，17:47～17:51。
    - PLAYABLE：基準 35／71，修改後 36／73。
    - 兩個新站都 PLAYABLE：都是 4 個分類、39 集，都有讀到 m3u8。
    - 原有站有兩站的判定變了，都跟 44C 無關：
      - Bili 的聽書趣 PLAYABLE → NO-PLAY：詳情正常，這次抽到的作品 B 站沒給播放網址。IOS-POC-42 記過同一站同樣的翻轉，`Bili.js` 沒改。
      - 88看球（type-4）DEAD-MEDIA → ERROR：詳情請求被對方伺服器拖到逾時，是 CMS 那條路，不是 spider。
    - 驗收通過。
  - 模擬器（設定是金牌、異界兩個原始 ext＋虎牙）：
    - 金牌：首頁 4 個分類、地區與年份篩選、海報與「藍光」→ 詳情（年份、地區、類型、導演、演員、簡介）→ 立即播放，原生播放器播放中。
    - 異界：首頁內容和金牌相同（回退到預設網域）→ 詳情 → 立即播放，原生播放器播放中。
  - **真機未驗證**。
- Ponytail（`ponytail:ponytail-review`，對最終 diff）：沒有可刪的項目（Lean already）。

## 14. 44D 實作紀錄（2026-10-06，Task-Guard `IOS-POC-44D`，`standard`）

- 基準：fetch 後的 `origin/ios-poc` `b277685f`，工作區乾淨。沒有沿用第 3 節 2026-10-02 的存活結論，全部重新確認。
- 設定：當天的 `wang-movie.json`（127,425 bytes，md5 `177d298c…`）。兩站都沒有 `ext`：
  - `飞娱影视`（`csp_Feiyu`）
  - `喵呜动漫`（`csp_MiaoWu`，`searchable: 1`）
  - JAR 都寫 `xiaosa-0807.jar;md5;4d263271…`，實際下載的是 `d8f71fc8…`，和 10-02 相同。
- 原版：以 jadx 反編譯 `Feiyu`（404 行）、`MiaoWu`（339 行），以及它們用到的 result builder 與 HTTP helper，完整讀過。HTTP helper 的逾時是 30 秒，信任所有憑證。

### 14.1 原版邏輯核對與站況（09:48～09:52 CST，家用網路，python3／curl／openssl 照原版重做）

- **飛魚的雙層 HMAC 簽章**：
  - `secret = hex(HMAC-SHA256(key=鹽, msg=deviceId))`。
  - `x-signature = hex(HMAC-SHA256(key=secret, "GET\n路徑\n查詢\n秒\nnonce\n2.6.8+1"))`。nonce 是 16 個英數字的 base64。
  - 分類與搜尋用**原始值**簽，網址帶 encode 過的值；排行用 encode 過的值簽。
  - 正確簽章回 200，錯誤簽章回 403 `签名验证失败`。
  - 新發現：伺服器是對**排序後**的參數驗章。`page,page_size,year` 剛好是字母序所以會過；`area`、`class`、`lang` 排在 `page` 後面就回 403。原版首頁沒有篩選，所以這些參數實際上從來不會送出去。
  - 用原始值簽中文關鍵字 200，用 encode 過的值簽 403。
- **飛魚站況**：
  - 分類 6 個，`children` 都是空的，API 沒有提供篩選。
  - 列表：電影 82,057 部，回傳中有 `total`。
  - 排行 50 筆。
  - 詳情 6 條線路。
  - 搜尋「蜘蛛侠」共 109 筆，第 2 頁可以取。
  - 媒體：fengbao、ffzy、lz、dytt 的 m3u8 都回 200。`极速资源站`（`vv.jisuzyv.com`）是自簽憑證。`高清qq` 的解析 API 回 `账户已欠费`，`url` 是相對路徑 `/mizhicdn/video/error.mp4`。
- **喵呜的 DoH 與 AES**：
  - `doh.pub` 的 TXT 去掉引號後，以 AES-256-ECB（32 字元 UTF-8 鍵 `6516…`）解開是 `http://app.nyafun.vip`，和原版寫死的備援相同。
  - 回應的 `data` 是長度大於 16、不是 `{`／`[` 開頭的字串時，用另一把鍵 `c55c…` 解開，結果取代整個 envelope。
- **喵呜站況**：
  - config 有 6 個分類，`type_extend` 有 `class`／`year` 清單。4K专区的 year 欄位是一段提示文字（`PC请使用…`）。
  - 原版的篩選有 80 字上限，當天所有 class／year 清單都超過，所以原版**一個篩選都不顯示**，`categoryContent` 也不送篩選。實測 `content/filter` 會依 `class`、`year` 篩選，結果不同。
  - 列表每頁 12 筆。
  - 詳情的線路名稱全部都是「请移步牛番」。
  - 4K专区的集數是 `mwvod` 位址，要 POST `vod/parse`，會換到 Cloudflare R2 的簽名 mp4（206 `ftypisom`）；直接連 `mwvod` 主機連不上。
  - 搜尋「斗罗」48 筆，不分頁（帶 `page=2` 也回同樣 48 筆）。

### 14.2 改動

- 新增 `ios/Sources/WebHTVCore/Resources/Spiders/Feiyu.js`、`MiaoWu.js`。
  - `SpiderRegistry.ported` 加兩行。
  - 沿用既有的 `host.get/post`、`host.hmac`、`host.aesDecrypt`（ECB）、`host.base64`、`host.random`、`host.enc`、`host.result`、`host.isVideoFormat`。
  - 不動 `host.js`／Swift host，`js.host` 維持 1.2。
- 測試：
  - `ShortDramaSpiderTests.swift`：stub 多攔截 `4kyszx.top`、`doh.pub`、`app.nyafun.vip`，並新增兩個離線測試。
    - 飛魚：每個請求的 `x-signature` 都和用 CryptoKit 獨立算出的雙層 HMAC 相同；nonce 是 16 個英數字的 base64；搜尋的網址帶 encode 過的中文，簽章用原始值；線路依原版的畫質排序；集數 id 是 `parseApi||url`；解析 API 回相對網址時交給嗅探。
    - 喵呜：DoH 用 10-06 當天 `doh.pub` 實際回的 TXT 密文，ext 設的主機會被 DoH 解出的主機取代（原版也是這樣）；AES-ECB 回應能解開；篩選列（提示文字不算篩選）與分類請求帶 `class`／`year`；重名線路加上 player 代碼；`mwvod` 會 POST `vod/parse`，body 是 `{vid, player}`。
  - `SpiderGoldenTests.registryClaimsOnlyWhatIsActuallyPorted` 加兩類；`SourceClientTests` 的 spider 站數由 38 改成 40。
- **和原版刻意不同的地方**：
  - 共通：
    - 逾時 20 秒（原版 30 秒），跟其他 port 一樣。
    - 不支援彈幕（`addDanmaku` 要用 Android 的本機 proxy）。
    - `destroy` 會清掉狀態。
  - 飛魚：
    - 分類與搜尋的總頁數用 API 回的 `total` 算（原版寫死 999）。
    - 搜尋照 App 傳的頁碼送（原版永遠是第 1 頁）。
    - 播放結果帶 `User-Agent: Dart/3.10 (dart:io)`。原版不帶，但 golden 要求 `parse:0` 一定要有 header，其他 port 也都帶。
    - 解析 API 回的 `url` 不是 http(s) 時改成 `parse:1` 交給嗅探。原版會照收，就會播 `/mizhicdn/video/error.mp4`。
    - 不送篩選參數，因為 API 沒有提供篩選選項，伺服器也會拒絕非字母序的參數。
    - `host` header 由 URLSession 依網址自動帶。
  - 喵呜：
    - 顯示並送出 `class`／`year` 篩選：拿掉 80 字上限，保留「请／建议」的提示文字過濾。
    - 重複的線路名稱後面加 player 代碼，例如「请移步牛番 ffm3u8」。App 找回上次看的線路是用名稱（`WebHTVApp.swift` 的 `flags.first(where: { $0.name == watchedFlag })`），名稱重複時永遠回到第一條。
    - 詳情多帶 `type_name`（API 的 `vod_class`）。
    - 搜尋回單頁清單：原版的總頁數是 10，但這個 API 不分頁。
    - DoH 只在 `init` 查一次。原版每個請求前都會檢查一個旗標，但旗標在 `init` 之後就一直是 true。
    - `vod_author` 照原版放在 `vod_actor`。有些作品這個欄位是「豆瓣」，不是演員，照原版不改。

### 14.3 驗證

- **簽章與解密的離線測試**：新增的 2 個測試加上 registry 測試通過。突變 3／3 都被抓到：改版本字串、改 DoH 鍵、改成用 encode 過的值簽章。
- **runtime 端到端探測**：真的 JavaScriptCore，走 `CSPSourceResolver().session(for:)`，用設定檔原本的站台定義。10:00 CST 執行。探測檔是臨時測試，用完就刪掉，沒有 commit。

| 功能 | 飛魚 | 喵呜动漫 |
|---|---|---|
| 首頁分類 | 6 個 | 6 個 |
| 篩選 | 來源沒有提供（同原版） | 番剧、剧场、国漫、欧美动漫 4 個分類有 `class`／`year`；番剧＋搞笑／2024 回 12 筆，和不篩選時不同 |
| 首頁推薦列表 | 排行 50 筆 | 原版沒有 |
| 分類與分頁 | 6 個分類的第 1、2 頁各 20 筆，不重疊；總頁數 16～12,376 | 6 個分類的第 1 頁各 12 筆；第 2 頁 5 個分類各 12 筆不重疊，4K专区第 2 頁 0 筆 |
| 搜尋 | 「蜘蛛侠」第 1、2 頁各 20 筆，總頁數 6 | 「斗罗」48 筆（單頁） |
| 作品 metadata | 年份、類型、地區、演員、導演、簡介、備註 | 年份、類型（`vod_class`）、簡介、備註；`vod_actor` 來自 `vod_author` |
| 線路與集數 | 魅力航班第二季：5 條線路，集數 20／24／2／22／22 | 擅长逃跑的殿下第二季：2 條線路（第二條加上 `ffm3u8`），各 4 集；紫罗兰永恒花园（4K）：1 條 14 集 |
| HTTP 成功 | API 全部 200 | DoH、config、列表、詳情、搜尋、`vod/parse` 全部 200 |
| 取得媒體網址（`parse:0`） | 5／5 條 | 3／3 條（2 條直連 m3u8，1 條經 `vod/parse` 的 R2 mp4） |
| 媒體 bytes | 4／5 條：m3u8（→ variant）→ TS 分段 206、`47 40 11…`；**无水印**（`v13.wsyzym3u8.com`）憑證無效，連不上 | 3／3：TS 分段 206；R2 mp4 `ftyp` |
| AVFoundation 可開啟（macOS，`isPlayable`／`duration`） | 4／5 條 playable，長度約 40 分鐘；无水印失敗（憑證） | 3／3 playable |
| 播放 header | `User-Agent: Dart/3.10 (dart:io)` | `User-Agent: Dart/3.5 (dart:io)`＋`content-type: application/json`（同原版） |
| **iOS 實際播放（畫面）** | **未驗證**（沒有跑模擬器或真機） | **未驗證** |

- 這次的飛魚作品沒有 `高清qq` 線路。10-02 抽到的作品有，當時它的解析 API 已經欠費，走嗅探，**能不能播未驗證**。
- 即時 golden（`CSP_GOLDEN_SITE` 用設定原本的定義，含相容包 golden）：套用 Ponytail 前後各跑一次，兩站都通過（10:05 CST）。
  - 飛魚：6 個分類 → 分類 1 共 20 筆 → 詳情 5 條線路 → 搜尋「我」0 筆（這個 API 搜「我」本來就沒有結果）→ `parse:0` m3u8。
  - 喵呜：6 個分類 → 12 筆 → 詳情 2 條線路 → 搜尋「我」100 筆 → `parse:0` m3u8。
- **既有來源回歸**：`swift test --filter` 跑 SpiderHost、ShortDramaSpider、SpiderPack、RuntimeABI、RuntimePackManifest、XBPQRule、XYQHikerRule、DrpyEngine、SpiderGolden、SourceClient 這 10 個檔，帶 `WANG_MOVIE_JSON`=當天設定。
  - 164 個測試中 163 個通過。
  - App 列表 70 站＝30 原生＋40 spider（原本 68 站）。
  - 唯一失敗的 `ConfigLoaderTests.decodesProvidedWangMovieConfig` 寫死設定檔有 167 站（2026-09-15 寫的），當天設定是 169 站。這是過時的預期，和 44D 無關，沒有修。
  - 既有的 spider 腳本與 host 都沒改。
- 沒有跑：完整 `swift test`、測試 CI、`wang-movie.json` sweep、模擬器、Xcode 建置、真機。
- Ponytail（`ponytail:ponytail-review`，對最終 diff）：提出 2 項，已套用。
  - `Feiyu.js` 只用一次的 `items()` 改成內嵌。
  - `MiaoWu.js` 拿掉 DoH 旗標和多餘的 `resolve()` 呼叫。
  - 套用後重跑離線測試與兩站的即時 golden，都通過。

### 14.4 要用 SideStore 真機確認的項目（這次沒有發版）

1. 兩站首頁、分類、篩選（喵呜）、翻頁、搜尋在 App 裡的顯示。
2. 飛魚：暴风／非凡／量子／电影天堂這幾條線路能播。无水印、极速资源站的憑證是無效的，**預期在 iOS 上會失敗**，是否顯示合適的錯誤要確認；`高清qq` 這類走解析 API 的線路會交給嗅探。
3. 喵呜：直連 m3u8 線路、4K专区經 `vod/parse` 的 R2 mp4（簽名 1 小時內有效）、重名線路的續看會回到正確的線路。
4. 收藏、觀看記錄、下載對這兩站的行為（App 端沒有改程式）。

## 15. 44E 實作紀錄（2026-10-06，Task-Guard `IOS-POC-44E`，`standard`）

- 基準：fetch 後的 `origin/ios-poc` `0068cd9c`（含 44D），工作區乾淨。沒有沿用第 3、4 節 2026-10-02 的存活與畫質結論，全部重新確認。
- 設定：當天的 `wang-movie.json`（169 站，md5 `177d298c…`）。
  - `奴娜`：`csp_AppYsV2`，`ext` `https://www.nntv.in/api.php/v1.vod`，`searchable`／`quickSearch`／`filterable` 都是 1。JAR 是 `river-fman.jar` `ca48f92e…`，和設定一致。
  - `一起影视`：`csp_AppYQK`，沒有 `ext`，`filterable: 0`。JAR 設定寫 `xiaosa-0807.jar` `4d263271…`，實際下載的是 `d8f71fc8…`。
- 原版：以 jadx 反編譯 `AppYQK`（342 行，以及它的 md5 helper `merge/A/e0`）、`AppYsV2`（969 行，以及 `merge/A0/ku` 的影片判斷與解析結果處理），完整讀過。

### 15.1 原版邏輯核對與站況（10:17～10:35 CST，家用網路，python3／curl 照原版重做）

- **一起影视的 md5 簽章**：
  - 欄位以 `k=v&…` 串接，結尾加上 `&appKey=…`，取 md5 小寫 hex 當作 `sign`，放在 JSON body 的最後一欄。每個端點在原版裡的欄位順序剛好都是字母序。
  - `udid` 是毫秒時間的 16 位 hex：`getUUID` 先組了一個 UUID，最後卻回傳時間字串。
  - 正確簽章回 `result:true`，錯誤簽章回 `sign error`。
- **一起影视站況**：
  - 頻道 8 個，原版略過短剧、体育，剩 6 個。API 沒有提供篩選。
  - 分類是一頁精選專題：電影頻道有 15 個專題、90 筆，其中 2 筆重複；API 不接受頁碼。
  - 詳情有 18 條線路。
  - 畫質：`epDetail` 列出每集的畫質。超清標 `APP独享`、`canPlay:false`，向 `playUrl` 要網址時，伺服器回「网页版不支持该清晰度」；标清、流畅的 `canPlay:true`，會回 m3u8。
  - 搜尋每次 15 筆，回應帶 `hasNext`／`nextVal` 游標（原版沒用）。實測把 `nextVal` 放進簽章欄位，就能拿到第 2 頁，結果和第 1 頁不同。
- **奴娜的 `.vod` 方言**：
  - 首頁 `/types`：10 個分類，`type_extend` 有 class／area／lang／year（還有 star、director 等，原版不用）。
  - 列表 `?type=&class=&area=&lang=&year=&by=&limit=18&page=`：回 `data.total`／`limit`，篩選與排序有效。
  - 排行 `/vodPhbAll`：只有 `vod_list`，沒有 `vlist`。
  - 詳情 `/detail?vod_id=`：線路是 `vod_play_list[].player_info.from`，集數是 `url`。
  - 搜尋 `?wd=&page=`：會分頁。
  - jadx 的 `m()` 在 `.vod` 分支結束後，接著輸出 `api.php/app` 分支讀 `data.vod_url_with_player` 的程式碼。這是反編譯工具把互斥分支攤平造成的；照抄的話，`.vod` 會在讀不到 `vod_url_with_player` 時丟例外，詳情整個失敗。這裡 `.vod` 只讀 `vod_play_list`。
- **奴娜站況**：
  - 抽查 8 部作品，每部都有 3 條線路：`jazsjzlp_1080p`、`dyttm3u8`、`lzm3u8`。
  - `parse`／`parse2` 全部是空的，所以原版的解析器流程（`r()`）沒有東西可試。
  - `jazsjzlp_1080p` 的集數是網頁播放頁（307 → validator → Next.js 頁面），原版也是交給 `parse:1`。
  - `lzm3u8` 有些作品的集數只有網址、沒有「名稱$」（iOS 的 `Episode.parse` 會用序號當名稱）。
  - 直播（23）和電視劇（25）兩個分類的列表是空的，來源本身沒有內容。

### 15.2 改動

- 新增 `ios/Sources/WebHTVCore/Resources/Spiders/AppYQK.js`、`AppYsV2.js`，`SpiderRegistry.ported` 加兩行。
  - 沿用 `host.post/get`、`host.md5`、`host.random`、`host.enc`、`host.result`、`host.isVideoFormat`。
  - 不動 host 與 Swift，`js.host` 維持 1.2。
- 測試：
  - `ShortDramaSpiderTests.swift`：stub 多攔截 `yzy0916.n0z6fkpuk.com`，並新增兩個離線測試。
    - 一起影视：每個請求的 `sign` 都和用 CryptoKit 獨立計算的 md5 相同，`sign` 是最後一欄；`udid`、`requestId` 的格式正確；短剧、体育被略過；重複的作品只列一次；線路名稱不含集數；只向 `canPlay` 的畫質要網址，超清從不送出；播放帶 Origin／Referer；搜尋第 2 頁會帶第 1 頁的 `nextVal`。
    - 奴娜：篩選列依 `type_extend` 的順序產生，去空白，伦理和結尾的空值丟掉，最後加上排序列；分類請求的參數（`排序` → `by`）、總頁數＝`data.total`／`limit`；詳情只讀 `vod_play_list`（fixture 故意放一個錯的 `vod_url_with_player`）；m3u8 → `parse:0`，播放頁 → `parse:1`；`vodPhbAll` 去重；非 `.vod` 的 `ext` 不輸出任何東西。
  - registry 測試加兩類；`SourceClientTests` 的 spider 站數由 40 改成 42。
- **和原版刻意不同的地方**：
  - 共通：逾時 20 秒（原版是 OkHttp 的預設值）；不支援彈幕（原版的 `addDanmaku`／`Proxy.getUrl()?do=appdanmu` 都要用 Android 的本機 proxy）。
  - 一起影视：
    - 線路名稱只用 `playerName`。原版是「`名稱共(N)集`」，但集數會隨更新改變，App 找回上次看的線路又是比對名稱。
    - 集數 id 只用 `epId`。原版是 `epId|片名|集名`，給彈幕用；片名會隨版本更新改變（例如「…-8月31日-HD高清」）。
    - 分類頁裡重複的作品只列一次。
    - 分類只有一頁（原版的總頁數永遠是頁碼＋1，但 API 不吃頁碼）。
    - 搜尋用 `nextVal` 游標翻頁（原版只取第一頁）。
    - 詳情多帶 `vod_director`（`directorList`）與 `type_name`（`tagList`）。
    - `playUrl` 拒絕的畫質直接略過（原版會丟例外）。
  - 奴娜：
    - 只做 `.vod` 方言，`iopenyun` 變體與其他方言都沒移植。
    - 解析器流程不做，因為來源的 `parse`／`parse2` 目前都是空的；以後有了，非媒體網址也會照樣交給嗅探。
    - 搜尋照 App 傳的頁碼送（原版 `page=` 留空）。
    - `parse:0` 的結果帶 `User-Agent: okhttp/4.1.0`。原版不帶，但 golden 要求一定要有 header。
    - 篩選值裡的空值丟掉；原版只有結尾的空值會被 Java 的 `split` 自動丟掉。
    - `ku.e` 裡只對 `m3u8.pw/Cache`＋`banyung` 的特例沒有做。

### 15.3 驗證

- **簽章與解析的離線測試**：新增的 2 個測試加上 registry 測試通過。突變 4／4 都被抓到：改 `appKey`、拿掉 `canPlay` 過濾、改讀 `vod_url_with_player`、欄位不排序。
- **畫質調查**（python 照原版，10:35～10:39）：5 部作品（奈飞、電視劇、動漫、韓劇、電影頻道各 1 部）每部取前 3 條線路的第 1 集，列出所有畫質，並對每個畫質向 `playUrl` 要網址。
  - 有「一起看APP」線路的 4 部，畫質都是**超清（`APP独享`，`canPlay:false`）＋标清（`canPlay:true`）**。超清每次都被拒（「网页版不支持该清晰度」），标清每次都拿到 m3u8。
  - 其他線路（WJ、BF、HH、JS、SN、SD、KC…）都只有**流畅**，`canPlay:true`，也都拿到網址。
  - **超清不能宣稱可播**：adapter 不會列出它，也不會去要網址。
- **runtime 端到端探測**：真的 JavaScriptCore，走 `CSPSourceResolver().session(for:)`，用設定檔原本的站台定義。10:26～10:28 執行。探測檔是臨時測試，用完就刪掉，沒有 commit。讀媒體最多 256 KB。

| 功能 | 一起影视 | 奴娜 |
|---|---|---|
| 首頁分類 | 6 個（奈飞Netflix、电影、电视剧、动漫、综艺、高清韩剧） | 10 個 |
| 篩選 | 來源沒有提供（同原版） | 10 個分類都有 class／area／lang／year＋排序；电影＋喜剧／2025／最热 回 18 筆、16 頁，和不篩選時不同 |
| 首頁推薦列表 | 原版回空清單 | `vodPhbAll` 56 筆（去重後） |
| 分類與分頁 | 每個頻道一頁精選：170／88／41／30／24／47 筆（已去重），第 2 頁 0 筆（設計如此） | 8 個分類的第 1、2 頁各 18 筆，不重疊，總頁數 183～1278；直播、電視劇是空的（來源沒有內容） |
| 搜尋 | 「蜘蛛侠」第 1 頁 15 筆、第 2 頁 15 筆（不同作品，用游標） | 「蜘蛛侠」15 筆，1 頁 |
| 作品 metadata | 年份、類型（tag）、地區、演員、導演、簡介、備註 | 年份、類型、地區、演員、導演、簡介、備註 |
| 線路與集數 | 金特务：18 條線路各 10 集；欢迎来龙餐馆：18 條，1～2 集 | 夜色将烬：3 條各 20 集；太玄·东方阙：3 條各 4 集 |
| HTTP 成功 | 全部 `result:true`（只有超清的 `playUrl` 被拒，adapter 不會送） | 全部 200 |
| 取得媒體網址 | 兩部作品 36 條線路都拿到 `parse:0` 畫質清單（「一起看APP」是 [标清]，其他是 [流畅]） | `dyttm3u8`／`lzm3u8` 是 `parse:0` m3u8；`jazsjzlp_1080p` 是播放頁，`parse:1` |
| 讀到媒體 | 13／36 條讀到 TS 或加密分段（一起看APP、BF、FF、LZ、YZ、UK，加上龙餐馆的 MT）。KC、NN 4 條的 playlist 可讀，但分段主機憑證無效。**19 條（WJ、SN、HN、SD、HH、JS、JY、XL、BD，以及金特务的 MT）的媒體主機憑證無效**，Apple 平台連不上 | 4／4 條 m3u8 讀到 TS（`47 40 11…`），包含只有網址的 lzm3u8 集數（curl 補測） |
| AVFoundation 可開啟（macOS） | 讀到媒體的 13 條都 playable；KC、NN 只是 playlist 層判定 playable，分段實際讀不到 | 探測的 3 條 m3u8 都 playable |
| 播放 header | UA `Dart/3.1 (dart:io)`＋Origin／Referer `yqk1.app`（同原版） | UA `okhttp/4.1.0` |
| `parse:1`（交給嗅探） | 無 | `jazsjzlp_1080p`：嗅探能不能找到媒體**未驗證** |
| **iOS 實際播放（畫面）** | **未驗證** | **未驗證** |

- 即時 golden（`CSP_GOLDEN_SITE` 用設定原本的定義，含相容包 golden）兩站都通過（10:25）；奴娜在套用 Ponytail 後又跑了一次，也通過（10:35）。
  - 一起影视：6 個頻道 → 奈飞頻道 170 筆 → 詳情 18 條線路 → 搜尋「我」14 筆 → `parse:0` 标清 m3u8。
  - 奴娜：10 個分類 → 短剧 18 筆 → 詳情 3 條線路 → 搜尋「我」20 筆 → `parse:1`（第一條是播放頁）。
- **既有來源回歸**：`swift test --filter` 跑和 44D 相同的 10 個測試檔，帶 `WANG_MOVIE_JSON`=當天設定。
  - 166 個測試中 165 個通過。
  - App 列表 72 站＝30 原生＋42 spider（原本 70 站）。
  - 唯一失敗的 `ConfigLoaderTests.decodesProvidedWangMovieConfig` 是**既有的失敗**：它寫死 167 站，當天設定是 169 站，44D（本次改動之前）的回歸就已經這樣失敗，和 44E 無關，沒有修。
  - 既有的 spider 腳本與 host 都沒改。
- 沒有跑：完整 `swift test`、測試 CI、sweep、模擬器、Xcode 建置、真機。
- Ponytail（`ponytail:ponytail-review`，對最終 diff）：提出 3 項，都在 `AppYsV2.js`，已套用（拿掉其他方言的 `list`／`data` 陣列 fallback、`totalpage`／`pagecount`、`vlist`）。套用後重跑離線測試與奴娜的即時 golden，都通過。

### 15.4 要用 SideStore 真機確認的項目（這次沒有發版）

1. 兩站首頁、分類、奴娜的篩選與排序、翻頁、搜尋（一起影视的第 2 頁）在 App 裡的顯示。
2. 一起影视：
   - 「一起看APP」线路的标清，以及 BF、FF、LZ、YZ、UK 線路能播。
   - 超清不會出現在畫質清單裡。
   - 憑證無效的線路（WJ、SN、HN、SD、HH、JS、JY、XL、BD、KC、NN，MT 視作品而定）**預期會失敗**，要確認錯誤顯示是否合適。
3. 奴娜：`dyttm3u8`、`lzm3u8` 能播；`jazsjzlp_1080p` 交給嗅探後能不能播；只有網址的集數名稱會顯示成 01、02…。
4. 收藏、觀看記錄（線路名稱改成不含集數後的續看）、下載對這兩站的行為（App 端沒有改程式）。

## 16. 44F 實作紀錄（2026-10-06，Task-Guard `IOS-POC-44F`，`standard`）

- 基準：fetch 後的 `origin/ios-poc` `cd62381e`（含 44D、44E），工作區乾淨。沒有沿用第 3、4 節 2026-10-02 的存活結論，全部重新確認。
- 設定：當天的 `wang-movie.json`（169 站，md5 `177d298c…`）。
  - `瓜子体育`：`csp_GuaziTY`，沒有 `ext`，`style: list`；JAR 是 `river-fman.jar` `ca48f92e…`，和設定一致。
  - `魔都动漫`：`csp_MoDu`，沒有 `ext`，`searchable: 1`；JAR 設定寫 `xiaosa-0807.jar` `4d263271…`，實際下載的是 `d8f71fc8…`。
  - 同一份設定裡還有兩個魔都來源：type 0 的 `魔都`（`caiji.moduapi.cc`，XML）和 type 1 的 `vod_魔都`（`moduzy.com`）。三者 key 和 API 都不同，這次沒有合併，也沒有改設定。
- 原版：以 jadx 反編譯 `GuaziTY`（127 行，以及 `merge/A/a` 的 `bo`／`an` AES helper、result builder、表單 POST）、`MoDu`（139 行），完整讀過。

### 16.1 原版邏輯核對與站況（10:45～10:50 CST，家用網路，python3／curl／openssl 照原版重做）

- **瓜子体育**：
  - 每個請求都是表單 POST，`parameter` 是 base64(AES-128-CBC(JSON))，金鑰和 IV 都是固定的 UTF-8 字串；回應的 `data` 用同一組金鑰、IV 解密（原版會先拿掉 `\`）。原版的 `an()` 解密失敗時會原樣回傳密文，後面的 `new JSONArray(...)` 就會丟例外。
  - 4 個分類各一個查詢，回應各有 38～40 場賽事。原版只保留 24 小時內開賽、而且 `m_status<2`（0 未開賽、1 進行中）的場次；當時每個分類剩 18～20 場，包括進行中的 NBA 國王 vs 湖人。
  - 分類只有第 1 頁（其他頁原版回空字串）；沒有搜尋。
  - 詳情：`live_line` 是直播線路（中文解說、英文解說、賽場原聲）。
  - 媒體：進行中的比賽，m3u8 回 200、TS 分段 206（`47 40 00 10`），帶不帶原版的 `Lavf` UA／Referer 都可以。**未開賽的比賽同樣有線路，但 m3u8 回 404 `stream not found`**，開賽前本來就沒有串流，不能拿來判定來源失效。有些未開賽的場次連線路都還沒有。
- **魔都动漫**：
  - `www.mdzyapi.com/api.php/provide/vod` 是一般的苹果CMS JSON：`ac=detail&t=&pg=`、`ac=detail&ids=`、`/?ac=detail&pg=&wd=`。
  - 每頁 20 筆，回 `pagecount`／`total`；`limit` 是字串 `"20"`。
  - API 的分類清單有 30 多類（包含成人分類「里番」），原版只寫死 5 個動漫分類。
  - 線路都是 `modum3u8`。抽查 100 部作品的第一集：`modujx17`（59）、`modujx11`（21）、`modujx13`（1）的憑證正常，回 200；`modujx10`（15）、`modujx12`（4）是自簽憑證，就算跳過憑證檢查也回 404。

### 16.2 改動

- 新增 `ios/Sources/WebHTVCore/Resources/Spiders/GuaziTY.js`、`MoDu.js`，`SpiderRegistry.ported` 加兩行。
  - 沿用 `host.aesEncrypt`／`aesDecrypt`（CBC）、`host.post`（表單）、`host.get`、`host.enc`、`host.result`、`host.isVideoFormat`。
  - 不動 host 與 Swift，`js.host` 維持 1.2。
- 測試：
  - `ShortDramaSpiderTests.swift`：stub 多攔截 `api.46d5umpk.com`、`www.mdzyapi.com`，並新增兩個離線測試。
    - 瓜子：
      - 表單的 `parameter` 和 openssl 算出的 AES-CBC 密文完全相同（nba 查詢與 `{"mid":"1"}`）。
      - 已結束的、超過 24 小時的賽事會被排除；備註格式（`MM-dd HH:mm`，用裝置時區）與比分正確。
      - **沒有賽事的日子回空清單；回應無法解密時丟錯**，兩者不會混淆。
      - 第 2 頁回空；詳情的線路與集數正確；播放帶 `Lavf` UA 與 Referer；搜尋回空。
    - 魔都：
      - 名稱或 id 空白的作品略過；`pagecount`／`limit`（字串）／`total` 依原版的下限與預設值計算。
      - 沒有線路名稱時用「播放」。
      - 搜尋在 API 沒給 `pagecount` 時預設 10 頁。
      - 播放網址去空白並帶 UA。
  - registry 測試加兩類；`SourceClientTests` 的 spider 站數由 42 改成 44。
- **和原版刻意不同的地方**：
  - 共通：逾時 20 秒；不支援彈幕（魔都原版的 `addDanmaku` 要用 Android 的本機 proxy）。
  - 瓜子：
    - 分類結果多帶 `page:1`／`pagecount:1`（原版只回 `{list}`，但 golden 要求分類結果要有頁碼）。
    - 不在設定裡的分類 id 回空（原版會去找不存在的 `all`，然後丟例外）。
    - 請求本身失敗時回空清單，讓 runtime 以「站台連不上」回報。
    - 搜尋明確回空清單（原版沒有這個方法）。
  - 魔都：詳情多帶 `type_name`。

### 16.3 驗證

- **解密與解析的離線測試**：新增的 2 個測試加上 registry 測試通過。突變 4／4 都被抓到：改金鑰、拿掉 `m_status` 過濾、把「解密失敗要丟錯」改成回空、改掉 `pagecount` 的計算。
- **runtime 端到端探測**：真的 JavaScriptCore，走 `CSPSourceResolver().session(for:)`，用設定檔原本的站台定義。10:51～10:52 執行。探測檔是臨時測試，用完就刪掉，沒有 commit。

| 功能 | 瓜子体育 | 魔都动漫 |
|---|---|---|
| 首頁分類 | 4 個（热门、NBA、足球、篮球），篩選 `{}`（同原版） | 5 個動漫分類（同原版），沒有篩選 |
| 分類與分頁 | 每個分類一頁：20／20／18／19 場；第 2 頁 0 筆（來源沒有） | 5 個分類的第 1、2 頁不重疊，總頁數 2～225；港台動漫第 2 頁 15 筆 |
| 搜尋 | 原版沒有，回空 | 「斗罗」19 筆、「海贼王」7 筆 |
| 作品 metadata | 對戰、狀態與比分（例如「第二节 比分30-48」） | 年份、類型、地區、演員、導演、簡介、備註 |
| 線路與集數 | 1 條「 瓜子 」；直播中的場次 3 集（中文解說、英文解說、賽場原聲），未開賽的 0～1 集 | 1 條 `modum3u8`，例如 34／20／244 集 |
| API 成功 | 4 個分類與詳情都解密成功 | 全部 200 |
| 取得媒體網址 | 有線路的場次都是 `parse:0` m3u8 | `parse:0` m3u8 |
| 讀到媒體 | 直播中的國王 vs 湖人：m3u8 200 → TS 206（`47 40 00 10`）；**未開賽的中甲：404 `stream not found`（正常）** | `modujx17`、`modujx11`：TS 206；`modujx12`：憑證無效，連不上（抽查時 `modujx10` 也一樣） |
| AVFoundation 可開啟（macOS） | 直播中的那場：playable，時長是直播（無限） | `modujx17`／`modujx11` 的作品 playable；`modujx12` 失敗（憑證） |
| 播放 header | `User-Agent: Lavf/57.83.100`＋`Referer: http://WJiZxLXA2.com/`（同原版） | 原版的 Chrome UA |
| **iOS 實際播放（畫面）** | **未驗證** | **未驗證** |

- 即時 golden（`CSP_GOLDEN_SITE`，含相容包 golden）兩站都通過（10:50）。瓜子第一次跑時卡在「分類結果要有 `page`」，補上 `page:1`／`pagecount:1` 後重跑通過：4 個分類 → 热门 20 場 → 詳情 3 條直播線路 → 搜尋 0 筆 → `parse:0` 直播 m3u8。魔都：5 個分類 → 20 筆 → 詳情 244 集 → 搜尋「我」20 筆 → `parse:0` m3u8。
- **既有來源回歸**：`swift test --filter` 跑和 44D、44E 相同的 10 個測試檔，帶 `WANG_MOVIE_JSON`=當天設定。
  - 168 個測試中 167 個通過。
  - App 列表 74 站＝30 原生＋44 spider（原本 72 站）。type 0／type 1 的兩個魔都來源仍然各自在原生站裡。
  - 唯一失敗的 `ConfigLoaderTests.decodesProvidedWangMovieConfig` 是**既有的失敗**：它寫死 167 站，當天設定是 169 站，44D 之前就已經這樣失敗，和這次無關，沒有修。
- 沒有跑：完整 `swift test`、測試 CI、sweep、模擬器、Xcode 建置、真機。
- Ponytail（`ponytail:ponytail-review`，對最終 diff）：沒有可刪的項目（Lean already）。

### 16.4 要用 SideStore 真機確認的項目（這次沒有發版）

1. 瓜子：
   - 4 個分類在 App 裡的顯示（設定的 `style: list`）、賽事時間與比分。
   - 比賽進行中時直播能播。
   - 未開賽時打開線路會失敗（來源還沒有串流），要確認錯誤顯示是否合適。
   - 沒有比賽的時段，分類會顯示空清單。
2. 魔都：
   - 5 個分類、翻頁、搜尋。
   - `modujx11`／`13`／`17` 上的作品能播。
   - `modujx10`／`12` 上的作品預期會失敗（憑證無效，而且來源回 404）。
   - 魔都动漫和另外兩個魔都來源各自獨立顯示。
3. 收藏、觀看記錄、下載對這兩站的行為（App 端沒有改程式；瓜子的直播串流原本就不適合下載）。
