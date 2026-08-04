#!/usr/bin/env python3.12
# Copyright 2026 Carlos Eduardo Arango Gutierrez
# SPDX-License-Identifier: Apache-2.0
"""Turn captured hook payloads into public-safe fixtures.

Keeps SHAPE — every key, every type, nesting — because that is what the decode
boundary is tested against. Scrubs VALUE for anything that carries real content
or a real path. This repository is public.

Refuses to emit a fixture that still contains the real home directory, so a
missed field fails loudly instead of shipping.
"""
import json, sys, pathlib, re

HOME = str(pathlib.Path.home())
# Derived, never written out. This file is TRACKED, and the tree-wide guard in
# Tests/CoffeeBarCoreTests/FixtureRedaction_test.swift refuses to let the real
# username sit in a tracked file — a literal here would make this script the one
# file that fails its own rule. Deriving it also makes the refusal below work
# for whoever runs this next.
USERNAME = pathlib.Path(HOME).name
SRC = pathlib.Path(sys.argv[1])
DST = pathlib.Path(sys.argv[2])

# Values replaced wholesale: they carry conversation or command content.
# `reason` carries free prose on BOTH PermissionDenied and SessionEnd, and they
# mean unrelated things: 599 characters of panel text on one, the code `other`
# on the other. It is the field that leaked. `last_assistant_message` is already
# here; this closes the sibling that was missed. A key-based scrubber cannot
# tell the two meanings apart, and losing the short code is the cheaper error.
#
# The second block is Cursor's. Cursor does not nest command content under a
# `tool_input` object the way Claude Code and Codex do; it puts each piece at
# the TOP level under its own key, so every one of them needs naming here:
#   command      the shell command, on beforeShellExecution/afterShellExecution
#   output       that command's stdout, on afterShellExecution
#   content      the whole file body, on beforeReadFile
#   edits        [{old_string, new_string}], on afterFileEdit — real source
#   attachments  empty in the capture that produced these fixtures, so this one
#                is precautionary. It sits on beforeReadFile beside `content`,
#                which makes attached file bodies the only thing it can hold.
#
# Adding `command` does not touch the Claude Code or Codex fixtures. Their
# `command` lives INSIDE `tool_input`, and scrub() blanks a CONTENT_KEYS dict
# wholesale before it ever recurses into the keys below it.
CONTENT_KEYS = {"last_assistant_message", "tool_input", "tool_response",
                "prompt", "message", "background_tasks", "reason",
                "command", "output", "content", "edits", "attachments"}
# Identifiers replaced with stable fakes so tests can assert on them.
#
# `turn_id` is Codex's per-turn identifier and the analogue of Claude Code's
# `prompt_id`. It is here because it is UUID-shaped: without an entry the
# generic UUID rule in scrub_path() rewrites it to the SESSION id, and the
# fixture then claims turn_id == session_id, which no real payload does. A
# fixture that invents a shape is the one thing this corpus must never do.
# `generation_id` is deliberately NOT here, and the reason is the mirror image.
# An earlier revision mapped it, on the ASSUMPTION that a per-response id must
# be per-response. Measured instead, it is not:
#
#   33 of 33 captured lines have generation_id == conversation_id, and every
#   line that carries session_id has all three equal.
#
# The line that settles it is not the count. A one-shot `cursor-agent --print`
# run is one generation, so equality there proves nothing about the name. So:
# `create-chat` for a fixed chat id, then TWO `--resume` turns against it, each
# issuing its own command and its own reply. Two real generations, one
# conversation, and the result was ONE distinct generation_id over 8 lines. The
# conversation_id also came back equal to the chat id `create-chat` printed.
# Whatever the name suggests, this field tracks the conversation.
#
# Mapping it therefore made the fixtures claim a difference no observed payload
# has — the same fault as the paragraph above, pointed the other way. Leaving it
# out lets the generic UUID rule in scrub_path() give all three the same fake.
#
# Still unmeasured, so do not read this as universal: every line came through
# the CLI. The interactive editor is a different client and was not driven.
#
# `user_email` is not an id in the same sense, but it belongs here and not in
# CONTENT_KEYS. Cursor puts the signed-in account address on EVERY event. The
# literal "REDACTED" would drop the shape a decoder reads, so it gets a fake
# address instead. example.com is reserved by RFC 2606 and resolves nowhere.
# This is the field that would have leaked: it carries the account name, and it
# is why the refusal at the bottom of this file fired on the first Cursor run.
ID_MAP = {
    "session_id": "11111111-2222-3333-4444-555555555555",
    "prompt_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    "turn_id": "99999999-8888-7777-6666-555555555555",
    "tool_use_id": "toolu_FIXTUREFIXTUREFIXTURE01",
    "user_email": "user@example.com",
}

def scrub_path(s: str) -> str:
    """Scrub the home directory in EVERY encoding it appears in.

    Claude Code slugifies a project path into the transcript filename, turning
    every '/' into '-'. So one string can carry the same home directory twice in
    two alphabets: '/Users/<you>/src/...' and '-Users-<you>-src-...'. A
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
            # A list of objects keeps ONE element's key set, values blanked.
            # Returning a bare [] here loses the nesting this file's docstring
            # promises to keep, and the loss is not academic: one fixture is
            # the ONLY evidence a decoder author gets for its event. Cursor's
            # afterFileEdit.edits is really [{old_string, new_string}], and []
            # teaches the reader [String].
            #
            # One element, not all of them: the count is a property of the
            # capture, not of the payload shape, and a second element would
            # only repeat the same key set.
            if value and isinstance(value[0], dict):
                return [{k: "REDACTED" for k in value[0]}]
            # Empty, or a list of scalars: nothing to keep. background_tasks
            # and attachments are both empty in the captures on record, so
            # this branch is what holds those two fixtures steady.
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
    if USERNAME in text:
        sys.exit(f"REFUSING: {kind} still contains the real username")
    name = re.sub(r"(?<!^)(?=[A-Z])", "-", kind).lower() + ".json"
    (DST / name).write_text(text)
    written.append((name, len(text)))

for n, size in written:
    print(f"  wrote {n}  ({size} bytes)")
print(f"  {len(written)} fixture(s) from {len(seen)} event kind(s)")
