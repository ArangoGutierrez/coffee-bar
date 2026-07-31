#!/usr/bin/env python3
# Copyright 2026 Carlos Eduardo Arango Gutierrez
# SPDX-License-Identifier: Apache-2.0
"""End-to-end checks for scripts/redact-hook-fixtures.py.

The scrubber is the component that leaked. 599 characters of real session prose
reached origin/main inside permission-denied.json, because `reason` was not in
CONTENT_KEYS. It had no test at all, and that absence is HOW the key was missed.

These run the real script as a subprocess against a real temp capture. Nothing is
mocked: the scrubber reads argv at module scope, so importing it is not possible
without lying about argv, and the thing worth testing is the emitted file anyway.

Run: python3 scripts/redact-hook-fixtures_test.py
"""
import json
import pathlib
import subprocess
import sys
import tempfile

SCRIPT = pathlib.Path(__file__).with_name("redact-hook-fixtures.py")

# A sentinel that cannot collide with anything real, standing in for the prose
# that leaked. The real markers are NOT reproduced here; this file is tracked.
PROSE = ("SENTINEL-LEAK-PROSE-9f3a2c this stands in for free prose captured from "
         "a live session. It is long enough to matter and it must not survive "
         "the scrubber under any key that carries free text.")


def run_scrubber(events: list[dict]) -> dict[str, dict]:
    """Run the real script over `events`; return {filename: parsed json}."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        # Deliberately NOT the real capture filename: that name is itself one of
        # the forbidden content markers, and this file is tracked. The redaction
        # guard caught exactly that when this test was first written.
        src = tmp / "events.jsonl"
        dst = tmp / "out"
        src.write_text("".join(json.dumps(e) + "\n" for e in events))
        proc = subprocess.run([sys.executable, str(SCRIPT), str(src), str(dst)],
                              capture_output=True, text=True)
        if proc.returncode != 0:
            raise AssertionError(
                f"scrubber exited {proc.returncode}\nstdout: {proc.stdout}\nstderr: {proc.stderr}")
        return {p.name: json.loads(p.read_text()) for p in sorted(dst.glob("*.json"))}


def test_reason_is_scrubbed_on_permission_denied() -> None:
    """The named bug: a re-capture re-emits the prose that reached origin/main.

    `reason` carries free prose on PermissionDenied. If it is not treated as a
    content key, the scrubber passes it through untouched and the leak ships
    again. Deleting "reason" from CONTENT_KEYS turns this red.
    """
    out = run_scrubber([{"hook_event_name": "PermissionDenied",
                         "reason": PROSE,
                         "tool_name": "Write"}])
    doc = out["permission-denied.json"]

    assert doc["reason"] == "REDACTED", (
        f"reason survived the scrubber as {doc['reason'][:60]!r}...; "
        "free prose in this field is what reached origin/main")
    assert PROSE not in json.dumps(doc), "the prose survives somewhere in the document"


def test_reason_is_scrubbed_on_session_end_too() -> None:
    """Same key, unrelated meaning, same treatment.

    On SessionEnd `reason` is a short code such as `other`. Losing it to
    REDACTED is acceptable; letting the PermissionDenied sibling through is not.
    A key-based scrubber cannot tell the two apart, and this pins that choice.
    """
    out = run_scrubber([{"hook_event_name": "SessionEnd", "reason": "other"}])
    assert out["session-end.json"]["reason"] == "REDACTED"


def test_shape_survives_the_scrub() -> None:
    """Scrub VALUES, keep SHAPE — the decode boundary is tested against shape.

    A scrubber that dropped keys would make every fixture decode-test vacuous.
    """
    out = run_scrubber([{"hook_event_name": "PermissionDenied",
                         "reason": PROSE,
                         "tool_name": "Write",
                         "session_id": "deadbeef-0000-1111-2222-333344445555"}])
    doc = out["permission-denied.json"]
    assert set(doc) == {"hook_event_name", "reason", "tool_name", "session_id"}, (
        f"the scrubber changed the key set to {sorted(doc)}")
    assert doc["tool_name"] == "Write", "a value carrying no content was rewritten"


def test_the_real_home_directory_never_reaches_the_output() -> None:
    """A nested real home directory is scrubbed, in both of its alphabets.

    Named bug this catches: Claude Code slugifies a project path into the
    transcript filename, so one capture carries the same home directory as
    `/Users/<name>/...` AND as `-Users-<name>-...`. A literal replace fixes the
    first and sails past the second. Breaking either branch of `scrub_path`
    turns this red.

    The script also refuses outright if anything slips through, so this asserts
    the invariant the script promises rather than the branch it takes.
    """
    home = str(pathlib.Path.home())
    out = run_scrubber([{"hook_event_name": "PermissionDenied",
                         "reason": "x",
                         "note": {"plain": home + "/src/thing",
                                  "slug": home.replace("/", "-") + "-src-thing"}}])
    text = json.dumps(out["permission-denied.json"])
    assert home not in text, "the real home directory survived in its plain form"
    assert home.replace("/", "-") not in text, (
        "the real home directory survived in its slugified form; "
        "that is the encoding a literal replace sails past")


def main() -> int:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for t in tests:
        try:
            t()
            print(f"PASS {t.__name__}")
        except AssertionError as exc:
            failed += 1
            print(f"FAIL {t.__name__}: {exc}")
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
