# Solutions

## Summary

| Ticket / feature | Status |
|---|---|
| RES-101 · Search shows results for the wrong query | Fixed |
| RES-107 · Deep link opens to a crash | Fixed |
| RES-102 – RES-106 | Not started |
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

## RES-107 · Deep link opens to a crash

### Reproduction

With the app running on the emulator:

```
adb shell am start -a android.intent.action.VIEW -d "rescu://open/deal?id=42&source=push" dev.rescu.rescu
```

The result:

```
The following _TypeError was thrown building DealDetailsScreen(dirty):
type 'Null' is not a subtype of type 'DealModel' in type cast
#0  DealDetailsController.onInit (deal_details_controller.dart:28:26)
```

### Root cause

`DealDetailsController.onInit` did `deal = Get.arguments as DealModel`. It
assumed the screen is always opened from a list, which passes the whole
`DealModel` as a navigation argument. A deep link (Android intent, or
**Simulate deep link…**) is just a route string, `/deal?id=42&source=push`.
It carries the id as a route parameter and has **no arguments**, so
`Get.arguments` is `null` and the cast throws while building the screen.

The route already contained everything needed. `Routes.dealRoute()` puts the
`id` in the URL even for in-app navigation, and `DealRepo.fetchById` exists.
The screen just never used them.

### Fix

- `DealDetailsController`: the deal is now an `Rxn<DealModel>`.
  - If a `DealModel` argument is present (opened from a list), it is used
    immediately, exactly as before, with no extra request.
  - Otherwise the controller reads `id` from `Get.parameters` and fetches the
    deal with `DealRepo.fetchById`.
  - Analytics and the availability re-check use the id, so they work before
    the deal has loaded.
- `DealDetailsScreen`: shows a spinner while a deep-linked deal loads, then
  the normal details page. If the fetch fails (unknown id, network), it shows
  "Couldn't load this deal" with **Try again**.

### Why this fix

The deep-link URL is the screen's real contract: `id` is enough to show a
deal, and the argument is only an optimisation to skip a fetch. Making the
screen work from the route alone fixes every entry point: push
notifications, the in-app simulator, and any future link. The list path
stays instant.

### Alternatives considered

- **Resolve the deal before navigating** (for example in a deep-link handler
  or a `GetMiddleware` that fetches it and passes arguments). Rejected. It
  needs a second path for platform-delivered routes (which go straight to
  the navigator), and it blocks navigation on the network with no loading
  UI.
- **Look the deal up in `HomeController.deals`.** Rejected. On a cold start
  or a deep link to a deal that isn't on a loaded page, there is nothing to
  find. It also couples the details screen to the home feed.
- **Catch the error and show a fallback screen.** Explicitly not acceptable
  per the ticket. An error state exists only for a genuinely missing deal or
  a failed request, with retry.

### Edge cases

- Invalid or missing `id` (`/deal?id=abc`): `int.tryParse` gives null, so
  the screen goes straight to the error state (by the code path; not
  exercised on the device).
- Unknown id (`id=99999`, API 404): "Couldn't load this deal" + Try again,
  tested.
- **Not handled:** on a **cold start** from a deep link, the deal page is the
  only route, so Back leaves the app instead of going to Home. The page
  itself is fully working. Putting Home underneath would need custom
  initial-route handling for platform deep links, and I kept it out of this
  fix's scope.
- **Not handled:** if the deal loads after the user has already left the
  screen, the result is written to the closed controller. That is harmless.

### Verification

On the emulator:

| Scenario | Result |
|---|---|
| Deep link via `adb` while the app is running | Deal 42 (*Mystery Japanese Basket*) loads fully. Add to bag works. Back returns to Home. |
| Deep link via `adb` on a cold start (`am force-stop` first) | App opens directly on deal 42, no crash. |
| Home → ⋮ → **Simulate deep link…** → Open | Deal 42 loads (`GET /deals/42`). |
| Tap a card in the feed | Opens instantly from the argument, no extra `GET /deals/:id`. |
| Deep link with `id=99999` | "Couldn't load this deal" + Try again (API 404), no crash. |
