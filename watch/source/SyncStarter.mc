import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// The one place a sync is launched from.
//
// There are three routes into a sync and they must not drift apart: the
// playback hub's "Get new episodes", the playlists menu's "Download now" row,
// and backing out of that menu with something pending. All three land here.
module SyncStarter {

    // Whether begin() has been called since the current refresh started.
    //
    // Sync mode does not come up instantly: startSync2() returns, the spinner
    // that called it is still on screen, and there is a window of a second or
    // so in which a back press still reaches GarminPocketCastsRefreshDelegate.
    // That delegate cancels every outstanding request, which killed the sync it
    // had just asked for - read off a device log as "startSync2: How to beat
    // the resource curse in Norway" followed immediately by "refresh: cancelled
    // by user" and no onStartSync at all.
    //
    // In memory only, deliberately, like Catalog's syncFromMenu: it is a claim
    // about what THIS process has already done, and a copy in Storage would
    // survive to insist on it long after it stopped being true.
    var _launched as Boolean = false;

    function launched() as Boolean {
        return _launched;
    }

    // What the hub should say when this sync lands, or null.
    //
    // It carries the reason a playlist was refreshed stale (see
    // PocketCastsClient.staleReason()) from the refresh that launched the sync
    // to the hub that GarminPocketCastsSyncDelegate.finishSync() builds
    // afterwards. That hub is the only durable place to say it: the refresh
    // spinner is covered by the system's sync screen about a second after
    // begin() returns, so a toast fired here is gone before anyone reads it,
    // and the sync delegate has no other way of knowing a list was carried
    // forward.
    //
    // In memory only, for the same reason as _launched and
    // Catalog._syncFromMenu: it is a claim about what THIS process is doing
    // now. A copy in Storage would survive to caption a later sync that had
    // nothing wrong with it.
    //
    // ASSIGNED BY EVERY begin(), never conditionally, so it can never describe
    // an earlier one. Spent by whichever of finishSync()/onStopSync() ends the
    // session, alongside Catalog.takeSyncFromMenu().
    var _status as String?;

    function takeStatus() as String? {
        var status = _status;
        _status = null;
        return status;
    }

    // Called when a refresh starts, so that neither field can outlive the
    // refresh it describes.
    //
    // _launched: without clearing it here the first sync of the process would
    // disarm the cancel for every later spinner, including one that is
    // genuinely stuck.
    //
    // _status: belt-and-braces, since every begin() assigns it - but a sync the
    // watch silently drops (see "Device-state false alarms" - startSync()
    // returns, onStartSync never arrives) reaches no finishSync() and no
    // onStopSync(), so nothing spends it. This is the only thing that would
    // clear it before it captioned an unrelated sync.
    function clearForRefresh() as Void {
        _launched = false;
        _status = null;
    }

    // Start sync mode, with something other than the app name on the system's
    // sync screen.
    //
    // That screen is drawn by the SYSTEM and has no hook for a per-track
    // label: notifySyncProgress() takes a Number and nothing else, and
    // SyncDelegate has no callback that could supply one. startSync2() is the
    // only place a string reaches it, and the message is fixed when sync mode
    // is LAUNCHED - so this cannot tick through episode titles as they
    // download, and no amount of work in the sync delegate will change that.
    //
    // Hence: one pending episode gets its title, which is the case that
    // matters because a ~35 MB download is minutes of looking at that screen.
    // Several get a count, which stays true for the whole sync rather than
    // naming a track that finished several minutes ago.
    //
    // startSync2 is API level 4.0.4, below this app's 5.0.0 floor, but its
    // device list is NOT all of them - fenix 5 Plus, fenix 6, Forerunner
    // 645/745/945 and vivoactive 3/4 among others are absent - so it is
    // guarded and falls back to the plain call.
    // `status` is what the hub this sync lands on should say, or null for the
    // usual case of nothing to report. See _status: only the refresh view ever
    // has anything to pass, and it is the reason a playlist was carried
    // forward stale.
    function begin(status as String?) as Void {
        // Tell the sync delegate there is a view of ours underneath the
        // system's sync screen, so it can put the playback hub there before
        // the screen comes down. Without this the user lands back on whatever
        // they started the sync from and has to back out by hand.
        Catalog.setSyncFromMenu(true);
        _launched = true;
        _status = status;

        if (Communications has :startSync2) {
            var message = syncMessage();
            System.println("startSync2: " + message);
            Communications.startSync2({ :message => message });
            return;
        }
        System.println("startSync (no startSync2 on this device)");
        Communications.startSync();
    }

    function syncMessage() as String {
        var pending = Catalog.getPendingTracks();
        if (pending.size() == 1) {
            return pending[0].title;
        }
        return pending.size() + " " + (WatchUi.loadResource(Rez.Strings.syncEpisodes) as String);
    }

}
