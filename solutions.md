# Solutions

## Summary

| Ticket / feature | Status |
|---|---|
| RES-101 · Search shows results for the wrong query | Fixed |
| RES-104 · Duplicate deals in the home feed | Fixed (with regression tests) |
| RES-102, RES-103, RES-105 – RES-107 | Not started |
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
