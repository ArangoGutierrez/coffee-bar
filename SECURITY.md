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
| v0.1.x | Yes |

v0.1.0 is tagged, and the Homebrew tap installs from that tag. `main` and the
v0.1.x line both get fixes.

`scripts/build-app.sh` derives the version from `git describe --tags`. A build
from a tagged tree reports the tag plus the commits since it, such as
`0.1.0-3-g1258578`. A release tarball carries no `.git`, so the Homebrew formula
passes the version in through `COFFEE_BAR_VERSION` instead. The `0.0.0-dev`
fallback now appears only when neither source is available. Report the commit as
well as the version.

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

The shipped code resolves no host, opens no network connection, and sends
nothing anywhere. No telemetry, no crash reporting, no analytics, no update ping.

**It does open one socket, and it is not a network socket.** Ingest listens on a
**unix domain socket** at `~/Library/Application Support/coffee-bar/ingest.sock`,
mode `0600`, so Claude Code hooks can post session events. A unix domain socket
lives in the filesystem namespace: it has no address, no port and no route off
this machine, and the file permissions are what stop another user reaching it.
`IngestListener` also calls `Darwin.connect` **against that same local path**,
once, to tell a stale socket file from one a live instance is still serving —
without that probe a second app instance would delete the running instance's
socket and kill ingest silently.

Three facts back the network claim, all checkable from a clone:

- `Sources/` reaches the network stack in exactly one place, and binds it to a
  filesystem path. `IngestListener.swift` imports `Network` and builds an
  `NWListener`, then sets `parameters.requiredLocalEndpoint = .unix(path: path)`
  at line 251, so the listener answers on a unix socket and never on an IP
  endpoint. `URLSession`, `NSURL`, `CFNetwork`, `getaddrinfo` and
  `NWConnection(host:` all return zero hits across the tree.
- The only `connect(` in `Sources/` is `IngestListener.swift`, on
  `sockaddr_un` — a filesystem path, never an IP address or a hostname.
- `Package.swift` declares no external package dependencies, so no third-party
  code is fetched or linked, and none of it can open a socket on coffee-bar's
  behalf.

This section previously read "opens no socket … `connect(` returns zero hits".
That became false when ingest landed, and a security policy that fails its own
grep is worse than no policy. The claim is now narrower and true.

One deliberate future exception is on record: an update check through a Sparkle
appcast. It is not implemented and no code for it exists today. When it lands it
will be the first outbound request in the app, and this section will describe
what it sends. Any further outbound request is opt-in, off by default, and named
here before the release that carries it.

This paragraph grants no permission to add telemetry. It records that the
question is open and states the process any answer must follow.

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
the lid closed. It is not implemented. This policy is the authoritative bound on
it, and a shipped helper that exceeds any clause below is a vulnerability under
this policy:

- It is installed through `SMAppService.daemon(plistName:)` on macOS 13 or
  later, not the deprecated `SMJobBless` path.
- It listens on an XPC Mach service through `NSXPCListener(machServiceName:)`
  and pins the protocol with `setCodeSigningRequirement(_:)` on both ends. It
  rejects any peer that does not match the app's Team ID and bundle ID.
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

`FileJournalStore` creates every directory level it makes with mode 0700 and the
journal with mode 0600. The atomic replace behind each save carries the new
file's mode rather than the destination's, so a journal an earlier build left
0644 is repaired by the next write instead of keeping that mode forever.
`Tests/CoffeeBarPowerTests/JournalStore_test.swift` asserts all of this with
`stat(2)`, after the create path and after the replace path.

One gap stays open on purpose. The store pins the mode of a directory it
*creates*; it does not chmod a directory that already exists. An unprivileged
process that repairs a path another user may control is not a fix, and item 1
puts that check on the reader instead. So a journal directory an earlier build
left 0755 keeps that mode, and the M5 helper must refuse it rather than assume
the writer corrected it. If you are reading this after M5 shipped and item 1 or
item 3 is not true of the code, that is a vulnerability. Report it.

## Things that are not vulnerabilities

- **A Homebrew-installed bundle is ad-hoc signed, not Developer ID signed.** The
  formula builds from source on your own machine, so the result carries no team
  identifier:

  ```
  codesign -dv /opt/homebrew/opt/coffee-bar/CoffeeBar.app
  Signature=adhoc
  TeamIdentifier=not set
  ```

  That is the tap's design, not a defect. Homebrew compiled the code locally, so
  the bundle never crossed a trust boundary and carries no quarantine flag.
- **A bundle built by `scripts/build-app.sh` is unsigned.** Same reason.
  Gatekeeper quarantines such a copy handed to another Mac.
- **The version carries a commit suffix, such as `0.1.0-3-g1258578`.** That is
  `git describe` output for a tree ahead of the last tag. See above.
- **coffee-bar keeps the Mac awake.** That is the product.
- **A finding produced only by a scanner, with no reproduction.** Send the steps.
