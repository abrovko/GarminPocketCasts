import Toybox.Lang;
import Toybox.WatchUi;

// Settings: everything the listener does NOT do every day.
//
// The hub's other row, "Get new episodes", is one tap from spinner to sync to
// episodes and never stops anywhere. That is the everyday path, and it works
// only because the playlist picker is off it - which is what this menu is for.
// Picking playlists, changing account, configuring the speed proxy, deleting
// an episode by hand, wiping the app and reading the build stamp are all trips
// you make rarely and deliberately, so they live one level down together.
//
// Like every Menu2 here it is built once in its constructor and cannot redraw
// itself, so anything that changes state has to switch a view in rather than
// expect this one to update.
class GarminPocketCastsSettingsView extends WatchUi.Menu2 {

    // Kept distinct from any Track.key (an episode uuid) and from the ids the
    // other menus use.
    public static const SELECT_ID = "__select";
    public static const ACCOUNT_ID = "__account";
    public static const PROXY_ID = "__proxy";
    public static const DELETE_ID = "__delete";
    public static const RESET_ID = "__reset";

    function initialize() {
        Menu2.initialize({ :title => Rez.Strings.settings });

        // The only route to the picker now, and it goes through the refresh
        // view like every other: a Menu2 is built once, so the playlists have
        // to be fetched before the menu that lists them is constructed.
        addItem(new WatchUi.MenuItem(Rez.Strings.selectPlaylists, null, SELECT_ID, null));

        // The deliberate route to sign-in. The automatic one is
        // GarminPocketCastsRefreshView, which sends anyone without credentials
        // there without being asked - so this row exists for changing an
        // account that already works, and for signing out.
        //
        // The address is the sub-label because "which account is this watch
        // on" is the only question the row can be asked from here.
        var email = Auth.getEmail();
        addItem(new WatchUi.MenuItem(
            Rez.Strings.account,
            email.length() > 0 ? email : WatchUi.loadResource(Rez.Strings.notSignedIn) as String,
            ACCOUNT_ID,
            null
        ));

        // The proxy that makes faster-than-1x playback possible at all, since
        // the watch itself has no speed control. The sub-label carries the
        // whole state - "1.5x, 64 kbps mono", or "Off" - so the common
        // question can be answered without opening it.
        addItem(new WatchUi.MenuItem(
            Rez.Strings.playbackSpeed,
            Proxy.describeState(),
            PROXY_ID,
            null
        ));

        // Removing one episode, where Reset everything removes the lot. Most
        // of the time nothing needs deleting by hand - a finished episode goes
        // on its own, and a refresh releases anything no selected playlist
        // still wants - so this is for the cases neither covers.
        addItem(new WatchUi.MenuItem(Rez.Strings.deleteEpisodes, null, DELETE_ID, null));

        addItem(new WatchUi.MenuItem(Rez.Strings.clearDownloads, null, RESET_ID, null));

        // Which binary is actually running - a sideloaded .prg does not take
        // effect until the watch is restarted, and reading a log produced by
        // the PREVIOUS binary has cost a whole debugging cycle here. One level
        // deep now rather than on the hub, which is affordable because the
        // route to it needs no network at all.
        addItem(new WatchUi.MenuItem(Rez.Strings.buildLabel, BuildInfo.STAMP, null, null));
    }

}
