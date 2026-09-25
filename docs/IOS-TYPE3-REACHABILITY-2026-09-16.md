# type-3 reachability on iOS — measured, 2026-09-16

> ## ⚠ Partly superseded, 2026-09-16 (IOS-POC-5A)
>
> **Section A — the `csp_*` verdict — is wrong and must not be quoted.** This document concluded
> that all 90 `csp_*` sites are “structurally out of reach” because their JARs carry `classes.dex`.
> Carrying DEX says nothing about portability: every `Spider.java` method is text in, text out, so
> the behaviour can be reimplemented without running any Android bytecode. The full static audit
> (`scripts/audit_spider_jars.py`) found **54 of the 90 sites portable**, spanning 26 of the 51
> distinct classes, of which
> **15 are now ported and live-verified**; only **34 sites (23 classes)** are genuinely blocked, by a
> native-encrypted payload rather than by DEX, and **2** are merely missing downloads.
> (Corrected 2026-09-25: since IOS-POC-5L/5M, **32 sites over 8 classes** are ported and listed, and
> every class but `AppQi` has a live golden run on at least one of its sites; that is not a per-site
> verdict. See `docs/CSP_MIGRATION_STATUS.md`.)
>
> Live documents: `docs/CSP_PORTABILITY_MATRIX.md` (audit), `docs/CSP_MIGRATION_STATUS.md`
> (progress), `docs/IOS_SPIDER_RUNTIME_SPEC.md` (runtime and ABI).
>
> **Sections B and C — the 42 Python and 5 drpy JavaScript measurements — remain valid** and are
> still the reference for those 47 sites. This document is kept because that measurement is the
> reason the “132 out of reach” figure was retired; note that its own replacement figure was in turn
> too pessimistic in exactly the same way.
>
> (Corrected 2026-09-25: B and C are no longer the reference for what runs. The 5 JavaScript sites are
> listed and driven since IOS-POC-6B, and all four same-origin drpy2 sites reach media bytes; CPython
> is embedded since IOS-POC-7E–7P, and **14 of 42 Python sites execute and 6 reach media bytes**. Both groups are listed
> only under a remote configuration. See `docs/current-task-state.md` "Source coverage" and
> `docs/IOS-POC-7A-python-runtime.md`. The import and host-API inventories below still stand.)

## Why this document exists

`docs/current-task-state.md` and `docs/AGENT_HANDOFF.md` both carried the claim:

> Of the 137 type-3 sites, **132 are structurally out of reach on iOS**, not merely unimplemented:
> 90 are `csp_*` DEX/JAR and 42 are Python.

**The 42 Python sites do not belong in that sentence.** They are expensive, not impossible. This
document records what was actually measured, so the wrong figure stops being copied forward — it had
already been repeated in several session reports.

Corrected figure: **90 of 137 are structurally out of reach.** The other 47 are unimplemented at
very different costs.

## Method

Read directly from the user's own resource set — `wang-movie.json` (167 sites) and the
`recha-main.zip` it belongs to — not from the earlier planning documents. Only the JARs and scripts
this configuration actually references were inspected.

## A. 90 × `csp_*` — structurally out of reach — **SUPERSEDED, see the banner above**

51 distinct spider classes across 11 referenced JARs, of which 9 are present in the archive:

```
aowu-0722.jar          22 KB   classes.dex
custom_spider.jar     328 KB   classes.dex
fan-0720.jar          1.1 MB   classes.dex  ftyguard_v7.so  ftyguard_v8.so
fm.jar                283 KB   classes.dex
pro.jar               1.7 MB   classes.dex  libspider_guard_32.so  libspider_guard_64.so
river-fman.jar        2.0 MB   classes.dex
xiaosa-0807.jar       2.0 MB   classes.dex
xyqxbpq.jar           636 KB   classes.dex
愛影.jar              2.0 MB   classes.dex
```

Two facts decide it:

1. **Every JAR contains `classes.dex` and not a single `.class` file.** That is Android Dalvik
   bytecode, not JVM bytecode, so every "run Java somewhere else" route — CheerpJ and friends — is
   inapplicable rather than merely awkward. They consume `.class`, which is not present.
2. **Two of the nine also ship native ARM `.so` payloads** whose names state their purpose:
   `ftyguard_v7/v8.so` and `libspider_guard_32/64.so`. Anti-tamper native code.

iOS has no Dalvik/ART and cannot load downloaded native executables. The only remaining route is
hand-reimplementing each spider's scraping logic against obfuscated, guarded binaries — 51 rewrites,
not a port. This is the group that genuinely justifies "structurally out of reach".

## B. 42 × Python — expensive, architecturally possible

Imports across the 38 `.py` files present in the archive:

```
44 Crypto (pycryptodome)   37 base   33 json   32 sys   28 re
28 requests   27 urllib    22 base64  20 time   11 uuid   7 threading …
```

**Only 1 of the 38 references `android.` at all.** The rest are ordinary Python: standard library,
`requests`, `pycryptodome`, and `base` — the TVBox-provided spider base module, which is not shipped
in the archive because the host is expected to supply it.

So the blocker is engineering volume, not architecture:

- embed CPython for iOS,
- ship `requests` and `pycryptodome` (the latter is a C extension),
- implement the `base` host module against this project's own `CMSClient`/`Vod` types.

Large, and out of scope for the POC, but **not** in the same class as the DEX group. Describing these
as structurally impossible is wrong and has already caused them to be dismissed without analysis.

## C. 5 × JavaScript — the most plausible of the three

- 4 sites run `./drpy_libs/drpy2.min.js` with a per-site script: `去看吧.js`, `爱弹幕.js`,
  `七色番[漫].js`, `爱弹幕[漫].js`. All four are present in the archive.
- 1 site is `./json/4k.js`.

`drpy2.js` is ~149 KB of JavaScript. What it wants from its host: `pdfh` / `pdfa` / `pd` (HTML query
helpers, backed by jsoup on Android), `req` (HTTP), `local` (storage), `getProxy`. It contains one
`java.` reference.

iOS ships JavaScriptCore, so the engine itself has somewhere to run. The work is the host API,
and the HTML selector layer is the substantial part of it.

## Resource gaps in the archive itself

Worth knowing before anyone plans work on these:

- 11 JARs referenced, **9 present**.
- 42 Python spiders referenced, **38 present**.

Even with a runtime, this resource set is incomplete.

## What to say from now on

(Corrected 2026-09-25: all three bullets below are superseded. Of the 90 `csp_*` sites, 54 are
portable and 32 are ported and listed; the Python and JavaScript sites are driven as described in the banner; and the app lists 62
of 167 sources from an imported file and 109 from a remote URL. See `docs/current-task-state.md`
"Source coverage".)

- **90 sites** are structurally out of reach on iOS. Do not plan them.
- **42 Python + 5 JavaScript = 47 sites** are unimplemented, at very different costs. Do not call
  them impossible.
- The 30 supported sources (2 type-0, 22 type-1, 6 type-4) remain the working set.
