import Toybox.Application;
import Toybox.Lang;
import Toybox.System;

// Everything to do with the Pocket Casts account: who this watch is signed in
// as, and the bearer token that proves it.
//
// The credentials are entered on the watch through WatchUi.TextPicker - with
// the phone nearby that puts a real keyboard in front of the user - and they
// live in Storage, never in the binary - anything compiled in would ship one
// account to every install and leave the password recoverable from any copy
// of the .prg.
//
// THE PASSWORD HAS TO PERSIST, not just the token. Sync configuration, sync
// and playback are separate invocations, and sync mode has no UI at all - a
// token that expires mid-sync has to be renewed silently or the sync dies with
// no way to ask anyone anything. So the password is stored and re-used, and
// what protects it is that device Storage is encrypted. Note that the
// SIMULATOR's storage is not: its copy under %TEMP%\com.garmin.connectiq is
// plaintext and readable with any text editor.
//
// Never println() a password. "pc: login failed 401" is the right amount of
// detail; the log is a plain file on a device that mounts over USB.
module Auth {

    const EMAIL_KEY = "pcEmail";
    const PASSWORD_KEY = "pcPass";

    // The bearer token, cached across app invocations because sync
    // configuration, sync and playback are three separate launches. Owned here
    // rather than by PocketCastsClient so that signOut() is obviously complete
    // - a token left behind would keep working against the old account for as
    // long as the server honoured it.
    const TOKEN_KEY = "pcToken";

    // What the password row shows. Asterisks rather than a bullet character:
    // the device fonts are not guaranteed to carry U+2022, and a row of tofu
    // boxes is a worse answer than a row of stars.
    const PASSWORD_MASK = "********";

    // --- credentials ---

    function getEmail() as String {
        var stored = Storage.getValue(EMAIL_KEY);
        return stored instanceof String ? stored : "";
    }

    function getPassword() as String {
        var stored = Storage.getValue(PASSWORD_KEY);
        return stored instanceof String ? stored : "";
    }

    // Both halves, or this watch is not signed in. A half-filled account is
    // the same as no account: the login POST would go out and come back 401,
    // which costs a round trip to learn what is already known here.
    function hasCredentials() as Boolean {
        return getEmail().length() > 0 && getPassword().length() > 0;
    }

    // Store one field. The token goes with it: a live token for the previous
    // account would keep working, so a wrong password typed over a right one
    // would look like it had been accepted until the token expired days later.
    function setEmail(email as String) as Void {
        Storage.setValue(EMAIL_KEY, trim(email));
        clearToken();
        System.println("auth: email set");
    }

    function setPassword(password as String) as Void {
        Storage.setValue(PASSWORD_KEY, trim(password));
        clearToken();
        System.println("auth: password set");
    }

    // The server said these credentials are wrong. Drop the password but KEEP
    // the email - it is almost always the password that was mistyped, and
    // making the user re-enter both punishes them for the wrong mistake.
    //
    // This is what routes them back to the sign-in screen:
    // GarminPocketCastsRefreshView sends anyone without credentials there, and
    // dropping the password is what makes hasCredentials() false.
    function rejectCredentials() as Void {
        Storage.deleteValue(PASSWORD_KEY);
        clearToken();
        System.println("auth: credentials rejected, password cleared");
    }

    function signOut() as Void {
        Storage.deleteValue(EMAIL_KEY);
        Storage.deleteValue(PASSWORD_KEY);
        clearToken();
        System.println("auth: signed out");
    }

    // --- token ---

    function getToken() as String? {
        var stored = Storage.getValue(TOKEN_KEY);
        return stored instanceof String ? stored : null;
    }

    function setToken(token as String) as Void {
        Storage.setValue(TOKEN_KEY, token);
    }

    function clearToken() as Void {
        Storage.deleteValue(TOKEN_KEY);
    }

    // --- helpers ---

    // Monkey C has no String.trim(). Text entered through a picker routinely
    // carries a trailing space - it is one wheel position away from the end of
    // the alphabet - and " user@example.com" is a 401 that looks exactly like
    // a wrong password.
    function trim(text as String) as String {
        var chars = text.toCharArray();
        var size = chars.size();
        var start = 0;
        var end = size;
        while (start < end && isBlank(chars[start])) {
            start++;
        }
        while (end > start && isBlank(chars[end - 1])) {
            end--;
        }
        if (start == 0 && end == size) {
            return text;
        }
        var cut = text.substring(start, end);
        return cut != null ? cut : "";
    }

    function isBlank(c as Char) as Boolean {
        return c == ' ' || c == '\t' || c == '\n' || c == '\r';
    }

}
