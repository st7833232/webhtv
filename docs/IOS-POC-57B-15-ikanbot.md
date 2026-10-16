# IOS-POC-57B-15：爱看 • 影视（Ikanbot）移植（W-41 IKANBOT-IMPL）

- 工單：W-41（webhtv-dev-claude-dev-2），使用者 2026-10-12 核准實作。設計閘門：`artifacts/qist-ikanbot-gate-2026-10-09.md`（W-14／W-18 PASS，sha256 `a7a62c61…33cd1`）；片单 folder：`artifacts/qist-ikanbot-folder-2026-10-09.md`、`artifacts/qist-folder-design-2026-10-09.md`（App 端已由 W-40／IOS-POC-60 落地）；審查預備：`artifacts/review-prep-W-41-W-42-2026-10-15.md`（取代 10-13 版的過期處）＋`review-prep-W-41-2026-10-13.md` 的 I01–I28、J-01–J-20。
- 上游：`Ikanbot.java`（qist `j-spider.jar` blob `8ac9cb8e…`，jadx 394 行，sha256 `cdabae02…0b8d`，副本 `artifacts/w129-upstream/`）。
- 分支 `task/W-41`，parent＝origin/ios-poc `31161856`（W-122 審後修正）；guard `IKANBOT-IMPL`，一個 commit，`--no-tag`。

## 1. 拍板與範圍（Manager #2158、#2166、#2249、#2254）

| 項 | 決定 | 本單做法 |
|---|---|---|
| B1 fixture 遺失 | 用 W-117 live 副本＋實作時重抓，新 fixture 壓縮內嵌測試，期望值重新導出、記入本文件 | 2026-10-15 07:04–07:05 UTC 以公開 GET 重抓一次（§3），raw deflate＋base64 內嵌 `IkanbotSpiderTests.swift`，載入時核 sha256。期望值用一支獨立的 Python `html.parser` 小解析器從同一批頁面導出（不是拿 JS 輸出回填）。**取代 gate:110 的 fixture 值，結構與規則不變** |
| B2 FOLDER-04 | 「只隨 IPA」排除只加在相容包工具 | `scripts/spider_pack.py` 加 `IPA_ONLY = {"Ikanbot.js"}`，`build` 跳過（W-42 加 `Djuu.js`） |
| #2249（使用者 15:15） | Ikanbot、Djuu 不進第一版官方包 | `scripts/runtime_pack.py` 加暫時集合 `NOT_IN_FIRST_OFFICIAL_PACK = {"Ikanbot.js", "Djuu.js"}`，`shortcut:` 註記「第一版官方包先不收，發第二版前移除這個集合」；新測試 `scripts/test_pack_exclusions.py` 兩支工具各 build 一次，確認輸出不含這兩支；`IkanbotSpiderTests.neitherPackToolPacksIkanbot` 在 `swift test` 裡跑它 |
| #2254（W-122 已推） | 基準種子缺的 class 由內建層提供 | `SpiderBaselineTests.notInBaseline` 加 `Ikanbot.js`；基準 manifest 不重建、序號不升 |
| B3 GUI | W-41 驗 G1–G6a、G12（G11 能捲就驗）；G6b、G7 由 W-42 驗，兩單一起關 | 見 §5 |

範圍：`Resources/Spiders/Ikanbot.js`（新）、`SpiderRegistry.ported` 一行、`SpiderGoldenTests` 一個名稱、`SpiderBaselineTests`（`notInBaseline` 一個名稱＋種子測試認得這個集合，§6）、`IkanbotSpiderTests.swift`（新）、`scripts/spider_pack.py`、`scripts/runtime_pack.py`、`scripts/test_pack_exclusions.py`（新）、本文件。不動 App、`CMSClient.swift`、`RuntimeABI.swift`、`host.js`、`spider-pack/`。

### 1.1 guard 過程（照實記錄）
1. 第一次開 guard 前已先改了四個檔：把改動移到 scratch、還原、開 guard（`aaa14023`，protected 0）、再放回。
2. #2249 擴大範圍後，把 `scripts/runtime_pack.py`、`scripts/test_pack_exclusions.py` 加進 guard 的 scope 清單（`.codex/task-state/current/scope`；開 guard 時沒有任何既有 dirty 被保護）。
3. 送審前 origin 已推進到 `31161856`（W-122），而 #2254 要求同一個 commit 改 `SpiderBaselineTests.swift`：把那次 guard session 標成 `abandoned`、分支 fast-forward 到 origin（沒有改寫歷史）、以完整 scope 重開 guard（protected 0）、放回改動。過程中一次備份指令失敗（zsh 不拆 `$F`）導致未提交的檔被還原／刪除；已從先前的備份（`Ikanbot.js` 與 GUI 受測版 sha256 `a310a0cd…aeb` 相同、兩支 pack 工具、registry、golden）與原文重建（測試檔、`test_pack_exclusions.py`、本文件），之後重跑 §4 的檢查。

## 2. 和上游的差異（全部是閘門 §6.4 已核准的窄適配）

- canonical id：首頁、分類、搜尋的 `vod_id` 一律是 href（`/play/995772`）；詳情也接受上游舊複合 id（`split('$$$')[0]`），輸出 canonical id。
- 片单結果自組並帶 `vod_tag`（`host.result.page` 會丟掉它）；kanlist 項目 `folder`、其他分類 `file`。片单海報不經 `d()`，影片海報經 `d()`。
- 篩選：iOS 一律傳 `filter=false`，所以只要 extend 有非空值就替換。
- `[排序:]`：每個 key 依序把所有符合的線路（還沒被前面 key 取走的）移到前面，每條只移一次（上游 remove 後仍 `i++`，相鄰兩條相符時會漏掉第二條）。
- 詳情的片名取 `h1`、海報取 `img.cover@data-src`（`src` 是 SVG 佔位圖）。
- `get_tks`：Java 在 id 太短、末 4 位非數字、token 太短時丟例外回 `""`；JS 明確檢查這三種情況並回空，詳情回空、不打 getResN。
- 線路資料畸形：單一 `resData` 不是 JSON 時只略過那條線路（上游整個詳情回空）；`data.list` 缺失或 getResN 非 200 時整個詳情回空。
- 搜尋關鍵字用 `encodeURIComponent`（空白是 `%20`，上游 `URLEncoder` 是 `+`）。
- 分類回空時回 `{list:[]}` 形狀而不是上游的 `""`（`SourceClient` 解析 `""` 會丟錯）；失敗請求照既有規則由 runtime 轉成 `SiteUnreachable`。
- 不在範圍：XYQ.jar 變體（閘門 §6.6）。0825 的 `$$$proxy` ext 原本也不在範圍，W-144 已支援（見文末）。

## 3. Fixture 來源（2026-10-15，公開 GET，桌機 UA＋`Referer: https://www1.ikanbot.com`，沒有代理、沒有被攔截的跡象）

| 檔 | URL | UTC | 狀態 | 大小 | sha256 | 和閘門版比 |
|---|---|---|---|---|---|---|
| home | `https://www1.ikanbot.com` | 07:04:58 | 200 | 27158 | `a2ecf399…7c7ee` | 閘門沒有首頁；W-117 有 |
| hot-movie | `/hot/index-movie-热门.html` | 07:04:58 | 200 | 28701 | `1f0cffec…1738` | 閘門 `b893ec9d…`，內容已變（首筆 `/play/978607`「希望」） |
| kanlist-all-p1 | `/kanlist/全部-p-1.html` | 07:04:58 | 200 | 25345 | `e85a5ede…e5ac` | 首筆與閘門值相同（`/article/233`、15 筆、同一張海報） |
| search | `/search?q=功夫女足` | 07:04:58 | 200 | 21058 | `96da3c81…82e4` | 閘門沒有搜尋 fixture（K13） |
| detail-995772 | `/play/995772` | 07:04:58 | 200 | 15051 | `4043a02b…94d0` | 算出的 token 仍是 `5dba759a…3e3e` |
| getResN | `/api/getResN?videoId=995772&mtype=1&token=5dba759abf70c447fa65b47936fe3a3e` | 07:05:12 | 200 | 5181 | `1c5bce42…c4ea` | **和閘門逐位元組相同** |
| article-233 | `/article/233` | 07:05:12 | 200 | 21693 | `35234a24…b7f0` | 閘門 `386d0814…`；首筆仍 `/play/420851`「狗镇」、9 筆 |
| kanlist 404 | `/kanlist/全部.html` | 07:05:12 | 404 | 796 | `fcff2ed8…82dd` | 和閘門逐位元組相同（未內嵌，測試用合成 404） |

內嵌的是前 7 份（壓縮後 base64 約 39 KB）。期望值（獨立 Python 解析器）：首頁 24 筆（兩個 `v-list`，首筆 `/play/978607`「希望」、第 13 筆 `/play/1026022`）；hot 24 筆（`.item` 會得 48）；片单 15 筆；article 9 筆（首筆「狗镇」，海報 `p2457169802.jpg`）；搜尋 10 筆（首兩筆 `/play/995772`「功夫女足」`[31条线路可播放]`、`/play/1001522`「功夫女足之外星人篇」`[10条线路可播放]`）；詳情 `h1`「功夫女足」、year／area／actor 都空；31 條線路，`vod_play_from` sha256 `e4619f4d…6f26`、`vod_play_url` `71797192…f35f`；上游 filters（`Ikanbot.java:313`，排序後）sha256 `3abebb4c…7631`。

## 4. 測試紀錄

- 先紅：拿掉 `ported` 的 `"Ikanbot"` 那行，`swift test --filter IkanbotSpiderTests` 13 個全紅（`registryDrivesIkanbot` 斷言失敗，其他在 `#require(entry(for: "csp_Ikanbot"))` 失敗），log `artifacts/w41-logs/red.log`；放回後 13 個全綠（`green.log`）。
- Ponytail review 後加的第 14 個測試 `neitherPackToolPacksIkanbot` 以及 MK4 的 `#require`：`green-final.log` 14/14。
- mutant（`artifacts/w41-logs/mutants.log`，另 `mutants-2.log`、`pack-exclusions-mutant.log`）：

| ID | 突變 | 結果 |
|---|---|---|
| MK1 | 分類改用 `host.result.page` | 殺：hot、kanlist、article 三個測試 |
| MK3 | `get_tks` 拿掉長度檢查 | 殺：`aDetailWithoutATokenOrWithBrokenLinesFailsQuietly` |
| MK4 | 首頁只取第一個 `v-list` | 殺：第一輪是陣列越界崩潰，改成 `#require(count == 24)` 後在 `homeVideosWalkBothListsWithCanonicalIds` 乾淨失敗（`mutants-2.log`） |
| MK5 | article 第 2 頁照發請求 | 殺：article、address 兩個測試 |
| MK6 | `div.item` 改 `.item` | 殺：`aHotCategoryListsTaggedFiles` |
| MK7 | getResN Referer 改主機 | 殺：`detailReadsThePageThenItsLines` |
| MK8 | 片单海報經 `d()` | 殺：`kanlistListsFolders` |
| MK9 | article 套通用 `{cateId}` 模板（先替 extend） | 殺：`anArticleListsFilesAndHasOnePage`（I08b） |
| MK10 | 播放 header key 改 `UA` | 殺：`playIsDirectWithOnlyTheUserAgent` |
| MK11 | `[排序:]` 不生效 | 殺：`sortExtendMovesEveryMatchOnceOnAMirrorHost` |
| MK12 | 搜尋不去尾年份 | 殺：`searchListsCanonicalTitlesWithLabels` |
| MP1 | `runtime_pack.py` 拿掉排除 | 殺：`test_pack_exclusions.py`「official pack carries ['Ikanbot']」 |
| MP2 | `spider_pack.py` 拿掉 `IPA_ONLY` | 殺：同上「compatibility pack carries」；`swift test` 的 `neitherPackToolPacksIkanbot` 也紅（`mutants-2.log`） |

MK2（照抄上游迴圈）沒有單獨做：與 MK11 同一段程式，負向斷言 `from != [ff1, ik1, a, ff2, b]` 寫在測試裡。

- 全量：rebase 前（parent `aaa14023`）`swift test` 1233 tests／46 suites 全過（`artifacts/w41-logs/full.log`）。rebase 到 `31161856` 後的結果見 §6。

### Ponytail review（對最終 diff 跑過）
- 1（Should fix）`scripts/test_pack_exclusions.py` 沒有任何東西會自動執行 → 已在 `IkanbotSpiderTests` 加 `neitherPackToolPacksIkanbot`，用 `Process` 跑它，`swift test` 會守住。
- 未查：host `textOf` 不解 HTML 實體；7 份頁面的標題都沒有實體，沒有實際案例。
- 另外自己修了一處過時註解（`spider_pack.py` 原寫「官方包會收」，#2249 之後改為各自規則）。

## 5. Simulator GUI（`artifacts/w41-gui-evidence/RESULT.md`，背景 fork 執行）

- 受測 build：parent `aaa14023`＋本單工作樹（rebase 前）。`Ikanbot.js` 在 checkout、.app、Simulator 容器三處 sha256 都是 `a310a0cd…aeb`；`WebHTVApp`、`WebHTVApp.debug.dylib` .app＝容器。Simulator 自建 `WebHTV-dev2`（`107AA88B-F2E2-430A-B3CC-500C7ED07B1E`，iPhone 18 Pro／iOS 27.0；BC4948DD 被別人開著無法 clone）。容器測後還原 BYTE-IDENTICAL。
- folder 導覽 GUI（W-40 延後項）：G1 PASS、G2 PASS、G3 PASS、G4 PASS（1080zyk 線路實播：`started 狗镇 HD中字版 on 原生`，00:14→00:29，兩張畫面不同）、G5 PASS、G6a PASS、G11 PASS、G12 PASS；G6b、G7 未驗（待 W-42）。
- 縮小版 R6／R7（嗶哩 • 合集）PASS。
- Ikanbot 完整移植：PASS（首頁 4 類、片单進 folder 並實播）；實機未驗、MPV 未驗。
- 觀察（不是本單缺陷）：片单海報站方圖床回 404（上游同網址）；ff／xl 線路本機 TLS 憑證錯誤；詳情「立即播放」不照所選線路播（App 既有行為）。
- rebase 到 `31161856` 後沒有重跑 GUI：W-122 的 App 改動是啟動時離線種子，`Ikanbot.js` 不進種子、由內建層提供（#2254），Core 測試涵蓋（§6）。

## 6. 送審狀態

- rebase 到 `31161856` 後第一次全量：1290 個測試只有 1 個失敗——W-122 的 `SpiderBaselineTests.anEmptyScopeIsSeededAndRunsTheSameScripts` 要求每個 `ported` class 都來自種子，而 Ikanbot 依 #2249／#2254 刻意不進種子。修法：同一個 `notInBaseline` 集合裡的 class 改為斷言「仍由內建層提供（`source == .bundled`）且腳本和內建相同」，其餘照舊要求來自種子。
- 修正後全量 `swift test`：**1290 tests／47 suites 全過**（`artifacts/w41-logs/full-rebased.log`，`Ikanbot.js` sha256 仍是 GUI 受測版 `a310a0cd…aeb`）。
- commit SHA 與 parent 記在看板與 `work done`（parent＝origin/ios-poc `31161856`）。

## W-144：0825 的 `$$$proxy` 後綴（2026-10-16）

- 問題：W-139 的 Simulator 情境③發現，0825 把這個站設成 `https://v.ikanbot.com$$$proxy`。`init` 只照上游切 `[`，主機變成 `v.ikanbot.com$$$proxy`，首頁報「找不到網域」（Reviewer W-139 N-1）。
- 修正：`init` 先切掉 `$$$` 之後的 TVBox 附加旗標（同一份設定的荐片用 `$$$1` 也是這種寫法），再照原本規則取主機與 `[排序:`。iOS 沒有代理，旗標直接丟掉。只改 `ios/Spiders/Ikanbot.js`，隨下一個官方包（序號 4）發出，不必改版 App。
- 驗證（`artifacts/w144-logs/`）：新測試 `aDollarFlagSuffixIsNotPartOfTheHost` 先紅（請求打到帶後綴的主機，`red.log`）後綠，`IkanbotSpiderTests` 15/15（`green.log`）；`test_pack_exclusions.py` PASS、`runtime_pack.py build --sequence 4` 試建 35 支 verify 0 problem（`tools.txt`）。沒驗到：0825 線上首頁的實際內容（要等序號 4 發布後在 App 裡下載）。
- Ponytail：沒有 finding（一行；`$$$` 不可能是合法主機的一部分，`[排序:` 也不再帶到旗標）。
