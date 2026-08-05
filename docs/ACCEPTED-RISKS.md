# Accepted risks

Each entry is a decision, not a gap. Every one carries the reason, the guard that
pins today's behaviour, and the condition that should reopen it.

## The panel can show a refusal that is no longer the reason (audit id18)

**Behaviour.** After the battery floor refuses an On click, the explaining line
can stay on screen when nothing is requesting a hold. The same visible state —
Auto, battery below the floor, zero sessions — reads differently depending on
whether a refused click happened earlier.

**Why accepted.** The line is true about what happened. Suppressing it whenever
nothing requests a hold would also suppress the case it exists for: a user who
clicked On, got nothing, and needs to know why.

**Guard.** `Sources/CoffeeBarUI/ServingModel.swift:645-668` carries the
rationale. `Tests/CoffeeBarUITests/ServingModelIngest_test.swift:395`,
`theBatteryLineLeftOnScreenIsTrueOfWhatHappensNext`, names the finding.

**Reopen when.** The panel gains room to separate "why your click did nothing"
from "why the machine is not held right now".

## A crash leaves demoted processes demoted until the next start (issue #14)

**Behaviour.** `ProcGovernor` demotes processes coffee-bar does not own. A demotion applied
to a foreign process is state on THAT process, so it outlives whatever applied it. If
coffee-bar is `SIGKILL`ed, no cleanup of any kind runs, and every process it had demoted
stays demoted until coffee-bar next starts and reads its journal back. For a long-lived
process such as a browser that can mean days.

**Why accepted.** Recovery is a journal a later run reads back, decided on 2026-08-05 over
a recommendation panel HARD-DISSENT. The alternative was a supervising process that
outlives the app. That is a second process to install, keep running and keep in step, which
is a larger permanent cost than the window it closes. It is **not** a privilege question: a
supervisor would not have needed root, and an earlier claim that it would was wrong and was
withdrawn.

The exposure is bounded by construction. Darwin background state is a process attribute, so
it dies with the process and never survives a reboot. "Bounded" can still mean days, and
nothing here treats this as solved.

**Guard.** `Tests/CoffeeBarPowerTests/ProcGovernorCrashRecovery_test.swift`,
`aDemotionOutlivesTheSIGKILLedDemoterAndALaterRunUndoesIt`, runs the whole thing: a real
victim, a real second process running the real governor, a real `SIGKILL`, `proc_pidinfo`
proving the victim is still demoted, then a later run clearing the bit.
`Tests/CoffeeBarPowerTests/DemotionCrashPath_test.swift` records the underlying hazard.

**Reopen when.** coffee-bar demotes processes by default rather than by opt-in, or a user
reports a process that stayed slow after a crash.

## Staleness is measured on a wall clock (audit id20)

**Behaviour.** `StalePolicy` subtracts wall-clock values. After a backward clock
step no session can expire until the clock catches up, so the only automatic
retirement of a crashed agent is suspended for the size of the step.

**Why accepted.** The backstop is a safety net, not a primary path, and a
backward step of that size on a developer machine is rare. `workingTimeout` was
raised to 900 s in `7692934`, which is the change that actually mattered.

**Guard.** `Tests/CoffeeBarCoreTests/Staleness_test.swift:108`,
`aBackwardClockDoesNotRetireAWorkingSession`, pins the suspended expiry, so the
behaviour is recorded rather than assumed. The 900 s value is pinned at
`Sources/CoffeeBarCore/StalePolicy.swift:30`.

**Reopen when.** coffee-bar ships to machines that sleep across timezone changes,
or a user reports a hold that never released.

## The public history of `main` carries prose from a live session

**Behaviour.** This repository is public. The history of `main` contains prose
captured from a live Claude Code session, inside a hook fixture. The current tree
is clean. The history is not.

A census on 2026-07-31 measured the shape:

| Commit | State |
|---|---|
| `b319a84` — `main`, `origin/main` | carries the material in a tracked fixture |
| `8c18926` — first branch commit | inherits it from `main`; introduces nothing |
| `2d0f668` — the remediation commit | scrubs the fixture and adds the guard |
| `2d0f668` onward | clean, and verified clean |

**Why accepted.** The exposure is already irreversible. A forge keeps unreachable
objects fetchable by their hash, and every existing clone and fork keeps them
whatever the upstream branch does. Rewriting published history needs a
destructive force-push and still retracts nothing that is already fetched.

The material is four short prose fragments from a permission-denial explanation.
It carries no credential and no key. The real username is a separate concern with
its own guard: the scrubber refuses to emit a fixture containing it, and a test
refuses to let one sit in the tree.

**What was done instead.** `2d0f668` scrubbed the fixture. The redaction guard
now scans every tracked file rather than one fixtures directory, so the same
class of miss fails in the suite instead of shipping. The scrubber learned the
`reason` key, so a re-capture cannot re-emit the same material, and it now has
tests of its own — it had none, which is how the key was missed. The branch
history from the remediation commit onward is verified clean by an all-paths
scan.

**A recommendation panel dissented from this decision.** It argued the branch
rewrite buys nothing while the same material stays public. Carlos read the
dissent and chose this disposition on 2026-07-31.

**Reopen when.** Any of the material turns out to name something sensitive, or
the project moves somewhere the public history of a repository carries more
weight than it does here.
