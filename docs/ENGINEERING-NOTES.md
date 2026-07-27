# Engineering notes

Constraints, residuals and hard-won lessons from M0 that outlive it. Written down
because the working ledger lives in git-ignored scratch and would not survive a
`git clean`.

Anything here was established by measurement — a reproduced failure or a mutation
run — not by reasoning. Where a claim was later disproved, that is recorded too.

---

## Binding constraints for future work

**`CommandRunning.run` takes `timeout:`.** Swift forbids default arguments on a
protocol *requirement*, so the requirement is `run(_:_:timeout:)` and a protocol
*extension* supplies the two-argument form. Call sites stay source-compatible;
**conformers do not**. Any new test double must implement the three-argument form.

Second-order consequence: `defaultTimeout` and the two-argument `run` are extension
members and therefore **statically dispatched** — a conformer cannot override them.
Correctness is unaffected (the two-argument form forwards to the dynamic
requirement), but do not expect to intercept them.

**Probe tests are not serialised.** `AssertionProbe` and `AssertionHolder` tests are
safe together today only because their assertion names are disjoint
(`"coffee-bar probe baseline"` vs `"coffee-bar is serving"`). A second
`AssertionProbe` test would race. Move to `@Suite(.serialized)` before adding one.

**Journal schema decoding is deliberately permissive.** A journal with
`schemaVersion: 99` must decode successfully. `decide()` returns
`.revert(.unknownSchema)`, and reverting requires the record to decode far enough to
yield `priorValue` — the value to restore *to*. Adding rejection at the store or in
`init(from:)` makes that branch unreachable for every real on-disk journal. Pinned by
`schemaVersionIsReadFromTheFileNotAssumed`.

**Nothing may hold `PreventUserIdleDisplaySleep`.** Letting the display sleep while
the system stays awake is the product's differentiator (handoff §6.1). Two guards
exist, in two components, because a single one covered only one:
`holderNeverPreventsDisplaySleep` for `AssertionHolder`, and the `run(whileHeld:)`
observation for `AssertionProbe`.

---

## Open residuals

**fd leak in `SystemCommandRunner.run`** — leaks 2 fds per *successful* call,
linearly and unbounded. Measured census over 40 runs: `[5,21,37,53,69,85]`,
identical before and after the timeout work, so it is long-standing.

The severity is indirect. `CommandRunner.swift` degrades silently when `dup` fails —
`let fd = owned >= 0 ? owned : descriptor` — which restores the unsafe
shared-descriptor path *exactly at EMFILE*, and the leak is what makes EMFILE
reachable. **M5's watchdog is a long-lived loop calling this.** Tracked as its own
task.

**Timed-out runs park two threads** until the pipe holder exits — self-cleaning, but
N timeouts park 2N threads. The real fix is killing the process *group*, which needs
`posix_spawn` attributes Foundation's `Process` does not expose.

**Third-party demotion cannot currently be verified.** `setpriority(PRIO_DARWIN_PROCESS,
pid, PRIO_DARWIN_BG)` demotes and restores correctly on a process we own, and the
readback confirms it. For a *foreign* pid, `getpriority` reads 0 even while the target
is demoted — and it reads 0 after Apple's own `taskpolicy -b -p` too, so the failing
component is the **readback**, not necessarily the demotion.

`DemotionProbe` records `targetIsSelf` for exactly this reason: `finalStateRestored`
is a verified fact when the target is self and a return-code claim otherwise. Do not
let a consumer treat them as equal. Before any milestone depends on demoting a foreign
process, answer this with a different instrument — sampling the target's thread QoS,
or measuring core residency under load.

**`WatchdogPolicy` validation is a clamp, not a contract.** The initialiser clamps
`heartbeatTimeout` to `[1,300]` and `batteryFloorPercent` to `[5,100]`, but nothing
prevents a caller passing a legal-but-wrong policy. Clamping rather than
`precondition` is deliberate: `decide()` runs on the *revert* path inside a root
helper, where a trap would leave `SleepDisabled` set — strictly worse than a clamped
value.

**Durability is carried by review, not tests.** `F_FULLFSYNC` vs `fsync`, and the
existence of the parent-directory barrier, are both unverifiable from a unit test:
each call returns 0 and no user-space API reports whether a barrier reached media.
Deleting the barrier entirely leaves the suite green. This is inherent. Do not "fix"
it with a test that greps source for a token — that asserts structure, not behaviour.

**CF ownership is likewise review-only.** `IOPSGetProvidingPowerSourceType` is an
unaudited `Get`, so its result must be taken *unretained*. That is correct by the
header contract (`IOPowerSources.h:315-317`), but mutating it back to
`takeRetainedValue()` leaves the suite green — an over-release of an immortal CF
constant is not deterministically observable in-process. Do not record it as
test-covered; it is a code-review invariant.

---

## M5 security precondition

The journal is an **instruction to a root process**. It currently lands `0644` in a
`0755` tree with nothing verifying path ownership. Harmless in M0, where the probe
runs as the user; not harmless when a privileged helper reads that file and restores
`SleepDisabled` to whatever `priorValue` it finds. If the directory does not exist,
whoever creates the path first owns what the helper will trust.

Before M5's helper reads its first journal:

1. Verify **every** path component is root-owned and not group/other-writable — not
   just the leaf.
2. Refuse and quarantine any journal whose ownership or mode does not match.
3. Create the directory and file from the **privileged** side with explicit
   `0700`/`0600`.
4. Treat `armedBy` provenance as advisory **forensics, not authentication** — it is
   attacker-controlled in this threat model.

---

## Method: what actually caught defects

Every defect found during M0 was in a **test**, never in shipped implementation
logic. That is not luck — it is what happens when implementation is transcribed from
a reviewed plan and the tests are written to match a description rather than to fail.

**A test's name is not evidence.** Three separate guards asserted less than their
names claimed:

| Test | Claimed | Actually asserted |
|---|---|---|
| `hostStampIsRequiredAndSurvivesEncoding` | requiredness | only survival of encoding |
| `writeIsAtomicUnderOverwrite` | atomicity | that two writes both landed |
| `assertionProbeAcquiresAndReleasesCleanly` | acquire *and* release | neither |

Each read as thorough coverage in review. Only a mutant exposed them.

**Mutation at suite scope can lie.** A mutant killed while the whole suite runs may
be killed by *unrelated* tests via a shared side effect — one was caught by three
tests through an `EEXIST` on a later write. When attributing a kill to a specific
guard, re-run **that test alone**.

**Emphasis in a plan is not a guard.** Twice a requirement was marked CRITICAL in
prose while the accompanying test list left it unverified — the watchdog's precedence
ordering, and the thermal fail-safe. Both mutated green until someone checked.

**Individually-proof guards do not imply a proof composition.** Seven watchdog guards
were each mutation-proof while all six *adjacent orderings* between them survived.
Where a spec names an order, a precedence, or a parameter, that structure needs its
own test; one-guard-at-a-time mutation can never reach it.

**Prefer a stated gap to a comfortable test.** Several honest "not covered" reports
were more useful than the guards they replaced, because a fake guard stops people
thinking about the risk.
