# JPianAmns Google TV diagnosis and CarPlay requirement — 2026-09-13

This is a durable handoff for two requirements discussed on 2026-09-13:

1. Make the `csp_JPianAmns` / 荐片 source work on the user's current Google TV / Android TV deployment.
2. Treat CarPlay support as an explicit requirement for the future iOS WebHomeTV port.

This document records diagnosis and the intended minimal repair. It does **not** claim a functional fix was applied in this ChatGPT session because the project requires Ponytail pre-review before any functional change and Ponytail was not exposed in the active runtime.

## A. Mandatory process gate

Functional changes in this repository require Ponytail before implementation and again on the final diff. The user's established Ponytail workflow is:

1. inspect status/diff and relevant docs;
2. invoke Ponytail before implementation;
3. implement only the approved minimal scope;
4. run targeted verification;
5. invoke Ponytail again on the final diff;
6. if Ponytail reports overbuilding, remove the flagged excess and re-review;
7. only then commit/push/release.

Do not claim Ponytail was run if the current runtime cannot invoke the skill.

Known prior Ponytail locations in the user's normal development environments include:

- `/Users/chengchenchih/.codex/plugins/cache/ponytail/ponytail/4.9.0/skills/ponytail-review/SKILL.md`
- `~/.agents/skills/ponytail-review/SKILL.md`
- `/root/.config/opencode/skills/ponytail/SKILL.md`

The review is primarily an over-engineering/YAGNI review; it does not replace correctness, security, compatibility, or runtime verification.

## B. Current user platform

The active failure is on **Google TV / Android TV**, not iPhone.

Do not confuse the failing data source with the Android playback extractor:

- failing source/API: `csp_JPianAmns`
- Android playback extractor: `app/src/main/java/com/fongmi/android/tv/player/extractor/JianPian.java`

`JianPian.java` handles already-resolved `jianpian://`, `tvbox-xg://`, `xg://`, `xgplay://`, or FTP-style playback and proxies them through the local `P2PClass` runtime. It is not the component that supplies the home/category/search/detail data for `csp_JPianAmns`.

## C. Exact resource binding observed in the user's resource set

The inspected `recha-main.zip` / `wang-movie.json` resource set contains the 荐片 site using:

```json
{
  "name": "🎯荐片",
  "key": "荐片",
  "type": 3,
  "api": "csp_JPianAmns",
  "searchable": 1,
  "filterable": 1,
  "quickSearch": 1,
  "changeable": 1,
  "ext": "https://cnb.cool/aooooowuuuuu/FreeSpider/-/git/raw/main/json/jpian.json"
}
```

No site-specific `jar` was present on the inspected entry, so it inherits the resource's global Spider JAR.

The inspected `wang-movie.json` global Spider was:

```text
./jar/399640384_3_1788121085146.jar;md5;01e3d12b032b87e2e1f7c278453881ce
```

Therefore the effective runtime for `csp_JPianAmns` in that resource set is the old global `399640384_3_1788121085146.jar` unless a later resource revision changed it.

## D. How WebHTV actually loads `csp_JPianAmns`

`app/src/main/java/com/fongmi/android/tv/api/loader/JarLoader.java` resolves a CSP site by loading:

```text
com.github.catvod.spider.<api without csp_>
```

For this site that means:

```text
com.github.catvod.spider.JPianAmns
```

The loader then sets `siteKey`, calls `spider.init(App.get(), ext)`, and caches the resulting Spider instance. On class-load/init failure it returns `SpiderNull`.

Therefore an empty/non-functional 荐片 source can be caused before playback by:

- `JPianAmns` missing from the inherited JAR;
- stale `JPianAmns` implementation in the old JAR;
- JAR/native/DEX initialization failure;
- `ext` schema/API mismatch;
- upstream API/protocol change.

The Android `jianpian-release.aar` is separately bundled in `app/libs` and is relevant after a playback URL has been produced. It is not the first suspect when home/category/search data itself is absent.

## E. Current maintained Amns configuration observed publicly

A currently maintained Aowu/Amns configuration still uses:

```text
api = csp_JPianAmns
ext = https://cnb.cool/aooooowuuuuu/FreeSpider/-/git/raw/main/json/jpian.json
```

but its current global Spider points to:

```text
https://cnb.cool/aooooowuuuuu/FreeSpider/-/git/raw/main/bfdb--cvdvds.png
```

The current `jpian.json` includes 2026-era category/filter definitions, which is evidence that this source/runtime pair has continued to evolve.

This makes the most likely failure in the user's inspected resource set **version skew**: a newer `jpian.json` / current `JPianAmns` contract being used with an older inherited Amns JAR.

## F. Recommended minimal functional repair

Do **not** replace the global Spider for all 208 sites as the first fix.

The smallest reversible repair is to give only the 荐片 entry a site-specific current Amns JAR while preserving its current ext:

```json
{
  "name": "🎯荐片",
  "key": "荐片",
  "type": 3,
  "api": "csp_JPianAmns",
  "searchable": 1,
  "filterable": 1,
  "quickSearch": 1,
  "changeable": 1,
  "jar": "https://cnb.cool/aooooowuuuuu/FreeSpider/-/git/raw/main/bfdb--cvdvds.png",
  "ext": "https://cnb.cool/aooooowuuuuu/FreeSpider/-/git/raw/main/json/jpian.json"
}
```

Why this is preferred:

- isolates the change to one source;
- does not disturb the other sites using the existing global JAR;
- matches the currently maintained Amns `JPianAmns` + `jpian.json` pairing;
- uses WebHTV's existing per-site `jar` capability instead of adding app-level hard-coded special cases;
- is easy to roll back by removing one `jar` field.

Do not add hard-coded `JPianAmns` fallback logic to `JarLoader` unless the resource-side repair is proven insufficient.

## G. Verification required on Google TV

After the resource-side JAR override is applied, reload the configuration and ensure the old cached JAR/Spider instance is not masking the change. The decisive checks are:

1. `jar-loader` shows parse/load for the new site-specific JAR.
2. `spider init start site=荐片 api=csp_JPianAmns ...`
3. `spider init done ... class=com.github.catvod.spider.JPianAmns`
4. home content is non-empty.
5. category page is non-empty.
6. search returns a known title.
7. detail returns playable episodes.
8. one episode reaches `playerContent` and then, if it uses a `jianpian://`/`tvbox-xg://` style URL, the existing `JianPian` extractor/P2P runtime is validated separately.

If steps 1–3 fail, the problem is JAR/runtime initialization.

If steps 1–3 pass but steps 4–6 are empty, inspect the `JPianAmns` network request/response because the upstream API/protocol is then the likely fault.

If data works but playback fails, only then diagnose `JianPian.java`, `jianpian-release.aar`, ABI/native loading, local proxy port, or storage/network behavior.

## H. Second-line fallback only if current Amns JAR still fails

The user's resource archive also contains Python alternatives in the 荐片 family, including names such as:

- `荐片.py`
- `新荐片.py`
- `py_jianpian.py`

Do not switch to these blindly. If the current Amns JAR + current ext still fails, validate one Python implementation end-to-end (`home -> search -> detail -> player`) and use it as a resource-level fallback/replacement only if it is behaviorally working.

This Python path is also more portable for the future iOS work than Android DEX/JAR-only `JPianAmns`.

## I. CarPlay is now an explicit iOS requirement

The user explicitly requires the future iOS WebHomeTV port to support CarPlay where Apple/vehicle capabilities allow it.

Treat this as a product requirement, but do not let it expand POC-1.

Preferred phase order:

```text
POC-1 native iOS core
  -> config / HTTP-CMS / search / detail / episode / AVPlayer
  -> AirPlay + normal system media controls
  -> WebHome bridge
  -> JS/Python compatibility
  -> CarPlay integration
```

CarPlay work must respect Apple's supported app categories, entitlement/capability requirements, and driving-state restrictions. Do not design around bypassing vehicle/Apple safety restrictions. Video presentation, where supported, must follow the current CarPlay video APIs and availability state rather than assuming arbitrary video UI is allowed while driving.

For architecture, keep a shared media/library model so Android TV/Android Auto and iPhone/CarPlay consume the same logical content contract rather than duplicating source/search/history models.

## Recovery anchor

- Current active user issue: Google TV `csp_JPianAmns` returns no useful data.
- Most likely cause: old inherited global Amns JAR is out of sync with the current `JPianAmns`/`jpian.json` implementation.
- Smallest proposed fix: add only the current maintained Amns JAR as the `jar` field on the 荐片 site entry; preserve current `jpian.json` ext.
- Do not modify `JianPian.java` unless data retrieval is proven healthy and only playback remains broken.
- Functional edit status in the session that wrote this document: **not started**, because Ponytail could not be invoked in that ChatGPT runtime.
- Exactly one next action in a Ponytail-capable Work/Codex session: run Ponytail pre-review on the single-site resource override, apply it to the actual resource source used by Google TV, reload/clear the relevant cached Spider state, and execute the verification sequence in section G.
