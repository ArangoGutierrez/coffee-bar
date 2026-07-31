#!/usr/bin/env python3.12
"""Turn captured hook payloads into public-safe fixtures.

Keeps SHAPE — every key, every type, nesting — because that is what the decode
boundary is tested against. Scrubs VALUE for anything that carries real content
or a real path. This repository is public.

Refuses to emit a fixture that still contains the real home directory, so a
missed field fails loudly instead of shipping.
"""
import json, sys, pathlib, re

HOME = str(pathlib.Path.home())
SRC = pathlib.Path(sys.argv[1])
DST = pathlib.Path(sys.argv[2])

# Values replaced wholesale: they carry conversation or command content.
# `reason` carries free prose on BOTH PermissionDenied and SessionEnd, and they
# mean unrelated things: 599 characters of panel text on one, the code `other`
# on the other. It is the field that leaked. `last_assistant_message` is already
# here; this closes the sibling that was missed. A key-based scrubber cannot
# tell the two meanings apart, and losing the short code is the cheaper error.
CONTENT_KEYS = {"last_assistant_message", "tool_input", "tool_response",
                "prompt", "message", "background_tasks", "reason"}
# Identifiers replaced with stable fakes so tests can assert on them.
ID_MAP = {
    "session_id": "11111111-2222-3333-4444-555555555555",
    "prompt_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    "tool_use_id": "toolu_FIXTUREFIXTUREFIXTURE01",
}

def scrub_path(s: str) -> str:
    """Scrub the home directory in EVERY encoding it appears in.

    Claude Code slugifies a project path into the transcript filename, turning
    every '/' into '-'. So one string can carry the same home directory twice in
    two alphabets: '/Users/eduardoa/src/...' and '-Users-eduardoa-src-...'. A
    literal replace fixes the first and sails past the second — which is exactly
    what happened, and what the guard below caught.
    """
    s = s.replace(HOME, "/Users/USER")
    s = s.replace(HOME.replace("/", "-"), "-Users-USER")
    # Belt and braces: any remaining /Users/<name> or -Users-<name>.
    s = re.sub(r"/Users/[^/\"\s]+", "/Users/USER", s)
    s = re.sub(r"-Users-[^-\"\s]+", "-Users-USER", s)
    # The session UUID is scrubbed as a FIELD, but it reappears inside
    # transcript_path as a filename. Same value, different field: scrub it
    # wherever it occurs, or the field-level scrub is theatre.
    s = re.sub(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
               ID_MAP["session_id"], s)
    return s

def scrub(key, value):
    if key in ID_MAP:
        return ID_MAP[key]
    if key in CONTENT_KEYS:
        if isinstance(value, dict):
            # keep the key set, blank the values: shape is what we test
            return {k: "REDACTED" for k in value}
        if isinstance(value, list):
            return []
        return "REDACTED"
    if isinstance(value, str):
        return scrub_path(value)
    if isinstance(value, dict):
        return {k: scrub(k, v) for k, v in value.items()}
    if isinstance(value, list):
        return [scrub(key, v) for v in value]
    return value

seen = {}
for line in SRC.read_text().splitlines():
    try:
        d = json.loads(line)
    except Exception:
        continue
    kind = d.get("hook_event_name")
    if not kind or kind in seen:
        continue                      # one canonical fixture per kind
    seen[kind] = {k: scrub(k, v) for k, v in d.items()}

DST.mkdir(parents=True, exist_ok=True)
written = []
for kind, doc in sorted(seen.items()):
    text = json.dumps(doc, indent=2, sort_keys=True) + "\n"
    # Fail loudly rather than ship a leak.
    if HOME in text:
        sys.exit(f"REFUSING: {kind} still contains the real home directory")
    if "eduardoa" in text:
        sys.exit(f"REFUSING: {kind} still contains the real username")
    name = re.sub(r"(?<!^)(?=[A-Z])", "-", kind).lower() + ".json"
    (DST / name).write_text(text)
    written.append((name, len(text)))

for n, size in written:
    print(f"  wrote {n}  ({size} bytes)")
print(f"  {len(written)} fixture(s) from {len(seen)} event kind(s)")
