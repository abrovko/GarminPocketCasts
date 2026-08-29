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
            SyncStarter.begin();
            return;
        }

        // Re-fetch the playlists. This menu cannot rebuild itself, so the
        // refresh view is switched in and switches a fresh menu back. No
        // auto-sync: the user is standing in the picker, so the answer they
        // want is the refreshed menu, not a download starting under them.
        if (id.equals(GarminPocketCastsConfigureSyncView.REFRESH_ID)) {
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
    // which is the download loop you hit. With nothing pending, go to the
    // playback menu instead - that is the useful destination once tracks are
    // on the device.
    function onBack() as Void {
        Catalog.logState("onBack");

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
            SyncStarter.begin();
            return;
        }

        Nav.hub(WatchUi.SLIDE_RIGHT);
    }

}
