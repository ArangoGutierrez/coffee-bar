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

### It never elevates its own privilege

v0.1 holds `PreventUserIdleSystemSleep`, an unprivileged
`IOPMAssertionCreateWithName` call that any user process may make. v0.1 needed
no root at all: no privileged helper, no `LaunchDaemon`, no `sudo` prompt, and
no kernel extension.

**Three of those four promises change in v0.2, and they are restated here rather
than quietly dropped.** Lid-closed mode installs a `LaunchDaemon` —
`com.coffeebar.probewatchdog` — and it needs `sudo`. The kernel-extension
promise does not change: coffee-bar ships no kernel extension and will not.

The one that matters most is the one that does not change either. **coffee-bar
never elevates its own privilege.** The root path in v0.2 is opt-in, and *you*
are the one who takes it: you type `sudo coffee-bar-probe arm` in your own
shell. The app shows no authorization prompt, installs no privileged helper of
its own, and has no route to becoming root. It cannot elevate itself, and it
cannot ask you to elevate it.

The menu bar app itself still holds only the unprivileged assertion. It cannot
arm lid-closed mode, cannot install that daemon, and cannot revert one. It
prints the command for you to run — the same posture it already takes with hook
configuration, where it prints the snippet and refuses to write
`~/.claude/settings.json` for you.

You can see exactly what it holds, at any time, with:

```
pmset -g assertions
```

The app's assertion is named `coffee-bar is serving`. The capability probe's is
named `coffee-bar probe baseline`. The names are deliberately distinct so a
stranded assertion can be attributed to the code that stranded it.

### What the privileged path may do, now that M5 has shipped

M5 adds a root path so the Mac can stay awake with the lid closed. It ships as a
**root CLI plus a launchd watchdog**: you run `sudo coffee-bar-probe arm`, and
that installs the daemon `com.coffeebar.probewatchdog`, which supervises the
setting and puts it back. This policy is the authoritative bound on that path,
and a shipped binary that exceeds any clause below is a vulnerability under this
policy:

- **There is no XPC service and no Mach service.** Nothing on the privileged
  path listens for callers, so there is no peer to authenticate and no other
  local process that can ask it for anything.
- Its verbs are a fixed list, and **none of them takes an arbitrary string**.
  There is no "run this command" and no user-supplied path to execute.
  The complete verb list is `run`, `arm`, `report`, `revert` and `watchdog`.
- The program the daemon executes is resolved inside the installer and is never
  taken from an argument. Accepting one turned `sudo coffee-bar-probe arm` into
  a one-line root persistence primitive, measured, and the shipped interface
  cannot express it at all.
- Every state-mutating verb takes a TTL. `ProbeVerb.defaultTTLSeconds` gives 30
  minutes when you name none, and `JournalRecord.maxTTLSeconds` caps it at 8
  hours however much you ask for. A root process still holding a setting after
  whatever armed it has gone is the failure the watchdog exists to prevent.
- Supervision is **TTL-only**. There is no heartbeat channel, because there is
  no channel at all. Nothing cuts a hold short when the work finishes early, so
  the 30-minute default is deliberately the worst case rather than the cap.
- The daemon uses the built-in battery floor of 15% and **does not read your
  `batteryFloorPercent` setting**. A root process reading an unprivileged user's
  preferences is a new data flow into a privileged process, and it deserves its
  own review before it exists rather than after.
- **A thermal or battery abort restores the setting you had, not a safe one.**
  The revert writes the journal's recorded `priorValue`, which is deliberate:
  the daemon undoes what it did and never overrides a choice it did not make.
  The consequence is worth stating plainly, because §8.1 calls thermal pressure
  the real risk. If you had already set `SleepDisabled` yourself before arming,
  the abort hands that value back and the machine still refuses to sleep. The
  abort ends coffee-bar's hold; it is not a thermal safety cutout for the
  machine, and it is the one case where aborting does not reduce the risk.
  Clear your own `SleepDisabled` if you want the machine to sleep on heat.

#### Why there is no XPC helper, and what would bring one back

This section used to require the opposite, and it was written before anything
was built. The false premise is replaced rather than deleted: the rule it was
reaching for still stands, and the reasoning is the record of a decision.

What the shipped code does NOT do — each one refused structurally by
`noTargetOnThePrivilegedPathReachesForXPCOrSMAppService` in
`Tests/CoffeeBarUITests/AppLayerBoundary_test.swift`:

- coffee-bar registers no `SMAppService` daemon.
- It opens no `NSXPCListener`, and it publishes no `machServiceName`.
- It does not use the deprecated `SMJobBless` path either.
- It cannot pin a peer with `setCodeSigningRequirement(_:)`, and that is the
  measurement the whole decision turns on.

The only bundle that ships today is built from source by the Homebrew formula,
so it carries no team identifier and no certificate chain:

```
$ codesign -dvvv /opt/homebrew/Cellar/coffee-bar/0.1.1/CoffeeBar.app
Signature=adhoc          TeamIdentifier=not set
$ codesign -v -R='anchor apple generic' <that app>   ->  rc=1  FAILS
```

A peer check that cannot be satisfied is not a weaker helper. It is an
unauthenticated root service that accepts any local caller, which is strictly
worse than the CLI that shipped — a command you type has exactly one caller, and
you are it.

There is no route back to the XPC design until two things change: a Developer ID
certificate, and a signed bundle to attach it to. Until both exist, the peer
pinning this policy would otherwise demand cannot be met on the one channel that
users actually have.

The privileged side reads a journal file to know what to restore. That file is
an instruction to a root process, and it is treated as one. All four of these
hold in the shipped code, and they are recorded in `docs/ROADMAP.md` under
"M5 security precondition":

1. Before it reads a single byte, the reader verifies the journal's whole path,
   not only the final file. **Two different bars apply**, and
   `GuardedJournalReader` enforces both:
   - **Every ancestor** is owned by root and is neither group-writable nor
     other-writable. An ancestor may be `0755`, and that is deliberate rather
     than lax: `/`, `/Library` and `/Library/Application Support` are all
     root-owned `0755` in production, so an owner-only rule applied to ancestors
     would refuse every journal on every Mac.
   - **The journal's own directory is exactly `0700`**, and nothing looser
     passes. The journal file is exactly `0600`, and nothing looser passes. A
     `0755` directory is refused; so is a `0640` file, which is unwritable by
     anyone else and still leaks the `armedBy` provenance to every account on
     the machine.
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

One gap stays open on purpose, and the reader is what closes it. The store pins
the mode of a directory it *creates*; it does not chmod a directory that already
exists. An unprivileged process that repairs a path another user may control is
not a fix, and item 1 puts that check on the reader instead. So a journal
directory an earlier build left 0755 keeps that mode — and `GuardedJournalReader`
refuses it rather than assume the writer corrected it.

**This document used to contradict itself here, and the shipped code follows the
stricter reading.** Item 1 asked only that every component be root-owned and not
group- or other-writable, which a `0755` directory satisfies, while this
paragraph demanded that the helper refuse exactly that. Item 1 now states the
rule the code enforces, so the two agree. If item 1 or item 3 is not true of the
code you are reading, that is a vulnerability. Report it.

#### What refusing a journal costs you

A journal that fails these checks is refused, and refusing it has a price you
should be able to find before you meet it. The privileged side **discards the
journal's `priorValue`** — untrusted data cannot be allowed to name the value a
root process restores — and forces `SleepDisabled` to `false` instead.

**If you had genuinely set `disablesleep` yourself, you lose that setting.**
That is the deliberate direction. Refusing to trust the file cannot mean leaving
the machine awake for ever, which is the exact failure the watchdog exists to
prevent, and an untrusted file cannot tell us which of the two you wanted. Until
now this cost was recorded only in code comments and in a line on standard error
that launchd captures, which is not somewhere a user looks.

The refused journal is quarantined rather than deleted. It still proves
something was armed, and it is the only evidence of why a machine stopped
sleeping, so it is renamed and left for you to find.

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
