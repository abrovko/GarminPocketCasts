import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// The playback-speed transcoding proxy: where it lives, what proves us to it,
// and what to ask it for.
//
// The watch cannot vary playback rate - there is no speed control anywhere in
// Media.PlaybackProfile - so the only way to listen at 1.5x is for the audio
// to arrive already sped up. A small service (see proxy/ in this repo) pulls
// the episode from its podcast CDN, runs it through ffmpeg's atempo filter and
// streams the result back.
//
// SPEED IS NOT THE MAIN PRIZE. Re-encoding to 64 kbps mono shrinks an episode
// about threefold, and that matters more: at full size a ~37 MB download has
// never once completed on this hardware. So 100 (unchanged speed) is a
// perfectly sensible setting - it takes the size win and leaves the audio
// alone.
//
// ENTIRELY OPTIONAL. With nothing configured the app behaves exactly as it
// always has, and a configured proxy that cannot be reached falls back to the
// original url at full size. A dead server must cost the listener speed, never
// episodes.
//
// Laid out like Auth.mc, which owns the other set of credentials this app
// holds, and for the same reason: sync configuration, sync and playback are
// separate launches, so anything that has to outlive one of them lives in
// Storage. Note that Settings > Reset everything calls Storage.clearValues(),
// which takes these keys with it - correct, since that row means "behave like
// a first install", but worth knowing before someone reports it as a bug.
module Proxy {

    const URL_KEY = "pxUrl";        // String, base url with no trailing slash
    const TOKEN_KEY = "pxTok";      // String, the bearer token
    const SPEED_KEY = "pxSpeed";    // Number, percent: 150 means 1.5x
    const BITRATE_KEY = "pxRate";   // Number, kbps
    const MONO_KEY = "pxMono";      // Boolean

    // The phone-side settings, and what we last took from them.
    //
    // INERT ON A SIDELOADED INSTALL - see resources/settings/settings.xml for
    // the measurement. Garmin draws the settings UI from an app's store
    // listing rather than from the .prg, so nothing appears on the phone until
    // this app is published. readProperty() then simply answers null and the
    // TextPicker rows are the only way in, which is why the 31-character cap
    // they carry still shapes everything around them.
    const URL_PROP = "proxyServerProp";
    const TOKEN_PROP = "proxyTokenProp";
    const URL_SEEN_KEY = "pxUrlSeen";
    const TOKEN_SEEN_KEY = "pxTokSeen";

    // Speed travels as an integer percentage rather than a Float because the
    // number is written into every downloaded episode's record and divides
    // its playback position forever after. An integer round-trips through
    // Storage exactly; a Float invites a rounding difference between the
    // value written and the value read.
    const DEFAULT_SPEED = 150;
    const DEFAULT_BITRATE = 64;
    const DEFAULT_MONO = true;

    // --- what is configured ---

    function getUrl() as String {
        var stored = Storage.getValue(URL_KEY);
        return stored instanceof String ? stored : "";
    }

    function getToken() as String {
        var stored = Storage.getValue(TOKEN_KEY);
        return stored instanceof String ? stored : "";
    }

    // Both halves, or this watch has no proxy - exactly like
    // Auth.hasCredentials(). A url with no token is a round trip that can only
    // come back 401, which costs a request to learn what is already known
    // here; and clearing either row is how the feature is turned off.
    function isEnabled() as Boolean {
        return getUrl().length() > 0 && getToken().length() > 0;
    }

    // Normalise what was typed into a url we can actually request.
    //
    // THE SCHEME IS OPTIONAL, and that is not a convenience - it is what makes
    // the setting enterable at all. WatchUi.TextPicker caps entry at 31
    // characters on this hardware, and its constructor takes an initial string
    // and nothing else: there is no length parameter to raise. "https://" is
    // eight of those characters, more than a quarter of the budget, spent on
    // something that is the same every time. So a bare host is accepted and
    // https is assumed, which leaves 31 for the address itself.
    //
    // An explicit scheme is still honoured when there is room for it, because
    // a proxy on the local network is plain http and has a short host anyway.
    //
    // Trailing slashes come off here too, once, rather than being worked
    // around at every call site that appends a path.
    function setUrl(url as String) as Void {
        var value = Auth.trim(url);

        // Walked over a char array rather than by repeated substring: String
        // substring is declared nullable, so the string form needs a null
        // check on every iteration to say something this simple. Auth.trim
        // sidesteps it the same way.
        var chars = value.toCharArray();
        var end = chars.size();
        while (end > 0 && chars[end - 1] == '/') {
            end--;
        }
        if (end < chars.size()) {
            var cut = value.substring(0, end);
            value = cut != null ? cut : "";
        }

        if (value.length() > 0 && !hasScheme(value)) {
            value = "https://" + value;
        }

        Storage.setValue(URL_KEY, value);
        System.println("proxy: server set");
    }

    // Case-insensitive, because a picker that starts every entry with a
    // capital is a normal thing for a watch to do.
    function hasScheme(value as String) as Boolean {
        var lower = value.toLower();
        return lower.find("http://") == 0 || lower.find("https://") == 0;
    }

    // What to seed the TextPicker with when the row is opened again.
    //
    // NOT getUrl(). Seeding with the stored url would hand back the "https://"
    // that setUrl() just added, spending eight of the picker's 31 characters
    // before the user has typed anything - so a url that fitted when it was
    // entered could not be edited afterwards. The default scheme comes off
    // again here; an explicit http:// stays, because dropping it would
    // silently promote a local proxy to https on the next edit.
    function getUrlForEntry() as String {
        var value = getUrl();
        if (value.toLower().find("https://") == 0) {
            var cut = value.substring(8, value.length());
            return cut != null ? cut : "";
        }
        return value;
    }

    // Never println a token. The device log is a plain file on something that
    // mounts over USB.
    function setToken(token as String) as Void {
        Storage.setValue(TOKEN_KEY, Auth.trim(token));
        System.println("proxy: token set");
    }

    function clear() as Void {
        Storage.deleteValue(URL_KEY);
        Storage.deleteValue(TOKEN_KEY);
        System.println("proxy: cleared");
    }

    // --- settings from the phone ---

    // Take anything new from Garmin Connect Mobile and put it in Storage.
    //
    // PROPERTIES ARE AN INPUT CHANNEL, NOT THE STORE. Everything else in this
    // app reads Storage, and that does not change: this copies a value across
    // when the phone offers a different one. Keeping Storage as the single
    // thing read is what stops the watch rows and the phone settings becoming
    // two sources of truth that disagree.
    //
    // The "seen" keys are what make a watch edit survive. Copying whenever the
    // property merely DIFFERS from Storage would undo an on-watch change at
    // the next entry point, every time, since the property still holds the old
    // address. Comparing against the last value we consumed instead means the
    // phone only wins when the phone actually changed - and an empty value is
    // a change like any other, so clearing the setting clears the watch.
    function applyPhoneSettings() as Void {
        consumePhoneValue(URL_PROP, URL_SEEN_KEY, URL_KEY, true);
        consumePhoneValue(TOKEN_PROP, TOKEN_SEEN_KEY, TOKEN_KEY, false);
    }

    function consumePhoneValue(
        propKey as String,
        seenKey as String,
        storeKey as String,
        isUrl as Boolean
    ) as Void {
        var incoming = readProperty(propKey);
        if (incoming == null) {
            // No properties on this device or in this context. The TextPicker
            // rows are still there, so there is nothing to report.
            return;
        }

        var value = Auth.trim(incoming);
        var stored = Storage.getValue(seenKey);
        var seen = stored instanceof String ? stored : "";
        if (value.equals(seen)) {
            return;
        }

        Storage.setValue(seenKey, value);

        if (value.length() == 0) {
            Storage.deleteValue(storeKey);
        } else if (isUrl) {
            setUrl(value);
        } else {
            setToken(value);
        }

        // Never the value itself for the token - the device log is a plain
        // file on something that mounts over USB.
        System.println("proxy: " + (isUrl ? "server" : "token") + " updated from phone settings");
    }

    // Read one property, or null if this build cannot.
    //
    // Guarded AND wrapped. The guard is the usual one for anything whose
    // availability is not guaranteed across 57 products; the try/catch covers
    // a key the property store does not carry, which is what a device would do
    // if app settings turned out not to reach an audio content provider at
    // all. Either way the answer is null, the TextPicker rows keep working,
    // and nothing crashes - which is the whole reason this is additive rather
    // than a replacement for them.
    function readProperty(key as String) as String? {
        if (!(Application has :Properties)) {
            return null;
        }
        try {
            var value = Properties.getValue(key);
            return value instanceof String ? value : null;
        } catch (e) {
            return null;
        }
    }

    // --- speed ---

    // The speeds offered, in the order the Speed row cycles through them.
    // A function rather than a const because a Monkey C const has to be a
    // compile-time literal and an array is not one.
    function speeds() as Array<Number> {
        return [100, 125, 150, 175, 200] as Array<Number>;
    }

    function getSpeedPercent() as Number {
        var stored = Storage.getValue(SPEED_KEY);
        if (stored instanceof Number && stored > 0) {
            return stored;
        }
        return DEFAULT_SPEED;
    }

    function setSpeedPercent(percent as Number) as Void {
        Storage.setValue(SPEED_KEY, percent);
    }

    // Advance to the next offered speed, wrapping. A stored value that is not
    // in the list any more - an older build offered a different set - lands on
    // the default rather than sticking.
    function cycleSpeed() as Number {
        var list = speeds();
        var current = getSpeedPercent();
        var next = DEFAULT_SPEED;
        for (var i = 0; i < list.size(); i++) {
            if (list[i] == current) {
                next = list[(i + 1) % list.size()];
                break;
            }
        }
        setSpeedPercent(next);
        return next;
    }

    // "1.5x". Built here so the Speed row and the Playback speed row on the
    // Settings menu cannot describe the same number two different ways.
    function describeSpeed(percent as Number) as String {
        var whole = percent / 100;
        var fraction = percent % 100;
        if (fraction == 0) {
            return whole.toString() + "x";
        }
        if (fraction % 10 == 0) {
            return whole.toString() + "." + (fraction / 10).toString() + "x";
        }
        return whole.toString() + "." + fraction.format("%02d") + "x";
    }

    // --- quality ---

    // Bitrate and channel count move together, so they are offered as presets
    // rather than as two rows. 64k mono leads because speech survives it
    // comfortably and it is what makes the download three times smaller.
    function bitrates() as Array<Number> {
        return [64, 96, 128] as Array<Number>;
    }

    function monoFlags() as Array<Boolean> {
        return [true, true, false] as Array<Boolean>;
    }

    function getBitrate() as Number {
        var stored = Storage.getValue(BITRATE_KEY);
        if (stored instanceof Number && stored > 0) {
            return stored;
        }
        return DEFAULT_BITRATE;
    }

    function getMono() as Boolean {
        var stored = Storage.getValue(MONO_KEY);
        if (stored instanceof Boolean) {
            return stored;
        }
        return DEFAULT_MONO;
    }

    // Bitrate and mono are stored as themselves rather than as an index into
    // the preset list: an index would silently change meaning the day another
    // preset is inserted, and these values are sent to the server verbatim.
    function cycleQuality() as Void {
        var rates = bitrates();
        var monos = monoFlags();
        var rate = getBitrate();
        var mono = getMono();

        var next = 0;
        for (var i = 0; i < rates.size(); i++) {
            if (rates[i] == rate && monos[i] == mono) {
                next = (i + 1) % rates.size();
                break;
            }
        }

        Storage.setValue(BITRATE_KEY, rates[next]);
        Storage.setValue(MONO_KEY, monos[next]);
    }

    // "64 kbps mono"
    function describeQuality() as String {
        var channels = getMono()
            ? WatchUi.loadResource(Rez.Strings.qualityMono) as String
            : WatchUi.loadResource(Rez.Strings.qualityStereo) as String;
        return getBitrate().toString() + " kbps " + channels;
    }

    // Roughly how many bytes a proxied episode of this length will arrive as.
    // 0 when it cannot be worked out, which the caller must treat as unknown.
    //
    // This exists because the transcode is streamed: the response is chunked
    // and carries no Content-Length, so the system hands
    // :fileDownloadProgressCallback a null fileSize and the sync bar loses its
    // within-track denominator. The watch can work the denominator out for
    // itself - the output is CBR at a bitrate we chose, of a duration we
    // already know - and being a few percent out only means the bar fills
    // slightly early or late.
    //
    // NEVER SEND THIS TO THE SERVER AS A CONTENT-LENGTH. HTTP requires the
    // body to be exactly that many bytes: too high and the client waits for
    // data that never comes, too low and the tail is cut off. On this path
    // that would hand the watch a silently truncated episode which it would
    // cache as a complete one - trading a cosmetic problem for a corrupt
    // download.
    function expectedBytes(contentSeconds as Number) as Number {
        if (contentSeconds <= 0) {
            return 0;
        }
        // Float throughout: a long episode at a high bitrate multiplies into
        // the hundreds of millions, and the intermediate steps of the integer
        // form get close enough to the 32-bit ceiling to be worth avoiding.
        var fileSeconds = (contentSeconds.toFloat() * 100.0) / getSpeedPercent().toFloat();
        var bytes = fileSeconds * getBitrate().toFloat() * 125.0;   // kbps -> bytes/s
        if (bytes <= 0.0 || bytes > 2000000000.0) {
            return 0;
        }
        return bytes.toNumber();
    }

    // What the Playback speed row on the Settings menu says about itself, so
    // the state is readable without opening the submenu.
    function describeState() as String {
        if (!isEnabled()) {
            return WatchUi.loadResource(Rez.Strings.proxyOff) as String;
        }
        return describeSpeed(getSpeedPercent()) + ", " + describeQuality();
    }

}
