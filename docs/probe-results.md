# Probe results

Spike answers measured on real hardware, per handoff §10. Every entry records the
machine and OS build, because `SleepDisabled` and the power APIs are the kind of thing
Apple changes in a point release.

**Measurement host:** MacBook, Apple Silicon (arm64), macOS **26.5.2 build 25F84**,
Xcode 26.6 (17F113), Swift 6.3.3. Internal battery present.

---

## S3 — `proc_pid_rusage` energy fields — **ANSWERED: available**

**Question (handoff §10):** is `ri_billed_energy` populated for processes coffee-bar
does not own, without an additional entitlement?

**Answer: yes, for same-uid processes, with no special entitlement.** Cross-uid reads
are refused.

| Target | Result |
|---|---|
| Self | `pass`, `ri_billed_energy` = 2,374 |
| Same-uid third party (Finder, pid 1697) | `pass`, `ri_billed_energy` = **56,898,706,406** |
| Root-owned (launchd, pid 1) | `fail`, `proc_pid_rusage` rc = −1, errno 1 (EPERM) |

Measured with `RUSAGE_INFO_V4` (`sys/resource.h:190`). Note `RUSAGE_INFO_CURRENT` is
V6; V4 is pinned deliberately and is two revisions behind.

Independently reproduced by a second agent against different pids, including the
cross-uid EPERM.

**Consequence for the architecture.** Handoff §3 and §15 both depend on per-process
energy attribution being reachable. It is, for exactly the processes coffee-bar would
plausibly care about — the user's own agent processes and apps. No entitlement, no
privileged helper, no `taskpolicy` shell-out. This removes a risk from the Token Tap
design (§15.10's "tokens per watt-hour") and from any future energy display.

---

## S5 — demotion privilege — **PARTLY ANSWERED**

**Question (handoff §10):** does `setpriority(PRIO_DARWIN_BG)` / `taskpolicy -b -p`
succeed on a same-uid, hardened-runtime, notarised third-party app without root?

**Answer so far: demote and restore both work on a process we own. For a foreign pid,
the result cannot currently be verified — and that is a limitation of the
*instrument*, not evidence that demotion fails.**

| Case | Result |
|---|---|
| Self — demote | succeeds; `getpriority(PRIO_DARWIN_PROCESS, self)` reads 1 while demoted |
| Self — restore | succeeds; reads back 0 |
| Foreign pid (owned child) — readback while demoted | **reads 0**, i.e. the readback does not reflect the state |
| Foreign pid — after Apple's own `taskpolicy -b -p` | also reads 0 |

Because Apple's own tool produces the same unreadable result, the failing component is
the **readback**, not necessarily the demotion. Reporting "third-party demotion does
not work" would be wrong.

`finalStateRestored` is therefore only *verified* when the target is self. The probe
records `targetIsSelf` so consumers cannot conflate the two. For a foreign pid it is a
return-code claim only.

**Open:** whether demotion actually takes effect on a foreign process needs a
different instrument — sampling the target's thread QoS, or measuring its core
residency under load. Worth a follow-up spike before any milestone depends on
third-party demotion.

### API correction, recorded because the plan had it wrong

The implementation plan specified:

```swift
setpriority(PRIO_DARWIN_BG, pid, 0)     // WRONG — demotes nothing
```

`PRIO_DARWIN_BG` (`0x1000`, `sys/resource.h:120`) is a *prio value*, not a *which
selector*; valid `which` values are 0–4 (`sys/resource.h:99-106`). That call returns
−1/EINVAL. The correct form, and what ships:

```swift
setpriority(PRIO_DARWIN_PROCESS, who, PRIO_DARWIN_BG)   // demote
setpriority(PRIO_DARWIN_PROCESS, who, 0)                // restore
```

**On the restore value:** an earlier commit message claimed the state must be cleared
with `0` "and not with `1`". That is **false** — a reviewer measured restore-with-`1`
and the process returns to `backgroundAfter == 0` just as it does with `0`. Any
non-`PRIO_DARWIN_BG` value clears it. Only the *which* argument was ever broken.

---

## Not yet run

- **S1** — `SleepDisabled` survives lid close. Requires root, a physical lid close and
  ~10 minutes. Deliberately deferred; v0.1 does not depend on it (see `ROADMAP.md`).
- **S2** — internal display state under a closed lid. Same session as S1.
- **S4** — Cursor CLI hooks. Runtime test, out of M0 scope.
- **S6** — battery measurement harness. A measurement protocol, not a probe.
- **S8** — telemetry collision. Config inspection; Task 9.
