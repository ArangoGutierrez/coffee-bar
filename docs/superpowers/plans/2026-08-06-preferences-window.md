# Preferences Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every configurable control out of the 260pt menu-bar panel into a
dedicated Preferences window, rebuild the battery floor as a slider over a
narrowed policy, and give each unwired agent tool a copy-the-snippet action.

**Architecture:** A second SwiftUI `Scene` (`Settings`) sibling to the existing
`MenuBarExtra`, reached by `SettingsLink` from a `Preferences…` item above
`Quit coffee-bar`. The panel keeps live state only. Snippet text is generated in
`CoffeeBarCore` from `HookHealth.requiredEvents(for:)` so it cannot drift from
what the health check looks for.

**Tech Stack:** Swift 6, SwiftUI, swift-testing (`@Test` / `#expect`), SwiftPM.

**Spec:** `docs/superpowers/specs/2026-08-06-preferences-window-design.md`
**Issues:** #50, #37 (phase 1 only), #31
**Base:** `709715d`

## Global Constraints

- Deployment target is macOS 14 (`Package.swift`: `platforms: [.macOS(.v14)]`).
  `SettingsLink` requires it and is available.
- The app is `LSUIElement` — no Dock icon, `.accessory` activation.
- **Never write an absolute home path into a tracked file.**
  `noTrackedFileCarriesLiveSessionProse` scans every tracked file for the real
  username and turns the suite RED. Write `$HOME` or `~`.
- **Build with a fresh run-scoped scratch path**, never a warm `.build`:
  `swift build --scratch-path /tmp/claude/prefs-$(date +%s)-$$ --build-tests`.
  A warm `.build` certified a tree that could not compile from clean, six times.
- Compile-error count: `grep -cE '^.*:[0-9]+:[0-9]+: error:|^error:'`. The
  `^/.*\.swift:` form misses macro-expansion errors — every `#expect`.
- M1 design §5.4 rules out asserting on rendered AppKit text or rendered
  geometry. No check in this plan renders a view and reads a label out of it.
- Every commit is signed: `git commit -s -S`.
- `CoffeeBarCore` performs no I/O (design §8). Paths it returns are relative.
- Mutation-check every new guard: delete the behaviour it guards, confirm RED,
  restore. A guard that stays green when its subject is removed is theater.

---

## File Structure

| Path | Responsibility | Task |
|---|---|---|
| `Sources/CoffeeBarCore/BatteryFloor.swift` | policy: range, step, default, derived choices | 1 |
| `Sources/CoffeeBarCore/HookSnippet.swift` *(new)* | generate a tool's hook entry from `requiredEvents` | 3 |
| `Sources/CoffeeBarApp/main.swift` | add the `Settings` scene | 4 |
| `Sources/CoffeeBarUI/PreferencesView.swift` *(new)* | the window's whole content | 4, 5, 6 |
| `Sources/CoffeeBarUI/PanelView.swift` | lose 3 controls, gain `Preferences…` | 4, 5 |
| `README.md`, `docs/QUICKSTART.md`, `site/index.html`, `site/assets/bench.test.js` | the default is stated in six places | 1 |

Task 2 writes no product code — it resolves an unknown that Task 3 depends on.

---

## Task 1: Narrow the battery floor policy and sweep the six sites

Pure `CoffeeBarCore` change plus the documentation that states it. The doc sweep
is folded in because `theBatteryFloorStatedIsTheRealDefault` and the site suite
go RED the moment `default` changes — they are the same deliverable.

**Files:**
- Modify: `Sources/CoffeeBarCore/BatteryFloor.swift`
- Modify: `README.md`, `docs/QUICKSTART.md`, `site/index.html`, `site/assets/bench.test.js`
- Test — CREATE: `Tests/CoffeeBarCoreTests/BatteryFloor_test.swift`. **It does
  not exist today.** `BatteryFloor` is currently exercised only indirectly, from
  `PowerBroker_test.swift`, `WatchdogDecision_test.swift`, `HoldController_test.swift`,
  `DocsClaims_test.swift` and `SiteClaims_test.swift`. The policy is about to
  become the subject of a decision rather than a constant, so it earns its own file.
- Test — existing, must stay green: `Tests/CoffeeBarUITests/ServingModel_test.swift`
  (`everyOfferedFloorSitsInsideThePermittedRange`),
  `Tests/CoffeeBarCoreTests/DocsClaims_test.swift`
  (`theBatteryFloorStatedIsTheRealDefault`)

**Interfaces:**
- Produces: `BatteryFloor.permitted: ClosedRange<Int>` = `10...50`;
  `BatteryFloor.step: Int` = `5`; `BatteryFloor.default: Int` = `15`;
  `BatteryFloor.choices: [Int]` becomes a computed `[10, 15, 20, …, 50]`.
  `bounded(_:)` keeps its existing signature `(Int) -> Int`.

- [ ] **Step 1: Write the failing test**

CREATE `Tests/CoffeeBarCoreTests/BatteryFloor_test.swift` — it does not exist.
Start the file with the licence header every source file in this repo carries:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
@testable import CoffeeBarCore

@Test func theOfferedFloorsAreDerivedFromTheRangeAndStep() {
    // Named bug this catches: a hand-edited `choices` list that disagrees with
    // `permitted` — the exact drift the old literal [10, 20, 30, 40, 50] made
    // possible, and which put `default` outside the offered set.
    #expect(BatteryFloor.choices == [10, 15, 20, 25, 30, 35, 40, 45, 50])
    #expect(BatteryFloor.choices.first == BatteryFloor.permitted.lowerBound)
    #expect(BatteryFloor.choices.last == BatteryFloor.permitted.upperBound)
}

@Test func theDefaultIsReachableFromTheControl() {
    // A default a user cannot get back to is a setting with no undo.
    #expect(BatteryFloor.choices.contains(BatteryFloor.default))
    #expect(BatteryFloor.default == 15)
}

@Test func aStoredFloorOutsideTheNewRangeIsClampedNotTrapped() {
    // Migration: someone stored 75 under the old 5...100 policy.
    #expect(BatteryFloor.bounded(75) == 50)
    #expect(BatteryFloor.bounded(5) == 10)
    #expect(BatteryFloor.bounded(15) == 15)   // idempotent inside the range
}
```

- [ ] **Step 2: Run it and verify it fails**

```
swift test --filter BatteryFloor
```
Expected: FAIL. `choices` is `[10, 20, 30, 40, 50]`, `default` is `20`,
`bounded(75)` returns `75`.

- [ ] **Step 3: Change the policy**

In `Sources/CoffeeBarCore/BatteryFloor.swift`, replace the three declarations.
Keep every existing doc comment and extend it — the comments carry the reasoning
and a later reader needs it:

```swift
    public static let `default` = 15

    public static let permitted = 10...50

    /// The gap between offered floors.
    ///
    /// Here beside `permitted` for the reason `choices` gives: two numbers a
    /// view could restate are two numbers that can drift from the policy.
    public static let step = 5

    /// What the control offers, DERIVED so it cannot disagree with the range.
    ///
    /// Was a literal list. A literal let `default` sit outside the offered set,
    /// which is a setting with no undo.
    public static var choices: [Int] {
        Array(stride(from: permitted.lowerBound,
                     through: permitted.upperBound,
                     by: step))
    }
```

- [ ] **Step 4: Run the Swift suite and read what else broke**

```
swift test 2>&1 | tail -40
```
Expected: `BatteryFloor` tests PASS. `theBatteryFloorStatedIsTheRealDefault`
FAILS — the docs still say 20. That failure is the next step's worklist, not a
regression.

- [ ] **Step 5: Sweep all six sites**

Exact current text, verified on `709715d`:

| File | Change |
|---|---|
| `README.md` | `at or below 20%` → `at or below 15%` |
| `docs/QUICKSTART.md` | `The Battery floor control ships at 20%.` → `15%` |
| `docs/QUICKSTART.md` | `does not hold at or below 20%` → `15%` |
| `site/index.html` | `{"batteryFloorPercent":20}` → `{"batteryFloorPercent":15}` |
| `site/assets/bench.test.js` | `assert.equal(META.batteryFloorPercent, 20);` → `15` |
| `site/assets/bench.test.js` | the comment above it naming 20 as the default |

Leave `site/assets/bench.test.js` line ~223 alone: it passes
`{ batteryFloorPercent: 35 }`, which is inside the new range.

Verify the after-state rather than trusting the edit — scripted substitution
silently no-ops:

```bash
grep -rn "20%" README.md docs/QUICKSTART.md
grep -n "batteryFloorPercent" site/index.html site/assets/bench.test.js
```
Expected: no `20%` battery-floor line survives; both site files read 15.

- [ ] **Step 6: Run both suites**

```
swift test 2>&1 | tail -20
node --test site/assets/bench.test.js 2>&1 | tail -20
```
Expected: both green, 0 failures.

- [ ] **Step 7: Mutation-check the derived list**

Temporarily set `step = 10` and re-run `swift test --filter BatteryFloor`.
Expected: `theOfferedFloorsAreDerivedFromTheRangeAndStep` AND
`theDefaultIsReachableFromTheControl` both go RED — 15 vanishes from the offered
set. Print the diff to prove the mutant applied, then restore.

- [ ] **Step 8: Commit**

```bash
git add Sources/CoffeeBarCore/BatteryFloor.swift Tests/CoffeeBarCoreTests/BatteryFloor_test.swift \
        README.md docs/QUICKSTART.md site/index.html site/assets/bench.test.js
git commit -s -S -m "feat(power): narrow the battery floor to 10-50 in 5% steps, default 15 (#31)"
```

---

## Task 2: Resolve the snippet form — measurement, not code

**This task writes no product code and its output is a written finding.** Task 3
generates a hook command per tool and the correct form for Codex and Cursor is
currently UNKNOWN. Two sources disagree:

- `Sources/CoffeeBarCore/HookShim.swift` states Codex and Cursor accept command
  handlers only and therefore invoke the `coffeebar-hook` binary rather than
  posting the way Claude Code's `curl` line does.
- The maintainer's live `~/.codex/hooks.json` uses the `curl` form and
  `HookHealth` reports it wired.

`HookHealth` matches on `commandMarker` (`coffee-bar/ingest.sock`) OR
`shimCommandName` (`coffeebar-hook`), so **"wired" is string-matching and is not
evidence the hook executes.** The live Codex file was also hand-written by an
agent on 2026-08-06, so it is not independent evidence.

Shipping a copy button that emits a form the tool never executes is a button that
silently does nothing, and no unit test can see it.

- [ ] **Step 1: Confirm the socket is listening and owned by one instance**

```bash
lsof -U 2>/dev/null | grep coffee-bar
```
Expected: exactly one listener. Two instances compete and the loser reports
"not listening for agent events" — that is a known misdiagnosis trap.

- [ ] **Step 2: Record the current event count**

Note the panel's waiting list and any journal count before the probe, so the
next step's delta is attributable.

- [ ] **Step 3: Drive a REAL Codex session and observe**

Start a Codex session, submit one prompt, let it call one tool. Then check
whether coffee-bar received anything attributed to `codex`.

Expected outcomes, both informative:
- Events arrive → the `curl` form works for Codex; `HookShim.swift`'s comment is
  wrong and is corrected in Task 3.
- No events arrive → the `curl` form is inert for Codex; the snippet must emit
  `coffeebar-hook --tool=codex` and the maintainer's live config is broken and
  needs repairing.

- [ ] **Step 4: Repeat for Cursor**

Cursor is currently unwired (`~/.cursor/hooks.json`, 0 markers), so wire it with
ONE form, drive a session, observe, and record. Cursor uses the FLAT shape;
Claude Code and Codex use the NESTED shape.

**Wiring Cursor requires the maintainer's explicit approval** — it is persistent
hook execution on a tool that was not named in the original grant. Ask before
running it.

- [ ] **Step 5: Write the finding**

Record in `docs/superpowers/plans/2026-08-06-preferences-window.md` under this
task, or as a comment on #37: which command form each of the three tools
actually executes, with the observed evidence. Task 3 reads this and nothing
else.

- [ ] **Step 6: Commit the finding**

```bash
git add docs/superpowers/plans/2026-08-06-preferences-window.md
git commit -s -S -m "docs(plan): record which hook command form each tool executes (#37)"
```

---

## Task 3: Generate the hook snippet in CoffeeBarCore

**Blocked by Task 2.** Do not start until the command form per tool is a recorded
measurement.

**Files:**
- Create: `Sources/CoffeeBarCore/HookSnippet.swift`
- Test: `Tests/CoffeeBarCoreTests/HookSnippet_test.swift`

**Interfaces:**
- Consumes: `HookHealth.requiredEvents(for:) -> [String]?`,
  `HookHealth.settingsPath(for:) -> String`, `HookHealth.commandMarker`,
  `HookHealth.shimCommandName`, `AgentTool.shimName`.
- Produces: `HookSnippet.json(for tool: AgentTool) -> String?` — the pasteable
  JSON fragment, or `nil` when `requiredEvents(for:)` is `nil`. Task 5 calls it.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import CoffeeBarCore

@Test func theSnippetCoversExactlyTheEventsTheCheckerLooksFor() throws {
    // Named bug this catches: a hardcoded snippet telling the user to wire five
    // events while `requiredEvents(for:)` looks for six. The health check would
    // then report broken forever with nothing the user could do.
    for tool in AgentTool.allCases {
        let events = try #require(HookHealth.requiredEvents(for: tool))
        let snippet = try #require(HookSnippet.json(for: tool))
        for event in events {
            #expect(snippet.contains(event),
                    "\(tool) snippet omits \(event), which the checker requires")
        }
    }
}

@Test func everySnippetCarriesAMarkerTheCheckerRecognises() throws {
    // A snippet the checker cannot recognise leaves the user wired and still
    // reported broken.
    for tool in AgentTool.allCases {
        let snippet = try #require(HookSnippet.json(for: tool))
        #expect(snippet.contains(HookHealth.commandMarker)
                || snippet.contains(HookHealth.shimCommandName))
    }
}

@Test func theSnippetIsValidJSON() throws {
    for tool in AgentTool.allCases {
        let snippet = try #require(HookSnippet.json(for: tool))
        let data = Data(snippet.utf8)
        #expect(throws: Never.self) { try JSONSerialization.jsonObject(with: data) }
    }
}

@Test func noSnippetCarriesAnAbsoluteHomePath() throws {
    // CoffeeBarCore does no I/O and resolves no home directory (design §8).
    // A literal /Users/... in a snippet is also a path that is wrong on every
    // other machine.
    for tool in AgentTool.allCases {
        let snippet = try #require(HookSnippet.json(for: tool))
        #expect(!snippet.contains("/Users/"))
        #expect(snippet.contains("$HOME"))
    }
}
```

- [ ] **Step 2: Run it and verify it fails**

```
swift test --filter HookSnippet
```
Expected: FAIL — `HookSnippet` does not exist. This is a compile failure; count
errors with `grep -cE '^.*:[0-9]+:[0-9]+: error:|^error:'`.

- [ ] **Step 3: Implement**

Create `Sources/CoffeeBarCore/HookSnippet.swift`. **Use the command form Task 2
measured** — the `curl` line below is Claude Code's, verified from a working
config on 2026-08-06. Build the structure with `JSONSerialization` so the output
is valid by construction rather than by string concatenation:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The hook entry a user pastes into their agent tool's settings file.
///
/// **Derived, never a literal.** Every event comes from
/// `HookHealth.requiredEvents(for:)`, the same source the health check reads, so
/// a snippet cannot tell the user to wire a set the checker does not look for.
///
/// coffee-bar PRINTS this and never writes the file — M2 ingest design §6. The
/// pasteboard is the user's; a shared settings file is not.
public enum HookSnippet {

    /// The command Claude Code and Codex run. `$HOME` stays UNEXPANDED: this
    /// type performs no I/O and resolves no home directory (design §8), and an
    /// expanded path is wrong on every machine but one.
    static let postCommand = """
        curl -sS -o /dev/null --fail-with-body --max-time 5 --unix-socket \
        "$HOME/Library/Application Support/coffee-bar/ingest.sock" \
        -X POST --data-binary @- http://localhost/event
        """

    /// The pasteable fragment for `tool`, or `nil` when there is no advice to
    /// give — mirroring `requiredEvents(for:)`, where `nil` is not `[]`.
    public static func json(for tool: AgentTool) -> String? {
        guard let events = HookHealth.requiredEvents(for: tool) else { return nil }
        let object: [String: Any] = (tool == .cursor)
            ? flat(events: events)
            : nested(events: events)
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Claude Code and Codex: event -> [ { hooks: [ { type, command } ] } ].
    private static func nested(events: [String]) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in events {
            hooks[event] = [["hooks": [["type": "command", "command": postCommand]]]]
        }
        return ["hooks": hooks]
    }

    /// Cursor: a FLAT shape, and its own event vocabulary.
    private static func flat(events: [String]) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in events {
            hooks[event] = [["command": postCommand]]
        }
        return ["hooks": hooks]
    }
}
```

- [ ] **Step 4: Run the tests**

```
swift test --filter HookSnippet
```
Expected: PASS, 4 tests.

- [ ] **Step 5: Mutation-check the derivation**

Replace `HookHealth.requiredEvents(for: tool)` with a literal
`["SessionStart"]` and re-run.
Expected: `theSnippetCoversExactlyTheEventsTheCheckerLooksFor` goes RED for every
tool. Print the diff to prove the mutant touched only that line, then restore.

- [ ] **Step 6: Commit**

```bash
git add Sources/CoffeeBarCore/HookSnippet.swift Tests/CoffeeBarCoreTests/HookSnippet_test.swift
git commit -s -S -m "feat(hooks): derive the pasteable hook snippet from requiredEvents (#37)"
```

---

## Task 4: The Settings scene and an empty Preferences window

Smallest change that puts a real window on screen. Nothing moves yet, so a
regression here is unambiguous.

**Files:**
- Create: `Sources/CoffeeBarUI/PreferencesView.swift`
- Modify: `Sources/CoffeeBarApp/main.swift`
- Modify: `Sources/CoffeeBarUI/PanelView.swift` (add `Preferences…` above Quit)
- Test: `Tests/CoffeeBarUITests/PreferencesView_test.swift`

**Interfaces:**
- Consumes: `ServingModel` (`@MainActor @Observable public final class`),
  `PanelView.versionLine(from:)`.
- Produces: `public struct PreferencesView: View` with
  `public init(model: ServingModel)`. Tasks 5 and 6 add sections to it.

- [ ] **Step 1: Write the failing test**

The version invariant, checked by source scan — M1 §5.4 rules out reading a
rendered label. **Copy the repo-root locator verbatim from
`noSourceFileThatKnowsTheSettingsPathCanWriteToIt`, at
`Tests/CoffeeBarUITests/HookHealthReader_test.swift:384`; do not invent one.**
A locator resolved through `$HOME/.claude/…` or any deployed copy green-lights
the wrong artifact and makes the whole guard theater.

```swift
@Test func everyTopLevelSurfaceShowsTheRunningVersion() throws {
    // Named bug this catches: a second surface that composes its own version
    // sentence, or none at all. Two spellings of the version leave the user
    // comparing numbers that disagree with no way to tell which app is running
    // — the confusion issue #47 already cost this project once.
    let surfaces = ["PanelView.swift", "PreferencesView.swift"]
    for name in surfaces {
        let text = try sourceText(named: name)   // locator copied from the existing guard
        #expect(text.contains("versionLine(from:"),
                "\(name) does not show the running version")
        #expect(!text.contains("CFBundleShortVersionString"),
                "\(name) reads the version key directly instead of using the one seam")
    }
}
```

- [ ] **Step 2: Run it and verify it fails**

```
swift test --filter everyTopLevelSurfaceShowsTheRunningVersion
```
Expected: FAIL — `PreferencesView.swift` does not exist.

- [ ] **Step 3: Create the view**

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The Preferences window's whole content.
///
/// One scrolling page with headed sections rather than tabs: four short groups
/// do not earn a second navigation layer.
///
/// The version line is here AND in the panel, deliberately. Every surface states
/// the running version, and both read `PanelView.versionLine(from:)` — one seam,
/// so the two can never disagree.
public struct PreferencesView: View {
    @Bindable var model: ServingModel

    public init(model: ServingModel) { self.model = model }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(PanelView.versionLine(from: Bundle.main.infoDictionary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 420, height: 360)
    }
}
```

- [ ] **Step 4: Add the scene**

In `Sources/CoffeeBarApp/main.swift`, inside `var body: some Scene`, after the
existing `MenuBarExtra` and its `.menuBarExtraStyle(.window)`:

```swift
        Settings {
            PreferencesView(model: model)
        }
```

- [ ] **Step 5: Add the panel entry point**

In `Sources/CoffeeBarUI/PanelView.swift`, immediately ABOVE the existing
`Button("Quit coffee-bar")`:

```swift
            SettingsLink {
                Text("Preferences…")
            }
```

- [ ] **Step 6: Clean build and run the tests**

```
swift build --scratch-path /tmp/claude/prefs-$(date +%s)-$$ --build-tests 2>&1 | tee /tmp/claude/build.log
grep -cE '^.*:[0-9]+:[0-9]+: error:|^error:' /tmp/claude/build.log
swift test 2>&1 | tail -20
```
Expected: 0 errors, 0 warnings, suite green.

- [ ] **Step 7: VERIFY IN THE RUNNING APP — not optional**

Rebuild the bundle (`scripts/build-app.sh` — score it on `complete!`, NOT on
`Build complete`, which never appears), launch it, and with **another
application frontmost**:

1. Open the panel, click `Preferences…`. The window must appear IN FRONT.
2. Press `⌘,`. Same window, not a second one.
3. Confirm the panel dismisses.

This is the failure class no unit test can see: an `LSUIElement` app has no
natural activation, so the window can open behind the frontmost app. If it does,
the fix is an explicit `NSApp.activate(ignoringOtherApps: true)` — add it and
re-verify by hand.

Only ONE coffee-bar instance may run. Check `lsof` on the ingest socket first;
two instances compete and the loser reports "not listening for agent events".

- [ ] **Step 8: Commit**

```bash
git add Sources/CoffeeBarUI/PreferencesView.swift Sources/CoffeeBarApp/main.swift \
        Sources/CoffeeBarUI/PanelView.swift Tests/CoffeeBarUITests/PreferencesView_test.swift
git commit -s -S -m "feat(ui): add a Preferences window reached from the panel (#50)"
```

---

## Task 5: Move the three controls, battery floor becomes a slider

**Files:**
- Modify: `Sources/CoffeeBarUI/PreferencesView.swift`, `Sources/CoffeeBarUI/PanelView.swift`
- Test: `Tests/CoffeeBarUITests/PreferencesView_test.swift`

**Interfaces:**
- Consumes: `model.holdDisplayAwake: Bool`, `model.batteryFloorPercent: Int`,
  `model.quietEverythingElse: Bool`, `ServingModel.floorLabel(for:)`,
  `BatteryFloor.permitted`, `BatteryFloor.step` (Task 1).

- [ ] **Step 1: Write the failing placement guard**

```swift
@Test func eachMovedControlLivesInExactlyOneSurface() throws {
    // Named bug this catches: a control left behind in the panel during the
    // move, so the user has two of them and they disagree — or a refactor that
    // silently moves one back.
    let panel = try sourceText(named: "PanelView.swift")
    let prefs = try sourceText(named: "PreferencesView.swift")

    for control in ["holdDisplayAwake", "batteryFloorPercent", "quietEverythingElse"] {
        #expect(prefs.contains(control), "Preferences lost \(control)")
        #expect(!panel.contains(control), "\(control) is still in the panel")
    }
    // The Serving picker STAYS. This half is what makes the guard discriminate
    // rather than just assert everything moved.
    #expect(panel.contains("$model.intent"))
    #expect(!prefs.contains("$model.intent"))
}

@Test func theFloorSliderIsBuiltOverThePolicyAndAddsNoSecondBoundingSite() throws {
    // Named bug this catches: a UI that clamps. Bounding lives at PowerInputs.init
    // and WatchdogDecision — a third site is a value corrected in two places with
    // different rules.
    let prefs = try sourceText(named: "PreferencesView.swift")
    #expect(prefs.contains("BatteryFloor.permitted"))
    #expect(prefs.contains("BatteryFloor.step"))
    #expect(!prefs.contains("BatteryFloor.bounded"))
}
```

- [ ] **Step 2: Run it and verify it fails**

```
swift test --filter PreferencesView
```
Expected: FAIL — the controls are still in `PanelView.swift`.

- [ ] **Step 3: Add the sections to `PreferencesView`**

Insert above the version line, inside the `VStack`:

```swift
                Text("Power").font(.headline)

                Picker("Display", selection: $model.holdDisplayAwake) {
                    Text("Let the screen sleep").tag(false)
                    Text("Keep the screen on").tag(true)
                }

                HStack {
                    Text("Battery floor")
                    Slider(
                        value: Binding(
                            get: { Double(model.batteryFloorPercent) },
                            set: { model.batteryFloorPercent = Int($0) }
                        ),
                        in: Double(BatteryFloor.permitted.lowerBound)
                            ... Double(BatteryFloor.permitted.upperBound),
                        step: Double(BatteryFloor.step)
                    )
                    // A slider without a readout is unreadable; the picker it
                    // replaces at least named its positions.
                    Text(ServingModel.floorLabel(for: model.batteryFloorPercent))
                        .monospacedDigit()
                }

                Text("Focus").font(.headline)

                Toggle(ServingModel.quietOthersLabel, isOn: $model.quietEverythingElse)
```

Copy the exact `Picker` cases and `Toggle` label from `PanelView.swift` before
deleting them — do not retype the user-facing strings from memory.

- [ ] **Step 4: Delete the three controls from `PanelView`**

Remove the Display picker, the Battery floor picker and the Quiet toggle, with
their comments. Keep the Serving picker and Quit.

- [ ] **Step 5: Verify the panel did not lose its floor**

PR #49 established that the bounded `ScrollView` must keep
`.fixedSize(horizontal: false, vertical: true)` or it absorbs the whole shortfall
and collapses to zero. Removing three controls changes the layout tree.

```bash
grep -n "fixedSize" Sources/CoffeeBarUI/AttentionListView.swift
grep -n "frame(width: 260)" Sources/CoffeeBarUI/PanelView.swift
```
Expected: both still present. The panel width does not change in this plan.

- [ ] **Step 6: Run everything**

```
swift test 2>&1 | tail -20
```
Expected: green, including `everyOfferedFloorSitsInsideThePermittedRange`.

- [ ] **Step 7: Mutation-check the placement guard**

Re-add `holdDisplayAwake` to `PanelView.swift` and re-run.
Expected: `eachMovedControlLivesInExactlyOneSurface` goes RED. Restore.

- [ ] **Step 8: Verify in the running app**

Rebuild the bundle, open the panel: three controls gone, Serving and the
attention list intact, `Preferences…` and Quit present. Open Preferences: drag
the slider and confirm the readout tracks it and stops at 10 and 50.

- [ ] **Step 9: Commit**

```bash
git add Sources/CoffeeBarUI/PreferencesView.swift Sources/CoffeeBarUI/PanelView.swift \
        Tests/CoffeeBarUITests/PreferencesView_test.swift
git commit -s -S -m "feat(ui): move the preferences into the window and slide the battery floor (#50, #31)"
```

---

## Task 6: The Agent tools section — copy and reveal

**Files:**
- Modify: `Sources/CoffeeBarUI/PreferencesView.swift`
- Test: `Tests/CoffeeBarUITests/PreferencesView_test.swift`

**Interfaces:**
- Consumes: `HookSnippet.json(for:)` (Task 3), `ServingModel.hookAdvisory`,
  `HookHealthReader.defaultURL(for:)`, `HookHealth.settingsPath(for:)`.

- [ ] **Step 1: Write the failing guard**

```swift
@Test func thePreferencesWindowNeverWritesASettingsFile() throws {
    // Named bug this catches: phase 2 arriving by accident. M2 ingest design §6
    // is "print, never write" — that file is shared territory and this
    // workspace records a six-occurrence last-writer-wins clobber in exactly
    // this config.
    let prefs = try sourceText(named: "PreferencesView.swift")
    for writer in ["write(to:", "FileManager.default.createFile",
                   "Data(...).write", "removeItem(at:"] {
        #expect(!prefs.contains(writer),
                "PreferencesView can write a file; §6 says print, never write")
    }
    // Discriminates: it MUST reach the pasteboard, or the guard would pass on a
    // view that does nothing at all.
    #expect(prefs.contains("NSPasteboard"))
}

@Test func theCopyActionOffersEveryToolTheCheckerCanAdviseAbout() throws {
    // Named bug this catches: a snippet action wired to a hardcoded two tools,
    // so a third stays uncopyable forever.
    for tool in AgentTool.allCases {
        #expect(HookSnippet.json(for: tool) != nil,
                "\(tool) has no snippet to copy")
    }
}
```

- [ ] **Step 2: Run it and verify it fails**

```
swift test --filter Preferences
```
Expected: FAIL — no `NSPasteboard` reference exists yet.

- [ ] **Step 3: Add the section**

Insert above the About/version line:

```swift
                Text("Agent tools").font(.headline)

                if let advisory = model.hookAdvisory {
                    Text(advisory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(AgentTool.allCases, id: \.self) { tool in
                    HStack {
                        Text("~/" + HookHealth.settingsPath(for: tool))
                            .font(.caption)
                            .monospaced()
                        Spacer()
                        Button("Copy hook snippet") {
                            guard let snippet = HookSnippet.json(for: tool) else { return }
                            let board = NSPasteboard.general
                            board.clearContents()
                            board.setString(snippet, forType: .string)
                        }
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [HookHealthReader.defaultURL(for: tool)]
                            )
                        }
                    }
                }
```

Add `import AppKit` at the top of the file.

- [ ] **Step 4: Run the tests**

```
swift test 2>&1 | tail -20
```
Expected: green.

- [ ] **Step 5: Mutation-check the write guard**

Add a real `try Data().write(to: url)` call to `PreferencesView.swift` and
re-run.
Expected: `thePreferencesWindowNeverWritesASettingsFile` goes RED. Restore, and
confirm with `git diff` that only that line was removed.

- [ ] **Step 6: Verify in the running app — the whole point of the feature**

Rebuild, open Preferences, click **Copy hook snippet** for Cursor, then paste it
into a scratch file and confirm it is valid JSON in Cursor's FLAT shape carrying
Cursor's own event names. Click **Reveal** and confirm Finder opens with the file
selected.

**Do not paste it into the real `~/.cursor/hooks.json` without asking the
maintainer** — that is persistent hook execution on a tool outside the original
grant.

- [ ] **Step 7: Commit**

```bash
git add Sources/CoffeeBarUI/PreferencesView.swift Tests/CoffeeBarUITests/PreferencesView_test.swift
git commit -s -S -m "feat(ui): offer copy and reveal per unwired agent tool (#37)"
```

---

## Task 7: Close the milestone

- [ ] **Step 1: Full clean verification from a cold scratch path**

```bash
S=/tmp/claude/prefs-final-$(date +%s)-$$
swift build --scratch-path "$S" --build-tests > /tmp/claude/final-build.log 2>&1; echo "build rc=$?"
grep -cE '^.*:[0-9]+:[0-9]+: error:|^error:' /tmp/claude/final-build.log
grep -c 'warning:' /tmp/claude/final-build.log
swift test --scratch-path "$S" > /tmp/claude/final-test.log 2>&1; echo "test rc=$?"
tail -5 /tmp/claude/final-test.log
node --test site/assets/bench.test.js > /tmp/claude/site-test.log 2>&1; echo "site rc=$?"
```

Gate on the recorded `rc`, never on a pipe's exit code. Expected: all rc=0,
0 errors, 0 warnings.

- [ ] **Step 2: Re-read HEAD before reporting**

```bash
git log --oneline -1
git update-index --refresh; git diff --quiet HEAD; echo "clean rc=$?"
```
A stat-dirty file shows `M` under `git status --short` without being modified.

- [ ] **Step 3: Open the PR as a draft**

The body carries problem, approach, testing done, breaking changes, and
`Closes #50`, `Closes #31`. It states, explicitly:

- the battery floor default moved from 20% to 15%
- `BatteryFloor.permitted` narrowed from `5...100` to `10...50`, so a stored
  floor above 50 is silently clamped on next launch
- what Task 2 measured about each tool's hook command form

`gh pr create --draft` and every other outward action needs the maintainer's
explicit per-action approval. Prepare the text, show it, post only what is
approved.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| §3 Surface — `Settings` scene, `SettingsLink` | 4 |
| §4 What lands where | 5 |
| §5 One page, four sections | 4, 5, 6 |
| §6 The version invariant | 4 |
| §7 #37 phase 1 — copy, never write | 3, 6 |
| §8 Battery floor slider and narrower policy | 1 |
| §9 What this spec does NOT do | enforced by Task 6's write guard |
| §10 Testing | guards in 1, 3, 4, 5, 6; mutation checks in 1, 3, 5, 6 |
| §11 The risk a green suite cannot see | 4 step 7, 5 step 8, 6 step 6 |
| §12 Acceptance | 7 |

**Gap found and closed:** the spec assumes a known hook command form; it is not
known. Task 2 exists to measure it and Task 3 is blocked on it.

**Type consistency:** `HookSnippet.json(for:) -> String?` is the only new public
symbol crossing tasks; Task 3 defines it and Task 6 consumes it under that exact
name. `BatteryFloor.step` is defined in Task 1 and consumed in Task 5.
`PreferencesView(model:)` is defined in Task 4 and extended in 5 and 6.

**Known unresolved:** the repo-root locator used by the source-scanning guards in
Tasks 4, 5 and 6 is written as `sourceText(named:)`. Copy it verbatim from
`noSourceFileThatKnowsTheSettingsPathCanWriteToIt`
(`Tests/CoffeeBarUITests/HookHealthReader_test.swift:384`); this plan
deliberately does not restate it, because a restated locator is one that can
disagree with the original.

**Defects caught in this plan before it shipped**, recorded because the class is
at 27 observed occurrences:

1. Task 1 said "add to `Tests/CoffeeBarCoreTests/BatteryFloor_test.swift`". That
   file does not exist — `BatteryFloor` is exercised only indirectly today. Now
   a CREATE with a licence header.
2. The site-test invocation was verified against `.github/workflows/ci.yml:111`
   rather than assumed. `node --test site/assets/` fails with "Cannot find
   module" and `node --test 'site/assets/*.test.js'` returns rc=0 when nothing
   matches — ci.yml documents both traps. The plan uses the one form that is
   neither broken nor vacuous.
