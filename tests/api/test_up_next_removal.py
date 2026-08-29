"""Does marking an episode played take it off Up Next?

The whole of the watch's auto-delete design turns on this one question, and it
has never been measured - it was assumed, and the assumption is written into
`getPendingTracks()`:

- Up Next is deliberately EXEMPT from the "already finished here" guard,
  because putting an episode back on the queue is a request to hear it again.
- The only thing that then stops a finished Up Next episode being downloaded
  again is `refIds.hasKey()` - i.e. the watch still holding its audio.
- Auto-delete drops that audio, and the ref id with it, as soon as the played
  report is confirmed.

That is airtight if and only if the server removes the episode from Up Next
shortly after `status: 3`. If it does not, the last step removes the only
guard and the episode is pending again for ever.

A fenix 8 log (`logs/2026-08-29_091757`) says it does not. Four episodes were
finished, all four reported `status=played` successfully, their audio purged -
and the next three refreshes over four minutes still found all four in Up
Next, so all four downloaded again. That is roughly 140 MB of re-download.

But a device log cannot separate "the server kept them" from "the phone put
them back", and one earlier episode in that same log DID leave the queue after
being reported played - overnight, with the phone in reach. So it is measured
here instead.

WHAT THIS DOES TO THE ACCOUNT
-----------------------------
The read-only test costs nothing: it looks for an episode already sitting in
Up Next that the server already considers played, which is proof on its own
and needs no write.

The mutating test marks a real Up Next episode played. **If the answer turns
out to be "yes, it is removed", that removal cannot be undone from here** -
putting an episode back on Up Next needs an entry in `/up_next/sync`'s
`changes` array, whose format nothing in this repo knows. The restore sets the
played status back and reports whether the queue entry returned with it; if it
did not, the test says so and names the episode to re-queue by hand. It aims
at the LAST entry in the queue for that reason. `PC_TEST_UPNEXT_UUID`
overrides the choice.
"""

import os
import time

import pytest

from conftest import not_covered

# NO module-level `mutating` mark: the first test below is read-only and is
# the one most likely to answer the question outright, so it has to run on a
# plain run. Only the experiment is marked.

UNPLAYED, PLAYING, PLAYED = 1, 2, 3

# How long to give the server to drop the episode.
#
# 90 s was the first guess and it is PROBABLY TOO SHORT. A watch run the same
# day (logs/2026-08-29_112440_fenix-8-51mm) finished an episode, reported
# status=played, and saw it leave Up Next "shortly" afterwards - gone from
# -ListEpisodes too, which is this same API and not the phone app. This test
# said the opposite at 90 s.
#
# Worse, the window and the restore compound: the fixture puts the played
# status back in its `finally`, so a cleanup on a longer cycle has its trigger
# removed before it could ever fire, and the test reports "not removed" no
# matter how long the server would actually have taken. Raise this well past
# any plausible cycle before believing a negative result - and see
# PC_UP_NEXT_NO_RESTORE below, which is what makes a long wait meaningful.
REMOVAL_SECONDS = int(os.environ.get("PC_UP_NEXT_SECONDS") or 90)

# Leave the episode marked played instead of putting it back.
#
# The restore is what makes this test safe to run casually, and it is also
# what stops it answering the question. With this set the episode stays played,
# so the server (or the phone, next time it syncs) is free to act on it in its
# own time and a later -ListEpisodes says whether it did. Deliberately opt-in:
# it leaves the account changed.
NO_RESTORE = bool(os.environ.get("PC_UP_NEXT_NO_RESTORE"))

POLL_SECONDS = 5
TICK_SECONDS = 15


def up_next_entries(api):
    """The queue as it stands right now, not the session-cached copy."""
    response = api.up_next()
    if response.status_code != 200:
        pytest.fail("/up_next/sync returned " + str(response.status_code)
                    + " while reading the queue back", pytrace=False)
    return [e for e in (response.json().get("episodes") or []) if isinstance(e, dict)]


def episode_record(api, podcast, uuid, cache=None):
    """The episode as /user/podcast/episodes holds it, or None if it cannot say.

    Deliberately a local copy of test_update_episode.py's helper rather than a
    shared one: these files check two different claims, and a shared reader
    would make a change to one silently change what the other measured. None
    covers every way of not getting an answer, so a caller reports the
    endpoint as unavailable rather than the assumption as broken.
    """
    if cache is not None and podcast in cache:
        body = cache[podcast]
    else:
        try:
            response = api.podcast_episodes(podcast)
            body = response.json() if response.status_code == 200 else None
        except Exception:  # noqa: BLE001 - a diagnostic must not raise
            body = None
        if cache is not None:
            cache[podcast] = body
    if not body:
        return None
    for entry in body.get("episodes") or []:
        if isinstance(entry, dict) and entry.get("uuid") == uuid:
            return entry
    return None


def describe(entry):
    return ("playedUpTo=" + str(entry.get("playedUpTo"))
            + " playingStatus=" + str(entry.get("playingStatus")))


# --- the free half: does the account already answer this? ---

def test_a_played_episode_can_already_be_sitting_in_up_next(api, up_next_body, say):
    """Proof without a single write, when the account happens to hold it.

    An episode the server itself considers played (`playingStatus: 3`) that is
    STILL in Up Next settles the question outright: marking played is not what
    removes it. This is the cheap check, so it runs first.

    It is not marked as a failure either way. A played episode found here is
    the answer, not a regression, and the app is what has to change.
    """
    entries = [e for e in (up_next_body.get("episodes") or []) if isinstance(e, dict)]
    if not entries:
        not_covered("Up Next is empty, so whether a played episode can sit in it went "
                    "unchecked")

    cache = {}
    readable = 0
    played = []
    for entry in entries:
        uuid, podcast = entry.get("uuid"), entry.get("podcast")
        if not uuid or not podcast:
            continue
        record = episode_record(api, podcast, uuid, cache)
        if record is None:
            continue
        readable += 1
        if record.get("playingStatus") == PLAYED:
            played.append((uuid, entry.get("title") or "", record))

    if not readable:
        not_covered("/user/podcast/episodes answered for none of the Up Next entries, so "
                    "their played status could not be read")

    say("up_next: " + str(readable) + " of " + str(len(entries))
        + " queue entries readable, " + str(len(played)) + " already marked played")

    if played:
        for uuid, title, record in played:
            say("  PLAYED AND STILL QUEUED  " + uuid[:8] + "  " + describe(record)
                + "  " + title[:48])
        say("VERDICT: status=3 does NOT remove an episode from Up Next - the account is "
            "holding " + str(len(played)) + " that prove it.")
        return

    not_covered("nothing in Up Next is marked played, so the account cannot answer whether "
                "a played episode stays queued. The mutating test below asks directly.")


# --- the experiment ---

@pytest.fixture
def up_next_subject(api, say):
    """A real queue entry to mark played, put back as far as it can be.

    The LAST entry, because if the answer is "removed" that cannot be undone
    from here and the bottom of the queue is the cheapest place to find out.
    """
    entries = up_next_entries(api)
    if not entries:
        pytest.skip("Up Next is empty - nothing to test removal against")

    wanted = os.environ.get("PC_TEST_UPNEXT_UUID")
    entry = None
    if wanted:
        for candidate in entries:
            if candidate.get("uuid") == wanted:
                entry = candidate
                break
        if entry is None:
            pytest.skip("PC_TEST_UPNEXT_UUID is not in Up Next right now")
    else:
        entry = entries[-1]

    uuid, podcast = entry.get("uuid"), entry.get("podcast")
    if not uuid or not podcast:
        pytest.skip("the chosen Up Next entry carries no uuid/podcast")

    before = episode_record(api, podcast, uuid)
    say("up_next: subject is " + uuid[:8] + " (" + str(len(entries)) + " in the queue, "
        + "position " + str(entries.index(entry) + 1) + ") - "
        + (describe(before) if before else "its episode record could not be read"))
    say("up_next: THIS MARKS A REAL QUEUE ENTRY PLAYED. If that removes it, this suite "
        "cannot put it back - re-queue it in the Pocket Casts app.")

    try:
        yield uuid, podcast, before, len(entries)
    finally:
        # An if/else rather than an early return: a `return` inside `finally`
        # discards whatever exception is in flight, and this teardown must
        # never be able to swallow a test failure.
        if NO_RESTORE:
            say("up_next: PC_UP_NEXT_NO_RESTORE set - leaving " + uuid[:8]
                + " marked played. Re-run -ListEpisodes later to see whether the queue "
                  "empties on its own; put it back in the Pocket Casts app when done.")
        else:
            restore_and_report(api, say, uuid, podcast, before)


def restore_and_report(api, say, uuid, podcast, before):
    """Put the played status back, and say whether the queue entry survived.

    Split out of the fixture so its `finally` stays a plain if/else - a
    `return` inside `finally` discards whatever exception is in flight, and a
    teardown must never be able to swallow a test failure.

    The status is the only half of the mutation that is reversible. Whether the
    queue entry came back with it is reported rather than assumed, because
    re-queuing needs an Up Next change this suite cannot compose.
    """
    if before is not None:
        status = before.get("playingStatus")
        position = before.get("playedUpTo")
        api.update_episode(
            uuid, podcast,
            position=position if isinstance(position, int) else 0,
            status=status if status in (UNPLAYED, PLAYING, PLAYED) else UNPLAYED,
        )
    else:
        api.update_episode(uuid, podcast, position=0, status=UNPLAYED)

    after = episode_record(api, podcast, uuid)
    say("up_next: restored status - " + (describe(after) if after else "record unreadable"))

    if uuid in [e.get("uuid") for e in up_next_entries(api)]:
        say("up_next: the queue entry is still there, nothing to put back")
    else:
        say("up_next: THE QUEUE ENTRY IS GONE and cannot be restored from here. "
            "Re-queue " + uuid + " in the Pocket Casts app if you want it back.")


@pytest.mark.mutating
def test_marking_played_removes_it_from_up_next(api, up_next_subject, say):
    """The claim `getPendingTracks()` is built on, asked directly.

    A red test here is not the API breaking - it is the app's assumption
    failing, and the failure message names what has to change instead.
    """
    # The record as it was found is the fixture's business, not this test's -
    # it is what the teardown restores to.
    uuid, podcast, _, queued_before = up_next_subject

    response = api.update_episode(uuid, podcast, status=PLAYED)
    assert response.status_code == 200, (
        "status=3 returned " + str(response.status_code) + " - the removal question cannot "
        "be asked until the played report itself works; see test_update_episode.py"
    )

    record = episode_record(api, podcast, uuid)
    if record is not None and record.get("playingStatus") != PLAYED:
        not_covered("status=3 answered 200 but the episode record still reads "
                    + describe(record) + ", so nothing was actually marked played and the "
                    "removal question went unasked")

    say("up_next: marked played, waiting up to " + str(REMOVAL_SECONDS)
        + "s for it to leave the queue (PC_UP_NEXT_SECONDS to change)")

    started = time.time()
    deadline = started + REMOVAL_SECONDS
    said = 0
    present = True
    while present and time.time() < deadline:
        time.sleep(POLL_SECONDS)
        present = uuid in [e.get("uuid") for e in up_next_entries(api)]
        elapsed = int(time.time() - started)
        if present and elapsed - said >= TICK_SECONDS:
            said = elapsed
            say("up_next: still queued after " + str(elapsed) + "s of "
                + str(REMOVAL_SECONDS) + "s")

    if not present:
        say("VERDICT: status=3 DID remove it from Up Next, after about "
            + str(int(time.time() - started)) + "s")
        return

    still = len(up_next_entries(api))
    pytest.fail(
        "the episode was marked played and is STILL in Up Next " + str(REMOVAL_SECONDS)
        + "s later (" + str(queued_before) + " entries before, " + str(still) + " after).\n\n"
        "READ THIS BEFORE CONCLUDING ANYTHING: a watch run has since shown an episode "
        "leaving Up Next shortly after status=played, so this window is probably too short "
        "- and the fixture is about to restore the played status, which removes the trigger. "
        "Re-run with PC_UP_NEXT_SECONDS=600 and PC_UP_NEXT_NO_RESTORE=1 before treating a "
        "failure here as the answer.\n\n"
        "VERDICT: marking an episode played does not take it off Up Next. The watch's "
        "auto-delete is built on the opposite assumption:\n"
        "  - getPendingTracks() exempts Up Next from the finished guard, on the grounds that "
        "the server drops a finished episode from the queue;\n"
        "  - the only interim guard is refIds.hasKey(), i.e. still holding the audio;\n"
        "  - auto-delete removes that audio as soon as the played report lands.\n"
        "So every episode finished from Up Next is re-downloaded for ever. Fixing it means "
        "either sending an explicit Up Next REMOVE in /up_next/sync's changes array, or "
        "keeping a watch-side guard that outlives the audio.",
        pytrace=False,
    )
