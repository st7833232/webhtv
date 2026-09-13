# WebHTV Agent Handoff

## Repository and active branch

- Repository: `st7833232/webhtv`
- Upstream source: `fish2018/webhtv`
- Android mainline branch: `main`
- iPhone / iOS / PWA exploration branch: `ios-poc`
- `ios-poc` was created from commit `fc62397591701b2232ae7de4f50a032bd7742064`.
- Do not make experimental iOS/PWA changes directly on `main`.

## Required detailed iOS handoff

For any iPhone/iOS/WebHome portability work, **read `docs/IOS-PORTING-HANDOFF-2026-09-13.md` after this file before doing new analysis or implementation**.

That document is the durable record of the 2026-09-13 session and contains:

- user constraints and installation/signing decisions;
- SideStore/update strategy;
- PWA vs Native iOS conclusions;
- the inspected `recha-main.zip` / `wang-movie.json` compatibility findings;
- JAR/DEX/native `.so` conclusions;
- Python and JavaScript compatibility direction;
- the Android `VodConfig -> Site -> SiteApi -> Spider -> Result/Vod -> player` contract inventory;
- WebHome bridge mapping to WKWebView;
- AVPlayer-first playback scope;
- persistence mapping;
- the migration matrix;
- POC-1 scope, success criteria, exclusions, phase order, and recovery anchor.

Do not restart the broad architecture investigation unless the repository or resource set has materially changed. Continue from the documented recovery anchor.

## Mandatory Ponytail review gate

This project **must use the Ponytail skill for implementation work**. This is a project requirement, not an optional recommendation.

For every functional code change, architecture change, dependency/build change, native/runtime change, Spider compatibility change, player change, packaging/signing change, or deployment/release change:

1. Read `AGENTS.md`, `README.md`, this handoff document, `docs/IOS-PORTING-HANDOFF-2026-09-13.md` when the task concerns iOS, and any task/domain-specific Skill before editing.
2. **Before implementation, run Ponytail** against the proposed scope/design and resolve or explicitly document every material finding before changing functional code.
3. Use the repository task guard and verification workflow required by `AGENTS.md` for the selected lane.
4. After implementation and targeted verification, **run Ponytail again on the final diff** before considering the change complete, committing/pushing it, producing an IPA, or publishing an artifact.
5. Record the Ponytail pre-review and final-diff review result in the durable task document or handoff evidence for the task.

If Ponytail is not available in the current agent/runtime, **do not claim that Ponytail review was performed**. Read-only assessment and documentation may continue, but functional implementation must stop before the first functional edit and the missing Ponytail capability must be reported as the blocker.

## Current iPhone/iOS objective

The current goal is to make WebHomeTV usable on iPhone while keeping the user's preferred operating constraints:

- no jailbreak;
- zero recurring infrastructure cost where practical;
- no always-on self-hosted server;
- no requirement to leave a PC running continuously;
- updates should be installable/refreshable from the phone where possible;
- preserve as much WebHomeTV/CatVod/WebHome compatibility as practical rather than performing a blind Java-to-Swift rewrite.

After read-only repository and resource analysis, the **current preferred architecture is Native iOS + SwiftUI + WKWebView hybrid**, with SideStore as the preferred zero-cost personal installation/refresh path. PWA remains a fallback/lightweight option rather than the primary porting target. This preference must still be validated by POC-1 before later phases are treated as committed implementation scope.

## Existing architecture facts that matter to the iOS work

The Android project currently depends on several Android-specific/runtime-specific layers, including:

- `catvod` for the Spider/CatVod ecosystem;
- `chaquo` for Python/Chaquopy integration;
- `quickjs` for JavaScript Spider execution;
- Android WebView/native bridges used by WebHome and extensions;
- Android playback/native stacks such as Media3/MPV and related native binaries;
- local HTTP/proxy/server features used by Spider, WebHome, playback, sync, and management functions.

Do not assume an Android `.jar` used by TVBox/WebHomeTV is a normal JVM JAR. Resource inspection performed during the iOS assessment found real-world Spider packages containing `classes.dex`, Android API dependencies, dynamic DEX loading, WebView references, and in some cases native `.so` payloads. Browser JVM approaches such as CheerpJ therefore cannot be treated as a universal drop-in solution.

## Resource compatibility assessment already established

A separate user-provided `recha-main.zip` / `wang-movie.json` resource set was inspected during planning. The important result for future design work is:

- 208 configured sites were observed;
- 136 were `csp_*` / Android JAR-style Spider sites;
- 37 were Python Spider sites;
- 30 were HTTP/CMS API sites;
- 5 were JavaScript Spider sites;
- many JAR-backed sites appeared to have Python/JS/rule-based alternatives in the same resource collection.

Therefore the preferred compatibility strategy is **not** to promise 100% execution of arbitrary Android JARs on iOS. First prefer direct HTTP/CMS, JavaScript, Python compatibility, or equivalent rule implementations. Investigate DEX/native-only sources individually only when they remain valuable and have no viable equivalent.

The resource archive itself is not part of this Git repository unless explicitly added later. Do not infer that the counts above remain current without rechecking the actual resource set when a future task depends on exact numbers.

## Recommended first implementation unit

Functional implementation must wait for a session/runtime where Ponytail is available.

The first approved-style proof should be POC-1 as documented in `docs/IOS-PORTING-HANDOFF-2026-09-13.md`:

`config -> one HTTP/CMS source -> home/category -> search -> detail -> Flag/Episode -> direct HLS/MP4 playerContent -> AVPlayer`

Do not begin with protected/obfuscated DEX JARs, Python, JS runtime, MPV/VLC fallback, DLNA, cloud-drive special handling, or release automation.

## Branch and upstream discipline

- Preserve `main` as the Android/upstream-oriented line unless the user explicitly changes that policy.
- Keep iOS/PWA experiments isolated on `ios-poc` or a task branch derived from it.
- Before importing upstream Android changes, assess whether they touch shared contracts used by the iOS/PWA work.
- Do not silently copy third-party source/resource implementations into the repository; preserve license/provenance and review compatibility/legal implications where applicable.

## Current recovery anchor

- Objective: establish a safe iPhone path for WebHomeTV without destabilizing the Android fork.
- Active branch: `ios-poc`.
- Original branch baseline: `fc62397591701b2232ae7de4f50a032bd7742064`.
- Functional iOS/PWA code changes completed: none.
- Current preferred architecture: Native iOS + SwiftUI + WKWebView hybrid.
- Personal install/update direction: SideStore, with on-device signing/refresh after initial setup.
- Detailed session record: `docs/IOS-PORTING-HANDOFF-2026-09-13.md`.
- Ponytail status in the ChatGPT session that created/updated these documents: Ponytail was searched for but was not exposed as an available skill/plugin; therefore no Ponytail review was claimed or performed.
- Next functional action: in a runtime where Ponytail is available, run Ponytail pre-review for POC-1, then implement only the documented minimal HTTP/CMS-to-AVPlayer vertical slice on an iOS task branch derived from `ios-poc`.
