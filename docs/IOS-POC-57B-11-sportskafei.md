# IOS-POC-57B-11：咖啡体育（qist `csp_SportsKafei`，直播）

> Recovery anchor（2026-10-13 14:25 CST）：已實作，單元測試與全測試通過（W-72，guard `QIST-SPORTSKAFEI-IMPL`，`--no-tag`）。設計：`.herdr-synapse/webhtv-dev/artifacts/qist-sportskafei-gate-2026-10-12.md` D1–D6（W-59 第二輪 PASS），加上 Manager #1412 的兩個決定：每頁依 room_id 去重且直播中優先、任務文件編號用 57B-11。資料閘門 W-49 PASS；使用者 2026-10-12 已核准實作（W-71）。Simulator 直播實播 PASS（兩條線都原生起播；rtmp 沒有出現，沒驗）。下一步：Reviewer code review。

## 來源

- JAR：qist/tvbox `spider.jar` sha256 `72a1f3928eca281d878e44fc57162ff6a1f3ef779a2da05a2b351b241b110d69`；`SportsKafei.java` 140 行，sha256 `63e7b07ecf6dec92aa1ab2f9dfa37f69838c7e399c0788b27614f87f25293b00`。
- 設計寫的 `IOS-POC-57B-5` 已經被獨播庫用掉，依 Manager #1412 改用 57B-11。獨播庫的文件沒有動。

## 改動

| 檔案 | 內容 |
|---|---|
| `ios/Sources/WebHTVCore/Resources/Spiders/SportsKafei.js`（新） | 設計 D2／D3。兩個請求都用 `GET https://kafeizhibo.cc/api/v1/…`，標頭照上游只有兩個（被截斷的 `User-Agent`、`Accept: application/json`）；只接受「HTTP 200＋`code === 200`」的回應。首頁固定 3 類（`hot 热门`、`1 足球`、`2 篮球`），沒有 filters。分類：`tid` 只接受 `hot` 或純數字，否則不送請求；`pg` 不是整數或小於 1 時用 1；每筆 `vod_id = archor.room_id`（字串或數字都接受），名稱是 `主隊 VS 客隊`，海報是主隊 logo，備註是聯賽名，`status === 'live'` 時加上 ` 直播中`；**同一頁同一個 room 只出一張卡**（Manager #1412）：有直播中的就用直播中那場，否則用第一場，順序依被選中那筆的原始位置；`page(list, page, list.length ? page+1 : page, 30, list.length)`。詳情：id 必須是純數字；`vod_id = room_info.room_id`，`vod_name = room_info.title`（API 原文，小寫 vs），`vod_director = league`，`vod_actor = 主隊 VS 客隊`，線路名 `咖啡体育`；訊號網址必須符合 `^(https?\|rtmps?)://` 且不含 `$`／`#`，rtmp 保留（W59-01）；名稱裡的 `$`／`#` 換成空白，空名稱用 `线路<原始位置 i+1>`。播放：parse 0、不帶 header，網址條件同上。搜尋回空 |
| `ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift` | `ported` 加 `SportsKafei` |
| `ios/Tests/WebHTVCoreTests/SpiderGoldenTests.swift` | 預期清單在 `SportsGuazi` 後面加 `SportsKafei` |
| `ios/Tests/WebHTVCoreTests/SportsKafeiSpiderTests.swift`（新） | D5 的 8 組測試。fixture 用 gate 的 `schedule-1.json`（30 筆、20 個 room、2 筆直播中）、`room-1007.json`，raw deflate＋base64 內嵌並驗 sha256；畸形回應手寫 |
| `scripts/spider_pack.py`、`spider-pack/` | `DEFAULT_ORIGINS` 加 `SportsKafei`（`spider.jar` `72a1f392…`，只用 base host API：`host.get`／`result`）；相容包重建為 `2026-10-13.3`（31 支）：只新增 SportsKafei，舊 entry 全部不變；pack 與內建腳本 byte 相同（sha256 `7492fd10…ac0f`）；`verify` 0 problems |

### 與設計不同的地方，以及設計沒寫、由實作決定的地方（review-prep N7）

- **每個 room 一張卡**（Manager #1412，S6）：gate 那一頁的 30 筆變成 20 張卡。如果不去重，SwiftUI 的 `ForEach` 會遇到重複 id，翻頁時 `merging(newTitlesFrom:)` 也會吃掉後面的比賽。所以 `total` 是去重後的數量（測試 2：`total 20`、`pagecount 2`）。
- 缺 `signals` 這個 key 時，詳情照樣回傳，只是沒有線路（K13、S11）；上游在這種情況會丟例外，回空 list。`signals: []` 的處理和上游相同。
- 上游詳情另外輸出的 `vod_pic`／`vod_content`／`vod_year`／`vod_area`／`vod_remarks` 空字串（K11）這裡不輸出，App 讀到的結果相同。
- `code` 只接受數字 200（S3）；字串欄位不是字串時當成 `''`（D2；上游會把數字轉成字串，fixture 裡沒有這種情況）。
- 空名稱的序號用原始位置 `i+1`，和 ShortXingya 的做法一致。

## 驗證

| 項目 | 結果 | 證據 |
|---|---|---|
| 先紅 | 腳本已放進 Resources，但 Registry 還沒列：8/8 紅，能編譯 | `artifacts/w72-logs/w72-red.log` |
| 後綠 | `SportsKafeiSpiderTests` 8 個＋`registryClaimsOnlyWhatIsActuallyPorted`，9/9 通過 | `w72-green.log` |
| Mutant（review-prep §5 的 9 種） | 全部被抓到：rtmp 被丟掉→2 個失敗；`room_id` 只收字串→1；備註少空白→2；`VS` 改成 `vs`→2；播放結果帶 header→1；`$` 沒換掉→1；UA 換成完整的 Chrome→2；`tid` 不檢查→1；直播中不優先→1。全部還原後 sha256 `7492fd10…` 與原檔一致。roomstr 這個 mutant 第一次跑時，測試在 `items[2]` 越界 crash，所以改成先 `try #require` 再取索引，重跑後是正常的 1 個失敗 | `w72-mut-*.log` |
| 全測試 | `swift test` 1155 tests／37 suites 全部通過 | `full-summary.txt` |
| 相容包 | build `2026-10-13.3`，verify 0 problems；manifest 的差異只有版本號和新增的一列 | `w72-manifest.before.json` 對照 |
| Ponytail review | Ship，沒有 finding | — |
| Simulator 實播（iPhone 18 Pro／iOS 27.0；HEAD `68e06fd3`＋本單工作樹；`SportsKafei.js` `7492fd10…` 在 checkout、.app、容器三處相同；log 有 `SportsKafei type: js path: Spiders`） | 三個分類：熱門 21、足球 18（1 場直播中）、籃球 30，替代海報 0 → 足球的直播場：「原聲1」線原生 1425ms 起播，00:22→00:46→01:48，畫面不同（比分卡→廣告卡），stalls=0，host `pul-tenm.gkykp.com`，這次沒有被攔截 →「直播7」線這次也播得起來：原生 00:26→00:52，沒有退到 MPV（DNS 是 CloudFront）→ 從觀看紀錄重開：重新打了 room API，原生 00:12→00:27，App 沒有試圖跳回上次的秒數 → 一張卡片一個房間：API 30 場／18 個房間，App 顯示 18 張，沒有重複或錯位；往下捲 18→29→34→39，請求 6 次後停住。還原時整個 data 容器（Library、Documents、tmp、SystemData）和 App 都 BYTE-IDENTICAL，沒有用 uninstall。**rtmp：這次沒有 rtmp 訊號，MPV 接手沒驗** | `artifacts/w72-gui-evidence/RESULT.md` `f7d2f536…bc28` |

## 未驗證

- rtmp 由 MPV 接手（本次沒有 rtmp 訊號）；第 2 頁以後每個房間是否只出一張卡（App 也會依 id 去重，畫面上分辨不出來）；點一張和直播中比賽同房間的「未開賽」卡片，實際播的是哪一場；實機。

## 已知限制

- `room_id` 是主播間，不是比賽（D4、N5）：從觀看紀錄或收藏重開時，看到的是那個主播「現在」在播的內容，可能是別場比賽，也可能沒有訊號。點一張「未開賽」的卡片，播的是那個主播當下在播的比賽（S7）。
- 「原声」線的網址帶騰訊雲的 `txSecret`／`txTime`，大約 24 小時到期；adapter 不保存播放網址，重開詳情時會重新取得。
- 「直播」線（`hello.ooo0ooo.top`）在 gate 時讀不到，原因沒有判定；本機網路的 Fortinet 會間歇攔截「原声」線的 TLS（D6）。

## 回滾

一個 commit；`git revert` 會移除 adapter、Registry 那一行、測試與相容包那一列，不影響其他來源。
