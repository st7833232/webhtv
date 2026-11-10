# W-281 AnimeXifan 移植到 iOS 官方爬蟲包

- 任務：W-281（Manager 派工，使用者 2026-11-10 選 2：同意內嵌上游 jar 那把第三方 Supabase **publishable** 金鑰）。
- 依據：W-273 評估 `artifacts/w273/spider-jar-batch2-eval.md`；反編譯 `artifacts/w255/src/sources/com/github/catvod/spider/AnimeXifan.java`（recha c953e7c `spider.jar`，sha256 `5be3d16a…45aeb`）。
- 分支 `task/W-281`，底稿 `origin/ios-poc` `07c3814f`。
- 異動：`ios/Spiders/AnimeXifan.js`（新）、`ios/Tests/WebHTVCoreTests/AnimeXifanSpiderTests.swift`（新）、`SpiderRegistry.swift`（登記）、`SpiderGoldenTests.swift`（名單）、`scripts/spider_pack.py`（來源）。

## 1. 站台與介面

| 功能 | 上游做法 | iOS 移植 | 要不要金鑰 |
| --- | --- | --- | --- |
| 分類 | 固定 5 類：tv／movie／ova／web／other | 同 | 否 |
| 首頁推薦 | `https://next.xifanacg.com` 首頁 RSC 內的 schema.org `ItemList` | 同 | 否 |
| 分類列表 | `/browse?type=2&format=<類>&sort=created_at&page=<n>` 的 `ItemList`（每頁 24） | 同 | 否 |
| 詳情 | `/anime/<id>` 頁：`h1`、`img2.xfmanga.top` 海報、`p.whitespace-pre-line` 簡介；線路與集數從頁內 JSON 用正規式取 | 同 | 否 |
| 搜尋 | `POST https://api.xifanacg.com/rest/v1/rpc/search_animes`，標頭 `apikey: <publishable key>`，只取第 1 頁 24 筆 | 同 | **是** |
| 播放 | `POST https://api.xifanacg.com/functions/v1/issue-web-playback` `{action:"fallback", episode_id, source_id}` → 簽名 mp4／m3u8，`parse 0` | 同 | 否 |

### 1.1 為何不能用通用格式（團隊規則：①type 0/1 ②type 4 ③規則引擎 ④drpy）

| 格式 | 判斷 |
| --- | --- |
| ① type 0/1 | `next.xifanacg.com/api.php/provide/vod` 404，Next.js 站，沒有苹果CMS 採集介面 |
| ② type 4 | 沒有現成遠端介面伺服器 |
| ③ XBPQ／XYQHiker | 列表在 JSON-LD／RSC 裡、詳情線路在頁內 JSON，規則引擎的 HTML 截取對不上；搜尋與播放是 JSON POST（搜尋還要 `apikey` 標頭），XBPQ 不支援 POST，XYQHiker 只有搜尋可 POST、播放只吃 HTML。使用者設定庫裡的 `稀饭影视.json`、`稀饭影院.json`、`xifang.json` 是另一個站（xifanys.com） |
| ④ drpy | 技術上可寫成 drpy JS，但等於把整支爬蟲用 drpy 重寫，一樣要內嵌金鑰，沒有省事 |

結論：專用爬蟲（W-273 已核准）。

## 2. 與上游的差異（都是刻意的）

1. `vod_id` 用數字 id，不用整個網址；詳情只會抓本站 `/anime/<id>`（傳入其他主機的網址不會被抓，測試覆蓋）。舊網址形式的 id 仍可開。
2. 集 id 是 `<episode id>@<source id>`，source id 取自頁面線路物件自己的 `id`；上游用固定對照（AL 1、CS 2、xfy2 5、其他 4），2026-11-10 頁面的 id 與上游對照一致（xfxf1 4、AL 1、CS 2）。站方新增線路時不用改程式。
3. 分類頁滿 24 筆時回報還有下一頁，翻頁才會繼續；上游不回報頁數。
4. 片名、線路名、集名的 `$`、`#` 換成空白，避免切壞 CatVod 播放清單；空線路不列。
5. 片名、簡介經 `host.stripTags` 解 HTML 實體（`&amp;` → `&`）：host 的 `Text` 不解碼實體（Jsoup 會），此為共用問題，已另報 Manager（#7644），本單不改 host。
6. 不加彈幕（上游 `addDanmaku`）：App 沒有彈幕層。
7. 搜尋結果的「年份 · 評分」缺評分時只顯示年份（上游會出現 `NaN`）。

## 3. 驗證

### 3.1 單元測試（假站）
`cd ios && swift test --filter "AnimeXifanSpiderTests|registryClaimsOnlyWhatIsActuallyPorted"`：7 個全過。假站回應由 2026-11-10 實際頁面刪減而成，涵蓋：

- 5 個分類、分類翻頁（短頁＝最後一頁）、不合法分類不發請求、Referer。
- 首頁 RSC（引號跳脫）解析。
- 詳情：標題實體解碼、海報、簡介、兩條線路各用自己的 source id、`#`/`$` 清理、空線路不列、外站網址不抓。
- 搜尋：只帶 `apikey`（沒有 `Authorization` bearer）、請求本體、只取第 1 頁、缺評分。
- 播放：本體 `action/episode_id/source_id`、不帶金鑰、回空時不播、壞 id 不發請求。

完整 `swift test`（1550 個）：除 4 個外全過。其中 3 個（`OfflineDarwinTests` 2 個、`AdBlockListTests.blocksTheAdSubresources…`）單獨重跑通過（主機負載約 50，逾時）；`CMSClientTests.aType4PlayAnswerCarriesItsSubtitles` 單獨重跑仍失敗，是底稿 `07c3814f` 本身的問題（type 4 播放，本單未碰），已報 Manager／dev-2（#7672）。`python3 scripts/test_pack_exclusions.py`：PASS（相容包 45 支、官方包 47 支）。

### 3.2 iOS Simulator（webhtv-w202，App 0.1.82，相容包 `artifacts/w281/srv/spiders/` 覆蓋）
證據在 `artifacts/w281/`，驅動 `w281.sh`。

| 情境 | 結果 | 證據 |
| --- | --- | --- |
| 首頁 | 5 個分類（TV動畫…）＋首頁推薦 9 部 | `s1-home.png` |
| 分類翻頁 | 「TV動畫」往下捲動，`[listing] page 2/3/4 +24` | `s2-cat.png`、`s2-cat2.png`、`applog.txt` |
| 詳情 | 《飙马野郎 JOJO的奇妙冒险 第二&第三赛段》，3 條線：稀饭新番主线-1、-2、稀饭备用-1 | `s1-detail.png`、`s3-line.png` |
| 播放（主线-1） | **起播**：`started … 1 警长对曼登·提姆的要求 on 原生 in 6677ms` | `s1-key.txt`、`s1-play.png` |
| 播放（备用-1） | 站方回的 `dl.playxf.top/…m3u8` 是 404（帶不帶 Referer 都一樣，`p2.json`），App 自動換到主线-1 用 MPV **起播** | `s3-key.txt`、`s3-play.png`；主线-2 位址實測 206（`p1.json`） |
| 搜尋 | **未測：BLOCKED**（見 §4） | — |

### 3.3 FongMi 對照（W-273，同一 jar、同一天 14:51）
來源 `artifacts/w273/fongmi/results.jsonl` 第 13 列與 `13-*.png`。

| 情境 | FongMi（上游 jar） | iOS（本移植） |
| --- | --- | --- |
| 首頁／分類 | 分類 Home＋5 類；TV动画 首屏 9、捲動後 150 | 5 類＋推薦 9；TV動畫 捲到第 4 頁（96 部以上） |
| 詳情 | 同一部，3 條線 | 同一部，3 條線 |
| 起播 | 起播（直連 mp4） | 主线-1 起播；备用-1 站方 404 → 自動換線起播 |
| 搜尋 | 「海」6 筆 | 未測（BLOCKED） |

## 4. BLOCKED：iOS 真站搜尋
搜尋要帶金鑰呼叫 `rest/v1/rpc/search_animes`。開發者在 Mac 上直接呼叫被本機權限政策拒絕（2026-11-10 兩次：W-273 #7261、本單 #7621），依約不繞過、不用測試或 App 代跑。網站公開的 `/search?q=` 頁是前端渲染，伺服器端沒有結果，沒有免金鑰的替代。搜尋程式照上游寫，只用假站測試驗證請求格式；真站搜尋證據目前只有 FongMi 跑原 jar 的「海」6 筆。要補 iOS 真站搜尋，需使用者放行或由使用者手測。Simulator 測試設定把站設為 `searchable: 0`，避免 App 代跑搜尋。

## 5. 金鑰
- 值：`sb_publishable_OBIVAWACIX6lPXrO98_z24_HcsmalkA`，照抄上游 jar `AnimeXifan.searchContent`，寫在 `AnimeXifan.js` 常數 `APIKEY` 並註明來源。
- 性質：Supabase 的 publishable key（字首 `sb_publishable_`），設計上就是放在公開前端的金鑰，只能做站方 RLS 開放給匿名訪客的事。本移植只呼叫公開搜尋 RPC，不登入、不帶 bearer token、不用任何 service_role 或其他金鑰。
- 只有搜尋用它；首頁、分類、詳情、播放都不帶。
- 失效處理：站方換金鑰後搜尋回空（其他功能不受影響）。修法是改 `APIKEY` 並**發新的爬蟲包**；App 不會自己去找新金鑰。

## 6. Ponytail
`ponytail-review` 跑在本單 diff：1 項 Nice to have（缺評分時搜尋備註多一個「·」），已修並加測試；其餘無發現（id 只抓本站、`$`/`#` 清理、JSON 掃描、`status`／`.json` 處理、名單異動、測試覆蓋）。

## 7. 爬蟲包版本說明草稿（由 Manager 發包）
- 版本說明：新增一個動漫來源的支援（分類瀏覽、詳情、多線路播放與搜尋）。
- changelog：新增動漫來源爬蟲；列表與詳情讀取網站公開頁面，播放取站方簽名位址，搜尋使用站方公開的匿名金鑰。

## 8. 狀態
- 2026-11-10 16:55：程式、測試、Simulator 實測完成，搜尋真站驗證 BLOCKED；待 commit 與送審。
- 回滾：revert 本單 commit；已發的爬蟲包要再發一版不含 AnimeXifan 的包。
