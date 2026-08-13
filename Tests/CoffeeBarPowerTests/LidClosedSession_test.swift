// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import Darwin
@testable import CoffeeBarPower
@testable import CoffeeBarCore

// Handoff §8.2 and §8.3 — the arm path and the watchdog that undoes it.
//
// The failure to engineer against, verbatim from §8.2: "coffee-bar is SIGKILLed
// (or crashes) with SleepDisabled = 1, and the user's laptop never sleeps
// again." Everything below exists to make that unreachable.
//
// Nothing here runs `pmset`, `launchctl` or any privileged command. The power
// setting is modelled — in one test by a FILE, so a child process and this one
// share the same "system setting" the way two processes would share the real
// one. No test writes under `/Library`.

// MARK: - Fixtures

/// One ordered log of every side effect, shared by all the fakes below.
///
/// Order is the whole contract in §8.2(1): a journal written AFTER the power
/// mutation is defeated by a SIGKILL in the window between the two. A per-fake
/// call count cannot see that; one shared, ordered log can.
private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ entry: String) {
        lock.lock(); defer { lock.unlock() }
        entries.append(entry)
    }

    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    /// The index of the first call matching `name`, or nil.
    func firstIndex(of name: String) -> Int? {
        calls.firstIndex(of: name)
    }
}

/// A power controller whose state lives in memory, recording every transition.
private struct RecordingPower: SleepDisabledControlling {
    let log: CallLog
    let state: StateBox
    var failOnSet: Bool = false

    final class StateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool) { self.value = value }
        var current: Bool {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); defer { lock.unlock() }; value = newValue }
        }
    }

    func isEnabled() throws -> Bool {
        log.record("power.isEnabled")
        return state.current
    }

    func set(_ on: Bool) throws {
        log.record("power.set(\(on))")
        if failOnSet {
            throw PowerControlError.commandFailed(exitCode: 1, stderr: "modelled failure")
        }
        state.current = on
    }
}

/// A `SleepDisabledControlling` whose state lives in a FILE.
///
/// The crash test needs a child process and this one to see the same setting,
/// which is what the real `pmset` provides and an in-memory fake cannot.
private struct FileBackedPower: SleepDisabledControlling {
    let path: String

    func isEnabled() throws -> Bool {
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "0"
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    func set(_ on: Bool) throws {
        try (on ? "1" : "0").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

private struct RecordingSupervisor: WatchdogSupervising {
    let log: CallLog
    var failOnInstall: Bool = false

    func install() throws {
        log.record("watchdog.install")
        if failOnInstall {
            throw WatchdogInstallError.plistWriteFailed("modelled failure")
        }
    }

    func uninstall() throws {
        log.record("watchdog.uninstall")
    }
}

/// A supervisor that models what `install()` ACTUALLY STARTS.
///
/// `RecordingSupervisor.install()` is inert, and that inertness hid a defect
/// that made the whole feature undo itself: the plist carries
/// `RunAtLoad = true` and `ProgramArguments = [program, "watchdog"]`, so
/// `launchctl bootstrap` does not merely register a job — it RUNS one, there
/// and then, against the journal `arm` has already written.
///
/// No test that stubs `install()` to a no-op can see that. This one runs
/// whatever `runAtLoad` holds, which the composing test sets to the same entry
/// point `main.swift`'s daemon calls.
private final class LaunchdModel: WatchdogSupervising, @unchecked Sendable {
    let log: CallLog
    private let lock = NSLock()
    private var loaded = false

    init(log: CallLog) { self.log = log }

    /// What launchd executes at load. Assigned after the watchdog exists,
    /// because the job and its supervisor refer to each other.
    var runAtLoad: (@Sendable () -> Void)?

    var isLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return loaded
    }

    func install() throws {
        log.record("watchdog.install")
        lock.lock(); loaded = true; lock.unlock()
        // `RunAtLoad`. The job starts as part of the bootstrap, not later.
        runAtLoad?()
    }

    func uninstall() throws {
        log.record("watchdog.uninstall")
        lock.lock(); loaded = false; lock.unlock()
    }
}

/// A supervisor whose `uninstall()` NEVER RETURNS.
///
/// `RecordingSupervisor.uninstall()` returns and `LaunchdModel.uninstall()`
/// returns; the production one does not. It shells out to
/// `launchctl bootout system/<label>` from inside the very job that label names,
/// which terminates the caller. Everything the revert owes the user therefore
/// has to have happened BEFORE it — and the notification is the only output a
/// revert produces at all, since every rung of the ladder merely returns
/// `.revert(reason)`.
///
/// Blocking rather than throwing, for the same reason as
/// `DyingLaunchctlFake`: the call site is `try? supervisor.uninstall()`, so a
/// thrown error is swallowed and the next statement runs anyway.
private final class DyingSupervisor: WatchdogSupervising, @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func install() throws {}

    func uninstall() throws {
        entered.signal()
        release.wait()
    }

    /// Blocks until `uninstall()` is entered — the last instant at which the
    /// reverting process is still alive.
    func waitForUninstall(within seconds: Double) -> DispatchTimeoutResult {
        entered.wait(timeout: .now() + seconds)
    }

    func releaseTheCaller() { release.signal() }
}

private struct RecordingDisplay: DisplaySleepForcing {
    let log: CallLog
    /// What `isDisplayAwake()` answers AFTER `forceSleep()`. `nil` models the
    /// measured Apple Silicon reality — `IODisplayWrangler` publishes no
    /// `IOPowerManagement` key, so the state is genuinely unknown.
    var awakeAfterForcing: Bool?
    /// Fails the LAST step of `arm`, which is the only way to reach the
    /// rollback with the power setting already changed.
    var failOnForce: Bool = false

    func forceSleep() throws {
        log.record("display.forceSleep")
        if failOnForce {
            throw PowerControlError.commandFailed(exitCode: 1, stderr: "modelled failure")
        }
    }

    func isDisplayAwake() -> Bool? {
        log.record("display.isDisplayAwake")
        return awakeAfterForcing
    }
}

/// Records a journal write against the shared log while doing the REAL write.
///
/// A pure in-memory journal would not prove the ordering that matters: the
/// contract is that the bytes are on stable storage before `pmset` runs, so the
/// wrapped store is a real `FileJournalStore` doing a real `F_FULLFSYNC`.
private struct RecordingJournal: JournalStoring {
    let log: CallLog
    let inner: FileJournalStore

    func load() throws -> JournalRecord? {
        log.record("journal.load")
        return try inner.load()
    }

    func write(_ record: JournalRecord) throws {
        try inner.write(record)
        // Recorded AFTER the write returns, so the log entry means "durable",
        // not "started".
        log.record("journal.write")
    }

    func clear() throws {
        try inner.clear()
        log.record("journal.clear")
    }

    @discardableResult
    func quarantine() throws -> URL? {
        log.record("journal.quarantine")
        return try inner.quarantine()
    }
}

private final class RecordingNotifier: Notifying, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func notify(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        messages.append(message)
    }

    var posted: [String] {
        lock.lock(); defer { lock.unlock() }
        return messages
    }
}

/// What the machine reports, under this test's control.
///
/// Required rather than defaulted on `WatchdogService`, deliberately. A default
/// of `SystemWatchdogEnvironment()` would make every watchdog test read the
/// REAL thermal state of whatever machine runs the suite — so a hot laptop or a
/// loaded CI runner would revert an arm and fail tests that have nothing to do
/// with heat. Machine state is not a fixture.
private struct FakeEnvironment: WatchdogEnvironmentSensing {
    var thermal: ThermalLevel = .nominal
    var reading = PowerReading(source: .ac, percent: nil)

    func thermalLevel() -> ThermalLevel { thermal }
    func power() -> PowerReading { reading }
}

private func makeScratchRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "coffee-bar-lid-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    return root
}

private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

/// The monotonic reading taken beside `fixedNow`. An arbitrary since-boot
/// number: only its distance from the reading a tick passes is ever read.
private let fixedUptime: TimeInterval = 10_000

/// What the monotonic clock reports `seconds` after `fixedNow`, on a machine
/// whose wall clock never moved.
///
/// Every tick written before #77 passes this, because agreeing clocks are what
/// those tests meant. A tick that models a clock STEP passes the two apart, and
/// the gap between them is the step.
private func uptime(after seconds: TimeInterval) -> TimeInterval {
    fixedUptime + seconds
}

/// The machine booted an hour before the arm, which is the ordinary case.
///
/// A journal written AFTER this is not evidence of an unclean exit, so it must
/// not trigger §8.2(4)'s unconditional revert.
private let fixedBoot = Date(timeIntervalSince1970: 1_800_000_000 - 3600)

// MARK: - §8.2(1) — the journal lands before the mutation

@Test func armWritesAndSyncsTheJournalBeforeItTouchesTheSleepSetting() throws {
    // §8.2(1), and the reason the whole component exists. A journal written
    // after `pmset` is defeated by a SIGKILL in the window between the two:
    // sleep is disabled, nothing on disk says so, and the machine never sleeps
    // again.
    //
    // Named bug this catches: someone reordering `arm` so the write follows the
    // mutation — which reads more naturally and is silently fatal.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let log = CallLog()
    let url = root.appending(path: "state/probe-journal.json")
    let service = ArmService(
        journal: RecordingJournal(log: log, inner: FileJournalStore(url: url)),
        reader: GuardedJournalReader(url: url, requiredOwner: getuid(),
                                     quarantineOnRefusal: false),
        power: RecordingPower(log: log, state: .init(false)),
        supervisor: RecordingSupervisor(log: log),
        display: RecordingDisplay(log: log, awakeAfterForcing: false),
        clock: { fixedNow },
        // Fixed for the same reason `clock` is: the real uptime of whatever
        // machine runs the suite is machine state, not a fixture, and the
        // record `arm` writes is read back by ticks that pass their own.
        monotonicClock: { fixedUptime },
        displayVerifyDelay: 0)

    try service.arm(ttlSeconds: 3600)

    let write = try #require(log.firstIndex(of: "journal.write"),
                             "arm never wrote a journal at all: \(log.calls)")
    let mutate = try #require(log.firstIndex(of: "power.set(true)"),
                              "arm never disabled sleep: \(log.calls)")
    #expect(write < mutate, """
        arm disabled sleep before the journal was durable. A SIGKILL in that \
        window leaves the setting held with nothing on disk to revert it.
        order: \(log.calls)
        """)
}

@Test func armInstallsTheWatchdogBeforeItDisablesSleep() throws {
    // The second ordering, and it is the one §8.2 does not spell out. If the
    // setting goes first and the process dies before `install()`, no daemon
    // exists — so `RunAtLoad` never fires, `KeepAlive` supervises nothing, and
    // the journal on disk is read by nobody. Installing first makes the
    // supervisor older than the thing it supervises.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let log = CallLog()
    let url = root.appending(path: "state/probe-journal.json")
    let service = ArmService(
        journal: RecordingJournal(log: log, inner: FileJournalStore(url: url)),
        reader: GuardedJournalReader(url: url, requiredOwner: getuid(),
                                     quarantineOnRefusal: false),
        power: RecordingPower(log: log, state: .init(false)),
        supervisor: RecordingSupervisor(log: log),
        display: RecordingDisplay(log: log, awakeAfterForcing: false),
        clock: { fixedNow },
        // Fixed for the same reason `clock` is: the real uptime of whatever
        // machine runs the suite is machine state, not a fixture, and the
        // record `arm` writes is read back by ticks that pass their own.
        monotonicClock: { fixedUptime },
        displayVerifyDelay: 0)

    try service.arm(ttlSeconds: 3600)

    let install = try #require(log.firstIndex(of: "watchdog.install"))
    let mutate = try #require(log.firstIndex(of: "power.set(true)"))
    #expect(install < mutate, """
        arm disabled sleep before installing the watchdog. A crash in that \
        window leaves the setting held and no daemon to ever revert it.
        order: \(log.calls)
        """)
}

@Test func armRecordsThePriorValueItActuallyReadRatherThanAssumingFalse() throws {
    // Spec D6: the journal stores the value to restore TO and never assumes it.
    // A machine that already had `disablesleep` set for its own reasons must
    // get that setting back, not a guess.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let log = CallLog()
    let url = root.appending(path: "state/probe-journal.json")
    let store = FileJournalStore(url: url)
    let service = ArmService(
        journal: RecordingJournal(log: log, inner: store),
        reader: GuardedJournalReader(url: url, requiredOwner: getuid(),
                                     quarantineOnRefusal: false),
        power: RecordingPower(log: log, state: .init(true)),   // already set
        supervisor: RecordingSupervisor(log: log),
        display: RecordingDisplay(log: log, awakeAfterForcing: false),
        clock: { fixedNow },
        // Fixed for the same reason `clock` is: the real uptime of whatever
        // machine runs the suite is machine state, not a fixture, and the
        // record `arm` writes is read back by ticks that pass their own.
        monotonicClock: { fixedUptime },
        displayVerifyDelay: 0)

    try service.arm(ttlSeconds: 3600)

    let written = try #require(try store.load())
    #expect(written.priorValue == true)
    #expect(written.setAt == fixedNow)
    #expect(written.intent == .sleepDisabled)
}

@Test func armStampsTheJournalWithTheMonotonicClockAndNotWithTheWallClock() throws {
    // #77. `setAt` is what a human reads out of `report`; `setAtMonotonic` is
    // what the 8-hour cap is measured against, and the two come from different
    // clocks on purpose.
    //
    // Named bug this catches, and it is the one a compiler cannot: filling the
    // new field from the wall clock — `setAtMonotonic: clock().timeIntervalSince1970`
    // — because both are a `TimeInterval` and it reads fine. The daemon then
    // subtracts a since-1970 number from a since-BOOT one, gets an elapsed time
    // of about minus fifty-seven years, and no TTL ever expires. That is an
    // unbounded root-held `SleepDisabled`, reached with nobody attacking
    // anything. No other test in this file reads the record back, so none of
    // them would notice.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let log = CallLog()
    let url = root.appending(path: "state/probe-journal.json")
    let store = FileJournalStore(url: url)
    let service = ArmService(
        journal: RecordingJournal(log: log, inner: store),
        reader: GuardedJournalReader(url: url, requiredOwner: getuid(),
                                     quarantineOnRefusal: false),
        power: RecordingPower(log: log, state: .init(false)),
        supervisor: RecordingSupervisor(log: log),
        display: RecordingDisplay(log: log, awakeAfterForcing: false),
        clock: { fixedNow },
        // Distinct from `fixedUptime` and nowhere near `fixedNow`'s epoch, so
        // neither a hard-coded stamp nor a wall reading can satisfy this.
        monotonicClock: { 4242.5 },
        displayVerifyDelay: 0)

    try service.arm(ttlSeconds: 3600)

    let written = try #require(try store.load())
    #expect(written.setAtMonotonic == 4242.5, """
        arm recorded \(written.setAtMonotonic) as the monotonic stamp, and the \
        clock it was given reads 4242.5. The cap is measured against this field.
        """)
    // Both, because one alone does not distinguish a stamp from a copy.
    #expect(written.setAt == fixedNow)
}

@Test func armCapsTheTTLAtEightHoursHoweverLongTheCallerAsks() throws {
    // §8.2(5), hard cap regardless of settings. `JournalRecord` clamps, and
    // this pins that `arm` routes through the clamp rather than around it.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let log = CallLog()
    let url = root.appending(path: "state/probe-journal.json")
    let store = FileJournalStore(url: url)
    let service = ArmService(
        journal: RecordingJournal(log: log, inner: store),
        reader: GuardedJournalReader(url: url, requiredOwner: getuid(),
                                     quarantineOnRefusal: false),
        power: RecordingPower(log: log, state: .init(false)),
        supervisor: RecordingSupervisor(log: log),
        display: RecordingDisplay(log: log, awakeAfterForcing: false),
        clock: { fixedNow },
        // Fixed for the same reason `clock` is: the real uptime of whatever
        // machine runs the suite is machine state, not a fixture, and the
        // record `arm` writes is read back by ticks that pass their own.
        monotonicClock: { fixedUptime },
        displayVerifyDelay: 0)

    try service.arm(ttlSeconds: 99_999_999)

    let written = try #require(try store.load())
    #expect(written.ttlSeconds == JournalRecord.maxTTLSeconds)
    #expect(written.ttlSeconds == 8 * 60 * 60)
}

@Test func armAnswersWithTheHoldItTookRatherThanTheOneItWasAskedFor() throws {
    // Named bug this catches, and it reached the user as a printed number that
    // was not true: `arm --ttl 999999` answered "armed: sleep disabled for up to
    // 999999s" while the record on disk said 28800 and the watchdog reverted at
    // eight hours. `site/docs.html` states the cap, so the product's two
    // surfaces described the same hold differently and the CLI was the wrong one.
    //
    // READ BACK OFF THE JOURNAL, and never clamped a second time at the caller.
    // A `min(ttl, maxTTLSeconds)` beside the print would be a copy of the rule
    // that drifts the moment the cap moves, and it would still agree with a
    // record that had been written wrong. What the machine is actually held for
    // is what `decide()` reads, which is the file — so the answer comes from
    // there.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let log = CallLog()
    let url = root.appending(path: "state/probe-journal.json")
    let store = FileJournalStore(url: url)
    let service = ArmService(
        journal: RecordingJournal(log: log, inner: store),
        reader: GuardedJournalReader(url: url, requiredOwner: getuid(),
                                     quarantineOnRefusal: false),
        power: RecordingPower(log: log, state: .init(false)),
        supervisor: RecordingSupervisor(log: log),
        display: RecordingDisplay(log: log, awakeAfterForcing: false),
        clock: { fixedNow },
        monotonicClock: { fixedUptime },
        displayVerifyDelay: 0)

    let asked = 99_999_999
    let held = try service.arm(ttlSeconds: asked)
    let written = try #require(try store.load())

    #expect(held == written.ttlSeconds, """
        arm answered \(held)s and wrote \(written.ttlSeconds)s. The number a \
        caller prints has to be the one the journal keeps: that record is what \
        WatchdogDecision.decide reads, so it alone says when the machine sleeps \
        again.
        """)
    #expect(held == JournalRecord.maxTTLSeconds, """
        arm answered \(held)s for a request of \(asked)s. §8.2(5) caps a hold at \
        \(JournalRecord.maxTTLSeconds)s regardless of what is asked.
        """)
    #expect(held != asked, """
        arm answered with the \(asked)s it was handed, which is argv rather than \
        a fact about the machine.
        """)
}

@Test func armAnswersWithTheRequestedHoldWhenItIsUnderTheCap() throws {
    // THE DISCRIMINATOR for the test above, and it is not padding: an
    // implementation that returned `maxTTLSeconds` unconditionally — or the
    // record's clamp applied to nothing — satisfies every assertion there. A
    // request under the cap has to come back unchanged, or the printed number is
    // wrong in the other direction for every ordinary arm.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let log = CallLog()
    let url = root.appending(path: "state/probe-journal.json")
    let store = FileJournalStore(url: url)
    let service = ArmService(
        journal: RecordingJournal(log: log, inner: store),
        reader: GuardedJournalReader(url: url, requiredOwner: getuid(),
                                     quarantineOnRefusal: false),
        power: RecordingPower(log: log, state: .init(false)),
        supervisor: RecordingSupervisor(log: log),
        display: RecordingDisplay(log: log, awakeAfterForcing: false),
        clock: { fixedNow },
        monotonicClock: { fixedUptime },
        displayVerifyDelay: 0)

    let held = try service.arm(ttlSeconds: 900)

    #expect(held == 900, "arm answered \(held)s for a 900s request, which is under the cap")
    #expect(try #require(try store.load()).ttlSeconds == 900)
}

/// `Sources/CoffeeBarProbe/main.swift`, resolved from `#filePath`.
///
/// The probe is an executable with top-level code, so no test target can import
/// it and call anything in it. Reading it is the only route from this suite to
/// what it prints.
private func probeMainSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)  // …/Tests/CoffeeBarPowerTests/LidClosedSession_test.swift
        .deletingLastPathComponent()            // …/Tests/CoffeeBarPowerTests
        .deletingLastPathComponent()            // …/Tests
        .deletingLastPathComponent()            // the package root
    return try String(contentsOf: root.appending(path: "Sources/CoffeeBarProbe/main.swift"),
                      encoding: .utf8)
}

@Test func theProbePrintsTheHoldItTookAndNotTheNumberOnTheCommandLine() throws {
    // The half `armAnswersWithTheHoldItTookRatherThanTheOneItWasAskedFor` cannot
    // reach. `arm` can answer perfectly and the probe can go on printing
    // `invocation.ttlSeconds`, which is argv — the exact defect, with a correct
    // service underneath it and every service-level check green.
    //
    // The BINDING is read out of the source and required in the printed line,
    // rather than a fixed name being searched for. A guard looking for a literal
    // `armed` variable fails on a correct rename, and a guard merely asserting
    // that `invocation.ttlSeconds` is absent from that line passes for a line
    // that prints a second clamp computed on the spot.
    let source = try probeMainSource()
    let ns = source as NSString

    let printed = try NSRegularExpression(pattern: "^.*armed: sleep disabled.*$",
                                          options: [.anchorsMatchLines])
        .matches(in: source, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range) }

    // ANTI-VACUITY: a reworded message finds no line, and every assertion below
    // would then be about a string that was never located.
    let line = try #require(printed.count == 1 ? printed.first : nil,
                            "main.swift has \(printed.count) lines announcing an arm: \(printed)")

    let bound = try NSRegularExpression(pattern: "let\\s+(\\w+)\\s*=\\s*try\\s+service\\.arm\\(")
        .matches(in: source, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range(at: 1)) }
    let binding = try #require(bound.count == 1 ? bound.first : nil, """
        main.swift binds the result of service.arm() \(bound.count) time(s): \
        \(bound). It calls arm and throws the answer away, so whatever it prints \
        is not what the journal kept.
        """)

    #expect(line.contains("\\(\(binding))"), """
        the probe announces the arm with
          \(line.trimmingCharacters(in: .whitespaces))
        which does not print `\(binding)`, the hold arm reported.
        """)

    #expect(!line.contains("invocation."), """
        the probe announces the arm with
          \(line.trimmingCharacters(in: .whitespaces))
        `invocation` is argv. JournalRecord clamps the TTL to \
        \(JournalRecord.maxTTLSeconds)s on the way to disk, so `--ttl 999999` \
        prints a number the machine will not honour — and site/docs.html tells \
        the same user the cap is eight hours.
        """)
}

/// THE INVARIANT, for whoever edits `case .report:` next: **the deadline
/// `report` prints is derived from `setAtMonotonic`, because that is the clock
/// the cap is enforced against.**
///
/// `WatchdogDecision.decide` ends a hold when ELAPSED MONOTONIC time passes
/// `ttlSeconds`. `JournalRecord.expiry` is the same TTL added to `setAt`, a
/// wall-clock value, so the two disagree by the size of any step taken since
/// the arm — and `report` printed the second one (#85). Nothing misbehaved: the
/// user was simply told a time the machine would not honour, and `report` is
/// the only way to learn it, because the journal belongs to root.
///
/// Read out of the source rather than pinned to names: the BINDING that
/// receives the monotonic sample is discovered, so renaming it is not a
/// failure. Changing the CLOCK is. The unit-level half of this contract lives
/// in `OutputFormatter_test.swift`; only this half can see what the executable
/// actually hands to `print`.
///
/// The rule is "must not DO", so whole-line `//` comments are dropped before
/// anything is looked for: the report block explains in prose exactly which
/// value it stopped printing, and a raw `contains` is satisfied by that
/// sentence rather than by the code. `AppLayerBoundary_test.swift` strips
/// comments for the same reason, with a real lexer — that one lives in another
/// target, and this file needs a line rule, not a Swift grammar.
///
/// LIMIT, stated rather than hidden: this drops only lines that START with
/// `//`. A trailing comment on a line of code is still read as code, and block
/// comments are not handled; `main.swift` uses neither inside this block.
@Test func theProbeReportsTheDeadlineTheCapIsEnforcedAgainstAndNotTheWallClockOne() throws {
    /// Whole-line `//` comments removed, line structure kept.
    func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // Proven live on a fixture carrying the very sentence a broken stripper
    // would leave behind, rather than argued. If this ever stops stripping,
    // every check below reads prose about the bug instead of code avoiding it.
    #expect(codeOnly("let a = 1\n  // record.expiry\nprint(a)")
            == "let a = 1\nprint(a)")

    let source = try probeMainSource()

    // ANTI-VACUITY, part one: a read that resolved the wrong path, or a file
    // truncated to nothing, must fail here rather than sail through every
    // absence assertion below.
    #expect(source.count > 4000,
            "probeMainSource() returned \(source.count) characters; that is not main.swift")

    // The report block: from its `case` label to the next one. Both sit at
    // column zero inside the top-level `switch invocation.verb`.
    let opening = try #require(source.range(of: "\ncase .report:"),
                               "main.swift has no `case .report:` at column zero")
    let rest = source[opening.upperBound...]
    let block = codeOnly(
        String(rest[..<(rest.range(of: "\ncase ")?.lowerBound ?? rest.endIndex)]))

    // ANTI-VACUITY, part two: prove the extracted region really is the report
    // block and is not a sliver left by a stripper that ate too much.
    // `wantsJSON` is the branch every version of this block has to make,
    // whatever else changes around it.
    #expect(block.count > 200,
            "the extracted `case .report:` code is \(block.count) characters long:\n\(block)")
    #expect(block.contains("wantsJSON"), """
        the extracted block never branches on `wantsJSON`, so it is not the \
        report block:
        \(block)
        """)

    // `.expiry` on ANY binding, not `record.expiry`: the local is named
    // `record` today, and a guard pinned to that name goes quiet the moment
    // someone renames it — while the value it forbids walks straight back in.
    #expect(!block.contains(".expiry"), """
        `report` reaches for `.expiry`, which is `setAt` plus the TTL — both \
        wall-clock. The cap is enforced on elapsed MONOTONIC time, so after any \
        clock step that states a deadline the daemon will not act on, and \
        `report` is the only place a user can read one (#85).
        """)

    // Which local carries the deadline: the last binding opened before the
    // enforced clock is sampled, i.e. the one the sample is an argument to.
    let sampled = try #require(block.range(of: "SystemMonotonicClock.now()"), """
        `report` never samples `SystemMonotonicClock`, so nothing it prints can \
        be measured against the clock the cap is enforced on:
        \(block)
        """)
    let prefix = String(block[..<sampled.lowerBound])
    let ns = prefix as NSString
    let bindings = try NSRegularExpression(pattern: "let\\s+(\\w+)\\s*=")
        .matches(in: prefix, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range(at: 1)) }
    let binding = try #require(bindings.last, """
        the monotonic sample in `report` is bound to nothing, so it cannot \
        reach anything printed:
        \(block)
        """)

    // Every print AFTER that binding must carry it. The `nothing armed` print
    // sits before it, on the path where there is no hold and no deadline.
    let printed = String(block[sampled.upperBound...])
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.contains("print(") }

    // ANTI-VACUITY, part three: a block that prints nothing after building the
    // deadline reports nothing, and would pass the loop below by default.
    #expect(!printed.isEmpty, """
        `report` builds a deadline from the enforced clock and then prints \
        nothing derived from it:
        \(block)
        """)
    for statement in printed {
        #expect(statement.contains(binding), """
            `report` prints
              \(statement)
            which does not carry `\(binding)`, the value it built from \
            `setAtMonotonic` and the enforced clock. A path that skips it — the \
            `--json` one in particular — hands its reader the wall-clock answer \
            the human path just stopped giving.
            """)
    }
}

// MARK: - Rollback

@Test func armRestoresThePriorValueFromTheRecordAfterTheSettingAlreadyChanged() throws {
    // The C1 bug, in the caller. `LaunchDaemonInstaller.install` documents it:
    // a rollback that RE-READS the current setting reads back its own `true`,
    // re-applies it and deletes the journal — so the machine never sleeps
    // again, with no attacker and no crash.
    //
    // The failure has to land AFTER `power.set(true)` or the test cannot tell
    // the two implementations apart: fail earlier and the setting is still
    // `false`, which both a record-reading and a system-reading rollback
    // restore identically. Forcing the display is the last step of `arm`, so
    // failing there is the one seam that reaches the rollback with the setting
    // already changed.
    //
    // Prior value `false`, setting now `true`. A rollback reading the RECORD
    // restores `false`; one re-reading the system restores `true`.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let log = CallLog()
    let url = root.appending(path: "state/probe-journal.json")
    let store = FileJournalStore(url: url)
    let power = RecordingPower(log: log, state: .init(false))
    let service = ArmService(
        journal: RecordingJournal(log: log, inner: store),
        reader: GuardedJournalReader(url: url, requiredOwner: getuid(),
                                     quarantineOnRefusal: false),
        power: power,
        supervisor: RecordingSupervisor(log: log),
        display: RecordingDisplay(log: log, awakeAfterForcing: false, failOnForce: true),
        clock: { fixedNow },
        // Fixed for the same reason `clock` is: the real uptime of whatever
        // machine runs the suite is machine state, not a fixture, and the
        // record `arm` writes is read back by ticks that pass their own.
        monotonicClock: { fixedUptime },
        displayVerifyDelay: 0)

    #expect(throws: (any Error).self) { try service.arm(ttlSeconds: 3600) }

    // The premise: without this the assertion below could pass because the
    // setting was never changed at all.
    #expect(log.calls.contains("power.set(true)"),
            "arm never disabled sleep, so the rollback had nothing to undo: \(log.calls)")
    #expect(power.state.current == false, """
        the rollback left sleep disabled. A rollback that re-reads the setting \
        reads back its own true and re-applies it — the C1 defect, in the \
        caller. order: \(log.calls)
        """)
    #expect(try store.load() == nil, "the journal outlived the failed arm")
    #expect(log.calls.contains("watchdog.uninstall"),
            "the failed arm left the root daemon installed: \(log.calls)")
}

@Test func armRollsBackWhenTheWatchdogInstallFails() throws {
    // The earlier seam. `install()` throwing is the ordinary failure — a plist
    // that will not write, a `bootstrap` that exits non-zero — and it must
    // leave nothing behind: no journal, and sleep as it was found.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let log = CallLog()
    let url = root.appending(path: "state/probe-journal.json")
    let store = FileJournalStore(url: url)
    let power = RecordingPower(log: log, state: .init(false))
    let service = ArmService(
        journal: RecordingJournal(log: log, inner: store),
        reader: GuardedJournalReader(url: url, requiredOwner: getuid(),
                                     quarantineOnRefusal: false),
        power: power,
        supervisor: RecordingSupervisor(log: log, failOnInstall: true),
        display: RecordingDisplay(log: log, awakeAfterForcing: false),
        clock: { fixedNow },
        // Fixed for the same reason `clock` is: the real uptime of whatever
        // machine runs the suite is machine state, not a fixture, and the
        // record `arm` writes is read back by ticks that pass their own.
        monotonicClock: { fixedUptime },
        displayVerifyDelay: 0)

    #expect(throws: (any Error).self) { try service.arm(ttlSeconds: 3600) }

    #expect(power.state.current == false, "the rollback left sleep disabled: \(log.calls)")
    #expect(try store.load() == nil, "the journal outlived the failed arm")
    // The setting must never have been touched: the watchdog goes in first
    // precisely so a failed install happens before anything is held.
    #expect(log.calls.contains("power.set(true)") == false,
            "arm disabled sleep even though the watchdog never installed: \(log.calls)")
}

// MARK: - §8.3 — display safety

@Test func armForcesDisplaySleepWhenItEntersLidClosedMode() throws {
    // §8.3: `SleepDisabled` alone leaves the internal panel lit under a closed
    // lid, which burns the battery the feature exists to save.
    //
    // Named bug this catches: an `arm` that sets the power flag and stops
    // there, which passes every §8.2 test in this file.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let log = CallLog()
    let url = root.appending(path: "state/probe-journal.json")
    let service = ArmService(
        journal: RecordingJournal(log: log, inner: FileJournalStore(url: url)),
        reader: GuardedJournalReader(url: url, requiredOwner: getuid(),
                                     quarantineOnRefusal: false),
        power: RecordingPower(log: log, state: .init(false)),
        supervisor: RecordingSupervisor(log: log),
        display: RecordingDisplay(log: log, awakeAfterForcing: false),
        clock: { fixedNow },
        // Fixed for the same reason `clock` is: the real uptime of whatever
        // machine runs the suite is machine state, not a fixture, and the
        // record `arm` writes is read back by ticks that pass their own.
        monotonicClock: { fixedUptime },
        displayVerifyDelay: 0)

    try service.arm(ttlSeconds: 3600)

    #expect(log.calls.contains("display.forceSleep"), """
        arm never forced display sleep, so the internal panel stays lit under a \
        closed lid. order: \(log.calls)
        """)
}

@Test func armAbortsAndRevertsEverythingWhenTheDisplayStaysAwake() throws {
    // §8.3: "If the display is still awake 5 s after lid close, abort the mode
    // and notify. Do not silently cook the battery."
    //
    // Abort means abort: the power setting goes back, the journal goes away and
    // the daemon is uninstalled. An abort that threw but left the setting held
    // would be the worst of both.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let log = CallLog()
    let url = root.appending(path: "state/probe-journal.json")
    let store = FileJournalStore(url: url)
    let power = RecordingPower(log: log, state: .init(false))
    let service = ArmService(
        journal: RecordingJournal(log: log, inner: store),
        reader: GuardedJournalReader(url: url, requiredOwner: getuid(),
                                     quarantineOnRefusal: false),
        power: power,
        supervisor: RecordingSupervisor(log: log),
        display: RecordingDisplay(log: log, awakeAfterForcing: true),  // stayed lit
        clock: { fixedNow },
        // Fixed for the same reason `clock` is: the real uptime of whatever
        // machine runs the suite is machine state, not a fixture, and the
        // record `arm` writes is read back by ticks that pass their own.
        monotonicClock: { fixedUptime },
        displayVerifyDelay: 0)

    #expect(throws: ArmError.displayStayedAwake) { try service.arm(ttlSeconds: 3600) }

    #expect(power.state.current == false, "the aborted arm left sleep disabled")
    #expect(try store.load() == nil, "the aborted arm left a journal behind")
    #expect(log.calls.contains("watchdog.uninstall"),
            "the aborted arm left the root daemon installed: \(log.calls)")
}

@Test func armProceedsWhenTheDisplayPowerStateCannotBeRead() throws {
    // The measured reality on Apple Silicon, recorded in `DisplayStateProbe`:
    // `IODisplayWrangler` matches but publishes no `IOPowerManagement` key, so
    // the probe answers `nil` — genuinely unknown, not "awake".
    //
    // Treating unknown as awake would abort every arm on the only hardware
    // this ships to. Treating it as asleep is the deliberate, documented
    // choice; the alternative is a feature that never works.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let log = CallLog()
    let url = root.appending(path: "state/probe-journal.json")
    let power = RecordingPower(log: log, state: .init(false))
    let service = ArmService(
        journal: RecordingJournal(log: log, inner: FileJournalStore(url: url)),
        reader: GuardedJournalReader(url: url, requiredOwner: getuid(),
                                     quarantineOnRefusal: false),
        power: power,
        supervisor: RecordingSupervisor(log: log),
        display: RecordingDisplay(log: log, awakeAfterForcing: nil),
        clock: { fixedNow },
        // Fixed for the same reason `clock` is: the real uptime of whatever
        // machine runs the suite is machine state, not a fixture, and the
        // record `arm` writes is read back by ticks that pass their own.
        monotonicClock: { fixedUptime },
        displayVerifyDelay: 0)

    try service.arm(ttlSeconds: 3600)
    #expect(power.state.current == true)
}

// MARK: - arm and its own daemon, composed

@Test func armSurvivesTheDaemonThatArmItselfInstalls() throws {
    // The acceptance the whole milestone rests on, and the one no stubbed
    // supervisor can express: `arm` must still be armed once the daemon it
    // installs has had its first look.
    //
    // Named bug this catches, and it was LIVE and shipping: `install()` writes
    // a plist with `RunAtLoad = true`, so `launchctl bootstrap` starts the
    // `watchdog` job immediately, against the journal `arm` wrote moments
    // earlier. That first tick ran with `isBootEvaluation = true` — because
    // `main.swift` treated ITS OWN start as a boot — and §8.2(4) reverts a
    // dirty journal at boot unconditionally, above the TTL check. So `arm`
    // installed a daemon whose first act was to undo `arm`.
    //
    // The end state had no attacker in it: sleep held, journal deleted, daemon
    // booted out, and `revert` answering "nothing was armed" because the
    // journal it needed was already gone. That is §8.2's named failure,
    // produced by the feature itself.
    //
    // Every double here is a model, not a stub. `LaunchdModel.install()` runs
    // the job, the power setting is real state, and the journal is a real
    // `FileJournalStore` doing a real write.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let log = CallLog()
    let url = root.appending(path: "state/probe-journal.json")
    let store = FileJournalStore(url: url)
    let power = RecordingPower(log: log, state: .init(false))
    let supervisor = LaunchdModel(log: log)

    let watchdog = WatchdogService(
        reader: GuardedJournalReader(url: url, store: store, requiredOwner: getuid()),
        power: power,
        supervisor: supervisor,
        notifier: RecordingNotifier(),
        environment: FakeEnvironment(),
        bootTime: { fixedBoot })

    // Exactly what launchd runs at load: the `watchdog` verb, one tick.
    supervisor.runAtLoad = {
        _ = try? watchdog.evaluate(now: fixedNow, monotonicNow: fixedUptime)
    }

    let service = ArmService(
        journal: RecordingJournal(log: log, inner: store),
        reader: GuardedJournalReader(url: url, requiredOwner: getuid(),
                                     quarantineOnRefusal: false),
        power: power,
        supervisor: supervisor,
        display: RecordingDisplay(log: log, awakeAfterForcing: false),
        clock: { fixedNow },
        // Fixed for the same reason `clock` is: the real uptime of whatever
        // machine runs the suite is machine state, not a fixture, and the
        // record `arm` writes is read back by ticks that pass their own.
        monotonicClock: { fixedUptime },
        displayVerifyDelay: 0)

    try service.arm(ttlSeconds: 3600)

    // All three, because any one alone is survivable and the three together
    // are what "armed" means.
    #expect(power.state.current == true, """
        sleep is not held after a successful arm. order: \(log.calls)
        """)
    #expect(try store.load() != nil, """
        the daemon arm installed deleted arm's own journal. Nothing can revert \
        the setting now, which is exactly §8.2's named failure.
        order: \(log.calls)
        """)
    #expect(supervisor.isLoaded, """
        the daemon booted itself out during arm, so nothing supervises the \
        setting that is still held. order: \(log.calls)
        """)
}

// MARK: - The invariant: arm never succeeds while holding an unexplained setting

@Test func armFailsRatherThanHoldASettingTheJournalCannotExplain() throws {
    // THE INVARIANT, driven on its own: `arm` must never return success while
    // the system holds a setting the journal cannot explain.
    //
    // Deriving the boot time removed the daemon's REASON to revert on the first
    // tick. It did not remove its ABILITY. Anything that clears the journal
    // between `install()` and the end of `arm` — a revert this code has not
    // thought of, a future policy, an operator running `revert` in another
    // terminal — leaves sleep held with nothing on disk to undo it, and `arm`
    // cheerfully printing "armed".
    //
    // So this test does not model a daemon at all. It removes the journal
    // directly, which is the general shape every such race collapses to, and
    // requires `arm` to FAIL and roll back rather than report success.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let log = CallLog()
    let url = root.appending(path: "state/probe-journal.json")
    let store = FileJournalStore(url: url)
    let power = RecordingPower(log: log, state: .init(false))
    let supervisor = LaunchdModel(log: log)

    // Whatever launchd started, it took the journal with it.
    supervisor.runAtLoad = { try? store.clear() }

    let service = ArmService(
        journal: RecordingJournal(log: log, inner: store),
        reader: GuardedJournalReader(url: url, requiredOwner: getuid(),
                                     quarantineOnRefusal: false),
        power: power,
        supervisor: supervisor,
        display: RecordingDisplay(log: log, awakeAfterForcing: false),
        clock: { fixedNow },
        // Fixed for the same reason `clock` is: the real uptime of whatever
        // machine runs the suite is machine state, not a fixture, and the
        // record `arm` writes is read back by ticks that pass their own.
        monotonicClock: { fixedUptime },
        displayVerifyDelay: 0)

    #expect(throws: ArmError.journalVanished) { try service.arm(ttlSeconds: 3600) }

    // The premise: without this the assertions below could pass because the
    // setting was never held in the first place.
    #expect(log.calls.contains("power.set(true)"),
            "arm never held the setting, so it had nothing to detect: \(log.calls)")

    #expect(power.state.current == false, """
        arm left sleep disabled with no journal to explain it. That is §8.2's \
        named failure, produced by a successful arm. order: \(log.calls)
        """)
    #expect(supervisor.isLoaded == false,
            "the failed arm left the root daemon installed: \(log.calls)")
}

@Test func armRefusesBeforeHoldingAnythingWhenTheJournalPathWouldBeRefused() throws {
    // The regression the 0700 tightening introduced, and the reason a "refuse
    // safely" rule needs a partner on the WRITE side.
    //
    // A pre-existing 0755 state directory is exactly what SECURITY.md "an earlier build left 0755"
    // describes. The reader refuses it — correctly — and the watchdog's
    // fail-safe then restores sleep, clears and uninstalls. But `arm` went on
    // to set the flag anyway, so "refuse safely" became "hold forever": the
    // measured end state was `arm=SUCCESS sleepDisabled=true journalLoads=false
    // daemonLoaded=false`.
    //
    // The fix is to ask the READER'S OWN RULE before writing anything. Nothing
    // is held, and the refusal names the directory the operator has to fix.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let log = CallLog()
    let url = root.appending(path: "state/probe-journal.json")
    let stateDir = url.deletingLastPathComponent()
    // A directory an earlier build left behind, which the store cannot repair.
    try FileManager.default.createDirectory(
        at: stateDir, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755])

    let store = FileJournalStore(url: url)
    let power = RecordingPower(log: log, state: .init(false))
    let supervisor = LaunchdModel(log: log)
    let watchdog = WatchdogService(
        reader: GuardedJournalReader(url: url, store: store, requiredOwner: getuid()),
        power: power, supervisor: supervisor, notifier: RecordingNotifier(),
        environment: FakeEnvironment(),
        bootTime: { fixedBoot })
    supervisor.runAtLoad = {
        _ = try? watchdog.evaluate(now: fixedNow, monotonicNow: fixedUptime)
    }

    let service = ArmService(
        journal: RecordingJournal(log: log, inner: store),
        reader: GuardedJournalReader(url: url, requiredOwner: getuid(),
                                     quarantineOnRefusal: false),
        power: power,
        supervisor: supervisor,
        display: RecordingDisplay(log: log, awakeAfterForcing: false),
        clock: { fixedNow },
        // Fixed for the same reason `clock` is: the real uptime of whatever
        // machine runs the suite is machine state, not a fixture, and the
        // record `arm` writes is read back by ticks that pass their own.
        monotonicClock: { fixedUptime },
        displayVerifyDelay: 0)

    #expect(throws: (any Error).self) { try service.arm(ttlSeconds: 3600) }

    #expect(power.state.current == false,
            "the refused arm still held the setting: \(log.calls)")
    #expect(supervisor.isLoaded == false,
            "the refused arm left a root daemon installed: \(log.calls)")
    // Nothing was held, so nothing had to be rolled back: the refusal lands
    // before the first side effect.
    #expect(log.calls.contains("power.set(true)") == false, """
        arm reached the power setting on a path it had already judged \
        untrustworthy. order: \(log.calls)
        """)
    #expect(log.calls.contains("journal.write") == false, """
        arm wrote a journal into a directory it refuses to read back. \
        order: \(log.calls)
        """)
}

@Test func armFailsWhenItsOwnDaemonRevertsInsideTheBootSecond() throws {
    // The second reachable case, and the one that survives fix (a).
    //
    // `HostInfo.now()` truncates `setAt` DOWN to the whole second, so an `arm`
    // landing inside the boot second records a `setAt` fractionally BELOW
    // `kern.boottime`. The journal then reads as older than the boot, §8.2(4)
    // reverts it unconditionally, and the daemon undoes the arm that installed
    // it. Bounded under one second and vanishingly unlikely for a human's
    // `sudo` — and the consequence is unbounded, so it gets a guard.
    //
    // Reverting is the RIGHT call here: the boot comparison is deliberately
    // biased toward reverting. What must not happen is `arm` reporting success
    // afterwards.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let log = CallLog()
    let url = root.appending(path: "state/probe-journal.json")
    let store = FileJournalStore(url: url)
    let power = RecordingPower(log: log, state: .init(false))
    let supervisor = LaunchdModel(log: log)
    let watchdog = WatchdogService(
        reader: GuardedJournalReader(url: url, store: store, requiredOwner: getuid()),
        power: power, supervisor: supervisor, notifier: RecordingNotifier(),
        environment: FakeEnvironment(),
        // The machine booted a second AFTER this arm's truncated `setAt`.
        bootTime: { fixedNow.addingTimeInterval(1) })
    supervisor.runAtLoad = {
        _ = try? watchdog.evaluate(now: fixedNow, monotonicNow: fixedUptime)
    }

    let service = ArmService(
        journal: RecordingJournal(log: log, inner: store),
        reader: GuardedJournalReader(url: url, requiredOwner: getuid(),
                                     quarantineOnRefusal: false),
        power: power,
        supervisor: supervisor,
        display: RecordingDisplay(log: log, awakeAfterForcing: false),
        clock: { fixedNow },
        // Fixed for the same reason `clock` is: the real uptime of whatever
        // machine runs the suite is machine state, not a fixture, and the
        // record `arm` writes is read back by ticks that pass their own.
        monotonicClock: { fixedUptime },
        displayVerifyDelay: 0)

    #expect(throws: ArmError.journalVanished) { try service.arm(ttlSeconds: 3600) }

    #expect(power.state.current == false, """
        the daemon reverted inside the boot second and arm still reported \
        success, so the machine holds sleep with no journal. order: \(log.calls)
        """)
    #expect(supervisor.isLoaded == false)
}

// MARK: - §8.2(2,3) — the watchdog reverts

/// Builds a watchdog over a scratch journal that already holds `record`.
private func makeArmedWatchdog(root: URL, record: JournalRecord,
                               initiallyEnabled: Bool = true,
                               bootTime: Date = fixedBoot,
                               environment: FakeEnvironment = FakeEnvironment(),
                               policy: WatchdogPolicy = .default,
                               supervisor: (any WatchdogSupervising)? = nil)
    throws -> (service: WatchdogService, power: RecordingPower,
               store: FileJournalStore, log: CallLog, notifier: RecordingNotifier) {
    let log = CallLog()
    let url = root.appending(path: "state/probe-journal.json")
    let store = FileJournalStore(url: url)
    try store.write(record)

    let power = RecordingPower(log: log, state: .init(initiallyEnabled))
    let notifier = RecordingNotifier()
    let service = WatchdogService(
        reader: GuardedJournalReader(url: url, store: store, requiredOwner: getuid()),
        power: power,
        supervisor: supervisor ?? RecordingSupervisor(log: log),
        notifier: notifier,
        environment: environment,
        policy: policy,
        bootTime: { bootTime })
    return (service, power, store, log, notifier)
}

private func armedRecord(priorValue: Bool = false, ttlSeconds: Int = 3600)
    -> JournalRecord {
    JournalRecord(intent: .sleepDisabled, priorValue: priorValue, setAt: fixedNow,
                  setAtMonotonic: fixedUptime, ttlSeconds: ttlSeconds,
                  armedBy: ArmProvenance(pid: 4242, binaryPath: "/usr/local/bin/probe",
                                         uid: 501))
}

@Test func theWatchdogRevertsOnTTLExpiryWithNoHeartbeatAtAll() throws {
    // §8.2(3), and the CLI path's whole safety story. There is no XPC channel
    // on this path, so no heartbeat ever arrives; TTL expiry alone has to be
    // enough. A watchdog that needed a heartbeat to act would supervise nothing
    // that `sudo coffee-bar-probe arm` can produce.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let armed = try makeArmedWatchdog(root: root, record: armedRecord(ttlSeconds: 3600))

    let decision = try armed.service.evaluate(
        now: fixedNow.addingTimeInterval(3601),
        monotonicNow: uptime(after: 3601), lastHeartbeat: nil)

    #expect(decision == .revert(.ttlExpired))
    #expect(armed.power.state.current == false, "the TTL expired and sleep is still disabled")
    #expect(try armed.store.load() == nil, "the journal survived the revert")
    #expect(armed.log.calls.contains("watchdog.uninstall"))
    #expect(armed.notifier.posted.isEmpty == false, "§8.2(3) requires a notification")
}

@Test func theWatchdogNotifiesBeforeTheUninstallThatEndsTheProcess() throws {
    // #78. `uninstall()` runs `launchctl bootout system/<label>` from inside the
    // job that label names, so it does not come back. A `notify` sequenced after
    // it never fires — and the notification is the ONLY thing a revert produces
    // that a user can observe, because every rung of the ladder just returns
    // `.revert(reason)` to a process that is about to stop existing.
    //
    // Named bug this catches: `notifier.notify` placed below
    // `supervisor.uninstall()`. The test above cannot see it: its supervisor
    // returns from a call production never returns from, so the notification
    // lands in the test and never on the machine. The assertion here is taken at
    // the instant `uninstall` is entered, which is the last instant this code is
    // alive.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let supervisor = DyingSupervisor()
    let armed = try makeArmedWatchdog(root: root,
                                      record: armedRecord(ttlSeconds: 3600),
                                      supervisor: supervisor)
    let service = armed.service

    let thread = Thread {
        _ = try? service.evaluate(now: fixedNow.addingTimeInterval(3601),
                                  monotonicNow: uptime(after: 3601),
                                  lastHeartbeat: nil)
    }
    thread.start()
    defer { supervisor.releaseTheCaller() }

    #expect(supervisor.waitForUninstall(within: 10) == .success,
            "the TTL expired and the watchdog never uninstalled the daemon")
    #expect(armed.notifier.posted == ["reverted SleepDisabled to false: ttlExpired"], """
        the revert reached `uninstall` having notified nothing. `bootout` ends \
        this process, so a notification sequenced after it never fires and a TTL \
        revert is silent: sleep comes back and the user is never told why.
        posted: \(armed.notifier.posted)
        """)
}

@Test func theWatchdogHoldsWhileTheTTLIsLiveAndNoHeartbeatWriterExists() throws {
    // The positive control for the decision above, and it is load-bearing.
    //
    // `decide()` reverts with `.heartbeatLost` when `lastHeartbeat` is nil, so
    // a watchdog that passed nil straight through would revert every arm within
    // one 5 s tick and every "reverts" test in this file would still pass.
    // Absent heartbeat channel means TTL-only supervision, not instant revert.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let armed = try makeArmedWatchdog(root: root, record: armedRecord(ttlSeconds: 3600))

    let decision = try armed.service.evaluate(
        now: fixedNow.addingTimeInterval(60),
        monotonicNow: uptime(after: 60), lastHeartbeat: nil)

    #expect(decision == .hold, """
        the watchdog reverted a live arm 60 s in with 3600 s of TTL left. \
        `arm` is useless if supervision collapses the moment no heartbeat \
        writer exists.
        """)
    #expect(armed.power.state.current == true)
    #expect(try armed.store.load() != nil)
}

@Test func aForgedFutureHeartbeatCannotOutliveTheTTL() throws {
    // The heartbeat is the one input an unprivileged process could influence,
    // and its only power is to make the watchdog HOLD — the open failure
    // direction. So the TTL has to outrank it.
    //
    // `decide()` already tests TTL before the heartbeat guard; this pins that
    // ordering from the watchdog's own seam, where a future refactor could
    // undo it. A heartbeat a year in the future does not buy one extra second.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let armed = try makeArmedWatchdog(root: root, record: armedRecord(ttlSeconds: 3600))

    let decision = try armed.service.evaluate(
        now: fixedNow.addingTimeInterval(3601),
        monotonicNow: uptime(after: 3601),
        lastHeartbeat: fixedNow.addingTimeInterval(31_536_000))

    #expect(decision == .revert(.ttlExpired), """
        a forged heartbeat held the setting past its TTL. The heartbeat is \
        attacker-influenced and may only shorten a hold, never extend it.
        """)
    #expect(armed.power.state.current == false)
}

// MARK: - #77: a wall clock that steps cannot buy extra hold

@Test func aBackwardWallClockStepInsideTheLiveWindowDoesNotExtendTheHold() throws {
    // #77 driven the way it happens: `sudo coffee-bar-probe arm --ttl 28800`,
    // and 7 h 58 m later the machine's wall clock is put back seven hours.
    //
    // The second tick below used to answer `.hold`, and went on answering it
    // for another seven hours. Rung 3 tested `now < setAt` alone, so a step
    // landing INSIDE the live window passed it untouched, and the TTL rung then
    // compared the rewound clock against a deadline expressed in that same
    // rewound frame. Rung 6 is the only rung that ends a healthy hold on this
    // path — no reboot, no heat, no battery floor, no heartbeat channel — so
    // suppressing it suppresses the cap itself.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let armed = try makeArmedWatchdog(root: root,
                                      record: armedRecord(ttlSeconds: 28_800))

    // The premise, and it is load-bearing: 7 h 58 m in with both clocks
    // agreeing, the hold is healthy. Without it the revert below could just as
    // well be a daemon that refuses to hold anything.
    #expect(try armed.service.evaluate(now: fixedNow.addingTimeInterval(28_700),
                                       monotonicNow: uptime(after: 28_700),
                                       lastHeartbeat: nil) == .hold,
            "the daemon reverted a healthy hold, so the step below proves nothing")

    // One 5 s tick later. The wall clock now reads seven hours earlier than it
    // did; elapsed time does not, because nothing a user can type moves it.
    let decision = try armed.service.evaluate(
        now: fixedNow.addingTimeInterval(28_705 - 25_200),
        monotonicNow: uptime(after: 28_705),
        lastHeartbeat: nil)

    #expect(decision == .revert(.clockAnomaly), """
        the daemon held a root-set SleepDisabled straight through a seven-hour \
        backward clock step, and would keep holding it for seven more hours. \
        got: \(decision)
        """)
    #expect(armed.power.state.current == false,
            "the clock stepped backward and sleep is still disabled")
    #expect(try armed.store.load() == nil, "the journal survived the revert")
    #expect(armed.log.calls.contains("watchdog.uninstall"))
    #expect(armed.notifier.posted == ["reverted SleepDisabled to false: clockAnomaly"],
            "posted: \(armed.notifier.posted)")
}

@Test func theCapEndsTheHoldOnElapsedTimeWhileTheWallClockIsStillBehind() throws {
    // The cap itself, isolated from the anomaly signal above — and the two need
    // isolating, because the signal is a diagnostic and the cap is the
    // invariant SECURITY.md states.
    //
    // The wall clock here is 8 s behind real time, inside
    // `WatchdogPolicy.clockStepTolerance`, so the anomaly rung stays quiet by
    // design and the TTL rung is the only thing left that can end the hold.
    //
    // Named bug this catches: measuring the cap as `now > journal.expiry`. That
    // answers HOLD here — and answers it for however far the wall clock lags,
    // which is what turns #77's step into an extension rather than an error.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let armed = try makeArmedWatchdog(
        root: root,
        record: armedRecord(ttlSeconds: JournalRecord.maxTTLSeconds))
    let cap = TimeInterval(JournalRecord.maxTTLSeconds)

    // The premise: the same 8 s lag well inside the cap must NOT revert, or the
    // assertion below passes on a daemon that reverts unconditionally.
    #expect(try armed.service.evaluate(now: fixedNow.addingTimeInterval(cap - 108),
                                       monotonicNow: uptime(after: cap - 100),
                                       lastHeartbeat: nil) == .hold,
            "an 8 s clock lag ended a hold with 100 s of TTL left")

    let decision = try armed.service.evaluate(
        now: fixedNow.addingTimeInterval(cap - 7),      // wall clock: 7 s short
        monotonicNow: uptime(after: cap + 1),           // real time: 1 s past
        lastHeartbeat: nil)

    #expect(decision == .revert(.ttlExpired), """
        \(cap + 1) s of real time have passed on a \(cap) s cap and the daemon \
        is still holding, because the wall clock it measures against is 8 s \
        behind. SECURITY.md states that cap as a bound on a root-held setting. \
        got: \(decision)
        """)
    #expect(armed.power.state.current == false)
    #expect(try armed.store.load() == nil)
}

@Test func theWatchdogRevertsUnconditionallyWhenTheJournalPredatesTheLastBoot() throws {
    // §8.2(4). A journal written BEFORE the machine last booted means the armer
    // never got to clean up, so the machine came back holding a setting nobody
    // is supervising. The TTL is irrelevant here — this reverts with hours
    // left.
    //
    // The boot time is what makes the claim true. "A journal exists" alone
    // proves nothing about an unclean exit.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let armed = try makeArmedWatchdog(
        root: root, record: armedRecord(ttlSeconds: 28_800),
        // The machine booted AFTER the journal was written.
        bootTime: fixedNow.addingTimeInterval(1))

    let decision = try armed.service.evaluate(
        now: fixedNow.addingTimeInterval(5),
        monotonicNow: uptime(after: 5), lastHeartbeat: fixedNow)

    #expect(decision == .revert(.dirtyJournalAtBoot))
    #expect(armed.power.state.current == false)
    #expect(try armed.store.load() == nil)
}

@Test func theWatchdogDoesNotTreatItsOwnStartAsAMachineBoot() throws {
    // BLOCKER 1's root cause, isolated from the composition test.
    //
    // `isBootEvaluation` used to mean "this process just started", and the
    // daemon starts every time `arm` installs it — so `arm` armed the machine
    // and immediately reverted itself. It has to mean "the MACHINE booted since
    // this journal was written", which is a question only the boot time can
    // answer.
    //
    // Here the journal is written an hour after boot, with its TTL live. The
    // correct answer is to hold.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let armed = try makeArmedWatchdog(root: root,
                                      record: armedRecord(ttlSeconds: 3600),
                                      bootTime: fixedBoot)

    let decision = try armed.service.evaluate(
        now: fixedNow.addingTimeInterval(1),
        monotonicNow: uptime(after: 1), lastHeartbeat: nil)

    #expect(decision == .hold, """
        a fresh journal was read as a dirty boot, so the daemon undoes every \
        arm the moment launchd starts it.
        """)
    #expect(armed.power.state.current == true)
    #expect(try armed.store.load() != nil)
}

@Test func theWatchdogRestoresAPriorValueOfTrueRatherThanForcingSleepOn() throws {
    // Restore means restore. A user who had `disablesleep` set before coffee-bar
    // touched anything gets it back; the watchdog is not entitled to decide
    // that setting was wrong.
    //
    // Named bug this catches: a revert hardcoded to `set(false)`, which passes
    // every other revert test here because they all arm from `false`.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let armed = try makeArmedWatchdog(root: root,
                                      record: armedRecord(priorValue: true, ttlSeconds: 60))

    _ = try armed.service.evaluate(now: fixedNow.addingTimeInterval(61),
                                   monotonicNow: uptime(after: 61),
                                   lastHeartbeat: nil)

    #expect(armed.power.state.current == true,
            "the watchdog enabled sleep on a machine that had it disabled to begin with")
    #expect(try armed.store.load() == nil)
}

@Test func aRefusedJournalStillEndsWithTheSleepSettingRestored() throws {
    // The fail-safe direction, and the trap in SECURITY.md item 2. "Refuse to
    // act on it" cannot mean "do nothing": a watchdog that threw and stopped
    // would leave `SleepDisabled` held forever, which is precisely the failure
    // §8.2 exists to prevent. Refusing to TRUST the journal is not the same as
    // refusing to ACT.
    //
    // So the untrusted `priorValue` is discarded and the setting goes to
    // `false` — the safe direction — and the journal is quarantined as
    // evidence. The cost is real and deliberate: a user who genuinely had
    // `disablesleep` set loses it. An untrusted file cannot tell us otherwise.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let log = CallLog()
    let url = root.appending(path: "state/probe-journal.json")
    let store = FileJournalStore(url: url)
    try store.write(armedRecord(priorValue: true, ttlSeconds: 3600))

    // The gap SECURITY.md "One gap stays open on purpose" names: a directory the store did not create.
    let stateDir = url.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o777],
                                          ofItemAtPath: stateDir.path)

    let power = RecordingPower(log: log, state: .init(true))
    let notifier = RecordingNotifier()
    let service = WatchdogService(
        reader: GuardedJournalReader(url: url, store: store, requiredOwner: getuid()),
        power: power,
        supervisor: RecordingSupervisor(log: log),
        notifier: notifier,
        environment: FakeEnvironment())

    _ = try service.evaluate(now: fixedNow.addingTimeInterval(5),
                             monotonicNow: uptime(after: 5), lastHeartbeat: nil)

    #expect(power.state.current == false, """
        a refused journal left sleep disabled with nothing supervising it. \
        Refusing to trust the file is not a reason to leave the machine awake.
        """)
    let siblings = try FileManager.default.contentsOfDirectory(atPath: stateDir.path)
    #expect(siblings.contains { $0.hasPrefix("probe-journal.corrupt.") },
            "the refused journal was not quarantined: \(siblings)")
    #expect(notifier.posted.isEmpty == false)
}

@Test func aRefusedJournalNotifiesBeforeTheBootoutThatEndsTheProcess() throws {
    // The refusal path's half of the ordering `applyRevert` already pins.
    //
    // `uninstall()` boots out THIS daemon's own launchd job, so it does not
    // return — the process is gone. Anything sequenced after it never runs.
    // The refusal notification is the only account the user ever gets of why
    // the machine stopped holding sleep, and a refusal is exactly the case
    // where they are owed one: the journal was tampered with.
    //
    // `RecordingSupervisor` cannot see this. Its `uninstall` RETURNS, so the
    // notification fires either way and the existing guard above passes on
    // both orderings. `DyingSupervisor` blocks inside `uninstall` instead,
    // which is what the real bootout does, and `try?` cannot absorb a call
    // that never comes back — so the assertion runs at the last instant the
    // reverting process is still alive.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let url = root.appending(path: "state/probe-journal.json")
    let store = FileJournalStore(url: url)
    try store.write(armedRecord(priorValue: true, ttlSeconds: 3600))

    // The same tamper the guard above uses: a journal directory the store did
    // not create, left writable by everyone, which the reader must refuse.
    let stateDir = url.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o777],
                                          ofItemAtPath: stateDir.path)

    let supervisor = DyingSupervisor()
    let notifier = RecordingNotifier()
    let service = WatchdogService(
        reader: GuardedJournalReader(url: url, store: store, requiredOwner: getuid()),
        power: RecordingPower(log: CallLog(), state: .init(true)),
        supervisor: supervisor,
        notifier: notifier,
        environment: FakeEnvironment())

    let thread = Thread {
        _ = try? service.evaluate(now: fixedNow.addingTimeInterval(5),
                                  monotonicNow: uptime(after: 5),
                                  lastHeartbeat: nil)
    }
    thread.start()
    defer { supervisor.releaseTheCaller() }

    #expect(supervisor.waitForUninstall(within: 10) == .success,
            "the journal was refused and the watchdog never uninstalled the daemon")
    let posted = notifier.posted
    #expect(posted.count == 1
            && posted[0].hasPrefix("refused the journal and restored sleep: "), """
        the refusal reached `uninstall` having notified nothing. `bootout` ends \
        this process, so a notification sequenced after it never fires: sleep \
        comes back, the journal is quarantined, and the user is told neither.
        posted: \(posted)
        """)
}

@Test func revertNowUndoesAnArmedRunWhoseTTLHasHoursLeft() throws {
    // The developer escape hatch. A TTL of 8 h means `evaluate` would hold, so
    // this proves `revertNow` does not simply run the ordinary tick.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let armed = try makeArmedWatchdog(root: root,
                                      record: armedRecord(priorValue: false,
                                                          ttlSeconds: 28_800))

    #expect(try armed.service.revertNow() == true)
    #expect(armed.power.state.current == false)
    #expect(try armed.store.load() == nil)
    #expect(armed.log.calls.contains("watchdog.uninstall"))
}

@Test func revertNowReportsThatNothingWasArmed() throws {
    // A second `revert` is the ordinary case, not a failure. It must not throw
    // and must not claim to have undone something.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let log = CallLog()
    let url = root.appending(path: "state/probe-journal.json")
    let service = WatchdogService(
        reader: GuardedJournalReader(url: url, store: FileJournalStore(url: url),
                                     requiredOwner: getuid()),
        power: RecordingPower(log: log, state: .init(false)),
        supervisor: RecordingSupervisor(log: log),
        notifier: RecordingNotifier(),
        environment: FakeEnvironment())

    #expect(try service.revertNow() == false)
}

// MARK: - §8.1 aborts, through the daemon rather than through decide()

@Test func theWatchdogRevertsWhenTheMachineGetsHotUnderAClosedLid() throws {
    // Handoff §8.1: revert immediately on `thermalState >= .serious` while the
    // lid is closed. It calls thermal "the real risk", because a MacBook vents
    // through the hinge area and a closed lid under sustained agent load is the
    // worst case.
    //
    // `decide()` has covered this policy since M0. What was missing was the
    // WIRING: the daemon called `evaluate(now:)` and the thermal parameter
    // defaulted to `.nominal`, so the abort could not fire in production no
    // matter how hot the machine got. This drives the daemon, not `decide()`.
    //
    // Named bug this catches: a daemon that reads no thermal state. The TTL
    // here is 8 hours and the heartbeat is fine, so nothing else can revert.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let armed = try makeArmedWatchdog(
        root: root, record: armedRecord(priorValue: false, ttlSeconds: 28_800),
        environment: FakeEnvironment(thermal: .serious))

    let decision = try armed.service.evaluate(
        // `nil`, so the TTL-only substitution keeps the heartbeat guard quiet
        // and the input under test is the ONLY thing that can revert.
        now: fixedNow.addingTimeInterval(60),
        monotonicNow: uptime(after: 60), lastHeartbeat: nil)

    #expect(decision == .revert(.thermalAbort), """
        the daemon did not abort on a serious thermal state, so §8.1's thermal \
        rule is dead code in the one feature it exists to bound.
        """)
    // §8.1 says revert, notify and log — the same safe action as any other
    // revert, not a special case.
    #expect(armed.power.state.current == false)
    #expect(try armed.store.load() == nil, "the thermal abort left the journal behind")
    #expect(armed.log.calls.contains("watchdog.uninstall"))
    #expect(armed.notifier.posted.isEmpty == false)
}

@Test func theWatchdogRevertsWhenTheBatteryReachesTheFloorOnBatteryPower() throws {
    // §8.1: revert on battery at or below `batteryFloor`, default 20%.
    //
    // Same wiring gap as thermal: `batteryPercent` defaulted to nil and
    // `onBattery` to false, so this abort could never fire either.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let floor = WatchdogPolicy.default.batteryFloorPercent
    let armed = try makeArmedWatchdog(
        root: root, record: armedRecord(priorValue: false, ttlSeconds: 28_800),
        environment: FakeEnvironment(
            reading: PowerReading(source: .battery, percent: floor)))

    let decision = try armed.service.evaluate(
        // `nil`, so the TTL-only substitution keeps the heartbeat guard quiet
        // and the input under test is the ONLY thing that can revert.
        now: fixedNow.addingTimeInterval(60),
        monotonicNow: uptime(after: 60), lastHeartbeat: nil)

    #expect(decision == .revert(.batteryFloor))
    #expect(armed.power.state.current == false)
    #expect(try armed.store.load() == nil)
    #expect(armed.log.calls.contains("watchdog.uninstall"))
    #expect(armed.notifier.posted.isEmpty == false)
}

@Test func theWatchdogHoldsAtTheSameChargeWhenTheMachineIsOnACPower() throws {
    // The discriminator for the `onBattery` half of the wiring, and the reason
    // the test above cannot stand alone.
    //
    // A daemon that passed `onBattery: true` unconditionally — or that read the
    // charge and ignored the source — would pass the battery test and would
    // also revert every arm on a plugged-in machine sitting at 15%. That is a
    // desk-bound laptop that refuses to hold, which is the feature not working.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let floor = WatchdogPolicy.default.batteryFloorPercent
    let armed = try makeArmedWatchdog(
        root: root, record: armedRecord(priorValue: false, ttlSeconds: 28_800),
        environment: FakeEnvironment(
            reading: PowerReading(source: .ac, percent: floor - 5)))

    let decision = try armed.service.evaluate(
        // `nil`, so the TTL-only substitution keeps the heartbeat guard quiet
        // and the input under test is the ONLY thing that can revert.
        now: fixedNow.addingTimeInterval(60),
        monotonicNow: uptime(after: 60), lastHeartbeat: nil)

    #expect(decision == .hold, """
        the daemon reverted a charge below the floor while on AC power. The \
        floor is about draining the battery, and a plugged-in machine is not \
        draining it.
        """)
    #expect(armed.power.state.current == true)
}

@Test func theDaemonsBatteryFloorArrivesThroughTheBoundedRule() throws {
    // Issue #11's rule, checked on the daemon path: the floor is bounded at ONE
    // choke point every caller crosses, `BatteryFloor.bounded`, which
    // `WatchdogPolicy.init` calls rather than keeping its own clamp.
    //
    // This asserts the DAEMON honours the bounded value rather than the raw
    // one. An absurd floor of 1000 bounds to the top of `permitted`, which is
    // 50.
    //
    // **THE SECOND READING IS THE ONE THAT DISCRIMINATES, and the first cannot.**
    // The rule is `pct <= policy.batteryFloorPercent`. At 50 the bounded floor
    // reverts (50 <= 50) and so does an unbounded 1000 (50 <= 1000), so a
    // reading AT the floor gives the same answer either way. This comment
    // previously claimed an unbounded path "would compare against 1000, never
    // fire, and leave the abort silently dead" — that is backwards. An
    // unbounded floor fires MORE often, never less, so no reading at or below
    // 50 can tell the two apart, and the guard was passing for a reason
    // unrelated to what it said it checked.
    //
    // 60 separates them: above the bounded floor, below the raw one. Bounded
    // holds (60 > 50); unbounded reverts (60 <= 1000). Only the second reading
    // fails when the defect is reintroduced.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let policy = WatchdogPolicy(heartbeatTimeout: 45, batteryFloorPercent: 1000)
    #expect(policy.batteryFloorPercent == BatteryFloor.bounded(1000))
    #expect(policy.batteryFloorPercent == BatteryFloor.permitted.upperBound)

    let atTheFloor = try makeArmedWatchdog(
        root: root, record: armedRecord(priorValue: false, ttlSeconds: 28_800),
        environment: FakeEnvironment(
            reading: PowerReading(source: .battery, percent: 50)),
        policy: policy)

    #expect(try atTheFloor.service.evaluate(
        // `nil`, so the TTL-only substitution keeps the heartbeat guard quiet
        // and the input under test is the ONLY thing that can revert.
        now: fixedNow.addingTimeInterval(60),
        monotonicNow: uptime(after: 60), lastHeartbeat: nil)
        == .revert(.batteryFloor))

    // A SECOND root: the revert above cleared the first journal, so reusing it
    // would evaluate a machine with nothing armed and hold for that reason
    // instead of the one under test.
    let aboveRoot = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: aboveRoot) }

    let aboveTheFloor = try makeArmedWatchdog(
        root: aboveRoot, record: armedRecord(priorValue: false, ttlSeconds: 28_800),
        environment: FakeEnvironment(
            reading: PowerReading(source: .battery, percent: 60)),
        policy: policy)

    #expect(try aboveTheFloor.service.evaluate(
        now: fixedNow.addingTimeInterval(60),
        monotonicNow: uptime(after: 60), lastHeartbeat: nil)
        == .hold, """
        the daemon reverted at 60% against a floor that bounds to 50, so it is \
        reading the RAW configured floor of 1000 rather than the bounded one. \
        That is the defect `BatteryFloor.bounded` exists to prevent, and it \
        makes the abort fire on machines that are nowhere near empty.
        """)
    #expect(aboveTheFloor.power.state.current == true)
}

@Test func theThermalMirrorMapsEveryStateProcessInfoCanReport() {
    // `ThermalLevel` is a redeclaration of `ProcessInfo.ThermalState`, so the
    // mapping between them is a place two enums can silently disagree — and a
    // wrong mapping here reads `.critical` as `.nominal` and never aborts.
    //
    // Each case is a literal in, a literal out, never the mapping's own logic
    // re-run as the expectation.
    #expect(SystemWatchdogEnvironment.level(from: .nominal) == .nominal)
    #expect(SystemWatchdogEnvironment.level(from: .fair) == .fair)
    #expect(SystemWatchdogEnvironment.level(from: .serious) == .serious)
    #expect(SystemWatchdogEnvironment.level(from: .critical) == .critical)

    // The two that must clear §8.1's bar, stated as the rule rather than as
    // two more equalities: the abort fires at `.serious` and above.
    #expect(SystemWatchdogEnvironment.level(from: .serious).rawValue
            >= ThermalLevel.serious.rawValue)
    #expect(SystemWatchdogEnvironment.level(from: .critical).rawValue
            >= ThermalLevel.serious.rawValue)
    #expect(SystemWatchdogEnvironment.level(from: .fair).rawValue
            < ThermalLevel.serious.rawValue)
}

@Test func theWatchdogDoesNothingWhenNothingIsArmed() throws {
    // The idle case, which runs every 5 s forever. It must not notify, must not
    // touch the setting, and must not uninstall the daemon that is running it.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let log = CallLog()
    let url = root.appending(path: "state/probe-journal.json")
    let power = RecordingPower(log: log, state: .init(false))
    let notifier = RecordingNotifier()
    let service = WatchdogService(
        reader: GuardedJournalReader(url: url, store: FileJournalStore(url: url),
                                     requiredOwner: getuid()),
        power: power,
        supervisor: RecordingSupervisor(log: log),
        notifier: notifier,
        environment: FakeEnvironment())

    #expect(try service.evaluate(now: fixedNow, monotonicNow: fixedUptime,
                                 lastHeartbeat: nil) == .hold)
    #expect(log.calls.contains("power.set(false)") == false, "\(log.calls)")
    #expect(notifier.posted.isEmpty)
}

// MARK: - §8.2 acceptance: the armer is SIGKILLed

/// An armer that gets as far as a durable journal plus the system mutation, and
/// then never cleans up. Only a SIGKILL ends it.
///
/// It reproduces `FileJournalStore.write`'s durability sequence deliberately —
/// create at 0600, write, `F_FULLFSYNC`, rename, barrier the parent directory —
/// because the property under test is that the bytes SURVIVE the kill.
private let armerSource = #"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

/* argv: <journal path> <prepared json path> <modelled pmset state path> */
int main(int argc, char **argv) {
    if (argc < 4) return 2;

    static char buf[65536];
    FILE *src = fopen(argv[2], "rb");
    if (!src) return 3;
    size_t n = fread(buf, 1, sizeof(buf), src);
    fclose(src);
    if (n == 0) return 4;

    char tmp[4096];
    snprintf(tmp, sizeof(tmp), "%s.armer.tmp", argv[1]);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return 5;
    if (write(fd, buf, n) != (ssize_t)n) return 6;
    if (fcntl(fd, F_FULLFSYNC) == -1) return 7;
    close(fd);
    if (rename(tmp, argv[1]) != 0) return 8;

    char dir[4096];
    snprintf(dir, sizeof(dir), "%s", argv[1]);
    char *slash = strrchr(dir, '/');
    if (slash) *slash = '\0';
    int dfd = open(dir, O_RDONLY);
    if (dfd >= 0) { fcntl(dfd, F_FULLFSYNC); close(dfd); }

    /* The mutation the journal describes, modelled: `pmset -a disablesleep 1`. */
    FILE *rec = fopen(argv[3], "w");
    if (!rec) return 9;
    fprintf(rec, "1");
    fclose(rec);

    /* Armed, and holding the machine awake. Nothing below ever runs. */
    for (;;) pause();
}
"""#

private func buildArmer() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cb-armer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let source = dir.appendingPathComponent("armer.c")
    let binary = dir.appendingPathComponent("armer")
    try Data(armerSource.utf8).write(to: source)

    let cc = Process()
    cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    cc.arguments = ["-O0", "-o", binary.path, source.path]
    let errors = Pipe()
    cc.standardError = errors
    try cc.run()
    let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    cc.waitUntilExit()
    try #require(cc.terminationStatus == 0, "cc failed to build the armer: \(text)")
    return binary.path
}

@Test func theWatchdogRestoresTheSettingAfterTheArmerIsSIGKILLed() throws {
    // §8.2's acceptance criterion, with a real SIGKILL rather than a modelled
    // one. A SIGKILL cannot be caught, blocked or handled, so no `defer`, no
    // `atexit` and no signal handler runs — the only thing that can save the
    // machine is what was already on disk when the process died.
    //
    // The armer is a separate process that reaches the armed state and then
    // blocks forever. It shares the modelled power setting with this process
    // through a FILE, which is what makes the revert observable across the
    // kill; the real `pmset` shares system state the same way.
    //
    // LIMIT, stated rather than hidden: the child is a C stand-in that
    // reproduces `arm`'s disk sequence, NOT the shipped `ArmService`. The
    // shipped binary cannot be used here because it would drive the real
    // `pmset` and the real `launchctl` on this machine, which the brief
    // forbids, and no verb may take a path to a substitute. `arm`'s own
    // ordering is proven in-process by
    // `armWritesAndSyncsTheJournalBeforeItTouchesTheSleepSetting`; what this
    // test adds is that the state left behind survives a real kill and is
    // enough for the real watchdog to recover.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let stateDir = root.appending(path: "state")
    try FileManager.default.createDirectory(
        at: stateDir, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    let journalURL = stateDir.appending(path: "probe-journal.json")
    let powerFile = root.appending(path: "sleep-disabled").path

    // The bytes the armer will make durable are the PRODUCTION encoder's, not
    // a hand-rolled JSON string: staged through a real `FileJournalStore`.
    let staging = root.appending(path: "staged.json")
    let record = armedRecord(priorValue: false, ttlSeconds: 60)
    try FileJournalStore(url: staging).write(record)

    let power = FileBackedPower(path: powerFile)
    try power.set(false)

    let armer = Process()
    armer.executableURL = URL(fileURLWithPath: try buildArmer())
    armer.arguments = [journalURL.path, staging.path, powerFile]
    try armer.run()
    defer { if armer.isRunning { kill(armer.processIdentifier, SIGKILL) } }

    // Pins the premise: without this the kill proves nothing, because a child
    // that never armed cannot demonstrate a recovery.
    let deadline = Date().addingTimeInterval(10)
    var armed = false
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: journalURL.path),
           (try? power.isEnabled()) == true { armed = true; break }
        usleep(20_000)
    }
    try #require(armed, "the armer never reached the armed state; every assertion below would be vacuous")

    kill(armer.processIdentifier, SIGKILL)
    armer.waitUntilExit()

    // Proof that no cleanup ran, rather than an assumption about it. A child
    // that exited normally reports `.exit`; only a signalled one reports
    // `.uncaughtSignal`.
    #expect(armer.terminationReason == .uncaughtSignal)
    #expect(armer.terminationStatus == SIGKILL)
    #expect(kill(armer.processIdentifier, 0) == -1, "the armer is somehow still alive")

    // The machine as the user would find it: sleep disabled, a journal on
    // disk, and nothing running that knows why.
    #expect(try power.isEnabled() == true)
    #expect(FileManager.default.fileExists(atPath: journalURL.path))

    // Now the daemon takes its turn, exactly as `RunAtLoad` would have it.
    let log = CallLog()
    let store = FileJournalStore(url: journalURL)
    let notifier = RecordingNotifier()
    let watchdog = WatchdogService(
        reader: GuardedJournalReader(url: journalURL, store: store,
                                     requiredOwner: getuid()),
        power: power,
        supervisor: RecordingSupervisor(log: log),
        notifier: notifier,
        environment: FakeEnvironment())

    let decision = try watchdog.evaluate(
        now: fixedNow.addingTimeInterval(61),
        monotonicNow: uptime(after: 61), lastHeartbeat: nil)

    #expect(decision == .revert(.ttlExpired))
    #expect(try power.isEnabled() == false, """
        the watchdog did not restore the setting after the armer was killed. \
        This is §8.2's acceptance criterion and the whole point of the journal.
        """)
    #expect(try store.load() == nil, "the journal survived the revert")
    #expect(log.calls.contains("watchdog.uninstall"))
    #expect(notifier.posted.isEmpty == false)
}
