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

**Only `AssertionHolder` may hold `PreventUserIdleDisplaySleep`, and only when the
user opts in.** Letting the display sleep while the system stays awake is the
product's differentiator (handoff §6.1). Issue #12 settled that it is a DEFAULT and
not a promise, so the rule became an entitlement of one file and one symbol —
`displayAssertionEntitlement` in `AppLayerBoundary_test.swift`. Nothing reads the
setting on the way to IOKit: `PowerBroker` weighs the off switch and the battery
floor first, and `AssertionHolder` takes only what
`DesiredPowerState.displaySleepAssertion` asks for.

Guards exist in two components, because a single one covered only one:
`theHolderPreventsNoDisplaySleepWhileTheHoldIsOff` and
`noDisplayAssertionIsHeldUnderAnyNameWhileTheHoldIsOff` for `AssertionHolder`, and
the `run(whileHeld:)` observation for `AssertionProbe`. `AssertionProbe` keeps the
absolute ban: a capability probe has no user to ask.

---

## Open residuals

**~~fd leak in `SystemCommandRunner.run`~~ — FIXED.** Kept here because the diagnosis
is worth not rediscovering.

`Process` takes ownership of only the two **write** ends of the pipes — it closes and
invalidates them at spawn, which is *why* the drain ever sees EOF. Nothing owned the
**read** ends; `run()` dup'd them and closed only the dups. Census over 40 successful
runs went `[6,22,38,54,70,86]` (+2/call) to `[4,4,4,4,4,4]` (flat). A second leak on
the spawn-failure path (+4/call) came from the same root: when `process.run()` throws,
`Process` has not taken the write ends either. One `defer` before the spawn, closing
all four handles, fixes both.

**The `dup`-failure fallback was removed, and that was a prerequisite rather than a
tidy-up.** The old code did `let fd = owned >= 0 ? owned : descriptor`. Once `run()`
closes the pipe read ends on unwind, a reader left on the *shared* descriptor is
reading one `run()` has already closed — and a closed fd number is handed to the next
`open()`, so a parked read silently steals bytes from an unrelated file. Keeping the
fallback alongside the leak fix would have promoted a rare EMFILE hazard into routine
cross-file corruption on the ordinary success path. It now throws
`CommandError.descriptorUnavailable(errno:)`.

That path is deliberately untested: forcing a real `dup` failure needs `setrlimit` or
table exhaustion, both process-global, and this suite runs in parallel — it would
trade a deterministic bug for a flaky suite.

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

**The battery floor is bounded in one place, and issue #11 is why.** The floor is now
a user setting, so its value arrives from outside the program. `PowerInputs.init` is
the site: `PowerBroker.decide` takes a `PowerInputs` and nothing else, and that struct
declares an explicit `init`, which suppresses the memberwise one — so no caller reaches
the comparison with a floor the rule never saw. The rule itself lives on `BatteryFloor`
and `WatchdogPolicy.init` calls the same function rather than keeping its own copy. Two
clamps with their own literals drift the moment one is edited, and the product would
then refuse a hold at a charge the watchdog is content to keep. Do not add a second
bounding site — bounding at the UI or at the settings read was weighed and rejected,
and `bothFloorPathsBoundTheSameValueTheSameWay` goes red on a split.

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

## M5 is NOT "install mechanism only" — a claim I got wrong three times

I wrote, in this file and in two commit messages, that M5 swaps only the *installation*
mechanism (plain plist + `launchctl bootstrap` → `SMAppService`) while the supervised
logic carries over unchanged. A Principal Engineer review showed that is false.

`SMAppService.daemon(plistName:)` registers a **static, code-signed plist shipped inside
the app bundle, referenced by name**. There is no path argument, no generated XML, and
no `launchctl` subprocess. So `plistContents(binaryPath:)`, `install(binaryPath:)` and
the `CommandRunning` injection are not implementation details that survive the
migration — they are precisely the public surface that **disappears**. Migrating means
changing every call site, not swapping one type.

Worse, every parameter that M5 deletes is also where M0's root-privilege exposure
lives: XML injection through `binaryPath`, absent validation that the daemon's program
is root-owned, and a caller-supplied `plistURL`. The API makes the dangerous thing easy
and the safe thing optional.

The fix, applied in M0 rather than deferred: hoist to

```swift
protocol WatchdogSupervising {
    func install() throws
    func uninstall() throws
}
```

with the binary path resolved **and validated inside** the implementation. M5 then
becomes a second conformer with no caller churn, and the injection surface never
existed to begin with.

Lesson worth keeping separately from the fix: "the migration is mechanism-only" was an
assumption I recorded as a fact and then cited twice more as though it had been
checked. It had not — nobody had read what `SMAppService` actually takes as input.

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
