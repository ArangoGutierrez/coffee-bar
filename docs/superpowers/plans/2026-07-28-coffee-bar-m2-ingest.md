# M2 Claude Code Ingest Implementation Plan

> ## PE CORRECTIONS — read before implementing any task
>
> A principal-engineer review compiled this plan's framer and listener into a
> spike and attacked them. Every item below is a REPRODUCED failure, not a
> reading. Where this block and the task text disagree, THIS BLOCK WINS.
>
> **B1 — `Content-Length: -1` crashes the app.** `Int(...)` accepts a negative,
> the `available >= length` guard passes, `bodyEnd` lands before `bodyStart`,
> and the range subscript traps with "Range requires lowerBound <= upperBound".
> Any same-user process kills the menu-bar app with one 60-byte POST, which
> releases the assertion and sleeps the machine under a running agent. The 8
> framer tests miss it: `headersWithNoContentLengthAreRejected` covers a MISSING
> header, not a negative value. Require `length >= 0 && length <= maximumBytes`,
> and test the negative case.
>
> **B2 — two app instances silently kill ingest.** `start()` and `stop()` both
> unlink the socket node unconditionally. Measured: instance B steals A's path,
> A goes deaf forever, then A's `stop()` deletes B's LIVE node and ingest is
> dead while B looks healthy. Task 7's health check reads settings.json only, so
> the panel still says "wired". `stop()` must NOT unlink; `start()` must
> connect-probe before removing a stale node.
>
> **B3 — do not reintroduce `isolated deinit`.** It is experimental before Swift
> 6.3. Commit a33b35f removed it after it turned the repo's first CI run red at
> 6.1.2. The plan's own citation of `ServingModel.swift:66` points at a line
> a33b35f deleted. `ci.yml` pins macos-15 with no toolchain selection.
>
> **B4 — D1 (`UserIntent.auto`) needs two fixes to work at all.**
> `HoldController.evaluate` sets `intent = .stop` on ANY suppression, so one
> low-battery moment permanently disables ingest for the life of the process,
> and `ServingModel.reason(_:stillTrueOf:)` then hides the explanation once the
> reading recovers. Latch only when `intent == .serve`; `PowerBroker` re-checks
> the floor on every call anyway. Second: `PanelView` binds `$model.serving`,
> whose getter is `isServing` — the actual hold state — so under `.auto` the
> switch moves by itself and one click installs a `.stop` veto the user never
> chose. **`.auto` becomes unreachable through the UI after one click.** Needs a
> 3-way Picker bound to `intent`, not a `Bool` toggle.
>
> **I1 — sequencing.** Task 4's `aStaleWorkingSessionStopsHoldingTheAssertion`
> passes `userIntent: .stop` and asserts `hold == true`; it goes red the moment
> D1 lands. There are 12 `.stop` occurrences in `PowerBroker_test.swift`.
> **Land `UserIntent.auto` BEFORE Task 4, not after Task 5.**
>
> **I2 — `SessionHub.apply` is not pure.** `URL(fileURLWithPath:)` stats the
> disk: an existing directory yields a trailing slash, a missing one does not.
> Use `URL(fileURLWithPath:isDirectory:)`.
>
> **I3 — design §11 has zero plan coverage.** The spec-coverage table jumps §10
> to §12. Decide it or record the deferral.
>
> **I4 — a `.working` session appears nowhere in the UI.** The attention list
> shows only the two blocked states, so the user cannot see what is holding the
> machine awake, from a product whose pitch is exactly that.
>
> **B5 — landing `CoffeeBarIngest` breaks the app-layer guard unless TWO lists
> move together.** Plan Steps 5 and 6 contradict each other: Step 6 adds the new
> Ingest file to `expectedAppLayerEntries` (AppLayerBoundary_test.swift:81) but
> leaves `appLayerTargets` (line 69) at `[CoffeeBarApp, CoffeeBarUI]`. The guard
> derives `found` from `appLayerTargets`, so the new entry can never appear in it
> and `theAppLayerCompilesExactlyTheFilesThisGuardScans` goes RED on a correct
> change. Whoever lands the ingest target updates BOTH lists in the same commit.
>
> **B6 — `HookHealthReader` lives in `Sources/CoffeeBarUI/`, not
> `CoffeeBarIngest`.** Task 7 landed before the ingest target existed and could
> not create it. The pure parse is in Core as planned. Moving the reader is one
> file move once the target lands, and it is subject to B5.
>
> **B7 — Task 6 will conflict with `ServingModel_test.swift`.** Task 7 changed 17
> `ServingModel` constructions there so no test reads the real
> `~/.claude/settings.json`. Rebase before starting, do not merge blind.
>
> **Confirmed NOT defects, tested:** concurrent connections work (3 stalled
> half-open plus a real POST, delivered); the chmod window did not reproduce
> (0600 in 12/12 runs); staleness IS on a timer, in `refresh()` not `ingest()`.
> Network.framework cannot verify a peer, and peer checks would buy nothing:
> the authorized client is `/usr/bin/curl`, which any process can exec. **§4.1's
> trust floor is right for v0.1.**
>
> **Unverified risk for Task 9:** `LSUIElement` apps are App Nap candidates, and
> a throttled 30s `Timer` makes the stale timeout late. Measure on hardware.



> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bind the power assertion to what a Claude Code agent is actually doing, so the menu-bar glyph follows real session state and the user never touches the toggle.

**Architecture:** `SessionHub` is a pure function of `(sessions, event, now)` in Foundation-only `CoffeeBarCore`, so every transition tests with no socket and no Mac. A new `CoffeeBarIngest` target owns the unix-domain-socket listener and the HTTP framing. `ServingModel` feeds the hub's output into the `sessions` argument `HoldController.evaluate` already accepts.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v6)`), SwiftPM, `Network.framework`, `swift-testing`. Zero third-party dependencies, and M2 keeps it that way.

**Base:** branch `feat/m0-capability-probe` at `fdbb958`. Verified in this session:

```
$ swift build
Build complete!
$ swift test
✔ Test run with 209 tests in 3 suites passed after 3.285 seconds.
```

---

## Global Constraints

- **Test files are named `<Subject>_test.swift`.** Not `…Tests.swift`. `tdd-guard.sh` requires it.
- **`tdd-guard.sh` cannot see an untracked test file.** `git add` the test after the RED run and before the implementation. Never set `SKIP_TDD_GUARD`.
- **The test framework is `swift-testing`**, not XCTest: `import Testing`, `@Test func name()`, `#expect(...)`, `try #require(...)`.
- **`CoffeeBarCore` imports Foundation and nothing else.** No AppKit, SwiftUI, IOKit, Network.
- **Nothing may hold `PreventUserIdleDisplaySleep`.** Design §12 keeps this invariant through M2.
- **Nothing may open `transcript_path`.** Design §7. Task 2 makes this structural.
- Every target uses `.swiftLanguageMode(.v6)`. Platform floor is `.macOS(.v14)`.
- Every file starts with the two-line header used across the repo:
  `// Copyright 2026 Carlos Eduardo Arango Gutierrez` and
  `// SPDX-License-Identifier: Apache-2.0`.
- Commits are signed: `git commit -s -S`. Commit with explicit pathspecs. **The `-m`/`-F` comes BEFORE the `--`.**
- **Run all `swift` commands with the sandbox DISABLED.**
- Run `shellcheck` on every script this plan creates.
- Never write a backup inside the package tree. The app-layer guard flags stray files.

### Verified traps

**`swift test --filter` exits 0 when it matches nothing.** Measured in this session:

```
$ swift test --filter ThisTestDoesNotExistAnywhere
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
```

Any claim that a filtered test ran must quote a non-zero count.

**Every mutant must be proved APPLIED and proved to COMPILE.** Compare `git hash-object` before and after the substitution. A silent no-op substitution makes the check vacuous, and a mutant that fails to compile makes a red suite prove only that the compiler works. The pattern, run against `PowerBroker.swift` in this session:

```
$ git hash-object Sources/CoffeeBarCore/PowerBroker.swift
f65fc173f9b2c8bf70d24cc3565c62f21f843db8      # before
13d1bd902b112146a5525912188bc372d5d5dc3e      # after — mutant proved applied
$ git checkout -- Sources/CoffeeBarCore/PowerBroker.swift
f65fc173f9b2c8bf70d24cc3565c62f21f843db8      # revert proved by content
```

**A loose file inside a target's directory makes SwiftPM warn.** Measured, and the check discriminates:

```
$ echo '{}' > Tests/CoffeeBarCoreTests/loose-probe.json && touch Package.swift && swift build
warning: 'coffee-bar': found 1 file(s) which are unhandled; explicitly declare them as resources or exclude from the target

$ rm Tests/CoffeeBarCoreTests/loose-probe.json && mkdir -p Tests/Fixtures && touch Package.swift && swift build
(no warning)
```

**Fixtures therefore live at `Tests/Fixtures/`, outside every target directory**, and are read through `#filePath`, the idiom `AppLayerBoundary_test.swift:34` already uses. Do not add `resources:` to a test target.

---

## Decisions this plan does NOT make

Design §10 lists four open decisions. Three are carried here as provisional implementations, marked in the code, each with its own tests. **One blocks Task 6 and needs the user before that task starts.**

### D1 — Does an explicit `.stop` outrank an active session? BLOCKING.

`PowerBroker.decide` ORs user intent with the session predicate
(`Sources/CoffeeBarCore/PowerBroker.swift:70`). The six multi-session tests all
pass `intent: .stop`, so the OR has no multi-session coverage.

**Measured in this session, not estimated.** Replacing the OR with
`inputs.userIntent == .serve && (inputs.sessions.isEmpty || sessionsWantAwake)`
turns 8 tests red with 13 issues:

```
anActiveSessionAnywhereInTheListHolds
anActiveSessionFirstInTheListAlsoHolds
aWorkingSessionHoldsBesideABlockedOneWithTheKnobOff
blockedStatesHoldOnlyWhenTheKnobIsSet
evaluateForwardsTheSessionsAndTheKnobToTheBroker
theOrderOfTheSessionsDoesNotChangeTheOutcome
twoBlockedSessionsHoldOnlyOnceTheKnobIsSet
wakePredicateHonoursOnlyStartingAndWorking
```

The mutant was proved applied and then reverted by content, and the suite
returned to `209 tests … passed`.

Three options:

| Option | Shape | Cost |
|---|---|---|
| **a. Keep the OR** | An active session holds even after the user toggles off. | The toggle is not an off switch. A user who turns Serving off while an agent works sees the machine stay awake and has no way to stop it. |
| **b. `.stop` is a veto** | `wantsHold = intent == .serve`. | With a two-case enum this deletes the session predicate entirely. Ingest then changes nothing. |
| **c. Add `UserIntent.auto`** | `.auto` follows the sessions, `.serve` forces on, `.stop` forces off. `.auto` becomes the default. | `UserIntent` is `public` and `Codable`, so this is an API change. The toggle becomes three-state or gains a separate override. The 8 tests above keep their meaning under `.auto`. |

**Option (c) is the recommendation.** It is the only one that gives the user a
real off switch and still lets ingest drive the machine. It is also the largest
change, and it changes a shipped public type, so it is the user's call.

**Task 6 cannot start until D1 is answered.** Tasks 1 to 5 are unaffected: they
produce sessions, they do not decide what sessions mean.

### D2 — The stale timeout values. Provisional.

Task 4 ships `StalePolicy.standard` with a 300 s working timeout and a 14400 s
blocked timeout. The split answers design §10.2: an `.awaitingInput` session may
idle for hours by design, a `.working` one going quiet for five minutes is
suspicious. **Both numbers are guesses.** Every staleness test injects its own
policy, so changing the numbers touches exactly one test — the one that pins the
declared defaults, which exists for that purpose.

### D3 — What the attention list shows, and its ordering. Provisional.

Task 8 ships: the two attention states only, oldest wait first, `id` as the
tie-break. The tie-break is not cosmetic — it makes the order total, so no test
can pass by accident of insertion order.

### D4 — Does a session-end hook exist? MEASURED, and Task 1 confirms it.

Design §10.4 says measure. The installed Claude Code carries `SessionEnd`:

```
$ B=~/.local/share/claude/versions/2.1.220
$ strings -a "$B" | grep -F 'hook_event_name:"SessionEnd"' | tr '{};' '\n\n\n' | grep SessionEnd
...Kf(void 0),hook_event_name:"SessionEnd",reason:e

$ strings -a "$B" | grep -F 'Not a recognized hook event'
Not a recognized hook event. Common events: PreToolUse, PostToolUse, UserPromptSubmit, SessionStart, SessionEnd, Stop. Check spelling and capitalization.

$ strings -a "$B" | grep -E 'executeSessionEndHooks|getSessionEndHookTimeoutMs'
getSessionEndHookTimeoutMs
executeSessionEndHooks
```

The binary also carries the reason values `"clear"`, `"logout"`,
`"prompt_input_exit"` and `"other"`.

**A string in a binary is not a fired hook.** This is evidence that the event
exists, not proof that it reaches us. Task 1 registers `SessionEnd` in the
capture hook and settles it. **Task 3 writes the `SessionEnd` transition only if
Task 1 produces a `SessionEnd` fixture.** Design §3.2 forbids inventing it.

---

### Task 1: Capture the real hook payloads — **USER-GATED**

**This task edits `~/.claude/settings.json` and needs the user's explicit
approval before it starts.** Design §9 requires it, and the file is shared
territory: this workspace records a critical, six-occurrence pattern of
last-writer-wins clobber in exactly this file.

Every later task depends on the fixtures this task produces. **No transition
test may be written against an invented payload.**

**Files:**
- Create: `scripts/capture-hooks.sh`
- Create: `Tests/Fixtures/claude-hooks/*.json` (one file per captured payload)
- Create: `Tests/Fixtures/claude-hooks/README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: the fixture corpus every later task reads.

- [ ] **Step 1: Write the capture script**

Create `scripts/capture-hooks.sh`:

```bash
#!/bin/bash
# Copyright 2026 Carlos Eduardo Arango Gutierrez
# SPDX-License-Identifier: Apache-2.0
#
# Appends one Claude Code hook payload, verbatim, to its own file.
#
# One file per invocation, never one shared append target: hooks for two
# sessions can fire at the same moment, and a payload is far larger than
# PIPE_BUF, so concurrent appends to one file interleave and corrupt both.
#
# This script only reads stdin and writes into its own directory. It never
# touches ~/.claude/settings.json — the user installs and removes the hook
# entries by hand, per design §6.

set -euo pipefail

DIR="${COFFEE_BAR_CAPTURE_DIR:-$HOME/coffee-bar-capture}"
mkdir -p "$DIR"

# The name carries nothing but uniqueness. The payload names its own event.
OUT="$DIR/$(date +%s)-$$-${RANDOM}.json"
cat > "$OUT"

# Exit 0 always. A capture hook that fails a turn is a capture hook the user
# rips out before it has recorded anything.
exit 0
```

Run: `shellcheck scripts/capture-hooks.sh`
Expected: no findings.

- [ ] **Step 2: Print the snippet for the user to paste**

Run this and give the output to the user. **Do not write the file.**

```bash
cat <<EOF
Add these entries under "hooks" in ~/.claude/settings.json, run the session in
step 3, then REMOVE them again.

"SessionStart":      [{"hooks":[{"type":"command","command":"$PWD/scripts/capture-hooks.sh"}]}],
"PreToolUse":        [{"hooks":[{"type":"command","command":"$PWD/scripts/capture-hooks.sh"}]}],
"PostToolUse":       [{"hooks":[{"type":"command","command":"$PWD/scripts/capture-hooks.sh"}]}],
"PermissionDenied":  [{"hooks":[{"type":"command","command":"$PWD/scripts/capture-hooks.sh"}]}],
"Stop":              [{"hooks":[{"type":"command","command":"$PWD/scripts/capture-hooks.sh"}]}],
"PreCompact":        [{"hooks":[{"type":"command","command":"$PWD/scripts/capture-hooks.sh"}]}],
"SessionEnd":        [{"hooks":[{"type":"command","command":"$PWD/scripts/capture-hooks.sh"}]}]
EOF
```

`SessionEnd` is in the list on purpose. It settles D4.

**Warning: record what the file looked like before the edit.** The user reverts
by hand in step 5, and a diff is the only way to prove the revert was clean.

- [ ] **Step 3: Drive a real Claude Code session**

The user runs one session through all five events design §9 lists:

1. start a session (`SessionStart`, `source: "startup"`);
2. let the agent run a tool (`PreToolUse`, `PostToolUse`);
3. deny a permission prompt (`PermissionDenied`);
4. let the turn end (`Stop`);
5. resume the session (`SessionStart`, `source: "resume"`);
6. quit (`SessionEnd`, if it fires).

- [ ] **Step 4: Check the corpus covers every event**

```bash
grep -ho '"hook_event_name":"[A-Za-z]*"' "$HOME"/coffee-bar-capture/*.json | sort | uniq -c
```

Expected: a non-zero count for `SessionStart`, `PreToolUse`, `PostToolUse`,
`PermissionDenied` and `Stop`. **Record whether `SessionEnd` appears.** That
answer is D4, and Task 3 reads it.

If an event is missing, go back to step 3. Do not proceed with a gap and do not
write a payload by hand.

- [ ] **Step 5: Revert `~/.claude/settings.json`**

The user removes the entries. Prove the revert by CONTENT, against the record
from step 2 — never by exit code.

- [ ] **Step 6: Redact and install the fixtures**

**The raw payloads carry the user's real home directory, real repository paths,
and possibly real prompt text.** They are about to be committed to a public
repository. Redact before committing:

- rewrite every path under the real home directory to `/Users/example/…`;
- replace the `message` text with a short neutral sentence;
- **keep `transcript_path` present**, pointed at a redacted path. Task 2 needs a
  fixture that carries the field, as the positive control that proves the
  privacy guard's needle is real.

Keep the structure, the key order and the key names byte-for-byte. Rename each
file to `<event>-<n>.json`, for example `session-start-startup.json`.

Show the user the redacted corpus and get approval before step 7.

Create `Tests/Fixtures/claude-hooks/README.md` recording: the Claude Code
version (`2.1.220`), the capture date, which events fired, which did not, and
that the payloads are redacted.

- [ ] **Step 7: Confirm SwiftPM stays quiet, then commit**

```bash
touch Package.swift && swift build 2>&1 | grep -i warning
```
Expected: no output. Fixtures sit outside every target directory.

```bash
git add scripts/capture-hooks.sh Tests/Fixtures/claude-hooks
git commit -s -S -m "test(fixtures): capture real Claude Code hook payloads"
```

**Acceptance:** `Tests/Fixtures/claude-hooks/` holds at least one redacted
payload per event that fired. `README.md` records what fired and what did not.
`~/.claude/settings.json` is back to its pre-capture content, proved by content.
`swift build` emits no warning.

---

### Task 2: HookEvent — the decode boundary and the privacy guard

**Files:**
- Create: `Sources/CoffeeBarCore/HookEvent.swift`
- Test: `Tests/CoffeeBarCoreTests/HookEvent_test.swift`
- Test: `Tests/CoffeeBarCoreTests/PrivacyBoundary_test.swift`

**Interfaces:**
- Consumes: the Task 1 fixtures.
- Produces: `HookEvent`, `HookEventKind`.

Depends on Task 1.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CoffeeBarCoreTests/HookEvent_test.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

/// The fixture directory, resolved from `#filePath`.
///
/// Never from the working directory: under `swift test` the working directory
/// is not the package root, and a fixture test that silently reads nothing is
/// worse than no test at all.
private var fixtures: URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarCoreTests/HookEvent_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarCoreTests
        .deletingLastPathComponent()    // …/Tests
        .appending(path: "Fixtures/claude-hooks")
}

private func fixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: fixtures.appending(path: name))
}

private func decodeAll() throws -> [HookEvent] {
    let names = try FileManager.default
        .contentsOfDirectory(atPath: fixtures.path)
        .filter { $0.hasSuffix(".json") }
        .sorted()
    return try names.map {
        try JSONDecoder().decode(HookEvent.self, from: fixtureData($0))
    }
}

@Test func everyCapturedPayloadDecodes() throws {
    // Named bug this catches: a CodingKeys map that does not match what Claude
    // Code actually sends. The whole point of design §9 is that this test reads
    // recorded bytes, so a renamed or missing key fails here rather than in the
    // field with an ingest that silently drops every event.
    let events = try decodeAll()
    #expect(events.count >= 5,
            "decoded \(events.count) fixtures; the corpus is missing events")
    for event in events {
        #expect(!event.sessionID.isEmpty)
        #expect(!event.hookEventName.isEmpty)
    }
}

@Test func theCorpusCoversEveryEventTheHubActsOn() throws {
    // A corpus that lost an event would let Task 3 write a transition against
    // nothing. `SessionEnd` and `PreCompact` are deliberately NOT required —
    // D4 records whether SessionEnd fired at all.
    let names = Set(try decodeAll().map(\.hookEventName))
    for required in ["SessionStart", "PreToolUse", "PostToolUse",
                     "PermissionDenied", "Stop"] {
        #expect(names.contains(required), "no fixture for \(required)")
    }
}

@Test func sessionStartCarriesItsSource() throws {
    // §3: SessionStart is the only event carrying `source`, and `resume` is how
    // a returning session is told from a fresh one.
    let event = try JSONDecoder().decode(
        HookEvent.self, from: fixtureData("session-start-startup.json"))
    #expect(event.kind == .sessionStart)
    #expect(event.source == "startup")
}

@Test func preToolUseCarriesItsToolName() throws {
    let event = try JSONDecoder().decode(
        HookEvent.self, from: fixtureData("pre-tool-use.json"))
    #expect(event.kind == .preToolUse)
    #expect(event.toolName != nil)
}

@Test func anUnknownEventDecodesWithNoKind() throws {
    // Claude Code adds hook events over time. An unknown one must decode and
    // classify as nil, so the hub can ignore it. Named bug this catches: a
    // `HookEventKind` decoded directly, which makes the whole payload fail to
    // decode and takes the KNOWN events on that connection down with it.
    let raw = Data("""
        {"hook_event_name":"SomeFutureEvent","session_id":"s1"}
        """.utf8)
    let event = try JSONDecoder().decode(HookEvent.self, from: raw)
    #expect(event.hookEventName == "SomeFutureEvent")
    #expect(event.kind == nil)
}

@Test func aPayloadWithNoSessionIDFailsToDecode() throws {
    // `session_id` is the key everything is keyed by. A payload without one is
    // not a session event, and accepting it with an empty id would merge every
    // such payload into one phantom session that holds the machine awake.
    let raw = Data(#"{"hook_event_name":"Stop"}"#.utf8)
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(HookEvent.self, from: raw)
    }
}
```

Create `Tests/CoffeeBarCoreTests/PrivacyBoundary_test.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

// Design §7 forbids reading transcript contents. `HookEvent` therefore declares
// NO `transcript_path` property: a field that does not exist cannot be opened,
// and `Codable` drops unknown keys, so the path is discarded at the decode
// boundary and never reaches a variable.
//
// The source scan below is the SECOND line of defence, not the first. It cannot
// prove that no route to the transcript exists — only that no file in `Sources`
// names the key. The structural absence of the property is what actually holds.

private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarCoreTests/PrivacyBoundary_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarCoreTests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // the package root
}

private let forbidden = ["transcript_path", "transcriptPath"]

private func everySwiftSourceFile() throws -> [URL] {
    let sources = packageRoot.appending(path: "Sources")
    guard let walk = FileManager.default.enumerator(
        at: sources, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return [] }

    var found: [URL] = []
    for case let entry as URL in walk where entry.pathExtension == "swift" {
        found.append(entry)
    }
    return found.sorted { $0.path < $1.path }
}

@Test func theFixturesDoCarryATranscriptPath() throws {
    // The POSITIVE CONTROL, and the reason the scan below is not theater.
    //
    // Every real payload carries `transcript_path`. If the redaction in Task 1
    // had stripped the key, the scan below would pass against a needle that
    // exists nowhere, and would keep passing after somebody added the property.
    // This test proves the needle is real before the scan claims its absence.
    let dir = packageRoot.appending(path: "Tests/Fixtures/claude-hooks")
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.hasSuffix(".json") }
    #expect(!names.isEmpty, "no fixtures found at \(dir.path)")

    let carrying = try names.filter {
        try String(contentsOf: dir.appending(path: $0), encoding: .utf8)
            .contains("transcript_path")
    }
    #expect(!carrying.isEmpty,
            "no fixture carries transcript_path; the guard below tests nothing")
}

@Test func hookEventHasNoTranscriptPathProperty() throws {
    // The structural guard. A fixture that carries the key decodes, and the
    // decoded value carries no trace of it — proved by re-encoding.
    let dir = packageRoot.appending(path: "Tests/Fixtures/claude-hooks")
    let name = try #require(
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }.sorted().first)
    let raw = try Data(contentsOf: dir.appending(path: name))
    #expect(String(data: raw, encoding: .utf8)?.contains("transcript_path") == true,
            "picked a fixture with no transcript_path; the check would be vacuous")

    let event = try JSONDecoder().decode(HookEvent.self, from: raw)
    let round = try JSONEncoder().encode(event)
    let text = try #require(String(data: round, encoding: .utf8))
    for needle in forbidden {
        #expect(!text.contains(needle),
                "HookEvent round-tripped \(needle); design §7 forbids carrying it")
    }
}

@Test func noSourceFileNamesTheTranscriptPath() throws {
    let files = try everySwiftSourceFile()
    // Without this, a broken walk passes by reading nothing — the exact defect
    // `AppLayerBoundary_test.swift` was rewritten to close.
    #expect(files.count >= 20,
            "the privacy scan reached \(files.count) files at \(packageRoot.path)")

    for file in files {
        let source = try String(contentsOf: file, encoding: .utf8)
        for needle in forbidden {
            #expect(!source.contains(needle),
                    "\(file.lastPathComponent) names \(needle); design §7 forbids opening it")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HookEvent`
Expected: FAIL — compilation error, `cannot find 'HookEvent' in scope`.

`git add` both test files now, before writing the implementation.

- [ ] **Step 3: Write the implementation**

Create `Sources/CoffeeBarCore/HookEvent.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The Claude Code hook events M2 acts on. Design §3.
///
/// Raw values are the wire names, pinned to literals rather than derived from
/// the case names, so renaming a case cannot silently stop matching what
/// Claude Code sends.
public enum HookEventKind: String, Sendable, CaseIterable {
    case sessionStart = "SessionStart"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case permissionDenied = "PermissionDenied"
    case stop = "Stop"
    case preCompact = "PreCompact"
    case sessionEnd = "SessionEnd"
}

/// One Claude Code hook payload, reduced to the fields M2 acts on.
///
/// **`transcript_path` is absent on purpose.** Every real payload carries it,
/// and design §7 forbids opening it. A property that does not exist cannot be
/// read, and `Decodable` drops unknown keys, so the path is discarded here and
/// never reaches a variable. `Tests/CoffeeBarCoreTests/PrivacyBoundary_test.swift`
/// holds that line, with a fixture carrying the key as its positive control.
///
/// `hookEventName` is a `String`, not a `HookEventKind`. Decoding straight into
/// the enum would make an unrecognised event fail the whole payload, and Claude
/// Code adds events over time. An unknown name decodes and classifies as `nil`.
public struct HookEvent: Codable, Equatable, Sendable {
    public let hookEventName: String
    public let sessionID: String
    public let cwd: String?
    public let source: String?
    public let toolName: String?
    public let message: String?
    public let reason: String?

    private enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionID = "session_id"
        case cwd
        case source
        case toolName = "tool_name"
        case message
        case reason
    }

    /// `nil` for an event this version does not act on.
    public var kind: HookEventKind? { HookEventKind(rawValue: hookEventName) }

    public init(hookEventName: String, sessionID: String, cwd: String? = nil,
                source: String? = nil, toolName: String? = nil,
                message: String? = nil, reason: String? = nil) {
        self.hookEventName = hookEventName
        self.sessionID = sessionID
        self.cwd = cwd
        self.source = source
        self.toolName = toolName
        self.message = message
        self.reason = reason
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter HookEvent`
Expected: PASS, 6 tests. Confirm the count is non-zero.

Run: `swift test --filter noSourceFileNamesTheTranscriptPath`
Expected: PASS, 1 test.

- [ ] **Step 5: Mutation-check the two load-bearing guards**

One at a time, reverting between them. Prove each mutant applied with
`git hash-object`, and prove it compiles before reading the result.

| # | Mutant | Test that must go RED |
|---|---|---|
| 1 | Add `public let transcriptPath: String?` to `HookEvent` with key `"transcript_path"` | `noSourceFileNamesTheTranscriptPath` and `hookEventHasNoTranscriptPathProperty` |
| 2 | Change `case sessionID = "session_id"` to `= "sessionId"` | `everyCapturedPayloadDecodes` |
| 3 | Change `kind` to `HookEventKind(rawValue: hookEventName)!` | `anUnknownEventDecodesWithNoKind` (traps rather than fails; a trap is a pass for this mutant) |
| 4 | Strip `transcript_path` from every fixture | `theFixturesDoCarryATranscriptPath` |

Mutant 4 is the one that proves the privacy guard discriminates. Restore the
fixtures with `git checkout -- Tests/Fixtures`.

- [ ] **Step 6: Commit**

```bash
git add Sources/CoffeeBarCore/HookEvent.swift Tests/CoffeeBarCoreTests/HookEvent_test.swift Tests/CoffeeBarCoreTests/PrivacyBoundary_test.swift
git commit -s -S -m "feat(core): decode Claude Code hook payloads without the transcript path"
```

**Acceptance:** every captured fixture decodes. An unknown event decodes with
`kind == nil`. A payload with no `session_id` throws. No file under `Sources`
names `transcript_path`, and the fixture corpus proves that needle is real.

---

### Task 3: SessionHub — the pure transition function

**Files:**
- Create: `Sources/CoffeeBarCore/SessionHub.swift`
- Test: `Tests/CoffeeBarCoreTests/SessionHub_test.swift`

**Interfaces:**
- Consumes: `HookEvent`, `HookEventKind` (Task 2); `AgentSession`, `SessionState`, `AgentTool` (M1).
- Produces: `SessionHub.apply(_:to:now:)`.

Depends on Tasks 1 and 2. **No transition below is written from prose. Every one
is driven by a fixture.**

`SessionHub` is a caseless `enum` with static functions, the same shape
`PowerBroker` uses. It has no I/O, no clock and no stored state, so
`(sessions, event, now)` in gives `sessions` out, every time.

- [ ] **Step 1: Write the failing test**

Create `Tests/CoffeeBarCoreTests/SessionHub_test.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private var fixtures: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/claude-hooks")
}

/// Loads a recorded payload. Design §9 forbids inventing one.
private func event(_ name: String) throws -> HookEvent {
    try JSONDecoder().decode(
        HookEvent.self, from: Data(contentsOf: fixtures.appending(path: name)))
}

/// The state a single-session list ends in after one recorded event.
private func stateAfter(_ fixture: String,
                        from sessions: [AgentSession] = [],
                        at now: Date = t0) throws -> SessionState? {
    let out = SessionHub.apply(try event(fixture), to: sessions, now: now)
    return out.first?.state
}

private func session(_ state: SessionState,
                     id: String = "s1",
                     lastEventAt: Date = t0) -> AgentSession {
    AgentSession(tool: .claudeCode, sessionID: id, cwd: nil, repoName: nil,
                 pid: nil, state: state, stateEnteredAt: t0,
                 lastEventAt: lastEventAt, lastMessage: nil,
                 attentionSince: nil, turnCount: 0)
}

// MARK: - The mapping in design §3.1, driven by recorded payloads

@Test func sessionStartCreatesAStartingSession() throws {
    #expect(try stateAfter("session-start-startup.json") == .starting)
}

@Test func preToolUseMovesToWorking() throws {
    #expect(try stateAfter("pre-tool-use.json",
                           from: [session(.starting)]) == .working)
}

@Test func postToolUseMovesToWorking() throws {
    #expect(try stateAfter("post-tool-use.json",
                           from: [session(.awaitingInput)]) == .working)
}

@Test func permissionDeniedMovesToAwaitingPermission() throws {
    #expect(try stateAfter("permission-denied.json",
                           from: [session(.working)]) == .awaitingPermission)
}

@Test func stopMovesToAwaitingInput() throws {
    // The behaviour the product exists for. The agent has finished its turn and
    // the human is the bottleneck, so with `holdAwakeWhileBlocked` off the
    // assertion drops and the machine sleeps while it waits.
    #expect(try stateAfter("stop.json", from: [session(.working)]) == .awaitingInput)
}

@Test func preCompactChangesNothing() throws {
    // §3.1 calls PreCompact housekeeping. It does not even refresh lastEventAt:
    // a compaction that outlives the stale timeout releases the assertion, and
    // releasing is the SAFE direction to fail in.
    let before = [session(.working)]
    let after = SessionHub.apply(try event("pre-compact.json"), to: before, now: t0.addingTimeInterval(60))
    #expect(after == before)
}

@Test func anUnknownEventChangesNothing() {
    // Named bug this catches: a hub that creates a session for any payload. A
    // future Claude Code event would then mint a phantom `.starting` session
    // that holds the machine awake until the stale timeout retires it.
    let before = [session(.working)]
    let unknown = HookEvent(hookEventName: "SomeFutureEvent", sessionID: "s2")
    #expect(SessionHub.apply(unknown, to: before, now: t0) == before)
}

// MARK: - Identity and ordering

@Test func aSecondSessionIsAppendedRatherThanReplacing() throws {
    // Named bug this catches: a hub keyed by nothing, which merges two agents
    // into one row. The user then sees one session while two machines-worth of
    // work runs.
    let first = [session(.working, id: "s1")]
    let out = SessionHub.apply(
        HookEvent(hookEventName: "SessionStart", sessionID: "s2", source: "startup"),
        to: first, now: t0)
    #expect(out.count == 2)
    #expect(out.map(\.sessionID) == ["s1", "s2"])
}

@Test func anEventForALaterSessionLeavesTheOrderAlone() {
    // Order is asserted because everything downstream reads this list. A hub
    // that rebuilds the array from a dictionary returns a different order on
    // every call, and the attention list then reshuffles under the user's
    // cursor. Position-based access into the result is the defect this pins.
    let before = [session(.working, id: "a"),
                  session(.working, id: "b"),
                  session(.working, id: "c")]
    let out = SessionHub.apply(
        HookEvent(hookEventName: "Stop", sessionID: "b"), to: before, now: t0)
    #expect(out.map(\.sessionID) == ["a", "b", "c"])
    #expect(out.map(\.state) == [.working, .awaitingInput, .working])
}

@Test func theSameSessionIDUnderADifferentToolDoesNotMerge() {
    // M1 keyed sessions by (tool, sessionID) for this reason. M2 only produces
    // `.claudeCode`, so this pins the key BEFORE M3 adds a second tool.
    let existing = [AgentSession(
        tool: .codex, sessionID: "shared", cwd: nil, repoName: nil, pid: nil,
        state: .working, stateEnteredAt: t0, lastEventAt: t0, lastMessage: nil,
        attentionSince: nil, turnCount: 0)]
    let out = SessionHub.apply(
        HookEvent(hookEventName: "Stop", sessionID: "shared"), to: existing, now: t0)
    #expect(out.count == 2)
    #expect(out.map(\.id) == ["codex:shared", "claudeCode:shared"])
}

// MARK: - The timestamps staleness depends on

@Test func everyAcceptedEventRefreshesLastEventAt() throws {
    // Task 4 measures staleness from `lastEventAt`. An event that does not
    // refresh it makes a busy agent go stale mid-work and drops the assertion
    // while the agent is still running.
    let later = t0.addingTimeInterval(120)
    let out = SessionHub.apply(try event("pre-tool-use.json"),
                               to: [session(.working)], now: later)
    #expect(out.first?.lastEventAt == later)
}

@Test func stateEnteredAtMovesOnlyWhenTheStateChanges() throws {
    // Named bug this catches: `stateEnteredAt` reset on every event. "Working
    // for 40 minutes" would then read "working for 3 seconds" forever, and any
    // later rule keyed on time-in-state silently never fires.
    let later = t0.addingTimeInterval(120)
    let out = SessionHub.apply(try event("pre-tool-use.json"),
                               to: [session(.working)], now: later)
    #expect(out.first?.state == .working)
    #expect(out.first?.stateEnteredAt == t0)

    let changed = SessionHub.apply(try event("stop.json"),
                                   to: [session(.working)], now: later)
    #expect(changed.first?.state == .awaitingInput)
    #expect(changed.first?.stateEnteredAt == later)
}

@Test func attentionSinceIsSetOnEntryAndClearedOnExit() throws {
    let later = t0.addingTimeInterval(60)
    let blocked = SessionHub.apply(try event("stop.json"),
                                   to: [session(.working)], now: later)
    #expect(blocked.first?.attentionSince == later)

    let resumed = SessionHub.apply(try event("pre-tool-use.json"),
                                   to: blocked, now: later.addingTimeInterval(30))
    #expect(resumed.first?.state == .working)
    #expect(resumed.first?.attentionSince == nil)
}

@Test func turnCountRisesOncePerStop() throws {
    var sessions = [session(.working)]
    sessions = SessionHub.apply(try event("stop.json"), to: sessions, now: t0)
    #expect(sessions.first?.turnCount == 1)
    sessions = SessionHub.apply(try event("pre-tool-use.json"), to: sessions, now: t0)
    #expect(sessions.first?.turnCount == 1)
    sessions = SessionHub.apply(try event("stop.json"), to: sessions, now: t0)
    #expect(sessions.first?.turnCount == 2)
}

// MARK: - The untrusted text

@Test func lastMessageIsCappedAt140Characters() {
    // Design §7: `lastMessage` is attacker-influenced text the panel renders.
    // 140 is compared against a literal the implementation does not compute.
    let long = String(repeating: "x", count: 500)
    let out = SessionHub.apply(
        HookEvent(hookEventName: "PermissionDenied", sessionID: "s1", message: long),
        to: [session(.working)], now: t0)
    #expect(out.first?.lastMessage?.count == 140)
}

@Test func aShortMessageIsNotPadded() {
    // The other side of the cap. Named bug this catches: a truncation written
    // with `prefix` on a fixed range, or padding to the cap.
    let out = SessionHub.apply(
        HookEvent(hookEventName: "PermissionDenied", sessionID: "s1", message: "no"),
        to: [session(.working)], now: t0)
    #expect(out.first?.lastMessage == "no")
}

// MARK: - The repository the panel names

@Test func repoNameIsTheLastComponentOfTheCwd() {
    let out = SessionHub.apply(
        HookEvent(hookEventName: "SessionStart", sessionID: "s9",
                  cwd: "/Users/example/src/coffee-bar", source: "startup"),
        to: [], now: t0)
    #expect(out.first?.repoName == "coffee-bar")
    #expect(out.first?.cwd == URL(fileURLWithPath: "/Users/example/src/coffee-bar"))
}

@Test func anEventWithNoCwdKeepsTheOneAlreadyKnown() {
    // §3: only SessionStart and PreToolUse carry `cwd`. A Stop must not blank
    // the repository name out of the attention list.
    let start = SessionHub.apply(
        HookEvent(hookEventName: "SessionStart", sessionID: "s9",
                  cwd: "/Users/example/src/coffee-bar", source: "startup"),
        to: [], now: t0)
    let stopped = SessionHub.apply(
        HookEvent(hookEventName: "Stop", sessionID: "s9"), to: start, now: t0)
    #expect(stopped.first?.repoName == "coffee-bar")
}
```

**If Task 1 captured a `SessionEnd` payload**, add this test as well. **If it
did not, do not write it and do not add the `.sessionEnd` branch.** Design §3.2
forbids a transition no event produces.

```swift
@Test func sessionEndRetiresTheSession() throws {
    // Only written because Task 1 recorded a real SessionEnd payload. Design
    // §3.2 forbids a `.done` transition that no event produces.
    #expect(try stateAfter("session-end.json", from: [session(.working)]) == .done)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionHub`
Expected: FAIL — `cannot find 'SessionHub' in scope`.

`git add Tests/CoffeeBarCoreTests/SessionHub_test.swift` now.

- [ ] **Step 3: Write the implementation**

Create `Sources/CoffeeBarCore/SessionHub.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Turns Claude Code hook events into `AgentSession` values.
///
/// A caseless enum of static functions, the shape `PowerBroker` uses: no I/O,
/// no clock, no stored state. `apply` is a pure function of
/// `(sessions, event, now)`, so every transition in design §3.1 tests from a
/// recorded payload with no socket and no Mac in the loop.
///
/// **There is no transition into `.done` or `.failed` from a turn-level event.**
/// Design §3.2: the observed hook set carries no session-end signal beyond
/// `SessionEnd`, so a session that simply stops is retired by the stale timeout
/// in `StalePolicy`, not by a transition invented here.
public enum SessionHub {

    /// Design §7 caps the rendered message. It is attacker-influenced text.
    public static let messageCap = 140

    /// Applies one event and returns the new session list.
    ///
    /// Unknown events return the input unchanged, so a Claude Code release that
    /// adds an event cannot mint a phantom session that holds the machine awake.
    public static func apply(_ event: HookEvent,
                             to sessions: [AgentSession],
                             now: Date) -> [AgentSession] {
        guard let kind = event.kind, let newState = state(for: kind) else {
            return sessions
        }

        // Keyed by (tool, sessionID) through `AgentSession.id`, never by
        // position: two tools may use the same session id and must not merge.
        let id = "\(AgentTool.claudeCode.rawValue):\(event.sessionID)"

        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            var appended = sessions
            appended.append(make(event, state: newState, now: now))
            return appended
        }

        var updated = sessions
        updated[index] = advance(sessions[index], with: event,
                                 to: newState, now: now)
        return updated
    }

    /// Design §3.1. `preCompact` maps to nothing: it is housekeeping, and it
    /// deliberately does not even refresh `lastEventAt`. A compaction longer
    /// than the stale timeout therefore releases the assertion, which is the
    /// safe direction to be wrong in.
    private static func state(for kind: HookEventKind) -> SessionState? {
        switch kind {
        case .sessionStart: return .starting
        case .preToolUse, .postToolUse: return .working
        case .permissionDenied: return .awaitingPermission
        case .stop: return .awaitingInput
        case .sessionEnd: return .done
        case .preCompact: return nil
        }
    }

    private static func make(_ event: HookEvent,
                             state: SessionState,
                             now: Date) -> AgentSession {
        let cwd = event.cwd.map { URL(fileURLWithPath: $0) }
        return AgentSession(
            tool: .claudeCode,
            sessionID: event.sessionID,
            cwd: cwd,
            repoName: cwd?.lastPathComponent,
            pid: nil,
            state: state,
            stateEnteredAt: now,
            lastEventAt: now,
            lastMessage: cap(event.message),
            attentionSince: SessionState.attentionStates.contains(state) ? now : nil,
            turnCount: state == .awaitingInput ? 1 : 0)
    }

    private static func advance(_ session: AgentSession,
                                with event: HookEvent,
                                to state: SessionState,
                                now: Date) -> AgentSession {
        let changed = session.state != state
        // Only SessionStart and PreToolUse carry `cwd`; a Stop must not blank
        // the repository name out of the attention list.
        let cwd = event.cwd.map { URL(fileURLWithPath: $0) } ?? session.cwd

        let attentionSince: Date?
        if SessionState.attentionStates.contains(state) {
            // Preserved across a re-entry into the SAME attention state, so the
            // "waiting since" the panel orders by is when the wait began, not
            // when the newest event landed.
            attentionSince = changed ? now : session.attentionSince
        } else {
            attentionSince = nil
        }

        return AgentSession(
            tool: session.tool,
            sessionID: session.sessionID,
            cwd: cwd,
            repoName: cwd?.lastPathComponent ?? session.repoName,
            pid: session.pid,
            state: state,
            stateEnteredAt: changed ? now : session.stateEnteredAt,
            lastEventAt: now,
            lastMessage: cap(event.message) ?? session.lastMessage,
            attentionSince: attentionSince,
            turnCount: session.turnCount + (state == .awaitingInput && changed ? 1 : 0))
    }

    private static func cap(_ message: String?) -> String? {
        guard let message else { return nil }
        return String(message.prefix(messageCap))
    }
}

extension SessionState {
    /// The two states where the agent is blocked on the human.
    ///
    /// Not a second copy of a rule `PowerBroker` already owns: a test asserts
    /// this set equals the difference between the broker's two active sets, so
    /// the two definitions cannot drift apart silently.
    public static let attentionStates: Set<SessionState> = [.awaitingPermission,
                                                            .awaitingInput]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SessionHub`
Expected: PASS, 16 tests (17 with the `SessionEnd` case). Confirm the count.

- [ ] **Step 5: Add the drift guard between the two definitions**

Append to `Tests/CoffeeBarCoreTests/SessionHub_test.swift`:

```swift
@Test func theAttentionStatesAreExactlyWhatTheKnobAddsToTheWakeSet() {
    // Two definitions written independently — `PowerBroker.activeStates` and
    // `SessionState.attentionStates` — compared against each other rather than
    // against a literal either one computes.
    //
    // Named bug this catches: `holdAwakeWhileBlocked` gaining a third state
    // while the attention list keeps showing two, so a session holds the
    // machine awake and never appears in the list that explains why.
    let added = PowerBroker.activeStates(holdAwakeWhileBlocked: true)
        .subtracting(PowerBroker.activeStates(holdAwakeWhileBlocked: false))
    #expect(SessionState.attentionStates == added)
}
```

- [ ] **Step 6: Mutation-check the load-bearing guards**

One at a time, reverting between them. Prove each applied and compiling.

| # | Mutant | Test that must go RED |
|---|---|---|
| 1 | `case .stop: return .awaitingInput` → `return .working` | `stopMovesToAwaitingInput` |
| 2 | Return `sessions` unchanged when `firstIndex` finds no match | `aSecondSessionIsAppendedRatherThanReplacing` |
| 3 | `updated[index] = …` → `updated[0] = …` | `anEventForALaterSessionLeavesTheOrderAlone` |
| 4 | `stateEnteredAt: changed ? now : session.stateEnteredAt` → `stateEnteredAt: now` | `stateEnteredAtMovesOnlyWhenTheStateChanges` |
| 5 | `messageCap = 140` → `141` | `lastMessageIsCappedAt140Characters` |
| 6 | Key on `event.sessionID` alone rather than on `AgentSession.id` | `theSameSessionIDUnderADifferentToolDoesNotMerge` |
| 7 | `case .preCompact: return nil` → `return .working` | `preCompactChangesNothing` |
| 8 | Drop the `guard let kind` and default unknown events to `.starting` | `anUnknownEventChangesNothing` |

Mutant 3 is the important one. It is the index-based-access defect this
workspace records six times, and it stays green against every single-session
test in the file.

- [ ] **Step 7: Commit**

```bash
git add Sources/CoffeeBarCore/SessionHub.swift Tests/CoffeeBarCoreTests/SessionHub_test.swift
git commit -s -S -m "feat(core): add SessionHub, the pure hook-event transition function"
```

**Acceptance:** every transition in design §3.1 is driven by a recorded fixture.
Order survives an update to a middle element. An unknown event and a
`PreCompact` both change nothing. The message cap is 140. No `.done` transition
exists unless Task 1 captured a `SessionEnd`.

---

### Task 4: Staleness — the safety property

**Files:**
- Create: `Sources/CoffeeBarCore/StalePolicy.swift`
- Test: `Tests/CoffeeBarCoreTests/Staleness_test.swift`

**Interfaces:**
- Consumes: `AgentSession`, `SessionState`, `SessionHub` (Task 3), `PowerBroker` (M1).
- Produces: `StalePolicy`, `SessionHub.expiring(_:now:policy:)`.

Depends on Task 3.

Design §5: nothing reports session end, so a crashed or killed agent would leave
a `.working` session behind and hold the machine awake forever. **This is a
correctness requirement, not a nicety.** Guard BOTH sides of the boundary — M1
shipped two defects where exactly one side of a comparison was unguarded.

- [ ] **Step 1: Write the failing test**

Create `Tests/CoffeeBarCoreTests/Staleness_test.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

/// Distinct, easily distinguished values, so a swapped pair is visible.
private let policy = StalePolicy(workingTimeout: 100, blockedTimeout: 1000)

private func session(_ state: SessionState,
                     id: String = "s1",
                     lastEventAt: Date,
                     stateEnteredAt: Date = t0) -> AgentSession {
    AgentSession(tool: .claudeCode, sessionID: id, cwd: nil, repoName: nil,
                 pid: nil, state: state, stateEnteredAt: stateEnteredAt,
                 lastEventAt: lastEventAt, lastMessage: nil,
                 attentionSince: nil, turnCount: 0)
}

private func stateAfterExpiry(_ state: SessionState,
                              silentFor seconds: TimeInterval) -> SessionState? {
    SessionHub.expiring([session(state, lastEventAt: t0)],
                        now: t0.addingTimeInterval(seconds),
                        policy: policy).first?.state
}

// MARK: - Both sides of the working boundary

@Test func aWorkingSessionGoesStaleAtExactlyTheTimeout() {
    // The boundary itself. Named bug this catches: `>` where `>=` belongs. At
    // exactly the timeout the session keeps holding, and nothing else in this
    // file notices — the M1 battery floor shipped this defect twice.
    #expect(stateAfterExpiry(.working, silentFor: 100) == .stale)
}

@Test func aWorkingSessionOneSecondInsideTheTimeoutSurvives() {
    // The mirror. Named bug this catches: `>= timeout - 1`, or a comparison
    // that rounds. A working agent would be retired a second early, releasing
    // the assertion under an agent that is still running.
    #expect(stateAfterExpiry(.working, silentFor: 99) == .working)
}

@Test func aWorkingSessionOneSecondPastTheTimeoutIsStale() {
    #expect(stateAfterExpiry(.working, silentFor: 101) == .stale)
}

@Test func aFreshWorkingSessionIsNotTouched() {
    #expect(stateAfterExpiry(.working, silentFor: 0) == .working)
}

// MARK: - Both sides of the blocked boundary

@Test func aBlockedSessionOutlivesTheWorkingTimeout() {
    // Design §10.2: an `.awaitingInput` session may legitimately idle for
    // hours. Named bug this catches: the two timeouts swapped, which retires
    // every waiting session after the working timeout and empties the
    // attention list the moment the user steps away.
    #expect(stateAfterExpiry(.awaitingInput, silentFor: 500) == .awaitingInput)
    #expect(stateAfterExpiry(.awaitingPermission, silentFor: 500) == .awaitingPermission)
}

@Test func aBlockedSessionGoesStaleAtExactlyItsOwnTimeout() {
    #expect(stateAfterExpiry(.awaitingInput, silentFor: 1000) == .stale)
}

@Test func aBlockedSessionOneSecondInsideItsTimeoutSurvives() {
    #expect(stateAfterExpiry(.awaitingInput, silentFor: 999) == .awaitingInput)
}

@Test func aStartingSessionUsesTheWorkingTimeout() {
    // `.starting` holds the assertion, so it needs a timeout. Named bug this
    // catches: a switch that handles `.working` and lets `.starting` fall
    // through to never expiring — an agent that dies during startup then holds
    // the machine awake forever.
    #expect(stateAfterExpiry(.starting, silentFor: 100) == .stale)
    #expect(stateAfterExpiry(.starting, silentFor: 99) == .starting)
}

// MARK: - States that must not be re-expired

@Test func alreadyFinishedSessionsAreLeftAlone() {
    // `.done`, `.failed` and `.stale` hold nothing already. Rewriting them
    // would churn `stateEnteredAt` on every tick for no reason.
    for state in [SessionState.done, .failed, .stale] {
        #expect(stateAfterExpiry(state, silentFor: 100_000) == state)
    }
}

// MARK: - The measurement is from lastEventAt, not stateEnteredAt

@Test func aLongRunningSessionWithRecentEventsIsNotStale() {
    // Named bug this catches: expiry measured from `stateEnteredAt`. An agent
    // that has been `.working` for an hour, emitting a PreToolUse every few
    // seconds, is the NORMAL case this product exists for. Measuring from
    // `stateEnteredAt` drops the assertion under a perfectly healthy agent, and
    // every other test in this file stays green because they set the two
    // timestamps to the same instant.
    let now = t0.addingTimeInterval(3600)
    let busy = session(.working,
                       lastEventAt: now.addingTimeInterval(-10),
                       stateEnteredAt: t0)
    #expect(SessionHub.expiring([busy], now: now, policy: policy).first?.state == .working)
}

// MARK: - Ordering and identity survive expiry

@Test func expiryKeepsTheListOrderAndTouchesOnlyTheStaleOnes() {
    let now = t0.addingTimeInterval(200)
    let sessions = [session(.working, id: "a", lastEventAt: now),
                    session(.working, id: "b", lastEventAt: t0),
                    session(.working, id: "c", lastEventAt: now)]
    let out = SessionHub.expiring(sessions, now: now, policy: policy)
    #expect(out.map(\.sessionID) == ["a", "b", "c"])
    #expect(out.map(\.state) == [.working, .stale, .working])
}

@Test func expiringStampsStateEnteredAt() {
    let now = t0.addingTimeInterval(200)
    let out = SessionHub.expiring([session(.working, lastEventAt: t0)],
                                  now: now, policy: policy)
    #expect(out.first?.stateEnteredAt == now)
}

// MARK: - The safety property itself

@Test func aStaleWorkingSessionStopsHoldingTheAssertion() {
    // Design §5, end to end and composed rather than asserted twice. A crashed
    // agent leaves `.working` behind; only this path releases the machine.
    let crashed = [session(.working, lastEventAt: t0)]
    let now = t0.addingTimeInterval(100)

    // Precondition: before expiry it DOES hold, so a broker stuck at false
    // cannot satisfy the assertion below.
    #expect(PowerBroker.decide(PowerInputs(
        sessions: crashed, powerSource: .ac, batteryPercent: 80,
        userIntent: .stop)).idleSleepAssertion == true)

    let expired = SessionHub.expiring(crashed, now: now, policy: policy)
    #expect(PowerBroker.decide(PowerInputs(
        sessions: expired, powerSource: .ac, batteryPercent: 80,
        userIntent: .stop)).idleSleepAssertion == false)
}

// MARK: - The declared defaults (design §10.2)

@Test func stalePolicyAppliesItsDocumentedDefaults() {
    // Every other test injects its own policy, so all of them are blind to the
    // shipped numbers: changing them leaves the file green. Design §10.2 marks
    // these as provisional, which is exactly why they need a test that sees
    // them. Pinned to literals, not to the type's own properties.
    #expect(StalePolicy.standard.workingTimeout == 300)
    #expect(StalePolicy.standard.blockedTimeout == 14_400)
    #expect(StalePolicy.standard.timeout(for: .starting) == 300)
    #expect(StalePolicy.standard.timeout(for: .awaitingPermission) == 14_400)
    #expect(StalePolicy.standard.timeout(for: .stale) == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter Staleness`
Expected: FAIL — `cannot find 'StalePolicy' in scope`.

`git add Tests/CoffeeBarCoreTests/Staleness_test.swift` now.

- [ ] **Step 3: Write the implementation**

Create `Sources/CoffeeBarCore/StalePolicy.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How long a session may go silent before it is retired.
///
/// Design §5 makes this a SAFETY property, not a feature. The observed hook set
/// carries no reliable session-end signal, so a crashed or killed agent leaves
/// a `.working` session behind and would hold the machine awake forever. This
/// timeout is the only thing that retires it.
///
/// The two values differ because the two situations differ. An `.awaitingInput`
/// session may legitimately idle for hours while the human is at lunch. A
/// `.working` one going quiet for minutes is a dead process.
///
/// Design §10.2 records both numbers as PROVISIONAL.
public struct StalePolicy: Equatable, Sendable {
    public let workingTimeout: TimeInterval
    public let blockedTimeout: TimeInterval

    public static let standard = StalePolicy(workingTimeout: 300,
                                             blockedTimeout: 14_400)

    public init(workingTimeout: TimeInterval, blockedTimeout: TimeInterval) {
        self.workingTimeout = workingTimeout
        self.blockedTimeout = blockedTimeout
    }

    /// `nil` for a state that holds nothing already, so expiry leaves it alone
    /// rather than churning `stateEnteredAt` on every tick.
    public func timeout(for state: SessionState) -> TimeInterval? {
        switch state {
        case .starting, .working:
            return workingTimeout
        case .awaitingPermission, .awaitingInput:
            return blockedTimeout
        case .done, .failed, .stale:
            return nil
        }
    }
}

extension SessionHub {

    /// Retires every session that has gone silent for longer than its timeout.
    ///
    /// Design §5 requires this to run on a TIMER, not only when the next event
    /// arrives: an agent that dies sends nothing, so nothing would ever notice.
    /// `ServingModel.refresh()` is that timer, and it is the existing one — the
    /// design forbids a second timer discipline.
    ///
    /// The elapsed time is measured from `lastEventAt`, never from
    /// `stateEnteredAt`. A healthy agent stays `.working` for hours while
    /// emitting an event every few seconds, and measuring from `stateEnteredAt`
    /// would drop the assertion underneath it.
    public static func expiring(_ sessions: [AgentSession],
                                now: Date,
                                policy: StalePolicy = .standard) -> [AgentSession] {
        sessions.map { session in
            guard let timeout = policy.timeout(for: session.state),
                  // `>=` so that exactly the timeout retires the session. Both
                  // sides of this boundary are guarded by tests: M1 shipped two
                  // defects where only one side of a comparison was covered.
                  now.timeIntervalSince(session.lastEventAt) >= timeout
            else { return session }

            return AgentSession(
                tool: session.tool,
                sessionID: session.sessionID,
                cwd: session.cwd,
                repoName: session.repoName,
                pid: session.pid,
                state: .stale,
                stateEnteredAt: now,
                lastEventAt: session.lastEventAt,
                lastMessage: session.lastMessage,
                attentionSince: nil,
                turnCount: session.turnCount)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter Staleness`
Expected: PASS, 14 tests. Confirm the count.

- [ ] **Step 5: Mutation-check both sides of the boundary**

| # | Mutant | Test that must go RED |
|---|---|---|
| 1 | `>= timeout` → `> timeout` | `aWorkingSessionGoesStaleAtExactlyTheTimeout` |
| 2 | `>= timeout` → `>= timeout - 1` | `aWorkingSessionOneSecondInsideTheTimeoutSurvives` |
| 3 | `now.timeIntervalSince(session.lastEventAt)` → `…(session.stateEnteredAt)` | `aLongRunningSessionWithRecentEventsIsNotStale` |
| 4 | Swap `workingTimeout` and `blockedTimeout` in `timeout(for:)` | `aBlockedSessionOutlivesTheWorkingTimeout` |
| 5 | `case .starting, .working` → `case .working` only | `aStartingSessionUsesTheWorkingTimeout` |
| 6 | `case .done, .failed, .stale: return nil` → `return workingTimeout` | `alreadyFinishedSessionsAreLeftAlone` |
| 7 | `standard` working timeout `300` → `600` | `stalePolicyAppliesItsDocumentedDefaults` |

Mutants 1 and 2 are the pair design §5 demands. Neither one alone proves the
boundary is guarded.

- [ ] **Step 6: Commit**

```bash
git add Sources/CoffeeBarCore/StalePolicy.swift Tests/CoffeeBarCoreTests/Staleness_test.swift
git commit -s -S -m "feat(core): retire silent sessions so a crashed agent stops holding the machine"
```

**Acceptance:** both sides of both timeout boundaries are guarded. Expiry is
measured from `lastEventAt`. A stale `.working` session stops holding the
assertion, proved through `PowerBroker.decide`. The shipped defaults have their
own test.

---

### Task 5: CoffeeBarIngest — HTTP framing and the unix-socket listener

**Files:**
- Create: `Sources/CoffeeBarIngest/HTTPRequestFramer.swift`
- Create: `Sources/CoffeeBarIngest/IngestListener.swift`
- Create: `Tests/CoffeeBarIngestTests/HTTPRequestFramer_test.swift`
- Create: `Tests/CoffeeBarIngestTests/IngestListener_test.swift`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: `HookEvent` (Task 2).
- Produces: `IngestListening`, `UnixSocketIngestListener`, `IngestError`, `HTTPRequestFramer`.

Depends on Task 2. Independent of Tasks 3 and 4 — it can run beside them.

#### What was proved by running, before this was written

A standalone spike compiled with `swiftc -swift-version 6 -target
arm64-apple-macos14.0` and run against `/usr/bin/curl 8.7.1`:

```
=== socket node ===
srw-------@ 1 eduardoa  wheel  0 Jul 28 19:40 /tmp/claude/cbspike.sock
=== curl ===
http_code=204
=== stderr ===
LISTENER STATE: ready
READY chmod=true mode=Optional(384)
REQUEST BYTES=216
---
POST /ingest HTTP/1.1
Host: localhost
User-Agent: curl/8.7.1
Accept: */*
Content-Type: application/json
Content-Length: 85

{"hook_event_name":"SessionStart","session_id":"abc","cwd":"/tmp","source":"startup"}
---
```

Four facts come out of that run, and each one shapes the code below.

1. `NWEndpoint.unix(path:)` on `NWParameters.requiredLocalEndpoint` binds a real
   unix domain socket. Confirmed against the SDK's
   `Network.swiftmodule/arm64e-apple-macos.swiftinterface` at `:392`
   (`case unix(path:)`), `:2484` (`requiredLocalEndpoint`) and `:692`
   (`NWListener.init(using:on:)`).
2. `chmod` after `.ready` yields `srw-------`, mode `0600`.
3. **The bind itself creates the node at `0755`.** Measured directly:

   ```
   $ python3 -c "import socket,os,stat; s=socket.socket(socket.AF_UNIX);
     s.bind('/tmp/claude/cbmode.sock'); print('%o' % stat.S_IMODE(os.stat('/tmp/claude/cbmode.sock').st_mode))"
   755
   ```

   There is a window between bind and chmod where any local user can connect.
   **The parent directory is therefore created at `0700` before the bind.** That
   closes the window deterministically: at `0755` or not, no other user can
   traverse into the directory.
4. `curl` delivered the whole request in one 216-byte receive. **That is not
   guaranteed**, so the framer below accumulates.

#### The path-length limit, measured

`sun_path` is 104 bytes:

```
$ grep -n "sun_path\[" .../MacOSX26.5.sdk/usr/include/sys/un.h
79:	char            sun_path[104];  /* [XSI] path name (gag) */
```

The production path is 66 bytes on this machine
(`/Users/eduardoa/Library/Application Support/coffee-bar/ingest.sock`), which
clears it. A longer user name does not necessarily. The listener therefore
refuses an over-long path rather than failing obscurely, and **the tests must use
a SHORT temporary path**: `FileManager.default.temporaryDirectory` is 48 bytes
here, so a UUID-named socket under it reaches 93 bytes and a slightly longer
temp root overflows.

- [ ] **Step 1: Add the target to `Package.swift`**

Insert after the `CoffeeBarPower` target, and add the test target at the end:

```swift
        // The listener and the HTTP framing. Depends on CoffeeBarCore only:
        // ingest produces sessions, it does not decide what they mean.
        .target(name: "CoffeeBarIngest", dependencies: ["CoffeeBarCore"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
```

```swift
        .testTarget(name: "CoffeeBarIngestTests", dependencies: ["CoffeeBarIngest"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
```

`CoffeeBarUI` does NOT depend on it yet. That edge, and the
`AppLayerBoundary_test.swift` update it forces, belong to Task 6.

- [ ] **Step 2: Write the failing framer test**

Create `Tests/CoffeeBarIngestTests/HTTPRequestFramer_test.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarIngest

private let body = #"{"hook_event_name":"Stop","session_id":"s1"}"#

private func request(body: String, contentLength: Int? = nil) -> Data {
    let length = contentLength ?? body.utf8.count
    return Data("""
        POST /ingest HTTP/1.1\r
        Host: localhost\r
        Content-Type: application/json\r
        Content-Length: \(length)\r
        \r
        \(body)
        """.utf8)
}

@Test func aWholeRequestInOneChunkYieldsExactlyTheBody() {
    var framer = HTTPRequestFramer()
    #expect(framer.append(request(body: body)) == .body(Data(body.utf8)))
}

@Test func aRequestSplitAcrossChunksIsReassembled() {
    // The case the curl spike could NOT produce: it delivered all 216 bytes in
    // one receive. Named bug this catches: a framer that parses whatever the
    // first receive happened to contain, which works on a developer's machine
    // and drops events under load.
    let whole = request(body: body)
    var framer = HTTPRequestFramer()

    // Split INSIDE the header block, so the header terminator itself straddles
    // two chunks.
    #expect(framer.append(whole.prefix(20)) == .needMore)
    #expect(framer.append(whole.dropFirst(20).prefix(60)) == .needMore)
    #expect(framer.append(whole.dropFirst(80)) == .body(Data(body.utf8)))
}

@Test func aBodyArrivingAfterTheHeadersIsWaitedFor() {
    let whole = request(body: body)
    let headerEnd = whole.count - body.utf8.count
    var framer = HTTPRequestFramer()
    #expect(framer.append(whole.prefix(headerEnd)) == .needMore)
    #expect(framer.append(whole.suffix(body.utf8.count)) == .body(Data(body.utf8)))
}

@Test func onlyContentLengthBytesAreTaken() {
    // Named bug this catches: returning everything after the headers. A client
    // that pipelines a second request would have both bodies concatenated into
    // one unparseable blob, and every event on that connection would be lost.
    var framer = HTTPRequestFramer()
    let padded = request(body: body + "TRAILING-GARBAGE",
                         contentLength: body.utf8.count)
    #expect(framer.append(padded) == .body(Data(body.utf8)))
}

@Test func headersWithNoContentLengthAreRejected() {
    var framer = HTTPRequestFramer()
    let raw = Data("POST /ingest HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
    #expect(framer.append(raw) == .malformed)
}

@Test func contentLengthIsMatchedWithoutRegardToCase() {
    // curl sends `Content-Length`. Nothing stops another client sending
    // `content-length`, and RFC 9110 makes field names case-insensitive.
    var framer = HTTPRequestFramer()
    let raw = Data("POST / HTTP/1.1\r\ncontent-length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
    #expect(framer.append(raw) == .body(Data(body.utf8)))
}

@Test func anOversizedRequestIsRefusedRatherThanBuffered() {
    // Design §4.1: a same-user process can post. Without a cap it can also pin
    // unbounded memory in a menu-bar app that is meant to be invisible.
    var framer = HTTPRequestFramer()
    let huge = Data(repeating: 0x41, count: HTTPRequestFramer.maximumBytes + 1)
    #expect(framer.append(huge) == .tooLarge)
}

@Test func aRequestExactlyAtTheCapIsAccepted() {
    // The other side of the cap. Named bug this catches: `>=` where `>` belongs,
    // which refuses a legal request one byte under the limit.
    let filler = String(repeating: "x", count: 100)
    let payload = #"{"hook_event_name":"Stop","session_id":"\#(filler)"}"#
    var framer = HTTPRequestFramer()
    let raw = request(body: payload)
    #expect(raw.count < HTTPRequestFramer.maximumBytes)
    #expect(framer.append(raw) == .body(Data(payload.utf8)))
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter HTTPRequestFramer`
Expected: FAIL — `no such module 'CoffeeBarIngest'` or `cannot find 'HTTPRequestFramer' in scope`.

`git add Tests/CoffeeBarIngestTests/HTTPRequestFramer_test.swift Package.swift` now.

- [ ] **Step 4: Write the framer**

Create `Sources/CoffeeBarIngest/HTTPRequestFramer.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Reassembles one HTTP request from however many pieces the socket delivers.
///
/// A spike against `curl 8.7.1` delivered a 216-byte request in a single
/// receive. That is a property of one small request on one machine, not a
/// guarantee, so this type accumulates and reports `needMore` until the body is
/// complete.
///
/// Only what design §4 needs: a POST with a `Content-Length` body. No chunked
/// encoding, no keep-alive, no pipelining. The client is `curl --unix-socket`
/// from a hook the user pasted in.
struct HTTPRequestFramer {

    /// The largest request accepted, headers included.
    ///
    /// Design §4.1 is explicit that a same-user process can post here. A cap
    /// stops it pinning unbounded memory in a menu-bar app.
    static let maximumBytes = 65_536

    enum Outcome: Equatable {
        case needMore
        case body(Data)
        case tooLarge
        case malformed
    }

    private static let terminator = Data("\r\n\r\n".utf8)

    private var buffer = Data()

    mutating func append(_ chunk: Data) -> Outcome {
        buffer.append(chunk)
        if buffer.count > Self.maximumBytes { return .tooLarge }

        guard let separator = buffer.range(of: Self.terminator) else {
            return .needMore
        }

        let headers = buffer[..<separator.lowerBound]
        guard let length = Self.contentLength(in: headers) else {
            return .malformed
        }

        // `separator.upperBound` already sits past the four terminator bytes.
        let bodyStart = separator.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= length else { return .needMore }

        // Exactly `length` bytes, never everything that arrived: a pipelined
        // second request would otherwise be concatenated into the first body.
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        return .body(Data(buffer[bodyStart..<bodyEnd]))
    }

    /// RFC 9110 makes field names case-insensitive, so the match is lowercased.
    private static func contentLength(in headers: Data) -> Int? {
        guard let text = String(data: headers, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                    == "content-length"
            else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter HTTPRequestFramer`
Expected: PASS, 8 tests. Confirm the count.

- [ ] **Step 6: Write the failing listener test**

Create `Tests/CoffeeBarIngestTests/IngestListener_test.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import CoffeeBarCore
@testable import CoffeeBarIngest

/// A SHORT unique socket path.
///
/// `sun_path` is 104 bytes (`sys/un.h:79`). The per-user temporary directory is
/// already 48 bytes on macOS, so a UUID-named socket under it reaches 93 and a
/// slightly longer temp root overflows. Eight hex characters is enough.
private func shortSocketPath() -> String {
    let tag = String(UUID().uuidString.prefix(8)).lowercased()
    return FileManager.default.temporaryDirectory
        .appending(path: "cb-\(tag).sock").path
}

/// Posts one payload the way a real hook does. `/usr/bin/curl` ships with macOS.
@discardableResult
private func post(_ json: String, to socketPath: String) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = ["--silent", "--show-error", "--fail",
                         "--unix-socket", socketPath,
                         "-X", "POST",
                         "-H", "Content-Type: application/json",
                         "--data", json,
                         "http://localhost/ingest"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

/// Collects what the listener delivered, across the queue boundary.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [HookEvent] = []
    private var mainThread: [Bool] = []

    func record(_ event: HookEvent, onMain: Bool) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
        mainThread.append(onMain)
    }

    var all: [HookEvent] { lock.lock(); defer { lock.unlock() }; return events }
    var everyDeliveryWasOnMain: Bool {
        lock.lock(); defer { lock.unlock() }
        return !mainThread.isEmpty && mainThread.allSatisfy { $0 }
    }
}

/// Runs the main run loop until `condition` holds or the deadline passes.
///
/// The listener is started on `DispatchQueue.main`, so the test cannot block the
/// main thread waiting for it — that would deadlock rather than fail.
private func pump(until condition: () -> Bool, seconds: TimeInterval = 5) {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

@Test func aPostedPayloadArrivesAsADecodedEvent() throws {
    let path = shortSocketPath()
    let collected = Collected()
    let listener = UnixSocketIngestListener(socketPath: path)
    defer { listener.stop() }

    try listener.start { event in
        collected.record(event, onMain: Thread.isMainThread)
    }
    pump(until: { FileManager.default.fileExists(atPath: path) })

    #expect(try post(#"{"hook_event_name":"Stop","session_id":"s1"}"#, to: path) == 0)
    pump(until: { !collected.all.isEmpty })

    let event = try #require(collected.all.first)
    #expect(event.hookEventName == "Stop")
    #expect(event.sessionID == "s1")
}

@Test func theSocketIsNotReadableByOtherUsers() throws {
    // Design §4: the filesystem is the authenticator. There is no token, so the
    // mode IS the access control.
    let path = shortSocketPath()
    let listener = UnixSocketIngestListener(socketPath: path)
    defer { listener.stop() }
    try listener.start { _ in }
    pump(until: { FileManager.default.fileExists(atPath: path) })

    let mode = try #require(
        FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
    #expect(mode.int16Value == 0o600, "socket mode is \(String(mode.int16Value, radix: 8))")
}

@Test func theParentDirectoryIsNotTraversableByOtherUsers() throws {
    // Measured, not assumed: a bare bind under umask 022 creates the node at
    // 0755, and the chmod to 0600 lands afterwards. Any local user can connect
    // inside that window. A 0700 parent directory closes it deterministically,
    // because no other user can reach the node at all.
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "cb-dir-\(String(UUID().uuidString.prefix(8)).lowercased())")
    let path = directory.appending(path: "i.sock").path
    let listener = UnixSocketIngestListener(socketPath: path)
    defer { listener.stop() }
    try listener.start { _ in }
    pump(until: { FileManager.default.fileExists(atPath: path) })

    let mode = try #require(
        FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
    #expect(mode.int16Value == 0o700,
            "parent directory mode is \(String(mode.int16Value, radix: 8))")
}

@Test func deliveryHappensOnTheMainThread() throws {
    // Load-bearing, and a runtime TRAP rather than a warning if it breaks.
    // `ServingModel` reaches the main actor from this callback with
    // `MainActor.assumeIsolated`, matching the discipline `startMonitoring`
    // already uses. Delivering from any other queue crashes the app.
    let path = shortSocketPath()
    let collected = Collected()
    let listener = UnixSocketIngestListener(socketPath: path)
    defer { listener.stop() }
    try listener.start { event in
        collected.record(event, onMain: Thread.isMainThread)
    }
    pump(until: { FileManager.default.fileExists(atPath: path) })

    #expect(try post(#"{"hook_event_name":"Stop","session_id":"s1"}"#, to: path) == 0)
    pump(until: { !collected.all.isEmpty })

    #expect(collected.everyDeliveryWasOnMain)
}

@Test func anUndecodablePayloadDeliversNothingAndDoesNotKillTheListener() throws {
    // Named bug this catches: a decode failure that cancels the listener. One
    // malformed post would then silently stop ingest for the rest of the
    // session, and the panel would keep looking healthy.
    let path = shortSocketPath()
    let collected = Collected()
    let listener = UnixSocketIngestListener(socketPath: path)
    defer { listener.stop() }
    try listener.start { event in
        collected.record(event, onMain: Thread.isMainThread)
    }
    pump(until: { FileManager.default.fileExists(atPath: path) })

    _ = try post("not json at all", to: path)
    _ = try post(#"{"hook_event_name":"Stop","session_id":"good"}"#, to: path)
    pump(until: { !collected.all.isEmpty })

    #expect(collected.all.map(\.sessionID) == ["good"])
}

@Test func aStaleSocketFileDoesNotStopTheNextStart() throws {
    // The app is force-quit and the socket node survives. Named bug this
    // catches: a bind that fails on the leftover file, so ingest never comes
    // back until the user deletes a file they do not know about.
    let path = shortSocketPath()
    FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
    #expect(FileManager.default.fileExists(atPath: path))

    let listener = UnixSocketIngestListener(socketPath: path)
    defer { listener.stop() }
    try listener.start { _ in }
    pump(until: {
        (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) != nil
    })

    let mode = try #require(
        FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
    #expect(mode.int16Value == 0o600)
}

@Test func anOverLongSocketPathIsRefusedWithANamedError() throws {
    // `sun_path` is 104 bytes. Named bug this catches: an obscure bind failure
    // on a machine with a long user name, which would look like "ingest just
    // does not work here" with no way to tell why.
    let long = "/tmp/" + String(repeating: "a", count: 120) + ".sock"
    let listener = UnixSocketIngestListener(socketPath: long)
    #expect(throws: IngestError.socketPathTooLong(long.utf8.count)) {
        try listener.start { _ in }
    }
}

@Test func stopRemovesTheSocketNode() throws {
    let path = shortSocketPath()
    let listener = UnixSocketIngestListener(socketPath: path)
    try listener.start { _ in }
    pump(until: { FileManager.default.fileExists(atPath: path) })
    #expect(FileManager.default.fileExists(atPath: path))

    listener.stop()
    pump(until: { !FileManager.default.fileExists(atPath: path) })
    #expect(FileManager.default.fileExists(atPath: path) == false)
}

@Test func theDefaultSocketPathIsUnderApplicationSupport() {
    // Design §4 fixes the location. Pinned to the literal suffix, not rebuilt
    // from the implementation's own components.
    let path = UnixSocketIngestListener.defaultSocketPath
    #expect(path.hasSuffix("/Library/Application Support/coffee-bar/ingest.sock"))
    #expect(path.utf8.count < 104, "the default path overflows sun_path")
}
```

- [ ] **Step 7: Run test to verify it fails**

Run: `swift test --filter IngestListener`
Expected: FAIL — `cannot find 'UnixSocketIngestListener' in scope`.

`git add Tests/CoffeeBarIngestTests/IngestListener_test.swift` now.

- [ ] **Step 8: Write the listener**

Create `Sources/CoffeeBarIngest/IngestListener.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network
import CoffeeBarCore

public enum IngestError: Error, Equatable {
    /// `sun_path` is 104 bytes. See `/usr/include/sys/un.h`.
    case socketPathTooLong(Int)
    case directoryUnwritable(String)
}

/// Injection seam, alongside `PowerReadingProviding` and `AssertionHolding`.
///
/// `ServingModel` depends on this rather than on the concrete listener, so the
/// model's tests run with no socket at all.
public protocol IngestListening: Sendable {
    /// Delivers every decoded event ON THE MAIN THREAD. See `start(queue:)`.
    func start(onEvent: @escaping @Sendable (HookEvent) -> Void) throws
    func stop()
}

/// An HTTP-over-unix-socket ingest endpoint.
///
/// Design §4: the filesystem is the authenticator. There is no port to collide
/// with, no token to leak or rotate, and no other local user can post.
/// `SECURITY.md`'s "no network egress" stays true — a unix socket is not
/// network egress and this opens no outbound connection.
///
/// Design §4.1 states the residual risk plainly: a process running as the same
/// user can still post. The socket stops other users and remote hosts, not you.
public final class UnixSocketIngestListener: IngestListening, @unchecked Sendable {

    /// `~/Library/Application Support/coffee-bar/ingest.sock`, per design §4.
    public static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/coffee-bar/ingest.sock")
            .path
    }

    /// `sun_path[104]` in `sys/un.h`, minus the terminating NUL.
    private static let maximumPathBytes = 103

    private let socketPath: String
    private let lock = NSLock()
    private var listener: NWListener?

    public init(socketPath: String = UnixSocketIngestListener.defaultSocketPath) {
        self.socketPath = socketPath
    }

    public func start(onEvent: @escaping @Sendable (HookEvent) -> Void) throws {
        guard socketPath.utf8.count <= Self.maximumPathBytes else {
            throw IngestError.socketPathTooLong(socketPath.utf8.count)
        }

        let path = socketPath
        let directory = (path as NSString).deletingLastPathComponent

        // The 0700 directory is created BEFORE the bind, and that ordering is
        // load-bearing. A bare bind under umask 022 creates the node at 0755 —
        // measured — and the chmod below only lands once the listener reports
        // `.ready`. Inside that window the socket is world-connectable. A
        // parent directory no other user can traverse closes it outright.
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            // `createDirectory` applies the attributes only when it CREATES the
            // directory, so an existing one keeps whatever mode it had.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory)
        } catch {
            throw IngestError.directoryUnwritable(directory)
        }

        // A force-quit leaves the node behind and the next bind would fail on
        // it. Removing a stale node is how every unix-socket server starts.
        try? FileManager.default.removeItem(atPath: path)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters)

        listener.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            // The node exists only once the bind has happened.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: path)
        }

        listener.newConnectionHandler = { connection in
            Self.serve(connection, onEvent: onEvent)
        }

        // `.main` is load-bearing, not a default. `ServingModel` reaches the
        // main actor from `onEvent` with `MainActor.assumeIsolated`, the same
        // discipline `startMonitoring` already uses for its `Timer`. Delivering
        // from any other queue makes that call TRAP at runtime.
        listener.start(queue: .main)

        lock.lock()
        self.listener?.cancel()
        self.listener = listener
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        listener?.cancel()
        listener = nil
        lock.unlock()
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private static func serve(_ connection: NWConnection,
                              onEvent: @escaping @Sendable (HookEvent) -> Void) {
        let framer = Framing()
        connection.start(queue: .main)
        receive(connection, framer: framer, onEvent: onEvent)
    }

    /// Boxes the framer so the escaping receive closure can keep mutating it.
    private final class Framing: @unchecked Sendable {
        var framer = HTTPRequestFramer()
    }

    private static func receive(_ connection: NWConnection,
                                framer: Framing,
                                onEvent: @escaping @Sendable (HookEvent) -> Void) {
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: HTTPRequestFramer.maximumBytes) {
            data, _, isComplete, error in

            if let data, !data.isEmpty {
                switch framer.framer.append(data) {
                case .needMore:
                    if !isComplete && error == nil {
                        receive(connection, framer: framer, onEvent: onEvent)
                        return
                    }
                    reply(connection, status: "400 Bad Request")
                    return

                case .body(let body):
                    // A payload that will not decode is DROPPED, and the
                    // listener survives. Cancelling here would let one
                    // malformed post silently stop ingest for the session while
                    // the panel kept looking healthy.
                    if let event = try? JSONDecoder().decode(HookEvent.self, from: body) {
                        onEvent(event)
                        reply(connection, status: "204 No Content")
                    } else {
                        reply(connection, status: "400 Bad Request")
                    }
                    return

                case .tooLarge:
                    reply(connection, status: "413 Content Too Large")
                    return

                case .malformed:
                    reply(connection, status: "400 Bad Request")
                    return
                }
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }
            receive(connection, framer: framer, onEvent: onEvent)
        }
    }

    private static func reply(_ connection: NWConnection, status: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8),
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
```

- [ ] **Step 9: Run test to verify it passes**

Run: `swift test --filter IngestListener`
Expected: PASS, 9 tests. Confirm the count.

Then run the whole suite: `swift build && swift build -c release && swift test`
Expected: zero warnings, and the total has grown by the new tests.

- [ ] **Step 10: Mutation-check the listener's guards**

| # | Mutant | Test that must go RED |
|---|---|---|
| 1 | `[.posixPermissions: 0o600]` → `0o644` | `theSocketIsNotReadableByOtherUsers` |
| 2 | Delete the `createDirectory` attributes and the `setAttributes` after it | `theParentDirectoryIsNotTraversableByOtherUsers` |
| 3 | `listener.start(queue: .main)` → `.global()` | `deliveryHappensOnTheMainThread` |
| 4 | Replace the `try?` decode with `connection.cancel()` on failure | `anUndecodablePayloadDeliversNothingAndDoesNotKillTheListener` |
| 5 | Delete the `removeItem` before the bind | `aStaleSocketFileDoesNotStopTheNextStart` |
| 6 | `maximumPathBytes = 103` → `1024` | `anOverLongSocketPathIsRefusedWithANamedError` |
| 7 | In the framer, `bodyEnd` → `buffer.endIndex` | `onlyContentLengthBytesAreTaken` |
| 8 | In the framer, `buffer.count > maximumBytes` → `>=` … then delete the check | `anOversizedRequestIsRefusedRatherThanBuffered` |

- [ ] **Step 11: Commit**

```bash
git add Package.swift Sources/CoffeeBarIngest Tests/CoffeeBarIngestTests
git commit -s -S -m "feat(ingest): serve HTTP over a 0600 unix socket for Claude Code hooks"
```

**Acceptance:** a real `curl --unix-socket` post arrives as a decoded
`HookEvent`. The socket is `0600` inside a `0700` directory. Delivery is on the
main thread. A malformed payload does not kill the listener. A stale node does
not block a restart. An over-long path throws a named error.

---

### Task 6: Wire the hub into the model — **BLOCKED ON D1**

**Do not start this task until the user answers D1.** The step-3 code below is
written for the CURRENT `PowerBroker` semantics, option (a). If the user picks
(c), add the `UserIntent.auto` case first, in its own task, with its own tests.

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/CoffeeBarUI/ServingModel.swift`
- Modify: `Tests/CoffeeBarUITests/AppLayerBoundary_test.swift`
- Modify: `Tests/CoffeeBarUITests/ServingModel_test.swift`
- Test: `Tests/CoffeeBarUITests/ServingModelIngest_test.swift`

**Interfaces:**
- Consumes: `SessionHub`, `StalePolicy`, `HookEvent` (Tasks 2 to 4); `IngestListening` (Task 5); `HoldController.evaluate(powerSource:batteryPercent:sessions:holdAwakeWhileBlocked:batteryFloorPercent:)` (M1, unchanged).
- Produces: a `ServingModel` whose `sessions` reach the broker.

The seam already exists. `HoldController.evaluate` takes `sessions:` and
forwards it, and `Tests/CoffeeBarCoreTests/HoldController_test.swift:82` already
guards that forwarding. M2 supplies the argument; it reshapes nothing.

**The whole shape below was compile-proved before it was written into this plan**
— `isolated deinit` calling `listener.stop()`, and `MainActor.assumeIsolated`
inside the `@Sendable` callback — with
`swiftc -swift-version 6 -target arm64-apple-macos14.0`.

- [ ] **Step 1: Add the dependency edge**

In `Package.swift`, change the `CoffeeBarUI` target:

```swift
        .target(name: "CoffeeBarUI", dependencies: ["CoffeeBarPower", "CoffeeBarIngest"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
```

- [ ] **Step 2: Update the app-layer boundary guard**

`CoffeeBarIngest` now ships inside the `coffee-bar` binary through
`CoffeeBarUI`. `AppLayerBoundary_test.swift` is built to go red for exactly
this, and its own comment says so: *"a second app-layer target that
`CoffeeBarApp` depends on — the walk reads two fixed directories and knows
nothing of the build graph"*. **That friction is the point. Updating the list is
the moment somebody reads the new files against design §6.1.**

Three edits in `Tests/CoffeeBarUITests/AppLayerBoundary_test.swift`:

```swift
private let appLayerDirectories = [
    "Sources/CoffeeBarUI",
    "Sources/CoffeeBarApp",
    "Sources/CoffeeBarIngest",
]
```

```swift
private let expectedAppLayerEntries = [
    "Sources/CoffeeBarApp/main.swift",
    "Sources/CoffeeBarIngest/HTTPRequestFramer.swift",
    "Sources/CoffeeBarIngest/IngestListener.swift",
    "Sources/CoffeeBarUI/MenuBarGlyphs.swift",
    "Sources/CoffeeBarUI/PanelView.swift",
    "Sources/CoffeeBarUI/ServingModel.swift",
]
```

That order is not a guess. `appLayerEntries()` sorts the whole list with
`sorted()`, and the order above is what Swift's own `[String].sorted()` produced
for these strings.

```swift
    #expect(try manifestDependencies(ofTarget: "CoffeeBarUI")
            == ["CoffeeBarPower", "CoffeeBarIngest"],
            "CoffeeBarUI gained a dependency; a new app-layer target is unscanned")
```

The `CoffeeBarApp` assertion stays `== ["CoffeeBarUI"]`.

**Check the two content guards still hold against the new files.**
`IngestListener.swift` imports `Network`, not IOKit, and names neither
`AssertionHolder` nor `AssertionHolding`. Run
`swift test --filter AppLayerBoundary` and read the count.

- [ ] **Step 3: Write the failing test**

Create `Tests/CoffeeBarUITests/ServingModelIngest_test.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import CoffeeBarCore
import CoffeeBarIngest
import CoffeeBarPower
@testable import CoffeeBarUI

/// A listener that never touches a socket. The handler it is given is kept so
/// a test can post events by hand.
private final class FakeListener: IngestListening, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (HookEvent) -> Void)?
    private var started = 0
    private var stopped = 0

    func start(onEvent: @escaping @Sendable (HookEvent) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        handler = onEvent
        started += 1
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped += 1
    }

    var startCount: Int { lock.lock(); defer { lock.unlock() }; return started }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stopped }

    func deliver(_ event: HookEvent) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(event)
    }
}

private final class FakeReader: PowerReadingProviding, @unchecked Sendable {
    private let reading: PowerReading
    init(source: PowerSource = .ac, percent: Int? = 80) {
        reading = PowerReading(source: source, percent: percent)
    }
    func read() -> PowerReading { reading }
}

private final class SpyHolder: AssertionHolding, @unchecked Sendable {
    private let lock = NSLock()
    private var acquires = 0
    private var releases = 0
    var acquireCount: Int { lock.lock(); defer { lock.unlock() }; return acquires }
    var releaseCount: Int { lock.lock(); defer { lock.unlock() }; return releases }
    @discardableResult func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }; acquires += 1; return true
    }
    func release() { lock.lock(); defer { lock.unlock() }; releases += 1 }
}

private let t0 = Date(timeIntervalSince1970: 1_000_000)

/// A clock the test moves by hand, so staleness is exercised without waiting.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = t0
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }; value = value.addingTimeInterval(seconds)
    }
}

@MainActor
private func model(listener: FakeListener,
                   clock: Clock,
                   holder: SpyHolder = SpyHolder(),
                   policy: StalePolicy = StalePolicy(workingTimeout: 100,
                                                     blockedTimeout: 1000)) -> ServingModel {
    ServingModel(holder: holder, reader: FakeReader(), listener: listener,
                 policy: policy, now: { clock.now })
}

// MARK: - An agent holds the machine awake with no toggle

@MainActor
@Test func aWorkingSessionHoldsTheAssertionWithNoUserToggle() throws {
    // The claim the whole product rests on. Named bug this catches: a
    // `refresh()` that never passes `sessions` to `evaluate`, which leaves the
    // app behaving exactly like M1 while every ingest test stays green.
    let listener = FakeListener()
    let clock = Clock()
    let holder = SpyHolder()
    let model = model(listener: listener, clock: clock, holder: holder)

    try model.startMonitoring(interval: 3600)
    #expect(model.isServing == false)

    listener.deliver(HookEvent(hookEventName: "PreToolUse", sessionID: "s1",
                               cwd: "/Users/example/src/coffee-bar", toolName: "Bash"))

    #expect(model.isServing == true)
    #expect(holder.acquireCount == 1)
}

@MainActor
@Test func aStopReleasesTheAssertionAndTheMachineSleeps() throws {
    // Design §3.1: the human is now the bottleneck, so the assertion drops.
    let listener = FakeListener()
    let clock = Clock()
    let holder = SpyHolder()
    let model = model(listener: listener, clock: clock, holder: holder)
    try model.startMonitoring(interval: 3600)

    listener.deliver(HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))
    #expect(model.isServing == true)

    listener.deliver(HookEvent(hookEventName: "Stop", sessionID: "s1"))
    #expect(model.isServing == false)
    #expect(holder.releaseCount >= 1)
}

@MainActor
@Test func aSecondEventForTheSameSessionDoesNotDoubleTheAssertion() throws {
    let listener = FakeListener()
    let clock = Clock()
    let holder = SpyHolder()
    let model = model(listener: listener, clock: clock, holder: holder)
    try model.startMonitoring(interval: 3600)

    listener.deliver(HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))
    listener.deliver(HookEvent(hookEventName: "PostToolUse", sessionID: "s1"))
    #expect(model.sessionCount == 1)
}

// MARK: - The stale timeout runs on the existing ticker

@MainActor
@Test func aSilentSessionStopsHoldingWhenTheTimerFires() throws {
    // Design §5: the timeout must be evaluated on a TIMER, not only on the next
    // event. Named bug this catches: expiry applied inside `ingest` only. A
    // crashed agent sends nothing, so nothing would ever notice, and the
    // machine stays awake until the user reboots.
    let listener = FakeListener()
    let clock = Clock()
    let holder = SpyHolder()
    let model = model(listener: listener, clock: clock, holder: holder)
    try model.startMonitoring(interval: 3600)

    listener.deliver(HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))
    #expect(model.isServing == true)

    // The agent dies. No further event arrives — only the ticker.
    clock.advance(100)
    model.refresh()

    #expect(model.isServing == false)
    #expect(holder.releaseCount >= 1)
}

// MARK: - The listener's lifecycle follows the model's

@MainActor
@Test func startMonitoringStartsTheListenerExactlyOnce() throws {
    let listener = FakeListener()
    let clock = Clock()
    let model = model(listener: listener, clock: clock)
    try model.startMonitoring(interval: 3600)
    #expect(listener.startCount == 1)
    _ = model
}

@Test func aModelThatGoesAwayStopsItsListener() async throws {
    // The mirror of `theModelInvalidatesItsTimerWhenItGoesAway`. Named bug this
    // catches: a second `App` build leaving an orphan model holding the socket,
    // so the next start binds nothing and ingest is silently dead.
    let listener = FakeListener()
    let clock = Clock()
    await MainActor.run {
        let model = ServingModel(holder: SpyHolder(), reader: FakeReader(),
                                 listener: listener, policy: .standard,
                                 now: { clock.now })
        try? model.startMonitoring(interval: 3600)
    }
    // The model is gone at this point; `isolated deinit` has run.
    #expect(listener.stopCount >= 1)
}

// MARK: - The attention states reach the panel

@MainActor
@Test func aBlockedSessionAppearsInTheAttentionList() throws {
    let listener = FakeListener()
    let clock = Clock()
    let model = model(listener: listener, clock: clock)
    try model.startMonitoring(interval: 3600)

    listener.deliver(HookEvent(hookEventName: "PermissionDenied", sessionID: "s1",
                               message: "Bash(rm -rf /) needs approval"))

    #expect(model.attention.map(\.sessionID) == ["s1"])
    #expect(model.attention.first?.state == .awaitingPermission)
}

@MainActor
@Test func aWorkingSessionIsNotInTheAttentionList() throws {
    let listener = FakeListener()
    let clock = Clock()
    let model = model(listener: listener, clock: clock)
    try model.startMonitoring(interval: 3600)

    listener.deliver(HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))
    #expect(model.attention.isEmpty)
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `swift test --filter ServingModelIngest`
Expected: FAIL — extra arguments at the `ServingModel` initializer.

`git add Tests/CoffeeBarUITests/ServingModelIngest_test.swift` now.

- [ ] **Step 5: Change the one existing test that would bind a real socket**

`theModelInvalidatesItsTimerWhenItGoesAway` in
`Tests/CoffeeBarUITests/ServingModel_test.swift:294` calls `startMonitoring`.
The default listener is the real one, so as written it would bind
`~/Library/Application Support/coffee-bar/ingest.sock` during `swift test` and
two concurrent runs would fight over it.

The default stays real on purpose. A `nil` or null default would let a wiring
defect ship silently, and this milestone exists because ingest that looks wired
and delivers nothing is the failure mode design §6 is built around. So the test
injects a fake instead.

Replace exactly:

```swift
        let model = ServingModel(holder: SpyHolder(),
                                 reader: FakeReader(source: .ac, percent: 80))
```

with:

```swift
        // A fake listener, so the suite never binds the real ingest socket.
        // The default IS the real listener, deliberately: see ServingModel.
        let model = ServingModel(holder: SpyHolder(),
                                 reader: FakeReader(source: .ac, percent: 80),
                                 listener: NoopIngestListener())
```

and add `NoopIngestListener` near the other doubles in that file:

```swift
/// Starts nothing. `theModelInvalidatesItsTimerWhenItGoesAway` calls
/// `startMonitoring`, and the real listener would bind the production socket.
private final class NoopIngestListener: IngestListening, @unchecked Sendable {
    func start(onEvent: @escaping @Sendable (HookEvent) -> Void) throws {}
    func stop() {}
}
```

That file also needs `import CoffeeBarIngest`.

`startMonitoring` becomes `throws`, so that call site becomes
`try model.startMonitoring(interval: 3600)` and the test is already `throws`.

**Verify the after-state**: `grep -n "NoopIngestListener" Tests/CoffeeBarUITests/ServingModel_test.swift`
must print two lines. A scripted substitution that changes nothing while
reporting success is a pattern this workspace has recorded twice.

- [ ] **Step 6: Write the implementation**

Modify `Sources/CoffeeBarUI/ServingModel.swift`. Add to the imports:

```swift
import CoffeeBarIngest
```

Add the stored properties beside the existing ones:

```swift
    private let listener: any IngestListening
    private let policy: StalePolicy
    private let now: @Sendable () -> Date
    private var sessions: [AgentSession] = []

    /// The sessions blocked on the human, for the panel's attention list.
    public private(set) var attention: [AgentSession] = []

    /// How many sessions the hub is tracking. Internal, for the tests: no
    /// production code reads it, so it does not widen the public surface.
    var sessionCount: Int { sessions.count }
```

Replace the initializer:

```swift
    /// The listener default is the REAL one, deliberately.
    ///
    /// A null default would let a missing wire ship silently, and ingest that
    /// looks connected while delivering nothing is the exact honesty failure
    /// design §6 exists to prevent. Tests inject a fake.
    ///
    /// `now` is injected so the stale timeout tests do not wait in real time.
    public init(holder: any AssertionHolding = AssertionHolder(),
                reader: any PowerReadingProviding = SystemPowerReader(),
                listener: any IngestListening = UnixSocketIngestListener(),
                policy: StalePolicy = .standard,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.holder = holder
        self.reader = reader
        self.listener = listener
        self.policy = policy
        self.now = now
        self.reading = reader.read()
    }
```

Replace the `deinit`:

```swift
    // CORRECTED after PE finding B3. The original text here used
    // `isolated deinit`, which is EXPERIMENTAL before Swift 6.3. It compiles on
    // a 6.3 developer machine and fails the 6.1.2 GitHub runner with "requires
    // frontend flag -enable-experimental-feature IsolatedDeinit". Commit
    // a33b35f already removed exactly this construct after it turned the repo's
    // first CI run red. Do not reintroduce it.
    //
    // The ticker is handled by the timer block invalidating the timer it is
    // handed once `self` has gone — see ServingModel.startMonitoring. The
    // listener needs the same treatment: it must NOT be stopped from a deinit.
    //
    // Note also PE finding B2: `stop()` must not unlink the socket node, or an
    // orphaned model deletes the LIVE instance's socket and kills ingest for
    // the whole session while the panel still reports "wired".
```

Replace `refresh()`:

```swift
    /// Re-samples power, retires silent sessions, and reconciles the assertion.
    ///
    /// Expiry happens HERE rather than in `ingest` because design §5 requires
    /// it on a timer: a crashed agent sends no event, so an expiry that only
    /// runs on the next event never runs at all.
    public func refresh() {
        let instant = now()
        sessions = SessionHub.expiring(sessions, now: instant, policy: policy)
        attention = AttentionList.rows(from: sessions)

        reading = reader.read()
        let state = controller.evaluate(powerSource: reading.source,
                                        batteryPercent: reading.percent,
                                        sessions: sessions)
        desired = state
        suppression = Self.reason(controller.lastSuppression, stillTrueOf: reading)

        if state.idleSleepAssertion {
            isServing = holder.acquire()
        } else {
            holder.release()
            isServing = false
        }
    }

    /// Applies one hook event and reconciles immediately.
    ///
    /// Immediately, not on the next tick: a 30-second delay between an agent
    /// starting work and the machine staying awake is a 30-second window in
    /// which it can fall asleep.
    public func ingest(_ event: HookEvent) {
        sessions = SessionHub.apply(event, to: sessions, now: now())
        refresh()
    }
```

Make `startMonitoring` also start the listener:

```swift
    public func startMonitoring(interval: TimeInterval = 30) throws {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // `assumeIsolated` is sound here ONLY because the listener delivers on
        // the main thread. `UnixSocketIngestListener` starts on
        // `DispatchQueue.main` for this reason, and
        // `deliveryHappensOnTheMainThread` holds that line. Delivering from any
        // other queue makes this TRAP at runtime.
        try listener.start { [weak self] event in
            MainActor.assumeIsolated { self?.ingest(event) }
        }
    }
```

`AttentionList` arrives in Task 8. Until then use this placeholder in `refresh`
and delete it in Task 8:

```swift
        attention = sessions.filter { SessionState.attentionStates.contains($0.state) }
```

- [ ] **Step 7: Update `main.swift` for the throwing call**

`Sources/CoffeeBarApp/main.swift:22` calls `model.startMonitoring()`. Replace:

```swift
        // Ingest failing must not stop the app launching. The panel says so
        // instead — see the hook health check.
        do {
            try model.startMonitoring()
        } catch {
            NSLog("coffee-bar: ingest did not start: \(error)")
        }
```

`main.swift` gains no new import: `NSLog` comes from Foundation, which SwiftUI
re-exports. **Confirm that with `swift build`, not by reading.** Add
`import Foundation` if the build says otherwise.

- [ ] **Step 8: Run the whole suite**

Run: `swift build && swift build -c release && swift test`
Expected: zero warnings, all green, and the total has grown.

Run: `swift test --filter AppLayerBoundary`
Expected: PASS, 4 tests. A zero count means the filter matched nothing.

- [ ] **Step 9: Mutation-check the wiring**

| # | Mutant | Test that must go RED |
|---|---|---|
| 1 | Drop `sessions: sessions` from the `evaluate` call | `aWorkingSessionHoldsTheAssertionWithNoUserToggle` |
| 2 | Move the `expiring` call from `refresh` into `ingest` | `aSilentSessionStopsHoldingWhenTheTimerFires` |
| 3 | Delete `listener.stop()` from the `deinit` | `aModelThatGoesAwayStopsItsListener` |
| 4 | Delete the `try listener.start` from `startMonitoring` | `aWorkingSessionHoldsTheAssertionWithNoUserToggle` |
| 5 | Add a file `Sources/CoffeeBarIngest/Escape.swift` | `theAppLayerHoldsExactlyTheFilesThisGuardScans` |

Mutant 5 proves the boundary guard now actually reaches the new target. Without
it, adding `CoffeeBarIngest` to `appLayerDirectories` is unverified.

- [ ] **Step 10: Commit**

```bash
git add Package.swift Sources/CoffeeBarUI/ServingModel.swift Sources/CoffeeBarApp/main.swift Tests/CoffeeBarUITests
git commit -s -S -m "feat(ui): drive the assertion from live Claude Code sessions"
```

**Acceptance:** an agent event holds the assertion with the toggle untouched. A
`Stop` releases it. A silent session releases it on the ticker, not only on the
next event. The model's `deinit` stops the listener. The boundary guard scans
`CoffeeBarIngest` and is proved to by a planted file.

---

### Task 7: The settings.json health check

**Files:**
- Create: `Sources/CoffeeBarCore/HookHealth.swift`
- Create: `Sources/CoffeeBarIngest/HookHealthReader.swift`
- Create: `Tests/Fixtures/claude-settings/wired.json`
- Create: `Tests/Fixtures/claude-settings/missing-stop.json`
- Create: `Tests/Fixtures/claude-settings/no-hooks.json`
- Create: `Tests/Fixtures/claude-settings/malformed.json`
- Test: `Tests/CoffeeBarCoreTests/HookHealth_test.swift`
- Test: `Tests/CoffeeBarIngestTests/HookHealthReader_test.swift`
- Modify: `Sources/CoffeeBarUI/ServingModel.swift`
- Modify: `Tests/CoffeeBarUITests/AppLayerBoundary_test.swift`

**Interfaces:**
- Consumes: `HookEventKind` (Task 2).
- Produces: `HookHealth`, `HookHealthStatus`, `HookHealthReader`.

Depends on Task 6.

Design §6: coffee-bar **prints** the snippet and **never writes**
`~/.claude/settings.json`. It **reads** the file to check its own entries are
there, so silent failure becomes visible failure with no clobber risk.

The parse is pure and lives in Core. The file read lives in Ingest, so Core
keeps its no-I/O rule.

- [ ] **Step 1: Write the fixtures**

Create four files under `Tests/Fixtures/claude-settings/`. Real shapes, not
minimal ones — the parser must survive a settings file with other people's hooks
in it.

`wired.json`:

```json
{
  "model": "opus",
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "/opt/other/thing.sh"}]},
      {"hooks": [{"type": "command", "command": "curl -sS --unix-socket \"$HOME/Library/Application Support/coffee-bar/ingest.sock\" -X POST --data-binary @- http://localhost/ingest"}]}
    ],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "curl -sS --unix-socket \"$HOME/Library/Application Support/coffee-bar/ingest.sock\" -X POST --data-binary @- http://localhost/ingest"}]}],
    "PostToolUse": [{"hooks": [{"type": "command", "command": "curl -sS --unix-socket \"$HOME/Library/Application Support/coffee-bar/ingest.sock\" -X POST --data-binary @- http://localhost/ingest"}]}],
    "PermissionDenied": [{"hooks": [{"type": "command", "command": "curl -sS --unix-socket \"$HOME/Library/Application Support/coffee-bar/ingest.sock\" -X POST --data-binary @- http://localhost/ingest"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "curl -sS --unix-socket \"$HOME/Library/Application Support/coffee-bar/ingest.sock\" -X POST --data-binary @- http://localhost/ingest"}]}]
  }
}
```

`missing-stop.json` is `wired.json` with the `Stop` key removed.

`no-hooks.json`:

```json
{"model": "opus"}
```

`malformed.json`:

```
{"hooks": {"Stop": [ this is not json
```

- [ ] **Step 2: Write the failing test**

Create `Tests/CoffeeBarCoreTests/HookHealth_test.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

// Design §6 is explicit: read a fixture from disk, do not assert against a
// hand-built string that duplicates the parser's own logic.
private func settings(_ name: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/claude-settings/\(name)"))
}

@Test func aFullyWiredSettingsFileReportsWired() throws {
    #expect(try HookHealth.status(ofSettings: settings("wired.json")) == .wired)
}

@Test func aMissingEventIsNamed() throws {
    // The user has to know WHICH entry to paste back. "Ingest is broken" sends
    // them to re-paste all five and risk clobbering the other four.
    #expect(try HookHealth.status(ofSettings: settings("missing-stop.json"))
            == .missing(["Stop"]))
}

@Test func aSettingsFileWithNoHooksNamesEveryRequiredEvent() throws {
    #expect(try HookHealth.status(ofSettings: settings("no-hooks.json"))
            == .missing(HookHealth.requiredEvents))
}

@Test func aMalformedSettingsFileIsReportedNotCrashed() throws {
    // Someone else's editor half-wrote the file. The panel must say so, not
    // die, and must not claim the hooks are missing — that would send the user
    // to paste entries that are already there.
    #expect(try HookHealth.status(ofSettings: settings("malformed.json"))
            == .unreadable)
}

@Test func anAbsentSettingsFileIsReportedNotCrashed() {
    #expect(HookHealth.status(ofSettings: nil) == .unreadable)
}

@Test func anEntryPointingSomewhereElseDoesNotCount() {
    // Named bug this catches: matching on the EVENT KEY rather than on the
    // command. Another tool's SessionStart hook would then satisfy our check,
    // the panel would report healthy, and no event would ever arrive.
    let raw = Data("""
        {"hooks": {"Stop": [{"hooks": [{"type":"command","command":"/opt/other/thing.sh"}]}]}}
        """.utf8)
    let status = HookHealth.status(ofSettings: raw)
    #expect(status != .wired)
    if case .missing(let events) = status {
        #expect(events.contains("Stop"))
    } else {
        Issue.record("expected .missing, got \(status)")
    }
}

@Test func theRequiredEventsAreTheOnesTheHubActsOn() {
    // Ties the health check to the state machine. Named bug this catches: the
    // hub gaining an event while the check keeps asking for the old five, so a
    // half-installed hook set reports healthy.
    //
    // PreCompact is excluded because SessionHub maps it to nothing, and
    // SessionEnd because design §10.4 leaves it open.
    #expect(HookHealth.requiredEvents ==
            ["PermissionDenied", "PostToolUse", "PreToolUse", "SessionStart", "Stop"])
    for event in HookHealth.requiredEvents {
        #expect(HookEventKind(rawValue: event) != nil,
                "\(event) is required but SessionHub does not know it")
    }
}
```

Create `Tests/CoffeeBarIngestTests/HookHealthReader_test.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import CoffeeBarCore
@testable import CoffeeBarIngest

private var fixtures: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/claude-settings")
}

@Test func theReaderReportsWiredForARealFileOnDisk() {
    let reader = HookHealthReader(settingsURL: fixtures.appending(path: "wired.json"))
    #expect(reader.status() == .wired)
}

@Test func theReaderDoesNotCrashOnAnAbsentFile() {
    // A user who has never run Claude Code has no settings.json at all.
    let reader = HookHealthReader(
        settingsURL: fixtures.appending(path: "definitely-not-here.json"))
    #expect(reader.status() == .unreadable)
}

@Test func theReaderDoesNotCrashOnADirectory() {
    // `Data(contentsOf:)` on a directory throws rather than returning empty.
    let reader = HookHealthReader(settingsURL: fixtures)
    #expect(reader.status() == .unreadable)
}

@Test func theDefaultSettingsURLIsTheUsersClaudeSettings() {
    // Design §6 fixes the location. coffee-bar READS it and never writes it.
    #expect(HookHealthReader().settingsURL.path
        .hasSuffix("/.claude/settings.json"))
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter HookHealth`
Expected: FAIL — `cannot find 'HookHealth' in scope`.

`git add` both test files and the fixtures now.

- [ ] **Step 4: Write the implementation**

Create `Sources/CoffeeBarCore/HookHealth.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum HookHealthStatus: Equatable, Sendable {
    case wired
    /// Sorted event names, so the panel's line is stable between refreshes.
    case missing([String])
    /// The file is absent, unreadable, or not JSON. NOT the same as missing:
    /// telling the user to paste entries that are already there is how a
    /// settings file gets clobbered.
    case unreadable
}

/// Checks that the user's Claude Code settings still point at our socket.
///
/// Design §6: coffee-bar PRINTS the snippet and NEVER writes
/// `~/.claude/settings.json`. That file is shared territory, and this workspace
/// records a critical last-writer-wins clobber pattern in exactly it. Reading
/// costs nothing and turns silent failure into visible, recoverable failure.
///
/// Pure. The file read lives in `CoffeeBarIngest`.
public enum HookHealth {

    /// The events `SessionHub` acts on.
    ///
    /// `PreCompact` is excluded because the hub maps it to nothing. `SessionEnd`
    /// is excluded because design §10.4 leaves it open.
    public static let requiredEvents = ["PermissionDenied", "PostToolUse",
                                        "PreToolUse", "SessionStart", "Stop"]

    /// What an installed hook command must contain to be ours.
    ///
    /// Matched on the COMMAND, not on the event key: another tool's
    /// `SessionStart` hook must not make us report healthy while no event ever
    /// arrives.
    public static let commandMarker = "coffee-bar/ingest.sock"

    public static func status(ofSettings data: Data?) -> HookHealthStatus {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any]
        else {
            // A file with no `hooks` key at all is READABLE and simply has no
            // entries, so it reports missing rather than unreadable.
            if let data,
               (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] != nil {
                return .missing(requiredEvents)
            }
            return .unreadable
        }

        let missing = requiredEvents.filter { !isWired(hooks[$0]) }.sorted()
        return missing.isEmpty ? .wired : .missing(missing)
    }

    /// The settings shape is `hooks.<Event>[].hooks[].command`.
    private static func isWired(_ entry: Any?) -> Bool {
        guard let matchers = entry as? [[String: Any]] else { return false }
        for matcher in matchers {
            guard let commands = matcher["hooks"] as? [[String: Any]] else { continue }
            for command in commands {
                if let text = command["command"] as? String,
                   text.contains(commandMarker) {
                    return true
                }
            }
        }
        return false
    }
}
```

Create `Sources/CoffeeBarIngest/HookHealthReader.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoffeeBarCore

/// Reads `~/.claude/settings.json` and reports whether our hooks are installed.
///
/// **This type only ever reads.** Design §6 forbids writing that file, and the
/// snippet is printed for the user to paste.
public struct HookHealthReader: Sendable {
    public let settingsURL: URL

    public init(settingsURL: URL = HookHealthReader.defaultSettingsURL) {
        self.settingsURL = settingsURL
    }

    public static var defaultSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/settings.json")
    }

    public func status() -> HookHealthStatus {
        HookHealth.status(ofSettings: try? Data(contentsOf: settingsURL))
    }
}
```

- [ ] **Step 5: Publish the status from the model**

In `Sources/CoffeeBarUI/ServingModel.swift`, add the stored property and read it
in `refresh()`:

```swift
    private let health: HookHealthReader

    /// Whether the user's Claude Code hooks still point at our socket.
    public private(set) var hookHealth: HookHealthStatus = .unreadable
```

Add `health: HookHealthReader = HookHealthReader()` to the initializer, and in
`refresh()`:

```swift
        hookHealth = health.status()
```

- [ ] **Step 6: Update the app-layer boundary guard again**

`HookHealthReader.swift` is a new file inside a scanned directory. Add it to
`expectedAppLayerEntries`, in the position Swift's `sorted()` puts it:

```swift
private let expectedAppLayerEntries = [
    "Sources/CoffeeBarApp/main.swift",
    "Sources/CoffeeBarIngest/HTTPRequestFramer.swift",
    "Sources/CoffeeBarIngest/HookHealthReader.swift",
    "Sources/CoffeeBarIngest/IngestListener.swift",
    "Sources/CoffeeBarUI/MenuBarGlyphs.swift",
    "Sources/CoffeeBarUI/PanelView.swift",
    "Sources/CoffeeBarUI/ServingModel.swift",
]
```

`"HTTPRequestFramer.swift"` sorts before `"HookHealthReader.swift"` because `T`
precedes `o`. That order was produced by Swift's own `sorted()`, not reasoned
about.

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --filter HookHealth`
Expected: PASS, 11 tests. Confirm the count.

Run: `swift build && swift build -c release && swift test`
Expected: zero warnings, all green.

- [ ] **Step 8: Mutation-check the health check**

| # | Mutant | Test that must go RED |
|---|---|---|
| 1 | Match on the event key only; drop the `commandMarker` check | `anEntryPointingSomewhereElseDoesNotCount` |
| 2 | Return `.missing` rather than `.unreadable` for bad JSON | `aMalformedSettingsFileIsReportedNotCrashed` |
| 3 | Drop `"Stop"` from `requiredEvents` | `aMissingEventIsNamed` and `theRequiredEventsAreTheOnesTheHubActsOn` |
| 4 | Delete `.sorted()` from the `missing` list | Add a second missing event to a fixture first, then `aMissingEventIsNamed` |
| 5 | `commandMarker` → `"curl"` | `anEntryPointingSomewhereElseDoesNotCount` fails only if the other-tool fixture command contains `curl`; **change `/opt/other/thing.sh` to a curl command in that test before trusting this mutant** |

Mutant 5 is written out because it is the one that could pass vacuously. Check
the fixture actually exercises it before recording a result.

- [ ] **Step 9: Commit**

```bash
git add Sources/CoffeeBarCore/HookHealth.swift Sources/CoffeeBarIngest/HookHealthReader.swift Sources/CoffeeBarUI/ServingModel.swift Tests/Fixtures/claude-settings Tests/CoffeeBarCoreTests/HookHealth_test.swift Tests/CoffeeBarIngestTests/HookHealthReader_test.swift Tests/CoffeeBarUITests/AppLayerBoundary_test.swift
git commit -s -S -m "feat(ingest): report when the Claude Code hooks are not installed"
```

**Acceptance:** the check reports wired for a wired fixture, names the missing
event for a partial one, and reports unreadable for an absent or malformed file
without crashing. It matches on the command, not on the event key. It never
writes `~/.claude/settings.json`.

---

### Task 8: The attention list in the panel

**Files:**
- Create: `Sources/CoffeeBarCore/AttentionList.swift`
- Create: `Sources/CoffeeBarUI/AttentionListView.swift`
- Test: `Tests/CoffeeBarCoreTests/AttentionList_test.swift`
- Modify: `Sources/CoffeeBarUI/PanelView.swift`
- Modify: `Sources/CoffeeBarUI/ServingModel.swift` (delete the Task 6 placeholder)
- Modify: `Tests/CoffeeBarUITests/AppLayerBoundary_test.swift`

**Interfaces:**
- Consumes: `AgentSession`, `SessionState.attentionStates` (Task 3), `HookHealthStatus` (Task 7).
- Produces: `AttentionList.rows(from:)`, `AttentionListView`.

Depends on Tasks 6 and 7. **Design §10.3 is open — what this shows and how it
orders are provisional.**

The ordering rule lives in Core, so it tests with no view. The view renders it.

- [ ] **Step 1: Write the failing test**

Create `Tests/CoffeeBarCoreTests/AttentionList_test.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func session(_ state: SessionState,
                     id: String,
                     attentionSince: Date? = nil) -> AgentSession {
    AgentSession(tool: .claudeCode, sessionID: id, cwd: nil, repoName: nil,
                 pid: nil, state: state, stateEnteredAt: t0, lastEventAt: t0,
                 lastMessage: nil, attentionSince: attentionSince, turnCount: 0)
}

@Test func onlyTheAttentionStatesAppear() {
    let all = SessionState.allCases.map {
        session($0, id: $0.rawValue, attentionSince: t0)
    }
    let rows = AttentionList.rows(from: all)
    #expect(Set(rows.map(\.state)) == SessionState.attentionStates)
    #expect(rows.count == 2)
}

@Test func theLongestWaitComesFirst() {
    // The list exists to answer "what is waiting on me". The thing waiting
    // longest is the answer, so it goes at the top.
    let rows = AttentionList.rows(from: [
        session(.awaitingInput, id: "recent", attentionSince: t0.addingTimeInterval(500)),
        session(.awaitingPermission, id: "old", attentionSince: t0),
        session(.awaitingInput, id: "middle", attentionSince: t0.addingTimeInterval(100)),
    ])
    #expect(rows.map(\.sessionID) == ["old", "middle", "recent"])
}

@Test func theOrderIsTotalSoTiesDoNotShuffle() {
    // Named bug this catches: a sort with no tie-break. Two sessions blocked in
    // the same instant would then swap places between refreshes, under the
    // user's cursor, while every other test in this file stayed green.
    let rows = AttentionList.rows(from: [
        session(.awaitingInput, id: "zeta", attentionSince: t0),
        session(.awaitingInput, id: "alpha", attentionSince: t0),
    ])
    #expect(rows.map(\.sessionID) == ["alpha", "zeta"])

    let reversed = AttentionList.rows(from: [
        session(.awaitingInput, id: "alpha", attentionSince: t0),
        session(.awaitingInput, id: "zeta", attentionSince: t0),
    ])
    #expect(rows.map(\.sessionID) == reversed.map(\.sessionID),
            "input order changed the output order")
}

@Test func aSessionWithNoAttentionStampSortsLast() {
    // `attentionSince` is nil only for a session built before it entered an
    // attention state. It must not sort to the top as "waiting since forever".
    let rows = AttentionList.rows(from: [
        session(.awaitingInput, id: "unstamped", attentionSince: nil),
        session(.awaitingInput, id: "stamped", attentionSince: t0),
    ])
    #expect(rows.map(\.sessionID) == ["stamped", "unstamped"])
}

@Test func anEmptyInputGivesAnEmptyList() {
    #expect(AttentionList.rows(from: []).isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AttentionList`
Expected: FAIL — `cannot find 'AttentionList' in scope`.

`git add Tests/CoffeeBarCoreTests/AttentionList_test.swift` now.

- [ ] **Step 3: Write the ordering rule**

Create `Sources/CoffeeBarCore/AttentionList.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What the panel shows under "waiting on you".
///
/// Design §10.3 leaves the contents and the ordering OPEN. This is the
/// provisional answer: the two attention states only, longest wait first.
///
/// The rule lives here rather than in the view so it tests with no SwiftUI, and
/// so the panel cannot quietly disagree with the broker about which states are
/// attention states — `SessionState.attentionStates` is the single source.
public enum AttentionList {

    public static func rows(from sessions: [AgentSession]) -> [AgentSession] {
        sessions
            .filter { SessionState.attentionStates.contains($0.state) }
            .sorted { left, right in
                // A total order. Without the `id` tie-break the sort is not
                // stable across calls, and two sessions blocked in the same
                // instant swap places under the user's cursor on every refresh.
                //
                // `nil` sorts LAST: an unstamped session is not "waiting since
                // the beginning of time".
                switch (left.attentionSince, right.attentionSince) {
                case let (l?, r?) where l != r: return l < r
                case (nil, _?): return false
                case (_?, nil): return true
                default: return left.id < right.id
                }
            }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AttentionList`
Expected: PASS, 5 tests. Confirm the count.

- [ ] **Step 5: Use it in the model**

In `Sources/CoffeeBarUI/ServingModel.swift`, replace the Task 6 placeholder with
the real call:

```swift
        attention = AttentionList.rows(from: sessions)
```

Verify the after-state:
`grep -n "AttentionList.rows" Sources/CoffeeBarUI/ServingModel.swift` must print
one line, and `grep -c "attentionStates" Sources/CoffeeBarUI/ServingModel.swift`
must print `0`.

- [ ] **Step 6: Write the view**

Create `Sources/CoffeeBarUI/AttentionListView.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import CoffeeBarCore

/// The sessions blocked on the human, and whether ingest is wired up at all.
///
/// `Text(verbatim:)` for `lastMessage`, deliberately. Design §7 calls that text
/// attacker-influenced, and `verbatim` renders it as characters rather than
/// letting anything interpret it as markup.
struct AttentionListView: View {
    let sessions: [AgentSession]
    let health: HookHealthStatus

    /// Rendered from the enum, never from free text, so what the panel says is
    /// what the check decided.
    private var healthLine: String? {
        switch health {
        case .wired:
            return nil
        case .missing(let events):
            return "Not receiving \(events.joined(separator: ", ")). "
                 + "Re-add the coffee-bar hooks to ~/.claude/settings.json."
        case .unreadable:
            return "Cannot read ~/.claude/settings.json, so agent sessions may not arrive."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let line = healthLine {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if sessions.isEmpty {
                Text("Nothing waiting on you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sessions) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: session.repoName ?? session.sessionID)
                            .font(.caption).bold()
                        Text(session.state == .awaitingPermission
                             ? "waiting for permission" : "waiting for you")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let message = session.lastMessage {
                            Text(verbatim: message)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 7: Add it to the panel**

In `Sources/CoffeeBarUI/PanelView.swift`, insert between the battery `Label` and
the final `Divider`:

```swift
            Divider()

            AttentionListView(sessions: model.attention, health: model.hookHealth)
```

- [ ] **Step 8: Update the app-layer boundary guard a third time**

```swift
private let expectedAppLayerEntries = [
    "Sources/CoffeeBarApp/main.swift",
    "Sources/CoffeeBarIngest/HTTPRequestFramer.swift",
    "Sources/CoffeeBarIngest/HookHealthReader.swift",
    "Sources/CoffeeBarIngest/IngestListener.swift",
    "Sources/CoffeeBarUI/AttentionListView.swift",
    "Sources/CoffeeBarUI/MenuBarGlyphs.swift",
    "Sources/CoffeeBarUI/PanelView.swift",
    "Sources/CoffeeBarUI/ServingModel.swift",
]
```

That is the final list, and it is what Swift's `[String].sorted()` produced.

- [ ] **Step 9: Run the whole suite**

Run: `swift build && swift build -c release && swift test`
Expected: zero warnings, all green.

- [ ] **Step 10: Mutation-check the ordering**

| # | Mutant | Test that must go RED |
|---|---|---|
| 1 | Delete the `id` tie-break; return `false` in the `default` branch | `theOrderIsTotalSoTiesDoNotShuffle` |
| 2 | `case (nil, _?): return false` → `return true` | `aSessionWithNoAttentionStampSortsLast` |
| 3 | `l < r` → `l > r` | `theLongestWaitComesFirst` |
| 4 | Filter on `$0.state != .working` instead of `attentionStates` | `onlyTheAttentionStatesAppear` |

- [ ] **Step 11: Commit**

```bash
git add Sources/CoffeeBarCore/AttentionList.swift Sources/CoffeeBarUI Tests/CoffeeBarCoreTests/AttentionList_test.swift Tests/CoffeeBarUITests/AppLayerBoundary_test.swift
git commit -s -S -m "feat(ui): show the sessions waiting on the user, and whether ingest is wired"
```

**Acceptance:** only the two attention states appear, longest wait first, with a
total order. The panel names a missing hook entry. `lastMessage` renders through
`Text(verbatim:)`.

---

### Task 9: Manual acceptance on real hardware

**Files:** none. This task produces a record, not code.

Design §12 lists five acceptance criteria. **None can be checked by the test
suite.** M1 shipped a first-run defect that 203 green tests said nothing about,
because `LSUIElement=true` means the app has no window and no Dock icon.

- [ ] **Step 1: Build the bundle**

Run: `scripts/build-app.sh && open build/CoffeeBar.app`

- [ ] **Step 2: Install the ingest hooks**

Print the snippet and give it to the user to paste into
`~/.claude/settings.json`. **coffee-bar does not write that file.** The command
for each of the five events:

```
curl -sS --unix-socket "$HOME/Library/Application Support/coffee-bar/ingest.sock" \
  -X POST --data-binary @- http://localhost/ingest
```

Confirm the socket exists and is `0600` first:

```bash
ls -l "$HOME/Library/Application Support/coffee-bar/ingest.sock"
```
Expected: a line starting `srw-------`.

And the directory:

```bash
ls -ld "$HOME/Library/Application Support/coffee-bar"
```
Expected: a line starting `drwx------`.

- [ ] **Step 3: Run the acceptance checks**

Record the ACTUAL output of each, not the expected output.

1. Start a Claude Code session and give it work. The menu-bar glyph changes to
   serving **without the user touching the toggle**.
2. While the agent works:
   `pmset -g assertions | grep -i coffee-bar`
   Expected: a line naming `coffee-bar is serving`.
3. Let the agent finish its turn and wait for input. Re-run the same command.
   Expected: no output. The machine now sleeps while it waits for the human.
4. At every point above:
   `pmset -g assertions | grep -i PreventUserIdleDisplaySleep`
   Expected: no line attributable to coffee-bar. Design §12 keeps this invariant.
5. Start work again, then `kill -9` the Claude Code process. Wait for the stale
   timeout, then re-run the command from step 2.
   Expected: no output. The assertion released with no session-end event.
6. Remove the hook entries from `~/.claude/settings.json` and open the panel.
   Expected: the panel names the missing events.

- [ ] **Step 4: Write the results into the handoff**

Record every command's real output. **A step that was not run is recorded as not
run.** Do not carry an expected value forward as a result.

**Acceptance:** all six checks recorded with real output. No
`PreventUserIdleDisplaySleep` at any point.

---

## Documentation this plan does NOT cover

**`SECURITY.md` does not exist on this branch.** Design §4.1 requires it to
describe the listener. Verified:

```
$ git ls-files | grep -i security
(no output)
$ git ls-tree -r --name-only origin/feat/m4-repo-hygiene | grep -i security
SECURITY.md
```

The file lives only on the unmerged `feat/m4-repo-hygiene` branch. **The
`SECURITY.md` update is therefore an M4 task, not an M2 one**, and it must land
before M4 merges. Writing a new `SECURITY.md` here would create the
last-writer-wins conflict this workspace has recorded six times.

`README.md` must not gain Codex or Cursor language. Design §1 and
`docs/ROADMAP.md:98` put those in v0.2.

---

## Plan self-review

### Identifiers grepped against the tree

Every new identifier was grepped across `Sources`, `Tests` and `Package.swift`
before it was written into this plan. The M1 plan shipped a type name that
already existed and did not compile.

```
$ for id in SessionHub HookEvent IngestEvent IngestListener CoffeeBarIngest \
    HookHealth AttentionList SessionsView IngestSocket HookInstallation \
    SessionEvent StaleTimeout ClaudeHookEvent SessionSnapshot AttentionRow \
    IngestServer SocketListener; do
    echo "$id: $(grep -rn "$id" Sources Tests Package.swift | wc -l)"
  done
SessionHub: 0        HookEvent: 0         IngestEvent: 0       IngestListener: 0
CoffeeBarIngest: 0   HookHealth: 0        AttentionList: 0     SessionsView: 0
IngestSocket: 0      HookInstallation: 0  SessionEvent: 0      StaleTimeout: 0
ClaudeHookEvent: 0   SessionSnapshot: 0   AttentionRow: 0      IngestServer: 0
SocketListener: 0
```

All zero. Nothing this plan introduces collides with a name already in the tree.
`StalePolicy`, `HookEventKind`, `HTTPRequestFramer`, `HookHealthReader`,
`UnixSocketIngestListener`, `IngestError`, `IngestListening`,
`AttentionListView` and `NoopIngestListener` were covered by the same sweep
through their stems (`Stale`, `Hook`, `Ingest`, `Attention`).

### Existing declarations read, not remembered

Every signature this plan calls was read from the file, and the argument labels
copied.

| Symbol | Read at | Consumed by |
|---|---|---|
| `AgentSession.init(tool:sessionID:cwd:repoName:pid:state:stateEnteredAt:lastEventAt:lastMessage:attentionSince:turnCount:)` | `Sources/CoffeeBarCore/AgentSession.swift:51` | Tasks 3, 4 |
| `AgentSession.id` = `"\(tool.rawValue):\(sessionID)"` | `AgentSession.swift:49` | Task 3 |
| `SessionState` — 7 cases | `AgentSession.swift:19` | Tasks 3, 4, 8 |
| `AgentTool` — 3 cases | `AgentSession.swift:7` | Task 3 |
| `PowerInputs.init(sessions:powerSource:batteryPercent:userIntent:holdAwakeWhileBlocked:batteryFloorPercent:)` | `PowerBroker.swift:18` | Task 4 test |
| `PowerBroker.decide(_:)` and `activeStates(holdAwakeWhileBlocked:)` | `PowerBroker.swift:63`, `:57` | Tasks 3, 4 |
| `PowerBroker` OR at `wantsHold` | `PowerBroker.swift:70` | D1 |
| `HoldController.evaluate(powerSource:batteryPercent:sessions:holdAwakeWhileBlocked:batteryFloorPercent:)` | `HoldController.swift:31` | Task 6 |
| `ServingModel.init(holder:reader:)`, `refresh()`, `startMonitoring(interval:)`, `isolated deinit` | `ServingModel.swift:58`, `:79`, `:132`, `:66` | Tasks 6, 7 |
| `AssertionHolding` — `acquire() -> Bool`, `release()` | `AssertionHolding.swift:14` | Task 6 test |
| `PowerReadingProviding.read() -> PowerReading` | `SystemPowerReader.swift` | Task 6 test |
| `appLayerDirectories`, `expectedAppLayerEntries`, `manifestDependencies` | `AppLayerBoundary_test.swift:41`, `:53`, `:151` | Tasks 6, 7, 8 |
| `theModelInvalidatesItsTimerWhenItGoesAway` | `ServingModel_test.swift:282` | Task 6 step 5 |
| `evaluateForwardsTheSessionsAndTheKnobToTheBroker` | `HoldController_test.swift:82` | Task 6 |

**`ServingModel` lives in `Sources/CoffeeBarUI/`, not `Sources/CoffeeBarApp/`.**
The M1 plan put it in the executable; the `CoffeeBarUI` split happened during
execution and is not in that plan.

### Commands run, with real output

| Claim | Command | Result |
|---|---|---|
| The base is green | `swift test` | `Test run with 209 tests in 3 suites passed` |
| The base builds | `swift build` | `Build complete!` |
| `--filter` exits 0 on no match | `swift test --filter ThisTestDoesNotExistAnywhere` | `Test run with 0 tests in 0 suites passed` |
| D1 costs 8 tests | mutant + `swift test` | 8 tests named, 13 issues; reverted, back to 209 |
| `SessionEnd` exists | `strings` on the CLI | `hook_event_name:"SessionEnd",reason:e` |
| The unix listener works | spike + `curl --unix-socket` | `http_code=204`, request body received |
| The socket ends at 0600 | `ls -l` on the spike socket | `srw-------` |
| A bare bind is 0755 | `python3` bind + `os.stat` | `755` |
| `sun_path` is 104 | `grep sys/un.h` | `char sun_path[104];` |
| The production path fits | length of the real path | `66` |
| Fixtures at `Tests/Fixtures` are silent | `touch Package.swift && swift build` | no warning; a loose file inside a target DOES warn |
| `Text(verbatim:)` + `ForEach` compile | `swiftc -swift-version 6` | object file produced |
| The listener seam compiles | `swiftc -swift-version 6` | `isolated deinit` + `assumeIsolated` clean |
| The framer behaves as its tests assert | compiled + run | all 6 outcomes true, including the 20/60/rest split |
| The attention sort behaves as its tests assert | compiled + run | `["alpha", "zeta", "recent", "unstamped"]` |
| The sorted entry list | `[String].sorted()` in Swift | the exact list in Tasks 6, 7, 8 |
| `SECURITY.md` is absent here | `git ls-files` | no match; present on `feat/m4-repo-hygiene` |

### Spec coverage

| Design section | Task |
|---|---|
| §1 scope — no Codex, no Cursor, no root | Nothing added; noted in "Documentation this plan does NOT cover" |
| §2 do not reshape the broker | Task 6 supplies `sessions:` to an unchanged signature |
| §3 the hook contract | Task 1 captures it; Task 2 decodes it |
| §3.1 the mapping | Task 3, one fixture-driven test per row |
| §3.2 nothing reports session end | Task 3 writes no `.done` without a fixture; Task 4 is the retirement path |
| §4 unix socket, 0600 | Task 5, proved by a spike |
| §4.1 residual risk | Task 5 doc comment; the 0700 directory closes the measured bind race |
| §5 staleness is safety | Task 4, both sides of both boundaries; Task 6 puts it on the existing ticker |
| §6 print, never write | Task 7; `HookHealthReader` only reads |
| §7 privacy boundary | Task 2, structural absence plus a scan with a positive control; §7's 140-char cap in Task 3 |
| §8 target layout | Task 5 adds `CoffeeBarIngest`; Core stays Foundation-only |
| §9 fixtures first | Task 1 gates every later task |
| §10.1 to §10.4 | D1 to D4 above; D1 blocks Task 6 |
| §12 acceptance | Task 9 |

### Gaps found and closed while writing this

1. **The app-layer boundary guard breaks on a new target, by design.** Nothing
   in the spec mentions it. Tasks 6, 7 and 8 each update it, with the exact
   sorted list Swift produces.
2. **A bare unix bind is world-connectable until the chmod lands.** Not in the
   spec — found by measuring. The 0700 parent directory in Task 5 closes it.
3. **`sun_path` is 104 bytes.** Not in the spec. The listener refuses an
   over-long path, and the tests must use a short temp path or they will fail on
   a machine with a longer temp root.
4. **The default listener would bind the real socket during `swift test`.** Task
   6 step 5 fixes the one existing test that calls `startMonitoring`, and says
   why the default stays real.
5. **`SECURITY.md` does not exist on this branch.** Design §4.1 assumes it does.
   Moved to M4 rather than created here.
6. **`MainActor.assumeIsolated` traps if the listener delivers off the main
   queue.** A runtime crash, not a warning. `deliveryHappensOnTheMainThread`
   guards it.

### Placeholder scan

No TBD. No "handle edge cases". No "similar to Task N". Every implementation
step carries the code it asks for. Two deliberate conditionals, both stated as
conditions rather than left open:

- Task 3's `SessionEnd` test and the `.sessionEnd` branch exist **only if** Task
  1 captures that payload.
- Task 6 is **blocked** until D1 is answered, and says what changes under each
  answer.

Task 6 carries a placeholder line for `attention`, and Task 8 step 5 deletes it
with a `grep` that proves the deletion landed.

### Type consistency

`HookEvent` is defined in Task 2 and consumed with the same spelling in Tasks 3,
5 and 6. `HookEventKind` is defined in Task 2 and read in Tasks 3 and 7.
`SessionState.attentionStates` is defined in Task 3 and read in Tasks 6 and 8.
`StalePolicy` is defined in Task 4 and consumed in Task 6. `IngestListening` is
defined in Task 5 and implemented by three types: `UnixSocketIngestListener`
(Task 5), `FakeListener` and `NoopIngestListener` (Task 6). `HookHealthStatus`
is defined in Task 7 and rendered in Task 8. `SessionHub.expiring` is declared
in Task 4 with the argument labels Task 6 calls it with:
`(_:now:policy:)`.

### What this plan could NOT verify

- **Every fixture filename** in Tasks 3 and 7 (`session-start-startup.json`,
  `pre-tool-use.json`, `stop.json`, and so on). Task 1 has not run, so these are
  named, not observed. **Task 3 must be re-read against the real corpus before
  it starts**, and any name corrected there.
- **Whether `SessionEnd` actually fires.** The binary carries the string and the
  dispatch function. Only Task 1 settles it.
- **The exact common fields of a payload.** Design §3 lists them from a
  different reading of the same machine. Task 2's `CodingKeys` are checked by
  `everyCapturedPayloadDecodes` against the real bytes, which is where a wrong
  key name fails.
- **The listener under two concurrent connections.** The spike posted one
  request. `NWListener` serialises new connections onto its queue, so this
  should hold, but it was not measured.
- **`main.swift` needing `import Foundation` for `NSLog`.** Task 6 step 7 says
  to confirm with the build rather than assume.
