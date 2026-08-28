"""POST /user/in_progress - {} -> {episodes: [{uuid, playedUpTo, duration, playingStatus}]}.

This is where positions made on other devices come from, and where the
durations behind the hub's "23m left" come from. The load-bearing assumption
is the one in the name: it reports episodes the server considers PLAYING, not
every episode with a playedUpTo. That distinction is the whole of the
status-is-not-optional bug, and test_update_episode.py is the other half of
it.
"""

from conftest import not_covered


def test_response_shape(in_progress_body, shape):
    assert isinstance(in_progress_body.get("episodes"), list), (
        "no episodes array; onInProgress() logs the keys and merges nothing"
    )
    shape("user_in_progress", in_progress_body)


def test_entries_carry_position_and_duration(in_progress_body):
    episodes = in_progress_body.get("episodes") or []
    if not episodes:
        not_covered("nothing is in progress on the account, so entry fields went unchecked")

    for entry in episodes:
        assert isinstance(entry.get("uuid"), str) and entry["uuid"], (
            "an in_progress entry has no uuid: " + str(sorted(entry.keys()))
        )
        assert isinstance(entry.get("playedUpTo"), (int, float)), (
            "an in_progress entry has no numeric playedUpTo - resume positions come from "
            "nowhere else: " + str(sorted(entry.keys()))
        )

    with_duration = sum(1 for e in episodes if isinstance(e.get("duration"), (int, float)))
    assert with_duration, (
        "no in_progress entry carries a duration. This is the only endpoint that gives one "
        "away for the episodes that need it, so the hub's remaining-time would go blank."
    )
    print("in_progress: " + str(with_duration) + " of " + str(len(episodes))
          + " entries carry a duration")


def test_the_response_is_the_whole_list_and_not_a_page(in_progress_body):
    """`total` must match what came back, or the watch is merging a page.

    onInProgress() walks the episodes array and merges what it recognises.
    Nothing in it pages, and there is no obvious way to ask for a second page
    even if it did - so any episode the server holds beyond this response is
    one whose position can never reach the watch, silently and forever.

    This is the read-only half of a question --mutating raised: a position
    written with status 2 was stored correctly and never appeared here, with
    the response holding exactly 20 entries. If `total` exceeds what came
    back, that is the explanation and it is not about that episode at all.
    """
    episodes = in_progress_body.get("episodes") or []
    total = in_progress_body.get("total")

    if not isinstance(total, (int, float)) or isinstance(total, bool):
        not_covered("in_progress carries no numeric `total`, so whether the response is the "
                    "whole list went unchecked")

    print("in_progress: " + str(len(episodes)) + " episodes returned, total=" + str(total))

    assert total == len(episodes), (
        "/user/in_progress reports total=" + str(total) + " but returned "
        + str(len(episodes)) + " episodes, so it is a PAGE and not the whole list. "
        "onInProgress() has no notion of a second page: every in-progress episode beyond "
        "this response is one whose position can never reach the watch. It also explains a "
        "pushed position that stores correctly and is never reported back."
    )


def test_everything_returned_is_playing_status_2(in_progress_body):
    """Every entry ever seen has carried playingStatus 2.

    If that stops being true, the endpoint has widened and the position-only
    write that /sync/update_episode accepts might become visible after all.
    """
    episodes = in_progress_body.get("episodes") or []
    if not episodes:
        not_covered("nothing is in progress on the account, so playingStatus went unchecked")

    other = sorted({e.get("playingStatus") for e in episodes if e.get("playingStatus") != 2})
    assert not other, (
        "in_progress now returns playingStatus " + str(other) + " as well as 2. It has always "
        "been 'episodes the server considers playing'; that may no longer hold."
    )
