<!--
Copyright 2026 Carlos Eduardo Arango Gutierrez
SPDX-License-Identifier: Apache-2.0
-->

# Security policy

## Report a vulnerability privately

Use GitHub private vulnerability reporting:

**https://github.com/ArangoGutierrez/coffee-bar/security/advisories/new**

That route is enabled and is the one to prefer: it keeps the report private and
attaches it to this repository.

If you cannot use it, email the maintainer directly:

**arangogutierrez@gmail.com** — Carlos Eduardo Arango Gutierrez

coffee-bar is a personal project. It is not an NVIDIA product, and a report sent
to a work address will not reach the maintainer any faster.

Do not open a public issue, a discussion, or a pull request for a security
problem. A public report tells everyone at once, including the people you do not
want to tell.

Include, if you have them: the affected version or commit, the macOS version and
build, the hardware model, the steps to reproduce, and what an attacker gets.
`CONTRIBUTING.md` shows the commands that print the first three.

Expect an acknowledgement within 7 days. There is no bounty programme.

Please give the maintainer 90 days to ship a fix before you disclose publicly.
If the flaw is already exploited in the wild, say so — that shortens the clock.

## Supported versions

| Version | Supported |
|---|---|
| `main` | Yes |
| v0.1.x | Not released yet |

No release is tagged. `main` is the only thing that exists, so it is the only
thing that gets a fix. This table changes when v0.1 ships.

A build from source reports `0.0.0-dev` as its version, because
`scripts/build-app.sh` derives the version from `git describe --tags` and no tag
exists. Report the commit as well as the version.

## What coffee-bar does, and what it deliberately does not

These are the properties a security report should be measured against. Each one
is a commitment, not a description of current luck.

### It reads agent metadata only, never transcript contents

coffee-bar tracks which agent sessions are running and what state each one is
in. It does not read, parse, store, or display the contents of an agent
conversation. `transcript_path` and `~/.claude/projects/**/*.jsonl` hold
proprietary source code and secrets, and coffee-bar stays out of them.

This is a privacy commitment and it binds future work. Token accounting (M7)
does not relax it: that design uses the OTLP metrics stream, which carries
counters and attributes and no message content at all. The transcript-parsing
route to token counts is rejected by design.

If you find code that reads transcript content, that is a vulnerability under
this policy. Report it.

### It makes no network egress

The shipped code opens no socket, resolves no host, and sends nothing anywhere.
No telemetry, no crash reporting, no analytics, no update ping.

Two facts back that up, and both are checkable from a clone:

- `Sources/` contains no networking symbol. `URLSession`, `import Network`,
  `NSURL`, `CFNetwork`, `socket`, `getaddrinfo` and `connect(` all return zero
  hits across the whole source tree.
- `Package.swift` declares no external package dependencies, so no third-party
  code is fetched or linked, and none of it can open a socket on coffee-bar's
  behalf.

One deliberate future exception is on record: an update check through a Sparkle
appcast. It is not implemented and no code for it exists today. When it lands it
will be the only outbound request in the app, and this section will say so
explicitly rather than quietly.

`TelemetryRecon` is the one component whose name suggests otherwise. It reads
three local files — the Claude Code managed settings, the user settings, and the
Codex config — and looks for an OTLP endpoint that is already configured. It
inspects files. It never contacts the endpoint it finds.

### It does not influence agent behaviour

coffee-bar observes. It never returns a decision, a permission decision, or a
stop signal to an agent tool, and it never answers a prompt for you. A power
utility that can block your tool calls is a supply-chain risk, so it does not
have that power.

### It needs no root in v0.1

v0.1 holds `PreventUserIdleSystemSleep`, an unprivileged
`IOPMAssertionCreateWithName` call that any user process may make. There is no
privileged helper, no `LaunchDaemon`, no `sudo` prompt, and no kernel extension.

You can see exactly what it holds, at any time, with:

```
pmset -g assertions
```

The app's assertion is named `coffee-bar is serving`. The capability probe's is
named `coffee-bar probe baseline`. The names are deliberately distinct so a
stranded assertion can be attributed to the code that stranded it.

### What the privileged helper will be allowed to do, once M5 lands

M5 adds a root helper, `com.coffeebar.helper`, so the Mac can stay awake with
the lid closed. It is not implemented. The design in section 5.3 of
`coffee-bar-HANDOFF.md` bounds it as follows, and a shipped helper that exceeds
this is a vulnerability under this policy:

- It is installed through `SMAppService.daemon(plistName:)`, not the deprecated
  `SMJobBless` path.
- It listens on an XPC Mach service and pins the protocol with
  `setCodeSigningRequirement(_:)` on both ends. It rejects any peer that does not
  match the app's Team ID and bundle ID.
- Its verbs are a fixed list, and **none of them takes an arbitrary string**.
  There is no "run this command" and no user-supplied path to execute. The list
  is: read the S1 and S2 capability results; set `SleepDisabled`; set Spotlight
  indexing; set Time Machine; heartbeat; read current state. The last three
  power-triage verbs belong to M6 and arrive with it, not with M5.
- Every state-mutating verb takes a TTL. A helper that is left holding a setting
  after the app dies is the failure mode the watchdog exists to prevent.

The helper reads a journal file to know what to restore. That file is an
instruction to a root process, and it is treated as one. Before M5 ships, all
four of these must hold, and they are recorded in `docs/ROADMAP.md` under
"M5 security precondition":

1. The helper verifies that **every** component of the journal path is owned by
   root and is not group-writable or other-writable, before it reads anything —
   not only the final file.
2. The helper refuses to act on a journal it did not write, or one whose
   ownership or mode does not match expectation, and quarantines it instead.
3. The privileged side creates the directory and the file with explicit modes
   (`0700` and `0600`). Neither is left to whichever process created the path
   first.
4. The `armedBy` provenance in the journal — pid, binary path, uid — is advisory
   forensics, never authentication. In this threat model it is
   attacker-controlled data.

The current `FileJournalStore` writes 0755 directories and a 0644 journal, and
nothing pins those modes yet. That is harmless today, because only the
unprivileged probe reads them. It stops being harmless the day a root process
does. If you are reading this after M5 shipped and item 1 or item 3 is not true
of the code, that is a vulnerability. Report it.

## Things that are not vulnerabilities

- **The app bundle is unsigned.** `scripts/build-app.sh` says so, and Gatekeeper
  quarantines a copy handed to another Mac. Signing and notarisation are planned
  release work, not a defect in the current build.
- **The version reads `0.0.0-dev`.** No tag exists yet. See above.
- **coffee-bar keeps the Mac awake.** That is the product.
- **`Formula/coffee-bar.rb` carries a placeholder SHA-256.** No release tarball
  exists for it to hash.
- **A finding produced only by a scanner, with no reproduction.** Send the steps.
