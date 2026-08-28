import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Sign in to Pocket Casts: an email row, a password row, and the button that
// tries them.
//
// Reached from Settings > Account, and landed on automatically by
// GarminPocketCastsRefreshView whenever the watch is not signed in - which
// covers a first run and a password the server has just rejected. That gate is
// the reason nothing else in the app has to check.
class GarminPocketCastsLoginView extends WatchUi.Menu2 {

    // Kept distinct from any Track.key (an episode uuid) and from the ids the
    // other menus use.
    public static const EMAIL_ID = "__email";
    public static const PASSWORD_ID = "__password";
    public static const SIGN_IN_ID = "__signin";
    public static const SIGN_OUT_ID = "__signout";

    // status is why the last attempt failed, or null. Like the picker's
    // Refresh row, this is the only place it can be said: a Menu2 is built
    // once and cannot redraw itself, so there is nowhere later to put it.
    function initialize(status as String?) {
        Menu2.initialize({ :title => Rez.Strings.account });

        var email = Auth.getEmail();
        addItem(new WatchUi.MenuItem(
            Rez.Strings.email,
            email.length() > 0 ? email : WatchUi.loadResource(Rez.Strings.notSet) as String,
            EMAIL_ID,
            null
        ));

        // The stored password is never shown, not even as a hint of its
        // length: the picker draws its initial text in the clear on a screen
        // someone else can be standing next to.
        addItem(new WatchUi.MenuItem(
            Rez.Strings.password,
            Auth.getPassword().length() > 0
                ? Auth.PASSWORD_MASK
                : WatchUi.loadResource(Rez.Strings.notSet) as String,
            PASSWORD_ID,
            null
        ));

        addItem(new WatchUi.MenuItem(Rez.Strings.signIn, status, SIGN_IN_ID, null));

        // Only worth offering when there is something to forget. This menu is
        // rebuilt on every entry, so the row appears and disappears correctly
        // without anything having to redraw.
        if (Auth.hasCredentials()) {
            addItem(new WatchUi.MenuItem(Rez.Strings.signOut, null, SIGN_OUT_ID, null));
        }
    }

}

class GarminPocketCastsLoginDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (!(id instanceof String)) {
            return;
        }

        // A TextPicker is PUSHED, and it is the one thing in this app that is.
        // Every config view is a peer switched in rather than pushed, because
        // a Menu2 left underneath is always a stale Menu2 - but a picker is a
        // modal that pops itself and hands control back to this exact menu,
        // still the only copy of itself on the stack.
        //
        // With the phone in range the picker opens a text field and a keyboard
        // on the PHONE, which is what makes entering a password on a watch
        // tolerable. The on-watch character wheel is the fallback.
        if (id.equals(GarminPocketCastsLoginView.EMAIL_ID)) {
            if (WatchUi has :TextPicker) {
                // Seeded with the stored address so fixing a typo is not a
                // retype. Every product in this manifest was checked against
                // its SDK definition and all 57 declare TextPicker, so this
                // guard is belt and braces rather than a real branch.
                WatchUi.pushView(
                    new WatchUi.TextPicker(Auth.getEmail()),
                    new GarminPocketCastsTextEntryDelegate(item, false),
                    WatchUi.SLIDE_LEFT
                );
            }
            return;
        }

        if (id.equals(GarminPocketCastsLoginView.PASSWORD_ID)) {
            if (WatchUi has :TextPicker) {
                // Deliberately NOT seeded with the stored password - see the
                // password row above.
                WatchUi.pushView(
                    new WatchUi.TextPicker(""),
                    new GarminPocketCastsTextEntryDelegate(item, true),
                    WatchUi.SLIDE_LEFT
                );
            }
            return;
        }

        if (id.equals(GarminPocketCastsLoginView.SIGN_IN_ID)) {
            if (!Auth.hasCredentials()) {
                // Nothing to try. Said on the row that was pressed, which is
                // the only place this menu can say anything.
                item.setSubLabel(Rez.Strings.enterBoth);
                WatchUi.requestUpdate();
                return;
            }

            // The refresh view IS the sign-in test: it logs in, shows a
            // spinner, has the 45s watchdog and already knows how to report a
            // failure. On success it lands on the playlist picker, which is
            // exactly where someone who has just signed in wants to be; on a
            // rejected password it comes straight back here with the reason.
            // No auto-sync - picking playlists comes first.
            WatchUi.switchToView(
                new GarminPocketCastsRefreshView(false),
                new GarminPocketCastsRefreshDelegate(),
                WatchUi.SLIDE_LEFT
            );
            return;
        }

        if (id.equals(GarminPocketCastsLoginView.SIGN_OUT_ID)) {
            // The account only. Downloaded episodes and their audio stay put
            // and keep playing - they are already on the watch and need no
            // token. Settings > Reset everything is the row that wipes those.
            Auth.signOut();
            WatchUi.switchToView(
                new GarminPocketCastsLoginView(null),
                new GarminPocketCastsLoginDelegate(),
                WatchUi.SLIDE_RIGHT
            );
            return;
        }
    }

    // Nothing underneath to pop to - see GarminPocketCastsConfigurePlaybackDelegate
    // - so backing out names its own destination. Settings, because that is
    // the deliberate route here; the automatic route (not signed in) has
    // nothing better to offer either, and Settings is one hop from the hub.
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
// It holds the MenuItem it was launched from so the row can be corrected in
// place: returning true pops the picker back to the menu underneath, and that
// menu is a Menu2 which will not rebuild itself. MenuItem.setSubLabel is API
// 3.0.0, well under this app's 5.0.0 floor, and requestUpdate() asks for the
// repaint. If a device ever turns out not to honour that, the row is still
// right the next time the menu is entered - the value itself is in Storage
// either way.
class GarminPocketCastsTextEntryDelegate extends WatchUi.TextPickerDelegate {

    private var _item as WatchUi.MenuItem;
    private var _isPassword as Boolean;

    function initialize(item as WatchUi.MenuItem, isPassword as Boolean) {
        TextPickerDelegate.initialize();
        _item = item;
        _isPassword = isPassword;
    }

    function onTextEntered(text as String, changed as Boolean) as Boolean {
        // changed is false when the user confirmed without touching anything.
        // Storing anyway would throw away a perfectly good token for no
        // reason, since setEmail/setPassword both clear it.
        if (!changed) {
            return true;
        }

        var value = Auth.trim(text);
        if (value.length() == 0) {
            // An empty entry means "never mind", not "sign me out". Sign out
            // is its own row, so there is no need to read a cleared field as a
            // request to forget the account.
            return true;
        }

        if (_isPassword) {
            Auth.setPassword(value);
            _item.setSubLabel(Auth.PASSWORD_MASK);
        } else {
            Auth.setEmail(value);
            _item.setSubLabel(value);
        }
        WatchUi.requestUpdate();
        return true;
    }

    function onCancel() as Boolean {
        return true;
    }

}
