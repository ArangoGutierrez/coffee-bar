// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoffeeBarCore

/// Forces the internal panel off, and reports whether it went.
///
/// Handoff §8.3: `SleepDisabled` alone leaves the panel lit under a closed lid,
/// which burns the battery the whole feature exists to save.
public protocol DisplaySleepForcing: Sendable {
    func forceSleep() throws
    /// `nil` when the panel's power state cannot be read — genuinely unknown,
    /// never "awake". Collapsing the two would report a lit screen as dark.
    func isDisplayAwake() -> Bool?
}

/// Tells the user something happened while they were not looking.
///
/// A protocol rather than a direct call because the privileged CLI has no
/// user-facing notification channel: a launchd daemon runs in no GUI session,
/// so `StandardErrorNotifier` writes where launchd captures it and a human
/// finds it afterwards. That is weaker than the notification §8.2(3) asks for,
/// and it is what a path with no app-side channel can honestly deliver.
public protocol Notifying: Sendable {
    func notify(_ message: String)
}

public struct StandardErrorNotifier: Notifying {
    public init() {}

    public func notify(_ message: String) {
        FileHandle.standardError.write(Data("coffee-bar-probe: \(message)\n".utf8))
    }
}

/// `pmset displaysleepnow`, which is the documented way to put the panel to
/// sleep immediately without holding any assertion.
public struct PmsetDisplaySleeper: DisplaySleepForcing {
    private let runner: any CommandRunning
    private let probe: DisplayStateProbe

    public init(runner: any CommandRunning, probe: DisplayStateProbe = DisplayStateProbe()) {
        self.runner = runner
        self.probe = probe
    }

    public func forceSleep() throws {
        let result = try runner.run(PmsetSleepDisabledController.pmsetPath,
                                    ["displaysleepnow"])
        guard result.exitCode == 0 else {
            throw PowerControlError.commandFailed(
                exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    public func isDisplayAwake() -> Bool? {
        probe.isInternalDisplayAwake()
    }
}

public enum ArmError: Error, Equatable {
    /// §8.3's abort. The panel was still lit after it was told to sleep, so the
    /// mode is refused rather than left cooking the battery.
    case displayStayedAwake
}

/// Enters lid-closed mode: journal, watchdog, power setting, display.
///
/// The ordering is the entire contract and none of it is incidental.
///
/// 1. The journal is written and `F_FULLFSYNC`'d FIRST (§8.2(1)). A journal
///    written after the mutation is defeated by a SIGKILL in the window
///    between the two: sleep held, nothing on disk saying so.
/// 2. The watchdog is installed BEFORE the setting changes. §8.2 does not
///    spell this out, but a process that dies between `pmset` and `install()`
///    leaves a held setting that no daemon exists to revert — `RunAtLoad` and
///    `KeepAlive` supervise a job that was never loaded.
/// 3. Only then does `SleepDisabled` go to 1, and the display is forced off.
///
/// Every failure after step 1 rolls back to the journal's `priorValue`. The
/// value comes from the RECORD, never from a fresh read: a rollback that
/// re-read the setting would read back its own `true` and re-apply it, which is
/// the defect `LaunchDaemonInstaller.install` documents at its `bootout` call.
public struct ArmService: Sendable {
    private let journal: any JournalStoring
    private let power: any SleepDisabledControlling
    private let supervisor: any WatchdogSupervising
    private let display: any DisplaySleepForcing
    private let clock: @Sendable () -> Date
    private let displayVerifyDelay: TimeInterval

    /// `clock` and `displayVerifyDelay` stay injectable so tests need no wall
    /// clock. No dependency here is reachable from argv: SECURITY.md forbids a
    /// verb that takes a path to execute, and `ProbeVerb` takes none.
    public init(journal: any JournalStoring,
                power: any SleepDisabledControlling,
                supervisor: any WatchdogSupervising,
                display: any DisplaySleepForcing,
                clock: @escaping @Sendable () -> Date = HostInfo.now,
                displayVerifyDelay: TimeInterval = 5) {
        self.journal = journal
        self.power = power
        self.supervisor = supervisor
        self.display = display
        self.clock = clock
        self.displayVerifyDelay = displayVerifyDelay
    }

    public func arm(ttlSeconds: Int) throws {
        // Read the value to restore TO. Never assumed false (spec D6): a
        // machine that already had `disablesleep` set keeps it on revert.
        let priorValue = try power.isEnabled()

        // `JournalRecord.init` clamps the TTL to 8 h (§8.2(5)), so the cap
        // applies here by construction rather than by a second literal.
        let record = JournalRecord(
            intent: .sleepDisabled,
            priorValue: priorValue,
            setAt: clock(),
            ttlSeconds: ttlSeconds,
            armedBy: Self.provenance())

        // Step 1. Durable before anything else moves.
        try journal.write(record)

        do {
            try supervisor.install()          // Step 2: supervisor first.
            try power.set(true)               // Step 3.
            try display.forceSleep()

            // §8.3's re-verify. The handoff times this from the lid-close
            // event; a CLI cannot observe one, so it is timed from the force
            // instead. See the report: the lid-close half is untested.
            if displayVerifyDelay > 0 {
                Thread.sleep(forTimeInterval: displayVerifyDelay)
            }
            // `nil` — the measured Apple Silicon answer, per
            // `DisplayStateProbe` — is NOT treated as awake. Aborting on
            // unknown would abort every arm on the only hardware this ships
            // to; the trade is deliberate and recorded in the report.
            if display.isDisplayAwake() == true {
                throw ArmError.displayStayedAwake
            }
        } catch {
            rollBack(to: record.priorValue)
            throw error
        }
    }

    /// Undoes everything step 1 committed to.
    ///
    /// Every step is best-effort and none may abort the others: a rollback that
    /// stopped at its first failure is how a machine keeps a held setting. The
    /// original error is what reaches the caller.
    private func rollBack(to priorValue: Bool) {
        try? power.set(priorValue)
        try? supervisor.uninstall()
        try? journal.clear()
    }

    /// Advisory forensics only. SECURITY.md item 4: in this threat model the
    /// provenance is attacker-controlled data and is never authentication.
    private static func provenance() -> ArmProvenance {
        ArmProvenance(pid: getpid(),
                      binaryPath: Bundle.main.executablePath ?? "",
                      uid: getuid())
    }
}

/// The daemon side: decides whether `SleepDisabled` may stay set, and undoes it
/// when it may not.
///
/// The decision itself lives in `CoffeeBarCore.decide`, which is pure and
/// already tested. This type owns only the effects — read the journal under the
/// SECURITY.md preconditions, apply the verdict, clean up, notify.
public struct WatchdogService: Sendable {
    private let reader: GuardedJournalReader
    private let power: any SleepDisabledControlling
    private let supervisor: any WatchdogSupervising
    private let notifier: any Notifying
    private let policy: WatchdogPolicy
    private let bootTime: @Sendable () -> Date

    /// `bootTime` is injectable so a test can drive both sides of §8.2(4)
    /// without rebooting. Production reads `kern.boottime`.
    public init(reader: GuardedJournalReader,
                power: any SleepDisabledControlling,
                supervisor: any WatchdogSupervising,
                notifier: any Notifying,
                policy: WatchdogPolicy = .default,
                bootTime: @escaping @Sendable () -> Date = SystemBootTime.current) {
        self.reader = reader
        self.power = power
        self.supervisor = supervisor
        self.notifier = notifier
        self.policy = policy
        self.bootTime = bootTime
    }

    private enum JournalState {
        case nothingArmed
        case armed(JournalRecord)
        /// Refused AND already handled: the setting is restored and the file
        /// is quarantined.
        case refused
    }

    /// One tick of the 5 s timer.
    @discardableResult
    public func evaluate(now: Date,
                         lastHeartbeat: Date? = nil,
                         thermal: ThermalLevel = .nominal,
                         batteryPercent: Int? = nil,
                         onBattery: Bool = false) throws -> WatchdogDecision {
        switch readJournal() {
        case .refused:
            return .revert(.journalRefused)
        case .nothingArmed:
            return .hold
        case .armed(let record):
            let inputs = WatchdogInputs(
                journal: record,
                now: now,
                // No heartbeat channel means TTL-ONLY supervision, not an
                // instant revert. `decide()` treats a nil heartbeat as
                // `.heartbeatLost`, which is right when a channel exists and
                // has gone quiet; on the CLI path there is no channel at all,
                // and collapsing the two would revert every `arm` within one
                // tick.
                //
                // Substituting `now` is safe because it can only ever make the
                // heartbeat guard PASS, and `decide()` tests the TTL first — so
                // no heartbeat, forged or absent, buys a second past expiry.
                lastHeartbeat: lastHeartbeat ?? now,
                // §8.2(4) asks whether the MACHINE booted while this journal
                // was live — an unclean exit. It does NOT ask whether this
                // process just started, and conflating the two was a defect
                // that made the feature undo itself: `install()` writes a plist
                // with `RunAtLoad`, so `arm` starts this daemon, whose first
                // tick then reverted the journal `arm` had just written. The
                // measured end state was sleep held, journal deleted and the
                // daemon booted out, with no attacker anywhere near it.
                //
                // `setAt` is truncated DOWN to the second by `HostInfo.now`, so
                // a journal written in the same second as the boot can read as
                // older than it. That errs toward reverting, which is the safe
                // direction.
                isBootEvaluation: record.setAt < bootTime(),
                thermal: thermal,
                batteryPercent: batteryPercent,
                onBattery: onBattery)

            let decision = decide(inputs, policy: policy)
            guard case .revert(let reason) = decision else { return decision }
            try applyRevert(record: record, reason: reason)
            return decision
        }
    }

    /// The `revert` verb: undo an armed run now, whatever its TTL says.
    ///
    /// Deliberately NOT "pretend the machine booted". That spelling worked only
    /// while `isBootEvaluation` was a caller-supplied flag, and it is exactly
    /// the conflation above. A human asking is its own reason.
    ///
    /// Returns whether anything was armed.
    @discardableResult
    public func revertNow() throws -> Bool {
        switch readJournal() {
        case .refused:
            return true          // something WAS armed, and it is now undone
        case .nothingArmed:
            return false
        case .armed(let record):
            try applyRevert(record: record, reason: .operatorRequested)
            return true
        }
    }

    /// Reads the journal, handling a refusal in full.
    ///
    /// A refusal fails SAFE, not closed. "Refuse to act on it" (SECURITY.md
    /// item 2) cannot mean "do nothing": stopping there would leave
    /// `SleepDisabled` held forever, which is the exact failure §8.2 exists to
    /// prevent. The untrusted `priorValue` is discarded and the setting goes to
    /// `false` — the safe direction — rather than to a number an attacker may
    /// have chosen. The reader has already quarantined the file.
    ///
    /// The cost is real: a user who genuinely had `disablesleep` set loses it.
    /// An untrusted file cannot tell us otherwise.
    private func readJournal() -> JournalState {
        do {
            guard let record = try reader.read() else { return .nothingArmed }
            return .armed(record)
        } catch {
            try? power.set(false)
            try? reader.clear()
            try? supervisor.uninstall()
            notifier.notify("refused the journal and restored sleep: \(error)")
            return .refused
        }
    }

    private func applyRevert(record: JournalRecord, reason: RevertReason) throws {
        // The journal passed every precondition, so the restore uses its
        // recorded `priorValue`.
        try power.set(record.priorValue)
        try reader.clear()
        // Best-effort, and last: `bootout` ends the very process running this,
        // so anything after it may not run. A failure to unload must not leave
        // the revert half-done.
        try? supervisor.uninstall()
        notifier.notify("reverted SleepDisabled to \(record.priorValue): \(reason.rawValue)")
    }
}

/// When this machine last booted, from `kern.boottime`.
///
/// §8.2(4) turns on this value: a journal written BEFORE the last boot is
/// evidence of an unclean exit, and one written after it is not.
public enum SystemBootTime {
    public static func current() -> Date {
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else {
            // An unknown boot time must not switch the check off. `now` makes
            // every journal look older than the boot, so every armed run
            // reverts on the next tick. That loses the feature and keeps the
            // machine safe, which is the right way round.
            return Date()
        }
        return Date(timeIntervalSince1970:
            Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000)
    }
}
