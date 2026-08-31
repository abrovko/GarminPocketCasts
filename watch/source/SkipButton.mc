import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Media;
import Toybox.WatchUi;

// A transport button that draws its own art, so the number on the skip
// buttons is the number the app actually skips.
//
// The stock skip icons have "30" baked into them. Garmin's own doc for
// PlaybackProfile.skipBackwardTimeDelta says as much - "When overriding the
// default value, it will be necessary to provide a custom icon for the skip
// backward button, as the default indicates 30 seconds" - so the art does not
// follow the delta, and a 10 second skip drawn on a 30 second button is
// simply wrong. Forward happens to agree with the default, but it is
// overridden too: a hand-drawn 10 beside Garmin's stock 30 would not read as
// a pair.
//
// Media.SystemButton is the right base and Media.CustomButton is not. A
// SystemButton replaces the ART of an existing PLAYBACK_CONTROL_*, leaving
// the system to perform the seek; a CustomButton replaces the ACTION, calling
// ContentDelegate.onCustomButton() instead - and there is no seek API to
// implement it with, so that route loses the skip entirely.
//
// getImage() may also return a 24-bit RRGGBB Number, which recolours the
// stock icon. That is no use here: it would recolour the wrong number.
class SkipButton extends Media.SystemButton {

    // Loaded on demand and held for the life of the button, which is the life
    // of the PlaybackProfile and so of one playback session. getImage() is a
    // draw-time call - re-reading the resource on every repaint would be a
    // decode per frame.
    private var _iconId as ResourceId;
    private var _detailId as ResourceId;
    private var _icon as BitmapResource?;
    private var _detail as BitmapResource?;

    function initialize(control as Media.PlaybackControl, iconId as ResourceId, detailId as ResourceId) {
        SystemButton.initialize(control, null);
        _iconId = iconId;
        _detailId = detailId;
    }

    // Point the button at a different pair of drawables. The app scales the
    // skip delta by playback speed, so a queue that steps to an episode
    // encoded at another speed needs a glyph naming that speed's number -
    // see GarminPocketCastsContentIterator.getPlaybackProfile(). Only ever
    // called from a profile rebuild, which happens on a speed change and not
    // on the hot per-frame getPlaybackProfile() calls, so dropping the cached
    // bitmaps here costs one reload per speed transition, not per draw.
    function retarget(iconId as ResourceId, detailId as ResourceId) as Void {
        if (iconId == _iconId && detailId == _detailId) {
            return;
        }
        _iconId = iconId;
        _detailId = detailId;
        _icon = null;
        _detail = null;
    }

    // Signature is the SDK's exactly - see rule 8. The player's callback
    // signatures are runtime assertions, and a declaration that merely looks
    // equivalent throws "Unexpected Type Error" at the first draw.
    //
    // state and highlighted are both ignored. A skip button has no on/off or
    // disabled state to draw, and the highlight is the player's own framing
    // rather than something it asks us to draw differently.
    //
    // MEASURED on a fenix 8, 2026-08-29, by logging every distinct request
    // for one session: the playback screen and the control dial BOTH ask for
    // (image=BUTTON_IMAGE_ICON, state=BUTTON_STATE_DEFAULT, highlighted=false)
    // and nothing else. So on that device the detail art is never drawn, and
    // the two surfaces cannot be sized apart - they share one bitmap.
    //
    // The detail branch stays anyway. It is under a kilobyte in the .prg, the
    // measurement covers one of 57 products, and a device that does ask for
    // BUTTON_IMAGE_DETAIL would otherwise get art built for half the size.
    function getImage(image as Media.ButtonImage, state as Media.ButtonState, highlighted as Lang.Boolean) as Graphics.BitmapType or Graphics.ColorType or Null {
        if (image == Media.BUTTON_IMAGE_DETAIL) {
            var detail = _detail;
            if (detail == null) {
                detail = WatchUi.loadResource(_detailId) as BitmapResource;
                _detail = detail;
            }
            return detail;
        }
        var icon = _icon;
        if (icon == null) {
            icon = WatchUi.loadResource(_iconId) as BitmapResource;
            _icon = icon;
        }
        return icon;
    }
}
