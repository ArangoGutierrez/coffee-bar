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
// removal that unregisters first and releases afterwards leaves the machine in
// exactly the state `GuardedJournalReader` documents — `SleepDisabled` set with
// no record of why — with the one thing that could put it back now removed. The
// Mac cannot sleep and nothing is left to fix it, short of a root shell.
//
// So the sequence is: release the hold, READ the flag back, and only then ask
// macOS to unregister. Every check below is stated over the order or over the
// abort, because a removal that does all three steps in the wrong order passes
// every "did it call unregister" assertion there is.
//
// NOTHING HERE REACHES macOS. Every model is handed doubles for both halves of
// the helper seam, and the one check that drives `PrivilegedHelperClient`
// itself drives the CLOSED gate — a build whose signature names no team, which
// is what the `swift test` runner is.

// MARK: - Test doubles

/// Every step of a removal, in the order it actually happened.
///
/// A shared log across three unrelated doubles, and that is the point: the
/// invariant is not "each step happened" but "they happened in this order". A
/// call counter on each double separately is green over the reversal this file
/// exists to catch.
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

/// The IOKit assertion, recording the release rather than performing one.
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

    func sleepIsDisabled() throws -> Bool {
        log.record("read SleepDisabled")
        guard let disabled else { throw UnreadableFlag.thePmsetOutputMadeNoSense }
        return disabled
    }
}

/// What a `pmset -g` that could not be interpreted looks like to the model.
private enum UnreadableFlag: Error {
    case thePmsetOutputMadeNoSense
}

/// Both halves of the helper seam in one object, which is how the shipping app
/// is wired: `PrivilegedHelperClient` reports the registration AND takes it off.
///
/// It flips itself to inactive on a successful unregister, so a model that
/// remembered the answer from `init` is visible to a check.
private final class FakeHelper: RegisteredHelperReporting, HelperUnregistering,
                                @unchecked Sendable {
    private let lock = NSLock()
    private let log: RemovalLog
    private let failing: Bool
    private var active: Bool

    init(log: RemovalLog, active: Bool, failing: Bool = false) {
        self.log = log
        self.active = active
        self.failing = failing
    }

    /// Deliberately UNLOGGED. The model is entitled to ask this as often as it
    /// likes; the order that matters is the one over the three ACTIONS.
    func registeredHelperIsActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func unregisterHelper() throws {
        log.record("unregister")
        if failing { throw UnregisterFailed.macOSDeclined }
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
@Test func theHelperIsUnregisteredOnlyAfterTheHoldIsReleasedAndTheFlagIsReadClear() {
    // THE check this feature turns on. Its mutant is the obvious mistake and it
    // is one line: unregister first, release afterwards. Every "was unregister
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

    let outcome = model.removeRegisteredHelper()

    #expect(log.recorded == ["release", "read SleepDisabled", "unregister"], """
        the removal ran its steps as \(log.recorded). The order is the safety \
        property: unregistering before the flag is confirmed clear leaves \
        SleepDisabled set with the only thing that could clear it removed.
        """)
    #expect(outcome == .removed,
            "a removal that completed every step reported \(outcome) instead of .removed")
}

@MainActor
@Test func aSleepFlagStillSetAfterTheReleaseAbortsTheRemoval() {
    // Named bug: reading the flag, ignoring the answer, and unregistering
    // anyway — a verification that is performed and not ACTED on. This is the
    // case that strands the machine, so it is stated on its own rather than
    // folded into the order check above.
    //
    // The state is real rather than contrived: the registered helper holds
    // lid-closed mode by setting `SleepDisabled`, and a user who clicks Remove
    // while a hold is in force is exactly the person this refusal is for.
    let log = RemovalLog()
    let helper = FakeHelper(log: log, active: true)
    let model = modelForRemoval(log: log, helper: helper, sleepDisabled: true)

    let outcome = model.removeRegisteredHelper()

    #expect(log.recorded == ["release", "read SleepDisabled"], """
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
@Test func aSleepFlagThatCannotBeReadAbortsTheRemovalRatherThanAssumingItIsClear() {
    // Named bug, and it is one character: `try?`. Collapsing the read's failure
    // to `nil` — or to `false` — turns "I could not find out" into "there is
    // nothing holding it", which is the exact reasoning
    // `PmsetSleepDisabledController.isEnabled()` refuses to do when `pmset`
    // prints a value it cannot interpret. An unread setting is not evidence the
    // machine is free.
    let log = RemovalLog()
    let helper = FakeHelper(log: log, active: true)
    let model = modelForRemoval(log: log, helper: helper, sleepDisabled: nil)

    let outcome = model.removeRegisteredHelper()

    #expect(log.recorded == ["release", "read SleepDisabled"], """
        the removal ran \(log.recorded) without ever learning whether the \
        machine's sleep was disabled. A read that failed is not a read that \
        answered no.
        """)
    #expect(outcome != .removed,
            "a removal that could not verify anything reported .removed")

    // A DIFFERENT sentence from the one above, because the two states need
    // different actions from the user: "end the hold" versus "something is
    // wrong with this machine's power settings". One message for both is the
    // shape this discriminates against.
    #expect(outcome.statusLine.contains("could not read"), """
        the refusal for an UNREADABLE flag reads the same as the refusal for a \
        flag that is set, so the user is told to end a hold that may not exist: \
        \(outcome.statusLine)
        """)
}

@MainActor
@Test func theHoldIsReleasedEvenWhenTheModelBelievesItIsHoldingNothing() {
    // Named bug: `if isServing { holder.release() }`. `isServing` is the app's
    // record of what IOKit last did, and a `release()` skipped on the strength
    // of it leaves a live assertion behind whenever the two disagree — which is
    // precisely the state `refresh()` documents as possible, because the
    // controller decides what SHOULD happen and IOKit is what actually
    // answered.
    //
    // The model here has never served: nothing called `refresh()`, so
    // `isServing` is its `init` value.
    let log = RemovalLog()
    let helper = FakeHelper(log: log, active: true)
    let model = modelForRemoval(log: log, helper: helper, sleepDisabled: false)

    #expect(model.isServing == false,
            "precondition: this model has never acquired an assertion")

    _ = model.removeRegisteredHelper()

    #expect(log.recorded.first == "release", """
        the removal's first act was \(log.recorded.first ?? "nothing"). The \
        release is unconditional: the app's belief about what it holds is not \
        what IOKit holds.
        """)
}

@MainActor
@Test func removalIsRefusedWhenMacOSReportsNoRegisteredHelper() {
    // The window offers the control only while a helper is registered, and this
    // is the model-side half of that: a click that arrives anyway — a stale
    // window, or a registration dropped between the render and the click — must
    // not release the user's hold to remove something that is not there.
    //
    // NOTHING is touched, which is the assertion. Releasing an assertion the
    // user is relying on, in service of a removal with no subject, is a side
    // effect they did not ask for.
    let log = RemovalLog()
    let helper = FakeHelper(log: log, active: false)
    let model = modelForRemoval(log: log, helper: helper, sleepDisabled: false)

    let outcome = model.removeRegisteredHelper()

    #expect(log.recorded == [], """
        a removal with nothing to remove still did \(log.recorded) — the \
        user's hold was released, and their machine may now sleep, to take off \
        a helper macOS says is not registered.
        """)
    #expect(outcome != .removed,
            "the model claimed it removed a helper that was never registered")
}

@MainActor
@Test func anUnregisterMacOSRefusedIsReportedRatherThanClaimedAsDone() {
    // Named bug: `try? removal.unregisterHelper()` followed by `.removed`. The
    // window would tell the user the helper is gone while the daemon is still
    // registered and still running, and the control that could try again would
    // disappear with it, because the model would also have marked the
    // registration inactive.
    let log = RemovalLog()
    let helper = FakeHelper(log: log, active: true, failing: true)
    let model = modelForRemoval(log: log, helper: helper, sleepDisabled: false)
    // The property below is written in `refresh()` alone, so it has to have run
    // once for "the model still reports a registered helper" to mean anything.
    model.refresh()
    log.reset()

    let outcome = model.removeRegisteredHelper()

    #expect(log.recorded == ["release", "read SleepDisabled", "unregister"],
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
@Test func theRemovalControlGoesAwayWithoutARelaunchOnceTheHelperIsGone() {
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

    #expect(model.removeRegisteredHelper() == .removed,
            "precondition: the removal completed")

    // NO second `refresh()`. That is the whole check.
    #expect(model.registeredHelperIsActive == false, """
        the model still reports a registered helper after removing it. The \
        window keeps offering Remove for a daemon macOS no longer runs, until \
        the next 30-second tick or a relaunch.
        """)
}

// MARK: - The gate on the client itself

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
