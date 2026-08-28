import Toybox.Lang;
import Toybox.System;

// A wall-clock stamp for the log lines that answer "when did the watch do
// this?".
//
// System.println() writes the line and nothing else, so a device log is a
// sequence with no times in it. That is fine for reading one session
// end-to-end and useless for the question a battery drain asks: a log pulled
// in the morning covering the whole night cannot say whether a burst of
// syncing happened at 02:00 or in the ten minutes before the pull. Both look
// identical.
//
// So the stamp goes on the handful of lines that mark the app WAKING - the
// build line, the sync-decision dumps, the start of a refresh, the media
// player asking for an iterator - rather than on everything. Stamping every
// line would cost ~9 bytes each on a log that rotates at 5 KB, which is to
// say it would buy times by throwing away history.
//
// Local time, matching what the watch face shows, because the point is to line
// a log line up against "the battery was fine when I went to bed".
module Log {

    // "HH:MM:SS", zero padded so the column stays put and the log stays
    // readable when scanned by eye.
    function stamp() as String {
        var now = System.getClockTime();
        return now.hour.format("%02d") + ":" +
            now.min.format("%02d") + ":" +
            now.sec.format("%02d");
    }

}
