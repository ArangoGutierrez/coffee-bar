// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import CoffeeBarCore
import CoffeeBarPower
import CoffeeBarTestSupport
@testable import CoffeeBarUI

// Issue #71's last acceptance line: "the helper is removable from the UI, and
// removal is verified".
//
// **The ORDER is the safety property, and it is the whole of this file.** A
// removal that unregisters first and reverts afterwards leaves the machine in
// exactly the state `GuardedJournalReader` documents — `SleepDisabled` set with
// no record of why — with the one thing that could put it back now removed. The
// Mac cannot sleep and nothing is left to fix it, short of a root shell.
//
// So the sequence is: ask the HELPER to revert, read the flag back, and only
// then ask macOS to unregister. Every check below is stated over the order or
// over an abort, because a removal that does all three steps in the wrong order
// passes every "did it call unregister" assertion there is.
//
// **WHICH hold is reverted, because an earlier draft of this file got it
// wrong.** `AssertionHolding.release()` drops the IOKit assertion THIS PROCESS
// holds. `SleepDisabled` is a system-wide setting written by ROOT through
// `pmset`, and only the privileged helper can put it back. Releasing the app's
// assertion cannot clear it, so a sequence built on `release()` could never
// verify anything mid-hold and refused instead of removing.
// `theRemovalLeavesTheAppsOwnAssertionAlone` pins the correction from the other
// side: the app's assertion is not this control's business at all.
//
// NOTHING HERE REACHES macOS OR THE ROOT DAEMON. Every model is handed doubles
// for both halves of the helper seam, and the two checks that drive
// `PrivilegedHelperClient` itself drive the CLOSED gate — a build whose
// signature names no team, which is what the `swift test` runner is.

// MARK: - Test doubles

/// Every step of a removal, in the order it actually happened.
///
/// A shared log across unrelated doubles, and that is the point: the invariant
/// is not "each step happened" but "they happened in this order". A call counter
/// on each double separately is green over the reversal this file exists to
/// catch.
private final class RemovalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [String] = []

    func record(_ step: String) {
        lock.lock()
        defer { lock.unlock() }
        steps.append(step)
    }

    var recorded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return steps
    }

    /// Forgets everything recorded so far.
    ///
    /// For the checks that have to call `refresh()` before the click, because
    /// the property they assert on is only written there. `refresh()` reconciles
    /// the assertion and so records a step of its own, which belongs to the
    /// setup rather than to the removal.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        steps = []
    }
}

/// The IOKit assertion, recording what was asked of it rather than asking it.
///
/// Present so that a removal which touched the app's own assertion would be
/// VISIBLE, not because the sequence uses one. See
/// `theRemovalLeavesTheAppsOwnAssertionAlone`.
private final class LoggingHolder: AssertionHolding, @unchecked Sendable {
    private let log: RemovalLog

    init(log: RemovalLog) { self.log = log }

    @discardableResult
    func acquire(displaySleep: Bool) -> Bool {
        log.record("acquire")
        return true
    }

    func release() { log.record("release") }
}

/// A `pmset -g` read that never runs `pmset`.
///
/// `disabled == nil` is the read FAILING, which is a third state and not a
/// synonym for `false`: `PmsetSleepDisabledController.isEnabled()` throws
/// `PowerControlError.unreadableState` rather than answering "off" for a value
/// it cannot interpret, precisely so a caller cannot conclude there is nothing
/// holding the machine.
private final class LoggingSleepHold: SleepHoldReporting, @unchecked Sendable {
    private let log: RemovalLog
    private let disabled: Bool?

    init(log: RemovalLog, disabled: Bool?) {
        self.log = log
        self.disabled = disabled
    }

    func sleepIsDisabled() async throws -> Bool {
        log.record("read SleepDisabled")
        guard let disabled else { throw UnreadableFlag.thePmsetOutputMadeNoSense }
        return disabled
    }
}

/// What a `pmset -g` that could not be interpreted looks like to the model.
private enum UnreadableFlag: Error {
    case thePmsetOutputMadeNoSense
}

/// Both halves of the removal seam in one object, which is how the shipping app
/// is wired: `PrivilegedHelperClient` reports the registration, asks the helper
/// to revert, and takes the registration off.
///
/// It flips itself to inactive on a successful unregister, so a model that
/// remembered the answer from `init` is visible to a check.
private final class FakeHelper: RegisteredHelperReporting, HelperRemovalControlling,
                                @unchecked Sendable {
    private let lock = NSLock()
    private let log: RemovalLog
    private let revertRefusal: String?
    private let unregisterFails: Bool
    private var active: Bool

    init(log: RemovalLog,
         active: Bool,
         revertRefusal: String? = nil,
         unregisterFails: Bool = false) {
        self.log = log
        self.active = active
        self.revertRefusal = revertRefusal
        self.unregisterFails = unregisterFails
    }

    /// Deliberately UNLOGGED. The model is entitled to ask this as often as it
    /// likes; the order that matters is the one over the three ACTIONS.
    func registeredHelperIsActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func revert() async -> HelperRevertOutcome {
        log.record("revert")
        if let revertRefusal { return .refused(revertRefusal) }
        return .reverted(wasArmed: true)
    }

    func unregisterHelper() throws {
        log.record("unregister")
        if unregisterFails { throw UnregisterFailed.macOSDeclined }
        lock.lock()
        defer { lock.unlock() }
        active = false
    }
}

/// What macOS refusing the unregister looks like to the model.
private enum UnregisterFailed: Error {
    case macOSDeclined
}

/// A `HelperRegistering` that records what the client asked macOS to do.
///
/// Used only by the closed-gate check, where the point is that NOTHING is
/// asked. The list is asserted against a literal rather than each method
/// recording an issue, so a failure names what was asked and not merely that
/// something was.
private final class RecordingService: HelperRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private var asks: [String] = []

    var registrationState: HelperRegistrationState {
        lock.lock()
        defer { lock.unlock() }
        asks.append("status")
        return .enabled
    }

    func register() throws {
        lock.lock()
        defer { lock.unlock() }
        asks.append("register")
    }

    func unregister() throws {
        lock.lock()
        defer { lock.unlock() }
        asks.append("unregister")
    }

    var asked: [String] {
        lock.lock()
        defer { lock.unlock() }
        return asks
    }
}

/// A settings store held in memory, so no check writes the preferences of
/// whoever runs the suite.
private final class FakeSettings: SettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    func bool(forKey key: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return values[key] as? Bool
    }

    func setBool(_ value: Bool, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    func integer(forKey key: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return values[key] as? Int
    }

    func setInteger(_ value: Int, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    func stringArray(forKey key: String) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        return values[key] as? [String]
    }

    func setStringArray(_ value: [String], forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }
}

/// The power reader the model reads once in `init`.
private final class FakeReader: PowerReadingProviding, @unchecked Sendable {
    func read() -> PowerReading { PowerReading(source: .ac, percent: 80) }
}

/// A hook-health reader pointed at a committed fixture, so nothing here reads
/// the machine's own `~/.claude/settings.json`.
private func fixtureHealth() -> HookHealthReader {
    HookHealthReader(settingsURL: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()    // …/Tests/CoffeeBarUITests
        .deletingLastPathComponent()    // …/Tests
        .appending(path: "Fixtures/claude-settings/wired.json"))
}

/// A model wired to the doubles above and to nothing else.
@MainActor
private func modelForRemoval(log: RemovalLog,
                             helper: FakeHelper,
                             sleepDisabled: Bool?) -> ServingModel {
    ServingModel(holder: LoggingHolder(log: log),
                 reader: FakeReader(),
                 health: fixtureHealth(),
                 registration: helper,
                 removal: helper,
                 sleepHold: LoggingSleepHold(log: log, disabled: sleepDisabled),
                 settings: FakeSettings())
}

// MARK: - The order, which is the safety property

@MainActor
@Test func theHelperIsUnregisteredOnlyAfterTheHoldIsRevertedAndTheFlagIsReadClear() async {
    // THE check this feature turns on. Its mutant is the obvious mistake and it
    // is one move: unregister first, revert afterwards. Every "was unregister
    // called" assertion stays green over that, and the machine it leaves behind
    // is the one `GuardedJournalReader` describes — `SleepDisabled` set, no
    // journal saying why, and the daemon that would have put it back gone.
    //
    // The three steps are asserted as ONE literal array rather than as three
    // separate expectations, because "each happened" is not the invariant and a
    // suite that asserts it passes over the reversal.
    let log = RemovalLog()
    let helper = FakeHelper(log: log, active: true)
    let model = modelForRemoval(log: log, helper: helper, sleepDisabled: false)

    let outcome = await model.removeRegisteredHelper()

    #expect(log.recorded == ["revert", "read SleepDisabled", "unregister"], """
        the removal ran its steps as \(log.recorded). The order is the safety \
        property: unregistering before the flag is confirmed clear leaves \
        SleepDisabled set with the only thing that could clear it removed.
        """)
    #expect(outcome == .removed,
            "a removal that completed every step reported \(outcome) instead of .removed")
}

@MainActor
@Test func aRevertTheHelperRefusedAbortsTheRemoval() async {
    // The case that strands the machine, and it is REAL rather than
    // hypothetical: the helper is the only thing that can put `SleepDisabled`
    // back, and a revert it refused means the setting is still where it was.
    // Carrying on to the unregister deletes the one process able to fix that.
    //
    // Named bug: `_ = await removal.revert()`, or a `switch` whose refusal case
    // falls through. Either compiles, and every later assertion in this file
    // stays green over both.
    let log = RemovalLog()
    let helper = FakeHelper(log: log, active: true,
                            revertRefusal: "the journal is owned by uid 501")
    let model = modelForRemoval(log: log, helper: helper, sleepDisabled: false)

    let outcome = await model.removeRegisteredHelper()

    #expect(log.recorded == ["revert"], """
        the removal ran \(log.recorded) after the helper refused to end its \
        hold. Nothing may follow a revert that did not happen: the flag is \
        still set and the helper is the only thing that can clear it.
        """)
    #expect(outcome != .removed,
            "a removal whose revert was refused reported .removed")

    // The helper's OWN words reach the user. "Removal failed" hides the one
    // sentence that says what to fix, which is the argument
    // `HelperArmOutcome.statusLine` already makes for passing a refusal through
    // verbatim.
    #expect(outcome.statusLine.contains("the journal is owned by uid 501"), """
        the refusal dropped the helper's own explanation, so the user is told \
        the removal failed and not why: \(outcome.statusLine)
        """)
}

@MainActor
@Test func aSleepFlagStillSetAfterTheRevertAbortsTheRemoval() async {
    // Named bug: reading the flag, ignoring the answer, and unregistering
    // anyway — a verification that is performed and not ACTED on.
    //
    // The state this describes is a helper that REPORTED success and a machine
    // that disagrees, which is exactly why the verification reads `pmset` rather
    // than trusting the reply. Something else is holding the setting, and
    // removing the helper would leave nothing on the machine able to clear it.
    let log = RemovalLog()
    let helper = FakeHelper(log: log, active: true)
    let model = modelForRemoval(log: log, helper: helper, sleepDisabled: true)

    let outcome = await model.removeRegisteredHelper()

    #expect(log.recorded == ["revert", "read SleepDisabled"], """
        the removal ran \(log.recorded) with the machine's sleep still \
        disabled. Unregistering here removes the daemon that puts the setting \
        back, and nothing else on the machine will.
        """)
    #expect(outcome != .removed,
            "a removal that never unregistered anything reported .removed")

    // The sentence has to name the setting, because the user's next action
    // depends on knowing WHICH thing is still held. "Removal failed." sends
    // them nowhere.
    #expect(outcome.statusLine.contains("SleepDisabled"), """
        the refusal does not name the setting that blocked it, so the user is \
        told the removal failed and not what to do about it: \
        \(outcome.statusLine)
        """)
}

@MainActor
@Test func aSleepFlagThatCannotBeReadAbortsTheRemovalRatherThanAssumingItIsClear() async {
    // Named bug, and it is one character: `try?`. Collapsing the read's failure
    // to `nil` — or to `false` — turns "I could not find out" into "there is
    // nothing holding it", which is the exact reasoning
    // `PmsetSleepDisabledController.isEnabled()` refuses to do when `pmset`
    // prints a value it cannot interpret. An unread setting is not evidence the
    // machine is free.
    let log = RemovalLog()
    let helper = FakeHelper(log: log, active: true)
    let model = modelForRemoval(log: log, helper: helper, sleepDisabled: nil)

    let outcome = await model.removeRegisteredHelper()

    #expect(log.recorded == ["revert", "read SleepDisabled"], """
        the removal ran \(log.recorded) without ever learning whether the \
        machine's sleep was disabled. A read that failed is not a read that \
        answered no.
        """)
    #expect(outcome != .removed,
            "a removal that could not verify anything reported .removed")

    // A DIFFERENT sentence from the one above, because the two states need
    // different actions from the user: "something else is holding the setting"
    // versus "this machine's power settings could not be read at all". One
    // message for both is the shape this discriminates against.
    #expect(outcome.statusLine.contains("could not read"), """
        the refusal for an UNREADABLE flag reads the same as the refusal for a \
        flag that is set, so the user is sent after the wrong fault: \
        \(outcome.statusLine)
        """)
}

@MainActor
@Test func theRemovalLeavesTheAppsOwnAssertionAlone() async {
    // THE CORRECTION, pinned from the side it can be pinned from.
    //
    // An earlier draft of this sequence opened with `holder.release()`, on the
    // reasoning that a removal should let go of the hold first. That conflates
    // two mechanisms: `AssertionHolding` is the IOKit assertion THIS PROCESS
    // holds, and `SleepDisabled` is a system setting only root can write. The
    // release cannot clear the flag, so it bought no safety — and it is a side
    // effect the user did not ask for, because whether coffee-bar holds sleep
    // for a working agent has nothing to do with whether the privileged helper
    // is installed. `refresh()` owns that decision and would re-acquire on the
    // next tick anyway.
    //
    // Named bug: re-adding `holder.release()` to this sequence.
    let log = RemovalLog()
    let helper = FakeHelper(log: log, active: true)
    let model = modelForRemoval(log: log, helper: helper, sleepDisabled: false)

    #expect(await model.removeRegisteredHelper() == .removed,
            "precondition: the removal completed")

    #expect(!log.recorded.contains("release"), """
        the removal touched the app's own IOKit assertion: \(log.recorded). \
        That is a different hold from the one being ended, and dropping it \
        stops coffee-bar holding sleep for a working agent as a side effect of \
        uninstalling a helper.
        """)
    #expect(!log.recorded.contains("acquire"),
            "the removal acquired an assertion: \(log.recorded)")
}

@MainActor
@Test func removalIsRefusedWhenMacOSReportsNoRegisteredHelper() async {
    // The window offers the control only while a helper is registered, and this
    // is the model-side half of that: a click that arrives anyway — a stale
    // window, or a registration dropped between the render and the click — must
    // not open a channel to a root daemon that is not there.
    //
    // NOTHING is touched, which is the assertion.
    let log = RemovalLog()
    let helper = FakeHelper(log: log, active: false)
    let model = modelForRemoval(log: log, helper: helper, sleepDisabled: false)

    let outcome = await model.removeRegisteredHelper()

    #expect(log.recorded == [], """
        a removal with nothing to remove still did \(log.recorded), against a \
        helper macOS says is not registered.
        """)
    #expect(outcome != .removed,
            "the model claimed it removed a helper that was never registered")
}

@MainActor
@Test func anUnregisterMacOSRefusedIsReportedRatherThanClaimedAsDone() async {
    // Named bug: `try? removal.unregisterHelper()` followed by `.removed`. The
    // window would tell the user the helper is gone while the daemon is still
    // registered and still running, and the control that could try again would
    // disappear with it, because the model would also have marked the
    // registration inactive.
    let log = RemovalLog()
    let helper = FakeHelper(log: log, active: true, unregisterFails: true)
    let model = modelForRemoval(log: log, helper: helper, sleepDisabled: false)
    // The property below is written in `refresh()` alone, so it has to have run
    // once for "the model still reports a registered helper" to mean anything.
    model.refresh()
    log.reset()

    let outcome = await model.removeRegisteredHelper()

    #expect(log.recorded == ["revert", "read SleepDisabled", "unregister"],
            "the removal ran \(log.recorded); the attempt itself must still happen")
    #expect(outcome != .removed,
            "an unregister macOS refused was reported to the user as .removed")
    #expect(model.registeredHelperIsActive, """
        the model marked the helper gone after an unregister that FAILED, so \
        the window hides the only control that could try again while the \
        daemon is still registered and still running.
        """)
}

@MainActor
@Test func theRemovalControlGoesAwayWithoutARelaunchOnceTheHelperIsGone() async {
    // Named bug: reading the registration only in `refresh()`, which runs on a
    // 30-second timer. The click that makes the answer false happens in the
    // Preferences window of a running app, so a value left until the next tick
    // leaves the user looking at a Remove button for a helper that is already
    // gone — and clicking it a second time refuses. The same frozen-state
    // defect `armingThroughTheHelperClearsTheStaleAdvisoryOnTheNextRefresh`
    // names, pointed the other way.
    let log = RemovalLog()
    let helper = FakeHelper(log: log, active: true)
    let model = modelForRemoval(log: log, helper: helper, sleepDisabled: false)
    model.refresh()

    #expect(model.registeredHelperIsActive,
            "precondition: the model reports a registered helper before the click")

    #expect(await model.removeRegisteredHelper() == .removed,
            "precondition: the removal completed")

    // NO second `refresh()`. That is the whole check.
    #expect(model.registeredHelperIsActive == false, """
        the model still reports a registered helper after removing it. The \
        window keeps offering Remove for a daemon macOS no longer runs, until \
        the next 30-second tick or a relaunch.
        """)
}

// MARK: - The gates on the client itself

@Test func anUnsignableBuildNeverAsksMacOSToUnregisterAnything() {
    // The mirror of `register()`'s opening `guard`, and it is not decoration.
    // A `brew install` bundle names no team, so it could never have registered
    // this daemon — and asking macOS about that job on such a build asks about
    // a registration belonging to whoever DID make one. Unregistering there
    // takes off somebody else's helper.
    //
    // `RunningSignature { nil }` is the state the `swift test` runner is really
    // in, measured by `theRunningBuildReadsItsOwnSignatureRatherThanAssumingOne`.
    // Driving the CLOSED gate is safe by construction: the guard closes one line
    // in and the service below it is never reached.
    let service = RecordingService()
    let client = PrivilegedHelperClient(signature: RunningSignature { nil },
                                        daemon: { service })

    #expect(throws: (any Error).self) {
        try client.unregisterHelper()
    }

    #expect(service.asked == [], """
        a build that names no team asked macOS for \(service.asked). It cannot \
        have registered this daemon, so anything it takes off belongs to \
        somebody else.
        """)
}

@Test func anUnsignableBuildNeverAsksTheLiveHelperToRevert() async {
    // The SAME gate on the other new entry point, and here the consequence is
    // not about macOS at all. Past this guard `revert()` opens a channel to a
    // ROOT daemon and asks it to change a system power setting. On a machine
    // with a registered helper that is a live side effect, and `swift test`
    // must never be one click from it.
    //
    // **LIMIT, stated because it bounds what this check is worth.** It measures
    // the OUTCOME and not the reachability: the refusal is the shape a build
    // with no team gets, and this proves the method answers it. Nothing here
    // can prove the channel was not opened, because the only way to observe
    // that is to delete the guard and see what happens — against the live
    // daemon. That mutant is deliberately not run, and this is what the live
    // exercise has to cover instead.
    let client = PrivilegedHelperClient(signature: RunningSignature { nil })

    let outcome = await client.revert()

    #expect(outcome != .reverted(wasArmed: true),
            "a build that names no team reported a revert it cannot have performed")
    guard case .refused(let reason) = outcome else {
        Issue.record("expected a refusal, got \(outcome)")
        return
    }
    // The EXACT sentence, and the substring it replaces was not a stylistic
    // choice. `HelperRemovalRefusal.thisBuildCouldNotHaveRegisteredIt` opens
    // with the same words -- "This build is not signed by coffee-bar's
    // developer, so it" -- and then says something else entirely: that it "must
    // not take one off". `contains("not signed")` cannot tell the two apart, so
    // the plausible copy-paste (returning the UNREGISTER refusal from `revert()`)
    // stays green while the user is told coffee-bar declined to remove
    // something, at a moment when nothing was being removed.
    #expect(reason == HelperAvailability.unavailable.explanation, """
        the refusal is not the availability sentence, so the user reads a \
        channel failure, or a refusal about a removal, instead of the reason \
        there is no channel: \(reason)
        """)
}

// MARK: - The surface

@Test func thePreferencesWindowOffersRemovalOnlyWhileAHelperIsRegistered() throws {
    // PRESENCE and CONDITIONALITY together, because for this control they are
    // one decision. `ServingModel` can hold the whole sequence and
    // `PrivilegedHelperClient` can take the registration off with every check
    // in this package green while no surface offers a way to do it — the shape
    // `ProcGovernor` and `LaunchDaemonInstaller` both shipped in, which issue
    // #13 exists to complain about.
    //
    // The condition is the other half: a Remove button on a Mac with no
    // registered helper does nothing a user can understand, and on an unsigned
    // build there is nothing it could ever remove.
    //
    // COMMENT-STRIPPED, for the reason the quiet-others guard gives:
    // `PreferencesView.swift` explains every control at length, so a raw read
    // would be satisfied by prose about a control that had been deleted.
    let prefs = try removalSurfaceCode()

    // The block the control has to live in, found by its condition. A `contains`
    // over the whole file proves the button is SPELLED, which is not the
    // invariant: moving it out of the `if` leaves every `contains` green.
    let gated = try #require(braceBlock(after: "if model.registeredHelperIsActive", in: prefs), """
        PreferencesView.swift has no `if model.registeredHelperIsActive` block, \
        so either the removal control is gone or it is offered on machines with \
        no helper to remove.
        """)

    #expect(gated.block.contains("removeRegisteredHelper()"), """
        the removal control is not inside the block that checks for a \
        registered helper, so the window offers Remove on a Mac that has \
        nothing to remove, including every unsigned build, where the click \
        could only ever refuse.
        """)

    #expect(gated.block.contains("ServingModel.removeHelperLabel"), """
        PreferencesView.swift names its own label for the removal control. It \
        belongs on ServingModel beside the other control labels, where a check \
        can read it.
        """)

    // The ARM button must NOT have been swept into the same condition. Gating it
    // on an existing registration is how the button that CREATES one becomes
    // unreachable, and it is a plausible way to write this change that no
    // `contains` check above would notice.
    #expect(!gated.block.contains("buttonTitle"), """
        the arm control was moved inside the registered-helper condition, so \
        the button that registers the helper is offered only to users who \
        already have one.
        """)
}

/// `PreferencesView.swift`, comment-stripped.
///
/// Resolved from `#filePath` rather than from the working directory, so the
/// scan reads the file in THIS worktree and not whichever checkout the suite
/// happens to be launched from.
private func removalSurfaceCode() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()    // …/Tests/CoffeeBarUITests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // the package root
    let view = root.appending(path: "Sources/CoffeeBarUI/PreferencesView.swift")
    return swiftCodeWithoutComments(try String(contentsOf: view, encoding: .utf8))
}

// MARK: - Where the pmset read runs

/// A `CommandRunning` that runs nothing and remembers WHERE it was asked to.
///
/// `Thread.isMainThread` is sampled inside `run`, which is the exact instant the
/// real `SystemCommandRunner` forks `/usr/bin/pmset` and blocks its caller until
/// the child and both drain threads are finished. Sampling anywhere else — at
/// construction, or after the `await` has already hopped back — measures a
/// different question and answers it green.
private final class ThreadWitnessRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var sawMain = false
    private var calls = 0

    func run(_ executable: String, _ arguments: [String],
             timeout: TimeInterval) throws -> CommandResult {
        let onMain = Thread.isMainThread
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        sawMain = sawMain || onMain
        // A `pmset -g` that says the machine is free. The value is irrelevant to
        // what this measures, but it has to PARSE: a controller that threw would
        // return before the witness could be read on some future rewrite.
        return CommandResult(exitCode: 0, stdout: "SleepDisabled\t\t0\n", stderr: "")
    }

    var ranOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sawMain
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

/// `Thread.isMainThread` sampled through a SYNCHRONOUS call, deliberately.
///
/// The property is unavailable from asynchronous contexts, and the reason is a
/// good one: an `async` body can resume on a different thread after every
/// suspension point, so the answer describes an instant and not a function.
/// A synchronous call pins that instant, which is exactly what the premise
/// below needs — `pump()` in `IngestListener_test.swift` reads it the same way
/// and for the same reason.
private func runningOnTheMainThread() -> Bool { Thread.isMainThread }

@MainActor
@Test func theSleepFlagIsReadOffTheMainActorRatherThanBlockingIt() async throws {
    // Named bug: `try sleepHold.sleepIsDisabled()` called straight from the
    // `@MainActor` body of `removeRegisteredHelper()`. That is what shipped in
    // the first two rounds of this branch, and what it costs is not visible in
    // any other check here — every order and abort assertion in this file stays
    // green over it, because the SEQUENCE is right and only the THREAD is wrong.
    //
    // The cost, measured: `/usr/bin/pmset -g` is about 10 ms typical, and
    // `SystemCommandRunner.run` bounds itself at 30 s rather than at 10 ms. Both
    // numbers land on the thread that draws the window, immediately after the
    // user clicks Remove. #71h removed a 5.72 ms main-actor block from this same
    // line of work; putting a 30-second-worst-case subprocess back on it is that
    // fix undone twice over.
    //
    // This drives the REAL `PmsetSleepHoldReader` and fakes one layer down, at
    // `CommandRunning`, so what is measured is the shipped reader's own
    // isolation and not a double's.
    let runner = ThreadWitnessRunner()
    let reader = PmsetSleepHoldReader(runner: runner)

    // THE PREMISE, asserted rather than assumed. Without this the check passes
    // for the wrong reason the day Swift Testing stops running `@MainActor`
    // bodies on the main thread: a caller that was never on the main actor
    // cannot demonstrate anything about leaving it.
    #expect(runningOnTheMainThread(), """
        this check is not running on the main thread, so it is not driving the \
        reader the way the Preferences window does and cannot see the block it \
        exists to catch.
        """)

    let disabled = try await reader.sleepIsDisabled()

    #expect(runner.callCount == 1,
            "the reader ran pmset \(runner.callCount) times to answer one question")
    #expect(disabled == false,
            "the reader did not return the witness's own reading, so the path measured below is not the real one")

    #expect(runner.ranOnMainThread == false, """
        the pmset subprocess was spawned and waited for ON THE MAIN THREAD. \
        `removeRegisteredHelper()` runs on the main actor, and a blocking read \
        there freezes the window for as long as the child takes, bounded at 30 \
        seconds by `CommandRunning.defaultTimeout` and not by how quick pmset \
        usually is.
        """)
}
