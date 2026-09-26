# Solutions

## Summary

| Ticket / feature | Status |
|---|---|
| RES-101 · Search shows results for the wrong query | Fixed |
| RES-102 · Crash after leaving My orders | Fixed |
| RES-103 · Requests pile up the longer you browse | Fixed |
| RES-104 · Duplicate deals in the home feed | Fixed (with regression tests) |
| RES-105 · Home feed is janky and memory keeps climbing | Fixed (measured before/after) |
| RES-106 · Wrong pickup times; "Pickup today" misses deals | Fixed (with regression tests) |
| RES-107 | Not started |
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

## RES-102 · Crash after leaving My orders

### Reproduction

On the Android emulator, open **My orders** (the seed data has three active
orders with upcoming pickups), then tap Back. Within a second the console
shows the following, and it repeats every second from then on:

```
Unhandled Exception: setState() called after dispose(): _PickupCountdownState#60bb9 (lifecycle state: defunct, not mounted)
#2 _PickupCountdownState.initState.<anonymous closure> (package:rescu/feature/order/widget/pickup_countdown.dart:22:7)
#3 _Timer._runTimers (dart:isolate-patch/timer_impl.dart:398:19)
```

It is logged three times per tick: once per active order.

### Root cause

`PickupCountdown` (`lib/feature/order/widget/pickup_countdown.dart`) is a
`StatefulWidget`. It starts a `Timer.periodic` in `initState` and calls
`setState` every second. The timer was never stored and never cancelled, so
it **outlives the widget**. Leaving My orders disposes the `State`, the timer
fires again, and `setState()` runs on a defunct `State`.

This is also a leak, not just a noisy error. Each live timer keeps a
reference to its `State`, so every visit to My orders adds one more immortal
timer per active order. Those timers keep firing (and allocating) for the
rest of the session.

### Fix

Keep the timer in a field and cancel it in `dispose()`. A resource opened in
`initState` is closed in `dispose`, so its lifetime matches the widget's.

### Why this fix

The countdown's lifetime belongs to the widget, and nothing else in the app
depends on this timer. Cancelling it in `dispose()` removes the cause: no
timer survives the widget, so no `setState` on a disposed `State` and no
leaked references.

### Alternatives considered

- **`if (mounted) setState(...)`**. Rejected. It silences the exception, but
  the timer keeps running forever and keeps the `State` alive. That hides the
  symptom and keeps the leak, which is exactly what the brief warns against.
- **try/catch around `setState`**. Rejected for the same reason.
- **Moving the tick into `OrdersController` as an `RxInt`/`Timer` cancelled in
  `onClose`**. Rejected for this ticket. It would work, but it moves
  view-only state into the controller and is a larger change than the bug
  needs. A shared ticker is worth revisiting for F-1, where many countdowns
  have to tick together cheaply.

### Edge cases

- Several active orders: each tile owns and cancels its own timer.
- Returning to My orders several times: the old timers are gone, so they no
  longer pile up.
- **Not handled:** once the pickup window is open, the text no longer
  changes, but the timer still ticks every second while the screen is
  visible. That is harmless because it is cancelled on dispose, but it could
  be stopped early as an optimisation.

### Verification

On the emulator I opened and closed My orders twice after the fix. There were
0 `setState() called after dispose()` errors, and the countdowns ("Opens in
17:50", "46:50", "2h 11m") still ticked while the screen was open.

---

## RES-103 · Requests pile up the longer you browse

### Reproduction

On the Android emulator, open deal 1 and go back, then open deal 5 and go
back. Open deal 2 and tap **Add to bag** once. That single tap produces:

```
re-checking availability for deal 1
re-checking availability for deal 5
re-checking availability for deal 2
GET /deals/5
GET /deals/2
GET /deals/1
```

That is three requests, two of them for screens that were closed earlier.
Each deal page you view adds one more request to every later cart change.

### Root cause

`DealDetailsController.onInit` subscribes to the cart:

```dart
ever(cartService.itemCount, (_) => _recheckAvailability());
```

`ever` subscribes directly to the `Rx`'s stream and returns a `Worker`. It is
**not** tied to the controller's lifecycle (I checked `get` 4.7.3,
`rx_workers.dart`: it is a plain `listener.listen(...)`). The worker was
never stored or disposed.

`CartService` is a `GetxService` that lives for the whole session. So:

1. Leaving a deal page deletes the controller (`onClose` runs), but the
   subscription on `CartService.itemCount` stays alive.
2. The subscription holds the closure, and the closure holds the controller.
   The disposed controller cannot be garbage-collected (a leak).
3. Every later cart change calls `_recheckAvailability()` on every controller
   ever created, which fires `GET /deals/:id` for screens that no longer
   exist.

The bug comes from treating the controller as if its subscriptions die with
it. A subscription on a longer-lived object lives as long as that object,
unless we cancel it.

### Fix

Keep the `Worker` returned by `ever` and dispose it in `onClose()`. The
subscription now has the same lifetime as the screen that needs it.

### Why this fix

It removes the cause, not just the extra traffic: no subscription outlives
its controller, so there are no stale requests and no leaked controllers. The
"re-check stock when the cart changes" behaviour still works for the screen
that is actually open.

### Alternatives considered

- **Guard `_recheckAvailability` with an `isClosed` check.** Rejected. It
  stops the requests but keeps every dead controller subscribed and in
  memory, so it hides the symptom.
- **Debounce or throttle the re-check.** Rejected. It reduces the burst but
  still issues one request per dead screen.
- **Fetch stock once in `onInit` / pull-to-refresh only.** Rejected for this
  ticket. It changes product behaviour (live availability on cart change),
  and the ticket is about the leak, not the feature.

### Edge cases

- Pages opened several times: each visit creates and closes its own worker,
  so nothing accumulates.
- **Not handled:** if the controller closes while a `fetchById` is still in
  flight, the response is written to the closed controller's `Rx`. That is
  harmless (nobody listens anymore), so I left it.

### Verification

Same script on the emulator after the fix (deal 1 → back, deal 5 → back,
deal 2 → Add to bag). **One** request, down from three:

```
re-checking availability for deal 2
GET /deals/2
```

---

## RES-104 · Duplicate deals in the home feed

### Reproduction

On a device the bug depends on timing: page requests take 250–950 ms, and
the refresh has to land inside that window. To reproduce it deterministically
I wrote `test/home_controller_test.dart`. It uses a `DealRepo` whose requests
stay pending until the test completes them, so the test controls the order
in which responses arrive.

Against the original code:

- **Load page 2, pull to refresh, refresh returns first, then page 2
  returns.** The feed ends up with 40 items right after the refresh (page 1
  plus the stale page 2). Scrolling on requests page 2 *again*, which
  duplicates those 20 cards.
- **Same, but the stale page 2 fails.** The next load requests **page 1**
  again, which duplicates it.

Repeat either and the feed grows past the 122 deals in the catalog.

### Root cause

`HomeController` keeps pagination state (`_page`, `_isFetchingMore`, the
`deals` list), and `loadMore` and `refreshDeals` both mutate it across an
`await` with no coordination:

1. `loadMore` increments `_page` to 2 **before** its request, then awaits.
2. `refreshDeals` sets `_page = 1` and replaces `deals` with page 1.
3. The old `loadMore` resumes and runs `deals.addAll(page2)` on the **new**
   list. That response belongs to the feed that the refresh just replaced.
   The feed now holds pages 1 + 2 while `_page` says 1.
4. The next `loadMore` asks for page 2 again, which produces duplicates.
   On the failure path, `_page--` turns 1 into 0, so the next load re-fetches
   page 1.

The underlying problem: a page request doesn't know which feed it was made
for. A response from before the refresh is applied to the list after it.

### Fix

`lib/feature/home/home_controller.dart`:

- **Feed generation.** When a refresh's page 1 arrives, it bumps
  `_feedGeneration`. `loadMore` records the generation when it starts. After
  the `await`, it applies its result (or its error handling) only if the
  generation is unchanged. Otherwise the result is for a feed that no longer
  exists, and it is dropped.
- **Commit pagination on success only.** `loadMore` computes
  `nextPage = _page + 1` locally and sets `_page = nextPage` only after the
  page has been appended. The `_page++` / `_page--` rollback is gone, so a
  failure can no longer rewind the counter.
- Because the dropped request will never call `loadComplete()`, the refresh
  resets `_isFetchingMore` and ends the footer spinner itself. Otherwise the
  footer would stay stuck in "loading".

### Why this fix

The feed stays consistent under **every** ordering. A page is appended only
to the feed it was requested for, and `_page` always matches what is in the
list. The generation is bumped when the refresh *lands*, not when it starts.
That covers both a page requested before the refresh and one requested while
the refresh is still in flight. `pull_to_refresh` 2.0.0 does not block
load-more while refreshing, so I didn't rely on it.

### Alternatives considered

- **Deduplicate by `deal.id` before `addAll`.** Rejected. It hides the
  duplicates but `_page` still desyncs, so pages get skipped or re-fetched
  and the "more items than the catalog" problem remains in other forms. That
  is a symptom fix.
- **Block refresh while a page is loading (or the other way round).**
  Rejected. The user explicitly pulled to refresh, and making them wait for a
  page they no longer want is worse UX.
- **Cancel the in-flight request.** Not possible: the fake API's futures
  can't be cancelled, so the response still arrives and has to be ignored
  anyway.

### Edge cases

- Stale page arrives after the refresh: dropped (test 1).
- Stale page arrives before the refresh lands: appended to the old list, then
  replaced by the refresh (test 2).
- Stale page fails: its error is ignored and the counter isn't touched
  (test 3).
- **Not handled:** if `refreshDeals` itself throws, it never calls
  `refreshFailed()`, so the header can stay in the refreshing state. That
  behaviour is unchanged and outside this ticket.
- **Not handled:** after reaching the last page (`loadNoData`), a refresh
  doesn't reset the footer's "no more" state
  (`refreshCompleted(resetFooterState: true)`). That is a separate issue.

### Verification

- `flutter test`: tests 1 and 3 fail on the original code (40 items after
  the refresh / page 1 re-requested) and pass after the fix. Test 2 covers the
  other ordering, which the original code already handled, so the fix can't
  regress it. All tests pass.
- On the emulator: scrolling loads pages 1 → 5, pull-to-refresh reloads
  page 1, and scrolling again loads pages 2 → 3 → 4 with no duplicates.

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

---

## RES-106 · Wrong pickup times; "Pickup today" filter misses deals

### Reproduction

I used the Android emulator with its time zone set to `Asia/Bangkok`, at
01:30 local time on 27 Sep. Every card shows its pickup window in **UTC**:

| Store | Real hours (Bangkok) | Card showed |
|---|---|---|
| Sunrise Bakehouse | 06:00 – 09:30 | **23:00 – 02:30** (the ticket's example) |
| Baan Somtam Kitchen | 05:30 – 08:00 | 22:30 – 01:00 |
| Chao Phraya Sushi | 22:00 – 01:00 | 15:00 – 18:00 |

With **Pickup today** on, Baan Somtam Kitchen and Sunrise Bakehouse
disappeared, even though both open later that same morning.

### Root cause

The backend is right: it sends ISO-8601 UTC instants (`...Z`). The bug is in
how `PickupWindowModel` turns those instants into things a person reads:

- `DateTime.parse('...Z')` returns a `DateTime` with `isUtc == true`. That is
  the correct instant, but its fields (`hour`, `day`, and what
  `DateFormat.format` prints) are **UTC wall-clock** values. `label`
  formatted it directly, so Bangkok users saw times 7 hours early, sometimes
  on the wrong side of midnight. That is why some users showed up at closed
  stores.
- `isToday` compared `start.day` (the **UTC** day of the month) with
  `DateTime.now().day` (the **local** day). Anything opening before 07:00
  Bangkok time starts "yesterday" in UTC, so the filter dropped it. It also
  compared only the day of the month, so 27 Oct would count as "today" on
  27 Sep.

Comparisons between instants (`isOpenNow`, `untilStart`, the order and
flash-sale countdowns) were already correct, because `isAfter`/`difference`
compare instants whatever the zone. Only the "human" views were wrong.

### Fix

`lib/model/pickup_window_model.dart`: keep `start`/`end` as instants, and
convert to local time exactly where a clock time or calendar day is derived.

- `label` formats `start.toLocal()` and `end.toLocal()`.
- `isToday` compares the full local date (year, month, day) of
  `start.toLocal()` with `DateTime.now()`.

### Why this fix

It fixes the cause in the one model every screen goes through: the feed
cards, the details screen and the filter all use `label` and `isToday`. It
keeps the instant as the source of truth and treats "which day / what time
is it for this user" as a presentation concern. The backend contract stays
untouched.

### Alternatives considered

- **Convert to local in `fromJson` (`DateTime.parse(...).toLocal()`).**
  Also works for the app. I rejected it because the fix would then depend
  on every producer of `PickupWindowModel` passing local values. A window
  built from UTC (as the tests and any future caller would do) would
  silently bring the bug back. Deriving local time in the getters works
  whatever the input's zone.
- **Hard-coding Bangkok time (`+7`) in the client.** Rejected. It encodes
  the server's market in the client and breaks when the market expands.
- **Showing the store's own time zone instead of the device's.** That is the
  "right" answer for a traveller browsing another city's stores. But the API
  doesn't send a store time zone or offset, so the client has no correct way
  to do it. With this API, device-local time is the best choice. The proper
  fix would be for the backend to add an IANA zone per store.

### Edge cases

- Overnight windows (22:00 – 01:00) keep their local times (tested).
- "Today" for a window that opens late tonight but ends after midnight:
  counts as today, because the start is today.
- **Not handled:** a user whose device time zone differs from the store's
  sees their own local time (see above; this needs API data).
- **Not handled / by design:** a window that already ended today is rolled
  to tomorrow by the backend, so it correctly drops out of "Pickup today".

### Tests

`test/pickup_window_model_test.dart` builds windows the way the API does
(local wall-clock time → `toUtc().toIso8601String()`) and checks `label` and
`isToday`. Early morning, late evening, tomorrow, and the same day of the
month in the next month are all covered. On the original code, 4 of the 6
tests fail on a UTC+7 machine. All pass after the fix.

These tests only catch the bug when the test process isn't in UTC. CI
should run them with a non-UTC zone (for example `TZ=Asia/Bangkok flutter
test` on Linux/macOS), ideally with both an east and a west zone.

### Verification

On the emulator after the fix, every card shows local hours (Sunrise
Bakehouse **06:00 – 09:30**). With **Pickup today** on, all 7 stores in the
first pages appear, including Baan Somtam Kitchen and Sunrise Bakehouse.
