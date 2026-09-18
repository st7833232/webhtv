# IOS-POC-5P — the headers travel with the URL

A spider has always attached request headers to its play result. The app threw them away between
resolving a stream and opening it, so a CDN that checks `Referer` produced a URL that looked fine and
then refused to play. This closes that gap from the spider all the way to `AVPlayer`.

## The measurement this stage exists for

Re-measured 2026-09-18 on one freshly resolved bilibili URL, four requests within seconds:

| request | result |
|---|---|
| browser `User-Agent` + `Referer: https://www.bilibili.com` | **206** |
| browser `User-Agent`, no Referer | 403 |
| `AppleCoreMedia` UA + Referer | 403 |
| the `backup_url` mirror, `AppleCoreMedia` UA + Referer | 403 |

**Both headers matter, not just the Referer.** The 2026-09-17 note in IOS-POC-5L said a bare
`AppleCoreMedia` request got a 206; that was an `akamaized.net` mirror on that day, and the same
mirror refuses it now. The correction matters for the design: sending only a Referer would not have
been enough, and the port already attaches both — so what had to change was the app carrying *the
whole header set*, not one well-known field.

`Bili.js` already sent that Referer with its play result. Three places discarded it: the decode
(`SpiderPlayResponse` had no `header` field), the probe (`MediaProbe.classify` sent none, so a 403
came back as `.unknown`, which reads as dead media) and the player (`AVPlayerItem(url:)` carries no
headers at all).

## What changed

| | before | after |
|---|---|---|
| `SpiderPlayResponse` | `parse`, `url` | + `header`, tolerant of a spider writing a non-map |
| `SourceClient.playbackURL` | `URL?` | `PlaybackTarget?` — the URL **and** its headers, as one fact |
| `MediaProbe.classify` | URL only | `classify(_:headers:session:)`, headers merged with the range request |
| `MediaSniffer` call | no referer | the spider's `Referer`, which is what a player page usually demands |
| built-in player | `AVPlayerItem(url:)` | `AVURLAsset(url:options:)` when there are headers, unchanged when there are none |
| the 61-source sweep | probed bare | probes with the same headers the app will use, so the sweep and the app agree |

`PlaybackTarget` is two fields rather than a bare `URL` on purpose: a stream and the headers that
make it play are one fact, and every path that carried only the first half is a source that resolved
and then 403'd.

## The one uncomfortable detail

`AVPlayer` accepts request headers only through `AVURLAsset` options, under the key
`AVURLAssetHTTPHeaderFieldsKey`, which **is not in Apple's public headers**. It is spelled as a
string literal here rather than referenced, with the reasoning written at the call site. The
alternatives were an `AVAssetResourceLoaderDelegate` proxy (a whole second HTTP client, for the same
result) or a local HTTP server (which this project has ruled out). If the key ever stops working the
failure is the one we already had — the stream 403s — and with no headers the asset is built exactly
as before, so nothing that plays today can regress.

For an App Store build this sits in the same bucket as the compatibility pack: a risk to disable, not
to argue. Personal sideloading, the only pipeline that exists, is unaffected.

## What this does not fix

**External players still cannot be told about headers.** Infuse, Fileball, SenPlayer and VidHub are
reached through a URL scheme, and a URL scheme is the whole interface they expose. A referer-checked
stream opened in one of them will still fail; the built-in player is the one that can play it. The
picker does not yet say so — noted as the obvious next small thing, not done here.

## Verification

- `WANG_MOVIE_JSON=… swift test --package-path ios` → **95 tests, all pass** (4 new).
- `theProbeSendsTheHeadersTheSourceAskedFor` stands a `URLProtocol` in front of a fake CDN that
  answers 403 without a `Referer` and 206 with one — the same behaviour measured on bilibili — and
  asserts the probe reports `.unknown` bare and `.media` with headers, that both headers arrive, and
  that the existing `Range` request survived.
- `aSpidersHeadersReachThePlaybackTarget` drives a spider through `SourceClient` and asserts the
  headers the script wrote are the headers the player is handed.
- `anUnusableHeaderFieldIsNoHeadersRatherThanNoPlayback` — a spider writing `false` or a number
  costs its own headers, never the play result.
- **`avURLAssetSendsTheHeadersItWasGiven` — the one no stub can prove.** AVFoundation does not use
  `URLSession`, so a `URLProtocol` cannot see its requests. The test stands a real `NWListener` on a
  real port, points `AVURLAsset` at it with the header option, and asserts on the bytes that arrived:
  `Referer: https://www.bilibili.com` **and** `User-Agent: WebHTV/IOS-POC-5P`. That is this repository
  observing the undocumented key work, and observing that it overrides AVFoundation's own UA, rather
  than repeating that everyone uses it.
- Simulator, driven end to end: the app opened on the seeded configuration, the site picker listed
  all 62 sources, `bili靜聽歌` loaded a real bilibili grid, and a title opened to a detail screen with
  the `B站` flag — so the whole spider path runs inside the app, not only in tests.
- Live: the 62-source sweep re-run. **It landed in another bad provider window** (`PLAYABLE=8`,
  `ERROR=18`, 9 of them TLS certificate failures that `curl` reproduces) and all four `Bili` sites
  came back `EMPTY` on bilibili's risk-control page, so it did **not** produce the Bili confirmation
  it was run for. 薦片 did come back `+hdr1 [media] PLAYABLE`, which is the header path reaching the
  sweep's own probe.
- `xcodebuild … iPhone 17 Pro -configuration Debug build` → BUILD SUCCEEDED.
- **Simulator only.** `AVURLAsset` header delivery has not been observed on a physical device.

## Not established, and honestly so

- **No bilibili stream has been played end to end inside the app.** The pieces are each measured —
  the CDN's rule, the spider attaching both headers, the app carrying them, `AVURLAsset` sending them
  — but the join has not been observed as a playing video. What blocked it is below.
- **A synthetic tap on the episode chip did nothing.** Two taps at the chip's centre produced no
  sheet, no alert and no spinner, while the back button on the same screen responded immediately, so
  tap injection itself was working. This is not caused by anything in this stage — the chip predates
  it — but it is unexplained and worth one bounded look: either the hit target is smaller than it
  looks, or that button is genuinely dead.

## Ponytail review of the final diff

- One new two-field struct, one new parameter with a default on `classify`, one `AVURLAsset` branch.
  No player abstraction, no header-policy type, no per-site override table.
- The headers are carried, never invented: the app adds nothing of its own, so a source that needs
  none behaves exactly as it did.
- Not written: telling external players about headers (they have no way to hear it), a UI warning in
  the picker, per-request cookies (the jar already handles those inside the spider).
