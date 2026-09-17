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
| Utility | `host.match`, `now`, `timestamp`, `random`, `urljoin` | done |
| Storage | `host.local.get/set/del` | done |
| Text slicing | `host.cut` / `cut1` — XBPQ's `前綴&&後綴` with `[包含:]` `[不包含:]` `[替换:a>>b]`, plus `host.stripTags` | done |
| Hiker rule syntax | `&&` first-match descent, `\|\|` attribute fallback, `,N` index, `:has()`, `!prefix` stripping | done |
| RSA | — | **not implemented**; `csp_AppDrama` needs it |
| WebView / sniffing | — | **not implemented**; no ported spider needs it yet |
| `proxy` | ABI present, no host plumbing | **not implemented** |

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

If a port needs a primitive the host lacks, add it to `CatVodHost` — never inside the spider. A
spider that re-implements HTTP, crypto or parsing is a bug.

## Native `.so`

A `.so` in a JAR is not a verdict. Establish what the native code actually computes first. If it is
MD5, AES, base64, a token, a signature, a fixed string decryption, a header or a URL transform, then
reimplement that algorithm in `CatVodHost` and leave the binary behind — the algorithm is the
contract, not the binary that happened to run it on Android.

Only these are genuine blockers: a native VM, heavy control-flow obfuscation, anti-debug or
anti-tamper, Binder, device attestation, DRM, or a proprietary native protocol.
