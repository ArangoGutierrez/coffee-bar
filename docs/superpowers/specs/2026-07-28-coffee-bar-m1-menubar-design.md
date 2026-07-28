# M1 — menu-bar app design

Status: approved 2026-07-28. Supersedes nothing; this is the first M1 design.

M1 is the first shipping milestone. It delivers a menu-bar app that holds one
IOKit power assertion under manual control, and it builds the decision core that
M2 plugs agent ingest into.

Authorities, in precedence order: this spec, then `docs/ROADMAP.md`, then
`coffee-bar-HANDOFF.md`. Where the handoff is silent, this spec decides and says
so.

---

## 1. Scope

### In

- A `MenuBarExtra` app, `LSUIElement`, no Dock icon.
- A manual "Serving" control that acquires and releases
  `PreventUserIdleSystemSleep` through the existing `AssertionHolder`.
- `PowerBroker` — the pure decision function, in Foundation-only `CoffeeBarCore`.
- `HoldController` — the latching state machine that owns the release rule.
- The §5.1 session model types, unused in M1 and populated by M2.
- A battery floor at 20% on battery power, with the reason shown in the panel.
- `scripts/build-app.sh` — a signed-ready `.app` assembly, replacing the POC script.

### Out

M1 ships no agent ingest, no session list, no notifications, no Settings window,
no privileged helper, no lid-closed mode, no process demotion, and no token
accounting. The session list is empty by construction, so M1 renders no session
rows at all rather than an empty-state placeholder.

### Deleted by this milestone

`Sources/CoffeeBarMenuBarPOC/`, the `coffee-bar-poc` product, and
`scripts/build-poc-app.sh`. The POC's own header requires it: "M1 replaces this
target wholesale — do not review it as milestone code, do not build on it, do not
copy patterns out of it."

---

## 2. The invariant that justifies the product

**Nothing may hold `PreventUserIdleDisplaySleep`.** Handoff §6.1 makes
display-off-while-awake the difference from `caffeinate -d` and KeepingYouAwake.

`AssertionHolder` already carries a guard asserting its type set is exactly
`["PreventUserIdleSystemSleep"]`. M1 adds a second, at the decision layer:
`DesiredPowerState.displaySleepAssertion` is `false` on **every** path, asserted
across every input combination in the broker's table test.

Two guards in two layers is deliberate. `docs/ENGINEERING-NOTES.md` records that a
single guard previously covered only one of two components, and a review had to
catch it.

---

## 3. Architecture

```
CoffeeBarApp (SwiftUI, @MainActor, needs a Mac)
    │  reads
    ▼
SystemPowerReader (CoffeeBarPower, IOKit)  ──┐
                                             │
UserIntent (the toggle)  ────────────────────┤
                                             ▼
                                    HoldController (CoffeeBarCore, pure)
                                             │ calls
                                             ▼
                                    PowerBroker.decide (CoffeeBarCore, pure)
                                             │ returns DesiredPowerState
                                             ▼
                                    AssertionHolder (CoffeeBarPower, IOKit)
```

`CoffeeBarCore` keeps zero Apple-framework dependencies beyond Foundation, per
handoff §13.1, so the whole decision path tests without a Mac in the loop. The UI
layer never touches IOKit and never decides anything.

### Why the decision core lands in M1 rather than M2

Handoff line 202: "All decisions live in `PowerBroker`". Putting the decision in
the SwiftUI layer for M1 would invert the dependency direction and guarantee a
rewrite in M2, which is already a committed milestone under the v0.1 cut.

---

## 4. Types

All new types live in `CoffeeBarCore` unless stated otherwise.

### 4.1 Session model — from handoff §5.1, verbatim shape

```swift
public enum AgentTool: String, Codable, Sendable { case claudeCode, codex, cursor }

public enum SessionState: String, Codable, Sendable {
    case starting, working, awaitingPermission, awaitingInput, done, failed, stale
}

public struct AgentSession: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(tool.rawValue):\(sessionID)" }
    public let tool: AgentTool
    public let sessionID: String
    public let cwd: URL?
    public let repoName: String?
    public let pid: pid_t?
    public let state: SessionState
    public let stateEnteredAt: Date
    public let lastEventAt: Date
    public let lastMessage: String?      // truncated to 140, per §5.1
    public let attentionSince: Date?
    public let turnCount: Int
}
```

**M1 never constructs an `AgentSession` outside a test.** These types exist so
that M2 adds ingest rather than reshaping the broker's signature.

### 4.2 Decision types

```swift
public enum PowerSource: Equatable, Sendable { case ac, battery }
public enum UserIntent: Equatable, Sendable { case serve, stop }

public enum HoldSuppression: Equatable, Sendable {
    case batteryFloor(percent: Int, floor: Int)
}

public struct PowerInputs: Equatable, Sendable {
    public let sessions: [AgentSession]        // always empty in M1
    public let powerSource: PowerSource
    public let batteryPercent: Int?            // nil where there is no battery
    public let userIntent: UserIntent
    public let holdAwakeWhileBlocked: Bool     // §5.1 knob, default false
    public let batteryFloorPercent: Int        // §8.1 default 20
}

public struct DesiredPowerState: Equatable, Sendable {
    public let idleSleepAssertion: Bool
    public let displaySleepAssertion: Bool     // false on every path in v0.1
    public let suppression: HoldSuppression?
}
```

**On the fields M1 omits.** Handoff §5.2 lists `sleepDisabled`, `demoteSet`,
`suspendSet`, `spotlightSuppressed`, `timeMachineSuppressed` on
`DesiredPowerState`. M1 defines none of them. Nothing in M1 can honour them, and
a field that does not exist cannot be silently dropped. M5 and M6 add each field
together with the component that acts on it. This answers the panel's concern
about dropped state more strongly than logging would.

`thermalState` and `lidClosed` are omitted from `PowerInputs` for the same
reason: no data source exists before M3/M5. Profiles beyond on/off are M6.

---

## 5. Behaviour

### 5.1 The wake predicate

```
activeStates = holdAwakeWhileBlocked
    ? [.starting, .working, .awaitingPermission, .awaitingInput]
    : [.starting, .working]

sessionsWantAwake = sessions.contains { activeStates.contains($0.state) }
wantsHold         = (userIntent == .serve) || sessionsWantAwake
```

`holdAwakeWhileBlocked` defaults to `false`, per §5.1. In M1 `sessions` is empty,
so `wantsHold` reduces to the toggle.

**A deliberate ambiguity, named rather than hidden.** The formula above ORs the
two sources, so an active session would hold the assertion even when the user
has explicitly chosen `.stop`. That is almost certainly wrong as final
behaviour — an explicit stop should win — but the correct precedence depends on
what handoff §5.2 means by `userOverride`, which the handoff names once and never
defines.

M1 cannot resolve it, because M1 never has a session. The OR is therefore
provisional and unreachable in M1. **M2 must decide the precedence before ingest
populates `sessions`,** and this line is the reminder. No M1 test asserts the
mixed case, because M1 cannot produce it.

### 5.2 The battery floor

Handoff §8.1 lists five abort conditions. Three carry an explicit qualifier
(`while lid is closed`, `while SleepDisabled is set`). **The battery bullet
carries none**, so it applies to the plain user-level assertion.

```
if wantsHold, powerSource == .battery, let pct = batteryPercent, pct <= floor {
    → idleSleepAssertion = false, suppression = .batteryFloor(pct, floor)
}
```

A `nil` battery percentage never suppresses. A desktop has no battery, and an
unreadable percentage must not silently stop the product working.

### 5.3 The release rule — latching, no auto-re-arm

`PowerBroker` is pure and has no memory, so the release rule lives in
`HoldController`:

1. When the broker returns a `suppression`, `HoldController` sets `userIntent` to
   `.stop` and publishes the reason.
2. It does **not** restore `.serve` when the battery recovers or the machine
   returns to AC. Re-arming requires the user to toggle again.

Feeding 21% → 20% → 21% therefore produces **exactly one** release. Auto-re-arm
would be a behaviour the user did not ask for and cannot see coming.

Toggling on while already below the floor is refused the same way: the toggle
does not latch on, and the panel states why.

### 5.4 What the user sees

The panel shows the toggle, and — when suppressed — one line naming the reason
and the measured percentage. `HoldController` publishes a `HoldSuppression`
value; the view renders it. **The reason is asserted on that enum, never on
rendered AppKit text**, otherwise the surfacing half of this decision is itself
untested.

---

## 6. Testing

`CoffeeBarCore` tests run without a Mac. Test files are named
`<Subject>_test.swift`, required by `tdd-guard.sh`.

### Required guards

| Guard | Asserts |
|---|---|
| `displaySleepAssertionIsNeverRequested` | `displaySleepAssertion == false` across **every** input combination |
| `wakePredicateHonoursOnlyStartingAndWorking` | each of the 7 `SessionState` cases, with the knob off |
| `blockedStatesHoldOnlyWhenTheKnobIsSet` | `awaitingPermission` / `awaitingInput` flip with `holdAwakeWhileBlocked` |
| `batteryFloorSuppressesAtOrBelowTheFloor` | 21% holds, 20% suppresses, 19% suppresses |
| `batteryFloorAppliesOnlyOnBatteryPower` | 19% on AC holds |
| `absentBatteryReadingNeverSuppresses` | `batteryPercent == nil` holds |
| `recoveringBatteryDoesNotReArmTheHold` | 21→20→21 yields exactly one release |
| `suppressionReasonNamesTheMeasuredPercent` | the enum carries the real value, not a constant |

### Forbidden in M1

- **No test may assert session-transition semantics.** Handoff §14 requires
  `SessionHub` to be fed "recorded hook payloads (capture real ones during M2)".
  Asserting transitions against invented events now would repeat the M0 failure
  mode, where guards written from a description passed while asserting nothing.

  The distinction an implementer must hold: testing **which states the predicate
  treats as awake** is required, because that is a pure function of the enum.
  Testing **which events move a session between states** is forbidden, because
  that needs payloads M1 has never seen. The first constructs an `AgentSession`
  in a known state and reads the predicate. The second does not exist in M1.
- No tests for `thermalState`, `lidClosed`, or profiles beyond on/off. Those
  inputs do not exist in M1.

### Mutation requirement

Each guard above is mutation-checked by deleting the behaviour it names and
confirming that guard alone goes red. Attribution runs the named test alone —
`docs/ENGINEERING-NOTES.md` records that suite-scope mutation can be killed by
unrelated tests through a shared side effect.

Note that `swift test --filter` exits 0 when it matches nothing, so every kill
attribution confirms a non-zero test count.

### Acceptance, run by hand on real hardware

1. `scripts/build-app.sh`, then `open build/CoffeeBar.app`.
2. Toggle Serving on. `pmset -g assertions` names `coffee-bar is serving` under
   `PreventUserIdleSystemSleep`.
3. The same output shows **no** `PreventUserIdleDisplaySleep` held by coffee-bar.
4. The display sleeps on its normal schedule while the system stays awake.
5. Toggle off. The assertion disappears.

---

## 7. Packaging

`scripts/build-app.sh` derives from the POC script and keeps its verified parts:
`plutil -lint`, the `LSUIElement` extract check, the required-glyph guard, and
`command cp -f` to defeat an interactive `cp -i` alias.

Changes from the POC script: product `coffee-bar`, bundle `CoffeeBar.app`, bundle
id `com.coffeebar.app`, and a version read from one place rather than hard-coded
in the heredoc.

Signing, notarisation and Sparkle are M4. No `.xcodeproj` is created; the POC
script already proves SwiftPM builds a `MenuBarExtra` app.

---

## 8. Decisions this spec makes where the handoff is silent

| Gap | Decision |
|---|---|
| What drives the assertion with no ingest | A manual toggle, per §6.5 screen 1 |
| Whether §8.1's battery floor covers the plain assertion | Yes — the bullet is unqualified where three siblings are qualified |
| Re-arm after a floor release | Latching. The user re-toggles; nothing auto-re-arms |
| `DesiredPowerState` fields M1 cannot honour | Omitted, not stubbed |
| Session list empty state | No rows rendered at all in M1 |
| Bundle mechanism | Script-assembled, no `.xcodeproj` |
| App bundle id | `com.coffeebar.app` |
| Launch at login | Out of M1. Not specified anywhere in the handoff |
| `staleTimeout` default | Not set here. M2 owns it, with the sampler |

## 9. Risk carried into M2

The session types are written from the handoff's description, not from observed
Claude Code hook payloads. If real payloads do not map onto the seven states, M2
reshapes the enum. The panel raised this and it is accepted deliberately: M1
writes no transition logic and no transition tests, so the exposed surface is the
enum shape alone, and adding a case is additive.
