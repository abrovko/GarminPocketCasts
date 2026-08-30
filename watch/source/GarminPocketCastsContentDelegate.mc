import Toybox.Lang;
import Toybox.Media;
import Toybox.System;

// This class handles events from the system's media player.
//
// NOTE on the callback signatures below: the template (and the SDK docs)
// declare these as `Object` / `SongEvent` / `Number or PlaybackPosition`.
// With type checking on, those declarations become runtime assertions, and
// the values the player actually passes do not satisfy them - onSong() threw
// "Unexpected Type Error" on the first playback event, which killed the app
// and made the media player skip straight through every track. They are
// deliberately widened to Object? so no assertion can fire.
class GarminPocketCastsContentDelegate extends Media.ContentDelegate {

    // Index into Catalog.getDownloadedTracks() to start playback at. This is
    // the value handed to Media.startPlayback() by the playback config menu,
    // and comes back through GarminPocketCastsApp.getContentDelegate().
    private var _startIndex as Number;

    // One iterator, reused. Building a new one per call re-runs
    // getCachedContentObj() for every track and hands the player a fresh set
    // of system-owned media objects mid-playback.
    private var _iterator as GarminPocketCastsContentIterator?;


    // Best-effort reporting from inside playback. Set to false to confine
    // reporting to sync sessions, which is where it is guaranteed to work.
    static const FLUSH_DURING_PLAYBACK = true;

    // Never more often than this. Positions are worth a few hundred bytes over
    // BLE, not a request every time the user taps pause.
    static const FLUSH_EVERY_MS = 60000;

    private var _client as PocketCastsClient?;
    private var _lastFlush as Number = 0;

    // The episode whose SONG_EVENT_START was last seen - i.e. the one the
    // player is actually on. Kept because the player does NOT report the end
    // of a track that was skipped past; see onLeftCurrent().
    private var _currentKey as String?;

    function initialize(startIndex as Number) {
        ContentDelegate.initialize();
        _startIndex = startIndex;
    }

    // Returns an iterator that is used by the system to play songs.
    function getContentIterator() as ContentIterator? {
        System.println(Log.stamp() + " getContentIterator start=" + _startIndex);
        var iterator = _iterator;
        if (iterator == null) {
            iterator = new GarminPocketCastsContentIterator(_startIndex);
            _iterator = iterator;
        } else if (iterator.isExhausted()) {
            // Nothing left to hand over - see resetContentIterator().
            System.println("getContentIterator: queue exhausted, no content");
            return null;
        }
        iterator.publishKeys();
        return iterator;
    }

    // Called by the system to rewind to the start of the current playlist.
    // NOT overriding this leaves the inherited implementation, which can hand
    // the player back null - a player with no content will simply never start.
    //
    // Which is exactly what is wanted once the queue has run out. The player
    // asks for a reset when it reaches the end, and rewinding to track 0 there
    // made a single finished episode restart from the beginning - right for an
    // album, wrong for a podcast that was just marked played and queued for
    // deletion. Returning null stops it instead. The iterator is rewound past
    // its end as well, so a player that ignores the null and asks again still
    // gets nothing.
    function resetContentIterator() as ContentIterator? {
        System.println("resetContentIterator");
        var iterator = _iterator;
        if (iterator == null) {
            iterator = new GarminPocketCastsContentIterator(0);
            _iterator = iterator;
            return iterator;
        }

        iterator.reset();
        if (iterator.isExhausted()) {
            // Skipping off the end of the LAST episode leaves no next track to
            // report the skip against, so onLeftCurrent() never fires for it.
            // This is that moment. A _currentKey still set here means the
            // player ran out of queue while on an episode that never sent
            // COMPLETE - which clears it - so it was skipped through.
            var key = _currentKey;
            _currentKey = null;
            if (key != null) {
                markSkippedThrough(key, "resetContentIterator");
            }
            // Nothing left to hand over means the player is done with all of
            // it, so the whole queue is fair game for the purge.
            Catalog.clearPlayerKeys();
            return null;
        }
        iterator.publishKeys();
        return iterator;
    }

    // Playback events from the media player. A real provider would bank these
    // in Storage and report them back to the service on the next sync.
    function onSong(contentRefId as Object, songEvent as SongEvent, playbackPosition as Number or PlaybackPosition) as Void {
        // println is NOT stripped from release builds (verified - the strings are
        // present in the release .prg), so this lands in GARMIN/APPS/LOGS/GarminPocketCasts.TXT
        // on device as well as in the simulator console.
        System.println("onSong ref=" + contentRefId + " event=" + songEvent + " pos=" + playbackPosition);
        bankPosition(contentRefId, songEvent, playbackPosition);

        // STOP is the player letting go. Said out loud here so the audio of an
        // episode finished earlier in this session can be reclaimed at the
        // next entry point rather than waiting for the process to end - which,
        // as a device log showed, can be hours.
        if (songEvent == Media.SONG_EVENT_STOP) {
            Catalog.clearPlayerKeys();
        }
    }

    // Try to report positions while the user is listening, so a phone that is
    // nearby sees progress straight away rather than at the next sync.
    //
    // Strictly best-effort, and deliberately timid. Outside a sync session
    // there is no Wi-Fi, so this goes over BLE and only works with the phone
    // in range - which, for a watch app whose whole premise is leaving the
    // phone at home, is the exception rather than the rule. It is attempted
    // only when the listener has actually stopped (pause, stop, finished),
    // never mid-decode, and the outbox is only cleared on confirmation, so a
    // request killed with the app costs nothing but a retry at the next sync.
    private function tryOpportunisticFlush() as Void {
        if (!FLUSH_DURING_PLAYBACK || _client != null) {
            return;
        }

        var now = System.getTimer();
        if (_lastFlush != 0 && (now - _lastFlush) < FLUSH_EVERY_MS) {
            return;
        }

        if (!System.getDeviceSettings().phoneConnected) {
            System.println("flush: no phone, leaving it for the sync");
            return;
        }

        _lastFlush = now;
        var client = new PocketCastsClient(method(:onFlushDone));
        _client = client;
        client.flushPositions();
    }

    function onFlushDone(success as Boolean, message as String?) as Void {
        System.println("flush: done success=" + success + " msg=" + message);
        _client = null;
    }

    // The encoded speed of one episode, looked up at most once per track.
    //
    // Resolving this inside the conversion meant an encrypted Storage read and
    // a dictionary deserialise on every playback event that carries a
    // position. onSong runs on the player's own callback path, so the less it
    // does the better - and the answer cannot change while a track is
    // playing, because it is a property of the file already on the watch.
    private var _speedKey as String?;
    private var _speedPercent as Number = 100;

    private function speedFor(key as String) as Number {
        var cached = _speedKey;
        if (cached == null || !cached.equals(key)) {
            _speedKey = key;
            _speedPercent = Catalog.getSpeed(key);
            System.println("speed " + _speedPercent + "% for " + key);
        }
        return _speedPercent;
    }

    // Remember where the listener got to, so the next launch can resume there.
    // The system tracks nothing itself - getPlaybackStartPosition() on a cached
    // Content is always 0 - so if this does not record it, it is lost.
    //
    // Playback is its own app invocation with no network guarantee, so this
    // only writes to Storage; reporting it back to Pocket Casts happens on the
    // next sync, which is the flow the audio content provider guide describes.
    private function bankPosition(
        contentRefId as Object?,
        songEvent as Object?,
        playbackPosition as Object?
    ) as Void {
        if (!(songEvent instanceof Number)) {
            return;
        }

        var key = Catalog.findKeyForRefId(contentRefId);

        // Has the player moved to a different track without ever telling us
        // the old one ended? That is what skipping off the end looks like -
        // see onLeftCurrent(). Checked before anything else, because the event
        // that carries the move names the NEW track and its position is 0,
        // which is meaningless as a position and must not be banked.
        var current = _currentKey;
        if (key != null && current != null && !key.equals(current)) {
            onLeftCurrent(key);
            return;
        }

        // START tells us which track the player is on. Handled before the
        // position guard, since START is the one event that can carry a
        // PLAYBACK_POSITION_* value rather than a count of seconds.
        if (songEvent == Media.SONG_EVENT_START) {
            _currentKey = key;
            return;
        }

        if (!(playbackPosition instanceof Number)) {
            return;
        }

        // COMPLETE means the episode finished: drop the position so it starts
        // from the beginning rather than resuming one second from the end.
        var finished = (songEvent == Media.SONG_EVENT_COMPLETE);

        // Everything else worth recording is a moment the listener stopped:
        // pause, stop, or skipping away. START and RESUME are not - the
        // position at those is where we already were.
        var stopped = (songEvent == Media.SONG_EVENT_PAUSE) ||
                      (songEvent == Media.SONG_EVENT_STOP) ||
                      (songEvent == Media.SONG_EVENT_SKIP_NEXT) ||
                      (songEvent == Media.SONG_EVENT_SKIP_PREVIOUS) ||
                      (songEvent == Media.SONG_EVENT_SKIP_FORWARD) ||
                      (songEvent == Media.SONG_EVENT_SKIP_BACKWARD);

        // SONG_EVENT_PLAYBACK_NOTIFY is deliberately not handled.
        // playbackNotificationThreshold is "the number of seconds a song must
        // play to trigger a played notification" - it fires ONCE per track,
        // not on a tick, so it cannot checkpoint position periodically. The
        // consequence is accepted: a flat battery mid-episode loses progress
        // back to the last pause, stop or skip. A Timer could close that gap,
        // at the cost of a recurring wake-up inside the playback invocation.
        if (!finished && !stopped) {
            return;
        }

        if (key == null) {
            System.println("bankPosition: no episode for ref " + contentRefId);
            return;
        }

        // Reaching here means the watch itself moved this episode, which is
        // exactly the condition for reporting it back to Pocket Casts. A
        // position that only ever came from the server is never marked, and so
        // can never overwrite progress made on another device.
        if (finished) {
            // Finished is reported as a status, not as a position - and
            // markPlayed() zeros the stored position itself, since pushing a 0
            // would tell the server the episode is back at the start and reset
            // it to unplayed on every other device.
            Catalog.markPlayed(key);
            System.println("bankPosition: " + key + " -> PLAYED");

            // Accounted for, so the end-of-queue check below has nothing left
            // to finish for it.
            _currentKey = null;

            // Latch the queue here rather than waiting for the player to ask
            // for a track past the end, so the decision is made while we still
            // know which track just finished.
            var iterator = _iterator;
            if (iterator != null && iterator.atLastTrack()) {
                iterator.finish();
            }
        } else {
            // FILE SECONDS IN, CONTENT SECONDS OUT. The player counts through
            // the file it was given, and a file fetched at 1.5x is physically
            // shorter than the episode - so 600 here is 900 of the episode
            // Pocket Casts knows about. Everything downstream of this line, and
            // everything in Storage, is content seconds; this is one of the
            // only two places the two ever meet. Bank the raw number and the
            // next refresh tells the server the listener is a third of the way
            // further back than they are.
            var seconds = Catalog.toContentSeconds(speedFor(key), playbackPosition);
            Catalog.setPosition(key, seconds);
            Catalog.markDirty(key);
            System.println("bankPosition: " + key + " -> " + seconds + "s (dirty)");
        }

        if (finished || songEvent == Media.SONG_EVENT_PAUSE || songEvent == Media.SONG_EVENT_STOP) {
            tryOpportunisticFlush();
        }
    }

    // The player has moved off _currentKey without ever reporting that it
    // ended. Read from a device log, this is the whole of what a skip past the
    // end of an episode looks like:
    //
    //     onSong ref=OLD event=7 pos=1077      <- resume, then nothing more
    //     get() -> track 0
    //     next() from 0                        <- the iterator advances
    //     onSong ref=NEW event=8 pos=0         <- the skip, against the NEW ref
    //     onSong ref=NEW event=0 pos=0         <- and only then, START
    //
    // The old episode gets no COMPLETE and no closing event of any kind - the
    // skip that crossed the boundary is reported against the track it landed
    // in, at position 0. Nothing in the events names the episode that was
    // left, which is why the delegate has to remember it.
    //
    // Compare a natural finish, where next() is preceded by a COMPLETE that
    // does name the episode and there is no event=8 at 0:
    //
    //     onSong ref=OLD event=4 pos=1189
    //     next() from 0
    //     onSong ref=NEW event=0 pos=0
    //
    // So: an event naming a track other than the one we last saw START for is
    // the player advancing, and skipping off the end is the only way to make
    // it advance - NEXT and PREVIOUS are not among the controls the iterator's
    // profile draws (rule 4). Finishing the episode is what the listener meant
    // by skipping through its last minutes of ads.
    private function onLeftCurrent(startedKey as String) as Void {
        var key = _currentKey;
        _currentKey = startedKey;
        if (key == null) {
            return;
        }

        markSkippedThrough(key, "bankPosition");

        // No flush from here: the next episode is starting to decode, and the
        // flush points deliberately avoid firing a BLE request mid-decode.
        // The report goes out at the next pause, stop or refresh.
    }

    // An episode the player moved off without ever sending COMPLETE was skipped
    // through - the listener nudging past its last minutes of ads, which is a
    // request to finish it. markPlayed() zeros the stored position itself.
    // `where` is only the log prefix, so which path noticed stays visible in
    // the one diagnostic channel the device has.
    private function markSkippedThrough(key as String, where as String) as Void {
        System.println(where + ": " + key + " skipped off the end -> PLAYED");
        Catalog.markPlayed(key);
    }
}
