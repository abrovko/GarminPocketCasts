import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Delete one downloaded episode at a time.
//
// Reached from Settings > Delete episodes. Tapping a row deletes that
// episode's audio and takes it off the hub.
//
// IT IS NOT ON THE HUB, AND IT CANNOT BE. On the hub a tap means "play this",
// and Menu2 offers exactly one gesture - there is no long press, no swipe and
// no secondary action to hang a delete on. Putting deletion behind its own
// screen is what makes the tap unambiguous, and it belongs in Settings for the
// same reason Reset everything does: a trip you make rarely and deliberately.
//
// No confirmation, matching Reset everything, which wipes far more with a
// single tap. The screen's title is the warning.
class GarminPocketCastsDeleteView extends WatchUi.Menu2 {

    function initialize() {
        Menu2.initialize({ :title => Rez.Strings.deleteEpisodes });

        var tracks = Catalog.getDownloadedTracks();
        System.println("delete: " + tracks.size() + " episode(s) to choose from");

        for (var i = 0; i < tracks.size(); i++) {
            var track = tracks[i];
            // The podcast rather than the remaining time: this screen is about
            // identifying the right episode before throwing it away, and the
            // show name is what tells two similarly titled ones apart.
            addItem(new WatchUi.MenuItem(track.title, track.artist, track.key, null));
        }

        if (tracks.size() == 0) {
            addItem(new WatchUi.MenuItem(Rez.Strings.noEpisodes, null, null, null));
        }
    }

}

class GarminPocketCastsDeleteDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (!(id instanceof String)) {
            // The "nothing downloaded" placeholder.
            return;
        }

        // Straight through removeDownload rather than the purge queue: the
        // user is standing here asking for it, so there is nothing to defer
        // and no player to work around - playback is its own invocation and
        // cannot be running while this menu is on screen. It takes the audio,
        // the ref id and the record together, which is what keeps the media
        // cache and Storage in step (rule 5: ref ids get recycled).
        System.println("delete: removing " + id);
        Catalog.removeDownload(id);

        // And record that it was not wanted, or the next sync fetches it
        // straight back - removeDownload() takes the audio, the ref id and the
        // record, and getPendingTracks() works off the PLAYLISTS, which still
        // list it. Deleting an episode and watching it return is not a delete.
        //
        // markFinished, deliberately NOT markPlayed. They are different
        // claims: finished is local and means "not on this watch", while
        // played tells the whole account you listened to it and changes the
        // episode on every other device. Only the listener can say the second,
        // and deleting something is often exactly the opposite statement.
        Catalog.markFinished(id);

        // And take it off Up Next, if that is where it came from. This is the
        // half the user actually asked for - "delete" that leaves the episode
        // queued on every other device is not a delete - and it is a claim
        // about the QUEUE only. Still no markPlayed: removing something from a
        // queue says you do not want it, where played says you listened to it,
        // and deleting is often exactly the opposite statement.
        Catalog.queueUpNextRemoval(id);

        // Rebuilt rather than repainted - a Menu2 cannot drop a row - and
        // switched rather than pushed, like every other view here, so there is
        // never a stale copy underneath.
        Nav.deleteEpisodes(WatchUi.SLIDE_IMMEDIATE);
    }

    function onBack() as Void {
        Nav.settings(WatchUi.SLIDE_RIGHT);
    }

}
