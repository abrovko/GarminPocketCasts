import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

class GarminPocketCastsConfigureSyncDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (!(id instanceof String)) {
            return;
        }

        if (id.equals(GarminPocketCastsConfigureSyncView.DOWNLOAD_ID)) {
            // The row is on the menu whether or not there is anything to
            // fetch, because it cannot be added at the moment ticking a
            // playlist creates the work. So pressing it with nothing pending
            // is a fair question, not a mistake, and it gets the same answer
            // the one-tap path gives: the episodes, with "Up to date" on the
            // row that was pressed there. That is also where backing out of
            // this menu with nothing pending already goes, so the two agree.
            if (!Catalog.hasPendingDownloads()) {
                System.println("onSelect: download now, nothing pending");
                Nav.upToDate();
                return;
            }

            // Deliberate retry. This is the user asking for it explicitly, so
            // it clears the suppression flag rather than being governed by it.
            System.println("onSelect: download now");
            Catalog.setSyncBlocked(false);
            Catalog.setSyncError(null);
            // No status for the landing hub. A refresh that carried a playlist
            // forward stale already said so on this menu's Refresh playlists
            // row, which the user has been looking at - repeating it on the hub
            // afterwards would report a fetch they did not just ask for.
            SyncStarter.begin(null);
            return;
        }

        // Re-fetch the playlists. This menu cannot rebuild itself, so the
        // refresh view is switched in and switches a fresh menu back. No
        // auto-sync: the user is standing in the picker, so the answer they
        // want is the refreshed menu, not a download starting under them.
        if (id.equals(GarminPocketCastsConfigureSyncView.REFRESH_ID)) {
            // Both cleared, for the same reason Download now clears them: this
            // is a deliberate press on the menu that is SHOWING the failure,
            // and the menu the refresh switches back cannot redraw - it is
            // built from Storage, so a sync error left there reappears on a
            // screen the user just asked to be refreshed and reads as the
            // refresh having failed. Measured on a fenix 8
            // (logs/2026-09-06_091420_fenix-8-51mm): a 404 on one episode, then
            // every later "refresh: done success=true" still landing on a menu
            // headed "Sync failed - Download failed (404)".
            //
            // THE PAIR MOVES TOGETHER. completeSync() sets them together and
            // Download now spends them together, and it has to stay that way:
            // clearing the message while leaving the suppression raised is the
            // worst of both, a menu whose back-out silently does nothing and
            // no longer says why.
            Catalog.setSyncBlocked(false);
            Catalog.setSyncError(null);
            Nav.refresh(false, WatchUi.SLIDE_LEFT);
            return;
        }

        // A ToggleMenuItem has already flipped by the time this is called, so
        // isEnabled() is the new state. Persist it immediately: the sync runs
        // as a separate launch of the app and can only see Storage.
        if (item instanceof WatchUi.ToggleMenuItem) {
            var enabled = item.isEnabled();
            Catalog.setListSelected(id, enabled);
            System.println("onSelect: list " + id + " -> " + enabled);

            // Unticking removes what the playlist put on the device, otherwise its
            // episodes stay in the playback list forever and their recycled
            // ids can later point at different audio. This runs AFTER the
            // selection is updated, so episodes another still-selected playlist
            // also wants are kept.
            if (!enabled) {
                Catalog.removeListDownloads(id);
            }
        }
    }

    // Backing out is the commit action, but only when there is genuinely
    // something left to fetch. Calling startSync() unconditionally sent the
    // watch back into sync mode every single time you backed out of this menu,
    // which is the download loop you hit. With nothing pending it just goes to
    // the playback menu - that is the useful destination once tracks are on the
    // device.
    //
    // BACK ALWAYS LEAVES, whether or not it starts a sync. That is not tidiness:
    // this menu used to stay on screen after SyncStarter.begin(), on the
    // assumption that the system's sync screen would cover it a moment later.
    // When the watch silently DROPS startSync2 (see "Device-state false
    // alarms" - it answers "download already in progress" and never calls
    // onStartSync) nothing covers it, so the next back press re-entered this
    // same onBack and asked for the sync again. Read off a fenix 8
    // (logs/2026-09-05_200938_fenix-8-51mm, 20:04:01/04/07): three onBack
    // lines, three identical startSync2 lines, not one onStartSync - and no
    // way out of the menu but force-quitting the app.
    function onBack() as Void {
        Catalog.logState("onBack");

        // Sync mode does not come up instantly and this menu is still live
        // while it does, so a second press in that window must not launch a
        // second sync - it just leaves, like every other back press here. Same
        // guard as GarminPocketCastsRefreshDelegate.onBack(), which has the
        // window for the same reason.
        if (SyncStarter.launched()) {
            System.println("onBack: sync already launched, leaving it running");
            Nav.hub(WatchUi.SLIDE_RIGHT);
            return;
        }

        // A sync that made no progress raises the block, and it is spent here:
        // this back-out escapes to the playback menu instead of starting the
        // same doomed sync over again. Clearing it means a deliberate second
        // visit to this menu WILL retry - the user stays in charge of that,
        // the watch just stops deciding it on its own.
        if (Catalog.isSyncBlocked()) {
            System.println("onBack: sync blocked, skipping auto-sync");
            Catalog.setSyncBlocked(false);
            Nav.hub(WatchUi.SLIDE_RIGHT);
            return;
        }

        if (Catalog.shouldSync()) {
            // Nothing to report on the hub, for the same reason as the
            // Download now row above: this menu was the screen showing it.
            SyncStarter.begin(null);
        }

        // After begin(), not instead of it, and in that order - the request
        // goes out before a Menu2 is built. Switching UNDER the system's sync
        // screen is what finishSync() already does, so a sync that does come up
        // is unaffected: it lands on its own freshly built hub either way, and
        // this one is only ever seen if the launch was dropped. Which makes
        // this the whole fix - the worst case is now "you are on the hub and
        // nothing downloaded", not a menu that answers every back press with
        // another sync request.
        Nav.hub(WatchUi.SLIDE_RIGHT);
    }

}
