# IOS-POC-57B-16：呦呦 • DJ（Djuu）移植（W-42 DJUU-IMPL）

- 工單：W-42（webhtv-dev-claude-dev），使用者 2026-10-12 核准實作。設計閘門：`artifacts/qist-djuu-gate-2026-10-09.md`（W-24／W-29 PASS，sha256 `14420451…b3f5fb`，§5 為唯一權威）；資料夾導覽：IOS-POC-60（W-40）。審查準備：`review-prep-W-42-2026-10-13.md`（D01–D22、DJ-01–DJ-20）＋`review-prep-W-41-W-42-2026-10-15.md`（B1–B3、MU1–MU9、G6b／G7／G11）。
- 上游：`Djuu.java`（qist `j-spider.jar` blob `8ac9cb8e…`，jadx 266 行，sha256 `ce2aa93d…4eec`，副本 `artifacts/w129-upstream/`）。
- 分支 `task/W-42`，從 W-41 審過的 `8be0d6f0` 開（Manager #2319；發布前推送凍結 #2300，送審前 rebase 到推送後的 origin）；guard `DJUU-IMPL`，一個 commit，`--no-tag`。

## 1. 拍板與範圍（Manager #2158、#2249、#2254、#2319）

| 項 | 決定 | 本單做法 |
|---|---|---|
| B1 fixture 遺失 | 用 W-117 live 副本＋實作時重抓，壓縮內嵌測試，期望值重新導出、記入本文件 | 曲库、超出範圍頁、folder 第 1 頁、播放 JSON 用 W-117 的 2026-10-13 副本；搜尋頁閘門從沒抓過，2026-10-15 公開 GET 一次（§3）。raw deflate＋base64 內嵌 `DjuuSpiderTests.swift`，載入時核 sha256。期望值由獨立的 Python `html.parser` 解析器導出（`artifacts/w42-fixtures/expected.py` → `expected.json`），和 `host.js` 的 `pdfa`／`pdfh` 無關 |
| B2 FOLDER-04 | 「只隨 IPA」只加在相容包工具 | `scripts/spider_pack.py` 的 `IPA_ONLY` 加 `Djuu.js`（#2319：W-41 只放了 Ikanbot） |
| #2249 第一版官方包不收 | `runtime_pack.NOT_IN_FIRST_OFFICIAL_PACK` 已含 `Djuu.js`（W-41 加） | 不動 `runtime_pack.py`；`scripts/test_pack_exclusions.py` 兩支工具各 build 一次，都沒有 Djuu |
| #2254 基準 | `SpiderBaselineTests.notInBaseline` 要列 `Djuu.js` | 加入；基準 manifest 不動、序號不升（Djuu 不在種子裡，由內建層提供） |
| B3 資料夾 GUI | W-42 驗 G6b、G7、G11 | §5 |

範圍：新 `Resources/Spiders/Djuu.js`、`SpiderRegistry.ported` 一行（加註解）、`SpiderGoldenTests` 一個名稱、新 `DjuuSpiderTests.swift`、`SpiderBaselineTests.notInBaseline`、`scripts/spider_pack.py` 的 `IPA_ONLY`、本文件。沒有動 host、App、播放器、歌詞、`CMSClient`、`RuntimeABI`、`spider-pack/`。

## 2. 和上游的差異（全部是閘門 §5.2–5.3 已核准的窄適配）

| 項 | 上游 | 本移植 | 原因 |
|---|---|---|---|
| 跨請求狀態 | 靜態 `ArrayList a` 存上一頁曲目，詳情用它組播放清單（:25、:74、:110–117、:142、:172–196） | 沒有任何狀態；folder 曲目 id＝`<該頁路徑>#<data-bs-id>`，詳情重抓該頁 | 搜尋或另一個 folder 夾在中間會改掉清單；App 可能交錯呼叫（DJUU-D-02、D19） |
| 曲目 id | `id$$$名$$$圖$$$清單` | folder：`/djlist/115_0_1_1.html#326050`；搜尋：`326041` | canonical、清單內唯一；詳情仍接受舊格式，當單曲（DJUU-D-03） |
| 詳情判別 | 依 `a` 是否為空 | ① 含 `$$$` → 舊 id 單曲 ② `lastIndexOf('#')` 前段 `^/djlist/[^#]+\.html$`、後段 `^\d+$` → 重抓該頁 ③ `^\d+$` → 單曲 ④ 其他 → 空，②以外都不發請求 | 舊 id 的曲名含 `#` 不會被當成 folder |
| 該頁沒有被點的曲目 | — | 把 `<id>$<id>` 加回清單最後 | 站台上新會讓曲目移到下一頁，播放與續播仍找得到（DJUU-D-02；live 已出現，`325541` 不在 10-13 的第 1 頁） |
| 歌單只含該頁 | 跨頁累積 | 只有該頁 30 首 | 無狀態 |
| 曲库結果 | 經 JSONObject，有 `vod_tag` | 自組 `{list, page, pagecount, limit, total}`，不經 `host.result.page`（會丟 `vod_tag`） | folder 導覽（IOS-POC-60） |
| 失敗 | 丟例外回 `""` | 回空 `list` | `""` 會解碼失敗；category 的空結果＋失敗請求由 runtime 轉成「站台無法連線」（DJ-20） |
| 超出範圍頁 | `pagecount` 永遠 `Integer.MAX_VALUE` | 照上游；站台對超出範圍頁回 200 但 0 首，回空 `list`，App 在新頁沒新增時停止 | DJUU-D-01 |
| 搜尋編碼 | `URLEncoder`（空白 `+`） | `encodeURIComponent`（空白 `%20`） | 閘門 §5.3 |
| 播放成功判斷 | 直接取 `data.url` | `String(code) === '0'` 而且 `data.url` 是字串 | `code` 是 int 0；空字串、缺欄位、非 JSON、非 200 都播放空（DJ-12、D21） |

圖片照上游 `b()`：`https://m.djuu.com<path>@Headers={"User-Agent":"<UA>","Referer":"https://m.djuu.com/"}`（`JSON.stringify` 的 key 順序 UA、Referer）；請求 Referer 沒有尾斜線，圖片與播放 header 有（DJ-01）。

## 3. Fixture 來源（全部存在 `artifacts/`，內嵌在測試裡）

| 檔 | 來源 | bytes | sha256 | 備註 |
|---|---|---|---|---|
| `djuu-djlist.html` | W-117 `w117-liveness/`（2026-10-13 09:04:06 UTC） | 61608 | `a11672a5747e91995e30ca7de2b3054c7053004316aa47395d968794d1d7ad76` | 和閘門 `djlist.html` 逐位元組相同 |
| `djuu-folder-p1.html` | 同上（09:04:08） | 85761 | `2afe44f77ff0be0cb054e68e29ab39619af0efca78157f86974cbf277a0b1e69` | 站台已上新，和閘門版不同；結構相同 |
| `djuu-folder-p9999.html` | 同上（09:04:09） | 51845 | `a0c3aded529e2e431b08782069bad503d82a8208a7777263d0d8b573af6cca2b` | 和閘門逐位元組相同（0 首、9 處雜訊 `data-bs-id`） |
| `djuu-play.json` | 同上（09:04:11，POST `id=325541`） | 646 | `0072248cf2174e4c228ca1cf25f0896145c8559d84a732e1d110a9af90d38e8e` | `data.url` 和閘門相同 |
| `djuu-search-bingwen.html` | **本單抓一次**：`GET https://m.djuu.com/search?musicname=%E5%86%B0%E5%90%BB`，2026-10-15 08:14:05 UTC，200 `text/html; charset=utf-8`，桌機 UA＋`Referer: https://m.djuu.com`，`python3 -I` urllib、TLS 驗證開著、沒有代理 | 81213 | `6f723b88f74a9818c25154a326382f3cca041f8a27b0a9f265137b97f383ebde` | `artifacts/w42-fixtures/`；記錄 `djuu-search-bingwen.json` |

獨立解析器導出的期望值（`expected.json`）：曲库 11 筆依序 独家舞曲、迪高串烧、慢摇串烧、慢歌串烧、中文Remix、外文Remix、HOUSE、霓虹风格、Mashup、中文DISCO、外文DISCO，id `/djlist/{115,1,…,10}_0_1_{pg}.html`、圖 `e115.png`、`e1.png`…`e10.png`；folder 第 1 頁「独家舞曲」30 首，首 `326050`「【DJUU私货】Taylor Swift - Love Story(Dj阿衍 Electro Rmx 2026)」、末 `325776`「【DJUU独家】海伦 - 桥边姑娘(DJ阿翔 FunkyHouse Rmx 2026)」；p9999 0 首；搜尋 30 首，首 `326041`「王键 - 冰吻(肇庆GonBe拾三 Electro Rmx 2026)」、末 `130894`；播放 `https://mp4.djuu.com/c115/166615/116/2026/3f70e1223b32f5e1.m4a`。整份清單以 sha256 斷言（folder id、曲名、播放清單；搜尋 id、曲名）。60 個曲名都沒有 `#`／`$`、沒有 HTML 實體（`textOf` 不解實體，DJ-17）。

## 4. 測試紀錄（證據 `artifacts/w42-logs/`）

| 項目 | 結果 |
|---|---|
| 先紅 | 16 個測試裡的 15 個在 registry 沒有 `csp_Djuu` 時全紅（`red.log`）；DJ-04 那條是之後補的（見 mutant） |
| 後綠 | `DjuuSpiderTests` 16＋`SpiderGoldenTests`＋`SpiderBaselineTests`＋`RuntimeABITests`：`green.log` |
| 涵蓋 | D01 headers、D02 首頁、D03／D04／D06 曲库 11 筆＋圖＋`ImageRequest.parse`、D04 經 `SourceClient.category` 11 筆 `isFolder`／30 首都不是、D05 第 2 頁不發請求、D07／D08／D09 folder 頁、D10 p9999 回空、D11 畸形、D12 搜尋（`%E5%86%B0%E5%90%BB`、`a%20b&page=2`、空關鍵字不發請求）、D13–D17 詳情四種判別與缺曲加回（31 集）、D18 字串 id、D19 交錯、D20／D21 播放（body 精確 `id=325541`、form Content-Type、header 精確；`code` 1、空字串、缺欄位、缺 `data.url`、非 JSON、500 → 空）、D22 registry、DJ-04 曲库範圍 |
| 打包排除 | `python3 -I scripts/test_pack_exclusions.py` → `PASS: compatibility 33 and official 33 scripts, none of ['Djuu', 'Ikanbot']`（`pack-exclusions.log`） |
| Mutant | MU1 曲目改抓全頁 `[data-bs-id]`、MU2 曲名用 `div.me-2`、MU3 曲库拿掉 `div.my-3`、MU4 曲库經 `host.result.page`、MU5 舊 id 含 `#` 時不走 ①、MU6 缺曲不加回、MU7 圖片 Referer 拿掉尾斜線、MU8 模組層快取上一頁曲目、MU9 播放不檢查 `code`：9/9 變紅（`mutants.txt`）。**MU3 第一次存活**：真實頁面上 `div.my-3` 以外的 `div.mb-2` 都沒有可解析的 `onclick`，結果剛好相同；補了手做頁面的 `onlyTheLibraryBlockCounts` 後變紅。全部還原，`Djuu.js` sha256 相同 |
| 全測試 | `swift test` 1306／48 通過（W-41 之後 1290＋16）：`full.log` |

### Ponytail review

對最終 diff 跑 `ponytail-review`：沒有 finding，Ship。核過：非 200 的分類回空（runtime 轉成站台無法連線）、搜尋與詳情回空；超出範圍頁回空讓翻頁停止；歌單頁 0 首時詳情仍加回被點的那首；詳情判別順序只有 ② 發請求；播放所有失敗回應都回空；只取曲目區塊自己的 `data-bs-id`；兩支打包工具都不收 Djuu。成本：每次打開歌單曲目詳情多抓一次約 85 KB（無狀態的代價，閘門已核准）。

## 5. Simulator GUI（`artifacts/w42-gui-evidence/RESULT.md`，背景 fork 執行）

iPhone 18 Pro／iOS 27.0（`BC4948DD`），`-configSourceURL …/qist/tvbox/master/dianshi.json`，來源「呦呦 • DJ」。`Djuu.js` 在 checkout、.app、容器三處 sha256 `8b2fcd75…` 相同；測試前後受測檔 hash 不變。RESULT.md sha256 `1930ca3e…`。

| 行 | 結果 |
|---|---|
| folder 導覽 GUI（W-40 延後項）G6b／G7／G11 | **PASS**（W-41 已驗 G1–G6a、G11、G12；資料夾導覽 GUI 至此整組完成） |
| Djuu 完整移植 | **PASS** |

- 1 首頁：11 個歌單，featured「獨家舞曲」；歌單圖與曲目 logo（帶 header）有顯示（W-32 未驗項，這次驗到）。
- G7：folder 模式有導覽列、返回鈕、標題，30 首，捲到底自動載入 30→60；詳情「DJ呦呦網 · 30 集」；播放 00:08→00:22，總長 06:23（不是 `--:--`），原生引擎。
- 播完接下一首（W-83）：log `finished (end) at 382s/382s` 後播第 2 首，只前進一首。
- 續播（W-110／W-86）：片庫「看到 0:35 / 7:10」；重開約 7 秒後進度 00:42（log 沒記起播秒數，從進度推算）。
- G6b：下拉刷新 60→30，仍在同一個 folder；再捲到底又自動載到 60。
- G11：頂端沒有「回到頂部」，捲動後出現，點了回到 folder 頂端、不跳回首頁。
- 返回兩層：folder 仍 60 筆、首頁 11 個歌單；搜尋「冰吻」30 筆、首筆和 fixture 相同；單曲 1 集，播放 00:09→00:22（集名顯示數字 id，設計 ③ 的既定行為）。
- 片庫：兩筆都是曲目，沒有歌單。
- 還原：App（1571 檔）、data（18 檔）BYTE-IDENTICAL，Simulator 已關機，建置暫存已刪。
- 沒驗到：真機、MPV、背景播放、鎖屏控制、AirPlay；p9999 只有單元測試。

## 6. 回滾

一個 commit；`git revert` 回到未支援（registry 沒有 `csp_Djuu`，「呦呦 • DJ」不出現在站台清單）。`Djuu.js` 不在相容包、第一版官方包與種子裡，沒有發布物要收回。
