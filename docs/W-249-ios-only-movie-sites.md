# W-249 wang-movie 只有 iOS 失敗的站

## Recovery anchor
- 目標：wang-movie（GitLab 2a74b1f）裡「Android 能播、iOS 失敗」的 5 站＋drpy 3 站，逐站找根因；iOS 能小修的修並補測試，站方／網路問題寫證據。不改設定檔（建議交 Manager）。
- 狀態（2026-11-09 10:20）：8 站都有結論，無水 T4 的 iOS 修正已 commit；**Simulator 實播還沒做**（Manager #6539 改派 W-252 優先，W-249 停在這裡）。
- 下一步（唯一）：Simulator（設定網址用 archive 前的 GitLab `08d25173…/wang-movie.json`，含 drpy 函式庫）實播 無水、飛魚（手動選西瓜線）、七色番，並看 Uvod 備用在 iOS Python 的實際錯誤。
- 探測工具：未追蹤的 `ios/Tests/WebHTVCoreTests/W249ProbeTests.swift`（不提交），`cd ios && W249_SITE='<站 JSON>' [W249_BASE=<設定網址>] swift test --filter w249Probe`。

## 逐站結論（熱點 en0 172.20.10.6，2026-11-09）
| 站 | iOS 重現 | 根因 | 處理 |
|---|---|---|---|
| 三秋（csp_App3Q） | 502 不再重現；首頁 6 部、詳情 2 線 | 兩線 decode 都回 `bubutv.top/video_close_site.mp4`＝站方「即將關站」10.5 秒公告片 | 站方，兩平台同；建議移除 |
| 飛魚（csp_Feiyu） | 第一條「4K」線解析回空 | 4K 線的解析服務 `zanelee.jdyx.pro` 回 `{"code":404,"msg":"解析失败"}`；西瓜、如意線 iOS 解出 m3u8 且片段 200 video/mp2t，極速線逾時。Android 預設 `player_auto_change`（`VideoActivity.checkFlag→nextFlag`）失敗自動換下一條線，iOS 沒有這個功能 | 手動換線即可播。iOS 自動換線屬新播放行為，建議 Manager 另開單（需設計） |
| 紅果短剧｜瀟灑（csp_XBPQ） | 詳情只有 1 集「全集完结」 | 網站本來就只放 1 集（整部合併）；片源 CDN `vodcnd16.tix8opu.cn`、`vodcnd10a.myqqdd.com` 在 Google／Cloudflare／阿里 DNS 都無 A 記錄，站內解析播放器 `huaqi.live` 連不上 | 站方，建議移除 |
| 無水｜(T4)（type 4） | 首頁 0 部 | **iOS 缺陷兩處**：①把 `ext` 物件拆成多個 query 參數，站方要的是 Android `SiteApi.call` 那種 `extend=<ext 原文>`，否則回 `{"msg":"module_name is null"}`；②type 4 首頁本身有 20 部片，iOS 卻丟掉改抓第一個分類（电影 t=1，上游該上層分類是空的） | **已修**（見下）。片源 `*.wsyzym3u8.com`／`*.wsyzyts.vip` 在此熱點的電信 DNS 被 RPZ 導到 `rpz10-landing` 自簽頁；改用公共 DNS 的 IP 取片段 200 video/mp2t。熱點下實播會失敗屬網路環境 |
| Uvod｜備用（py） | 未在 Simulator 重現 | Mac CPython＋iOS `base/spider.py` 跑 Uvod.py：首頁 7 類、homeVideo 10 部、詳情有集、播放解出 m3u8 → 站方正常，問題在 iOS 執行環境 | 待 Simulator 看實際錯誤 |
| 爱动漫（drpy 爱弹幕）、爱动漫（爱弹幕[漫]） | `drpy could not fetch cheerio.min.js: HTTP 404` | ①共用：GitLab 906118ff（10-30）把 `drpy_libs/cheerio.min.js`、`crypto-js.js` 移到 `_unused/`，iOS 從設定同源下載並驗 sha256，Android 內建不受影響；②補回後：`anime.girigirilove.com` 301 自我循環，新站改需登入 SPA | ①建議 Manager 移回兩檔（大小／sha256 與 `DrpyEngine.dependencies` 一致，#6547）；②站方，兩平台壞，建議移除 |
| 七色番动漫（drpy） | 同上 404 | 同①；補回後（指向 08d25173）首頁 24 部、詳情 2 線、兩線都解出 mp4 | 移回兩檔即可 |

## 程式修正（無水 T4）
- `ios/Sources/WebHTVCore/CMSClient.swift` `requestURL`：`ext` 原文以 `extend` 送出（取代 search 自帶的空 `extend`），不再拆成參數；`home()`：type 4 首頁有片就用，沒有才補第一個分類。
- `ios/Sources/WebHTVCore/WebHTVConfig.swift`：移除只剩拆參數在用的 `Site.ext`（`rawExtJSON` 保留）。
- 行為差異：`采集集合`（`ext:"0"`）現在也會送 `extend=0`，與 Android 一致；伺服器因此多列一個分類「瑟瑟采集资源」（Android 本來就有）。
- 驗證：`swift test --filter "CMSClient|ConfigLoader|…|SourceClient"` 58/58 通過；真站探測無水首頁 20 部→詳情→播放網址 m3u8。首頁分支沒有單元測試（`CMSClient` 無可注入 session），以真站探測證明。
- 未做：Simulator 實播、Ponytail review（送審前跑）。
