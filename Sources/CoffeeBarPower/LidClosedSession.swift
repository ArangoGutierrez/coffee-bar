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
    /// The journal path fails the bar the reader applies, so arming would
    /// produce a setting the daemon must refuse to explain. Nothing is held.
    case journalPathRefused(JournalRefusal)
    /// The journal was gone by the end of `arm`. Something reverted underneath
    /// it, so the arm is failed and rolled back rather than reported as
    /// success.
    case journalVanished
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
    private let reader: GuardedJournalReader
    private let power: any SleepDisabledControlling
    private let supervisor: any WatchdogSupervising
    private let display: any DisplaySleepForcing
    private let clock: @Sendable () -> Date
    private let monotonicClock: @Sendable () -> TimeInterval
    private let bootSession: @Sendable () -> String?
    private let displayVerifyDelay: TimeInterval

    /// `clock` and `displayVerifyDelay` stay injectable so tests need no wall
    /// clock. No dependency here is reachable from argv: SECURITY.md forbids a
    /// verb that takes a path to execute, and `ProbeVerb` takes none.
    ///
    /// `reader` is the same guard the daemon uses. `arm` asks it two questions:
    /// may this path be armed at all, and is the journal still there at the
    /// end. Both exist to keep one invariant.
    public init(journal: any JournalStoring,
                reader: GuardedJournalReader,
                power: any SleepDisabledControlling,
                supervisor: any WatchdogSupervising,
                display: any DisplaySleepForcing,
                clock: @escaping @Sendable () -> Date = HostInfo.now,
                monotonicClock: @escaping @Sendable () -> TimeInterval
                    = SystemMonotonicClock.now,
                bootSession: @escaping @Sendable () -> String?
                    = SystemBootTime.currentSessionID,
                displayVerifyDelay: TimeInterval = 5) {
        self.journal = journal
        self.reader = reader
        self.power = power
        self.supervisor = supervisor
        self.display = display
        self.clock = clock
        self.monotonicClock = monotonicClock
        self.bootSession = bootSession
        self.displayVerifyDelay = displayVerifyDelay
    }

    /// Arms lid-closed mode and answers with the hold the JOURNAL kept.
    ///
    /// **The return value is read back off the disk, never handed straight
    /// through.** `JournalRecord` clamps the TTL to §8.2(5)'s eight hours, so
    /// the number a caller was given and the number the machine will honour are
    /// different values whenever the request is over the cap — and the probe
    /// printed the caller's one, telling a user their laptop would stay awake
    /// for 999999s while `WatchdogDecision.decide` reverted it at 28800.
    ///
    /// It is the CONFIRMED record's value rather than `record.ttlSeconds`,
    /// because the confirmation read is what already proves the file is there
    /// and is the same read the daemon will make. Clamping a second time at the
    /// print site would copy the rule instead, which drifts the moment the cap
    /// moves and agrees with a record that was written wrong.
    ///
    /// `@discardableResult`, because the answer is a REPORT rather than the
    /// point of the call: `arm` succeeds or throws, and a caller with nothing to
    /// print is not making a mistake by ignoring it. `main.swift` is the one
    /// caller that prints, and
    /// `theProbePrintsTheHoldItTookAndNotTheNumberOnTheCommandLine` is what
    /// keeps it printing this rather than argv.
    @discardableResult
    public func arm(ttlSeconds: Int) throws -> Int {
        // THE INVARIANT this function answers for:
        //
        //   `arm` never returns success while the system holds a setting the
        //   journal cannot explain.
        //
        // Two guards keep it. This is the first: refuse a path the READER would
        // refuse, before anything at all is held. Without it, a directory an
        // earlier build left 0755 is written, refused on the read side, and the
        // daemon's fail-safe restores and uninstalls — after which `arm` sets
        // the flag regardless, turning "refuse safely" into "hold forever".
        do {
            try reader.validatePath()
        } catch let refusal as JournalRefusal {
            throw ArmError.journalPathRefused(refusal)
        }

        // Read the value to restore TO. Never assumed false (spec D6): a
        // machine that already had `disablesleep` set keeps it on revert.
        let priorValue = try power.isEnabled()

        // `JournalRecord.init` clamps the TTL to 8 h (§8.2(5)), so the cap
        // applies here by construction rather than by a second literal.
        let record = JournalRecord(
            intent: .sleepDisabled,
            priorValue: priorValue,
            setAt: clock(),
            // Sampled beside `setAt`, and it is what the cap is measured
            // against. The wall stamp stays because a human reading `report`
            // needs a date, not a since-boot number.
            setAtMonotonic: monotonicClock(),
            // Which boot this hold belongs to, so the daemon can tell an
            // unclean exit from its own start without consulting a clock.
            //
            // `""` when the identity cannot be read. The daemon treats that as
            // a different boot and reverts on its next tick — the same
            // direction an unreadable `kern.boottime` used to take, and the
            // reason the unknown is not a sentinel that could match another
            // unknown.
            bootSessionID: bootSession() ?? "",
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

            // The second guard, and the general one. Deciding §8.2(4) from the
            // MACHINE's boot rather than from this process's start removed the
            // daemon's REASON to revert on its first tick; it did not remove
            // its ABILITY, and nothing stops a future policy, an
            // operator running `revert`, or a race nobody has thought of from
            // clearing the journal in this window.
            //
            // So the invariant is enforced by OBSERVATION rather than by
            // enumerating causes: read the journal back, and if it cannot be
            // read, fail the arm and put the setting back. That converts every
            // such race — present and future — from "held forever" into "failed
            // arm", which the user can see and retry.
            //
            // Deliberately LAST, so it covers the widest window `arm` can see,
            // including the display verification above. A launchd exec is
            // asynchronous, so a revert landing after this point is still
            // possible; that residue belongs to the daemon's own next tick and
            // is recorded in the report rather than claimed as closed.
            let confirmed = (try? reader.read()) ?? nil
            guard let confirmed else {
                throw ArmError.journalVanished
            }

            // The hold the machine is actually under, off the disk. Everything
            // that ends this hold — the daemon's ticks, `revert`, `report` —
            // reads this file, so it is the only value a caller may announce.
            return confirmed.ttlSeconds
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
/// What the machine is doing right now, for the aborts §8.1 requires.
///
/// A seam rather than direct calls, because the alternative is a daemon whose
/// behaviour depends on the temperature of whatever machine runs the suite.
public protocol WatchdogEnvironmentSensing: Sendable {
    func thermalLevel() -> ThermalLevel
    func power() -> PowerReading
}

/// The production sensor: `ProcessInfo` for heat, IOKit for the battery.
public struct SystemWatchdogEnvironment: WatchdogEnvironmentSensing {
    private let powerReader: any PowerReadingProviding

    public init(powerReader: any PowerReadingProviding = SystemPowerReader()) {
        self.powerReader = powerReader
    }

    /// `ProcessInfo.ThermalState` onto `CoffeeBarCore`'s mirror of it.
    ///
    /// Split from the instance method so the mapping is testable without
    /// heating a laptop up. The mirror exists so `CoffeeBarCore` stays
    /// Foundation-only, and two enums that mean the same thing are exactly
    /// where a silent disagreement lives — a `.critical` read as `.nominal`
    /// never aborts.
    public static func level(from state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        // A state this build has never heard of is treated as the WORST case.
        // Every uncertain path in this component resolves toward reverting, and
        // guessing `.nominal` for an unknown thermal state would do the
        // opposite in the one place §8.1 calls the real risk.
        @unknown default: return .critical
        }
    }

    public func thermalLevel() -> ThermalLevel {
        Self.level(from: ProcessInfo.processInfo.thermalState)
    }

    public func power() -> PowerReading {
        powerReader.read()
    }
}

public struct WatchdogService: Sendable {
    private let reader: GuardedJournalReader
    private let power: any SleepDisabledControlling
    private let supervisor: any WatchdogSupervising
    private let notifier: any Notifying
    private let environment: any WatchdogEnvironmentSensing
    private let policy: WatchdogPolicy
    private let bootSession: @Sendable () -> String?

    /// `bootSession` is injectable so a test can drive both sides of §8.2(4)
    /// without rebooting. Production reads `kern.bootsessionuuid`.
    ///
    /// `environment` has NO default, deliberately. A default of
    /// `SystemWatchdogEnvironment()` would let a caller reach a decision
    /// without ever deciding where the thermal and battery readings come from —
    /// which is precisely how §8.1's two aborts shipped as dead code, with
    /// `evaluate` defaulting them to `.nominal` and `nil`. Making the parameter
    /// required means the omission cannot recur silently.
    public init(reader: GuardedJournalReader,
                power: any SleepDisabledControlling,
                supervisor: any WatchdogSupervising,
                notifier: any Notifying,
                environment: any WatchdogEnvironmentSensing,
                policy: WatchdogPolicy = .default,
                bootSession: @escaping @Sendable () -> String?
                    = SystemBootTime.currentSessionID) {
        self.reader = reader
        self.power = power
        self.supervisor = supervisor
        self.notifier = notifier
        self.environment = environment
        self.policy = policy
        self.bootSession = bootSession
    }

    /// Whether this journal was written in a DIFFERENT boot than the one now
    /// running — §8.2(4)'s question, asked of two identities.
    ///
    /// UNKNOWN on either side counts as another boot. Every uncertain path in
    /// this component resolves toward reverting, and an identity nobody can
    /// read is no evidence that the armer survived: answering "same boot" there
    /// would keep `SleepDisabled` set for a process that may be long gone.
    ///
    /// The emptiness checks are the reason this is a function rather than a
    /// `!=`. Two unreadable identities are not one boot, but `"" == ""` is
    /// true — so the naive comparison says "same boot" precisely when least is
    /// known, which is the answer that suppresses the revert.
    private static func isFromAnotherBoot(record: JournalRecord,
                                          current: String?) -> Bool {
        guard let current, !current.isEmpty, !record.bootSessionID.isEmpty else {
            return true
        }
        return record.bootSessionID != current
    }

    private enum JournalState {
        case nothingArmed
        case armed(JournalRecord)
        /// Refused AND already handled: the setting is restored and the file
        /// is quarantined.
        case refused
    }

    /// One tick of the 5 s timer.
    ///
    /// The thermal and battery readings are NOT parameters. They were, with
    /// safe-looking defaults of `.nominal` and `nil`, and the daemon called
    /// `evaluate(now:)` — so §8.1's two aborts could not fire in production
    /// however hot the machine got or however low the charge fell. Reading them
    /// from the injected environment removes the caller's chance to forget.
    ///
    /// `monotonicNow` is REQUIRED and has no default, for that same reason: a
    /// default is how an input ships unwired. It is also the only reading here
    /// a wall clock cannot move, so a caller that quietly skipped it would put
    /// the 8-hour cap back on the clock issue #77 showed can be stepped.
    @discardableResult
    public func evaluate(now: Date,
                         monotonicNow: TimeInterval,
                         lastHeartbeat: Date? = nil) throws -> WatchdogDecision {
        switch readJournal() {
        case .refused:
            return .revert(.journalRefused)
        case .nothingArmed:
            return .hold
        case .armed(let record):
            // Sampled ONCE per tick, before the decision, so every branch of
            // `decide()` sees one consistent view of the machine.
            let reading = environment.power()
            let inputs = WatchdogInputs(
                journal: record,
                now: now,
                monotonicNow: monotonicNow,
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
                //
                // **SAID PLAINLY, because #74 asked and a half-answer here is
                // worse than none: THIS SUBSTITUTION MAKES RUNG 7 UNABLE TO
                // FIRE ON THIS PATH.** `main.swift`'s watchdog loop calls
                // `evaluate(now:monotonicNow:)` and never passes a heartbeat, so
                // `beat == now` on every tick the daemon takes,
                // `now.timeIntervalSince(beat)` is 0, and 0 is inside any
                // timeout. Not "rarely fires" — cannot. A guard that cannot
                // fire is theatre, so it has to be justified or removed, and
                // this is the justification:
                //
                //   1. What is inert is this CALLER, not the rung. `decide()`
                //      is public in `CoffeeBarCore` and takes a real
                //      `lastHeartbeat`; `staleHeartbeatReverts` and
                //      `missingHeartbeatReverts` drive it and pass. Deleting
                //      the rung would delete a live guard to tidy away one
                //      caller's substitution.
                //   2. The substitution is not optional. Passing `nil` through
                //      makes `decide()` answer `.heartbeatLost` on the first 5 s
                //      tick and revert every `arm` immediately —
                //      `theWatchdogHoldsWhileTheTTLIsLiveAndNoHeartbeatWriterExists`
                //      is the positive control for exactly that.
                //   3. It cannot be abused, because it sits BELOW the cap.
                //      Rung 6 ends the hold on elapsed monotonic time whatever
                //      this value is, so a heartbeat — absent, substituted, or
                //      forged a year into the future — buys nothing.
                //      `aForgedFutureHeartbeatCannotOutliveTheTTL` pins the
                //      ordering and
                //      `anACHoldRunsTheWholeConfiguredCapAndOnlyTheCapEndsIt`
                //      pins that it stays inert across the full 24-hour ceiling
                //      #74 raised the cap to, which is the far end the 60-second
                //      control above never reached.
                //
                // #74 asked specifically whether removing the TTL would remove
                // this justification with it. It would have — point 3 IS the
                // TTL — and that is one of the reasons the hold stayed bounded
                // rather than running indefinitely on AC. The TTL still exists;
                // it is the configurable hold now rather than a fixed half
                // hour, and it is still tested first. Building a real heartbeat
                // is a new channel into a root daemon and is out of scope here:
                // SECURITY.md's claim is that there is no channel at all, and
                // adding one needs its own review rather than a comment.
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
                // Asked of the boot's IDENTITY, and no longer of its clock.
                // This compared `record.setAt` against `kern.boottime` — a
                // frozen stamp against a live realtime reading, so the two
                // respond differently to a step of the wall clock and the
                // answer moves with it. Two UUIDs do not (#83).
                isBootEvaluation: Self.isFromAnotherBoot(record: record,
                                                         current: bootSession()),
                // §8.1: thermal is the abort that matters most here — a MacBook
                // vents through the hinge area, and a closed lid under
                // sustained agent load is the worst case the handoff names.
                thermal: environment.thermalLevel(),
                batteryPercent: reading.percent,
                // The SOURCE decides, not the charge. A plugged-in laptop at
                // 15% is not draining, and reverting there would refuse to hold
                // on a machine that is in no danger.
                onBattery: reading.source == .battery)

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
            // Notify BEFORE the bootout. `uninstall()` ends this process, so
            // anything sequenced after it never runs — and this notification is
            // the only account the user gets of why the machine stopped holding
            // sleep, in the one case where the journal was tampered with. Both
            // mutations the message describes are already done above, so it is
            // true at the moment it is posted.
            notifier.notify("refused the journal and restored sleep: \(error)")
            try? supervisor.uninstall()
            return .refused
        }
    }

    private func applyRevert(record: JournalRecord, reason: RevertReason) throws {
        // The journal passed every precondition, so the restore uses its
        // recorded `priorValue`.
        try power.set(record.priorValue)
        try reader.clear()
        // Before the uninstall, not after it. `bootout` ends the very process
        // running this, so a notification sequenced after it never fires — and
        // this is the ONLY output a revert produces that a user can observe,
        // since every rung of the ladder merely returns `.revert(reason)`. Both
        // mutations it describes are already done above, so the message is
        // still true at the moment it is posted.
        notifier.notify("reverted SleepDisabled to \(record.priorValue): \(reason.rawValue)")
        // Best-effort, and last: a failure to unload must not leave the revert
        // half-done, and this call may not return at all.
        try? supervisor.uninstall()
    }
}

/// This machine's boot, as an identity.
///
/// §8.2(4) turns on the IDENTITY, and `currentSessionID` is the only reader
/// here because it is the only one anything needs. A `current()` returning the
/// boot as a `Date` from `kern.boottime` stood here until `#83`; rung 2 was its
/// only caller, and reading a wall clock is exactly what that rung stopped
/// doing. `git show b9bd084` has it if a caller ever turns up.
public enum SystemBootTime {
    /// `kern.bootsessionuuid`: a fresh UUID string for each boot of this
    /// machine, and the value §8.2(4) is decided on.
    ///
    /// It is an identity, not a reading, which is the whole point. The check
    /// used to compare TWO wall-clock values — a realtime `kern.boottime`
    /// against the journal's `setAt`, and only the second of those is frozen on
    /// disk, so a step of the clock moved the answer. Whatever a clock step does
    /// to a pair of timestamps, it cannot make two different UUIDs equal.
    ///
    /// `nil` when the identity cannot be read, and deliberately NOT a sentinel
    /// string. A sentinel would compare EQUAL to the sentinel an arm that could
    /// not read it either stamped into the journal, and equal is the answer
    /// that suppresses the revert. The caller resolves the unknown toward
    /// reverting; see `WatchdogService`.
    public static func currentSessionID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0,
              size > 0 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0
        else {
            return nil
        }
        // `String(cString:)` over an array is deprecated. sysctl writes a
        // NUL-terminated C string into a buffer it sized to include that
        // terminator, so the bytes before the first NUL are the value.
        let identity = String(decoding: buffer.prefix(while: { $0 != 0 }),
                              as: UTF8.self)
        // An empty answer is an unreadable one. Collapsing the two here means
        // no caller has to know that the sysctl can succeed and say nothing.
        return identity.isEmpty ? nil : identity
    }
}
