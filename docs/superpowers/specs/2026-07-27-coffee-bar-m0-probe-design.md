# coffee-bar M0 — Capability Probe Design

**Status:** approved design, pre-implementation
**Date:** 2026-07-27
**Source brief:** `coffee-bar-HANDOFF.md` (§2, §3, §8, §9, §10, §13)
**Milestone:** M0 — gate before M1

---

## 1. What this is, and what it is not

The product is a **native macOS menu-bar app** for a general-public audience. This
document specifies M0 only: a capability probe that answers the load-bearing spikes the
architecture branches on, before any UI exists.

The probe is a **gate, not a deliverable**. Its CLI is a developer convenience. Design
effort goes into the engine modules the app will consume; the CLI is a thin harness over
them.

Handoff §0 is explicit: *"Do not start with UI. Start with the capability probe (M0)."*
S1 decides whether the product has three pillars or two (§11), and that answer is wanted
before UI is built for a feature that may not exist.

### Audience consequence

The target user is not a developer. Therefore **no safety guarantee may depend on a human
running a command.** A non-technical user with a stuck `SleepDisabled` flag will not type
`sudo pmset -a disablesleep 0`; they will have a laptop that stopped sleeping and no
explanation.

- Every recovery path is automatic: launchd watchdog, plus the app self-healing on launch
  when it finds a dirty journal.
- The CLI `revert` verb is a developer escape hatch. It is never the answer in
  user-facing documentation or support replies.

---

## 2. Verified environment

Measured in-session on the target machine, 2026-07-27. Every number below came from a
command run against this tree, not from memory.

| Property | Value |
|---|---|
| macOS | 26.5.2, build 25F84 |
| Arch | arm64, internal battery present (laptop) |
| Swift | 6.3.3 (swiftlang-6.3.3.1.3) |
| Toolchain | CommandLineTools only — **no full Xcode** |
| SwiftPM + IOKit | builds and runs; `IOPMAssertionCreateWithName` returned `rc=0` |
| `swift test` | **fails** — no `XCTest` module *and* no `Testing` module |
| Builds | must run **unsandboxed** (clang module cache is outside the sandbox allowlist) |
| SIP | enabled |
| `/Library/LaunchDaemons` | 28 third-party entries (Docker, Microsoft, FleetDM) — non-Apple daemons are well-precedented here |
| Machine management | corporate-managed: FleetDM MDM, Microsoft Defender DLP incl. `dlp_processor_install_monitor` |

### Two findings that settle open questions in the handoff

**`SleepDisabled` persists across reboot — confirmed, not assumed.**
`/Library/Preferences/com.apple.PowerManagement.plist` is the on-disk store. Its
`SystemPowerSettings` dict is exactly what `pmset -g` prints as "System-wide power
settings" (`DestroyFVKeyOnStandby` appears in both). A system-wide power setting written
there survives reboot by construction. This confirms handoff §2.2 and refutes any claim
that a dirty flag self-heals on restart. `disablesleep` appears **0 times** in `man pmset`
— "undocumented" is literal.

**S8 is answered for this machine: §15.4 mode 1 ("Own it") is available.**
No `/Library/Application Support/ClaudeCode/managed-settings.json`; no `OTEL_*` or
`TELEMETRY` keys in `~/.claude/settings.json`. This contradicts the guess in handoff §16
Q7. Caveat: the machine is MDM-managed, so managed settings could be pushed later — the
probe must re-check at runtime, never cache this verdict.

### Live observation motivating §6.1

`pmset -g live` currently reports sleep prevented by **Claude plus three separate
`caffeinate` processes**, and `displaysleep 0` — display sleep is actively held by
`caffeinate`, with `Display Sleep Timer` set to 0 on both AC and Battery in the plist.
The behaviour §6.1 exists to fix is happening on the author's machine right now.

---

## 3. Decisions

Decisions taken during design, with the reasoning that produced them.

| # | Decision | Rationale |
|---|---|---|
| D1 | Probe code is the **seed of M3**, in a shared module | The journal/TTL/watchdog is written once in `CoffeeBarPower`; M3's privileged helper consumes that same code. Removes the duplication objection by construction and makes this production-grade code, not a prototype. |
| D2 | Handoff spike numbering is **authoritative** | The kickoff engine renumbered S3–S6 to mean different things. Two documents using "S4" for different spikes is a defect. Engine numbering rejected. |
| D3 | M0 covers S1, S2, S3, S5 + baseline + S8 recon | S4 (Cursor CLI hooks) is a *runtime* hook-firing test, not config inspection, and does not belong in a power-capability CLI. S6 (battery drain harness) is a multi-hour measurement protocol. Both ship as separate non-CLI spikes. |
| D4 | S1/S2 use a two-phase `arm`/`report` flow | A single CLI run cannot verify lid-close behaviour: it needs root, a physical lid close, and 10 minutes. |
| D5 | Revert guarantee enforced by a **launchd LaunchDaemon** | Only option satisfying all five §8.2 clauses including reboot recovery. Needs no Xcode and no code signing. M3 changes only the *install* mechanism (`SMAppService`) and adds XPC; the journal/TTL/revert core carries over unchanged. Alternatives fail on the walked-away-operator and reboot cases — which, for a general-public audience, is everyone. |
| D6 | `priorValue` is stored and restored | If a user deliberately set `disablesleep 1` before arming, we restore *their* state rather than clobbering it to 0. |
| D7 | No production code until `swift test` runs | Neither test framework exists locally yet. TDD is not negotiable, so implementation waits for Xcode; CI on GitHub macOS runners (Xcode preinstalled) provides the gate in the meantime. |
| D8 | Distribution: notarised DMG + Sparkle primary; Homebrew secondary | General public ≠ Homebrew users. §13.3 rules out the App Store (privileged helper, `KERN_PROCARGS2`, writes to `~/.claude`). Cask is a convenience channel over the same notarised artifact; the M0 CLI formula builds from source. |

---

## 4. Architecture

Module layout scaffolds handoff §13.1 but populates only M0's three targets. Dependency
direction is strictly one-way: `Probe → Power → Core`. `Core` depends on nothing.

```
Package.swift            Swift 6, strict concurrency, .macOS(.v14)
Sources/
  CoffeeBarCore/         Foundation ONLY. Pure, no syscalls, no I/O.
                         SpikeID, Verdict, ProbeReport, JournalRecord,
                         WatchdogDecision, decide().
  CoffeeBarPower/        The syscall boundary, behind protocols.
                         IOKit assertions, thermal, IOPS battery, libproc,
                         pmset + launchctl invocation, journal persistence.
  CoffeeBarProbe/        executable `coffee-bar-probe`. Wires Core + Power,
                         formats JSON and human output. No logic of its own.
Tests/
  CoffeeBarCoreTests/    exhaustive, hermetic, CI-safe
  CoffeeBarPowerTests/   boundary tests with injected fakes and PATH shims
```

`CoffeeBarCore` has **zero Apple-framework dependencies beyond Foundation** (§13.1). This
is what makes the policy logic testable in CI without a Mac in the loop, and what lets M3
reuse the watchdog brain unchanged. `Core` never learns that `pmset` exists.

### CLI surface

Five verbs, split by privilege. `--json` on any verb switches to machine output.

| Verb | Root | Purpose |
|---|---|---|
| `run` (default) | no | Unprivileged spikes S3, S5, S8 + assertion/thermal/battery baseline |
| `arm --ttl <s>` | yes | S1/S2 phase 1: journal → set flag → install watchdog → start sampler |
| `report` | no | S1/S2 phase 2: read sample log + journal, emit verdict |
| `revert [--force]` | yes | Developer escape hatch: revert, clear journal, uninstall daemon |
| `watchdog` | yes | launchd-invoked only; not human-facing |

`watchdog` is the **same binary** under a different argv, not a second product — one
artifact to build, sign, and ship, and it keeps the M3 migration a change of installation
rather than a change of code.

Every report embeds hardware model and OS build (`26.5.2/25F84`) per §14. A verdict
without the build it was measured on is worthless when Apple changes this behaviour in a
point release.

---

## 5. Journal and watchdog contract

The part that outlives M0 verbatim. The decision function is pure and lives in `Core`:

```swift
struct JournalRecord: Codable, Equatable, Sendable {
    let schemaVersion: Int      // refuse to act on versions we don't know
    let intent: Intent          // .sleepDisabled (extensible: .spotlight, .timeMachine)
    let priorValue: Bool        // what we must restore TO
    let setAt: Date
    let ttlSeconds: Int         // hard-capped at 8h per §8.2(5)
    let armedBy: ArmProvenance  // pid, binary path, uid — forensics for a stuck flag
}

enum WatchdogDecision: Equatable {
    case hold
    case revert(RevertReason)   // .ttlExpired, .heartbeatLost, .dirtyJournalAtBoot,
}                               // .thermalAbort, .batteryFloor, .unknownSchema
```

Contract, mapping 1:1 onto §8.2:

1. `arm` writes the journal and **`fsync`s it before** touching `SleepDisabled`. Order is
   non-negotiable: a crash between the two must leave evidence, never a silent mutation.
2. The watchdog ticks every 5 s, evaluating `decide(journal:now:lastHeartbeat:)`.
3. TTL expiry, or a heartbeat older than 45 s, reverts to `priorValue` and clears the
   journal.
4. `RunAtLoad` means boot with a non-empty journal reverts **unconditionally**, without
   consulting the TTL. An unclean exit is not a state we attempt to reason about.
5. TTL is clamped to 8 h **in the constructor**, not at the call site, so no caller can
   opt out.

### Failure policy

- **Journal write fails → refuse to arm.** Fail closed: no journal, no mutation, exit
  non-zero. Trading a recoverable abort for an unrecoverable stuck flag is the wrong
  direction.
- **Revert fails → retry, then escalate loudly.** Bounded retries; if `pmset` still will
  not take, leave the journal dirty **on purpose** so the next boot retries, and emit an
  `UNSAFE_STATE` line. Never clear a journal we did not successfully act on.
- **Unknown `schemaVersion` → revert, do not parse.** A future version's journal is not
  something an old binary should interpret. Reverting is always the safe direction, which
  is why `priorValue` is stored rather than assumed `false`.

---

## 6. Spikes

| Spike | Mechanism | Verdict discriminates on |
|---|---|---|
| **S1** | `arm` → lid close → `report` | Did sampling continue across the closed-lid window with no gap beyond threshold, and did `uptime` not reset? |
| **S2** | Sample display power state while armed | Was the internal panel actually dark under the closed lid, or lit and burning battery (§2.2)? |
| **S3** | `proc_pid_rusage(RUSAGE_INFO_V4+)` | Is `ri_billed_energy` populated for a **non-owned** process without extra entitlement, or zero/EPERM? |
| **S5** | `setpriority(PRIO_DARWIN_BG)` on a same-uid notarised app | Does demotion take, and does `-B` reverse it? Needs a live third-party target. |
| **S8** | Read managed-settings, `~/.claude/settings.json` env, `~/.codex/config.toml [otel]` | Which of §15.4's three modes applies. |
| baseline | `IOPMAssertion`, `thermalState`, `IOPSCopyPowerSourcesInfo` | Sanity, plus the numbers every report is stamped with. |

**S1 is reported as `not-yet-run` until a real armed run with a real closed lid happens.**
It is never inferred from a green unit suite. Per the standing rule that unit tests verify
the seam and not the live integration, the code being complete and the spike being
answered are two different claims.

---

## 7. Testing

- **Core is table-driven and exhaustive** over the `decide()` matrix: every combination of
  journal present/absent, TTL expired/live, heartbeat fresh/stale, schema known/unknown.
  This suite must go red if anyone weakens the watchdog.
- **Every guard test is mutation-checked.** For each safety assertion, delete the guard and
  confirm the test fails. A watchdog test that passes with the watchdog removed is worse
  than no test.
- **Failure injection via PATH shim, not environment.** To test "pmset refuses", place a
  fake failing `pmset` earlier on `PATH` and assert the **exact** documented exit code.
  Environment-based failure injection (`TMPDIR=/nonexistent` and similar) only fails inside
  the agent sandbox and is theatre everywhere else.
- **Fault injection cases:** watchdog `SIGKILL`, corrupt journal, unknown schema version,
  disk full on journal write, clock jump backwards, daemon already installed.

Not claimed by any test: that S1 passes. See §6.

---

## 8. Out of scope for M0

All UI and menu-bar work. Agent hooks, ingest server, and the shim. The privileged helper
daemon proper and its XPC protocol. S4 (Cursor CLI runtime hook test) and S6 (battery
drain harness). Token Tap (§15) in its entirety.

The menu-bar identity assets (`Coffee-bar menu bar identity.zip`: Icon Composer
`AppIcon.icon`, `.iconset`, layered light/dark/mono SVGs, `make-icns.sh`) are M1 material
per §6.2 and require Xcode 26 to compile. Deliberately not extracted into M0.

---

## 9. Open items carried forward

- Xcode install must complete before implementation begins (D7).
- Homebrew formula/cask name availability check before first public commit (§16 Q5).
- Handoff §16 questions 1–8 remain open; none block M0.
