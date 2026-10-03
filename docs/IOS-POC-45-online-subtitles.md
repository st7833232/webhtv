# IOS-POC-45 — 線上字幕搜尋、下載、套用與 Session 暫存

## Recovery anchor

- 目標：使用者 2026-10-02 要求（同一則訊息即授權實作，「不要每一步停下來詢問確認」）：播放中從字幕 panel 編輯搜尋文字、向 Subtitle Cat 搜尋、看到現成字幕、點選一個 direct SRT、以 URLSession 下載到該 playback session 的暫存目錄、加入既有字幕系統並立即在 AVPlayer／MPV 顯示；離開真正的播放 session 後清除；任何 Provider 失敗不影響播放。
- 範圍：task guard `IOS-POC-45`（`standard`），路徑 `ios/Sources/WebHTVCore`、`ios/Tests/WebHTVCoreTests`、`ios/WebHTVApp/Sources`、本文件、`docs/current-task-state.md`、`README.md`。不動 `project.pbxproj`、版號、release workflow、MPVKit、lock、patch。
- 與既有計畫的關係：`docs/IOS-POC-17-dual-internal-player.md` 第十四節 P4（MPV 外掛字幕）原本「沒有指示不開始」；本任務的 MPV `sub-add` 是使用者這次明確要求的範圍，只做「掛載本機已下載的 SRT」，不做 P4 的 ASS 樣式／來源字幕網址。
- 狀態：實作完成並 commit。macOS CI：Core 測試 714／714、Debug／Release（device）build 成功；iOS Simulator 只有與 base 相同的 9 個既有 WKWebView 測試失敗（第 9 節）。live smoke test 因網路政策未執行。
- 唯一下一步：在能連上 Subtitle Cat 的環境與真機上驗證第 10 節列出的項目（實際頁面結構、CJK 字型、PiP、鍵盤）。

## 1. 需求摘要

1. Provider 架構：`SubtitleProvider` 協定、共用模型（查詢、結果、下載、Session 暫存、錯誤）；第一個 Provider 是 Subtitle Cat，預留 OpenSubtitles／SubDL，但不假裝已可用。
2. 搜尋文字：自動辨識只負責預填與候選 chip，欄位永遠可全部刪除、自由輸入；送出的就是欄位文字。
3. Subtitle Cat：`https://www.subtitlecat.com/index.php?search=<URL encoded>` 的 HTTP GET → 解析結果頁連結 → GET 結果頁 → 只取已存在的 direct `.srt`；不用 WebView／JS，不觸發、不模擬 Translate。
4. 排序：zh-TW → zh-CN → ja → en → 其他（Provider 原順序）；語言先看頁面 label，再看 metadata，最後看檔名。頁面只寫「Chinese」、沒說簡繁的檔案不屬於前兩組，依規格歸入「其他」（顯示為「中文」）；zh-HK 歸入繁體中文組。
5. 下載：檢查 HTTP status、內容（非空、不是 HTML／CAPTCHA／Cloudflare／登入頁、有時間碼），UTF-8 BOM；寫入 session 專屬暫存目錄；同 session 同 URL 不重複下載。
6. Session 暫存：暫停、seek、畫質／音軌／字幕切換、背景、鎖屏、回前景、AVPlayer ↔ MPV、fallback 重建、同片重載都保留；結束播放、換片、關閉播放器、下次啟動發現 stale 目錄才清除，且只清本功能的目錄。
7. 錯誤：無結果、unreachable、HTTP failure、rate limited、搜尋頁解析失敗、結果頁解析失敗、download unavailable、invalid content、cancelled；最新搜尋為準；retry 最多一次且只對 transient／5xx。
8. 25 項測試案例（第 8 節對照）、live smoke test（第 9 節）。

## 2. 現況審查（修改前 HEAD `f6cd65dbcb459d85bf019c0704a134ee38ab3a26`）

- 字幕只有內嵌軌：`PlaybackMediaSelection`（`ios/Sources/WebHTVCore/PlaybackMediaSelection.swift`）是兩個 engine 共用的 track model；AVPlayer 走 `AVMediaSelectionGroup`（`AVPlayerEngine.mediaTrack`），MPV 走 `track-list`／`sid`（`MPVPlayerCore.refreshMediaSelection`）。全 repo 沒有 SRT parser、cue model、overlay、`sub-add`。
- Session 擁有者：`PlaybackSession`（App 生命週期的單例）。每個新項目都經過 `load(_:autoplay:)`；畫質切換與 prefetch retry 也走 `load`；engine 切換、fallback、背景暫停重載走 `PlayerRouter.handOff`／`reload`，不經過 `load`。播放器關閉只有 `PlayerView.onDisappear` → `closePlayer()`；WebHome bridge 的停止是 `control("stop")`。
- 同片識別：`WatchHistory.key`（站＋片）、`vodFlag`（線路）、`episodeUrl`（集）；畫質切換三者不變。沒有 record 的 bridge 播放只有網址。
- 字幕 panel：`PlayerControlBar` 的字幕按鈕只在內嵌選項 ≥ 2 時出現，`reconcileTrackPanel` 在選項 < 2 時關閉 panel；engine 交接時 panel 關閉。
- Core 慣例：網路以 closure 注入（`HLSAdPlanner.Fetch`）或 `URLSession.webHTV`；測試全用 Swift Testing、fixture inline；Logger subsystem `com.webhtv.ios.poc`、`privacy: .public`；App 端 Swift 檔需手動登錄 `project.pbxproj`（所以本任務不新增 App 檔案）。

## 3. Best-practice 查證（2026-10-02）

網路限制：本 session 的 egress proxy 拒絕 `www.subtitlecat.com`、`mpv.io`、`download.swift.org`、`www.autohotkey.com`（WebFetch 同樣被擋），只能用允許的來源。

| 證據類別 | 來源 | 等級 | 支持的結論 | 對設計的影響 |
|---|---|---|---|---|
| 上游原始碼／commit | 不適用：不是上游合併 | — | — | — |
| 官方文件（mpv） | mpv.io 被擋；改用 PyPI `mpv==1.0.7`（python-mpv）`mpv.py:1415` `sub_add(url, flags='select', title=None, lang=None)` | B（第三方包裝，2026-10-02 下載） | `sub-add <url> [<flags> [<title> [<lang>]]]`，flags 預設 `select` | 用 `sub-add <path> auto <title> <lang>`，選取另外設定 `sid` |
| 官方文件（mpv，訓練知識） | mpv manual：`sub-add` 加入的外部軌屬於目前檔案；`track-list/N/external`、`external-filename` | C（未能線上重讀） | `loadfile … replace` 後外部軌消失 | 每次 `MPV_EVENT_FILE_LOADED` 重新掛載 |
| 平台文件（AVFoundation，訓練知識） | `AVPlayerItem` 無法對串流（HLS）項目側載字幕；`AVMutableComposition` 只適用檔案型 asset；HLS 字幕 rendition 來自 master playlist | C | AVPlayer 不能直接掛外部 SRT | AVPlayer 以 overlay 繪製 cue；PiP 視窗不會有 overlay |
| 成熟專案做法（訓練知識） | VLC／Infuse 類播放器自繪字幕；mpv 系播放器用 libass | C | 自繪 overlay 是 AVPlayer 側載字幕的常見解 | 同上 |
| Subtitle Cat 頁面結構 | 站台被擋，無法實測 | 未取得 | — | parser 改為「不依賴版面」：只認連結型態與 host；fixture 標示為重建版本 |
| 既有 repo 先例 | `HLSAdPlanner.fetcher`、`DrpyEngine.download`（有上限的 bytes 讀取）、`SourceClientTests`（假網路） | A | 本 repo 的抓取與測試慣例 | 沿用 closure 注入與位元組上限 |

未解決的查證 gate：Subtitle Cat 實際 HTML 未能取得；已以容錯設計降低風險，並列為第 10 節的真機／連網驗證項目。

## 4. 方案比較與決定

| 面向 | 不做 | 照 Android／一般 scraper 直做（各 engine 各自抓） | WebHTV 調整版（採用） |
|---|---|---|---|
| 架構 | 無 | 搜尋／下載寫在播放器裡，AVPlayer、MPV 各一套 | 全部在 `WebHTVCore`；engine 只收 `PlaybackExternalSubtitle`（本機檔＋cues） |
| AVPlayer | — | 嘗試 `AVMutableComposition`：HLS 不能用 | SwiftUI overlay（10 Hz `TimelineView`），選取時關閉內嵌 legible |
| MPV | — | 每次切換重新下載 | `sub-add` 掛本機檔，`FILE_LOADED` 重掛，id 兩個 engine 相同 |
| HTML 解析 | — | 依固定 CSS／行號 | 自寫容錯 tokenizer（`LightHTML`），只認 `/subs/<數字>/<名>.html` 與本站 `.srt` |
| 暫存 | — | 永久 cache | session 目錄，`end()` 才刪，啟動清 stale |
| 風險 | 無功能 | 重複邏輯、重新下載、版面一改就壞 | overlay 不進 PiP；Subtitle Cat 版面未實測 |

決定：採用調整版。理由：一份下載、兩個 engine 共用同一個 id；engine 切換不重新下載；Provider 失敗只在 panel 呈現。

## 5. 設計

### 5.1 Core（`ios/Sources/WebHTVCore`）

- `OnlineSubtitles.swift`：`SubtitleLanguage`（label → metadata → 檔名；群組排序）、`SubtitleSearchQuery`（只去頭尾空白）、`RemoteSubtitleTrack`、`SubtitleSearchResult`（`ordered` 穩定排序；`listedCount`／`openedCount` 說明上限）、`SubtitleProviderError`（含 `isTransient`、`classify`、中文訊息）、`SubtitleProvider` 協定（`search`、`downloadRequest`、`availability`）。
- `SubtitleSearchKeywords.swift`：寬字元與破折號正規化 → 規則表（FC2、字母＋數字），保守：分隔只允許 `-`／`_`，有停用字表。
- `LightHTML.swift`：容錯 tokenizer／tree（void、raw-text、implied end、entity）。
- `SubtitleCatProvider.swift`：搜尋網址（RFC 3986 unreserved 以外全部 percent-encode，`+` → `%2B`）、結果頁連結、結果頁 `.srt`（排除 Translate、只收 `https://*.subtitlecat.com`、http 升級 https）、一次最多開 5 筆結果、同時 2 筆、單筆失敗不影響其他、全部失敗才拋錯。
- `SubtitleDownload.swift`：`SubtitleFetch` 注入、最多重試一次（transient／非 challenge 的 5xx）、狀態對應、內容驗證、編碼（UTF-8／BOM、UTF-16 BOM，否則依語言試 Big5／GB18030／Shift JIS／CP1252）、`SubtitleDownloadService`。
- `SubtitleHTTP.swift`：真正的 `URLSession.bytes` 抓取，位元組上限（頁面 4 MB、字幕 8 MB）。
- `SubtitleSessionCache.swift`：`<tmp>/WebHTVOnlineSubtitles/session-<UUID>/`；寫入 UTF-8；同 URL 去重；`end()` 刪目錄並拒絕後續寫入；`removeStaleSessions` 只刪 root 下 `session-` 開頭的目錄。
- `SubtitleCues.swift`：SubRip 解析（容錯）與 cue 查詢（overlay 用，也是下載驗證的一部分）。
- `OnlineSubtitleSession.swift`：每部影片一個 `@Observable` 狀態（查詢、候選、phase、結果、下載狀態、已下載清單）；搜尋以 generation 防止舊結果覆蓋、同查詢連按只送一次；下載一次一個、最後一次點選為準；`OnlineSubtitleCoordinator` 依 `OnlineSubtitleIdentity` 決定保留或結束 session。
- `PlaybackEngine.swift`：協定新增 `setExternalSubtitles(_:selectedID:)`（extension 預設 no-op）；`PlayerRouter` 保存清單與選取，`run()` 在新 engine `load` 前交給它，`selectMedia` 記住線上選取。
- `PlaybackMediaSelection.swift`：`PlaybackExternalSubtitle`、`PlaybackMediaTrack.subtitles(embedded:external:selectedExternalID:)`。

### 5.2 App（`ios/WebHTVApp/Sources`）

- `PlaybackSession`：`load` 在 `router.open` 前呼叫 `onlineSubtitles.playbackOpened`；`endOnlineSubtitles()` 由 `PlayerView.onDisappear`（同步、在 `persist` 之前）與 `control("stop")` 呼叫；下載完成 → `router.setExternalSubtitles` → 提示「已套用線上字幕：…」並關閉 panel；`selectMedia` 改經 router。
- `AVPlayerEngine`：合併清單；選線上字幕時關閉內嵌 legible，`readyToPlay` 後再套一次；`activeExternalCues` 給 overlay。
- `MPVPlayerCore`：`externals` 只在 `queue` 存取；`FILE_LOADED` 時 `sub-add … auto`，再明確設定 `sid`（避免 `subs-fallback` 自動選到）；`track-list` 的外部軌以檔案路徑（解析 `/private` 連結後）對回共用 id；清單移除時 `sub-remove`。
- `PlayerControlBar`：有線上字幕 session 時永遠顯示字幕按鈕；字幕 panel 下方新增「線上字幕」區（`OnlineSubtitleSection`）：搜尋來源、可編輯欄位與清除鈕、搜尋／取消、自動辨識候選 chip、狀態列、結果列（語言｜Provider、檔名、結果標題、下載狀態「下載中／已下載／使用中」）。不顯示比對分數。
- `OnlineSubtitleOverlay`：AVPlayer 時在影片上方、控制列下方畫目前 cue；控制列顯示時上移。字幕文字原樣，不做繁簡轉換。
- `WebHTVApp.init`：啟動時 `SubtitleSessionCache.removeStaleSessions()`。

### 5.3 Diagnostics

`[subtitle]` 前綴：搜尋（provider、query、listed／opened／files、耗時）、頁面 GET（路徑、status、bytes）、下載（檔名、語言、bytes、cue 數）、失敗類別、MPV 掛載、套用、session 結束。不記錄字幕內容、cookie、header。

## 6. 驗收條件

1. 從播放中的影片開字幕 panel，可改搜尋文字、搜尋 Subtitle Cat、看到現成字幕、點選後下載並立即顯示（AVPlayer overlay、MPV libass）。
2. AVPlayer ↔ MPV 切換後同一字幕仍可選且不重新下載。
3. 關閉播放器或換集後該 session 目錄被刪除；啟動時只清本功能的 stale 目錄。
4. 任何 Provider 失敗只在 panel 顯示，不影響播放與內嵌字幕。
5. Core 測試、Debug／Release build 通過。

## 7. Rollback

- 單一 commit；`git revert <commit>` 即可完全移除（無資料遷移、無永久檔案、無設定鍵）。
- 已安裝的 App 只會留下 tmp 內的 session 目錄，系統會自行清理 tmp；revert 後不再建立。

## 8. 測試對照（`ios/Tests/WebHTVCoreTests`）

| # | 案例 | 測試 |
|---|---|---|
| 1 | FC2PPV-1234567 候選 | `fc2PPVWithAHyphenGivesEveryUsefulSpelling` |
| 2 | FC2-PPV-1234567 不被破壞 | `theCanonicalFC2SpellingIsNotBroken` |
| 3 | FC2PPV1234567／FC2 PPV 1234567 | `everyFC2SpellingIsRecognized` |
| 4 | DLDSS553 → DLDSS-553 | `labelNumberCodesNormalizeToOneForm` |
| 5 | 一般片名不轉番號 | `ordinaryTitlesAreNotForcedIntoCodes` |
| 6 | 自訂文字原樣進 query、不被候選覆蓋 | `whatTheViewerTypedIsTheQueryVerbatim`、`theViewersTextIsSearchedAndNeverOverwrittenByRecognition` |
| 7 | URL encoding | `theSearchAddressEncodesEveryCharacterThatIsNotUnreserved` |
| 8 | 搜尋頁解析 | `theSearchPageGivesEveryResultPageOnce` |
| 9 | 無結果回 empty | `aSearchWithNoResultsAnswersEmpty` |
| 10 | zh-TW direct .srt | `theResultPageGivesItsDirectFilesWithTheirLanguages` |
| 11 | zh-CN／ja／en | 同上 |
| 12 | 排序 | `resultsAreOrderedTraditionalSimplifiedJapaneseEnglishThenTheRest`、`aSearchOpensTheResultPagesAndListsTheirFilesInOrder` |
| 13 | 相對 URL | `relativeSubtitleLinksResolveAgainstTheResultPage`、案例 10 |
| 14 | Translate 不算字幕 | 案例 10、`aPageWithOnlyTranslateButtonsHasNoFiles` |
| 15 | 404／403／429／5xx | `searchStatusesAreClassifiedAndOnlyServerErrorsRetried`、`downloadStatusesAreClassified` |
| 16 | 200 但是 HTML challenge | `aPageServedAsTheFileIsRejected` |
| 17 | 空檔 | `anEmptyFileIsRejected` |
| 18 | UTF-8 SRT 存入 session 目錄 | `aValidFileIsKeptInTheSessionFolder` |
| 19 | UTF-8 BOM | `aByteOrderMarkIsHandled` |
| 20 | AVPlayer ↔ MPV 後字幕仍在 | `anEngineSwitchKeepsTheDownloadedSubtitle` |
| 21 | pause／background／foreground 不清 | `pauseBackgroundForegroundAndReloadsKeepTheSubtitle` |
| 22 | 結束 session 清除 | `endingThePlaybackSessionDeletesItsSubtitles`、`endingTheSessionDeletesItsFolder` |
| 23 | 啟動只清本功能 stale 目錄 | `launchCleanupRemovesOnlyThisFeaturesStaleSessionFolders` |
| 24 | 舊搜尋晚回不覆蓋 | `aLateAnswerToAnOlderSearchNeverReplacesTheNewerOne` |
| 25 | Provider 錯誤不清 player／內嵌字幕 | `aProviderFailureLeavesThePlayerAndItsEmbeddedSubtitlesAlone` |

## 9. 驗證紀錄

### 9.1 Linux（雲端 session，Swift 6.0.3）

- 雲端 session 沒有 Xcode；從 Ubuntu 25.10 archive 取 `swiftlang 6.0.3` 解壓到 scratchpad（不動系統、不進 repo）。`WebHTVCore` 整個 target 在 Linux 編不起來（`os`、WebKit、JavaScriptCore），所以另建 scratch package，只連結本任務的新檔與 `PlaybackEngine.swift`、`PlaybackMediaSelection.swift`、`PausedBackgroundReload.swift`、`PlaybackActivity.swift`、`PlayURL.swift`、`WatchHistory.swift`；`os.Logger`、`FoundationNetworking`、CF 編碼轉換、`SourceClient.swift` 的 `PlaybackTarget` 用 scratch-only shim（不 commit）。`SubtitleHTTP.swift`（`URLSession.bytes`）在 Linux 不存在，只在 macOS 編譯。
- 結果：135 個測試全部通過（本任務 47 個，加上既有 `PlaybackEngineTests`、`PausedBackgroundReloadTests`、`PlaybackActivityTests`，確認 `PlayerRouter` 改動沒有回歸）。
- Mutation check（Rule 9）：在 scratch 副本逐一改壞 16 個關鍵規則（搜尋 generation、Translate 排除、語言排序、4xx 不重試、只重試一次、HTML 拒收、router 交接、stale 目錄前綴、label 優先、同 session 去重、同片保留 session、`+` 編碼、FC2 候選、空白不算分隔、`end()` 刪目錄、status 重試規則），16 個都會讓測試失敗。第一次發現「HTTP status 是否重試」在 retry 路徑另寫一份、`isTransient` 沒被用到；已改成共用同一規則再驗一次。
- Source-scan 規則（`RuntimeABITests`、`ExternalPlayerRemovalTests`、`TaiwanTraditionalTests` 的禁用字串）：新檔以 grep 檢查，沒有命中。

### 9.2 macOS CI（暫時驗證分支）

雲端 session 沒有 Xcode，所以把工作區的改動複製到一次性的分支 `ci/ios-poc-45-verify`（另一個 git worktree，`ios-poc` 的 HEAD 不動），加一個只在該分支觸發的 workflow，在 `macos-26`（Xcode 26.6）上跑；驗證完即刪除該分支，workflow 不進 `ios-poc`。

- Run 1 `36997761009`（第一版改動）：
  - `swift test --package-path ios`（macOS host）：**706／706 通過**（含本任務 47 個）。
  - iOS Simulator（`xcodebuild -scheme WebHTVCore test`）：706 個中 16 個 issue，全部在既有的 WKWebView／嗅探相關測試（`MediaSnifferTests` 6、`SnifferRulesTests` 1、`AdBlockListTests` 1、`SourceClientTests.theProbeReadsOnlyTheHeadOfABodyThatNeverEnds` 1）；本任務的測試沒有失敗。是否在 base 也失敗見 Run 2。
  - Release（device，未簽章）：**BUILD SUCCEEDED**。
  - Debug（device，未簽章）：BUILD FAILED，摘要沒有 `error:` 行；Run 2 改為完整擷取並與 base 對照。
- Run 2 `36999649367`（review 修正後）：macOS host 713／713；Debug（device）本次與 base 都 BUILD SUCCEEDED（Run 1 的 Debug 失敗沒有重現）；Simulator 測試與 Debug（simulator）見 Run 3。
- Run 3 `37001070319`（最終改動，`ios/` 與 commit 內容逐檔相同）：
  - macOS host：**714／714 通過**（base 659 + 本任務 55）。
  - iOS Simulator（同一台模擬器，base 先跑）：base 與本次**失敗的是同一組 9 個既有測試**（`MediaSnifferTests` 6、`SnifferRulesTests` 1、`AdBlockListTests` 1、`SourceClientTests.theProbeReadsOnlyTheHeadOfABodyThatNeverEnds` 1，都是 CI 模擬器的 WKWebView／本機 socket 逾時）；本任務 55 個測試在模擬器上全部通過。這 9 個不是本任務造成，未修改。
  - Debug（device）：**BUILD SUCCEEDED**；Release（device）：**BUILD SUCCEEDED**。
  - Debug（generic iOS Simulator）：base 與本次都以同一個既有錯誤失敗：`Install Python` build phase 的 rsync 路徑在雙架構時組成 `lib-arm64 x86_64`。與本任務無關，未修改（另案）。
  - 警告：本任務新增與修改的 Core／MPV 檔案沒有警告；`WebHTVApp.swift` 的 5 個警告與 base 相同（`UIDevice.current`、`consider using asynchronous alternative`，都是既有程式）。
- 暫時分支 `ci/ios-poc-45-verify` 於驗證後刪除。

### 9.3 Live smoke test

未執行。雲端 session 的 egress proxy 拒絕 `www.subtitlecat.com`（`curl` 與 WebFetch 都是 `403 connect_rejected`，2026-10-02 10:10 UTC），所以 `FC2PPV-4159457` 的搜尋頁、結果頁與 direct `.srt` 都沒有實際取得或驗證。fixture 依已知版面重建，並刻意變化寫法；需要在能連線的環境用 App 實測一次（第 10 節）。

### 9.4 Ponytail

`ponytail:ponytail-review` 不在本 session 的可用 skill 清單：Ponytail: unavailable / skipped。改以多面向對抗式 review（見 9.5）。

### 9.5 對抗式 review

四個面向（Core 並行、Provider 解析與安全、App 整合與 Swift 6 編譯風險、需求覆蓋與測試意圖）各一個 reviewer，再各一個 verifier 逐項反駁。App 整合面向沒有發現；其餘 12 項都修正並補測試，verifier 逐項確認已修正：

1. `LightHTML` 沒有巢狀深度上限，惡意或破損頁面可在 512 KB 的工作執行緒上 stack overflow → 上限 256 層。
2. 單一字幕檔＋多個 Translate 列的頁面，label 爬到整個清單而誤判成繁中 → Translate 控制項也算一筆，補 Croatian／未知語言測試。
3. 部分結果頁失敗、其餘沒有檔案時誤報「找不到字幕」→ 沒有檔案且有失敗時回報失敗原因。
4. redirect 到別的 host 或 http 沒被擋 → 頁面與下載都檢查最終 URL（`acceptsDownload(from:)`）。
5. `download=` 屬性被拆字當語言 → 移除。
6. 「Dune-2021」「Avatar2009」被當番號 → 非全大寫且為年份時不算。
7. 搜尋按鈕連點第二下變成取消 → 搜尋鈕永遠是搜尋，取消移到狀態列。
8. 非拉丁語系 legacy 編碼一律 CP1252 → 依語言選 code page（CP949、CP1250／1251／1253／1254、希伯來、阿拉伯、泰、越）。
9. `.noResults` 狀態沒有測試 → 補。
10. 下載的重試次數沒有測試 → 補參數化測試。
11. 沒寫簡繁的「Chinese」排在日文、英文之前，與使用者指定的順序不符 → 歸入「其他」。
12. （verifier 追加）he／ar／fa／th／vi 仍用 CP1252 → 補上。

## 10. 尚待真機或連網驗證

1. **Subtitle Cat 實際頁面**：用 `FC2PPV-4159457` 在 App 內搜尋，確認搜尋頁、結果頁、direct `.srt` 的實際 HTML 與 fixture 的假設一致（結果頁連結 `/subs/<數字>/<名>.html`、檔案 `…-<語言>.srt`、Translate 為按鈕或 `onclick`）。不一致時只需改 `SubtitleCatProvider` 的連結判斷與 fixture。
2. **MPV CJK 字型**：0.1.52 真機回報 MPV 字幕全是方格；IOS-POC-45A（第 11 節）改以 `sub-font` 指定 libass 能開啟的 CJK 字型，待真機確認。
3. **MPV PiP**：`sub-add` 的字幕是否也畫進 PiP 的軟體輸出（libmpv render API 通常會，未實測）。
4. **AVPlayer PiP／AirPlay**：overlay 只在 App 內的播放畫面顯示；PiP 視窗與 AirPlay 電視上看不到線上字幕（平台限制，已知）。
5. **鍵盤**：直式底部 sheet 與橫式側邊 drawer 在鍵盤出現時的高度（SwiftUI keyboard avoidance 未實測）。
6. **字幕同步**：HLS 廣告切除或片頭偏移時，外掛字幕可能整體偏移（`docs/IOS-POC-26-engine-switch-position.md` 的 H1 已記錄過同類現象）；IOS-POC-45B（第 12 節）加入時間軸校正。

## 11. IOS-POC-45A：MPV 中文字幕顯示為方格

- 回報：使用者 2026-10-02 於 `0.1.52 (53)` 真機回報「Mpv 的字幕都是方格」。
- 證據：libass 0.17.5 原始碼（`libass/ass_coretext.c`、`libass/ass_fontselect.c`，tag `0.17.5`，2026-10-02 取得）。
  1. CoreText provider 只收有檔案 URL 的字型（`get_font_info_ct`：URL 為空即跳過），之後由 FreeType 依路徑開檔。
  2. `ass_font_select` 的順序：樣式字型 → 預設 family（mpv 的 `sub-font`）→ provider 的 `get_fallback`（`CTFontCreateForString` 回傳的 family 名稱，再以名稱比對）→ 預設字型檔。
  3. mpv 的 `sub-font` 預設 `sans-serif`，CoreText provider 對應為 Helvetica，沒有中文字形；中文只能走 `get_fallback`。iOS 的 CoreText fallback 回傳的 family 若是系統私有字型（名稱以 `.` 開頭，模擬器的 PingFang 即為此類，見 `WebHTVApp.swift` 的 `displayName` 註解）或檔案打不開，比對就失敗，畫出方格。
- 修正：`MPVSubtitleFont.family` 依序檢查 `PingFang TC`、`PingFang HK`、`PingFang SC`、`Hiragino Sans`，取第一個 CoreText 能找到、有檔案 URL 且檔案實際能開啟的 family，於 `mpv_initialize` 前設為 `sub-font`。文字字幕（SRT 轉成的樣式字型）直接使用它；ASS 指名但找不到的字型也先試它，再走 fallback。結果記一行 `[subtitle] mpv sub-font=…`（只有 family 名稱）。
- 不採用：
  1. 內建 CJK 字型檔：保證可用，但 IPA 增加約 7 至 16 MB，且需授權登錄；等真機證明系統字型開不了再評估。
  2. `sub-fonts-dir` 指向系統字型：libass 會把目錄內字型整個讀進記憶體，PingFang 字型集合檔過大。
  3. 以 SwiftUI overlay 取代 MPV 字幕：失去 ASS 樣式，內嵌圖形字幕仍需 libass，範圍過大。
- 風險：四個 family 都開不了時行為與修正前相同，log 會寫 `default (no CJK family opens)`，屆時改走內建字型方案。
- 驗證：此環境無 macOS／iOS，無法編譯 App target 或實機播放；以下一次 release workflow 的建置與真機播放中文 SRT／內嵌中文字幕為準。
- Rollback：revert 本 commit（只動 `MPVEngine.swift` 與文件）。

## 12. IOS-POC-45B：字幕時間軸校正

- 需求：使用者 2026-10-02「需要可以調整字幕的字軌」，隨後確認為「時間軸矯正」。
- 行為：字幕 panel 在字幕清單下方新增「時間軸校正」：`-1`、`-0.1`、目前數值（點一下歸零）、`+0.1`、`+1`。正值讓字幕延後出現，與 mpv `sub-delay` 同號；數值固定在 0.1 秒刻度，上下限 ±600 秒（`SubtitleDelay`）。
- 套用範圍（`SubtitleDelay.applies`）：
  1. MPV：所選字幕不是「關閉」即顯示，內嵌與線上字幕都以 `sub-delay` 移動。
  2. AVPlayer：只有選中線上字幕時顯示，由 overlay 以 `SubtitleCues.text(at:delay:)` 查 cue。AVPlayer 的內嵌 legible 字幕沒有可移動時間的 API，不顯示此列，避免出現按了沒有作用的按鈕。
- 生命週期：數值存在 `PlayerRouter.subtitleDelay`，和線上字幕檔一樣在引擎切換、fallback、重新載入時於新引擎 load 前交給它；字幕 session 結束（換集、換影片、關閉播放器，即 `setExternalSubtitles([])`）時歸零。
- 測試（`ios/Tests/WebHTVCoreTests`）：
  1. `aPositiveDelayShowsTheSameLineLaterOnBothEngines`：+0.5 秒時 10 至 12 秒的 cue 在 10.5 至 12.5 秒顯示，負值相反。
  2. `theDelayStaysOnTenthsAndWithinItsLimit`：十次 +0.1 等於 1.0、上下限、NaN 歸零、標籤符號。
  3. `theCorrectionIsOfferedOnlyWhereItMovesTheSubtitleOnScreen`：AVPlayer 內嵌字幕與「關閉」不顯示。
  4. `theTimingCorrectionFollowsTheVideoAcrossEnginesAndEndsWithIt`：MPV 設定 1.5 秒後切到 AVPlayer，新引擎在 load 前已拿到 1.5；同一集重新開啟保留；換集與關閉歸零。
- 驗證：Linux swiftlang 6.0.3 scratch package `swift test` 147 項，146 通過；唯一失敗為既有的 `legacyFilesDecodeInTheirLanguagesCodePage`（Linux Foundation 沒有 CP1251 轉換器，macOS 通過，第 9 節已記錄）。App target（`MPVEngine.swift`、`WebHTVApp.swift`）未在 macOS 編譯，以下一次 release workflow 建置為準。
- Rollback：revert 本 commit。

## 13. IOS-POC-45C：其他字幕來源（官方 API）

### 13.1 需求與限制

- 使用者 2026-10-02「另外幫我提供其他字幕來源」。沿用第 1 節的限制：只用正式公開 API，不做 HTML scraping；API key／token 不寫進 repository、測試、log 或文件；沒有 key 時自動停用並顯示「未設定」，不送出任何請求；遇到 CAPTCHA 或 challenge 不繞過。

### 13.2 Best-practice 查證（2026-10-02）

此環境的出口代理擋下 `api.opensubtitles.com`、`opensubtitles.stoplight.io`、`api.subdl.com`、`api.assrt.net`、`jimaku.cc`（HTTP CONNECT 403），官方文件站與 API 都無法直接讀取，也無法做 live smoke test。改讀可取得的一手與成熟專案程式碼：

| 來源 | 版本 | 等級 | 支持的結論 |
|---|---|---|---|
| `opensubtitles/service.subtitles.opensubtitles-com`（OpenSubtitles 官方 Kodi add-on），`resources/lib/osclient/provider.py`、`model/request/*.py` | `7acfa8f2932a0155ba921212882baa0fade05890`（2026-08-29） | 官方客戶端程式碼 | API 根 `https://api.opensubtitles.com/api/v1/`；每個請求帶 `Api-Key` 與應用程式 `User-Agent`；`GET subtitles`（`query`、逗號分隔 `languages`）回傳 `data[].attributes.{language,release,files[].file_id,file_name}`；`POST download` 以 JSON `{file_id, sub_format: "srt"}` 換一次性 `link`；未登入可下載（「Proceeding with free downloads」），每日額度用完回 406，429 為速率限制，401 為認證失敗；log 不得含 header（含 Api-Key）。 |
| `morpheus65535/bazarr` master，`custom_libs/subliminal_patch/providers/opensubtitlescom.py` | 2026-10-02 讀取 | 成熟相關專案 | 與上表一致；查詢參數依字母排序以避免轉址。 |
| 同上，`providers/assrt.py`、`converters/assrt.py` | 2026-10-02 讀取 | 成熟相關專案 | API 根 `https://api.assrt.net/v1`；`token` 為查詢參數；`sub/search?q=` 回傳 `sub.subs[].{id,videoname,native_name,lang.langlist}`；`sub/detail?id=` 回傳 `sub.subs[0].filelist[].{f,url}`（壓縮檔內的檔案逐一列出、各有直接連結）或單檔 `url`；`status`/`errmsg` 表示 API 自身錯誤；`langlist` 鍵為 `lang<代碼>`，`cht`/`twn` 繁體、`chs`/`chn` 簡體、`eng` 英文。 |
| 同上，`providers/subdl.py` | 2026-10-02 讀取 | 成熟相關專案 | SubDL 的下載一律是 ZIP（部分舊檔是副檔名為 .zip 的 RAR），`api_key` 在 URL 查詢參數。 |

不適用的證據類別：官方規格與文件（被出口政策擋下，已記錄為未讀）；論文與 benchmark（與 API 介接無關）。

### 13.3 方案比較

1. 不變：只有 Subtitle Cat，中文影視字幕的覆蓋差。
2. 照搬成熟客戶端：Bazarr 的 OpenSubtitles 需要帳號密碼登入取得 JWT；保存使用者密碼的風險與維護成本高於收益（官方 add-on 證明未登入也能下載）。
3. WebHTV 調整版（採用）：
   - OpenSubtitles：只用 API key，不登入；下載的 `POST download` 只送一次、不重試（已回應的請求可能已扣額度）；一次性連結取回檔案時不帶 Api-Key；同一 session 再選同一檔案由 session 快取回傳，不再呼叫 API。
   - 射手網：token 只出現在 API 請求的查詢字串，不出現在 track、referrer 或 log；結果依序開啟最多 4 筆、一筆一筆送（API 以每分鐘請求數計），遇 429 或 key 被拒即停止其餘；只列 `.srt`。
   - SubDL：暫緩。每個下載都是壓縮檔，現有流程沒有解壓縮（ZIP 需實作 DEFLATE，RAR 無系統支援），不在本階段範圍。
   - Jimaku：暫緩。只收動畫日文字幕，且常為壓縮檔。

### 13.4 實作

- `SubtitleCredentials.swift`：`SubtitleCredentialStore`、`KeychainSubtitleCredentials`（`kSecClassGenericPassword`，service `com.webhtv.ios.subtitle-credentials`，`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`），`OnlineSubtitleProviders.make` 依序提供 Subtitle Cat、OpenSubtitles、射手網。Subtitle Cat 仍排第一，未設定 key 的使用者預設行為不變。
- `OpenSubtitlesProvider.swift`、`AssrtProvider.swift`；共用的 `SubtitleAPI`（JSON 物件、狀態分類、不記錄 URL／header／body）。
- `SubtitleProviderError` 新增 `unauthorized`（401/403）、`quotaExceeded`（OpenSubtitles 406）、`rejected(Int)`（射手網 `status`）。
- App：設定頁新增「線上字幕來源」，以 SecureField 輸入、存入鑰匙圈，只顯示「已設定／未設定」，不回顯內容；字幕面板對未設定來源顯示原因。key 變更在下一部影片生效（provider 每個播放 session 建立一次）。
- 與 Keychain 的取捨：既有設定使用 `@AppStorage`（UserDefaults）；API key 屬於憑證，改用 Keychain（不進一般備份、不同步到其他裝置）。這是新增的儲存機制，設定頁仍是既有入口。

### 13.5 驗收與測試

`ios/Tests/WebHTVCoreTests/SubtitleAPIProviderTests.swift`：

1. `aProviderWithoutItsKeyIsListedAsNotSetUpAndNeverCalled`：沒有 key 時兩個 API 來源顯示未設定、預設選 Subtitle Cat、搜尋不送出任何請求。
2. `openSubtitlesSearchesWithTheKeyInItsHeaderOnly`：Api-Key 只在 header、參數順序、繁中優先、沒有 file id 的結果不列、track 不含 key。
3. `openSubtitlesDownloadAsksForOneLinkAndKeepsTheKeyAway`：一次 POST、body 正確、連結請求不帶 key、同一 session 重選不再 POST。
4. `openSubtitlesRefusalsAreNamedAndTheLinkRequestIsNotRetried`：406、401、503 各只送一次並分類正確；403 為 key 被拒。
5. `assrtListsTheSubRipFilesOfEachResultAndKeepsTheTokenToTheAPI`：只列 `.srt`、檔名語言優先、langlist 補足、下載請求不含 token 與 referrer。
6. `assrtErrorsAreRefusalsAndARateLimitStopsTheDetailRequests`：`status` 非 0 為拒絕、429 停止其餘 detail 請求。

突變檢查：讓下載 POST 重試、連結請求帶 Api-Key、移除 `.srt` 過濾、移除 429 停止，四項各自讓上述測試失敗（已還原）。Linux swiftlang 6.0.3 `swift test` 153 項，152 通過，唯一失敗為既有的 Linux CP1251 項目。

### 13.6 未驗證與風險

- 兩個 API 都未實際連線（出口政策）；回應格式依官方 add-on 與 Bazarr 程式碼。若實際格式不同，只需修改各 provider 的解析與測試 fixture。
- OpenSubtitles 一次性連結的主機與是否需要 Api-Key 未實測；目前不帶 key。若真機下載回 401/403，改為對該連結帶 key 即可。
- 射手網的 `q` 是否需要 `is_file` 等其他參數未證實（Bazarr 以 `is_file=1` 搭配片名與年份）；目前只送 `q`。
- App target（設定頁、面板）未在 macOS 編譯，以下一次 release workflow 為準。
- Rollback：revert 本 commit；鑰匙圈中已存的 key 不影響其他功能，可在設定頁「清除」。

## 14. IOS-POC-45C-1：射手網評估（2.assrt.net）與錯誤處理修正

- 使用者 2026-10-02 要求評估 `https://2.assrt.net`。站台與 API 在此環境都連不上；以官方 API 文件的 GitHub 剪存（`PingWangWang/SubQuick` `0b77ff4eaa0718001a8d60ed661125bb10365faa`，`docs/API文档-射手网.md`，2026-06-29 剪存）、IINA `AssrtSubtitle.swift`（`45955567392afd6cf9c1228bc9208141c3e2c8a6`）、atv-player（`afc26c47745e6782d0e291ee4495c1d1bf049dd5`，實測 20001 以 HTTP 400 回傳）、Bazarr issue #1953（超出配額回 HTTP 509）與 DNS 查詢為據。
- 結論：
  1. `2.assrt.net` 是 assrt.net 營運者自己的備用網頁入口（同網域 A 記錄、同一組 Cloudflare IP），不是新的來源。API 仍是 `https://api.assrt.net/v1/`，第 13 節的 provider 已涵蓋，不另做 HTML 擷取。
  2. 一般影視的中文字幕是主要用途；番號只在搜尋索引看到零星舊作，新番號命中率預期很低（未實測）。
  3. 樣本 34 筆中約 65% 至少有一個 `.srt`，約 32% 只有 `.ass`；壓縮包內的檔案由 `filelist[].url` 逐一提供直接連結，不需要解壓。
- 修正（本 commit）：
  1. `AssrtProvider.answer` 不論 HTTP 狀態都先讀 JSON `status`：20001 → `unauthorized`，30900 → `rateLimited`，其他 → `rejected(code)`；沒有 `status` 才依 HTTP 分類，509 → `rateLimited`。搜尋的 20900（字幕不存在）視為沒有結果。
  2. 射手網的請求一律不重試（配額以每分鐘計，文件寫 20 次、部分 token 只有 5 次）；`rateLimited` 與 `unauthorized` 會停止其餘 detail 請求。
  3. `SubtitleAPI.response` 拆出未判讀狀態的取得步驟；`SubtitleAPI.object`（OpenSubtitles）行為不變。
  4. 依 API 文件的使用條件，設定頁與字幕面板標示「字幕服務由 assrt.net 提供」。
  5. 測試 `assrtStatusCodesDecideAndAUsedUpQuotaStopsAtOnce` 取代原本把 101 當成 token 無效的測試，涵蓋 20001／HTTP 400、30900／HTTP 200、HTTP 509、HTTP 429、101、20900／HTTP 404 與請求次數。突變檢查（恢復重試、30900 不對應、20900 不視為空）三項都讓測試失敗（已還原）。Linux `swift test` 153 項，152 通過（既有 CP1251 項目除外）。
- 暫不做：`filelist=1` 預先篩選含 `.srt` 的結果、token 改用 `Authorization: Bearer`、`.ass` 支援、依 `user/quota` 節流；這些需要實測或另行核准。

## 15. IOS-POC-45E：快轉後時間軸跑掉（廣告留在播放器時間軸）

### 15.1 回報與查證

- 回報：使用者 2026-10-02「為什麼設定好時間軸然後快轉字幕的時間軸就跑掉了」。2026-10-03 使用者同意實作（「好」）。
- 查證（workflow，四個方向各附反駁）：
  1. 沒有程式錯誤會改動偏移量：快轉、自動跳過廣告、重新載入、切換引擎、PiP 都不寫 `subtitleDelay`；mpv 的 `sub-delay` 是全域選項，跨 seek 與 `loadfile` 保留（mpv v0.41.0 `options/options.c`）。
  2. 成因是設計缺口：智慧去廣不改寫播放清單，而是播放時 seek 跳過（`HLSAdTimeline.swift` 開頭說明、`HLSAdSkip.swift`），廣告秒數留在兩個引擎的時間軸裡；下載的字幕是照沒有廣告的正片做的。固定偏移量只在兩段廣告之間成立：在第一段廣告後對齊，快轉越過第二段廣告後字幕會早出現該段的長度。IOS-POC-25 的樣本（兩段 19.633 s、17.359 s）在 10:00 對齊、快轉到 30:00 時早 17.4 s。
  3. 其他較低可能：偵測器沒抓到的插入片段、不同剪輯版本、影格率不同；App 只能以重新對齊緩解。

### 15.2 方案比較

1. 不變：每過一段廣告就要重調。
2. 重新產生已扣廣告時間的 SRT 再 `sub-add`：ASS 需要另寫輸出器，計畫晚到或切換引擎要重新掛載，近廣告邊界時與 overlay 的時間不同。
3. 在 FFmpeg 層移除廣告：二進位變更，範圍過大。
4. 採用：同一個「字幕時鐘」給兩個引擎。`content(p) = p − adBefore(p)`，廣告中沒有節目時間（字幕隱藏）；查詢時間 `content(p) − 使用者偏移`。

### 15.3 實作

- `SubtitleAdClock.swift`（新）：由 `HLSAdTimeline` 建立，合併相隔 `adjacentRangeGapMs` 的區間；`adSeconds(before:)`、`adSeconds(endedBy:)`、`isInsideAd`、`contentTime(at:)`、`engineDelay(user:at:)`（使用者值加上所有已開始的廣告）。
- `SubtitleCues.text(at:delay:clock:)`：`.none` 時與原本 `text(at:delay:)` 完全相同。`SubtitleDelay.aligned` 計算「對齊上一句／下一句」。
- `HLSAdSkipper.subtitleTimeline(engine:duration:)`：與 `activeTimeline` 相同條件但不看智慧去廣開關（引擎時長與計畫相差 1 秒內、該引擎未暫停跳過）；`activeTimeline` 改為 `enabled ? subtitleTimeline : nil`，行為不變。
- `PlayerRouter`：
  1. `subtitleDelay` 永遠是使用者的值（節目時間）；`subtitleClock`、`subtitleAdMapping`（每部影片的開關）、`activeSubtitleClock`（只對選中的下載字幕生效，內嵌字幕維持使用者值）。
  2. `refreshSubtitleTiming(at:)` 只在值改變時推給引擎：`sub-delay = 使用者值 + 已開始的廣告`，廣告中 `setSubtitleHidden(true)`。新引擎在 load 前以起播位置推送。
  3. `setSubtitleClock` 只對「使用者以下載字幕對齊過」的值重新換算，讓字幕維持原本的時間：離開時鐘時計入目前所在的整段廣告，進入時只計已播完的廣告；不四捨五入，畫質切換清除再恢復會得到原值。位置在引擎尚未回報時取起播位置（`subtitlePosition`）。
- App：
  1. `PlaybackSession.seek`、自動跳過、重播在 seek 前先 `refreshSubtitleTiming(at: 目標)`；ad tick 每次以路由器位置更新；每個新項目清除時鐘，計畫到後由 `syncSubtitleClock` 設定（引擎尚未載入時不動，避免切換引擎時清除再恢復）。
  2. AVPlayer overlay 改用 `text(at:delay:clock:)`。MPV：`setSubtitleHidden` → `sub-visibility`；`sub-delay` 以固定小數格式寫入並記錄失敗。
  3. 時間軸校正列：「對齊上一句／下一句」、「扣除廣告時間」開關與說明（只在選中下載字幕且有廣告計畫時顯示）。
  4. 診斷：`[subtitle] clock on|off <引擎> ads= adTotal= reason=`；偏移量相關動作記錄位置、節目時間、已扣廣告秒數與給引擎的值（不含字幕內容）。

### 15.4 Review 與驗證

- Review workflow（四個面向、每項反駁）確認 11 項，皆已修正：畫質切換時以載入中的 0 秒重新換算（3 項同源）、廣告中途重新換算只計部分廣告、重新換算受當下選的字幕軌影響、載入中以 0 秒覆寫 MPV 的值（3 項同源）、重播未先更新、面板數值在點擊後最多延遲 0.5 秒才更新（加 `revision` 觸發重繪）。駁回 1 項（`?? .none` 的型別推斷）。
- 測試：`SubtitleAdClockTests`（9 項）、`HLSAdSkipTests.subtitleTimelineNeedsThePlaylistClockButNotTheSwitch`、`OnlineSubtitleSessionTests` 新增 6 項（下載與內嵌字幕的差異、晚到的計畫、沒對齊過的值、畫質切換、廣告中清除時鐘、內嵌字幕時到達的計畫）。三項 review 回歸測試以突變檢查確認會失敗（已還原）。
- Linux swiftlang 6.0.3 `swift test` 232 項，231 通過；唯一失敗為既有的 Linux CP1251 項目。HLS 相關測試在 Linux 以替代 CryptoKit 的副本執行（僅 scratchpad，未進 repo）。
- App target 未在 macOS 編譯；以下一次 release workflow 為準。真機待驗：快轉跨廣告後字幕仍對齊、廣告中字幕隱藏、對齊按鈕、開關。
- Rollback：revert 本 commit；沒有廣告計畫時行為與修改前相同。

## 16. IOS-POC-45D：MPV 字幕內建中文字型

### 16.1 回報與成因

- 回報：`0.1.53 (54)` 真機上 MPV 中文字幕仍是方格，且字幕顯示時掉幀、聲音斷續（使用者 2026-10-02 截圖）。2026-10-03 使用者同意內建字型（約增加 4 MB）。
- 成因（workflow 查證，各項附反駁）：
  1. 方格：iOS 18 以後 CoreText 把 PingFang 解析到 `PingFangUI.ttc`，字形只存在 Apple 的 `hvgl` 表（Apple developer forums 758189、759219）。MPVKit libass-build `0.17.5`（`e08eb5bb3be5137e845f781dc9477d1843f23261`）用 FreeType `VER-2-14-3`，沒有 HVF driver（FreeType master 的 HVF 是實驗性、僅 macOS）。FreeType 能讀檔頭但開不了字型，libass 不登錄它，缺字時畫 face 0 的 `.notdef` 方格。第 11 節（IOS-POC-45A）的 `FileHandle` 檢查只證明檔案能開，所以正好選中這個讀不了的字型；它沒有造成方格，但讓每個缺字多一次失敗查詢。
  2. 掉幀與斷音（中高可信度，未在 iPhone 量測）：libass 0.17.5 每格重新排版字幕，每個字查一次字型索引，缺字不做快取，每次都重跑 CoreText 查詢與 FreeType 開檔。mpv v0.41.0 在 VO 執行緒持有字幕鎖時繪製，核心執行緒補音訊前也要拿同一把鎖。另一個 iOS 播放器（NuvioMobile #1843，iPadOS 26.6，MPV）症狀相同並記錄 `Audio device underrun`，內建 Noto CJK 後消失（PR #1833）。
- 第 11 節「不採用」的第 1 項（內建字型）與第 2 項的前提被證據推翻；第 3 項的描述也要更正：圖形字幕（PGS、VobSub）不經 libass。

### 16.2 方案比較

1. 內建 CJK 字型給 libass（採用）：修好線上 SRT 與內嵌 SRT/ASS（保留 ASS 樣式），MPV PiP 仍有字幕；IPA 約 +4.05 MB，播放字幕時約 +5 MB 記憶體（libass 會把 `sub-fonts-dir` 的檔案讀進記憶體；估計值）。
2. MPV 文字字幕改用 SwiftUI overlay：不增大小，但 ASS 樣式全失、MPV PiP 沒有字幕、改動大。
3. 兩者並用：overlay 對線上 SRT 沒有額外好處。
4. 以 `CTFontManagerRegisterFontsForURL` 註冊字型（記憶體較省）：未驗證 libass 能否看到，保留為記憶體備案。
5. 改用其他系統字型（例如 Hiragino）：缺簡體字，方格與查詢成本仍在，只作診斷。

### 16.3 實作

- 字型：Noto Sans CJK TC 2.004（`notofonts/noto-cjk` `f8d157532fbfaeda587e826d4cd5b21a49186f7c`，SHA-256 `dce08bd4…`），以 fontTools 4.66.1 取 Big5-HKSCS、GB2312 全部 BMP 字元、KS X 1001 韓文、假名、拉丁、希臘、西里爾與標點符號（21,786 個字元全收），去掉 `locl`／`vert`／`vrt2`、不保留 hinting，改名為 `WebHTV Subtitle CJK`（Noto 是商標；OFL 允許改名後的修改版）。結果 4,776,328 bytes，SHA-256 `f1c79354…`。來源、指令與檢查記在 `ios/Sources/WebHTVCore/Resources/SubtitleFont/README.md`，OFL 原文為同目錄 `LICENSE`。
- `ios/Package.swift` 加 `.copy("Resources/SubtitleFont")`（沿用 Spiders、OpenCC 的方式，不動 pbxproj）；`SubtitleFont.family`、`SubtitleFont.directory`（`fonts/` 只放這一個檔）。
- `MPVPlayerCore.init`（`mpv_initialize` 前）：`sub-fonts-dir`＝內建字型目錄、`sub-font`＝`WebHTV Subtitle CJK`、`sub-font-provider`＝`auto`（CoreText 仍處理泰文等字型未涵蓋的文字）。移除 IOS-POC-45A 的 PingFang 偵測與 `sub-font` 設定。
- 診斷（不含字幕內容）：
  1. 啟動時一行：`[subtitle] libass font bundled=ok|missing family=… setopt dir=… font=… provider=… device=… pingfang glyf=… CFF=… CFF2=… hvgl=…`（最後一段直接確認裝置上的 PingFang 是否只有 hvgl）。
  2. `mpv_request_log_messages(handle, "warn")`，只計數：`Error opening font`（只記第一次的檔名）、`failed to find any fallback`、`underrun`。
  3. 每個檔案結束時：`[subtitle] mpv health fontErrors= fallbackMisses= underruns= frameDrops= decoderDrops= sid=`。
- 測試：`SubtitleFontTests.theSubtitleFontFolderHoldsOneCFFFontAndNothingElse`（目錄只有一個檔、是 CFF OpenType、內含 `sub-font` 指定的名稱）。

### 16.4 驗證與待驗

- Linux swiftlang 6.0.3：字型測試通過；Core 全套見 commit 紀錄。App target 未在 macOS 編譯，以下一次 release workflow 為準。
- 真機待驗：
  1. 啟動紀錄 `bundled=ok`、三個 setopt 為 0、PingFang 一段為 `hvgl=1`。
  2. 繁體與簡體 SRT 各播 2 分鐘：沒有方格、沒有斷音，`mpv health` 的 fontErrors／fallbackMisses／underruns 為 0，frameDrops 與關字幕時相近。
  3. 內嵌 ASS（含 `\an8` 或 `\pos`）保留樣式；MPV PiP 有字幕。
- 若第 2 項仍斷續：先試 `sub-font-provider=none`（需使用者接受泰文等字型的取捨），再考慮 overlay，最後才是 libass 修補。
- Rollback：revert 本 commit。

### 16.5 IOS-POC-45D-1：review 修正

- Review workflow（行為與編譯兩個面向、每項反駁）確認 6 項，沒有駁回：
  1. 字型錯誤計數永遠是 0：libass 的警告在 mpv 被降為 info（mpv v0.41.0 `sub/ass_mp.c` `map_ass_level`），而 `mpv_request_log_messages` 只訂閱 warn。改為 info，並同時比對 `Error opening font`、`Error opening memory font`（`sub-fonts-dir` 的字型以記憶體字型開啟）、`failed to find any fallback`、`not found in font for`。
  2. `frame-drop-count`、`decoder-frame-drop-count` 在 `END_FILE` 時已被 mpv 釋放，永遠讀到 n/a，最後一支影片也不會回報：改為觀察這兩個屬性並保留最後的值，`shutdown()` 前補回報。
  3. 子集缺《通用規範漢字表》中的 544 字（例如「啰」）：加入全部 8,105 字（`shengdoushi/common-standard-chinese-characters-table` `d9b599a9c9cc0dd2d58cad829e285bc780cd4451`），字型 4,776,328 → 4,966,308 bytes（壓縮後 4,200,451），SHA-256 `f8259c8d…`；8,105 字全收，FreeType 都畫得出來。
  4. 檔案交界處計數為近似值：加註解。
  5. 測試只查 `OTTO` 檔頭與字串：改為解析 sfnt 目錄（有 `CFF `、沒有 `hvgl`／`glyf`）與名稱表（平台 3、name ID 1 完全等於 `SubtitleFont.family`）；以未改名的字型替換時測試失敗（已還原）。
  6. 發布流程不檢查字型是否打包進 App：需要改 release workflow，不在本次範圍，僅記錄；裝置上的 `bundled=missing` 紀錄可判斷。
- 第 16.4 節的真機檢查第 2 項，現在 `fontErrors`／`fallbackMisses` 才是有效的指標。

## 17. IOS-POC-45G：射手網網頁版（2.assrt.net）

### 17.1 需求與授權

- 使用者 2026-10-02 指出 `2.assrt.net` 不需要 token 就能下載，並在選項中選了「新增網頁版來源」：放寬第 13 節「新來源只用官方 API、不擷取網頁」的條件，只限這個網站。登入、驗證碼、Cloudflare 與其他防爬機制仍一律不繞過；不偽裝瀏覽器 User-Agent；只取單一 `.srt`，不下載也不解壓壓縮檔。
- 第 13 節的 API 版（`AssrtProvider`，需要 token）保留。

### 17.2 查證（站台在此環境連不上）

- 依據為讀過的開源擷取程式與搜尋引擎收錄的網址，沒有實測：TVBox `SubtitleViewModel.java`（`kukuqi666/TVBoxOS-Mobile` `6aabea8965a45df9a126d0436404ae8afccfe96f`）、tokimo `assrt.rs`（`d29fb883782ed10f685d74a189f48b756b624157`）、ShootingCodeTalker（`6a5df6fd915634764e17e7b556125e137eb1ec15`）、scrapy_l（`a6161f04b06a8dbef0fa854fab261a69b490de7e`）、jun9100 moviepilot-subtitle-agent（`8fdd1c78c80b8ee07b0fecbc3a078f7a253be2b7`）等，加上官方 API 文件剪存（`PingWangWang/SubQuick` `0b77ff4e…`）。完整規格（含信心等級與未決項）由 workflow 整理。
- 結構：
  1. 搜尋 `GET /sub/?searchword=<q>&sort=rank&no_redir=1`；結果是 `/xml/sub/<桶>/<id>.xml` 的連結（桶號一律從連結讀，不自己算）。
  2. 詳情頁以 `onthefly("<id>","<part>","<檔名>")` 列出上傳（多半是壓縮檔）裡的每個檔案，對應網站的 `/download/<id>/-/<part>/<檔名>`，下載到的是解壓後的單一檔案；單檔上傳則是 `/download/<id>/<檔名>`。
  3. 網站錯誤頁 `/errpage/…`（擷取程式看到的 HTTP 493）、登入頁 `/user/…`、`/usercp.php`。
- 最大的未決項：沒有任何擷取程式在 `2.assrt.net` 上用過 `/download/<id>/-/<part>/<檔名>`（多用 `secure.assrt.net`、`assrt.net`），轉址目標也沒有紀錄。若真機上 2.assrt.net 不接受這個路徑，改主機需要再問使用者。

### 17.3 實作

- `AssrtWebProvider.swift`（新，`id = assrt-web`，名稱「射手網（網頁）」，不需要 key）：
  1. 搜尋頁只讀第一頁；每個 id 一筆，標題取卡片的發布名稱或連結標題；卡片寫明 SubRip（或打包連結是 `.srt`）與沒寫格式的優先開啟，只寫其他格式的最後開；最多開 5 個詳情頁、同時 2 個，搜尋頁作為詳情頁的 Referer。
  2. 詳情頁：逐個 `onclick` 比對 `onthefly`（檔名取到最後一個引號，處理 `\\ \" \' \/`），id 必須與頁面相同，只留 `.srt`；檔名已百分比編碼就沿用，否則依 `encodeURIComponent` 規則編碼。沒有 `onthefly` 時取單檔 `.srt` 連結。只有壓縮檔或沒有 `.srt` 時回空結果（不是錯誤）；完全沒有下載連結時回報頁面無法解析，避免改版被當成「找不到字幕」。
  3. 語言以檔名為準；卡片只標一種語言時才補上。
  4. 頁面與連結只接受 `https` 的 `2.assrt.net`、`assrt.net`、`secure.assrt.net`；下載最終位址另接受文件記載為 http 的 `file<N>.assrt.net`，內容仍須通過 SubRip 驗證。下載以詳情頁為 Referer，每次從網站連結重新取得（不保存有時效的轉址）。
  5. 驗證頁 → `blockedByChallenge`；錯誤頁 → `rejected(493)`；登入頁 → `blockedByChallenge`；都不重試、不繞過。
- 來源順序：Subtitle Cat、射手網（網頁）、OpenSubtitles、射手網（API）。字幕面板選射手網任一來源時標示「字幕服務由 assrt.net 提供」。

### 17.4 測試與驗證

- `AssrtWebProviderTests`（10 項，fixture 全為依規格重建，未經實站擷取）：搜尋網址編碼、結果辨識與開啟順序、壓縮檔逐檔連結與編碼、單檔上傳與卡片語言、壓縮檔無 SRT 與頁面無下載連結、驗證頁／錯誤頁／登入頁、下載主機限制、完整搜尋流程（Referer）、站台直接開啟單一結果、驗證頁立即停止。突變檢查五項（拿掉 `.srt` 過濾、拿掉 id 檢查、拿掉開啟順序、下載主機全開、拿掉錯誤頁判斷）都讓測試失敗（已還原）。
- Linux swiftlang 6.0.3 `swift test` 243 項，242 通過（既有 CP1251 項目除外）。App 只改說明文字，未在 macOS 編譯。
- 真機待驗（必要）：用一個常見片名搜尋，確認搜尋頁、詳情頁與一個逐檔下載實際可用；若下載回錯誤頁或 493，記錄狀態碼後回報。
- Rollback：revert 本 commit。

### 17.5 IOS-POC-45G-1：審查修正

45G 提交後的審查找出 12 項問題，除「扁平版面的卡片判斷」（只影響卡片提示資訊，不影響能否下載）記錄不做外，其餘都修：

1. 詳情頁遇到驗證頁、限流或錯誤頁後不再排入其他詳情頁（已送出的那一頁照常完成）。
2. 落在錯誤頁或登入頁的判斷移進單次請求內：即使伴隨 5xx 也只請求一次，不重試。
3. 卡片取「只含單一 id、且帶有欄位或 `meta_top` 的最低祖先」，沒有才取最高；單一結果時不再把整頁當成卡片。
4. 卡片欄位逐元素讀取，最後一個欄位不再吃進後面的「下载」按鈕文字（`语言：简` 不會變成 `简 下载`）。
5. 詳情頁網址小寫化作為唯一形式；標題取同 id 任一連結的 `title` 或文字，都沒有時顯示 `#<id>`。
6. 卡片的打包連結只認 `/download/<同一 id>/`。
7. 詳情頁只把同一 id 的 `onthefly` 或下載連結算作下載參考；只有其他上傳的連結時回報頁面無法解析。
8. 由上傳者決定的檔名：含 `.`／`..` 層級、query 或 fragment 的連結一律捨棄（`%2E%2E` 也擋）；已編碼檔名中的 `#`、`?` 等改為編碼；逐檔連結的編號必須至少為 1。
9. 檔名中的中文語言詞（繁体、简体、英文等）優先於卡片語言，與 `AssrtProvider` 一致。
10. 正規表示式預先編譯。

測試與驗證：

- `AssrtWebProviderTests` 新增 6 項（共 16 項），另在既有搜尋結果測試補上 `语言：简` 的檢查：單一結果的卡片範圍、其他上傳的打包連結、其他上傳的下載參考、上傳者檔名的路徑與語言、詳情頁被擋後不再開啟、錯誤頁只請求一次。fixture 仍為依規格重建，未經實站擷取。
- 突變檢查十項（拿掉停止旗標、錯誤頁判斷移出請求、拿掉打包連結 id 檢查、先設下載參考再比對 id、`staysOnPath` 全放行、卡片改取最高祖先、欄位改讀整張卡片、網址不小寫化、拿掉中文語言詞、已編碼檔名原樣保留）都讓對應測試失敗（已還原）。
- Linux swiftlang 6.0.3 `swift test` 254 項，253 通過（既有 CP1251 項目除外）。
- 真機待驗與 17.4 相同。Rollback：revert 本 commit。

## 18. IOS-POC-45F：有些影片選不出 CC 字幕

### 18.1 查證結論（workflow，四個方向各附反駁）

- 沒有找到 App 把字幕軌弄丟的路徑：0.1.53 不改寫、不代理播放清單（智慧去廣只 seek），兩個引擎回報的字幕軌都會列在面板上。
- 較可能的原因：
  1. 影片本身沒有軟字幕（燒錄在畫面、HLS master 沒宣告字幕、來源直接給 media playlist）。
  2. AVPlayer 不列出串流裡沒有宣告的 CEA-608 隱藏式字幕（推測的平台行為，沒有文件證實）；同一個串流在 MPV 可能讀得到（FFmpeg 從 SEI 取出、mpv 收到資料才建立 `eia_608` 軌）。
  3. CC 軌其實在，但標示不清：AVPlayer 的 CC 選項只顯示語言，和同語言字幕一模一樣；MPV 顯示成「字幕 N · EIA_608」。
  4. 少數格式（`dvb_teletext`、`arib_caption`）在 MPVKit 的 FFmpeg 沒有解碼器，選了會跳回「關閉」，沒有任何提示。
  5. 來源播放回應裡的 `subs` 欄位 iOS 版沒有讀取（Android 會當成外掛字幕）：這是新功能，需要使用者核准，本階段不做。
- 不建議 `sub-create-cc-track=yes`：mpv 建立的 CC 軌帶 default 旗標，可能在載入時被自動選中，蓋掉原本會顯示的內嵌字幕。

### 18.2 實作

- `PlaybackSubtitleRole`（一般、CC、SDH、強制）：AVPlayer 依 `mediaType == .closedCaption`、`containsOnlyForcedSubtitles`、`transcribesSpokenDialogForAccessibility` 加 `describesMusicAndSoundForAccessibility` 判斷；任一引擎的 `eia_608`／`c608` 等格式自動視為 CC，格式名稱顯示為「CC」。標籤附在名稱後（「English · CC」）；一般字幕的名稱不變。
- `dvb_teletext`、`arib_caption` 標示「不支援」，不隱藏。MPV 在使用者選擇後 3 秒內把字幕關回 `no` 時記錄 `[subtitle] mpv dropped the chosen subtitle id= codec=`。
- 面板：沒有內嵌字幕時顯示說明（不寫「沒有字幕」）。AVPlayer 下另有「改用 MPV 讀取內嵌字幕」按鈕（沿用既有的切換引擎）；MPV 下說明 CC 可能在播放後才出現（`SubtitleEmptyState`）。
- 診斷：兩個引擎的字幕清單變動時各記一行 `[subtitle] engine= list=ok|nil|empty|error:<domain>#<code> options= cc= sdh= forced= unsupported= codecs=`（`SubtitleTrackSummary`，不含標題、語言名稱、網址）；AVPlayer 載入字幕群組失敗不再被 `try?` 吞掉。

### 18.3 測試與驗證

- `SubtitleTrackLabelTests`（5 項）：CC 標示（兩個引擎）、SDH／強制／不支援、一般字幕名稱不變（回歸）、空清單的面板說明、診斷行只含計數。Linux swiftlang 6.0.3 `swift test` 248 項，247 通過（既有 CP1251 項目除外）。App target 未在 macOS 編譯。
- 真機待驗：找一部「選不出 CC」的影片，看面板說明與按鈕、切到 MPV 後是否出現「CC」列，並回傳 `[subtitle] engine=` 那幾行紀錄。
- 待使用者決定：讀取來源回應的 `subs`（外掛字幕）。
- Rollback：revert 本 commit。

## 19. IOS-POC-45H：片源自帶字幕（playerContent `subs`）

### 19.1 需求與授權

- 使用者 2026-10-03 回覆「影片來源自帶的字幕 要做」，核准 18.1 第 5 點記錄的功能：讀取來源播放回應的 `subs`，在 iOS 當成外掛字幕顯示。
- 完成條件：來源回應附的字幕出現在 iOS 字幕清單，AVPlayer（畫面疊字）與 MPV 都能選用；預設字幕的選擇規則對齊 Android 上游；不影響既有線上字幕、時間軸校正、廣告時鐘與內嵌字幕。

### 19.2 查證（workflow，Android／iOS／上游三路加完整性檢查，2026-10-03）

| 來源 | 版本 | 等級 | 結論與影響 |
|---|---|---|---|
| WebHTV Android `bean/Sub.java`、`bean/Result.java`、`player/exo/ExoUtil.java`、`PlayerManager.java` | 1d46bc927ecb2708af4546c27eec8d3866882526 | 本地主要程式碼 | 欄位 `url`、`name`、`lang`、`format`（MIME 字串）、`flag`（Media3 選擇旗標：1 預設、2 強制、4 自動選）；`flag` 0 視為預設；Exo 用影片的 header 下載；mpv 用 `sub-add <uri> auto`（不選取）；`subs` 型別錯誤會讓整個播放結果失效；沒有網址協定、大小、內容檢查；名稱依繁簡設定轉換。 |
| FongMi/TV `player/media/MediaItemFactory.java:78-134`、`player/track/LangUtil.java` | c616c0aa3613e87529791587a9f71b78c278c991 | 上游主要程式碼 | 較新的預設規則：只有一筆時依自身旗標；多筆且有人帶旗標時，帶旗標者照舊、其餘改自動選；多筆且都沒旗標時，`lang` 與系統語言最接近者為預設（同字 400、同書寫系統 300、`zh` 200、另一書寫系統 100），都不符時第一筆；mpv 選第一個預設或強制字幕；缺 `format` 時依副檔名推斷（fe6a5b235477c02633cf3bc50d4cd83414a521b4，2026-08-27）。 |
| FongMi/CatVodSpider `bean/Sub.java`、`spider/WebDAV.java`、`Push.java`、`Local.java` | db4cf26356fa59d1331769f11cbbfb2a779227e6 | 上游主要程式碼 | 爬蟲只輸出 `application/x-subrip`、`text/x-ssa`、`text/vtt`；網址有 http(s)、`file://`、`proxy://`（WebDAV，依賴本機代理）。 |
| takagen99/Box `PlayActivity.java`、`SubtitleLoader.java` | 258a5fef61578869ae905ca230bdde9e99fc19a8 | 相關專案程式碼 | TVBox 系另讀單一網址 `subt`；下載時偵測字元集；依內容嘗試 SRT、ASS。WebHTV Android 與 FongMi 都不讀 `subt`。 |
| mpv `demux/demux_lavf.c`、`DOCS/man/options.rst`（`--sub-codepage`） | 413ff0b1cd4585294803308a1a14be2fad30cede | 官方文件與程式碼 | 依內容判斷格式；字元集依 BOM、UTF-8、uchardet。支持「依內容判斷，不信任 `format`」。 |
| FongMi/TV issue #85（SRT 亂碼） | 2023-05-19 | 次級 | 非 UTF-8 字幕是實際問題。 |
| iOS 現況：`SourceClient.swift` `SpiderPlayResponse`、`CMSClient.swift` `PlayResponse`、`SubtitleDownload.swift`、`SubtitleSessionCache.swift`、`OnlineSubtitleSession.swift`、`PlaybackEngine.swift` `PlayerRouter`、`WebHTVApp.swift` `PlaybackSession` | 1d46bc92 | 本地主要程式碼 | `subs` 被 `JSONDecoder` 靜默丟棄；13 個內建爬蟲都不輸出 `subs`（下載的 drpy／JS／Python 爬蟲可能輸出）；外掛字幕管線只收 SubRip（ASS 會因沒有 cue 被拒）；檔案以 `online-subtitle-<n>` 交給路由器，時間軸校正與廣告時鐘自動適用；iOS 沒有本機代理，`proxy://`、`127.0.0.1:9978` 無法使用；`catvod.result` ABI 會因新增解碼欄位而改變。 |

未取得：CatVodTVOfficial 規格倉庫（404 或私有）、drpy-node（私有）。現行規格以上游程式碼為準。

### 19.3 方案比較

| 方案 | 內容 | 優點 | 缺點 |
|---|---|---|---|
| 不做 | 維持丟棄 `subs` | 零風險 | 帶字幕的來源在 iOS 沒有字幕，與 Android 不一致 |
| 照搬上游 | 遠端網址直接 `sub-add`；AVPlayer 不支援 | 改動小 | AVPlayer 無法顯示；遠端網址交給 mpv 不經大小、內容與主機檢查；ASS 字型會繞過內建字型（45D 的方格與掉幀風險） |
| WebHTV 調整版（建議） | 解碼後經既有下載管線（大小上限、HTML 拒絕、編碼）下載到本次播放的暫存資料夾，再交給兩個引擎 | 兩個引擎一致；沿用時間軸校正、廣告時鐘、清理機制與內建字型 | 每筆字幕在開播後多一次請求；ASS 樣式不保留 |

### 19.4 決定（WebHTV 調整版）

1. **解碼**：`SpiderPlayResponse` 與 type-4 `?play=` 的 `PlayResponse` 讀 `subs`，逐筆容錯（一筆壞掉只略過那一筆，`subs` 型別錯誤視為沒有字幕，不再像 Android 讓整個播放失敗）。`catvod.result` ABI 1.0 → 1.1，新增凍結指紋列；指紋來源加入新檔 `SourceSubtitles.swift`，避免解碼欄位逃過檢查。不讀 `subt`（與 Android、FongMi 一致）。
2. **攜帶**：`PlaybackTarget.subtitles`；`PlaybackSession` 在 `open` 時保存、`open(vod)` 清空；預取的下一集自動帶上。
3. **網址**：只接受 http／https，拒絕 loopback（`localhost`、`127.0.0.0/8`、`::1`、`0.0.0.0`）；`file://`、`proxy://`、相對路徑略過並記錄數量。每支影片最多處理 8 筆。
4. **Header**：與影片同主機時轉送全部 header（`Range`、`Host`、`Content-Length`、`Connection`、`Accept-Encoding`、`Accept` 除外）；不同主機只送 `User-Agent` 與 `Referer`，避免 Cookie、Authorization 外流。轉址後的 header 行為與影片本身相同（URLSession 預設），列為已知限制。
5. **格式**：不信任 `format`，依內容判斷：開頭 `WEBVTT` 為 WebVTT；含 `[Events]` 與 `Dialogue:` 為 ASS／SSA；其餘為 SubRip。WebVTT 與 ASS 轉成 SubRip 儲存（樣式與位置不保留，ASS 繪圖行略過、同時間同文字的多層合併），所以 MPV 一律用內建字型。此判斷放在共用驗證，線上來源若拿到內容其實是 WebVTT／ASS 的檔案也會轉換（原本 ASS 會被拒）。
6. **編碼**：沿用 BOM、UTF-8、依語言的舊編碼；片源字幕語言不明時以中文（GB18030、Big5）解碼，不用 Windows-1252。
7. **預設字幕**：採 FongMi 上游較新的規則（見 19.2），語言比對用 `SubtitleLanguage` 判斷出的代碼與 `Locale.preferredLanguages.first`。WebHTV Android 仍是「每個旗標 0 都是預設」的舊規則，兩者衝突時採上游（較新、已處理多筆字幕），Android 端另列待同步。預設字幕先下載，其餘依序下載（一次一筆）。只在本支影片還沒有使用者自己選過字幕（面板選字幕或下載線上字幕）時自動選取，每支影片最多一次；內嵌字幕原本自動顯示時會被來源的預設字幕取代，與 Android 行為一致。
8. **名稱**：`<來源名稱>（片源）`，沒有名稱時 `<語言>（片源）`；面板顯示時照常轉繁體。
9. **生命週期**：同一支影片（畫質切換、重新載入、預取重試）只處理第一份非空清單；換集或關閉播放器時隨線上字幕一起刪除。自動載入不顯示「已套用線上字幕」通知，也不收起面板。
10. **紀錄**：只記筆數、語言、位元組與 cue 數，不記網址、檔名、header。
11. **廣告時鐘**：維持預設開啟（字幕對應節目本身，廣告是 CDN 插入的）；可用既有的「扣除廣告時間」開關關閉。

### 19.5 驗收標準

1. Linux 可執行的測試涵蓋：容錯解碼、預設規則（單筆、多筆有旗標、多筆無旗標依語言）、網址與主機限制、header 轉送規則、WebVTT／ASS 轉換、語言不明時的中文解碼、名稱、每支影片只處理一次、使用者選過就不自動選、與線上下載互不取消、結束時取消。
2. 既有測試全部維持通過（Linux 既有 CP1251 項目除外）。
3. ABI 指紋：以 Python 移植的 `canonical(.catvodResult)` 先重現 1.0 的指紋，再計算 1.1。
4. 真機待驗：用一個會回傳 `subs` 的來源確認兩個引擎都能顯示，並回傳 `[subtitle] source` 紀錄。

### 19.6 Rollback

revert 本 commit。ABI 1.1 尚未出貨前可整列移除；出貨後依規則只能新增。

## 20. SubtitleNexus 評估（番號字幕後續，只評估不實作）

使用者 2026-10-03 要求「確認 SubtitleNexus 能不能用」。workflow 三路查證（官方文件與條款、廠商外掛原始碼、未帶 key 的公開端點與社群資料）加兩個對抗式驗證，結論：**依目前證據不能用**，不實作。

| 依據 | 來源 | 等級 |
|---|---|---|
| 廠商所有用戶端（Kodi、IINA、Emby 等 5 個倉庫的完整歷史）只用 `GET https://api.subtitlenexus.com/v1/subtitle/search/?file_hash=…` 搜尋，雜湊是 OpenSubtitles 的檔案雜湊（檔案大小加頭尾各 64 KiB），沒有片名、番號或關鍵字搜尋 | github.com/subtitlenexus（Kodi `nexus_api.py:78-84`、IINA `nexus.lua:1400`） | 主要程式碼 |
| 廠商用戶端拒絕網路串流（IINA `nexus.lua:1814-1820` 'Live subtitles for URLs not supported'；Kodi `service.py:137-139` 略過 http(s)）；HLS 沒有單一檔案可算雜湊，轉檔或重新封裝的串流副本也不會與上傳檔案相同 | 同上 | 主要程式碼 |
| 驗證用使用者自己的 `X-API-Key`；每日免費額度用完回 HTTP 402，之後扣付費點數；免費下載可能是 10 分鐘試用（`is_demo`）；字幕為 AI 轉錄與翻譯 | 同上加 README | 主要程式碼與廠商說明 |
| 唯一的文字搜尋是一個第三方 CLI 使用、未記載的 `term` 參數，在網站主機的 `/api/v1`；該主機據報有 Cloudflare 驗證（依使用者規則不可繞過） | 第三方 CLI 原始碼與社群文章 | 次級 |
| 官方 API 文件、服務條款、隱私權政策都讀不到：`subtitlenexus.com`、`www.`、`api.` 從此環境一律 CONNECT 403 或 EGRESS_BLOCKED | 2026-10-03 實測 | 實測 |

條件式可行（不建議）：只有使用者自己讀過條款確認第三方 App 可用，並用自己的 key 在可連線的網路確認 `term=<番號>` 經廠商支援的端點回傳完整（非試用）中文 `.srt`、沒有驗證頁時，才值得當補充來源；HLS 與 FC2-PPV 仍無法期待命中。番號字幕目前仍以 Subtitle Cat 為主，另一條可行路是本機 `.srt` 匯入（尚未核准）。

### 19.7 IOS-POC-45H-1：審查修正

45H 提交後的 workflow 審查（四個面向，每項發現各一個對抗式驗證）確認 15 項（2 項中度，其餘低度，部分重複），全部修正。本節取代 19.4 第 3、4、5、7、9 點中對應的規則：

1. **預取重試的新清單（中度）**：原本同一支影片只收第一份清單；預取的清單若因簽名過期全部下載失敗，重試取得的新清單會被忽略。改為「有檔案成功下載後才鎖定」：之前沒有任何檔案成功時，後到的清單取代前一份（取消前一份的下載，以世代編號丟棄晚到的結果）。
2. **ASS 正規表示式可被惡意檔案拖垮（中度）**：拿掉 ASS 處理中的回溯型正規表示式，改為單次掃描去除 `{…}` 覆寫區塊並判斷繪圖（`\p1`…`\p9`），任意長度的覆寫區塊都會去除；超過 16 KB 的單行對白直接略過。
3. **預設字幕的旗標**：改為先在來源的完整清單上計算旗標（與上游相同），再排除抓不到的網址與超過 8 筆的部分。來源指定的預設字幕若是 `proxy://` 等抓不到的網址，不再改由其他字幕頂替，而是不自動顯示。
4. **ASS 判斷**：改為整份檔案中有一行就是 `[Events]` 才視為 ASS（Aegisub 會把內嵌字型放在前面，超過 64 KB）；判斷為 ASS 卻讀不到對白時退回 SubRip，原本能用的 SubRip 檔不會因內容剛好有 `[Events]`、`Dialogue:` 字樣而被拒。
5. **WebVTT**：結束時間後以 tab 接 cue 設定的行不再遺失（SubRip 解析也因此接受 tab，只會更寬鬆）。
6. **登入資訊**：Cookie、Authorization 等只送給與影片同主機、同連接埠，且不會從 https 降為 http 的字幕網址；http 影片的字幕在同主機升級為 https 時照送。
7. **本機位址**：另擋結尾帶點（`localhost.`）、八進位（`0177.0.0.1`）、各種 IPv6 寫法的 `::1`、`::` 與指向 127/8 的 IPv4 映射位址；無法解析的 IPv6 字面值一律不抓。
8. **測試補強**：線上下載與片源字幕互不取消且線上下載算使用者選擇、重試清單取代失敗清單、抓不到的預設字幕不被頂替、本機位址各種寫法、降級與換埠不送登入資訊、內嵌字型的 ASS、含 `[Events]` 字樣的 SubRip、長覆寫區塊、大量 `{` 的效能、WebVTT tab。

未做：type-4 `?play=` 從 `CMSClient.playback` 到 `PlaybackTarget.subtitles` 的端對端測試（需要網路替身，現有 CMS 測試沒有這個機制）；目前只測解碼器。

驗證：
- 新增與修改的測試共 18 項（`SourceSubtitleTests`）；12 個突變（旗標改在過濾後計算、拿掉結尾點、八進位、IPv6 解析、連接埠、降級、後到清單、線上下載不算選擇、`[Events]` 只看前 64 KB、繪圖判斷、WebVTT tab、SubRip 退回）各自讓對應測試失敗（已還原）。
- Linux swiftlang 6.0.3 `swift test` 272 項，270 通過；未通過的 2 項是 Linux 缺少字元集轉換（CP1251 既有項目、GB18030 的 `aFileOfUnknownLanguageIsDecodedAsChinese`）。
- `catvod.result` 指紋不變（本次未改解碼欄位）。App 未改動。
- Rollback：revert 本 commit（回到 45H 的行為）。

### 18.4 IOS-POC-45F-1：編譯修正

- `0.1.54 (55)` 的 release 建置（run `37094163945`）是 45F 之後 App 的第一次 macOS 編譯，失敗於 `WebHTVApp.swift:4458`：`AVMediaCharacteristic` 沒有 `describesMusicAndSound`。正確名稱是 `describesMusicAndSoundForAccessibility`（與同一判斷式的 `transcribesSpokenDialogForAccessibility` 成對）。該次建置只有這一個錯誤。
- 修正後以重新觸發的 release 建置驗證。Rollback：revert 本 commit。


## 20. IOS-POC-45I：Web 播放頁字幕嗅探（8Movie 類來源）

### 20.1 需求與現況

- 使用者 2026-10-03 指定 `https://8movie.com/play/16178/`，要求由 WebHTV 開發把網站播放器的字幕導入 App，而不是再產生給其他 agent 的提示詞。
- 45H 已完成 CatVod `playerContent.subs` → `PlaybackTarget.subtitles` → Session 暫存 → AVPlayer／MPV 的後半段；本次只補「來源沒有輸出 `subs`、而字幕藏在 Web 播放頁」的前半段。
- 修改前 `SourceClient.target` 的 `parse:1` 路徑只取 `MediaSniffer.sniff() -> URL`；`MediaSniffer` 在第一個影片 URL 出現時立刻銷毀 WKWebView，因此頁面即使另有 `<track>`、VTT/SRT/ASS request，也全部丟失。
- 本 session 無法直接開啟 8Movie 的實際播放頁與 Network，因此不假定該站一定是軟字幕；若字幕已燒錄進影片像素，本功能不會假裝能抽出字幕檔。

### 20.2 規格與方案查證（2026-10-03）

- WHATWG HTML Standard `track`：外掛 timed-text 的標準欄位就是 `src`、`srclang`、`label`、`kind`、`default`；`subtitles`／`captions` 是可顯示文字軌，`metadata`／`chapters` 不是字幕。來源：https://html.spec.whatwg.org/multipage/media.html
- Apple HLS Authoring Specification / RFC 8216：HLS master 以 `#EXT-X-MEDIA:TYPE=SUBTITLES` 宣告字幕 rendition；Apple HLS 的字幕為 WebVTT 或 IMSC1。來源：https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices 、https://www.rfc-editor.org/rfc/rfc8216.html
- WebHTV 現況：若 sniffer 拿到的是 HLS master，AVPlayer／MPV 本來就會把 `EXT-X-MEDIA` 當內嵌字幕軌，不應再下載、重組 master；本次只捕捉「master 之外的 out-of-band 字幕」。
- Android `Sniffer.java` 只找影片 URL，沒有字幕 contract；直接照搬 Android 不能解決需求。

### 20.3 採用設計

1. 新增 `MediaSniffResult(mediaURL, subtitles)` 與 `SniffedSubtitle`。舊 `sniff()` API 保留第一個 media match 就回傳，不增加 source-health 等既有路徑延遲。
2. 新增 `sniffWithSubtitles()`：找到影片後只多保留 WKWebView **250 ms**，收集同一播放頁的外掛字幕，再回傳；取消、換來源時仍沿用「newest wins」。
3. JS hook：
   - 掃描／監看 `<track>`，只收 `subtitles`／`captions`，保存 `label`、`srclang`、`default`。
   - XHR／fetch 若直接請求 `.vtt/.srt/.ass/.ssa`，也收為候選；無法從 request 單獨知道語言時留空，讓既有內容／檔名判斷處理。
   - `metadata`／`chapters` track 不加入字幕清單。
   - 同 URL 重複出現時合併資訊；例如先被 fetch 看見、稍後 `<track>` 才提供語言與 label，會補齊而不建立兩筆。
4. `SourceClient` 的 `parse:1` 與「probe 後確認是 page」兩條路都使用 subtitle-aware sniff，再用既有 `SourceSubtitles` 管線下載、格式驗證／VTT/ASS 轉 SRT、Session 清理、AVPlayer overlay、MPV `sub-add`。
5. 明確的 CatVod `subs` 優先於網頁嗅探：同 URL 時保留來源明確提供的 metadata。網頁嗅探字幕只有 `<track default>` 才設 flag 1；其他設 flag 4（autoselect-only），避免僅因抓到一個 VTT 就蓋掉原本內嵌字幕。
6. HLS master 不拆解成 `SourceSubtitle`：維持交給兩個播放器原生解析，避免把 subtitle media-playlist URL 當單一 SRT/VTT 下載。

### 20.4 範圍、風險與驗收

- Branch：`ios-poc-45i-web-sniffed-subtitles`，base `c7fdda2ee5a7dd84ef58241af6fcea520b7c8c7a`。
- 修改：`MediaSniffer.swift`、`SourceClient.swift`、`SourceSubtitles.swift`、兩個既有測試檔、本文件；不動播放器核心、版本、SideStore source、release workflow。
- 新測試覆蓋：靜態 `<track>` metadata、影片後延遲出現的 SRT request、只有字幕 request 不可被當影片、同 URL metadata upgrade、metadata track 排除、與 CatVod `subs` 去重、非 default 網頁字幕不自動搶選。
- 已知限制：Worker/WASM 內取得且沒有 DOM `<track>`、也沒有主頁 XHR/fetch 的字幕仍無法被 WKWebView JS hook 看見；無副檔名且沒有 `<track>` 語意的自訂字幕 request 也不猜。
- 真機必要驗收：8Movie `/play/16178/<episode>/` 實播，看字幕 panel 是否出現「片源」字幕；若完全沒有 soft track/resource，確認畫面文字是否為燒錄硬字幕。
- Ponytail：本 runtime skill 清單沒有 Ponytail，依 repo 規則記為 unavailable / skipped。
- Task guard：本 runtime 只有 GitHub connector、沒有 repository shell/worktree，無法執行 `.codex/scripts/task_guard.sh`；以從乾淨遠端 HEAD 建立隔離 branch、單一原子 tree commit、只改上述 scoped paths 代替，未觸碰 `ios-poc`。
- Rollback：刪除 task branch，或合併後 `git revert` 本功能 commit；沒有資料遷移與永久快取。
