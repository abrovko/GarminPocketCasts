"""The episode-resolution endpoint on the public cache.

GET /mobile/podcast/findbyepisode/{podcast}/{episode} needs no token and
answers with the podcast plus the single episode asked about. The size is the
point - /mobile/podcast/full/{uuid} returns the podcast's entire episode
history, which the watch cannot hold.
"""

from conftest import not_covered

# Not the ~1 KB a real response measures, but far below what the full episode
# list would be. This is a guard against the endpoint quietly widening, not a
# budget.
SIZE_CEILING = 32 * 1024


# What encodingForUrl() does, restated. Normally this suite refuses to
# reimplement anything from source/ - a shared assumption proves nothing. This
# is the exception that justifies the rule: the point is to check the watch's
# sniff against the server's OWN answer for the same episode, so the two sides
# have to come from different places. Getting this wrong gives a track that
# downloads happily and then refuses to play, with nothing in any log.
SNIFF = {
    ".m4a": "m4a", ".mp4": "m4a", ".m4b": "m4a",
    ".aac": "adts",
    ".wav": "wav",
}
DECLARED = {
    "audio/mpeg": "mp3", "audio/mp3": "mp3",
    "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/m4a": "m4a", "video/mp4": "m4a",
    "audio/aac": "adts", "audio/aacp": "adts",
    "audio/wav": "wav", "audio/x-wav": "wav", "audio/wave": "wav",
}


def sniff_encoding(url):
    """MP3 for .mp3 and for anything unrecognised, exactly as the watch does."""
    path = url.split("?")[0].lower()
    for suffix, encoding in SNIFF.items():
        if path.endswith(suffix):
            return encoding
    return "mp3"


def test_the_url_extension_agrees_with_the_declared_file_type(anon, sample_episode,
                                                              sample_episode_url):
    """encodingForUrl() sniffs the extension; the server states the type.

    Playlist and Up Next entries carry no file type at all, so the extension
    is the watch's only input - and an encoding that disagrees with the bytes
    is one of the failures that gives no error: the download completes, the
    Content is built, and playback simply never starts.

    findbyepisode is where the server says what the file actually is. This is
    the only place the two can be put side by side.
    """
    podcast_uuid, episode_uuid = sample_episode
    body = anon.find_by_episode(podcast_uuid, episode_uuid).json()
    podcast = body.get("podcast") or {}
    episodes = podcast.get("episodes") or body.get("episodes") or []
    if not episodes:
        not_covered("findbyepisode returned no episode, so the declared file type was "
                    "unavailable to check the url sniff against")

    declared = (episodes[0].get("file_type") or "").lower().split(";")[0].strip()
    if not declared:
        not_covered("findbyepisode carries no file_type for this episode, so the url sniff "
                    "went unchecked")

    sniffed = sniff_encoding(sample_episode_url)
    print("lookups: url sniffs as " + sniffed + ", server declares " + declared)

    expected = DECLARED.get(declared)
    if expected is None:
        not_covered("findbyepisode declares file_type '" + declared + "', which encodingFor() "
                    "has no mapping for - check what it does with it before trusting this")

    assert sniffed == expected, (
        "the url's extension sniffs as " + sniffed + " but the server declares " + declared
        + " (" + expected + "). encodingForUrl() has no file type to read on a playlist entry, "
        "so the watch would hand the wrong Media.Encoding to a file that downloads fine and "
        "then refuses to play, with nothing in any log to say why."
    )


def test_findbyepisode_needs_no_token(anon, sample_episode, shape):
    podcast_uuid, episode_uuid = sample_episode
    response = anon.find_by_episode(podcast_uuid, episode_uuid)
    assert response.status_code == 200, (
        "findbyepisode returned " + str(response.status_code) + " unauthenticated - it is "
        "called with no Authorization header at all"
    )
    shape("findbyepisode", response.json())


def test_findbyepisode_stays_small(anon, sample_episode):
    podcast_uuid, episode_uuid = sample_episode
    response = anon.find_by_episode(podcast_uuid, episode_uuid)
    size = len(response.content)
    print("findbyepisode: " + str(size) + " bytes")
    assert size < SIZE_CEILING, (
        "findbyepisode now returns " + str(size) + " bytes. It is issued once per distinct "
        "podcast during a refresh, on a 512 KB device that parses the response whole."
    )


def test_findbyepisode_answers_with_the_episode_asked_for(anon, sample_episode):
    podcast_uuid, episode_uuid = sample_episode
    body = anon.find_by_episode(podcast_uuid, episode_uuid).json()

    podcast = body.get("podcast")
    assert isinstance(podcast, dict), "no podcast object: " + str(sorted(body.keys()))
    assert isinstance(podcast.get("title"), str) and podcast["title"], (
        "the podcast carries no title - this call exists for the artist line"
    )

    episodes = podcast.get("episodes") if isinstance(podcast.get("episodes"), list) else body.get("episodes")
    if not isinstance(episodes, list) or not episodes:
        not_covered("findbyepisode returned no episodes array, so the per-episode fields "
                    "(url, file_type, duration) went unchecked")

    assert len(episodes) == 1, (
        "findbyepisode returned " + str(len(episodes)) + " episodes, not 1. The one-episode "
        "answer is why this is used instead of /mobile/podcast/full."
    )
    episode = episodes[0]
    assert episode.get("uuid") == episode_uuid, "findbyepisode answered about a different episode"
