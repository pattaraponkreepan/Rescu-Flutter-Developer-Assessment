# Solutions

## Summary

| Ticket / feature | Status |
|---|---|
| RES-101 · Search shows results for the wrong query | Fixed |
| RES-105 · Home feed is janky and memory keeps climbing | Fixed (measured before/after) |
| RES-102 – RES-104, RES-106, RES-107 | Not started |
| F-1 – F-3 | Not started |

---

## RES-101 · Search shows results for the wrong query

### Reproduction

On an Android emulator (API 35), open Search and type `sushi` one letter at a
time (~120 ms between keys). The text box ends up with `sushi`, but the list
shows *Sunrise Bakehouse* deals, which are the results for `su`.

Console log from the failing run. The lines are in **completion** order:

```
GET /deals/search?q=sush  (492ms)
GET /deals/search?q=sushi (301ms)   <- correct results rendered here
GET /deals/search?q=sus   (819ms)
GET /deals/search?q=s     (1252ms)
GET /deals/search?q=su    (1056ms)  <- last to arrive, so it wins
```

### Root cause

`SearchDealsController.onQueryChanged` starts a new search on every keystroke.
Each search writes its response into `results` when it completes. **Nothing
connects a response to the query the user currently has.** The UI shows
whichever response arrives *last*, when it should show the response to the
request that was made last.

The backend turns this into a reliable bug, not a rare one. Search latency
drops as the query gets longer
(`180 + max(0, 1200 - len * 280) + rand(300)` ms in `FakeApiService.searchDeals`):

- `s` takes about 1.1–1.4 s.
- `sushi` takes about 0.2–0.5 s.

So the shorter, older queries almost always resolve *after* the final one and
overwrite its results. That matches the ticket: "correct results appear
briefly, then get replaced by results for an earlier, shorter query".

A second symptom has the same cause. The first request to finish set
`isLoading = false` while newer requests were still in flight.

### Fix

`lib/feature/search/search_deals_controller.dart`: every search takes a
monotonically increasing request id. After the `await`, a response (or error)
is applied only if its id is still the latest one. Stale responses are
dropped.

- Only the latest request clears `isLoading`. A stale response returns early
  and leaves the spinner to the request that is still pending.
- Clearing the field also bumps the id, so a request still in flight cannot
  fill the list again after the user has emptied the query. Clearing the
  field also resets `isLoading`.

### Why this fix

It makes the result correct **regardless of timing**. The UI always reflects
the most recent request, however the network orders the responses. The fix is
small, lives in the controller that owns the state, and needs no new
dependencies.

### Alternatives considered

- **Debounce only** (search after the user pauses for ~300 ms). Rejected as
  the fix. It reduces the number of requests but does not remove the race.
  Suppose the user types `su`, pauses longer than the debounce window, then
  types `shi`: the slow `su` response can still land after `sushi`. Debounce
  is a good *addition* for backend load, and it belongs in a separate commit.
- **Cancelling the previous request (`switchMap` via rxdart).** Rejected.
  It adds a package, which the rules forbid. The fake API's futures cannot be
  cancelled anyway, so the old response would still arrive and we would still
  have to ignore it.
- **Compare the response to the current text.** Rejected. The response does
  not echo the query, so the controller would have to track the text-field
  state. A request id is simpler and does not depend on the view.

### Edge cases

- Field cleared while a request is in flight: handled (see Fix).
- A stale request fails: the error is ignored, because it belongs to a query
  the user has already abandoned.
- **Not handled:** if the *latest* request fails, the list keeps the previous
  results and shows no error state. This behaviour is unchanged from before
  and is out of scope for this ticket.
- **Not handled:** one request per keystroke (request volume). This is left
  for a follow-up debounce commit.

### Verification

I re-ran the repro on the emulator after the fix. The responses still arrived
out of order (`sushi` → `su` → `sush` → `s`), and the list correctly showed
*Surprise Sushi Box*, *Lucky Sushi Platter* and *End-of-day Sushi Bag*.

---

## RES-105 · Home feed is janky and memory keeps climbing

### How I measured

All numbers come from the Dart VM service, from the same events DevTools
uses: `Flutter.Frame` for the frame chart, `Flutter.RebuiltWidgets` for Rebuild
Stats, and `PaintingBinding.imageCache` for image memory. Process memory comes
from `adb shell dumpsys meminfo`. Each run:

- **Device:** Android emulator (Pixel 8, API 35, x86_64).
- **Starting state:** app data cleared first (`pm clear`), so both runs start
  with an empty image disk cache.
- **Gestures:** the same scripted flings down the home feed (`adb input
  swipe`).

Rebuild counts and image-cache size need **debug** mode (widget-creation
tracking and `evaluate`). Frame times and memory come from **profile** mode,
because debug-mode timings are not representative.

### Root causes

There are three separate problems.

**1. The whole screen rebuilt on every scroll pixel.**
`HomeController._onScroll` wrote `scrollController.offset` into
`scrollOffset` (an `RxDouble`) on every scroll notification. `HomeScreen`
read it at the top of a single `Obx` wrapping the entire `Scaffold`: app bar,
feed and FAB. Every scrolled pixel changed the value, so every frame rebuilt
the whole screen, including every mounted `DealCard`. The screen only needed
two booleans from that value ("scrolled past 4 px" for the app-bar elevation,
"past 800 px" for the scroll-to-top FAB).

**2. The feed was an eager `ListView(children: [...])`.**
On each rebuild it constructed a `DealCard` widget for *every* loaded deal
(up to 122) and diffed the list, even though only about 3 are on screen.
Combined with (1), that happened on every scroll frame, and the cost grew
with every page loaded.

**3. Images were decoded at full source resolution.**
The API serves 1600×1200 images: 1600 × 1200 × 4 bytes ≈ **7.3 MB** per
decoded image. The feed draws them at about 380×160 dp. `CachedNetworkImage`
had no `memCacheWidth`, so every image was decoded and uploaded as a GPU
texture at full size. The 100 MB `ImageCache` filled up after only 13
images, so scrolling back meant evicting, re-decoding and re-uploading. Live
images (on screen or loading) are not bounded by the cache limit at all.

### Fix

1. **Scope reactivity to what actually changes.** The controller exposes
   `isScrolled` and `showScrollToTop` as `RxBool`s. GetX only notifies when an
   `Rx`'s value changes, so scrolling triggers a rebuild only when a
   threshold is crossed. `HomeScreen` now has three small `Obx`es: the app bar
   (elevation), the body (loading, deals, filter) and the FAB. None of them
   depends on the scroll position.
2. **Build the feed lazily** with `ListView.builder`: the flash rail, the
   header and the cards are created only when they come near the viewport.
   All observables are read inside the `Obx` builder, so dependency tracking
   still works (the item builder runs later, during layout).
3. **Decode images at display size.** `TheNetworkImage` uses a
   `LayoutBuilder` to find the box it is drawn into and passes
   `memCacheWidth = box's larger side × devicePixelRatio`. A feed card now
   decodes at about 1000 px wide instead of 1600, a flash-rail card at about
   500 px, and an order thumbnail at about 170 px.

### Before / after

Debug mode, 15 flings:

| Metric | Before | After |
|---|---|---|
| Widget rebuilds (total) | 15,009 | 4,408 |
| `DealCard` builds | 550 | 119 |
| Image cache | 95.2 MB for **13** images (7.3 MB each) | 99.3 MB for **35** images (2.8 MB each) |

Profile mode, 30 flings, all 7 pages loaded:

| Metric | Before | After |
|---|---|---|
| UI thread frame time: avg / p90 | 3.96 ms / 8.09 ms | 3.37 ms / 6.60 ms |
| UI frames over 16.7 ms | 14 | 6 |
| Total PSS | 152 MB | 140 MB |

The 119 `DealCard` builds after the fix are each card being built once as
it scrolls into view (about 6 pages were loaded). Before the fix, the cards
already on screen were rebuilt on every frame.

**What these numbers do not show:**

- **Raster time.** It was about 34 ms per frame in both runs. That is the
  emulator's virtualized GPU (nearly every frame is over budget in both runs,
  whatever the widget tree does). It needs confirming on a real mid-range
  device, where the smaller textures
  should also reduce raster and GPU memory.
- **The image cache's own size.** It sits near its 100 MB cap either way,
  because that cap bounds it. What changed is how much content fits in it
  (13 → 35 images) and the size of each live image, which the cap does not
  bound.

### Alternatives considered

- **Keep `scrollOffset` but throttle or debounce the listener.** Rejected. It
  still rebuilds the whole screen, just less often, and a delayed app-bar
  elevation looks laggy.
- **Material 3 `scrolledUnderElevation` instead of a listener.** Tempting,
  since M3 is on and it needs no controller state. But it changes how the app
  bar looks (tint instead of shadow), and the FAB still needs the threshold.
  I kept the existing look.
- **Shrinking `ImageCache.maximumSizeBytes`.** Rejected as the fix. With
  7.3 MB images, a smaller cap only means more re-decoding. Once images are
  decoded at display size, lowering the cap becomes a reasonable tuning
  option, but it is not needed to fix the ticket.
- **Setting both `memCacheWidth` and `memCacheHeight`.** Rejected.
  `ResizeImage` with both set distorts the aspect ratio unless you pick a
  policy, and no policy gives "cover".

### Edge cases

- Unbounded constraints (for example an image in an unconstrained scroll
  direction): `_decodeWidth` returns null and decodes at full size, which is
  the old behaviour, instead of guessing.
- Square order thumbnails: sizing by the larger side and assuming a landscape
  source leaves the decoded height at about 0.75 of the box (a slight
  upscale, invisible at 64 dp). A portrait source would upscale more. The API
  only serves 4:3 landscape images today.
- **Not handled:** the shimmer placeholders use `ShaderMask`, and each one
  costs a `saveLayer` per frame while an image is loading. That adds to
  raster cost during loading. It is a smaller effect and I left it.
