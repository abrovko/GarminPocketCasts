r"""Prints the episode/podcast uuid pairs on the account, for --mutating.

The mutating tests need PC_TEST_EPISODE_UUID and PC_TEST_PODCAST_UUID, and
not just any episode will do: the clean A/B - the half showing that a
position-only write is invisible to /user/in_progress - can only be observed
against an episode the server does NOT already consider playing. Pick one that
is already in progress and that half skips itself as not covered.

So this does not just list uuids, it sorts them by whether they are usable and
hands back the two lines to paste.

    $env:PC_EMAIL = '...'; $env:PC_PASSWORD = '...'
    .\tests\api\Run-Tests.ps1 -ListEpisodes

It reads only. Nothing here writes to the account.

It prints episode titles, so treat the output like the rest of the account -
it is fine on your terminal and does not belong in a bug report.
"""

import os
import sys

from pcapi import PocketCasts


def main():
    email = os.environ.get("PC_EMAIL")
    password = os.environ.get("PC_PASSWORD")
    if not email or not password:
        print("PC_EMAIL / PC_PASSWORD are not set - see tests/api/README.md")
        return 2

    client = PocketCasts()
    response = client.login(email, password)
    if response.status_code != 200:
        print("login failed with " + str(response.status_code))
        return 1
    client.token = response.json()["token"]

    # Episodes the server considers playing. These are the ones the A/B cannot
    # use, because in_progress reports them whatever we send.
    #
    # The PODCASTS behind them matter too, and for the opposite reason: a
    # position written against a podcast that never appears in /user/in_progress
    # cannot be read back from it, so the round-trip test can prove nothing
    # about such an episode and reports itself as not covered.
    in_progress = set()
    represented = set()
    body = client.in_progress().json()
    entries = body.get("episodes") or []
    for entry in entries:
        if entry.get("uuid"):
            in_progress.add(entry["uuid"])
        if entry.get("podcastUuid"):
            represented.add(entry["podcastUuid"])
    total = body.get("total")
    if isinstance(total, int) and total > len(entries):
        print("")
        print("NOTE: /user/in_progress returned " + str(len(entries)) + " of total="
              + str(total) + ". It is paging, so the round-trip test cannot conclude")
        print("      anything from an episode's absence there whichever one you pick.")

    candidates = []
    seen = set()

    def collect(source, entries, episode_key):
        for entry in entries or []:
            if not isinstance(entry, dict):
                continue
            uuid = entry.get(episode_key)
            podcast = entry.get("podcast")
            if not uuid or not podcast or uuid in seen:
                continue
            seen.add(uuid)
            candidates.append({
                "uuid": uuid,
                "podcast": podcast,
                "title": entry.get("title") or "(untitled)",
                "source": source,
                "started": uuid in in_progress,
                "readable": podcast in represented,
            })

    collect("up next", client.up_next().json().get("episodes"), "uuid")
    for playlist in client.playlists().json().get("playlists") or []:
        if isinstance(playlist, dict) and playlist.get("manual") and not playlist.get("isDeleted"):
            collect(playlist.get("title") or "playlist", playlist.get("episodes"), "episode")

    if not candidates:
        print("no episodes in Up Next or any manual playlist - nothing to point the "
              "mutating tests at")
        return 1

    # Never started first, and among those the ones whose podcast already
    # appears in /user/in_progress - those are the only episodes the
    # round-trip test can conclude anything from.
    candidates.sort(key=lambda c: (c["started"], not c["readable"], c["source"]))

    print("")
    print("%-4s %-13s %-9s %-38s %-38s %s" % (
        "", "STATE", "READBACK", "EPISODE UUID", "PODCAST UUID", "TITLE"))
    print("-" * 128)
    for i, c in enumerate(candidates, 1):
        print("%-4s %-13s %-9s %-38s %-38s %s" % (
            str(i) + ".",
            "in progress" if c["started"] else "never started",
            "yes" if c["readable"] else "no",
            c["uuid"], c["podcast"],
            (c["title"][:44] + "...") if len(c["title"]) > 47 else c["title"],
        ))

    print("")
    print("STATE     never started is what the A/B wants - it compares playingStatus against")
    print("          whatever the episode came in as, so either works, but a fresh one is")
    print("          cleaner and can be restored exactly.")
    print("READBACK  whether this episode's podcast already appears in /user/in_progress. If")
    print("          not, a position written against it cannot be read back from there, and")
    print("          the round-trip test reports itself as NOT COVERED rather than failing.")

    best = (next((c for c in candidates if not c["started"] and c["readable"]), None)
            or next((c for c in candidates if c["readable"]), None)
            or next((c for c in candidates if not c["started"]), None))

    print("")
    if best is None:
        print("Every episode on the account is already in progress and none of their podcasts")
        print("appear in /user/in_progress. Any of the above will still run the A/B.")
        return 0

    if best["readable"] and not best["started"]:
        print("Best candidate - never started, and its podcast is readable back, so both the")
        print("A/B and the round trip can run:")
    elif best["readable"]:
        print("Best candidate - already in progress, but its podcast is readable back, so the")
        print("round trip can run. It is restored to the position it is found at:")
    else:
        print("Best available - never started, so the A/B runs cleanly. No candidate's podcast")
        print("appears in /user/in_progress, so the round trip will report NOT COVERED:")

    print("")
    print("  $env:PC_TEST_EPISODE_UUID = '" + best["uuid"] + "'")
    print("  $env:PC_TEST_PODCAST_UUID = '" + best["podcast"] + "'")
    print(r"  .\tests\api\Run-Tests.ps1 -Mutating")
    print("")
    print("The tests move this episode's position and mark it played, then put it back - to")
    print("its own position if it was in progress, or to unplayed at 0 if it was not.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
