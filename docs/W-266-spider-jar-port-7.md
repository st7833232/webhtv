# W-266 spider.jar 第一批 7 支移植到 iOS 官方爬蟲包

- 工單：W-266（SPIDER-JAR-PORT-7），依據 W-255 盤點 `artifacts/w255/spider-jar-triage.md` 第一批。
- 分支：`task/W-266`（自 ios-poc `fdc24d73` 開，2026-11-10 11:36 快轉到 ios-poc `3967892b`；guard 在新底稿重開，舊狀態封存於 `.codex/task-state/W-266-stale-before-ff-1411`）。
- 來源 jar：recha `c953e7c` 的 `spider.jar`（sha256 `5be3d16a600bb1a9cbf74810070ad098d4a43b8b4a0e2b947a7c58156bc45aeb`），反編譯於 `artifacts/w255/src/sources/com/github/catvod/spider/`。
- 證據目錄：`.herdr-synapse/webhtv-dev/artifacts/w266/`（Simulator 截圖 `s<n>-*.png`、App 日誌 `applog.txt`、起播摘錄 `sim-started.txt`、引擎層真站 `engine/live*.txt`、FongMi `fongmi/`）。

## 1. 完成句與範圍

7 個 spider.jar 類別（Yidong4K、AnimeHuazi、XingChen、AnimeGiri、AppFox、AnimeBashi、SaoHuo）改寫成 iOS 官方爬蟲包的 JS 爬蟲，登記到 `SpiderRegistry`、`SpiderGoldenTests` 名單與 `scripts/spider_pack.py` 來源表，並有假站單元測試。不做驗證碼／人機驗證繞過，不碰站方封鎖。發包由 Manager 經使用者授權（第 16 包與 XYQHiker 一起）。

變更檔案：

| 檔案 | 內容 |
| --- | --- |
| `ios/Spiders/{Yidong4K,AnimeHuazi,XingChen,AnimeGiri,AppFox,AnimeBashi,SaoHuo}.js` | 7 支爬蟲 |
| `ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift` | `ported` 加 7 個類別 |
| `ios/Tests/WebHTVCoreTests/SpiderGoldenTests.swift` | 已載入腳本名單加 7 個 |
| `ios/Tests/WebHTVCoreTests/W266PortSpiderTests.swift` | 11 個假站測試 |
| `scripts/spider_pack.py` | `DEFAULT_ORIGINS` 加 7 個（同一個 jar 與 sha256） |

## 2. 各站做法與和上游的差異

| 類別 | 站點型態 | 和上游不同（刻意） |
| --- | --- | --- |
| Yidong4K | JSON POST 片單；每部片是一個**移動雲盤（139）公開分享**（W-255 寫「直連」有誤，抽 3 類 12 部全是 139 分享） | 上游交給 `Pan` 基底的 139 解析；這裡只移植 139 匿名分享（`getOutLinkInfoV6` AES-CBC IV 前置加密列目錄、`getContentInfoFromOutLink` 取 HLS），用既有 `host.aesEncryptIV/aesDecryptIV`。非 139 分享不列線路（不驅動其他雲盤）。播放回傳分享本身的 master m3u8，由播放器選畫質（上游自己改寫成 2160/1080/720/480 清單）。資料夾最多走 3 層，多資料夾時集數名前加 `[資料夾]`。播放不需 Referer（已實測）。 |
| AnimeHuazi | 純 JSON API；播放走站方 `/api/play/resolve` | 搜尋站方回 `4001 需要验证码` → 空結果（上游相同，不解驗證碼）；關鍵字改 URL 編碼。 |
| XingChen | shoutu HTML；播放頁 player JSON 取 m3u8 | vod_id 改純數字；未知標籤列不再黏到前一列；站方字面 `&nbsp;` 清掉；集數改用 `li a.this-link`（上游寫法在 host 選擇器下只取第一集）。 |
| AnimeGiri | maccms JSON API；集數直連 HLS | 詳情海報為相對路徑時接 `jpg.girigirilove.com`（上游接 `m3u8.` 主機會 404）；搜尋關鍵字 URL 編碼。 |
| AppFox | ext 指定主機的 Appfox App API | 只移植 Appfox API 路徑（host／apiDomain、ver、ua、parse 表、custom_first、category 0/1、timeout、from）；**`cms` 與 `category: 2` 不移植**（唯一已知設定 `{"host":"http://nico.oiio.fun","ver":"2"}` 沒用到）。修上游兩個 bug：分類篩選每個 key 都送「地區」值、排序從未送出。集數 id 改 `playerCode@網址`（丟掉只給 TVBox 代理彈幕用的片名）。config 每個 session 讀一次。都解析不到時回 `jx: 1` 交 App 的全域解析（同上游）。 |
| AnimeBashi | HTML 片單；播放頁 iframe → hhplayer `/api/parse` | 修上游 導演／主演 對調；vod_id 改純數字；線路名用站方分頁名。 |
| SaoHuo | ext 主機或 `shapp.us` 鏡像頁第一個網址（同上游）；HTML | 類型篩選真的套用（上游有選單但沒用），動漫篩選掛在 4（上游掛在不存在的 3）；vod_id 改路徑（鏡像換網址不影響紀錄）；cookie 用 host 每 session 的 cookie jar；主演去掉尾巴「剧情介绍」、簡介去掉站方宣傳句。**播放：2026-11-09 抽查的播放頁 iframe 都是 hhplayer（與 AnimeBashi 同一個解析器），改走其 `/api/parse` 直接拿 m3u8；解析失敗或非 hhplayer 才照上游 `parse: 1` 交嗅探。** |

### 2.1 為何不能用通用格式（團隊規則 2026-11-10：①type 0/1 苹果CMS ②type 4 ③規則引擎 ext ④drpy）

2026-11-10 11:4x 實測各站 `/api.php/provide/vod/?ac=list`。type 4 需要另架遠端介面伺服器，7 站都沒有現成的，下表不再逐列重複。

| 類別 | ① type 0/1 | ③ 規則引擎（XBPQ／XYQHiker／AppYsV2） | ④ drpy | 結論 |
| --- | --- | --- | --- | --- |
| Yidong4K | 無採集介面（片單是自訂 JSON POST） | 影片在 139 雲盤加密分享：列目錄要 AES-CBC 加密請求、再呼叫第二支 API 取 HLS，規則引擎做不到 | 要寫等同爬蟲的自訂 JS | 專用爬蟲 |
| AnimeHuazi | `provide/vod` 404；站方是自訂 REST JSON | 規則引擎吃 HTML 或 AppYs 格式，對不上；播放要再打 `/api/play/resolve` | 同上，要自訂 JS | 專用爬蟲 |
| XingChen | 站方對本機 IP 回 444，無法確認有沒有採集介面 | 首頁／分類是苹果CMS 網頁版型，XBPQ **可能**接得上，但詳情與播放被 444 擋住無法驗證 | 同 ③ | 先維持專用爬蟲（移植自上游）；站方恢復後可再評估 XBPQ |
| AnimeGiri | **type 1 部分可接**：`https://m3u8.girigirilove.com/api.php/provide/vod/` 可分頁、搜尋（「海」23 筆）、直連 m3u8 播放（免 Referer）。但 ①海報網址指向 `m3u8.` 主機，全部 404（圖實際在 `jpg.` 主機，type 1 不能改寫）②分類只回 日番／美番／4K杜比，真人番剧、剧场版、BD副音轨、演唱会 4 類 `t=` 無效 ③沒有首頁推薦 | — | — | 保留專用爬蟲（海報與 6 個分類完整）；type 1 可當退路。已依規則回報 Manager（#7370），Manager #7372 同意保留 |
| AppFox | `provide/vod` 回 `closed`（站方關閉） | 走 `/api.php/Appfox/` App API（ver、UA、解析表），不是 AppYsV2 的 `app/`、`v1.vod` 格式 | 要自訂 JS | 專用爬蟲 |
| AnimeBashi | `provide/vod` 回 `closed` | 片單／詳情是苹果CMS 網頁，XBPQ 可解析；但播放要呼叫 hhplayer `/api/parse` 取 m3u8，XBPQ 只能交嗅探（iOS 對 hhplayer 嗅探未驗證） | 要自訂 JS 才能直解 | 專用爬蟲；hhplayer 直解若之後有第三個站用到，可考慮加進通用規則引擎（列入 W-274 盤點） |
| SaoHuo | 測試時 `shdy2.com` 回 Cloudflare 522，鏡像主機會換 | 同 AnimeBashi（hhplayer）；另外主機要從 `shapp.us` 鏡像頁動態取得，規則引擎做不到 | 要自訂 JS | 專用爬蟲（同上，hhplayer 列入 W-274） |

共通：host 規則 `host.pdfh(node, 'href')` 這種單段規則會被當選擇器，取節點本身屬性要寫 `a&&href`（XingChen、SaoHuo 已修，測試覆蓋）。

## 3. 驗證

### 3.1 單元測試（已驗證）

`cd ios && swift test --filter "W266PortSpiderTests|registryClaimsOnlyWhatIsActuallyPorted"`：12 個全過（W266PortSpiderTests 11 個＋golden 名單）。完整 `swift test`：1511 個全過（底稿 `fdc24d73`）；快轉到 `3967892b` 後重跑 1520 個，只有 `AdBlockListTests.blocksTheAdSubresourcesWithoutTouchingThePageOrOverMatching` 在主機負載 43 時 20.9 秒逾時失敗，單獨重跑 1.8 秒通過（與爬蟲無關，負載造成）。`python3 scripts/test_pack_exclusions.py`：PASS（相容包 44 支、官方包 46 支）。假站回應由 2026-11-09 各站真實回應刪減而成；139 分享回應在測試內用 CommonCrypto 加密，並解密檢查請求的 `pCaID`／`linkID`。

### 3.2 iOS 引擎層真站（App 同一個 `JavaScriptSpiderRuntime`＋真實 URLSession，暫時探測檔不 commit）

證據 `artifacts/w266/engine/live*.txt`（2026-11-09 17:2x–17:38、2026-11-10 09:4x，熱點網路）。

| 類別 | 首頁 | 分類第 1／2 頁 | 搜尋 | 詳情 | 播放 |
| --- | --- | --- | --- | --- | --- |
| Yidong4K | 無首頁推薦（上游亦無），App 首頁顯示第一分類 9 部 | 9／9，共 36 頁 324 部 | 「海」5 筆 | 移动云盘 1 線 1 集 | 139 HLS master |
| AnimeHuazi | 10 | 24／24，共 160 頁 | 「海」空（站方驗證碼 4001） | 1 線 31 集 | bytepluscdn mp4 |
| XingChen | 10 | 56／56（17:2x） | 444 | 詳情 OK 一次，之後 444／-1005 | 站方斷線 |
| AnimeGiri | 10 | 20／20，共 158 頁 | 「海」24 筆 | chs／cht 2 線 | 直連 m3u8 |
| AppFox | 27 | 30／30 | 「喜欢」20 筆 | 線路名「花柳斋\|B线 (bfzym3u8)」 | 直連 m3u8＋UA 標頭 |
| AnimeBashi | 無首頁推薦（上游亦無） | 36／36，共 10 頁 | 「全民」21 筆 | 1 線 482 集 | gtimg mp4 或 hhplayer m3u8 |
| SaoHuo | 6 | 36／36 | 「野兽之心」1 筆 | 1 線 | hhplayer m3u8（parse 0） |

### 3.3 iOS Simulator（App 0.1.82＋相容包覆蓋這 7 支，`w243/work/srv/spiders/` 經 18445 提供）

起播摘錄 `artifacts/w266/sim-started.txt`，截圖 `s<n>-{home,detail,play}.png`：

| 類別 | 結果 |
| --- | --- |
| Yidong4K | 首頁 9 部 → 詳情 → 原生起播（3 個畫質，緩衝 60s、stalls 0） |
| AnimeHuazi | 首頁 10 部 → 原生起播 |
| AnimeGiri | 首頁 10 部 → 原生起播 |
| AppFox | 首頁 27 部 → 原生起播（11-09 一次失敗是當時網路切換：主機解析不到；11-10 重測兩條線 m3u8 都可取，起播成功） |
| AnimeBashi | 「末世钞能力者」原生起播。「界门之下」失敗：hhplayer 給的清單片段在愛奇藝 CDN，片段回 `405 {"code":"D8013"}`（換 Referer／UA 皆同）＝片源端拒絕，非爬蟲問題 |
| SaoHuo | 首頁 6 部 → 原生起播（hhplayer 直解，沒有走嗅探） |
| XingChen | 首頁（分類）56 部；詳情停在「載入詳情」：站方對本機 IP 回 nginx 444（首頁 200、分類與詳情 444），不繞過 |

另發現（本單範圍外，未修）：設定檔只有 `csp_*` 站、沒有任何 type 1 站時，App 顯示「尚未載入設定」；加一個 type 1 佔位站即正常。

### 3.4 FongMi（Android 5560）對照

FongMi 5.8.4＋上游 `spider.jar`、設定 `artifacts/w255/work/srv/w255-test.json`，2026-11-10 10:04–11:46 由 dev-2 實測 6 站、claude-dev 補 AppFox。證據 `artifacts/w266/fongmi/`：`results.jsonl`（每站一列或多列）、`NN-{home,cat-scrolled,detail,search}.png`、`NN-log.txt`，驅動 `run.py`／`lib.py`。

| 類別 | 分類（首屏／捲動後） | 詳情 | 起播 | 搜尋 | 和 iOS 比較 |
| --- | --- | --- | --- | --- | --- |
| Yidong4K | 9／99 | 「茫然女王」，線路 移动普画#1，畫質 2160／1080／720／480 | **起播**（1080；2160 是模擬器解碼器不支援 3840x1608，非站方問題） | 「海」5（dev-2 手動搜尋；自動化一次逾時記成 0） | 一致 |
| AnimeHuazi | 9／138（「TV动画」） | 「学生会也有洞！」，花子-D线 | **起播** | 「海」0（站方驗證碼） | 一致 |
| XingChen | 9／98 | 「我最丑陋的真相」，天王 | 失敗 `Unable to load url` | 「海」0（XingChen 沒有回應，同 iOS 444） | 一致：兩平台播放都被站方擋 |
| AnimeGiri | 9／126（「日番」） | 「化物语」，chs | **起播** | 「海」6 | 一致 |
| AppFox | 9／138 | 「超超超超超喜欢你的100个女朋友第二季」，花柳斋\|R线、F线 | **起播** | 「喜欢」6 | 一致 |
| AnimeBashi | 9／138 | 「宗门修仙传」，线路1 | 失敗 `Timed out` | 「全民」6 | iOS 較好：iOS 起播（「末世钞能力者」）；FongMi 那部可能是愛奇藝片源（iOS 同類片源也 405） |
| SaoHuo | 9／107（「电影」） | 「谷雨」，**沒有線路** | 失敗 `No play data` | 「野兽之心」1 | iOS 較好：上游在 FongMi 取不到線路；iOS 移植改走 hhplayer 直解後起播 |

結論：5 站兩平台一致可播；SaoHuo、AnimeBashi 在 iOS 可播、FongMi 上游 jar 不行（上游問題，不影響 iOS 上包）；XingChen 兩平台都被站方限流。

補測（2026-11-10 13:38–13:59，claude-dev，#7359 dev-2 更正）：AnimeHuazi、SaoHuo、AnimeGiri 第一個分類是「Home」推薦頁，改量第二個分類的翻頁；XingChen、SaoHuo 搜尋重跑。各站以 `results.jsonl` 該站最後一筆為準。

## 4. 不可行或有限制的站

- XingChen：**站方限流、目前不可用**。站方對本機 IP 限流／封鎖（444、連線中斷），iOS 只驗到首頁與分類；FongMi 上游 jar 同樣播不了（`Unable to load url`）。程式照上游，限流時回空，不繞過。依 Manager #7209，不擋其他 6 支；照常上包，站方恢復即可用。
- AnimeHuazi 搜尋：站方要求驗證碼，回空（兩平台相同，不繞過）。
- AnimeBashi／SaoHuo：部分片源（愛奇藝片段）在 CDN 端被拒，與平台無關。
- AppFox：`cms`、`category: 2` 未移植（無設定使用）。

## 5. 爬蟲包版本說明草稿（第 16 包，和 XYQHiker 一起；只寫能力）

- 新增 7 個來源的 iOS 爬蟲：雲盤分享影片站（可直接播放公開分享的影片）、兩個動畫 API 站、兩個以網頁解析器取片的動畫／影視站、一個 App API 影視站（支援分類篩選）、一個網頁影視站（播放頁直接解析，不必嗅探）。
- 修正上游問題：分類篩選沒有套用或送錯值、導演與主演對調、詳情海報網址錯誤、多集只顯示第一集。
- 需要驗證碼的搜尋維持空結果，不繞過。

CHANGELOG 由發包 workflow 依 `release_notes` 寫入；發包時請用 `spider_pack.py` 從 `ios/Spiders` 重產。

## 6. 回滾

單一 commit：revert 即移除 7 支腳本與登記；已發的爬蟲包回滾為發下一包時不帶這 7 支（App 端沒有這些類別就顯示「未移植」，不影響其他站）。

## 7. Ponytail

2026-11-10 對最終 diff 跑 `ponytail:ponytail-review`，三項全部在範圍內修掉：
1. （必修）AnimeBashi 分頁數用 `[\s\S]*/list-…` 正則，頁面沒有分頁連結時回溯，74KB 頁 node 實測 3.8 秒 → 改全域掃描取最大頁碼（0 ms）。
2. （應修）AppFox 首頁影片 UA 沒有照上游退回 `ua.home` → 改 `ua.homeVideo ? 'homeVideo' : 'home'`。
3. （應修）補測試：AnimeBashi 無分頁頁面 pagecount 為 1；AppFox 首頁影片請求帶 `ua.home`。

## 8. 狀態與下一步

- 狀態：`774f1daf` Reviewer APPROVE（#7402，`artifacts/w266-review-reviewer2.md`）。
- 審查非阻擋項：N-1 SaoHuo 的 `SpiderRegistry` 註解與 `spider_pack.py` notes 原寫「嗅探 parse 1」，已改成「hhplayer 直解，失敗才嗅探」（notes 會進包，第 16 包前修）；N-2 本節已更新；N-3 Yidong4K 每層目錄只取 200 筆（已知限制，記錄不改；超過的分享目錄會少列集數）；N-4 只有 csp 站時顯示「尚未載入設定」為範圍外，由 Manager 決定是否開單。
- Ponytail（N-1 修正 diff）：無發現；`test_pack_exclusions` PASS。
- 下一步：Manager 推 ios-poc；發第 16 包用 `spider_pack.py` 從 `ios/Spiders` 重產。
