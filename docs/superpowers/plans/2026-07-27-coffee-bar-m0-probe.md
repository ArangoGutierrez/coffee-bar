# coffee-bar M0 Capability Probe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the M0 capability probe that answers handoff spikes S1, S2, S3, S5 and S8 on real hardware, with a crash-safe `SleepDisabled` revert guarantee that M3's privileged helper will later reuse unchanged.

**Architecture:** Three SwiftPM targets with strictly one-way dependencies — `CoffeeBarProbe` (CLI harness) → `CoffeeBarPower` (syscall boundary, behind protocols) → `CoffeeBarCore` (pure Foundation-only logic). All policy and decision logic lives in `Core` so it is exhaustively testable in CI without root, without hardware, and without a Mac in the loop. The `arm`/`report` two-phase flow plus a launchd-installed watchdog implements handoff §8.2 clauses 1–5.

**Tech Stack:** Swift 6.3.3, SwiftPM, swift-testing (`import Testing`), IOKit (`IOPMAssertion`, `IOPS`, `IODisplayWrangler`), libproc (`proc_pid_rusage`), Darwin (`setpriority`, `fcntl`, `sysctlbyname`), launchd, GitHub Actions on macOS runners.

## Global Constraints

Every task's requirements implicitly include this section. Values are copied verbatim from the spec.

- **Swift tools version 6.0**, `swiftLanguageModes: [.v6]`, strict concurrency enabled.
- **Platform floor `.macOS(.v14)`.** Do not target below macOS 14.
- **`CoffeeBarCore` imports Foundation and nothing else.** No IOKit, no Darwin, no AppKit. This is enforced by review; a violation invalidates the CI-testability guarantee.
- **Dependency direction is one-way:** `Probe → Power → Core`. `Core` depends on nothing. `Core` must never reference `pmset`, `launchctl`, or any file path.
- **Zero third-party package dependencies.** No `swift-argument-parser`. Argument parsing is hand-rolled; the verb surface is five verbs.
- **TTL hard cap is 8 hours (28800 s)**, clamped in both `init` and `init(from:)`. No caller may opt out.
- **Journal is `fsync`'d before any system mutation**, using `fcntl(fd, F_FULLFSYNC)` — on macOS plain `fsync()` does not guarantee the data reached stable storage.
- **Copyright year is 2026** in all new files. License is Apache-2.0.
- **No `claude` in any product, target, or binary name** (handoff §13.4). Third-party marks are nominative use only.
- **Commits are signed:** `git commit -s -S`. Conventional format `type(scope): description`.
- **Builds and tests must run unsandboxed** on the dev machine (clang module cache is outside the agent sandbox allowlist).
- **S1 is reported `notYetRun` until a real armed run with a real closed lid occurs.** No test may assert S1 passes.

---

## File Structure

| File | Responsibility |
|---|---|
| `Package.swift` | Three targets, two test targets, platform floor, Swift 6 mode |
| `Sources/CoffeeBarCore/SpikeID.swift` | Spike identifiers, stable JSON keys |
| `Sources/CoffeeBarCore/Verdict.swift` | `Verdict`, `SpikeResult`, `ProbeReport`, `HostStamp` |
| `Sources/CoffeeBarCore/JournalRecord.swift` | `Intent`, `ArmProvenance`, `JournalRecord` + TTL clamping |
| `Sources/CoffeeBarCore/WatchdogDecision.swift` | `RevertReason`, `WatchdogDecision`, `WatchdogPolicy`, `WatchdogInputs`, `decide()` |
| `Sources/CoffeeBarPower/JournalStore.swift` | Atomic + `F_FULLFSYNC` journal persistence behind `JournalStoring` |
| `Sources/CoffeeBarPower/SleepDisabledController.swift` | `pmset -a disablesleep` read/write behind `SleepDisabledControlling` |
| `Sources/CoffeeBarPower/CommandRunner.swift` | Process execution seam; the only place `Process` is constructed |
| `Sources/CoffeeBarPower/BaselineProbes.swift` | `IOPMAssertion`, thermal, battery, host stamp |
| `Sources/CoffeeBarPower/EnergyProbe.swift` | S3 `proc_pid_rusage` |
| `Sources/CoffeeBarPower/DemotionProbe.swift` | S5 `setpriority(PRIO_DARWIN_BG)` |
| `Sources/CoffeeBarPower/TelemetryRecon.swift` | S8 config inspection |
| `Sources/CoffeeBarPower/DisplayStateProbe.swift` | S2 `IODisplayWrangler` power state |
| `Sources/CoffeeBarPower/LaunchDaemonInstaller.swift` | plist write + `launchctl bootstrap`/`bootout` |
| `Sources/CoffeeBarProbe/main.swift` | Verb dispatch, exit codes |
| `Sources/CoffeeBarProbe/RunCommand.swift` | `run` verb: unprivileged spikes |
| `Sources/CoffeeBarProbe/ArmCommand.swift` | `arm`, `report`, `revert`, `watchdog` verbs |
| `Sources/CoffeeBarPower/OutputFormatter.swift` | JSON and human rendering. Lives in `Power`, not `Probe`: executable targets cannot be imported by test targets. |
| `.github/workflows/ci.yml` | `swift build`, `swift build -c release`, `swift test` |
| `Formula/coffee-bar.rb` | Homebrew formula, builds from source |

---

### Task 1: Package scaffolding, licence, CI, and first Core type

Establishes the build, the test harness, and the CI gate in one deliverable. Ends with a real passing test so the whole chain is proven, not assumed.

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `LICENSE`
- Create: `README.md`
- Create: `Sources/CoffeeBarCore/SpikeID.swift`
- Create: `.github/workflows/ci.yml`
- Test: `Tests/CoffeeBarCoreTests/SpikeIDTests.swift`

**Interfaces:**
- Consumes: nothing (first task)
- Produces: `public enum SpikeID: String, Codable, CaseIterable, Sendable` with cases `s1LidCloseSleep`, `s2DisplayUnderClosedLid`, `s3EnergyFields`, `s5DemotionPrivilege`, `s8TelemetryCollision`, `baseline`; raw values `"S1"`, `"S2"`, `"S3"`, `"S5"`, `"S8"`, `"baseline"`.

- [ ] **Step 1: Create `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "coffee-bar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "coffee-bar-probe", targets: ["CoffeeBarProbe"]),
        .library(name: "CoffeeBarCore", targets: ["CoffeeBarCore"]),
    ],
    targets: [
        .target(name: "CoffeeBarCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "CoffeeBarPower", dependencies: ["CoffeeBarCore"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "CoffeeBarProbe", dependencies: ["CoffeeBarPower"],
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CoffeeBarCoreTests", dependencies: ["CoffeeBarCore"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CoffeeBarPowerTests", dependencies: ["CoffeeBarPower"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
```

- [ ] **Step 2: Create `.gitignore`**

```gitignore
.build/
.swiftpm/
*.xcodeproj
DerivedData/
.DS_Store
docs/probe-results.local.md
```

- [ ] **Step 3: Add the Apache-2.0 `LICENSE`**

Write the standard Apache License 2.0 text verbatim. The copyright line is:

```
Copyright 2026 Carlos Eduardo Arango Gutierrez
```

- [ ] **Step 4: Create a minimal `README.md`**

```markdown
# coffee-bar

A macOS menu-bar app that binds the sleep assertion to agent session state.

**Status:** M0 — capability probe. No UI yet.

## M0: capability probe

    swift build
    swift run coffee-bar-probe --json

The probe answers the hardware/OS capability questions the architecture
branches on. See `docs/superpowers/specs/2026-07-27-coffee-bar-m0-probe-design.md`.

## Licence

Apache-2.0. "Claude Code", "Codex" and "Cursor" are third-party marks used
nominatively; coffee-bar is not affiliated with or endorsed by their owners.
```

- [ ] **Step 5: Write the failing test**

Create `Tests/CoffeeBarCoreTests/SpikeIDTests.swift`:

```swift
import Testing
@testable import CoffeeBarCore

@Test func spikeIDRawValuesMatchHandoffNumbering() {
    // Handoff numbering is authoritative (spec D2). The kickoff engine
    // renumbered S3-S6; those values are rejected.
    #expect(SpikeID.s1LidCloseSleep.rawValue == "S1")
    #expect(SpikeID.s2DisplayUnderClosedLid.rawValue == "S2")
    #expect(SpikeID.s3EnergyFields.rawValue == "S3")
    #expect(SpikeID.s5DemotionPrivilege.rawValue == "S5")
    #expect(SpikeID.s8TelemetryCollision.rawValue == "S8")
}

@Test func spikeIDDoesNotClaimDeferredSpikes() {
    // S4 (Cursor runtime hooks) and S6 (drain harness) are out of M0 scope
    // per spec D3. A raw value of "S4" or "S6" means scope crept.
    let raws = Set(SpikeID.allCases.map(\.rawValue))
    #expect(!raws.contains("S4"))
    #expect(!raws.contains("S6"))
}
```

- [ ] **Step 6: Run the test to verify it fails**

Run: `swift test --filter SpikeIDTests`
Expected: FAIL — `cannot find 'SpikeID' in scope`.

- [ ] **Step 7: Write the minimal implementation**

Create `Sources/CoffeeBarCore/SpikeID.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Identifiers for the capability spikes M0 answers.
///
/// Raw values follow `coffee-bar-HANDOFF.md` §10 numbering, which is
/// authoritative. S4 (Cursor CLI runtime hooks) and S6 (battery drain
/// harness) are deliberately absent — they are not power-capability probes
/// and ship separately.
public enum SpikeID: String, Codable, CaseIterable, Sendable {
    case s1LidCloseSleep = "S1"
    case s2DisplayUnderClosedLid = "S2"
    case s3EnergyFields = "S3"
    case s5DemotionPrivilege = "S5"
    case s8TelemetryCollision = "S8"
    case baseline = "baseline"
}
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test --filter SpikeIDTests`
Expected: PASS, 2 tests.

- [ ] **Step 9: Create the CI workflow**

Create `.github/workflows/ci.yml`. Note `set -o pipefail` is not needed because no step pipes; each command's own exit code gates the job.

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  build-test:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4

      - name: Show toolchain
        run: swift --version

      - name: Build (debug)
        run: swift build

      - name: Build (release)
        run: swift build -c release

      - name: Test
        run: swift test
```

- [ ] **Step 10: Verify the full acceptance chain locally**

Run each separately and record the exit code — do not chain with `&&` after a pipe:

```bash
swift build; echo "build rc=$?"
swift build -c release; echo "release rc=$?"
swift test; echo "test rc=$?"
```

Expected: all three `rc=0`.

- [ ] **Step 11: Commit**

```bash
git add Package.swift .gitignore LICENSE README.md \
        Sources/CoffeeBarCore/SpikeID.swift \
        Tests/CoffeeBarCoreTests/SpikeIDTests.swift \
        .github/workflows/ci.yml
git commit -s -S -m "feat(core): scaffold SwiftPM package, CI, and SpikeID

Establishes the three-target layout with one-way dependencies and a
working swift-testing harness. SpikeID pins handoff §10 numbering as
authoritative so a later renumbering fails a test rather than drifting
silently."
```

---

### Task 2: Core — verdicts, spike results, and the report envelope

**Files:**
- Create: `Sources/CoffeeBarCore/Verdict.swift`
- Test: `Tests/CoffeeBarCoreTests/VerdictTests.swift`

**Interfaces:**
- Consumes: `SpikeID` from Task 1.
- Produces:
  - `public enum Verdict: String, Codable, Sendable` — `pass`, `fail`, `notApplicable`, `notYetRun`, `error`
  - `public struct SpikeResult: Codable, Equatable, Sendable` — `id: SpikeID`, `verdict: Verdict`, `detail: String`, `durationMS: Int`, `evidence: [String: String]`
  - `public struct HostStamp: Codable, Equatable, Sendable` — `hardwareModel: String`, `osVersion: String`, `osBuild: String`, `arch: String`
  - `public struct ProbeReport: Codable, Equatable, Sendable` — `schemaVersion: Int`, `generatedAt: Date`, `host: HostStamp`, `spikes: [SpikeResult]`; plus `public func result(for: SpikeID) -> SpikeResult?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CoffeeBarCoreTests/VerdictTests.swift`:

```swift
import Testing
import Foundation
@testable import CoffeeBarCore

private func makeReport(_ spikes: [SpikeResult]) -> ProbeReport {
    ProbeReport(
        schemaVersion: 1,
        generatedAt: Date(timeIntervalSince1970: 1_785_000_000),
        host: HostStamp(hardwareModel: "Mac16,6", osVersion: "26.5.2",
                        osBuild: "25F84", arch: "arm64"),
        spikes: spikes
    )
}

@Test func reportRoundTripsThroughJSON() throws {
    let original = makeReport([
        SpikeResult(id: .s3EnergyFields, verdict: .pass,
                    detail: "ri_billed_energy populated",
                    durationMS: 12, evidence: ["rusageVersion": "V4"])
    ])
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ProbeReport.self, from: data)
    #expect(decoded == original)
}

@Test func reportJSONUsesHandoffSpikeIdentifiers() throws {
    let report = makeReport([
        SpikeResult(id: .s1LidCloseSleep, verdict: .notYetRun,
                    detail: "requires an armed run", durationMS: 0, evidence: [:])
    ])
    let data = try JSONEncoder().encode(report)
    let json = String(decoding: data, as: UTF8.self)
    // The acceptance command greps spike ids out of this envelope.
    #expect(json.contains("\"S1\""))
    #expect(json.contains("\"notYetRun\""))
}

@Test func resultLookupFindsBySpikeID() {
    let report = makeReport([
        SpikeResult(id: .s5DemotionPrivilege, verdict: .fail,
                    detail: "EPERM", durationMS: 3, evidence: [:]),
        SpikeResult(id: .s8TelemetryCollision, verdict: .pass,
                    detail: "mode 1", durationMS: 1, evidence: [:]),
    ])
    #expect(report.result(for: .s5DemotionPrivilege)?.verdict == .fail)
    #expect(report.result(for: .s8TelemetryCollision)?.verdict == .pass)
    #expect(report.result(for: .s1LidCloseSleep) == nil)
}

@Test func hostStampIsRequiredAndSurvivesEncoding() throws {
    // Spec §4: a verdict without the OS build it was measured on is worthless.
    let report = makeReport([])
    let data = try JSONEncoder().encode(report)
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("25F84"))
    #expect(json.contains("26.5.2"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter VerdictTests`
Expected: FAIL — `cannot find 'SpikeResult' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CoffeeBarCore/Verdict.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Outcome of a single spike.
///
/// `notYetRun` exists because S1 cannot be answered by any automated run —
/// it needs a physical lid close. Reporting it as `fail` would be a lie and
/// reporting it as `pass` would be worse.
public enum Verdict: String, Codable, Sendable {
    case pass
    case fail
    case notApplicable
    case notYetRun
    case error
}

public struct SpikeResult: Codable, Equatable, Sendable {
    public let id: SpikeID
    public let verdict: Verdict
    public let detail: String
    public let durationMS: Int
    public let evidence: [String: String]

    public init(id: SpikeID, verdict: Verdict, detail: String,
                durationMS: Int, evidence: [String: String]) {
        self.id = id
        self.verdict = verdict
        self.detail = detail
        self.durationMS = durationMS
        self.evidence = evidence
    }
}

/// Hardware and OS identity. Handoff §14: `SleepDisabled` behaviour is the
/// kind of thing Apple changes in a point release, so every verdict records
/// the build it was measured on.
public struct HostStamp: Codable, Equatable, Sendable {
    public let hardwareModel: String
    public let osVersion: String
    public let osBuild: String
    public let arch: String

    public init(hardwareModel: String, osVersion: String,
                osBuild: String, arch: String) {
        self.hardwareModel = hardwareModel
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.arch = arch
    }
}

public struct ProbeReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let host: HostStamp
    public let spikes: [SpikeResult]

    public init(schemaVersion: Int = ProbeReport.currentSchemaVersion,
                generatedAt: Date, host: HostStamp, spikes: [SpikeResult]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.host = host
        self.spikes = spikes
    }

    public func result(for id: SpikeID) -> SpikeResult? {
        spikes.first { $0.id == id }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter VerdictTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/CoffeeBarCore/Verdict.swift Tests/CoffeeBarCoreTests/VerdictTests.swift
git commit -s -S -m "feat(core): add Verdict, SpikeResult and ProbeReport envelope

HostStamp is non-optional so no report can be produced without the OS
build it was measured on. Verdict carries notYetRun because S1 cannot be
answered without a physical lid close."
```

---

### Task 3: Core — journal record with TTL clamping on both construction paths

The subtle bug this task exists to prevent: clamping the TTL in `init` but not in `init(from:)` means a journal file on disk claiming `ttlSeconds: 999999999` bypasses the 8-hour cap entirely.

**Files:**
- Create: `Sources/CoffeeBarCore/JournalRecord.swift`
- Test: `Tests/CoffeeBarCoreTests/JournalRecordTests.swift`

**Interfaces:**
- Consumes: nothing from prior tasks.
- Produces:
  - `public enum Intent: String, Codable, Sendable` — `sleepDisabled`
  - `public struct ArmProvenance: Codable, Equatable, Sendable` — `pid: Int32`, `binaryPath: String`, `uid: UInt32`
  - `public struct JournalRecord: Codable, Equatable, Sendable` — fields per spec §5; `static let currentSchemaVersion = 1`; `static let maxTTLSeconds = 28800`; `var expiry: Date`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CoffeeBarCoreTests/JournalRecordTests.swift`:

```swift
import Testing
import Foundation
@testable import CoffeeBarCore

private let provenance = ArmProvenance(
    pid: 4242, binaryPath: "/usr/local/bin/coffee-bar-probe", uid: 501)

@Test func ttlIsClampedToEightHoursOnInit() {
    let r = JournalRecord(intent: .sleepDisabled, priorValue: false,
                          setAt: Date(timeIntervalSince1970: 0),
                          ttlSeconds: 999_999_999, armedBy: provenance)
    #expect(r.ttlSeconds == 28_800)
}

@Test func ttlIsClampedToEightHoursOnDecode() throws {
    // The bug this catches: clamping only in init lets a hand-edited or
    // corrupted journal on disk hold SleepDisabled for 31 years.
    let json = """
    {"schemaVersion":1,"intent":"sleepDisabled","priorValue":false,
     "setAt":0,"ttlSeconds":999999999,
     "armedBy":{"pid":4242,"binaryPath":"/x","uid":501}}
    """
    let r = try JSONDecoder().decode(JournalRecord.self, from: Data(json.utf8))
    #expect(r.ttlSeconds == 28_800)
}

@Test func ttlBelowOneIsRaisedToOne() {
    let r = JournalRecord(intent: .sleepDisabled, priorValue: false,
                          setAt: Date(timeIntervalSince1970: 0),
                          ttlSeconds: -5, armedBy: provenance)
    #expect(r.ttlSeconds == 1)
}

@Test func expiryIsSetAtPlusClampedTTL() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    let r = JournalRecord(intent: .sleepDisabled, priorValue: false,
                          setAt: base, ttlSeconds: 900, armedBy: provenance)
    #expect(r.expiry == base.addingTimeInterval(900))
}

@Test func priorValueSurvivesRoundTrip() throws {
    // Spec D6: if the user deliberately had disablesleep on, we restore THAT.
    let r = JournalRecord(intent: .sleepDisabled, priorValue: true,
                          setAt: Date(timeIntervalSince1970: 5),
                          ttlSeconds: 60, armedBy: provenance)
    let decoded = try JSONDecoder().decode(
        JournalRecord.self, from: JSONEncoder().encode(r))
    #expect(decoded.priorValue == true)
    #expect(decoded == r)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter JournalRecordTests`
Expected: FAIL — `cannot find 'JournalRecord' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CoffeeBarCore/JournalRecord.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum Intent: String, Codable, Sendable {
    case sleepDisabled
}

public struct ArmProvenance: Codable, Equatable, Sendable {
    public let pid: Int32
    public let binaryPath: String
    public let uid: UInt32

    public init(pid: Int32, binaryPath: String, uid: UInt32) {
        self.pid = pid
        self.binaryPath = binaryPath
        self.uid = uid
    }
}

/// Crash-safe intent log. Written and `F_FULLFSYNC`'d *before* the system
/// mutation it describes, so a crash in between leaves evidence rather than
/// a silent change. Handoff §8.2(1).
public struct JournalRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    /// Handoff §8.2(5): hard cap regardless of settings.
    public static let maxTTLSeconds = 8 * 60 * 60

    public let schemaVersion: Int
    public let intent: Intent
    /// The value to restore TO. Stored, never assumed false (spec D6).
    public let priorValue: Bool
    public let setAt: Date
    public let ttlSeconds: Int
    public let armedBy: ArmProvenance

    public var expiry: Date { setAt.addingTimeInterval(TimeInterval(ttlSeconds)) }

    private static func clamp(_ ttl: Int) -> Int {
        min(max(ttl, 1), maxTTLSeconds)
    }

    public init(schemaVersion: Int = JournalRecord.currentSchemaVersion,
                intent: Intent, priorValue: Bool, setAt: Date,
                ttlSeconds: Int, armedBy: ArmProvenance) {
        self.schemaVersion = schemaVersion
        self.intent = intent
        self.priorValue = priorValue
        self.setAt = setAt
        self.ttlSeconds = Self.clamp(ttlSeconds)
        self.armedBy = armedBy
    }

    // Hand-written so the clamp applies to data read from disk too. The
    // synthesised decoder would bypass `init` and honour any value present
    // in the file.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        self.intent = try c.decode(Intent.self, forKey: .intent)
        self.priorValue = try c.decode(Bool.self, forKey: .priorValue)
        self.setAt = try c.decode(Date.self, forKey: .setAt)
        self.ttlSeconds = Self.clamp(try c.decode(Int.self, forKey: .ttlSeconds))
        self.armedBy = try c.decode(ArmProvenance.self, forKey: .armedBy)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter JournalRecordTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Mutation-check the clamp**

Temporarily change `Self.clamp(try c.decode(...))` to `try c.decode(...)` in `init(from:)`.
Run: `swift test --filter ttlIsClampedToEightHoursOnDecode`
Expected: FAIL. If it passes, the test is theatre — fix the test before restoring the guard.
Restore the guard and re-run to confirm PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/CoffeeBarCore/JournalRecord.swift \
        Tests/CoffeeBarCoreTests/JournalRecordTests.swift
git commit -s -S -m "feat(core): add JournalRecord with TTL clamped on both paths

The synthesised Codable decoder bypasses init, so a journal on disk could
otherwise carry an unbounded TTL. init(from:) is hand-written to apply the
same 8h cap. Mutation-checked: removing the clamp fails the decode test."
```

---

### Task 4: Core — the watchdog decision function

The heart of the safety guarantee, and the code M3 reuses verbatim. Pure, hermetic, exhaustively tested.

**Files:**
- Create: `Sources/CoffeeBarCore/WatchdogDecision.swift`
- Test: `Tests/CoffeeBarCoreTests/WatchdogDecisionTests.swift`

**Interfaces:**
- Consumes: `JournalRecord`, `ArmProvenance` from Task 3.
- Produces:
  - `public enum RevertReason: String, Codable, Equatable, Sendable` — `ttlExpired`, `heartbeatLost`, `dirtyJournalAtBoot`, `unknownSchema`, `thermalAbort`, `batteryFloor`, `clockAnomaly`
  - `public enum WatchdogDecision: Equatable, Sendable` — `hold`, `revert(RevertReason)`
  - `public enum ThermalLevel: Int, Codable, Sendable` — `nominal=0`, `fair=1`, `serious=2`, `critical=3`
  - `public struct WatchdogPolicy: Equatable, Sendable` — `heartbeatTimeout: TimeInterval = 45`, `batteryFloorPercent: Int = 20`, `knownSchemaVersion: Int = 1`; `static let `default``
  - `public struct WatchdogInputs: Sendable` — `journal: JournalRecord?`, `now: Date`, `lastHeartbeat: Date?`, `isBootEvaluation: Bool`, `thermal: ThermalLevel`, `batteryPercent: Int?`, `onBattery: Bool`
  - `public func decide(_ inputs: WatchdogInputs, policy: WatchdogPolicy = .default) -> WatchdogDecision`

**Precedence (must be honoured in this order):** no journal → `hold`; unknown schema → `revert(.unknownSchema)`; boot evaluation → `revert(.dirtyJournalAtBoot)`; clock before `setAt` → `revert(.clockAnomaly)`; thermal ≥ serious → `revert(.thermalAbort)`; on battery at or below floor → `revert(.batteryFloor)`; TTL expired → `revert(.ttlExpired)`; heartbeat stale → `revert(.heartbeatLost)`; else `hold`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CoffeeBarCoreTests/WatchdogDecisionTests.swift`:

```swift
import Testing
import Foundation
@testable import CoffeeBarCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private let prov = ArmProvenance(pid: 1, binaryPath: "/x", uid: 501)

private func journal(ttl: Int = 900, schema: Int = 1,
                     prior: Bool = false) -> JournalRecord {
    JournalRecord(schemaVersion: schema, intent: .sleepDisabled,
                  priorValue: prior, setAt: t0, ttlSeconds: ttl, armedBy: prov)
}

private func inputs(journal j: JournalRecord? = journal(),
                    now: Date = t0.addingTimeInterval(10),
                    heartbeat: Date? = t0.addingTimeInterval(10),
                    boot: Bool = false,
                    thermal: ThermalLevel = .nominal,
                    battery: Int? = 80,
                    onBattery: Bool = false) -> WatchdogInputs {
    WatchdogInputs(journal: j, now: now, lastHeartbeat: heartbeat,
                   isBootEvaluation: boot, thermal: thermal,
                   batteryPercent: battery, onBattery: onBattery)
}

@Test func noJournalMeansNothingToRevert() {
    #expect(decide(inputs(journal: nil)) == .hold)
}

@Test func healthyArmedStateHolds() {
    #expect(decide(inputs()) == .hold)
}

@Test func expiredTTLReverts() {
    #expect(decide(inputs(now: t0.addingTimeInterval(901),
                          heartbeat: t0.addingTimeInterval(900)))
            == .revert(.ttlExpired))
}

@Test func ttlBoundaryIsNotYetExpired() {
    // Exactly at expiry is still live; one second later is not.
    #expect(decide(inputs(now: t0.addingTimeInterval(900),
                          heartbeat: t0.addingTimeInterval(900))) == .hold)
}

@Test func staleHeartbeatReverts() {
    #expect(decide(inputs(now: t0.addingTimeInterval(100),
                          heartbeat: t0.addingTimeInterval(50)))
            == .revert(.heartbeatLost))
}

@Test func missingHeartbeatReverts() {
    #expect(decide(inputs(now: t0.addingTimeInterval(100), heartbeat: nil))
            == .revert(.heartbeatLost))
}

@Test func bootWithDirtyJournalRevertsUnconditionally() {
    // Handoff §8.2(4): an unclean exit is not a state we reason about.
    // Even a perfectly live TTL and fresh heartbeat must revert at boot.
    #expect(decide(inputs(boot: true)) == .revert(.dirtyJournalAtBoot))
}

@Test func unknownSchemaOutranksEverything() {
    #expect(decide(inputs(journal: journal(schema: 99)))
            == .revert(.unknownSchema))
}

@Test func clockJumpBackwardsReverts() {
    // now < setAt means the clock moved; TTL arithmetic is untrustworthy.
    #expect(decide(inputs(now: t0.addingTimeInterval(-60),
                          heartbeat: t0.addingTimeInterval(-60)))
            == .revert(.clockAnomaly))
}

@Test func seriousThermalRevertsWhileArmed() {
    #expect(decide(inputs(thermal: .serious)) == .revert(.thermalAbort))
    #expect(decide(inputs(thermal: .critical)) == .revert(.thermalAbort))
}

@Test func fairThermalDoesNotRevert() {
    #expect(decide(inputs(thermal: .fair)) == .hold)
}

@Test func batteryFloorRevertsOnlyOnBattery() {
    #expect(decide(inputs(battery: 20, onBattery: true))
            == .revert(.batteryFloor))
    #expect(decide(inputs(battery: 19, onBattery: true))
            == .revert(.batteryFloor))
    // Same percentage on AC is fine — it is charging.
    #expect(decide(inputs(battery: 19, onBattery: false)) == .hold)
}

@Test func unknownBatteryDoesNotTriggerFloor() {
    #expect(decide(inputs(battery: nil, onBattery: true)) == .hold)
}

@Test func bootEvaluationOutranksThermalAndTTL() {
    #expect(decide(inputs(now: t0.addingTimeInterval(99_999), boot: true,
                          thermal: .critical))
            == .revert(.dirtyJournalAtBoot))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter WatchdogDecisionTests`
Expected: FAIL — `cannot find 'decide' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CoffeeBarCore/WatchdogDecision.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum RevertReason: String, Codable, Equatable, Sendable {
    case ttlExpired
    case heartbeatLost
    case dirtyJournalAtBoot
    case unknownSchema
    case thermalAbort
    case batteryFloor
    case clockAnomaly
}

public enum WatchdogDecision: Equatable, Sendable {
    case hold
    case revert(RevertReason)
}

/// Mirror of `ProcessInfo.ThermalState`, redeclared so Core stays
/// Foundation-only and CI-testable without the real enum's platform
/// availability.
public enum ThermalLevel: Int, Codable, Sendable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3
}

public struct WatchdogPolicy: Equatable, Sendable {
    public let heartbeatTimeout: TimeInterval
    public let batteryFloorPercent: Int
    public let knownSchemaVersion: Int

    public static let `default` = WatchdogPolicy(
        heartbeatTimeout: 45, batteryFloorPercent: 20, knownSchemaVersion: 1)

    public init(heartbeatTimeout: TimeInterval, batteryFloorPercent: Int,
                knownSchemaVersion: Int) {
        self.heartbeatTimeout = heartbeatTimeout
        self.batteryFloorPercent = batteryFloorPercent
        self.knownSchemaVersion = knownSchemaVersion
    }
}

public struct WatchdogInputs: Sendable {
    public let journal: JournalRecord?
    public let now: Date
    public let lastHeartbeat: Date?
    public let isBootEvaluation: Bool
    public let thermal: ThermalLevel
    public let batteryPercent: Int?
    public let onBattery: Bool

    public init(journal: JournalRecord?, now: Date, lastHeartbeat: Date?,
                isBootEvaluation: Bool, thermal: ThermalLevel,
                batteryPercent: Int?, onBattery: Bool) {
        self.journal = journal
        self.now = now
        self.lastHeartbeat = lastHeartbeat
        self.isBootEvaluation = isBootEvaluation
        self.thermal = thermal
        self.batteryPercent = batteryPercent
        self.onBattery = onBattery
    }
}

/// Decides whether `SleepDisabled` may stay set.
///
/// Every branch except the first resolves toward reverting: when in doubt,
/// let the machine sleep. Precedence is deliberate and covered by tests —
/// boot recovery outranks thermal, which outranks TTL.
public func decide(_ inputs: WatchdogInputs,
                   policy: WatchdogPolicy = .default) -> WatchdogDecision {
    guard let journal = inputs.journal else { return .hold }

    if journal.schemaVersion != policy.knownSchemaVersion {
        return .revert(.unknownSchema)
    }
    if inputs.isBootEvaluation {
        return .revert(.dirtyJournalAtBoot)
    }
    if inputs.now < journal.setAt {
        return .revert(.clockAnomaly)
    }
    if inputs.thermal.rawValue >= ThermalLevel.serious.rawValue {
        return .revert(.thermalAbort)
    }
    if inputs.onBattery, let pct = inputs.batteryPercent,
       pct <= policy.batteryFloorPercent {
        return .revert(.batteryFloor)
    }
    if inputs.now > journal.expiry {
        return .revert(.ttlExpired)
    }
    guard let beat = inputs.lastHeartbeat,
          inputs.now.timeIntervalSince(beat) <= policy.heartbeatTimeout else {
        return .revert(.heartbeatLost)
    }
    return .hold
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter WatchdogDecisionTests`
Expected: PASS, 14 tests.

- [ ] **Step 5: Mutation-check every safety branch**

For each guard below, comment it out, run the named test, confirm FAIL, then restore:

| Guard removed | Test that must fail |
|---|---|
| `schemaVersion` check | `unknownSchemaOutranksEverything` |
| `isBootEvaluation` check | `bootWithDirtyJournalRevertsUnconditionally` |
| `now < setAt` check | `clockJumpBackwardsReverts` |
| thermal check | `seriousThermalRevertsWhileArmed` |
| battery floor check | `batteryFloorRevertsOnlyOnBattery` |
| `now > expiry` check | `expiredTTLReverts` |
| heartbeat guard | `staleHeartbeatReverts` |

Any guard whose removal leaves the suite green means that test is theatre. Fix the test, not the guard.

- [ ] **Step 6: Commit**

```bash
git add Sources/CoffeeBarCore/WatchdogDecision.swift \
        Tests/CoffeeBarCoreTests/WatchdogDecisionTests.swift
git commit -s -S -m "feat(core): add pure watchdog decision function

Implements handoff §8.2 precedence: boot recovery outranks thermal, which
outranks TTL, which outranks heartbeat. Every branch resolves toward
reverting. All seven guards mutation-checked."
```

---

### Task 5: Power — durable journal persistence

**Files:**
- Create: `Sources/CoffeeBarPower/JournalStore.swift`
- Test: `Tests/CoffeeBarPowerTests/JournalStoreTests.swift`

**Interfaces:**
- Consumes: `JournalRecord` from Task 3.
- Produces:
  - `public protocol JournalStoring: Sendable` — `func load() throws -> JournalRecord?`, `func write(_ record: JournalRecord) throws`, `func clear() throws`
  - `public struct FileJournalStore: JournalStoring` — `init(url: URL)`; `public static let systemURL: URL` = `/Library/Application Support/coffee-bar/state/probe-journal.json`
  - `public enum JournalError: Error, Equatable` — `writeFailed(String)`, `syncFailed(Int32)`, `corrupt(String)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CoffeeBarPowerTests/JournalStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import CoffeeBarPower
@testable import CoffeeBarCore

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("cb-journal-\(UUID().uuidString)")
        .appendingPathComponent("probe-journal.json")
}

private let prov = ArmProvenance(pid: 7, binaryPath: "/x", uid: 501)

private func sample(prior: Bool = false) -> JournalRecord {
    JournalRecord(intent: .sleepDisabled, priorValue: prior,
                  setAt: Date(timeIntervalSince1970: 1_000_000),
                  ttlSeconds: 900, armedBy: prov)
}

@Test func loadOnMissingFileReturnsNil() throws {
    let store = FileJournalStore(url: tempURL())
    #expect(try store.load() == nil)
}

@Test func writeThenLoadRoundTrips() throws {
    let store = FileJournalStore(url: tempURL())
    let record = sample(prior: true)
    try store.write(record)
    #expect(try store.load() == record)
}

@Test func writeCreatesIntermediateDirectories() throws {
    let url = tempURL()
    let store = FileJournalStore(url: url)
    try store.write(sample())
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func clearRemovesTheJournal() throws {
    let url = tempURL()
    let store = FileJournalStore(url: url)
    try store.write(sample())
    try store.clear()
    #expect(try store.load() == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func clearOnMissingFileIsNotAnError() throws {
    let store = FileJournalStore(url: tempURL())
    try store.clear()   // must not throw
    #expect(try store.load() == nil)
}

@Test func corruptJournalThrowsRatherThanReturningNil() throws {
    // A corrupt journal must NOT look like "no journal" — that would let a
    // set SleepDisabled flag go unnoticed. The caller reverts on error.
    let url = tempURL()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: url)
    let store = FileJournalStore(url: url)
    #expect(throws: JournalError.self) { try store.load() }
}

@Test func writeIsAtomicUnderOverwrite() throws {
    let url = tempURL()
    let store = FileJournalStore(url: url)
    try store.write(sample(prior: false))
    try store.write(sample(prior: true))
    #expect(try store.load()?.priorValue == true)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter JournalStoreTests`
Expected: FAIL — `cannot find 'FileJournalStore' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CoffeeBarPower/JournalStore.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoffeeBarCore

public enum JournalError: Error, Equatable {
    case writeFailed(String)
    case syncFailed(Int32)
    case corrupt(String)
}

public protocol JournalStoring: Sendable {
    func load() throws -> JournalRecord?
    func write(_ record: JournalRecord) throws
    func clear() throws
}

public struct FileJournalStore: JournalStoring {
    public static let systemURL = URL(
        fileURLWithPath:
            "/Library/Application Support/coffee-bar/state/probe-journal.json")

    private let url: URL

    public init(url: URL = FileJournalStore.systemURL) {
        self.url = url
    }

    public func load() throws -> JournalRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(JournalRecord.self, from: data)
        } catch {
            // Deliberately NOT nil: a corrupt journal must not be mistaken
            // for "nothing was armed". Callers revert on this error.
            throw JournalError.corrupt(String(describing: error))
        }
    }

    /// Writes to a sibling temp file, forces it to stable storage with
    /// `F_FULLFSYNC`, then atomically renames. Plain `fsync(2)` on macOS
    /// only pushes to the drive cache and can be lost on power failure —
    /// `F_FULLFSYNC` is the documented durable barrier.
    public func write(_ record: JournalRecord) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)

        let data = try JSONEncoder().encode(record)
        let tmp = dir.appendingPathComponent(".probe-journal.\(UUID().uuidString).tmp")

        guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else {
            throw JournalError.writeFailed("could not create \(tmp.path)")
        }
        let handle = try FileHandle(forWritingTo: tmp)
        do {
            try handle.write(contentsOf: data)
            if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 {
                throw JournalError.syncFailed(errno)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }

        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter JournalStoreTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Mutation-check the corrupt-journal guard**

Change the `catch` in `load()` to `return nil`.
Run: `swift test --filter corruptJournalThrowsRatherThanReturningNil`
Expected: FAIL. Restore and confirm PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/CoffeeBarPower/JournalStore.swift \
        Tests/CoffeeBarPowerTests/JournalStoreTests.swift
git commit -s -S -m "feat(power): add durable atomic journal store

Uses fcntl(F_FULLFSYNC) rather than fsync(2): on macOS the latter only
reaches the drive cache. A corrupt journal throws rather than reading as
absent, so a set flag can never be mistaken for an unarmed machine."
```

---

### Task 6: Power — command runner seam and the pmset controller

`CommandRunner` is the single place a `Process` is constructed, which is what makes PATH-shim failure injection possible in the next step.

**Files:**
- Create: `Sources/CoffeeBarPower/CommandRunner.swift`
- Create: `Sources/CoffeeBarPower/SleepDisabledController.swift`
- Test: `Tests/CoffeeBarPowerTests/SleepDisabledControllerTests.swift`

**Interfaces:**
- Consumes: nothing from prior tasks.
- Produces:
  - `public struct CommandResult: Equatable, Sendable` — `exitCode: Int32`, `stdout: String`, `stderr: String`
  - `public protocol CommandRunning: Sendable` — `func run(_ executable: String, _ arguments: [String]) throws -> CommandResult`
  - `public struct SystemCommandRunner: CommandRunning` — `init(searchPath: [String]? = nil)`
  - `public protocol SleepDisabledControlling: Sendable` — `func isEnabled() throws -> Bool`, `func set(_ on: Bool) throws`
  - `public struct PmsetSleepDisabledController: SleepDisabledControlling` — `init(runner: any CommandRunning)`
  - `public enum PowerControlError: Error, Equatable` — `commandFailed(exitCode: Int32, stderr: String)`, `unreadableState(String)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CoffeeBarPowerTests/SleepDisabledControllerTests.swift`:

```swift
import Testing
import Foundation
@testable import CoffeeBarPower

private struct FakeRunner: CommandRunning {
    let result: CommandResult
    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        result
    }
}

private struct RecordingRunner: CommandRunning, @unchecked Sendable {
    final class Box: @unchecked Sendable { var calls: [[String]] = [] }
    let box = Box()
    let result: CommandResult
    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        box.calls.append([executable] + arguments)
        return result
    }
}

@Test func readsSleepDisabledTrueFromPmsetOutput() throws {
    let runner = FakeRunner(result: CommandResult(
        exitCode: 0, stdout: "System-wide power settings:\n SleepDisabled\t1\n",
        stderr: ""))
    let c = PmsetSleepDisabledController(runner: runner)
    #expect(try c.isEnabled() == true)
}

@Test func readsSleepDisabledFalseWhenKeyAbsent() throws {
    // Verified on macOS 26.5.2: when unset, pmset -g omits the key entirely.
    let runner = FakeRunner(result: CommandResult(
        exitCode: 0, stdout: "System-wide power settings:\n DestroyFVKeyOnStandby\t0\n",
        stderr: ""))
    let c = PmsetSleepDisabledController(runner: runner)
    #expect(try c.isEnabled() == false)
}

@Test func readsSleepDisabledFalseWhenExplicitlyZero() throws {
    let runner = FakeRunner(result: CommandResult(
        exitCode: 0, stdout: " SleepDisabled\t0\n", stderr: ""))
    let c = PmsetSleepDisabledController(runner: runner)
    #expect(try c.isEnabled() == false)
}

@Test func nonZeroExitOnReadThrows() {
    let runner = FakeRunner(result: CommandResult(
        exitCode: 1, stdout: "", stderr: "pmset: boom"))
    let c = PmsetSleepDisabledController(runner: runner)
    #expect(throws: PowerControlError.self) { try c.isEnabled() }
}

@Test func setIssuesTheExactDisablesleepInvocation() throws {
    let runner = RecordingRunner(result: CommandResult(
        exitCode: 0, stdout: "", stderr: ""))
    let c = PmsetSleepDisabledController(runner: runner)
    try c.set(true)
    #expect(runner.box.calls == [["/usr/bin/pmset", "-a", "disablesleep", "1"]])
}

@Test func setFalseIssuesZero() throws {
    let runner = RecordingRunner(result: CommandResult(
        exitCode: 0, stdout: "", stderr: ""))
    let c = PmsetSleepDisabledController(runner: runner)
    try c.set(false)
    #expect(runner.box.calls == [["/usr/bin/pmset", "-a", "disablesleep", "0"]])
}

@Test func setSurfacesFailureWithExitCodeAndStderr() {
    let runner = FakeRunner(result: CommandResult(
        exitCode: 1, stdout: "", stderr: "must be run as root"))
    let c = PmsetSleepDisabledController(runner: runner)
    #expect(throws: PowerControlError.commandFailed(
        exitCode: 1, stderr: "must be run as root")) { try c.set(true) }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SleepDisabledControllerTests`
Expected: FAIL — `cannot find 'PmsetSleepDisabledController' in scope`.

- [ ] **Step 3: Write `CommandRunner.swift`**

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult
}

/// The only place in the codebase that constructs a `Process`. Keeping this
/// a single seam is what lets tests inject a failing binary via PATH rather
/// than via environment tricks that only misbehave inside a sandbox.
public struct SystemCommandRunner: CommandRunning {
    private let searchPath: [String]?

    public init(searchPath: [String]? = nil) {
        self.searchPath = searchPath
    }

    public func run(_ executable: String,
                    _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let searchPath {
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = searchPath.joined(separator: ":")
            process.environment = env
        }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }
}
```

- [ ] **Step 4: Write `SleepDisabledController.swift`**

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum PowerControlError: Error, Equatable {
    case commandFailed(exitCode: Int32, stderr: String)
    case unreadableState(String)
}

public protocol SleepDisabledControlling: Sendable {
    func isEnabled() throws -> Bool
    func set(_ on: Bool) throws
}

/// Reads and writes the undocumented `SleepDisabled` system power setting.
///
/// Verified on macOS 26.5.2 (25F84): `disablesleep` appears zero times in
/// `man pmset`, and when unset the key is omitted from `pmset -g` entirely
/// rather than printed as 0. It persists in
/// `/Library/Preferences/com.apple.PowerManagement.plist` under
/// `SystemPowerSettings`, so it survives reboot.
public struct PmsetSleepDisabledController: SleepDisabledControlling {
    public static let pmsetPath = "/usr/bin/pmset"

    private let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    public func isEnabled() throws -> Bool {
        let r = try runner.run(Self.pmsetPath, ["-g"])
        guard r.exitCode == 0 else {
            throw PowerControlError.commandFailed(
                exitCode: r.exitCode, stderr: r.stderr)
        }
        for line in r.stdout.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count >= 2, fields[0] == "SleepDisabled" {
                return fields[1] == "1"
            }
        }
        return false   // key absent means unset
    }

    public func set(_ on: Bool) throws {
        let r = try runner.run(Self.pmsetPath,
                               ["-a", "disablesleep", on ? "1" : "0"])
        guard r.exitCode == 0 else {
            throw PowerControlError.commandFailed(
                exitCode: r.exitCode, stderr: r.stderr)
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter SleepDisabledControllerTests`
Expected: PASS, 7 tests.

- [ ] **Step 6: Add the PATH-shim failure-injection test**

Append to `Tests/CoffeeBarPowerTests/SleepDisabledControllerTests.swift`:

```swift
@Test func realRunnerSurfacesExitCodeFromAFailingBinary() throws {
    // Failure is injected with a real failing executable on disk, NOT by
    // corrupting the environment. Environment tricks such as
    // TMPDIR=/nonexistent only fail inside the agent sandbox and are
    // theatre in CI and user shells.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cb-shim-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let shim = dir.appendingPathComponent("pmset")
    try Data("#!/bin/sh\necho 'must be run as root' >&2\nexit 3\n".utf8)
        .write(to: shim)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: shim.path)

    let runner = SystemCommandRunner()
    let result = try runner.run(shim.path, ["-a", "disablesleep", "1"])
    #expect(result.exitCode == 3)                       // exact rc, not != 0
    #expect(result.stderr.contains("must be run as root"))
}
```

Run: `swift test --filter realRunnerSurfacesExitCodeFromAFailingBinary`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/CoffeeBarPower/CommandRunner.swift \
        Sources/CoffeeBarPower/SleepDisabledController.swift \
        Tests/CoffeeBarPowerTests/SleepDisabledControllerTests.swift
git commit -s -S -m "feat(power): add command runner seam and pmset controller

Absent SleepDisabled key reads as false, matching observed macOS 26.5.2
behaviour where pmset -g omits the key when unset. Failure injection uses
an on-disk PATH shim asserting the exact exit code, not environment
corruption that only misbehaves under a sandbox."
```

---

### Task 7: Power — host stamp and baseline probes

**Files:**
- Create: `Sources/CoffeeBarPower/BaselineProbes.swift`
- Test: `Tests/CoffeeBarPowerTests/BaselineProbeTests.swift`

**Interfaces:**
- Consumes: `HostStamp`, `SpikeResult`, `Verdict`, `SpikeID`, `ThermalLevel` from Core.
- Produces:
  - `public enum HostInfo` — `public static func stamp() -> HostStamp`
  - `public protocol PowerReading: Sendable` — `func thermalLevel() -> ThermalLevel`, `func batteryPercent() -> Int?`, `func isOnBattery() -> Bool`
  - `public struct SystemPowerReader: PowerReading` — `init()`
  - `public struct AssertionProbe` — `init()`, `func run() -> SpikeResult`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CoffeeBarPowerTests/BaselineProbeTests.swift`:

```swift
import Testing
import Foundation
@testable import CoffeeBarPower
@testable import CoffeeBarCore

@Test func hostStampIsPopulatedFromTheRunningMachine() {
    let s = HostInfo.stamp()
    #expect(!s.hardwareModel.isEmpty)
    #expect(!s.osBuild.isEmpty)
    #expect(s.osVersion.split(separator: ".").count >= 2)
    #expect(s.arch == "arm64" || s.arch == "x86_64")
}

@Test func hostStampBuildLooksLikeADarwinBuildIdentifier() {
    // e.g. "25F84" — digits, letter, digits. A verdict is worthless without it.
    let build = HostInfo.stamp().osBuild
    #expect(build.rangeOfCharacter(from: .decimalDigits) != nil)
    #expect(build.rangeOfCharacter(from: .uppercaseLetters) != nil)
}

@Test func assertionProbeAcquiresAndReleasesCleanly() {
    // Verified reachable in this environment: IOPMAssertionCreateWithName
    // returned rc=0 on macOS 26.5.2.
    let result = AssertionProbe().run()
    #expect(result.id == .baseline)
    #expect(result.verdict == .pass)
    #expect(result.evidence["assertionReturnCode"] == "0")
}

@Test func powerReaderReportsAConsistentPowerSource() {
    let reader = SystemPowerReader()
    let pct = reader.batteryPercent()
    if let pct { #expect(pct >= 0 && pct <= 100) }
    // Thermal must be one of the four documented levels.
    #expect(ThermalLevel(rawValue: reader.thermalLevel().rawValue) != nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter BaselineProbeTests`
Expected: FAIL — `cannot find 'HostInfo' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CoffeeBarPower/BaselineProbes.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import CoffeeBarCore

public enum HostInfo {
    public static func stamp() -> HostStamp {
        HostStamp(hardwareModel: sysctlString("hw.model"),
                  osVersion: ProcessInfo.processInfo
                      .operatingSystemVersionString.osVersionNumber(),
                  osBuild: sysctlString("kern.osversion"),
                  arch: sysctlString("hw.machine"))
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }
}

private extension String {
    /// "Version 26.5.2 (Build 25F84)" -> "26.5.2"
    func osVersionNumber() -> String {
        let parts = split(separator: " ")
        guard parts.count >= 2 else { return self }
        return String(parts[1])
    }
}

public protocol PowerReading: Sendable {
    func thermalLevel() -> ThermalLevel
    func batteryPercent() -> Int?
    func isOnBattery() -> Bool
}

public struct SystemPowerReader: PowerReading {
    public init() {}

    public func thermalLevel() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return .nominal
        case .fair:     return .fair
        case .serious:  return .serious
        case .critical: return .critical
        @unknown default: return .critical   // unknown means treat as worst
        }
    }

    public func batteryPercent() -> Int? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?
                  .takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return Int((Double(current) / Double(max)) * 100.0)
        }
        return nil
    }

    public func isOnBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return false
        }
        let source = IOPSGetProvidingPowerSourceType(blob)?
            .takeRetainedValue() as String?
        return source == kIOPSBatteryPowerValue
    }
}

/// Baseline: prove we can hold and release the assertion KeepingYouAwake
/// uses. This is the M1 floor — if it fails, nothing else matters.
public struct AssertionProbe {
    public init() {}

    public func run() -> SpikeResult {
        let start = Date()
        var assertionID: IOPMAssertionID = 0
        let rc = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "coffee-bar probe baseline" as CFString,
            &assertionID)
        let released: Bool
        if rc == kIOReturnSuccess {
            released = IOPMAssertionRelease(assertionID) == kIOReturnSuccess
        } else {
            released = false
        }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        return SpikeResult(
            id: .baseline,
            verdict: rc == kIOReturnSuccess && released ? .pass : .fail,
            detail: rc == kIOReturnSuccess
                ? "PreventUserIdleSystemSleep acquired and released"
                : "IOPMAssertionCreateWithName failed",
            durationMS: ms,
            evidence: ["assertionReturnCode": String(rc),
                       "released": String(released)])
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter BaselineProbeTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/CoffeeBarPower/BaselineProbes.swift \
        Tests/CoffeeBarPowerTests/BaselineProbeTests.swift
git commit -s -S -m "feat(power): add host stamp and assertion/thermal/battery baseline

Unknown thermal states map to .critical so an unrecognised future value
fails safe. Host stamp is read from sysctl so every report records the OS
build the verdict was measured on."
```

---

### Task 8: Power — S3 energy fields and S5 demotion privilege

**Files:**
- Create: `Sources/CoffeeBarPower/EnergyProbe.swift`
- Create: `Sources/CoffeeBarPower/DemotionProbe.swift`
- Test: `Tests/CoffeeBarPowerTests/SpikeProbeTests.swift`

**Interfaces:**
- Consumes: `SpikeResult`, `Verdict`, `SpikeID`.
- Produces:
  - `public struct EnergyProbe` — `init()`, `func run(targetPID: pid_t?) -> SpikeResult`
  - `public struct DemotionProbe` — `init()`, `func run(targetPID: pid_t?) -> SpikeResult`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CoffeeBarPowerTests/SpikeProbeTests.swift`:

```swift
import Testing
import Foundation
@testable import CoffeeBarPower
@testable import CoffeeBarCore

@Test func energyProbeReportsAgainstOwnProcess() {
    let r = EnergyProbe().run(targetPID: getpid())
    #expect(r.id == .s3EnergyFields)
    // Own process must always be readable; anything else is a real finding.
    #expect(r.verdict == .pass || r.verdict == .fail)
    #expect(r.evidence["rusageFlavor"] != nil)
}

@Test func energyProbeWithNoTargetIsNotApplicableNotAFailure() {
    let r = EnergyProbe().run(targetPID: nil)
    #expect(r.verdict == .notApplicable)
}

@Test func demotionProbeOnOwnProcessRoundTrips() {
    // Demoting ourselves and restoring must leave no lasting change.
    let r = DemotionProbe().run(targetPID: getpid())
    #expect(r.id == .s5DemotionPrivilege)
    #expect(r.evidence["demoteReturn"] != nil)
    #expect(r.evidence["restoreReturn"] != nil)
    // Guarantee the probe cleaned up after itself.
    #expect(r.evidence["finalStateRestored"] == "true")
}

@Test func demotionProbeWithNoTargetIsNotApplicable() {
    let r = DemotionProbe().run(targetPID: nil)
    #expect(r.verdict == .notApplicable)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SpikeProbeTests`
Expected: FAIL — `cannot find 'EnergyProbe' in scope`.

- [ ] **Step 3: Write `EnergyProbe.swift`**

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin
import CoffeeBarCore

/// S3 — are `proc_pid_rusage` energy fields populated, and for whom?
///
/// Handoff §3 lists `ri_billed_energy` as the same source Activity Monitor's
/// Energy Impact derives from. The open question is whether it is readable
/// for processes this app does not own, without an extra entitlement.
public struct EnergyProbe {
    public init() {}

    public func run(targetPID: pid_t?) -> SpikeResult {
        guard let pid = targetPID else {
            return SpikeResult(
                id: .s3EnergyFields, verdict: .notApplicable,
                detail: "no target process supplied", durationMS: 0,
                evidence: [:])
        }
        let start = Date()
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        let ms = Int(Date().timeIntervalSince(start) * 1000)

        guard rc == 0 else {
            return SpikeResult(
                id: .s3EnergyFields, verdict: .fail,
                detail: "proc_pid_rusage failed (errno \(errno)) for pid \(pid)",
                durationMS: ms,
                evidence: ["rusageFlavor": "V4", "returnCode": String(rc),
                           "errno": String(errno), "pid": String(pid)])
        }

        let billed = info.ri_billed_energy
        let populated = billed > 0
        return SpikeResult(
            id: .s3EnergyFields,
            verdict: populated ? .pass : .fail,
            detail: populated
                ? "ri_billed_energy populated for pid \(pid)"
                : "proc_pid_rusage succeeded but ri_billed_energy is zero",
            durationMS: ms,
            evidence: ["rusageFlavor": "V4",
                       "returnCode": String(rc),
                       "ri_billed_energy": String(billed),
                       "ri_interrupt_wkups": String(info.ri_interrupt_wkups),
                       "pid": String(pid)])
    }
}
```

- [ ] **Step 4: Write `DemotionProbe.swift`**

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin
import CoffeeBarCore

/// S5 — does `setpriority(PRIO_DARWIN_BG)` succeed on a same-uid process,
/// and does clearing it work?
///
/// Handoff §2.1: this is a brake, never an accelerator. There is no
/// mechanism to promote a process onto P-cores, and the probe must not
/// imply otherwise.
public struct DemotionProbe {
    public init() {}

    public func run(targetPID: pid_t?) -> SpikeResult {
        guard let pid = targetPID else {
            return SpikeResult(
                id: .s5DemotionPrivilege, verdict: .notApplicable,
                detail: "no target process supplied", durationMS: 0,
                evidence: [:])
        }
        let start = Date()

        errno = 0
        let demote = setpriority(PRIO_DARWIN_BG, id_t(pid), 0)
        let demoteErrno = errno

        errno = 0
        let restore = setpriority(PRIO_DARWIN_BG, id_t(pid), 1)
        let restoreErrno = errno

        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let restored = restore == 0
        let ok = demote == 0 && restored

        return SpikeResult(
            id: .s5DemotionPrivilege,
            verdict: ok ? .pass : .fail,
            detail: ok
                ? "demoted pid \(pid) to background QoS and restored it"
                : "demote rc=\(demote) errno=\(demoteErrno), "
                  + "restore rc=\(restore) errno=\(restoreErrno)",
            durationMS: ms,
            evidence: ["demoteReturn": String(demote),
                       "demoteErrno": String(demoteErrno),
                       "restoreReturn": String(restore),
                       "restoreErrno": String(restoreErrno),
                       "finalStateRestored": String(restored),
                       "pid": String(pid)])
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter SpikeProbeTests`
Expected: PASS, 4 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/CoffeeBarPower/EnergyProbe.swift \
        Sources/CoffeeBarPower/DemotionProbe.swift \
        Tests/CoffeeBarPowerTests/SpikeProbeTests.swift
git commit -s -S -m "feat(power): add S3 energy-field and S5 demotion probes

Both restore any state they touch and report notApplicable rather than
fail when given no target, so a missing third-party app does not read as a
capability failure."
```

---

### Task 9: Power — S8 telemetry collision recon

**Files:**
- Create: `Sources/CoffeeBarPower/TelemetryRecon.swift`
- Test: `Tests/CoffeeBarPowerTests/TelemetryReconTests.swift`

**Interfaces:**
- Consumes: `SpikeResult`, `Verdict`, `SpikeID`.
- Produces:
  - `public enum TelemetryMode: String, Codable, Sendable` — `ownIt`, `fanOut`, `passive`
  - `public struct TelemetryRecon` — `init(managedSettingsURL: URL, userSettingsURL: URL, codexConfigURL: URL)`, `func run() -> SpikeResult`, `func detectMode() -> TelemetryMode`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CoffeeBarPowerTests/TelemetryReconTests.swift`:

```swift
import Testing
import Foundation
@testable import CoffeeBarPower
@testable import CoffeeBarCore

private func scratch() -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("cb-otel-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func recon(managed: URL? = nil, user: URL? = nil,
                   codex: URL? = nil) -> TelemetryRecon {
    let missing = scratch().appendingPathComponent("absent.json")
    return TelemetryRecon(managedSettingsURL: managed ?? missing,
                          userSettingsURL: user ?? missing,
                          codexConfigURL: codex ?? missing)
}

@Test func noConfigAnywhereMeansOwnIt() {
    // Matches this machine as measured on 2026-07-27.
    #expect(recon().detectMode() == .ownIt)
}

@Test func managedSettingsForcePassiveMode() throws {
    let d = scratch()
    let managed = d.appendingPathComponent("managed-settings.json")
    try Data(#"{"env":{"OTEL_EXPORTER_OTLP_ENDPOINT":"http://corp:4318"}}"#.utf8)
        .write(to: managed)
    // Handoff §15.4: managed settings cannot be displaced, so mode 1 is
    // simply unavailable.
    #expect(recon(managed: managed).detectMode() == .passive)
}

@Test func userScopeOtelMeansFanOut() throws {
    let d = scratch()
    let user = d.appendingPathComponent("settings.json")
    try Data(#"{"env":{"OTEL_EXPORTER_OTLP_ENDPOINT":"http://localhost:4318"}}"#.utf8)
        .write(to: user)
    #expect(recon(user: user).detectMode() == .fanOut)
}

@Test func codexOtelSectionAlsoMeansFanOut() throws {
    let d = scratch()
    let codex = d.appendingPathComponent("config.toml")
    try Data("[otel]\nexporter = \"otlp-http\"\n".utf8).write(to: codex)
    #expect(recon(codex: codex).detectMode() == .fanOut)
}

@Test func managedSettingsOutrankUserSettings() throws {
    let d = scratch()
    let managed = d.appendingPathComponent("managed-settings.json")
    let user = d.appendingPathComponent("settings.json")
    try Data(#"{"env":{"OTEL_EXPORTER_OTLP_ENDPOINT":"http://corp:4318"}}"#.utf8)
        .write(to: managed)
    try Data(#"{"env":{"OTEL_EXPORTER_OTLP_ENDPOINT":"http://me:4318"}}"#.utf8)
        .write(to: user)
    #expect(recon(managed: managed, user: user).detectMode() == .passive)
}

@Test func reconResultCarriesTheModeAsEvidence() {
    let r = recon().run()
    #expect(r.id == .s8TelemetryCollision)
    #expect(r.verdict == .pass)
    #expect(r.evidence["mode"] == "ownIt")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TelemetryReconTests`
Expected: FAIL — `cannot find 'TelemetryRecon' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CoffeeBarPower/TelemetryRecon.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoffeeBarCore

/// Handoff §15.4's three modes.
public enum TelemetryMode: String, Codable, Sendable {
    case ownIt    // no existing config; coffee-bar may write its own
    case fanOut   // user-scope config exists; forward to their endpoint
    case passive  // managed settings present; Token Tap disabled, and says so
}

/// S8 — determine which telemetry mode applies before the Token Tap (§15)
/// is designed. Pure file inspection; no network, no process launch.
///
/// This must be re-evaluated at runtime and never cached: an MDM-managed
/// machine can acquire managed settings at any time.
public struct TelemetryRecon {
    public static let defaultManagedSettingsURL = URL(fileURLWithPath:
        "/Library/Application Support/ClaudeCode/managed-settings.json")

    private let managedSettingsURL: URL
    private let userSettingsURL: URL
    private let codexConfigURL: URL

    public init(managedSettingsURL: URL = TelemetryRecon.defaultManagedSettingsURL,
                userSettingsURL: URL = FileManager.default
                    .homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude/settings.json"),
                codexConfigURL: URL = FileManager.default
                    .homeDirectoryForCurrentUser
                    .appendingPathComponent(".codex/config.toml")) {
        self.managedSettingsURL = managedSettingsURL
        self.userSettingsURL = userSettingsURL
        self.codexConfigURL = codexConfigURL
    }

    public func detectMode() -> TelemetryMode {
        if fileMentionsOTEL(managedSettingsURL) { return .passive }
        if fileMentionsOTEL(userSettingsURL) { return .fanOut }
        if fileHasOtelSection(codexConfigURL) { return .fanOut }
        return .ownIt
    }

    public func run() -> SpikeResult {
        let start = Date()
        let mode = detectMode()
        return SpikeResult(
            id: .s8TelemetryCollision,
            verdict: .pass,
            detail: "telemetry mode: \(mode.rawValue)",
            durationMS: Int(Date().timeIntervalSince(start) * 1000),
            evidence: [
                "mode": mode.rawValue,
                "managedSettingsPresent":
                    String(FileManager.default.fileExists(
                        atPath: managedSettingsURL.path)),
                "userSettingsHasOTEL": String(fileMentionsOTEL(userSettingsURL)),
                "codexHasOtelSection": String(fileHasOtelSection(codexConfigURL)),
            ])
    }

    private func fileMentionsOTEL(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return String(decoding: data, as: UTF8.self).contains("OTEL_")
    }

    private func fileHasOtelSection(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces) == "[otel]" }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TelemetryReconTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/CoffeeBarPower/TelemetryRecon.swift \
        Tests/CoffeeBarPowerTests/TelemetryReconTests.swift
git commit -s -S -m "feat(power): add S8 telemetry collision recon

Managed settings outrank user settings, matching §15.4's note that they
cannot be displaced. Mode is computed on every call, never cached — an
MDM-managed machine can acquire managed settings at any time."
```

---

### Task 10: Probe — CLI wiring, `run` verb, and output formatting

Completes the session's acceptance criteria: `swift run coffee-bar-probe --json` emits a report containing all five spike ids.

**Files:**
- Create: `Sources/CoffeeBarPower/OutputFormatter.swift`
- Create: `Sources/CoffeeBarProbe/RunCommand.swift`
- Create: `Sources/CoffeeBarProbe/main.swift`
- Test: `Tests/CoffeeBarPowerTests/OutputFormatterTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–9.
- Produces: executable `coffee-bar-probe`; `public enum OutputFormatter` with `static func json(_ report: ProbeReport) throws -> String` and `static func human(_ report: ProbeReport) -> String`.

Move `OutputFormatter` into `CoffeeBarPower` so it is reachable from the test target (executable targets are not importable by tests).

- [ ] **Step 1: Write the failing tests**

Create `Tests/CoffeeBarPowerTests/OutputFormatterTests.swift`:

```swift
import Testing
import Foundation
@testable import CoffeeBarPower
@testable import CoffeeBarCore

private let report = ProbeReport(
    generatedAt: Date(timeIntervalSince1970: 1_785_000_000),
    host: HostStamp(hardwareModel: "Mac16,6", osVersion: "26.5.2",
                    osBuild: "25F84", arch: "arm64"),
    spikes: [
        SpikeResult(id: .s1LidCloseSleep, verdict: .notYetRun,
                    detail: "requires an armed run", durationMS: 0, evidence: [:]),
        SpikeResult(id: .s3EnergyFields, verdict: .pass,
                    detail: "populated", durationMS: 4, evidence: [:]),
    ])

@Test func jsonOutputContainsEverySpikeIdentifier() throws {
    let json = try OutputFormatter.json(report)
    #expect(json.contains("\"S1\""))
    #expect(json.contains("\"S3\""))
}

@Test func jsonOutputIsParseableBackIntoAReport() throws {
    let json = try OutputFormatter.json(report)
    let decoded = try JSONDecoder().decode(
        ProbeReport.self, from: Data(json.utf8))
    #expect(decoded == report)
}

@Test func humanOutputNamesTheOSBuild() {
    let text = OutputFormatter.human(report)
    #expect(text.contains("25F84"))
    #expect(text.contains("Mac16,6"))
}

@Test func humanOutputMarksNotYetRunDistinctlyFromFailure() {
    // S1 must never read as a failure just because nobody closed a lid.
    let text = OutputFormatter.human(report)
    #expect(text.contains("not-yet-run"))
    #expect(!text.lowercased().contains("s1 fail"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter OutputFormatterTests`
Expected: FAIL — `cannot find 'OutputFormatter' in scope`.

- [ ] **Step 3: Write `Sources/CoffeeBarPower/OutputFormatter.swift`**

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoffeeBarCore

public enum OutputFormatter {
    public static func json(_ report: ProbeReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }

    public static func human(_ report: ProbeReport) -> String {
        var lines: [String] = []
        lines.append("coffee-bar capability probe")
        lines.append("  host   \(report.host.hardwareModel) "
                     + "\(report.host.arch)")
        lines.append("  os     \(report.host.osVersion) "
                     + "(build \(report.host.osBuild))")
        lines.append("")
        for spike in report.spikes {
            lines.append("  \(spike.id.rawValue.padded(to: 9))"
                         + "\(label(spike.verdict).padded(to: 12))"
                         + spike.detail)
        }
        return lines.joined(separator: "\n")
    }

    private static func label(_ v: Verdict) -> String {
        switch v {
        case .pass:           return "pass"
        case .fail:           return "FAIL"
        case .notApplicable:  return "n/a"
        case .notYetRun:      return "not-yet-run"
        case .error:          return "ERROR"
        }
    }
}

private extension String {
    func padded(to width: Int) -> String {
        count >= width ? self + " " : self + String(repeating: " ", count: width - count)
    }
}
```

- [ ] **Step 4: Write `Sources/CoffeeBarProbe/RunCommand.swift`**

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoffeeBarCore
import CoffeeBarPower

enum RunCommand {
    /// Runs every unprivileged spike. S1 and S2 need an armed run, so they
    /// are reported `notYetRun` here rather than omitted — a missing row
    /// reads as "forgotten", a notYetRun row reads as "pending".
    static func execute() -> ProbeReport {
        var results: [SpikeResult] = []

        results.append(AssertionProbe().run())
        results.append(EnergyProbe().run(targetPID: getpid()))
        results.append(DemotionProbe().run(targetPID: getpid()))
        results.append(TelemetryRecon().run())

        results.append(SpikeResult(
            id: .s1LidCloseSleep, verdict: .notYetRun,
            detail: "run `coffee-bar-probe arm`, close the lid, then `report`",
            durationMS: 0, evidence: [:]))
        results.append(SpikeResult(
            id: .s2DisplayUnderClosedLid, verdict: .notYetRun,
            detail: "measured during an armed run",
            durationMS: 0, evidence: [:]))

        return ProbeReport(generatedAt: Date(),
                           host: HostInfo.stamp(),
                           spikes: results)
    }
}
```

- [ ] **Step 5: Write `Sources/CoffeeBarProbe/main.swift`**

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoffeeBarCore
import CoffeeBarPower

let arguments = Array(CommandLine.arguments.dropFirst())
let wantsJSON = arguments.contains("--json")
let verb = arguments.first(where: { !$0.hasPrefix("--") }) ?? "run"

switch verb {
case "run":
    let report = RunCommand.execute()
    if wantsJSON {
        print((try? OutputFormatter.json(report)) ?? "{}")
    } else {
        print(OutputFormatter.human(report))
    }
    // Exit 0 whenever the probe itself ran. A spike reporting `fail` is a
    // finding about the machine, not a probe malfunction, and must not be
    // conflated with one.
    exit(0)

case "arm", "report", "revert", "watchdog":
    FileHandle.standardError.write(Data(
        "coffee-bar-probe: '\(verb)' lands in Task 11\n".utf8))
    exit(64)

default:
    FileHandle.standardError.write(Data("""
    usage: coffee-bar-probe <verb> [--json]
      run       unprivileged spikes (default)
      arm       set SleepDisabled with a TTL watchdog (root)
      report    read an armed run's samples and verdict
      revert    developer escape hatch: revert and uninstall (root)

    """.utf8))
    exit(64)
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter OutputFormatterTests`
Expected: PASS, 4 tests.

- [ ] **Step 7: Verify the session acceptance criteria**

Run each separately, recording exit codes:

```bash
swift build; echo "build rc=$?"
swift build -c release; echo "release rc=$?"
swift test; echo "test rc=$?"
swift run coffee-bar-probe --json > /tmp/coffee-bar-probe.json; echo "run rc=$?"
jq -e '[.spikes[].id] | contains(["S1","S2","S3","S5","S8"])' /tmp/coffee-bar-probe.json
echo "acceptance rc=$?"
```

Expected: every `rc=0`, and `jq` prints `true`.

- [ ] **Step 8: Commit**

```bash
git add Sources/CoffeeBarPower/OutputFormatter.swift \
        Sources/CoffeeBarProbe/RunCommand.swift \
        Sources/CoffeeBarProbe/main.swift \
        Tests/CoffeeBarPowerTests/OutputFormatterTests.swift
git commit -s -S -m "feat(probe): add run verb, JSON and human output

S1 and S2 appear as notYetRun rather than being omitted, so a pending
spike reads as pending rather than forgotten. Exit code reflects whether
the probe ran, not whether the machine passed."
```

---

### Task 11: Probe — arm, report, revert, watchdog and the launchd installer

The privileged half. Everything here is gated behind root and writes the journal before any mutation.

**Files:**
- Create: `Sources/CoffeeBarPower/LaunchDaemonInstaller.swift`
- Create: `Sources/CoffeeBarPower/DisplayStateProbe.swift`
- Create: `Sources/CoffeeBarProbe/ArmCommand.swift`
- Modify: `Sources/CoffeeBarProbe/main.swift` — replace the exit-64 stub arm
- Test: `Tests/CoffeeBarPowerTests/LaunchDaemonInstallerTests.swift`

**Interfaces:**
- Consumes: `JournalStoring`, `SleepDisabledControlling`, `CommandRunning`, `decide()`, `WatchdogInputs`.
- Produces:
  - `public struct LaunchDaemonInstaller` — `init(runner: any CommandRunning, plistURL: URL)`; `func plistContents(binaryPath: String) -> String`; `func install(binaryPath: String) throws`; `func uninstall() throws`; `public static let label = "com.coffeebar.probewatchdog"`
  - `public struct DisplayStateProbe` — `init()`, `func isInternalDisplayAwake() -> Bool?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CoffeeBarPowerTests/LaunchDaemonInstallerTests.swift`:

```swift
import Testing
import Foundation
@testable import CoffeeBarPower

private struct StubRunner: CommandRunning {
    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        CommandResult(exitCode: 0, stdout: "", stderr: "")
    }
}

private func installer(at url: URL) -> LaunchDaemonInstaller {
    LaunchDaemonInstaller(runner: StubRunner(), plistURL: url)
}

private func scratchPlist() -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("cb-plist-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d.appendingPathComponent("com.coffeebar.probewatchdog.plist")
}

@Test func plistDeclaresRunAtLoadAndKeepAlive() {
    // Handoff §8.2(4): reboot with a dirty journal must revert at load.
    let xml = installer(at: scratchPlist())
        .plistContents(binaryPath: "/usr/local/bin/coffee-bar-probe")
    #expect(xml.contains("<key>RunAtLoad</key>"))
    #expect(xml.contains("<key>KeepAlive</key>"))
}

@Test func plistInvokesTheWatchdogVerbOnTheRealBinary() {
    let xml = installer(at: scratchPlist())
        .plistContents(binaryPath: "/usr/local/bin/coffee-bar-probe")
    #expect(xml.contains("<string>/usr/local/bin/coffee-bar-probe</string>"))
    #expect(xml.contains("<string>watchdog</string>"))
}

@Test func plistIsValidPropertyList() throws {
    let xml = installer(at: scratchPlist())
        .plistContents(binaryPath: "/usr/local/bin/coffee-bar-probe")
    let parsed = try PropertyListSerialization.propertyList(
        from: Data(xml.utf8), options: [], format: nil) as? [String: Any]
    #expect(parsed?["Label"] as? String == "com.coffeebar.probewatchdog")
    #expect(parsed?["RunAtLoad"] as? Bool == true)
    #expect(parsed?["KeepAlive"] as? Bool == true)
}

@Test func installWritesThePlistToDisk() throws {
    let url = scratchPlist()
    try installer(at: url).install(binaryPath: "/usr/local/bin/coffee-bar-probe")
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func uninstallRemovesThePlist() throws {
    let url = scratchPlist()
    let inst = installer(at: url)
    try inst.install(binaryPath: "/usr/local/bin/coffee-bar-probe")
    try inst.uninstall()
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func uninstallOnMissingPlistIsNotAnError() throws {
    try installer(at: scratchPlist()).uninstall()   // must not throw
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter LaunchDaemonInstallerTests`
Expected: FAIL — `cannot find 'LaunchDaemonInstaller' in scope`.

- [ ] **Step 3: Write `LaunchDaemonInstaller.swift`**

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Installs the watchdog as a launchd daemon.
///
/// M0 deliberately uses a plain plist plus `launchctl bootstrap system`
/// rather than `SMAppService`: it needs no app bundle, no code signing and
/// no Xcode. M3 swaps this installer for `SMAppService` and adds XPC; the
/// journal, TTL and revert logic it supervises does not change.
public struct LaunchDaemonInstaller {
    public static let label = "com.coffeebar.probewatchdog"
    public static let systemPlistURL = URL(fileURLWithPath:
        "/Library/LaunchDaemons/\(LaunchDaemonInstaller.label).plist")

    private let runner: any CommandRunning
    private let plistURL: URL

    public init(runner: any CommandRunning,
                plistURL: URL = LaunchDaemonInstaller.systemPlistURL) {
        self.runner = runner
        self.plistURL = plistURL
    }

    public func plistContents(binaryPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(Self.label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
                <string>watchdog</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ProcessType</key>
            <string>Background</string>
        </dict>
        </plist>
        """
    }

    public func install(binaryPath: String) throws {
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(plistContents(binaryPath: binaryPath).utf8).write(to: plistURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: plistURL.path)
        _ = try runner.run("/bin/launchctl",
                           ["bootstrap", "system", plistURL.path])
    }

    public func uninstall() throws {
        _ = try? runner.run("/bin/launchctl",
                            ["bootout", "system/\(Self.label)"])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }
}
```

- [ ] **Step 4: Write `DisplayStateProbe.swift`**

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IOKit

/// S2 — is the internal panel actually powered while the lid is shut?
///
/// Handoff §2.2: raw `disablesleep` leaves the panel lit under a closed lid,
/// silently burning the battery the feature exists to save. `IODisplayWrangler`
/// exposes the display power state; state 4 is fully on.
public struct DisplayStateProbe {
    public init() {}

    /// Returns nil when the wrangler cannot be read, so callers can
    /// distinguish "unknown" from "asleep".
    public func isInternalDisplayAwake() -> Bool? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IODisplayWrangler"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
                service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any],
              let pm = props["IOPowerManagement"] as? [String: Any],
              let current = pm["CurrentPowerState"] as? Int
        else { return nil }

        return current >= 4
    }
}
```

- [ ] **Step 5: Write `Sources/CoffeeBarProbe/ArmCommand.swift`**

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoffeeBarCore
import CoffeeBarPower

enum ArmCommand {
    static let sampleLogURL = URL(fileURLWithPath:
        "/Library/Application Support/coffee-bar/state/probe-samples.jsonl")

    static func requireRoot() {
        guard getuid() == 0 else {
            FileHandle.standardError.write(Data(
                "coffee-bar-probe: this verb requires root (use sudo)\n".utf8))
            exit(77)   // EX_NOPERM
        }
    }

    /// Journal first, fsync, THEN mutate. A crash between the two must
    /// leave evidence, never a silent change (handoff §8.2(1)).
    static func arm(ttlSeconds: Int) {
        requireRoot()
        let runner = SystemCommandRunner()
        let controller = PmsetSleepDisabledController(runner: runner)
        let store = FileJournalStore()

        let prior: Bool
        do {
            prior = try controller.isEnabled()
        } catch {
            FileHandle.standardError.write(Data(
                "arm aborted: cannot read current SleepDisabled: \(error)\n".utf8))
            exit(75)
        }

        let record = JournalRecord(
            intent: .sleepDisabled, priorValue: prior, setAt: Date(),
            ttlSeconds: ttlSeconds,
            armedBy: ArmProvenance(pid: getpid(),
                                   binaryPath: CommandLine.arguments[0],
                                   uid: getuid()))
        do {
            try store.write(record)
        } catch {
            // Fail closed: no journal means no mutation.
            FileHandle.standardError.write(Data(
                "arm aborted: journal write failed: \(error)\n".utf8))
            exit(73)
        }

        do {
            try LaunchDaemonInstaller(runner: runner)
                .install(binaryPath: CommandLine.arguments[0])
            try controller.set(true)
        } catch {
            try? controller.set(prior)
            try? store.clear()
            FileHandle.standardError.write(Data(
                "arm aborted and rolled back: \(error)\n".utf8))
            exit(75)
        }

        print("""
        armed. SleepDisabled=1, prior value \(prior ? "1" : "0"), \
        TTL \(record.ttlSeconds)s (expires \(record.expiry)).
        Close the lid now. Run `coffee-bar-probe report` afterwards.
        The watchdog reverts automatically on TTL, crash, or reboot.
        """)
    }

    static func revert() {
        requireRoot()
        let runner = SystemCommandRunner()
        let controller = PmsetSleepDisabledController(runner: runner)
        let store = FileJournalStore()

        let target = (try? store.load())??.priorValue ?? false
        do {
            try controller.set(target)
            try LaunchDaemonInstaller(runner: runner).uninstall()
            try store.clear()
            print("reverted SleepDisabled to \(target ? "1" : "0").")
        } catch {
            FileHandle.standardError.write(Data(
                "UNSAFE_STATE: revert failed: \(error)\n"
                + "journal left dirty on purpose; next boot will retry.\n".utf8))
            exit(75)
        }
    }

    /// launchd entry point. Ticks every 5s per handoff §8.2(2).
    static func watchdog() {
        requireRoot()
        let runner = SystemCommandRunner()
        let controller = PmsetSleepDisabledController(runner: runner)
        let store = FileJournalStore()
        let reader = SystemPowerReader()
        var isBoot = true

        while true {
            let journal = (try? store.load()) ?? nil
            // In M0 this process IS the only supervisor, so its own liveness
            // is the heartbeat — launchd restarts it if it dies. Passing
            // `journal.setAt` here would make `now - heartbeat` grow without
            // bound and trip `.heartbeatLost` 45s into every armed run,
            // reverting SleepDisabled before any lid-close measurement could
            // finish. The real cross-process heartbeat arrives in M3 over XPC.
            let decision = decide(WatchdogInputs(
                journal: journal, now: Date(),
                lastHeartbeat: Date(),
                isBootEvaluation: isBoot && journal != nil,
                thermal: reader.thermalLevel(),
                batteryPercent: reader.batteryPercent(),
                onBattery: reader.isOnBattery()))
            isBoot = false

            if case .revert(let reason) = decision, let journal {
                try? controller.set(journal.priorValue)
                try? store.clear()
                FileHandle.standardError.write(Data(
                    "watchdog reverted SleepDisabled "
                    + "(\(reason.rawValue))\n".utf8))
            }
            appendSample(reader: reader)
            Thread.sleep(forTimeInterval: 5)
        }
    }

    private static func appendSample(reader: SystemPowerReader) {
        let line = """
        {"ts":\(Date().timeIntervalSince1970),\
        "battery":\(reader.batteryPercent().map(String.init) ?? "null"),\
        "onBattery":\(reader.isOnBattery()),\
        "thermal":\(reader.thermalLevel().rawValue),\
        "displayAwake":\(DisplayStateProbe().isInternalDisplayAwake()
                          .map(String.init) ?? "null")}

        """
        try? FileManager.default.createDirectory(
            at: sampleLogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: sampleLogURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: sampleLogURL)
        }
    }
}
```

- [ ] **Step 6: Replace the stub in `main.swift`**

Replace the `case "arm", "report", "revert", "watchdog":` block with:

```swift
case "arm":
    let ttlIndex = arguments.firstIndex(of: "--ttl").map { $0 + 1 }
    let ttl = ttlIndex.flatMap { arguments.indices.contains($0)
        ? Int(arguments[$0]) : nil } ?? 900
    ArmCommand.arm(ttlSeconds: ttl)

case "revert":
    ArmCommand.revert()

case "watchdog":
    ArmCommand.watchdog()

case "report":
    let report = ReportCommand.execute()
    if wantsJSON {
        print((try? OutputFormatter.json(report)) ?? "{}")
    } else {
        print(OutputFormatter.human(report))
    }
    exit(0)
```

- [ ] **Step 7: Write `ReportCommand` in `Sources/CoffeeBarProbe/ArmCommand.swift`**

Append to the same file:

```swift
enum ReportCommand {
    /// Reads the sample log written during an armed run and decides S1/S2.
    /// A gap longer than 30s between samples means the machine slept —
    /// which is exactly what S1 is asking about.
    static func execute() -> ProbeReport {
        let samples = (try? String(contentsOf: ArmCommand.sampleLogURL,
                                   encoding: .utf8))?
            .split(separator: "\n")
            .compactMap { line -> (Double, Bool?)? in
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data)
                          as? [String: Any],
                      let ts = obj["ts"] as? Double else { return nil }
                return (ts, obj["displayAwake"] as? Bool)
            } ?? []

        guard samples.count >= 2 else {
            return ProbeReport(
                generatedAt: Date(), host: HostInfo.stamp(),
                spikes: [
                    SpikeResult(id: .s1LidCloseSleep, verdict: .notYetRun,
                                detail: "fewer than 2 samples; run `arm` first",
                                durationMS: 0, evidence: [:]),
                    SpikeResult(id: .s2DisplayUnderClosedLid, verdict: .notYetRun,
                                detail: "no samples", durationMS: 0, evidence: [:]),
                ])
        }

        let timestamps = samples.map(\.0).sorted()
        let biggestGap = zip(timestamps, timestamps.dropFirst())
            .map { $1 - $0 }.max() ?? 0
        let stayedAwake = biggestGap < 30
        let anyDisplayAwake = samples.contains { $0.1 == true }

        return ProbeReport(
            generatedAt: Date(), host: HostInfo.stamp(),
            spikes: [
                SpikeResult(
                    id: .s1LidCloseSleep,
                    verdict: stayedAwake ? .pass : .fail,
                    detail: stayedAwake
                        ? "sampling continuous across the window"
                        : "sampling gap of \(Int(biggestGap))s — machine slept",
                    durationMS: 0,
                    evidence: ["sampleCount": String(samples.count),
                               "largestGapSeconds": String(Int(biggestGap)),
                               "windowSeconds":
                                String(Int(timestamps.last! - timestamps.first!))]),
                SpikeResult(
                    id: .s2DisplayUnderClosedLid,
                    verdict: anyDisplayAwake ? .fail : .pass,
                    detail: anyDisplayAwake
                        ? "internal panel was powered during the window"
                        : "internal panel stayed asleep",
                    durationMS: 0,
                    evidence: ["anyDisplayAwakeSample": String(anyDisplayAwake)]),
            ])
    }
}
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test --filter LaunchDaemonInstallerTests`
Expected: PASS, 6 tests.
Run: `swift test`
Expected: PASS, whole suite.

- [ ] **Step 9: Verify the privileged path refuses to run unprivileged**

```bash
swift run coffee-bar-probe arm --ttl 60; echo "rc=$?"
```
Expected: `rc=77` and the message `this verb requires root (use sudo)`. **Do not** run this under `sudo` yet — the live armed run is a separate, deliberate session per spec §1.

- [ ] **Step 10: Commit**

```bash
git add Sources/CoffeeBarPower/LaunchDaemonInstaller.swift \
        Sources/CoffeeBarPower/DisplayStateProbe.swift \
        Sources/CoffeeBarProbe/ArmCommand.swift \
        Sources/CoffeeBarProbe/main.swift \
        Tests/CoffeeBarPowerTests/LaunchDaemonInstallerTests.swift
git commit -s -S -m "feat(probe): add arm, report, revert and watchdog verbs

Journal is written and fsynced before SleepDisabled is touched, and a
failed arm rolls back to the prior value. The launchd plist carries
RunAtLoad and KeepAlive so a SIGKILL or reboot still reverts. A failed
revert deliberately leaves the journal dirty so the next boot retries."
```

---

### Task 12: Homebrew formula and release workflow

**Files:**
- Create: `Formula/coffee-bar.rb`
- Create: `.github/workflows/release.yml`
- Modify: `README.md` — add install instructions

**Interfaces:**
- Consumes: the built `coffee-bar-probe` executable from Task 10.
- Produces: `brew install ArangoGutierrez/coffee-bar/coffee-bar`.

- [ ] **Step 1: Check name availability before publishing**

```bash
brew search coffee-bar; echo "rc=$?"
brew search --cask coffee-bar; echo "rc=$?"
```
Record the result in the commit message. Handoff §16 Q5 requires this before the first public commit. If either name is taken, stop and raise it rather than picking a near-miss.

- [ ] **Step 2: Write `Formula/coffee-bar.rb`**

```ruby
# Copyright 2026 Carlos Eduardo Arango Gutierrez
# SPDX-License-Identifier: Apache-2.0
class CoffeeBar < Formula
  desc "Capability probe for coffee-bar, the agent-aware macOS wake manager"
  homepage "https://github.com/ArangoGutierrez/coffee-bar"
  url "https://github.com/ArangoGutierrez/coffee-bar/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_WITH_RELEASE_TARBALL_SHA256"
  license "Apache-2.0"

  depends_on xcode: ["15.0", :build]
  depends_on :macos
  depends_on macos: :sonoma

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/coffee-bar-probe"
  end

  test do
    output = shell_output("#{bin}/coffee-bar-probe --json")
    assert_match "\"S1\"", output
    assert_match "\"baseline\"", output
  end
end
```

The `sha256` is filled in by the release workflow; it is the one value that cannot be known before the tag exists.

- [ ] **Step 3: Write `.github/workflows/release.yml`**

```yaml
name: Release

on:
  push:
    tags: ["v*"]

permissions:
  contents: write

jobs:
  release:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4

      - name: Build release binary
        run: swift build -c release

      - name: Verify the probe runs
        run: .build/release/coffee-bar-probe --json

      - name: Compute source tarball checksum
        id: sha
        run: |
          URL="https://github.com/${GITHUB_REPOSITORY}/archive/refs/tags/${GITHUB_REF_NAME}.tar.gz"
          curl -fsSL "$URL" -o source.tar.gz
          echo "sha256=$(shasum -a 256 source.tar.gz | cut -d' ' -f1)" >> "$GITHUB_OUTPUT"

      - name: Update formula checksum
        run: |
          /usr/bin/sed -i '' \
            -e "s|REPLACE_WITH_RELEASE_TARBALL_SHA256|${{ steps.sha.outputs.sha256 }}|" \
            -e "s|/tags/v[0-9][^\"]*\.tar\.gz|/tags/${GITHUB_REF_NAME}.tar.gz|" \
            Formula/coffee-bar.rb
          grep -c "${{ steps.sha.outputs.sha256 }}" Formula/coffee-bar.rb

      - name: Commit updated formula
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add Formula/coffee-bar.rb
          git commit -m "chore(release): pin formula to ${GITHUB_REF_NAME}"
          git push origin HEAD:main
```

The `grep -c` after the substitution is deliberate: a `sed` that silently matches nothing exits 0 and would otherwise ship a formula with the placeholder still in it.

- [ ] **Step 4: Add install instructions to `README.md`**

```markdown
## Install

    brew tap ArangoGutierrez/coffee-bar https://github.com/ArangoGutierrez/coffee-bar
    brew install coffee-bar

Homebrew reaches developers. The menu-bar app ships as a notarised,
stapled build with Sparkle updates — see the design spec.
```

- [ ] **Step 5: Validate the formula syntax locally**

```bash
ruby -c Formula/coffee-bar.rb; echo "rc=$?"
```
Expected: `Syntax OK`, `rc=0`.

- [ ] **Step 6: Commit**

```bash
git add Formula/coffee-bar.rb .github/workflows/release.yml README.md
git commit -s -S -m "feat(dist): add Homebrew formula and release workflow

Formula builds from source, so the CLI needs no notarisation. The release
job greps for the substituted checksum because a sed that matches nothing
exits 0 and would ship the placeholder."
```

---

## Self-Review

**Spec coverage.** Every numbered spec section maps to a task: §4 architecture → Tasks 1–11; §5 journal/watchdog contract → Tasks 3, 4, 5, 11; §6 spikes S1/S2 → Task 11, S3/S5 → Task 8, S8 → Task 9, baseline → Task 7; §7 testing → mutation-check steps in Tasks 3, 4, 5 and the PATH shim in Task 6; spec D8 distribution → Task 12. Spec §8's out-of-scope list has no tasks, correctly.

**Known gaps, stated rather than hidden.**
- The `arm` → lid-close → `report` cycle is not executed by any task. That is deliberate per spec §1 and the "build now, decide where later" decision; Task 11 Step 9 verifies only that the verb refuses to run unprivileged.
- `LaunchDaemonInstaller` tests use a stub runner, so `launchctl bootstrap` itself is never exercised in CI. It cannot be — CI runners have no root and no persistent launchd. This is the seam-versus-integration gap; the real bootstrap is verified only in the deliberate armed session.
- `--ttl` parsing in Task 11 Step 6 is untested. It is three lines in an executable target that tests cannot import; the clamp it feeds is tested exhaustively in Task 3.

**Type consistency.** `SpikeID` cases, `Verdict` cases, `JournalRecord` fields, `WatchdogInputs` parameter order, and `CommandRunning.run` signature are used identically in every task that references them. `OutputFormatter` is defined in `CoffeeBarPower`, not `CoffeeBarProbe`, precisely so Task 10's tests can import it.
