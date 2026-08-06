# Preferences window — design

**Date:** 2026-08-06
**Milestone:** v0.2.1
**Issues:** #50 (the window and what moves into it), #37 phase 1 (copy the hook
snippet), #31 (battery floor slider)
**Base:** `709715d`, measured against `origin/main` on the date above.

## 1. The problem

`PanelView.swift` is 396 lines and holds every surface the product has: the
Serving control, three preferences, the attention list, the hook advisory, the
version line and Quit. A user opens the menu-bar panel to learn what coffee-bar
is doing right now, and reads past a battery floor they set once and will never
change again.

The panel is `.frame(width: 260)`. Every line that is not live state competes for
that width with the one thing the panel exists to show.

## 2. Decisions

| # | Decision | Decided by |
|---|---|---|
| D1 | Preferences live in their OWN WINDOW, not a tab inside the panel | Carlos, 2026-08-06 |
| D2 | The window opens from a `Preferences…` item directly above `Quit coffee-bar` | Carlos, 2026-08-06 |
| D3 | The main panel keeps the name **Serving** — the product's own vocabulary | Carlos, 2026-08-06 |
| D4 | One scrolling page inside the window, not tabs | Carlos, 2026-08-06 |
| D5 | The running version appears on EVERY surface, panel and window alike | Carlos, 2026-08-06 |
| D6 | Tool selection (#51) and the first-run wizard (#52) are v0.2.2, NOT this spec | Carlos, 2026-08-06 |
| D7 | The battery floor becomes a 10–50 slider in 5% steps, default 15% (#31) | Carlos, 2026-08-06 |
| D8 | `BatteryFloor.permitted` narrows to `10...50` — the policy meets the control | Carlos, 2026-08-06 |

D1 replaces an earlier proposal for a `TabView` inside the panel. Tab chrome costs
roughly 28pt of vertical budget and centres itself in 260pt, which argued for
widening the panel to ~320pt. A separate window costs the panel nothing, so the
260pt frame and the `AttentionListView` height work from PR #49 are untouched.

## 3. Surface

A second `Scene`, sibling to the existing `MenuBarExtra` in
`Sources/CoffeeBarApp/main.swift`:

```swift
var body: some Scene {
    MenuBarExtra { PanelView(model: model) } label: { MenuBarLabel(isServing: model.isServing) }
        .menuBarExtraStyle(.window)

    Settings { PreferencesView(model: model) }
}
```

`PreferencesView` is new, in `CoffeeBarUI`, next to `PanelView`.

The panel footer gains `SettingsLink { Text("Preferences…") }` immediately above
`Quit coffee-bar`. `⌘,` comes free with the `Settings` scene.

**`SettingsLink` requires macOS 14 and this package targets it.**
`Package.swift` declares `platforms: [.macOS(.v14)]` and `scripts/build-app.sh`
writes `LSMinimumSystemVersion` `14.0`. That matters: without `SettingsLink` the
alternative is `NSApp.sendAction(Selector(("showSettingsWindow:")), …)`, a
string selector that has changed spelling between macOS releases. The idiomatic
route is available, so the hack is not considered.

## 4. What lands where

| Stays on the Serving panel | Moves to the Preferences window |
|---|---|
| Serving picker | Display hold |
| The attention list | Battery floor |
| `Preferences…` (new) | Quiet everything else |
| `Quit coffee-bar` | Hook health advisory |
| The version line | The hook snippet actions (§7) |

The version line is the one row that appears on BOTH surfaces, and it is not a
duplication mistake. §6 says why.

The panel keeps its 260pt frame. This spec changes no width.

## 5. One page, four sections

`PreferencesView` is a single scrolling page with four headed sections:

1. **Power** — display hold, battery floor (as a slider, §8)
2. **Focus** — quiet everything else
3. **Agent tools** — hook health per tool, and the §7 actions
4. **About** — the version line

Tabs inside the window would add a second navigation layer over four short
groups. They are not ruled out later — #51 and #52 both add content to section 3
— but they are not built now.

## 6. The version invariant

D5 makes this a product rule rather than a placement detail: **every surface
coffee-bar shows displays the running version.**

The seam already exists. `PanelView.versionLine(from:)` is a
`nonisolated static func` taking `Bundle.main.infoDictionary` and returning a
`String`; the panel renders its result rather than composing a sentence inline.
`Tests/CoffeeBarUITests/PanelVersionLine_test.swift` already pins it.

`PreferencesView` calls the SAME function. It does not compose its own sentence,
and it does not read `CFBundleShortVersionString` directly. Two spellings of the
version is the defect this rule exists to prevent — the user compares two numbers
that disagree and cannot tell which one is the app they are running. Issue #47
records what that confusion already cost once, when an installed bundle predated
the source by 16 commits and nothing in the product said so.

**The function does NOT move.** `PanelVersionLine_test.swift` calls
`PanelView.versionLine(from:)` by that exact type, four times. Relocating it to a
neutral home would edit a passing test in the same change that adds a feature,
which this project separates on purpose. `PreferencesView` calls
`PanelView.versionLine(from:)` as it stands. If the shared ownership starts to
read badly, it is a refactor of its own, in its own commit, with the test
following.

## 7. Issue #37 phase 1 — copy, never write

For each tool the Agent tools section reports as not wired, the window offers:

- **Copy hook snippet** — puts that tool's hook entry on the pasteboard
- **Reveal settings file** — opens the enclosing folder with the file selected

**The snippet is DERIVED, never a literal.** It is built from
`HookHealth.requiredEvents(for:)` and the shim name from `HookShim`, so it cannot
drift from what the health check looks for. A hardcoded snippet is a snippet that
tells the user to wire five events while the checker looks for six, and nothing
in the product notices.

**Shape differs per tool and is not a detail.** Claude Code and Codex take the
nested form; Cursor takes the flat form. `requiredEvents(for:)` already answers
per tool and is the only source consulted.

**Nothing is written.** "Print, never write" is
`docs/superpowers/specs/2026-07-28-coffee-bar-m2-ingest-design.md` §6 — the M2
ingest spec, not M1, whose §6 is Testing. It stands unchanged in this release. The pasteboard is the user's, the settings file is
not. Phase 2 — coffee-bar merging entries into a shared config — reopens §6 and
is explicitly out of scope here; #37 records why that decision deserves its own
scrutiny, having originally been made over a panel HARD-DISSENT that was partly
upheld.

## 8. Battery floor — a slider, and a narrower policy (#31)

The battery floor control is moving into the Preferences window anyway, so it is
rebuilt in the same pass rather than moved and then replaced.

| | Today | This release |
|---|---|---|
| Control | 5-position segmented picker | slider with a live numeric readout |
| Offered values | `choices = [10, 20, 30, 40, 50]` | derived, `10...50` by 5 |
| `BatteryFloor.permitted` | `5...100` | `10...50` |
| `BatteryFloor.default` | `20` | `15` |

**The policy narrows to meet the control, not the reverse.** #31 was filed on the
opposite premise — that `PowerBroker.decide` honours a 75% floor no user can ask
for, so the UI should widen. Carlos decided on 2026-08-06 to close that same gap
from the other side. A floor above 50% refuses holds through most of a normal
battery; a floor below 10% fires only once the machine is nearly dead.
`BatteryFloor.permitted`'s own comment already reasons this way about 0 and 100.

**The step and the default are ONE decision.**
`everyOfferedFloorSitsInsideThePermittedRange` holds `default` inside `choices`,
because "a default a user cannot get back to is a setting with no undo". 15 is
not in `[10, 20, 30, 40, 50]`. A default of 15 without a 5% step turns that guard
RED. Neither half ships alone.

`choices` is therefore DERIVED from `permitted` and a new `step`, not restated
beside them. The existing guard then cannot be satisfied by a hand-edited list
that disagrees with the range.

**Bounding stays where it is — in two places, not one.** `BatteryFloor.bounded`
is called from `PowerBroker.swift` (`PowerInputs.init`, commented "The ONE place
a user-supplied floor is bounded") and from `WatchdogDecision.swift`, the #13
launchd watchdog's own entry path. Narrowing `permitted` changes behaviour at
both. **The slider adds no third bounding site**: it is constructed over
`permitted`, so an out-of-range position is unreachable rather than corrected.

**A stored floor above 50 is silently clamped** to 50 on next launch, at both
entry paths. That is the existing documented behaviour for out-of-range values,
but it is a migration and the PR body states it rather than letting a user
discover it.

**Six sites pin the default and all must agree**, or
`theBatteryFloorStatedIsTheRealDefault` and the site suite go RED:
`BatteryFloor.swift`, `site/assets/bench.test.js`, `site/index.html`,
`README.md`, and two lines of `docs/QUICKSTART.md`.

## 9. What this spec does NOT do

Named so a reader cannot infer them from the direction of travel:

- It does not add a preference for which agent tools the user runs. That is #51,
  v0.2.2. Until it lands, `HookHealthReader.status(for:)` keeps its
  file-existence gate and its `.claudeCode` exemption exactly as they are.
- It does not add a first-run wizard. That is #52, v0.2.2.
- It does not add update checking. That is #29, v0.2.2.
- It does not write to any agent tool's settings file.

## 10. Testing

**The constraint that shapes every check here:** M1 design §5.4 rules out
asserting on rendered AppKit text, and the same limit covers rendered geometry.
`BrandPalette.swift` and `PanelView.swift` both cite it. So no check in this work
renders a view and reads a label out of it.

What that leaves, using idioms this repository already runs:

| Claim | How it is checked |
|---|---|
| The snippet matches what the checker wants | Generate for each `AgentTool`, compare against `HookHealth.requiredEvents(for:)`. A literal in the generator fails it. |
| Cursor gets the flat shape, the other two nested | Assert the generated structure per tool, not a golden string. |
| Every surface shows the version | Source-scanning guard: every top-level view calls `versionLine(from:)`. The repo already ships this idiom — `noLinkedTargetCanReachTheNetworkByAddress`, `noSourceFileThatKnowsTheSettingsPathCanWriteToIt`. |
| Each moved control appears exactly once | Source-scanning guard over the two view files: a control named in one is absent from the other. |
| Nothing writes a settings file | Extend the existing `noSourceFileThatKnowsTheSettingsPathCanWriteToIt` scan to `PreferencesView`. |

Every guard is mutation-checked before it is trusted: delete the behaviour it
guards and confirm it goes RED. A guard that stays green when its subject is
removed is theater and gets rewritten.

## 11. The risk a green suite cannot see

`SettingsLink` fires from inside a `MenuBarExtra(.window)` popover, in an app with
`LSUIElement` set to true — no Dock icon, `.accessory` activation. Two failures
are plausible and NEITHER is visible to any unit test:

1. The Preferences window opens BEHIND the frontmost application.
2. The menu-bar popover does not dismiss when the window opens.

**No PR in this milestone claims done on unit tests alone.** The window is opened
from the running app, from a cold launch, with another application frontmost, and
the result is observed. This project has already paid for that lesson: a demo
image built 21 hours before the feature commits returned 404 while every unit
test passed.

## 12. Acceptance

- [ ] `Preferences…` appears directly above `Quit coffee-bar` in the panel
- [ ] `⌘,` opens the same window
- [ ] The window opens in front of the frontmost app, verified by hand on a cold launch
- [ ] Display hold, battery floor and quiet-everything-else are reachable only from the window
- [ ] The panel is still `.frame(width: 260)`
- [ ] The 0-row and 1-row attention-list renders are unchanged from v0.2.0
- [ ] Both surfaces show the running version, from one function
- [ ] Copy and Reveal appear for each unwired tool, and the snippet is derived from `requiredEvents(for:)`
- [ ] No source file that knows a settings path can write to it
- [ ] The battery floor is a slider over `10...50` in 5% steps with a live readout
- [ ] `BatteryFloor.default` is 15 and `choices` is derived from `permitted` and `step`
- [ ] `everyOfferedFloorSitsInsideThePermittedRange` passes, and still goes RED
      when the default is moved outside the offered set
- [ ] All six sites pinning the default agree; `theBatteryFloorStatedIsTheRealDefault` passes
- [ ] No bounding call is added at the UI layer
- [ ] The PR body states that a stored floor above 50 is silently clamped
- [ ] Clean build from a fresh run-scoped scratch path: 0 errors, 0 warnings
