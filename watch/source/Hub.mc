import Toybox.Lang;
import Toybox.WatchUi;

// "Everything is already here", said from wherever the question was asked.
//
// Two routes ask it and both must answer the same way: the one-tap refresh
// that found nothing new, and the playlist picker's Download now row pressed
// with nothing pending. That is why it is written once here rather than twice
// at the call sites.
//
// The answer is given twice over, because neither half reaches every device or
// every moment. The hub carries it on the Get new episodes row with the focus
// moved there, which works everywhere and lasts as long as the user stays on
// the screen. The toast is the immediate signal, and it is guarded: showToast
// is API level 5.2.0, above this app's 5.0.0 floor, and its device list is
// narrower still - fenix 5 Plus, fenix 6, Forerunner 645/745/945 and
// vivoactive 3/4 are all in this manifest and none of them have it. Same trap
// as startSync2, and the export build will not catch it either.
module Hub {

    // Switch to a freshly built playback hub reporting that there was nothing
    // to download. Built here and now, so it lists what is actually on the
    // device - a Menu2 cannot redraw itself, so a hub built any earlier would
    // be a stale one.
    function showUpToDate() as Void {
        var hub = new GarminPocketCastsConfigurePlaybackView();
        hub.showUpToDate();
        WatchUi.switchToView(hub, new GarminPocketCastsConfigurePlaybackDelegate(), WatchUi.SLIDE_RIGHT);

        if (WatchUi has :showToast) {
            WatchUi.showToast(Rez.Strings.upToDate, null);
        }
    }

}
