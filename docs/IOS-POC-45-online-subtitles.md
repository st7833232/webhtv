# IOS-POC-45 — 線上字幕搜尋、下載、套用與 Session 暫存

## Recovery anchor

- 目標：使用者 2026-10-02 要求（同一則訊息即授權實作，「不要每一步停下來詢問確認」）：播放中從字幕 panel 編輯搜尋文字、向 Subtitle Cat 搜尋、看到現成字幕、點選一個 direct SRT、以 URLSession 下載到該 playback session 的暫存目錄、加入既有字幕系統並立即在 AVPlayer／MPV 顯示；離開真正的播放 session 後清除；任何 Provider 失敗不影響播放。
- 範圍：task guard `IOS-POC-45`（`standard`），路徑 `ios/Sources/WebHTVCore`、`ios/Tests/WebHTVCoreTests`、`ios/WebHTVApp/Sources`、本文件、`docs/current-task-state.md`、`README.md`。不動 `project.pbxproj`、版號、release workflow、MPVKit、lock、patch。
- 與既有計畫的關係：`docs/IOS-POC-17-dual-internal-player.md` 第十四節 P4（MPV 外掛字幕）原本「沒有指示不開始」；本任務的 MPV `sub-add` 是使用者這次明確要求的範圍，只做「掛載本機已下載的 SRT」，不做 P4 的 ASS 樣式／來源字幕網址。
- 狀態：實作完成；Core 測試在 Linux Swift 6.0.3 通過；macOS CI 驗證結果見第 9 節。
- 唯一下一步：真機驗證第 10 節列出的項目（CJK 字型、PiP、鍵盤遮擋）。

## 1. 需求摘要

1. Provider 架構：`SubtitleProvider` 協定、共用模型（查詢、結果、下載、Session 暫存、錯誤）；第一個 Provider 是 Subtitle Cat，預留 OpenSubtitles／SubDL，但不假裝已可用。
2. 搜尋文字：自動辨識只負責預填與候選 chip，欄位永遠可全部刪除、自由輸入；送出的就是欄位文字。
3. Subtitle Cat：`https://www.subtitlecat.com/index.php?search=<URL encoded>` 的 HTTP GET → 解析結果頁連結 → GET 結果頁 → 只取已存在的 direct `.srt`；不用 WebView／JS，不觸發、不模擬 Translate。
4. 排序：zh-TW → zh-CN → ja → en → 其他（Provider 原順序）；語言先看頁面 label，再看 metadata，最後看檔名。
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

（CI 結果填在這裡。）

### 9.3 Live smoke test

未執行。雲端 session 的 egress proxy 拒絕 `www.subtitlecat.com`（`curl` 與 WebFetch 都是 `403 connect_rejected`，2026-10-02 10:10 UTC），所以 `FC2PPV-4159457` 的搜尋頁、結果頁與 direct `.srt` 都沒有實際取得或驗證。fixture 依已知版面重建，並刻意變化寫法；需要在能連線的環境用 App 實測一次（第 10 節）。

### 9.4 Ponytail

`ponytail:ponytail-review` 不在本 session 的可用 skill 清單：Ponytail: unavailable / skipped。改以多面向對抗式 review（見 9.5）。

## 10. 尚待真機或連網驗證

（CI 後填寫。）
