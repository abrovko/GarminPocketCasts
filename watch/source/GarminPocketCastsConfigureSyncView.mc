import Toybox.Lang;
import Toybox.WatchUi;

// The playlist picker: one toggle per playlist. Whatever is toggled on here is
// what GarminPocketCastsSyncDelegate downloads the next time the system runs a
// sync.
//
// The playlists come out of Storage, not off the network - GarminPocketCastsRefreshView
// is what fills it in, and is the only sanctioned route to this menu.
//
// It is OFF the everyday path. The hub's "Get new episodes" refreshes and
// syncs without stopping here, so this screen is reached deliberately -
// Settings > Select playlists - or landed on when a one-tap sync had nothing
// to do, failed, or found nothing selected. That last case is why the picker
// is also the app's error reporter: it is where the user ends up when the
// short path could not finish, and the only screen with room to say why.
class GarminPocketCastsConfigureSyncView extends WatchUi.Menu2 {

    // Identifiers for the non-episode rows, kept distinct from any Track.key
    // (which is an episode uuid).
    public static const REFRESH_ID = "__refresh";
    public static const DOWNLOAD_ID = "__download";

    // status is the outcome of the refresh that led here: null when it worked,
    // otherwise a short reason, shown against the Refresh row. This menu is
    // the only place a failed fetch can be reported - it is built once and
    // cannot redraw itself, so there is nowhere later to put the message.
    function initialize(status as String?) {
        Menu2.initialize({ :title => Rez.Strings.playlistsMenuTitle });

        // Why the last sync failed, first thing on the menu. The automatic
        // retry is suppressed after a fruitless sync, and without this row
        // that suppression is invisible - the user backs out, nothing
        // happens, and the screen offers no explanation at all.
        var syncError = Catalog.getSyncError();
        if (syncError != null) {
            addItem(new WatchUi.MenuItem(Rez.Strings.syncFailed, syncError, null, null));
        }

        // One toggle per playlist, in the order the refresh produced: Up Next
        // first, then the manual playlists. Ticking a playlist means "download
        // everything in it"; smart playlists never reach here because the
        // server sends only their rules, not their episodes.
        var ids = Catalog.getListIds();
        for (var i = 0; i < ids.size(); i++) {
            var id = ids[i];
            addItem(new WatchUi.ToggleMenuItem(
                Catalog.getListTitle(id),
                { :enabled => Rez.Strings.toggleOn, :disabled => Rez.Strings.toggleOff },
                id,
                Catalog.isListSelected(id),
                null
            ));
        }

        if (ids.size() == 0) {
            addItem(new WatchUi.MenuItem(Rez.Strings.noPlaylists, null, null, null));
        }

        // The explicit way to start the download, and it is always here.
        //
        // It used to appear only when something was already pending, which is
        // the wrong test made at the wrong moment: ticking a playlist IS the
        // moment work becomes pending, and this menu was built before that
        // happened. A Menu2 does not redraw, so the row could not grow in
        // afterwards - it turned up on the NEXT visit to a screen the user had
        // no reason to visit again, and the only way to commit what they had
        // just ticked was to guess that backing out does it.
        //
        // Unconditional, it costs one row and always names the next step.
        // Pressed with nothing to fetch it answers "Up to date" rather than
        // starting anything - see the delegate.
        //
        // Backing out still commits too, but only when a sync is not
        // suppressed - so after a failure that hidden gesture silently does
        // nothing, and this row is the way back in without resorting to Clear
        // downloads and re-ticking everything.
        addItem(new WatchUi.MenuItem(Rez.Strings.downloadNow, null, DOWNLOAD_ID, null));

        addItem(new WatchUi.MenuItem(Rez.Strings.refreshPlaylists, status, REFRESH_ID, null));
    }

}
