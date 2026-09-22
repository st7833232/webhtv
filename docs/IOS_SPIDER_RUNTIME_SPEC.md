# iOS Spider runtime — ABI and host SDK

Source of truth for the CatVod spider runtime on iOS. Anything that contradicts this file is a bug
in that thing, not here.

## The principle

**Do not execute Android DEX on iOS. Reimplement the CatVod Spider behaviour.**

That is possible because of one property of `catvod/.../crawler/Spider.java`: every method is *text
in, text out* — JSON strings, two booleans, and an `Object[]` for `proxy`. The Android app never
inspects a spider's internals; it only parses those strings. A spider reimplemented in JavaScript is
therefore indistinguishable, from the app's side, from the original DEX class.

A JAR is decompiled to learn **what a site expects**, and that knowledge becomes a JavaScript spider.
The decompiled Java is a specification, never something to recompile or ship.

```
wang-movie.json  →  api: csp_AppGet
                 →  CSPSourceResolver        (is this class registered?)
                 →  SpiderRegistry           (AppGet.js + audit metadata)
                 →  JavaScriptSpiderRuntime  (own JSContext, own serial queue)
                 →  CatVodHost               (http / crypto / html / storage)
                 →  CatVod JSON
                 →  the existing WebHTV UI, unchanged
```

## ABI

`SpiderRuntime` mirrors `Spider.java` one to one. A ported spider implements what it needs; the rest
fall back to the same no-ops the Java base class has.

| `Spider.java` | `SpiderRuntime` | JS export |
|---|---|---|
| `init(Context, String extend)` | `initialize(extend:)` | `init(extend)` |
| `homeContent(boolean)` | `homeContent(filter:)` | `homeContent(filter)` |
| `homeVideoContent()` | `homeVideoContent()` | `homeVideoContent()` |
| `categoryContent(tid, pg, filter, extend)` | `categoryContent(tid:page:filter:extend:)` | `categoryContent(tid, page, filter, extend)` |
| `detailContent(List ids)` | `detailContent(ids:)` | `detailContent(ids)` |
| `searchContent(key, quick, pg)` | `searchContent(key:quick:page:)` | `searchContent(key, quick, page)` |
| `playerContent(flag, id, vipFlags)` | `playerContent(flag:id:vipFlags:)` | `playerContent(flag, id, vipFlags)` |
| `liveContent(url)` | `liveContent(url:)` | `liveContent(url)` |
| `isVideoFormat(url)` | `isVideoFormat(url:)` | `isVideoFormat(url)` |
| `manualVideoCheck()` | `manualVideoCheck()` | `manualVideoCheck()` |
| `proxy(Map)` | `proxy(params:)` | `proxy(params)` |
| `action(String)` | `action(_:)` | `action(action)` |
| `destroy()` | `destroy()` | `destroy()` |

A JS method may return a JSON **string**, like the Java original, or a plain **object**, which is far
more natural to write. `JavaScriptSpiderRuntime` serialises the latter, so both reach the app as the
same CatVod JSON.

`extend` is the site's raw `ext`, exactly as `Site.getExt()` gives it on Android: verbatim text for a
string, otherwise re-serialised JSON. `Site.rawExtJSON` preserves strings, numbers, bools, arrays,
objects and null — the old `[String: String]` decode dropped all but flat strings, and real sites use
the rest.

## Isolation

One `JavaScriptSpiderRuntime` per site, each owning:

- its own `JSContext` — no shared globals between two sites on the same spider class,
- its own serial `DispatchQueue`,
- its own `CookieJar`, keyed by host,
- its own `SpiderStorage`, namespaced `spider_<siteKey>_`.

This is the isolation Android gets by constructing one `Spider` per site.

**Why a plain `DispatchQueue` and not an actor:** the host's HTTP is synchronous, so a ported spider
reads line for line like the decompiled original and stays auditable against it. Blocking a
Swift-concurrency cooperative thread could starve the pool; blocking a dedicated queue cannot.
`SpiderSession` is the actor on top, and it guarantees `init` runs exactly once before any content
call — the ordering `SiteApi` relies on for type-3.

## CatVodHost

One SDK, shared by the `csp_*` ports and by the drpy JavaScript spiders the config already carries.
There must never be two JS runtimes. Native half in `Spider/Host/*.swift`, JavaScript half in
`Resources/Spiders/host.js`.

| area | API | status |
|---|---|---|
| HTTP | `host.req/get/post` — method, headers, body, timeout, redirect control, form encoding | done |
| Async | a spider method returning a promise is settled before serialisation (IOS-POC-10T); CatVod JS spiders write every method `async` | done |
| Cookies | per-host jar, auto attach and capture, per-session isolation | done |
| HTML | `host.pdfh` / `pdfa` / `pd`, CSS selectors incl. `.class` `#id` `[attr^=v]` `>` `:eq(n)`, `&&Text` / `&&Html` / `&&attr` | done |
| JSON | native `JSON`, plus `host.result.{list,page,home,detail,play}` builders | done |
| Encoding | `host.enc/dec`, `host.base64.encode/decode` | done |
| Crypto | AES and DES, CBC and ECB, PKCS7, base64 or hex input; MD5, SHA1, SHA256; HMAC | done |
| Crypto, IV-prefixed | `host.aesEncryptIV` / `aesDecryptIV` — AES-CBC carrying a fresh random IV in front of the ciphertext, `base64(iv‖ct)`, and inflating a zlib plaintext the way `java.util.zip.Inflater` does. `csp_App99` speaks only this dialect (IOS-POC-5L) | done |
| Utility | `host.match`, `now`, `timestamp`, `random`, `urljoin` | done |
| Storage | `host.local.get/set/del` | done |
| Text slicing | `host.cut` / `cut1` — XBPQ's `前綴&&後綴` with `[包含:]` `[不包含:]` `[替换:a>>b]`, plus `host.stripTags` | done |
| Hiker rule syntax | `&&` first-match descent, `\|\|` attribute fallback, `,N` index, `:has()`, `!prefix` stripping | done |
| RSA | — | **not implemented**; `csp_AppDrama` needs it |
| WebView / sniffing | `MediaSniffer` — injected JS hook on XHR / `fetch` / media `src`, plus `MediaProbe` | done (IOS-POC-5G). **Native, not a `host.*` primitive**: `WKWebView` has no `shouldInterceptRequest`, so the sniff happens in Swift above the spider, on any `parse:1` result |
| `proxy` | ABI present, no host plumbing | **not implemented** |

**Scripts can now arrive from outside the bundle.** Since IOS-POC-5O a signed-by-hash
*compatibility pack* — a manifest plus scripts published at any HTTPS URL beside the configuration —
may replace or add spider scripts at runtime. Resolution order is **verified pack → bundled script →
not supported**, `host.js` is deliberately not packable because it is the SDK `minHostApi` describes,
and a pack can never add a native primitive, touch entitlements, ATS or signing, or cross the
`Spider` ABI. `SpiderPackStore.hostApiVersion` (currently **1**) is the gate: bump it whenever
`CatVodHost` gains a primitive, and older apps will refuse a script that needs it instead of failing
mid-call. Full contract: `docs/IOS-POC-5O-remote-compatibility-pack.md`.

**Ported classes: 8.** `AppGet`, `AppQi`, `App99`, `App3Q` (苹果CMS App-API family), `Bili`
(bilibili public API), `JianPian` (registered under the blocked `JPianAmns` name the configuration
uses, IOS-POC-5M), and the two rule engines `XBPQ` and `XYQHiker`. This line said 7 and omitted
`JianPian` until 2026-09-21; `SpiderRegistry.ported` is the authority and has carried 8 since
IOS-POC-5M. See `docs/CSP_MIGRATION_STATUS.md` for what each one covers and what it was measured
doing.

## A play result's `url` is three shapes

`playerContent`'s `url` is **not** a string. `app/.../gson/UrlAdapter.java` accepts a JSON string
(one unnamed address), a JSON array of alternating `name, url` pairs (`i + 1 < size`, so a trailing
odd element is dropped), or a JSON object `{"values":[{"n","v"}], "position": n}`. `PlayURL`
(`ios/Sources/WebHTVCore/PlayURL.swift`) is the only decoder for it, on **both** the spider and the
CMS path — reading it as a `String` used to throw `DecodingError.typeMismatch` on one path and be
swallowed into 「這一集沒有可播放的網址」 by a `try?` on the other. `SourceClient.target(from:…)` is
the single place that turns it into a `PlaybackTarget`, and only the default entry gets the
probe/sniff hop. A spider may keep returning a plain string; nothing about that changed.

**A quality is not automatically a `url` array.** When each quality needs its own request to
resolve — which is the case for `Bili`, where every `qn` costs a separate `player/playurl` call —
express them as **flags** instead: one line per quality, the quality's parameter travelling in each
episode's id. The choice then happens before `playerContent` runs and costs no extra requests, and
the app's existing line UI presents it. `Bili.js` does exactly this since IOS-POC-5Q, labelling the
lines from the API's own `accept_description` rather than a local `qn`-to-name table. Contract:
`docs/IOS-POC-5Q-playback-quality.md`.

**Wired to the app UI since IOS-POC-5D.** `SourceClient` routes each site to either `CMSClient` or
a `SpiderSession` behind the five methods the app already called, and `ConfigView` lists
`drivableSites(resolvedBy:)`. A spider is stateful, so `SpiderSessionStore` keeps one session per
site — a rule engine downloads its rule file during `init`, and the app builds a client per call.
See `docs/IOS-POC-5D-spider-sites-in-app.md`.

## The second JavaScript contract: CatVod JS spiders

TVBox carries **two** JavaScript contracts and they share the `.js` extension, which is why
`wang-sex.json`'s 麻豆(js) played on Android TV and showed nothing here (IOS-POC-10P/10T).

|  | drpy rule | CatVod JS spider |
|---|---|---|
| entry point | exposes a `rule` object for an engine to read | defines `__jsEvalReturn()` |
| answers | — | `{init, home, homeVod, category, detail, play, search}` |
| engine | `drpy_libs/drpy2.min.js`, 1.2 MB, hash-pinned | **none — the script is the spider** |
| synchronous? | yes, drpy2 contains no `async` at all | **no, every method is `async`** |

**This is not a third runtime either.** Same `JSContext`, same `CatVodHost`, same cookie jar, same
storage namespace, no new native primitive. `js-spider.js` is the sibling of `drpy-bridge.js` and
maps the seven methods onto the thirteen above; the script is fetched, origin-checked and rewritten
out of ES-module syntax by the same `DrpyEngine` code drpy's own libraries go through, and
`CSPSourceResolver` chooses between the two contracts from the bytes, after one download.

Measured against `drpy_js/麻豆.min.js`: it needs **one** global, `req`, and reads **one** field off
the answer, `content` — both of which `DrpyEngine.moduleRuntime` already supplied to drpy sites.

Two things differ from every other spider and are handled in the bridge:

- **`init` receives an object, not text.** 麻豆's `init` writes `extend.stype = '3'`, which on a
  string primitive is a silent no-op in sloppy mode and a TypeError in strict.
- **Methods are `async`.** `JavaScriptSpiderRuntime` settles a returned promise before serialising
  it. Nothing is pumped and nothing needs to be: the host's HTTP is synchronous, so a spider's
  promise has no real suspension point and JavaScriptCore drains its microtask queue when a
  native→JS call unwinds. Before this, `JSON.stringify` turned the promise into `{}` and all
  thirteen methods answered nothing with no error anywhere.

Off switch: the same `isDrpySpider` branch in `CSPSourceResolver.canResolve`, which gates both.
Contract: `docs/IOS-POC-10-plan-ux-and-sources.md`, sections 10P and 10T.

## drpy sites run on this same runtime

A drpy site's `api` is a JavaScript engine (`./drpy_libs/drpy2.min.js`) and its `ext` is that site's
rule script — the engine/rule split `XBPQ` and `XYQHiker` already have, except the engine itself
arrives from the configuration. **It is not a second runtime.** `DrpyEngine` is a loader: it fetches
the engine and its nine libraries, rewrites the four that are ES modules into plain script, and
hands the result to the *existing* `JavaScriptSpiderRuntime` as a prelude. `drpy-bridge.js` maps
drpy2's export onto the same thirteen methods above.

**The engine is pinned; a rule script is not.** This is the `host.js` line from IOS-POC-5O applied
again: the libraries are the SDK a rule runs against, so their SHA-256 is compiled into the build
and a mismatch refuses the site with no warn-and-continue path. A rule script is the spider
equivalent and stays hot-updatable under same-origin, HTTPS and a size cap. Everything fails
closed — cross-origin, plain HTTP, oversize, bad hash, transport error, or module syntax the
rewriter could not handle. A drpy site gains **no** native capability: same `JSContext`, same
`CatVodHost`, no bridge, no file system, no entitlement. Contract:
`docs/IOS-POC-6A-drpy-loader.md`.

## Adding a port

1. Decompile and read the original: `jadx -d out jar/<name>.jar`.
2. Write `Resources/Spiders/<Class>.js` exporting the methods it implements. Keep only what is
   genuinely site-specific — endpoints, request params, the token algorithm, response mapping, player
   parsing. Everything else comes from `host`.
3. Register it in `SpiderRegistry.ported` with its audit category and origin JAR.
4. Add a golden test.
5. To ship it without an app release, publish it in a compatibility pack instead of (or as well as)
   bundling it — `scripts/spider_pack.py build`.

If a port needs a primitive the host lacks, add it to `CatVodHost` — never inside the spider. A
spider that re-implements HTTP, crypto or parsing is a bug.

## Native `.so`

A `.so` in a JAR is not a verdict. Establish what the native code actually computes first. If it is
MD5, AES, base64, a token, a signature, a fixed string decryption, a header or a URL transform, then
reimplement that algorithm in `CatVodHost` and leave the binary behind — the algorithm is the
contract, not the binary that happened to run it on Android.

Only these are genuine blockers: a native VM, heavy control-flow obfuscation, anti-debug or
anti-tamper, Binder, device attestation, DRM, or a proprietary native protocol.

## How a spider's code reaches the app — five mechanisms, two categories

Added 2026-09-21 (IOS-POC-7I), after the product shape was settled: **a shell app that bundles no
sources, into which the user brings their own configuration** — the XPTV model. Distribution itself
is analysed in `docs/analysis/ios-app-store-readiness-research.md`; this section is the architecture
half, and it exists because the two questions get confused.

The axis that matters is **not** "is it interpreted" — the bundled `csp_*` ports are interpreted
JavaScript too. It is **when the code arrives**, and therefore whether anyone reviewing the app
could have seen it.

| # | Mechanism | Where the logic comes from | Code or data? | Coverage |
|---|---|---|---|---|
| 1 | Bundled `csp_*` scripts | The app binary (116 KB of JS, 8 classes) | **Code, shipped** | ~62 of the user's sites |
| 2 | **Rule engines** `XBPQ` / `XYQHiker` | Engine in the binary; the **rule file is data** | **Data** | Whatever rules the user brings |
| 3 | Compatibility pack | The configuration's origin, at runtime | Code, later | Can replace any class |
| 4 | drpy | The configuration's origin, at runtime (1.2 MB) | Code, later | 5 sites |
| 5 | Python | The configuration's origin, at runtime, on a bundled CPython | Code, later | 42 sites |

### Mechanism 2 is the one that gets overlooked

An `XBPQ` or `XYQHiker` rule file is JSON and selectors — **data the engine interprets, not code the
app executes**. A user bringing their own rule file is doing the same kind of thing as bringing a
playlist. That makes it the only mechanism that gives all four of: no bundled sources, user-supplied
sources, updatable without rebuilding the app, and nothing that arrives after review.

Mechanisms 3, 4 and 5 each buy updatability by giving up the last of those. That is a real trade,
not a defect — it is simply a trade that only one of the two build profiles can afford.

### Why 5 sits below 4 rather than beside it

drpy runs on **JavaScriptCore, which the platform provides**. Python runs on **a CPython this project
bundles itself**. Whatever latitude exists for downloaded interpreted code has historically been
written around the platform's own JavaScript engines, so a bundled interpreter is a structurally
weaker position — not merely a worse one by degree. Treat that as reasoning to verify at submission
time, not as a quoted rule.

### The gates, and the one thing that must stay true

Each remote mechanism is one line:

| Mechanism | Off switch |
|---|---|
| Compatibility pack | `SpiderPackStore.url(for:)` returns `nil` |
| drpy | the `isDrpySpider` branch in `CSPSourceResolver.canResolve` returns `false` |
| Python | simply never install `PythonSpiderSupport.makeRuntime` — core links no interpreter at all |

Python's is the cleanest of the three, which is not an accident: IOS-POC-7H built that seam precisely
so `WebHTVCore` keeps building where no interpreter exists.

**The rule that keeps the gates usable: no remote mechanism may become load-bearing.** The bundled
scripts have to stay independently correct. The moment a spider fix ships only through the pack, or a
source is reachable only through drpy or Python, closing the gate stops shipping a smaller app and
starts shipping a broken one.
