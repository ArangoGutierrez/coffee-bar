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

private func makeScratchRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "coffee-bar-lid-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    return root
}

private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

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
        power: RecordingPower(log: log, state: .init(false)),
        supervisor: RecordingSupervisor(log: log),
        display: RecordingDisplay(log: log, awakeAfterForcing: false),
        clock: { fixedNow },
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
        power: RecordingPower(log: log, state: .init(false)),
        supervisor: RecordingSupervisor(log: log),
        display: RecordingDisplay(log: log, awakeAfterForcing: false),
        clock: { fixedNow },
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
        power: RecordingPower(log: log, state: .init(true)),   // already set
        supervisor: RecordingSupervisor(log: log),
        display: RecordingDisplay(log: log, awakeAfterForcing: false),
        clock: { fixedNow },
        displayVerifyDelay: 0)

    try service.arm(ttlSeconds: 3600)

    let written = try #require(try store.load())
    #expect(written.priorValue == true)
    #expect(written.setAt == fixedNow)
    #expect(written.intent == .sleepDisabled)
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
        power: RecordingPower(log: log, state: .init(false)),
        supervisor: RecordingSupervisor(log: log),
        display: RecordingDisplay(log: log, awakeAfterForcing: false),
        clock: { fixedNow },
        displayVerifyDelay: 0)

    try service.arm(ttlSeconds: 99_999_999)

    let written = try #require(try store.load())
    #expect(written.ttlSeconds == JournalRecord.maxTTLSeconds)
    #expect(written.ttlSeconds == 8 * 60 * 60)
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
        power: power,
        supervisor: RecordingSupervisor(log: log),
        display: RecordingDisplay(log: log, awakeAfterForcing: false, failOnForce: true),
        clock: { fixedNow },
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
        power: power,
        supervisor: RecordingSupervisor(log: log, failOnInstall: true),
        display: RecordingDisplay(log: log, awakeAfterForcing: false),
        clock: { fixedNow },
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
        power: RecordingPower(log: log, state: .init(false)),
        supervisor: RecordingSupervisor(log: log),
        display: RecordingDisplay(log: log, awakeAfterForcing: false),
        clock: { fixedNow },
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
        power: power,
        supervisor: RecordingSupervisor(log: log),
        display: RecordingDisplay(log: log, awakeAfterForcing: true),  // stayed lit
        clock: { fixedNow },
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
        power: power,
        supervisor: RecordingSupervisor(log: log),
        display: RecordingDisplay(log: log, awakeAfterForcing: nil),
        clock: { fixedNow },
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
        bootTime: { fixedBoot })

    // Exactly what launchd runs at load: the `watchdog` verb, one tick.
    supervisor.runAtLoad = { _ = try? watchdog.evaluate(now: fixedNow) }

    let service = ArmService(
        journal: RecordingJournal(log: log, inner: store),
        power: power,
        supervisor: supervisor,
        display: RecordingDisplay(log: log, awakeAfterForcing: false),
        clock: { fixedNow },
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

// MARK: - §8.2(2,3) — the watchdog reverts

/// Builds a watchdog over a scratch journal that already holds `record`.
private func makeArmedWatchdog(root: URL, record: JournalRecord,
                               initiallyEnabled: Bool = true,
                               bootTime: Date = fixedBoot)
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
        supervisor: RecordingSupervisor(log: log),
        notifier: notifier,
        bootTime: { bootTime })
    return (service, power, store, log, notifier)
}

private func armedRecord(priorValue: Bool = false, ttlSeconds: Int = 3600)
    -> JournalRecord {
    JournalRecord(intent: .sleepDisabled, priorValue: priorValue, setAt: fixedNow,
                  ttlSeconds: ttlSeconds,
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
        now: fixedNow.addingTimeInterval(3601), lastHeartbeat: nil)

    #expect(decision == .revert(.ttlExpired))
    #expect(armed.power.state.current == false, "the TTL expired and sleep is still disabled")
    #expect(try armed.store.load() == nil, "the journal survived the revert")
    #expect(armed.log.calls.contains("watchdog.uninstall"))
    #expect(armed.notifier.posted.isEmpty == false, "§8.2(3) requires a notification")
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
        now: fixedNow.addingTimeInterval(60), lastHeartbeat: nil)

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
        lastHeartbeat: fixedNow.addingTimeInterval(31_536_000))

    #expect(decision == .revert(.ttlExpired), """
        a forged heartbeat held the setting past its TTL. The heartbeat is \
        attacker-influenced and may only shorten a hold, never extend it.
        """)
    #expect(armed.power.state.current == false)
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
        now: fixedNow.addingTimeInterval(5), lastHeartbeat: fixedNow)

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
        now: fixedNow.addingTimeInterval(1), lastHeartbeat: nil)

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

    _ = try armed.service.evaluate(now: fixedNow.addingTimeInterval(61), lastHeartbeat: nil)

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

    // The gap SECURITY.md:184-190 names: a directory the store did not create.
    let stateDir = url.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o777],
                                          ofItemAtPath: stateDir.path)

    let power = RecordingPower(log: log, state: .init(true))
    let notifier = RecordingNotifier()
    let service = WatchdogService(
        reader: GuardedJournalReader(url: url, store: store, requiredOwner: getuid()),
        power: power,
        supervisor: RecordingSupervisor(log: log),
        notifier: notifier)

    _ = try service.evaluate(now: fixedNow.addingTimeInterval(5), lastHeartbeat: nil)

    #expect(power.state.current == false, """
        a refused journal left sleep disabled with nothing supervising it. \
        Refusing to trust the file is not a reason to leave the machine awake.
        """)
    let siblings = try FileManager.default.contentsOfDirectory(atPath: stateDir.path)
    #expect(siblings.contains { $0.hasPrefix("probe-journal.corrupt.") },
            "the refused journal was not quarantined: \(siblings)")
    #expect(notifier.posted.isEmpty == false)
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
        notifier: RecordingNotifier())

    #expect(try service.revertNow() == false)
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
        notifier: notifier)

    #expect(try service.evaluate(now: fixedNow, lastHeartbeat: nil) == .hold)
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
        notifier: notifier)

    let decision = try watchdog.evaluate(
        now: fixedNow.addingTimeInterval(61), lastHeartbeat: nil)

    #expect(decision == .revert(.ttlExpired))
    #expect(try power.isEnabled() == false, """
        the watchdog did not restore the setting after the armer was killed. \
        This is §8.2's acceptance criterion and the whole point of the journal.
        """)
    #expect(try store.load() == nil, "the journal survived the revert")
    #expect(log.calls.contains("watchdog.uninstall"))
    #expect(notifier.posted.isEmpty == false)
}
