import Toybox.Lang;
import Toybox.Media;
import Toybox.System;

// Hands the native media player one track at a time. The player never sees a
// playlist - it walks this iterator and reads getPlaybackProfile() to decide
// which transport controls to draw.
class GarminPocketCastsContentIterator extends Media.ContentIterator {

    // The two jumps podcast listeners actually use: forward past an ad or a
    // digression, back over something missed. Asymmetric on purpose - that is
    // the convention every podcast app follows.
    //
    // THESE TWO NUMBERS ARE DRAWN ON THE BUTTONS. The glyphs in
    // resources/drawables/skip_*.svg spell them out, so changing one here
    // without regenerating the art leaves the player advertising a skip the
    // app does not perform - which is the exact bug SkipButton exists to fix.
    static const SKIP_FORWARD_SECONDS = 30;
    static const SKIP_BACKWARD_SECONDS = 10;


    private var _contents as Array<Media.Content> = [] as Array<Media.Content>;
    private var _index as Number = 0;

    // The episode uuids behind _contents, in the same order. Kept so the
    // iterator can re-declare what the player is holding every time it is
    // handed over - the delegate clears that declaration when the player
    // stops, and a player that comes back must not find it still empty.
    private var _keys as Array<String> = [] as Array<String>;

    // Set once the last episode has been played to its end. A podcast queue
    // that runs out is finished, not something to start over - see reset().
    private var _exhausted as Boolean = false;

    // Cached between calls - getPlaybackProfile() is called constantly during
    // playback - but rebuilt whenever the track the iterator is now on was
    // encoded at a different speed than the one the cached profile was built
    // for. That is what lets a queue mixing speeds get skip deltas scaled to
    // whichever episode is playing rather than to the one playback started on.
    // _profileSpeed is the speed _profile was built for; -1 means none yet.
    private var _profile as Media.PlaybackProfile?;
    private var _profileSpeed as Number = -1;

    // The two skip buttons are built once and retarget()ed across profile
    // rebuilds rather than reallocated - each holds a BitmapResource and rule 9
    // has a handle budget. Their art is NOT fixed: forwardArt()/backwardArt()
    // pick the glyph naming the current track's scaled delta, and retarget()
    // swaps it in on a speed change.
    private var _skipForwardButton as SkipButton?;
    private var _skipBackwardButton as SkipButton?;

    function initialize(startIndex as Number) {
        ContentIterator.initialize();

        // Rebuild the downloaded tracks from the ids the sync saved. Metadata
        // is not stored with the audio, so it is re-attached here.
        var tracks = Catalog.getDownloadedTracks();
        var refIds = Catalog.getRefIds();

        // What the player will be holding, published so purgeFinished() can
        // keep its hands off it - deleting the cache entry of a Content the
        // player has in hand is the move that rebooted the watch in rule 2.
        _keys = [] as Array<String>;

        for (var i = 0; i < tracks.size(); i++) {
            var track = tracks[i];
            var refId = refIds.get(track.key);
            if (refId == null) {
                continue;
            }

            var contentRef = new Media.ContentRef(refId as Object, Media.CONTENT_TYPE_AUDIO);

            var cached = Media.getCachedContentObj(contentRef) as Media.Content?;
            if (cached != null) {
                // Mutate the ContentMetadata object the Content ALREADY OWNS.
                // Handing it a fresh one via setMetadata() silently destroyed
                // its ability to decode - as did replacing the Content itself.
                // The system object has to stay the system object; only the
                // fields inside its existing metadata get touched.
                var existing = cached.getMetadata() as Media.ContentMetadata?;
                if (existing != null) {
                    existing.title = track.title;
                    existing.artist = track.artist;
                    existing.album = Catalog.ALBUM;
                    existing.genre = Catalog.GENRE;
                    existing.trackNumber = i + 1;
                    // Does the SYSTEM already remember where this track got to?
                    // There is no setter for it anywhere in the API - the only
                    // way to specify a start position is to construct a
                    // Media.ActiveContent, which rule 1 says does not decode -
                    // so whether resume works at all hinges on what the system
                    // puts here on its own.
                    System.println("track " + i + " (" + track.key + ") ref=" + refId +
                        ", metadata set in place, startPos=" + cached.getPlaybackStartPosition());
                } else {
                    System.println("track " + i + " (" + track.key + ") ref=" + refId + ", NO metadata object");
                }
                // Resume where the listener left off. A self-constructed
                // ActiveContent decodes and honours its start position -
                // verified on device, and the reason rule 1 no longer says
                // otherwise. Two conditions still hold, and both are met here:
                // the metadata handed over is the object the system ALREADY
                // OWNS (`existing`, never a fresh ContentMetadata), and this
                // runs once in the constructor rather than mid-playback.
                // CONTENT SECONDS OUT OF STORAGE, FILE SECONDS INTO THE PLAYER
                // - the mirror of bankPosition(), and the other half of the
                // only boundary where the two meet. A position of 900 in an
                // episode fetched at 1.5x is 600 seconds into the file, and
                // handing the player 900 would drop the listener half a
                // conversion past where they stopped.
                var resumeAt = Catalog.toFileSeconds(
                    Catalog.getSpeed(track.key), Catalog.getPosition(track.key));
                var playable = cached;
                if (resumeAt > 0 && existing != null) {
                    playable = new Media.ActiveContent(contentRef, existing, resumeAt);
                    System.println("track " + i + " resuming at " + resumeAt + "s (file)");
                }
                _contents.add(playable);
            } else {
                System.println("track " + i + " (" + track.key + ") CACHE MISS, building, ref=" + refId);
                // Only the cache-miss path needs a metadata object we built -
                // the common path mutates the one the system already owns.
                var metadata = new Media.ContentMetadata();
                metadata.title = track.title;
                metadata.artist = track.artist;
                metadata.album = Catalog.ALBUM;
                metadata.genre = Catalog.GENRE;
                metadata.trackNumber = i + 1;
                _contents.add(new Media.Content(contentRef, metadata));
            }
            _keys.add(track.key);
        }

        Catalog.setPlayerKeys(_keys);

        if (startIndex >= 0 && startIndex < _contents.size()) {
            _index = startIndex;
        }

        System.println("iterator built: " + _contents.size() + " of " + tracks.size() + " tracks, starting at " + _index);

        var stats = Media.getCacheStatistics();
        System.println("media cache: " + stats.size + " bytes used of " + stats.capacity);
    }

    // Rewind without rebuilding. Re-running the constructor would fetch every
    // cached Content object again and replace the ones the player already
    // holds - churn that coincided with the watch rebooting.
    //
    // Once the queue is exhausted this rewinds to PAST the end instead, so
    // get() answers null. The player asks for a reset when it runs out of
    // tracks, and rewinding to 0 there is what made a single finished episode
    // start over from the beginning - correct for an album, wrong for a
    // podcast the listener has just finished and which is already queued for
    // deletion.
    function reset() as Void {
        if (_exhausted) {
            System.println("iterator reset: queue exhausted, staying at the end");
            _index = _contents.size();
            return;
        }
        System.println("iterator reset to 0");
        _index = 0;
    }

    // Re-declare what the player has in hand. Called on every hand-over, not
    // just at construction: purgeFinished() reads this, and the delegate wipes
    // it on SONG_EVENT_STOP.
    function publishKeys() as Void {
        Catalog.setPlayerKeys(_keys);
    }

    // The queue has run out and must not be played again in this session.
    function finish() as Void {
        if (!_exhausted) {
            System.println("iterator exhausted at track " + _index);
        }
        _exhausted = true;
    }

    function isExhausted() as Boolean {
        return _exhausted;
    }

    // Is the current track the last one? Asked when an episode finishes, so
    // the delegate can latch the queue before the player asks to advance.
    function atLastTrack() as Boolean {
        return _index + 1 >= _contents.size();
    }

    // Determine if the the current track can be skipped.
    function canSkip() as Boolean {
        return true;
    }

    // Get the current media content object.
    function get() as Content? {
        if (_index < _contents.size()) {
            System.println("get() -> track " + _index);
            return _contents[_index];
        }
        System.println("get() -> null (index " + _index + " of " + _contents.size() + ")");
        return null;
    }

    // Get the current media content playback profile
    function getPlaybackProfile() as PlaybackProfile? {
        var speed = currentTrackSpeed();

        var existing = _profile;
        if (existing != null && _profileSpeed == speed) {
            return existing;
        }

        System.println("getPlaybackProfile() - building for speed " + speed);
        var profile = new Media.PlaybackProfile();
        profile.attemptSkipAfterThumbsDown = false;

        // Podcast controls, not music controls.
        //
        // The first entry becomes the media player hotkey on devices that have
        // one, so SKIP_FORWARD leads: nudging past an ad is the thing a
        // listener does over and over, and it is what the most accessible
        // button on the watch should do. NEXT used to be here, which put
        // "abandon this episode" on the hotkey - the worst possible binding
        // for a 40 minute podcast.
        //
        // NEXT and PREVIOUS are gone entirely. Skipping whole tracks is a
        // music idea; episodes are chosen from the playback menu, which is
        // where the app is entered from anyway. Dropping them also keeps the
        // player to three buttons rather than five.
        //
        // PLAYBACK stays in the middle rather than first, because leading with
        // it produced a second play button - the player already renders
        // play/pause itself.
        //
        // SKIP IS IN CONTENT SECONDS, so the deltas are scaled down for a file
        // that plays faster than it was recorded. Pocket Casts, Overcast,
        // Apple Podcasts and Spotify all anchor the skip button to episode
        // time rather than to the listener's wall clock: at 1.5x, a 30 second
        // skip moves 30 seconds of episode, which is 20 seconds of file. Not
        // scaling would move 45 seconds of episode per tap and break the
        // muscle memory every one of those apps has trained.
        //
        // `speed` is the CURRENT track's - computed at the top of this method
        // and used for the cache key - so a queue mixing speeds gets the right
        // delta for whichever episode is playing. Confirmed on hardware: the
        // player re-asks for the profile at each track boundary on its own.
        var fwdDelta = scaleSkip(SKIP_FORWARD_SECONDS, speed);
        var backDelta = scaleSkip(SKIP_BACKWARD_SECONDS, speed);

        // The two skip buttons carry their own art. The stock icons have "30"
        // baked in, and the scaled delta is usually not 30 or 10 - so there is
        // one glyph per distinct scaled value (skip_f<n>.svg / skip_b<n>.svg,
        // wired in drawables.xml, generated by tools/New-SkipIcons.ps1), and
        // forwardArt()/backwardArt() pick the pair naming the delta the dial
        // is about to print.
        //
        // Guarded like getProviderIconInfo: Media.SystemButton is API 3.0.3,
        // well under this app's 5.0.0 floor, and the export build compiles
        // clean whether or not the guard is there. All 57 products in
        // manifest.xml were checked against their SDK api.debug.xml and every
        // one declares it, so the fallback is belt and braces - but it is the
        // only thing standing between a firmware that drops the class and an
        // app with no transport controls at all.
        //
        // A SystemButton leads the array rather than the bare enum. It wraps
        // PLAYBACK_CONTROL_SKIP_FORWARD, so the hotkey binding of rule 4
        // should be unaffected; that is the one thing here only the watch can
        // confirm. The buttons are held in members and retarget()ed rather
        // than reallocated - a rebuild only happens on a speed change, and
        // each button holds a BitmapResource (rule 9 has a handle budget).
        if (Media has :SystemButton) {
            var fwdArt = forwardArt(fwdDelta);
            var backArt = backwardArt(backDelta);
            var fwd = _skipForwardButton;
            if (fwd == null) {
                fwd = new SkipButton(PLAYBACK_CONTROL_SKIP_FORWARD, fwdArt[0], fwdArt[1]);
                _skipForwardButton = fwd;
            } else {
                fwd.retarget(fwdArt[0], fwdArt[1]);
            }
            var back = _skipBackwardButton;
            if (back == null) {
                back = new SkipButton(PLAYBACK_CONTROL_SKIP_BACKWARD, backArt[0], backArt[1]);
                _skipBackwardButton = back;
            } else {
                back.retarget(backArt[0], backArt[1]);
            }
            profile.playbackControls = [fwd, PLAYBACK_CONTROL_PLAYBACK, back];
        } else {
            profile.playbackControls = [
                PLAYBACK_CONTROL_SKIP_FORWARD,
                PLAYBACK_CONTROL_PLAYBACK,
                PLAYBACK_CONTROL_SKIP_BACKWARD
            ];
        }

        profile.skipForwardTimeDelta = fwdDelta;
        profile.skipBackwardTimeDelta = backDelta;
        System.println("profile: speed=" + speed +
            " fwd=" + fwdDelta + " back=" + backDelta);

        // Seconds of play before the system sends a "played" notification.
        // NOT a repeating tick - it fires once per track - so it cannot be
        // used to checkpoint position periodically.
        profile.playbackNotificationThreshold = 1;
        profile.requirePlaybackNotification = false;
        profile.skipPreviousThreshold = null;
        _profile = profile;
        _profileSpeed = speed;
        return profile;
    }

    // The encoded speed of the track the iterator is currently on, or 100 when
    // the queue is empty or the index is past the end.
    //
    // getPlaybackProfile() calls this on every invocation to decide whether its
    // cache is still good, and Catalog.getSpeed() is an encrypted Storage read
    // plus a dictionary deserialise - too much for a hot path - so the answer
    // is memoised against _index and only re-read when the iterator has
    // actually stepped to another track.
    private var _speedIndex as Number = -1;
    private var _speedValue as Number = 100;

    private function currentTrackSpeed() as Number {
        if (_speedIndex != _index) {
            _speedIndex = _index;
            if (_index >= 0 && _index < _keys.size()) {
                _speedValue = Catalog.getSpeed(_keys[_index]);
            } else {
                _speedValue = 100;
            }
        }
        return _speedValue;
    }

    // The [icon, detail] drawables for a skip button that will advertise
    // `delta` seconds. The cases are the distinct values scaleSkip() produces
    // across Proxy.speeds() - 30/24/20/17/15 forward, 10/8/6/5 back - and must
    // stay in step with the <bitmap> block in drawables.xml and the set
    // tools/New-SkipIcons.ps1 draws. Any delta with no exact glyph (a speed
    // list that changed without a regen) falls back to the base art: a wrong
    // number on the button, but never a missing resource.
    private function forwardArt(delta as Number) as Array<ResourceId> {
        if (delta == 24) { return [Rez.Drawables.SkipF24Icon, Rez.Drawables.SkipF24Detail]; }
        if (delta == 20) { return [Rez.Drawables.SkipF20Icon, Rez.Drawables.SkipF20Detail]; }
        if (delta == 17) { return [Rez.Drawables.SkipF17Icon, Rez.Drawables.SkipF17Detail]; }
        if (delta == 15) { return [Rez.Drawables.SkipF15Icon, Rez.Drawables.SkipF15Detail]; }
        return [Rez.Drawables.SkipF30Icon, Rez.Drawables.SkipF30Detail];
    }

    private function backwardArt(delta as Number) as Array<ResourceId> {
        if (delta == 8) { return [Rez.Drawables.SkipB8Icon, Rez.Drawables.SkipB8Detail]; }
        if (delta == 6) { return [Rez.Drawables.SkipB6Icon, Rez.Drawables.SkipB6Detail]; }
        if (delta == 5) { return [Rez.Drawables.SkipB5Icon, Rez.Drawables.SkipB5Detail]; }
        return [Rez.Drawables.SkipB10Icon, Rez.Drawables.SkipB10Detail];
    }

    // A skip delta is content seconds - a 30s tap moves 30s of episode - so it
    // crosses into file seconds by exactly the same conversion a stored
    // position does. Floored at 5 seconds: at the top of the offered range a
    // 10 second backward skip scales to 5, and anything shorter stops being a
    // control and starts being a twitch.
    private function scaleSkip(seconds as Number, percent as Number) as Number {
        var scaled = Catalog.toFileSeconds(percent, seconds);
        return scaled < 5 ? 5 : scaled;
    }

    // Advance and return the new current track, or null at the end.
    function next() as Content? {
        System.println("next() from " + _index);
        if (_index + 1 < _contents.size()) {
            _index++;
            return _contents[_index];
        }
        // Being asked for a track after the last one is the end of the queue,
        // whichever way the player got here.
        finish();
        return null;
    }

    // Get the next media content object without incrementing the iterator.
    function peekNext() as Content? {
        if (_index + 1 < _contents.size()) {
            return _contents[_index + 1];
        }
        return null;
    }

    // Get the previous media content object without decrementing the iterator.
    function peekPrevious() as Content? {
        if (_index > 0) {
            return _contents[_index - 1];
        }
        return null;
    }

    // Step back and return the new current track, or null at the start.
    function previous() as Content? {
        System.println("previous() from " + _index);
        if (_index > 0) {
            _index--;
            return _contents[_index];
        }
        return null;
    }

    // Determine if playback is currently set to shuffle.
    function shuffling() as Boolean {
        return false;
    }

}
