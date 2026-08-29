"""POST /sync/update_episode - the only call that WRITES. --mutating only.

This is the A/B that cost a day of listening, run as a test:

    {uuid, podcast, position}             -> 200, position stored,
                                             playingStatus UNCHANGED
    {uuid, podcast, position, status: 2}  -> 200, position stored,
                                             playingStatus 2

Both answer the same 200 carrying `{}` - measured 2026-08-27, and NOT a
zero-length body as this file first assumed - so nothing on the watch can tell
them apart. Which is exactly why it has to be checked from here, against a
live account, by reading the result back out of a different endpoint.

THE PUSH AND THE PULL ARE TWO TESTS, because they are two claims and they can
fail independently. Running them as one made a confirmed push read as a broken
one.

- The A/B is checked against /user/podcast/episodes - the episode record,
  i.e. what the API actually STORED. That is the push half, and it is what
  every position the watch banks depends on.
- The round trip is checked against /user/in_progress - a filtered VIEW of
  that record, and the only place the refresh reads positions back from. That
  is the pull half.

/user/podcast/episodes is not an endpoint the watch calls, so it is read
defensively: episode_record() returns None for every way of not getting an
answer, and a test that cannot read it reports itself as not covered rather
than failing. An assumption about a call the watch never makes must not be
able to fail a test about one it makes constantly.

WHAT THIS DOES TO THE ACCOUNT: it moves PC_TEST_EPISODE_UUID's playback
position twice and marks it played once, then puts it back.

The state it STARTS from matters as much as the one it leaves, because
"/user/in_progress does not report it" covers two different episodes: one
never started, and one already finished. They do not behave the same, and an
earlier aborted run leaves exactly the second kind behind - which is how a
run once poisoned the next one. So an episode that is unreported is explicitly
reset to unplayed before the A/B, not assumed to be fresh.

Reading the record rather than the view also means the A/B no longer needs a
never-started episode: it compares playingStatus against whatever the episode
came in as, so one already in progress works too. Only the round-trip test
still cares what it is pointed at.

The restore has two cases. An episode that WAS in progress goes back to its
position with status 2, exactly as found. An episode that was NOT is reset
with status 1 (unplayed) at position 0 - the closest thing to "never started"
the API offers, and the one call in this suite the watch itself never makes.
Both are verified rather than trusted, and the teardown only claims a clean
restore when it actually observed one.
"""

import os
import time

import pytest

from conftest import not_covered

pytestmark = pytest.mark.mutating

UNPLAYED, PLAYING, PLAYED = 1, 2, 3

# Distinctive, and far enough apart that neither could be mistaken for the
# other or for a real listening position landing mid-test.
PROBE_WITHOUT_STATUS = 4321
PROBE_WITH_STATUS = 1234

SETTLE_SECONDS = 20

# The round trip gets longer: in_progress is a derived view of the episode
# record rather than the record itself, and nothing says it is updated
# synchronously with the write. Overridable, because how long that view takes
# to catch up is the open question rather than something already known - raise
# it to test the lag theory without editing this file.
ROUND_TRIP_SECONDS = int(os.environ.get("PC_ROUND_TRIP_SECONDS") or 60)

# How often the wait says it is still waiting. A test that sits silent for a
# minute is indistinguishable from a hung one, and this one waits on purpose.
TICK_SECONDS = 10


def reported_position(api, uuid):
    """What /user/in_progress says about this episode, or None if it is silent."""
    body = api.in_progress().json()
    for entry in body.get("episodes") or []:
        if entry.get("uuid") == uuid:
            return entry.get("playedUpTo")
    return None


def episode_record(api, podcast, uuid):
    """The episode as /user/podcast/episodes holds it, or None if it cannot say.

    None covers every way of not getting an answer, so a caller can report the
    endpoint as unavailable rather than the assumption as broken. The watch
    never calls this, so a change to it must not be able to fail a test about
    an endpoint the watch does call.
    """
    try:
        response = api.podcast_episodes(podcast)
        if response.status_code != 200:
            return None
        for entry in response.json().get("episodes") or []:
            if isinstance(entry, dict) and entry.get("uuid") == uuid:
                return entry
    except Exception:  # noqa: BLE001 - a diagnostic must not raise
        return None
    return None


def server_state(api, podcast, uuid):
    """What /user/podcast/episodes holds, as a sentence for a log line."""
    entry = episode_record(api, podcast, uuid)
    if entry is None:
        return "/user/podcast/episodes does not list this episode, or could not be read"
    return ("/user/podcast/episodes holds playedUpTo=" + str(entry.get("playedUpTo"))
            + " playingStatus=" + str(entry.get("playingStatus")))


def in_progress_state(api, podcast, uuid):
    """Why /user/in_progress is silent about this episode, as far as it can say.

    Three different answers hide behind one absence, and they have different
    consequences:

    - the response is a PAGE (total exceeds what came back), so the episode
      may simply be outside the window and nothing is wrong with the write;
    - the podcast never appears there at all, so the view is filtered on
      something beyond having a position and this episode is unrepresentative;
    - the podcast is represented and this episode is not, which is the only
      one of the three that says the endpoint itself has changed.
    """
    try:
        body = api.in_progress().json()
    except Exception:  # noqa: BLE001
        return {"error": "/user/in_progress could not be read"}
    entries = [e for e in (body.get("episodes") or []) if isinstance(e, dict)]
    here = [e for e in entries if e.get("podcastUuid") == podcast]
    mine = [e for e in here if e.get("uuid") == uuid]
    total = body.get("total")
    return {
        "error": None,
        "count": len(entries),
        "total": total if isinstance(total, (int, float)) and not isinstance(total, bool) else None,
        "from_this_podcast": len(here),
        "entry": mine[0] if mine else None,
    }


def describe_in_progress(state):
    if state.get("error"):
        return state["error"]
    entry = state.get("entry")
    if entry is not None:
        return ("/user/in_progress lists it at playedUpTo=" + str(entry.get("playedUpTo"))
                + " playingStatus=" + str(entry.get("playingStatus")))
    total = state.get("total")
    return ("/user/in_progress returned " + str(state["count"]) + " episodes"
            + ("" if total is None else " of total=" + str(total)) + ", "
            + (str(state["from_this_podcast"]) + " of them from this podcast, none of them this "
               "one" if state["from_this_podcast"] else "none of them from this podcast at all"))


def wait_until(fn, want, seconds=SETTLE_SECONDS, tick=None):
    """Poll for an expected value - the write is not always visible instantly.

    `tick` is called with the elapsed seconds every TICK_SECONDS, so a long
    wait can say so while it happens rather than looking like a hang.
    """
    started = time.time()
    deadline = started + seconds
    said = 0
    value = fn()
    while value != want and time.time() < deadline:
        time.sleep(2)
        elapsed = int(time.time() - started)
        if tick is not None and elapsed - said >= TICK_SECONDS:
            said = elapsed
            tick(elapsed)
        value = fn()
    return value


def assert_body_is_empty(response, what):
    """The success body is `{}`, not nothing.

    Worth asserting rather than ignoring: onPushed() reads only the status
    code, so the day this starts carrying an error object saying the write was
    rejected, the watch would go on believing every push succeeded. The check
    is "carries no information", not "is zero bytes" - that stricter reading
    was wrong and is what this test first failed on.
    """
    text = response.text.strip()
    if not text:
        return
    try:
        body = response.json()
    except ValueError:
        pytest.fail(what + " returned a non-JSON body: " + text[:200], pytrace=False)
    assert not body, (
        what + " now returns a body with content: " + text[:200]
        + " - onPushed() reads only the status code and would ignore whatever it says"
    )


# `say` lives in conftest.py - test_up_next_removal.py waits on purpose too.


@pytest.fixture
def restored(api, test_episode):
    """Put the episode into a known state, and put it back however the test ends."""
    podcast, uuid = test_episode
    original = reported_position(api, uuid)

    if original is not None:
        print("update_episode: " + uuid[:8] + " starts in progress at " + str(original))
    else:
        # Unreported means never started OR already finished, and those are
        # different episodes as far as this endpoint is concerned. Normalise,
        # so an earlier run that ended mid-test cannot decide this one.
        print("update_episode: " + uuid[:8] + " is not reported by in_progress - "
              + server_state(api, podcast, uuid))
        api.update_episode(uuid, podcast, position=0, status=UNPLAYED)
        print("update_episode: reset to unplayed before the A/B - "
              + server_state(api, podcast, uuid))

    try:
        yield podcast, uuid, original
    finally:
        if original is not None:
            api.update_episode(uuid, podcast, position=original, status=PLAYING)
            back = wait_until(lambda: reported_position(api, uuid), original)
            if back == original:
                print("update_episode: restored to " + str(original))
            else:
                print("update_episode: RESTORE DID NOT TAKE - in_progress reports "
                      + str(back) + ", not " + str(original) + ". Set it back in the "
                      "Pocket Casts app.")
        else:
            api.update_episode(uuid, podcast, position=0, status=UNPLAYED)
            left = wait_until(lambda: reported_position(api, uuid), None, seconds=10)
            # Reading None back proves nothing on its own - it was None to
            # begin with. The episode record is what says whether the reset
            # actually landed.
            if left is None:
                print("update_episode: reset to unplayed - " + server_state(api, podcast, uuid))
            else:
                print("update_episode: RESET DID NOT TAKE - in_progress still reports it at "
                      + str(left) + ". Mark it unplayed in the Pocket Casts app.")


def test_status_is_what_makes_a_position_stick(api, restored):
    """The A/B itself: what each body does to the episode on the server.

    This is the claim the watch's push path rests on, and it is checked
    against the episode record rather than /user/in_progress - the record is
    what the API actually stored, where in_progress is a filtered view of it
    and answers a different question (the one the test below asks).

    Reproduces the table in CLAUDE.md:

        {uuid, podcast, position}            -> playedUpTo set, status UNCHANGED
        {uuid, podcast, position, status: 2}  -> playedUpTo set, status 2
    """
    podcast, uuid, _original = restored

    before = episode_record(api, podcast, uuid)
    if before is None:
        not_covered("/user/podcast/episodes did not answer, so what each update_episode body "
                    "records could not be read back")
    was_status = before.get("playingStatus")

    # --- A: position alone ---
    response = api.update_episode(uuid, podcast, position=PROBE_WITHOUT_STATUS)
    assert response.status_code == 200, (
        "a position-only update now returns " + str(response.status_code) + ", not 200"
    )
    assert_body_is_empty(response, "a position-only update")

    after_a = episode_record(api, podcast, uuid) or {}
    print("update_episode: after position-only, " + server_state(api, podcast, uuid))

    assert after_a.get("playedUpTo") == PROBE_WITHOUT_STATUS, (
        "a position-only update no longer records the position at all (playedUpTo="
        + str(after_a.get("playedUpTo")) + "). The watch always sends a status too, so it is "
        "unaffected - but the reason the status is needed has changed."
    )
    assert after_a.get("playingStatus") == was_status, (
        "a position-only update now moves playingStatus by itself (" + str(was_status) + " -> "
        + str(after_a.get("playingStatus")) + "). This is the whole reason the watch sends "
        "status explicitly; if the server now infers it, that requirement has relaxed."
    )

    # --- B: position and status ---
    response = api.update_episode(uuid, podcast, position=PROBE_WITH_STATUS, status=PLAYING)
    assert response.status_code == 200
    assert_body_is_empty(response, "a position sent with status=2")

    after_b = episode_record(api, podcast, uuid) or {}
    print("update_episode: after position with status=2, " + server_state(api, podcast, uuid))

    assert after_b.get("playedUpTo") == PROBE_WITH_STATUS, (
        "a position sent with status=2 was not recorded (playedUpTo="
        + str(after_b.get("playedUpTo")) + "). This is exactly the call the watch makes for "
        "every position it banks; if it stops recording, nothing listened to on the watch "
        "reaches the account."
    )
    assert after_b.get("playingStatus") == PLAYING, (
        "status=2 no longer sets playingStatus (it is " + str(after_b.get("playingStatus"))
        + "). That is what puts the episode into /user/in_progress, which is the only way a "
        "position gets back to the watch."
    )


def test_a_pushed_position_comes_back_from_in_progress(api, restored, say):
    """The round trip: /user/in_progress is where the watch reads positions back.

    Separate from the A/B above deliberately. That one is about what the
    server STORES and is the push half; this is about what it will REPORT,
    and it is the pull half - the refresh merges positions from here and
    nowhere else. They can fail independently, and conflating them made a
    confirmed push look like a broken one.

    Given a generous window because in_progress is a derived view rather than
    the record itself, and nothing says it updates synchronously.
    """
    podcast, uuid, _original = restored

    response = api.update_episode(uuid, podcast, position=PROBE_WITH_STATUS, status=PLAYING)
    assert response.status_code == 200

    stored = (episode_record(api, podcast, uuid) or {}).get("playedUpTo")
    say("update_episode: waiting up to " + str(ROUND_TRIP_SECONDS)
        + "s for /user/in_progress to report the position (PC_ROUND_TRIP_SECONDS to change)")

    seen = wait_until(
        lambda: reported_position(api, uuid), PROBE_WITH_STATUS,
        seconds=ROUND_TRIP_SECONDS,
        tick=lambda elapsed: say("update_episode: still not reported after "
                                 + str(elapsed) + "s of " + str(ROUND_TRIP_SECONDS) + "s"),
    )
    if seen == PROBE_WITH_STATUS:
        say("update_episode: /user/in_progress reported it")
        return

    state = in_progress_state(api, podcast, uuid)
    detail = ("  the episode record says: " + server_state(api, podcast, uuid) + "\n"
              "  " + describe_in_progress(state))

    if stored != PROBE_WITH_STATUS:
        pytest.fail(
            "the position was not stored, so there was nothing for /user/in_progress to "
            "report. The push itself is what broke - see the A/B test above.\n" + detail,
            pytrace=False,
        )

    consequence = (
        "\n  If this really is the endpoint, the watch pushes fine and reads back nothing: "
        "positions are lost on the MERGE, not on the push. mergeServerPosition() never sees "
        "them and furthest-along-wins has only the local side to work with."
    )

    # The write is confirmed stored, so what is left is why the view does not
    # show it - and two of the three answers are about this account rather
    # than about the API. Neither is something a red test should assert.
    total = state.get("total")
    if total is not None and total > state.get("count", 0):
        not_covered(
            "/user/in_progress returned " + str(state["count"]) + " of total=" + str(total)
            + ", so it is a page and a newly written position may simply fall outside it. "
            "The round trip could not be checked - see the in_progress paging test, which "
            "is where that belongs." + consequence
        )

    if not state.get("from_this_podcast"):
        not_covered(
            "the test episode's podcast has nothing in /user/in_progress at all ("
            + str(state.get("count")) + " episodes there, none from it), so a position "
            "written against it proves nothing about the round trip: that view is filtered "
            "on something beyond having a position. Point PC_TEST_EPISODE_UUID at an episode "
            "from a podcast that already appears there - -ListEpisodes marks them."
            + consequence
        )

    pytest.fail(
        "the position was stored correctly but /user/in_progress did not report it within "
        + str(ROUND_TRIP_SECONDS) + "s (saw " + str(seen) + "), and this episode's podcast IS "
        "represented there. That is the endpoint, not the account.\n" + detail + consequence,
        pytrace=False,
    )


def test_played_is_reported_as_a_status(api, restored):
    """Finishing an episode sends status 3 and NO position.

    The stored position of a finished episode is 0, and sending that would
    tell the server the episode is back at the start - resetting it to
    unplayed everywhere else.
    """
    podcast, uuid, _original = restored

    # It does NOT also remove the episode from Up Next - that was believed here
    # and is false, measured 2026-08-29 by test_up_next_removal.py. Removing
    # from the queue needs an entry in /up_next/sync's `changes` array, which
    # is the client's job. What status=3 buys is the played flag, which is what
    # stops other devices offering the episode as unfinished.
    response = api.update_episode(uuid, podcast, status=PLAYED)
    assert response.status_code == 200, (
        "status=3 now returns " + str(response.status_code) + " - this is how the watch "
        "reports a finished episode, and its stored position of 0 must never be sent as a "
        "position instead"
    )
    assert_body_is_empty(response, "status=3")
    print("update_episode: after status=3, " + server_state(api, podcast, uuid))
