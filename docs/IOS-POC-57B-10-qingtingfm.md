# IOS-POC-57B-10：蜻蜓FM（qist `csp_QingtingFM`）

> Recovery anchor（2026-10-12 17:12 CST）：已實作，單元測試、全測試與 Simulator 直播實播通過（W-77，guard `QIST-QINGTINGFM-IMPL`，`--no-tag`）。設計：`.herdr-synapse/webhtv-dev/artifacts/qist-qingtingfm-gate-2026-10-12.md` D1–D6（W-64 PASS）；資料閘門 W-55 PASS；使用者 2026-10-12 核准實作（W-71）。下一步：Reviewer code review。

## 來源

- 設定：dianshi:105「蜻蜓 • FM」`csp_QingtingFM`（`searchable 0`，`style.type list`）。JAR：qist/tvbox `spider.jar` sha256 `72a1f3928eca281d878e44fc57162ff6a1f3ef779a2da05a2b351b241b110d69`；`QingtingFM.java` 101 行，sha256 `d01569c0dc2ead54d1d5b7dd00869206033e9caa8ae50d0026b5f8a89b9d2d37`。

## 改動

| 檔案 | 內容 |
|---|---|
| `ios/Sources/WebHTVCore/Resources/Spiders/QingtingFM.js`（新） | 設計 D2／D3：UA（Chrome 151）＋`Referer: https://www.qtfm.cn` 用在分類、詳情、播放；首頁上游 44 類、順序照上游、不連網；分類 `POST https://webbff.qtfm.cn/www`，body 為上游 GraphQL 原文字串（含 `\n` 與縮排），`cid`（`extend.cateId` 有值時取代 `tid`）與 `pg` **先驗證為整數才插入**，否則不發請求；單筆 `id` 轉字串後不是純數字就略過；圖片只有 `//` 開頭才補 `https:`；`pagecount` 照上游（不足 12 筆＝目前頁，否則＋1）、`limit 12`；詳情 `GET https://webapi.qtfm.cn/api/pc/radio/<id>`，`id` 與 `album.id`（數字，先轉字串）都必須是純數字，`vod_play_url = title$album.id`（標題 `$`／`#` 換空白）；播放 `https://lhttp-hw.qtfm.cn/live/<id>/64k.mp3`＋同一組 header；搜尋回空、不發請求（設定 `searchable 0`，不移植 `searchResultsPage`） |
| `ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift` | `ported` 加 `QingtingFM` |
| `ios/Tests/WebHTVCoreTests/SpiderGoldenTests.swift` | 預期清單加 `QingtingFM` |
| `ios/Tests/WebHTVCoreTests/QingtingFMSpiderTests.swift`（新） | D5 八組測試；fixture 為 W-55 的 `radioPage-217-p1.json`（12 台，`4b41c6c8…`）與 `radio-1259.json`（`a9875ab5…`），raw deflate＋base64 內嵌、驗 sha256；GraphQL body 與 gate 的 `radioPage-request.json` 逐字比對 |
| `scripts/spider_pack.py`、`spider-pack/` | `DEFAULT_ORIGINS` 加 `QingtingFM`（`spider.jar` `72a1f392…`，只用 base host API：`host.post`、`host.get`、`host.result`）；相容包重建為 `2026-10-12.9`（28 支）：與 `2026-10-12.8` 比只新增 QingtingFM、舊 entry 全部不變，pack 與內建同 blob `40e2b5f2…`；`verify` 0 problems |

## 驗證

| 項目 | 結果 | 證據 |
|---|---|---|
| 單元測試 | `QingtingFMSpiderTests` 8 個＋`registryClaimsOnlyWhatIsActuallyPorted` 全過 | `artifacts/w77-logs/w77-tests.log` |
| 全測試 | `swift test --package-path ios` 一次：1123 個全過 | `w77-full.log` |
| 相容包 | build／verify 0 problems；只新增 QingtingFM | `w77-pack.log` |
| Ponytail review | Ship，沒有 finding | — |
| Simulator 直播實播（iPhone 18 Pro／iOS 27.0，checkout＝`3fb9be02`＋本次修改） | `QingtingFM.js` 在 checkout／.app／容器三處 sha256 `9dcf8308…`；選「蜻蜓 • FM」→ 44 類順序正確，App 自動載入「廣東」→ 廣東 12 台／頁、第一台廣東珠江經濟電台（備註「正在直播：…」），圖片全部顯示，共 5 頁 59 台 → 詳情、線路「蜻蜓FM · 1 集」→ **原生播放器**：黑底＋音波圖示、沒有誤報，時間顯示「已播放」00:16→01:34（`https://lhttp-hw.qtfm.cn/live/1259/64k.mp3`，起播約 4.9 秒，`stalls=0`，`final=risk` 是監控把直播約 8 秒前緩衝判成 risk）→ **背景播放**：Home 約 16 秒後回前景 01:11→01:31，Suspension 期間每秒仍在解碼 → 北京音樂廣播（`live/332`）00:05→00:20 → 觀看紀錄重開可直接再播 02:05→02:17；直播沒有檔尾，連續約 2 分鐘未卡（不受 W-83 檔尾問題影響）；Simulator 已逐檔還原（BYTE-IDENTICAL） | `/private/tmp/webhtv-gui-57b10-qingtingfm/RESULT.md` `bc3515ba…`（83 檔 SHA256SUMS 全 OK；關鍵檔備份 `artifacts/w77-gui-evidence/`） |

## 未驗證

- 實機；MPV；鎖屏與來電；其他 42 個地區或類型；長時間收聽（斷流重連）。

## 觀察（App 端，未改程式）

- 點分類後捲到底，第 2 頁不會載入，要先捲回頂端才一路續載（疑 `loadMore` 觸發時機）。
- 從觀看紀錄重開直播時，App 會 seek 到上次秒數（121.85 秒），時間接著上次顯示；直播其實沒有續播位置。可併入 W-83 的音訊播放檢查。
- 「广西」「云南」「旅游」與部分電台名沒有轉成繁體；設定是 list 樣式，App 仍顯示 3 欄海報格，方形 logo 被切邊。

## 回滾

一個 commit；`git revert` 移除 adapter、Registry 行、測試與相容包列，不影響其他來源。
