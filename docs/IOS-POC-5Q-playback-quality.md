# IOS-POC-5Q — 多畫質選擇

- 狀態：**Q1 / Q2 / Q3 已實作並驗證**
- 分支 `ios-poc`，基線 HEAD `d571f3a7`（IOS-POC-5P 之後）
- 計畫：`docs/IOS-POC-5Q-5R-plan-playback-quality-and-history.md`（Ready for Dev，`PASS`）
- 日期：2026-09-18

## 這個階段解決什麼

CatVod 的 `playerContent` 回傳的 `url` 是**三種形狀**，不是一種。權威定義在
`app/src/main/java/com/fongmi/android/tv/gson/UrlAdapter.java`：

| 形狀 | 意義 |
|---|---|
| JSON 字串 | 一條無名線路 |
| JSON 陣列 | `名稱, 網址` 交替；`convert` 以 `i + 1 < size` 兩格前進，**尾端落單的元素直接丟掉** |
| JSON 物件 | `{"values":[{"n","v"}], "position": n}`；`Url.objectFrom` 自己吃掉解析失敗並回傳空 `Url` |

iOS 兩條播放路徑都只認字串，而且**壞的方式不一樣**——這是這個階段的根因：

- spider 路徑 `SourceClient.swift` 的 `decodeIfPresent(String.self, forKey: .url)` 遇到陣列會
  **throw** `DecodingError.typeMismatch`（`decodeIfPresent` 對型別不符是拋錯，不是回 `nil`），
  一路傳到 `VodView.play` 的 `catch` 變成一行原始解碼錯誤字串；
- CMS 路徑 `CMSClient.playbackURL` 用 `try?` 把同一個錯誤吞成 `nil`，顯示
  「這一集沒有可播放的網址」。

兩種都不是站壞了，是我們讀不懂。`Bili.js` 也因此只取 `accept_quality` 的第一項，等於主動放棄
B 站的畫質選擇。

## 做了什麼

### Q1 — `url` 三形狀，一處解碼

新增 `ios/Sources/WebHTVCore/PlayURL.swift`：

- `PlayURL` 逐項對應 `UrlAdapter` 的三個分支，含 `Url.set(int)` 的 `min(position, size-1)` 夾擠、
  尾端落單元素丟棄、以及物件形狀畸形時回傳空選單而非拋錯。
- `PlayURL.Value` 的解碼刻意寬容：Gson 對缺欄位是留 null，所以一個不完整的成員不該毀掉整個選單。
- `PlayURL.isEmpty` 照 `Url.isEmpty`（沒有值，或 `position` 那一項沒有網址）。
- `PlaybackQuality` 是一條可選線路（`name` + `url`），並帶 `defaultIndex(in:position:preferred:)`
  這個**純函式**。

**兩條路徑改走同一個出口。** `SourceClient.target(from:headers:parse:)` 是唯一把 `url` 變成
可播放目標的地方——這個欄位之所以會用兩種方式壞掉，正是因為兩條路徑各自解碼。
`CMSClient.playbackURL` 的回傳型別因此從 `URL?` 改成 `PlayURL?`（type-4 的 `?play=` 回應本來就
可以列多個畫質，以前列了就整筆被丟掉；`vod_play_url` 的目標則是結構上單值，包成一項）。

`PlaybackTarget` 增加 `qualities`、`position`、`defaultIndex`。單一網址的來源仍然得到
**剛好一項**的選單，所以呼叫端永遠不用特判空集合。

**只有預設那一項會被解析。** 五個畫質的選單否則要付五次 probe，或 `parse:1` 時五個 WebView，
才能開一集。代價寫在 `ponytail:` 註記裡：在選單裡改選別的畫質，會用來源原本給的網址開啟，
沒有 probe／sniff 那一跳。目前 62 個來源沒有任何一個回傳 `url` 陣列，所以這個不對稱沒有實際影響；
真的出現時再把 resolver 串進去。

### Q2 — B 站的畫質是「線路」，不是 `url` 陣列（D10）

`Bili.js` 的 `detailContent` 把 `accept_quality` 攤成一條線路一個畫質：
`vod_play_from` = `B站 高清 720P$$$B站 流畅 360P`，每一段的每一集 id 帶自己的 `qn`
（`aid+cid+qn`），`playerContent` 用 id 裡的 `qn` 去請求。

為什麼不用陣列形狀：`accept_quality` 只是清單，**每個畫質的真實網址要各自打一次 `playurl`**。
用陣列等於每開一集就多打 4–8 次 API；做成線路則選擇發生在 `playerContent` 之前，
**額外請求為零**，而且直接沿用詳情頁本來就能用的線路 UI。

**畫質名稱直接用 API 的 `accept_description`，不自建 qn→名稱表。** 實測（2026-09-18）
`accept_quality` 與 `accept_description` 是平行陣列且 best-first：

```
accept_quality      [64, 16]
accept_description  ['高清 720P', '流畅 360P']
support_formats     [(64, '720P 准高清', '720P'), (16, '360P 流畅', '360P')]
```

站方是這些字的唯一權威，所以沒有本地對照表。排序仍明確做（`qn` 由大到小），
讓順序是這段程式的性質，而不是「今天伺服器剛好這樣回」。標籤裡的 `$`／`#` 會被換成空白，
因為那是 CatVod 自己的分隔符。

### Q3 — 畫質選單

`PlayerPickerView` 在既有的播放器選擇 sheet 裡多一個「畫質」section，**只有 `qualities.count > 1`
時才出現**；預設打勾在 `defaultIndex`；選定後才開始播（D7，因此不存在播放中切換要重新 seek 的問題）。
選中的那一項同時餵給內建播放器與外部播放器。

**選單不重新排序。** Android 保持 `Url.values` 來源給的順序，只移動 `position`；這裡照做，
只計算預設索引。D18 的排序表因此只用在「挑預設」，不用在顯示。

**預設索引的優先順序（D8）**：① 記住的選擇（以 `preferred:` 參數注入）② 標籤排名最高
③ 來源自己的 `position`。因為偏好是參數而非查表，Q3 **完全不相依於 R1**——R6 之後由 App 端
帶著記錄再跑同一個函式即可，這也是 `PlaybackTarget.position` 要存下來的原因。

## 與計畫的偏離

| 項目 | 計畫 | 實作 | 原因 |
|---|---|---|---|
| D18 的 `qn` 數字排名表 | 要認 `qn`（127 > 126 > … > 16） | **沒做** | D10 把 B 站的畫質變成線路，所以 `url` 陣列裡永遠不會出現裸 `qn`。寫了就是死碼；已在 `rank` 的註記寫明。 |
| 選單排序 | 計畫沒明說 | 不排序，只算預設索引 | Android 不重排 `values`；D18 的「對不上就保持原序」本來就指向不排序。 |
| B 站畫質名稱 | 計畫沒指定來源 | 用 API 的 `accept_description` | 站方是唯一權威，且省掉一張會過期的本地表。 |
| `PlayURL.isMulti` | — | 寫了又刪 | 只有它自己的測試在讀，production 沒有呼叫端。 |

## 驗證

### 單元測試（S1、S2 的閘門）

```bash
WANG_MOVIE_JSON=<config> swift test --package-path ios
```

**110 測試、109 通過**（5Q 之前是 96／95，新增 14 條）。唯一失敗是既有的
`reportsLiveType4SitesFromProvidedConfig`——88看球 把一集解析成 HTML 頁，測試斷言
`CMSClient` 直出媒體，而那條路徑沒有嗅探那一跳。它在更早的 HEAD 就同樣失敗，**不要去修**。

新增的 14 條在 `ios/Tests/WebHTVCoreTests/PlayURLTests.swift`：三種形狀、落單元素、position 夾擠、
畸形值（`{"values":"nope"}` / `{}` / `[]` / 非字串成員 / 缺 `v`）、`SpiderPlayResponse` 三形狀
（含既有的 `parse` 字串容忍與 `header` 行為未變）、D8 三層優先順序、D18 排序（含全部對不上時保持原序）、
以及單一網址來源仍然是一項選單。

改寫了三條既有斷言，都是型別跟著契約走，不是放寬：

- `SpiderGoldenTests.swift` 原本把 `play["url"]` 硬轉 `String`，任何回傳陣列的來源都會讓它爆；
  改用同檔的 `playURL(_:)` helper 讀三形狀。
- `CMSClientTests.swift` 兩處跟著 `playbackURL` 的回傳型別改（`PlayResponse.url` 與 type-4 掃描）。
- `SourceClientTests.swift` 一處 `.url == "…"` 改讀 `values`。

### Live golden（S3 的閘門）

**新增** `biliOffersMultipleQualityLines`，自己一條 `--filter` 目標。它不吃 `ext`，因為走的是
`searchContent`（B 站的搜尋與分類是同一支 keyword search），所以不需要 `ext.json`
也不需要遠端 config base：

```bash
CSP_GOLDEN_SITE='{"key":"biligequ","name":"bili靜聽歌","type":3,"api":"csp_Bili"}' \
  swift test --package-path ios --filter biliOffersMultipleQualityLines
```

2026-09-18 實測通過：

```
[golden] bili 【无损音质】2026年最火的50首热门歌曲合集…: lines=["B站 清晰 480P", "B站 流畅 360P"]
[golden] bili player qn=32: https://upos-sz-mirrorcosov.bilivideo.com/upgcxcode/90/14/41664381490/… +hdr3
✔ Test run with 1 test in 0 suites passed
```

斷言涵蓋：>1 條線路、每條 id 帶**不同**的 `qn`、`qn` 由大到小（第一條是最大值）、
第一條 `parse:0` 且 `MediaProbe.classify` 回 `.media`（**真的取到媒體位元組**，不只是解析出網址）。

**這一輪只拿到 480P／360P，不是 1080P。** 那是計畫 K3／K10 預測的情形：`qn > 80` 需要有效
SESSDATA，而使用者設定檔那三個 bili 站的 cookie 2025 年就過期，`Bili.js` 的 `api()` 會退回匿名
`buvid3`。API 對無權限的 `qn` 是靜默降級而不是報錯，所以選單只會呈現這個 session 真的拿得到的項目。
測試對「只找到單畫質影片」的情況是印一行訊息後通過，因為那量的是帳號狀態，不是這個 port。

### 既有 generic golden（S1 的「單一字串行為沒變」）

```bash
CSP_GOLDEN_SITE='{"key":"王子","name":"王子","type":3,"api":"csp_AppGet","ext":{"url":"https://app.95112475.xyz","dataKey":"5a9w6x58dsq6z3a6","dataIv":"5a9w6x58dsq6z3a6"}}' \
  swift test --package-path ios --filter appGetDrivesTheWholeCatVodFlowAgainstTheLiveSite
```

2026-09-18 通過：home 6 分類 → category 30 筆 → detail 7 條線路 → search 20 筆 →
`parse=0 https://fengbao12.com/video/…/index.m3u8`。單一字串路徑行為未變。

### 建置

```bash
xcodebuild -project ios/WebHTVApp/WebHTVApp.xcodeproj -scheme WebHTVApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
```

→ BUILD SUCCEEDED。

### 模擬器

iPhone 17 Pro（`7B4E9557-4774-4EB9-B408-BB544DCC8657`），2026-09-18：切到 `bilbil合集`，
分類列、CatVod 篩選列（排序／時長）與真實格線都正常載入，**Q2 沒有造成瀏覽面的退步**。

**沒拿到詳情頁的畫質線路截圖。** 海報 cell 的 synthetic tap 沒有反應——連點標題文字也一樣，
畫面完全沒有變化。這是既有踩坑 ② 的同一類問題（先前只記錄在詳情頁的單集鍵上，
**現在確認格線的 `NavigationLink` cell 也一樣**），原因仍未明。因此 Q2 的畫質線路證據是上面那條
live golden，不是截圖。

**S2 沒有截圖，而計畫本來就這樣寫。** 目前 62 個來源沒有任何一個回傳 `url` 陣列或物件形狀，
所以沒有真實資料可以觸發 Q3 的畫質選單；S2 的閘門是單元測試，截圖是 best effort。

### 沒驗到的

- **實機一次都沒跑。** 專案沒有任何 `CODE_SIGN` / `DEVELOPMENT_TEAM`，全部結果都來自模擬器。
- **Q3 的選單沒有在真實資料上被觸發過**，理由如上。選單資料與預設索引由單元測試涵蓋。
- **非預設畫質的 probe/sniff 那一跳沒有實測**，因為沒有來源會走到（見 Q1 的 `ponytail:` 註記）。
- **全站掃描不列為驗收條件**：2026-09-17／18 已兩次落在 TLS 憑證失效的壞窗，一輪壞掉的掃描
  不等於 regression。

## Ponytail

**實作前（設計軸）。** 爬梯子：① 需要存在——使用者要求，且 Q1 修的是實際會讓使用者看到錯誤字串的
靜默失敗。② 已有的東西先用——`PlaybackTarget` 擴充而不是新增平行型別；`resolveMedia` /
`MediaSniffer` / `MediaProbe` 全部沿用；B 站的畫質名稱用 API 已經回傳的 `accept_description`，
不寫本地對照表。③ 標準庫——`Decodable` 自訂 `init`，沒有第三方 JSON。④⑤ 沒有新增任何相依。
⑦ 最小可行：一個新檔（型別 + 排序）、四處 production 編輯，加上一個共用出口讓 CMS 與 spider
不會再各自壞掉。

刻意不做：選單排序、`qn` 數字排名表、播放中切換畫質、非預設項的 probe/sniff。

**final diff 軸。** 刪掉 `PlayURL.isMulti`——只有它自己的測試在讀。保留
`PlaybackTarget.position`：R6 要用同樣的輸入重跑 `defaultIndex`，少存它就得在 R6 再動三個型別
一次；這是整個 diff 裡最接近 YAGNI 邊界的一項，明白記在這裡。`PlaybackTarget.init` 對空選單
補一項的行為是刻意的不變量（`qualities` 永不為空），選單 UI 靠它。兩個 `ponytail:` 註記
（非預設項不解析、標籤排序是啟發式）都寫明了天花板與升級路徑。

## 下一步

計畫的建議提交順序是 `Q1+Q2+Q3` 一個 commit，接著 `R1+R2+R3+R5`。R2 的前置仍然成立且**還沒做**：
`Playback` 與 `PlaybackSession.open` 目前只帶 `url/headers/title/artwork`，完全沒有站與片的身分
（`ios/WebHTVApp/Sources/WebHTVApp.swift` 的 `Playback` 與 `PlaybackSession`），R2 與 R7 都要靠它。
