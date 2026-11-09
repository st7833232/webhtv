# W-249 wang-movie 只有 iOS 失敗的站

## Recovery anchor
- 目標：wang-movie（GitLab 2a74b1f）裡「Android 能播、iOS 失敗」的 5 站＋drpy 3 站，逐站找根因；iOS 能小修的修並補測試，站方／網路問題寫證據。不改設定檔（建議交 Manager）。
- 狀態（2026-11-09 11:40）：8 站都有結論；iOS 缺陷 2 個（無水 T4、Uvod 備用）已修，Simulator 實播完成，送審。
- 下一步（唯一）：等 Reviewer 審查。
- 探測工具（已刪，未提交）：臨時 `ios/Tests/WebHTVCoreTests/W249ProbeTests.swift`，`cd ios && W249_SITE='<站 JSON>' [W249_BASE=<設定網址>] swift test --filter w249Probe`。

## 逐站結論（熱點 en0 172.20.10.6，2026-11-09）
| 站 | iOS 重現 | 根因 | 處理 |
|---|---|---|---|
| 三秋（csp_App3Q） | 502 不再重現；首頁 6 部、詳情 2 線 | 兩線 decode 都回 `bubutv.top/video_close_site.mp4`＝站方「即將關站」10.5 秒公告片 | 站方，兩平台同；建議移除 |
| 飛魚（csp_Feiyu） | 第一條「4K」線解析回空 | 4K 線的解析服務 `zanelee.jdyx.pro` 回 `{"code":404,"msg":"解析失败"}`；西瓜、如意線 iOS 解出 m3u8 且片段 200 video/mp2t，極速線逾時。Android 預設 `player_auto_change`（`VideoActivity.checkFlag→nextFlag`）失敗自動換下一條線，iOS 沒有這個功能 | 手動換線即可播。iOS 自動換線屬新播放行為，建議 Manager 另開單（需設計） |
| 紅果短剧｜瀟灑（csp_XBPQ） | 詳情只有 1 集「全集完结」 | 網站本來就只放 1 集（整部合併）；片源 CDN `vodcnd16.tix8opu.cn`、`vodcnd10a.myqqdd.com` 在 Google／Cloudflare／阿里 DNS 都無 A 記錄，站內解析播放器 `huaqi.live` 連不上 | 站方，建議移除 |
| 無水｜(T4)（type 4） | 首頁 0 部 | **iOS 缺陷兩處**：①把 `ext` 物件拆成多個 query 參數，站方要的是 Android `SiteApi.call` 那種 `extend=<ext 原文>`，否則回 `{"msg":"module_name is null"}`；②type 4 首頁本身有 20 部片，iOS 卻丟掉改抓第一個分類（电影 t=1，上游該上層分類是空的） | **已修**（見下）。片源 `*.wsyzym3u8.com`／`*.wsyzyts.vip` 在此熱點的電信 DNS 被 RPZ 導到 `rpz10-landing` 自簽頁；改用公共 DNS 的 IP 取片段 200 video/mp2t。熱點下實播會失敗屬網路環境 |
| Uvod｜備用（py） | Simulator 首頁「載入失敗：The data couldn’t be read because it isn’t in the correct format.」 | **iOS 缺陷**：腳本 `homeVideoContent` 的 `vod_remarks` 是數字（集數 5），`Vod` 對 remarks 嚴格解成字串，丟錯讓整份片單解碼失敗；Android Gson 會把數字讀成文字 | **已修**（R1，見下） |
| 爱动漫（drpy 爱弹幕）、爱动漫（爱弹幕[漫]） | `drpy could not fetch cheerio.min.js: HTTP 404` | ①共用：GitLab 906118ff（10-30）把 `drpy_libs/cheerio.min.js`、`crypto-js.js` 移到 `_unused/`，iOS 從設定同源下載並驗 sha256，Android 內建不受影響；②補回後：`anime.girigirilove.com` 301 自我循環，新站改需登入 SPA | ①建議 Manager 移回兩檔（大小／sha256 與 `DrpyEngine.dependencies` 一致，#6547）；②站方，兩平台壞，建議移除 |
| 七色番动漫（drpy） | 同上 404 | 同①；補回後（指向 08d25173）首頁 24 部、詳情 2 線、兩線都解出 mp4 | 移回兩檔即可 |

## 程式修正 R1（Uvod 備用）
- `CMSClient.swift` `Vod.init(from:)`：`remarks` 改用 `decodeText`（字串或整數，其他讀成空），和 year／area 一致。
- 測試：`VodMetadataTests.oddlyTypedMetadataNeverDropsASearchResult` 加一筆 `"vod_remarks":5`，要讀成 "5" 且整頁不掉；反證：換回舊程式即失敗。`swift test --filter "VodMetadata|CMSClient|SourceClient"` 通過。Ponytail review：Ship。

## Simulator 實播（2026-11-09，webhtv-w202，Debug，設定＝正式 GitLab main `wang-movie.json`，證據 `.herdr-synapse/webhtv-dev/artifacts/w249/`）
| 站 | 結果 |
|---|---|
| 無水｜(T4) | 首頁「已載入 20 部」（修正前 0 部）→ 詳情 → 播放網址解出；播放時 `NSURLError -1202 安全連線失敗`：片源網域被熱點電信 DNS RPZ 導到自簽頁（`wushui-*`）。換一般網路才能實播，未驗 |
| 飛魚 | 首頁 50 部；詳情 4 線；手動選「西瓜資源」第 01 集，原生 1694 ms 起播（`feiyu-xg-*`） |
| 七色番动漫 | GitLab d66e021 補回函式庫後 drpy 正常：首頁、詳情、解析 12 s；線 1 片源 `groupvideo.photo.qq.com` 404（站方），手動選「線路空1」第 01 集原生 7215 ms 起播（`qise*`） |
| Uvod｜備用 | R1 後首頁「已載入 10 部」，「異能研究所 第二季」第 1 集原生 3902 ms 起播（`uvod2-*`）；修正前「載入失敗」（`uvod-*`） |

## 程式修正（無水 T4）
- `ios/Sources/WebHTVCore/CMSClient.swift` `requestURL`：`ext` 原文以 `extend` 送出（取代 search 自帶的空 `extend`），不再拆成參數；`home()`：type 4 首頁有片就用，沒有才補第一個分類。
- `ios/Sources/WebHTVCore/WebHTVConfig.swift`：移除只剩拆參數在用的 `Site.ext`（`rawExtJSON` 保留）。
- 行為差異：`采集集合`（`ext:"0"`）現在也會送 `extend=0`，與 Android 一致；伺服器因此多列一個分類「瑟瑟采集资源」（Android 本來就有）。
- 驗證：`swift test --filter "CMSClient|ConfigLoader|…|SourceClient"` 58/58 通過；真站探測無水首頁 20 部→詳情→播放網址 m3u8。首頁分支沒有單元測試（`CMSClient` 無可注入 session），以真站探測證明。
- Ponytail review（2026-11-09，rebase 到 4245fca4 後）：Ship；1 項建議——type 4 首頁分支沒有單元測試（`CMSClient` 不能注入 session），先以真站探測為證，未加注入點。
- 飛魚、七色番第 1 條線失效需手動換線：iOS 缺 Android 預設的「播放失敗自動換下一條線」，建議另開單。
