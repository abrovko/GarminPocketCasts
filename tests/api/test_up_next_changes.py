"""Can the watch take an episode OFF Up Next? --mutating only.

This is the last unknown blocking the third part of the Up Next fix. The watch
already stops re-downloading a finished episode (Catalog.pruneFinished and the
finished guard), but nothing removes it from the queue, so on a watch that
never sees a phone the queue only grows - and the local guard is capped at
Catalog.MAX_FINISHED = 100, so past that the re-download loop comes back.

Removing needs an entry in `/up_next/sync`'s `changes` array. That array is
the single most dangerous thing this suite can touch: the same field ADDs and
REPLACEs, so a wrong shape does not fail cleanly, it rearranges a real queue.
Hence a test before a line of Monkey C.

THE SHAPE IS NOT GUESSED. It is the official Android client's, from
UpNextSyncRequest.Change and UpNextChange's companion object:

    Change  = {action: Int, modified: Long, uuid: String?, title: String?,
               url: String?, published: String?, podcast: String?,
               episodes: List<ChangeEpisode>?}
    actions = PLAY_NOW 1, PLAY_NEXT 2, PLAY_LAST 3, REMOVE 4, REPLACE 5

What was NOT known was whether the web-player scope honours it. **It does** -
measured 2026-08-29, first shape tried, HTTP 200 and only the target moved:

    {"action": 4, "modified": <ms>, "uuid": "<episode>"}
    with upNext.serverModified taken from a prior pull

PLAY_LAST put it back, also 200, but APPENDED - so an add is possible and a
position is not. Remove is the lossless direction.

`serverModified: 0` also works - measured separately as shape 1 - so the watch
never has to carry that value at all, which matters because it does not fit a
32-bit Lang.Number (1788029412692) and arrives as a String.

**`modified: 0` works too** - shape 4, measured the same day, and it is the
last thing the watch needed. Epoch milliseconds is ~1.788e12 and Monkey C's
Number is 32-bit, so a real timestamp would have meant Lang.Long plus an
unmeasured question about whether makeWebRequest encodes one. With 0 the whole
body fits in 32-bit values:

    changes:        [{"action": 4, "modified": 0, "uuid": "<episode>"}]
    serverModified: 0

Shapes 5 and 6 (absent `modified`, and seconds) were therefore never run -
they would only map the server's tolerance further, and seconds is strictly
worse than 0 anyway: at a 1000x scale error it reads as 1970, so it buys the
same "very old change" semantics with a units bug attached.

A default run stops at the first shape that works, so it never reaches the
later ones; PC_TEST_UPNEXT_SHAPE=<n> runs exactly one, which is how they get
asked.

WHAT THIS DOES TO THE ACCOUNT
-----------------------------
It removes one named episode from Up Next, then tries to put it back with
PLAY_LAST. Both halves are reported honestly, and the queue is printed in full
BEFORE anything is sent so it can be rebuilt by hand whichever way it goes.

Three rails, and the middle one is the one that matters:

- **The target is opt-in.** PC_TEST_UPNEXT_REMOVE_UUID must name it. Nothing
  is auto-picked, unlike test_up_next_removal.py - that one marks an episode
  played, which is reversible, where this deletes a queue entry.
- **Any collateral change aborts the whole probe immediately.** After every
  attempt the queue is compared entry by entry. If anything moved that was not
  the target, no further shape is tried: the first sign that a guess reaches
  further than intended is the last thing this does.
- **A restore is attempted, not assumed.** PLAY_LAST re-adds at the END of the
  queue, so an episode removed from position 1 of 5 comes back at 5. That is
  reported rather than papered over.
"""

import json
import os
import time

import pytest

from conftest import not_covered

pytestmark = pytest.mark.mutating

# The whole enum, though only REMOVE and PLAY_LAST are ever sent. Naming all
# five is what stops a future reader assuming 4 is the only interesting value -
# REPLACE in particular rewrites the queue wholesale and is the one that would
# do real damage if it were reached by accident.
PLAY_NOW, PLAY_NEXT, PLAY_LAST, REMOVE, REPLACE = 1, 2, 3, 4, 5


def pull(api):
    """A fresh read: the ordered queue, the raw entries, and serverModified."""
    response = api.up_next()
    if response.status_code != 200:
        pytest.fail("/up_next/sync returned " + str(response.status_code)
                    + " on a plain read - nothing else here can be trusted", pytrace=False)
    body = response.json()
    entries = [e for e in (body.get("episodes") or []) if isinstance(e, dict)]
    return [e.get("uuid") for e in entries], entries, body.get("serverModified")


def describe_queue(entries):
    lines = []
    for index, entry in enumerate(entries):
        lines.append("  %2d. %-38s %s" % (
            index + 1,
            entry.get("uuid") or "(no uuid)",
            (entry.get("title") or "(untitled)")[:56],
        ))
    return "\n".join(lines) if lines else "  (empty)"


@pytest.fixture
def remove_target(api, say):
    """The episode to remove, named explicitly, with the queue snapshotted."""
    wanted = os.environ.get("PC_TEST_UPNEXT_REMOVE_UUID")
    if not wanted:
        pytest.skip("PC_TEST_UPNEXT_REMOVE_UUID is not set. This test DELETES a queue entry "
                    "and can only put it back at the end of the queue, so it will not pick "
                    "one for you - name an episode you are happy to re-queue by hand.")

    uuids, entries, server_modified = pull(api)
    if wanted not in uuids:
        pytest.skip("PC_TEST_UPNEXT_REMOVE_UUID is not in Up Next right now")

    entry = entries[uuids.index(wanted)]
    say("")
    say("up_next: the queue BEFORE anything is sent - write this down, it is what a "
        "damaged queue has to be rebuilt against:")
    say(describe_queue(entries))
    say("up_next: removing " + wanted[:8] + " (position " + str(uuids.index(wanted) + 1)
        + " of " + str(len(uuids)) + "), serverModified=" + str(server_modified))
    say("")
    return wanted, entry, uuids, server_modified


def attempt(api, say, label, changes, server_modified, before, target):
    """Send one candidate shape and say exactly what it did to the queue.

    Returns "removed", "nothing", or raises on collateral damage. The caller
    stops at the first of the first two; the third stops everything.
    """
    response = api.up_next_sync(changes, server_modified=server_modified)
    say("up_next: [" + label + "] HTTP " + str(response.status_code))

    after, _, _ = pull(api)
    if after == before:
        return "nothing"

    expected = [u for u in before if u != target]
    if after == expected:
        return "removed"

    # Anything else is the case this whole test is built to catch early.
    pytest.fail(
        "[" + label + "] changed the queue in a way that was NOT the requested removal.\n"
        "  before: " + str(before) + "\n"
        "  after:  " + str(after) + "\n"
        "  wanted: " + str(expected) + "\n\n"
        "STOPPING. No further shape is tried - a change entry that reaches further than "
        "asked is exactly the risk this test exists to find, and guessing again now would "
        "compound it. Rebuild the queue from the listing printed above.",
        pytrace=False,
    )


def test_an_explicit_change_removes_an_episode_from_up_next(api, remove_target, say):
    """REMOVE, tried in the order most-likely-correct first.

    A pass here is what unblocks the watch-side change. A clean "nothing
    happened" across every shape is also a result: it would mean the web-player
    scope does not accept queue writes, and the app's only option is the local
    guard it already has.
    """
    target, entry, before, server_modified = remove_target

    now = int(time.time() * 1000)

    # serverModified is the axis that decides the WATCH implementation, not
    # just whether this works. The value that succeeded first time was
    # 1788029412692, which does not fit a 32-bit Lang.Number, and the response
    # delivers it as a String. So shapes 1 and 2 are worth far more than shape
    # 0: either would let the watch avoid 64-bit arithmetic entirely.
    #
    # The default run stops at the first success, which answers "is this
    # possible". PC_TEST_UPNEXT_SHAPE=<n> runs exactly one, which is how the
    # cheaper shapes get asked on their own - a success at 0 says nothing at
    # all about 1 or 2.
    candidates = [
        ("0: action=4 uuid, serverModified from the pull",
         [{"action": REMOVE, "modified": now, "uuid": target}], server_modified),
        ("1: action=4 uuid, serverModified=0",
         [{"action": REMOVE, "modified": now, "uuid": target}], 0),
        ("2: action=4 uuid, serverModified as the STRING the pull returned",
         [{"action": REMOVE, "modified": now, "uuid": target}], str(server_modified)),
        ("3: action=4 with the full episode entry",
         [{"action": REMOVE, "modified": now, "uuid": target,
           "title": entry.get("title"), "url": entry.get("url"),
           "podcast": entry.get("podcast"), "published": entry.get("published")}],
         server_modified),
        # `modified` is the SAME 32-bit problem as serverModified, one field
        # over, and it was missed the first time round: epoch milliseconds is
        # ~1.788e12 and Monkey C's Lang.Number is 32-bit. Time.now().value()
        # gives SECONDS, which fits until 2038, so these two ask whether the
        # server minds - a pass on either makes the whole request body
        # expressible without a single 64-bit value.
        ("4: action=4 uuid, serverModified=0, modified=0",
         [{"action": REMOVE, "modified": 0, "uuid": target}], 0),
        ("5: action=4 uuid, serverModified=0, no modified field at all",
         [{"action": REMOVE, "uuid": target}], 0),
        ("6: action=4 uuid, serverModified=0, modified in SECONDS",
         [{"action": REMOVE, "modified": now // 1000, "uuid": target}], 0),
    ]

    only = os.environ.get("PC_TEST_UPNEXT_SHAPE")
    if only is not None:
        index = int(only)
        if index < 0 or index >= len(candidates):
            pytest.skip("PC_TEST_UPNEXT_SHAPE=" + only + " is not one of 0.."
                        + str(len(candidates) - 1))
        candidates = [candidates[index]]
        say("up_next: PC_TEST_UPNEXT_SHAPE=" + only + " - trying only that shape")

    outcome = None
    used = None
    used_changes = None
    used_server_modified = None
    for label, changes, sm in candidates:
        outcome = attempt(api, say, label, changes, sm, before, target)
        if outcome == "removed":
            used, used_changes, used_server_modified = label, changes, sm
            break
        say("up_next: [" + label + "] left the queue untouched")

    if outcome != "removed":
        not_covered(
            "no REMOVE shape moved the queue. Either the web-player scope refuses queue "
            "writes, or the shape has moved on from the Android client's "
            "UpNextSyncRequest.Change. The watch cannot then empty Up Next at all, and "
            "Catalog's finished guard - capped at MAX_FINISHED - is the only protection "
            "there is. Nothing was damaged: every attempt left the queue identical."
        )

    say("")
    # The ACTUAL body, not a hardcoded example of one. It printed
    # "modified: <ms>" for every shape until shape 4 passed with modified=0 and
    # the verdict said the opposite of what had been sent.
    say("VERDICT: Up Next accepts an explicit REMOVE. The shape that worked:")
    say("  " + used)
    say("  changes:        " + json.dumps(used_changes))
    say("  serverModified: " + json.dumps(used_server_modified))
    say("")

    # --- put it back, and be honest about how well ---
    say("up_next: attempting to re-queue it with PLAY_LAST")
    response = api.up_next_sync(
        [{"action": PLAY_LAST, "modified": now + 1, "uuid": target,
          "title": entry.get("title"), "url": entry.get("url"),
          "podcast": entry.get("podcast"), "published": entry.get("published")}],
        server_modified=server_modified,
    )
    say("up_next: [PLAY_LAST] HTTP " + str(response.status_code))

    restored, entries, _ = pull(api)
    if target not in restored:
        say("up_next: THE RESTORE DID NOT WORK. " + target + " is off the queue and this "
            "suite cannot put it back - re-add it in the Pocket Casts app.")
    elif restored == before:
        say("up_next: the queue reads the same as before - but only because it was the "
            "LAST entry, and PLAY_LAST appends. This is not evidence that position "
            "survives; the first run of this test removed position 1 of 2 and got it "
            "back at 2.")
    else:
        say("up_next: restored, but at position " + str(restored.index(target) + 1)
            + " of " + str(len(restored)) + " rather than "
            + str(before.index(target) + 1) + " - PLAY_LAST appends. The queue is now:")
        say(describe_queue(entries))
