# IOS-UI-A — Cinematic Minimal

## 狀態總覽與 Recovery anchor（2026-10-05 補記）

本文件各段由不同 session 依時間插入，順序是 A3、A2、第一版 theme trial、A4。對照如下：

| 階段 | 內容 | 程式 commit | 版本 | Release run | 段落 |
|---|---|---|---|---|---|
| A1 | 第一版 theme trial：只改背景、色彩、圓角、material | `d759a346` | `0.1.61 (62)` | `37199969137` | 「Historical first theme trial」 |
| A2 | 首頁、詳情、片庫、搜尋、下載、設定、底部列的結構重構 | `c361c637` | `0.1.62 (63)` | `37202892439` | 「A2 structure redesign」 |
| A3 | 0.1.62 真機回報修正：底部遮擋、返回手勢、鍵盤、片庫順序、深／淺主題、空白搜尋 | `f916df55`、`353879d4`（compile 修正） | `0.1.63 (64)` | `37206772558`（`37205918063` 編譯失敗、未發布） | 「A3」 |
| A4 | 首頁子分類與篩選預設收合 | `033d4336` | `0.1.64 (65)` | `37209250026` | 「A4」 |

- 各版發布證據（tag、IPA 大小、SHA-256、source commit）集中在 `docs/IOS-POC-11-sidestore-release.md` 檔頭。
- 之後 `0.1.65 (66)`（IOS-POC-51）在 A4 之上發布，沒有 UI-A 的改動。
- 已驗證：A1～A4 都由 SideStore Release workflow 完成 unsigned device Release build、IPA／schema 驗證、公開下載比對。沒有 Simulator 或真機 rendering。
- A1～A4 用的一次性 push 觸發（`f103ab5b`）已於 2026-10-05 移除（`IOS-RELEASE-TRIGGER-REMOVE`），預設 release notes 還原；之後發布用 `workflow_dispatch`，見 IOS-POC-11 檔頭「0.1.61 (62)」一節。
- 唯一下一步：SideStore 真機驗收，項目見 A2、A3、A4 各段的 Recovery anchor。

## A3 — 0.1.62 真機回報修正（2026-10-04）

基準：重新 fetch 的 `origin/ios-poc`，`c3cc8c5600b4bb70368fd1ea161d2dc16190f964`。使用者提供實際畫面及八項操作問題；沿用同一份 A 版任務文件。範圍僅 View／主題偏好、發布 metadata 與交接文件；播放器、來源、收藏／歷史、下載的 domain ownership 與 identity 不變。

| 真機問題／要求 | 程式／layout 定位（runtime 待真機驗證） | 修正與驗收 |
| --- | --- | --- |
| 底部無法完整滑到；回頂端按鈕被蓋住 | safeAreaInset 位於 TabView 外層；截圖顯示 scroll 內容延伸到 bar 後方，推測 inset 沒有可靠傳到內層 | TabView 與自訂 bar 改成 VStack 兄弟，內容框實際縮短；末列與浮動按鈕須完整露出 |
| 多層右滑返回失效 | VodView 隱藏原生 navigation bar／back button，使用自訂 dismiss header | 恢復原生返回與 toolbar heart，讓系統管理互動返回；不替換 gesture delegate |
| 片庫預設／順序 | UI 直接使用 core LibrarySection.initial／allCases（收藏優先） | 只在 UI 改成記錄優先、順序記錄／收藏；不改 store 或 core enum |
| 搜尋 focus／鍵盤收不起來 | 搜尋框只在 submit 放 focus；空白時 submit 被 disabled | 可見收鍵盤按鈕、keyboard 完成、空白背景 dismissal、scroll immediate dismissal；清除／離開也解除 focus |
| 缺主題設定 | WindowGroup 強制 dark，內容與 surface 部分寫死 white | 原生設定新增深色／淺色，AppStorage 持久保存，預設深色；semantic labels／動態 surface；播放器維持純黑 |
| 重點分頁行為 | 按鈕僅重設相同 selection，沒有事件 | 重點首頁送 ScrollViewReader 回頂端事件；重點片庫／設定呼叫目前最上層 SwiftUI dismiss，一次只回一層 |
| 空白搜尋使 Hero 消失 | onSubmit 無條件 searching=true，load 卻把空字串當 browse | 提交先 trim；空白走返回來源片單且 searching=false；非空才 search |

設計選擇：保留 A 版與原生 TabView 的各分頁生命週期。相較不修（持續遮擋），或全改 value routing／重建各 stack（擴大導航 scope），採狹義 UI 修正：固定底部 layout、系統 back、每個 native 頁面註冊其公開 SwiftUI dismiss。主題採公開 AppStorage／preferredColorScheme／動態 UIKit 色彩；不新增依賴，不更動 engine、網路、ABI、來源或資料模型。Apple 官方文件：preferredColorScheme、EnvironmentValues.dismiss、AppStorage、scrollDismissesKeyboard（2026-10-04，原始官方來源；實際文件擷取記錄在 scratch）。沒有 upstream 合併／效能／binary／研究論文問題，相關證據類別不適用。

執行計畫（直接執行授權沿用本 session）：
- [x] 修正 ConfigView bottom layout、重點 tab 事件與原生返回。
- [x] 修正搜尋 focus／空白提交、片庫順序與深淺主題。
- [x] 一次必要 Swift syntax／domain 保留比對、final Ponytail／read-only review；不另跑測試 CI。
- [x] 再 fetch 安全整合，依最新 Releases 決定新版本，沿既有 SideStore workflow 建置與發布。
- [x] 核對公開 IPA／source.json，寫回實際 commit／run／asset 證據。

限制：Linux 無 Simulator／SwiftUI rendering；使用者截圖是失敗重現證據，程式檢查與 Release device build 不能取代 SideStore 手勢／focus／layout／淺色真機驗收。回退：在最新 ios-poc revert 本次 presentation commit，發布更高版本；不移動舊 tag／清除資料。

官方證據 URLs：[preferredColorScheme](https://developer.apple.com/documentation/swiftui/view/preferredcolorscheme(_:))、[dismiss](https://developer.apple.com/documentation/swiftui/environmentvalues/dismiss)、[AppStorage](https://developer.apple.com/documentation/swiftui/appstorage)、[scrollDismissesKeyboard](https://developer.apple.com/documentation/swiftui/view/scrolldismisseskeyboard(_:))。實際 Markdown 全文已擷取／閱讀；dismiss 必須在目的頁自己的 environment 取得，故以每頁 ViewModifier 註冊與撤銷 action，不操作 UIKit delegate 或遷移 navigation identity。

程式證據：tree-sitter baseline／edited 均 0 syntax error；12 protected data／engine 宣告 byte-identical；PlayerView 僅增加 presentation 的 preferredColorScheme(.dark)，protected methods 全部未變。CMS load／loadMore 只有必要 UI generation guard，source client／API／資料 identity 不變。Review 修正：淺色的 unavailable badge 明確 white-on-black、FEATURED semantic label；SubtitleSourceSettingsView 加上原生 nav 與 dismiss 註冊。Home 重點只送 scroll event，不額外 pop；Library／Settings 才 pop 一層。

Final read-only review：所有四項 finding 已修正（Home 不額外 pop、badge／FEATURED 淺色對比、字幕設定 dismiss 註冊）；無剩餘 Critical／Important。Ponytail：Lean already. Ship. 不能由靜態檢查證明 UIKit／SwiftUI lifecycle timing、背景點擊或手勢像素行為，保留真機驗收。

首次 Release device compile（run 37205918063，code f916df556fa4035e1ffa4bbad4090ea3ab8cc491）失敗：兩處 `selected ? .primary : .primary.opacity(...)` 被推斷成 HierarchicalShapeStyle 與 opaque ShapeStyle 不相容。已依實際 Xcode logs 將兩個分支都明確寫成 Color.primary；沒有擴大 UI 或 domain 行為。原有 WebHome/PythonBoot 的 actor／async warning 不屬此修改，保留未改。第一次沒有建立 Release／tag／IPA 或更新 source；latest 仍 0.1.62 (63)，新 candidate 0.1.63 (64) tag 不存在。

局部編譯修正驗證：整份 Swift diff 精確等於兩個 Color.primary 型別更正；parse 0 error；read-only review 無問題；final Ponytail：Lean already. Ship. 實際 device build 仍待重建通過。

### A3 publication evidence

已發布 **0.1.63 (64)**（2026-10-04 21:53，Asia/Taipei）：成功 run [37206772558](https://github.com/st7833232/webhtv/actions/runs/37206772558)，全部 steps success（unsigned device Release build、IPA／schema validation、公開下載 byte comparison、source publish）。tag `ios-v0.1.63-b64` → IPA code commit `353879d4b2a72503fc3ee2b087f4ee34c37804bc`；source update commit `257f3f77f5a7ad45a7b92d2e8f08c2e2fa060f10`。asset `WebHTV-0.1.63-64.ipa` uploaded，35,076,199 bytes，SHA-256 `f714ae171121051746ba520c46317600e14d45eabbdbbd4a09140eb4fbcbde1b`。已從 immutable source commit 核對 versions[0] 0.1.63，downloadURL／size 與 Release 相同，bundle `com.webhtv.ios.poc`／source identifier `com.webhtv.sidestore.source` 未改。

Runtime 與 compile 明確區分：第二次 actual iOS device build 已通過；first failed run 未發布任何 asset／tag，後續只是兩行型別修正的必要重建。無另跑測試 CI，無 Core／backend／engine／download queue 更改。本機及 GitHub code trees 逐 blob／整樹核對相同；每次 force=false 更新前確認最新 origin/ios-poc，未覆蓋 concurrent session。

Recovery anchor：IOS-UI-A3 開發／發布已完成；post-publication 文件 guard IOS-UI-A3-RELEASE-STATE，branch ios-ui-a3-final-state，base source commit 257f3f77f5a7ad45a7b92d2e8f08c2e2fa060f10，無 protected dirty paths。唯一下一步：SideStore 真機驗收（末列／回頂端按鈕、edge back、多層重點 tab、背景點擊與 keyboard、淺色完整畫面／主題持久性、既有播放與下載／收藏復原）。無 Simulator／真機新 rendering，不宣稱像素或手勢已驗收。

## A2 structure redesign — 2026-10-04

User explicitly authorized complete UI implementation and SideStore publication without intermediate approval or separate test CI. Fetched baseline: `1bf5d7ade62b7ba14e9f60b5bbfed7585004e67c`. Previous sections below describe the first theme trial, not this redesign's completion or release state.

References inspected: `WebHTV 五款 iOS 介面設計比較板.png`, column A, and SideStore screenshot `E21AEE54-6530-4DF3-BF44-3C43556B1FA9.jpeg`. The screenshot establishes Home's current pixels only; other pages are inventoried from actual source.

| Page | Current → A target | Views |
|---|---|---|
| Home | Large glass source / search drawer / uninterrupted posters → brand, small source control, custom thin search, category underline, Featured and source content sections, titles below 2:3 artwork | HomeView, CMSView, VodCard |
| Detail | Standalone poster / stacked metadata / distant CTA → immersive art header, quiet back/heart, title/facts/source, primary play CTA, complete metadata, grouped lines/episodes/downloads | VodView presentation subviews |
| Library | Toolbar segment and search → in-content heading/收藏/記錄, thin search, shared poster grid; history remains native continuation List | LibraryView, FavoritesView, FavoriteCard, HistoryView |
| Search | Native always-open drawer → explicit thin search, existing submit/stop/progress/source filters/grid/paging | AggregateSearchView |
| Downloads | Plain usage and state List → native dark management List, summary and counted state sections | OfflineDownloadsView, OfflineAssetRow, title management |
| Settings | Many native sections, inconsistent surface → inset-grouped dark rows, clearer spacing/headings, every existing option retained | SettingsView |
| Bottom bar | Oversized floating glass → full-width plain thin bar, safe-area reservation, original tags 0/3/1/4/2 | ConfigView, CinematicTabBar |
| Player | Pure black internal playback → preserve | No engine/session/control changes |

Design: content cinematic, tools native. Featured uses the actual first source item; source lists retain order. No invented ranking/update time/capability, no new recommendation backend. Thin TextField submits the existing search only; typing causes no request. Keep TabView and child NavigationStacks for state, hide the system tab bar through public toolbar visibility and reserve the new bar via safeAreaInset; no UIKit traversal or global legacy UI flag. Poster crop is decorative; details retain access to the whole poster. Dynamic Type/VoiceOver and 44pt touch targets are required. Dark default remains; new theme settings are outside scope.

All source identity/health/configuration, metadata/translation, favorites/completion/undo, history and deletion ownership, download queue/bulk/single/cellular behavior, AVPlayer/MPV/track/subtitle/speed/skip/PiP behavior remain unchanged. Only presentation code, version/release metadata and task docs are in scope.

Best-practice decision: no change cannot meet the target; material-only trial is contradicted by the real screenshot; choose narrow SwiftUI layout redesign. Local ConfigView owns tabs/source; VodView owns playback hooks; FavoriteLibrary, WatchHistoryStore and OfflineDownloads.manager remain data owners. Apple safeAreaInset/toolbar visibility docs were queried on 2026-10-04 (https://developer.apple.com/documentation/swiftui/view/toolbar(_:for:) and https://developer.apple.com/documentation/swiftui/view/safeareainset(edge:alignment:spacing:content:)-6gwby). No upstream/dependency/ABI change, so upstream commit/revert/benchmark/paper research is inapplicable. No claim of best-practice certification or device rendering is made.

Implementation plan (inline, user authorized):
- [x] Display primitives and thin fixed bar; Home source header/custom search/categories/Featured/content sections.
- [x] Detail header/CTA/episode presentation extracted into small subviews; preserve all actions and metadata.
- [x] Library Grid/List and explicit segment/search; aggregate search presentation; native download/settings surfaces.
- [x] Review scope, domain invariance, syntax if available; fetch latest ios-poc and safely integrate; choose new version from actual Releases/tags/source, commit atomically.
- [x] Publish via existing SideStore workflow; verify device build, IPA/schema/public-byte validation, Release asset and source.json; synchronize actual evidence.

Review focus: keyboard/safe areas, long source names and switching, empty/error/paging/search, favorite unavailable/undo, long metadata and episode download hit targets.

Environment: Linux Work has no swift/xcodebuild/iOS Simulator/iPhone. Code/layout inspection is distinct from the release workflow's actual device compilation. Do not claim SwiftUI screenshots or 1:1; SideStore must verify iOS 27 layout, keyboard, Dynamic Type, artwork, source switching, library, downloads and both engines/PiP.

Rollback: revert the task presentation change on latest ios-poc and publish a higher version; never move existing tags, overwrite concurrent work or migrate domain data.

Recovery: branch `ios-ui-a-restructure`, worktree `/workspace/scratch/59247bee57e7/webhtv-ui-a`, clean start, no protected dirty paths, guard IOS-UI-A2. Implementation and read-only review complete; Swift parse 0 errors, 13 protected declarations byte-identical, existing domain methods unchanged. Reviewer: no Critical/Important or material complexity findings. Latest ios-poc re-fetched unchanged; new release target 0.1.62 (63), tag absence verified. Published: program commit c361c637f9f2214370e7170c45be4dce6d0a0475, source commit d7a9e418c9a28d80c6891ec5697286fc83f57485; Release run 37202892439 success. Next action: SideStore device acceptance only. Latest Release verified on entry is 0.1.61 (62); resolve again before publishing.

### A2 publication evidence

已發布 `0.1.62 (63)`：2026-10-04 20:45（Asia/Taipei）。Release run [37202892439](https://github.com/st7833232/webhtv/actions/runs/37202892439) success，device Release build、IPA / SideStore schema、public Release URL byte comparison、source publish 全部 success。tag `ios-v0.1.62-b63` 指向 IPA 程式 commit `c361c637f9f2214370e7170c45be4dce6d0a0475`；workflow source commit `d7a9e418c9a28d80c6891ec5697286fc83f57485`。Release asset `WebHTV-0.1.62-63.ipa` uploaded，35,038,242 bytes，SHA-256 `355b690c71e525ed481bf223cefff3c33e87992e2befaf9ad23f21571d7bb35b`。source.json 第一筆 0.1.62，downloadURL／size 與 Release 相同，bundle `com.webhtv.ios.poc`／source identifier `com.webhtv.sidestore.source` 保持不變。

Only code/layout/static review and actual Release compilation/packaging are verified. No Simulator/real-device rendering or behavioral acceptance occurred in this Work session. Do not claim 1:1 to the design board.

---

## Historical first theme trial

Date: 2026-10-04
Branch: `ios-poc`
Release target: `0.1.60 (61)` — 實際以 `0.1.61 (62)` 發布：`0.1.60 (61)` 已先從 A 版之前的 HEAD 發布（IOS-POC-50），A 版改用 `0.1.61 (62)`（版號 commit `82d952e8`，tag `ios-v0.1.61-b62` → `9d81a75e`，run `37199969137`，IPA 34,956,830 bytes）。

## Goal

Apply the user's selected A visual direction to the existing WebHTV iOS product without changing playback, source, favourite, history, subtitle or offline-download behavior.

## Visual changes

- Replace the decorative global wallpaper with a near-black / midnight-blue cinematic gradient.
- Primary accent becomes a saturated iOS-like blue; the main `立即播放` CTA uses a white label.
- Navigation and tab bars use visible ultra-thin material to keep controls legible over content.
- Home/search poster cards keep the existing 2:3 content model but use 16pt rounding, a subtle stroke and depth shadow; the home grid gets slightly more breathing room.
- Detail poster grows from 240pt to 300pt, with 18pt rounding, stroke and depth shadow.
- Favourite poster cards follow the same visual language; a selected favourite heart remains pink as a distinct semantic state.
- History, downloads, source lists and Settings use a raised dark surface instead of flat or translucent black rows.
- Player layout and engine UI are deliberately not redesigned in this pass; its black low-distraction presentation remains intact.

## Non-goals

No changes to AVPlayer/MPV routing, playback controls, source parsing, favourite identity/storage, WatchHistory ownership, offline download queueing, subtitle behavior, download deletion rules or completion detection.

## Integration note

The first A trial commit lived on `ios-poc-ui-a-cinematic` from an older base. While the user was reviewing it, `ios-poc` advanced with IOS-POC-50 and the 0.1.60 (61) version bump. The visual patch was therefore reapplied to the current `ios-poc` rather than merging the stale file wholesale, preserving the concurrent-download changes.

## Verification / release policy

The user explicitly requested no separate CI run. Do not start the macOS verification workflow. The existing SideStore release workflow's unsigned Release device build is the only compile check required for this trial release. Real-device visual acceptance remains with the user after SideStore installation.

## A4 — 2026-10-04：子分類與篩選預設收合

- 基準：fetch 的 `origin/ios-poc` `7b6fc1d89b6bdb552a03e714ae0b5d5bd8c9183c`，獨立 `ios-ui-a4-filter-disclosure`，無 protected dirty paths。
- 使用者兩張真機畫面：金牌首頁未選分類；薦片標亮電影並直接展示類型／地區／年代／排序。
- 原因：CMSView.load 對 type-4／CSPSpider home 以 firstListableCategory 標亮第一分類，其他來源維持自己的首頁片單（selectedCategory=nil）。SourceClient.home 的 spider 分支只在 home.list 為空時 fallback 第一分類。這是現有來源／UI 路徑差異；此次保留原本首頁／分類載入規則。
- 原收合機制只處理真正 child categories，activeFilterRows 無條件展開；因此沒有 child categories 的來源也無法收起篩選。
- CMSView 現改為單一 `subcategoriesExpanded=false`，獨立「子分類與篩選」入口同時控制 children 與 filter rows。切換分類重新收合；收合／展開只改 UI state、不重新發 request、不清除篩選。收合仍顯示已選篩選數。
- 保留 active underline、category target IDs、filter key/value、來源 API、搜尋、分頁與全部播放器／收藏／下載 domain；無 Core／engine 修改。
- 驗證：Swift tree-sitter baseline／edited 各 0 error，scoped diff whitespace 通過；獨立 read-only review 無 Critical／Important，Ponytail 最終 diff：Lean already. Ship. 只透過既有 SideStore Release 作 device build，不另跑測試 CI。Linux Work 沒有 iOS Simulator，未做實際 SwiftUI rendering，操作／動態字級／VoiceOver／深淺主題仍需真機驗收。
- 發布前再次 fetch ios-poc 未前進，既有功能全部保留。GitHub 最新 Release／source 與 tag 缺席核對後使用新的 0.1.64 (65)。已發布 **0.1.64 (65)**（2026-10-04 22:33，Asia/Taipei）：成功 run [37209250026](https://github.com/st7833232/webhtv/actions/runs/37209250026)，全部 steps success（device Release build、IPA／schema validation、公開下載 byte comparison、source publish）。tag `ios-v0.1.64-b65` → IPA code commit `033d43368ff7aa629375834d9e48da0997490ca5`；source update commit `57ef2ca38e72be9ddb4380f0baea290a94e59e30`。asset `WebHTV-0.1.64-65.ipa` uploaded，35,082,545 bytes，SHA-256 `67eda949b95cf06a57a835d52f668bedd99a35558dfd6031465ad43aa0915acc`。已從 immutable source commit 核對 versions[0] 0.1.64，downloadURL／size 與 Release 相同，bundle `com.webhtv.ios.poc`／source identifier `com.webhtv.sidestore.source` 未改。

Recovery anchor: implementation, syntax, independent review, device Release build, IPA public download and source.json publication all complete. No actual SwiftUI rendering in Linux Work. Next action: SideStore real-device acceptance for disclosure, retained filters, Dynamic Type and VoiceOver.
