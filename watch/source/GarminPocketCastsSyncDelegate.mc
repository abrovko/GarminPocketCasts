import Toybox.Application;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.Media;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

// Downloads the tracks that were toggled on in the sync configuration menu.
//
// Web requests have to be chained by hand: the next download is only issued
// from the previous one's callback, and notifySyncComplete() must be reached
// on every path or the device stays stuck in sync mode.
class GarminPocketCastsSyncDelegate extends Communications.SyncDelegate {

    private var _queue as Array<Track> = [] as Array<Track>;
    private var _total as Number = 0;
    private var _current as Track?;
    private var _error as String?;

    // Download progress for the track in flight. The logs rotate at 5 KB, so
    // this is reported sparsely - the first callback, then every few MB - and
    // the running total is printed again if the download fails. Whether any
    // bytes at all arrive before a REQUEST_CANCELLED is the whole question.
    private var _bytes as Number = 0;
    private var _loggedAt as Number = -1;

    // Last percentage handed to the system, and when. The system is told
    // again whenever the whole-sync percentage moves OR a second has passed,
    // whichever comes first - see onDownloadProgress().
    private var _lastPercent as Number = -1;
    private var _lastNotify as Number = 0;

    static const LOG_EVERY_BYTES = 4000000;
    static const NOTIFY_EVERY_MS = 1000;

    // Stall watchdog. Every path out of this delegate runs from a callback, so
    // a request that goes out and never comes back - or comes back byte by
    // byte and then simply stops - leaves the sync session open with nothing
    // left to end it. That costs Wi-Fi for as long as the system is willing to
    // hold the session, which is a battery question rather than a sync one:
    // the radio is up and the watch is not asleep. The refresh view has had a
    // watchdog since the day a spinner turned forever; this is the same guard
    // for the leg that actually spends power.
    //
    // STALL_MS is measured from the last sign of life, not from the start of
    // the download - a 20 MB episode at the 25 KB/s this hardware manages on
    // battery is over ten minutes of perfectly healthy transfer, so any
    // whole-download deadline would either fire on a good sync or be too long
    // to be worth having. Progress callbacks arrive continuously while bytes
    // move, so two minutes of complete silence means the transfer is gone.
    // Generous on purpose: it also has to cover a Cloud Run cold start, where
    // the proxy answers nothing at all until ffmpeg has produced its first
    // bytes.
    static const WATCHDOG_TICK_MS = 15000;
    static const STALL_MS = 120000;

    private var _watchdog as Timer.Timer?;
    private var _progressAt as Number = 0;

    // Guards notifySyncComplete() to exactly one call. It was reachable once
    // before this watchdog existed and is now genuinely racy: cancelAllRequests()
    // delivers REQUEST_CANCELLED to the download callback AFTER the watchdog
    // has already ended the sync, so onDownload() would otherwise run its
    // whole failure path - retry included - on a session that is over.
    private var _finished as Boolean = false;

    // Held only while a position flush is in flight, and doubles as the guard
    // that stops downloadNext() starting a second one.
    private var _client as PocketCastsClient?;

    // The speed the download in flight was requested at, banked against the
    // episode only once the audio actually lands. 100 means unproxied.
    private var _usedSpeed as Number = 100;

    // Stand-in denominator for the progress bar while a proxied download is in
    // flight, or 0 when it is not known. A streamed transcode is chunked and
    // so has no Content-Length for the system to report - see
    // Proxy.expectedBytes().
    private var _expectedBytes as Number = 0;

    // Set for exactly one retry after a proxied download failed, so the same
    // track is fetched again straight from its podcast CDN. A proxy that is
    // down has to cost the listener speed, never episodes - and this is the
    // only place that promise is kept.
    private var _bypassProxy as Boolean = false;

    // Whether this session ended because it was cancelled rather than because
    // it failed. It reaches exactly one decision - the sync-blocked flag in
    // completeSync() - and it is there so that a user who stops a download is
    // not also made to pay the automatic-retry suppression that a genuinely
    // fruitless sync earns. "I don't want this now" is not "this cannot work".
    private var _cancelled as Boolean = false;

    function initialize() {
        SyncDelegate.initialize();
    }

    // Polled by the system to decide whether a sync is worth running.
    function isSyncNeeded() as Boolean {
        Catalog.logState("isSyncNeeded");
        return Catalog.shouldSync();
    }

    function onStartSync() as Void {
        Catalog.logState("onStartSync");

        _queue = Catalog.getPendingTracks();
        _total = _queue.size();
        _current = null;
        _error = null;
        _finished = false;

        if (_total == 0) {
            finishSync(null);
            return;
        }

        startWatchdog();
        Communications.notifySyncProgress(0);
        downloadNext();
    }

    // Anything that shows the session is alive: a request going out, bytes
    // arriving, a callback landing. The watchdog measures from here.
    private function markProgress() as Void {
        _progressAt = System.getTimer();
    }

    private function startWatchdog() as Void {
        markProgress();
        stopWatchdog();
        var timer = new Timer.Timer();
        timer.start(method(:onWatchdog), WATCHDOG_TICK_MS, true);
        _watchdog = timer;
    }

    private function stopWatchdog() as Void {
        var timer = _watchdog;
        _watchdog = null;
        if (timer != null) {
            timer.stop();
        }
    }

    // Nothing has happened for STALL_MS: end the session rather than let it
    // hold the radio until the system loses patience on its own.
    //
    // Whether a Timer runs at all in sync mode is NOT confirmed on hardware -
    // sync is drawn by the system over our app, and this app's other timers
    // all live in views. It is written so that costs nothing if it does not:
    // a watchdog that never fires leaves exactly the behaviour that was here
    // before it. The log line is what will settle it.
    function onWatchdog() as Void {
        if (_finished) {
            stopWatchdog();
            return;
        }

        // System.getTimer() wraps at about 25 days, which makes this negative
        // rather than huge - so a wrap postpones the watchdog by one interval
        // instead of firing it on a healthy download.
        var idle = System.getTimer() - _progressAt;
        if (idle < STALL_MS) {
            return;
        }

        System.println(Log.stamp() + " sync: STALLED after " + _bytes +
            " bytes, nothing for " + idle + "ms - giving up");

        // The queue goes first: cancelAllRequests() delivers a cancelled
        // callback, and _finished stops it, but there must be nothing left for
        // any surviving path to start a fresh request from either.
        _queue = [] as Array<Track>;
        _current = null;
        _client = null;
        _bypassProxy = false;
        Communications.cancelAllRequests();

        if (_error == null) {
            _error = "Stalled";
        }
        completeSync();
    }

    // The user abandoned the sync from the system's screen. Spend the flag but
    // do not act on it: a cancel is not a download to show off, and dropping
    // them back on the playlists they came from is what they asked for.
    // Sync mode ending. NOT necessarily a cancel - see below.
    //
    // The log line goes FIRST, before every guard, because this used to leave
    // no trace at all and that cost a diagnosis: a fenix 8 hang
    // (logs/2026-08-29_091757) had to be reconstructed from a line that was
    // MISSING - finishSync() not printing its landing. Anything that ends a
    // sync has to say so.
    //
    // The first build that logged it answered a question the SDK docs frame as
    // "the user cancelled": measured 2026-08-29 (logs/2026-08-29_110545), the
    // system called getSyncDelegate() and then onStopSync() on a FRESH
    // delegate immediately after a sync that had completed perfectly -
    // "syncComplete ... error=null", the hub switched in, and then this. So
    // treat it as "sync mode is going away" and nothing stronger. Both lines
    // below stayed silent that time, which is how it should read: _finished
    // was false because this instance never ran anything, and the flag was
    // already spent by finishSync() a moment earlier.
    function onStopSync() as Void {
        System.println(Log.stamp() + " onStopSync: sync mode ending");
        stopWatchdog();
        if (_finished) {
            System.println("sync: already finished, nothing to cancel");
            return;
        }
        _finished = true;
        _cancelled = true;
        Communications.cancelAllRequests();
        _queue = [] as Array<Track>;
        _current = null;

        // Reaching here means the sync ended without finishSync() having named
        // a destination, and something still has to. Same reason finishSync()
        // does it: the system's sync screen is drawn OVER whatever the app
        // left underneath, and on the one-tap path that is the refresh spinner
        // - a view which, having launched the sync, has no timer, no callback
        // and no way to move itself. Spending the flag without acting on it
        // left the user turning that spinner until they force-quit the app.
        // The hub rather than the picker: stopping a sync is a change of mind,
        // not a failure with something to report.
        //
        // This delegate is very often NOT the instance that ran the downloads
        // - see the note above - which is exactly why the flag is module-level
        // state on Catalog. Whichever instance gets here reads the same
        // answer, and the first one to take it does the switch.
        if (Catalog.takeSyncFromMenu()) {
            System.println("sync: onStopSync landing on the playback hub");
            WatchUi.switchToView(
                new GarminPocketCastsConfigurePlaybackView(),
                new GarminPocketCastsConfigurePlaybackDelegate(),
                WatchUi.SLIDE_RIGHT
            );
        }

        Communications.notifySyncComplete(null);
    }

    // End the sync, and decide what the user is looking at when the system's
    // sync screen comes down.
    //
    // Sync runs in the same process as the menu that started it - measured: a
    // whole session of playback, refresh, sync and playback again carries one
    // build line, i.e. one onStart() - and the system draws its sync screen
    // OVER the app rather than replacing it. So the sync configuration menu is
    // still sitting on the view stack underneath, and swapping it out here is
    // what the user sees next. Two episodes downloaded used to end with them
    // looking at the playlists they had just downloaded from, one back press
    // short of the episodes.
    //
    // The switch goes BEFORE notifySyncComplete() deliberately: the swap
    // happens while the sync screen is still up, so the hub is already in
    // place when it comes down rather than sliding in over a flash of the old
    // menu.
    //
    // Nothing is switched unless the sync was started from that menu. A sync
    // the system decided on through isSyncNeeded() has no view of ours to
    // replace, and pushing one into view would be the app hijacking a screen
    // the user never asked it for.
    private function finishSync(error as String?) as Void {
        stopWatchdog();
        // Exactly once. See _finished: the watchdog and a late cancelled
        // callback can both arrive wanting to end the same session.
        if (_finished) {
            System.println("sync: already finished, ignoring error=" + error);
            return;
        }
        _finished = true;

        if (Catalog.takeSyncFromMenu()) {
            if (error == null) {
                // What they came for: the episodes, freshly resequenced and
                // including whatever just landed. The hub is built HERE, after
                // the downloads, which is the whole reason this cannot be done
                // by switching the view before the sync starts.
                System.println("sync: landing on the playback hub");
                WatchUi.switchToView(
                    new GarminPocketCastsConfigurePlaybackView(),
                    new GarminPocketCastsConfigurePlaybackDelegate(),
                    WatchUi.SLIDE_RIGHT
                );
            } else {
                // A REBUILT playlists menu, not the stale one underneath. That one
                // was constructed before the sync and cannot redraw itself, so
                // it would show neither the failure nor the Download now row
                // that is the way to retry. No network is needed for this -
                // the menu reads Storage; only updating the playlists needs the
                // refresh view.
                System.println("sync: landing on the list menu, error=" + error);
                WatchUi.switchToView(
                    new GarminPocketCastsConfigureSyncView(error),
                    new GarminPocketCastsConfigureSyncDelegate(),
                    WatchUi.SLIDE_IMMEDIATE
                );
            }
        }

        Communications.notifySyncComplete(error);
    }

    private function downloadNext() as Void {
        if (_queue.size() == 0) {
            _current = null;

            // The reliable flush point: a sync session has Wi-Fi, which is the
            // one moment connectivity is guaranteed. Downloads come first
            // because they are what the user asked for; reporting positions is
            // bookkeeping and must never cost them an episode.
            if (Catalog.hasPendingReports() && _client == null) {
                var client = new PocketCastsClient(method(:onFlushDone));
                _client = client;
                markProgress();
                client.flushPositions();
                return;
            }

            completeSync();
            return;
        }

        var track = _queue[0];
        _current = track;
        _bytes = 0;
        _loggedAt = -1;

        fetch(track);
    }

    // The bookkeeping every finished sync does, whatever ended it. Split out
    // of downloadNext() so the watchdog can reach it without going near the
    // position flush - a session that has just been declared dead is the last
    // place to start another request.
    private function completeSync() as Void {
        _client = null;

        // A sync that ends with as much still pending as it started with
        // achieved nothing, and backing out of the menu would start it
        // again immediately. Raise the flag that suppresses exactly one
        // automatic retry. Downloads that DID land clear it, so the normal
        // path never trips over this.
        // Downloads append, so a sync that filled a gap left its episodes
        // at the end of the playable list however far up the queue they
        // sit. Put them where the playlists say they go, before anything reads
        // the order back.
        Catalog.resequenceDownloads();

        // A cancelled sync is exempt: it made no progress by definition, and
        // suppressing the next automatic retry would punish the user for
        // stopping a download they did not want right then. The flag is for a
        // sync that TRIED and got nowhere, which is the thing that would
        // otherwise loop.
        var remaining = Catalog.getPendingTracks().size();
        Catalog.setSyncBlocked(!_cancelled && _total > 0 && remaining >= _total);

        // Carry the reason forward so the sync menu can show it. A null
        // _error means the sync worked, which clears any stale message.
        Catalog.setSyncError(_error);
        Catalog.logState("syncComplete");
        System.println("sync: started with " + _total + ", still pending " + remaining +
            ", error=" + _error);

        finishSync(_error);
    }

    // Issue the download for one track, through the proxy when there is one.
    //
    // POST with an audio response type is not something the SDK documents -
    // media downloads are only ever shown as GETs - so it was settled on
    // hardware before this was written. Measured on a fenix 8, 2026-08-27: a
    // POST carrying a json body and asking for HTTP_RESPONSE_CONTENT_TYPE_AUDIO
    // came back with a Media.ContentRef exactly like the GET control did. That
    // is what lets the episode url travel in the body, so nothing has to be
    // crammed into a query string and the proxy needs no ticket, no state and
    // no instance pinning.
    // Written as two whole calls rather than one built up by mutation. The
    // options dictionary makeWebRequest accepts is a strictly typed shape, and
    // assigning into it after the literal erases that type - which the checker
    // rejects at -l 3 with three errors that name none of this.
    private function fetch(track as Track) as Void {
        markProgress();
        var proxied = Proxy.isEnabled() && !_bypassProxy;
        _usedSpeed = proxied ? Proxy.getSpeedPercent() : 100;

        // Worked out once per track, not per progress event. Unproxied
        // downloads leave this at 0 and use the CDN's own Content-Length,
        // which the system reports as fileSize.
        _expectedBytes = proxied ? Proxy.expectedBytes(Catalog.getDuration(track.key)) : 0;

        if (proxied) {
            var url = Proxy.getUrl() + "/transcode";
            System.println("sync: POST " + track.key + " speed=" + _usedSpeed +
                " rate=" + Proxy.getBitrate() + " urlLen=" + url.length() +
                " expect=" + _expectedBytes);

            Communications.makeWebRequest(
                url,
                {
                    // The episode url travels in the BODY, which is the whole
                    // point of using POST: nothing has to be encoded into a
                    // query string, and the proxy needs no ticket and no state.
                    "url" => track.url,
                    "speed" => _usedSpeed,
                    "bitrate" => Proxy.getBitrate(),
                    "mono" => Proxy.getMono()
                },
                {
                    :method => Communications.HTTP_REQUEST_METHOD_POST,
                    :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_AUDIO,
                    // The proxy always answers MP3, whatever the source was.
                    // Passing track.encoding would hand ENCODING_M4A to an mp3
                    // body for any m4a podcast: it downloads happily and then
                    // refuses to play, which is the exact shape of silent
                    // failure this app keeps meeting.
                    :mediaEncoding => Media.ENCODING_MP3,
                    :headers => {
                        "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON,
                        "Authorization" => "Bearer " + Proxy.getToken()
                    },
                    :fileDownloadProgressCallback => method(:onDownloadProgress)
                },
                method(:onDownload)
            );
            return;
        }

        System.println("sync: GET " + track.key + " enc=" + track.encoding +
            " urlLen=" + track.url.length());

        Communications.makeWebRequest(
            track.url,
            null,
            {
                :method => Communications.HTTP_REQUEST_METHOD_GET,
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_AUDIO,
                :mediaEncoding => track.encoding,
                :fileDownloadProgressCallback => method(:onDownloadProgress)
            },
            method(:onDownload)
        );
    }

    // A failed flush is NOT a failed sync. The episodes are on the device,
    // which is the point; unreported positions stay in the outbox and go out
    // next time. Reporting them must never turn a good sync into a bad one.
    function onFlushDone(success as Boolean, message as String?) as Void {
        System.println("sync: flush done success=" + success + " msg=" + message);
        if (_finished) {
            return;
        }
        markProgress();
        _client = null;
        downloadNext();
    }

    // Media-download progress. Supported since CIQ 3.2.0 and only for media
    // downloads, which is exactly what this is.
    //
    // This is also where the system is kept informed. Progress used to be
    // reported only BETWEEN tracks, which meant a single 39 MB episode left
    // the app silent for minutes on end while the watch showed 0%. The SDK's
    // sync documentation asks the delegate to report progress as responses
    // come in, and a supervisor that treats a long silence as a stalled sync
    // would explain the REQUEST_CANCELLED / UNKNOWN_ERROR cut-offs seen on
    // device. It also gives the user a bar that actually moves.
    function onDownloadProgress(totalBytesTransferred as Number, fileSize as Number or Null) as Void {
        // Bytes that actually moved, not merely a callback that fired: a
        // progress event repeating the same total is what a stalled transfer
        // would look like, and feeding that to the watchdog would keep a dead
        // session alive forever.
        if (totalBytesTransferred > _bytes) {
            markProgress();
        }
        _bytes = totalBytesTransferred;

        // Tracks already finished; the one in flight is still at _queue[0].
        var done = _total - _queue.size();

        // The system reports fileSize from the response's Content-Length, so a
        // streamed transcode - chunked, and therefore without one - arrives as
        // null. Fall back to what we worked out ourselves, or the bar would
        // only move once per episode.
        var total = fileSize;
        if ((total == null || total <= 0) && _expectedBytes > 0) {
            total = _expectedBytes;
        }

        var percent = 0;
        if (_total > 0) {
            var fraction = 0.0;
            if (total != null && total > 0) {
                // Deliberately NOT (bytes * 100) / total: 39 MB times 100
                // overflows Monkey C's 32-bit Number. Float division cannot.
                fraction = totalBytesTransferred.toFloat() / total.toFloat();
                // The fallback is an estimate and can undershoot, so a track
                // must not be allowed to count more than once towards the
                // whole-sync figure.
                if (fraction > 1.0) {
                    fraction = 1.0;
                }
            }
            percent = (((done + fraction) * 100.0) / _total).toNumber();
        }
        if (percent < 0) { percent = 0; }
        if (percent > 100) { percent = 100; }

        var now = System.getTimer();
        if (percent != _lastPercent || (now - _lastNotify) >= NOTIFY_EVERY_MS) {
            _lastPercent = percent;
            _lastNotify = now;
            Communications.notifySyncProgress(percent);
        }

        if (_loggedAt < 0 || totalBytesTransferred - _loggedAt >= LOG_EVERY_BYTES) {
            _loggedAt = totalBytesTransferred;
            // `total` rather than fileSize: on a proxied download fileSize is
            // always null and would say nothing about how far this has got.
            System.println("sync: " + totalBytesTransferred + " of " + total +
                (fileSize == null ? " (est)" : "") + " (" + percent + "%)");
        }
    }

    // For an audio response the system has already written the file into the
    // app's encrypted sandbox; what comes back is a ContentRef, not bytes.
    // The SDK only types makeWebRequest callbacks for the JSON/GPX cases and
    // checks that signature exactly, so it is declared verbatim here and the
    // ContentRef the audio download actually returns is recovered by cast.
    function onDownload(
        responseCode as Number,
        data as Dictionary or String or Toybox.PersistedContent.Iterator or Null
    ) as Void {
        // The watchdog already ended this session, and cancelAllRequests() is
        // what produced this callback. Running the failure path here would
        // retry a track, write an error over the one that was reported, and
        // reach notifySyncComplete() a second time.
        if (_finished) {
            System.println("sync: late callback code=" + responseCode + ", session already over");
            return;
        }
        markProgress();

        var track = _current;
        var contentRef = data as Media.ContentRef?;

        if (responseCode == 200 && contentRef instanceof Media.ContentRef && track != null) {
            Catalog.recordDownload(track, contentRef.getId() as PersistableType);

            // AFTER recordDownload, which rewrites the record wholesale. The
            // speed belongs to the bytes that just landed, not to the playlist
            // entry, so it is patched in once they have.
            Catalog.setSpeed(track.key, _usedSpeed);

            System.println("downloaded " + track.key + " -> id=" + contentRef.getId() +
                " type=" + contentRef.getContentType() + " speed=" + _usedSpeed);

            _bypassProxy = false;
            _queue = _queue.slice(1, null);
            var done = _total - _queue.size();
            Communications.notifySyncProgress((done * 100) / _total);
            downloadNext();
            return;
        }

        // How far it got before failing is the difference between "never
        // connected" and "the system killed a transfer that was working".
        System.println(Log.stamp() + " sync: FAILED code=" + responseCode + " after " + _bytes + " bytes");

        // REQUEST_CANCELLED is not this download failing. It is the session
        // being taken away underneath it - onStopSync() calling
        // cancelAllRequests() - and the right answer is to stop, not to try
        // harder.
        //
        // Treating it as a failure cost a fenix 8 two minutes of nothing
        // (logs/2026-08-29_091757). The user cancelled seven seconds into a
        // proxied download; -1003 came back; the fail-soft retry below read it
        // as "the proxy is down" and issued a fresh FULL-SIZE direct GET into
        // a session the system had already ended. Not one byte ever arrived,
        // and the stall watchdog sat on it for 128 s before giving up. Note
        // the _finished guard does not cover this: the cancel had landed on a
        // different delegate instance, so this one's flag was still false.
        //
        // completeSync() rather than finishSync() directly - what did land is
        // still worth resequencing, and a cancel must clear the stale sync
        // error rather than leave one behind. _cancelled is what keeps it from
        // also raising the sync-blocked flag.
        if (responseCode == Communications.REQUEST_CANCELLED) {
            System.println("sync: cancelled underneath us, stopping");
            _cancelled = true;
            _bypassProxy = false;
            _queue = [] as Array<Track>;
            _current = null;
            completeSync();
            return;
        }

        // A proxied download that failed gets exactly one retry straight from
        // the podcast CDN, at full size and normal speed.
        //
        // This is the promise the whole feature rests on: a proxy that is
        // down, misconfigured or out of quota must not cost the listener their
        // episodes. It deliberately does NOT count against the
        // one-failure-poisons-the-session rule below, because that rule is
        // about a transport the system has soured - here the second attempt
        // goes somewhere else entirely.
        if (_usedSpeed != 100 && !_bypassProxy && track != null) {
            System.println("sync: proxy failed, retrying " + track.key + " direct");
            _bypassProxy = true;
            _bytes = 0;
            _loggedAt = -1;
            fetch(track);
            return;
        }
        _bypassProxy = false;
        if (_error == null) {
            _error = "Download failed (" + responseCode + ")";
        }

        // One failure poisons the rest of the sync session. Measured on
        // device: after a large download broke, the very next request - a
        // 52 KB file on a 39-character url that had downloaded fine moments
        // earlier - came back instantly with 0 bytes, and once with -1002
        // (UNSUPPORTED_CONTENT_TYPE_IN_RESPONSE), which is impossible for
        // that url. Whatever breaks takes the session's network stack with
        // it. Carrying on only burns minutes and buries the real error
        // behind a cascade of bogus ones, so stop at the first failure.
        if (_queue.size() > 1) {
            System.println("sync: abandoning " + (_queue.size() - 1) + " remaining track(s)");
        }
        _queue = [] as Array<Track>;

        // Deliberately NOT advancing notifySyncProgress here. Counting a
        // failed track as done reported "50%" for a sync that downloaded
        // nothing at all, which is worse than no number.
        downloadNext();
    }

}
