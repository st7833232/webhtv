# IOS-POC-44 — `wang-movie.json` 可以移植、還沒做的 `csp_*` 站（assessment）

## Recovery anchor

- 目標：使用者 2026-10-02「開始 IOS-POC-44 assessment」。對象是 `docs/current-task-state.md`「Current handoff — 2026-10-02 下午」列的 23 站（19 個類別）：可以移植、iOS 還沒有 port 的 `csp_*` 站。
- 範圍：只做 assessment，**不改程式**。task guard `IOS-POC-44`（`assessment`），路徑：本文件、`docs/current-task-state.md`、`docs/CSP_PORTABILITY_MATRIX.md`。探測腳本與回應都在 session scratchpad，不 commit。
- 結論：23 站裡 **18 站後端今天活著、5 站死了**。活著的 18 站裡 13 站只要寫 JS，不必改 Swift；3 站（AppDrama×2、Uvod）要先在 host 補 RSA 和二進位 HTTP；Douban×2 要另做 App 功能。建議與分段見第 7 節，待決定事項見第 9 節。
- 44A（`WeiguanDJ`＋`HemaDJ`）已完成，見第 11 節。
- 唯一下一步：等使用者決定下一段（第 7 節，建議 44B：`QimaoDJ`＋`HaokanDJ`）；沒有核准不改程式。

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
