# M2 Audit Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close all 23 confirmed findings from the M2 whole-branch adversarial audit so v0.1 can ship.

**Architecture:** Fixes are grouped by the file they touch, not by severity, because four findings land in `IngestListener.swift` and three in `ServingModel.swift`. Each task ends with a test that goes RED before the fix and GREEN after. Where a finding is a missing guard rather than a defect, the deliverable is the guard plus proof it discriminates.

**Tech Stack:** Swift 6, SwiftPM, swift-testing (`@Test`/`@Suite`), IOKit, Network.framework, AF_UNIX sockets.

## Global Constraints

- **Swift language mode `.v6`** on every target. Strict concurrency.
- **CI is Swift 6.1.2 / macOS 15.** This machine is 6.3.3 / macOS 26. Anything newer than 6.1.2 fails CI. `isolated deinit` is experimental before 6.3 — do not use it.
- **Platform floor is `.macOS(.v14)`** (`Package.swift:6`).
- **The central invariant:** the app holds `PreventUserIdleSystemSleep` and NEVER a display assertion.
- **The privacy invariant:** `last_assistant_message` and `transcript_path` never reach a stored property, a log line, or a rendered string.
- **Run the FULL suite**, never `--filter`, before any commit. A filtered green has hidden a real break four times on this project.
- **Run every `swift` command with the sandbox DISABLED.**
- **Never gate on a piped exit code.** `cmd > /tmp/out 2>&1; rc=$?`, then inspect.
- **Commits are signed:** `git commit -s -S`.
- **Post nothing outward.** No `git push`, no `gh`. Carlos owns every outward action.
- **Prove every mutant applied AND compiled** before believing a RED. Print the diff. This project made the "red suite proves the compiler works" mistake three times.

## Execution method: solo (subagent-driven, sequential)

**NOT team.** `IngestListener.swift` is touched by Tasks 2, 3, 6 and 7; `ServingModel.swift` by Tasks 6 and 9. Shared files mean parallel worktrees would conflict. Run one task at a time with a review gate between.

## Baseline warning — the suite is not deterministically green

`realRunnerRunsItsReadersWithoutAFreeSharedPoolWorker` (`Tests/CoffeeBarPowerTests/SleepDisabledController_test.swift:248`) fails about 6% of full-suite runs (2 of 33 measured). **Task 8 fixes it. Until Task 8 lands, a single red run is not necessarily your change** — re-run before you debug. Do not "fix" an unrelated test to chase it.

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `Tests/Fixtures/claude-hooks/permission-denied.json` | Redacted hook fixture | 1 |
| `Tests/CoffeeBarIngestTests/FixtureRedaction_test.swift` | NEW — guards every fixture | 1 |
| `Sources/CoffeeBarIngest/IngestListener.swift` | Socket lifecycle, connection state | 2, 3, 6, 7 |
| `Sources/CoffeeBarIngest/HTTPRequestFramer.swift` | HTTP framing and the size cap | 3 |
| `Sources/CoffeeBarCore/StalePolicy.swift` | Session expiry | 4 |
| `Tests/CoffeeBarUITests/AppLayerBoundary_test.swift` | The display-assertion boundary guard | 5 |
| `Sources/CoffeeBarCore/HoldController.swift` | User intent and suppression | 6 |
| `Sources/CoffeeBarUI/ServingModel.swift` | The @MainActor model | 6, 9 |
| `Sources/CoffeeBarCore/SessionHub.swift` | Hook-event transitions, message cap | 10 |
| `Tests/CoffeeBarIngestTests/IngestListener_test.swift` | Listener tests and `pump()` | 8 |
| `Sources/CoffeeBarApp/main.swift` | App entry, listener wiring | 7 |

---

## Task 1: Redact the leaked fixture and guard every fixture

Closes **B1 (blocking)**. 599 characters of unredacted live-session prose sit in a PUBLIC repo on `origin/main`.

> **WARNING — read before starting.** Redacting the file does NOT remove the content from git history. History rewrite is Carlos's decision and Carlos's action. This task makes the working tree correct and prevents recurrence. Do not attempt any history rewrite, and do not push.

**Files:**
- Modify: `Tests/Fixtures/claude-hooks/permission-denied.json`
- Create: `Tests/CoffeeBarIngestTests/FixtureRedaction_test.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing other tasks rely on.

- [ ] **Step 1: See exactly what is exposed**

```bash
cd /Users/eduardoa/src/github/ArangoGutierrez/coffee-bar
jq -r '.reason' Tests/Fixtures/claude-hooks/permission-denied.json | wc -c
jq -r 'keys[]' Tests/Fixtures/claude-hooks/permission-denied.json
```

Expected: 600 bytes for `.reason`. Note every key present.

- [ ] **Step 2: Write the failing guard**

Create `Tests/CoffeeBarIngestTests/FixtureRedaction_test.swift`. The guard asserts a **non-zero file count** first — a scan over an empty directory reports zero matches and looks like success.

```swift
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

/// Fixtures ship in a PUBLIC repo. A fixture carrying real session prose is a
/// data leak, not a test-quality problem.
///
/// Named bug this catches: permission-denied.json shipped 599 characters of
/// real, model-authored text quoting the maintainer's own words.
@Suite struct FixtureRedactionTests {

    /// Every scalar string a fixture may carry, with the longest length that is
    /// still plausibly a code or an identifier rather than prose.
    static let maximumProseCharacters = 120

    static func fixtureURLs() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CoffeeBarIngestTests
            .deletingLastPathComponent()   // Tests
            .appending(path: "Fixtures/claude-hooks")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path())
        return names.filter { $0.hasSuffix(".json") }.sorted().map { root.appending(path: $0) }
    }

    @Test func theFixtureScanActuallySeesFiles() throws {
        let urls = try Self.fixtureURLs()
        #expect(urls.count >= 5, "scan found \(urls.count) fixtures; an empty scan looks like success")
    }

    @Test func noFixtureCarriesProse() throws {
        var offenders: [String] = []
        for url in try Self.fixtureURLs() {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            for (key, value) in Self.strings(in: object) where value.count > Self.maximumProseCharacters {
                offenders.append("\(url.lastPathComponent):\(key) is \(value.count) characters")
            }
        }
        #expect(offenders.isEmpty, "fixtures carry prose: \(offenders.joined(separator: "; "))")
    }

    @Test func noFixtureNamesThePrivateCaptureFile() throws {
        var offenders: [String] = []
        for url in try Self.fixtureURLs() {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, marker) in forbiddenContentMarkers.enumerated()
            where text.contains(marker) {
                offenders.append("\(url.lastPathComponent) carries marker #\(index)")
            }
        }
        #expect(offenders.isEmpty, "fixtures name private material: \(offenders.joined(separator: "; "))")
    }

    static func strings(in object: Any, path: String = "") -> [(String, String)] {
        switch object {
        case let dictionary as [String: Any]:
            return dictionary.flatMap { strings(in: $1, path: path.isEmpty ? $0 : "\(path).\($0)") }
        case let array as [Any]:
            return array.enumerated().flatMap { strings(in: $1, path: "\(path)[\($0)]") }
        case let text as String:
            return [(path, text)]
        default:
            return []
        }
    }
}
```

- [ ] **Step 3: Run it and watch it FAIL**

```bash
swift test 2>&1 | tee /tmp/t1.log; grep -E 'noFixtureCarriesProse|noFixtureNamesThePrivateCaptureFile' /tmp/t1.log
```

Expected: both tests FAIL, naming `permission-denied.json`. If `theFixtureScanActuallySeesFiles` fails, the path is wrong — fix that first or the other two are vacuous.

- [ ] **Step 4: Redact the fixture**

Replace the `reason` value with a synthetic string that keeps the SHAPE the decoder needs and carries no real content. Preserve every other key and the field's type.

```bash
cd /Users/eduardoa/src/github/ArangoGutierrez/coffee-bar
jq '.reason = "Permission denied by policy: the tool call was refused."' \
  Tests/Fixtures/claude-hooks/permission-denied.json > /tmp/pd.json
mv /tmp/pd.json Tests/Fixtures/claude-hooks/permission-denied.json
jq -r '.reason' Tests/Fixtures/claude-hooks/permission-denied.json
```

Verify the after-state: print the line. Never trust the exit code of a scripted substitution.

- [ ] **Step 5: Run the FULL suite**

```bash
swift test > /tmp/t1b.log 2>&1; rc=$?; echo "rc=$rc"; tail -3 /tmp/t1b.log
```

Expected: rc=0. Any test that asserted on the old 599-character `reason` must be updated to the new value — that is a legitimate contract change, not a test bug.

- [ ] **Step 6: Prove the guard discriminates**

Put the prose back temporarily, confirm RED, then restore. A guard that never flips is theater.

```bash
cp Tests/Fixtures/claude-hooks/permission-denied.json /tmp/pd-good.json
# Derive the reason from the guard instead of reprinting the prose here. Marker 0
# is enough to trip the check, and reading it from the source keeps this block
# executable without putting live session content back into a public document.
LEAK=$(python3 -c 'import re; s=open("Tests/CoffeeBarCoreTests/FixtureRedaction_test.swift").read(); b=re.search(r"forbiddenContentMarkers = \[(.*?)\]", s, re.S).group(1); print(re.findall(r"\"([^\"]+)\"", b)[0])')
jq --arg r "$LEAK" '.reason = $r' /tmp/pd-good.json > Tests/Fixtures/claude-hooks/permission-denied.json
swift test > /tmp/t1c.log 2>&1; echo "expect FAIL: rc=$?"
cp /tmp/pd-good.json Tests/Fixtures/claude-hooks/permission-denied.json
cmp /tmp/pd-good.json Tests/Fixtures/claude-hooks/permission-denied.json && echo "restored"
swift test > /tmp/t1d.log 2>&1; echo "expect PASS: rc=$?"
```

- [ ] **Step 7: Commit**

```bash
git add Tests/Fixtures/claude-hooks/permission-denied.json Tests/CoffeeBarIngestTests/FixtureRedaction_test.swift
git commit -s -S -F - <<'MSG'
fix(tests): redact leaked session prose from the hook fixture

permission-denied.json carried 599 characters of real model-authored text
that named a private capture file and quoted the user verbatim. It shipped
in a public repo.

The new guard scans every fixture for prose over 120 characters and for
markers naming private material, and asserts a non-zero file count so an
empty scan cannot pass as success.

Redaction does not remove the content from history. That is a separate
decision.
MSG
```

- [ ] **Step 8: Report the history exposure — do NOT act on it**

Write one line into the task report: the content remains reachable at `b319a84` and earlier, the repo is public, and a history rewrite is cheap before the v0.1 tag and expensive after. Stop there.

---

## Task 2: Break the retain cycle that leaks every hook payload

Closes **B3 (blocking)**. Measured: 0 of 2200 `ConnectionState` objects deallocated; 6,405,780 bytes held; 2200 buffers still containing assistant text.

**Files:**
- Modify: `Sources/CoffeeBarIngest/IngestListener.swift` (`finish`, near line 354)
- Test: `Tests/CoffeeBarIngestTests/IngestListener_test.swift`

**Interfaces:**
- Consumes: `ConnectionState`, `finish(_:state:)`.
- Produces: nothing new. Behaviour only.

**Root cause, verified:** `state.timeout` holds a `DispatchWorkItem` whose block captured `state` strongly (`IngestListener.swift:343-347`). `finish()` calls `state.timeout?.cancel()` but never clears the reference. `cancel()` does NOT release a work item's captures, so the island `state → timeout → block → state` is unreachable and leaks.

- [ ] **Step 1: Write the failing test**

Add to `IngestListener_test.swift`. This asserts on deallocation, not on memory, so it is deterministic.

```swift
@Test func aFinishedConnectionDeallocatesItsState() async throws {
    final class Probe: @unchecked Sendable {
        static let live = OSAllocatedUnfairLock(initialState: 0)
    }
    // Serve N requests, then assert every ConnectionState is gone.
    // ConnectionState must expose a test-only deinit counter for this.
    let listener = try makeListener()
    defer { listener.stop() }
    let before = IngestListener.ConnectionState.liveCount
    for _ in 0..<50 { try await post(minimalStopPayload(), to: listener) }
    try await settle(past: listener.idleTimeout)
    #expect(IngestListener.ConnectionState.liveCount == before,
            "live ConnectionState grew from \(before) to \(IngestListener.ConnectionState.liveCount)")
}
```

Add to `ConnectionState` a counter guarded so it costs nothing in release:

```swift
final class ConnectionState {
    static let counter = OSAllocatedUnfairLock(initialState: 0)
    static var liveCount: Int { counter.withLock { $0 } }
    init()  { Self.counter.withLock { $0 += 1 } }
    deinit { Self.counter.withLock { $0 -= 1 } }
    // ... existing members
}
```

- [ ] **Step 2: Run it and watch it FAIL**

```bash
swift test 2>&1 | grep -A3 aFinishedConnectionDeallocatesItsState
```

Expected: FAIL, live count grew by 50. **The settle must exceed `idleTimeout`** — a pending `asyncAfter` holds the item until its deadline in BOTH the broken and fixed cases, so a short window shows a false leak. This exact confound produced a wrong result during the audit.

- [ ] **Step 3: Apply the one-line fix**

In `finish(_:state:)`, immediately after `state.timeout?.cancel()`:

```swift
    private func finish(_ connection: NWConnection, state: ConnectionState) {
        guard state.claimRelease() else { return }
        state.timeout?.cancel()
        state.timeout = nil        // cancel() does not release the item's captures
        lock.lock()
        activeConnections = max(0, activeConnections - 1)
        lock.unlock()
        connection.cancel()
    }
```

- [ ] **Step 4: Run the FULL suite**

```bash
swift test > /tmp/t2.log 2>&1; rc=$?; echo "rc=$rc"; tail -3 /tmp/t2.log
```

Expected: rc=0, the new test passes, 370+ tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/CoffeeBarIngest/IngestListener.swift Tests/CoffeeBarIngestTests/IngestListener_test.swift
git commit -s -S -m "fix(ingest): release the idle-timeout work item so ConnectionState deallocates

state.timeout held a DispatchWorkItem whose block captured state strongly.
finish() cancelled the item but never cleared the reference, and cancel()
does not release captures, so every served request leaked its raw POST —
including last_assistant_message — for the life of the process.

Measured before: 0 of 2200 states deallocated, 6.4 MB retained.
Measured after:  2200 of 2200 deallocated, 0 bytes retained."
```

---

## Task 3: Make an oversized hook event loud instead of silent

Closes **B4 (blocking)** and the minor finding at `HTTPRequestFramer_test.swift:96`.

**Files:**
- Modify: `Sources/CoffeeBarIngest/HTTPRequestFramer.swift:22`
- Modify: `Tests/CoffeeBarIngestTests/HTTPRequestFramer_test.swift:96`
- Modify: `docs/V0.1-ACCEPTANCE.md:53-57` (the hook snippet)

**Interfaces:**
- Consumes: `HTTPRequestFramer.Outcome`.
- Produces: unchanged `Outcome` cases.

**Two defects, one area.** (a) A request over the cap returns 413 but the shipped `curl` has no `--fail`, so it exits 0 printing nothing and the event vanishes; the session never leaves `.working`. (b) `aRequestExactlyAtTheCapIsAccepted` is 237 bytes against a 65,536-byte cap, so the `>` versus `>=` bug its own comment names does not go red.

- [ ] **Step 1: Write the failing boundary test**

Replace the vacuous test. Build a request of EXACTLY `maximumBytes` and one of `maximumBytes + 1`.

```swift
@Test func aRequestExactlyAtTheCapIsAccepted() {
    var framer = HTTPRequestFramer()
    let request = Self.request(bodyPaddedTo: HTTPRequestFramer.maximumBytes)
    #expect(request.count == HTTPRequestFramer.maximumBytes,
            "fixture is \(request.count) bytes; it must be exactly the cap or this does not test the cap")
    #expect(framer.append(request) != .tooLarge)
}

@Test func oneByteOverTheCapIsRefused() {
    var framer = HTTPRequestFramer()
    let request = Self.request(bodyPaddedTo: HTTPRequestFramer.maximumBytes + 1)
    #expect(request.count == HTTPRequestFramer.maximumBytes + 1)
    #expect(framer.append(request) == .tooLarge)
}
```

`request(bodyPaddedTo:)` must build real headers and pad the body so the TOTAL is the requested size — the cap counts headers too, which is why 65,385 body bytes already trips a 65,536 cap.

- [ ] **Step 2: Run and confirm the pair discriminates**

```bash
swift test 2>&1 | grep -E 'aRequestExactlyAtTheCapIsAccepted|oneByteOverTheCapIsRefused'
```

Both must PASS now. Then flip `>` to `>=` in `append`, re-run, and confirm `aRequestExactlyAtTheCapIsAccepted` goes RED. Restore. Print the diff of the mutated file to prove the mutant applied.

- [ ] **Step 3: Fix the silent drop in the documented hook**

In `docs/V0.1-ACCEPTANCE.md`, the hook command must fail loudly. Change the `curl` invocation to include `--fail-with-body` so a 413 is a non-zero exit the user can see:

```bash
curl -sS --fail-with-body --unix-socket "$SOCK" -X POST --data-binary @- http://localhost/event
```

- [ ] **Step 4: Raise the cap above a realistic Stop payload**

A reply with a large code block exceeds 64 KiB routinely. Raise `maximumBytes` to `1_048_576` (1 MiB) and record why in the doc comment, keeping the design's stated intent (a cap exists to stop a same-user process pinning unbounded memory).

```swift
    /// The largest request accepted, headers included.
    ///
    /// Design §4.1 is explicit that a same-user process can post here. A cap
    /// stops it pinning unbounded memory in a menu-bar app.
    ///
    /// 1 MiB, not 64 KiB: a Stop payload carries `last_assistant_message`, and
    /// a reply containing a large code block measured past 64 KiB, at which
    /// point the event was dropped and the session never left `.working`.
    static let maximumBytes = 1_048_576
```

- [ ] **Step 5: Run the FULL suite and commit**

```bash
swift test > /tmp/t3.log 2>&1; rc=$?; echo "rc=$rc"; tail -3 /tmp/t3.log
git add Sources/CoffeeBarIngest/HTTPRequestFramer.swift Tests/CoffeeBarIngestTests/HTTPRequestFramer_test.swift docs/V0.1-ACCEPTANCE.md
git commit -s -S -m "fix(ingest): stop dropping large hook events in silence

A Stop payload over the cap returned 413, but the documented curl had no
--fail, so it exited 0 printing nothing and the event was lost with no
signal. The session then never left .working.

Raises the cap to 1 MiB, adds --fail-with-body to the documented hook, and
replaces a 237-byte 'cap' test that could not detect a > versus >= defect."
```

---

## Task 4: Stop releasing the assertion during a long tool call

Closes **B2 (blocking)** and the minor at `StalePolicy.swift:65`.

**Files:**
- Modify: `Sources/CoffeeBarCore/StalePolicy.swift:22` and the expiry comparison near line 65
- Test: `Tests/CoffeeBarCoreTests/StalePolicy_test.swift`

**Interfaces:**
- Consumes: `SessionState`, `AgentSession.lastEventAt`.
- Produces: `StalePolicy.standard` with a changed `workingTimeout`.

**Why this is blocking:** nothing fires between `PreToolUse` and `PostToolUse`. Claude Code's Bash tool documents `timeout` max = 600000 ms. `workingTimeout` is 300 s — **half** the longest legal tool call. A build releases the assertion mid-run, which is the exact failure the product exists to prevent. Design §10.2 records both numbers as PROVISIONAL, so changing them is sanctioned.

- [ ] **Step 1: Write the failing test**

```swift
@Test func aWorkingSessionSurvivesTheLongestLegalToolCall() {
    // Claude Code documents Bash timeout max = 600_000 ms.
    let longestToolCall: TimeInterval = 600
    let policy = StalePolicy.standard
    let timeout = try #require(policy.timeout(for: .working))
    #expect(timeout > longestToolCall,
            "workingTimeout \(timeout)s expires inside a legal \(longestToolCall)s tool call")
}
```

- [ ] **Step 2: Run and watch it FAIL**

Expected: FAIL, `workingTimeout 300.0s expires inside a legal 600.0s tool call`.

- [ ] **Step 3: Raise the floor**

```swift
    /// 900 s, not 300 s: nothing fires between PreToolUse and PostToolUse, and
    /// Claude Code documents a 600 s maximum Bash timeout. At 300 s the
    /// assertion was released in the middle of the agent's longest operation.
    /// Design §10.2 records these as PROVISIONAL.
    public static let standard = StalePolicy(workingTimeout: 900,
                                             blockedTimeout: 14_400)
```

- [ ] **Step 4: Make expiry monotonic**

`now.timeIntervalSince(session.lastEventAt)` uses `Date()`, a wall clock. A backward NTP step makes every `lastEventAt` look future-dated and disables the only backstop against a crashed agent. Add a clamp so a negative elapsed value is treated as zero rather than as "not yet due", and record why:

```swift
    // Date() is a WALL clock. A backward step (NTP correction, manual change,
    // VM restore) makes lastEventAt look future-dated. Clamping at zero keeps
    // the session alive rather than retiring it early, and the next real event
    // re-bases lastEventAt.
    let elapsed = max(0, now.timeIntervalSince(session.lastEventAt))
    guard let timeout = policy.timeout(for: session.state), elapsed >= timeout
    else { return session }
```

- [ ] **Step 5: Add the boundary pair**

Both sides. M1 shipped two defects where only one side of a comparison was covered.

```swift
@Test func exactlyTheTimeoutRetiresTheSession() { /* elapsed == timeout → .stale */ }
@Test func oneSecondUnderTheTimeoutKeepsIt()     { /* elapsed == timeout - 1 → unchanged */ }
@Test func aBackwardClockStepDoesNotRetireEarly() { /* lastEventAt in the future → unchanged */ }
```

- [ ] **Step 6: Run the FULL suite and commit**

```bash
swift test > /tmp/t4.log 2>&1; rc=$?; echo "rc=$rc"; tail -3 /tmp/t4.log
git add Sources/CoffeeBarCore/StalePolicy.swift Tests/CoffeeBarCoreTests/StalePolicy_test.swift
git commit -s -S -m "fix(core): keep the hold through the longest legal tool call

Nothing fires between PreToolUse and PostToolUse, and Claude Code documents
a 600s maximum Bash timeout, so a 300s workingTimeout released the assertion
in the middle of a build. Raises it to 900s.

Also clamps the expiry comparison at zero: it read a wall clock, so a
backward NTP step disabled the only backstop against a crashed agent."
```

---

## Task 5: Derive the app-layer boundary instead of hardcoding it

Closes **B5 and B6 (both blocking)**.

**Files:**
- Modify: `Tests/CoffeeBarUITests/AppLayerBoundary_test.swift` (`appLayerTargets`, near line 76)

**Interfaces:**
- Consumes: `swift package describe --type json`, `ResolvedTarget`.
- Produces: a derived closure, not a literal list.

**Verified facts — do not re-derive, but do re-check if the manifest changed:**
- The real closure of `CoffeeBarApp` over `target_dependencies` is FIVE targets: `CoffeeBarApp, CoffeeBarUI, CoffeeBarIngest, CoffeeBarPower, CoffeeBarCore`.
- `appLayerTargets` lists THREE. `CoffeeBarPower` and `CoffeeBarCore` are unscanned, and `CoffeeBarPower` is the module that already imports IOKit.
- `swift package describe --type json` emits exactly these target keys: `c99name, module_type, name, path, sources, target_dependencies, type`. **There is no `product_dependencies` key.** Do not write code that decodes one.
- `swift package show-dependencies --format json` reports `dependencies` length **0**. The package has no external packages today.

- [ ] **Step 1: Write the failing test for the closure**

```swift
@Test func theScannedSetIsTheWholeAppLayerClosure() throws {
    let resolved = try #require(try? describeOnce().get())
    var seen: Set<String> = []
    var frontier = ["CoffeeBarApp"]
    while let name = frontier.popLast() {
        guard seen.insert(name).inserted else { continue }
        frontier.append(contentsOf: resolved[name]?.dependencies ?? [])
    }
    #expect(seen == Set(appLayerTargets),
            "the binary links \(seen.sorted()) but the guard scans \(appLayerTargets.sorted())")
}
```

- [ ] **Step 2: Run and watch it FAIL**

Expected: FAIL naming `CoffeeBarPower` and `CoffeeBarCore` as linked-but-unscanned.

- [ ] **Step 3: Make `appLayerTargets` the derived closure**

Replace the literal with the closure walk, and keep a literal only as an assertion of the EXPECTED closure so a new target entering the binary goes red:

```swift
/// Every target the `coffee-bar` binary links, derived from the manifest.
///
/// Derived, not listed: a hardcoded list silently missed CoffeeBarPower — the
/// module that imports IOKit — and CoffeeBarCore. Escape 4 was a target added
/// to the closure that nobody added here.
private func appLayerClosure(_ resolved: [String: ResolvedTarget]) -> Set<String> {
    var seen: Set<String> = []
    var frontier = ["CoffeeBarApp"]
    while let name = frontier.popLast() {
        guard seen.insert(name).inserted else { continue }
        frontier.append(contentsOf: resolved[name]?.dependencies ?? [])
    }
    return seen
}

/// The closure as it stands. A change here is a deliberate act, reviewed.
private let expectedAppLayerTargets: Set<String> = [
    "CoffeeBarApp", "CoffeeBarUI", "CoffeeBarIngest", "CoffeeBarPower", "CoffeeBarCore",
]
```

- [ ] **Step 4: Close the external-product escape**

`describe` cannot see a product dependency, so guard the only route one can arrive by — a package dependency in the manifest:

```swift
@Test func thePackageDeclaresNoExternalDependencies() throws {
    // An external product cannot be seen in `swift package describe`, whose
    // target keys are: c99name, module_type, name, path, sources,
    // target_dependencies, type. So guard the only door it can come through.
    // Escape 5 was `.product(name:package:)` raising a display assertion with
    // all seven checks green.
    let output = try runSwift(["package", "show-dependencies", "--format", "json"])
    let json = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
    let dependencies = json?["dependencies"] as? [Any] ?? []
    #expect(dependencies.isEmpty,
            "the package gained \(dependencies.count) external dependencies; an external product can ship a display assertion invisibly")
}
```

- [ ] **Step 5: Prove BOTH escapes now go red**

This step is the deliverable. A guard that does not discriminate is theater.

```bash
# Escape B6: add a display assertion inside CoffeeBarPower under another name.
# Expect: RED once CoffeeBarPower is scanned.
# Escape B5: add a trivial local package dependency to Package.swift.
# Expect: thePackageDeclaresNoExternalDependencies goes RED.
# Restore both, print `git diff` each time to prove the mutant applied and
# compiled, and confirm GREEN afterwards.
```

- [ ] **Step 6: Run the FULL suite and commit**

```bash
swift test > /tmp/t5.log 2>&1; rc=$?; echo "rc=$rc"; tail -3 /tmp/t5.log
git add Tests/CoffeeBarUITests/AppLayerBoundary_test.swift
git commit -s -S -m "fix(tests): derive the app-layer boundary from the manifest closure

The guard scanned three hardcoded targets while the binary links five. The
two it missed include CoffeeBarPower, the module that already imports IOKit
— six lines there shipped a live display assertion with the suite green.

Also asserts the package declares no external dependencies, because a
product dependency is invisible to swift package describe, whose target
keys carry no product field at all."
```

---

## Task 6: Stop a refused Serve from becoming a permanent veto

Closes **I4 (important)** and the minor at `ServingModel.swift:503`.

**Files:**
- Modify: `Sources/CoffeeBarCore/HoldController.swift:70`
- Modify: `Sources/CoffeeBarUI/ServingModel.swift:503`

**Interfaces:**
- Consumes: `PowerBroker.decide`, `UserIntent`.
- Produces: `HoldController.intent` that returns to its prior position.

**Defect:** `if intent == .serve { intent = .stop }` demotes the user's control to an ABSOLUTE VETO they never selected, with no memory of the prior position, so it can never return to `.auto`. One click on low battery permanently disables the app.

- [ ] **Step 1: Write the failing test**

```swift
@Test func aRefusedServeReturnsToAutoRatherThanVetoing() {
    var controller = HoldController(intent: .auto)
    _ = controller.evaluate(sessions: [], powerSource: .battery, batteryPercent: 15)
    controller.intent = .serve                       // the user clicks On
    _ = controller.evaluate(sessions: [], powerSource: .battery, batteryPercent: 15)
    #expect(controller.intent != .stop,
            "a refused Serve set an absolute veto the user never chose")
    #expect(controller.intent == .auto)
}
```

- [ ] **Step 2: Run and watch it FAIL** — `controller.intent == .stop`.

- [ ] **Step 3: Restore the prior intent instead of vetoing**

```swift
        if let suppression = state.suppression {
            lastSuppression = suppression
            // A refusal must not rewrite the user's control to the absolute
            // veto: .stop is a position only the user may select. Fall back to
            // the position held before .serve.
            if intent == .serve { intent = intentBeforeServe ?? .auto }
        }
```

Record `intentBeforeServe` at the point `intent` is set to `.serve`.

- [ ] **Step 4: Fix the panel's misleading reason**

`reason(_:stillTrueOf:)` filters the latched suppression against the newest reading only, never checking whether the current decision actually requested a hold. With no sessions, nothing asks for a hold, yet the panel still blames the battery. Gate the explanation on a hold actually having been requested.

- [ ] **Step 5: Run the FULL suite and commit**

```bash
swift test > /tmp/t6.log 2>&1; rc=$?; echo "rc=$rc"; tail -3 /tmp/t6.log
git add Sources/CoffeeBarCore/HoldController.swift Sources/CoffeeBarUI/ServingModel.swift
git commit -s -S -m "fix(core): a refused Serve no longer sets a permanent veto

One click on low battery demoted .auto to .stop, an absolute veto the user
never selected, with no memory of the prior position — so the app could
never serve again. Restores the position held before .serve.

Also stops the panel blaming the battery when no hold was requested."
```

---

## Task 7: Socket lifecycle, symlinks, and honest readiness

Closes **I1, I2, I3 (important)** and two minors (`IngestListener.swift:211`, `main.swift:33`).

**Files:**
- Modify: `Sources/CoffeeBarIngest/IngestListener.swift` (lines 185, 211, 253)
- Modify: `Sources/CoffeeBarUI/ServingModel.swift:310` (the false comment and missing cleanup)
- Modify: `Sources/CoffeeBarApp/main.swift:33`

**Five related defects in one surface:**

| Finding | Defect |
|---|---|
| I1 | The comment "the orphan's own NWListener goes with it when the object does" is FALSE. A released `NWListener` without `cancel()` stays bound and keeps accepting. It is the entire justification for shipping with no cleanup path. |
| I2 | `occupant(atPath:)` uses `FileManager.fileExists`, which FOLLOWS symlinks, so a dangling symlink is invisible and the live socket is relocated out of the 0700 directory through a 0755 window. |
| I3 | `isReady` stays true after the socket node is deleted, so the panel reports healthy while ingest is dead. |
| minor:211 | `NWListener` binds ASYNCHRONOUSLY, so a bind that loses the start-up race returns without throwing and can never retry. |
| minor:main:33 | A refused socket is invisible in the menu bar — identical to idle — and is never retried. |

- [ ] **Step 1: Write the failing tests, one per defect**

```swift
@Test func aDanglingSymlinkAtTheSocketPathIsDetected()      // lstat, not fileExists
@Test func isReadyGoesFalseWhenTheSocketNodeIsRemoved()
@Test func aReleasedListenerNoLongerOwnsTheSocket()          // proves the comment false
@Test func aLostBindRaceReportsAnErrorRatherThanReturning()
```

- [ ] **Step 2: Run all four and confirm each FAILS for its own reason**

Do not proceed on a test that fails for the wrong cause — that is how `pump()`'s wrong-cause message (Task 8) went unnoticed.

- [ ] **Step 3: Use `lstat` so a symlink is seen, not followed**

Replace `FileManager.fileExists` in `occupant(atPath:)` with `lstat`, which does not follow the link, and treat a symlink at the socket path as an occupant to be refused rather than an absence.

- [ ] **Step 4: Make `isReady` revalidate the node**

`isReady` must confirm the socket node still exists and is a socket, not merely that `start()` once succeeded.

- [ ] **Step 5: Give `ServingModel` a cleanup path and delete the false comment**

Replace the comment with what is true: a released `NWListener` keeps the socket until `cancel()`. Add the explicit cancel. **Do not use `isolated deinit`** — it is experimental before Swift 6.3 and CI is 6.1.2.

- [ ] **Step 6: Surface a refused socket in the menu bar and retry**

The glyph must differ from idle when ingest is dead, and `startMonitoring` must be retried rather than abandoned for the life of the process.

- [ ] **Step 7: Run the FULL suite and commit**

```bash
swift test > /tmp/t7.log 2>&1; rc=$?; echo "rc=$rc"; tail -3 /tmp/t7.log
git add Sources/CoffeeBarIngest/IngestListener.swift Sources/CoffeeBarUI/ServingModel.swift Sources/CoffeeBarApp/main.swift
git commit -s -S -m "fix(ingest): honest readiness, symlink-safe probing, real cleanup

fileExists follows symlinks, so a dangling link at the socket path moved the
live socket out of its 0700 directory through a 0755 window. isReady stayed
true after the node was deleted, so the panel reported healthy while ingest
was dead. A released NWListener keeps the socket until cancel(), which makes
the comment justifying no cleanup false.

A refused socket is now visible in the menu bar and is retried."
```

---

## Task 8: Fix the test harness so failures name their real cause

Closes **I6, I7, I8, I9 (all important)**.

**Files:**
- Modify: `Tests/CoffeeBarIngestTests/IngestListener_test.swift` (lines 152, 278, 505)
- Modify: `Tests/CoffeeBarPowerTests/SleepDisabledController_test.swift:248`

**Why this matters more than it looks:** I7 makes a slow runner report `socket mode is absent` — which reads as a **security regression**. A maintainer triaging that CI run hunts a permissions defect that does not exist.

- [ ] **Step 1: Fix `pump()`'s main-thread branch (I6)**

Adding `@MainActor` to any test makes every `pump` take its documented main-thread branch, wait the whole 5 seconds, and fail naming the wrong cause. Either make the branch work or make it a compile-time error to call `pump` from the main actor. Prefer the latter — a branch that cannot work should not exist.

- [ ] **Step 2: Separate "not ready" from "wrong mode" (I7)**

`theSocketIsNotReadableByOtherUsers` must distinguish a listener that never bound from a listener that bound with wrong permissions, and say so.

```swift
let ready = try await listener.waitUntilReady(within: .seconds(30))
try #require(ready, "listener never reached .ready; this is a timing failure, NOT a permissions regression")
#expect(mode == 0o600, "socket mode is \(String(mode, radix: 8))")
```

- [ ] **Step 3: Give line 505 the same budget as line 528 (I8)**

Commit `d6dafb2` gave 30 seconds to line 528 only. Line 505 still waits on the DEFAULT 5 seconds and its assertion fires first on a slow runner.

- [ ] **Step 4: Fix the 6% flake (I9)**

`realRunnerRunsItsReadersWithoutAFreeSharedPoolWorker` saturates `DispatchQueue.global()` with 256 blocked occupiers, then calls `run(shim, timeout: 2)`. On a loaded runner 2 seconds is not enough and it throws `timedOut`. Raise the timeout and make the assertion about the ABSENCE of pool starvation, not about wall-clock speed.

- [ ] **Step 5: Prove the flake is gone**

```bash
for i in $(seq 1 30); do
  swift test > /tmp/flake-$i.log 2>&1
  echo "run $i rc=$?"
done
grep -l 'failed' /tmp/flake-*.log | wc -l
```

Expected: 0 failures in 30 runs. The baseline was 2 of 33. **Iterate over a list, never a space-joined string** — an unquoted variable does not word-split in zsh and the loop runs once.

- [ ] **Step 6: Commit**

```bash
git add Tests/CoffeeBarIngestTests/IngestListener_test.swift Tests/CoffeeBarPowerTests/SleepDisabledController_test.swift
git commit -s -S -m "fix(tests): failures now name their real cause, and the suite is deterministic

A slow runner made theSocketIsNotReadableByOtherUsers report 'socket mode is
absent', which reads as a security regression for a listener that simply had
not bound yet. pump()'s main-thread branch could never work and burned the
full budget in silence. The connection-cap fix moved the 5s budget without
removing it from the assertion that fires first.

realRunnerRunsItsReadersWithoutAFreeSharedPoolWorker failed 2 of 33 runs;
now 0 of 30."
```

---

## Task 9: Prune terminal sessions and cover the ingest-to-model seam

Closes two minors (`ServingModel.swift:351`, `ServingModel.swift:471`).

**Files:**
- Modify: `Sources/CoffeeBarUI/ServingModel.swift:351`
- Test: `Tests/CoffeeBarUITests/ServingModel_test.swift`

- [ ] **Step 1: Write the failing test for pruning**

`StalePolicy.timeout` returns nil for `.done`, `.failed` and `.stale`, so terminal sessions stay in the array for the life of a process documented to run for days. Every 30 s tick maps the whole array and runs two filters plus a sort over it.

```swift
@Test func terminalSessionsAreEventuallyPruned() {
    // 1000 finished sessions must not survive a refresh cycle.
}
```

- [ ] **Step 2: Prune on refresh**, keeping terminal sessions only as long as the panel needs to display them.

- [ ] **Step 3: Add the integration test for the seam**

`MainActor.assumeIsolated { self?.ingest(event) }` TRAPS rather than recovers if its assumption is false, and its soundness rests entirely on `connection.start(queue: .main)`. Nothing in the suite joins the two halves.

> The obvious way to write this test DEADLOCKS. Drive the listener from a non-main thread and assert on the model from the main actor, with a timeout — do not block the main queue waiting for a delivery that needs the main queue.

- [ ] **Step 4: Run the FULL suite and commit**

---

## Task 10: Bound the message cap in bytes, not grapheme clusters

Closes the minor at `SessionHub.swift:29`.

**Files:**
- Modify: `Sources/CoffeeBarCore/SessionHub.swift:29`

**Defect:** `String(reason.prefix(140))` counts `Character`s. 140 grapheme clusters, each `a` plus 150 combining marks, is **42,140 bytes** — and passes the framer cap, so it is reachable from a conforming request.

- [ ] **Step 1: Write the failing test**

```swift
@Test func theMessageCapBoundsBytesNotGraphemeClusters() {
    let hostile = String(repeating: "a" + String(repeating: "\u{0301}", count: 150), count: 140)
    let capped = SessionHub.cap(hostile)
    #expect(capped.utf8.count <= 4 * SessionHub.messageCap,
            "capped message is \(capped.utf8.count) bytes")
}
```

- [ ] **Step 2: Run and watch it FAIL** — 42,140 bytes.

- [ ] **Step 3: Cap on UTF-8 bytes**, truncating on a character boundary so the result stays valid UTF-8.

- [ ] **Step 4: Run the FULL suite and commit**

---

## Task 11: Guard the raw hook payload in the ingest path

Closes **I5 (important)**.

**Files:**
- Create: `Tests/CoffeeBarIngestTests/IngestPayloadPrivacy_test.swift`
- Modify: `Sources/CoffeeBarIngest/IngestListener.swift:388` if the guard finds a real path

**Interfaces:**
- Consumes: `IngestListener.receive`, the fixture corpus.
- Produces: a guard other tasks must keep green.

**Defect:** no guard covers the raw payload between the socket and the decode. Adding one line — `NSLog("coffee-bar ingest: %@", String(data: body, encoding: .utf8) ?? "<binary>")` immediately before the decode in `receive` — writes every Stop payload verbatim to the unified log, readable in Console.app and persistent. **The suite stays green.** The existing privacy guards cover the decoded `HookEvent`, not the bytes that precede it.

This is the same class as B5 and B6: the invariant is real, the guard has a hole.

- [ ] **Step 1: Write the guard**

A source-level guard is the honest instrument here, because the leak is a line of code that does not yet exist. Assert that no file in `Sources/CoffeeBarIngest` passes raw request bytes to a logging or printing call.

```swift
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

/// The privacy invariant covers the BYTES, not only the decoded event.
///
/// Named bug this catches: one NSLog of `body` before the decode writes every
/// last_assistant_message to the unified log, with the whole suite green.
@Suite struct IngestPayloadPrivacyTests {

    static let loggingCalls = ["NSLog", "print(", "os_log", "Logger(", "debugPrint", "FileHandle.standardOutput"]
    static let rawByteNames = ["body", "buffer", "chunk", "data"]

    @Test func theScanActuallyReadsTheIngestSources() throws {
        let files = try Self.ingestSourceFiles()
        #expect(files.count >= 2, "scan found \(files.count) files; an empty scan looks like success")
    }

    @Test func noIngestSourceLogsRawRequestBytes() throws {
        var offenders: [String] = []
        for url in try Self.ingestSourceFiles() {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard Self.loggingCalls.contains(where: line.contains) else { continue }
                guard Self.rawByteNames.contains(where: line.contains) else { continue }
                offenders.append("\(url.lastPathComponent):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(offenders.isEmpty, "a logging call carries raw request bytes: \(offenders.joined(separator: "; "))")
    }

    static func ingestSourceFiles() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/CoffeeBarIngest")
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }
}
```

- [ ] **Step 2: Run it — expect GREEN**

The leak line does not exist yet. A green guard here is correct.

- [ ] **Step 3: PROVE it discriminates — this is the real deliverable**

Plant the exact leak the audit described, confirm RED, then remove it.

```bash
cd /Users/eduardoa/src/github/ArangoGutierrez/coffee-bar
cp Sources/CoffeeBarIngest/IngestListener.swift /tmp/il-good.swift
# Insert the NSLog immediately before the decode in receive(), then:
git diff --stat Sources/CoffeeBarIngest/IngestListener.swift   # prove the mutant applied
swift build > /tmp/t11-build.log 2>&1; echo "compiles rc=$?"   # prove it COMPILES
swift test > /tmp/t11.log 2>&1; echo "expect FAIL rc=$?"
grep noIngestSourceLogsRawRequestBytes /tmp/t11.log
command cp -f /tmp/il-good.swift Sources/CoffeeBarIngest/IngestListener.swift
cmp /tmp/il-good.swift Sources/CoffeeBarIngest/IngestListener.swift && echo "restored"
swift test > /tmp/t11b.log 2>&1; echo "expect PASS rc=$?"
```

A mutant that does not compile proves only that the compiler works. This project made that mistake three times.

- [ ] **Step 4: Commit**

```bash
git add Tests/CoffeeBarIngestTests/IngestPayloadPrivacy_test.swift
git commit -s -S -m "test(ingest): guard the raw payload, not only the decoded event

The privacy guards covered HookEvent after decoding. One NSLog of the raw
body before the decode wrote every last_assistant_message to the unified
log with the whole suite green.

Verified to discriminate: planting that exact line goes red, and the mutant
was proved to compile before the result was believed."
```

---

## Final gate — before this branch is offered for review

- [ ] **All 23 findings closed.** Walk `.superpowers/sdd/m2-audit-findings.md` and tick each one against a commit.
- [ ] **Full suite, 30 consecutive runs, zero failures.** One green run is one observation, not a property.
- [ ] **Release build clean:** `swift build -c release` with zero warnings.
- [ ] **SPDX headers on all 69 Swift files.** Five test files still lack one — a separate open M4 item, close it here:
  `JournalRecord_test.swift`, `SpikeID_test.swift`, `Verdict_test.swift`, `WatchdogDecision_test.swift`, `DependencyDirection_test.swift`.
- [ ] **Re-run the audit workflow** against the fixed branch and confirm the confirmed count is 0.
- [ ] **Do not push, tag, or open a PR.** Carlos owns every outward action.

## Self-review notes

**Spec coverage:** all 23 confirmed findings map to a task.

| Task | Findings closed | Count |
|---|---|---|
| T1 | B1 | 1 |
| T2 | B3 | 1 |
| T3 | B4, minor(framer cap test) | 2 |
| T4 | B2, minor(wall clock) | 2 |
| T5 | B5, B6 | 2 |
| T6 | I4, minor(panel reason) | 2 |
| T7 | I1, I2, I3, minor(bind race), minor(main.swift:33) | 5 |
| T8 | I6, I7, I8, I9 | 4 |
| T9 | minor(pruning), minor(seam test) | 2 |
| T10 | minor(SessionHub messageCap) | 1 |
| T11 | I5 | 1 |
| **Total** | **6 blocking + 9 important + 8 minor** | **23** |

The first draft of this plan mapped only 22. **I5 — the raw-payload privacy guard — was dropped**, and the self-review count caught it. T11 was added afterwards. That is the same defect class the audit found six times over: an invariant that is real and a guard that has a hole. Worth noting because a plan reviewer should assume the NEXT omission is also silent.

**Deliberately excluded:** the 9 refuted findings, listed at the end of `m2-audit-findings.md`. Do not act on them without new evidence.

**Known plan risk:** Tasks 7 and 9 carry less literal code than Tasks 1-5 because their fixes depend on runtime behaviour that must be measured in the worktree first. Their implementers should expect to write the test before knowing the exact fix, and should report back if the measured behaviour contradicts the finding.
