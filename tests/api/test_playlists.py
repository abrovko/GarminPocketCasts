"""POST /user/playlist/list - {"m": <model>, "v": 1} -> {playlists: [...]}.

Three assumptions carry the sync menu, and all three are here:

- deleted playlists are still returned, so `isDeleted` has to be filtered
- smart playlists carry rules and no episodes, so they are unusable offline
- `manual` is the ONLY field that separates the two, because a manual
  playlist carries every smart-filter field as well, populated with defaults
"""

from conftest import not_covered

# The playlist list is parsed WHOLE on a 512 KB device, and that parse - not
# MAX_EPISODES - is the real exposure. Overshooting surfaces as
# NETWORK_RESPONSE_TOO_LARGE (-403), reported on the watch as "List too big".
# The ceiling is a quarter of the device's entire memory: nowhere near a
# guarantee, but a size past it is a problem waiting for a busier account.
SIZE_CEILING = 128 * 1024


def manual_playlists(body):
    return [p for p in (body.get("playlists") or [])
            if isinstance(p, dict) and p.get("manual") and not p.get("isDeleted")]


def smart_playlists(body):
    return [p for p in (body.get("playlists") or [])
            if isinstance(p, dict) and not p.get("manual")]


def test_response_shape(playlists_body, shape):
    assert isinstance(playlists_body.get("playlists"), list)
    shape("user_playlist_list", playlists_body)


def test_every_playlist_declares_manual_and_isdeleted(playlists_body):
    playlists = playlists_body.get("playlists") or []
    if not playlists:
        not_covered("the account has no playlists at all")

    for playlist in playlists:
        assert "manual" in playlist, (
            "a playlist has no `manual` field - it is the only thing separating a usable "
            "playlist from a smart one: " + str(sorted(playlist.keys()))
        )
        assert "isDeleted" in playlist, (
            "a playlist has no `isDeleted` field - deleted playlists would be offered for sync"
        )


def test_manual_playlists_carry_their_episodes_inline(playlists_body):
    playlists = manual_playlists(playlists_body)
    if not playlists:
        not_covered("the account has no live manual playlist, so inline episodes went unchecked")

    for playlist in playlists:
        assert isinstance(playlist.get("episodes"), list), (
            "manual playlist '" + str(playlist.get("title")) + "' carries no episodes array; "
            "the watch has no way to resolve one"
        )
        assert isinstance(playlist.get("episodeOrder"), list), (
            "manual playlist '" + str(playlist.get("title")) + "' carries no episodeOrder"
        )


def test_playlist_episodes_carry_a_url_and_no_file_type(playlists_body):
    """encodingForUrl() sniffs the extension because there is no fileType here.

    If one ever appears, the sniffing can go - and this test is how you find
    out. If the url disappears, the whole no-resolution-per-episode design
    goes with it.
    """
    entries = [e for p in manual_playlists(playlists_body) for e in (p.get("episodes") or [])]
    if not entries:
        not_covered("no episodes in any manual playlist, so their entry fields went unchecked")

    for entry in entries:
        assert isinstance(entry.get("url"), str) and entry["url"], (
            "a playlist episode has no url; every episode would need a findbyepisode call: "
            + str(sorted(entry.keys()))
        )
        for field in ("episode", "podcast"):
            assert isinstance(entry.get(field), str) and entry[field], (
                "a playlist episode has no " + field + ": " + str(sorted(entry.keys()))
            )

    carries_type = [e for e in entries if e.get("fileType") or e.get("file_type")]
    assert not carries_type, (
        "playlist episodes now carry a file type - encodingForUrl()'s url sniffing could "
        "read it instead"
    )


def test_episodes_arrive_in_the_order_episode_order_names(playlists_body):
    """The watch takes the `episodes` array order as given, and never reads
    `episodeOrder`.

    That order is load-bearing twice over: it is what the sync menu shows, and
    what resequenceDownloads() re-lays `downloaded` against, so it decides
    both what plays first and what downloads first. If the server ever served
    the array in some other order - insertion, published date, uuid - nothing
    on the watch would notice and the queue would quietly play out of order.

    Checking it here is the only way to find out, because `episodeOrder` is
    the server's own statement of the intended order and the watch throws it
    away.
    """
    checked = 0
    for playlist in manual_playlists(playlists_body):
        order = playlist.get("episodeOrder")
        episodes = playlist.get("episodes")
        if not isinstance(order, list) or not order or not isinstance(episodes, list):
            continue
        checked += 1
        assert [e.get("episode") for e in episodes] == order, (
            "playlist " + str(playlist.get("title")) + " serves its episodes in a different "
            "order from its own episodeOrder. The watch reads the array and ignores "
            "episodeOrder, so its queue order and download priority are both wrong."
        )

    if not checked:
        not_covered("no manual playlist carries both episodes and episodeOrder, so the "
                    "array's order went unchecked")
    print("playlists: episode order matches episodeOrder in " + str(checked) + " playlist(s)")


def test_the_response_stays_parseable_on_the_watch(playlists_body, api):
    """512 KB total memory, and this response is parsed whole before we see it."""
    size = len(api.playlists().content)
    print("playlists: " + str(size) + " bytes for "
          + str(len(playlists_body.get("playlists") or [])) + " playlist(s)")
    assert size < SIZE_CEILING, (
        "/user/playlist/list now returns " + str(size) + " bytes. The watch parses it whole "
        "on a 512 KB device; past this it surfaces as NETWORK_RESPONSE_TOO_LARGE and the "
        "refresh reports 'List too big'. The fix is a smaller endpoint, not a bigger cap."
    )


def test_a_manual_playlist_still_carries_the_smart_filter_fields(playlists_body):
    """The one that makes `manual` load-bearing.

    A manual playlist arrives with `unplayed`, `longerThan`, `allPodcasts` and
    the rest populated with defaults. Anything that tried to spot a smart
    playlist by the presence of its rules would classify every playlist as
    smart.
    """
    playlists = manual_playlists(playlists_body)
    if not playlists:
        not_covered("the account has no live manual playlist, so the rule-field overlap "
                    "went unchecked")

    rule_fields = ("unplayed", "starred", "allPodcasts", "podcastUuids")
    for playlist in playlists:
        overlap = [f for f in rule_fields if f in playlist]
        assert overlap, (
            "manual playlist '" + str(playlist.get("title")) + "' no longer carries any smart "
            "filter fields. That would make the rules a valid discriminator - worth knowing, "
            "but it contradicts what the sync menu is written against."
        )


def test_smart_playlists_carry_no_episodes(playlists_body):
    playlists = smart_playlists(playlists_body)
    if not playlists:
        not_covered("the account has no smart playlist, so their emptiness went unchecked")

    for playlist in playlists:
        assert not playlist.get("episodes"), (
            "smart playlist '" + str(playlist.get("title")) + "' now carries episodes inline. "
            "They are skipped entirely today; if the server evaluates the rules now, they "
            "could be offered."
        )


def test_deleted_playlists_are_still_returned(playlists_body):
    """Not a requirement either - a check that the filter still earns its place."""
    deleted = [p for p in (playlists_body.get("playlists") or []) if p.get("isDeleted")]
    if not deleted:
        not_covered("the account has no deleted playlist, so the isDeleted filter was not "
                    "exercised (it may still be needed)")
    print("playlist/list: " + str(len(deleted)) + " deleted playlist(s) returned and filtered out")
