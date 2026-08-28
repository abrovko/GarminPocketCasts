"""Response shape recording, and the diff that tells you what changed.

An assertion says something broke. A shape snapshot says WHAT broke, which is
the whole point of this suite: the Pocket Casts web API is unofficial and has
no changelog, so the question is never "is it down" but "did the field we read
move".

A shape is the response with every value replaced by its type name. That makes
the snapshots safe to commit to a public repo - no token, no email, no episode
titles, nothing about what the account listens to - and it makes them stable,
so a diff is real drift rather than today's queue being different from
yesterday's.

Keys absent from some entries of a list are marked with a trailing "?". That
is deliberate: the everyday failure of an API like this one is not a field
vanishing, it is a field becoming optional and the watch reading null.
"""

import json

SCALARS = {
    str: "str",
    bool: "bool",
    int: "int",
    float: "float",
    type(None): "null",
}


def shape_of(value):
    """The type skeleton of a decoded JSON value. Values are discarded."""
    t = type(value)
    if t in SCALARS:
        return SCALARS[t]
    if isinstance(value, dict):
        return {k: shape_of(v) for k, v in sorted(value.items(), key=lambda kv: str(kv[0]))}
    if isinstance(value, list):
        if not value:
            return []
        return [merge([shape_of(v) for v in value])]
    return "unknown:" + t.__name__


def merge(shapes):
    """Collapse the shapes of a list's entries into one.

    Entries of the same array routinely differ - an Up Next entry may or may
    not carry `duration` - and recording only the first would bake today's
    accident into the baseline.
    """
    if not shapes:
        return []

    if all(isinstance(s, dict) for s in shapes):
        present, values = {}, {}
        for s in shapes:
            for raw, v in s.items():
                key = raw[:-1] if raw.endswith("?") else raw
                values.setdefault(key, []).append(v)
                if not raw.endswith("?"):
                    present[key] = present.get(key, 0) + 1
        out = {}
        for key in sorted(values):
            name = key if present.get(key, 0) == len(shapes) else key + "?"
            out[name] = merge(values[key])
        return out

    if all(isinstance(s, list) for s in shapes):
        inner = [i for s in shapes for i in s]
        return [merge(inner)] if inner else []

    labels = sorted({s if isinstance(s, str) else json.dumps(s, sort_keys=True) for s in shapes})
    return labels[0] if len(labels) == 1 else " | ".join(labels)


def preserve_populated(expected, actual):
    """Merge a fresh shape over a stored one, keeping entry shapes it lost.

    An array that is empty today records as `[]`, which would overwrite the
    entry shape recorded on a day the account had something in it - and it is
    exactly the arrays that matter (Up Next, playlists) that are routinely
    empty. Re-recording on the wrong day would silently throw away everything
    the baseline knows about their entries.

    Only ever ADDS back what an empty array would have dropped. A field that
    genuinely changed type still records its new type, because that is the
    drift --update-shapes is for.
    """
    if isinstance(expected, dict) and isinstance(actual, dict):
        want = {k.rstrip("?"): (k, v) for k, v in expected.items()}
        out = {}
        for raw, value in actual.items():
            key = raw.rstrip("?")
            out[raw] = preserve_populated(want[key][1], value) if key in want else value
        return out

    if isinstance(expected, list) and isinstance(actual, list):
        if expected and not actual:
            return expected
        if expected and actual:
            return [preserve_populated(expected[0], actual[0])]
        return actual

    return actual


def diff(expected, actual, path="$"):
    """Human-readable drift between a stored shape and a fresh one.

    Returns a list of lines, empty when they agree. Phrased as what the API
    did, not as what the assertion wanted, because that is the sentence you
    want to read at 11pm when the watch has stopped syncing.
    """
    lines = []

    if isinstance(expected, dict) and isinstance(actual, dict):
        want = {k.rstrip("?"): (k, v) for k, v in expected.items()}
        have = {k.rstrip("?"): (k, v) for k, v in actual.items()}
        for key in sorted(set(want) | set(have)):
            here = path + "." + key
            if key not in have:
                lines.append("REMOVED  " + here + "  (was " + _label(want[key][1]) + ")")
            elif key not in want:
                lines.append("ADDED    " + here + "  (" + _label(have[key][1]) + ")")
            else:
                was_opt, now_opt = want[key][0].endswith("?"), have[key][0].endswith("?")
                if was_opt != now_opt:
                    lines.append(
                        "OPTIONAL " + here + "  ("
                        + ("always present -> sometimes missing" if now_opt
                           else "sometimes missing -> always present") + ")"
                    )
                lines.extend(diff(want[key][1], have[key][1], here))
        return lines

    if isinstance(expected, list) and isinstance(actual, list):
        if expected and actual:
            lines.extend(diff(expected[0], actual[0], path + "[]"))
        elif expected and not actual:
            lines.append("EMPTY    " + path + "  (no entries returned, so nothing to compare)")
        elif actual and not expected:
            lines.append("FILLED   " + path + "  (baseline was recorded from an empty array)")
        return lines

    if expected != actual:
        lines.append("TYPE     " + path + "  " + _label(expected) + " -> " + _label(actual))
    return lines


def _label(shape):
    return shape if isinstance(shape, str) else json.dumps(shape, sort_keys=True)
