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

**Ported classes: 7.** `AppGet`, `AppQi`, `App99`, `App3Q` (苹果CMS App-API family), `Bili`
(bilibili public API), and the two rule engines `XBPQ` and `XYQHiker`. See
`docs/CSP_MIGRATION_STATUS.md` for what each one covers and what it was measured doing.

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
