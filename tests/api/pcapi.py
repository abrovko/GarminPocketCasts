"""The bare HTTP client the tests drive.

Deliberately thin, and deliberately NOT a port of PocketCastsClient.mc. These
tests exist to check the API's behaviour, so anything they share with the
watch's code would be a shared assumption rather than a verified one - the
request bodies below are written out in full for exactly that reason.
"""

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
