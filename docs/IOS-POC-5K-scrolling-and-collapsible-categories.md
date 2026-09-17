# IOS-POC-5K — category rows scroll away, a Top button, collapsible children

Stage record. Four requests, all `CMSView` layout; no new types and no core changes.

## 1. The category rows scroll away with the grid

They were in a `VStack` above the `ScrollView`, so they were pinned. On a phone with a category row,
a child row and five filter rows that is most of the screen. The rows moved inside the `ScrollView`,
above the grid, so they scroll off like any other content.

## 2. Top button

Bottom-trailing overlay on the scroll view, hidden while the grid is already at the top, and
`proxy.scrollTo` back to a zero-height anchor at the top of the content.

**Two attempts failed before the third worked**, and the reason matters for anyone touching this:

- `onAppear`/`onDisappear` on a marker at the top of the content: **a plain `ScrollView` is not
  lazy**, so nothing is unloaded when it scrolls out of sight and `onDisappear` never fires.
- `GeometryReader` + a `PreferenceKey` reading the marker's `minY`: no value arrived. A zero-height
  container is not a reliable place to measure from.
- What works: **`LazyVGrid` genuinely does load and unload its cells**, so the first cell's
  `onAppear`/`onDisappear` is a dependable "am I at the top" signal, and it needs no extra type.
  The grid already had an `onAppear` on the last cell for pagination; this is the same idea at the
  other end.

A consequence worth knowing: because the signal is the first *cell*, the button appears slightly
later than a pixel-offset approach would — the category rows have to scroll past first. That is the
right moment anyway.

## 3 & 4. Parent categories fold their children away

A parent with children is now also a disclosure control:

- tapping a **different** parent switches to it and unfolds it, as before
- tapping the one **already listed** folds its child row away, and again to unfold
- the chevron points down when the children are hidden and up when they are showing
- a parent with no children has no chevron and behaves exactly as before

Folding does not change what is listed: the chosen child category stays selected and the grid does
not reload. Only the row is hidden, which is what "讓子分類可以藏起來" asks for.

State is a `Set<String>` of folded group ids, so the default is unfolded — the previous behaviour.
It is per-`CMSView`, and switching source rebuilds the view (`.id(selectedSite.id)`), so nothing
leaks between sources.

`chip(_:id:active:)` lost its `active` parameter in the same pass: parents are now `parentChip` and
nothing else ever passed it.

## Verification

- `xcodebuild … iPhone 17 Pro Debug` → **BUILD SUCCEEDED**. UI-only; the core suite is untouched.
- **Simulator, end to end (iPhone 17 Pro):**
  - 靈虎: scrolling the grid carries the category row off screen; the Top button appears; tapping it
    returns to the top and the button hides again.
  - 360 (which has child categories): every parent shows a ⌄ chevron. Tapping 电影 unfolds
    动作片/喜剧片/爱情片/科幻片/恐怖片, flips the chevron to ⌃ and lists action films. Tapping 电影
    again folds the row away, flips the chevron back, and **leaves the listing unchanged**.
  - 永樂 (no child categories): no chevrons, unchanged behaviour.

## Files

| file | change |
|---|---|
| `WebHTVApp/Sources/WebHTVApp.swift` | rows inside the scroll view; `topButton`; `parentChip` with fold state; `chip` loses its dead `active` parameter |
