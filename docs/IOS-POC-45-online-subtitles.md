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
6. **字幕同步**：HLS 廣告切除或片頭偏移時，外掛字幕可能整體偏移（`docs/IOS-POC-26-engine-switch-position.md` 的 H1 已記錄過同類現象）；本任務不提供時間軸微調。

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
