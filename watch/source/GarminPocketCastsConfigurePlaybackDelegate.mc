import Toybox.Lang;
import Toybox.Media;
import Toybox.WatchUi;

class GarminPocketCastsConfigurePlaybackDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (!(id instanceof String)) {
            return;
        }

        // The everyday route, and the reason it is one tap: the refresh view
        // is told to go straight on into the sync rather than stopping at the
        // playlist picker. It only stops there when the short path cannot
        // finish - the fetch failed, nothing is ticked, or there is nothing
        // new - which is the same screen that would explain any of those.
        //
        // Switched to, not pushed. The hub, the refresh spinner, the picker
        // and Settings are all peers - every route between them ends in a
        // switchToView to a freshly built one - so leaving a copy of this menu
        // underneath would only ever be a STALE copy. It is a Menu2 and cannot
        // redraw itself, so backing onto it after a sync would show the
        // episodes as they stood before the download.
        if (id.equals(GarminPocketCastsConfigurePlaybackView.GET_ID)) {
            WatchUi.switchToView(
                new GarminPocketCastsRefreshView(true),
                new GarminPocketCastsRefreshDelegate(),
                WatchUi.SLIDE_LEFT
            );
            return;
        }

        if (id.equals(GarminPocketCastsConfigurePlaybackView.SETTINGS_ID)) {
            WatchUi.switchToView(
                new GarminPocketCastsSettingsView(),
                new GarminPocketCastsSettingsDelegate(),
                WatchUi.SLIDE_LEFT
            );
            return;
        }

        // startPlayback() exits this app and relaunches it in playback mode. The
        // argument is handed straight back to GarminPocketCastsApp.getContentDelegate(),
        // which is how the chosen starting track survives the relaunch.
        var tracks = Catalog.getDownloadedTracks();
        for (var i = 0; i < tracks.size(); i++) {
            if (tracks[i].key.equals(id)) {
                Media.startPlayback(i);
                return;
            }
        }
    }

}
