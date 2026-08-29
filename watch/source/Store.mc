import Toybox.Application;
import Toybox.Lang;

// Reading a typed value back out of Storage, with the type check that every
// such read needs.
//
// Storage.getValue() answers PropertyValueType - anything persistable, or null
// - so every reader in this app has to narrow it before use, and a bare cast
// would be an unchecked lie that works right up until a key predates a change
// of shape. Thirteen readers across Auth, Proxy and Catalog spelled out the
// same three lines to do it:
//
//     var stored = Storage.getValue(KEY);
//     return stored instanceof String ? stored : "";
//
// The fallback is always the caller's, never assumed here, because "absent"
// means something different at each of them: no account, no proxy, the default
// speed, an empty catalog.
//
// Note this module reads only. Writes stay at their call sites: they carry
// Storage.setValue's cast to KeyType/ValueType, which is specific to the shape
// being written, and several of them log or delete-instead-of-write.
module Store {

    function getString(key as String, fallback as String) as String {
        var stored = Storage.getValue(key);
        return stored instanceof String ? stored : fallback;
    }

    // Where absent and empty have to be told apart - a missing token is not
    // the same as a blank one.
    function getStringOrNull(key as String) as String? {
        var stored = Storage.getValue(key);
        return stored instanceof String ? stored : null;
    }

    // Zero and negative are treated as absent as well as null. Every Number
    // this app stores under a defaulted key - a speed percentage, a bitrate -
    // is meaningless at or below zero, so a value that fails the test wants
    // the default rather than to be passed on to arithmetic.
    function getPositiveNumber(key as String, fallback as Number) as Number {
        var stored = Storage.getValue(key);
        if (stored instanceof Number && stored > 0) {
            return stored;
        }
        return fallback;
    }

    function getBool(key as String, fallback as Boolean) as Boolean {
        var stored = Storage.getValue(key);
        return stored instanceof Boolean ? stored : fallback;
    }

    // An empty dictionary for a key that holds none, so callers can walk the
    // answer without a null check. Note that an empty answer is therefore
    // ambiguous - it is both "nothing stored" and "stored something that is
    // not a Dictionary" - which is why Catalog.reclaimOrphans() cross-checks
    // an empty refIds against the rest of the catalog before acting on it.
    function getDict(key as String) as Dictionary<String, PersistableType> {
        var stored = Storage.getValue(key);
        if (stored instanceof Dictionary) {
            return stored as Dictionary<String, PersistableType>;
        }
        return {} as Dictionary<String, PersistableType>;
    }

    // Untyped and nullable, for the records and playlist entries whose fields
    // are checked one at a time by the caller rather than trusted wholesale.
    function getDictOrNull(key as String) as Dictionary? {
        var stored = Storage.getValue(key);
        if (stored instanceof Dictionary) {
            return stored as Dictionary;
        }
        return null;
    }

}
