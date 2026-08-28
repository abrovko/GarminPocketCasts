"""Fixtures, the shape snapshot machinery, and the two safety gates.

Two things this file exists to enforce:

- **Nothing writes to the account by default.** Every test that mutates is
  marked `mutating` and deselected unless --mutating is passed.
- **An untested assumption is never reported as a passing one.** Most of what
  is checked here depends on what the account happens to hold - there is no
  way to assert how a smart playlist is shaped on an account with none. Those
  call not_covered(), which skips AND is listed separately at the end, so
  "verified" and "could not look" never read the same.
"""

import json
import os
import pathlib

import pytest

from pcapi import PocketCasts

SHAPES_DIR = pathlib.Path(__file__).parent / "shapes"

_not_covered = []
_new_baselines = []


# --- options and markers ---

def pytest_addoption(parser):
    parser.addoption(
        "--mutating",
        action="store_true",
        help="also run the tests that WRITE to the account (needs PC_TEST_EPISODE_UUID)",
    )
    parser.addoption(
        "--update-shapes",
        action="store_true",
        help="rewrite the stored response shapes instead of comparing against them",
    )


def pytest_configure(config):
    config.addinivalue_line("markers", "mutating: writes to the real Pocket Casts account")


def pytest_collection_modifyitems(config, items):
    if config.getoption("--mutating"):
        return
    skip = pytest.mark.skip(reason="writes to the account; pass --mutating to run")
    for item in items:
        if "mutating" in item.keywords:
            item.add_marker(skip)


# --- reporting ---

def note_not_covered(reason):
    """Record that something went unchecked, without ending the test.

    For the case where the rest of a test is still worth running - a response
    whose arrays are empty today can still have every one of its other fields
    compared.
    """
    if reason not in _not_covered:
        _not_covered.append(reason)


def not_covered(reason):
    """Skip, and say out loud that the assumption went unchecked."""
    note_not_covered(reason)
    pytest.skip("NOT COVERED: " + reason)


def pytest_terminal_summary(terminalreporter):
    if _new_baselines:
        terminalreporter.write_sep("=", "NEW SHAPE BASELINES RECORDED", yellow=True)
        terminalreporter.write_line(
            "These were written from this run, not compared against anything. Read them "
            "before committing - a broken API baselined here will look correct forever."
        )
        for name in _new_baselines:
            terminalreporter.write_line("  shapes/" + name + ".json")
    if _not_covered:
        terminalreporter.write_sep("=", "NOT COVERED BY THIS ACCOUNT", yellow=True)
        terminalreporter.write_line(
            "These assumptions were not checked - the account holds nothing to check them "
            "against. They are not passing."
        )
        for reason in _not_covered:
            terminalreporter.write_line("  - " + reason)


# --- shape snapshots ---

@pytest.fixture(scope="session")
def shape(pytestconfig):
    """Compare a response against its stored shape, or record a new baseline."""
    from shapes import diff, preserve_populated, shape_of

    def _shape(name, payload):
        path = SHAPES_DIR / (name + ".json")
        actual = shape_of(payload)
        existing = json.loads(path.read_text(encoding="utf-8")) if path.exists() else None

        if pytestconfig.getoption("--update-shapes") or existing is None:
            # An array that is empty today must not blank out the entry shape
            # a populated day recorded - see shapes.preserve_populated.
            record = actual if existing is None else preserve_populated(existing, actual)
            SHAPES_DIR.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            if existing is None:
                _new_baselines.append(name)
            return actual

        lines = diff(existing, actual)

        # An array the baseline saw populated and today's response does not is
        # the account being quiet, not the API moving - an empty Up Next is a
        # Tuesday. It cannot be checked, so it is reported as unchecked rather
        # than failed. The opposite direction (FILLED) stays a failure: that is
        # a shape nothing has ever looked at.
        empty = [line for line in lines if line.startswith("EMPTY")]
        drift = [line for line in lines if not line.startswith("EMPTY")]

        for line in empty:
            note_not_covered(
                name + ": " + line.split("  ")[1].strip()
                + " came back empty, so its entries went unchecked"
            )

        if drift:
            pytest.fail(
                "the shape of " + name + " has changed:\n  "
                + "\n  ".join(drift + empty)
                + "\n\nIf this is a deliberate API change, re-record with --update-shapes "
                  "and check what in source/PocketCastsClient.mc reads the moved field.",
                pytrace=False,
            )
        return actual

    return _shape


# --- credentials and clients ---

@pytest.fixture(scope="session")
def credentials():
    email = os.environ.get("PC_EMAIL")
    password = os.environ.get("PC_PASSWORD")
    if not email or not password:
        pytest.skip("PC_EMAIL / PC_PASSWORD are not set - see tests/api/README.md")
    return email, password


@pytest.fixture(scope="session")
def anon():
    """Unauthenticated client, for the public cache and the login tests."""
    return PocketCasts()


@pytest.fixture(scope="session")
def api(credentials):
    """Logged-in client. One login for the whole run."""
    email, password = credentials
    client = PocketCasts()
    response = client.login(email, password)
    assert response.status_code == 200, (
        "login failed with " + str(response.status_code)
        + " - check PC_EMAIL / PC_PASSWORD before reading anything else in this run"
    )
    token = response.json().get("token")
    assert token, "login returned 200 with no token: " + str(sorted(response.json().keys()))
    client.token = token
    return client


# Session-scoped so one run makes one call of each. These are the responses
# most tests read; anything checking a call's side effects makes its own.

@pytest.fixture(scope="session")
def up_next_body(api):
    response = api.up_next()
    if response.status_code != 200:
        pytest.fail("/up_next/sync returned " + str(response.status_code), pytrace=False)
    return response.json()


@pytest.fixture(scope="session")
def playlists_body(api):
    response = api.playlists()
    if response.status_code != 200:
        pytest.fail("/user/playlist/list returned " + str(response.status_code), pytrace=False)
    return response.json()


@pytest.fixture(scope="session")
def in_progress_body(api):
    response = api.in_progress()
    if response.status_code != 200:
        pytest.fail("/user/in_progress returned " + str(response.status_code), pytrace=False)
    return response.json()


@pytest.fixture(scope="session")
def sample_episode(up_next_body, playlists_body):
    """A (podcast_uuid, episode_uuid) pair off the account, for the lookups.

    Taken from whatever the account holds rather than from an env var: an
    episode uuid hardcoded here would rot, and one the user has to supply is
    another thing to set up before anything runs at all.
    """
    for entry in up_next_body.get("episodes") or []:
        if isinstance(entry, dict) and entry.get("podcast") and entry.get("uuid"):
            return entry["podcast"], entry["uuid"]

    for playlist in playlists_body.get("playlists") or []:
        for entry in (playlist.get("episodes") or []) if isinstance(playlist, dict) else []:
            if isinstance(entry, dict) and entry.get("podcast") and entry.get("episode"):
                return entry["podcast"], entry["episode"]

    not_covered("no episode in Up Next or any playlist to resolve, so the lookup "
                "endpoints went unchecked")


@pytest.fixture(scope="session")
def sample_episode_url(up_next_body, playlists_body, sample_episode):
    """The media url the WATCH would use for sample_episode.

    Deliberately the url off the playlist or queue entry, not the one
    findbyepisode answers with: the sync delegate downloads the former, and
    encodingForUrl() sniffs the former. If the two ever disagree, that is
    itself worth knowing.
    """
    _podcast, uuid = sample_episode

    for entry in up_next_body.get("episodes") or []:
        if isinstance(entry, dict) and entry.get("uuid") == uuid and entry.get("url"):
            return entry["url"]

    for playlist in playlists_body.get("playlists") or []:
        for entry in (playlist.get("episodes") or []) if isinstance(playlist, dict) else []:
            if isinstance(entry, dict) and entry.get("episode") == uuid and entry.get("url"):
                return entry["url"]

    not_covered("the sample episode carries no url in Up Next or any playlist, so the "
                "extension sniff went unchecked")


@pytest.fixture(scope="session")
def test_episode():
    """The sacrificial episode for the mutating tests."""
    uuid = os.environ.get("PC_TEST_EPISODE_UUID")
    podcast = os.environ.get("PC_TEST_PODCAST_UUID")
    if not uuid or not podcast:
        pytest.skip("PC_TEST_EPISODE_UUID / PC_TEST_PODCAST_UUID are not set")
    return podcast, uuid
