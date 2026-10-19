# IOS-POC-57B-17：旺旺 • 影视（Wwys）移植（W-152）

- 工單：W-152，分支 `task/W-152`（從 `origin/ios-poc` `fc19061a` 開），worktree `webhtv-dev1`。本單只改檔、不 commit，由 Manager 審後收尾。
- 來源（資料閘門）：`artifacts/qist-Wwys-gate-2026-10-16.md`（W-148，GO 有條件）與 `artifacts/wwys-gate-fixtures/`（2026-10-16 03:34–03:37 UTC，手機熱點出口，23 次請求，`SHA256SUMS`）。
- 上游：`com.github.catvod.spider.Wwys`（qist `spider.jar` md5 `bf32cf121ae92e49326a9fed7a82b76b`，jadx 115 行，sha256 `934632670ed3cd9a3e126581860b780189b5ca437c7b3f263c42b980d5ca04eb`）。**實作時 `/private/tmp/webhtv-qist-batch-work/` 已被清掉，原碼副本讀不到**；行為以閘門文件的逐方法描述（行號、選擇器、正則）為準，篩選值見 §2。
- 設定：`cfg/dianshi.json` `sites[58]`、`cfg/jsm.json` `sites[57]`，`{"api":"csp_Wwys","ext":"https://vip.wwgz.cn:5200"}`。
- 時間：2026-10-19 CST。

## 1. 決定

| 項 | 決定 | 原因 |
|---|---|---|
| 播放線路 | **只列線路②**（`mac_from` 裡的 `lzm3u8` 那組），名稱用站方自己的「线路②」；依代碼對應，不依位置。標題沒有線路②時**不列任何線路**（`vod_play_from`／`vod_play_url` 都是空字串），不退回線路① | 線路② 是標準 HLS（閘門 #11、#14、#17、#22）；線路①（`monday`）的分段藏在 PNG 圖床，AVPlayer 不能播（#16、#23）。上游寫死一個 `在线播放` 卻放整串 `mac_url`，TVBox 只會顯示線路①，一併修掉 |
| 分類 | 寫死 电影 1、连续剧 2、综艺 3、动漫 4、短剧 26、音乐 31；**拿掉小姐姐 20** | 20 是空分類（#3，0 項），也是唯一有疑慮的名稱；寫死省掉上游每次抓 `#topnav` 的一次請求 |
| 播放 | `playerContent` **直接回播放 id（m3u8）**，`parse:0`，header 只帶上游 UA；不是 `http(s)` 開頭就回空網址；不發任何請求 | 上游三段轉址鏈：`relay067.php` 回 `Key does not exist`（#8），`api.wwgz.cn:520/player/` 原樣回傳輸入（#12、#13）。m3u8／TS 只要 UA（閘門「header」列） |
| `ext` 的 `$$$` | `split('$$$')[0]`、去尾端 `/`；不是 `http(s)` 開頭（含空字串）就用 `https://vip.wwgz.cn:5200` | 同 W-144 Ikanbot 的作法 |
| 分類分頁 | 從頁尾 `共N条数据 当前:p/P页` 取 `pagecount`、`total`（上游沒回） | 閘門 #2、#20 |
| 搜尋 | 照上游 `/index.php?m=vod-search&wd=`（`encodeURIComponent`）、`#data_list > li`；只回第 1 頁，第 2 頁以後與空關鍵字回空、不發請求 | 站方搜尋沒有分頁，上游每頁都回同一批，App 翻頁會重複 |
| 彈幕 | 不移植 | 上游 `addDanmaku` 依賴 TVBox 本地代理 |
| 失敗 | 分類頁抓失敗回空頁（runtime 轉成「站台無法連線」）；詳情頁失敗或 id 不是數字回空 `list`；播放頁失敗或沒有 `mac_url` 回詳情但沒有線路 | 閘門「畸形輸入」 |

## 2. 和上游的其他差異

| 項 | 上游 | 本移植 |
|---|---|---|
| 首頁推薦 | `homeVideoContent` 沒實作；`homeContent` 取 `section.mod:nth-child(3) … ul.resize_list` | `homeVideoContent` 取第一個 `.globalPicList` 的 `li`（今日更新 12 項）；host.js 不支援 `:nth-child`。圖取 `data-src`（畸形 `<img data-src="…"<img src=…>` 仍解得到） |
| 篩選 | `:72` 寫死 JSON，只有 1、2 有「类型 cateId」 | key／名稱照上游；**值是從閘門分類頁的「类型」列導出**（原碼讀不到）：电影 动作片5 喜剧片6 爱情片7 科幻片8 恐怖片9 剧情片10 战争片11 惊悚片16 奇幻片17；连续剧 国产剧12 港台泰13 日韩剧14 欧美剧15；「全部」值為空，用原分類 id。若和上游 JSON 有出入，以站方頁面為準 |
| 詳情欄位 | `:nth-child` 選擇器 | 依 `.desc_item` 的標籤文字（状态／主演／导演／年代）取值；簡介去掉「简 介：」前綴；名稱 `.title a@title`、圖 `.page-hd img@src` |
| 搜尋備註 | `span:nth-child(3)` 文字「评分：0.0」 | 去掉「评分：」只留「0.0」，和分類頁的備註一致 |
| 網址含中文 | — | 不處理：只列線路②，取樣到的線路② 網址都是 ASCII |

## 3. 改動

| 檔 | 內容 |
|---|---|
| `ios/Spiders/Wwys.js`（新，137 行，sha256 `bc54e988…19e6`） | 移植本體，只用既有 host 原語（`get`、`pdfa`、`pdfh`、`parse`、`match`、`result.*`），不需要新 IPA |
| `ios/Sources/WebHTVCore/Spider/SpiderRegistry.swift` | `ported` 加一行 `"Wwys"`（註解：類別 http-html、qist spider.jar） |
| `ios/Tests/WebHTVCoreTests/WwysSpiderTests.swift`（新） | 13 個測試；閘門 7 個回應 raw deflate＋base64 內嵌，載入時核 sha256（和閘門 `SHA256SUMS` 相同）；回應本體沒有 Cookie（`PHPSESSID` 只在 `.headers`，沒有內嵌） |
| `ios/Tests/WebHTVCoreTests/SpiderGoldenTests.swift` | `registryClaimsOnlyWhatIsActuallyPorted` 的名單加 `"Wwys"`（`ported` 多一項，這個寫死的名單必須同步，否則變紅） |
| `scripts/spider_pack.py`、`scripts/runtime_pack.py` | **沒動**。兩支工具從 `ios/Spiders/*.js` 自動收；`DEFAULT_ORIGINS` 是選填的來源紀錄，Djuu／Ikanbot 也沒有；這版 `spider.jar`（md5 `bf32cf12…`）的 sha256 手上沒有，不寫猜的值 |

內嵌 fixture（全部來自 `wwys-gate-fixtures/`）：

| 檔 | bytes | sha256 | 用途 |
|---|---|---|---|
| `home.html` | 46911 | `8a1a1866…6640` | 今日更新 |
| `cat-1-pg1.html` | 38681 | `3c83292a…701d` | 电影第 1 頁，1/691 |
| `cat-12-pg2.html` | 39060 | `beca3858…362d` | 篩選 cateId=12、第 2 頁，2/116 |
| `detail-96319.html` | 15159 | `11f3c062…8034` | 詳情欄位 |
| `play-96319-src1-num1.html` | 16930 | `bc821c72…1282` | 劇集兩條線路各 15 集 |
| `play-94741-src1-num1.html` | 10306 | `b0b67b2d…1e51` | 電影兩條線路各 1 集 |
| `search-changzheng.html` | 11185 | `c82e9324…d862` | 搜尋「长征」 |

期望值由獨立的 Python 正則解析器導出（`artifacts/w152-logs/expected.py` → `expected.json`，和 host.js 無關）：首頁 12 項 id 串 sha256 `4363d953…6747`；分類 1 第 1 頁 30 項 id `4d75da9e…988f`、名稱 `ee356f15…a9b8`、備註全是 `0.0`；分類 12 第 2 頁 id `8d7bdccd…79d8`、名稱 `067a1f27…9895`；96319 線路② `6d9e5b7e…e0df`（15 集，首 `第01集$https://v.lzcdn27.com/20261009/18602_052ef918/index.m3u8`）；94741 線路② `第01集$https://v.lfthirtytwo.com/20260817/9549_253c93dd/index.m3u8`。

**閘門更正**：閘門 #18 寫搜尋「`#data_list > li` 10 項」，實際頁面只有 **5 項**（96319 伟大的长征、73999 长征先锋、73471 向着星辰的长征、28481 长征、6443 长征1996）；測試以 5 項為準。

## 4. 驗證（log 在 `artifacts/w152-logs/`）

| 項目 | 結果 |
|---|---|
| 先紅 | 測試先寫、`Wwys.js` 與 `ported` 行都還不存在時跑 `swift test --filter WwysSpiderTests`：13/13 失敗（`csp_Wwys` 取不到腳本）→ `red.log` |
| 後綠 | `swift test --filter WwysSpiderTests`：13/13 通過 → `green.log`。紅之後改過兩條測試：搜尋備註改為只留評分（§2）；分類頁失敗改為預期 runtime 的 `SiteUnreachable`（runtime 把「空結果＋失敗請求」轉成站台無法連線，Djuu DJ-20 同一機制），另補搜尋第 2 頁／空關鍵字不發請求 |
| 涵蓋 | 首頁 6 分類無 20、篩選值、不發請求；今日更新 12 項＋畸形 img；`ext` 的 `$$$`／尾斜線／空字串；分類分頁 1/691、篩選 2/116；分類失敗、非數字 tid；詳情全欄位＋只有線路②（不含 `123clouddisk`、不含 `$$$`）；電影 1 集；只有線路①、沒有 `mac_url`、空播放頁 → 沒有線路；線路② 排第一也認得；詳情失敗、非數字 id；搜尋 5 項＋URL 編碼＋第 2 頁；播放直接回 m3u8、`parse:0`、UA header、非 http 回空、不發請求 |
| Registry／解耦 | `swift test --filter "SpiderDecoupleTests\|registryClaimsOnlyWhatIsActuallyPorted"`：5＋1 通過（含 `everyPortedClassHasItsScriptInTheRepository`）→ `decouple.log` |
| 打包 | `python3 -I scripts/test_pack_exclusions.py` → `PASS: compatibility 34 scripts without ['Djuu', 'Ikanbot'], official 36 with them`（官方包名單 = `ported`）→ `pack-test.txt` |
| Ponytail review | 對最終 diff 自審（`ponytail-review`）：沒有必修項，Ship。核過：失敗路徑都回空不拋錯、線路依代碼對應、`mac_from`／`mac_url` 組數不一致時回空字串、搜尋與播放沒有多餘請求 |
| Simulator（`artifacts/w152-gui-evidence/RESULT.md`） | 2026-10-19 11:30–11:41 CST，熱點出口 `111.71.119.15`，暫存機 iPhone 18 Pro／iOS 27.0（測完刪除，BC4948DD 全程關機），安裝後雜湊與 build 相同（`fc19061a` 的 App，W-152 不改 App）。本機 HTTPS 提供 `runtime_pack.py` 建的序號 5（36 支），設定只放這一站：全是爬蟲站畫面「有 1 個來源需要爬蟲工具」→ 下載 → `applied 2026-10-19.w152-5 seq 5`；首頁 42 部（今日更新），分類只有 電影／連續劇／綜藝／動漫／短劇／音樂、沒有小姐姐；連續劇第 1 頁 30 部；《醉夢》詳情只有「線路② · 4 集」；第 1 集 AVPlayer 1789 ms 起播、0 次卡頓，時間碼與實際時間一致，關閉後播放摘要正常。全部 PASS。偏差：省流量規則要播 30 秒內，實際約 148 秒（axe 每次讀畫面要 10–19 秒），總用量估約 25 MB；分類改用連續劇，因為爬蟲站首頁載入後第一個分類（電影）已標成選取、再點不會重新載入（App 既有行為，不屬本單，已回報 Manager）。站方線路②只有 1–4 集、列表寫「更新至08集」，是站方資料；線路② 內有站方插的廣告，App 偵測到兩段共 51.5 秒 |
| 全量 swift test | 1331／50 通過（`artifacts/w152-logs/full.log`）。官方包序號 5 試建（`runtime_pack.py build --sequence 5`）36 支、含 `Wwys`，verify 0 problem（`pack-seq5.txt`） |
| 上游篩選對照 | 實作時 `/private/tmp` 的反編譯原碼已被清掉，篩選值先從站方分類頁導出；之後從 `artifacts/qist-next-batch-2026-10-16/jar-new/spider.jar`（md5 `bf32cf12…`）重新反編譯 `Wwys` 對過：上游 `filterContent` 的電影 9 個、連續劇 4 個子分類 id 與本實作逐一相同；「全部」上游是分類 id 本身，本實作空值時回到分類 id，行為相同；唯一差別是 13 的名稱，上游寫「港台剧」，本實作用站方頁面上的「港台泰」 |

## 5. 沒驗到

- 沒有實網請求（全部用閘門 fixture）；沒有在 App／模擬器實播線路②（線路② 可播仍是閘門依 TS 同步位元組推論）。
- 上游原碼副本已不在，篩選 JSON 沒能和上游逐字比對（值來自站方頁面）。
- 分類 2/3/4/26/31 只有 1 與 12 有 fixture；其他影片是否都有線路② 沒全面檢查（閘門只抽 2 部），沒有線路② 的影片在 App 會沒有可播線路。
- 簡介內文若含 HTML 實體（`&quot;` 等），host.js 的 `Text` 不解實體，會原樣顯示（fixture 只有前綴的 `&nbsp;`，已去掉）。
- 公司網路連不到站（閘門紀錄的逾時），沒有處理。

## 6. 回滾

刪 `ios/Spiders/Wwys.js` 與 `WwysSpiderTests.swift`，還原 `SpiderRegistry.ported` 的那一行與 `SpiderGoldenTests` 名單的 `"Wwys"`（或 `git revert` 該 commit）。之後 registry 不再宣稱 `csp_Wwys`，打包工具也不再收它；本單沒有發布物要收回。
