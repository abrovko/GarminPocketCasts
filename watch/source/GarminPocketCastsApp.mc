import Toybox.Application;
import Toybox.Communications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Media;
import Toybox.System;
import Toybox.WatchUi;

class GarminPocketCastsApp extends Application.AudioContentProviderApp {

    // The accent colour the media player pairs with the provider icon. The doc
    // asks for a Graphics.COLOR_* value rather than a free hex, which matters
    // on the 64-colour MIP devices where an arbitrary brand red would quantise
    // to something else anyway. COLOR_RED is the nearest to Pocket Casts' own.
    private static const ACCENT_COLOR = Graphics.COLOR_RED;

    function initialize() {
        AudioContentProviderApp.initialize();
    }

    // onStart() is called on application start up.
    //
    // The build stamp goes out on every invocation - sync configuration, sync,
    // playback configuration and playback are four separate launches, so
    // whichever one a log captures, it says which binary produced it. A
    // sideloaded .prg does not take effect until the watch is restarted, and
    // "am I even running the build I just copied?" has cost real debugging
    // time here.
    function onStart(state as Dictionary?) as Void {
        // WHICH watch, as well as which build. Two devices run this app and
        // their logs land in the same logs/ tree, so a log with no device in
        // it is a guess - and the two do not behave identically (the fenix 8
        // falls back to the launcher icon for the now-playing ring where the
        // fenix 7 does not, and TextPicker caps entry at 256 characters
        // against the fenix 7's 31).
        //
        // partNumber rather than uniqueIdentifier: the question is which MODEL
        // produced the log, not which installation, and uniqueIdentifier is 40
        // characters of hash on a log with a rotation limit.
        //
        // It shares its BASE with the software_part_number in ERR_LOG.txt but
        // is not the same string - measured on one fenix 8 51mm, this reports
        // 006-B4536-00 where the crash log says 006-B4536-10. Match on
        // 006-B4536 and treat the suffix as a revision, not an identity.
        //
        // It rides on the existing build line rather than taking one of its
        // own, for that same 5 KB reason. All 57 products in manifest.xml
        // declare partNumber; guarded anyway, per getContentRefIter - the
        // check is free and the export build cannot catch its absence.
        var settings = System.getDeviceSettings();
        var part = (settings has :partNumber) ? settings.partNumber : "?";
        System.println(Log.stamp() + " build " + BuildInfo.STAMP + " on " + part);

        // Reclaim the audio of episodes finished during an earlier invocation,
        // and any audio no ref id points at any more. Here rather than at
        // SONG_EVENT_COMPLETE on purpose: onStart() runs before any content
        // iterator exists, so nothing is holding the media objects being
        // deleted.
        //
        // NOT only here, though. onStart() fires once per PROCESS, and the
        // process outlives the mode: a device log covering playback, refresh,
        // sync, playback and another refresh carried exactly one "build" line,
        // so an episode finished during it was never purged at all. Every
        // non-playback entry point below calls reclaimIdleAudio() too; the
        // orphan sweep inside it is rate-limited to once a day, so the repeat
        // calls cost a single Storage read.
        Catalog.reclaimIdleAudio();
    }

    // onStop() is called when your application is exiting
    function onStop(state as Dictionary?) as Void {
    }

    // NO onSettingsChanged() OVERRIDE HERE, AND THAT IS DELIBERATE.
    //
    // It was added to make a proxy address typed on the phone land without
    // leaving and re-entering the app, and it crashed the app on a fenix 8
    // (CIQ_LOG.YML, 2026-08-27: "Invalid Value / Failed invoking <symbol>").
    // Resolved against the matching .prg.debug.xml, the faulting pc 0x10003902
    // sat inside the override, between the entries for its first and second
    // lines - and its opening System.println never reached the device log, so
    // it died on the invocation rather than in the body. AppBase documents the
    // method from API 1.2.0 with no app-type restriction; it is nonetheless
    // not safe to override in an audio content provider on this firmware.
    //
    // Nothing is lost either way. Garmin renders app settings from an app's
    // STORE LISTING rather than from the .prg, so a sideloaded install never
    // receives a settings change for this to react to - measured, and the
    // reason the settings resources and the property-reading code they fed
    // have been removed. The TextPicker rows on Settings > Playback speed are
    // the only way a proxy is configured.

    // Get a Media.ContentDelegate for use by the system to get and iterate through media on the device
    function getContentDelegate(arg as PersistableType) as ContentDelegate {
        var startIndex = 0;
        if (arg instanceof Number) {
            startIndex = arg;
        }
        return new GarminPocketCastsContentDelegate(startIndex);
    }

    // Get a delegate that communicates sync status to the system for syncing media content to the device
    function getSyncDelegate() as Communications.SyncDelegate? {
        // Safe here: getSyncDelegate() is called BEFORE onStartSync(), so no
        // download is in flight and no ref id is waiting to be written.
        Catalog.reclaimIdleAudio();
        return new GarminPocketCastsSyncDelegate();
    }

    // Get the initial view for configuring playback
    function getPlaybackConfigurationView() as [Views] or [Views, InputDelegates] {
        // Before the menu is built, so a finished episode's row is gone the
        // first time the user comes back to the hub rather than the time
        // after. The menu is a Menu2 and will not redraw itself.
        Catalog.reclaimIdleAudio();
        var view = new GarminPocketCastsConfigurePlaybackView();
        return [ view, new GarminPocketCastsConfigurePlaybackDelegate() ];
    }

    // Get the icon the media player draws for this provider in the now-playing
    // ring. This is NOT the launcher icon, even though it is the same artwork.
    //
    // manifest.xml's launcherIcon is what Music > Music Providers lists. The
    // ring asks for this instead, and a provider that does not answer gets a
    // blank slot - silently, with nothing wrong anywhere else. Measured on a
    // fenix 7X against a fenix 8: same source, same resource, the 40x40 raster
    // verified present in the shipped .prg, correct on both, and still missing
    // from the fenix 7's ring because nothing had ever supplied it. The fenix 8
    // renders one only because its firmware falls back to the launcher icon.
    // The built-in "My Music" is the tell - a watch silhouette in the provider
    // list, a music note in the ring, i.e. two different resources.
    //
    // Guarded like startSync2 and showToast. ProviderIconInfo is API 3.0.0,
    // far below this app's 5.0.0 floor, but 8 of the 57 products in
    // manifest.xml are absent from its Supported Devices list (every fenix 9
    // variant, plus Forerunner 170 Music). The export build compiles clean
    // either way, so it will NOT catch this if the guard is dropped.
    function getProviderIconInfo() as Media.ProviderIconInfo? {
        if (!(Media has :ProviderIconInfo)) {
            return null;
        }
        return new Media.ProviderIconInfo(Rez.Drawables.LauncherIcon, ACCENT_COLOR);
    }

    // Get the initial view for configuring sync.
    //
    // This lands on the refresh spinner rather than the menu itself: the menu
    // is built from the playlists, a Menu2 is built once and never redraws,
    // so they have to be fetched before it is constructed. The refresh view
    // switches the menu in when the API answers - or when it does not.
    function getSyncConfigurationView() as [Views] or [Views, InputDelegates] {
        Catalog.reclaimIdleAudio();
        var view = new GarminPocketCastsRefreshView(false);
        return [ view, new GarminPocketCastsRefreshDelegate() ];
    }

}

function getApp() as GarminPocketCastsApp {
    return Application.getApp() as GarminPocketCastsApp;
}
