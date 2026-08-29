"""The bare HTTP client the tests drive.

Deliberately thin, and deliberately NOT a port of PocketCastsClient.mc. These
tests exist to check the API's behaviour, so anything they share with the
watch's code would be a shared assumption rather than a verified one - the
request bodies below are written out in full for exactly that reason.
"""

import time

import requests

API_BASE = "https://api.pocketcasts.com"
CACHE_BASE = "https://podcast-api.pocketcasts.com"

# Honest, rather than impersonating the watch. Worth knowing as a difference
# from the real client if a test ever disagrees with hardware.
USER_AGENT = "GarminPocketCastsApiTests/1.0"

TIMEOUT = 30


class PocketCasts:
    def __init__(self, token=None):
        self.token = token
        self.session = requests.Session()
        self.session.headers["User-Agent"] = USER_AGENT

    # --- transport ---

    def post(self, path, body, auth=True, base=API_BASE):
        headers = {"Content-Type": "application/json"}
        if auth:
            assert self.token, "post(auth=True) with no token"
            headers["Authorization"] = "Bearer " + self.token
        return self.session.post(base + path, json=body, headers=headers, timeout=TIMEOUT)

    def get(self, path, auth=False, base=CACHE_BASE):
        headers = {}
        if auth:
            assert self.token, "get(auth=True) with no token"
            headers["Authorization"] = "Bearer " + self.token
        return self.session.get(base + path, headers=headers, timeout=TIMEOUT)

    # --- the endpoints the watch uses, one method each ---

    def login(self, email, password):
        return self.post(
            "/user/login",
            {"email": email, "password": password, "scope": "webplayer"},
            auth=False,
        )

    def up_next(self):
        # An empty `changes` array is what makes this two-way endpoint a pull.
        # NOTHING may ever be put in it from here: entries ADD, REMOVE or
        # REORDER the real account's queue. test_up_next.py checks that the
        # empty array really does leave the queue alone.
        return self.post(
            "/up_next/sync",
            {
                "deviceTime": 0,
                "version": "2",
                "upNext": {"serverModified": 0, "changes": []},
            },
        )

    # WRITES, and the only call in this suite that can damage the account
    # structurally rather than just move a position. Only
    # test_up_next_changes.py calls it, and only under --mutating.
    #
    # Same endpoint as up_next() above - the difference IS the changes array,
    # which is the whole point. The shape comes from the official Android
    # client's UpNextSyncRequest.Change:
    #
    #   {action: Int, modified: Long, uuid: String?, title: String?,
    #    url: String?, published: String?, podcast: String?,
    #    episodes: List<ChangeEpisode>?}
    #
    # and the actions from UpNextChange's companion object: PLAY_NOW 1,
    # PLAY_NEXT 2, PLAY_LAST 3, REMOVE 4, REPLACE 5. Written out here rather
    # than imported from anywhere, like the rest of this file - a shape shared
    # with the code under test is an assumption, not a measurement.
    #
    # serverModified is echoed back from a prior pull rather than hardcoded to
    # 0: this is a two-way sync and 0 means "I have seen nothing", which is a
    # different claim when you are also sending changes.
    def up_next_sync(self, changes, server_modified=0, device_time=None):
        return self.post(
            "/up_next/sync",
            {
                "deviceTime": int(time.time() * 1000) if device_time is None else device_time,
                "version": "2",
                "upNext": {
                    # Passed through verbatim, NOT coerced. The response
                    # delivers serverModified as a String while the official
                    # client models it as a Long, and whether the server will
                    # accept the string form back is exactly what one of the
                    # candidate shapes is asking - a cast here would answer it
                    # for the test instead of measuring it.
                    "serverModified": server_modified,
                    "changes": changes,
                },
            },
        )

    def playlists(self):
        return self.post("/user/playlist/list", {"m": "garmin", "v": 1})

    def in_progress(self):
        return self.post("/user/in_progress", {})

    # NOT a call the watch makes, and deliberately not asserted against
    # anywhere. It is the read-back the original A/B used, and it is the only
    # way to tell "the write did not land" from "it landed and
    # /user/in_progress does not report it" - which is the whole question that
    # endpoint pair exists to answer. Its response carries a podcast's entire
    # episode history, which is why the watch cannot use it.
    def podcast_episodes(self, podcast_uuid):
        return self.post("/user/podcast/episodes", {"uuid": podcast_uuid})

    def find_by_episode(self, podcast_uuid, episode_uuid):
        return self.get("/mobile/podcast/findbyepisode/" + podcast_uuid + "/" + episode_uuid)

    # WRITES. Only test_update_episode.py calls this, and only under
    # --mutating.
    def update_episode(self, uuid, podcast, position=None, status=None):
        body = {"uuid": uuid, "podcast": podcast}
        if position is not None:
            body["position"] = position
        if status is not None:
            body["status"] = status
        return self.post("/sync/update_episode", body)
