# Current Task State

## Original Goal

- Port WebHomeTV to iPhone/iOS with an Android-like UI, use the newest user-provided `wang-movie.json`, and offer built-in, Infuse, Fileball, SenPlayer, and VidHub playback choices. The Google TV `csp_JPianAmns` repair is no longer in scope.
- Current user request: hand remaining iOS work to Claude, refresh factual handoff documents, and provide a paste-ready handoff paragraph.

## Current Scope

- Documentation-only handoff on `ios-poc`: this file, `docs/AGENT_HANDOFF.md`, `docs/IOS-PORTING-HANDOFF-2026-09-13.md`, and `docs/IOS-POC-1E-config-persistence.md`. No runtime/code/API change is authorized by this handoff task.
- Task guard `IOS-HANDOFF-CLAUDE` assessment lane began from clean HEAD `e567b03b0f6ba0790a59790358b5e96c20ed2e30`; 10 local commits ahead of `origin/ios-poc` at task start. Protected dirty paths: none. Check actual HEAD/status on resume.

## Non-Negotiable Constraints

- Preserve Android `main`, unrelated/dirty user files, current CMS/player behavior, system TLS validation, and the repository's task-guard/Ponytail/research/approval gates for later functional work. Do not push, sign, package, or publish without user authorization.
- No jailbreak, always-on self-hosted server, or recurring infrastructure cost is intended for the personal iPhone path. No unapproved DEX/JAR, Python, type-4, or broad ATS support claim.

## Important Decisions

- Current input is the replacement Recha `wang-movie.json`: 125,864 bytes, SHA-256 `b17576e34eb42b4c589a818ef8b5ec2655a2c7a188d626fc427c37d628897168`, 167 sites (2 type-0, 22 type-1, 137 type-3, 6 type-4). Earlier 208-site counts are historical. The archive is external, not committed.
- Use native iOS core/UI for supported type-1 JSON CMS. Keep system TLS/ATS policy. `WKWebView` WebHome bridge remains a proposed next-stage proof, not implemented and not a direct path to more usable entries in this JSON.
- The user chose removal of the oversized `ic_logo.png` from the source-picker label, not removal of the aqua/green wallpaper. This was committed in `IOS-POC-3C`.

## Files Read

- `AGENTS.md` (user-supplied repository instructions), `docs/AGENT_HANDOFF.md`, `docs/IOS-PORTING-HANDOFF-2026-09-13.md`, `docs/IOS-POC-1E-config-persistence.md`, and the relevant `ConfigView`/`HomeView`/player portions of `ios/WebHTVApp/Sources/WebHTVApp.swift`. Targeted symbols were inventoried with `rg` in `ios/Sources/WebHTVCore/ConfigLoader.swift`, `ios/Sources/WebHTVCore/CMSClient.swift`, and `ios/Tests/WebHTVCoreTests/`; those core/test files were not fully reread for this docs-only handoff. Skill: `/Users/chengchenchih/.codex/skills/context-compact-prep/SKILL.md` and its template.

## Files Modified

- This docs-only handoff update modifies the four paths listed in Current Scope. Functional changes from earlier POC stages are committed, not part of this diff.

## Current Diff Summary

- Replace stale no-iOS-code/old-resource/next-POC markers, record POC-1E's actual commit/tag closure, and preserve one Claude resume decision. No iOS source, assets, test, Android, dependency, or binary diff in this task.

## Completed Work

- Commits already on `ios-poc`: POC-1A native config classification; POC-1B type-1 MacCMS home/search/detail/media URL; POC-1C SwiftUI/AVPlayer app; POC-2A five selectable players; POC-3A/3B Android-like surfaces; current Recha input baseline `7e6cb0e7`; POC-1E persistence `3d715f04`; POC-3C oversized Logo removal `e567b03b`.
- POC-1E imported the current JSON into Application Support with matching SHA-256 and restored non-first key `vod_360` after app relaunch. POC-3C's expanded source menu no longer showed the obstructing Logo; wallpaper and poster home remained visible.

## Remaining Work

- Decide one next user-visible unit: minimal WebHome bridge proof versus increasing usable sources from the current JSON. Then perform the repository's decision-ready research/plan and obtain explicit stage approval before implementation.
- Type-0 XML, type-3 Spider/Python/DEX, type-4 remote APIs, full WebHome bridge, and SideStore/IPA delivery are not implemented. Do not combine these into an unbounded porting task.

## Open Questions / Blockers

- User priority between hybrid WebHome proof and immediate `wang-movie.json` source coverage is Unknown. The current JSON has no WebHome entry; a bridge proof alone cannot unlock its type-3/type-4 entries.
- POC-1E invalid re-import UI path and third-party Files-provider permission paths were not exercised. Actual installation/launch of every external player app is Unknown.
- Site reachability is volatile: `vod_魔都` produced “A server with the specified hostname could not be found.” on simulator; host diagnostics timed out for its configured URL, while 如意 returned HTTP 200 on 2026-09-15. This does not establish a global app defect or a permanent provider outage. Some other configured sources showed TLS failure without bypass.

## Build / Test / Verification Status

- Replacement-config baseline: `WANG_MOVIE_JSON=/tmp/webhtv-recha-new.wprHof/wang-movie.json swift test --package-path ios` passed all 5 tests on 2026-09-15, including the configured live CMS vertical flow.
- POC-1E: Xcode 26.3 iPhone 17 Pro Simulator Debug build, Files import/SHA match, selected-key persistence and relaunch restoration passed. Negative/provider-specific cases above were not run.
- POC-3C: Xcode 26.3 iPhone 17 Pro Simulator Debug build and expanded source-menu visual check passed. In the observed iOS 26.3 layout the picker was accessible via toolbar overflow (`⋯`). This docs-only handoff did not rerun builds, tests, or device scenarios.

## Risks

- Only 22 type-1 sites are exposed from 167 configured entries; source URL failures are data/network-specific until proven otherwise. Do not weaken TLS/ATS globally to make a single site appear to work.
- The current app is an iOS POC, not full Android/WebHome parity or a signed installable IPA. The 600 x 600 Logo asset remains bundled but is no longer used in the source-picker label.

## Next Recommended Step

- Claude first reads Git status/HEAD and the current anchors, then asks the user whether to prioritize a small WebHome bridge proof or one current-JSON source-coverage candidate. Choose one bounded stage and review its exact call/data path before any functional edit.

## Resume Prompt

> Continue the WebHomeTV iPhone port in `/Users/chengchenchih/GIT/webhtv` on the actual `ios-poc` Git state. The newest Recha `wang-movie.json` has 167 sites; the implemented SwiftUI app currently supports its 22 type-1 JSON CMS sites, persists the imported JSON/selected source, offers built-in/Infuse/Fileball/SenPlayer/VidHub players, keeps the aqua/green wallpaper, and no longer shows the oversized source-picker Logo. Read `AGENTS.md`, `docs/AGENT_HANDOFF.md`, this file, `docs/IOS-PORTING-HANDOFF-2026-09-13.md`, and only source/test files relevant to the chosen stage. Do not resume the Google TV `csp_JPianAmns` repair. WebHome bridge and type-3/type-4 sources are not implemented; the current JSON has no WebHome entry. First confirm with the user whether the next unit should prove a narrow WKWebView bridge or increase usable current-JSON sources, then prepare one evidence-backed stage and obtain explicit implementation approval. Preserve dirty files, Android `main`, TLS validation, and current CMS/player behavior. The 5-test replacement-config run and targeted simulator builds passed on 2026-09-15, but invalid re-import, provider-specific permissions, and complete external-player installations were not verified. Do not infer that 10 local iOS commits have been pushed.
