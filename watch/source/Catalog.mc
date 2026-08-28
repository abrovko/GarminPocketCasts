import Toybox.Application;
import Toybox.Lang;
import Toybox.Media;
import Toybox.System;
import Toybox.Time;

// One playable episode, flattened out of the API response into just the six
// fields the rest of the app needs.
class Track {
    public var key as String;     // episode uuid; doubles as the Storage map key
    public var url as String;     // media url, what onStartSync downloads
    public var title as String;   // episode title
    public var artist as String;  // podcast title
    public var encoding as Media.Encoding;  // passed to the download as :mediaEncoding

    // Total length in seconds, or 0 when it is not known. Nothing in the
    // media layer can supply this - Media.Content has no duration and
    // ContentMetadata has no field for one - so it is whatever the API
    // happened to tell us, and every reader has to cope with 0.
    public var duration as Number;

    function initialize(
        trackKey as String,
        trackUrl as String,
        trackTitle as String,
        trackArtist as String,
        trackEncoding as Media.Encoding,
        trackDuration as Number
    ) {
        key = trackKey;
        url = trackUrl;
        title = trackTitle;
        artist = trackArtist;
        encoding = trackEncoding;
        duration = trackDuration;
    }
}

// The episode catalog, plus the Storage plumbing that carries state between
// app invocations.
//
// Sync configuration, sync and playback each run as a *separate* launch of
// this app, so nothing can be held in memory between them. Storage is the
// only channel they share:
//
//   refresh --(lists + records)--> configure sync --(selLists)-->
//       sync --(refIds + downloaded)--> playback
//
// NAMING. What the user picks from is called a PLAYLIST everywhere on screen,
// Up Next included - it is a queue rather than a playlist strictly speaking,
// but one word for one kind of row is worth more than the distinction. The
// code still says `list` for that concept (LISTS_KEY, getListIds, selLists,
// "le<id>"), and deliberately: `playlist` is already taken in
// PocketCastsClient for the narrower thing the API returns from
// /user/playlist/list, of which Up Next is not one. The Storage key strings
// are frozen regardless - renaming one strands every episode on every watch
// that already holds it.
//
// STORAGE LAYOUT. Keys and values are limited to 8 KB *each*, with 128 KB
// available in total, so the way to hold more than a handful of episodes is
// more keys rather than bigger ones - which is also what the SDK's audio
// content provider FAQ recommends. One episode record therefore gets its own
// key, and the indexes hold only uuids:
//
//   "lists"       Array<String>  playlist ids in display order ("__upnext" first)
//   "selLists"    Array<String>  playlist ids the user ticked
//   "l<id>"       Dictionary     that playlist's { "t" => title }
//   "le<id>"      Array<String>  that playlist's episode uuids
//   "r<uuid>"     Dictionary     that episode's record (~450 bytes)
//   "downloaded"  Array<String>  uuids on the device, in download order
//   "refIds"      Dictionary     uuid => Media.ContentRef id
//   "positions"   Dictionary     uuid => seconds played
//   "dirty"       Array<String>  uuids to report; "played" those that finished
//   "outPod"      Dictionary     uuid => podcast uuid, for everything in "dirty"
//   "finished"    Array<String>  completed here, never re-downloaded
//   "purge"       Array<String>  audio awaiting deletion at the next safe moment
//   "syncBlock"   Boolean        a sync made no progress; suppress one retry
//   "syncError"   String         why the last sync failed
//   "orphChk"     Number         epoch seconds of the last orphan sweep
//   "pcToken"     String         bearer token (PocketCastsClient owns this one)
//
// Two other modules keep keys in the same store and are listed here only so
// this stays the one place to look: Auth.mc owns "pcEmail" and "pcPass", and
// Proxy.mc owns "pxUrl", "pxTok", "pxSpeed", "pxRate", "pxMono" and the pair
// of "pxUrlSeen"/"pxTokSeen" markers. Nothing in this module reads them.
//
// A record is ~450 bytes, dominated by a 275-character media url, so a single
// combined value would have overflowed 8 KB at about 18 episodes and done it
// silently. Split this way the binding limit is the uuid index (8 KB / ~38
// bytes is roughly 200 entries), well past anything else here.
//
// That is a lot of keys, which is exactly why reset() calls
// Storage.clearValues() instead of deleting them one by one.
module Catalog {

    const LISTS_KEY = "lists";              // Array<String> playlist ids, display order
    const SELECTED_LISTS_KEY = "selLists";  // Array<String> playlist ids the user ticked
    const DOWNLOADED_KEY = "downloaded";
    const REF_IDS_KEY = "refIds";

    // Up Next is not a playlist - it is a separate entity on its own endpoint -
    // but it is presented as just another selectable playlist, pinned to the top.
    // This is its id; playlists use their own uuid.
    const UP_NEXT_ID = "__upnext";
    const POSITIONS_KEY = "positions";     // { uuid => seconds played }
    const DIRTY_KEY = "dirty";            // Array<String> uuids played here, not yet reported
    const OUTBOX_PODCAST_KEY = "outPod";  // { uuid => podcast uuid } for everything in DIRTY_KEY
    const PLAYED_KEY = "played";          // Array<String> uuids FINISHED here, not yet reported
    const FINISHED_KEY = "finished";      // Array<String> uuids completed here; never re-downloaded
    const PURGE_KEY = "purge";            // Array<String> uuids whose audio is awaiting deletion

    // Delete an episode's audio once it has been listened to. A ~37 MB episode
    // is worth reclaiming, and a finished one is dead weight. Flip to false to
    // keep everything until the user clears it by hand; a user-facing setting
    // would replace this constant.
    const AUTO_DELETE_PLAYED = true;

    // How many completed uuids to remember. This is what stops a finished
    // episode being re-downloaded by the next sync, so it has to outlive the
    // download - but it cannot grow forever inside one 8 KB value. ~37 bytes
    // each puts the ceiling near 200; 100 is half of that, and the oldest fall
    // off the front.
    const MAX_FINISHED = 100;
    const SYNC_BLOCK_KEY = "syncBlock";   // Boolean, set when a sync made no progress
    const SYNC_ERROR_KEY = "syncError";   // String, why the last sync failed

    // When the media cache was last swept for audio nothing points at any
    // more. See reclaimOrphans() for what that means and why it is needed.
    const ORPHAN_CHECK_KEY = "orphChk";   // Number, epoch seconds of the last sweep

    // How long between sweeps. This runs on the way into the playback hub -
    // the everyday screen - so its cost has to be bounded and predictable
    // rather than proportional to the size of the cache. Orphans are created
    // by faults, never by normal use, so once a day is already far more often
    // than they can appear.
    const ORPHAN_CHECK_INTERVAL = 86400;

    // Deletions per sweep. Bounds the time any one entry point pays, and also
    // bounds how much a mistake in the comparison could destroy before anyone
    // noticed. A sweep that fills its quota deliberately does NOT stamp the
    // marker, so a real backlog drains at the next entry point rather than
    // over the next fortnight.
    const MAX_ORPHAN_DELETES = 8;

    const ALBUM = "Pocket Casts";
    const GENRE = "Podcast";

    // Record fields. One character each on purpose - they are written once per
    // episode and this device has 128 KB of Storage in total.
    //   "k" key  "u" url  "t" title  "a" artist  "e" encoding  "p" podcast uuid
    //   "d" duration in seconds, absent when unknown
    //   "s" playback speed percent this file was encoded at, absent means 100
    //
    // "p" is not used by playback at all. It is carried because reporting a
    // position back to Pocket Casts (/sync/update_episode) requires the
    // podcast uuid alongside the episode uuid, and by then the API response it
    // came from is long gone.
    //
    // "d" lives in the record rather than in a dictionary of its own for the
    // same reason every other per-episode fact does: one key per episode is
    // what keeps any single value clear of the 8 KB limit, and the record's
    // lifetime is already exactly the lifetime a duration should have.

    function makeRecord(
        key as String,
        url as String,
        title as String,
        artist as String,
        encoding as Media.Encoding,
        podcast as String,
        duration as Number
    ) as Dictionary<String, PersistableType> {
        var record = {
            "k" => key,
            "u" => url,
            "t" => title,
            "a" => artist,
            "e" => encoding,
            "p" => podcast
        } as Dictionary<String, PersistableType>;

        // Absent rather than 0 when unknown: a record is written once per
        // episode per refresh and there is no point paying for a field that
        // says nothing.
        if (duration > 0) {
            record.put("d", duration);
        }
        return record;
    }

    function toRecord(track as Track) as Dictionary<String, PersistableType> {
        return makeRecord(
            track.key, track.url, track.title, track.artist, track.encoding,
            getPodcastFor(track.key), track.duration
        );
    }

    // The podcast a downloaded episode belongs to, or "" if unknown - records
    // written before "p" existed simply do not have it. /sync/update_episode
    // needs it long after the response it arrived in is gone.
    //
    // The record is the source, but it is NOT the only place to look, and that
    // is load-bearing rather than defensive. markPlayed() queues a report and
    // then retires the episode; purgeFinished() later deletes its audio AND its
    // record. Read off a device log, that happened in exactly that order with
    // the phone out of reach:
    //
    //   flush: no phone, leaving it for the sync   <- status:3 into the outbox
    //   catalog: purged 1 played episode(s)        <- record deleted
    //   pc: no podcast for 8d687f9f..., dropping from outbox
    //
    // The episode was never reported played, so it stayed in Up Next on the
    // server and the next sync downloaded 37 MB of it again. So the outbox
    // carries its own copy, written by markDirty() while the record is still
    // there, and this falls back to it.
    function getPodcastFor(uuid as String) as String {
        var record = getRecord(uuid);
        if (record != null) {
            var podcast = record.get("p");
            if (podcast instanceof String) {
                return podcast;
            }
        }

        var outbox = getOutboxPodcasts();
        var queued = outbox.get(uuid);
        if (queued instanceof String) {
            return queued;
        }
        return "";
    }

    // Overwrite a record's artist in place. The one-character field names are
    // an implementation detail of this module, so callers that need to patch
    // a record after building it go through here rather than knowing "a".
    function setRecordArtist(record as Dictionary<String, PersistableType>, artist as String) as Void {
        record.put("a", artist);
    }

    function setRecordDuration(record as Dictionary<String, PersistableType>, seconds as Number) as Void {
        if (seconds > 0) {
            record.put("d", seconds);
        }
    }

    function recordDuration(record as Dictionary) as Number {
        var seconds = record.get("d");
        if (seconds instanceof Number && seconds > 0) {
            return seconds;
        }
        return 0;
    }

    // --- playback speed, and the two places time crosses the media boundary ---

    // The speed THIS FILE ON THIS WATCH was encoded at, as a percentage.
    //
    // It belongs to the download, not to the setting. An episode fetched at
    // 1.5x and played after the listener switches the proxy to 2x has to be
    // read back against the 150 it was made with; taking the current setting
    // instead would divide every position by the wrong number, permanently and
    // invisibly. Absent means 100, so every record written before this field
    // existed is already correct and nothing needs migrating - the same
    // convention "d" uses for an unknown duration.
    function getSpeed(uuid as String) as Number {
        var record = getRecord(uuid);
        if (record == null) {
            return 100;
        }
        var percent = record.get("s");
        if (percent instanceof Number && percent > 0) {
            return percent;
        }
        return 100;
    }

    // Record the speed a completed download was encoded at.
    function setSpeed(uuid as String, percent as Number) as Void {
        var record = getRecord(uuid);
        if (record == null) {
            return;
        }
        var patched = record as Dictionary<String, PersistableType>;
        if (percent == 100) {
            patched.remove("s");
        } else {
            patched.put("s", percent);
        }
        putRecord(uuid, patched);
    }

    // EVERYTHING IN STORAGE IS IN CONTENT SECONDS - the episode's own timeline,
    // the one Pocket Casts and every other device agree on. The media layer is
    // the only place file seconds exist, because the file is physically
    // shorter than the episode. These two functions are the entire boundary,
    // and there are exactly two callers:
    //
    //   toContentSeconds  GarminPocketCastsContentDelegate.bankPosition()
    //   toFileSeconds     GarminPocketCastsContentIterator, building ActiveContent
    //
    // Keeping it to those two is what lets markDirty, the outbox,
    // mergeServerPosition, furthest-along-wins, getDuration and the hub's
    // "23m left" all carry on untouched: they were always content seconds on
    // both sides and still are.
    //
    // THEY TAKE THE PERCENTAGE, NOT THE UUID, AND THAT IS DELIBERATE. Looking
    // the speed up in here meant an encrypted Storage read and a dictionary
    // deserialise inside a media playback callback, on every event that
    // carries a position. Callers resolve it once per track with getSpeed()
    // and pass the number down, which keeps the hot path to arithmetic.
    function toContentSeconds(percent as Number, fileSeconds as Number) as Number {
        if (percent == 100 || percent <= 0 || fileSeconds <= 0) {
            return fileSeconds;
        }
        return (fileSeconds * percent) / 100;
    }

    function toFileSeconds(percent as Number, contentSeconds as Number) as Number {
        if (percent == 100 || percent <= 0 || contentSeconds <= 0) {
            return contentSeconds;
        }
        return (contentSeconds * 100) / percent;
    }

    // How long an episode runs, or 0 when nobody has told us. Records written
    // before "d" existed simply do not have it, and a manual playlist entry
    // never carries one, so 0 is a normal answer rather than an error.
    function getDuration(uuid as String) as Number {
        var record = getRecord(uuid);
        if (record == null) {
            return 0;
        }
        return recordDuration(record);
    }

    // Patch a duration into an episode's stored record. This is the path for
    // an episode that is downloaded but no longer in any fetched playlist - it
    // still has a record and still shows up in the playback menu, but the
    // client has no in-memory record to patch.
    function setDuration(uuid as String, seconds as Number) as Void {
        if (seconds <= 0) {
            return;
        }
        var record = getRecord(uuid);
        if (record == null || recordDuration(record) == seconds) {
            return;
        }
        var patched = record as Dictionary<String, PersistableType>;
        patched.put("d", seconds);
        putRecord(uuid, patched);
    }

    // Records come back out of Storage untyped and may predate a change to
    // the shape above, so every field is checked rather than cast. A record
    // that does not survive the check is dropped, not repaired.
    function fromRecord(record as Dictionary) as Track? {
        var key = record.get("k");
        var url = record.get("u");
        var title = record.get("t");
        if (!(key instanceof String) || !(url instanceof String) || !(title instanceof String)) {
            return null;
        }

        var artist = record.get("a");
        if (!(artist instanceof String)) {
            artist = "";
        }

        var encoding = Media.ENCODING_MP3;
        var stored = record.get("e");
        if (stored instanceof Number) {
            encoding = stored as Media.Encoding;
        }

        return new Track(key, url, title, artist, encoding, recordDuration(record));
    }

    // --- one key per episode record ---

    function recordKey(uuid as String) as String {
        return "r" + uuid;
    }

    function getRecord(uuid as String) as Dictionary? {
        var stored = Storage.getValue(recordKey(uuid));
        if (stored instanceof Dictionary) {
            return stored as Dictionary;
        }
        return null;
    }

    function putRecord(uuid as String, record as Dictionary<String, PersistableType>) as Void {
        Storage.setValue(recordKey(uuid), record as Dictionary<Storage.KeyType, Storage.ValueType>);
    }

    function deleteRecord(uuid as String) as Void {
        Storage.deleteValue(recordKey(uuid));
    }

    // --- the uuid indexes ---

    function getIds(storageKey as String) as Array<String> {
        var stored = Storage.getValue(storageKey);
        if (stored instanceof Array) {
            return stored as Array<String>;
        }
        return [] as Array<String>;
    }

    function putIds(storageKey as String, ids as Array<String>) as Void {
        Storage.setValue(storageKey, ids as Array<Storage.ValueType>);
    }

    function tracksFor(ids as Array<String>) as Array<Track> {
        var tracks = [] as Array<Track>;
        for (var i = 0; i < ids.size(); i++) {
            var record = getRecord(ids[i]);
            if (record != null) {
                var track = fromRecord(record);
                if (track != null) {
                    tracks.add(track);
                }
            }
        }
        return tracks;
    }

    // --- the playlists ---

    function listKey(id as String) as String {
        return "l" + id;
    }

    function listEpisodesKey(id as String) as String {
        return "le" + id;
    }

    // Replace the whole catalog: the playlists on offer and every episode record
    // they reference. Called only by PocketCastsClient.
    //
    // `lists` entries are { "i" => id, "t" => title, "e" => Array<String> of
    // episode uuids }, already in display order.
    //
    // `stale` names playlists whose own fetch FAILED this time round. They are
    // carried forward verbatim - keys, episodes, position in the menu and the
    // user's tick - rather than being treated as deleted.
    //
    // Only /up_next/sync can fail and still reach here; a failed
    // /user/playlist/list abandons the whole refresh. But a transient BLE
    // failure there is common and the consequence was not obvious: Up Next
    // simply was not in `lists`, so the prune below dropped it from LISTS_KEY
    // and, with it, from selLists. Read off a device log as "pc: up_next failed
    // -2", then "committing 1 list(s)", then "selectedLists=0" - the user had
    // to notice their queue had silently unticked itself and tick it again.
    function setCatalog(
        lists as Array<Dictionary<String, PersistableType>>,
        records as Array<Dictionary<String, PersistableType>>,
        stale as Array<String>
    ) as Void {
        var keep = {} as Dictionary<String, Boolean>;
        for (var i = 0; i < records.size(); i++) {
            var uuid = records[i].get("k");
            if (uuid instanceof String) {
                // A duration already learned outlives the fetch that replaces
                // the record. Most of them arrive from /user/in_progress or a
                // findbyepisode lookup rather than from the playlist entry - a
                // manual playlist entry carries no duration at all - so
                // overwriting wholesale would throw one away on every single
                // refresh and the remaining time would never settle.
                if (recordDuration(records[i] as Dictionary) == 0) {
                    setRecordDuration(records[i], getDuration(uuid));
                }
                putRecord(uuid, records[i]);
                keep.put(uuid, true);
            }
        }

        // A downloaded episode keeps its record even after it drops out of
        // every playlist - that is what lets playback survive a refresh.
        var downloaded = getIds(DOWNLOADED_KEY);
        for (var i = 0; i < downloaded.size(); i++) {
            keep.put(downloaded[i], true);
        }

        // A playlist that was not fetched keeps its episodes' records too -
        // this refresh knows nothing about them, so it is in no position to
        // call them orphans.
        for (var i = 0; i < stale.size(); i++) {
            var staleEpisodes = getIds(listEpisodesKey(stale[i]));
            for (var j = 0; j < staleEpisodes.size(); j++) {
                keep.put(staleEpisodes[j], true);
            }
        }

        // Drop records from the previous fetch that nothing references any
        // more. Storage is 128 KB in total; orphans would accumulate on every
        // single refresh.
        var previousLists = getIds(LISTS_KEY);
        for (var i = 0; i < previousLists.size(); i++) {
            var previousEpisodes = getIds(listEpisodesKey(previousLists[i]));
            for (var j = 0; j < previousEpisodes.size(); j++) {
                if (!keep.hasKey(previousEpisodes[j])) {
                    deleteRecord(previousEpisodes[j]);
                }
            }
        }

        var ids = [] as Array<String>;
        for (var i = 0; i < lists.size(); i++) {
            var id = lists[i].get("i");
            if (!(id instanceof String)) {
                continue;
            }
            var title = lists[i].get("t");
            var episodes = lists[i].get("e");

            Storage.setValue(
                listKey(id),
                { "t" => (title instanceof String) ? title : id } as Dictionary<Storage.KeyType, Storage.ValueType>
            );
            putIds(
                listEpisodesKey(id),
                (episodes instanceof Array) ? episodes as Array<String> : [] as Array<String>
            );
            ids.add(id);
        }

        // Put back any playlist this refresh could not fetch, at the position
        // it already held - which for Up Next is the top, where it is pinned.
        // Everything below reads `ids` as "the playlists that exist", so doing
        // it here is what saves both its keys and its tick.
        for (var i = 0; i < stale.size(); i++) {
            var staleId = stale[i];
            var was = previousLists.indexOf(staleId);
            if (was < 0 || ids.indexOf(staleId) >= 0) {
                continue;
            }
            var at = (was < ids.size()) ? was : ids.size();
            var merged = [] as Array<String>;
            for (var j = 0; j < ids.size(); j++) {
                if (j == at) {
                    merged.add(staleId);
                }
                merged.add(ids[j]);
            }
            if (at >= ids.size()) {
                merged.add(staleId);
            }
            ids = merged;
            System.println("catalog: carried " + staleId + " forward, not fetched this time");
        }

        // Playlists that have gone away take their keys with them - and their
        // selection, or a deleted playlist would keep queueing downloads.
        var selected = getSelectedLists();
        var stillSelected = [] as Array<String>;
        for (var i = 0; i < previousLists.size(); i++) {
            if (ids.indexOf(previousLists[i]) < 0) {
                Storage.deleteValue(listKey(previousLists[i]));
                Storage.deleteValue(listEpisodesKey(previousLists[i]));
            }
        }
        for (var i = 0; i < selected.size(); i++) {
            if (ids.indexOf(selected[i]) >= 0) {
                stillSelected.add(selected[i]);
            }
        }
        putIds(SELECTED_LISTS_KEY, stillSelected);

        putIds(LISTS_KEY, ids);

        // Before the resequence, so what it re-lays is only what survives.
        reconcileDownloads();

        // A refresh is the only way new ordering information reaches the
        // watch, so it is the moment to act on it - a queue reordered on the
        // phone means nothing until what is already downloaded is re-laid to
        // match. Strictly after LISTS_KEY is written: it reads the playlists back.
        resequenceDownloads();
    }

    // Let go of downloads that no selected playlist wants any more.
    //
    // The everyday case is finishing an episode on the phone: it drops off Up
    // Next, the next refresh brings back a shorter queue, and the copy on the
    // watch has nothing left pointing at it. Without this it stays for good -
    // unticking Up Next would not catch it either, because
    // removeListDownloads() walks the playlist's CURRENT episodes and this one
    // is no longer among them. Short of playing it through on the watch or
    // Reset everything, there was no way to be rid of it.
    //
    // Retire now, delete the bytes later: retireDownload() is pure Storage and
    // safe at any moment, while the audio goes through the purge queue so it
    // meets the same guards as a finished episode - never deleted under a
    // player that still holds it, never deleted before its position has been
    // reported. See purgeFinished().
    //
    // THREE THINGS MUST BE TRUE BEFORE ANY OF THIS IS SAFE:
    //
    // 1. Something is selected. With nothing ticked every download looks like
    //    an orphan, and a user who unticks everything to stop syncing would
    //    lose the lot. That is a legitimate state, not a signal.
    // 2. The playlists were actually fetched. A failed list call must not read
    //    as an empty list - setCatalog()'s caller carries a stale playlist
    //    forward verbatim for exactly this reason, so its episodes are still
    //    in le<id> here and still count as wanted.
    // 3. The episode is genuinely in no selected playlist. An episode in both
    //    Up Next and a manual playlist survives leaving one of them.
    function reconcileDownloads() as Void {
        var selected = getSelectedLists();
        if (selected.size() == 0) {
            return;
        }

        var wanted = {} as Dictionary<String, Boolean>;
        for (var i = 0; i < selected.size(); i++) {
            var episodes = getListEpisodeIds(selected[i]);
            for (var j = 0; j < episodes.size(); j++) {
                wanted.put(episodes[j], true);
            }
        }

        var downloaded = getIds(DOWNLOADED_KEY);
        var dropped = 0;
        for (var i = 0; i < downloaded.size(); i++) {
            var uuid = downloaded[i];
            if (wanted.hasKey(uuid)) {
                continue;
            }
            retireDownload(uuid);
            markForPurge(uuid);
            dropped++;
        }

        if (dropped > 0) {
            System.println("catalog: released " + dropped +
                " download(s) no selected playlist still wants");
        }
    }

    function getListIds() as Array<String> {
        return getIds(LISTS_KEY);
    }

    function getListTitle(id as String) as String {
        var stored = Storage.getValue(listKey(id));
        if (stored instanceof Dictionary) {
            var title = stored.get("t");
            if (title instanceof String) {
                return title;
            }
        }
        return id;
    }

    function getListEpisodeIds(id as String) as Array<String> {
        return getIds(listEpisodesKey(id));
    }

    // --- which playlists the user ticked ---

    function getSelectedLists() as Array<String> {
        return getIds(SELECTED_LISTS_KEY);
    }

    function isListSelected(id as String) as Boolean {
        return getSelectedLists().indexOf(id) >= 0;
    }

    function setListSelected(id as String, selected as Boolean) as Void {
        var ids = getSelectedLists();
        var at = ids.indexOf(id);
        if (selected && at < 0) {
            ids.add(id);
        } else if (!selected && at >= 0) {
            ids.remove(id);
        }
        putIds(SELECTED_LISTS_KEY, ids);
    }

    // Unticking a playlist deletes what it put on the device - but only the
    // episodes no OTHER still-selected playlist also wants. An episode can sit in
    // Up Next and a playlist at the same time, and deleting its audio because
    // one of them was unticked would strand the other playlist's download.
    //
    // Call this AFTER updating the selection, so `id` is already out of it.
    function removeListDownloads(id as String) as Void {
        var episodes = getListEpisodeIds(id);
        var selected = getSelectedLists();

        for (var i = 0; i < episodes.size(); i++) {
            var uuid = episodes[i];
            var wantedElsewhere = false;
            for (var j = 0; j < selected.size(); j++) {
                if (getListEpisodeIds(selected[j]).indexOf(uuid) >= 0) {
                    wantedElsewhere = true;
                    break;
                }
            }
            if (!wantedElsewhere) {
                removeDownload(uuid);
            }
        }
    }

    // --- what actually made it onto the device ---

    // The runtime type of a ContentRef id is NOT guaranteed. The docs imply a
    // String, but the device hands back Numbers (e.g. -2030043135). So ids
    // are round-tripped as whatever the SDK gave us rather than coerced - a
    // cast to String here would be an unchecked lie that works right up until
    // it does not.
    function getRefIds() as Dictionary<String, PersistableType> {
        var stored = Storage.getValue(REF_IDS_KEY);
        if (stored instanceof Dictionary) {
            return stored as Dictionary<String, PersistableType>;
        }
        return {} as Dictionary<String, PersistableType>;
    }

    // Record a finished download: the ref id, the episode's own record, and
    // its place in the download order. The record is rewritten here on purpose
    // - it may exist only because of the current fetch, which is replaced
    // wholesale on the next refresh, and playback must not depend on that.
    // DOWNLOADED_KEY's order is canonical: the playback menu and the content
    // iterator both walk it, so an index means the same thing to both.
    function recordDownload(track as Track, refId as PersistableType) as Void {
        var refIds = getRefIds();
        refIds.put(track.key, refId);
        Storage.setValue(REF_IDS_KEY, refIds as Dictionary<Storage.KeyType, Storage.ValueType>);

        putRecord(track.key, toRecord(track));

        var ids = getIds(DOWNLOADED_KEY);
        if (ids.indexOf(track.key) < 0) {
            ids.add(track.key);
            putIds(DOWNLOADED_KEY, ids);
        }
    }

    // Delete one episode's audio from the device and forget it. Unticking a
    // track in the sync menu only used to change the selection, which left the
    // audio on the device and the id in Storage - so the episode kept showing
    // up in the playback list. Note that ids get RECYCLED across syncs, so a
    // stale id left behind can later resolve to a different episode's audio.
    function removeDownload(key as String) as Void {
        var refIds = getRefIds();
        var refId = refIds.get(key);
        if (refId == null) {
            return;
        }

        Toybox.Media.deleteCachedItem(
            new Toybox.Media.ContentRef(refId as Object, Toybox.Media.CONTENT_TYPE_AUDIO)
        );
        refIds.remove(key);
        Storage.setValue(REF_IDS_KEY, refIds as Dictionary<Storage.KeyType, Storage.ValueType>);

        var ids = getIds(DOWNLOADED_KEY);
        if (ids.indexOf(key) >= 0) {
            ids.remove(key);
            putIds(DOWNLOADED_KEY, ids);
        }

        // The record goes with the audio. Nothing else needs it: a playlist
        // that still lists this episode writes the record again on the next
        // refresh, and getPendingTracks() works off the playlists, not off
        // records left behind.
        deleteRecord(key);
    }

    // Forget what has been downloaded. Pair this with Media.resetContentCache(),
    // which wipes the audio itself - leaving one without the other strands
    // ContentRef ids that no longer resolve.
    // Wipe everything this app owns and go back to a first-install state.
    //
    // Storage.clearValues() rather than a list of deleteValue() calls, on
    // purpose: this module owns a dozen fixed keys plus one per episode and
    // two per playlist, and a hand-maintained list is a list that goes stale. It
    // did - clearSelection() went on deleting the legacy per-episode key long
    // after playlist selection had moved to another one, so the reset silently
    // left every playlist ticked and the next back-out re-synced the lot.
    //
    // Pair it with Media.resetContentCache(), which wipes the audio: either
    // one alone leaves ContentRef ids resolving to nothing, or audio on the
    // device that no menu can reach.
    //
    // The account goes too - email, password and token - so the next launch
    // asks who you are, exactly as a first install does. That is deliberate: a
    // reset should leave nothing behind to wonder about. Signing out WITHOUT
    // losing the downloads is a separate row, on the account menu.
    function reset() as Void {
        Storage.clearValues();
        System.println("catalog: storage cleared");
    }

    // The selected playlists in DISPLAY order - Up Next pinned first, then the
    // playlists as the API served them - rather than in whatever order the
    // user happened to tick them, which is what SELECTED_LISTS_KEY records.
    //
    // This is the app's one definition of "playlist order", and both the download
    // queue and resequenceDownloads() read it, so the order episodes arrive in
    // and the order they are played in cannot drift apart. It also decides
    // which playlist an episode belongs to when several claim it: the first playlist
    // to name it wins, and Up Next being first means the queue's position is
    // the one that counts.
    function getSelectedListsInOrder() as Array<String> {
        var selected = getSelectedLists();
        var ordered = [] as Array<String>;
        var all = getIds(LISTS_KEY);
        for (var i = 0; i < all.size(); i++) {
            if (selected.indexOf(all[i]) >= 0) {
                ordered.add(all[i]);
            }
        }
        return ordered;
    }

    // Everything the selected playlists want that is not on the device yet, in
    // playlist order and de-duplicated - an episode in both Up Next and a playlist
    // must be downloaded once, not twice.
    //
    // The order matters beyond tidiness: a sync abandons the rest of its queue
    // at the first failure, and an episode is minutes of Wi-Fi, so whatever is
    // at the top of Up Next should be the thing that lands first.
    //
    // Both the sync delegate's isSyncNeeded() and the configure menu's
    // back-out read this, so the two can never disagree about whether a sync
    // is worth starting.
    function getPendingTracks() as Array<Track> {
        var refIds = getRefIds();
        var selected = getSelectedListsInOrder();
        var seen = {} as Dictionary<String, Boolean>;
        var wanted = [] as Array<String>;

        for (var i = 0; i < selected.size(); i++) {
            var listId = selected[i];

            // Up Next is a deliberate queue, not a standing collection: an
            // episode put back on it AFTER being finished here is a request to
            // hear it again, so the "already listened to" guard does not
            // apply. A manual playlist is different - it keeps listing what it
            // always listed, which is not a fresh instruction, so there the
            // guard stays and stops auto-delete and the next sync fighting
            // each other forever.
            //
            // Order-independent: a finished episode skipped while walking a
            // playlist is not added to `seen`, so Up Next still picks it up
            // however the two happen to be ordered.
            var honourFinished = !listId.equals(UP_NEXT_ID);

            var episodes = getListEpisodeIds(listId);
            for (var j = 0; j < episodes.size(); j++) {
                var uuid = episodes[j];
                if (seen.hasKey(uuid) || refIds.hasKey(uuid)) {
                    continue;
                }
                if (honourFinished && isFinished(uuid)) {
                    continue;
                }
                seen.put(uuid, true);
                wanted.add(uuid);
            }
        }

        return tracksFor(wanted);
    }

    function hasPendingDownloads() as Boolean {
        return getPendingTracks().size() > 0;
    }

    // Episodes that have been downloaded, in download order. Read from
    // DOWNLOADED_KEY rather than the fetched playlists so that refreshing the
    // catalogue - or failing to refresh it, offline - cannot disturb what is
    // playable or renumber it underneath the iterator.
    function getDownloadedTracks() as Array<Track> {
        var refIds = getRefIds();
        var ids = getIds(DOWNLOADED_KEY);
        var kept = [] as Array<String>;
        for (var i = 0; i < ids.size(); i++) {
            if (refIds.hasKey(ids[i])) {
                kept.add(ids[i]);
            }
        }
        return tracksFor(kept);
    }

    // --- playback position ---
    //
    // The system does NOT remember where a track got to: getPlaybackStartPosition()
    // on a cached Content is always 0. So resume is entirely ours to
    // implement - positions are banked here during playback and handed back
    // to Media.ActiveContent when the iterator is built.
    //
    // One value holds them all: ~45 bytes per entry against an 8 KB limit is
    // roughly 180 episodes, far more than MAX_EPISODES.

    function getPositions() as Dictionary<String, PersistableType> {
        var stored = Storage.getValue(POSITIONS_KEY);
        if (stored instanceof Dictionary) {
            return stored as Dictionary<String, PersistableType>;
        }
        return {} as Dictionary<String, PersistableType>;
    }

    function getPosition(uuid as String) as Number {
        var seconds = getPositions().get(uuid);
        if (seconds instanceof Number) {
            return seconds;
        }
        return 0;
    }

    // A position of 0 is stored as absent rather than as a zero, so a finished
    // or restarted episode does not keep an entry alive forever.
    function setPosition(uuid as String, seconds as Number) as Void {
        var positions = getPositions();
        if (seconds <= 0) {
            if (!positions.hasKey(uuid)) {
                return;
            }
            positions.remove(uuid);
        } else {
            positions.put(uuid, seconds);
        }
        Storage.setValue(POSITIONS_KEY, positions as Dictionary<Storage.KeyType, Storage.ValueType>);
    }

    // --- the outbox ---
    //
    // An episode is dirty only when THIS WATCH moved its position. That is the
    // whole guard against clobbering the phone: the watch is offline for long
    // stretches, so it routinely holds a position that is stale but newer in
    // wall-clock terms, and pushing one it merely read from the server would
    // overwrite progress made elsewhere. A position pulled from the server is
    // never dirty and is never pushed back.
    //
    // Entries survive a failed push - they are cleared only when the server
    // confirms - so a flush that dies with the app is retried on the next one.

    function getDirtyKeys() as Array<String> {
        return getIds(DIRTY_KEY);
    }

    function isDirty(uuid as String) as Boolean {
        return getDirtyKeys().indexOf(uuid) >= 0;
    }

    // The podcast uuid of everything currently in the outbox. An entry is
    // written here at the moment the episode is queued and removed when the
    // server confirms it, so it lives exactly as long as the report does -
    // which is longer than the episode's record survives once auto-delete has
    // it. See getPodcastFor().
    function getOutboxPodcasts() as Dictionary<String, PersistableType> {
        var stored = Storage.getValue(OUTBOX_PODCAST_KEY);
        if (stored instanceof Dictionary) {
            return stored as Dictionary<String, PersistableType>;
        }
        return {} as Dictionary<String, PersistableType>;
    }

    function markDirty(uuid as String) as Void {
        // Remembered before the early return, not after it: an episode queued
        // by an older build has no entry here, and a second markDirty() - a
        // pause after a skip, say - is the chance to fill it in.
        var podcast = getPodcastFor(uuid);
        if (podcast.length() > 0) {
            var outbox = getOutboxPodcasts();
            if (!podcast.equals(outbox.get(uuid))) {
                outbox.put(uuid, podcast);
                Storage.setValue(
                    OUTBOX_PODCAST_KEY,
                    outbox as Dictionary<Storage.KeyType, Storage.ValueType>
                );
            }
        }

        var ids = getDirtyKeys();
        if (ids.indexOf(uuid) >= 0) {
            return;
        }
        ids.add(uuid);
        putIds(DIRTY_KEY, ids);
    }

    function clearDirty(uuid as String) as Void {
        var outbox = getOutboxPodcasts();
        if (outbox.hasKey(uuid)) {
            outbox.remove(uuid);
            Storage.setValue(
                OUTBOX_PODCAST_KEY,
                outbox as Dictionary<Storage.KeyType, Storage.ValueType>
            );
        }

        var ids = getDirtyKeys();
        if (ids.indexOf(uuid) < 0) {
            return;
        }
        ids.remove(uuid);
        putIds(DIRTY_KEY, ids);
    }

    // Finishing an episode is reported as a STATUS, never as a position.
    //
    // A finished episode has no meaningful position - it is at the end - and
    // reporting the 0 we store locally would tell the server "back to the
    // start", resetting the episode to unplayed everywhere else. Pocket Casts
    // wants status 3 (1=unplayed, 2=playing, 3=played) instead.
    function getPlayedKeys() as Array<String> {
        return getIds(PLAYED_KEY);
    }

    function isPlayed(uuid as String) as Boolean {
        return getPlayedKeys().indexOf(uuid) >= 0;
    }

    // Everything that follows from an episode being listened to right through:
    // report it as played, never download it again, and reclaim its audio.
    function markPlayed(uuid as String) as Void {
        var ids = getPlayedKeys();
        if (ids.indexOf(uuid) < 0) {
            ids.add(uuid);
            putIds(PLAYED_KEY, ids);
        }
        markDirty(uuid);
        markFinished(uuid);

        if (AUTO_DELETE_PLAYED) {
            markForPurge(uuid);

            // Off the playable list straight away. The audio deletion has to
            // wait for a moment the player is not holding it, but nothing
            // stops the row going now - and it has to, because the audio
            // deletion is what used to be relied on to remove it and that can
            // be deferred for the whole life of the process.
            retireDownload(uuid);
        }
    }

    // Completed on this watch. Kept out of getPendingTracks() so the next sync
    // does not simply download it again - which it otherwise would, forever,
    // for any episode in a manual playlist. (Up Next self-heals: reporting the
    // episode played removes it server-side.)
    function isFinished(uuid as String) as Boolean {
        return getIds(FINISHED_KEY).indexOf(uuid) >= 0;
    }

    function markFinished(uuid as String) as Void {
        var ids = getIds(FINISHED_KEY);
        if (ids.indexOf(uuid) >= 0) {
            return;
        }
        ids.add(uuid);
        while (ids.size() > MAX_FINISHED) {
            ids = ids.slice(1, null);
        }
        putIds(FINISHED_KEY, ids);
    }

    // --- deferred deletion ---
    //
    // Two halves, deliberately split, because they are safe at very different
    // moments.
    //
    // Taking the episode OFF THE LIST is pure Storage and safe immediately, so
    // markPlayed() does it: the playback hub and the next iterator both read
    // DOWNLOADED_KEY, and the running iterator was built from a snapshot and
    // is unaffected. The ref id is deliberately kept, which also keeps
    // getPendingTracks() from re-downloading an Up Next episode in the window
    // before the server drops it from the queue.
    //
    // DELETING THE AUDIO is not. SONG_EVENT_COMPLETE arrives while the player
    // still holds that Content and the iterator still has it in _contents;
    // pulling its cache entry out from under them is the same move that
    // rebooted the watch in rule 2. So completion only marks it and
    // purgeFinished() does the work later, skipping anything the player is
    // still walking.
    //
    // purgeFinished() used to run from onStart() alone, and that was the bug:
    // onStart() fires once per PROCESS, not once per mode. Read off a device
    // log, a whole session - playback, refresh, sync, playback, refresh again -
    // produced a single "build" line, so an episode finished during it was
    // still listed and still on the device hours later. It now runs at every
    // non-playback entry point as well.

    function markForPurge(uuid as String) as Void {
        var ids = getIds(PURGE_KEY);
        if (ids.indexOf(uuid) >= 0) {
            return;
        }
        ids.add(uuid);
        putIds(PURGE_KEY, ids);
    }

    // Re-lay DOWNLOADED_KEY into playlist order.
    //
    // The order episodes are DOWNLOADED in is only ever the order they were
    // wanted in on the day they were fetched: recordDownload() appends, and
    // nothing ever moved anything afterwards. So Up Next reordered on the
    // phone did not reach the watch, and - more commonly - an episode synced
    // today landed after one synced last week however far up the queue it sat.
    // The playback hub and the content iterator both walk this array, so the
    // watch played the queue in an order the queue had stopped being in.
    //
    // Rebuilt against the playlists as they now stand: every one in display order
    // (Up Next first), each playlist's episodes in the order the API served them,
    // first playlist to claim an episode wins. Anything downloaded that no longer
    // belongs to any playlist keeps its relative order and goes at the end - a
    // record outliving its playlist is a supported state, and it must not be
    // dropped here just because nothing lists it.
    //
    // Safe to call at any moment, including mid-playback. A live iterator was
    // built from a snapshot in its own constructor and never re-reads this,
    // and the playback hub resolves the row the user picked by UUID rather
    // than by index, so nothing is renumbered underneath anything.
    function resequenceDownloads() as Void {
        var downloaded = getIds(DOWNLOADED_KEY);
        if (downloaded.size() < 2) {
            return;
        }

        var ordered = [] as Array<String>;
        var placed = {} as Dictionary<String, Boolean>;

        var lists = getIds(LISTS_KEY);
        for (var i = 0; i < lists.size(); i++) {
            var episodes = getIds(listEpisodesKey(lists[i]));
            for (var j = 0; j < episodes.size(); j++) {
                var uuid = episodes[j];
                if (placed.hasKey(uuid) || downloaded.indexOf(uuid) < 0) {
                    continue;
                }
                placed.put(uuid, true);
                ordered.add(uuid);
            }
        }

        for (var i = 0; i < downloaded.size(); i++) {
            if (!placed.hasKey(downloaded[i])) {
                ordered.add(downloaded[i]);
            }
        }

        // Storage writes are not free and this runs on every refresh, so say
        // nothing and write nothing when the order already agrees.
        var changed = false;
        for (var i = 0; i < ordered.size(); i++) {
            if (!ordered[i].equals(downloaded[i])) {
                changed = true;
                break;
            }
        }
        if (!changed) {
            return;
        }

        putIds(DOWNLOADED_KEY, ordered);
        System.println("catalog: resequenced " + ordered.size() + " downloaded episode(s) into playlist order");
    }

    // Drop an episode from the playable list without touching its audio or its
    // ref id, both of which purgeFinished() still needs.
    function retireDownload(key as String) as Void {
        var ids = getIds(DOWNLOADED_KEY);
        if (ids.indexOf(key) < 0) {
            return;
        }
        ids.remove(key);
        putIds(DOWNLOADED_KEY, ids);
        System.println("catalog: retired " + key + " from the playable list");
    }

    // The episodes the media player is currently walking.
    //
    // In memory only, and deliberately so - it describes THIS process's
    // player, and a stale answer written to Storage would be worse than no
    // answer at all. The iterator publishes its contents here when it is
    // built; the delegate clears it when the player stops.
    var _playerKeys as Array<String> = [] as Array<String>;

    function setPlayerKeys(keys as Array<String>) as Void {
        _playerKeys = keys;
    }

    function clearPlayerKeys() as Void {
        _playerKeys = [] as Array<String>;
    }

    function playerHolds(uuid as String) as Boolean {
        return _playerKeys.indexOf(uuid) >= 0;
    }

    // Whether the sync now running was started from our own menu, and so has
    // one of our views sitting underneath the system's sync screen for the
    // delegate to switch out when it finishes.
    //
    // In memory only, for the same reason as _playerKeys and a sharper one:
    // this is a claim about THIS process's view stack. The SDK describes
    // startSync() as exiting the app and relaunching it in sync mode, which is
    // not what this device does - a whole session produces one onStart() - but
    // a device that does relaunch has no view stack to switch, and a flag in
    // Storage would survive to insist otherwise. In memory it cannot: a
    // relaunch loses it, which is exactly right.
    //
    // The system can also start a sync on its own through isSyncNeeded(), with
    // no UI in play at all. This is what tells those two apart.
    var _syncFromMenu as Boolean = false;

    function setSyncFromMenu(fromMenu as Boolean) as Void {
        _syncFromMenu = fromMenu;
    }

    // Read once and cleared, so a system-initiated sync later in the same
    // process cannot inherit the answer.
    function takeSyncFromMenu() as Boolean {
        var fromMenu = _syncFromMenu;
        _syncFromMenu = false;
        return fromMenu;
    }

    // Reclaim the audio of everything finished earlier, except whatever the
    // player still has in hand - that stays queued for the next attempt rather
    // than being deleted underneath it.
    function purgeFinished() as Void {
        var ids = getIds(PURGE_KEY);
        if (ids.size() == 0) {
            return;
        }

        var deferred = [] as Array<String>;
        var purged = 0;
        var unreported = 0;
        for (var i = 0; i < ids.size(); i++) {
            if (playerHolds(ids[i])) {
                deferred.add(ids[i]);
                continue;
            }
            // Finished here, and the server has not been told yet. Deleting
            // now takes the ref id with it, and the ref id is the only thing
            // keeping getPendingTracks() off an episode that is still sitting
            // in the account's Up Next - so the next sync fetches ~37 MB of
            // something already listened to. That is exactly what happened on
            // device when the phone was out of reach at the moment it
            // finished. The bytes wait for the report; the row has already
            // gone, so all this costs is cache on a ~7.1 GB store.
            if (isPlayed(ids[i]) && isDirty(ids[i])) {
                deferred.add(ids[i]);
                unreported++;
                continue;
            }
            removeDownload(ids[i]);
            purged++;
        }

        if (deferred.size() == 0) {
            Storage.deleteValue(PURGE_KEY);
        } else {
            putIds(PURGE_KEY, deferred);
        }
        System.println("catalog: purged " + purged + " episode(s), " +
            (deferred.size() - unreported) + " still held by the player, " +
            unreported + " awaiting a played report");
    }

    // --- reclaiming audio that nothing points at any more ---
    //
    // Every route to an episode's audio in this module runs THROUGH refIds:
    // removeDownload() looks the ref id up by uuid, and there is no other way
    // in. So the moment a uuid => ref id entry goes missing, the bytes behind
    // it become unaddressable - no menu lists them, purgeFinished() cannot
    // find them, and they sit on the device until Reset everything or an
    // uninstall. Recording a download is three separate Storage writes
    // (recordDownload), so dying between the audio landing and the first of
    // them is enough to strand ~35 MB, and so is any future version that
    // changes a key.
    //
    // Media.getContentRefIter() is the way back in. It walks the media cache
    // itself - "all cached media on the system for the calling app" - so it
    // answers what is ACTUALLY on the watch rather than what Storage believes
    // is, and anything it returns that refIds does not name is ours and
    // orphaned.
    //
    // API 3.0.0, far below this app's 5.0.0 floor, and per getProviderIconInfo
    // that means nothing on its own. Checked: all 57 products in manifest.xml
    // declare BOTH getContentRefIter and ContentRefIterator in their SDK
    // <id>.api.debug.xml, so unlike startSync2/showToast this one really is
    // universal. Guarded regardless, because the check is free and the export
    // build cannot catch its absence.
    //
    // Returns the number of orphans deleted, or -1 when the sweep declined to
    // run. `force` skips the once-a-day marker and nothing else - the safety
    // guards are not optional.
    function reclaimOrphans(force as Boolean) as Number {
        if (!(Media has :getContentRefIter)) {
            return -1;
        }

        // Never underneath the player. Deleting a cache entry out from under a
        // Content the player is holding is the move that rebooted the watch in
        // rule 2, and _playerKeys is the same declaration purgeFinished()
        // already reads to avoid it.
        if (_playerKeys.size() > 0) {
            return -1;
        }

        var now = Time.now().value();
        if (!force) {
            var last = Storage.getValue(ORPHAN_CHECK_KEY);
            // now < last means the clock moved backwards; treat that as due
            // rather than letting it wedge the sweep off for however long the
            // jump was.
            if (last instanceof Number && now >= last && now - last < ORPHAN_CHECK_INTERVAL) {
                return -1;
            }
        }

        var refIds = getRefIds();

        // Refuse to act on a refIds that disagrees with the rest of Storage.
        //
        // An empty dictionary is a legitimate state - the watch holds nothing,
        // so everything in the cache really IS an orphan, which is precisely
        // the case worth recovering - but it is also what getRefIds() answers
        // when the read gives back something that is not a Dictionary. What
        // tells those apart is the rest of the catalog: if anything still
        // claims to be downloaded or queued for purge, the empty answer is
        // inconsistent, and that is not the moment to delete every episode on
        // the watch.
        if (refIds.size() == 0 &&
            (getIds(DOWNLOADED_KEY).size() > 0 || getIds(PURGE_KEY).size() > 0)) {
            System.println("orphans: refIds empty but the catalog is not - skipping");
            return -1;
        }

        // Ref ids are Numbers on this device and Strings per the docs (rule 6),
        // so they are matched as strings - exactly what findKeyForRefId() does
        // for the same reason.
        var known = {} as Dictionary<String, Boolean>;
        var keys = refIds.keys();
        for (var i = 0; i < keys.size(); i++) {
            var stored = refIds.get(keys[i]);
            if (stored != null) {
                known.put(stored.toString(), true);
            }
        }

        // Collected first, deleted afterwards. Pulling an entry out of the
        // cache while its own iterator is still walking it is not something
        // the SDK says anything about, and separating the two costs one small
        // array.
        var orphans = [] as Array<Object>;
        var seen = 0;
        // getContentRefIter() is TYPED non-null and answers null when the
        // cache is EMPTY - not documented anywhere, measured. It is the same
        // lie next() tells below and getCachedContentObj() tells in rule 3,
        // one level up.
        //
        // Reproduced in the simulator against a wiped device filesystem, after
        // it crashed a fenix 7X on every launch: uninstall + reinstall clears
        // both the media cache AND Storage, so the once-a-day marker is gone
        // and the sweep runs immediately with nothing to sweep. Since this
        // runs from all four entry points, the app could not be opened at all.
        var iter = Media.getContentRefIter({
            :contentType => Media.CONTENT_TYPE_AUDIO,
            :shuffle => false
        }) as Media.ContentRefIterator?;
        if (iter == null) {
            // Nothing cached is a clean sweep, not a declined one: stamp the
            // marker so a fresh install does not re-ask on every entry point.
            System.println("orphans: nothing in the media cache");
            Storage.setValue(ORPHAN_CHECK_KEY, now);
            return 0;
        }

        // next() is TYPED non-null and DOCUMENTED to answer null once the
        // cache runs out - the same lie getCachedContentObj() tells in rule 3.
        var ref = iter.next() as Media.ContentRef?;
        while (ref != null && orphans.size() < MAX_ORPHAN_DELETES) {
            seen++;
            var id = ref.getId() as Object?;
            if (id != null && !known.hasKey(id.toString())) {
                orphans.add(id);
            }
            ref = iter.next() as Media.ContentRef?;
        }

        for (var i = 0; i < orphans.size(); i++) {
            Media.deleteCachedItem(
                new Media.ContentRef(orphans[i], Media.CONTENT_TYPE_AUDIO)
            );
        }

        // A sweep that filled its quota stopped early and has probably not
        // seen the whole cache, so the marker stays unstamped and the next
        // entry point carries on where this one left off.
        if (orphans.size() < MAX_ORPHAN_DELETES) {
            Storage.setValue(ORPHAN_CHECK_KEY, now);
        }

        if (orphans.size() > 0) {
            var stats = Media.getCacheStatistics();
            System.println("orphans: deleted " + orphans.size() + " of " + seen +
                " cached item(s) refIds does not name; cache now " +
                stats.size + " of " + stats.capacity + " bytes");
        } else {
            System.println("orphans: " + seen + " cached item(s), all accounted for");
        }
        return orphans.size();
    }

    function clearPlayed(uuid as String) as Void {
        var ids = getPlayedKeys();
        if (ids.indexOf(uuid) < 0) {
            return;
        }
        ids.remove(uuid);
        putIds(PLAYED_KEY, ids);
    }

    // Fold a position the server reports into what we hold locally.
    //
    // Furthest-along wins. It is symmetric, needs no clock comparison between
    // a watch and a server, and its only failure mode is forgetting that you
    // deliberately re-listened to an earlier part - which costs one rewind,
    // where the opposite rule costs you your place in a 40 minute episode.
    //
    // A server position that wins also clears the dirty flag: whatever the
    // watch had is now superseded, so pushing it back would undo the merge.
    function mergeServerPosition(uuid as String, serverSeconds as Number) as Void {
        // "Finished here" outranks any position the server still holds - the
        // server simply has not been told yet. Merging would drop the dirty
        // flag and lose the played report entirely.
        //
        // But only while there IS a report outstanding. markPlayed() and
        // onPushed() set and clear PLAYED_KEY together with the outbox entry,
        // so "played with nothing queued to report" cannot arise on its own -
        // it is the signature of a report that was dropped, and it is poison
        // left alone: the flag refuses every server position for that episode
        // for good, so the watch starts it at 0 and keeps doing so however many
        // times the server says otherwise. That is exactly the state one watch
        // was left in - the server holding 876s, every refresh reading it back,
        // every refresh refusing it. A stranded flag is cleared and the merge
        // goes ahead.
        if (isPlayed(uuid)) {
            if (isDirty(uuid)) {
                return;
            }
            System.println("catalog: " + uuid + " flagged played with nothing to report, clearing");
            clearPlayed(uuid);
        }
        if (serverSeconds <= getPosition(uuid)) {
            return;
        }
        setPosition(uuid, serverSeconds);
        clearDirty(uuid);
        System.println("merge: " + uuid + " server ahead at " + serverSeconds + "s");
    }

    // Map a ContentRef id back to the episode it belongs to. The media player
    // reports playback events by ref id, and nothing else in the app is keyed
    // that way.
    //
    // Compared as strings deliberately: rule 6 says the runtime type of a ref
    // id is not guaranteed - Numbers on this device, String per the docs - and
    // this stays correct either way.
    function findKeyForRefId(refId as Object?) as String? {
        if (refId == null) {
            return null;
        }
        var wanted = refId.toString();
        var refIds = getRefIds();
        var keys = refIds.keys();
        for (var i = 0; i < keys.size(); i++) {
            var key = keys[i];
            var stored = refIds.get(key);
            if (stored != null && stored.toString().equals(wanted) && key instanceof String) {
                return key;
            }
        }
        return null;
    }

    // --- the loop breaker ---
    //
    // Backing out of the sync menu starts a sync when something is pending,
    // and a sync that finishes without shifting anything off the pending list
    // therefore starts another one the moment the user backs out again. That
    // is an endless loop with no way out on the watch.
    //
    // So a sync that makes NO progress raises this flag, and it suppresses the
    // automatic re-sync exactly once. The user still gets back to the menu and
    // can retry deliberately; what they do not get is the watch deciding to
    // retry forever on their behalf.
    function isSyncBlocked() as Boolean {
        var blocked = Storage.getValue(SYNC_BLOCK_KEY);
        return blocked instanceof Boolean && blocked;
    }

    function setSyncBlocked(blocked as Boolean) as Void {
        if (blocked) {
            Storage.setValue(SYNC_BLOCK_KEY, true);
        } else {
            Storage.deleteValue(SYNC_BLOCK_KEY);
        }
    }

    // Why the last sync failed, carried across app invocations so the sync
    // menu can say so. Without this the suppressed retry is invisible: the
    // user backs out, nothing happens, and there is nothing on screen to
    // explain it. Cleared by a sync that succeeds.
    function getSyncError() as String? {
        var stored = Storage.getValue(SYNC_ERROR_KEY);
        if (stored instanceof String) {
            return stored;
        }
        return null;
    }

    function setSyncError(message as String?) as Void {
        if (message == null) {
            Storage.deleteValue(SYNC_ERROR_KEY);
        } else {
            Storage.setValue(SYNC_ERROR_KEY, message);
        }
    }

    // The single predicate for "is a sync worth starting". Both
    // SyncDelegate.isSyncNeeded() and the sync menu's back-out read THIS, not
    // hasPendingDownloads() directly, so the two can never disagree.
    function shouldSync() as Boolean {
        return hasPendingDownloads() && !isSyncBlocked();
    }

    // Dump the whole decision state. On device this is the only diagnostic
    // channel there is, and every question about the sync loop is answered by
    // these five numbers.
    function logState(tag as String) as Void {
        var pending = getPendingTracks();
        System.println(Log.stamp() + " " + tag + ": lists=" + getListIds().size() +
            " downloaded=" + getIds(DOWNLOADED_KEY).size() +
            " selectedLists=" + getSelectedLists().size() +
            " refIds=" + getRefIds().size() +
            " pending=" + pending.size() +
            " blocked=" + isSyncBlocked());
        for (var i = 0; i < pending.size(); i++) {
            System.println(tag + ": PENDING " + pending[i].key);
        }
    }
}
