# IOS-POC-32 — 詳情頁：海報蓋到標題、顯示年份簡介演員、簡體顯示為台灣繁體、日文翻譯

- 狀態：**階段 A、B 已實作、查核，並隨 `0.1.28 (29)` 發布（Release build 第一次即編譯成功）；單元測試未執行、真機未驗證。階段 C 已實作（2026-09-28，第六節第 5 點）：未編譯、單元測試未執行、真機未驗證、尚未發布。階段 D 待核准。**
- 使用者要求（2026-09-27，附詳情頁截圖，橫向海報超出左緣並蓋住標題）：「這個幫我規劃要怎麼處理，並且之後還需要顯示年份、簡介、演員相關訊息。然後 UI 呈現簡體中文都要顯示成台灣繁體中文，不要動到搜尋邏輯，最好日文也可以幫忙翻譯成中文。」
- 分類：
  - 階段 A（海報版面）：quick-fix，設計由使用者指定（第四節），依 AGENTS.md §7 免設計研究門檻。
  - 階段 B（詳情資料）、C（簡轉繁）、D（日文翻譯）：新功能、新增內建資源、iOS 18 框架，適用 AGENTS.md §7 設計研究門檻；本文件即其研究與計畫紀錄，每個階段各自核准後才實作。
- 研究方式：四個主題各由一個代理研究（版面、資料欄位、簡轉繁、翻譯），綜合成設計後由兩個獨立代理對照程式碼與原始資料查核。查核推翻或修正的內容已改進本文件（第十一節）。
- 本環境沒有 Swift，本文件的程式片段都**未編譯**。

## 一、四個階段共同的規則

### 1. 搜尋不動

以下檔案與行不修改：

- `ios/Sources/WebHTVCore/TraditionalSimplified.swift`（繁轉簡表，只供搜尋用）
- `ios/Sources/WebHTVCore/AggregateSearch.swift:62-78`
- `ios/WebHTVApp/Sources/WebHTVApp.swift:848`、`:864`（分類頁搜尋）、`submit()` `:1135-1146`（搜尋分頁）
- `ios/Sources/WebHTVCore/WebHomeBridge.swift:340-343`（WebHome `app.search`）
- `ios/Tests/WebHTVCoreTests/AggregateSearchTests.swift:28-47`

### 2. 身分值一律不轉換、不翻譯

這些值會送回來源、當作比對鍵或存進記錄，轉換後會找不到資料或接不上進度：

| 值 | 用途（程式位置） |
|---|---|
| `Vod.id`、`episode.url` | 送回來源 |
| 線路名稱 `flag.name` | 送回來源（`SourceClient.swift:86-93`、`CMSClient.swift:359`）；`ForEach` 的 id 與選取鍵（`WebHTVApp.swift:1532-1533`）；與觀看記錄比對（`:1563`、`:1650`、`:1685`）；預載身分（`:1713`） |
| 集數名稱 | 存成 `WatchHistory.vodRemarks`（`:1698-1703`）；續播要名稱相同（不分大小寫，`WatchHistory.swift:191`） |
| 篩選值、分類 id | 送回來源（`:721`、`:850`、`:866`） |
| 畫質名稱 | 記住的畫質以名稱比對（`PlayURL.swift:167`） |
| `Playback.title` | 只進 log 與 `player.status`（`:2924`），不在畫面上 |
| WebHome 橋接資料 | `WebHomeBridge.swift:372`、`:383`、`:439-441` |

### 3. 只在畫面繪製時轉換

- 模型欄位（`CMSClient.swift` 的 `public let`）保持來源的原始字串。
- Android 在 `Vod.trans()`（`Vod.java:302-311`）直接改寫模型欄位；iOS 不採用這個做法，原因就是上表：線路、集數、標題都是身分值。Android 自己的 `Flag` 也保留原始 `flag`，另存顯示用的 `show`（`Flag.java:30`、`:71-72`、`:200`）。

## 二、研究證據（讀取日期均為 2026-09-27）

等級：A＝原始碼或原始資料；B＝官方文件；C＝論壇或次級資料。

| # | 來源 | 版本 | 等級 | 支持的結論 | 對本計畫的影響 |
|---|---|---|---|---|---|
| E1 | Apple SwiftUI 文件：[`scaledToFill()`](https://developer.apple.com/documentation/swiftui/view/scaledtofill())、[`frame(width:height:alignment:)`](https://developer.apple.com/documentation/swiftui/view/frame(width:height:alignment:))、[`clipped(antialiased:)`](https://developer.apple.com/documentation/swiftui/view/clipped(antialiased:))、[`contentShape(_:eoFill:)`](https://developer.apple.com/documentation/swiftui/view/contentshape(_:eofill:)) | 線上版 | B | frame 只影響版面，超出的內容仍會畫出來，除非裁切；裁切不改觸控範圍 | 階段 A 的原因與修法 |
| E2 | WebHTV `VodCard`（`WebHTVApp.swift:891-932`）、觀看記錄縮圖（`:1932-1939`） | `3d265037` | A | 同檔案已有正確做法：容器決定尺寸，圖放在 overlay | 階段 A 沿用，不另創做法 |
| E3 | Android FongMi `origin/main`：`Vod.java:42-63`（欄位）、`activity_video.xml:474-585`（版面）、`VideoActivity.java:1297-1299`（沒有詳情時用列表項目）、`:1327`（空列隱藏）、`Util.java:126-132`（HTML 清理）、`Sniffer.java:24`（`[a=cr:…]` 連結標記） | `5856232743d2b8ddd5b3730e676b197ff2c0a264` | A | Android 顯示年份、地區、類型、導演、演員、簡介，空的列隱藏 | 階段 B 的欄位與行為參考 |
| E4 | Android `catvod/.../Trans.java:9-27`、`:30-36`、`:58-66`；`Setting.java:42-45`、`:386-389` | 同上 | A | 逐字 1:1 對照表，沒有詞組；預設依手機地區，App 語言設定可強制開或關 | 階段 C 選項 (a)；Android 的已知錯字（頭發、皇後、這里、薑文、鐘漢良） |
| E5 | [OpenCC](https://github.com/BYVoid/OpenCC)：`data/config/s2tw.json`、`data/dictionary/STCharacters.txt`、`STPhrases.txt`、`TWVariants*.txt`、`data/CMakeLists.txt:11`、`:40-42`、LICENSE | `528ae2624972301649fbd00bbd837ce4e085650b`（查核時為 HEAD） | A | 詞組優先的轉換品質最好；`s2tw` 還包含相容字正規化與建置時產生的地區詞組檔；**輸入已是繁體時會誤轉**（干擾→幹擾、里長→裡長、台北→臺北、于和偉→於和偉）；不具冪等性（朴樹第二次變樸樹） | 階段 C 建議方案，並加上「只轉簡體輸入」的前置判斷 |
| E6 | [ICU `Hans_Hant.txt`](https://github.com/unicode-org/icu/blob/main/icu4c/source/data/translit/Hans_Hant.txt)；[Apple ICU fork](https://github.com/apple-oss-distributions/ICU) `root.txt:768` | ICU `main`；Apple `9e80977766f830c93e3cdae3d5628997e1a61b63` | A | 有詞組規則，皇后、頭髮、這裡、颱風正確；姓氏 范→範、于→於、朴→樸 錯（`:20` 明說不處理于／於）；iOS 實際是否帶這份轉寫資料、各版是否一致，原始碼無法確認 | 階段 C 選項 (b)，列為替代方案 |
| E7 | [SwiftyOpenCC](https://github.com/ddddxxx/SwiftyOpenCC) | `1d8105a0f7199c90af722bff62728050c858e777` | A | C++ target，約 1.1 MB 編譯後字典，最後 commit 2021-04-29，綁定舊版 OpenCC `be3af873` | 階段 C 選項 (d)，不建議 |
| E8 | Apple Translation 文件：[framework](https://developer.apple.com/documentation/translation)、[`TranslationSession`](https://developer.apple.com/documentation/translation/translationsession)、[`translationTask`](https://developer.apple.com/documentation/swiftui/view/translationtask(_:action:))、[`translations(from:)`](https://developer.apple.com/documentation/translation/translationsession/translations(from:))、[`LanguageAvailability.status(for:to:)`](https://developer.apple.com/documentation/translation/languageavailability/status(for:to:))、[`Strategy`](https://developer.apple.com/documentation/translation/translationsession/strategy)、[`init(installedSource:target:)`](https://developer.apple.com/documentation/translation/translationsession/init(installedsource:target:))、[`translationPresentation`](https://developer.apple.com/documentation/swiftui/view/translationpresentation(ispresented:text:attachmentanchor:arrowedge:replacementaction:)) | 線上版 | B | 系統彈出視窗 iOS 17.4；App 內翻譯 `TranslationSession` iOS 18.0，在裝置上執行，文字不離開手機；一批字串必須同一語言；session 在 view 消失後使用會 `fatalError`；`Strategy`（`.lowLatency`／`.highFidelity`）iOS 26.4 起，用 26.4 以上 SDK 建置時在支援 Apple Intelligence 的裝置上預設 `.highFidelity` | 階段 D 建議方案與版本條件 |
| E9 | Apple Developer Forums [791357](https://developer.apple.com/forums/thread/791357)、[777113](https://developer.apple.com/forums/thread/777113)、[813109](https://developer.apple.com/forums/thread/813109) | 讀取當日 | C | 刪除系統「翻譯」App 後，即使狀態為已安裝仍回錯誤 16；Apple DTS 回覆可能是 bug | 階段 D 的錯誤處理 |
| E10 | WWDC24 [10117](https://developer.apple.com/videos/play/wwdc2024/10117/) | — | B | 語言模型與系統「翻譯」App 共用，離開 App 後仍會繼續下載；模擬器不能翻譯 | 階段 D 只能真機驗證 |
| E11 | Apple [Foundation Models](https://developer.apple.com/documentation/foundationmodels) 與 [Acceptable Use Requirements](https://developer.apple.com/apple-intelligence/acceptable-use-requirements-for-the-foundation-models-framework/) | 線上版 | B | iOS 26、需要 Apple Intelligence；使用條款禁止成人內容 | 階段 D 不採用 |
| E12 | Google Cloud Translation [價格](https://cloud.google.com/translate/pricing)、[AUP](https://cloud.google.com/terms/aup) | 線上版 | B | 每月 50 萬字元免費，之後每百萬字元 20 美元 | 階段 D 不採用：金鑰放在 App 內可被取出、需要網路、片名與 IP 會送到 Google |
| E13 | Unicode [片假名區塊](https://www.unicode.org/charts/PDF/U30A0.pdf) | — | A | U+30FB（・）屬於片假名區塊，中文資料常用它分隔外文人名（湯姆・克魯斯） | C、D 共用的日文判斷要排除它 |
| E14 | 已發布的 `WebHTV-0.1.27-28.ipa` 載入指令（以 Python 解析 Mach-O） | `0.1.27 (28)` | A | `minos 17.0`、`sdk 26.5`；尚未連結 Translation | 階段 D 必須把 Translation 設為弱連結並驗證 |

未取得的證據（本環境的網路政策擋住 apple.com 與 support.apple.com）：

1. Apple 官方的「日文→繁體中文」語言支援清單：只查到搜尋結果摘要，**未讀原文**；要在真機以 `LanguageAvailability` 確認（階段 D 驗收第 1 項）。
2. DeepL、Azure、內建開源翻譯模型（Opus-MT、NLLB）：未讀。內建模型大小估計為數百 MB，**未驗證**；不影響建議，因為 Apple Translation 已能滿足需求且不增加 App 大小。

## 三、現況程式（HEAD `3d265037`）

### 1. 海報版面

1. 詳情頁表頭：`WebHTVApp.swift:1505-1519` 是 `HStack(alignment: .top, spacing: 16) { VodPoster(vod: summary).frame(width: 112, height: 168); VStack { 標題, 備註, 來源標籤 } }`。
2. `VodPoster`（`:1967-1979`）是 `AsyncImage { image.resizable().scaledToFill() }.clipShape(.rect(cornerRadius: 10))`。
3. 問題在修飾順序：`clipShape` 在 `VodPoster` 內、呼叫端的 `.frame` 之前。
   - 16:9 的圖以 `scaledToFill` 填滿 112×168 時，寬度變成 168 × 16/9 ≈ 299 pt。
   - `clipShape` 裁的是自己的邊界，已經是 299 pt 寬，所以沒有裁掉任何東西。
   - 外層 `.frame(112×168)` 不裁切，圖置中後左右各超出約 93 pt。
   - 左側超出畫面邊緣（內容 `.padding(16)` 在 `:1580`），右側約 77 pt 落在標題下方；標題後宣告，畫在圖上面，就是截圖的樣子。
4. 載入中與載入失敗的佔位圖剛好 112×168，所以只有圖載入後才出錯。
5. 目前沒有點擊錯誤：詳情頁海報沒有手勢，標題與線路列畫在圖之上（IOS-POC-28 文件第二節已記錄）。

### 2. 詳情資料

1. `Vod` 只解碼 6 個欄位（`CMSClient.swift:166-199`）；`decodeString`（`:407-410`）只接受字串或整數，`8.5` 這類評分會解成失敗。
2. XML 解碼器（`MacCMSXML.swift:81-103`）略過 year、area、actor、director、des。
3. 詳情頁已經載入 `detail`（`VodView.task`），但表頭只讀 `summary`（`:1503-1519`）。
4. 從觀看記錄開啟時，`summary` 只有 id、名稱、海報（`:1917-1919`）；WebHome 橋接開啟時同樣（`WebHomeBridge.swift:320`）。
5. `Vod(...)` 的呼叫端共 4 處：`MacCMSXML.swift:94`、`WebHomeBridge.swift:320`、`WebHTVApp.swift:1918`、`AggregateSearchTests.swift:72`。
6. type 0／1 的 CMS 來源，首頁、分類、搜尋本來就用詳情格式（`ac=detail` 或 `videolist`，`CMSClient.swift:338`、`:343-349`、`:369-373`），每個列表與搜尋項目都已帶有 `vod_content`、`vod_actor` 等欄位，只是被丟掉。
7. 來源確實有送這些欄位：MacCMS type 1；spider `App99.js:150-163`、`XYQHiker.js:198-212`、`JianPian.js:184-196`。

### 3. 簡轉繁

- 只有繁轉簡表，而且只用在搜尋（`AggregateSearch.swift:65`、`:77`；`WebHTVApp.swift:848`、`:864`）。沒有任何簡轉繁。
- IOS-POC-20 已決定「iOS 介面固定是繁體，相當於 Android 的繁體模式」（`docs/IOS-POC-20-aggregate-search.md:247`）。

### 4. 翻譯

- 沒有任何翻譯功能。
- App 的部署版本是 iOS 17.0（`project.pbxproj:332`、`:412`）；程式中沒有任何 `#available` 分支可沿用。
- 發布 workflow 用 `runs-on: macos-26`，沒有固定 Xcode 版本（`ios-sidestore-release.yml:32`）；FFmpeg workflow 有固定（`ios-ffmpeg-build.yml:66-72`）。

### 5. 單元測試沒有執行環境

- 本環境沒有 Swift；`.github/workflows/` 沒有 `swift test` 或 `xcodebuild test`；Release build 不編譯測試（`ios-sidestore-release.yml:83-99`）。
- 階段 B 改的 `Vod` 解碼器，搜尋結果也用它。沒有測試執行環境時，「搜尋結果不變」只能靠程式審查、編譯與真機確認。這是第九節要決定的事。

## 四、階段 A：海報版面（quick-fix）

### 1. 方案

| 方案 | 說明 | 判斷 |
|---|---|---|
| 不改 | 問題留著 | 不採用 |
| 在 `:1507` 的 `.frame` 之後補 `.clipShape` | 一行 | 可行，但每個呼叫端都要記得順序 |
| `VodPoster` 自己決定 2:3 尺寸 | `Color.clear.aspectRatio(2/3, .fit)` 決定尺寸，`AsyncImage` 放在 `.overlay`；與 `VodCard`、IOS-POC-28 同一做法；橫向海報會被裁切 | 原建議，**使用者未採用** |
| **海報在上、標題在下，海報完整顯示** | 固定高度的框內以 `scaledToFit` 顯示整張圖，任何比例都不裁切 | **使用者指定（2026-09-27）** |

### 2. 設計（使用者指定後）

1. 使用者選擇（2026-09-27）：「修改一個海報在上、標題在下，但是海報要完整顯示。」
2. 表頭（`VodView`）：原本的 `HStack` 改為 `VStack(alignment: .leading, spacing: 16)`，海報在上；標題、備註、來源標籤的 `VStack` 不變。
3. `VodPoster`：

   ```swift
   AsyncImage(url: URL(string: vod.picture)) { phase in
       switch phase {
       case .success(let image):
           image.resizable().scaledToFit().clipShape(.rect(cornerRadius: 10))  // 圓角裁在縮放後的圖上
       default:
           appSurface.overlay { Image(systemName: "film").foregroundStyle(.secondary) }
               .clipShape(.rect(cornerRadius: 10))
       }
   }
   .frame(maxWidth: .infinity)
   .frame(height: 240)
   ```

   - 固定高度 240 pt：`ScrollView` 在垂直方向不給高度；`maxHeight` 在這種情況下是否仍限制子 view 未驗證，所以不依賴它，改用固定高度，讓 `scaledToFit` 收到明確的寬高，載入前後的框高度也相同。
   - 16:9 的圖：寬度填滿（約 343～398 pt），高約 193～224 pt，上下留一點空白。
   - 2:3 的圖：高 240 pt、寬 160 pt，置中。
   - 載入中與失敗：整個框顯示佔位色塊與圖示。
4. 只改 `ios/WebHTVApp/Sources/WebHTVApp.swift`。首頁格狀、搜尋結果的 `VodCard` 不動；`VodPoster` 只有這一個呼叫端。

### 3. 驗收（真機；這是畫面程式，沒有核心單元測試）

| # | 步驟 | 預期 |
|---|---|---|
| T1 | 開啟截圖中的那部片 | 海報在標題上方，整張圖都看得到，四角是圓角，不蓋到文字 |
| T2 | 直式（2:3、3:4）與很高（1:2）的海報各一部 | 整張圖置中顯示，不裁切，不超出框 |
| T3 | 標題超過 40 字的片 | 標題完整換行，不截斷 |
| T4 | 設定 > 輔助使用 > 更大字體開到最大後開啟詳情 | 文字在海報下方換行，不重疊 |
| T5 | 橫向旋轉 | 版面不重疊 |
| T6 | 從觀看記錄開啟 | 同 T1 |
| T7 | 網路很慢或圖片失敗時 | 佔位色塊與圖片載入後的框高度相同，版面不跳動 |
| T8 | 首頁與搜尋結果 | 與目前相同 |

- 風險與取捨（查核時確認，屬於這個版面本身的結果）：
  - 直式海報兩側、橫向海報上下會有空白；4:3 的圖高度填滿、寬 320 pt，不會填滿寬度。
  - 很小的圖會被放大而變模糊（格狀卡片也一樣）。
  - 沒有海報的片也固定佔 240 pt，顯示佔位色塊。
  - 手機橫放時，海報與標題佔掉大部分畫面，線路與集數要往下捲才看得到；不重疊。
- 查核（2026-09-27，workflow `w7bel1r5s`）：編譯、版面、回歸三個角度，每項發現由另一個代理嘗試推翻。確認 1 項（兩段註解描述錯誤，只改註解），推翻 3 項（橫放要捲動兩項、無海報佔位一項：都是使用者選的版面的結果，列在上面）。編譯角度未發現問題（逐一對照 Apple 文件的 API 與 iOS 版本、括號配對）。
- 回滾：`git revert`。

## 五、階段 B：年份、簡介、演員等資料

### 1. 方案

| 方案 | 說明 | 判斷 |
|---|---|---|
| 不改 | 使用者要求的資料不顯示 | 不採用 |
| Android 完整對應 | 含 `[a=cr:…]` 可點連結（開分類頁） | 可點連結延後，另案決定 |
| **WebHTV 精簡版** | 新增選用欄位，純文字顯示，連結標記只顯示標籤文字 | **建議** |
| `NSAttributedString(.html)` 呈現簡介 | 由 WebKit 處理，只能在主執行緒 | 不採用 |

### 2. 設計

1. `CMSClient.swift` 的 `Vod`：新增選用欄位 `year`、`area`、`lang`、`typeName`（沒有時用 `vod_class`）、`director`、`actor`、`content`（沒有時用 `vod_blurb`）、`pubdate`、`score`。
   - 每個欄位以 `try?` 解碼，新增一個接受字串、整數、小數的寬鬆 helper；解碼失敗只讓該欄位為 `nil`，不影響既有 6 個欄位。
   - 保留有預設值的 `init`；4 個呼叫端中只有 `MacCMSXML.swift:94` 要傳新欄位。
2. `MacCMSXML.swift`：擷取 `year`、`area`、`lang`、`type`、`actor`、`director`、`des`。
3. 新檔 `WebHTVCore/VodText.swift`：
   - HTML 清理，以 Android `Util.java:126-132` 為準，差異如下（查核後更正）：
     | 項目 | Android | WebHTV |
     |---|---|---|
     | 沒有 `<` 時 | 原樣返回 | 仍解碼 entity、整理空白 |
     | `br`／`p`／`div` | `Html.fromHtml`（`</p>` 之間留一個空行） | 換成一次換行，其他標籤移除 |
     | entity | `Html.fromHtml` 解碼完整 HTML 名稱 | 只解碼數字與常用名稱（約 30 個） |
     | U+00A0、U+3000 | 有 `<` 時換成空格 | 一律換成空格 |
     | 每行 | 有 `<` 時去頭尾空白 | 一律去頭尾空白 |
     | 空行 | 保留 | 連續空行合併成一行 |
   - `[a=cr:{json}/]標籤[/a]` 只取標籤（`Sniffer.java:24`）。
   - 年份：只接受 19xx／20xx，沒有時用 `vod_pubdate` 的前四碼。
   - 評分：大於 0 才顯示（MacCMS 以 0.0 表示沒有評分）。
   - 標題的 HTML entity 解碼（Android `Vod.java:135`）：只用在顯示，模型的 `name` 不變。
4. `VodView`：
   - 表頭每個值優先用 `detail`，沒有時用 `summary`。
   - 新增一列 `年份 · 地區 · 類型`。
   - 全寬的列：導演（最多 2 行）、演員（2 行）、簡介（4 行，可「更多／收起」，可選取文字）。
   - 空的列隱藏。

### 3. 驗收

- 單元測試（`WebHTVCoreTests`，執行環境見第九節）：
  1. 真實的 `ac=detail` 搜尋回應，metadata 為數字、`null`、陣列、HTML 時，解出的 id 與名稱與目前相同。
  2. XML 的新欄位有擷取。
  3. HTML 清理、連結標記、年份、評分各自的案例。
- 真機：
  1. 一個 MacCMS 來源、一個 spider 來源各開一部，新的列出現。
  2. 從觀看記錄開啟，顯示詳情的值。
  3. 沒有資料的列不出現。
  4. 搜尋結果的項目與順序不變。
- 風險：
  - `Vod` 也解碼搜尋與列表頁，新增的解碼（含簡介 HTML）會跑在每個搜尋結果上；每頁多出的記憶體與解碼時間**未量測**。可選擇只在詳情回應時解碼 `content`。
  - `try?` 與上面第 1 項測試把影響限制在新欄位。
- 回滾：`git revert`。
- 規模：核心約 150 行、測試約 120 行、畫面約 80 行。

### 4. 實作（2026-09-27，使用者核准「B：年份、簡介、演員」，評分不顯示）

1. `ios/Sources/WebHTVCore/CMSClient.swift` `Vod`：新增 `year`、`area`、`typeName`（沒有時用 `vod_class`）、`director`、`actor`、`content`（沒有時用 `vod_blurb`），都是 `String`，缺少時為空字串。
   - 以新的 `decodeText(forKey:orElse:)` 解碼：只接受字串或整數，其他形狀（`null`、陣列、物件、小數）一律當成空字串，**不會讓整筆記錄或整頁解碼失敗**。
   - 有預設值的 `init` 加上這六個參數，4 個呼叫端中只有 XML 解碼器傳入。
2. `ios/Sources/WebHTVCore/MacCMSXML.swift`：擷取 `<video>` 內的 `year`、`area`、`type`、`director`、`actor`、`des`。
3. 新檔 `ios/Sources/WebHTVCore/VodText.swift`：
   - `VodText.plain(_:)`：`[a=cr:…/]標籤[/a]` 只留標籤；`br`、`</p>`、`</div>`、`</li>` 換行，其餘標籤移除；解碼 entity（常用名稱與數字）；U+00A0、U+3000 換成空格；每行去頭尾空白；連續空行只留一行。
   - `VodText.year(_:)`：開頭是 1900～2099 的四位數才顯示。
   - 不用靜態 `NSRegularExpression`，避免 Swift 6 並行檢查的問題；只用 Foundation 的 `replacingOccurrences(…, options: .regularExpression)`。
4. `ios/WebHTVApp/Sources/WebHTVApp.swift` `VodView`：
   - 標題、海報、備註：沿用列表項目的值，空的才用詳情的值（表頭不在載入後變動；從觀看記錄開啟時只有名稱與海報）。標題經 `VodText.plain` 清理，表頭與導覽列用同一個顯示名稱，只影響顯示。
   - 年份、地區、類型、導演、演員、簡介：優先用詳情，空的才用列表項目。
   - 標籤下方一列「年份 · 地區 · 類型」；表頭與線路之間是導演（2 行）、演員（2 行；輔助使用字級時標籤在上、最多 4 行）、簡介（4 行，確實被截斷時才顯示「更多／收起」，可選取文字）。沒有資料的列不顯示。
   - `VodPoster` 改為接收圖片網址，讓詳情可補上觀看記錄沒有的海報。
5. 與計畫不同的地方：
   | 計畫 | 實作 | 原因 |
   |---|---|---|
   | 顯示評分 | 不顯示 | 使用者決定 |
   | 年份沒有時用 `vod_pubdate` | 不做 | 簡化；`vod_year` 缺少時整列只少年份 |
   | 另存 `lang` | 不做 | 畫面沒有顯示語言的位置 |
   | 表頭每個值優先用詳情 | 名稱、海報、備註優先用列表項目 | 載入詳情後表頭不跳動 |
   | 寬鬆解碼接受小數 | 只接受字串、整數 | 小數只用在評分 |
6. 測試：新檔 `ios/Tests/WebHTVCoreTests/VodMetadataTests.swift`（7 個）：怪異型別不會丟掉搜尋結果、備用欄位的優先順序與名稱保持原文、XML 欄位、HTML 轉純文字、空白整理、連結標記、年份。依使用者選擇（第九節方案 3）**未執行**；`VodText` 的 21 個預期值以 Python 移植版逐條執行，全部符合（移植版不是 Swift，只能當作邏輯檢查）。

### 5. 查核（2026-09-27，workflow `wmowsyzfp`）

編譯、解碼相容與搜尋安全、`VodText` 行為、畫面、回歸五個角度，每項發現由另一個代理嘗試推翻。編譯與解碼兩個角度沒有發現問題（新欄位不會讓任何記錄解碼失敗；搜尋、觀看記錄、WebHome 的資料都沒有讀到新欄位或 `VodText` 的輸出）。確認 11 項，全部為次要或建議修正，已在同一個 commit 修正：

| # | 問題 | 修正 |
|---|---|---|
| 1 | `<br />` 後面接原始換行（PHP `nl2br`）會變成空行，4 行簡介一半是空白 | 換行標籤一併吃掉後面的一個換行 |
| 2 | `&emsp;`、`&copy;` 等常用 entity 不解碼；`&#0;` 會產生 NUL；`&#+65;` 會被解成 A | 補常用名稱與大寫舊式寫法；數字只接受數字字元、不接受 0 |
| 3 | 連結標記的規則比 Android 寬鬆，標籤沒有去頭尾空白 | 改用 Android `CLICKER` 的形狀並去空白 |
| 4 | 「更多」依字數判斷：大字體時被截斷卻沒有按鈕，預設字級時沒截斷卻有按鈕 | 改為量測四行與完整文字的高度，確實截斷才顯示 |
| 5 | 「更多／收起」按鈕只有約 30×20 pt，VoiceOver 只讀「更多」 | 觸控範圍 44 pt；VoiceOver 讀「展開簡介／收起簡介」 |
| 6 | 輔助使用字級下，導演、演員的值只剩每行幾個字 | 改為標籤在上、值在下，最多 4 行 |
| 7、8 | 表頭標題解碼了 entity，導覽列標題仍是原文；名稱整段是標記時表頭變空白 | 共用一個顯示名稱，清理後是空的就用詳情的名稱，再不行用原文；觀看記錄與播放器仍用原文 |
| 9 | 測試無法偵測備用欄位的優先順序被改反、`vod_blurb` 備用被拿掉、名稱在解碼時被清理 | 新增 `metadataFallbacksKeepPrecedenceAndNamesStayRaw` |
| 10 | `VodText` 註解說是 Android 的「超集」，並說空白處理與 Android 相同，兩者都不正確 | 改寫註解、測試註解與上面的差異表 |
| 11 | 引用的 `VideoActivity.java:1327` 在這個 checkout 是空行 | 改為方法名稱 `VideoActivity.setText(TextView, int, String)` |

推翻 2 項：標題中 `<…>` 會被移除（與 Android `Vod.getName()` 的 `Html.fromHtml` 相同）；WebHome 開啟沒有片名時標題是 id（階段 B 以前就是如此）。

## 六、階段 C：簡體顯示為台灣繁體（只改顯示）

### 1. 方案

| 方案 | 正確性 | 大小 | 其他 | 判斷 |
|---|---|---|---|---|
| 不改 | — | — | 不符合要求 | 不採用 |
| (a) 反轉現有的繁轉簡表（Android 做法） | 逐字轉換，錯字與 Android 相同：頭發、皇後、這里、干淨、薑文、鐘漢良；干、里、台、只 等不轉 | 0 | 最簡單 | 不建議 |
| (b) ICU `Hans-Hant`（`String.applyingTransform`） | 皇后、頭髮、這裡、颱風正確；姓氏 范、于、朴 錯 | 0 | iOS 是否帶這份資料、各 iOS 版本是否一致**未驗證**；測試結果依機器而定（IOS-POC-20 在搜尋方向因同一理由不採用 ICU） | 替代方案 |
| (c) **從 OpenCC `s2tw` 衍生的純 Swift 轉換** | 詞組優先，品質最好；仍有姓氏問題（範偉、餘華） | 0.23 MB（精簡字典，需與完整字典比對）至 1.04 MB（完整）；未含地區詞組產生檔，需重算 | Apache-2.0，要附 LICENSE 與修改說明；資料版本由我們決定何時更新 | **建議** |
| (d) SwiftyOpenCC | 同 (c) | 約 1.1 MB | 新增 C++ target；2021 年後沒有更新 | 不建議 |
| 直接改寫模型欄位（Android 做法） | — | — | 線路、集數、標題是身分值（第一節） | 不採用 |

選 (c) 而不選 (b) 的理由：(b) 零成本，但「iOS 是否提供這個轉換」與「輸出是否隨 iOS 版本改變」都要先在真機確認，而且測試無法固定結果；(c) 的輸出由內建資料決定，可以寫出固定的測試案例。如果你偏好零大小，可以先用一次真機測試確認 (b)，再決定。

### 2. 設計（依查核修正後）

1. **只轉換簡體輸入。** 字串至少含一個「只出現在簡體」的字（STCharacters／STPhrases 的鍵，且從不出現在繁體值中）才轉換，否則原樣返回。
   - 原因：OpenCC 預期輸入是簡體，遇到已是繁體的文字會誤轉（干擾→幹擾、里長→裡長、周末→週末、于和偉→於和偉），不少來源名稱與片名本來就是繁體。
   - 每個來源字串只轉一次，已轉過或翻譯過的文字（階段 D 的輸出）不再轉。測試以「不會轉兩次」的規則取代「轉兩次結果相同」。
2. **字典。** OpenCC `528ae26` 的 STPhrases、STCharacters（取第一候選）、TWVariantsPhrases、TWVariants，以及 `s2tw.json` 的相容字正規化。
   - `s2tw` 另外合併了建置時產生的 `STPhrases_GeneratedFromRegionalPhrases`，這個檔案不在 repo 中。建議用 OpenCC 自己的產生腳本（`scripts/generate_st_phrases_from_regional_phrases.py`）在 `528ae26` 產生一次並內建，記錄產生方式；做不到時，文件與授權說明要寫明「OpenCC 衍生、不含地區詞組」。
   - 測試的預期值以 OpenCC 自己的工具輸出為準，不用我們自寫的比對腳本。
3. **台／臺。** `s2tw` 幾乎把所有「台」轉成「臺」（臺北、臺劇、平臺、港臺、臺詞）。只覆寫「台湾→台灣」會造成台灣與臺北並存。建議改成最後一步「臺→台」全面替換（台灣常用寫法），另列少數例外。這是你要決定的事。
4. **人名模式。** 演員、導演欄位：以 `，`、`,`、`/`、`、`、空白分開，開頭的 于、朴、范、姜、余、沈 不轉，钟→鍾。標題與簡介中的人名仍可能出錯（範偉、餘華），可另加常見人名的覆寫清單。
5. **日文判斷（與階段 D 共用一個分類器）。**
   - 假名不含 U+30A0、U+30FB（・）、U+30FC、U+FF65，避免「湯姆・克魯斯」被當成日文。
   - 以假名與漢字的比例判斷，不以「有沒有假名」判斷。
   - 中文字串中夾有假名時，只轉假名以外的漢字段落，不是整串不轉。
6. **API 與「搜尋不會用到」的保證。**
   - 核心（`WebHTVCore`）目前只 import Foundation、CoreGraphics、CryptoKit、WebKit、os，沒有 SwiftUI。
   - 建議：核心提供公開的 `String` 轉換函式，App 端提供 `Text(zhTW:)` 包裝；再加一個測試，檢查核心中除了轉換檔本身，沒有其他檔案呼叫它。**這是以測試與審查執行的規則，不是型別層級的保證。**
7. **載入不卡畫面。** 字典約 4.9 萬筆詞組。字典尚未載入完成時先顯示原文，載入完成後通知畫面更新；快取的鍵含（模式、文字、字典版本）。載入時間與記憶體**未量測**，要在真機量。
8. **設定開關。** 使用者決定（2026-09-27）不加開關，一律轉換；回滾只靠 `git revert`。
9. **套用位置（只改顯示）：**
   - 首頁：來源選擇 `:507`、目前來源 `:541`、VoiceOver 標籤 `:548`
   - 分類頁：分類 `:613`、`:777`，篩選列名稱 `:705`，篩選選項 `:724`
   - `VodCard`：名稱 `:911`、備註 `:919`（同時涵蓋搜尋結果的顯示）
   - 搜尋分頁：來源名稱 `:995`、`:1061`
   - 設定頁：目前來源 `:1406`；來源清單 `SiteChoiceList` `:1455`
   - 詳情頁：`:1509-1513`、線路按鈕的**文字** `:1533`、單一線路標題 `:1542`、集數按鈕的**文字** `:1565`、`navigationTitle` `:1590`
   - 觀看記錄：`:1942-1943`
   - 播放器：畫質 `:3796`、`:4023`；音軌與字幕選項 `:3489`
   - 階段 B 的新欄位
   - 需要改簽名的 helper：`chip` ×2（`:813`、`:1069`）、`choiceRow`（`:4053`）、`panelButton`（`:3795`）

### 3. 已知風險

1. **搜尋時複製畫面上的片名。** 畫面會出現現有繁轉簡表對不回去的字。實作時算出共 664 字：OpenCC 繁轉簡字表認定為繁體專用、畫面可能寫出、但搜尋用的 Android 對照表沒有的字，常見的有 裡、髮、乾、隻、鬆、麵、颱、複、範、曆、週、迴、幹、鬥、採、鬍、係、繫。改用「台」後「臺」不會出現。例如來源的「头发」畫面顯示「頭髮」，複製去搜尋會變成「头髮」，來源找不到。搜尋邏輯不改（你的要求），所以這個情況會存在；補齊繁轉簡表會改到搜尋，要另案核准。清單記錄在 `TaiwanTraditionalTests` 的 `recordsWhatTextCopiedFromTheScreenCannotSearchFor`。IOS-POC-33（2026-09-28）起，搜尋也會把輸入的原文送出，所以複製的繁體片名在以繁體建檔的站找得到；以簡體建檔的站仍找不到。
2. 姓氏：標題與簡介中的 范、于、余 可能轉錯。
3. App 增加約 1.1 MB 資源：6 份字典共 1,100,764 bytes，另有 `LICENSE`、`README.md`。IPA 壓縮後的實際增量待發布後量。
4. 字典載入時間與首頁捲動**未量測**。App 會在 log 記錄 `[zhtw] dictionaries loaded in …ms`（category `zhtw`）。

### 4. 驗收

- 單元測試：
  1. 範例詞：頭髮、皇后、這裡、颱風、乾淨、鍾漢良、姜文。
  2. 繁體輸入原樣返回：干擾、里長、台北、周末、若干、于小彤。
  3. 分類名稱：台劇、港台、台綜（依第 3 點的決定）。
  4. 姓氏案例；「湯姆・克魯斯」照常轉換；夾假名的中文簡介只轉漢字段落。
  5. ASCII、網址、`1080P`、`第01集` 不變，數字不變。
  6. `AggregateSearch` 假資料回傳「头发」「庆余年」，回報的名稱逐位元組相同。
  7. 列出轉換後可能出現、但繁轉簡表對不回去的所有字（作為「已知風險」第 1 點的紀錄）。
  8. 既有搜尋測試照常通過。
- 真機：首頁格狀、分類、篩選、詳情、觀看記錄、播放器選單顯示繁體；搜尋結果與目前相同；量測字典載入時間與首頁第一次捲動。
- 回滾：關閉開關（若採用），或 `git revert`。
- 規模：核心約 250 行、測試約 150 行、約 35 處顯示位置與 4 個 helper 簽名、資源檔。

### 5. 實作（2026-09-28，使用者核准「IOS-POC-32 C」；簡介不換台灣用語）

1. 檔案：
   - `ios/Sources/WebHTVCore/TaiwanTraditional.swift`：轉換器。核心只 import Foundation、os。
   - `ios/Sources/WebHTVCore/Resources/OpenCC/`：OpenCC `528ae2624972301649fbd00bbd837ce4e085650b` 的 6 份字典（未修改）、`LICENSE`、`README.md`（來源、產生方式、SHA-256、更新步驟）。`ios/Package.swift` 加 `.copy("Resources/OpenCC")`。
   - `ios/WebHTVApp/Sources/WebHTVApp.swift`：`TaiwanDisplay`（載入與快取）、`zhTW(_:_:)`、`Text(zhTW:)`，以及 32 處顯示位置。
   - `ios/Tests/WebHTVCoreTests/TaiwanTraditionalTests.swift`：9 個測試，未執行。
2. 轉換，與第 2 點設計相同的部分不重述：
   - 步驟：相容字正規化；以詞組（`STPhrases` ∪ 地區詞組產生檔）最長比對分段，其餘逐字（`STCharacters`）；各段內再做台灣異體（`TWVariantsPhrases`、`TWVariants`）。一律取第一候選，重複鍵以先載入者為準。依 OpenCC 原始碼 `MaxMatchSegmentation.cpp`、`Conversion.cpp`、`ConversionChain.cpp`、`PrefixMatch.cpp`、`Config.cpp` 對照。
   - 地區詞組產生檔：以 OpenCC 自己的 CMake 建置在 `528ae262` 產生（556 筆），未修改。
   - 簡體專用字：`STCharacters` 的鍵，扣掉所有字典的全部候選字與兩份台灣異體表的鍵，載入時計算，共 3,797 字。其中 7 字（宫无緼藴輼醖麽）在 OpenCC 的繁轉簡表中也是繁體輸入；影響只限這 7 字，不另外處理（要處理就得多帶一份繁轉簡字典）。
   - 「臺」→「台」：全面替換，沒有例外。
   - 日文：假名至少 2 個、且占假名加漢字至少 25% 才算日文，整串不轉。只夾少量假名的中文照常轉換；假名不在任何字典中，等於只轉漢字段落。已知限制：「海贼王（ワンピース）」這種以假名為主的短中文標題會被當成日文而不轉。
   - 人名模式：依第 4 點。分隔字元照原設計，每個名字各自判斷要不要轉。
   - 沒有重現的 OpenCC 行為：表意文字描述序列（⿰氵马）OpenCC 整段照抄，這裡照一般字轉換。影片資料實務上不會出現。
3. App：
   - 字典在 App 啟動時於背景解析（`Task.detached`）。完成前顯示原文；完成時由 Observation 讓讀過轉換的畫面重畫。
   - 快取以（模式、原文）為鍵，上限 4,096 筆，滿了就清空。一次執行中字典不會換，所以鍵不含字典版本。
   - 第 2 點第 9 項列的 helper 都不改簽名，改在呼叫端轉換後傳入。`chip`、`choiceRow`、`panelButton` 收到的標題與 VoiceOver 值只用於顯示，已逐一確認。
   - 32 處顯示位置（行號以本次 commit 為準）：
     - 首頁：來源清單 `:511`、目前來源 `:545`、VoiceOver 標籤 `:552`。
     - 分類頁：子分類 `:617`、篩選列名稱 `:709`、篩選選項 `:728`、父分類 `:781`。
     - `VodCard`：名稱 `:915`、備註 `:923`（首頁、分類與搜尋結果共用）。
     - 搜尋分頁：來源名稱 `:999`、來源切換鈕 `:1065`。
     - 設定頁：目前來源 `:1410`；來源清單 `:1459`。
     - 詳情頁：標題 `:1524`、備註 `:1527`、年份地區類型 `:1531`、來源標籤 `:1533`、線路按鈕 `:1555`、單一線路標題 `:1564`、集數按鈕 `:1587`、`navigationTitle` `:1612`、導演與演員（人名模式）`:1678-1679`、簡介 `:1680`。
     - 觀看記錄：片名 `:2055`、來源・線路・備註 `:2056`。
     - 播放器：字幕、音軌、畫質鈕的 VoiceOver 值 `:3904`、`:3909`、`:3916`；畫質鈕文字 `:3917`；畫質選項 `:4144`；字幕與音軌選項 `:4205`。
   - 不轉換：WebHome 網頁（網頁自己顯示；橋接資料是身分值）、錯誤訊息、App 自己的文字、搜尋關鍵字的回顯、播放器回報給 WebHome 的片名（`player.status`）。
4. 驗證：
   - Python 對照實作（與 Swift 同一演算法）對 OpenCC 官方 CLI：OpenCC 自己的 67 個 `s2tw` 測試案例，加上所有字典鍵、6 萬行隨機組合、2 萬行詞組重疊，共 134,127 行，**0 差異**。
   - 測試預期值：由 OpenCC CLI 輸出加上「臺」→「台」產生，再以 Python 對照實作逐條重算，0 差異。
   - Swift：以 tree-sitter-swift 做語法分析，新增程式沒有語法錯誤（`WebHTVApp.swift` 另有 3 個既有的分析器誤報）。**未編譯**：容器沒有 Swift，swift.org 與 GitHub releases 被網路政策擋住。單元測試未執行、真機未驗證。第一次編譯是下一次發布的 Release build。
5. 待真機驗收：第 4 點的真機項目，並確認字典載入前後畫面會自動更新（首頁來源名稱、分類列）。

## 七、階段 D：日文翻成中文

### 1. 方案

| 方案 | 判斷 | 理由 |
|---|---|---|
| 不改 | 不採用 | 不符合要求 |
| Android 做法 | — | Android 沒有翻譯功能 |
| **Apple Translation 框架** | **建議** | 在裝置上翻譯，文字不離開手機；不增加 App 大小；語言模型與系統「翻譯」App 共用 |
| Foundation Models | 不採用 | iOS 26 且需要 Apple Intelligence；使用條款禁止成人內容 |
| Google Cloud Translation | 不採用 | 金鑰可被取出、需要網路、片名與 IP 送到 Google |
| 內建開源翻譯模型 | 未驗證 | 估計數百 MB |

### 2. 設計

1. **版本條件。**
   - iOS 18 以上：App 內翻譯（`TranslationSession` 經 `.translationTask`）。
   - iOS 17.4～17.x：只能用系統彈出視窗（`.translationPresentation`），使用者按「以翻譯取代」才拿得到結果；或不提供。
   - iOS 17.0～17.3：不提供。
2. **哪些文字要翻。** 共用階段 C 的日文分類器；先移除番號（例如 `ABC-123`）與括號再判斷。
   - 標題本身被判斷為日文才翻；只是簡介是日文時，標題只做階段 C 的轉換。原因：中文站常把中文片名配上日文簡介，一批字串又必須同一語言。
   - 簡介單獨翻。
   - 演員、導演不翻（翻譯後的人名多半是錯的）。
3. **何時翻。** 詳情載入後：
   - 語言已下載且設定為「自動」：直接翻。
   - 語言可下載：顯示「翻譯成中文」按鈕，按下後出現系統下載提示。
   - 不支援：不顯示。
4. **目標語言。** 從 `supportedLanguages` 中找繁體中文（`hanTraditional` 或地區 TW）；沒有時翻成簡體，再經過階段 C 轉成繁體。
5. **翻譯模型。** 以 26.4 以上 SDK 建置時（目前發布用 SDK 26.5），支援 Apple Intelligence 的裝置預設走 Apple Intelligence 模型。建議在 `if #available(iOS 26.4, *)` 內明確指定 `.lowLatency`（傳統模型），因為 Apple Intelligence 模型對這類內容的過濾行為未知；26.4 以下本來就是傳統模型。
   - 發布 workflow 沒有固定 Xcode 版本，未來 runner 換版可能讓這段無法編譯。要固定 Xcode（改 `.github`，需另外核准），或加編譯條件。
6. **連結方式。** 部署版本 17.0，Translation 要弱連結：`OTHER_LDFLAGS` 加 `-weak_framework Translation -weak_framework _Translation_SwiftUI`。發布後以 Python 解析 IPA 的載入指令確認（本環境可做，不需要 `otool`）。
7. **快取。** 鍵為（來源語言、目標語言、模型、原文）的 SHA-256，記憶體加上 Caches 內有大小上限的檔案。第一版只用在詳情頁，**不改格狀與搜尋結果的顯示**。
8. **畫面。** 顯示譯文，旁邊標「機器翻譯」，可切換「顯示原文」。
9. **錯誤。** 使用者取消、未下載、不支援的語言組合、錯誤 16（提示安裝系統「翻譯」App 或下載語言）都保留原文，可重試。
10. **設定。** 「日文翻譯」：關／詢問／自動。

### 3. 驗收（只能真機；模擬器不能翻譯）

1. 在你的 iPhone 上確認「日文→繁體中文」可用。
2. 第一次使用時出現下載提示；下載完成後可翻。
3. 設定為「自動」時直接翻。
4. 取消下載、錯誤 16 時保留原文。
5. `.lowLatency` 的翻譯品質可接受。
6. 解析發布的 IPA，Translation 為弱連結。
7. 中文片名配日文簡介時，片名不送去翻譯。

- 風險：日文→繁體中文未以官方清單確認；錯誤 16 的框架問題；iOS 17 使用者只有部分或沒有功能。
- 回滾：設定改為「關」，或 `git revert`。
- 規模：核心約 120 行、測試約 80 行、App 約 200 行，加上 `project.pbxproj`。

## 八、階段順序與回滾

1. 順序固定：A → B → C → D，每個階段各自一個 task guard session 與 commit，可各自發布。
   - C 的人名模式要等 B 有演員、導演欄位後才有東西可轉；若 C 先做，B 的新欄位要直接用 C 的 API。
   - D 需要 B 的簡介欄位與 C 的日文分類器。
2. 四個階段都改同一段詳情頁表頭，先 revert 前面的階段會與後面的衝突。回滾要**反向依序**（D → C → B → A）。
3. 不重新發布的回滾：D 的設定改為「關」。C 沒有開關（使用者決定），回滾是 revert C 的 commit 後重新發布。

## 九、驗證環境（B、C 的前提）

`WebHTVCoreTests` 目前沒有任何地方會執行（第三節第 5 點）。B 改的解碼器與搜尋共用，C 的主要保護也是單元測試。

| 方案 | 說明 | 判斷 |
|---|---|---|
| 1. 新增 macOS `swift test` workflow | 新增 `.github/workflows/` 檔案，推送後在 GitHub `macos-26` 執行；需要你核准擴大範圍到 `.github` | **建議**；之後每個階段都能在 commit 前取得測試結果 |
| 2. 有 Mac 時執行 | 在 Mac 上跑一次 `swift test` 當作 commit 前的關卡 | 可行，但要等 Mac |
| 3. 只靠編譯與真機 | 測試寫好但不執行 | 不建議；「搜尋不變」只能靠審查 |

選方案 3 時，文件會寫明「單元測試未執行」，與 IOS-POC-29、30 相同。

**使用者選擇（2026-09-27）：方案 3，只靠編譯與真機。** B、C 的單元測試照常撰寫，但文件會寫明未執行。

## 十、需要你決定的事

已決定（2026-09-27）：

| 項目 | 使用者選擇 |
|---|---|
| 階段 A | 實作，改為海報在上、標題在下、完整顯示（第四節） |
| 測試執行環境 | 只靠編譯與真機（第九節方案 3） |
| 階段 C 轉換方式 | OpenCC 衍生 |
| 台／臺 | 台 |
| 階段 B | 實作；評分不顯示 |
| 階段 C 設定頁開關 | 不加 |
| 發布 | 階段 A 等 B 完成後一起發布 |
| 階段 C 開始實作 | 核准（2026-09-28） |
| 階段 C 簡介換成台灣用語 | 不換，不採 `s2twp`（2026-09-28） |
| 階段 D：你的 iPhone 的 iOS 版本 | iOS 26.x（2026-09-28） |
| 階段 D：設定預設值 | 關（2026-09-28） |

尚待決定：

1. 階段 C 是否發布（下一版 `0.1.29 (30)`；bump 版本、tag、發布前都要先問）。
2. 階段 D 是否開始實作。
3. **階段 B**：演員、類型之後是否要可點（開分類頁，不是搜尋）；本階段不做。
4. **階段 D**：
   - iOS 17.x 的做法：系統彈出視窗或不提供。
   - 是否同意固定使用 `.lowLatency`。

## 十一、查核紀錄

兩個獨立代理對照程式碼、Android 原始碼、OpenCC 與 ICU 原始資料、Apple 文件及已發布 IPA 查核設計。兩者都確認階段 A 的原因與修法正確、可以直接做。修正的內容：

| 原本的說法 | 查核結果 | 本文件的處理 |
|---|---|---|
| ICU 會轉成頭發、皇後；IOS-POC-20 已不採用 ICU | 錯：ICU 有詞組規則，皇后、頭髮正確；IOS-POC-20 不採用的是繁轉簡方向 | 第六節 (b) 改寫 |
| 轉換是 OpenCC `s2tw` | 不完整：漏了相容字正規化與地區詞組產生檔 | 第六節第 2 點 |
| 繁體輸入原樣返回、轉兩次結果相同 | 錯：OpenCC 會誤轉繁體、不冪等 | 第六節第 1 點加前置判斷 |
| 覆寫「台湾→台灣」 | 會造成台灣與臺北並存 | 第六節第 3 點改為全面規則 |
| 有任何假名就不轉 | 「・」會讓外文人名被當成日文；夾假名的中文整串不轉 | 第六節第 5 點 |
| 核心回傳 SwiftUI `Text` 可保證不進搜尋 | 核心沒有 SwiftUI；是審查規則不是型別保證 | 第六節第 6 點 |
| 字典以 `static let` 延遲載入 | 首頁可能等整份字典載完；快取鍵要含模式 | 第六節第 7 點 |
| 搜尋不受影響 | 程式不受影響，但複製畫面文字去搜尋會失敗 | 第六節「已知風險」第 1 點 |
| 單元測試可證明搜尋不變 | 沒有地方執行測試 | 第九節 |
| 標題與簡介一起翻 | 中文片名會被當成日文送去翻 | 第七節第 2 點 |
| 26.4 SDK 設定 `.lowLatency` 即可 | 也要執行期 `#available(iOS 26.4, *)`；Xcode 未固定 | 第七節第 5 點 |
| 以 pbxproj 檔案參照弱連結 | 既有參照指向舊 SDK 路徑；SwiftUI overlay 也要弱連結 | 第七節第 6 點 |
| 四個階段各自可 revert | 同一段表頭，回滾要反向依序 | 第八節 |
| HTML 清理與 Android 相同 | 不同 | 第五節第 2 點列出差異 |
| Android 只在地區為 TW 時轉換 | 地區只是預設，App 設定可覆寫 | 第二節 E4 |
| 行號：`.padding(16)` `:1606`、`init` 呼叫端 5 處等 | 應為 `:1580`、4 處等 | 已更正 |

## Recovery anchor

- 目標：詳情頁的海報版面修正，以及年份、簡介、演員顯示、簡體顯示為台灣繁體（不動搜尋）、日文翻成中文。
- 狀態（2026-09-28）：階段 A、B 已隨 `0.1.28 (29)` 發布（第四節、第五節第 4～5 點；發布紀錄在 IOS-POC-11 第二十九次發布）；單元測試未執行、真機未驗證。C 已實作並 commit（第六節第 5 點）：未編譯、單元測試未執行、真機未驗證、未發布。D 未實作，待核准（第十節）。
- 相關檔案：`ios/WebHTVApp/Sources/WebHTVApp.swift`（`VodView` 表頭約 `:1503-1520`、`VodPoster` 約 `:1968-1988`）、`ios/Sources/WebHTVCore/CMSClient.swift`（`Vod` `:166-199`）、`ios/Sources/WebHTVCore/MacCMSXML.swift`。
- C 的檔案：`ios/Sources/WebHTVCore/TaiwanTraditional.swift`、`ios/Sources/WebHTVCore/Resources/OpenCC/`、`WebHTVApp.swift` 的 `TaiwanDisplay`、`zhTW(_:_:)` 與 32 處顯示位置、`ios/Tests/WebHTVCoreTests/TaiwanTraditionalTests.swift`。
- 下一步（唯一）：請使用者決定是否把 C 發布為 `0.1.29 (30)`（bump 版本、tag、發布前都要先問）。
