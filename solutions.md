# Solutions

## Summary

| Ticket / feature | Status |
|---|---|
| RES-101 · Search shows results for the wrong query | Fixed |
| RES-102 · Crash after leaving My orders | Fixed |
| RES-103 · Requests pile up the longer you browse | Fixed |
| RES-104, RES-105, RES-106, RES-107 | Not started |
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
