"""POST /up_next/sync - the two-way one.

This is the only endpoint the watch touches that could damage the account.
Entries in `changes` ADD, REMOVE or REORDER the real queue; the empty array
is what turns it into a read. The first test here is the one that matters -
everything else in the app assumes that empty array is inert.
"""

from conftest import not_covered

# The watch parses this response whole on a 512 KB device - see test_playlists.
SIZE_CEILING = 128 * 1024


def test_pull_leaves_the_queue_alone(api):
    """Two identical pulls, same queue.

    A change made on the phone between the two calls would show up here as a
    failure - so read a failure as "check the phone" before "the API changed".
    """
    first = api.up_next()
    assert first.status_code == 200
    second = api.up_next()
    assert second.status_code == 200

    before = [e.get("uuid") for e in (first.json().get("episodes") or [])]
    after = [e.get("uuid") for e in (second.json().get("episodes") or [])]
    assert before == after, (
        "a pull with changes:[] altered the queue - "
        "before=" + str(len(before)) + " after=" + str(len(after))
    )


def test_the_response_stays_parseable_on_the_watch(up_next_body, api):
    """512 KB total memory, and this response is parsed whole before we see it.

    Up Next is the one list a user can grow without meaning to - queue a
    season and it is fifty entries. MAX_EPISODES caps what gets STORED, which
    does nothing about the parse.
    """
    size = len(api.up_next().content)
    print("up_next: " + str(size) + " bytes for "
          + str(len(up_next_body.get("episodes") or [])) + " episode(s)")
    assert size < SIZE_CEILING, (
        "/up_next/sync now returns " + str(size) + " bytes. The watch parses it whole on a "
        "512 KB device; past this it surfaces as NETWORK_RESPONSE_TOO_LARGE and the refresh "
        "reports 'List too big'."
    )


def test_response_shape(up_next_body, shape):
    assert isinstance(up_next_body.get("episodes"), list), (
        "no episodes array; onUpNext() treats that as a failed fetch and carries the "
        "stored queue forward"
    )
    shape("up_next_sync", up_next_body)


def test_server_modified_is_a_string(up_next_body):
    """The official client's model calls this a Long. The wire says otherwise."""
    value = up_next_body.get("serverModified")
    if value is None:
        not_covered("serverModified absent from this response, so its type went unchecked")
    assert isinstance(value, str), (
        "serverModified is now " + type(value).__name__ + ", not str"
    )


def test_entries_carry_what_the_watch_reads(up_next_body):
    episodes = up_next_body.get("episodes") or []
    if not episodes:
        not_covered("Up Next is empty, so its entry fields went unchecked")

    for entry in episodes:
        for field in ("uuid", "podcast", "title", "url"):
            assert isinstance(entry.get(field), str) and entry[field], (
                "an Up Next entry has no usable " + field + ": keys=" + str(sorted(entry.keys()))
            )


def test_duration_is_still_not_dependable(up_next_body):
    """Not a requirement - a record of which way it currently falls.

    CLAUDE.md's "remaining time" section says Up Next entries only sometimes
    carry a duration, which is why it cannot be sourced from the queue alone.
    This reports what the account actually returns so that claim stays honest.
    """
    episodes = up_next_body.get("episodes") or []
    if not episodes:
        not_covered("Up Next is empty, so duration availability went unchecked")

    with_duration = sum(1 for e in episodes if isinstance(e.get("duration"), (int, float)))
    print("up_next: " + str(with_duration) + " of " + str(len(episodes)) + " entries carry a duration")
