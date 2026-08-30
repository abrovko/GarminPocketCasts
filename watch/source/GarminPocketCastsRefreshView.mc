import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

// The spinner shown while the playlists are fetched, and the thing that
// owns the fetch itself.
//
// A Menu2 is built once in its constructor and will not redraw itself, so the
// sync menu cannot be shown first and filled in when the network answers. The
// fetch has to finish before that menu is constructed, which is what this view
// is for: show a progress bar, run the refresh, then switch to the menu.
//
// The request is fired from initialize(). It used to be fired from onShow(),
// which never ran: WatchUi.ProgressBar is a system-managed view and the
// conventional pattern is to start the work FIRST and show a progress bar over
// it, not to hang work off the bar's lifecycle. The symptom was a spinner that
// turned forever with nothing in the log - not one "pc:" line - because the
// client was never asked to do anything. Do not move this back into onShow().
class GarminPocketCastsRefreshView extends WatchUi.ProgressBar {

    // How long to wait before giving up. Without this a stalled request is an
    // spinner that turns until the user force-quits, with no way to tell a
    // slow network from a dead one.
    static const TIMEOUT_MS = 45000;

    // Held for the life of the request. The client owns a Method bound back to
    // this view, so this is one half of a reference cycle - it is broken in
    // finishOnce(). It also guarantees the client outlives initialize(),
    // rather than depending on Communications to keep the callback's receiver
    // alive, which is not something the SDK documents.
    // A failure can arrive before initialize() has even returned - with the
    // phone out of reach, BLE_CONNECTION_UNAVAILABLE (-104) comes back with no
    // network round trip at all - and a switchToView() issued before the
    // system has pushed this view is silently lost, stranding the user on a
    // spinner that never moves. So the switch always bounces off the timer
    // queue, which cannot run until the constructor has returned and the view
    // is on screen. This is not a "just in case" delay; it is a bug that was
    // reproduced on the watch.
    static const SWITCH_DELAY_MS = 250;

    // How often the rescue timer looks at whether this spinner is still on
    // screen after the sync it launched has ended. See armRescue().
    static const RESCUE_TICK_MS = 2000;

    // How many ticks to let pass after the sync ends before judging what is on
    // screen. finishSync() switches the view and THEN calls
    // notifySyncComplete(), so for a moment after the flag clears the system's
    // sync screen is still up and getCurrentView() is answering about a screen
    // that is on its way out.
    static const RESCUE_SETTLE_TICKS = 2;

    // How many times to try. If the switch works the next tick sees a
    // different view and stops, so a second attempt only ever happens when
    // switches are being dropped - and a rescue that retries forever would
    // build a menu every two seconds for as long as the app lived.
    static const MAX_RESCUE_ATTEMPTS = 3;

    private var _client as PocketCastsClient?;
    private var _timer as Timer.Timer?;
    private var _switchTimer as Timer.Timer?;
    private var _rescueTimer as Timer.Timer?;
    private var _settled as Number = 0;
    private var _attempts as Number = 0;
    private var _message as String?;
    private var _finished as Boolean = false;

    // The reason a list was carried forward stale this refresh
    // (PocketCastsClient.staleReason()), or null. Captured off the client in
    // onRefreshDone() before finishOnce() drops it. Turned into a toast rather
    // than a false "Up to date" - see onSwitchToMenu().
    private var _staleMsg as String?;

    // Whether to go straight on into a sync when the refresh answers, instead
    // of showing the picker. True for the hub's "Get new episodes", which is
    // the everyday route and should be one tap; false for the deliberate trip
    // to Settings > Select playlists, where stopping at the menu IS the point.
    private var _autoSync as Boolean;

    function initialize(autoSync as Boolean) {
        _autoSync = autoSync;
        // A null progress value gives the indeterminate spinner - the API
        // reports no progress, so any number here would be invented.
        ProgressBar.initialize(WatchUi.loadResource(Rez.Strings.refreshing) as String, null);

        // Outside a sync session the watch has no Wi-Fi: web requests go over
        // BLE through the Garmin Connect phone app. Worth knowing in the log,
        // because "no phone" and "bad response" look identical on screen.
        var settings = System.getDeviceSettings();
        System.println(Log.stamp() + " refresh: start, phoneConnected=" + settings.phoneConnected);

        // Scope the "we already launched a sync" flag to this refresh, so
        // backing out of a LATER spinner still cancels its requests.
        SyncStarter.clearForRefresh();

        var timer = new Timer.Timer();
        timer.start(method(:onTimeout), TIMEOUT_MS, false);
        _timer = timer;

        var client = new PocketCastsClient(method(:onRefreshDone));
        _client = client;
        client.refreshEpisodes();
    }

    // Logged only. Whether the system dispatches this to a ProgressBar
    // subclass is exactly the question that cost a device cycle, so record the
    // answer rather than depending on it.
    function onShow() as Void {
        System.println("refresh: onShow");
    }

    // Called by PocketCastsClient, once.
    function onRefreshDone(success as Boolean, message as String?) as Void {
        System.println("refresh: done success=" + success + " msg=" + message);
        // Captured before finishOnce() drops the client. Meaningful only on a
        // success (message == null); a hard failure has its own message.
        var client = _client;
        if (client != null) {
            _staleMsg = client.staleReason();
        }
        finishOnce(message);
    }

    // Called by the watchdog when nothing has come back in time.
    //
    // The two messages are the two things that can mean: with no phone the
    // request never had a link to travel over, which is the same condition
    // describeError() reports as BLE_CONNECTION_UNAVAILABLE and gets the same
    // words. With a phone, it went out and nothing came back - the phone's own
    // internet, the Garmin Connect app or the API, and nothing on the watch
    // can tell which.
    //
    // It deliberately does NOT say "Timed out": that is describeError()'s
    // answer to NETWORK_REQUEST_TIMED_OUT, which is the SDK giving up on one
    // request, whereas this is our own watchdog giving up on the whole
    // refresh. Naming the interval keeps the two apart on screen and says
    // which one you are looking at.
    function onTimeout() as Void {
        System.println("refresh: TIMED OUT after " + TIMEOUT_MS + "ms");
        var settings = System.getDeviceSettings();
        finishOnce(settings.phoneConnected
            ? "No reply in " + (TIMEOUT_MS / 1000) + "s"
            : "No phone link");
    }

    // Whichever of the callback and the watchdog gets here first wins; the
    // other is ignored. Both can genuinely fire - a request that is merely
    // slow still lands after the timeout - and switching views twice is not
    // something to find out about on the watch.
    private function finishOnce(message as String?) as Void {
        if (_finished) {
            return;
        }
        _finished = true;
        _message = message;

        var timer = _timer;
        _timer = null;
        if (timer != null) {
            timer.stop();
        }

        // Breaks the view <-> client cycle. Monkey C is reference counted; a
        // cycle is never collected. Dropped here rather than in
        // onRefreshDone(), which reads the client for its staleReason() on the
        // way past and must run first.
        if (_client != null) {
            _client = null;
        }

        var switcher = new Timer.Timer();
        switcher.start(method(:onSwitchToMenu), SWITCH_DELAY_MS, false);
        _switchTimer = switcher;
    }

    // Where the refresh goes next. Named for what it used to do only; on the
    // one-tap route it usually starts a sync instead and never builds a menu.
    function onSwitchToMenu() as Void {
        var timer = _switchTimer;
        _switchTimer = null;
        if (timer != null) {
            timer.stop();
        }

        // Not signed in, so nothing else on this screen's list of destinations
        // is reachable: the picker would show whatever was cached with no way
        // to fix anything, and the hub would say "up to date" about an account
        // it cannot see. This is the single gate for it - a first run lands
        // here, and so does a password the server has just rejected, because
        // PocketCastsClient drops the password on a 401 from /user/login.
        //
        // Before the auto-sync check on purpose. Episode audio comes off a
        // public CDN and needs no token at all, so a sync WOULD run - and
        // downloading against a stale playlist is not what someone who has
        // just been signed out is waiting for.
        if (!Auth.hasCredentials()) {
            System.println("refresh: not signed in, msg=" + _message);
            Nav.login(_message, WatchUi.SLIDE_LEFT);
            return;
        }

        // The one-tap path only carries on by itself when the fetch was clean.
        // A message is something to show, and the only screen with room to show
        // it is the picker.
        var happyRefresh = _autoSync && _message == null;

        // The whole of "one tap". The system's sync screen comes up over this
        // spinner, and GarminPocketCastsSyncDelegate.finishSync() puts the
        // playback hub underneath it before it comes down - so the user taps
        // once and ends up at their episodes.
        //
        // shouldSync() rather than hasPendingDownloads(), so a suppressed
        // retry after a fruitless sync falls through to the picker instead of
        // silently doing nothing.
        if (happyRefresh && Catalog.shouldSync()) {
            // A stale list here means something DID refresh and has episodes to
            // fetch while something else was carried forward. Sync what we
            // have, and hand the reason to SyncStarter so it reaches the hub
            // finishSync() builds on the way out.
            //
            // Reporting it HERE is what does not work, and was tried: this view
            // is covered by the system's sync screen about a second after
            // begin() returns, so a toast is gone before it can be read and
            // there is no row on a ProgressBar to write it down on. The landing
            // hub is the first screen the user is left looking at.
            System.println("refresh: auto-syncing" +
                (_staleMsg != null ? " (a list was carried stale: " + _staleMsg + ")" : ""));
            SyncStarter.begin(_staleMsg);
            armRescue();
            return;
        }

        // Nothing to fetch, and nothing wrong: the fetch worked, playlists are
        // ticked, and everything they hold is already here. Answering that
        // with the playlist picker was wrong - it puts a screen full of
        // toggles in front of someone whose question was "anything new?" and
        // makes them work out from a sub-label that the answer was no. So say
        // it and go to the episodes instead.
        //
        // Deliberately NOT hasPendingDownloads() alone: a suppressed retry
        // after a fruitless sync also has nothing pending in the sense that
        // matters here, but it is a failure and belongs on the picker with its
        // Sync failed row. shouldSync() above has already sent the healthy
        // case to the sync, so reaching here with something pending means
        // exactly that suppression.
        if (happyRefresh && !Catalog.hasPendingDownloads() &&
                Catalog.getSelectedLists().size() > 0) {
            var stale = _staleMsg;
            if (stale != null) {
                // NOT "Up to date": a list could not be fetched, so the watch
                // never saw its current contents and cannot claim there is
                // nothing new in it. The hub says which link was missing on the
                // Get new episodes row instead - the row that was pressed, and
                // the half of the answer that reaches every device.
                //
                // This is also where a refresh that fetched NOTHING lands (both
                // calls blipped, everything carried forward), which is the
                // everyday no-phone case. That used to fail hard to the picker;
                // a screen of toggles fixes nothing about a missing phone, and
                // the message it was carrying is now on the hub.
                System.println("refresh: nothing new to sync, a list was carried stale: " + stale);
                Nav.hubStatus(stale, WatchUi.SLIDE_RIGHT);
                return;
            }
            System.println("refresh: nothing new, up to date");
            // The one answer the user cannot check for themselves. They can
            // see the episode in Up Next on their phone; this says which guard
            // turned it away.
            Catalog.logWhyNothingPending();
            Nav.upToDate();
            return;
        }

        // Everything else lands on the picker, which is the one screen with
        // somewhere to explain itself: a failed fetch shows its reason, a
        // suppressed retry shows Sync failed and Download now, and a first run
        // shows the toggles the user has not ticked yet.
        System.println("refresh: switching to menu, msg=" + _message + " staleMsg=" + _staleMsg);
        // A first run or a nothing-ticked refresh with a stale list still has
        // no _message; carry the stale reason onto the picker's Refresh row so
        // that route explains itself too.
        Nav.picker(_message != null ? _message : _staleMsg, WatchUi.SLIDE_LEFT);
    }

    // The way off this spinner when the sync's own switch never arrives.
    //
    // Launching a sync is the one branch of onSwitchToMenu() that leaves this
    // view on screen deliberately: the system draws its sync screen over it,
    // and GarminPocketCastsSyncDelegate.finishSync() puts the playback hub
    // underneath before that screen comes down. By then finishOnce() has
    // stopped the watchdog, stopped the switch timer and dropped the client,
    // so that one cross-mode switchToView() is the ONLY thing left that can
    // move this view - and if it is lost the spinner turns until the app is
    // force-quit, with the sync having succeeded.
    //
    // Which is what happened on a fenix 7X (logs/2026-08-29_070047): four
    // episodes downloaded cleanly, "sync: landing on the playback hub" logged,
    // the hub built - and then the next back press was answered by
    // GarminPocketCastsRefreshDelegate, i.e. this view was still the live one.
    // A second switch, from that onBack, was lost the same way. It is not
    // every device or every sync: the same route works on a fenix 8, and the
    // fenix 7X runs where it worked all show a second hub built straight after
    // finishSync's, which is the system relaunching playback configuration
    // mode on its own and landing the user on a hub whatever we did.
    //
    // So this does not replace that switch, it backstops it: if this view is
    // still on screen once the sync is over, go to the hub. Built here rather
    // than before the sync on purpose - it is a Menu2 and will not redraw, so
    // a hub constructed on the way in would list the episodes as they stood
    // before the download.
    private function armRescue() as Void {
        _settled = 0;
        _attempts = 0;
        var timer = new Timer.Timer();
        timer.start(method(:onRescueTick), RESCUE_TICK_MS, true);
        _rescueTimer = timer;
    }

    // Nulled as well as stopped: the timer holds a Method bound back to this
    // view, so leaving the field set is a reference cycle, and Monkey C is
    // reference counted.
    private function stopRescue() as Void {
        var timer = _rescueTimer;
        _rescueTimer = null;
        if (timer != null) {
            timer.stop();
        }
    }

    function onRescueTick() as Void {
        // Still syncing. Whether a timer in this invocation runs at all while
        // sync mode is up is not confirmed on hardware - if it does not, this
        // simply starts ticking when the app comes back, which is the moment
        // that matters. Either way nothing is judged until the sync delegate
        // has ended the session.
        //
        // The flag never clearing is the case where the watch silently drops
        // startSync() and no sync mode ever comes up. That is left alone: it
        // is a device-state fault with its own diagnosis, and the spinner is
        // no worse off than before this timer existed.
        if (Catalog.isSyncFromMenu()) {
            _settled = 0;
            return;
        }

        _settled++;
        if (_settled < RESCUE_SETTLE_TICKS) {
            return;
        }

        // Identity, not type: if the user has since started ANOTHER refresh,
        // the current view is a different GarminPocketCastsRefreshView and
        // switching away from it would kill a fetch that is still running.
        // A null answer means the question could not be answered, which is not
        // grounds to stand down - the whole point is that this view can be on
        // screen when nothing thinks it is.
        if (WatchUi has :getCurrentView) {
            var current = WatchUi.getCurrentView()[0];
            if (current != null && !current.equals(self)) {
                System.println("refresh: sync landed, spinner already gone");
                stopRescue();
                return;
            }
        }

        _attempts++;
        System.println("refresh: still on the spinner after sync, attempt " + _attempts);
        if (_attempts >= MAX_RESCUE_ATTEMPTS) {
            stopRescue();
        }
        // _staleMsg rather than SyncStarter.takeStatus(): this hub REPLACES the
        // one finishSync() built and could not switch in, and finishSync spent
        // the status building it. This view has held the same reason all along,
        // so the rescue hub says what the lost one would have.
        Nav.hubStatus(_staleMsg, WatchUi.SLIDE_LEFT);
    }

}

// Backing out of the spinner abandons the fetch - unless a sync has already
// been launched off the back of it. See onBack().
class GarminPocketCastsRefreshDelegate extends WatchUi.BehaviorDelegate {

    function initialize() {
        BehaviorDelegate.initialize();
    }

    // Switched to, not popped: every config view is switched IN rather than
    // pushed (see GarminPocketCastsConfigurePlaybackDelegate), so there is
    // nothing underneath to pop back to, and popping the last view would drop
    // the user out of the app altogether. The hub is the app's home screen and
    // is built here and now, so it costs no network - which matters, because
    // "no phone" is one of the reasons to abandon a refresh in the first
    // place.
    //
    // cancelAllRequests() is the whole point of this - without it the callback
    // still fires, against a view that is no longer on screen - but it must NOT
    // run once the one-tap path has already launched a sync.
    //
    // Sync mode takes a moment to come up and this spinner is still on screen
    // while it does, so a back press in that window used to cancel the sync it
    // had just started. On device: "startSync2: How to beat the resource curse
    // in Norway", then "refresh: cancelled by user", and no onStartSync at all -
    // which reads exactly like a sync that failed for no reason. The fetch is
    // finished by then anyway; there is nothing left to abandon.
    function onBack() as Boolean {
        if (SyncStarter.launched()) {
            System.println("refresh: back during sync launch, leaving it running");
        } else {
            System.println("refresh: cancelled by user");
            Communications.cancelAllRequests();
        }
        Nav.hub(WatchUi.SLIDE_RIGHT);
        return true;
    }

}
