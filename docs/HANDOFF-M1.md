# Session Handoff — 2026-07-28, M1 in flight

Project: **coffee-bar**. M0 is closed. **M1 is about half built and NOT reviewed.**

Read `docs/HANDOFF-M0.md` first for the project-wide rules. This file covers only
what changed on 2026-07-28 and what the next session must do.

## State

| Branch | Head | Meaning |
|---|---|---|
| `feat/m0-capability-probe` | `7e0642c` | Parent. M0 plus the M1 spec and plan. No M1 code. |
| `feat/m1-core` | `bfcc24d` | **All M1 code lives here.** Tasks 1, 2, 4 built and merged. |
| `feat/m1-power` | `776419f` | Task 4 only. Already merged into `feat/m1-core`. Safe to delete. |

Worktrees, both intentional:

- `.worktrees/m1core` → `feat/m1-core`
- `.worktrees/m1power` → `feat/m1-power` (finished; remove once you confirm the merge)

Verified at `bfcc24d`: `swift build` rc=0, `swift test` **172 tests in 3 suites**,
0 warnings. Baseline before M1 was 152.

## Decisions closed on 2026-07-28

All three of the M0 handoff's open decisions, plus two M1 design forks. Full
reasoning in `docs/ROADMAP.md` and the M1 design spec.

1. **Homebrew** — the formula moves to a separate tap repo,
   `ArangoGutierrez/homebrew-coffee-bar`. A human pins it per release. Decided on
   a measured fact: `brew tap user/repo` resolves to `github.com/user/homebrew-repo`.
2. **M7 telemetry** — existence of a managed-settings file implies `passive`.
3. **v0.1 = M1 + M2 + M4.** M3 moves to v0.2.
4. **M1 builds `PowerBroker` and the session types**, not just a toggle.
5. **M1 enforces a 20% battery floor**, surfaced in the panel, latching.

Decisions 1, 2, 4 and 5 each drew a panel HARD- or SOFT-DISSENT that the user
overrode. Where a dissent had a real point, it became a binding requirement
rather than being waved away — see the M4 checklist in `ROADMAP.md` and the
design spec §5.3.

## What is built

Plan: `docs/superpowers/plans/2026-07-28-coffee-bar-m1-menubar.md` — six tasks.
Spec: `docs/superpowers/specs/2026-07-28-coffee-bar-m1-menubar-design.md`.

| Task | State |
|---|---|
| 1 — core value types | Built, **reviewed**, 3 defects fixed, verified |
| 2 — `PowerBroker` | Built. **NOT REVIEWED** |
| 3 — `HoldController` | Not started |
| 4 — `SystemPowerReader` | Built. **NOT REVIEWED** |
| 5 — app target, POC removal | Not started |
| 6 — bundle script | Not started |

## START HERE — two unreviewed tasks

Task 1 went through an adversarial critic and it found **three real defects, all
in tests, all mutation-proven**. The most instructive: renaming
`SessionState.done` left all four tests green while the test's own comment
claimed it would fail.

**Tasks 2 and 4 have not had that gate.** Run it before building Task 3. Use the
`adversarial-critic` agent at opus, one task at a time, and tell it to re-run
every claim rather than trust the report. Reports are at
`.worktrees/m1core/.superpowers/sdd/2026-07-28-coffee-bar-m1/` (untracked — read
them before any `git worktree remove --force`).

Self-reported concerns worth attacking first:

- **Task 2**: the §6.1 no-display-assertion invariant holds at the decision layer
  and at the IOKit layer, but nothing forces the app layer to route through
  `DesiredPowerState`. A bypass would ship silently. Task 5 should close this.
- **Task 2**: `PowerInputs` default arguments are never exercised; the test helper
  always passes them explicitly. Task 5 will rely on the default floor of 20.
- **Task 2**: multi-session inputs are untested — every test passes 0 or 1
  session. Matters at M2, not now.
- **Task 4**: `repeatedReadsAgreeOnWhetherABatteryExists` survived all four
  mutants. It cannot fail on a single-power-source host. It was reported as a
  stated gap rather than dressed up as a guard.
- **Task 4**: `batteryPercent()` truncates where `read()` rounds, so the two can
  disagree by one percent. Both now live on one type.

## One decision needed before Task 5 ships the floor

`SystemPowerReader.read()` returns the **first** power source carrying a usable
capacity pair. It does not index by position, so the IOKit ordering bug is
absent. But with a UPS attached it can return the **UPS** charge as the battery
percent, and M1's battery floor would then gate on the UPS.

M0 reasons the opposite way at `Sources/CoffeeBarPower/BaselineProbes.swift:101`:
"UPS power is deliberately *not* 'on battery'". The two are inconsistent. Nobody
could produce a repro without a UPS, so no deviation was made. **Settle it before
the floor ships.**

## The plan had four defects. Expect more.

Plan-authored literals are untested code. Four were caught on this plan:

- Three before dispatch: `ServingModel.swift` uses `@Observable` without
  `import Observation`; `PanelView.swift` calls `NSApplication` without
  `import AppKit`; `main.swift` uses `Timer.publish` without `import Combine`.
- One at build time: **Task 4's code does not compile as written.**
  `CoffeeBarPower` already declared both `PowerReading` (a protocol) and
  `SystemPowerReader` (a struct) at M0. The builder renamed the protocol to
  `HostPowerReading` — it describes a reader, not a reading — and that is
  committed.

The census that missed the fourth checked file *paths* and never checked existing
*symbol names*. **Before writing any new type into a plan, grep the module for
that identifier.**

## Traps this session paid for twice each

- **`tdd-guard.sh` does not understand the SwiftPM `Tests/<Target>Tests/`
  layout.** Its fallback runs `git diff --name-only HEAD`, which cannot see an
  untracked file. Fix: `git add` the test file after the RED run and before
  writing the implementation. Do not set `SKIP_TDD_GUARD` and do not edit the
  hook. Every remaining task will hit this.
- **`$TMPDIR` differs between sandboxed and unsandboxed shells.** A builder wrote
  a mutation backup in one mode and restored it in the other; `cp` failed while
  returning success and the mutant stayed live under a green report. Use the git
  index as the backup store, and verify every revert by **content** — grep the
  restored text or compare the blob hash. Never trust the exit code.
- `git commit -s -S -F <file> -- <paths>` — the `-m`/`-F` must come **before**
  the `--`. One builder lost a commit to `pathspec '-m' did not match any file(s)`.

## Next actions, in order

1. Critic gate on Task 2, then on Task 4. Fix what it finds.
2. Settle the UPS question above.
3. Task 3 (`HoldController`) in `.worktrees/m1core`.
4. Task 5 (app target, delete the POC) — and add the app-layer guard that Task 2
   flagged.
5. Task 6 (bundle script) plus the manual acceptance run on hardware.
6. Merge `feat/m1-core` into the parent. Build and test **after** the merge.
7. Delete `feat/m1-power` and both worktrees.

## Still true from M0

- Verify in a `git archive` copy, never the working tree.
- All swift commands run with the sandbox DISABLED.
- `swift test --filter` exits 0 when it matches nothing. Always read the count.
- Mutation attribution runs the named test **alone**.
- Nothing is pushed. `origin` has no branches. The repo is public and empty.
