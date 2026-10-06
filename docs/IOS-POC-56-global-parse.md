# IOS-POC-56 設定檔全域解析接口（type 0 網頁解析、type 1 JSON 解析）

## Recovery anchor

- **目標**：設定檔的 `parses`（全域解析接口）在 iOS 生效。來源回 `jx:1`、`parse:1`＋`playUrl`、或線路屬於設定 `flags`（VIP 線路）時，依 Android 原版語意交給解析接口；第一版只執行 type 0（網頁）與 type 1（JSON），其他類型明確回報「iOS 尚未支援」。
- **允收**：見第 4 節。
- **基準**：`origin/ios-poc` `f730bd20`（14:24 fetch 時是 `cdec4ec5`，guard 開始前另一個 session 推了 0.1.70 (71) 發版紀錄）。工作樹開始時乾淨。Task-Guard `IOS-POC-56`（standard）。
- **計畫狀態**：完成並提交（commit 見 `git log --grep IOS-POC-56`）；發版另行處理。
- **下一步**：見文末「目前狀態」。

## 1. 原版語意（Android，FongMi 分支，本 repo `app/`）

證據都是本 repo 的原始碼（2026-10-06 讀取）：

| 檔案 | 語意 |
|---|---|
| `bean/Parse.java` | `name`、`type`（`ParseTypeAdapter`：數字或數字字串，其他 0）、`url`、`ext.flag`（線路名清單）、`ext.header`。`isEmpty()`＝type 0 且 url 空。`setHeader` 只在 `ext.header` 空時才用結果的 header。 |
| `api/config/VodConfig.java` | `parses` 依 `name` 去重；**非空時在最前面插入「超級解析」（type 4，`Parse.god()`）**；預設選中的是設定記住的名字，否則第一個＝超級解析。`getParses(type, flag)`：該類型中 `ext.flag` 含此線路的；一個都沒有就回該類型全部。`flags`＝頂層 VIP 線路名。 |
| `bean/Result.java` | `needParse()`＝`parse==1 || jx==1`；`shouldUseParse()`＝有 `parses` 且（`playUrl` 空且 `flags` 含此線路，或 `jx==1`）。 |
| `api/SiteApi.java` | type 3／4：spider／API 的 JSON；`flag` 空就補請求的線路。type 0／1 CMS：`playUrl`＝站台的 `playUrl`，`parse`＝`isVideoFormat(id) && playUrl 空 ? 0 : 1`。 |
| `player/ParseJob.java` | `useParse` 時用選中的解析；`playUrl` 以 `json:` 開頭→type 1（後面是接口）；`parse:名稱`→設定中同名的；都沒有或空→`Parse(0, playUrl)`（`playUrl` 空＝直接嗅探頁面本身）。type 0：WebView 開 `解析url + 網址`，帶解析的 header，嗅探媒體；type 1：GET `解析url + 網址`，取 `url` 或 `data.url`，長度要 >40，媒體 header 取回應中的 `User-Agent`／`Referer`／`Cookie`／`ua`，沒有就用解析的 header；type 2／3 走 JAR 的 `jsonExt`／`jsonExtMix`；type 4 超級解析：所有 type 1（依線路過濾）同時送出，所有 type 0（依線路過濾）放進同一頁的多個 iframe（`assets/parse.html`）同時嗅探，誰先解出用誰。整體 15 秒（`Constant.TIMEOUT_PARSE_DEF`／`_WEB`）。 |
| `ui/activity/VideoActivity.java` | 播放失敗時「自動換解析」：照 `ParseAdapter` 順序換下一個；iOS 沒有解析選單，本次不做（第 6 節）。 |

## 2. 盤點（2026-10-06 實測）

### 2.1 實際設定的 `parses`

| 設定 | type 0 網頁 | type 1 JSON | 其他 | 頂層 `flags` | 站台 `playUrl` |
|---|---|---|---|---|---|
| `wang-movie.json` | 14 | 3 | type 3 ×2（`聚合1` Demo、`聚合0` Web，JAR） | 無 | 無 |
| `wang-sex.json` | 12 | 8（其中 2 個 type 是字串 `"1"`） | type 3 ×4 | 34 個 VIP 線路名 | 7 站 `json:http://127.0.0.1:10079/parse/…`（JAR 本機服務） |

### 2.2 接口可用性（家用網路，無 proxy，2026-10-06 14:40～15:00）

- type 1 JSON：`zy.qiaoji8.com`、`pan.qiaoji8.com`、`150.138.78.37:4399`、`1.94.221.189:88` TCP 都連不上（逾時）；`yunhai.qijiyun.vip`、`jiexi.52ppx.top` DNS 查不到。**全部是外部接口失效**，本機網路無法驗證 type 1 的實際解析。
- type 0 網頁：HTTP 層 ikun、虾米、咸鱼、七七、虾米1 回「江湖路远，后会无期」停用頁；A6、淘片連不上；nnxv 是 Cloudflare 驗證頁；云解、冰豆、盘古、夜幕、8090、M3u8TV、CK 回播放器頁，是否解得出媒體要在 WebView 實測（第 5 節）。

### 2.3 需要全域解析的線路（原版會走解析的）

- `csp_JianPian`（荐片）：官方平台連結（`iqiyi`、`v.qq`、`youku`…）原版回 `parse:1, jx:1`；iOS port 當初因為沒有解析接口改成 `parse:1` 嗅探官方頁面。
- `csp_AppYsV2`（奴娜）：非媒體網址（`bsky*` 線路的抖音影片 ID、`jazsjzlp_1080p` 的播放頁）原版回 `parse:1, jx:1`；iOS port 回 `parse:1`。
- drpy 站（`drpy2.min.js`）：`jx: tellIsJx(url)`，官方平台連結為 1。
- wang-sex 的 VIP `flags` 線路（CMS／spider 回 `qq`、`腾讯`… 線路名且 `playUrl` 空）。
- CMS 采集站實測（22＋38 站）：非媒體網址都是 `/share/`、`/play/` 播放頁，沒有官方平台線路，原本的 probe→嗅探路徑不變。

## 3. 設計

### 3.1 比較

| 方案 | 結論 |
|---|---|
| 不改 | 拒絕：`jx:1`、VIP 線路、`json:` 線路在 iOS 一律「沒有可播放的網址」。 |
| 原版照搬（含解析選單、自動換解析、type 2／3、JAR 本機服務） | 拒絕：type 2／3 需要 JAR 的 `jsonExt`；`127.0.0.1` 服務 iOS 沒有；選單是 UI 新功能，超出本次範圍。 |
| **iOS 改寫的最小版（採用）** | 解碼設定；依原版決定要不要解析與用哪個；超級解析＝原版預設行為（JSON 同時送、網頁用同一頁 iframe 同時嗅探）；只執行 type 0／1。 |

### 3.2 做法

1. **設定**：`WebHTVConfig` 解碼 `parses`（寬鬆：type 數字或字串，`ext.flag`、`ext.header`，名稱去重）與 `flags`；`Site` 解碼 `playUrl`。像 `jar` 一樣，設定把自己的 `ParseSettings` 填進每個 `Site`，所以解析設定一定屬於產生這個 `Site` 的設定；換設定＝換一整組 `Site`。`Site.id`（收藏、記錄、下載 identity）不變。
2. **SourceClient**：`.spider` 帶上建立它的 `Site`（spider session 依 `Site.id` 快取，可能來自上一份設定，不能從 session 讀解析設定）。播放結果多解碼 `jx`、`playUrl`、`flag`（type-4 `?play=` 同樣）。CMS type 0／1：`parse`＝站台 `playUrl` 非空才 1（空的時候維持既有 probe→嗅探，和原版的 `Parse(0, "")` 等價且多一步 probe）。
3. **決策（純函式 `GlobalParse.plan`）**：照 `Result.needParse`／`shouldUseParse`／`ParseJob.setParse`。不需要→原路徑；`Parse(0, "")`→原本的嗅探頁面；超級解析→type 1、type 0 依線路過濾；單一解析→該解析；其他類型、找不到名稱、本機（loopback）接口、非 http(s)→`GlobalParseError.unsupported`，不執行、不改走別的路。
4. **直接媒體快速路徑**：選中的網址副檔名是媒體（`CMSClient.isDirectMedia`）就直接播，不解析（原版在 `playUrl` 非空時連 m3u8 都送解析；iOS 保留既有行為）。
5. **執行（`GlobalParser`）**：JSON 每個接口一個 task，網頁一個 task（一個→單頁、帶該解析 header；多個→`parse.html` 同款 iframe 頁）；全部同時跑，第一個成功的取消其他；整體上限 15 秒；全部失敗→`GlobalParseError.failed`（列出試過的接口）。
   - **只收媒體**：解析出的網址先用既有 `MediaProbe` 帶媒體 header 讀開頭（一次 range 請求），判定為媒體才採用。原版沒有這一步；加上的原因是 Simulator 實測時，超級解析把「云解」自己的錯誤影片（主機已查不到）交給播放器，畫面只顯示 mpv error，把外部接口的失敗誤顯示成播放器錯誤（第 5.4 節）。
   - **headers 分開**：解析請求用解析的 `ext.header`（單一解析時空的話用來源結果的 header，同原版 `setHeader`）；JSON 成功時媒體 header 取回應裡的 UA／Referer／Cookie，沒有就用解析的 header；網頁成功時媒體 header＝解析 header 的 `User-Agent`＋嗅到媒體那個 frame 的 origin 作 `Referer`（瀏覽器預設的 cross-origin referrer）。
6. **嗅探器**：`MediaSniffer` 加 `headers`（UA→`customUserAgent`，其他放在請求上）、多頁 iframe 版本、回報媒體來自哪個 frame，並在呼叫端的 Task 取消時結束這次嗅探（以前只能等逾時或被下一次嗅探取消）。
7. **結果**：沿用 `PlaybackTarget`：預設畫質換成解析出的網址，畫質清單、`position`、來源字幕＋嗅到的字幕照舊。
8. **來源檢查**：解析失敗或不支援→新的結果類別「需要解析，未解出」，不記成來源播放失敗。
9. **adapter**：荐片的官方平台連結照原版補 `jx:1`。奴娜只有非網址的影片 ID（`bsky*`）補 `jx:1`；**http 播放頁（`jazsjzlp_1080p`）刻意不補**：實測直接嗅探 7 秒解出 m3u8，交給解析接口 15 秒解不出，照原版會讓能播的線路退步（第 5.3 節）。`parse:1` 不變，舊版 App 讀不到 `jx` 時行為不變。`spider-pack/` 重建為 `2026-10-06.3`，避免日後發布舊腳本把 `jx` 蓋掉。
10. **ABI**：播放結果多讀 `jx`、`playUrl`、`flag`（type 4 另讀 `parse`），`catvod.result` 1.1 → 1.2（只新增），`RuntimeABITests` 加凍結列。

### 3.3 界限

- 一次播放最多：JSON 接口數個並行 HTTP＋一個 WebView，整體 15 秒，不重試、不循環。
- 取消：呼叫端 Task 取消→HTTP 取消、WebView 停止；新的嗅探會取消舊的（既有）；播放畫面在解析中鎖住集數按鈕（既有 `resolving`），預取有 identity 檢查（既有），所以舊結果不會蓋掉新播放。
- 不快取任何解析結果；每次播放／預取／下載都重新解析。

## 4. 允收

1. 離線測試：設定解碼（type 字串、ext、header、去重、flags、playUrl）、決策表（needParse／useParse／json:／parse:／flag 過濾／未支援／loopback／直接媒體）、JSON 解析（`url`／`data.url`、長度、header 取法、請求 header 與媒體 header 分開）、全部失敗與逾時、取消、換設定後 `Site` 的解析設定跟著換、spider client 用自己的 `Site` 而不是快取 session 的。
2. 既有測試不退步（SourceClient、MediaSniffer、ShortDramaSpider、SpiderGolden 離線部分、CMSClient）。
3. live：在 macOS WKWebView 用實際接口解析一條原本需要解析的代表性線路，並分開記錄外部接口失效。
4. iOS Release build 成功；Simulator 實際播放至少一條解析出的線路（若接口可用）。
5. Ponytail review 已跑並記錄。

## 5. 驗證紀錄（2026-10-06，macOS 27／Xcode 27，家用網路、無 proxy）

### 5.1 離線測試

- `GlobalParseTests`（新，13 個＋1 個 live opt-in）：設定解碼（type 字串、`ext.flag`／`ext.header`、名稱去重、壞項目只丟自己、`flags`、站台 `playUrl`）；決策表（`.none`、`jx:1` 超級解析與線路過濾、VIP 線路、`json:`、`parse:名稱`、網頁 `playUrl`、type 3／loopback／找不到名稱→未支援）；JSON 解析（`url`／`data.url`、長度、相對網址、媒體 header 取回應的 UA／Referer／`ua`、否則 fallback，請求只帶解析自己的 header）；第一個成功就取消其他、掛住的接口最多耗掉預算、全部失敗立即結束、呼叫端取消就停；經 `SourceClient` 端到端（畫質清單、來源字幕、headers 保留、VIP 線路、直接媒體不送解析、全部失敗→`unresolved` 列出接口名、type 3→`unsupported` 且不發任何請求）；換設定：同一個 `Site.id`、快取的 session 來自 A 設定，client 用 B 設定的解析；`make` 帶回請求的 `Site`；CMS `playUrl` 與 loopback `json:`；來源檢查不記播放失敗；iframe 合併頁嗅到子 frame 的串流、嗅探帶 UA、取消後 5 秒內結束。
- adapter：奴娜 `bsky` ID→`jx:1`、播放頁與媒體不帶；荐片 VIP 連結→`jx:1`、檔案不帶。
- 突變 4／4 被抓到：線路過濾、header 優先序、spider 改讀 `session.site`、JSON 的 `ua`。
- 回歸：`swift test --filter`（GlobalParse、SourceClient、MediaSniffer、ShortDramaSpider、CMSClient、RuntimeABI、SiteFailure、SnifferRules、SpiderGolden、ConfigLoader、SpiderHost、NextPlaybackTarget、SiteSelection、SourceSubtitle、PlayURL、SpiderPack、DrpyEngine、PythonRouting、Offline）**417／417 通過**（未帶 `WANG_MOVIE_JSON`，env 閘門的 live 測試略過）。

### 5.2 接口可用性（live，macOS WKWebView，`liveParseServices`）

騰訊 `https://v.qq.com/x/cover/mzc002003kpyd2m/j4102xkp1jl.html` 逐一試 `wang-movie.json` 的 17 個 type 0／1：

| 接口 | 結果 | 判定 |
|---|---|---|
| ikun、虾米、咸鱼、七七、XY | 15 秒無結果；HTTP 層是「江湖路远，后会无期」停用頁 | 外部失效 |
| 冰豆 | 瀏覽器實看同樣是停用頁 | 外部失效 |
| A6、淘片 | 連不上 | 外部失效 |
| 8090、M3u8TV | 瀏覽器實看：「系统错误: 无法解析视频，请尝试换一个播放源解析」（同一後端） | 外部（解不出此片） |
| 云解 | 嗅到 `…/player/404_2.mp4`（接口自己的錯誤影片，MediaProbe 非媒體） | 外部（解不出此片） |
| 盘古、夜幕、CK | 15 秒無結果 | 未細查，視為外部 |
| 推荐、臻享、优选（type 1） | TCP 逾時 | 外部失效 |
| 超级解析（3 JSON＋14 網頁） | 15 秒無結果 | 同上 |

另外看到：M3u8TV 單獨嗅探時把 `svip.qlplayer.cyou/api/auth.php?host=jx.m3u8.tv` 當成媒體——網址含 `.m3u8` 字樣。Android 的 `Sniffer.SNIFFER` 正則用 `find()`，同樣會收，屬既有嗅探規則的共同限制，不在本次範圍。

公開官方網址各跑一次超級解析（兩份設定結果相同）：

| 網址 | 結果 |
|---|---|
| bilibili `BV1GJ411x7h7` | **3～5 秒解出** `…bilivideo.com/…/137649199_da2-1-192.mp4`，媒體 header `Referer: https://jiexi.bot.cd/`，MediaProbe 讀到媒體 bytes |
| 愛奇藝、優酷、芒果、騰訊各一 | 15 秒無結果（外部） |

### 5.3 設定中原本需要解析的線路（live）

`wang-movie.json` 掃奴娜與 4 個 drpy 動漫站（各 30 部、每條線路第一集的原始播放結果）：

- 回 `jx:1` 的只有奴娜：`bsky3`（抖音影片 ID，如 `v14033g50000d9mtltvog65jtsh3ctl0`）、`bsky7`（`tos-cn-v-0051/…`），以及照原版也會是 `jx:1` 的 `jazsjzlp_1080p` 播放頁。drpy 動漫站都是 `jx:0`（不是官方平台連結），不受影響。CMS 采集站（60 站）的非媒體網址都是 `/share/`、`/play/` 頁，沒有 VIP 線路。
- `bsky3`、`bsky7` 交給超級解析：15 秒無結果，屬外部接口解不出抖音 ID；App 會顯示「設定的解析接口都沒有解出影片（試過：…）」，不再是「沒有可播放的網址」。
- `jazsjzlp_1080p`：直接嗅探 7 秒解出 `ppvod01.kqgfbs.com/…/index.m3u8`（媒體）；超級解析 15 秒無結果 → 決定維持嗅探（第 3.2 節第 9 點）。

### 5.4 iOS build 與 Simulator（iPhone 17 Pro，iOS 26.0，Debug）

- iOS Release device build（unsigned，照 CI 的 `EXPANDED_CODE_SIGN_IDENTITY=-`）：成功，bundle 內 `JianPian.js`、`AppYsV2.js` 與原始碼逐位元組相同，版號仍是 0.1.70 (71)（本次沒動版號）。第一次少帶 ad-hoc 簽章參數，Python 框架簽章失敗，屬呼叫參數錯誤，補上後成功。
- 安裝前確認：模擬器 App 容器的 `WebHTVApp.debug.dylib` 與這次建置產物相同。
- 用本機 demo 設定（`http://127.0.0.1:8765/parse-demo.json`，由 Mac 上的 `python3 -m http.server` 提供，不進 repo）：一個本機假 CMS 站（線路 `bilibili`、`qq`，`flags` 設成這兩個），加上 `wang-movie.json` 真實的奴娜、荐片兩站與真實的 19 個 `parses`：

| 線路 | 結果 |
|---|---|
| CMS `bilibili`（VIP 線路→超級解析） | 解析 4.2～5.3 秒，**原生播放器開播**，畫面持續前進，buffer 16 秒、stalls 0；第二次從觀看記錄的 25 秒續播 |
| CMS `qq`（加媒體檢查前） | 14.5 秒「解出」云解的錯誤影片→原生失敗→MPV「mpv error -13」→ 促成第 3.2 節第 5 點的媒體檢查 |
| CMS `qq`（加媒體檢查後） | 約 15 秒顯示「設定的解析接口都沒有解出影片（試過：推荐、臻享、优选、ikun…XY）。可能是接口暫時失效，請換一條線路。」 |
| 奴娜《現在不是出軌的問題》`bsky3` 第 01 集 | 約 15 秒顯示同一則訊息（以前是「這一集沒有可播放的網址」） |
| 奴娜 同片 `jazsjzlp_1080p` 第 1 集 | 照舊由嗅探解出，resolve 4.4 秒，原生播放器開播（無退步） |

- 測完已把模擬器還原：`configSourceURL` 改回 `wang-movie.json`，刪除 demo 的已存來源、設定快取，以及觀看記錄、站點健康中的 demo 項目。操作中誤點換過 wang-movie 目前選中的站，沒有還原。
- 荐片的 VIP 線路：Simulator 沒找到帶官方平台連結的作品，只有離線測試涵蓋。

**結論**：機制在真實接口上可用（bilibili）。目前兩份設定裡原本需要解析的線路（奴娜 `bsky*`），這些接口解不出來，屬外部接口能力，不是程式缺陷。

## 6. 沒做的與後續

- 解析選單（手動選解析）、播放失敗自動換下一個解析、type 2／3、JAR 本機服務（`127.0.0.1:10079`）、站台 `click` 腳本。
- 畫質選單中其他畫質不解析（沿用既有 ponytail：只解析預設那一個）。

## 7. 回滾

`git revert <本任務 commit>`。設定、收藏、記錄、下載資料格式都沒改；舊版 App 讀到新的 `spider-pack/` 只會忽略 `jx`。

## 8. Ponytail

`ponytail:ponytail-review` 對最終 diff：1 項 `shrink`（`GlobalParse.plan` 為了換 header 重新逐欄建 `ParseEntry`，改成直接改 `header`），已套用。套用後回歸 417／417 通過。

## 9. 真機驗收

**使用者 2026-10-06 回報 `0.1.71 (72)` 真機驗收完成，沒問題。** 當時的驗收項目：

1. 設定裡有 `parses` 的來源，原本能播的線路照常（直接 m3u8、播放頁嗅探，例如奴娜的 `dyttm3u8`、`jazsjzlp_1080p`）。
2. 奴娜 `bsky3`／`bsky7`：約 15 秒後顯示「設定的解析接口都沒有解出影片…」，不會卡住，也不會開出無法播放的播放器。
3. 有官方平台連結、且解析接口解得出的線路（目前實測只有 bilibili 解得出）：能開播，畫質選單、字幕、續播位置正常。
4. 解析中換集、退出詳情頁：舊的解析不會蓋掉新播放。
5. 下載：需要解析的集數會在下載前解析，解不出時顯示同一則訊息。

## 目前狀態

- 程式、測試、文件完成；iOS build（最終程式再建一次 Release device，成功）與 Simulator 驗證完成；Ponytail 完成。
- 提交前 fetch：`origin/ios-poc` 與本地同為 `f730bd20`，沒有需要整合的新變更。
- **已隨 `0.1.71 (72)` 發布**（2026-10-06，run `37430560852`，tag `ios-v0.1.71-b72` → `ace72419`，見 IOS-POC-11「第七十二次發布」）。
- 真機驗收：使用者 2026-10-06 回報完成。任務結束。
