"""Self-test of the shape recorder. No network, no credentials.

Here because the recorder is the part of this suite that is trusted rather
than checked: a diff that quietly missed a type change would make every other
test in the directory look reassuring for the wrong reason.
"""

from shapes import diff, merge, preserve_populated, shape_of


def test_values_are_discarded():
    assert shape_of({"token": "abc", "uuid": "def"}) == {"token": "str", "uuid": "str"}


def test_a_string_of_digits_is_not_an_int():
    """serverModified arrives as "1787685495549". That must not read as int."""
    assert shape_of({"serverModified": "1787685495549"}) == {"serverModified": "str"}
    assert shape_of({"serverModified": 1787685495549}) == {"serverModified": "int"}


def test_booleans_are_not_ints():
    assert shape_of({"manual": True}) == {"manual": "bool"}


def test_list_entries_are_merged_not_sampled():
    body = [{"uuid": "a", "duration": 1}, {"uuid": "b"}]
    assert shape_of(body) == [{"uuid": "str", "duration?": "int"}]


def test_an_always_present_key_is_not_marked_optional():
    assert shape_of([{"uuid": "a"}, {"uuid": "b"}]) == [{"uuid": "str"}]


def test_mixed_types_in_one_field_are_recorded_as_both():
    assert shape_of([{"d": 1}, {"d": None}]) == [{"d": "int | null"}]


def test_empty_arrays_shape_as_empty():
    assert shape_of({"episodes": []}) == {"episodes": []}


def test_identical_shapes_do_not_diff():
    body = {"episodes": [{"uuid": "a", "playedUpTo": 1}]}
    assert diff(shape_of(body), shape_of(body)) == []


def test_a_changed_type_is_reported_with_its_path():
    was = shape_of({"serverModified": "1"})
    now = shape_of({"serverModified": 1})
    lines = diff(was, now)
    assert len(lines) == 1
    assert "$.serverModified" in lines[0] and "str -> int" in lines[0]


def test_a_removed_field_is_reported():
    lines = diff(shape_of({"episodes": [{"url": "u"}]}), shape_of({"episodes": [{}]}))
    assert any(line.startswith("REMOVED") and "$.episodes[].url" in line for line in lines)


def test_an_added_field_is_reported():
    lines = diff(shape_of({"episodes": [{}]}), shape_of({"episodes": [{"fileType": "audio/mpeg"}]}))
    assert any(line.startswith("ADDED") and "fileType" in line for line in lines)


def test_a_field_becoming_optional_is_reported():
    was = shape_of([{"duration": 1}, {"duration": 2}])
    now = shape_of([{"duration": 1}, {}])
    lines = diff(was, now)
    assert any(line.startswith("OPTIONAL") for line in lines), lines


def test_an_empty_array_does_not_report_every_field_as_removed():
    """A quiet day on the account is not an API change."""
    was = shape_of({"episodes": [{"uuid": "a"}]})
    now = shape_of({"episodes": []})
    lines = diff(was, now)
    assert len(lines) == 1 and lines[0].startswith("EMPTY"), lines


def test_merge_of_nothing_is_an_empty_list():
    assert merge([]) == []


def test_re_recording_on_a_quiet_day_keeps_the_entry_shape():
    """--update-shapes on a day Up Next is empty must not blank the baseline.

    This is the destructive one, which is why it is checked here rather than
    trusted. Re-recording is how a deliberate API change is accepted, and the
    arrays worth recording - Up Next, playlists - are the same ones that are
    routinely empty, so re-recording on the wrong day would throw away
    everything the baseline knows about their entries.
    """
    was = shape_of({"episodes": [{"uuid": "a", "url": "b"}], "serverModified": "1"})
    now = shape_of({"episodes": [], "serverModified": "1"})
    assert preserve_populated(was, now) == was


def test_re_recording_still_accepts_a_real_type_change():
    """Preserving empty arrays must not preserve anything else."""
    was = shape_of({"episodes": [{"playedUpTo": 1}]})
    now = shape_of({"episodes": [{"playedUpTo": "1"}]})
    assert preserve_populated(was, now) == now


def test_re_recording_keeps_a_nested_array_that_went_quiet():
    was = shape_of({"episodes": [{"alternateEnclosures": [{"url": "a"}]}]})
    now = shape_of({"episodes": [{"alternateEnclosures": []}]})
    assert preserve_populated(was, now) == was


def test_re_recording_takes_added_and_dropped_fields_as_recorded():
    was = shape_of({"episodes": [{"uuid": "a", "gone": "x"}]})
    now = shape_of({"episodes": [{"uuid": "a", "added": 1}]})
    assert preserve_populated(was, now) == now
