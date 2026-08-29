import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Playback configuration. On a real watch this is the entry point you get when
// you pick the app from the music sources list, so it doubles as the hub: it
// lists what is already downloaded and offers a way into the sync menu, which
// the device otherwise gives no route to.
class GarminPocketCastsConfigurePlaybackView extends WatchUi.Menu2 {

    // Identifiers for the non-episode rows, kept distinct from any Track.key
    // (which is an episode uuid).
    public static const GET_ID = "__get";
    public static const SETTINGS_ID = "__settings";

    function initialize() {
        Menu2.initialize({ :title => Rez.Strings.playbackMenuTitle });

        // One read of the whole positions map, not one per row: it is a single
        // Storage value and every episode's position is in it.
        var positions = Catalog.getPositions();

        var tracks = Catalog.getDownloadedTracks();
        System.println("hub: " + tracks.size() + " episode(s) downloaded");
        for (var i = 0; i < tracks.size(); i++) {
            var track = tracks[i];
            addItem(new WatchUi.MenuItem(track.title, describe(track, positions), track.key, null));
        }

        // An empty list gets no placeholder row, deliberately. The two rows
        // below already say what an empty hub means and what to do about it -
        // Get new episodes IS the answer - where a dead row above them read
        // as a fault: "Nothing synced" names the sync, and the everyday way
        // to arrive here is a sync that worked perfectly and episodes that
        // were then listened through.

        // The two non-episode rows, last so that everything above them is
        // something to play - this is the screen the listener lands on from
        // the watch's music sources, and nothing should sit between them and
        // the episode they came for.
        //
        // Get new episodes is the everyday one and is a single tap: refresh,
        // then straight into the sync. Everything that is not that - picking
        // playlists, the reset, the build stamp - is behind Settings, which is
        // the trip you make rarely and deliberately.
        addItem(new WatchUi.MenuItem(Rez.Strings.getEpisodes, null, GET_ID, null));
        addItem(new WatchUi.MenuItem(Rez.Strings.settings, null, SETTINGS_ID, null));
    }

    // Report that a one-tap refresh found nothing to download.
    //
    // It goes on the Get new episodes row - the one the user pressed, so the
    // answer appears where the question was asked - and the focus moves there
    // with it. Without that the message is the last row of a menu that opens
    // at the first, i.e. below however many episodes are downloaded, which on
    // a watch screen means invisible.
    //
    // Only ever set on a hub built for this purpose. Every other route builds
    // a plain one, so the message cannot survive to a visit where it would be
    // a lie.
    function showUpToDate() as Void {
        var index = findItemById(GET_ID);
        if (index < 0) {
            return;
        }
        var item = getItem(index);
        if (item == null) {
            return;
        }
        item.setSubLabel(Rez.Strings.upToDate);
        setFocus(index);
    }

    // The sublabel for one episode row.
    //
    // An episode that has been started leads with what is left of it, then the
    // podcast; one that has not is just the podcast, as before. Leading with
    // the time is deliberate - a Menu2 sublabel truncates at the END, so
    // anything placed after a podcast name is the first thing a long one eats.
    // Putting it in the title instead would lose it the same way, and worse:
    // episode titles are far longer than podcast names.
    private function describe(track as Track, positions as Dictionary<String, PersistableType>) as String? {
        var position = positions.get(track.key);
        if (!(position instanceof Number) || position <= 0) {
            return track.artist.length() > 0 ? track.artist : null;
        }

        // Duration is not always knowable - a manual playlist entry carries no
        // duration, and one only reaches us once some device has reported the
        // episode in progress. How far in the listener is answers most of the
        // same question and is always available, so it stands in rather than
        // the row saying nothing.
        var duration = track.duration;
        var progress = duration > position
            ? span(duration - position) + " left"
            : span(position) + " in";

        if (track.artist.length() == 0) {
            return progress;
        }
        return progress + " - " + track.artist;
    }

    // A rough, short span: "1h 05m", "23m", "45s". Rounded down, because
    // "23m left" reading a few seconds short of the truth costs nothing, and
    // the position it is measured from is only checkpointed at pause, stop,
    // skip and completion anyway.
    private function span(seconds as Number) as String {
        if (seconds >= 3600) {
            var minutes = (seconds % 3600) / 60;
            return (seconds / 3600).toString() + "h " + minutes.format("%02d") + "m";
        }
        if (seconds >= 60) {
            return (seconds / 60).toString() + "m";
        }
        return seconds.toString() + "s";
    }

}
