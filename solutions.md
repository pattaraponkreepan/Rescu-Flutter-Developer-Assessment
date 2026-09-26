# Solutions

## Summary

| Ticket / feature | Status |
|---|---|
| RES-101 · Search shows results for the wrong query | Fixed |
| RES-106 · Wrong pickup times; "Pickup today" misses deals | Fixed (with regression tests) |
| RES-102 – RES-105, RES-107 | Not started |
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
