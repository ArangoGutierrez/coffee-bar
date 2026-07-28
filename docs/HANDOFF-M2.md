# Session Handoff — 2026-07-28 evening, M1 closed

Project: **coffee-bar**. **M0 and M1 are closed and merged.** M4 documents are
built and pushed but not merged. **M2 has not started.**

Read `docs/HANDOFF-M0.md` for the project-wide rules. This file covers what
changed on 2026-07-28 after the M1 mid-flight handoff, and what comes next.

## State — verify this before trusting it

| Ref | Head | Meaning |
|---|---|---|
| `origin/feat/m0-capability-probe` | `b886ea2` | integration branch. **M1 is merged here.** |
| `origin/feat/m1-core` | `b886ea2` | same commit. Merged, kept for now. |
| `origin/feat/m4-repo-hygiene` | `a5131f4` | M4 documents. **Not merged.** |
| `backup/m1-core-pre-rebase` | `9b8deda` | local only. Pre-rebase safety net. Delete when comfortable. |

Verified at `b886ea2`, in a `git archive` copy, after the merge:

```
swift build             rc=0, 0 warnings
swift build -c release  rc=0, 0 warnings
swift test              Test run with 203 tests in 3 suites passed
```

Worktrees: `.worktrees/m1core` is on `feat/m4-repo-hygiene`.
`.worktrees/m1power` is finished and safe to remove.

**`feat/m1-power` is safe to delete, but `git merge-base --is-ancestor` says
otherwise.** The M1 rebase rewrote every SHA, so the ancestry check is a false
negative. Confirmed by content instead: its Task 4 commit is present as
`7792f51`, `SystemPowerReader.swift` on the parent is a strict superset, and
nothing exists on `m1-power` that the parent lacks.

## What M1 shipped

A menu-bar app that holds `PreventUserIdleSystemSleep` from a manual toggle,
with a latching 20% battery floor. It never holds a display assertion — that is
the product's whole differentiator, and it is guarded at three layers.

Targets: `CoffeeBarCore` (pure) → `CoffeeBarPower` (IOKit) → `CoffeeBarUI`
(SwiftUI) → `CoffeeBarApp` (`main.swift` only). `CoffeeBarUITests` is new.

The `CoffeeBarUI` split was not in the plan. The plan put everything in one
executable target, whose `main.swift` is top-level code that no test target can
import, and specified zero tests. A recommendation panel returned HOLD on the
split.

## The number that matters

**Two adversarial gates found 9 defects in Task 5 alone.** Across M1, every gate
found real defects, and all but two lived in TESTS rather than in
implementation. Do not skip the gate. The loop that works:

```
sonnet builder on a fully-specified brief
  -> opus adversarial-critic gate
  -> bounded fix round
  -> re-gate
```

Two of those defects were silently green: a boundary at exactly 20% battery, and
its mirror at 21%. Both left all tests passing. Both were found by mutating the
comparison and watching nothing go red.

## Seven plan defects, and two were the orchestrator's

Plan-authored literals are untested code. This plan carried seven:

1-4. Task 5: zero tests specified; the suppression line never cleared; the 30s
ticker hung off `PanelView`, which `MenuBarExtra(.window)` builds only while the
panel is open; and `struct CoffeeBarApp` sat inside module `CoffeeBarApp`.
5. Task 6 hard-coded the bundle version, which spec §7 forbids.
6. **A fix brief said the floor line should read "below 20%".** `PowerBroker`
suppresses at `<=`, so that sentence is false at exactly 20%. The builder
refused the wording and shipped "at or below".
7. The same brief's suggested `deinit` comment was wrong — see below.

**Both times a builder refused a brief literal, the builder was right.** Write
briefs that carry the INVARIANT so a worker can attack it, not just the
instruction.

## Things proved by running, not by reading

- **`isolated deinit { timer?.invalidate() }` builds clean** at `.macOS(.v14)`
  under `swiftLanguageMode(.v6)`, zero warnings. A plain `deinit` does not. A
  comment claiming isolation must be weakened was false, and it was steering the
  next task away from the one available fix.
- **`ProcessInfo.performActivity`/`beginActivity` with
  `.idleDisplaySleepDisabled` holds a real `PreventUserIdleDisplaySleep`**, under
  no IOKit import and no obvious name. A denylist guard cannot see it. This is
  why the app-layer guard is now structural: it asserts the exact expected file
  set plus `CoffeeBarApp`'s dependency list, not just forbidden strings.
- **`FileManager.enumerator` does not follow symlinked directories, but SwiftPM
  compiles through them.** A symlinked directory was a proven escape.

## The first-run gap that no test could catch

`LSUIElement=true` means no Dock icon, no window, no app-switcher entry. The app
launched correctly and neither the maintainer nor the assistant could tell — the
process was alive at 0% CPU holding no assertion, and the only sign of life was a
16pt glyph at the right end of the menu bar.

Fixed in `a5131f4` by documenting it in the README. It was a documentation
defect, not a code one, which is exactly why 203 tests said nothing about it.

## STILL UNVERIFIED — needs a human at a real menu bar

The acceptance checklist is at
`.superpowers/sdd/2026-07-28-coffee-bar-m1/task6-acceptance-checklist.md`.
Steps 2-5 are already covered by `AssertionHolder_test.swift`, which reads live
IOKit state through `IOPMCopyAssertionsByProcess`. **These are not:**

1. Whether the menu-bar glyph is the vendored artwork or the silent
   `cup.and.saucer` SF Symbol fallback. `MenuBarGlyphs` returns `nil` on a failed
   load and the app still works, so a broken resource path looks healthy.
2. Whether the glyph changes between idle and serving.
3. Whether the app process wires `ServingModel` to `AssertionHolder` end to end.
   The unit tests use a spy.

Build the bundle with `scripts/build-app.sh`, then `open build/CoffeeBar.app`.

## Open decisions for the user

1. **Private vulnerability reporting is not enabled**, so `SECURITY.md`'s
   advisory URL returns 404. Enable it before merging M4.
2. **`SECURITY.md` has no email fallback.** The only address in git history is
   the NVIDIA work address, and using it implies an affiliation the README
   disclaims.
3. **Branch protection on `main` breaks `release.yml`**, which pushes the formula
   pin to `main`. Remove the formula job first — `ROADMAP.md:166`.

## Next session should

1. **Get the M1 acceptance run done** if it still has not happened. It is three
   screenshots and two `pmset` commands.
2. **Close the multi-session gap before M2 ingest.** `PowerBroker` uses
   `sessions.contains {…}`; replacing it with `.first`, `.last`, or `prefix(1)`
   leaves the suite green, because no test passes two sessions. Harmless in M1
   where `sessions` is always empty. **Not harmless the moment M2 feeds it.**
3. **Brainstorm and spec M2** — Claude Code adapter, `SessionHub`, HTTP ingest,
   session state machine, attention queue. This needs the user.
4. Finish M4: the README SEO and GEO rewrite, the tap repo, repo settings.

## Binding constraint on M2

Design spec §6 forbids asserting session-transition semantics against invented
events. `SessionHub` must be fed **recorded hook payloads captured during M2**.
Asserting transitions from a description repeats the M0 failure mode, where
guards written from prose passed while asserting nothing.

Testing WHICH STATES the wake predicate treats as awake is required and already
done. Testing WHICH EVENTS move a session between states does not exist yet and
must not be faked.

## Verification before claiming done

Run from the repo root, sandbox DISABLED:

```
swift build
swift build -c release
swift test
```

Expect `Test run with 203 tests in 3 suites passed` and zero warnings.
Verify in a `git archive` copy, never the working tree.

## Still true from M0 and M1

- `swift test --filter` exits 0 when it matches nothing. Always read the COUNT.
- Mutation attribution runs the named test ALONE, and the mutant must be proved
  APPLIED by comparing `git hash-object` before and after. A silent no-op
  substitution makes the whole check vacuous.
- Prove every revert by CONTENT, never by exit code. Back up through the git
  index, and **never write a backup inside the package tree** — the app-layer
  guard now catches stray files, which is how a `.orig` file got flagged.
- `tdd-guard.sh` cannot see an untracked test file. `git add` the test after the
  RED run and before the implementation. Never set `SKIP_TDD_GUARD`.
- `git commit -s -S -F <file> -- <paths>`: the `-m`/`-F` comes BEFORE the `--`.
- `$TMPDIR` differs between sandboxed and unsandboxed shells.
- `tac` does not exist on macOS. Use `tail -r`.
- Run `shellcheck` on every script you write. It caught three real defects in the
  orchestrator's own scripts this session, including an unguarded `cd`.
