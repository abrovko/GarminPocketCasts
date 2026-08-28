# Pocket Casts API contract tests

The watch talks to the Pocket Casts **web player** API: unofficial, reverse-engineered, and
with no changelog or deprecation notice. Everything the app believes about it was measured
once, on hardware, and then written down. This directory turns those measurements into
something that can be re-run in seconds.

**It does not test the app.** There is no Monkey C here and nothing imports anything from
`source/`. It tests the *service*, so that when the watch stops syncing you can tell an API
change from a code change without a sideload, a log pull and an afternoon.

Run it when something looks wrong, before blaming `PocketCastsClient.mc`, and after any change
to what the app reads.

## Running it

Python is not installed on the machine this repo is developed on, so the runner uses Docker —
the same way `proxy/` is tested.

```powershell
$env:PC_EMAIL    = 'you@example.com'
$env:PC_PASSWORD = 'your-password'
.\tests\api\Run-Tests.ps1
```

Credentials come from the environment and are passed to the container **by name**, so nothing
lands in a command line, an image layer or a file. Nothing is stored, and there are no
credentials anywhere in this tree — same rule as the rest of the repo. With them unset every
test that needs an account skips and the harness self-tests still run.

Without Docker, any Python 3.10+ works:

```sh
pip install -r tests/api/requirements.txt
cd tests/api && python -m pytest
```

## What it checks

| Endpoint | Assumptions under test |
| --- | --- |
| `POST /user/login` | 200 → `{token, uuid}`; **bad credentials are 401, not 400** |
| `POST /up_next/sync` | `changes: []` really is a read; `serverModified` is a **string**; entries carry `uuid`/`podcast`/`title`/`url`; the response stays small enough to parse on a 512 KB device |
| `POST /user/playlist/list` | deleted playlists are still returned; smart playlists carry no episodes; **`manual` is the only discriminator**; episode entries carry a `url` and no file type; **the `episodes` array is served in `episodeOrder`**, which the watch relies on and never reads; the response stays parseable |
| `POST /user/in_progress` | entries carry `playedUpTo` and `duration`; **everything returned is `playingStatus: 2`**; **`total` matches what came back**, i.e. it is the whole list and not a page |
| `GET /mobile/podcast/findbyepisode/…` | works with **no token**; answers with exactly one episode; stays small; **its declared `file_type` agrees with what `encodingForUrl()` sniffs off the playlist url** |
| `POST /sync/update_episode` | **position alone is recorded but leaves `playingStatus` untouched; `status` is what makes it stick**, and separately whether a stored position comes back from `/user/in_progress` — `--mutating` only |

Each test's docstring says what breaks in the app if the assumption fails. That is the point of
them: a red test should name the consequence, not just the field.

## Two safety rules, both enforced in `conftest.py`

**Nothing writes to the account by default.** Two of these endpoints mutate. `/up_next/sync`
would ADD, REMOVE or REORDER the real queue if anything were ever put in its `changes` array —
the suite's first up-next test exists to confirm the empty array is inert. `/sync/update_episode`
writes playback position and played status outright, so every test that calls it is marked
`mutating` and deselected unless `--mutating` is passed.

To run those you need an episode to aim them at. `-ListEpisodes` finds one — it logs in, lists
everything in Up Next and your manual playlists, marks which episodes the server already
considers playing, and prints the two lines to paste:

```powershell
.\tests\api\Run-Tests.ps1 -ListEpisodes
```

```
     STATE         EPISODE UUID    PODCAST UUID    TITLE
1.   never started 3f2a…           9b60…           How to beat the resource curse in Norway
2.   in progress   71f3…           9b60…           …
```

It is read-only, and it now prints two columns rather than one. `STATE` is whether the server
considers the episode playing — a never-started one restores exactly and is the cleaner choice,
though the A/B works either way since it compares `playingStatus` against whatever the episode
came in as. `READBACK` is whether that episode's **podcast** already appears in
`/user/in_progress`: if it does not, a position written against it cannot be read back from
there, and the round-trip test reports itself as not covered rather than failing. The listing
sorts the usable ones to the top and names the best candidate.

```powershell
$env:PC_TEST_EPISODE_UUID = '...'
$env:PC_TEST_PODCAST_UUID = '...'
.\tests\api\Run-Tests.ps1 -Mutating
```

They move that episode's position twice and mark it played once, then put it back — to its own
position with `status: 2` if it was in progress, or to unplayed at 0 if it was not. Both are
read back and confirmed; the teardown says `RESET DID NOT TAKE` rather than claiming a clean
restore it did not observe. Point it at something disposable anyway.

**The state it starts from matters as much as the one it leaves.** "Not reported by
`/user/in_progress`" covers two different episodes — one never started, one already finished —
and they do not behave the same. An earlier run that ended mid-test leaves the second kind
behind, which is how one run once poisoned the next. So an unreported episode is explicitly
reset to unplayed *before* the A/B rather than assumed fresh.

**The push and the pull are two tests, because they are two claims.** Running them as one made
a confirmed push read as a broken one.

- The A/B — what each request body *stores* — is checked against `/user/podcast/episodes`, the
  episode record. That is the push half, and every position the watch banks depends on it.
- The round trip — whether a stored position is *reported back* — is checked against
  `/user/in_progress`, a filtered view of that record and the only place the refresh reads
  positions from. That is the pull half.

**The round trip waits, and says so while it waits.** Nothing states that the view updates
synchronously with the write, so it polls for 60 s — set `PC_ROUND_TRIP_SECONDS` to try a
longer window against the lag theory. pytest holds a test's output until it ends, so the wait
prints straight past the capture; a run without that looked exactly like a hang and got killed
at two minutes.

`/user/podcast/episodes` is not an endpoint the watch calls, so it is read defensively: a test
that cannot read it reports itself as not covered rather than failing. An assumption about a
call the watch never makes must not be able to fail a test about one it makes constantly.

Reading the record rather than the view also means the A/B no longer needs a never-started
episode — it compares `playingStatus` against whatever the episode came in as. Only the round
trip still cares what it is pointed at.

**An unchecked assumption is never reported as a passing one.** Most of what is here depends on
what the account happens to hold: there is no way to assert how a smart playlist is shaped on an
account with none, or how Up Next entries look when the queue is empty. Those call
`not_covered()`, which skips *and* prints a separate `NOT COVERED BY THIS ACCOUNT` section at
the end of the run. Read it — it is the difference between "verified" and "could not look".

## Shape snapshots

Assertions tell you something broke. `shapes/*.json` tells you **what**.

Every response is recorded as its type skeleton — each value replaced by its type name, keys
absent from some entries of an array marked `?` — and compared against the committed baseline
on every run. A drift is reported as a path and a change, not a diff of two blobs:

```
the shape of user_in_progress has changed:
  TYPE     $.episodes[].playedUpTo  int -> str
  ADDED    $.episodes[].playbackSpeed  (float)
  OPTIONAL $.episodes[].duration  (always present -> sometimes missing)
```

Values are discarded, which is what makes the snapshots safe to commit to a public repo — no
token, no email, no episode titles, nothing about what the account listens to — and what makes
them stable, so a diff is real drift rather than today's queue differing from yesterday's.
Marking keys optional rather than dropping them is deliberate: the everyday failure of an API
like this is not a field vanishing, it is a field becoming optional and the watch reading null.

**An array that is empty today is the account being quiet, not the API moving.** An empty Up
Next is a Tuesday, and it cannot be compared against a baseline recorded when it held
something — so it is reported under `NOT COVERED BY THIS ACCOUNT` rather than failed, and the
rest of the response is still compared. The opposite direction stays a failure: `FILLED` means
an array nothing has ever looked at now has entries in it.

Re-recording protects the same case. `--update-shapes` on a quiet day would otherwise write
`"episodes": []` over everything the baseline knew about the entries; `preserve_populated()`
keeps the recorded entry shape where today's response has nothing to say, and takes every other
change as recorded. `test_harness.py` checks that in both directions, because getting it wrong
destroys a baseline silently.

A missing baseline is written from the run that finds it and listed under `NEW SHAPE BASELINES
RECORDED`. **Read a new one before committing it** — a broken API baselined here will look
correct forever. To re-record after a deliberate change:

```powershell
.\tests\api\Run-Tests.ps1 -UpdateShapes
```

then `git diff tests/api/shapes/` and check what in `source/PocketCastsClient.mc` reads the
moved field.

`test_harness.py` self-tests the recorder — it needs no network and no account, because the
recorder is the part of this suite that is otherwise trusted rather than checked.

## What it does not tell you

- **It speaks for this account only.** A field is optional across all of Pocket Casts, not just
  here; a shape recorded from one busy account is evidence, not a specification.
- **It is not the watch's HTTP stack.** These are `requests` calls from a container. Several of
  the worst bugs in this project lived in Connect IQ's `makeWebRequest` — response size caps,
  content-type handling, a sync session poisoned by one failure — and nothing here can see any
  of that. A green run means the API is behaving; it does not mean the watch will.
- **The User-Agent is honest** (`GarminPocketCastsApiTests/1.0`), not the watch's. Worth
  remembering if a test ever disagrees with hardware.
- **`status: 1` (unplayed) is never sent.** The app has no path that sends it, so it is not
  covered.
- **An array that is empty today records as `[]` and asserts nothing about its contents.**
  `episodeSync`, `alternateEnclosures` and `bookmarks` are all empty on this account, so their
  entries are unrecorded. The diff reports `FILLED` if one ever populates, which is the signal
  to look.
- **`/user/podcast/episodes` is read but not covered.** It is called only to print what the
  server actually holds into a failing A/B message, and nothing asserts against it — the watch
  does not use it, so a wrong guess about its shape must not be able to fail a test about an
  endpoint the watch does use.
- Archived-episode filtering and `/mobile/podcast/full/` are not covered either — the app does
  not call them. See CLAUDE.md on why archived episodes are
  deliberately not filtered.
