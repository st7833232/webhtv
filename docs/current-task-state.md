# Current Task State

## Original Goal

Port WebHomeTV to iPhone with an Android-like UI, drive the user's own `wang-movie.json`, and play with the app's own engines. **Superseded by dual internal-player decision, 2026-09-23:** the goal used to include Infuse, Fileball, SenPlayer and VidHub playback; those were removed, and the product maintains exactly two internal engines — AVPlayer (primary) and MPV (compatibility). `docs/IOS-POC-17-dual-internal-player.md`. The Google TV `csp_JPianAmns` repair is not in scope.

## Current handoff — 2026-09-24 12:15 CST（讀這一節，再讀文末 Resume Prompt）

**Git（交接當下）**：分支 `ios-poc`，**已 push，本機＝`origin/ios-poc`（`0 0`）**：`5dadcd04` 版號、`d7a6e35e` workflow 推回的
`source.json`，再加上本次發布紀錄的 docs commit（也已 push）。接手時先 `git fetch`、`git log --oneline -6`、`git status` 重新確認，
不要相信這一行。

**目前最新已發布版本是 `0.1.10 (11)`**（2026-09-24，使用者授權；tag `ios-v0.1.10-b11` → `5dadcd04`，run `35953397506`，
IPA 24,851,830 bytes，sha256 `01ff7bb60f230fbef8c77ed83fc8c32bd3c9e65316b0d3272e342367a9f205f0`，下載回驗通過）＝`0.1.9 (10)`
＋IOS-POC-16B／15D／17F。`0.1.8 (9)` 起 Release 版就開放 MPV（17E）。
使用者規定：**每次 push、bump 版本、tag、package、publish 或發 SideStore release 都要另外明確授權**；不要直接裝到使用者的 iPhone。

**已完成（都已 push，並在 `0.1.10 (11)` 發布）**

| 單元 | commit | 內容 | 驗證 | 未驗 |
|---|---|---|---|---|
| IOS-POC-16B | `a5f2678e` | 控制列七個二級選單改為自有 panel（`PlayerChrome`／`PlayerPanelPlacement`） | `swift test` 335／334（天氣）；模擬器直向實操 | 橫向 drawer、AirPlay 邊緣觸控、VoiceOver、真機。`docs/IOS-POC-16-custom-player-controls.md` 第十之一節 |
| IOS-POC-15D | `6416c4d4` | IOS-POC-15 契約逐條補缺口＋`os.Logger` `[playback]` 量測 | `swift test` 340／339（天氣）；模擬器看到預載命中 | 真機效能（IOS-POC-15 §8 七項）仍 pending。`docs/IOS-POC-15-playback-buffering-preload.md` 第十二節 |
| IOS-POC-17F | `b37751d2` | 播不出來就主動切換播放核心：network／unclassified 失敗切一次；`offline`／`source` 不切；目前核心接手 20 秒仍 preparing／buffering 就切（`PlayerRouter.startupTimeout`、`startupTimedOut()`；App 端在 `PlaybackSession.watchStartup()`）；不顯示成錯誤 | `PlaybackEngineTests` 29／29；全套 `swift test` **344／344**；Simulator Debug build；模擬器用本機假串流（每秒 1 byte 的 `.m3u8`）實播：原生→MPV、MPV→原生都在 20 秒切換，不會切第二次、不顯示錯誤 | 真機、真實來源上的切換。`docs/IOS-POC-17-dual-internal-player.md` 第十二之二節 |
| 文件整理 | 本次 commit | 依 `.codex/task-state/handoff-2026-09-24/stale-docs-inventory.txt`（gitignored）修正 7 份文件的過時現況陳述；IOS-POC-11 補「第十次發布 `0.1.9 (10)`」；MPV parity roadmap 寫進 IOS-POC-17 第十四節；本文件與 `docs/AGENT_HANDOFF.md` 補 IOS-POC-18／16B／15D／17F | 文件，無程式變更 | — |

**17F 模擬器測法（要重做時）**：一個本機 Python HTTP server 提供假 `config.json`（一個 type-1 站 `api=http://127.0.0.1:8765/api`）、
對任何 `/api` 回同一個含 `vod_play_url` 的 JSON、`.m3u8` 回 200 後每秒寫 1 byte；把 App 容器
`Library/Preferences/com.webhtv.ios.poc.plist` 的 `configSourceURL` 改成本機 URL（**不是** `simctl spawn defaults write com.webhtv.ios.poc`，
那寫到裝置層級 domain，App 讀不到）；要從 MPV 起播就暫時設 `webhtv.playback.defaultEngine=mpv`。測前備份、測後還原
偏好設定與 `Library/Application Support`（本次已還原，設定來源回到使用者的 `wang-movie.json`）。
注意 AVPlayer 對**完全不回應**的網址約 10 秒就自己報錯，那會走「network 失敗切一次」而不是 20 秒逾時。

**已知但不修（已記錄）**：`MediaSelection` 只在開 panel／換 engine 時重讀（pre-existing）；滑動進度條可能同時觸發全畫面拖曳的
相對 seek（pre-existing，未實測）；冷啟動會閃一下「尚未載入設定」（pre-existing）；17F：開播前按暫停，20 秒後仍會切到另一個核心並自動播放（罕見）。

**環境備忘**：模擬器 `7B4E9557-4774-4EB9-B408-BB544DCC8657`（iPhone 17 Pro, iOS 26.3）；`wang-movie.json` 的 SHA-256
`b17576e34eb42b4c589a818ef8b5ec2655a2c7a188d626fc427c37d628897168`，需要時從使用者 GitLab 重抓；模擬器控制工具一次來回
5～10 秒，比 5 秒自動隱藏長，互動測試時可暫時把 `PlayerChrome.autoHideSeconds` 改大、測完還原並重建（不要 commit）。

**下一步（唯一）**：使用者用 SideStore 裝 `0.1.10 (11)`，依 `docs/IOS-POC-8L-core-real-device-acceptance.md` 7.2 回報，
優先 ⑱⑲（＝MPV parity P1），並留意 16B 面板與 17F 自動切換；收到回報後逐列填進 8L 與 IOS-POC-17。
使用者沒有指示前，不開始 MPV parity P2 以後的任何階段，也不開始 IOS-POC-12／13。

## Current Scope

- **Re-verified 2026-09-23 16:48 CST at the start of IOS-POC-17 (after `git fetch`): HEAD
  `2a46c3fb`, identical to `origin/ios-poc` (`0 0`), worktree clean.** IOS-POC-17 then added
  `ecb0c4d0` (17A), `cf076e79` (9G), `7d679d68` (17B), `a1750b8c` (17C) and a docs commit (17D),
  **all pushed since, followed by 17E `a1bc5bb6`, the `0.1.8 (9)` release, IOS-POC-18 `8df71c12` and the
  `0.1.9 (10)` release; `origin/ios-poc` was `dde455ba` on 2026-09-24**; the local commits after it are listed in
  the handoff section at the top. Re-check with `git log` rather than trusting this line.
- Branch `ios-poc`. **Re-verified 2026-09-23 16:04 CST at the start of IOS-POC-8L (after
  `git fetch`): HEAD `f0495b8b`, identical to `origin/ios-poc`
  (`git rev-list --left-right --count HEAD...origin/ios-poc` → `0 0`), worktree clean; the last
  functional commit is `63040bb3` and everything after it is docs-only.** The earlier
  `ecebeaa3` (IOS-POC-15 start) and `61f2d6fd` readings are ancestors and superseded. Since the
  runtime-roadmap update the branch has shipped IOS-POC-5S-1 (ads blocking), IOS-POC-14
  (auto-advance), 14A/14B (the playback speed carried within one title), **IOS-POC-5S-2 (the
  viewer's opening and ending)** and the **PiP foreground-restore fix**, plus **four releases:
  `0.1.2 (3)`, `0.1.3 (4)`, `0.1.4 (5)` and `0.1.5 (6)`**.
  **Every SHA this line has carried went stale**: `7b7ad584`, `616e182e`, `eba5346c`, and a handoff
  that named `035ad0bf` as "the latest on GitHub" was **sixteen commits behind** — that is the
  roadmap-only commit, an ancestor rather than a tip. Test counts have read 197, 203 and 225 and are
  equally stale.
  **Always re-check Git rather than trusting a quoted SHA** — this line is a recovery anchor, not a
  substitute for `git log` / ahead-behind / worktree checks.
- Android `app/` is read-only for all iOS work and has never been modified: `git diff <branch-point>..HEAD -- app/` is empty, and every commit on this branch touches only `ios/`, `docs/`, `scripts/`, `AGENTS.md` and `.codex/`.
- **The input configuration lives in the scratchpad, not `/tmp`.** `/tmp/webhtv-recha-new.wprHof/` was cleared mid-session; `wang-movie.json` was re-fetched from the user's own GitLab and its SHA-256 matches the recorded baseline byte for byte. Re-fetch it from `https://gitlab.com/st7833232/recha/-/raw/main/wang-movie.json` if it is missing. `recha-main.zip` was **not** restored, so `scripts/audit_spider_jars.py` cannot be re-run without downloading it again.
- Stages through IOS-POC-4J have an annotated `recovery/<task-id>/*` tag; tags through `IOS-POC-1H` are on the remote. **Recovery tags became opt-in on 2026-09-16** (AGENTS.md §6), so IOS-POC-5A onwards are deliberately untagged.

## Where the roadmap actually stands (2026-09-22, IOS-POC-11B)

| Milestone | State |
|---|---|
| IOS-POC-5Q multi-quality | **Done and verified** (Q1–Q3) |
| IOS-POC-5R WatchHistory / resume | **Done and verified** (R1–R6). **R7 intro/outro skipping is no longer deferred — it shipped as IOS-POC-5S-2** |
| drpy loader | **Done and verified** (IOS-POC-6A/6B) |
| 4 drpy sources end to end | **Done** — all four reached real media bytes |
| Python feasibility / P1 | **Done** — measured, not implemented (`docs/IOS-POC-7A-python-runtime.md`) |
| Python P2–P5 | **Done** — `docs/IOS-POC-7A-python-runtime.md` carries all of it: `PythonSpiderRuntime`, the `base/spider.py` shim, routing through `CSPSourceResolver`, the same-origin/HTTPS/size gates, a real-source golden and the 42-site survey |
| CPython starts on iOS | **Done on the simulator (7F) and on the iPhone 18 Pro (9F)** — 3.13.15 both times |
| Python `requests` Tier-1 vendoring (IOS-POC-7P) | **Done** — measured **14 of 42 sites execute, 6 reach media bytes** |
| Python `Crypto` / `lxml` / `pyquery` / `bs4` | **Not started** — 24 sites wait on these (`Crypto` 17, `lxml` 3, `pyquery` 2, `bs4` 2) |
| CatVod JS spider contract (IOS-POC-10T) | **Done** — `__jsEvalReturn` mapped onto the ABI on the existing runtime; **麻豆(js) listed and playing on the iPhone 18 Pro** (10V) |
| MPV licence / provenance (IOS-POC-9A) | **Done** — no licensing blocker, conditional on pinning MPVKit ≥1.0.0 non-GPL; `docs/IOS-POC-9A-mpv-license-provenance.md` |
| MPV technical feasibility (IOS-POC-9B/9C/9D/9F) | **Done.** MPVKit is wired into the App target, static linking is confirmed by symbol table, and **libmpv initialises on the simulator and on the iPhone 18 Pro** |
| **MPV rendering (IOS-POC-9G, 2026-09-23)** | **Root cause found and fixed; first frame on the simulator; real device not yet re-run.** The probe drained mpv's events *inside* the wakeup callback — `client.h` forbids any client API call there, and mpv v0.41.0's `client.c`/`dispatch.c` show the property reads at `FILE_LOADED` waiting on the very playloop that broadcast it: the device's "`FILE_LOADED`, never `VIDEO_RECONFIG`". Fixed as MPVKit's demo does it; the OpenGL path then exposed a second defect (its update callback inherited main-actor isolation and trapped on mpv's `vo` thread), also fixed. **Simulator: Metal and OpenGL both draw** a TS segment, a TS playlist and a multi-rendition fMP4 master. **The MPV stop condition was not triggered; no VLCKit spike.** `docs/IOS-POC-9B-mpv-playback-core.md` §9G. Until 2026-09-23 this row read "NOT DONE — PAUSED — UNRESOLVED" |
| **IOS-POC-17 Dual internal player** | **Implemented 2026-09-23 (17A–17E) and shipped in `0.1.8 (9)`. 17E (user decision): MPV is offered in release builds too — its device first frame is still unverified, and the 10-second first-frame watchdog hands a black MPV load back to AVPlayer; the quality menu moved into the control bar (323 tests, all pass).** Earlier in the day this row read: MPV disabled in release builds until its device first frame. External players removed (17A). Core `PlaybackEngine` / `PlayerRouter` / `PlaybackEngineSelection` (global default, session override, current engine) / `PlaybackFailure` (only engine-capability failures fall back, once per attempt, both directions) (17B). `AVPlayerEngine` is a thin adapter over the existing `AVPlayer` code; `MPVEngine` uses the demo's Metal path. Settings 「預設播放器」, a control-bar engine menu showing the engine actually playing, and a classified failure message instead of a silent black screen. An episode now opens the player directly (17C, the user's request). **322 tests, all pass**; simulator build succeeds; manual AVPlayer↔MPV switching keeps position, speed, pause state and target **on the simulator**. `docs/IOS-POC-17-dual-internal-player.md` |
| **IOS-POC-18 Source identity** | **Done 2026-09-23 (`8df71c12`), shipped in `0.1.9 (10)`.** Object-ext sources (e.g. 靈虎) keep their site across relaunch; watch-history entries greyed out by source-ID drift migrate on upgrade; sources are keyed by a stable canonical identity, Spider ext behaviour unchanged. `swift test` 326／325 at `dde455ba` (weather) |
| **IOS-POC-16B Player panels** | **Done 2026-09-24 (`a5f2678e`), shipped in `0.1.10 (11)`.** The control bar's seven second-level choices open panels the bar owns; portrait sheet, landscape drawer (landscape not run). `docs/IOS-POC-16-custom-player-controls.md` 第十之一節 |
| **IOS-POC-15D Buffering contract** | **Done 2026-09-24 (`6416c4d4`), shipped in `0.1.10 (11)`.** IOS-POC-15 checked line by line; `os.Logger` `[playback]` measurements. Device performance still pending. `docs/IOS-POC-15-playback-buffering-preload.md` 第十二節 |
| **IOS-POC-17F Proactive engine fallback** | **Done to the simulator 2026-09-24 (`b37751d2`), shipped in `0.1.10 (11)`; device unverified.** Network/unclassified failures and a 20-second no-start try the other engine once per attempt; offline/source never switch; replaces 17B's capability-only rule (user decision). 344／344. `docs/IOS-POC-17-dual-internal-player.md` 第十二之二節; MPV parity roadmap 第十四節 |
| SideStore release pipeline (IOS-POC-11) | **Done** — `.github/workflows/ios-sidestore-release.yml` and `source.json` exist and have published every release since, through `0.1.10 (11)` |
| Current release | **WebHTV `0.1.10 (11)`**, tag `ios-v0.1.10-b11` → `5dadcd04`, published 2026-09-24 at the user's instruction (run `35953397506`, `WebHTV-0.1.10-11.ipa` 24,851,830 bytes, SHA-256 `01ff7bb6…`, downloaded back and verified); `source.json` first entry `0.1.10`, pushed by the workflow as `d7a6e35e`. The project carries `MARKETING_VERSION = 0.1.10` / `CURRENT_PROJECT_VERSION = 11`. It is `0.1.9 (10)` (`8df71c12`, IOS-POC-18) plus IOS-POC-16B, 15D and 17F. Everything earlier is superseded. **No device result yet.** (This row read `0.1.7 (8)` until 2026-09-24 and `0.1.9 (10)` until the same day's release.) |
| IOS-POC-14 auto-advance | **Done and confirmed on the device by the user.** An episode that ends starts the next one on the same line; the last one closes the player |
| IOS-POC-14A/14B playback speed | **Done, not device-verified.** The chosen speed carries across episodes **of the same title** — keyed on `WatchHistory.key`, so switching source resets it, which the user decided to leave (14C) |
| Real-device acceptance (IOS-POC-8) | **Partial.** Several runs on hardware; the list below is what is and is not confirmed. Not to be recorded as complete. **IOS-POC-8L (2026-09-23) prepared the core acceptance: `docs/IOS-POC-8L-core-real-device-acceptance.md` is the matrix** (已驗證／這輪要驗／延後驗證／不適用, 14 user-run items). Two findings it recorded: `wang-movie.json` has **no source** that reaches either `script` rule host (`yeslivetv.com`, `www.maolvys.com`) and none that requests its only ad host `mozai.4gtv.tv`; and the sniffer web view and every `print` diagnostic are **invisible on a SideStore Release install** — so 5S-1/5S-3's positive behaviour has no on-device observation channel, only non-regression |
| Acceptance release candidate | **Superseded — `0.1.8 (9)` was published on 2026-09-23** (run `35846736589`, tag `ios-v0.1.8-b9` → `0a57d545`, `WebHTV-0.1.8-9.ipa` 24,754,269 bytes, SHA-256 `e6aff904…`, downloaded back and verified; `source.json` pushed by the workflow as `30af13f5`). It carries 5S-3 and IOS-POC-17 including **MPV opened in release builds** and the quality menu in the control bar (17E, user decision). **No device result yet.** The text below is the pre-release plan: **`0.1.8 (9)` planned, not published.** Must be built from the latest `ios-poc` HEAD (functional tree = `63040bb3`), so it carries 5S-3 as well as everything `0.1.7 (8)` has. An unsigned `iphoneos` Release pre-flight with `MARKETING_VERSION=0.1.8 CURRENT_PROJECT_VERSION=9` on the command line **BUILD SUCCEEDED** on 2026-09-23 (project file untouched). No version commit, tag, push, dispatch or Release was made; the four-step publish sequence and the release-notes draft are in the 8L document §3 and wait for the user's explicit authorisation |
| IOS-POC-5S-1 ads blocking | **Done, 2026-09-22** — 62 literal ad domains compile into a `WKContentRuleList` scoped only to the sniffer WebView; one whole-URL entry stays inert to preserve Android semantics. **Not device-verified** |
| IOS-POC-5S-2 opening / ending | **Done, 2026-09-22.** `WatchHistory.opening`/`ending` as optional milliseconds so a history file without them still decodes; start position is `max(opening, resume)`; the ending rides the existing five-second sampler into the existing `finished()` path. **Not device-verified** |
| IOS-POC-5S-3 config `rules` → sniffer | **Done in code, 2026-09-23. Not device-verified.** `SnifferRules` in core is pure: host extraction, rule selection, `exclude`/`regex` precedence and the `script` lookup are all driven by `swift test`, and the WebKit layer only calls in. Ported from the Java rather than a summary, which corrected two things: the host haystack is **one comma-joined string** of direct + `url=` host, so **neither takes precedence** — configuration order does, first match wins; and each of `exclude`/`regex` runs a **literal pass over every entry, then a pattern pass**, so a literal hit on a later entry beats a pattern hit on an earlier one. `exclude` outranks `regex`, both outrank the built-in candidate test, and when no rule matches, behaviour is byte-for-byte what it was. `script` is evaluated with `evaluateJavaScript` on `didFinish` — **not** `WKUserScript`, which would persist and stack across navigations — selected by the **page's** host while accept/reject is selected by the **candidate's**. The whole iOS tree builds exactly two `WKWebView`s and the rules reach only the sniffer's. The 9 playlist-shaped regexes stay inert: no playlist is ever opened, and a test pins that. **297 tests / 296 pass** (+31), simulator build succeeds |
| IOS-POC-5S overall | **Code complete, 2026-09-23** (5S-1 ads, 5S-2 opening/ending, 5S-3 rules). **Not real-device acceptance** — no part of 5S has been watched working on hardware |
| IOS-POC-16 Custom player controls | **Implemented; the bar is confirmed to render correctly on the simulator; per-control interaction testing handed to the user 2026-09-23.** AVKit draws no controls; `PlayerControlBar` draws close / subtitles / audio / speed / AirPlay / ±10 s / play / scrubber-with-buffer / opening / ending, and owns its own four-second auto-hide. Confirmed on the simulator: AVKit's controls are gone, the video is clean while the bar is hidden, and the bar renders complete and correctly laid out. **Not confirmed: any individual control, including the close button, which is now the only way out of the player** — the tooling round-trip is longer than the five-second auto-hide, so a two-step "summon then press" can never land. **Compare the installed binary before believing any simulator observation:** `ios/.build/out/...` holds a stale artifact while `xcodebuild` writes to DerivedData. `docs/IOS-POC-16-custom-player-controls.md` |
| IOS-POC-15 Playback Buffering / Preload | **Code implemented 2026-09-23 / real-device performance verification pending.** A hysteretic `good/normal/risk/poor` model over buffer-ahead, `likelyToKeepUp`, `bufferEmpty`, `timeControlStatus`, stalls and the access log drives `preferredForwardBufferDuration` 60/90/120 s for VOD, leaves live and unknown-duration playback system-managed, and caps resolution to 1080p/720p **only** when `AVURLAsset.variants` reports more than one. `preferredPeakBitRate` stays 0 in every state and a test asserts it. The next episode's `PlaybackTarget` is pre-resolved **once**, through the same `SourceClient.playbackURL` pipeline, inside the last 90 s before the handoff, and the existing `playNext` consumes it or resolves normally. **266 tests / 265 pass** (+38), simulator build succeeds. **No device numbers exist**: startup latency, buffer-ahead, rebuffer counts, throughput and next-episode handoff are all unmeasured. `docs/IOS-POC-15-playback-buffering-preload.md` **User decision 2026-09-23: device performance testing is deferred until later and must not block the roadmap.** It did not block 5S-3, which shipped the same day in `63040bb3`; it must not block core real-device acceptance either. |
| 2.5×/3× silent audio | **Fixed in code, not heard on a device.** `AVAudioTimePitchAlgorithmLowQualityZeroLatency` supports exactly 0.5/0.666/0.8/1/1.25/1.5/2 and drops audio at every other rate — which is precisely the two speeds IOS-POC-16 added. `AVPlayerItem.audioTimePitchAlgorithm = .timeDomain`. Reported by the user 2026-09-23; **not part of IOS-POC-15's charter**, fixed because its root cause is the item-creation site that stage was already editing |
| IOS-POC-12 Runtime Architecture Reconciliation | **Planned, not started.** Begins only after core real-device acceptance — **now including MPV's device first frame, switching and fallback** (8L ⑱⑲). The MPV keep/drop decision is made: **kept**, as the second internal engine (user, 2026-09-23). 5S is already code complete. **IOS-POC-15 is not a gate here**: what 12 needs from it is the AVPlayer item/session contract being settled, which its code already did — the deferred device *performance* pass does not block the freeze |
| IOS-POC-13 Runtime Hot Update | **Planned, not started.** Begins only after IOS-POC-12 freezes the Native Core / Dynamic Layer boundary and update manifest contract |
| More `csp_*`, Python dependency shims, CarPlay | **Backlog.** Do not let these pre-empt core acceptance or the 12→13 refactor/update sequence. (Automatic AVPlayer↔MPV fallback came off this row on 2026-09-23: it is implemented in IOS-POC-17B.) |

## Post-core roadmap: refactor first, then runtime hot update

The user decided on 2026-09-22 that WebHTV should eventually support an **in-app runtime update**
path, but **not by replacing its signed native executable**. The sequencing is intentional:

`5S-2 → 5S-3 → core real-device acceptance → MPV keep/drop decision → IOS-POC-12 → IOS-POC-13`.

**That line is the historical plan and is kept for context.** Two things happened out of that order,
both at the user's explicit instruction, so the sequence below is what actually remains.

**5S-2 closed on 2026-09-22 and 5S-3 on 2026-09-23** (`63040bb3`), so **IOS-POC-5S is code
complete**. **IOS-POC-15's code also landed on 2026-09-23, ahead of the device baseline it was
supposed to follow** — and the user then decided to defer its real-device performance pass and run
it themselves later. The stage still owes the baseline *and* the post-change comparison together
(the seven measurements in `docs/IOS-POC-15-playback-buffering-preload.md` §8 are what close it),
and what it did build is the ability to take them: bounded diagnostics that name which of
「來源解析慢／AVPlayer buffer 不足／CDN throughput 不足／selected bitrate 太高」is limiting playback.
**Do not record IOS-POC-15 as closed on simulator evidence, and do not go back and redo it either.**

The remaining sequence — **replaced on 2026-09-23 by the user's dual internal-player decision**:
`remove external players ✓ → MPV rendering recovery ✓ (simulator) → minimal MPVEngine ✓ →
AVPlayer + MPV dual-engine integration ✓ → global/default engine setting ✓ → session engine
selector ✓ → manual engine switching ✓ → classified automatic fallback ✓ → core real-device
acceptance (incl. MPV on a device) → IOS-POC-12 → IOS-POC-13`.
Only if MPV hits the stop condition on a device and is proven unsuitable:
`MPV stop → minimal VLCKit spike → decision AVPlayer + VLC` — never three engines.
IOS-POC-15's device performance pass stays folded in whenever the user chooses to run it.
The line `core real-device acceptance → MPV keep/drop decision → IOS-POC-12 → IOS-POC-13` that
stood here is superseded: there is no keep/drop decision left to make.

IOS-POC-15 deliberately comes **after a real-device playback baseline** so buffering work is driven
by measured startup time, buffer-ahead, rebuffer/stall events, throughput and next-episode handoff
latency rather than by choosing a large cache value blindly. It remains before the Native Core
contract-freeze because it can still change AVPlayer item/session behaviour.

### IOS-POC-12 — Runtime Architecture Reconciliation

This is a **bounded refactor / contract-freeze stage**, not the updater itself. It starts only when the
first stable product shape is known. Its job is to:

- freeze the Native Core contracts that dynamic content depends on: `ConfigSource`, `SourceClient`,
  `PlaybackTarget`, `PlaybackSession`, `SpiderRuntime` / resolver boundaries, `WatchHistory`
  persistence semantics, and the WebHome bridge ABI;
- inventory hard-coded source mappings, bundled scripts/rules/resources, and source-specific branches,
  then decide which are genuinely volatile and can move out of Swift without changing behaviour;
- separate a **Native Core** from a **Dynamic Layer**. The Native Core remains IPA-delivered; the
  Dynamic Layer is the only future hot-update surface;
- define a versioned runtime-pack manifest contract, compatibility gates (including minimum App
  version / runtime ABI), per-file type/size/hash metadata, origin/authenticity policy, configuration
  isolation, activation semantics and rollback/LKG rules;
- preserve the existing fail-closed security model. Moving code out of the bundle must not weaken
  same-origin/HTTPS/size/hash checks or turn a provider failure into executable fallback;
- keep this stage behaviour-preserving. Do **not** add the downloader, activator or update UI here.

### IOS-POC-13 — Runtime Hot Update

Only after IOS-POC-12 freezes the boundary, implement:

`manifest → download to staging → size/hash/authenticity verification → compatibility check →
atomic activation → session/cache invalidation → rollback to last-known-good`.

A failed or partial update must leave the previous active generation intact. Runtime generations must
be isolated from one another and from saved configuration caches; activation is a pointer/swap after
every file verifies, never an in-place mutation of the working generation.

**Intended hot-update surface:** compatibility packs, CatVod/JS spiders, Python `.py` spiders,
drpy/rule scripts where the existing security policy allows them, XBPQ/XYQ-style rules, source/host
mappings, ads/rules data, images/resources, text, and **schema/data-driven UI properties that an
already-shipped native renderer understands** (for example labels, order, visibility and predefined
layout parameters).

**Still requires a new IPA:** Swift / SwiftUI executable logic, new native views or navigation
behaviour, `SourceClient` / `CatVodHost` native primitives, AVPlayer integration, MPVKit/FFmpeg,
the CPython interpreter/XCFramework or compiled Python dependencies, native frameworks, App
entitlements, `Info.plist` capabilities, signing changes and any new native ABI the active App does
not already understand. UI is therefore not categorically non-updatable: **data-driven UI can move
with the runtime pack; new compiled UI behaviour cannot.**

The SideStore pipeline remains the native-App update path. IOS-POC-13 is for the high-churn runtime
and compatibility layer so ordinary source repairs do not require an IPA release.

Full design record: `docs/IOS-POC-12-13-runtime-update-roadmap.md`.

The device acceptance is **not** finished, and nothing here should be read as saying it is. What
already ran on hardware stands and is not to be rolled back; what is listed as unverified stays
unverified until a later device pass.

- **Verified on hardware:** a fresh install accepts a remote configuration; the remote configuration
  lists its sources; CJK and the source names' emoji render correctly; the app icon ships from the
  asset catalog and installs; IOS-POC-8F and 8G (search field, wallpaper) were confirmed by the user;
  **a CatVod JS spider source — 麻豆(js) from `wang-sex.json` — is listed and plays** (IOS-POC-10V),
  which also puts a spider source, a remote configuration and a same-origin script download on the
  verified side; **CPython runs the whole chain to real media bytes** (IOS-POC-9F); **libmpv
  initialises** (9F); and **荐片's filter rows appear on a cold start** after IOS-POC-10Z, confirmed
  by the user from a SideStore install of `0.1.1 (2)`; and **an episode that ends starts the next
  one** (IOS-POC-14), confirmed by the user from a SideStore install of `0.1.2 (3)`.
- **Still unverified on hardware:** the AVKit close button in its new position; browsing and playback
  on a **CMS** source; a **`csp_*`** spider source; a **drpy** source; **Bili's `Referer` + browser
  `User-Agent` actually playing through `AVPlayer`**; whether `AVURLAssetHTTPHeaderFieldsKey` works
  on a device at all; WatchHistory position and resume; ~~opening Infuse / Fileball / SenPlayer /
  VidHub~~ (superseded 2026-09-23: removed); the player's volume and brightness drags; the
  line-picker row; and **MPV on a device** (first frame, switching, fallback).
- **PiP foreground restore (2026-09-22): code fix implemented / device verification pending.**
  `PlayerSurface.Coordinator` observes the app becoming active, and only while its existing PiP
  binding is true it briefly disables `allowsPictureInPicturePlayback`, restoring it on the next
  main runloop. This asks AVKit to stop PiP without touching `PlaybackSession.shared.player`, its
  item, position, rate or playing/paused state. A small state gate permits one request per active
  PiP session and resets for the next cycle; three focused tests cover the gate. The current Linux
  host has no Swift/Xcode toolchain, so the full Swift suite and Simulator build remain unrun here.
  Real-device closure still requires the repeated-cycle acceptance in
  `docs/bugs/IOS-PIP-foreground-restore.md`.
- **麻豆 playing does not settle the header question.** Its only header is a `User-Agent`, and that
  stream answers `HTTP 200` with and without one — measured with `curl` both ways on 2026-09-22.
- **The header question is the sharp one.** `avURLAssetSendsTheHeadersItWasGiven` stands a real
  `NWListener` and asserts on real bytes, but **it runs on macOS**, so it is not evidence about the
  device. The key is undocumented; a simulator or socket result must not be recorded as device-verified.
- The device is the **iPhone 18 Pro** (`00008160-00124C8200214036`); the iPhone 16 Pro of the earlier
  runs reports `unavailable`. **Since 2026-09-22 the user installs through SideStore**, so builds
  reach the phone as a published IPA rather than by `devicectl install`.
- Live evidence that the Bili path itself is healthy, so a future device failure is not
  misread as a spider fault: `CSP_GOLDEN_SITE='{"key":"bili",…,"api":"csp_Bili"}' swift test
  --filter biliOffersMultipleQualityLines` **passed on 2026-09-21**, resolving 480P and 360P lines
  and probing the best one to `.media` with headers, on an `akamaized.net` mirror.

## Non-Negotiable Constraints

- Preserve Android `main`, unrelated dirty files, and the repository's task-guard / Ponytail / research / approval gates. Do not push, sign, package or publish without user authorization.
- No jailbreak, always-on self-hosted server, or recurring infrastructure cost for the personal iPhone path.
- **ATS: superseded by explicit user decision (2026-09-15, IOS-POC-4B).** The user was offered a narrow per-domain exception, no change, or global cleartext, was told the earlier records forbid weakening ATS globally for one site, and chose global cleartext. `NSAllowsArbitraryLoads` ships. Keep it; do not broaden further — no server-trust override, no pinning bypass — without a fresh decision.
- **Do not claim iOS executes Python, JAR or DEX — it does not, and that is deliberate.** A CatVod
  spider runtime *does* exist since IOS-POC-5A, but it works by **reimplementing the CatVod Spider
  contract in JavaScript on JavaScriptCore**, never by running Android bytecode. The decompiled
  Java is a specification only. `docs/IOS_SPIDER_RUNTIME_SPEC.md` is the single source of truth for
  that boundary; an earlier version of this line read “No Spider runtime exists” and was left stale
  by the IOS-POC-5A/5B commits.
- **A Python runtime exists and has run on a device.** This line read "There is still no Python
  runtime — that is the next milestone" until IOS-POC-11B, which was left stale by IOS-POC-7E–7P
  (the runtime) and by 9F (the device run). CPython 3.13.15 starts inside the app on the simulator
  **and on the iPhone 18 Pro**, `PythonSpiderRuntime` answers the same `SpiderRuntime` contract as
  every other spider, and `皮皮虾.py` ran `init → home → category → detail → search → player →
  probe(media)` to real media bytes on hardware. What remains unbuilt is the `Crypto`, `lxml`,
  `pyquery` and `bs4` shims the other 24 sites need — a dependency gap, not a missing runtime.
  **A drpy loader does exist**, since IOS-POC-6A/6B: `DrpyEngine` fetches the engine and its nine
  libraries from the configuration's own origin, hash-pins and verifies them before evaluation, and
  runs them on the existing `JavaScriptSpiderRuntime`; **four drpy sources were driven end to end to
  real media bytes.** `ConfigSource` still resolves `./py/` references and nothing loads or executes
  them — locating a resource is not running it. An earlier revision of this line said no drpy loader
  existed and was left stale by the IOS-POC-6A/6B commits.

## Stage index

Each stage owns a durable document where one exists; the rest are recorded here and in their commit.

| Stage | What it delivered | Record |
|---|---|---|
| 1A–1D | Config classification, type-1 MacCMS flow, SwiftUI/AVPlayer shell | commits |
| 1E | Imported-config persistence | `docs/IOS-POC-1E-config-persistence.md` |
| 1F | Local-file / remote Raw URL config sources, relative-resource resolver | `docs/IOS-POC-1F-config-sources.md` |
| 1G | Launch refresh with 2 s/5 s/15 s retry | same document |
| 1H | Invalid config URLs are reported instead of ignored | same document |
| 2A | Five selectable players | commit |
| 2B | WebHome bridge over `WKWebView` + `WKScriptMessageHandler` | `docs/IOS-POC-2B-webhome-bridge.md` |
| 2C | Debug-only CJK font fallback for the simulator | same document |
| 2D | Bridge UI, navigation and information methods | `docs/IOS-POC-2D-webhome-bridge-ui-info.md` |
| 2E | Bridge playback half on a persistent playback session | `docs/IOS-POC-2E-webhome-bridge-playback.md` |
| 2F | Drove the five playback paths 2E left unexecuted; no code change | same document |
| 3A–3C | Android-like surfaces, wallpaper, oversized-logo removal | commits |
| 3D | Uniform 2:3 poster cells | commit |
| 3E | Built-in player presented full screen | commit |
| 4A | type-4 CatVod remote API sources | `docs/IOS-POC-4A-type4-sources.md` |
| 4J | type-0 MacCMS XML sources | `docs/IOS-POC-4J-type0-xml-sources.md` |
| 4B | ATS cleartext decision | same document |
| 4E–4I | Request timeout, category browsing, two-level categories, pagination, type-1 posters | commits |
| 5A | CatVod spider runtime on JavaScriptCore + `CatVodHost` + the `AppGet` port | `docs/IOS_SPIDER_RUNTIME_SPEC.md`, `docs/CSP_PORTABILITY_MATRIX.md`, `docs/CSP_MIGRATION_STATUS.md` |
| 5B | `XBPQ` and `XYQHiker` rule engines | `docs/CSP_MIGRATION_STATUS.md` |
| 5C | Reconciled this document and the handoff with the code at `226e826c`; no functional change | this document |
| 5D | The 15 ported spider sites reach the app UI (`SourceClient`); Xcode 27 build repair | `docs/IOS-POC-5D-spider-sites-in-app.md` |
| 5E | End-to-end sweep of all 45 listed sources, with a media probe | `docs/IOS-POC-5E-all-source-sweep.md` |
| 5F | Fixed five spider/host defects the sweep found; 27 → 29 playable | `docs/IOS-POC-5F-spider-defect-fixes.md` |
| 5G | WebView media sniffer + first-bytes probe; 29 → 35 playable | `docs/IOS-POC-5G-media-sniffer.md` |
| 5H | Removed the `Task { }` race that made four bridge tests flaky | the 5G document |
| 5I | XBPQ knew only the older 苹果CMS skins; 永樂 rendered its nav as films | `docs/IOS-POC-5I-xbpq-listing-templates.md` |
| 5J | One 全部 chip instead of two; CatVod filter rows under the category row | `docs/IOS-POC-5J-category-filters.md` |
| 5K | Category rows scroll away; Top button; collapsible child rows | `docs/IOS-POC-5K-scrolling-and-collapsible-categories.md` |
| 5L | `AppQi`, `App99`, `App3Q` and `Bili` ported (+16 sites, 45 → 61 listed); IV-prefixed AES + zlib in the host; `Site.id` made unique | `docs/IOS-POC-5L-appqi-app99-app3q-bili.md` |
| 5M | 薦片 driven by `JianPian` although its configured class is a protected shim (+1 site, 62 listed) | `docs/IOS-POC-5M-jianpian.md` |
| 5N | Assessment: do the other 34 protected sites have unprotected equivalents? 7 more do | `docs/IOS-POC-5N-protected-site-equivalents.md` |
| 5O | Remote compatibility pack: spider scripts update without rebuilding the app | `docs/IOS-POC-5O-remote-compatibility-pack.md` |
| 5P | A spider's request headers reach `AVPlayer`, the probe and the sniffer | `docs/IOS-POC-5P-player-request-headers.md` |
| 5Q | `playerContent`'s `url` reads all three CatVod shapes; `Bili` offers one line per quality; a quality menu in the player picker | `docs/IOS-POC-5Q-playback-quality.md` |
| 5R | Watch history, resume, the 記錄 tab, the detail screen's last-episode mark, and `app.history` answering real data | `docs/IOS-POC-5R-watch-history.md` |
| 5S-1 | The configuration's `ads` hosts compiled into a `WKContentRuleList` scoped to the sniffer WebView only; the one whole-URL entry stays inert because it is inert on Android too | `docs/IOS-POC-5S-ads-and-skip.md` |
| 5S-2 | **The viewer's own opening and ending**, in milliseconds, on `WatchHistory` — Android's `History.opening`/`ending`, not anything from the configuration. Start position becomes `max(opening, resume)`; the ending hands off through the existing `finished()` path on the existing sampler; two `Menu`s on the player carry Android's four operations. Old history files without the fields still decode | `docs/IOS-POC-5S-ads-and-skip.md` |
| 5U | Reconciliation: the live handoff documents rewritten against the actual HEAD and test run | this document |
| 5V | Debug-only simulator display fix for the font set the runtime is missing; no behaviour change | this document |
| 7A/7C | Assessment and P1 measurement for a Python runtime: what it would cost, measured rather than estimated | `docs/IOS-POC-7A-python-runtime.md` |
| 7B | Xcode's per-user state is ignored, after it blocked three commits in one session | `.gitignore` |
| 8A | **The first real-device run**, and the defect it found: a fresh install could not accept a remote configuration URL | this document |
| 8B | Two more device findings: a black band under the tab bar, and the player's close button in AVKit's corner | this document |
| 8C | An app icon, and the asset catalog the project never had | this document |
| 8D | Reverted 8B's wallpaper change, which had relayouted every screen; the black band it chased is left alone | this document |
| 8E | The three device-reported UI defects re-tested on the clean build: two were the 8B regression and are gone, the third was real and is fixed — the search field no longer vanishes after a source switch | this document |
| 8F | The search field goes back to hiding on scroll, at the user's request: the `.id` moves up to the whole `NavigationStack`, after three other ways of making the bar give the field back were measured and failed | this document |
| 8G | The black band behind the tab bar is gone on every tab — `scaledToFill` never filled, so `.ignoresSafeArea()` had nothing to expand | this document |
| 8H | 8F and 8G confirmed on the iPhone 16 Pro by the user; the second device run this project has had | this document |
| 8I | No synthetic 全部 anywhere — the category row and the filter rows show only what the source sends; the episode picker splits a long line into 100-episode blocks | this document |
| 8J | The episode blocks split on the printed episode number, not on position, so `1-100` ends at 第100集 on a line whose entries merge episodes | this document |
| 8K | Pull to refresh on the listing, and the source picker opens on the source in use instead of at the top of 67 | this document |
| 9G | **MPV's black screen was the probe's own event pump**: client API calls inside the wakeup callback (forbidden by `client.h`), plus an OpenGL update callback that inherited main-actor isolation. Both fixed as MPVKit's demo does it; Metal and OpenGL draw on the simulator | `docs/IOS-POC-9B-mpv-playback-core.md` |
| 17A | External players removed: `ExternalPlayer`, its picker rows, the URL-scheme handoff, its test | `docs/IOS-POC-17-dual-internal-player.md` |
| 17B | Dual internal engines: core contract, selection, failure classification, `PlayerRouter`; `AVPlayerEngine`, `MPVEngine`; 「預設播放器」; control-bar engine menu; MPV release-disabled (until 17E) | same document |
| 17C | An episode opens the player directly; the 播放 page is gone (user request) | same document |
| 17D | Documentation reconciliation for 17A–17C; historical external-player records marked superseded | same document |
| 17E | MPV offered in release builds (user decision; the 10-second first-frame watchdog falls back to AVPlayer); quality menu in the control bar | same document |
| 18 | Stable source identity across launches; drifted watch-history entries migrate; shipped as `0.1.9 (10)` | `docs/IOS-POC-11-sidestore-release.md` 第十次發布 |
| 16B | The control bar's second-level choices open panels the bar owns (2026-09-24, `0.1.10 (11)`) | `docs/IOS-POC-16-custom-player-controls.md` |
| 15D | IOS-POC-15 contract gaps closed; `os.Logger` playback measurements (2026-09-24, `0.1.10 (11)`) | `docs/IOS-POC-15-playback-buffering-preload.md` |
| 17F | Proactive engine fallback: network/unclassified and a 20-second no-start switch once; offline/source never (2026-09-24, `0.1.10 (11)`) | `docs/IOS-POC-17-dual-internal-player.md` |
| 8L | **Core real-device acceptance preparation** — the acceptance matrix, the `wang-movie.json` rules/ads inventory, and the `0.1.8 (9)` release-candidate plan with a Release pre-flight build. Docs only; nothing was device-verified by it | `docs/IOS-POC-8L-core-real-device-acceptance.md` |
| 6C | The sniffer unwraps a wrapper page that carries the stream in its own query string; one shared candidate test for both sniff paths | `docs/IOS-POC-6A-drpy-loader.md` |
| 7E | The CPython payload arrives by `scripts/fetch_python_ios.sh` + `third_party/python-ios-lock.json`, not by commit | `docs/IOS-POC-7A-python-runtime.md` |
| 7F | **CPython 3.13.15 starts inside the app** on the simulator; Python links into the app target only, so `WebHTVCore` still builds and tests on macOS | same document |
| 7G | `base/spider.py` shim + `PythonSpiderRuntime`; a hard-coded spider drives all 13 ABI methods and errors propagate | same document |
| 7H | **P3 routing**: `Site.isPythonSpider`, `PythonSpiderSupport` seam, and drpy's own same-origin/HTTPS/size/fail-closed implementations reused. Sources listed went 67 → 109 | same document |
| 7I | The shell-app/XPTV shape recorded as the product; the five ways a spider's code reaches the app | `docs/IOS_SPIDER_RUNTIME_SPEC.md` |
| 7J | `PythonLiveCheck` drives a real Python source through the app's own path; found the `requests` gap and a URL-encoding defect | `docs/IOS-POC-7A-python-runtime.md` |
| 7K | **P4 done**: `皮皮虾.py` runs `init → home → category → detail → search → player` and `MediaProbe` returns `.media`. The shim now percent-encodes before urllib sees a URL | same document |
| 7L/7M | **P5 done**: `scripts/audit_python_spiders.py` (static, 42 sites) and the runtime survey, reconciled | same document |
| 7N | A Python traceback goes to the log; one readable line goes to the screen | same document |
| 7P | `requests` + `urllib3` + `certifi` + `idna` + `charset-normalizer` vendored as pinned pure-Python wheels; sites reaching media bytes went 1 → 6, executing 4 → 14 | same document |
| 10F–10Q | **Eleven more user-reported items, 2026-09-22.** Player gestures (seek / volume / brightness); the close button removed and Picture in Picture enabled; `DrpyError` and `CMSClientError` made readable; pull to refresh was being answered by `URLCache` and no longer is; three drpy configuration shapes reconciled; and **麻豆(js) diagnosed as a CatVod JS spider this app does not implement** | `docs/IOS-POC-10-plan-ux-and-sources.md` |
| 14 / 14A / 14B / 14C | **An episode that ends starts the next one, and the last one closes the player**, plus the playback speed carried within one title. The auto-advance is **confirmed on the device by the user**; the speed is not. 14C records the decision to leave the source switch resetting it | `docs/IOS-POC-14-autoplay-next-episode.md` |
| 11 | **SideStore release pipeline.** `.github/workflows/ios-sidestore-release.yml` builds an unsigned device IPA on GitHub `macos-26`, validates it against SideStore's own schema, publishes a Release and updates `source.json` on this branch. **Eleven releases so far, through `0.1.10 (11)`**; `source.json` carries all eleven | `docs/IOS-POC-11-sidestore-release.md` |
| 10W–10Z | **荐片's posters and filter rows, and the defect underneath them.** The poster host was the first entry of a list whose first two were dead; the filter rows were missing because `SpiderSessionStore.reset()` called `destroy()` on a session its caller still held, wiping what `init` had built between `start()` and `homeContent()`. **Not specific to one spider** | `docs/IOS-POC-10-plan-ux-and-sources.md` |
| 10S | The source list follows the configuration's own order — `drivableSites` was four concatenated per-kind filters, so 麻豆(js), seventh in the file, was buried among the drpy sites | `docs/IOS-POC-10-plan-ux-and-sources.md` |
| 10V | **麻豆 confirmed on the iPhone 18 Pro by the user** — listed and playing. Does **not** settle the `AVURLAssetHTTPHeaderFieldsKey` question: that stream serves without a `User-Agent` | `docs/IOS-POC-10-plan-ux-and-sources.md` |
| 10T | **The CatVod JS spider contract implemented.** The blocker was `async`, not `__jsEvalReturn`: drpy2 has no `async` at all, so the runtime never settled a promise and all thirteen methods answered `{}` with no error. 麻豆 now runs to real media bytes | `docs/IOS-POC-10-plan-ux-and-sources.md`, `docs/IOS_SPIDER_RUNTIME_SPEC.md` |
| 10A–10E | **All five user-reported items done.** Close button follows AVKit's control-visibility delegate (the first attempt guessed with a timer and came out inverted); filter rows get Chinese labels from a closed table; the last source is remembered — `UserDefaults` had been truncating `Site.id` at its NUL; configuration sources are saved by name, switchable, each with its own cache; watch history binds to the configuration it was watched on | `docs/IOS-POC-10-plan-ux-and-sources.md` |
| 10 | Plan for five user-reported UI/data items, two of them decided by the user on the spot. **MPV paused**: on device, Metal + software decode reaches `FILE_LOADED` and still never fires `VIDEO_RECONFIG`, which rules out both the simulator and the network | `docs/IOS-POC-10-plan-ux-and-sources.md` |
| 9F | Installed on the iPhone 18 Pro. **libmpv initialises on real hardware, and so does CPython — `皮皮虾.py` runs the whole chain to real media bytes on device**, which closes the Python line's largest unverified gap. MPV rendering still needs the user to tap through the probe | `docs/IOS-POC-9B-mpv-playback-core.md` |
| 9E | Re-test. It overturned 9D's reading that Metal reliably reaches `FILE_LOADED` — it does not, run to run — and measured two MPVKit capability facts: its FFmpeg has no `lavfi` input and no PNG decoder | `docs/IOS-POC-9B-mpv-playback-core.md` |
| 9D | The OpenGL fallback, tried beside Metal rather than instead of it. It builds its render context and mpv reports the simulator as a software renderer, but it never reaches `FILE_LOADED`. **Both paths black; the simulator line is exhausted** | `docs/IOS-POC-9B-mpv-playback-core.md` |
| 9C | MPV rendering probe: libmpv draws through `CAMetalLayer`/`gpu-next`/MoltenVK. Vulkan device, HLS load and software decode all succeed on the simulator; **no frame ever reached the layer**, so the question moves to the device | `docs/IOS-POC-9B-mpv-playback-core.md` |
| 9B | MPV first unit: MPVKit 1.0.0 (non-GPL) wired into the App target and libmpv initialising inside the app. Static linking confirmed by symbol table, not just by configure flags | `docs/IOS-POC-9B-mpv-playback-core.md` |
| 9A | MPV second playback core: licence and provenance review. No blocker, conditional on MPVKit ≥1.0.0 non-GPL — every release before it carried `--enable-nonfree` | `docs/IOS-POC-9A-mpv-license-provenance.md` |
| 7R | Reconciliation: the handoff anchor and the spider spec rewritten against the actual HEAD and a fresh test/build run; no functional change | this document |
| 6A/6B | **drpy JavaScript loader**: the engine and its nine libraries fetched from the configuration's own origin, hash-pinned and verified before evaluation, running on the existing `JavaScriptSpiderRuntime` | `docs/IOS-POC-6A-drpy-loader.md` |

## Important Decisions

- Input baseline: Recha `wang-movie.json`, 125,864 bytes, SHA-256 `b17576e34eb42b4c589a818ef8b5ec2655a2c7a188d626fc427c37d628897168`, 167 sites (2 type-0, 22 type-1, 137 type-3, 6 type-4). The archive itself is external, not committed.
- **SUPERSEDED 2026-09-16 (IOS-POC-5A): the 90 `csp_*` sites are not “structurally out of reach”.**
  That verdict came from observing `classes.dex`, which says nothing about portability. The full
  static audit (`scripts/audit_spider_jars.py`, re-runnable) found **54 of the 90 sites portable**,
  spanning **26 of the 51 distinct classes** (33 rows in the audit, which keys a class per JAR);
  **34 sites / 23 classes** are blocked by a **native-encrypted payload** (`aowu-0722.jar`,
  `fan-0720.jar`) whose `csp_*` classes are empty shims; **2 sites / 2 classes** are only **missing
  downloads**, which is not a technical verdict. Authoritative tables:
  `docs/CSP_PORTABILITY_MATRIX.md` (audit) and `docs/CSP_MIGRATION_STATUS.md` (progress). Do not
  attempt to defeat the native protection on those two JARs.
- **The 42 Python sites are expensive, not impossible.** Measured 2026-09-16: only 1 of the 38 present `.py` files references `android.`; the rest are standard library plus `requests`, `pycryptodome` and the host-supplied `base` module. The blocker is embedding CPython and those packages, which is architecture-compatible. An earlier record counted them among the 132 "structurally out of reach" and that was wrong. The 5 drpy JavaScript sites are the most plausible of all, since iOS ships JavaScriptCore. Evidence: `docs/IOS-TYPE3-REACHABILITY-2026-09-16.md`.
- With type-0 done (IOS-POC-4J), **every non-Spider source type in this configuration is supported**.
  Since IOS-POC-5A/5B, 15 of the 137 type-3 entries are driven too — see the coverage table below.
- **The spider runtime reimplements the CatVod contract; it does not run Android code.** Every
  `Spider.java` method is text in, text out, so a JavaScript reimplementation is indistinguishable
  from the DEX original to everything above it. One `JSContext` and one serial queue per site, one
  shared `CatVodHost`, and `host.js` is the only JS SDK — a second runtime for drpy must never be
  built. Full contract: `docs/IOS_SPIDER_RUNTIME_SPEC.md`.
- The WebHome JS SDK is injected by the app, not shipped by pages: pages only touch `window.fm` / `window.fongmi`. Porting the bridge therefore means porting `HomeWebController.getSdk()`, not designing an API from the method list.
- Core names no hosting provider. A remote config source is an HTTPS URL and nothing more; GitLab and GitHub appear only in test and verification data.

## Completed Work

### Sources and browsing

#### Source coverage, from the 167-site `wang-movie.json`

Counted by `listsThePortedSpiderSitesAlongsideTheNativeCMSSites`, which asserts every number in this
table and passes at the current HEAD. Earlier revisions of this section said 45, 61 and 67; all are
stale. **The heading used to pin this table to `261b5c03`, "before the drpy sites"** — it is not
pinned to that HEAD any more, because the test is.

| group | sites | status |
|---|---:|---|
| type-0 MacCMS XML | 2 | listed |
| type-1 MacCMS JSON | 22 | listed |
| type-4 CatVod remote API | 6 | listed |
| type-3 `csp_*` spiders | 90 | **32 listed** through 8 ported classes |
| type-3 Python (`./py/*.py`) | 42 | **listed and driven since IOS-POC-7H/7P** under a remote configuration; 14 execute and 6 reach media bytes (this row said "not implemented — no Python runtime" until IOS-POC-11B) |
| type-3 drpy JavaScript | 5 | **listed and driven since IOS-POC-6B — but only under a remote configuration**, because the engine must come from the configuration's own origin |
| **total** | **167** | **62 listed from an imported file, 109 from a remote URL** |

62 + 5 drpy + 42 Python = 109. **This row said "67 from a remote URL" until IOS-POC-11B** and was
left stale by IOS-POC-7H, which put the Python sources in the picker; the handoff had already been
corrected on 2026-09-21 while this table had not.

**Listing is not playing, and the playable count is still unmeasured for everything except the
Python sources.** IOS-POC-7P measured those end to end — **14 of 42 execute, 6 reach media bytes** —
and IOS-POC-9F confirmed the same dependency and policy counts on the device. For the rest, the last
coherent sweep was **37 of 61 playable on 2026-09-17** (26 of 30 native, 11 of 31 spider), and it predates
three stages that change the answer: IOS-POC-5M added 薦片, IOS-POC-5P gave the player the request
headers the four `Bili` sites were failing without, and IOS-POC-5Q changed how `Bili` reports its
episodes. **Do not quote 37 of 61 as current** — quote 62 listed, and say the playable count has not
been re-measured since 5L. Per-site tables, both historical:
`docs/IOS-POC-5L-appqi-app99-app3q-bili.md` (61 sources) and
`docs/IOS-POC-5E-all-source-sweep.md` (the earlier 45).

**Provider state moves by the hour and a bad sweep is not a regression.** A run the same afternoon
as the 37/61 one collapsed to 10 playable with 9 TLS certificate failures that `curl` reproduced;
2026-09-17 and 2026-09-18 both had windows like that. Re-measure before calling anything broken.

**IOS-POC-5D closed the routing gap that used to sit here.** `ConfigView` lists
`drivableSites(resolvedBy:)` and every content call goes through `SourceClient`, which routes a
site to either `CMSClient` or a cached `SpiderSession`. The caption reads 「目前支援 62 個來源」.

#### The 90 `csp_*` sites

| bucket | classes | sites |
|---|---:|---:|
| portable (audit categories A–C) | 26 | 54 |
|  of which ported | 8 | **32** |
|  of which portable but not yet ported | 19 | 23 |
| blocked by native-encrypted payload (category H) | 23 | 34 |
| missing resource — JAR never downloaded, portability unknown | 2 | 2 |
| **total** | **51** | **90** |

Class counts above are **distinct class names**, so they sum to 51. The audit table in
`docs/CSP_PORTABILITY_MATRIX.md` keys a class per JAR and therefore shows 58 rows (33 portable);
a class shipped in two JARs still costs only one port. See `docs/CSP_MIGRATION_STATUS.md`.

Ported classes: `AppGet` (5 sites), `AppQi` (6), `App99` (4), `App3Q` (2) — four dialects of the
苹果CMS App-API — `Bili` (4, the public bilibili API), `JianPian` (1 — registered under the blocked
`JPianAmns` name the config uses), `XBPQ` (7, rule engine) and `XYQHiker` (3, rule engine). All are live-verified except `AppQi`, whose six sites resolve to four hosts that
were all dead on 2026-09-17; its `init`, decrypt, home and category are proven from one short
window in which one host answered, its detail and player are not. The two rule engines serve any future site configured for them
without further code, which is why they are worth more than their site counts suggest.

#### Native CMS notes

- type-0 is the same MacCMS contract as type-1 carried in XML, so it reuses `CMSClient` whole and changes only the decoder. `MacCMSXMLDecoder` (Foundation `XMLParser`, no dependency) turns `<class><ty>` into the categories and `<video>` into `Vod`, with `<dd flag>` becoming the flags through the same `$$$` encoding. The one query difference is `ac=videolist` instead of `ac=detail`, matching `SiteApi.ac(int)`. `XMLDocument` is macOS-only and is not an option on iOS. Type-4 extends `CMSClient` rather than adding a second client; its only structural difference is that its home returns categories, so the first browsable category fills the grid.
- Web-page episodes resolve through `?play=&flag=` before reaching the player, so an HTML page is never handed to AVPlayer.
- Category browsing has a parent row and a child row. `categoryGroups` pairs each `type_pid == 0` entry with its children; a source without `type_pid` becomes childless groups and renders as one row. A parent chip targets its first child when it has one and its own id otherwise, because childless parents do list content that way.
- Pagination loads the next page when the last card appears, for home, category and search. It stops when a page contributes no new `vod_id` rather than trusting page metadata, which also ends the loop for a source that ignores `pg`.
- Type-1 listings request `ac=detail`, the only form that carries `vod_pic`. That form drops `class`, so a type-1 home issues the plain and detail requests concurrently.
- Root-cause fix in the shared `Vod` decoder: `vod_id` and `vod_name` are optional, because `爱瓜TV` answers `ac=detail` without them and requiring them discarded the whole record.

### Playback

- The built-in player is a full-screen cover with its own close control, not a push inside the picker sheet. A page sheet is inset and rounded, so the player used to inherit those bounds and the app wallpaper showed around the video. Letterbox bars for a 16:9 video in a portrait screen are correct aspect-ratio behaviour and are left alone; the player now draws them on its own black background.

### Watch history (IOS-POC-5R)

- `WatchHistory` + `WatchHistoryStore` in `ios/Sources/WebHTVCore/WatchHistory.swift`: one JSON file
  in Application Support, written with `Data.write(options: .atomic)`, read behind an actor, pruned
  to 60 days (`Constant.HISTORY_TIME`) and 500 records. A corrupt file costs the history, not the
  launch.
- Fields follow `History.java` so `app.history` is a reproduction rather than an extension, and the
  formulas are Android's: `canSave()`, and `isNearEnding()` as one percent of runtime clamped to
  5–30 s. **The key is `Site.id`, not `siteKey`** — the configuration has four duplicate keys, and
  keying on the key alone would merge two providers into one record. `androidKey` (`siteKey@@@vodId`)
  is the only form that leaves the app, because a page splits it.
- `quality` is an iOS-only field: Android expresses every quality as a line, and since IOS-POC-5Q one
  line can carry several. It is deliberately absent from the `app.history` payload.
- Playback carries the site and title identity it never had. Position is sampled every five seconds
  **only while actually playing**, and written again on player close, on entering the background, at
  the end of an item, and on `control("stop")`.
- Reopening a title resumes it when the stored position is past ten seconds and not inside the
  near-end window; the detail screen marks the last episode; the 記錄 tab lists everything with
  「看到 m:ss / m:ss」. Only the built-in player is recorded — a URL scheme gives an external player
  no way back.

### Configuration

- The configuration comes from an imported file or any HTTPS Raw URL. `ConfigSource.resourceURL(for:)` resolves `./jar/…`, `./py/…`, `./json/…`, `./drpy_libs/…` against the config's own directory, drops the `;md5;<hash>` suffix, passes absolute references through, and refuses anything that is not a relative path so `csp_*` class names are never mistaken for resources. **This locates resources; it does not download, verify or execute them.**
- A failed remote load keeps the last known good cache. Validation requires at least one usable source, so a payload that parses but drives nothing cannot replace a working cache.
- Every launch re-fetches a remote source, retrying at 2 s, 5 s and 15 s, and stays silent on failure because the cached configuration is already on screen and the 上次更新 row shows its age. A manual refresh reports errors and does not retry.

### WebHome bridge

- `WKWebView` + `WKScriptMessageHandler` reproducing the Android string-RPC contract. Implemented: `net.request`, `player.playUrl`, **`player.playVod`, `player.playVodInline`, `player.control`, `player.status`**, `app.search`, `app.history`, `cache.get/set/del`, `ui.getViewport`, `ui.setToolbar`, `navigation.back`, `navigation.reload`, `site.info`, `config.info`, `ext.info`, `ext.log`, `ext.toast`, `device.info`.
- Android payload shapes are reproduced field for field including the fields iOS cannot fill; a missing value is zero, empty or false rather than omitted, so a page never reads `undefined`.
- Deviations, each commented in code: `net.resourceUrl` returns the raw URL (no local proxy server); results are never chunked, so the synchronous `resultLength`/`resultChunk` accessors are unnecessary; `app.history` **answered `[]` until IOS-POC-5R and now returns the real store** in Android's field shape, minus `quality`, which has no Android counterpart; `device.info` is built natively; Android-only gesture and system-bar insets are zero; `site.info` omits `homePage`, `chromeMode`, `webHomeChrome`, `header`; `config.info` has no `id` or `desc`.
- Still outside the bridge, each for a stated reason: `net.resourceUrl` proxying (no local server), `player.preloadArtwork` (`AsyncImage` has no preload hook, so it would be a no-op claiming success), `app.open*` (no Live or Keep screen), `pan.*` (no drive-check service), `ui.setChrome` / `restoreChrome` (no equivalent surface). All reject with the same `Unknown method` the Android default branch produces.

### Playback session (IOS-POC-2E)

- One `@MainActor` `PlaybackSession.shared` in the app target owns a single `AVPlayer` for the app's lifetime and swaps items into it, so no view observes a changing player object. It adds only what `AVPlayer` has no concept of: the inline playlist and index, the page-supplied title and artwork, and the repeat flag. Android's equivalent is the process-wide `PlaybackService` behind `Server.get().getService()`.
- `PlayerView` no longer creates its own player; closing it pauses rather than tears down, which is what lets a WebHome page read a live `player.status` and resume with `player.control` — the page is only on screen once the player is gone.
- Every playback path now feeds that one session: the CMS grid, `player.playUrl`, `player.playVod` (which resolves `siteKey` against the loaded config and opens the existing `VodView`) and `player.playVodInline` (which goes straight to the built-in player, since a playlist and `control` semantics are things an external player cannot honour).
- `player.status` reproduces Android's **`net.request` envelope**, because Android fetches `/media` over its own local HTTP server; the envelope is reproduced field for field and the HTTP hop is not. Durations and positions are milliseconds, as Media3 reports them.
- An unknown or empty `siteKey` rejects with `Unknown site: <key>` instead of opening a screen that fails later — the showcase page ships that field empty, so a page reaches it immediately.

### Spider runtime (IOS-POC-5A / 5B)

- `ios/Sources/WebHTVCore/Spider/` holds the 13-method `SpiderRuntime` ABI mirroring `Spider.java`,
  `SpiderRegistry` (class name → script + audit metadata), `SpiderSession` (the actor that guarantees
  `init` runs exactly once before any content call), `CSPSourceResolver` (the routing change: the
  question became “is this class registered?” instead of “is this type 3?”) and
  `JavaScriptSpiderRuntime` (one `JSContext` and one serial `DispatchQueue` per site).
- `Spider/Host/` is the native half of `CatVodHost`: HTTP with a per-host cookie jar, AES/DES,
  MD5/SHA/HMAC, and per-site namespaced storage. `Resources/Spiders/host.js` is the JavaScript half:
  `pdfh`/`pdfa`/`pd` selectors, `host.cut` text slicing, and the CatVod result builders.
- A spider that re-implements HTTP, crypto or parsing is a bug — the primitive belongs in
  `CatVodHost`. `RSA` and `proxy` host plumbing are **not implemented**; `csp_AppDrama` needs RSA
  before it can be ported. **WebView sniffing is implemented** — `MediaSniffer` since IOS-POC-5G —
  but natively, above the spider, not as a `host.*` primitive; an earlier revision of this line
  listed it as missing, contradicting `docs/IOS_SPIDER_RUNTIME_SPEC.md`, which is the authority.
- `XBPQ`'s 331 rule keys were recovered by decoding the decompiled `merge/xbpq/HaB.d` string table
  (hex + XOR `"wxEesU"`). That is ordinary bytecode inspection, unrelated to the native-protected
  JARs, which are left alone.

## Build / Test / Verification Status

**Latest — after IOS-POC-17F (`b37751d2`), 2026-09-24:** `swift test --package-path ios` → **344 tests, all pass**
(the weather test passed this time). Measured on the way: `dde455ba` (after IOS-POC-18) 326／325, after 16B 335／334,
after 15D 340／339 — the only failure each time was the weather test `reportsLiveType4SitesFromProvidedConfig`;
17E measured 323／323. Simulator Debug build after 17F → **BUILD SUCCEEDED**, no new warnings.

**Earlier — IOS-POC-17B, 2026-09-23:** `WANG_MOVIE_JSON=<user config> swift test --package-path ios`
→ **322 tests, all pass** (297 − 1 removed external-player test + 1 removal scan + 25 dual-engine
tests); the weather test passed this time. Simulator Debug build → **BUILD SUCCEEDED** after 17B and
again after 17C. **No device build.**

**Earlier, measured on macOS 2026-09-23 at `61f2d6fd`:**

- `swift test --package-path ios` → **228 tests, 227 pass, 1 fails**. The failure is
  `reportsLiveType4SitesFromProvidedConfig` (`CMSClientTests.swift:212`, `isDirectMedia(resolved)`),
  **which is weather and not a gate** — it is a live-provider case that has failed and passed on the
  same day before, once with a TLS error `curl` could not reproduce a minute later. **Do not "fix"
  it.** The +3 over IOS-POC-5S-2's 225 are the PiP foreground-restore lifecycle-gate tests.
- Simulator Debug build (`id=7B4E9557-4774-4EB9-B408-BB544DCC8657`) → **BUILD SUCCEEDED**.
- **This run closed a real gap.** The session that wrote the PiP fix and its three tests ran on a
  **Linux host with neither `swift` nor `xcodebuild`**, so that code was committed — and `0.1.5 (6)`
  was published from it — without ever being compiled or tested locally. It compiles and its tests
  pass. **The defect itself is still open**: it is a real-device PiP presentation bug and
  `docs/bugs/IOS-PIP-foreground-restore.md` still owns its unchanged device acceptance.

**Previously, 2026-09-22 at base HEAD `eba5346c` (IOS-POC-5S-2):**

- `swift test --package-path ios` → **225 tests, all pass** (203 before this stage). The +22 are
  IOS-POC-5S-2's: an old history file with neither field still decoding, as one record and as a whole
  list; both fields round-tripping through the store; the start position on either side of
  `max(opening, resume)`; an unset opening leaving resume untouched; a watched-to-the-end title
  replaying from its opening; the next episode taking the opening but not the previous episode's
  position; the ending threshold either side of the boundary; an unset, zero or negative ending never
  firing; an unknown duration never firing; `getOpEdLimit`'s three bands and the markable window;
  four clamp cases (opening past the end, an ending eating the opening, an opening inside the ending,
  both floored at zero); an unknown runtime clamping only at zero; `NaN`/`Infinity` refused; nothing
  crossing a title, a site or a configuration; one record covering every episode and line of its
  title; and `app.history` carrying both set and unset values.
  **The live provider tests passed in this run.**
- Simulator Debug build (`7B4E9557-4774-4EB9-B408-BB544DCC8657`) → **BUILD SUCCEEDED**, re-run after
  the Ponytail final-diff fixes rather than before them.

**Previously, at `616e182e` (IOS-POC-11F):**

- `swift test --package-path ios` → **203 tests, all pass**. The trajectory since IOS-POC-11B's 188:
  +9 for IOS-POC-5S-1 (the real 63-entry ads data set as 62 literal domains plus one intentionally
  inert whole URL, real `WKContentRuleListStore` compilation, top-document safety, blocked
  subresources, unrelated resources left alone, A→B→A configuration switching, empty ads) and
  +6 for IOS-POC-14 (`Flag.episode(after:)`: the next episode, the last one answering nil, a
  single-episode line, an episode not on the line, repeated names, an empty line).
  **The live provider tests passed in this run.** They are weather: `reportsLiveType4SitesFromProvidedConfig`
  and `completesLiveCMSFlowFromProvidedConfig` have each failed and passed on the same day, once
  with a TLS error that `curl` could not reproduce a minute later. **Neither is to be "fixed".**
- Simulator Debug build (`7B4E9557-4774-4EB9-B408-BB544DCC8657`) → **BUILD SUCCEEDED**.
- **No device build in this session.** The iPhone 18 Pro reports `unavailable`, and **since
  2026-09-22 the user installs through SideStore**, so a build reaches the phone as a published IPA
  rather than by `devicectl install`. Do not install to the device directly.
- **The release pipeline builds it too**, on GitHub `macos-26` with no local state. The most recent
  is `WebHTV-0.1.6-7.ipa` (24,650,445 bytes), unsigned, re-signed on the device by SideStore.
  `WebHTV-0.1.5-6.ipa` (24,601,187 bytes) is the one before it.
  Each release was downloaded back and its `Info.plist` checked against the version it claims.
- `third_party/python-ios/` is present (78 MB) with the five vendored wheels in `site-packages`, so
  the Python path is buildable on this machine without a re-fetch.
- Simulator, from the app's own launch path:
  `[python] boot running(version: "3.13.15")`,
  `[python] selfcheck 13/13 methods OK, errors propagate`,
  `[python] live OK [🏆｜銅牌｜高清] init → home(5) → category(21) → detail → search(1) → player → probe(media)`.
- `scripts/audit_python_spiders.py --config <the user's GitLab URL>` → 42 sites classified.
- **Device verification of the Python runtime has been run** (IOS-POC-9F): `皮皮虾.py` ran the whole
  chain to real media bytes on the iPhone 18 Pro, and the 42-site survey ran there too with the same
  dependency and policy counts as the simulator. This bullet read "Not run: any device verification
  of the Python runtime. Everything Python is simulator-only" until IOS-POC-11B, contradicting a
  section further down this same document.


Everything in this section is from **HEAD `261b5c03`** unless it names another stage or date; the
test and build lines below were re-measured at **`bb965dda` on 2026-09-21**. The three
conflicting test counts that used to sit here (77/76, 96/95, 110/109, each from a different HEAD)
have been collapsed into the first bullet.

- **143 tests** — `WANG_MOVIE_JSON=<config> swift test --package-path ios`, measured 2026-09-18 and
  **re-run three times on 2026-09-21 at `f34ae805`, `67e72604` and `bb965dda`: 143 passed each time.**
  **Either 142 or 143 pass**, and which one is not a property of this code: the only test that ever
  fails is the live-network `reportsLiveType4SitesFromProvidedConfig` in the next bullet, which went
  fail, fail, pass, fail, pass across five runs on the same day. The trajectory: 96 at `d571f3a7`,
  110 after IOS-POC-5Q, 124 after IOS-POC-5R, 140 after the drpy loader, 143 after the sniffer's
  wrapper handling.
- **`reportsLiveType4SitesFromProvidedConfig` passed this run, and that is not a change in the
  code.** It is a live-network check: 88看球 resolves an episode to an HTML page, and the test
  asserts direct media through `CMSClient`, which has no sniffer hop. It failed twice earlier on
  2026-09-18 and passed on the third run, which is exactly what a provider-state check looks like.
  **Do not "fix" it when it fails.** The sweep classifies that site as playable *through
  `SourceClient`*, the path the app actually uses; the two disagree because they drive different
  layers.
- **The suite is stable across runs since IOS-POC-5H.** Four bridge tests used to fail
  intermittently; they recorded callbacks through a detached `Task` and read the result immediately.
- `xcodebuild -project ios/WebHTVApp/WebHTVApp.xcodeproj -scheme WebHTVApp -destination 'platform=iOS Simulator,id=7B4E9557-4774-4EB9-B408-BB544DCC8657' -configuration Debug build` → **BUILD SUCCEEDED**.
  **The destination must now be an id, not a name.** An iOS 27.0 runtime appeared on this machine on
  2026-09-18, so `name=iPhone 17 Pro` matches two devices (26.0 and 26.3) and xcodebuild refuses to
  choose. That UDID is the iOS 26.3 device every simulator result in this document came from.
- Gated live checks stay off by default: `WANG_MOVIE_URL` (remote config), `CSP_GOLDEN_SITE` (spider
  goldens, including IOS-POC-5Q's own `biliOffersMultipleQualityLines`), `SWEEP_CONFIG` +
  `SWEEP_BASE` (the whole-configuration sweep).
- **Toolchain: Xcode 27 / Swift 6.4.** It changed mid-session and the project stopped building at the
  then-current HEAD; the Swift 6 region-isolation repairs are recorded in the IOS-POC-5D document.
  There is no older Xcode on this machine.

### Live golden runs

- **2026-09-18 (IOS-POC-5Q).** `biliOffersMultipleQualityLines` — a bilibili title returned
  `B站 清晰 480P` and `B站 流畅 360P`, distinct `qn`, best first, and the best line's stream probed
  as `.media`. Only 480P/360P were on offer because `qn > 80` needs a SESSDATA the configured sites'
  2025 cookies cannot supply: that measures the account, not the port.
  `appGetDrivesTheWholeCatVodFlowAgainstTheLiveSite` passed unchanged, which is what proves the
  single-string `url` path did not move.
- **2026-09-17, all three then-ported classes, each ending in `parse:0`:** `AppGet` (王子) home 6
  classes → category 30 items → detail 5 flags → search 20 → `…/index.m3u8`; `XBPQ` (果果短剧) 8
  classes → 30 items → `…/index.m3u8`; `XYQHiker` (农民影视) 5 classes → 30 items → flags
  `[线路①, 线路②]` → search 20 → `….m3u8`.

### Simulator runs (iPhone 17 Pro)

- **IOS-POC-8K, 2026-09-21.** Two requests.
  - **The source picker opens on the source in use.** It was a `Menu`, which is a `UIMenu` and
    cannot be scrolled to an item, so with a long list it always opened at the first one — 67 at the
    time of that fix, **109 since IOS-POC-7H**. It is now
    a sheet holding a `List` inside a `ScrollViewReader`, and `onAppear` scrolls the selected id to
    centre. **Confirmed:** with 王子 selected — 40-odd rows down — the sheet opens with 王子 and its
    checkmark in the middle of the screen, not at 無水.
  - **Pull to refresh on the listing.** `.refreshable` on `CMSView`'s `ScrollView`, calling the same
    `load` the category chips use: the search results while searching, otherwise the listed
    category, otherwise the home listing. `load` already resets `page` and `canLoadMore`, so a
    refresh also drops paging back to page one.
  - **Partly verified.** The modifier is on the `ScrollView` and the gesture leaves the screen
    correct, but the spinner is transient and no screenshot caught it, so the refresh was not
    watched happening. One pull on the device settles it.

- **IOS-POC-8J, 2026-09-21.** 8I's blocks were cut by **position**, and the user caught it on the
  device: the block labelled `1-100` ran to 第109集. The cause is that a source may merge episodes
  into one entry — 稀有祖宗 carries `第1-8集`, `第9-10集`, `第95-96集`, `第115-117集` — so the 100th
  *entry* is not 第100集. The split now reads the number the source printed (first run of digits,
  which also survives the malformed `-第98集`) and breaks on it; the chip is labelled from the
  numbers actually inside the block, so it cannot disagree with the grid beneath it. A line that
  prints no numbers at all still falls back to fixed blocks of 100 entries.
  **Confirmed on 稀有祖宗 (王子, `csp_AppGet`, 119 episodes over two lines):** the chips read
  `1-100` / `101-119` (was `1-100` / `101-108`), the first block ends at 第100集 (was 第109集) and
  the second begins at 第101集 (was 第110集).

- **IOS-POC-8I, 2026-09-21.** Two user requests, both confirmed on the simulator against live sources.
  - **No synthetic 全部.** The app used to prepend its own 全部 in three places: the category row
    (`parentChips`) and the filter rows built by `AppGet.js` and `AppQi.js`. All three are gone, so
    the row is the source's own list. Confirmed on 紅果短劇 (`csp_JPianAmns`), whose `CLASSES` holds
    exactly 电影/电视剧/动漫/综艺/短剧 — the row now shows those six categories and no 全部, where the
    user's own device screenshot of 荐片 had shown an extra one. A source that **does** send its own
    "all" entry keeps it: 王子 (`csp_AppGet`) still leads with 全部 (`type_id: 0`), and its 排序 row —
    the one row whose API sends no 全部 — now correctly starts at 最新.
  - **100-episode blocks.** 稀有祖宗 on 王子 has 108 episodes per line. The picker shows `1-100` and
    `101-108` above the grid; selecting the second lists 第110集–第119集 only. The blocks are per
    line, verified by `JS线路` sitting on `101-108` while `SB线路` stayed on `1-100`. A line with
    ≤100 episodes gets no chip row at all, and the default block is the one holding the remembered
    episode.
  - Not covered: `AppQi.js` carries the identical edit but no live AppQi source was exercised; three
    type-1 CMS sources (愛瓜, 菠菜, 360) were unreachable this session — one timeout, two invalid
    certificates — which is a source-side fault, not a regression.
  - Known consequence, accepted by the user: the removed chip was also the only way back to the
    unfiltered `home()` listing. Sources whose home returns a distinct recommendation list can no
    longer return to it after a category is picked. 荐片 is unaffected because an empty home already
    fell back to the first category, which is what its 全部 chip had been re-listing.

- **Confirmed on the real device, 2026-09-18 (IOS-POC-8H).** The iPhone 16 Pro run of `feeb1407`
  was signed and installed with the command line settings as before, and **the user confirmed both
  fixes on hardware: no black band, and the search field behaving.** That is the **second** device
  run this project has had, and the first that verified a change rather than finding defects. It
  covers IOS-POC-8F and 8G only — everything else in this document is still simulator-only, and the
  three items below remain unchecked on hardware.
- **IOS-POC-8G, 2026-09-18.** All three tabs (首頁／記錄／設定) screenshotted with no black band; the
  wallpaper runs under the floating glass tab bar. 荐片 re-checked for the IOS-POC-8B relayout tells
  and shows none, and a detail screen renders normally.
- **IOS-POC-8F, 2026-09-18.** 愛瓜 loaded and scrolled down until the search field hid → source menu
  → 菠菜 lists from the top **with the search field back**, and it still hides on the next scroll.
  The three failed attempts above were each driven through this same sequence and each left the
  field gone, which is what makes them worth recording rather than re-trying.
- **IOS-POC-8E, 2026-09-18, on the remote configuration (67 sources at the time; 109 today).** Before the fix: 愛瓜 scrolled
  down → source menu → 菠菜 listed from the top **with no search field**, and it came back only on an
  over-scroll. After the fix the same sequence keeps the field, and so does 荐片 → 愛瓜. 荐片 renders
  its category row and all four filter rows clear of the field at rest, while scrolled, and with the
  field focused; the grid keeps its 12 pt margin. Search itself still submits: on 360 高清,
  `the` returned `X The League`, `Happy Together`, `The One Shot`, `The Scout`. **A source answering
  「暂不支持搜索」 looks identical to a search that did not fire** — 菠菜 does exactly that
  (`curl` confirms the provider, not the app), and because the error surface only renders on an empty
  grid the old list simply stays. That is the known error-surface limitation, not a defect found here.
- **IOS-POC-5R end to end, 2026-09-18** — the fullest one on record. `愛瓜 PHP` → `莲花楼` →
  普快线路 01 → the player sheet showed **no quality section**, which is the correct behaviour for a
  single-URL source and the reverse check on IOS-POC-5Q. Sixteen seconds in, the app container held
  a record keyed on `Site.id` with `position 28261`, `duration 2796399`, flag `普快线路`, episode
  `01`. Closing the player advanced it to `44292`. The detail screen came back with episode 01
  marked. The 記錄 tab listed 「莲花楼 / 愛瓜｜PHP · 普快线路 · 01 / 看到 0:44 / 46:36」. Replaying
  from that list read `53487` after seven seconds — it **resumed rather than restarted**.
- **IOS-POC-5Q, 2026-09-18.** `bilbil合集` browses, filters and renders its grid. The detail screen
  was not reached that day: taps on the grid cells did nothing. **That did not reproduce in the 5R
  run above**, where grid cells and episode buttons both responded, so the earlier failure was more
  likely coordinate mis-mapping than the known synthetic-tap defect. Neither confirms nor clears it.
- Earlier: `爱瓜TV` grid → 莲花楼 detail with 41 episodes → episode 01 plays. Type-1 `如意` and `360`
  grids load with posters and both category rows. Pagination scrolls past the first page.
- WebHome bridge with the unmodified devkit showcase page: badge reads `SDK: native`; `fm.req JSON`
  logged `req-json ok (799ms)`; the HLS button played; `cache-set ok`; `ext-info` and `config` logged
  real payloads; `legacy hide`/`show` removed and restored the navigation bar.
- **IOS-POC-2E/2F from the page:** `vodInline 多集` played the inline MP4; with the player closed,
  `播放状态` returned a live envelope (`duration 90080`, `position 28136`, `state 2`); `fm.ctrl play`
  advanced it to `state 3`; `next` switched url and title; `pause` returned `{}` and the next status
  read `speed 0`. `fm.vod` with `vod_360` / `101020` opened the native detail screen and played
  episode 1.
- Remote config against the real GitLab Raw URL (measured at IOS-POC-1F): 125,864 bytes, 167 sites,
  cached SHA-256 identical to the remote, resolved `jar/fm.jar` HTTP 200. An unreachable URL left the
  sources and cache intact. Launch retry proven with a local server armed to fail twice.

## Risks / Unverified

**IOS-POC-5S-2 opening / ending, added 2026-09-22 — all of it is simulator-and-unit-test evidence:**

- **No device run.** Every claim below rests on `swift test` and a simulator build.
- **The player overlay's placement has not been seen on hardware.** The trailing edge, vertically
  centred, was chosen because it is the part of `AVPlayerViewController`'s full-screen layout that
  neither the top bar (Done / PiP / AirPlay) nor the transport bar occupies — **reasoned from the
  layout, not measured against a real device**. If it collides with anything, moving it is one
  `alignment:` argument.
- **The `Menu` sits over the volume-drag half of the screen.** The drag needs 12 pt of movement and
  a tap should be consumed by the button, but that interaction has not been exercised by a finger.
- **The five-second sampler means up to five seconds of the ending can play before the skip.**
  Android's clock is one second. Whether the lag is acceptable is a subjective device question. The
  `ponytail:` note names the two upgrade paths (`addPeriodicTimeObserver` at 1 s, or
  `AVPlayerItem.forwardPlaybackEndTime` once the duration is known).
- **The ending firing while Picture in Picture holds the video was not tested.**
- **No real WebHome page has read a non-zero `app.history.opening`/`ending`** — bridge unit tests
  only, which is the same gap IOS-POC-5R recorded for the rest of that payload.
- **The migration is asserted, not observed on a real phone's file.** The tests decode the exact
  legacy JSON shape, including a whole array, but nobody has upgraded a device that already had
  history and watched it survive.

**Python, added 2026-09-21:**

- ~~**Nothing Python has run on a device.**~~ **Superseded 2026-09-21 (IOS-POC-9F):** on the
  iPhone 18 Pro the interpreter boots, the 13-method self-check passes, and `皮皮虾.py` runs
  `init → home → category → detail → search → player → probe(media)` end to end on device. The
  42-site survey ran on hardware too: **driven 5/42**, against 6/42 on the simulator, and the
  dependency and policy tallies are **identical** — `Crypto` 17, `lxml` 3, `pyquery` 2, `bs4` 2,
  policy-refused 4. The one-site difference sits in the content layer, which is provider state.
- **The payload is not in the repository.** `third_party/python-ios/` is ignored; a fresh clone must
  run `scripts/fetch_python_ios.sh` (the Xcode "Prepare Python" phase calls it, so a build does this
  by itself — but an offline machine cannot build until it has run once).
- **`Prepare Python` rewrites a file under `third_party/python-ios/` on every build** (the module map
  clang needs). Idempotent and untracked, but its proper home is the fetch script.
- **What the Python line buys is measured, and still modest**: after IOS-POC-7P vendored `requests`,
  **14 of 42 sites execute and 6 reach media bytes** (it was 4 and 1 before). Do not quote a larger
  number from the P1 assessment, which estimated before any of it ran.
- **Still blocked on a dependency: 24 sites** — `Crypto` 17, `lxml` 3, `pyquery` 2, `bs4` 2. `bs4` is
  pure Python and would go the same way `requests` did; `Crypto` is the big one and `CatVodHost`
  already has AES, DES, MD5, SHA and HMAC to shim over. **Neither was started.**
- **`麒麟影视.py` counts as executing only until something calls the method its `import requests`
  hides in.** It is not a Tier-1 site in any durable sense.
- **The survey hammers the configuration origin** — one script fetch per site. Running it twice after
  the audit made GitLab stop answering entirely, which read as "driven 0/42" and was false. It now
  paces at 400 ms; do not remove that.


- **It has now run on a real device — once, on 2026-09-18 (IOS-POC-8A).** An iPhone 16 Pro, signed
  with the personal Apple ID `st7833232@gmail.com`, team `764SVXY2B7`. **The project file still has
  no `CODE_SIGN` or `DEVELOPMENT_TEAM`**: the settings were passed to `xcodebuild` on the command
  line so nothing personal was committed —
  `DEVELOPMENT_TEAM=764SVXY2B7 CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates` with
  `-destination 'platform=iOS,id=<device udid>'`, then `xcrun devicectl device install app`.
  **The provisioning profile is a free-tier one and expires seven days after issue**, so the app
  stops launching and must be reinstalled; a paid account or SideStore is the way out of that.
  **Everything else in this document is still simulator-only** — one device run is not a device
  verification pass.
- **Confirmed on that device run:** Chinese and the site names' emoji render correctly, which
  settles that the simulator's `.notdef` boxes are the runtime's missing font set and not this app
  (IOS-POC-5V's Debug-only workaround is therefore correctly scoped). A remote configuration loaded
  and the app listed **67 sources — the count on 2026-09-18, before IOS-POC-7H added the 42 Python
  sources; the same run today would list 109**. Either way it is only reachable through the remote
  path, so it also confirms the five drpy sites route correctly on device.
- **Found by the device run and fixed the same day — three defects, each hidden for a different
  reason.**
  1. **A fresh install could only ever import a file.** The remote-URL entry lives in the settings
     page, the settings page lives in the tab bar, and the tab bar only exists once a configuration
     has loaded, so the one screen a new install shows was missing half its purpose. **The simulator
     could not have caught it**: it always had a configuration cached by an earlier session, so the
     empty state was never exercised. It now offers both ways in, calling the `useRemote`
     `ConfigView` already had.
  2. **A black band sat under the tab bar on every screen.** `appWallpaper()` was a `.background`,
     and a background is bounded by the view it decorates: on a `TabView` it stops at the content
     area, so hiding the tab bar's own background revealed the window rather than the wallpaper. It
     is a `ZStack` now, the image behind as a sibling that nothing clips. **This one did reproduce
     in the simulator** and is visible in every screenshot this project has taken — it took a real
     phone for anyone to name it.
  3. **The wallpaper fix in 2 was wrong and is reverted (IOS-POC-8D).** Making `appWallpaper()` a
     `ZStack` put every screen inside a container whose other child ignores the safe area, so
     content laid out against the window instead: row labels clipped at the left edge, posters
     bleeding to the screen edge, and the grid running under the navigation bar so the search field
     covered the category and filter rows. **Two ways of covering the tab bar were tried and both
     relayouted content**, so the black band — which predates today and is cosmetic — is left alone,
     with the attempts recorded in the code so nobody repeats them.
  4. **The player's close button sat in AVKit's corner.** iOS puts its video-output control top-left
     and mute top-right; the custom close button crowded the first. Moved below that row rather than
     to another corner, because AVKit owns both top corners and the bottom. **Only the simulator's
     different AVKit layout hid this.**
- **The three UI defects the user reported from the device were re-tested on a clean build
  (IOS-POC-8E, 2026-09-18), and only one of them was real.** The build they saw carried the 8B
  wallpaper regression, so the first job was to see which complaints survived its revert. Driven in
  the simulator against the remote configuration, on 荐片 because it publishes a category row plus
  four filter rows:
  1. ~~**「海報沒有留外圍的邊」**~~ **did not reproduce.** The grid keeps its 12 pt padding on all
     four sides and the cells sit level with the category chips. This was 8B's
     「posters bleeding past the screen edge」.
  2. ~~**「搜尋框會擋住分類跟篩選列」**~~ **did not reproduce** at rest, while scrolled, or with the
     field focused: the category row and all four filter rows stayed clear. This was 8B's
     「the grid running under the navigation bar」.
  3. **「切換內容來源之後搜尋框會不見」 did reproduce, and is fixed.** It needs one precondition the
     report did not mention, which is why it looked intermittent: **the previous source must be
     scrolled down when the menu is opened.** The search field hides on scroll, that hidden state
     belongs to the navigation bar rather than to the grid, and `HomeView` rebuilds `CMSView` under
     a new `.id` on every switch — so the new grid starts at the top while the bar keeps the
     collapse it learned from the destroyed one. The field stayed gone until the user over-scrolled.
     Fixed by `placement: .navigationBarDrawer(displayMode: .always)`, UIKit's
     `hidesSearchBarWhenScrolling = false`: a field that never collapses has no state to carry
     across the swap. **The cost is that the field now occupies its row permanently**, and content
     scrolls underneath it.
- **8E's always-visible search field was replaced at the user's request (IOS-POC-8F, 2026-09-18).**
  They asked for the field to hide on scroll again, which meant fixing the navigation bar's stale
  collapse rather than removing the collapse. **Three pure-SwiftUI attempts were built and measured,
  and none of them worked:**
  1. **Hoisting `.searchable` above the grid's `.id`**, into a shell view that a source switch never
     replaces, so the search controller itself survives. No effect — the replacement `ScrollView` is
     born at offset 0 and never raises a scroll event, so the bar has nothing to re-evaluate on.
  2. **Resetting the listing in place**, dropping the `.id` entirely so the scroll view is never
     replaced at all, plus `proxy.scrollTo(topAnchor)`. No effect: scrolling a view already at the
     top is not a scroll.
  3. **Scrolling the old listing to the top first**, while it was still tall enough for that to be a
     real offset change, and swapping the content on the next turn. No effect either.
  **What worked is moving the `.id` up to the whole `NavigationStack`.** A new stack is a new
  navigation bar, and a new bar has no collapse to remember. The functional diff is one modifier
  moved one level up and `placement:` deleted; the three failures are recorded in the code so nobody
  repeats them. **The bleed-through note below is now historical** — with the field hiding on scroll
  again it is only ever over the wallpaper, not over the grid.

  **Dropping `appNavigationBar()` on `CMSView` to put a material behind that pinned field was tried
  and reverted — it changed nothing on screen.** iOS 26 draws this navigation bar as per-control
  glass, not as a full-width background, so there is no material to opt into; scrolling content
  shows through the search field either way, exactly as it already showed through the status bar and
  the source chip before this change. **That bleed-through is pre-existing chrome behaviour, not
  new**, and the attempt is recorded in the code the way 8D's were. Restructuring so the field hides
  on scroll again — hoisting `query` and `.searchable` out of the `.id()` into `HomeView` — was
  weighed and rejected: about twenty lines across two views plus a second search path for the
  WebHome bridge sheet, to buy back a transient cosmetic overlap.
  **Ponytail, before:** the ladder stops at the native-platform rung — `SearchFieldPlacement` already
  expresses this, so no state, no restructuring and no new view. **Ponytail, after:** the functional
  diff is one line in one file; nothing was abstracted, and the one addition that earned nothing was
  taken back out. Two of the three reported defects were closed by reproducing them rather than by
  writing code.
- **The black band behind the tab bar is fixed (IOS-POC-8G, 2026-09-18), and the diagnosis it had
  carried since IOS-POC-8B was wrong.** That record said the bar sits outside the content view's
  frame and that nothing reachable from a background modifier draws there, so the band was written
  off as permanent and cosmetic. Both halves were false. **`appWallpaper()`'s image was
  `scaledToFill`, which sizes the image to its own aspect-filled bounds rather than filling its
  container — so `.ignoresSafeArea()` had nothing to expand and the wallpaper stopped at the safe
  area.** Wrapping it in a `Color.clear` that does fill, and moving `.ignoresSafeArea()` onto that,
  runs the wallpaper to the bottom of the window on all three tabs. It is still a `.background`, so
  the IOS-POC-8B relayout trap is untouched: 荐片 was re-checked and its filter labels are unclipped,
  the poster grid keeps its 12 pt margin, and the detail screen is unchanged.
  **Four heavier things were built and measured first, and all four failed.** Colouring
  `UIWindow.appearance()` and `UITabBar.appearance()` — neither ever appeared, which is what ruled
  out the window and the tab bar as the painter. Then a probe walking up to the tab bar controller
  and inserting a wallpaper image view at the bottom of its container — installed correctly,
  confirmed in a logged view hierarchy, and invisible because every hosting view above it paints an
  opaque `systemBackground`. Then clearing those backgrounds — SwiftUI re-applies them on its next
  layout pass. **The lesson is recorded in the code: do not reach into UIKit for this.** The view
  hierarchy dump that settled it is worth re-deriving rather than guessing if this ever regresses.
- **The app has an icon and an asset catalog since IOS-POC-8C.** The project had neither: its images
  were loose files read through `Bundle.main.path(forResource:)`, which cannot supply an app icon —
  iOS needs a compiled `Assets.car` and `CFBundleIconName`. A single 1024×1024 entry is enough on
  iOS 17+. The source art was a rounded square on white, so it is cropped past its own corner radius
  (~22%) until the gradient reaches all four edges; leaving it would have shown white slivers
  wherever iOS's mask radius disagreed with the artwork's.
- **Not measured: that HTTPS certificate validation is still enforced.** It is reasoned from the code — no `URLSessionDelegate`, no `serverTrust` handling anywhere — but no test against a known-bad certificate was run.
- Not driven from the WebHome page, covered only by offline tests: `cache.get`, `cache.del`,
  `app.search`, `app.history`, `device.info`, `site.info`, `ui.getViewport`, `ext.toast`,
  `navigation.back`, `navigation.reload`. **`app.history` answers real data since IOS-POC-5R** — it
  is on this list because no page has asked it for that data yet, not because it is still a stub.
- **IOS-POC-2F closed the playback gaps.** All seven `player.control` actions and the inline JS resolver have now been driven from the page; see the IOS-POC-2F section of the 2E document for the evidence. No code changed.
- `player.status.position` is the media's own playhead. A reading taken after a control tap includes the delay between the two taps — an earlier reading of `6000` right after `replay` was misread as an HLS timeline origin offset, and the normalisation written for it was measured, disproved and reverted.
- `player.playUrl` reports an empty `artwork` because `Actions.play` carries only a URL and a title; `playVod`, `playVodInline` and the CMS path all report the real poster.
- Playback has no background audio, media session or lock-screen controls. Closing the player pauses it; the session keeps the item so `player.status` still answers.
- Remote reachability is highly volatile. `itv666.cc` went from HTTP 200 to DNS failure within ten minutes, and the GitLab Raw host was unreachable for about a minute mid-session. Never treat one site's failure as a global app defect.
- `URLSession.webHTV` caps request inactivity at 10 s. A type-4 home issues two sequential requests, so its worst case is about 20 s. This is an inactivity timeout, not a total-transfer cap. AVPlayer playback does not use this session.
- A failed next page stops pagination silently, because the error surface only renders when the grid is empty.
- The direct-media test is a path-extension heuristic, marked `ponytail:` in `CMSClient.swift`.
- The `ac=detail` form costs bandwidth: a 20-title page on `360zy` grew from 6.5 KB to 49 KB.
- `drpyS_听友[听]` returns an empty list for all 43 of its categories, and `php_无水印资源` answers HTTP 403. Both are provider state, not app defects.
- The Debug-only CJK font fallback does not fix the log panel's `[上午…]` prefix, and says nothing about a real device.
- **The simulator's font set is incomplete, and that is not an app defect (IOS-POC-5V).** Every site
  name in this configuration starts with an emoji, and the iOS 26.3 simulator runtime draws all of
  them as `.notdef` boxes. Measured 2026-09-18: the runtime ships **no PingFang** — only Hiragino and
  Kohinoor — and although `AppleColorEmoji-160px.ttc` (136 MB) sits in
  `System/Library/Fonts/CoreAddition/` it is never picked up. **Safari on the same simulator renders
  🎡, 蓮花樓 and even the fullwidth ｜ as boxes**, which is what proves the gap belongs to the
  runtime; the app's own CJK survives only because SwiftUI falls back to Hiragino. A real device has
  the full set. `String.displayName` in the app target drops the undrawable characters **only in a
  Debug simulator build** so screenshots are legible; Release and device builds show the name
  verbatim, and the stored, bridged and searched name is always the real one. This is the same shape
  as IOS-POC-2C's Debug-only web-view fallback, added for the same underlying reason.
  **Delete it when the simulator ships a complete font set.**
- ~~**A spider play result's `header` is dropped.**~~ **Fixed in IOS-POC-5P**: `SourceClient`
  answers a `PlaybackTarget` carrying the headers, and the probe, the sniffer and `AVURLAsset` all
  send them. bilibili's CDN needs both a `Referer` and a browser `User-Agent`.
- **Only the default quality is resolved (IOS-POC-5Q).** When a source answers a multi-value `url`,
  `SourceClient.target(from:…)` runs the probe/sniff hop on the default entry alone; picking another
  entry in the player sheet opens that URL exactly as the source gave it. Marked `ponytail:` in
  `SourceClient.swift` and `WebHTVApp.swift`. **No source in this configuration returns a `url`
  array**, so the quality menu has never been triggered by real data — its gate is a unit test.
- **Watch history is local and built-in-player only (IOS-POC-5R).** An external player is opened
  through a URL scheme, which has no way back, so nothing watched in Infuse, Fileball, SenPlayer or
  VidHub is ever recorded (K6). There is no cross-device sync: Android has its own local HTTP server
  for that and iOS has no equivalent. The store rewrites the whole JSON file on every save, at most
  every five seconds and only while actually playing — marked `ponytail:` with the upgrade path.
- **The sniffer is best effort and timing-sensitive.** `MediaSniffer` hooks `XMLHttpRequest`,
  `fetch` and media `src` — `WKWebView` has no `shouldInterceptRequest`, so there is no way to see
  every subresource. A stream fetched inside a Worker or through WASM is not caught. It is also
  slower on the first web view of a process: in one sweep run the first two sniffs missed and the
  next run caught both. **Treat a single sweep row as a sample, not a verdict.**
- ~~A site whose own category list contains 「全部」 renders two chips~~ **Fixed in IOS-POC-5J**: the
  app's own 全部 is suppressed when the provider's first category is already an “all” entry.
- **All remaining source failures are provider state**, each confirmed with `curl` against the URL
  the spider builds — 522/403 hosts, a withdrawn media file, or the site itself answering
  「暂无数据」. **None is a defect in this app.** Per-site table:
  `docs/IOS-POC-5E-all-source-sweep.md`.
- **I mis-assigned blame twice, and both corrections are recorded.** `csp_If101` was filed as our
  parse failure when the site answers 「暂无数据」; `永乐影视` was filed as a provider 404 because I
  checked `ylsp.tv` and applied the verdict to `ylys.tv`, which answers 200. A screenshot from the
  user exposed the second one. **Check the actual host for the actual site key before assigning a
  verdict.**
- **The 3 `XYQHiker` sites need a remote config to work at all.** Their `ext` is a relative path
  (`./json/农民影视.json`), and `ConfigSource.importedFile` has no `baseURL`, so `resourceURL` returns
  nil and `resolvedExtend` hands the spider an unfetchable `./json/…` string. The 2026-09-17 golden
  run passed only because the absolute GitLab Raw URL was substituted by hand. Confirmed in the
  app at IOS-POC-5D: 农民 resolved and played correctly **because the configuration came from a
  remote URL**. `XBPQ`'s 7 sites and `AppGet`'s 5 carry inline `ext` objects and are unaffected.
- **The drpy loader works, and all four sources are verified end to end.** Each runs
  `home → category → detail → search → player` against its live provider with all ten dependencies
  hash-verified, and each ends in real media bytes. Two answer `parse:0` directly; two answer
  `parse:1` and are sniffed. The encoded rule scripts — one base64, one not — are decoded by drpy2
  itself, so nothing was reverse-engineered. `bubutv`'s `./json/4k.js` is a 404 in the repository
  and is still listed, because listing goes by shape; it fails with a named error when opened.
- **A wrapper page is unwrapped since IOS-POC-6C.** A sniffed candidate like
  `…/vip/?url=…/index.m3u8` matched the keyword test only because of the address inside it, and the
  player was handed a page. `MediaSniffer.isCandidate` is now the single test both sniff paths use,
  and an accepted candidate is unwrapped one level. A page whose own query names the stream skips
  the web view entirely.
- **The Python runtime is assessed but not built (IOS-POC-7A).** Measured 2026-09-18 across the 31
  same-origin scripts: **zero Android dependencies** — the five files mentioning "android" all do so
  in a User-Agent or a query parameter. 30 need the host's `base` module, whose Android original is
  in this repository at `chaquo/src/main/python/base/spider.py`; `requests` (23 files) is pure
  Python; and **4 scripts need nothing but `base` and the standard library**, which is what makes a
  minimum POC possible with no C extension at all. 15 of 31 need one (`Crypto` 10, `pyquery` 4,
  `lxml` 3) and are deliberately out of that POC. Three of the 42 sites point at cross-origin,
  mostly plain-HTTP script URLs and would be refused under the rule IOS-POC-6B set.
  **Embedding CPython is a binary and packaging decision and is not taken yet.**
- **Still not implemented:** a Python runtime (42 sites), the 23 portable-but-unported `csp_*` sites, `CatVodHost` RSA and `proxy`
  plumbing, the configuration's `ads`/`rules` (`WebHTVConfig` decodes only `sites`) and everything
  else in IOS-POC-5S including opening/ending skip, `player.preloadArtwork`, `pan.*`, `app.open*`,
  `net.resourceUrl` proxying, `ui.setChrome`/`restoreChrome`, WebHome sites in `wang-movie.json`
  (this config has none), device signing, and SideStore/IPA delivery.
  **Landed and no longer future work:** the `AppQi`/`App99`/`App3Q`/`Bili` ports (IOS-POC-5L),
  `JianPian` for 薦片 (5M), the compatibility pack (5O), per-request playback headers (5P),
  multi-quality `url` handling (5Q), and the watch-history store with resume and `app.history`
  (5R). Earlier revisions of this line listed several of those as missing.
- **Filter rows exist only where the source publishes them.** MacCMS has no filter protocol and
  neither rule engine exposes one, so only `AppGet` sites show 類型/地區/語言/年代/排序. That is
  correct behaviour, not a missing feature.
- 34 `csp_*` sites are blocked by the native-encrypted payload in `aowu-0722.jar` and
  `fan-0720.jar`. **Do not attempt to defeat that protection.** If such a site matters, the routes
  are an `XBPQ`/`XYQHiker` rule equivalent or a direct HTTP/CMS entry.
- The `csp_*` audit is a **static** audit. “Portable” means nothing in the class prevents a
  reimplementation — it is not a promise that the site is reachable or that the port is cheap.
- 2 `csp_*` classes (`JPianAmns`, `AppV6`) were never downloaded, so their portability is
  **unknown**. Do not record a missing file as a technical verdict.
- type-0 was verified only against the two configured endpoints. A provider sending a non-UTF-8 encoding would parse to an empty response rather than being transcoded.

## Next Recommended Step

### IOS-POC-5S is code complete. The next stage is core real-device acceptance

**This heading read "The next functional stage is IOS-POC-5S-3, and it has not started" until
2026-09-23 and was left stale by commit `63040bb3`.** 5S-3 shipped in that commit: the
configuration's `rules` now reach the sniffer, ported from `Sniffer.java` itself. So
**5S-1 (ads), 5S-2 (opening/ending) and 5S-3 (rules) are all done in code, and IOS-POC-5S as a whole
is code complete.**

**Code complete is not acceptance.** No part of 5S has been watched working on hardware.

**Nothing functional may begin without the user saying so.**

#### The next stage, as the user fixed it on 2026-09-23

1. **Core real-device acceptance / smoke verification** — the stage that is actually next. Verify
   what the currently installed build can show, rather than waiting for a full matrix:
   5S-3's rules against a real source that has one, 5S-1 ad blocking, 5S-2 opening/ending, the PiP
   foreground restore, IOS-POC-16's player controls, and the long-standing unconfirmed items — CMS
   browsing/playback, a `csp_*` source, a drpy source, Bili's `Referer` + browser `User-Agent`
   through `AVPlayer`, whether `AVURLAssetHTTPHeaderFieldsKey` works on a device at all,
   WatchHistory and resume. (~~the external players~~ — superseded 2026-09-23, removed by
   IOS-POC-17A.)
   **Mind which build carries what:** 5S-3 first shipped in `0.1.8 (9)`; `0.1.7 (8)` (`add58007`)
   does not contain it. The latest release is `0.1.9 (10)` = `0.1.8 (9)` + the IOS-POC-18
   source-identity fix. The local 16B, 15D and 17F commits are in **no** release yet.
   **Prepared by IOS-POC-8L on 2026-09-23:** the full matrix, the per-item sources, steps and
   report format are in `docs/IOS-POC-8L-core-real-device-acceptance.md`. What is waiting is the
   user's report from `0.1.9 (10)`.
2. ~~**MPV keep/drop decision** for the first stable product.~~ **Made on 2026-09-23: kept**
   (IOS-POC-17). What remains is MPV's **device** first frame, switching and fallback — 8L ⑱⑲,
   which the release build has offered since `0.1.8 (9)` (17E, user decision). The MPV parity
   roadmap that follows it (P1 = 8L ⑱⑲) is `docs/IOS-POC-17-dual-internal-player.md` 第十四節.
3. **IOS-POC-12 Runtime Architecture Reconciliation.**
4. **IOS-POC-13 Runtime Hot Update.**

**IOS-POC-15 is not a blocker and must not be written back in as one.** Its code is implemented and
the user decided on 2026-09-23 to defer its real-device performance pass and run it themselves
later. It stays `device verification pending` — never `closed` — and the acceptance work above does
not wait for it. Do **not** go back and redo IOS-POC-15.

The constraints the user set for 5S as a whole, which 5S-3 was built under:

- prefer the configuration's own verifiable `ads` / `rules`;
- block known ad hosts or requests at the WebView / sniffer / network layer;
- **no** broad DOM-selector deletion and no "looks like an ad" heuristics;
- opening/ending skip reuses `PlaybackSession`, `WatchHistory` and the player's own
  position/duration — **no second playback state** (satisfied by 5S-2);
- reuse any portable Android data model or rule contract rather than inventing one;
- burned-in watermarks are out of scope; no image recognition or OCR;
- HLS mid-stream ads stay unimplemented until there is a reliable, verifiable rule;
- no ad rule may break a working media URL, subtitle, poster, API or sniffer unwrap;
- smallest verifiable unit first.

### Everything shipped on 2026-09-22

Six stages, all on the remote: **10S** source order, **10T** the CatVod JS spider contract,
**10V** the device confirmation, **10W–10X** 荐片's poster host and remembered state,
**10Z** the session-reset defect, **11** the SideStore release pipeline, **5S-1** ad blocking and
**14/14A/14B/14C** auto-advance with the playback speed carried within one title. Five releases have
gone out, through **`0.1.4 (5)`**. **IOS-POC-5S-2 (the viewer's opening and ending) landed on the
same day**; it was pushed at the user's explicit instruction on 2026-09-22 and is on the remote.
**`0.1.5 (6)` followed on 2026-09-23**, carrying 5S-2 and the PiP foreground-restore fix.

**The JS spider blocker turned out not to be `__jsEvalReturn` at all — it was `async`.** drpy2
contains no `async` anywhere, so `JavaScriptSpiderRuntime` never had to settle a promise; a JS
spider writes every method `async`, `invokeMethod` returned the promise itself and `JSON.stringify`
made it `{}`. Thirteen methods answering nothing, with **no error anywhere**. Settling the promise is
the one change in shared code. No second runtime, no new native primitive, and a JS spider does not
download drpy's 1.2 MB engine because it does not use one. Contract:
`docs/IOS_SPIDER_RUNTIME_SPEC.md`; record: `docs/IOS-POC-10-plan-ux-and-sources.md` §10T.

**The filter-row defect was the sharpest lesson of the day, and it was mine.** I twice announced a
cause from a log line — "the fetch failed", then "one failure is permanent" — without ever looking
at the screen. Both were wrong. `SpiderSessionStore.reset()` was calling `destroy()` on a session its
caller still held, and `destroy()` is a **spider** call that clears what `init` built;
`SpiderSession` is a reentrant actor, so it landed between `start()` and `homeContent()`. The
rule-file fetch had returned HTTP 200 and the rows were thrown away afterwards. **When there is a
screen to look at, look at the screen first** (§10Z).

### Confirmed on the device by the user, and what it does not prove

- **麻豆(js) is listed and plays** (10V), and **荐片's filter rows appear on a cold start** from a
  SideStore install of `0.1.1 (2)`, and **auto-advance from a `0.1.2 (3)` install**.
- **Neither is evidence that `AVURLAssetHTTPHeaderFieldsKey` works on a device.** 麻豆's only header
  is a `User-Agent` and its stream answers `HTTP 200` with or without one, measured with `curl` both
  ways. The real test of that key is still Bili, which needs a `Referer` too.

### Reported and deliberately not fixed

- **A cold start whose per-source cache is missing forgets the selected site.** `restore()` returns
  early when the cache file is absent, so `selectedSiteID` is still nil when `adopt()` runs, and
  `adopt` only preserves the in-memory value — it never consults the stored token. IOS-POC-10D's
  per-source caches made this reachable more often. Same family as IOS-POC-10C, different defect.
- **Switching source leaves the previous source's error text on screen.**
- `SpiderError`'s English `Spider script error:` prefix, deferred since IOS-POC-7N.
- **荐片's own API host list also leads with a dead domain**, so a first launch with no remembered
  host still pays a 10-second probe. IOS-POC-10X removed the cost on every launch after the first;
  the first one was left alone.

### Verified by the user, and not

- **Confirmed on hardware by the user:** 麻豆(js) listed and playing; 荐片's filter rows on a cold
  start; IOS-POC-8F and 8G.
- **Not confirmed by anyone yet:** the volume and brightness drags, Picture in Picture, the Chinese
  filter-row labels, the line-picker row, **the ad blocking actually stopping a real ad request in
  the app** (IOS-POC-5S-1), and **the playback speed carrying into the next episode**
  (IOS-POC-14A/14B) — build- and test-verified only. Every attempt to watch
  them on the simulator was blocked either by provider failures or by the simulator not implementing
  the feature.

**Do not start anything below without the user saying so.** The order is the user's, restated on
2026-09-22. Items 0–2 are finished; the numbering is kept so older references still resolve.

0. ~~**The CatVod JS spider contract.**~~ **Done (IOS-POC-10T), and confirmed on the device (10V).**
   Confirmed reach is **one site**, 麻豆(js); the other four `.js` sites in `wang-sex.json` are
   genuine drpy rules.
1. ~~**POC-3 — the drpy JavaScript loader.**~~ **Done (IOS-POC-6A/6B/6C).**
2. ~~**POC-4 — the Python runtime, P2–P5.**~~ **Done (IOS-POC-7E–7P), and run on a device (9F).**
   What it buys is modest and measured: **14 of 42 configured Python sites execute and 6 reach media
   bytes** (4 and 1 before IOS-POC-7P vendored `requests`). **24 are still blocked on a
   dependency** — `Crypto` 17, `lxml` 3, `pyquery` 2, `bs4` 2 — and 4 are refused by the
   same-origin/HTTPS policy. `bs4` is pure Python and would go the way `requests` did; a
   `Crypto.Cipher` shim over the AES, DES, MD5, SHA and HMAC `CatVodHost` already has would address
   the largest block, 17 sites. **Neither shim has been started, and neither should start without
   the user asking.**
3. **Superseded 2026-09-23 by IOS-POC-9G/17 — MPV renders on the simulator and has shipped as the second
   engine since `0.1.8 (9)`; only its device first frame, switching and fallback are owed (8L ⑱⑲).**
   The rest of this item is the pre-9G record: **MPV — started, and paused with rendering unresolved.** Not a future stage and not a finished
   one. **Done:** the licence/provenance review (9A, no blocker, conditional on MPVKit ≥1.0.0
   non-GPL), MPVKit wired into the App target with static linking confirmed by symbol table, and
   **libmpv initialising on the simulator and on the iPhone 18 Pro** (9B/9C/9D/9F).
   **Not done:** rendering. On the device, Metal + software decode reaches `FILE_LOADED` and
   **`VIDEO_RECONFIG` never fires; the picture stays black.** There is **no second playback core** —
   `PlaybackTarget → PlayerRouter → AVPlayerEngine / MPVEngine` was the design, not the state.
   **When the user resumes it**, start from that unresolved point — the `FILE_LOADED → VIDEO_RECONFIG`
   gap, with the untried **OpenGL on device** cell as the cheapest discriminator — **not** from
   MPVKit installation, and do not redo 9A unless MPVKit or its dependencies actually change. Do not
   guess a third render path, do not build an AVPlayer↔MPV fallback, and do not add subtitle or
   audio-track UI. `docs/IOS-POC-9B-mpv-playback-core.md`.
4. **The full real-device acceptance. This is the next stage** — since 2026-09-23, when 5S-3 closed
   item 5 below. Partial today. Still owed, at least: CMS browsing and
   playback; a `csp_*` source; a drpy source; Bili's `Referer` + browser `User-Agent` through
   `AVPlayer`; whether `AVURLAssetHTTPHeaderFieldsKey` works on a device at all; WatchHistory and
   resume; ~~opening Infuse / Fileball / SenPlayer / VidHub~~ (superseded 2026-09-23); Picture in Picture; and MPV rendering if
   it is fixed by then. **The runs already done are not a completed acceptance.**
5. ~~**IOS-POC-5S — ads, opening and ending. The next functional stage, not started.**~~
   **IOS-POC-5S — ads, opening/ending, and config rules. Code complete; real-device acceptance
   pending.** All three parts are implemented: 5S-1 ads (2026-09-22), 5S-2 opening/ending
   (2026-09-22) and **5S-3 config `rules` → sniffer (2026-09-23, `63040bb3`)**. This item read
   "the next functional stage, not started" until then and contradicted the status table at the top
   of this document. **Code complete is not acceptance** — no part of 5S has been watched working on
   hardware, and `0.1.7 (8)` did not contain 5S-3; it first shipped in `0.1.8 (9)`. Record: `docs/IOS-POC-5S-ads-and-skip.md`; what is left of it is item 4 above.

**Backlog, not to be started:** the Python `Crypto` / `bs4` / `lxml` / `pyquery` shims; further
portable `csp_*` ports; XueLuo, QimaoDJ and AppDrama; `CatVodHost` RSA and `proxy` plumbing; CarPlay;
~~an automatic AVPlayer↔MPV fallback~~ (superseded: implemented in IOS-POC-17B, widened in 17F); extra work for an Official/App Store profile; and **any new
release version**.

## Resume Prompt

Paste this into a new session:

> 接手 `/Users/chengchenchih/GIT/webhtv` 的 `ios-poc`，用台灣繁體中文回報，不要每一步停下來問我確認。先 `git fetch`、`git log --oneline -6`、`git status`，以實際 Git 狀態為準、不要相信文件裡的 SHA。依 `AGENTS.md` 先讀 `AGENTS.md`、`docs/current-task-state.md` 最上方「Current handoff — 2026-09-24」一節、`docs/IOS-POC-17-dual-internal-player.md`（第十二之二節 17F、第十四節 MPV parity roadmap）。
>
> 目前狀態：最新已發布版本是 `0.1.10 (11)`（2026-09-24）＝`0.1.9 (10)`＋IOS-POC-16B（控制列 panel）、15D（緩衝／預解析契約）、17F（播不出來就主動切換播放核心）；`ios-poc` 已 push，與 origin 同步。`0.1.8 (9)` 起 Release 開放 MPV。全套 `swift test` 344／344（天氣測試 `reportsLiveType4SitesFromProvidedConfig` 偶爾失敗，不要修）。
>
> 下一步：我在 `0.1.10 (11)` 上依 8L 7.2 回報（優先 ⑱⑲＝MPV parity P1，並看 16B 面板與 17F 自動切換），你把結果填進 8L 與 IOS-POC-17。沒有我的指示前，不開始 MPV parity P2 以後的階段，也不開始 IOS-POC-12／13。
>
> 規則：功能修改前 Ponytail pre-review＋`bash .codex/scripts/task_guard.sh start`；結束用 `finish --no-tag`。**未經我另外明確授權，不要 push、bump 版本、tag、package、publish 或發 SideStore release**；不要直接安裝到我的 iPhone（我用 SideStore）。真機沒測到的一律寫「未驗證」。
