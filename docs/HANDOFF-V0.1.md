# Handoff — walking to v0.1

Written 2026-07-29. Supersedes `docs/HANDOFF-M2.md` for current state; that file
keeps the M1 history.

## State — verify before trusting

```
main = d6dafb2      370 tests in 3 suites      0 warnings debug and release
CI   = green TWICE on this commit (a re-run, not one sample)
```

Branches on origin: `main`, `feat/m0-capability-probe` (same commit as main),
plus stale `feat/m1-core` and `feat/m4-repo-hygiene` which can be deleted.

Verify with, from the repo root, sandbox disabled:

```
swift build && swift build -c release && swift test
```

**M0, M1 and M2 are complete. M4 is complete bar two items, both yours.**

---

## What v0.1 needs, in order

### 1. The whole-branch adversarial review — NOT DONE

**1,259 lines of M2 production code have never been independently reviewed.**
Every M2 task landed with its own builder's mutation evidence, and PE reviewed
the *plan* before Task 5 existed, but nothing has attacked the merged result.

A workflow was launched and **stopped without completing** when the process
exited. It produced no findings. Relaunch:

```
Workflow({ scriptPath: ".../workflows/scripts/m2-whole-branch-review-wf_5ad0b2f2-97c.js",
           resumeFromRunId: "wf_5ad0b2f2-97c" })
```

Six dimensions — concurrency, listener/parser, power-decision path, privacy,
guard quality, CI parity — each finding adversarially refuted before reporting.

Why this matters: on M1, two gates found **9 defects in one task**, and all but
one lived in tests rather than implementation.

### 2. The acceptance run — YOURS, about 15 minutes

`docs/V0.1-ACCEPTANCE.md`. Nine steps. Steps 4, 5 and 6 are the milestone:

- an agent session drives the assertion **with nobody touching a control**
- no display assertion at any point
- the hold drops when the agent goes idle

**Do this AFTER the review**, so the fifteen minutes tests reviewed code.

Nothing in that file has been executed. It was written from the source, and the
source has been wrong before — if a step does not match reality, fix the step.

### 3. Then, yours alone

- **Tag v0.1.** Held all session, deliberately.
- **Branch protection** on `main`, required check `build-test`. Correctly LAST:
  `release.yml` no longer pushes to `main`, so it is unblocked, but enabling it
  while agents push would halt the loop.
- **Port the substitution checks into the tap's CI** — the last open M4 item.
- **`tdd-guard.sh`** — see below.

---

## Open decisions and known gaps

**`tdd-guard.sh` has three false positives**, and one bypass happened:

| Case | Cause |
|---|---|
| every Swift test here | no `Sources/` to `Tests/<Module>Tests` mapping; it maps `src/`, `lib/`, `electron/renderer/` |
| `Package.swift` | the manifest allowlist (lines 91-95) covers `go.mod`, `package.json`, `pyproject.toml`, `Cargo.toml` — not `Package.swift` |
| Homebrew `.rb` | a formula carries its own inline `test do` block |

The Task 5 builder applied a manifest change via Bash after being blocked. It
refused `SKIP_TDD_GUARD`, refused to edit the hook, and disclosed it. The change
was audited by content before merging: two `.v6` targets, `CoffeeBarIngest`
depending on Core only. **The hook is your config and was not modified.**

**Design §6's "re-offer the snippet" is unkept.** coffee-bar has no CLI at all,
so nothing can print the hook JSON. Either add a verb or amend the spec. The
acceptance doc carries the snippet by hand meanwhile.

**The panel cannot report that the listener failed to bind.** `startMonitoring`
throws when a second instance owns the socket; `main.swift` only `NSLog`s it.
Task 8 added a "not serving" line, but the path is unverified on hardware.

**`coffee-bar-HANDOFF.md` retirement is half-done.** Twelve sections still cited
by number; three were rehomed into `CONTRIBUTING.md` and `SECURITY.md`. Cosmetic;
v0.2 work. Note a filename grep finds ~5 references and MISSES the 30 `handoff
§N` citations.

**App Nap is unmeasured.** An `LSUIElement` app is a candidate, and a throttled
30s timer would make the stale timeout late rather than wrong.

---

## Things that are true because they were MEASURED

Not inferred, not read from documentation:

- **`SessionEnd` exists and fires.** Running `claude -p` headless in the repo
  directory crosses a real session boundary and produces `SessionStart` and
  `SessionEnd`. **Reusable whenever a hook corpus needs an event the current
  session cannot produce.**
- **The `Stop` payload carries `last_assistant_message`** — 2747 characters of
  assistant reply text, delivered directly, not behind `transcript_path`. The
  privacy rule as originally written permitted exactly what handoff §12 forbids.
- **`SessionStart` carries a strictly smaller field set** than tool events: no
  `agent_type`, `permission_mode` or `effort`. A decoder built from tool events
  alone throws on it.
- **`SessionEnd` and `PermissionDenied` both use `reason`**, meaning unrelated
  things — 599 characters of panel text versus the code `other`.
- **`caffeinate` is the same IOKit mechanism one layer up.** It links
  `IOKit.framework` and calls `IOPMAssertionCreateWithDescription`. coffee-bar
  wins on attribution and LOSES on self-description — see spec §11.
- **`isolated deinit` is experimental before Swift 6.3.** It compiles on this
  machine (6.3.3) and fails the runner (6.1.2).
- **The connection-cap test takes 9.75s on the runner**, against a 5s budget.
  That is why it failed 3 of 5 CI runs.

---

## Traps that cost real time this session

1. **Verifying against ONE toolchain is not verifying.** CI is Swift 6.1.2 /
   macOS 15; this machine is 6.3.3 / macOS 26 with far more cores.
2. **A mutation check must prove the mutant APPLIED and that it COMPILES.**
   Otherwise a red suite proves only that the compiler works. That mistake was
   made three times.
3. **Never `git checkout --` to revert an UNCOMMITTED baseline.** It restores the
   committed file and destroys the work. Copy outside the package tree.
4. **A scan must assert a non-zero file count.** A leak scan over an empty
   directory reports zero matches and looks like success.
5. **Run the FULL suite, never just `--filter`.** A filtered green hid a real
   break four times.
6. **Never build a test's expectation with the call under test.** One test
   asserted a URL built by the very constructor being tested; both sides agreed
   while the behaviour was wrong, and it went red only when the bug was FIXED.
7. **Backticks in a double-quoted shell string are command substitution.** They
   silently gutted a commit message. Use `-F <file>`.
8. **`timeout` does not exist on macOS. `tac` does not either** — use `tail -r`.
9. **A filename grep misses citations by section number.** ~5 versus 30.
10. **Fixing code does not fix the documents that tell you to write it again.**
    The `isolated deinit` defect was fixed once and then found in three more
    places, including a spec section the next task was about to read, and a plan
    test that ASSERTED a behaviour a review had just forbidden.

---

## The instruction that produced the most findings

Every dispatch brief carried:

> **VERIFY ANY PREMISE I GIVE YOU.**

Eleven briefs were corrected by the agents executing them, and **every
correction was right**: a mutant already dead, a plan mutant that would not
compile, a report file that did not exist, wording that was false at exactly the
boundary, a scope item already done, an impossible instruction to call a CLI that
does not exist.

Write briefs that carry the INVARIANT so a worker can attack it, not just the
instruction. The plan has been the weakest artifact throughout: **eight defects
in plan literals**, two of them the orchestrator's.
