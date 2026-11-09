# W-258 iOS type 4 相對 api 與無 vod_id 項目改走搜尋

## Recovery anchor

- 目標：wang-sex 的番號、女優、薇薇珊（type 4，api 為 `./json/00title0515x.json`，項目沒有 `vod_id`）在 iOS 首頁有片、點片照 FongMi 改走全站搜尋，且至少一部可播。
- 狀態：完成，待 reviewer-2 審。task/W-258 自 origin/ios-poc 7fccd89f（ios-poc 之後已前進到 f4d67bee，推送前需 rebase）。
- 下一步：依審查意見修正。

## 根因（W-250 評估已定位）

1. `Site.isNativeCMS` 只認 http(s) 的 api，所以 `WebHTVConfig.drivableSites` 把相對 api 的 type 4 站整個濾掉，來源清單看不到。FongMi 在 `Site.java:161` 用 `UrlUtil.convert` 以設定檔網址補成完整網址。
2. 項目沒有 `vod_id`。FongMi `VideoActivity.checkId()`（mobile `VideoActivity.java:1218-1222`）對空 id 走 `setEmpty(false)` → `checkSearch`，用片名搜尋所有站；iOS 只對 `msearch:` 前綴這樣做。
3. Simulator 實測發現第三個問題：首頁海報格 `ForEach(items)` 用 `Vod.id` 當識別，75 個空 id 只畫出 1 張海報。

## 修正

- `ios/Sources/WebHTVCore/WebHTVConfig.swift`：`Site.resolvingRelativeCMSAPI(against:)`：type 4 且 api 以 `./`、`../` 開頭時，用 `ConfigSource.resourceURL` 補成完整網址（與 type 3 `.py`／drpy 相對路徑同一規則；匯入的本機檔沒有基準網址就不列出）。`drivableSites` 在原位置換成補好網址的站，順序與 `Site.id` 不變。`Site.api` 改 `public internal(set) var`。
- `ios/Sources/WebHTVCore/Spider/CSPSourceResolver.swift`：`source` 由 private 改 internal，讓 `drivableSites` 取得設定來源。
- `ios/Sources/WebHTVCore/CMSClient.swift`：`Vod.isMultiSearch` 加上 `id.isEmpty`（FongMi `getId().isEmpty()`）。只有列表點擊（`vodDestination`）用它。
- `ios/WebHTVApp/Sources/WebHTVApp.swift`：`posterGrid` 改用位置當識別（`items` 在同一個列表內只往後追加、換列表整批替換），最後一張出現才載入下一頁的判斷改看位置。
- `ios/Sources/WebHTVCore/ConfigLoader.swift`：既有 ponytail 註解補上限制：`validate` 用沒有來源的 resolver，只含相對 type 4 站的設定仍會被拒（wang-sex 不受影響）。
- 不動 type 0／1／3 行為；不改設定檔。

## 驗證

- 單元測試：`aRelativeType4ApiResolvesAgainstTheConfiguration`（相對、`../`、絕對不變、type 1 相對不處理、匯入檔不列出、`Site.id` 不變）、`anItemWithNoIdIsSearchedFor`。反證：還原原始碼後兩項失敗；修正後通過。相關套件（ConfigLoader／FolderVod／CMSClient／SourceClient／SiteSelection／AggregateSearch／ListingPager）92 項全過。
- Simulator（webhtv-w185，iOS 27.0，安裝檔與建置輸出 dylib sha256 相同）：
  - 番號：首頁「已載入 75 部」、畫出 17 張海報（修正格線前只有 1 張）；點片 → 搜尋所有站台（25 筆）→ 選一筆 → 原生播放器 4315 ms 起播。
  - 女優：「已載入 139 部」、18 張海報；點片 → 搜尋（6 筆）→ 原生 2105 ms 起播。
  - 薇薇珊：「已載入 57 部」；點片 → 搜尋（110 筆）→ 原生 5887 ms 起播。
  - 播放的是搜尋到的其他站同名片，與 FongMi 行為相同；type 4 項目本身沒有 id 與線路。
  - 證據：`.herdr-synapse/webhtv-dev/artifacts/w258/simulator-evidence.txt`（不存片名與截圖）。
- 偏差：工單要求「正式 GitLab 設定」，但 11-09 12:37 起 gitlab.com 從這台 Mac 連線逾時（github.com 正常），改用 GitLab recha main 快照 `2a74b1f9f0b7fdc08a0d73590a27f41b26efdc05`（11-06）在本機 HTTPS 提供。三站的 api 與 json 檔就是快照內容；若 GitLab 之後改過這三站，需重測。
- Ponytail review：Ship；1 項小建議（`validate` 對只含相對 type 4 的設定仍拒絕）已改為註解記錄。另記「未查」：搜尋結果格的識別是 `站序＋vod_id`，若某 type 4 站的搜尋回多筆空 id 會只畫一筆；本輪番號沒有回搜尋結果，沒有實例。

## 沒驗到

- 真機。Android 對照（W-250 已確認 Android 可用，本單未重測）。
- 下一頁載入：`merging(newTitlesFrom:)` 以 `vod_id` 去重，空 id 的第二頁會被濾掉；三站首頁一頁就給完（75／139／57），沒有實例。
