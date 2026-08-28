import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Playback speed: the proxy that provides it, and what to ask it for.
//
// Reached from Settings > Playback speed. Four rows, and they split cleanly
// into two kinds:
//
//   Server, Token   entered once, through a TextPicker
//   Speed, Quality  changed often, cycled in place
//
// Nothing here needs the network. Configuring a proxy and finding out whether
// it works are deliberately separate: the first download is the test, and it
// reports itself the way every other sync failure does.
class GarminPocketCastsProxyView extends WatchUi.Menu2 {

    // Kept distinct from any Track.key (an episode uuid) and from the ids the
    // other menus use.
    public static const SERVER_ID = "__pxserver";
    public static const TOKEN_ID = "__pxtoken";
    public static const SPEED_ID = "__pxspeed";
    public static const QUALITY_ID = "__pxquality";

    function initialize() {
        Menu2.initialize({ :title => Rez.Strings.playbackSpeed });

        var notSet = WatchUi.loadResource(Rez.Strings.notSet) as String;

        var url = Proxy.getUrl();
        addItem(new WatchUi.MenuItem(
            Rez.Strings.proxyServer,
            url.length() > 0 ? url : notSet,
            SERVER_ID,
            null
        ));

        // Masked like the password row, and for the same reason: the picker
        // draws its initial text in the clear on a screen someone else can be
        // standing next to. Auth's mask is reused rather than duplicated so
        // the two secrets cannot come to look different.
        addItem(new WatchUi.MenuItem(
            Rez.Strings.proxyToken,
            Proxy.getToken().length() > 0 ? Auth.PASSWORD_MASK : notSet,
            TOKEN_ID,
            null
        ));

        addItem(new WatchUi.MenuItem(
            Rez.Strings.proxySpeed,
            Proxy.describeSpeed(Proxy.getSpeedPercent()),
            SPEED_ID,
            null
        ));

        addItem(new WatchUi.MenuItem(
            Rez.Strings.proxyQuality,
            Proxy.describeQuality(),
            QUALITY_ID,
            null
        ));
    }

}

class GarminPocketCastsProxyDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (!(id instanceof String)) {
            return;
        }

        // A TextPicker is PUSHED - see GarminPocketCastsLoginDelegate, which
        // explains why that is the one exception to this app's flat stack.
        // With the phone in range it opens a text field and keyboard on the
        // PHONE, which is what makes a url and a token bearable to enter here
        // at all: both can be pasted. Pasting does NOT get around the entry
        // cap, which is the device's - see Proxy.setUrl().
        if (id.equals(GarminPocketCastsProxyView.SERVER_ID)) {
            if (WatchUi has :TextPicker) {
                // Seeded WITHOUT the assumed https:// - see
                // Proxy.getUrlForEntry(). The picker's entry cap is the
                // device's own and can be as low as 31 characters, so seeding
                // with the scheme would spend eight of them before the user
                // touched anything and make a url that fitted once impossible
                // to edit.
                WatchUi.pushView(
                    new WatchUi.TextPicker(Proxy.getUrlForEntry()),
                    new GarminPocketCastsProxyTextDelegate(item, false),
                    WatchUi.SLIDE_LEFT
                );
            }
            return;
        }

        if (id.equals(GarminPocketCastsProxyView.TOKEN_ID)) {
            if (WatchUi has :TextPicker) {
                // Deliberately NOT seeded - see the mask above.
                WatchUi.pushView(
                    new WatchUi.TextPicker(""),
                    new GarminPocketCastsProxyTextDelegate(item, true),
                    WatchUi.SLIDE_LEFT
                );
            }
            return;
        }

        // Cycled in place rather than opened as a submenu. A Menu2 will not
        // rebuild itself, but setSubLabel + requestUpdate repaints one row,
        // which is all a five-value cycle needs - and it keeps the whole
        // setting one tap deep.
        if (id.equals(GarminPocketCastsProxyView.SPEED_ID)) {
            var percent = Proxy.cycleSpeed();
            item.setSubLabel(Proxy.describeSpeed(percent));
            WatchUi.requestUpdate();
            System.println("proxy: speed " + percent);
            return;
        }

        if (id.equals(GarminPocketCastsProxyView.QUALITY_ID)) {
            Proxy.cycleQuality();
            item.setSubLabel(Proxy.describeQuality());
            WatchUi.requestUpdate();
            System.println("proxy: quality " + Proxy.getBitrate() + "k mono=" + Proxy.getMono());
            return;
        }
    }

    // Nothing underneath to pop to - every config view is a peer switched in
    // rather than pushed - so backing out names its own destination. Settings
    // is where this was reached from, and it is rebuilt here so its Playback
    // speed row shows whatever was just changed.
    function onBack() as Void {
        WatchUi.switchToView(
            new GarminPocketCastsSettingsView(),
            new GarminPocketCastsSettingsDelegate(),
            WatchUi.SLIDE_RIGHT
        );
    }

}

// Catches one TextPicker's answer and puts it away.
//
// The same shape as GarminPocketCastsTextEntryDelegate, which does this for
// the Pocket Casts account. Kept separate rather than generalised: the two
// write to different modules and treat an empty entry differently, and a
// shared version would need a callback for the setter to buy very little.
class GarminPocketCastsProxyTextDelegate extends WatchUi.TextPickerDelegate {

    private var _item as WatchUi.MenuItem;
    private var _isToken as Boolean;

    function initialize(item as WatchUi.MenuItem, isToken as Boolean) {
        TextPickerDelegate.initialize();
        _item = item;
        _isToken = isToken;
    }

    function onTextEntered(text as String, changed as Boolean) as Boolean {
        if (!changed) {
            return true;
        }

        var value = Auth.trim(text);
        var notSet = WatchUi.loadResource(Rez.Strings.notSet) as String;

        // An empty entry DOES clear the field here, unlike the account rows.
        // Clearing either half is how the proxy is turned off, and there is
        // no separate row to do it with - where the account has an explicit
        // Sign out.
        if (_isToken) {
            if (value.length() == 0) {
                Storage.deleteValue(Proxy.TOKEN_KEY);
                _item.setSubLabel(notSet);
            } else {
                Proxy.setToken(value);
                _item.setSubLabel(Auth.PASSWORD_MASK);
            }
        } else {
            if (value.length() == 0) {
                Storage.deleteValue(Proxy.URL_KEY);
                _item.setSubLabel(notSet);
            } else {
                Proxy.setUrl(value);
                // Read back rather than echoed: setUrl trims and drops any
                // trailing slash, and the row should show what was stored.
                _item.setSubLabel(Proxy.getUrl());
            }
        }

        WatchUi.requestUpdate();
        return true;
    }

    function onCancel() as Boolean {
        return true;
    }

}
