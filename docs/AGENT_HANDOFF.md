# WebHTV Agent Handoff

## Repository and active branch

- Repository: `st7833232/webhtv`
- Upstream source: `fish2018/webhtv`
- Android mainline branch: `main`
- iPhone / iOS / PWA exploration branch: `ios-poc`
- `ios-poc` was created from commit `fc62397591701b2232ae7de4f50a032bd7742064`.
- Do not make experimental iOS/PWA changes directly on `main`.

## Mandatory Ponytail review gate

This project **must use the Ponytail skill for implementation work**. This is a project requirement, not an optional recommendation.

For every functional code change, architecture change, dependency/build change, native/runtime change, Spider compatibility change, player change, packaging/signing change, or deployment/release change:

1. Read `AGENTS.md`, `README.md`, this handoff document, and any task/domain-specific Skill before editing.
2. **Before implementation, run Ponytail** against the proposed scope/design and resolve or explicitly document every material finding before changing functional code.
3. Use the repository task guard and verification workflow required by `AGENTS.md` for the selected lane.
4. After implementation and targeted verification, **run Ponytail again on the final diff** before considering the change complete, committing/pushing it, producing an IPA, or publishing an artifact.
5. Record the Ponytail pre-review and final-diff review result in the durable task document or handoff evidence for the task.

If Ponytail is not available in the current agent/runtime, **do not claim that Ponytail review was performed**. Read-only assessment and documentation may continue, but functional implementation must stop before the first functional edit and the missing Ponytail capability must be reported as the blocker.

## Current iPhone/iOS objective

The current exploration goal is to determine the best way to make WebHomeTV usable on iPhone while keeping the user's preferred operating constraints:

- no jailbreak;
- zero recurring infrastructure cost where practical;
- no always-on self-hosted server;
- updates should be installable/refreshable from the phone where possible;
- preserve as much WebHomeTV/CatVod/WebHome compatibility as practical rather than performing a blind Java-to-Swift rewrite.

No final decision has been made that the product must be native iOS or PWA. Treat `ios-poc` as an evidence-gathering and proof-of-concept branch until the runtime compatibility questions are resolved.

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

## Recommended first iOS/PWA work units

Until functional implementation is explicitly approved and Ponytail is available, the safest useful work in a new session is read-only assessment/documentation. The recommended order is:

1. Map the Android contracts that a new front end must preserve: config parsing, Site/CatVod result models, search/detail/category/player contracts, WebHome bridge methods, history/favorites/storage, and playback URL/header/cookie handling.
2. Produce a migration matrix separating capabilities into: portable shared protocol, browser/PWA implementation, native iOS implementation, server-dependent/unsupported Android behavior.
3. Select a minimal end-to-end proof: `config -> one HTTP/CMS source -> search -> detail -> episode -> HLS/MP4 playback`.
4. Separately select one JS Spider and one relatively simple Python Spider as compatibility proofs. Do not begin with protected/obfuscated DEX JARs.
5. After those proofs, decide whether the primary client should be native iOS, PWA, or a hybrid architecture before investing in broad UI work.
6. Only after runtime direction is proven should packaging/IPA/SideStore/GitHub Actions update automation become an implementation task.

## Branch and upstream discipline

- Preserve `main` as the Android/upstream-oriented line unless the user explicitly changes that policy.
- Keep iOS/PWA experiments isolated on `ios-poc` or a task branch derived from it.
- Before importing upstream Android changes, assess whether they touch shared contracts used by the iOS/PWA work.
- Do not silently copy third-party source/resource implementations into the repository; preserve license/provenance and review compatibility/legal implications where applicable.

## Current recovery anchor

- Objective: establish a safe iPhone path for WebHomeTV without destabilizing the Android fork.
- Active branch: `ios-poc`.
- Baseline before this handoff document: `fc62397591701b2232ae7de4f50a032bd7742064`.
- Functional iOS/PWA code changes completed: none.
- Ponytail status in the ChatGPT session that created this document: Ponytail was searched for but was not exposed as an available skill/plugin; therefore no Ponytail review was claimed or performed.
- Next action: perform a read-only contract/architecture inventory for the minimal iOS/PWA proof, or obtain a runtime/session where Ponytail is available before any functional implementation.
