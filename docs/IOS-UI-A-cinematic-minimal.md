# IOS-UI-A — Cinematic Minimal

## A2 structure redesign — 2026-10-04 (current task)

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
Release target: `0.1.60 (61)`

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
