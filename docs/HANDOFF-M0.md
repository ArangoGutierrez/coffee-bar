# Session Handoff — 2026-07-28 09:30

Project: **coffee-bar** — macOS menu-bar app binding the sleep assertion to agent state.
Two-day session. **M0 (capability probe) is COMPLETE.** All 12 tasks built,
reviewed, merged. 152 tests (3 suites), zero warnings, acceptance green.

## Context

- Repo: `/Users/eduardoa/src/github/ArangoGutierrez/coffee-bar`
- Branch: `feat/m0-capability-probe` @ (see `git log -1`) — all four branches merged
- Nothing pushed. `origin` has no branches. Repo is public and empty.
- Working tree clean except the untracked `Coffee-bar menu bar identity.zip` (leave it — assets are already vendored under `assets/art/`)
- State: GREEN on the parent — 152 tests in 3 suites, 0 warnings, all branches merged. Nothing in flight.
- Worktrees (intentional — do not delete until merged):

| Worktree | Branch | State |
|---|---|---|
| `.worktrees/task10` | `feat/m0-task10` | ✅ merged |
| `.worktrees/task11p` | `feat/m0-task11-power` | ✅ merged |
| `.worktrees/task12` | `feat/m0-task12` | ✅ merged |

All three are safe to remove: `git worktree remove .worktrees/<name>` then
`git branch -d feat/m0-<name>`. Confirm each is merged first.

## READ THESE FIRST — they are the real handoff

1. `.superpowers/sdd/2026-07-27-coffee-bar-m0-probe/progress.md` — **1,624-line ledger**, git-ignored. The full per-task record: every review, every mutation, every defect and its diagnosis.
2. `docs/ENGINEERING-NOTES.md` — committed. Binding constraints, open residuals, and the method section on what actually caught defects.
3. `docs/probe-results.md` — committed. Measured spike answers, incl. negative results.
4. `docs/ROADMAP.md` — committed. v0.1 scope and three open decisions needing the user.

Trust these over any recollection. After compaction, trust them plus `git log`.

## Where M0 stands

Twelve tasks, all built, all closed with adversarial review + mutation-verified fixes.

- **Deliverable works on the parent**: `swift run coffee-bar-probe --json` → rc=0, `jq` spike-id gate → rc=0. Report: `baseline`/S3/S5/S8 `pass` with measured values; S1/S2 `notYetRun`, and S2's row states the instrument problem, not just "needs a lid close".
- **Spike answers** (committed to `docs/probe-results.md`):
  - **S3 ANSWERED, favourably** — `ri_billed_energy` readable for same-uid processes, no entitlement. De-risks §15 Token Tap.
  - **S5 partly** — self verified; foreign-pid readback fails *even for Apple's own `taskpolicy`*, so the instrument fails, not necessarily the demotion.
  - **S8 ANSWERED** — mode `ownIt` (no managed settings, no OTEL keys). Contradicts handoff §16 Q7.
  - **S2 INSTRUMENT INVALID** — `IODisplayWrangler` publishes an empty `IOPowerManagement` on Apple Silicon; `IOMobileFramebufferAP` has `MaxPowerState` 1, not 4. Retarget is an M5 design call.
  - **S1 not run** — needs root + a physical lid close.

## Decisions made (from the ledger, not transcript-mined)

- **v0.1 re-scoped**: M0+M1+M2+M3+M4. Lid-closed moved to M5; new M4 = OSS repo/CI/Homebrew. v0.1 requires no root, no kernel flags, no App Store.
- **No hidden durations** — if the UI exposes no time control, behaviour is indefinite. The M5 8h TTL is a safety interlock on a global flag, not a convenience timer.
- **Probe holds only `PreventUserIdleSystemSleep`**, never the display assertion (§6.1). Guarded in *both* components after a review found one guard covered only one.
- **M5 is NOT "install-mechanism-only"** — corrected. `SMAppService` takes a bundled plist by name, so `install(binaryPath:)` disappears. Hoisted to `WatchdogSupervising` so M5 is a second conformer.
- **Team pattern for M1–M4**: PE + QA + workers in real worktrees. Validated here — 3 workers, disjoint file sets, zero conflicts.
- **Swift test files are `<Subject>_test.swift`**, not `…Tests.swift` — required by `tdd-guard.sh`, which is otherwise routed around.

## Next session should

**M0 is done — nothing is left to finish. Start M1.**

The last M0 work (Task 10's verdict guards) is merged and independently verified:
a mutant forcing every measured spike to `.pass` is killed by
`runReportsEverySpikeWithTheVerdictItsProbeProduced`, which invokes each probe
directly and compares. A second mutant making `RunCommand` pass `nil` instead of
`getpid()` is killed by `theShippedBinaryMeasuresTheProcessItRunsIn`, which drives
the real binary as a child process — `RunCommand` lives in an executable target no
test can import, so nothing in-process could catch it. Before these, both mutants
left 122 tests green.

1. **Verify the inherited state first** — run the block under "Verification"
   below. Expect 152 tests in 3 suites, `probe rc=0`, `jq rc=0`.
2. **`ArmCommand` and the privileged verbs are NOT built.** `arm` / `report` /
   `revert` / `watchdog` still exit 64 by design; only `run` is implemented.
   That work is M5, not M0 — v0.1 excludes lid-closed mode. When it happens,
   four inputs are already known, all the same species (*an operation fails,
   returns something plausible, reports success*):
   - **CRITICAL**: `arm` must NOT derive rollback state by re-reading a flag it
     may itself have set. On an already-armed machine it reads `true`, writes
     `priorValue: true`, "restores" to true, deletes the journal → sleep
     disabled forever with no supervisor.
   - Installer self-cleans a failed bootstrap now; `arm`'s catch must not
     assume otherwise.
   - `install()` takes no `binaryPath:` and throws `WatchdogInstallError`;
     `arm` must explain the path-validation refusal usefully rather than dump
     a raw error.
   - `sudo .build/debug/coffee-bar-probe arm` is deliberately REFUSED — see
     `docs/probe-results.md` for the working armed-session sequence.
3. **Start M1** — the menu-bar app. Brainstorm → spec → plan, then build.
   `AssertionHolder` and the POC already exist; `scripts/build-poc-app.sh`
   proves no `.xcodeproj` is needed.
4. **Use `team-execute` with real worktrees.** Validated here: three workers,
   disjoint file sets, zero conflicts, while the lead committed to the parent
   throughout. Sequential dispatch on one checkout produced three separate
   near-misses.

## Two residuals from the final merge — read before touching tests

**A latent test race is mitigated, not closed.** `ProbeRun.report` acquires a
process-global IOKit assertion whose name `assertionProbeAcquiresAndReleasesCleanly`
(in `BaselineProbe_test.swift`) requires to be uniquely live. Measured: baseline 0
failures/60 runs, an intermediate attempt 1/30, final 0/60 after adding
`@Suite(.serialized)` to `ProbeRunTests`. That serialises one side only — the complete
fix puts both parties in a single serialized suite, which spans a file the fixing agent
did not own. **Adding another test that calls `ProbeRun.report` or `AssertionProbe` can
reintroduce it.**

**`docs/probe-results.md` had diverged** between `feat/m0-task10` and the parent; the
parent's richer copy won the merge. Correct outcome, but by luck rather than design —
if a future branch edits that file, diff it deliberately rather than trusting the merge.

**And the merge lesson itself:** the final revision was merged in two steps because I
first merged an intermediate commit. The second merge produced a *semantic* conflict —
git combined both versions of `ProbeRun_test.swift` textually, reported success, emitted
no conflict markers, and left a stale reference to a now-private method. It did not
compile. A clean merge is not a correct merge; build and test after every one.

## Open decisions needing the user

- **Release job pushes to `main`** while branch protection is an M4 deliverable. Ranked options in `ROADMAP.md`; a separate tap repo is my recommendation.
- **M7**: what "managed settings present" means — existence vs OTEL-content. Both readings and their failure directions are recorded.
- **v0.1 timing**: not achievable in a day. M1–M4 need their own spec+plan cycles. M1-alone as v0.1 is the defensible cut if speed matters.

## Verification before claiming done

```
cd /Users/eduardoa/src/github/ArangoGutierrez/coffee-bar
D=$TMPDIR/cbv-$$; rm -rf "$D"; mkdir -p "$D"; git archive HEAD | tar -x -C "$D"
swift build --package-path "$D"
swift build --package-path "$D" -c release
swift test --package-path "$D"
swift run --package-path "$D" coffee-bar-probe --json > $TMPDIR/p.json
jq -e '[.spikes[].id] | contains(["S1","S2","S3","S5","S8"])' $TMPDIR/p.json
rm -rf "$D"
```

**Verify in a `git archive` copy, never the working tree** — agents in sibling worktrees
and a shared `.build` produced a phantom test failure with no identifiable failing test.
All swift commands need the sandbox DISABLED.

## Hard-won operational rules

- **One implementation agent at a time**, unless each has its own worktree. Wait for the completion *message*, not the commit — a committed task is still running.
- **Commit with explicit pathspecs**: `git commit -s -S -F - -- <files>` (`-F -` *before* `--`). A bare commit nearly swept another agent's staged work.
- **`swift test --filter` exits 0 when it matches nothing.** Any kill attribution must confirm a non-zero test count, and ideally a pre-run proving the filter matches *and passes* before mutating.
- **Mutation at suite scope can lie** — a mutant may be killed by unrelated tests via a shared side effect. Attribute by running the named test alone.
- Shell is **zsh**: no `PIPESTATUS`, unquoted `$var` does not word-split, an unmatched glob aborts the whole line. Use `$TMPDIR`, not `/tmp`.
- **Never** run `pmset -a disablesleep`, `launchctl bootstrap`, or `sudo` in a test.

## The one thing worth internalising

Fourteen-plus mutation-verified defects were found across M0. **Every single one was in a
test, not in implementation logic.** The implementation was transcribed from a reviewed
plan and was mostly right; the tests were written from descriptions and asserted the
description rather than the behaviour. Three guards asserted materially less than their
names claimed, and all three read as solid coverage in review.

Corollary, learned the hard way: *knowing a failure mode and writing the warning down does
not prevent producing it.* A brief that explicitly forbade literal-compared-to-literal
assertions contained one. Only the mutant catches it.
