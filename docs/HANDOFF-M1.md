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
| 1 — core value types | Built, reviewed, 3 defects fixed, verified |
| 2 — `PowerBroker` | Built, reviewed, 2 defects fixed, verified |
| 3 — `HoldController` | Built, reviewed, 3 defects fixed, verified |
| 4 — `SystemPowerReader` | Built, reviewed, 2 defects fixed, verified |
| 5 — app target, POC removal | **Not started — start here** |
| 6 — bundle script | Not started |

Head is `31aa82a`, pushed to `origin`. **188 tests in 3 suites**, 0 warnings.

## Task 5 carries three inherited requirements

Do not let these fall on the floor — each came out of a gate on an earlier task.

1. **The app must route through `DesiredPowerState` and must never call
   `AssertionHolder` directly.** The §6.1 no-display-assertion invariant is
   guarded at the decision layer and at the IOKit layer, but nothing stops an app
   layer that bypasses both. Add that guard as Task 5 acceptance.
2. **`ServingModel` must decide when the panel stops showing a suppression
   reason.** `userToggled(to: .stop)` deliberately does NOT clear
   `lastSuppression`, and a test now pins that. Left alone, the panel keeps
   explaining a release the user has already read.
3. **The plan's Task 5 code has three import fixes already applied** —
   `Observation`, `AppKit`, `Combine`. Do not "clean them up".

## What the three critic gates found

Every gate found real defects, and **all but one were in tests** rather than
implementation — the same pattern M0 recorded 14+ times.

- **Task 1**: three defects. Renaming `SessionState.done` left all four tests
  green while the test's own comment claimed it would fail.
- **Task 2**: two. The blocked-states knob could be mutated to *replace* the
  active set rather than extend it — dropping `.working` from the knob-on set
  left the entire 172-test suite green. The builder had not reported this one.
  Also, `PowerInputs`'s declared defaults were unexercised: changing the floor
  from 20 to 90 left everything green.
- **Task 4**: two, one of them in implementation.
  `repeatedReadsAgreeOnWhetherABatteryExists` was theater — it survived the exact
  reordering bug its own comment named, and the builder's stated mitigation for it
  was factually wrong. And `read()` derived the power source from the wrong IOKit
  call.

## The UPS question is SETTLED

`read()` used to take `onAC` from the per-source `kIOPSPowerSourceStateKey` of
whichever source it picked first, so a UPS could supply the battery percent and
M1's floor would gate on it.

Fixed in `cd35c9e`. `source` now comes from `IOPSGetProvidingPowerSourceType` by
way of M0's already-tested `onBattery(providingType:)`, and `percent` is taken
only from a source whose `kIOPSTypeKey` is `kIOPSInternalBatteryType`. The
decision was extracted into a pure function over a list of descriptions, so a
UPS-first ordering is tested with synthetic input and **no UPS is needed**.

Note the memory rule: `IOPSGetProvidingPowerSourceType` is an unaudited CF `Get`,
so its result is taken **unretained**. `docs/ENGINEERING-NOTES.md:100` records
why. A fix brief on this plan wrongly specified `takeRetainedValue()` and the
builder correctly refused it.

## Two open gaps, neither blocking

- **`read()`'s internal wiring is unguarded on an AC host.** The pure function is
  fully covered by synthetic input, but nothing proves `read()` feeds it the real
  providing type — a `read()` passing `nil` would report `.ac` always, and the
  `pmset` cross-check reads `false == false` on a plugged-in machine. Closing it
  needs one run on battery power.
- **Multi-session inputs are untested.** Replacing `sessions.contains {…}` with
  `.first`, `.last`, or `prefix(1)` all leave the suite green, because no test
  passes two sessions. Harmless in M1, where `sessions` is always empty.
  **Must land before M2 starts ingest.**

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
