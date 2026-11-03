# W-235：評估改進 iOS App 的 HLS 廣告偵測規則

> 狀態：已實作，待正式審查。由 Manager #5855 指派（2026-11-03），Reviewer #5862 預審後補完 3 項，#5866 通過；使用者核准實作（Manager #5870）。實作與驗證見第 7 節。
> 證據：`.herdr-synapse/webhtv-dev/artifacts/w235-ios-hls-ad-rules/`。

## Recovery anchor
- 目標：判斷 iOS「智慧去廣」要不要修正「可疑區塊上限」的計數方式。
  - 現況：90 分鐘以上的片，如果廣告每插一次就被切成 2 個區塊，整部會被判成「不明確」而完全不跳（W-233 根因）。
- 驗收：
  - W-233 的實際清單：正片 0 誤刪。
  - 其他站、其他 CDN 的實際清單：判斷結果和現行規則相同。
  - 對抗清單：保護不能變弱。
  - Android 對拍語料 26 例：結果不變。
- 狀態：方案 C 已實作在 task/W-235（從 `ed471d39` 開出）。單元測試、Simulator 實播、Ponytail 都完成，等 Reviewer 正式審查。
- 下一步：Reviewer 核准後由 Manager push，隨下一版 App 發布。

## 1. 問題
- iOS 的 `HLSAdsParser`（`ios/Sources/WebHTVCore/HLSAdsParser.swift`）逐條移植自 Android FongMi fork 的 `HlsAdsParser.java`（`third_party/maven/androidx/media3/media3-exoplayer-hls/1.11.0-alpha01-fongmi/…-sources.jar`）。
- 不連續分析 `findAdsByDiscontinuity` 的規則：
  - 段數少於「最常見區塊段數 × 0.75」的區塊算可疑。
  - 可疑區塊數在 1 到上限之間才採用。上限依片長：≤30 分鐘 3、≤60 分鐘 4、≤90 分鐘 5、>90 分鐘 6（`minorityCountThreshold`，第 119–124 行）。
- 有些 CDN 把一次廣告切成 2 個相鄰的 DISCONTINUITY 區塊。90 分鐘以上的片插 4 次廣告就有 8 個可疑區塊，超過 6，整部判「不明確」不跳。
  - 例：W-233 根因片 122.7 分鐘（`artifacts/w233-kkys-ad-skip/報告.md` 第 42 行）。
- 同一條 CDN 同樣插 4 次，如果每次只是 1 個區塊，就會跳。
  - 例：空枪，4 個區塊；見 W-233 文件 13.4 的 iOS log。
- 所以使用者看到的是「有的片會跳、有的片不會」。

## 2. 方案比較
| | 做法 | 好處 | 壞處 |
|---|---|---|---|
| A 不改 | 維持與 Android 逐條相同 | 對拍測試保證一致，沒有新風險 | 根因片這類「一次廣告切 2 塊」的長片照樣播廣告 |
| B 照 Android 改 | 等上游 FongMi fork 修改 | 兩平台一致 | 上游公開分支找不到這個檔（第 5 節），追不到修改，也沒有時程 |
| **C 有限合併（建議）** | 只改計數：一串連續的可疑區塊**剛好 2 塊、而且合計 ≤60 秒**時算 1 次；其他情況照 Android 一塊算一次。哪些段要刪、上限、其他規則都不變 | 根因片類型可以跳；一長串短區塊與分散的區塊照樣受上限保護 | 和 Android 不再逐條相同，要在測試寫明這個差異 |
| D 套用 W-233 的 K／R＋F／P | 把 kkys.py 的證據規則搬進 App | 對已知素材判斷更準 | K 是 2026-11 素材的段長，換素材就失效；R＋F 要估幀率，是新規則；P 在 App 已有 `findAdsByFilename`。規則大、要維護，不適合通用 App；W-233 已在腳本層處理那 5 條線路 |

- C 的原型在 `artifacts/w235-ios-hls-ad-rules/probe/HLSAdsParserC.swift`：迴圈改成先收集一串連續的可疑區塊再計數，另加一個逐段秒數的函式，約 30 行。
- 為什麼要「剛好 2 塊、≤60 秒」（Reviewer #5862 第 1 點）：
  - `HLSAdTimeline` 的 120 秒保護是逐一檢查「每個來源區塊」，檢查完才合併相鄰範圍（`HLSAdTimeline.swift` 第 78–80 行）。
  - 如果不限制，正片有 10 個相鄰的 60 秒短區塊時，C 會把它算成 1 次，整段 10 分鐘被跳掉；現行規則算 10 次，超過上限，不跳。
  - 只合併「剛好 2 塊」的一串，3 塊以上照樣一塊算一次。所以一長串短區塊的計數和現行規則完全相同。
  - 60 秒和 W-233 kkys.py 的「一次廣告最長 60 秒」一致。

## 3. 離線驗證（2026-11-03，原始碼 webhtv `3ccb48cc`）
- 做法：把 iOS 的 `HLSAdsParser.swift`、`HLSAdTimeline.swift` 原封不動複製到 scratch 的獨立 Swift 套件，加上方案 C。repo 一行都沒動。
- 「刪到正片」的定義：iOS 要跳的時間落在參考答案範圍外的秒數。

### 3.1 W-233 抓的可可影視清單（79 份）
- 參考答案：W-233 審查過的規則 B（`kkys.hls_ad_lines`；W-233 文件 12.3，0 誤刪）。
- 原始結果：`compare-summary.tsv`、`compare-rows.tsv`。

| 線路 | 清單 | B 認定的廣告秒數 | 目前規則：跳到／漏掉 | C：跳到／漏掉 | 刪到正片（目前／C） |
|---|---|---|---|---|---|
| FF | 11 | 575 | 575／0 | 575／0 | 0／0 |
| LZ | 11 | 721 | 721／0 | 721／0 | 0／0 |
| 蓝光 | 12 | 611 | 542／70 | **611／0** | 0／0 |
| 蓝光1 | 12 | 696 | 696／0 | 696／0 | 0／0 |
| 蓝光1-1 | 2 | 155 | 155／0 | 155／0 | 0／0 |
| 蓝光3 | 12 | 561 | 475／86 | 475／86 | 0／0 |
| JY（三條分線；沒有 DISCONTINUITY，走不到不連續分析） | 13 | 0 | 0 | 0 | 0／0 |
| 48 分鐘劇集（舊抓取，沒有線路紀錄） | 5 | 209 | 209／0 | 209／0 | 0／0 |
| 根因片（122.7 分鐘） | 1 | 74 | 0／74 | **74／0** | 0／0 |

- C 多抓到 2 部，兩部目前規則都判 no-ads，C 跳的時間都和 B 完全重疊，正片 0 秒：
  - 根因片：8 個可疑區塊，合併成 4 次。
  - 蓝光《欢迎来龙餐馆》：141.2 分鐘，4 次廣告共 69.7 秒。
- 兩種規則都漏的蓝光3（86 秒）是另一個原因，C 不處理：
  - yzzy 的正片區塊很長、每塊段數都不同，「最常見段數」反而變成廣告自己的段數（每支廣告出現 2 次），門檻就算錯了。
  - 最後一塊一律不判，所以《杯雪·一战成名》《生化危机爆发夜》各漏最後一支 17.7 秒。
  - 《老江湖》3 支都沒抓到，只跳了一個夾在兩支廣告中間、0.17 秒的區塊。
  - W-233 已在 kkys.py 層處理這部分；App 層要處理就另開題目。

### 3.2 其他站、其他 CDN 的實際清單（Reviewer #5862 第 2 點）
- 來源：GitLab `wang-movie.json` 的 13 個 type-1 CMS 站，各抓第 2、3、5 頁每頁 8 部，取第 1 集（只讀）。只保留有 `#EXT-X-DISCONTINUITY`、而且是 VOD 的 variant。
  - 檔案：`neg/index-all.json`、`neg/summary.txt`。
- 結果：82 份、16 個 CDN 主機。**C 和目前規則判得不一樣的：0 份。**

| CDN 主機 | 清單 | C 與目前規則相同 | 兩者都不跳 |
|---|---|---|---|
| maowushi | 20 | 20 | 0 |
| modujx17 | 22 | 22 | 0 |
| ryiplay18／ryiplay20 | 14 | 14 | 8 |
| ryplay10／11／12／14 | 10 | 10 | 5 |
| lzcdn27／28／31 | 9 | 9 | 0 |
| yzzy30／31-play | 4 | 4 | 0 |
| ffzy-plays、high20-playback、yaaabc | 3 | 3 | 2 |

- 有 DISCONTINUITY、兩種規則都不跳的：15 份，來自 7 個主機（4 個 CDN 家族：ryiplay、ryplay、high20、yaaabc）。C 在這 15 份也沒有跳。
- 抓不到的照實記錄，沒有繞過：
  - 優質、飘零、无忧的 m3u8，以及天涯、菠菜、艾旦的部分 m3u8：連線失敗（URLError）。
  - 豆瓣的 API：連線失敗。
  - 创享、天涯、菠菜抓到的清單沒有 DISCONTINUITY，走不到這條規則。
- 限制：
  - 「兩者都不跳」不等於人工確認這部片沒有廣告。
  - 但 C 只會在「剛好 2 塊、≤60 秒」的一串上和現行規則不同；82 份裡沒有一份出現這種差異，所以這批清單上 C 沒有新增任何跳轉。

### 3.3 對抗清單（`adversarial.txt`、`adv/`）
- 人造清單：正片區塊 50 段 × 6 秒，片長 100 分鐘以上，段名是隨機雜湊，避開檔名規則。

| 清單 | 期望 | 目前規則 | C |
|---|---|---|---|
| 10 個相鄰短區塊、每塊 60 秒（Reviewer 的例子） | 不跳 | 不跳 | 不跳 |
| 10 個相鄰極短區塊、每塊 5 秒 | 不跳 | 不跳 | 不跳 |
| 4 次廣告、每次切成 2 塊（合計 18 秒） | 跳 4 段 | 不跳 | **跳 4 段、72 秒** |
| 分散 7 個短區塊 | 不跳 | 不跳 | 不跳 |
| 4 次 2 塊相鄰、但每次合計 72 秒 | 不跳 | 不跳 | 不跳 |
| 3 次 3 塊相鄰（每次合計 30 秒） | 不跳 | 不跳 | 不跳 |

### 3.4 Android 對拍語料（26 例，`golden-diff.tsv`）
- `HLSAdsParserTests.swift` 裡 Android 在 2026-09-25 實跑過的 26 份語料：C 的結果和目前規則全部相同。
- 這組語料當作回歸測試，不算負樣本。

## 4. 風險與限制
- 和 Android 不再逐條相同：
  - 對拍測試的檔頭要註明唯一的差異，並加第 6 節的 C 專屬案例。
  - Android 不改，它是官方 FongMi APK。
- 「剛好 2 塊、≤60 秒」是依現有樣本定的：
  - 如果某個 CDN 把一次廣告切成 3 塊，C 照樣抓不到，和現在一樣。
  - 如果正片剛好有「2 塊相鄰、合計 ≤60 秒」的短區塊，而且整部的可疑區塊合計會因此降到上限以內，C 會跳掉那段。這段最長 60 秒，而且兩塊都必須是「段數少於常見段數 3/4」的短區塊。目前 161 份實際清單（79＋82）裡沒有這種情況。
- 只影響 iOS「智慧去廣」開啟時的跳轉，不改播放清單本身；關掉這個設定，就和現在一樣。

## 5. 研究來源（設計研究 gate，2026-11-03 查閱）
| 類別 | 來源 | 結論 | 影響 |
|---|---|---|---|
| 上游原始碼 | 本 repo 鎖定的 `media3-exoplayer-hls-1.11.0-alpha01-fongmi-sources.jar` 的 `HlsAdsParser.java` 第 128–134 行 | 上限 3／4／5／6 依片長，計數單位是「區塊」 | iOS 逐條相同，根因成立 |
| 上游歷史 | `gh api repos/FongMi/media`：release 分支（2026-10-24 push）的整個檔案樹裡沒有 `HlsAdsParser` | 這個類別只在 FongMi 給 TV 用的 fork；公開歷史查不到 | 方案 B 沒有上游變更可以跟；記為未解 |
| 規格 | RFC 8216，https://www.rfc-editor.org/rfc/rfc8216.html，§4.3.2.3 | DISCONTINUITY 在檔案格式、軌道、時間戳換了時 MUST 出現，編碼參數換了時 SHOULD 出現；RFC 沒有「一次廣告只有一個區塊」的語意，廣告只在 §4.3.2.7.1 的 SCTE-35 `EXT-X-DATERANGE` 出現 | 用區塊數當廣告次數本來就是近似；一次廣告切成 2 塊（例如換編碼參數）完全符合規格，支持 C |
| 成熟播放器 | Kodi `xbmc/inputstream.adaptive`（`src/parser/HLSTree.cpp` 第 334 行，HEAD `4bbfbc67f97b5c06760c7b40bfc51b787e4bd542`，2026-11-01） | DISCONTINUITY 只用來切 period 和時間軸，沒有廣告判斷 | 主流播放器不做這種啟發式判斷，所以沒有現成的上限設計可以參照 |
| 成熟播放器 | mpv（`gh search code discontinuity --repo mpv-player/mpv`：只有 discnav、encode、recorder 等，沒有 HLS 廣告邏輯；HLS 由 FFmpeg 的 demuxer 處理） | 沒有 HLS 廣告判斷 | 同上 |
| 相關專案 | `skimotv/m3u8adskipper`（`lib/m3u8adskipper.js`，commit `bc0eb897ef0fdbe79cb0a29fa76d18355160330e`，2015-01-14） | 遇到 DISCONTINUITY 就在兩組之間交替，最後保留段數多的那組；沒有次數上限 | 「多數是正片、少數是廣告」是共同原則，但它沒有防誤判；C 保留 Android 的上限，比它保守 |
| 實測 | 第 3 節：161 份實際清單、6 份對抗清單、26 例對拍 | C 正片 0 誤刪，和現行規則只差在「2 塊合併」 | 建議 C |

- 搜尋過的關鍵字：「m3u8 去广告 EXT-X-DISCONTINUITY」「m3u8 广告过滤 TVBox」「mpv script skip HLS ads」。找不到以「合併相鄰區塊」處理廣告次數的現成專案。

## 6. 建議與驗收（待核准）
- 建議：方案 C，只改 iOS 的 `HLSAdsParser.findAdsByDiscontinuity` 計數，加一個逐段秒數函式。
- 驗收：
  1. 單元測試：
     - 原有 26 例對拍不變。
     - 新增第 3.3 節的 6 個對抗案例：只有「4 次 × 2 塊」要跳，其他 5 個不跳。
     - 新增根因片類型的實際結構案例（只取段長，匿名路徑）。
  2. 離線：第 3.1、3.2 節的腳本重跑，正片 0 誤刪、其他站和現行規則 0 差異。
  3. iOS Simulator：根因片，或蓝光線路的《欢迎来龙餐馆》（用原版 kkys）實播，log 出現 `exo-hls-detector ranges=` 4 段，跳過後接的是正片。
- 回滾：還原這段計數。使用者也可以在設定裡關閉「智慧去廣」。

## 7. 實作與驗證（2026-11-03，task/W-235，從 `ed471d39` 開出）
### 7.1 改了什麼
- `ios/Sources/WebHTVCore/HLSAdsParser.swift`：
  - `findAdsByDiscontinuity`：先收集一串連續的可疑區塊再計數。整串剛好 2 塊、合計 ≤60 秒（`splitBreakMaxSeconds`）算 1 次，其他照 Android 一塊算一次。哪些段要刪、上限、退路都沒動。
  - 新增 `segmentDurations`：逐段讀 `#EXTINF` 秒數，認段方式和 `discontinuityBlocks` 相同，所以索引一定對得上；讀不懂的算 0。
  - 檔頭註明這是和 Android 唯一的刻意差異。
- `ios/Tests/WebHTVCoreTests/HLSAdsParserMergeTests.swift`（新增）：
  - 3.3 節的 6 個對抗例。
  - 根因片與蓝光《欢迎来龙餐馆》的實際區塊結構：只有每塊的段數和秒數，段名是匿名雜湊。
  - 檔頭寫明和 Android 的差異。
- `ios/Tests/WebHTVCoreTests/HLSAdsParserTests.swift`：檔頭加 2 行，指向上面這個差異；26 例對拍不動。

### 7.2 驗證（證據 `artifacts/w235-ios-hls-ad-rules/ios-sim/`）
- `swift test`（完整）：1432 個測試、58 個 suite 全部通過，包含 26 例 Android 對拍和新增的 9 個案例（`swift-test.txt`）。
- 兩個 mutant：
  - 「全部合併」：長串短區塊、3 塊、2 塊超過 60 秒這幾個測試都失敗。
  - 「照 Android 不合併」：4 次 × 2 塊和兩份實際結構的測試失敗。
  - 兩個 mutant 都被抓到，原始碼已還原。
- iOS Simulator（webhtv-w202，從這個 worktree 編譯的 Debug build；`build-proof.txt` 證明 dylib 含 `segmentDurations` 與 `splitBreakMaxSeconds`）：
  - 用原版 kkys 播根因片《我家的律师又惹麻烦了》的 FF 線路（直連 ffzy，不經 W-233 的代理），總長 2:02:42。
  - App log：`plan exo-hls-detector ranges=356668-376302,1697249-1714609,3635184-3654818,5754612-5771972`。和離線預測的 4 段完全相同，也就是根因報告的 4 支廣告；改之前這部片是 `no-ads`。
  - `skip from=356669ms to=376302ms`：連拍 5:30–6:48（`sheet-root-FF-556.png`），5:52 之後直接接 6:17，前後都是有字幕的正片，沒有其他跳轉。
  - 測完已還原：來源改回 GitLab、刪掉 127.0.0.1 已存來源和快取、模擬器關機、刪掉 DerivedData。Simulator 上留著的是這個 W-235 Debug build。
- Ponytail（W-235 差異）：可以交付。查過索引對齊、NaN／Infinity 秒數（會退回 Android 的計數）、最後一串、呼叫端、速度（多走一次清單，O(段數)）。
- 沒做：Android 不改（官方 FongMi APK）；沒有實機測試。

### 7.3 回滾
- revert 這個 commit 即可；使用者也可以在設定裡關閉「智慧去廣」。
