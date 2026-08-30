import Toybox.Application;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.Media;
import Toybox.System;

// Client for the Pocket Casts web API.
//
// The API is the one the web player talks to - unofficial, reverse-engineered,
// and liable to change without notice. Written against the reference at
// github.com/madisonrickert/pocketcasts-api, with the playlist half taken from
// the official (open source) Android client, which is authoritative about the
// shapes the server serves:
//   Automattic/pocket-casts-android, modules/services/servers/.../sync/
//
// One instance drives one refresh, and the whole thing is a chain of requests
// hung off each other's callbacks - Monkey C has no await, and firing them all
// at once is how you blow a 512 KB memory cap:
//
//   login -> /user/playlist/list -> [one lookup per podcast] -> Catalog
class PocketCastsClient {

    // Authenticated API. Everything here is POST + JSON with a bearer token.
    static const API_BASE = "https://api.pocketcasts.com";

    // Public podcast cache. No auth, no token. findbyepisode returns the
    // podcast plus ONE episode in well under 1 KB, where that podcast's full
    // episode list (/mobile/podcast/full) runs to hundreds of KB.
    static const CACHE_BASE = "https://podcast-api.pocketcasts.com";

    // Shown as the title of the Up Next row. Up Next is not a playlist - it
    // is a separate entity on /up_next/sync - but it is offered as just
    // another selectable playlist, pinned to the top.
    static const UP_NEXT_TITLE = "Up Next";

    // From the official Android client's UpNextChange: PLAY_NOW 1,
    // PLAY_NEXT 2, PLAY_LAST 3, REMOVE 4, REPLACE 5. Only REMOVE is ever sent
    // from here - the others are named in tests/api/test_up_next_changes.py,
    // where the shape was verified against the live account before any of this
    // was written. REPLACE in particular rewrites the queue wholesale and must
    // never be reached by accident.
    static const UP_NEXT_ACTION_REMOVE = 4;

    // The Up Next endpoint wants a version string; the official client's
    // SYNC_API_VERSION is 2. Confirmed working against a live account.
    static const SYNC_API_VERSION = "2";

    // Until a podcast's real name is resolved, this stands in as the artist.
    static const UNKNOWN_ARTIST = "Pocket Casts";

    // /sync/update_episode playing status: 1=unplayed, 2=playing, 3=played.
    //
    // BOTH are sent explicitly, and "playing" is the one that was learned the
    // hard way. It used to be left out on the reasoning that reporting a
    // position implies it - every in-progress episode comes back with
    // playingStatus 2, so surely writing playedUpTo sets it. It does not.
    //
    // Measured against the live account, same episode, two calls:
    //
    //   {uuid, podcast, position:875}             -> 200, status stays 0,
    //                                                /user/in_progress: 19,
    //                                                episode NOT among them
    //   {uuid, podcast, position:875, status:2}    -> 200, status becomes 2,
    //                                                /user/in_progress: 20,
    //                                                episode listed at 875
    //
    // Both answer an empty-body 200, so nothing here could ever have told
    // them apart. The position was landing all along - the server had
    // playedUpTo=875 while /user/in_progress, which returns only status 2,
    // showed nothing - so the watch wrote to one field and read from a query
    // filtered on another, and could never resume what it had played itself.
    static const PLAYING_STATUS_PLAYING = 2;
    static const PLAYING_STATUS_PLAYED = 3;

    // No TOKEN_KEY here: the bearer token and the credentials behind it are
    // Auth's, which owns everything to do with the account. It is cached in
    // Storage because sync configuration, sync and playback are three separate
    // launches, and it does expire - a 401 clears it and logs in again, once.

    // Storage is no longer what bounds this: Catalog gives every episode its
    // own key, so the 8 KB per-value limit applies to one ~450 byte record
    // rather than to the whole list, and 50 records is ~23 KB of the 128 KB
    // total. What still bounds it is memory - the playlist JSON is parsed
    // whole before we ever see it, on a device with 512 KB. Overshooting
    // shows up as NETWORK_RESPONSE_OUT_OF_MEMORY, which describeError()
    // reports as "Out of memory" rather than failing silently.
    static const MAX_EPISODES = 50;

    // Titles are only ever rendered into a menu row or track metadata, and
    // both truncate long before this. Trimming here keeps Storage small.
    static const MAX_TITLE = 64;

    // How many /user/in_progress entries get a line of their own in the log.
    // A real account has ~20 and the device log rotates at 5 KB, so this is
    // enough to see the shape of the response without the refresh output
    // pushing everything else out of the file.
    static const MAX_IN_PROGRESS_LOG = 8;

    private var _onDone as (Method(success as Boolean, message as String?) as Void)?;
    private var _retriedAuth as Boolean = false;
    private var _token as String?;

    // What this instance was asked to do, so onLogin knows where to resume
    // after acquiring a token. One instance does one job.
    private var _flushing as Boolean = false;

    // Episodes whose position still has to be reported. Entries leave only
    // when the server confirms.
    private var _dirty as Array<String> = [] as Array<String>;

    // Episodes to take off Up Next. Same contract as _dirty: loaded from
    // Storage at the start of a flush or a refresh's push stage, drained one
    // request at a time, and cleared only on a confirmed 200.
    private var _removals as Array<String> = [] as Array<String>;

    // The episodes, and - parallel to them - the podcast each one belongs to.
    // The podcast uuids are only needed while the refresh is running, so they
    // are kept beside the records rather than inside them.
    private var _records as Array<Dictionary<String, PersistableType>> =
        [] as Array<Dictionary<String, PersistableType>>;
    private var _podcastOf as Array<String> = [] as Array<String>;

    // Episode uuids already banked, so an episode that appears in both Up Next
    // and a playlist gets one record and one download rather than two.
    private var _seenEpisodes as Dictionary<String, Boolean> = {} as Dictionary<String, Boolean>;

    // The selectable playlists, in display order: { "i" => id, "t" => title,
    // "e" => Array<String> of episode uuids }.
    private var _lists as Array<Dictionary<String, PersistableType>> =
        [] as Array<Dictionary<String, PersistableType>>;

    // Distinct podcasts still to be named, as [podcastUuid, anyEpisodeUuid].
    private var _podcastQueue as Array<Array<String>> = [] as Array<Array<String>>;

    // Playlists whose own fetch failed, so _lists says nothing about them.
    // Passed to setCatalog(), which carries them forward instead of concluding
    // from their absence that the user deleted them. Only Up Next can end up
    // here: a failed /user/playlist/list abandons the whole refresh.
    private var _staleLists as Array<String> = [] as Array<String>;

    // onDone is called exactly once, with (true, null) on success or
    // (false, "reason") on failure.
    function initialize(onDone as Method(success as Boolean, message as String?) as Void) {
        _onDone = onDone;
    }

    // Entry point: refresh Catalog's playlists. Up Next is fetched first so it
    // lands at the top of the menu, then the manual playlists are appended.
    function refreshEpisodes() as Void {
        _records = [] as Array<Dictionary<String, PersistableType>>;
        _podcastOf = [] as Array<String>;
        _seenEpisodes = {} as Dictionary<String, Boolean>;
        _lists = [] as Array<Dictionary<String, PersistableType>>;
        _podcastQueue = [] as Array<Array<String>>;
        _staleLists = [] as Array<String>;

        var token = Auth.getToken();
        System.println("pc: refresh, cached token=" + (token != null));
        if (token != null) {
            _token = token;
            requestUpNext();
        } else {
            login();
        }
    }

    // --- Up Next ---

    // /up_next/sync is a two-way sync, not a read: entries in "changes" would
    // ADD, REMOVE or REORDER the user's actual queue. Sending an empty changes
    // array is what makes this a pull. Do not put anything in it.
    private function requestUpNext() as Void {
        System.println("pc: up_next/sync");
        Communications.makeWebRequest(
            API_BASE + "/up_next/sync",
            {
                "deviceTime" => System.getTimer(),
                "version" => SYNC_API_VERSION,
                "upNext" => {
                    "serverModified" => 0,
                    "changes" => [] as Array<PersistableType>
                }
            },
            {
                :method => Communications.HTTP_REQUEST_METHOD_POST,
                :headers => {
                    "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON,
                    "Authorization" => "Bearer " + tokenHeader()
                },
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            },
            method(:onUpNext)
        );
    }

    // A failure here is not fatal: the playlists are still worth having, and
    // an absent Up Next row is better than an empty menu.
    //
    // But it must not be mistaken for "the user has no Up Next". Recording it
    // as stale is what stops commit() concluding, from its absence, that the
    // queue was deleted - which silently threw away the user's tick and left
    // the next sync with nothing selected.
    function onUpNext(
        responseCode as Number,
        data as Dictionary or String or Toybox.PersistedContent.Iterator or Null
    ) as Void {
        var episodes = null;
        if (responseCode == 200 && data instanceof Dictionary) {
            episodes = data.get("episodes");
        }

        if (episodes instanceof Array) {
            // An empty queue arrives as an empty array, and that IS an answer -
            // it collects a list with no episodes, which is different from not
            // having asked.
            collectList(Catalog.UP_NEXT_ID, UP_NEXT_TITLE, episodes as Array<Object?>);
        } else {
            System.println("pc: up_next failed " + responseCode + ", carrying the stored queue forward");
            _staleLists.add(Catalog.UP_NEXT_ID);
        }

        requestPlaylists();
    }

    // --- login ---

    private function login() as Void {
        // Fail here rather than POSTing empty strings and paying a round trip
        // to be told what Storage already knows. The message is what
        // GarminPocketCastsRefreshView shows on the way to the sign-in screen,
        // which is where anyone without credentials is sent.
        if (!Auth.hasCredentials()) {
            System.println("pc: no credentials, not logging in");
            finish(false, "Sign in first");
            return;
        }

        System.println("pc: login");
        Communications.makeWebRequest(
            API_BASE + "/user/login",
            {
                "email" => Auth.getEmail(),
                "password" => Auth.getPassword(),
                "scope" => "webplayer"
            },
            {
                :method => Communications.HTTP_REQUEST_METHOD_POST,
                :headers => { "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON },
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            },
            method(:onLogin)
        );
        System.println("pc: login request issued");
    }

    // The SDK types makeWebRequest callbacks only for the JSON/GPX cases and
    // checks the signature invariantly, so every callback here is declared
    // with the SDK's exact signature and narrowed by instanceof afterwards.
    function onLogin(
        responseCode as Number,
        data as Dictionary or String or Toybox.PersistedContent.Iterator or Null
    ) as Void {
        if (responseCode == 200 && data instanceof Dictionary) {
            var token = data.get("token");
            if (token instanceof String) {
                Auth.setToken(token);
                _token = token;
                System.println("pc: login ok");
                if (_flushing) {
                    pushNext();
                } else {
                    requestUpNext();
                }
                return;
            }
        }

        System.println("pc: login failed " + responseCode);

        // 401 from /user/login is the server saying these credentials are
        // wrong - the one place in this app where that is unambiguous, since a
        // 401 from any authenticated endpoint means a token that has merely
        // expired. Throw the password away: that makes hasCredentials() false,
        // which is what routes the user to the sign-in screen instead of
        // leaving them on a picker they cannot fix anything from.
        //
        // Bad credentials come back 401 here, not 400.
        if (responseCode == 401) {
            Auth.rejectCredentials();
            finish(false, "Wrong email or password");
            return;
        }

        if (responseCode == 200) {
            finish(false, "Login gave no token");
        } else {
            finish(false, "Login failed (" + responseCode + ")");
        }
    }

    // --- the playlist ---

    private function requestPlaylists() as Void {
        System.println("pc: playlist/list");
        Communications.makeWebRequest(
            API_BASE + "/user/playlist/list",
            // The official client sends {"m": <model>, "v": 1} here (its
            // BasicRequest). This endpoint does want the version field.
            { "m" => "garmin", "v" => 1 },
            {
                :method => Communications.HTTP_REQUEST_METHOD_POST,
                :headers => {
                    "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON,
                    "Authorization" => "Bearer " + tokenHeader()
                },
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            },
            method(:onPlaylists)
        );
    }

    function onPlaylists(
        responseCode as Number,
        data as Dictionary or String or Toybox.PersistedContent.Iterator or Null
    ) as Void {
        // A stored token outlives its server-side session. Throw it away and
        // log in again, but only once - a login that keeps coming back 401
        // would otherwise loop until the watch gave up.
        if (responseCode == 401 || responseCode == 403) {
            Auth.clearToken();
            if (!_retriedAuth) {
                _retriedAuth = true;
                System.println("pc: token rejected, re-login");
                login();
                return;
            }
        }

        if (responseCode != 200 || !(data instanceof Dictionary)) {
            System.println("pc: playlist/list failed " + responseCode);
            finish(false, describeError(responseCode));
            return;
        }

        var playlists = data.get("playlists");
        if (!(playlists instanceof Array)) {
            finish(false, "No playlists in reply");
            return;
        }

        collectPlaylists(playlists as Array<Object?>);

        System.println("pc: " + _lists.size() + " list(s), " + _records.size() +
            " episode(s), " + _podcastQueue.size() + " podcast(s)");

        // Pull server-side progress before committing, so an episode played on
        // the phone resumes in the right place here.
        requestInProgress();
    }

    // Every manual playlist is offered as one. Two kinds are skipped:
    //
    //   isDeleted  - deleted playlists STAY in the response, and offering one
    //                would queue downloads for a playlist the user has thrown away
    //   manual=0   - a smart playlist stores only rules (podcastUuids,
    //                unplayed, starred, filterHours, longerThan/shorterThan)
    //                which the official clients evaluate locally against a
    //                full episode database this watch cannot hold
    //
    // A MANUAL playlist still carries every one of those rule fields populated
    // with defaults, so `manual` is the only field that distinguishes the two.
    private function collectPlaylists(playlists as Array<Object?>) as Void {
        for (var i = 0; i < playlists.size(); i++) {
            var entry = playlists[i];
            if (!(entry instanceof Dictionary)) {
                continue;
            }

            var deleted = entry.get("isDeleted");
            if (deleted instanceof Boolean && deleted) {
                continue;
            }

            var manual = entry.get("manual");
            var isManual = (manual instanceof Boolean && manual) ||
                           (manual instanceof Number && manual != 0);
            if (!isManual) {
                continue;
            }

            var uuid = getString(entry, "uuid");
            if (uuid.length() == 0) {
                continue;
            }

            var title = getString(entry, "title");
            if (title.length() == 0) {
                title = uuid;
            }

            var episodes = entry.get("episodes");
            if (!(episodes instanceof Array)) {
                episodes = [] as Array<Object?>;
            }
            collectList(uuid, title, episodes as Array<Object?>);
        }
    }

    // A manual playlist and Up Next serve their episodes in the same shape:
    //
    //   { "uuid"|"episode": <uuid>, "podcast": <uuid>, "title": ...,
    //     "url": ..., "published": ... }
    //
    // Everything the player needs is there except the media type, so nothing
    // has to be resolved per episode. The array arrives in the user's own
    // order - matching "episodeOrder" for a playlist, queue order for Up Next -
    // so it is taken as-is.
    private function collectList(id as String, title as String, episodes as Array<Object?>) as Void {
        var ids = [] as Array<String>;

        for (var i = 0; i < episodes.size(); i++) {
            var entry = episodes[i];
            if (!(entry instanceof Dictionary)) {
                continue;
            }
            var uuid = addEpisode(entry);
            if (uuid != null) {
                ids.add(uuid);
            }
        }

        if (episodes.size() > ids.size()) {
            System.println("pc: list '" + title + "' kept " + ids.size() + " of " + episodes.size());
        }

        _lists.add({
            "i" => id,
            "t" => clampTitle(title),
            "e" => ids
        } as Dictionary<String, PersistableType>);
    }

    // The episodes this refresh collected, eight characters each - the other
    // half of the answer to "why did nothing merge". Side by side with
    // "ip all:" it says whether the server never reported an episode we hold
    // or reported one we failed to match, which want completely different
    // fixes.
    private function heldKeys() as String {
        var keys = _seenEpisodes.keys();
        var out = "";
        for (var i = 0; i < keys.size(); i++) {
            out += (keys[i] as String).substring(0, 8) + " ";
        }
        return out;
    }

    // Bank one episode's record, or return the uuid of the one already banked.
    // The same episode can sit in Up Next and a playlist at once; it must get
    // one record and one download, while still appearing in both playlists.
    private function addEpisode(entry as Dictionary) as String? {
        var uuid = firstString(entry, "episode", "uuid");
        var url = getString(entry, "url");
        if (uuid.length() == 0 || url.length() == 0) {
            return null;
        }

        if (_seenEpisodes.hasKey(uuid)) {
            return uuid;
        }
        if (_records.size() >= MAX_EPISODES) {
            return null;
        }

        var title = getString(entry, "title");
        if (title.length() == 0) {
            title = uuid;
        }
        var podcastUuid = firstString(entry, "podcast", "podcastUuid");

        // The podcast's name is not in either response. It gets filled in by
        // resolvePodcastNext(); this stands in if that lookup fails.
        //
        // Duration is best-effort in exactly the same way: Up Next entries
        // carry one, manual playlist entries do not, and 0 means the playback
        // menu shows how far in the listener is instead of how much is left.
        _records.add(Catalog.makeRecord(
            uuid,
            url,
            clampTitle(title),
            UNKNOWN_ARTIST,
            encodingForUrl(url, firstString(entry, "fileType", "file_type")),
            podcastUuid,
            secondsOf(entry, "duration")
        ));
        _podcastOf.add(podcastUuid);
        _seenEpisodes.put(uuid, true);

        queuePodcast(podcastUuid, uuid);
        return uuid;
    }

    // One lookup per DISTINCT podcast, not per episode. A hand-curated
    // playlist usually draws on a handful of shows, so this is typically one
    // or two requests however many episodes are in it.
    private function queuePodcast(podcastUuid as String, episodeUuid as String) as Void {
        if (podcastUuid.length() == 0) {
            return;
        }
        for (var i = 0; i < _podcastQueue.size(); i++) {
            if (_podcastQueue[i][0].equals(podcastUuid)) {
                return;
            }
        }
        _podcastQueue.add([podcastUuid, episodeUuid] as Array<String>);
    }

    // --- pulling positions back from the service ---

    // /user/in_progress returns every partially-played episode on the account
    // - 20 of them on a real account, most of which this watch has never heard
    // of. Only positions for episodes we actually hold are merged, so the
    // positions store does not fill up with strangers.
    private function requestInProgress() as Void {
        System.println("pc: in_progress");
        Communications.makeWebRequest(
            API_BASE + "/user/in_progress",
            {},
            {
                :method => Communications.HTTP_REQUEST_METHOD_POST,
                :headers => {
                    "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON,
                    "Authorization" => "Bearer " + tokenHeader()
                },
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            },
            method(:onInProgress)
        );
    }

    // Not fatal: without it the playlists still work, they just do not pick up
    // progress made on another device.
    function onInProgress(
        responseCode as Number,
        data as Dictionary or String or Toybox.PersistedContent.Iterator or Null
    ) as Void {
        if (responseCode == 200 && data instanceof Dictionary) {
            var episodes = data.get("episodes");

            // A 200 whose body is not the expected shape used to fall through
            // in complete silence - no "failed" line, and "considered 0" never
            // printed either, so the only trace of it was the ABSENCE of a
            // line. Say so out loud instead; the top-level keys are few and
            // name the shape well enough to work from.
            if (!(episodes instanceof Array)) {
                System.println("pc: in_progress: 200 but no episodes array, keys=" + data.keys());
            }

            if (episodes instanceof Array) {
                var list = episodes as Array<Object?>;
                var merged = 0;
                // Every uuid the server returned, built up here and printed on
                // one line at the bottom. See the append below for why.
                var returned = "";

                // What the merge is working with, before any of it is
                // filtered. "considered 0" on its own cannot distinguish an
                // empty response from a full one that overlaps nothing we
                // hold, and those want completely different fixes.
                System.println("pc: in_progress: " + list.size() +
                    " episode(s) on the account, " + _seenEpisodes.size() + " in our lists");

                for (var i = 0; i < list.size(); i++) {
                    var entry = list[i];
                    if (!(entry instanceof Dictionary)) {
                        if (i < MAX_IN_PROGRESS_LOG) {
                            System.println("pc: ip[" + i + "] not a dictionary");
                        }
                        continue;
                    }
                    var uuid = getString(entry, "uuid");
                    if (uuid.length() == 0) {
                        if (i < MAX_IN_PROGRESS_LOG) {
                            System.println("pc: ip[" + i + "] no uuid, keys=" + entry.keys());
                        }
                        continue;
                    }

                    // Every uuid the server returned, eight characters each on
                    // one line. The detailed lines below are capped, and that
                    // cap is exactly what made a whole debugging cycle
                    // inconclusive: with 19 entries and 8 shown, "merged 0"
                    // could not distinguish an episode the server never
                    // reported from one it reported that we failed to match.
                    // This line answers that outright and costs ~170 bytes.
                    returned += uuid.substring(0, 8) + " ";

                    // One compact line per entry, capped: this is the whole
                    // point of the endpoint laid out side by side, so a run
                    // that merges nothing says WHY - a uuid we do not hold, a
                    // missing playedUpTo, or a field under another name.
                    if (i < MAX_IN_PROGRESS_LOG) {
                        System.println("pc: ip[" + i + "] " + uuid.substring(0, 8) +
                            " pos=" + entry.get("playedUpTo") +
                            " dur=" + entry.get("duration") +
                            " status=" + entry.get("playingStatus") +
                            " held=" + _seenEpisodes.hasKey(uuid));
                    }

                    // The one endpoint that reports a duration for every
                    // episode that is part-played, which is exactly the set
                    // the playback menu wants a remaining time for. Taken
                    // whoever wins the position merge - the length of an
                    // episode does not depend on who listened furthest.
                    //
                    // Deliberately OUTSIDE the _seenEpisodes guard below,
                    // which positions need and this does not: a downloaded
                    // episode that has dropped out of every playlist is not in
                    // _seenEpisodes, still has a row in the playback menu, and
                    // is exactly the one whose duration is hardest to get any
                    // other way. Nothing can leak in - applyDuration writes
                    // only where a record already exists.
                    applyDuration(uuid, secondsOf(entry, "duration"));

                    if (!_seenEpisodes.hasKey(uuid)) {
                        continue;
                    }

                    var playedUpTo = entry.get("playedUpTo");
                    if (!(playedUpTo instanceof Number)) {
                        playedUpTo = entry.get("played_up_to");
                    }
                    if (playedUpTo instanceof Number) {
                        Catalog.mergeServerPosition(uuid, playedUpTo);
                        merged++;
                    }
                }
                if (list.size() > MAX_IN_PROGRESS_LOG) {
                    System.println("pc: ip ... and " + (list.size() - MAX_IN_PROGRESS_LOG) + " more");
                }
                System.println("pc: ip all: " + returned);
                System.println("pc: we hold: " + heldKeys());
                System.println("pc: considered " + merged + " server position(s)");
            }
        } else if (responseCode == 200) {
            // 200 with a body that is not a Dictionary at all - a String here
            // means the response was not JSON, which the request explicitly
            // asks for. Truncated, because the device log rotates at 5 KB and
            // an error page would take the whole of it.
            var body = (data == null) ? "null" : data.toString();
            if (body.length() > 120) {
                body = body.substring(0, 120) + "...";
            }
            System.println("pc: in_progress: 200 but body is not a dictionary: " + body);
        } else {
            System.println("pc: in_progress failed " + responseCode);
        }

        // Report our own progress now, over the same BLE link the refresh is
        // already using. This is the flush that matters in practice: a sync
        // only runs when something needs DOWNLOADING, so a listener who
        // finishes what they already synced would otherwise never report it.
        //
        // Strictly AFTER the merge above, never before. Pushing first would
        // send a local position that the pull is about to discover is behind
        // the server's, overwriting further progress made on another device -
        // which is precisely what furthest-wins exists to prevent. Merging
        // first clears the dirty flag on anything the server has already
        // beaten, so only genuinely-ahead positions survive to be pushed.
        _dirty = Catalog.getDirtyKeys();
        _removals = Catalog.getUpNextRemovals();

        // Only here, never in flushPositions(): this is the one path with a
        // pull behind it, and the pull is the freshest word on what the queue
        // actually holds. Before the count is printed, so the log says what
        // will be sent rather than what was banked.
        dropRemovalsAlreadyGone();

        if (_dirty.size() > 0 || _removals.size() > 0) {
            System.println("pc: pushing " + _dirty.size() + " position(s), "
                + _removals.size() + " up_next removal(s)");
        }
        pushNext();
    }

    // Forget removals the account has already applied.
    //
    // A REMOVE for an episode the queue does not hold is harmless - the server
    // finds nothing and answers 200 - but this app writes to an account it
    // does not own, and a write that means nothing should not be sent. The
    // everyday case is the listener opening Pocket Casts on their phone before
    // the watch next finds a link: the phone tidies the queue, and the watch
    // arrives with an instruction that has already been carried out.
    //
    // It does NOT close the re-queue race, and cannot. An episode deliberately
    // put back on the queue after being finished here is simply *present*, and
    // so is one nobody ever touched - the watch has no way to tell them apart,
    // and dropping the removal whenever the episode is present would disable
    // the feature entirely. `modified: 0` remains the only mitigation there.
    private function dropRemovalsAlreadyGone() as Void {
        var queued = fetchedUpNextIds();
        if (queued == null) {
            // No fetched Up Next this time round - either the queue's own
            // fetch failed and it is carried as stale, or Up Next is not among
            // the lists. Either way this refresh knows nothing about what the
            // queue holds, and silence is not evidence of absence.
            return;
        }

        var keep = [] as Array<String>;
        for (var i = 0; i < _removals.size(); i++) {
            var uuid = _removals[i];
            if (queued.indexOf(uuid) >= 0) {
                keep.add(uuid);
                continue;
            }
            System.println("pc: up_next " + uuid + " already gone, dropping the removal");
            Catalog.clearUpNextRemoval(uuid);
        }
        _removals = keep;
    }

    // The uuids Up Next came back with on THIS refresh, or null if it did not
    // come back at all. Read from _lists rather than Storage deliberately -
    // Storage still holds the previous fetch until commit() runs, which is
    // after the push, so it would answer the older question.
    private function fetchedUpNextIds() as Array<String>? {
        for (var i = 0; i < _lists.size(); i++) {
            var id = _lists[i].get("i");
            if (id instanceof String && id.equals(Catalog.UP_NEXT_ID)) {
                var episodes = _lists[i].get("e");
                return (episodes instanceof Array) ? episodes as Array<String> : null;
            }
        }
        return null;
    }

    // --- reporting positions back to the service ---

    // Entry point for a flush. Separate from refreshEpisodes(): one instance
    // does one job, and _flushing tells onLogin where to resume.
    function flushPositions() as Void {
        _flushing = true;
        _dirty = Catalog.getDirtyKeys();
        _removals = Catalog.getUpNextRemovals();
        System.println("pc: flush " + _dirty.size() + " position(s), "
            + _removals.size() + " up_next removal(s)");

        if (_dirty.size() == 0 && _removals.size() == 0) {
            finish(true, null);
            return;
        }

        var token = Auth.getToken();
        if (token != null) {
            _token = token;
            pushNext();
        } else {
            login();
        }
    }

    private function pushNext() as Void {
        if (_dirty.size() == 0) {
            // Positions are done; the queue removals go next, and they share
            // both tails - see removeNext().
            removeNext();
            return;
        }

        var uuid = _dirty[0];
        var podcast = Catalog.getPodcastFor(uuid);
        if (podcast.length() == 0) {
            // Nothing to report it against - a record written before the
            // podcast uuid was carried, and nothing in the outbox either.
            // Drop it rather than retrying forever; the position is still held
            // locally for resume.
            //
            // clearPlayed() as well as clearDirty(), because the report is
            // never going to be sent and "played here" outranks any server
            // position in mergeServerPosition(). Leaving it set stranded the
            // episode at 0 forever: the server held 876s for it, every refresh
            // read that back, and every refresh refused to merge it.
            System.println("pc: no podcast for " + uuid + ", dropping from outbox");
            Catalog.clearPlayed(uuid);
            Catalog.clearDirty(uuid);
            _dirty = _dirty.slice(1, null);
            pushNext();
            return;
        }

        // A finished episode is reported by STATUS. Sending the 0 that is
        // stored locally would tell the server the episode is back at the
        // start, resetting it to unplayed on every other device - the exact
        // opposite of what finishing it means.
        // Typed as makeWebRequest declares its params, not as a record.
        var body = { "uuid" => uuid, "podcast" => podcast } as Dictionary<Object, Object>;
        if (Catalog.isPlayed(uuid)) {
            body.put("status", PLAYING_STATUS_PLAYED);
            System.println("pc: update_episode " + uuid + " status=played");
        } else {
            // Position AND status. "Accepted" is not the same as "recorded":
            // position alone has been measured returning 200 and changing
            // nothing that /user/in_progress can see. See PLAYING_STATUS_*.
            var position = Catalog.getPosition(uuid);
            body.put("position", position);
            body.put("status", PLAYING_STATUS_PLAYING);

            // duration is deliberately NOT sent. It would only ever help
            // other devices - this app reads durations, it does not need the
            // server to hold them - and it is the one field of this call that
            // has not been measured. Adding it is a separate change with its
            // own A/B against a live account, not a rider on this one.
            System.println("pc: update_episode " + uuid + " pos=" + position + " status=playing");
        }

        Communications.makeWebRequest(
            API_BASE + "/sync/update_episode",
            body,
            {
                :method => Communications.HTTP_REQUEST_METHOD_POST,
                :headers => {
                    "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON,
                    "Authorization" => "Bearer " + tokenHeader()
                },
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            },
            method(:onPushed)
        );
    }

    // Success is a 200 with an empty body, so there is nothing to parse -
    // only the code matters. The outbox entry is cleared ONLY here: a push
    // that never gets a reply stays queued and is retried on the next flush.
    function onPushed(
        responseCode as Number,
        data as Dictionary or String or Toybox.PersistedContent.Iterator or Null
    ) as Void {
        if (_dirty.size() == 0) {
            return;
        }

        if (responseCode != 200) {
            reportFailed("update_episode", responseCode);
            return;
        }

        Catalog.clearDirty(_dirty[0]);
        Catalog.clearPlayed(_dirty[0]);
        _dirty = _dirty.slice(1, null);
        pushNext();
    }

    // --- taking finished episodes off Up Next ---

    // The second outbox, drained after the positions and sharing both of
    // pushNext()'s tails so a flush and a refresh each end where they did
    // before.
    //
    // One request per episode rather than one batch, even though `changes` is
    // an array and would take them all. The outbox almost never holds more
    // than one - episodes are finished one at a time - and per-entry
    // confirmation is what lets an entry be cleared only when the server has
    // actually taken it. A batch answers with a single code for the lot, so a
    // partial failure would either re-send removals the server already applied
    // or drop ones it never did.
    private function removeNext() as Void {
        if (_removals.size() == 0) {
            if (_flushing) {
                System.println("pc: flush done");
                finish(true, null);
            } else {
                // Mid-refresh: carry on to naming the podcasts and committing.
                resolvePodcastNext();
            }
            return;
        }

        var uuid = _removals[0];
        System.println("pc: up_next remove " + uuid);

        // serverModified 0 and modified 0, both measured rather than assumed.
        // 0 is what this client already sends on a pull, and it keeps every
        // value inside a 32-bit Number - epoch milliseconds does not fit one,
        // and a real timestamp would have meant Lang.Long plus an unanswered
        // question about whether makeWebRequest encodes it. It is also the
        // safer value: a change stamped 0 looks maximally old, so a genuine
        // re-queue from the phone wins.
        Communications.makeWebRequest(
            API_BASE + "/up_next/sync",
            {
                "deviceTime" => System.getTimer(),
                "version" => SYNC_API_VERSION,
                "upNext" => {
                    "serverModified" => 0,
                    "changes" => [
                        {
                            "action" => UP_NEXT_ACTION_REMOVE,
                            "modified" => 0,
                            "uuid" => uuid
                        }
                    ] as Array<PersistableType>
                }
            },
            {
                :method => Communications.HTTP_REQUEST_METHOD_POST,
                :headers => {
                    "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON,
                    "Authorization" => "Bearer " + tokenHeader()
                },
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            },
            method(:onRemoved)
        );
    }

    // Cleared ONLY on a confirmed 200, exactly like a position push: a request
    // that never gets a reply stays queued and goes again next time.
    //
    // The failure policy is the same too, and for the same reason. A flush
    // reports the failure, because reporting is all a flush was for. A refresh
    // abandons the outbox and carries on, because the user came here to pick
    // episodes and must not lose that to a tidy-up - the entries are untouched
    // in Storage and are retried at the next opportunity.
    function onRemoved(
        responseCode as Number,
        data as Dictionary or String or Toybox.PersistedContent.Iterator or Null
    ) as Void {
        if (_removals.size() == 0) {
            return;
        }

        if (responseCode != 200) {
            reportFailed("up_next remove", responseCode);
            return;
        }

        Catalog.clearUpNextRemoval(_removals[0]);
        _removals = _removals.slice(1, null);
        removeNext();
    }

    // What a failed report does, for both outboxes. They had the same policy
    // written out twice, which is two places for it to drift.
    //
    // A FLUSH reports the failure, because reporting is the only thing a flush
    // was ever for. A REFRESH abandons the outboxes and carries on to naming
    // the podcasts and committing, because the user came here to pick episodes
    // and must not lose that to a tidy-up.
    //
    // Either way Storage is untouched - entries are cleared only on a
    // confirmed 200 - so everything abandoned here goes out at the next
    // opportunity. The in-memory arrays are emptied so nothing downstream
    // tries to drain them; resolvePodcastNext() never reads them again.
    private function reportFailed(what as String, responseCode as Number) as Void {
        System.println("pc: " + what + " failed " + responseCode);
        if (_flushing) {
            finish(false, describeError(responseCode));
            return;
        }
        _dirty = [] as Array<String>;
        _removals = [] as Array<String>;
        resolvePodcastNext();
    }

    // --- naming the podcasts ---

    private function resolvePodcastNext() as Void {
        if (_podcastQueue.size() == 0) {
            commit();
            return;
        }

        var entry = _podcastQueue[0];
        System.println("pc: findbyepisode " + entry[0]);
        Communications.makeWebRequest(
            CACHE_BASE + "/mobile/podcast/findbyepisode/" + entry[0] + "/" + entry[1],
            null,
            {
                :method => Communications.HTTP_REQUEST_METHOD_GET,
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            },
            method(:onPodcast)
        );
    }

    // {podcast: {title, author, ...}, episodes: [{...}]} off the public cache.
    //
    // A failure here is deliberately NOT fatal: the episodes are already
    // complete and playable, and all that is lost is a nicer artist line.
    function onPodcast(
        responseCode as Number,
        data as Dictionary or String or Toybox.PersistedContent.Iterator or Null
    ) as Void {
        if (_podcastQueue.size() == 0) {
            return;
        }
        var podcastUuid = _podcastQueue[0][0];

        if (responseCode == 200 && data instanceof Dictionary) {
            var podcast = data.get("podcast");
            if (podcast instanceof Dictionary) {
                var title = getString(podcast, "title");
                if (title.length() > 0) {
                    applyPodcastTitle(podcastUuid, clampTitle(title));
                }
            }

            // The lookup is made for the podcast's NAME, but it answers with
            // the one episode it was asked about, duration included. That is a
            // free duration for one episode per podcast, so it is taken even
            // though it is not why the request was sent.
            //
            // The episode array is looked for in both places on purpose: this
            // endpoint nests it under "podcast", its sibling /mobile/podcast/full
            // has been seen with it at the top level, and neither is worth a
            // device cycle to pin down for something this optional.
            takeEpisodeDuration(data.get("episodes"));
            if (podcast instanceof Dictionary) {
                takeEpisodeDuration(podcast.get("episodes"));
            }
        } else {
            System.println("pc: findbyepisode failed " + responseCode);
        }

        _podcastQueue = _podcastQueue.slice(1, null);
        resolvePodcastNext();
    }

    private function takeEpisodeDuration(episodes as Object?) as Void {
        if (!(episodes instanceof Array)) {
            return;
        }
        var list = episodes as Array<Object?>;
        for (var i = 0; i < list.size(); i++) {
            var episode = list[i];
            if (episode instanceof Dictionary) {
                applyDuration(
                    getString(episode, "uuid"),
                    secondsOf(episode, "duration")
                );
            }
        }
    }

    private function applyPodcastTitle(podcastUuid as String, title as String) as Void {
        for (var i = 0; i < _records.size(); i++) {
            if (_podcastOf[i].equals(podcastUuid)) {
                Catalog.setRecordArtist(_records[i], title);
            }
        }
    }

    private function commit() as Void {
        System.println("pc: committing " + _lists.size() + " list(s), " +
            _records.size() + " episode(s), " + _staleLists.size() + " carried");
        Catalog.setCatalog(_lists, _records, _staleLists);
        finish(true, null);
    }

    // --- helpers ---

    private function tokenHeader() as String {
        var token = _token;
        return token != null ? token : "";
    }

    // Read a string field under either of two names. The live API is camelCase
    // and the reference implementation's fixtures are snake_case; accepting
    // both costs nothing and saves a device debugging cycle.
    // The single-name form, for the fields the two conventions happen to
    // spell identically - passing the same name twice said nothing except
    // that the two-name form was the only one available.
    private function getString(source as Dictionary, name as String) as String {
        return firstString(source, name, name);
    }

    private function firstString(source as Dictionary, primary as String, fallback as String) as String {
        var value = source.get(primary);
        if (!(value instanceof String)) {
            value = source.get(fallback);
        }
        if (value instanceof String) {
            return value;
        }
        return "";
    }

    // Seconds off a JSON field, whatever shape the server chose to send them
    // in. Durations come back as a bare number from one endpoint and as a
    // decimal string from another, and playedUpTo has been seen both ways
    // too, so nothing here assumes a type.
    private function secondsOf(source as Dictionary, name as String) as Number {
        return seconds(source, name, name);
    }

    private function seconds(source as Dictionary, primary as String, fallback as String) as Number {
        var value = source.get(primary);
        if (value == null) {
            value = source.get(fallback);
        }
        if (value instanceof Number) {
            return value;
        }
        if (value instanceof Float || value instanceof Double || value instanceof Long) {
            return value.toNumber();
        }
        if (value instanceof String) {
            var parsed = value.toNumber();
            if (parsed != null) {
                return parsed;
            }
            // "1234.0" - toNumber() rejects the decimal point, toFloat() does not.
            var asFloat = value.toFloat();
            if (asFloat != null) {
                return asFloat.toNumber();
            }
        }
        return 0;
    }

    // Note the duration of an episode we already know about. The record is
    // usually still in memory, waiting for commit(); an episode that is
    // downloaded but has since dropped out of every playlist has no in-memory
    // record and is patched in Storage instead.
    private function applyDuration(uuid as String, length as Number) as Void {
        if (length <= 0) {
            return;
        }
        for (var i = 0; i < _records.size(); i++) {
            if (uuid.equals(_records[i].get("k"))) {
                Catalog.setRecordDuration(_records[i], length);
                return;
            }
        }
        Catalog.setDuration(uuid, length);
    }

    // Cap a title at MAX_TITLE characters. NOT the same as Auth.trim(), which
    // strips whitespace - this only ever shortens, and the menu row and track
    // metadata both truncate long before this anyway; it is here to keep
    // Storage small.
    private function clampTitle(text as String) as String {
        if (text.length() <= MAX_TITLE) {
            return text;
        }
        var cut = text.substring(0, MAX_TITLE);
        return cut != null ? cut : text;
    }

    // The playlist response carries NO media type, so the encoding has to come
    // off the url. This matters: :mediaEncoding is handed straight to the
    // decoder, and guessing wrong gives a track that downloads happily and
    // then refuses to play - one of the silent failures this app is full of.
    //
    // Podcast urls are typically ".../128_default_tc.mp3?aid=rss_feed&feed=..."
    // so the query string has to come off before looking at the extension.
    private function encodingForUrl(url as String, fileType as String) as Media.Encoding {
        if (fileType.length() > 0) {
            return encodingFor(fileType);
        }

        var path = url;
        var query = path.find("?");
        if (query != null) {
            var stripped = path.substring(0, query);
            if (stripped != null) {
                path = stripped;
            }
        }
        path = path.toLower();

        if (hasSuffix(path, ".m4a") || hasSuffix(path, ".mp4") || hasSuffix(path, ".m4b")) {
            return Media.ENCODING_M4A;
        }
        if (hasSuffix(path, ".aac")) {
            return Media.ENCODING_ADTS;
        }
        if (hasSuffix(path, ".wav")) {
            return Media.ENCODING_WAV;
        }
        // MP3 for ".mp3" and for anything unrecognised - it is what the
        // overwhelming majority of podcast feeds serve, and the encoding proven
        // on hardware here.
        return Media.ENCODING_MP3;
    }

    private function hasSuffix(text as String, suffix as String) as Boolean {
        var length = text.length();
        var suffixLength = suffix.length();
        if (length < suffixLength) {
            return false;
        }
        var tail = text.substring(length - suffixLength, length);
        return tail != null && tail.equals(suffix);
    }

    private function encodingFor(fileType as String) as Media.Encoding {
        var type = fileType.toLower();
        if (type.equals("audio/mp4") || type.equals("audio/m4a") ||
            type.equals("audio/x-m4a") || type.equals("audio/aac")) {
            return Media.ENCODING_M4A;
        }
        if (type.equals("audio/aacp") || type.equals("audio/adts")) {
            return Media.ENCODING_ADTS;
        }
        if (type.equals("audio/wav") || type.equals("audio/x-wav")) {
            return Media.ENCODING_WAV;
        }
        return Media.ENCODING_MP3;
    }

    private function describeError(responseCode as Number) as String {
        if (responseCode == Communications.NETWORK_RESPONSE_TOO_LARGE) {
            return "List too big";
        }
        if (responseCode == Communications.NETWORK_RESPONSE_OUT_OF_MEMORY) {
            return "Out of memory";
        }
        if (responseCode == Communications.NETWORK_REQUEST_TIMED_OUT) {
            return "Timed out";
        }
        if (responseCode == 401 || responseCode == 403) {
            return "Login rejected";
        }
        // Outside a sync session there is no Wi-Fi: the request goes over BLE
        // through the phone, and with the phone out of reach it fails with
        // this, immediately and with no network round trip at all.
        if (responseCode == Communications.BLE_CONNECTION_UNAVAILABLE) {
            return "No phone link";
        }
        return "Failed (" + responseCode + ")";
    }

    // Drop the callback on the way out. The caller holds this client and this
    // client holds a Method bound back to the caller, and Monkey C is
    // reference counted - that cycle would never be collected.
    private function finish(success as Boolean, message as String?) as Void {
        var callback = _onDone;
        _onDone = null;
        if (callback != null) {
            callback.invoke(success, message);
        }
    }

}
