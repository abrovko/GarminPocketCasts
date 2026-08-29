import Toybox.Lang;
import Toybox.Media;
import Toybox.System;
import Toybox.WatchUi;

class GarminPocketCastsSettingsDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (!(id instanceof String)) {
            return;
        }

        // To the picker, by way of the refresh. No auto-sync: the user came
        // here to change what is ticked, so the menu is the destination rather
        // than something to pass through.
        if (id.equals(GarminPocketCastsSettingsView.SELECT_ID)) {
            Nav.refresh(false, WatchUi.SLIDE_LEFT);
            return;
        }

        if (id.equals(GarminPocketCastsSettingsView.ACCOUNT_ID)) {
            Nav.login(null, WatchUi.SLIDE_LEFT);
            return;
        }

        if (id.equals(GarminPocketCastsSettingsView.PROXY_ID)) {
            Nav.proxy(WatchUi.SLIDE_LEFT);
            return;
        }

        if (id.equals(GarminPocketCastsSettingsView.DELETE_ID)) {
            Nav.deleteEpisodes(WatchUi.SLIDE_LEFT);
            return;
        }

        if (id.equals(GarminPocketCastsSettingsView.RESET_ID)) {
            // A genuine reset: the audio AND every key this app owns, so the
            // next launch behaves exactly like a first install. Anything less
            // has repeatedly produced a reset that looked like a no-op,
            // because whatever was left behind put the state straight back.
            System.println("reset: wiping downloads and storage");
            Media.resetContentCache();
            Catalog.reset();

            // Straight to a freshly built hub, which now reads empty - that is
            // the whole point of the row, and this menu cannot redraw itself
            // to show anything.
            Nav.hub(WatchUi.SLIDE_RIGHT);
            return;
        }
    }

    function onBack() as Void {
        Nav.hub(WatchUi.SLIDE_RIGHT);
    }

}
