import Toybox.Lang;
import Toybox.WatchUi;

// Every move between the app's configuration screens.
//
// EVERY CONFIG VIEW IS A PEER ON A FLAT STACK. NOTHING IS EVER PUSHED. The
// hub, the refresh spinner, the playlist picker, Settings, the account menu,
// the proxy menu and the delete menu all switchToView between each other, so
// there is never a second copy of any of them underneath. That is load-bearing
// rather than tidy: they are all Menu2s or a ProgressBar, none of which can
// redraw itself, so a copy left below is always a STALE copy - back onto a
// pushed hub after a sync and it lists the episodes as they stood before the
// download. (The one exception is WatchUi.TextPicker, which is a modal that
// pops itself straight back to the single menu that launched it.)
//
// The cost of a flat stack is that backing out has to NAME its destination -
// there is nothing to pop to, and popping the last view drops the user out of
// the app. So these calls appear at the end of almost every onBack() as well
// as on the forward paths.
//
// It is a module rather than 23 copies of the same three lines because the
// error is silent: a view switched in beside the wrong delegate compiles, runs,
// draws correctly and then answers no input. Pairing each view with its
// delegate exactly once is the whole point.
//
// Each view is built HERE AND NOW, at the moment of the switch, never earlier.
// A Menu2 is built once in its constructor and will not redraw, so a menu
// constructed before the thing it reports on - a hub built before the sync
// that fills it, a picker built before the refresh that lists its playlists -
// shows the state as it stood beforehand.
//
// The transition is the caller's: the same destination is a forward move from
// one screen and a way back from another, and only the caller knows which.
module Nav {

    // The app's home screen, and where everything backs out to eventually. It
    // costs no network, which matters - "no phone" is one of the reasons to
    // abandon a refresh in the first place.
    function hub(transition as WatchUi.SlideType) as Void {
        WatchUi.switchToView(
            new GarminPocketCastsConfigurePlaybackView(),
            new GarminPocketCastsConfigurePlaybackDelegate(),
            transition
        );
    }

    // The hub, reporting that a refresh found nothing to download.
    //
    // Two routes ask that question and both must answer the same way: the
    // one-tap "Get new episodes" that found nothing new, and the picker's
    // "Download now" row pressed with nothing pending.
    //
    // The answer is given twice over, because neither half reaches every
    // device or every moment. The hub carries it on the Get new episodes row
    // with the focus moved there, which works everywhere and lasts as long as
    // the user stays on the screen. The toast is the immediate signal, and it
    // is guarded: showToast is API level 5.2.0, above this app's 5.0.0 floor,
    // and its device list is narrower still - fenix 5 Plus, fenix 6,
    // Forerunner 645/745/945 and vivoactive 3/4 are all in this manifest and
    // none of them have it. Same trap as startSync2, and the export build will
    // not catch it either.
    function upToDate() as Void {
        // Built and marked before the switch: a Menu2 cannot redraw, and the
        // message is only ever set on a hub built for this purpose so it
        // cannot survive to a visit where it would be a lie.
        var view = new GarminPocketCastsConfigurePlaybackView();
        view.showUpToDate();
        WatchUi.switchToView(view, new GarminPocketCastsConfigurePlaybackDelegate(), WatchUi.SLIDE_RIGHT);

        if (WatchUi has :showToast) {
            WatchUi.showToast(Rez.Strings.upToDate, null);
        }
    }

    // Everything the listener does NOT do every day.
    function settings(transition as WatchUi.SlideType) as Void {
        WatchUi.switchToView(
            new GarminPocketCastsSettingsView(),
            new GarminPocketCastsSettingsDelegate(),
            transition
        );
    }

    // The spinner, which owns the playlist fetch. autoSync is what makes the
    // hub's "Get new episodes" a single tap: true goes straight on into the
    // sync, false stops at the picker because the picker IS the destination.
    function refresh(autoSync as Boolean, transition as WatchUi.SlideType) as Void {
        WatchUi.switchToView(
            new GarminPocketCastsRefreshView(autoSync),
            new GarminPocketCastsRefreshDelegate(),
            transition
        );
    }

    // The playlist picker. status is why the refresh that led here failed, or
    // null - this menu is the only screen in the app with anywhere to say it.
    function picker(status as String?, transition as WatchUi.SlideType) as Void {
        WatchUi.switchToView(
            new GarminPocketCastsConfigureSyncView(status),
            new GarminPocketCastsConfigureSyncDelegate(),
            transition
        );
    }

    // The account menu. status is why the last sign-in attempt failed, or null.
    function login(status as String?, transition as WatchUi.SlideType) as Void {
        WatchUi.switchToView(
            new GarminPocketCastsLoginView(status),
            new GarminPocketCastsLoginDelegate(),
            transition
        );
    }

    function proxy(transition as WatchUi.SlideType) as Void {
        WatchUi.switchToView(
            new GarminPocketCastsProxyView(),
            new GarminPocketCastsProxyDelegate(),
            transition
        );
    }

    function deleteEpisodes(transition as WatchUi.SlideType) as Void {
        WatchUi.switchToView(
            new GarminPocketCastsDeleteView(),
            new GarminPocketCastsDeleteDelegate(),
            transition
        );
    }

}
