# IOS-POC-57B-14：88看球（qist `csp_Sports88`＋0825 `csp_Kanqiu`）直播

> Recovery anchor（2026-10-15 11:00 CST）：已實作（W-105，guard `QIST-SPORTS88-IMPL`，`--no-tag`）。測試先紅後綠、mutant 9/10 紅（1 個等價）、全量 1183 通過、相容包 `2026-10-15.1` verify 0 problems、Ponytail review Ship。Simulator A–E PASS（見「驗證」）。下一步：Reviewer code review。

## 依據

- 閘門 W-102 GO（有條件）：`.herdr-synapse/webhtv-dev/artifacts/qist-Sports88-gate-2026-10-13.md`（sha256 `c6d1ecb1…b963`），fixture `artifacts/sports88-gate-fixtures/`（33/33 SHA256SUMS OK）。
- 審查預備：`artifacts/review-prep-W-105-2026-10-13.md`（N1–N17）。
- 站：Sports88 在 qist dianshi:100、jsm:101（`spider.jar`）；Kanqiu 在 0825:44（`pg_upgraded.jar`）。三站的 ext 都是空字串。
- Manager 決定：只列可拆成 m3u8 的 88player 線路；9 條第三方 JS 頁（要嗅探）不列，避免「看得到、不能播」。使用者「先把爬蟲工具補齊」視同核准。

## 和上游的差異

| 項目 | 上游 | WebHTV |
|---|---|---|
| 詳情路線 | Sports88 `/live/<id>/source`；Kanqiu `<play>-url` | 一律 `/live/<id>/source`（Kanqiu 的 `-url` 回 404，閘門 #4、#6） |
| 線路 | 全部 `links[]`，`parse:1` 交給嗅探 | 只收主機剛好是 `play.88player.top`、路徑 `/m3u8.html` 的包裝頁，取 `url` 參數（遇 `&` 停、`host.dec` 解碼），結果要符合 `^(https?|rtmps?)://` 且不含 `$`、`#`，`parse:0` 直接播。`http://play.88player.top` 也收（只是外殼的 scheme）。`embed.st`、`sportsteam368`、`taifood-blog` 等全部不列 |
| 列表 | 所有 `.list-group-item`；日期列與沒在直播的比賽 `vod_id` 都等於主機（首頁 60 項重複） | **只列直播中的比賽**（有 `.btn.btn-primary` 的那幾場）。`vod_id` 是 `/live/(\d+)/play` 抓出的比賽編號，同頁去重。未開始／已結束的比賽沒有線路，`/source` 對已結束比賽的回應也沒測過，所以不列 |
| 分類 | Sports88 `""/4/23/21`（和它自己的篩選 key 對不上）；Kanqiu `""/1/8/21` | 統一用 Kanqiu 的 `""/1/8/21`，篩選帶 key `1`、`8`（上游的 `29` 沒有對應分類，不帶）。`cateId` 整個取代 tid；兩者都必須是純數字或空字串，否則不發請求 |
| 名稱 | `.row.d-none` 的文字（尾端帶「直播中」） | 同上，但去掉尾端和備註相同的按鈕文字；備註是按鈕文字 |
| 線路名稱 | 原樣 | `$`、`#` 與括號 `()（）[]【】《》` 換成空白（App 在未閉合的括號內不切 `#`，`CMSClient.swift:340–345`）；空名稱用 `线路N`；重名加 ` (2)`、` (3)` |
| 解碼失敗 | 拋錯 | `data` 不是字串或長度 < 8、補位不足（JS 先補 `=`）、不是 JSON、沒有 `links` 陣列：都回沒有線路的詳情。兩個播放欄位留空、`vod_content` 寫「暂无可播放线路」，App 會停用「立即播放」，不塞佔位線路 |
| 主機 | Sports88 `http://www.88kanqiu.la`、Kanqiu `http://www.88kanqiu.tw` | 預設 `https://www.88kanqiu.la`；ext 是 `http(s)://` 網址時才覆蓋。JS 拿不到 class 名稱，所以 Kanqiu 也打 `.la`（閘門證明兩站同一個後端；R3：`.la` 被封而 `.tw` 還活著時 Kanqiu 也會失效） |
| 搜尋 | 沒有 | 回空列表、不發請求 |
| 相容包 | — | `DEFAULT_ORIGINS` 加 `Sports88`，帶 `"aliases": ["Kanqiu"]`，pack 更新時兩站同步（R4） |

`vod_id` 只存比賽編號：`dyrur1` 的網址帶有時效的 `auth_key`，觀看紀錄重開時會重打 `/source` 拿新網址。詳情頁開著超過 1–3.5 小時再按，舊網址可能過期（R1），重開詳情即可。每次 `auth_key` 都不同，所以「上次看的線路」不會被標示（外觀問題，`WebHTVApp.swift:2604`）。

## 改動

| 檔案 | 內容 |
|---|---|
| `Resources/Spiders/Sports88.js`（新） | 上表的設計，只用 base host API（`get`、`pdfa`、`pdfh`、`urljoin`、`dec`、`base64.decode`、`result`） |
| `SpiderRegistry.swift` | `ported` 加 `"Sports88"`、`"Kanqiu"`；單行的 `aliases` 加 `"Kanqiu": "Sports88"`，其他 pair 不動。`audit_spider_jars.registry_names()` 印出 `True True Sports88` |
| `Sports88SpiderTests.swift`（新） | 12 個測試：6 份閘門 fixture 以 raw deflate＋base64 內嵌並驗 sha256；alias 不是獨立檔案（列出 Spiders 資料夾比對完整檔名）、首頁 4 分類＋篩選不發請求、首頁只列 2 場直播、Kanqiu 走同一支 JS 且 `cateId` 取代 tid、壞 tid／第 2 頁不發請求、失敗頁回報 `SiteUnreachable`、同場去重、129230 剛好 10 條／129494 剛好 2 條（`.tw` 的回應解出相同 10 條）、包裝頁判斷與 `url` 參數的 19 個手寫項目、6 種壞回應、`parse:0`＋UA、沒有搜尋、ext 覆蓋主機 |
| `SpiderGoldenTests.swift` | 黃金清單加 `"Kanqiu"`、`"Sports88"` |
| `scripts/spider_pack.py`、`spider-pack/` | 相容包 `2026-10-15.1`（33 支），manifest 只多了 Sports88 一列，其他 entry 不變；pack 與內建 byte 相同（sha256 `479a9fac…b78e`）；`verify` 0 problems；`test_spider_compat.py` ok |

沒有改任何 App／Core 的 Swift：直播判定沿用 W-86（AVPlayer 對沒有 `#EXT-X-ENDLIST` 的 HLS 回報 duration 無限 → 0 → 不續播、`--:--`）。

## 驗證

| 項目 | 結果 | 證據（`.herdr-synapse/webhtv-dev/artifacts/w105-logs/`） |
|---|---|---|
| 先紅 | 新測試在沒有 JS／沒註冊時全紅，黃金清單也紅 | `red.log` |
| 後綠 | Sports88 12 個＋Registry＋JianpianAlias，17/17 | `green.log` |
| Mutant | M1 主機改 `indexOf`、M2 不解碼、M4 只收 https、M5 不去重、M6 不補位、M7 不處理括號、M8 回 `parse:1`、M9 不檢查 tid、M10 塞佔位線路，全部變紅。M3（`xurl=` 被當成 `url=`）是等價 mutant：`slice(4)` 會留下開頭的 `=`，網址條件仍擋掉。M6 第一次存活，因為測試的「沒補位」資料本來就不需要補位；已改測試，讓它真的缺補位，重跑變紅。全部還原，sha256 一致 | `mutants.txt`、`mut-*.log` |
| 全測試 | `swift test` 1183 tests／40 suites 全部通過 | `full.log` |
| 相容包 | `2026-10-15.1` 0 problems | `pack-verify.txt`、`manifest.before.json` |
| Ponytail review | Ship，沒有 finding | — |
| Simulator（iPhone 18 Pro／iOS 27，BC4948DD，2026-10-15 上午有直播） | **PASS**。A：dianshi「88 • 看球」全部直播 16 部，和網站同時的 16 場直播一致，id 不重複；另外 38 場未開始或已結束的沒列出。籃球直播 5 部、NBA 篩選 5 部；足球直播與 CBA 當下網站 0 場，App 顯示「沒有內容」。B：《雄鹿 VS 公牛》9 條，等於網站 18 條 links 中拆得出的 9 條，順序相同；第三方主機 0 次請求。該場的 dyrur1、rtmpcdn 兩條在來源端已失效（Mac 直接抓也逾時或 404），App 顯示「無法播放」並標示 MPV。改播《快船 VS 掘金》線路A4，原生 1936ms 起播，00:11 → 00:24，總長 `--:--`，stalls=0。C：紀錄頁顯示「看過」；看到 00:43 關掉後重開，從直播最新處開始，沒有續播。D：0825「看球」6 部，詳情和 Sports88 站相同，原生 1681ms 起播。E：棒球《道奇 VS 釀酒人》0 條可用線路，「立即播放」停用、顯示「暫無可播放線路」。容器還原 BYTE-IDENTICAL | `.herdr-synapse/webhtv-dev/artifacts/w105-gui-evidence/RESULT.md`（sha256 `742e8cc9…560b`） |

沒驗到：App 不記錄請求路徑，`/match/<tid>/live`、`/live/<id>/source` 只靠「數量和網站同時的直播場數一致」間接證明；「其他直播」分類、離線下載沒測；已結束比賽打 `/source` 的回應（閘門 G:115），從觀看紀錄重開已結束的比賽可能顯示載入失敗；MPV 成功播直播時 duration 是否為 0（R5；這次 MPV 只出現在兩條本身失效的線路上）；iOS 實機。

## 回滾

一個 commit；`git revert` 會拿掉 JS、Registry 兩行與 alias、測試、黃金清單與相容包的變動。
