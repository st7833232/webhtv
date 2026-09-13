# WebHTV iOS / Google TV Addendum — JPian and CarPlay — 2026-09-13

This addendum records two decisions/findings discussed after `docs/IOS-PORTING-HANDOFF-2026-09-13.md` was created.

## Current runtime platform for the reported JPian problem

The user's current WebHomeTV device is **Google TV / Android TV**, not iPhone. Diagnose the current `csp_JPianAmns` failure on the Android/Google TV runtime. Do not mix this failure with the future iOS port.

## `csp_JPianAmns` is not the JianPian playback extractor

There are two different layers:

1. `csp_JPianAmns` is a **CSP/JAR Spider**. It provides home/category/search/detail/player metadata through the CatVod Spider contract.
2. `app/src/main/java/com/fongmi/android/tv/player/extractor/JianPian.java` plus `app/libs/jianpian-release.aar` is a **playback extractor/runtime** used only after a player URL with schemes such as `jianpian://`, `tvbox-xg://`, or `ftp://` is returned.

Therefore, if the user reports that the JPian source cannot retrieve lists/data at all, investigate Spider/JAR/ext/upstream-network initialization first. The P2P `JianPian` extractor is not the primary suspect until metadata/detail/player resolution succeeds and playback itself fails.

## WebHomeTV Android loading path

Current `JarLoader` loads CSP classes as:

```text
api = csp_JPianAmns
  -> effective site/global jar
  -> DexClassLoader
  -> com.github.catvod.spider.JPianAmns
  -> spider.init(context, ext)
  -> homeContent/categoryContent/detailContent/searchContent/playerContent
```

`JarLoader` already logs the decisive stages: jar parse/load, Spider init start/done/error, missing loader, and class/init exceptions. `SiteApi` logs home/category/detail/search/player return strings.

## Current external configuration evidence

Public AOWU-family configurations still use `csp_JPianAmns`; it has not simply disappeared from the ecosystem.

Recent/public configurations commonly pair it with both:

- a current AOWU/Amns-specific Spider JAR rather than an unrelated global JAR; and
- an `ext` filter/config resource (`jpian.json` or an equivalent remote payload).

One 2026 configuration using the same global Spider family seen in the user's resources overrides JPian with an AOWU-specific JAR and a JPian-specific remote `ext`. Another September 2026 configuration uses `csp_JPianAmns` with `./lib/jpian.json`, and its `jpian.json` contains 2026 category/year/filter data.

This makes the leading failure hypotheses for the user's Google TV setup:

1. **Spider/JAR version mismatch** — the configured effective JAR is stale or is not the JAR version expected by the current JPian implementation.
2. **Missing/stale/unreachable `ext`** — the JPian Spider is initialized with no/old filter/config resource, or Google TV cannot retrieve the referenced remote/local `ext`.
3. **Upstream JPian API/protocol drift** — the class loads correctly, but its network calls now return empty/error responses.
4. **Class/init failure** — `com.github.catvod.spider.JPianAmns` is missing from the effective JAR or its initialization throws, in which case WebHomeTV falls back to `SpiderNull`.

Do not diagnose this as a `jianpian-release.aar` problem unless metadata works and failure occurs only after selecting an episode for playback.

### Decisive Android log classification

When reproducing on Google TV, capture the log around `csp_JPianAmns` and classify it using:

```text
jar-loader ... spider init start site=<JPian site> api=csp_JPianAmns ...
jar-loader ... spider init done ...
```

If it instead shows `spider init error`, `loader missing`, `ClassNotFoundException`, network/TLS/DNS exceptions, or empty `home` / `category` output, that identifies the failing layer.

## CarPlay requirement for the future iOS client

The user additionally requires the future WebHomeTV iOS client to support **Apple CarPlay**.

Treat this as a product requirement for the iOS work, but distinguish three levels:

1. **Normal iPhone playback + AirPlay** — should be supported independently of a full CarPlay app UI.
2. **CarPlay audio presence** — requires the appropriate CarPlay audio entitlement/category and Apple Developer Program approval.
3. **CarPlay video browsing/playback** — Apple announced video apps for supported vehicles with the video-in-car capability; video is available only while the vehicle is parked, and the app requires the appropriate CarPlay video entitlement for a full CarPlay video app experience.

Important constraint: full CarPlay app integration is not equivalent to ordinary SideStore sideloading. Apple requires CarPlay entitlements, and CarPlay apps require Apple Developer Program participation. A free Apple account / ordinary free SideStore provisioning should therefore not be treated as sufficient for the final full CarPlay entitlement path.

For the iOS architecture, preserve the following separation:

```text
WebHTVCore / Site / Result / Vod / Episode
                 |
                 +--> iPhone SwiftUI UI
                 +--> AVPlayer / AirPlay
                 +--> CarPlay scene/templates (entitlement-gated)
```

Do not couple CarPlay UI implementation to Spider runtime work. First complete the iOS data/playback POC; then add CarPlay as its own entitlement/template integration stage.

## Recovery anchor

- Current Android issue: diagnose `csp_JPianAmns` data retrieval on Google TV.
- Leading suspect: effective AOWU JPian JAR/ext pairing or upstream protocol/network drift, not the JianPian P2P extractor.
- Future iOS requirement: CarPlay support is required.
- Full CarPlay support has an Apple Developer Program + entitlement dependency and conflicts with the earlier assumption that free SideStore provisioning alone can deliver every requested capability.
- Functional code changes remain gated by Ponytail pre-review and final-diff review.
