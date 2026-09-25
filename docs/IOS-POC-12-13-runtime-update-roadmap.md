# IOS-POC-12 / IOS-POC-13 — Runtime Architecture Reconciliation and Hot Update Roadmap

- Status: **planned, not started**.
- Recorded: 2026-09-22 after IOS-POC-5S-1 (`7b7ad584`).
- This document authorizes **no runtime-update implementation by itself**. It fixes sequencing,
  boundaries, acceptance gates and rollback semantics for the future work.
- Native iOS / SideStore product shape remains a shell that bundles no user sources and loads the
  user's own configuration.

## Why this is deliberately later

The updater must be built around contracts that are stable enough to freeze. Building it while
`SourceClient`, playback, Spider ABI or persistence are still moving would force the update format
to chase implementation details and would turn ordinary refactors into compatibility breaks.

Entry order — **replaced 2026-09-23 by the user's dual internal-player decision**
(`docs/IOS-POC-17-dual-internal-player.md`). The earlier order ended in
"MPV keep/drop decision → IOS-POC-12"; that decision is made — MPV is kept as the second internal
engine — so the order is now:

1. ~~Remove external players~~ **done** (IOS-POC-17A).
2. ~~MPV rendering recovery~~ **done on the simulator** (IOS-POC-9G: both Metal and OpenGL draw);
   **the real-device first frame is still owed**. (Corrected 2026-09-25: on `0.1.10 (11)` the user
   reported MPV showing video on a real device, so MPV does draw there; the formal first-frame check,
   item ⑱ of `docs/IOS-POC-8L-core-real-device-acceptance.md` with its event sequence and decoder
   cells, is still not reported.)
3. ~~Minimal `MPVEngine`~~, ~~AVPlayer + MPV dual-engine integration~~, ~~global default engine
   setting~~, ~~session engine selector~~, ~~manual engine switching~~, ~~classified automatic
   fallback~~ — **implemented** (IOS-POC-17B; widened by 17F on 2026-09-24 to network/unclassified
   failures and a 20-second no-start switch); MPV has been offered in release builds since 17E /
   `0.1.8 (9)` (user decision); its device gate is still owed.
4. **Core real-device acceptance** (`docs/IOS-POC-8L-core-real-device-acceptance.md`), now including
   MPV's device first frame, switching and fallback.
5. IOS-POC-12 — Runtime Architecture Reconciliation.
6. IOS-POC-13 — Runtime Hot Update.

Only if MPV reaches the stop condition in IOS-POC-17 §5 on a device and is proven unsuitable:
`MPV stop → minimal VLCKit replacement spike → decision AVPlayer + VLC` — never three engines.
KSPlayer stays a secondary contingency and GStreamer / a custom FFmpeg+VideoToolbox player are not
pursued. IOS-POC-15's device performance pass stays deferred at the user's decision and is not a
gate.

**Superseded, kept for the record** — the 2026-09-22 order was: finish 5S; device playback
baseline; IOS-POC-15; the rest of core acceptance; MPV keep/drop decision; 12; 13. Its line
"automatic AVPlayer↔MPV fallback stay behind this sequence" is superseded by the same decision:
classified fallback is now part of the playback contract IOS-POC-12 freezes.

Portable CSP expansion, Python Crypto/lxml/pyquery/bs4 work and CarPlay stay behind this sequence
unless the user explicitly reprioritises them.

## IOS-POC-12 — Runtime Architecture Reconciliation

### Goal

Make the boundary between stable native engine code and high-churn runtime/source content explicit,
small and testable **before** an updater exists.

### Native Core contracts to freeze

At minimum audit and freeze the externally meaningful semantics of:

- `ConfigSource` and configuration identity / per-source cache isolation;
- `SourceClient` and `PlaybackTarget` including request headers;
- `PlaybackSession` state and control semantics;
- the playback engine boundary (IOS-POC-17): `PlaybackEngine`, `PlayerRouter`,
  `PlaybackEngineSelection` (global default / session override / current engine), and
  `PlaybackFailure`'s classification and one-fallback rule;
- `SpiderRuntime`, `CSPSourceResolver`, CatVod JS / Python / drpy routing and host primitives;
- `WatchHistory` persistence, source binding, opening/ending fields after 5S-2, resume behaviour;
- WebHome bridge ABI and Android-shaped payload compatibility;
- compatibility-pack precedence, verification and failure fallback.

The goal is not to make these APIs permanent forever. It is to give IOS-POC-13 a versioned runtime
ABI it can compare against instead of guessing whether downloaded content is compatible.

### Refactor inventory

Measure before moving anything:

- hard-coded source keys, aliases, host lists, mapping tables and provider-specific branches in Swift;
- bundled JS/Python/rule files and images/resources that change independently of native behaviour;
- dynamic content that already has a safe remote path versus content whose current security model
  depends on being bundled;
- duplicate or overlapping update mechanisms (compatibility pack, remote config, drpy resources,
  Python script fetch) that can share one manifest/activation model without changing their trust
  boundaries.

Move something out of Swift only when doing so **reduces update coupling without inventing a new
runtime language or weakening validation**.

### Native Core vs Dynamic Layer

**Native Core — IPA only**

- Swift / SwiftUI executable logic;
- new native screens, navigation semantics and gestures;
- `SourceClient`, `CatVodHost` and other native primitives;
- AVPlayer integration and native playback/session behaviour;
- MPVKit / FFmpeg / other native frameworks;
- CPython interpreter/XCFramework and compiled native Python dependencies;
- entitlements, Info.plist capabilities, signing, bundle executable and native ABI changes.

**Dynamic Layer — candidate runtime-pack content**

- compatibility packs and CatVod/JS spiders;
- Python `.py` spiders that run on the already-shipped interpreter and ABI;
- drpy/rule scripts where their existing same-origin/hash policy permits;
- XBPQ/XYQ-style rules and source/host mappings;
- ads/rules data;
- images, text and other non-native resources;
- schema/data-driven UI properties only where the installed native renderer already supports the
  property (labels, order, visibility, predefined style/layout parameters).

A runtime pack may configure existing UI capability. It may **not** smuggle in a new native screen,
new Swift navigation behaviour or a new entitlement.

### Manifest contract to design and freeze

IOS-POC-12 must define, but not yet implement, a versioned manifest with at least:

- pack identifier and monotonically comparable runtime version;
- runtime ABI/schema version;
- minimum compatible App version/build (and an upper bound if needed);
- explicit file list with logical type, path, byte size and cryptographic digest;
- origin / authenticity policy — a digest inside an untrusted manifest is integrity, not
  authenticity, so the trust root must be explicit;
- total and per-file size ceilings;
- configuration/global scope and isolation rules;
- activation generation id;
- optional changelog / human-readable release notes;
- rollback/LKG metadata and retention policy.

The design must say how a pack fails closed when it requires a newer native primitive.

### Acceptance for IOS-POC-12

- No user-visible behaviour intentionally changes.
- A written inventory classifies every proposed runtime-updatable asset.
- Native/Dynamic ownership has no ambiguous "maybe executable" bucket.
- Runtime ABI/version policy is documented and testable.
- Manifest/authenticity/size/rollback semantics are defined.
- Existing compatibility-pack and config security guarantees are preserved or strengthened.
- No updater/downloader/activation UI is added in this stage.

## IOS-POC-13 — Runtime Hot Update

### Goal

Allow high-churn source/runtime compatibility content to update inside WebHTV without requiring a
new IPA, while a native-core change continues to use the SideStore release pipeline.

### Required flow

`check manifest
→ compatibility gate
→ download into a new staging generation
→ enforce per-file/total limits
→ verify authenticity + digest for every file
→ validate type/schema
→ atomically activate the complete generation
→ invalidate only the affected runtime/session caches
→ keep the previous generation as last-known-good`.

Never patch the active generation in place.

### Failure and rollback

- Any missing, oversized, malformed, unauthenticated or hash-mismatched file aborts the whole
  candidate generation.
- Activation happens only after every file verifies.
- A failed activation or runtime boot leaves/reverts to the previous known-good generation.
- Remote failure never removes the bundled/LKG path that already works.
- Keep a bounded number of prior generations and clean old staging directories separately from the
  active pointer.

### Multi-configuration isolation

Runtime content that belongs to a user's configuration must not leak across saved config sources.
Global WebHTV-owned runtime content and config-owned content need distinct identities/trust roots.
Switching A→B→A must deterministically restore each configuration's applicable runtime generation,
just as 5S-1 already requires ad rules not to leak between configurations.

### UI / product surface

At minimum expose:

- installed App version/build;
- active runtime-pack version;
- update availability / changelog;
- manual check/update;
- clear failure state that says the previous runtime remains active.

Automatic checking can be added only with bounded cadence and must not force activation during
playback. A runtime reload should prefer session/cache invalidation over restarting the App when the
changed content type permits it.

### What this stage cannot do

IOS-POC-13 does not and cannot replace signed native executable code. Changes to Swift/SwiftUI
behaviour, native frameworks, MPV/FFmpeg, CPython XCFramework/native modules, entitlements,
Info.plist capabilities or native ABI still require a new IPA through SideStore.

## Relationship to existing update mechanisms

- SideStore: updates the native App/IPA.
- Remote configuration: user-owned source/config data.
- Compatibility pack / remote JS/Python/drpy resources: existing dynamic mechanisms to be reconciled
  into the IOS-POC-12 model where doing so preserves their trust boundaries.
- IOS-POC-13: the coordinated runtime generation/activation layer above those mechanisms, not a
  reason to weaken their individual security rules.

## Recovery anchor

When this roadmap resumes, do **not** start by writing a downloader. Re-read the current Git state,
5S results, real-device acceptance, IOS-POC-17 (the MPV decision is made: MPV is kept) and this
document. IOS-POC-12 is first; only
after its contract-freeze acceptance is complete may IOS-POC-13 begin.
