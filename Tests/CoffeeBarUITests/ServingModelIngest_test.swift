// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import CoffeeBarCore
import CoffeeBarIngest
import CoffeeBarPower
@testable import CoffeeBarUI

// The claim this whole product rests on: the assertion follows live agent
// sessions, with nobody touching the control. Every check below drives the
// model through the SAME seam a real hook uses — `IngestListening`'s callback —
// so a wiring defect between the listener and `PowerInputs.sessions` fails
// here rather than on the user's Mac.
//
// The doubles are named apart from the ones in `ServingModel_test.swift` on
// purpose. Both files are in one module, and one name meaning two things is
// how a reader ends up debugging the wrong class.

// MARK: - Test doubles

/// A listener that never touches a socket.
///
/// It keeps the handler it is given, so a check can post an event by hand.
private final class StubListener: IngestListening, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (HookEvent) -> Void)?
    private var started = 0
    private var stopped = 0
    private var ready = false

    func start(onEvent: @escaping @Sendable (HookEvent) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        handler = onEvent
        started += 1
        ready = true
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped += 1
        ready = false
    }

    /// Follows `UnixSocketIngestListener`: false before the first `start()`,
    /// true while serving, false again after `stop()`. A double that answered
    /// `true` for ever would let a model that CACHES the first `start()` pass
    /// the checks a live listener would fail.
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready }

    var startCount: Int { lock.lock(); defer { lock.unlock() }; return started }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stopped }

    /// Delivers on the CALLING thread. Every check here is `@MainActor`, which
    /// is the thread `UnixSocketIngestListener` delivers on — see
    /// `deliveryHappensOnTheMainThread`. A double that delivered anywhere else
    /// would let `MainActor.assumeIsolated` pass here and trap in production.
    func deliver(_ event: HookEvent) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(event)
    }
}

/// The socket is already taken. `UnixSocketIngestListener.start` throws
/// `IngestError.alreadyServing` for exactly this, and it is the most likely
/// failure the shipped app meets.
private struct ListenerRefused: Error {}

private final class RefusingListener: IngestListening, @unchecked Sendable {
    func start(onEvent: @escaping @Sendable (HookEvent) -> Void) throws {
        throw ListenerRefused()
    }
    func stop() {}
    /// Never serves, so the panel must never claim it does.
    var isReady: Bool { false }
}

/// Refuses with the REAL error the shipped app meets, rather than with a
/// stand-in.
///
/// `RefusingListener` above throws an error of its own, which is the right
/// double for "any refusal at all". This one exists because the panel's line
/// reads fields OFF the error, so a check on that wording needs the error the
/// listener actually throws.
private final class AlreadyServingListener: IngestListening, @unchecked Sendable {
    static let takenPath = "/Users/example/Library/Application Support/coffee-bar/ingest.sock"

    func start(onEvent: @escaping @Sendable (HookEvent) -> Void) throws {
        throw IngestError.alreadyServing(Self.takenPath)
    }
    func stop() {}
    var isReady: Bool { false }
}

/// Refuses the first `start()` and serves the second.
///
/// `ServingModel.listenerStarted` is set only on success, deliberately, so a
/// refused socket can be retried. This double is the only way to walk that path.
private final class FlakyListener: IngestListening, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    private var ready = false

    func start(onEvent: @escaping @Sendable (HookEvent) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        attempts += 1
        if attempts == 1 { throw IngestError.alreadyServing(AlreadyServingListener.takenPath) }
        ready = true
    }

    func stop() { lock.lock(); defer { lock.unlock() }; ready = false }
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready }
}

/// The power reader these checks drive. Mutable, so the battery can move.
private final class StubReader: PowerReadingProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var next: PowerReading

    init(source: PowerSource = .ac, percent: Int? = 80) {
        next = PowerReading(source: source, percent: percent)
    }

    func set(source: PowerSource, percent: Int?) {
        lock.lock(); defer { lock.unlock() }
        next = PowerReading(source: source, percent: percent)
    }

    func read() -> PowerReading {
        lock.lock(); defer { lock.unlock() }
        return next
    }
}

/// Counts what the model asked IOKit to do, without asking IOKit to do it.
private final class CountingHolder: AssertionHolding, @unchecked Sendable {
    private let lock = NSLock()
    private var acquires = 0
    private var releases = 0

    var acquireCount: Int { lock.lock(); defer { lock.unlock() }; return acquires }
    var releaseCount: Int { lock.lock(); defer { lock.unlock() }; return releases }

    @discardableResult
    func acquire(displaySleep: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }; acquires += 1; return true
    }

    func release() {
        lock.lock(); defer { lock.unlock() }; releases += 1
    }
}

/// A settings store held in memory.
///
/// The model here is built by `makeModel`, which hands one in. The shipping
/// default reads `UserDefaults.standard` — the preferences of whoever runs the
/// suite — and every check in this file is about ingest, not about settings.
private final class FakeSettings: SettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    func bool(forKey key: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }; return values[key] as? Bool
    }

    func setBool(_ value: Bool, forKey key: String) {
        lock.lock(); defer { lock.unlock() }; values[key] = value
    }

    func integer(forKey key: String) -> Int? {
        lock.lock(); defer { lock.unlock() }; return values[key] as? Int
    }

    func setInteger(_ value: Int, forKey key: String) {
        lock.lock(); defer { lock.unlock() }; values[key] = value
    }
}

private let t0 = Date(timeIntervalSince1970: 1_000_000)

/// A clock the check moves by hand, so the stale timeout is exercised without
/// waiting for it.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = t0

    var now: Date { lock.lock(); defer { lock.unlock() }; return value }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        value = value.addingTimeInterval(seconds)
    }
}

/// A hook-health reader pointed at a committed fixture.
///
/// EVERY model built here is handed one, for the reason `ServingModel_test`
/// gives: the shipping default reads the developer's own
/// `~/.claude/settings.json`.
private func fixtureHealth() -> HookHealthReader {
    HookHealthReader(settingsURL: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()    // …/Tests/CoffeeBarUITests
        .deletingLastPathComponent()    // …/Tests
        .appending(path: "Fixtures/claude-settings/wired.json"))
}

@MainActor
private func makeModel(listener: any IngestListening,
                       reader: StubReader = StubReader(),
                       holder: CountingHolder = CountingHolder(),
                       clock: TestClock = TestClock(),
                       policy: StalePolicy = .standard) -> ServingModel {
    ServingModel(holder: holder, reader: reader, health: fixtureHealth(), settings: FakeSettings(),
                 listener: listener, policy: policy, now: { clock.now })
}

// MARK: - An agent holds the machine awake with no toggle

@MainActor
@Test func aWorkingSessionHoldsTheAssertionWithNoUserToggle() throws {
    // The claim the whole product rests on, and the one the M1 build could not
    // make. Named bug this catches: a `refresh()` that never hands `sessions`
    // to `evaluate`. The app then behaves exactly like M1 — a manual toggle —
    // while every ingest check in `CoffeeBarIngestTests` stays green, because
    // those checks stop at the listener's callback.
    //
    // Nothing here moves the control. `intent` stays at its `.auto` default.
    let listener = StubListener()
    let holder = CountingHolder()
    let model = makeModel(listener: listener, holder: holder)

    try model.startMonitoring(interval: 3600)
    // Precondition: an idle machine holds nothing, so the acquire below is
    // caused by the event and not by a model that acquires unconditionally.
    #expect(model.isServing == false)
    #expect(holder.acquireCount == 0)

    listener.deliver(HookEvent(hookEventName: "PreToolUse", sessionID: "s1",
                               cwd: "/Users/example/src/coffee-bar",
                               toolName: "Bash"))

    #expect(model.isServing == true, "a working agent session did not hold the assertion")
    #expect(holder.acquireCount == 1)
    #expect(model.intent == .auto, "ingest moved the user's control")
}

@MainActor
@Test func aStopReleasesTheAssertionAndTheMachineSleeps() throws {
    // Design §3.1: on `Stop` the human is the bottleneck, so the assertion
    // drops rather than burning battery while nobody types.
    let listener = StubListener()
    let holder = CountingHolder()
    let model = makeModel(listener: listener, holder: holder)
    try model.startMonitoring(interval: 3600)

    listener.deliver(HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))
    #expect(model.isServing == true)

    listener.deliver(HookEvent(hookEventName: "Stop", sessionID: "s1"))

    #expect(model.isServing == false, "an agent waiting on the human still held the machine awake")
    #expect(holder.releaseCount >= 1)
}

@MainActor
@Test func twoEventsForOneSessionDoNotMakeTwoSessions() throws {
    // Named bug this catches: `ingest` appending to `sessions` instead of
    // handing the array back to `SessionHub.apply`. The count grows with every
    // event, so a single `Stop` leaves an older `.working` copy holding the
    // machine awake forever.
    let listener = StubListener()
    let model = makeModel(listener: listener)
    try model.startMonitoring(interval: 3600)

    listener.deliver(HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))
    listener.deliver(HookEvent(hookEventName: "PostToolUse", sessionID: "s1"))
    #expect(model.sessions.count == 1)

    listener.deliver(HookEvent(hookEventName: "Stop", sessionID: "s1"))
    #expect(model.sessions.count == 1)
    #expect(model.sessions.first?.state == .awaitingInput)
    #expect(model.isServing == false)
}

@MainActor
@Test func twoSessionsBothHaveToFinishBeforeTheHoldDrops() throws {
    // Named bug this catches: keying the session list on anything but the
    // session id, so a second agent overwrites the first. The user closes one
    // terminal and the Mac sleeps under the other one.
    let listener = StubListener()
    let model = makeModel(listener: listener)
    try model.startMonitoring(interval: 3600)

    listener.deliver(HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))
    listener.deliver(HookEvent(hookEventName: "PreToolUse", sessionID: "s2"))
    #expect(model.sessions.count == 2)

    listener.deliver(HookEvent(hookEventName: "Stop", sessionID: "s1"))
    #expect(model.isServing == true, "one agent finishing dropped the hold under the other one")

    listener.deliver(HookEvent(hookEventName: "Stop", sessionID: "s2"))
    #expect(model.isServing == false)
}

// MARK: - The user's control still outranks ingest

@MainActor
@Test func anExplicitStopVetoesALiveSession() throws {
    // `PowerBroker` makes the off switch ABSOLUTE, and this is that rule seen
    // from the app layer. Named bug this catches: `ingest` reconciling from a
    // stale copy of the intent, so the next hook event re-arms a hold the user
    // has just switched off. coffee-bar overrides the machine's own sleep
    // policy, so an app that ignores "off" is a trust failure, not a bug.
    let listener = StubListener()
    let model = makeModel(listener: listener)
    try model.startMonitoring(interval: 3600)

    listener.deliver(HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))
    #expect(model.isServing == true)

    model.intent = .stop
    #expect(model.isServing == false)

    // The agent keeps working. The veto has to survive it.
    listener.deliver(HookEvent(hookEventName: "PostToolUse", sessionID: "s1"))
    #expect(model.isServing == false, "a hook event re-armed a hold the user had switched off")
    #expect(model.sessions.first?.state == .working,
            "the veto stopped the model tracking the session at all")
}

@MainActor
@Test func theLatchDoesNotFireUnderAutoInTheAppLayer() throws {
    // The app-layer mirror of `HoldController_test.theLatchDoesNotFireUnderAuto`.
    // That check reaches the controller directly; `ServingModel.refresh()`
    // passed NO sessions until this task, so under `.auto` the controller could
    // never hold from here and the narrowed latch was unexercised above the
    // core.
    //
    // Named bug this catches: the M1 `intent = .stop` on ANY suppression. One
    // dip below the floor pins the intent to `.stop` for the life of the
    // process, every later agent session is ignored, and
    // `reason(_:stillTrueOf:)` drops the battery line as soon as the reading
    // recovers — so the panel shows a dead app and no reason for it. The only
    // cure is to quit and relaunch.
    let listener = StubListener()
    let reader = StubReader(source: .battery, percent: 21)
    let holder = CountingHolder()
    let model = makeModel(listener: listener, reader: reader, holder: holder)
    try model.startMonitoring(interval: 3600)

    listener.deliver(HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))
    // Precondition: `.auto` is genuinely holding, so the drop below is a
    // release and not a hold that never started.
    #expect(model.isServing == true)
    #expect(holder.acquireCount == 1)

    reader.set(source: .battery, percent: 20)
    model.refresh()
    #expect(model.isServing == false)
    #expect(model.suppression == .batteryFloor(percent: 20, floor: 20))

    reader.set(source: .battery, percent: 21)
    model.refresh()

    #expect(model.intent == .auto, "a floor suppression latched the intent away from .auto")
    #expect(model.isServing == true,
            "the hold did not come back under .auto once the battery recovered")
    #expect(holder.acquireCount == 2)
    #expect(model.suppression == nil, "the panel still explains a refusal that has stopped")
}

@MainActor
@Test func aRefusedOnClickDoesNotVetoTheAgentSessionsThatFollow() throws {
    // Audit finding I4, as the five steps it reports, at the layer the user
    // touches. `HoldController_test` reaches the controller directly; this drives
    // the SAME two seams a real user and a real hook use — the control setter and
    // the listener callback.
    //
    // Named bug this catches: `intent = .stop` on a refused `.serve`. The Mac
    // then sleeps under a working agent, which is the single failure this product
    // exists to prevent, and the cause is a click that ASKED for more holding.
    let listener = StubListener()
    let reader = StubReader(source: .battery, percent: 15)
    let holder = CountingHolder()
    let model = makeModel(listener: listener, reader: reader, holder: holder)
    try model.startMonitoring(interval: 3600)

    // 1. The shipping default, untouched.
    #expect(model.intent == .auto)

    // 2. An agent works while the battery sits under the floor. Precondition:
    //    nothing is held yet, so the hold at the end comes from the recovery.
    listener.deliver(HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))
    #expect(model.isServing == false)
    #expect(model.workingSummary == "1 session working")
    #expect(holder.acquireCount == 0)

    // 3. The user clicks On. The floor refuses the hold and says why.
    model.intent = .serve
    #expect(model.isServing == false)
    #expect(model.suppression == .batteryFloor(percent: 15, floor: 20))
    #expect(model.intent == .auto,
            "a refused click left the control on a position the user never picked")

    // 4-5. The battery recovers to 100% on AC, with the agent still working.
    reader.set(source: .ac, percent: 100)
    model.refresh()

    #expect(model.isServing == true,
            "the Mac sleeps under a working agent because one refused click vetoed .auto")
    #expect(holder.acquireCount == 1)
    #expect(model.suppression == nil,
            "the panel still explains a refusal that has stopped happening")
}

@MainActor
@Test func theBatteryLineLeftOnScreenIsTrueOfWhatHappensNext() throws {
    // The minor finding at `ServingModel.reason(_:stillTrueOf:)`. The filter
    // compares the latched reason against the newest READING only. It never asks
    // whether anything is currently requesting a hold, so with no sessions at all
    // the panel still names the battery.
    //
    // The observation is correct, and the line is still honest — but only once
    // the control is back on `.auto`. The floor is then the binding constraint on
    // whatever happens next, so the sentence on screen predicts the next event
    // exactly, and lifting the floor is enough to make the hold arrive.
    //
    // Named bug this catches: leaving the control on `.stop` after the refusal.
    // The battery is then NOT the operative reason — an absolute veto is — so the
    // agent below is refused for a reason the panel never shows, and going back
    // on AC power changes nothing.
    let listener = StubListener()
    let reader = StubReader(source: .battery, percent: 15)
    let model = makeModel(listener: listener, reader: reader)
    try model.startMonitoring(interval: 3600)

    // No sessions at all: nothing is asking for a hold. The user clicks On and
    // the floor refuses.
    model.intent = .serve
    #expect(model.sessions.isEmpty)
    #expect(model.suppression == .batteryFloor(percent: 15, floor: 20))

    // The claim that line makes, put to the next thing that happens.
    listener.deliver(HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))
    #expect(model.isServing == false)
    #expect(model.suppression == .batteryFloor(percent: 15, floor: 20))

    // And the floor is the ONLY thing refusing. Lift it and the hold arrives
    // with no further action from the user.
    reader.set(source: .ac, percent: 100)
    model.refresh()
    #expect(model.isServing == true,
            "the panel named the battery while something else was refusing the hold")
    #expect(model.suppression == nil)
}

// MARK: - The stale timeout runs on the existing ticker

@MainActor
@Test func aSilentSessionStopsHoldingWhenTheTimerFires() throws {
    // Design §5 makes the timeout a SAFETY property and requires it on a TIMER.
    // Named bug this catches: expiry applied inside `ingest` only. A crashed
    // agent sends no further event, so an expiry that runs only on the next
    // event never runs at all, and the Mac stays awake until the user reboots.
    //
    // Nothing here delivers a second event. The only route from the clock to
    // the holder is `refresh()`.
    let listener = StubListener()
    let holder = CountingHolder()
    let clock = TestClock()
    let model = makeModel(listener: listener, holder: holder, clock: clock,
                          policy: StalePolicy(workingTimeout: 100, blockedTimeout: 1000))
    try model.startMonitoring(interval: 3600)

    listener.deliver(HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))
    #expect(model.isServing == true)

    // One second short of the timeout: the session is still live, so the drop
    // below is caused by the timeout and not by a model that retires anything
    // on the first tick.
    clock.advance(99)
    model.refresh()
    #expect(model.isServing == true, "a session went stale before its timeout")

    clock.advance(1)
    model.refresh()

    #expect(model.isServing == false, "a dead agent held the machine awake")
    #expect(model.sessions.first?.state == .stale)
    #expect(holder.releaseCount >= 1)
}

// MARK: - What the panel is told about those sessions

// `AttentionList` is checked directly in `CoffeeBarCoreTests`. These checks are
// about the WIRING: that the model publishes what that rule computes, off the
// same `sessions` array it hands the broker. A published value nothing feeds is
// the failure `thePanelReadsTheHookAdvisoryTheModelPublishes` exists to catch,
// and it has already shipped here once.
//
// Asserted on the model's published values, never on rendered AppKit text. M1
// design §5.4 rules the second one out.

@MainActor
@Test func aBlockedSessionAppearsInTheAttentionList() throws {
    // The list answers "what is waiting on me". Named bug this catches: a model
    // that tracks sessions for the broker and publishes nothing for the panel,
    // so a permission prompt the user has to answer is invisible until they go
    // hunting through terminal windows for it.
    let listener = StubListener()
    let model = makeModel(listener: listener)
    try model.startMonitoring(interval: 3600)

    #expect(model.attention.isEmpty)

    listener.deliver(HookEvent(hookEventName: "PermissionDenied", sessionID: "s1",
                               cwd: "/Users/example/src/coffee-bar",
                               reason: "Bash needs approval"))

    #expect(model.attention.map(\.sessionID) == ["s1"])
    #expect(model.attention.first?.state == .awaitingPermission)
    #expect(model.attention.first?.repoName == "coffee-bar")
    #expect(model.attention.first?.lastMessage == "Bash needs approval")
}

@MainActor
@Test func aWorkingSessionIsNotWaitingOnTheUser() throws {
    // Named bug this catches: publishing `sessions` straight through as the
    // attention list. Every busy agent then shows up under "waiting on you" and
    // the list stops meaning anything.
    let listener = StubListener()
    let model = makeModel(listener: listener)
    try model.startMonitoring(interval: 3600)

    listener.deliver(HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))

    #expect(model.sessions.count == 1, "the model stopped tracking the session at all")
    #expect(model.attention.isEmpty, "a working agent was listed as waiting on the user")
}

@MainActor
@Test func theAttentionListPutsTheLongestWaitFirst() throws {
    // Named bug this catches: `attention = sessions.filter { … }` in the model,
    // which produces the right SET in ingest order. The user then reads a list
    // whose top entry is whichever agent blocked most recently, and the one
    // that has been waiting longest scrolls off the bottom.
    //
    // The fixture blocks the sessions in the OPPOSITE order to the one they
    // arrived in, and that is what makes it discriminate. `SessionHub.apply`
    // appends, so a session that arrives blocked and stays blocked sits in
    // ingest order AND in wait order at once — measured: with both sessions
    // delivered blocked, the unordered filter above passed this check.
    let listener = StubListener()
    let clock = TestClock()
    let model = makeModel(listener: listener, clock: clock)
    try model.startMonitoring(interval: 3600)

    // Arrives FIRST, and it is working, so it is not waiting on anybody yet.
    listener.deliver(HookEvent(hookEventName: "PreToolUse", sessionID: "arrived-first"))
    // Arrives SECOND and blocks immediately, so it is the longest wait.
    listener.deliver(HookEvent(hookEventName: "Stop", sessionID: "blocked-first"))

    clock.advance(60)
    listener.deliver(HookEvent(hookEventName: "Stop", sessionID: "arrived-first"))

    #expect(model.sessions.map(\.sessionID) == ["arrived-first", "blocked-first"],
            "the fixture no longer holds the two orders apart, so it proves nothing")
    #expect(model.attention.map(\.sessionID) == ["blocked-first", "arrived-first"])
}

@MainActor
@Test func aWorkingSessionIsVisibleAsACount() throws {
    // Design §14, and PE finding I4 that it resolves. Named bug this catches,
    // and it is the one the design rejected the original plan over: the panel
    // shows the blocked states only, so the session ACTUALLY holding the machine
    // awake appears NOWHERE — in a product whose entire pitch is that you can
    // see what is keeping your Mac awake.
    let listener = StubListener()
    let model = makeModel(listener: listener)
    try model.startMonitoring(interval: 3600)

    // Precondition: an idle machine names nothing, so the line below is caused
    // by the event and not printed unconditionally.
    #expect(model.workingSummary == nil)

    listener.deliver(HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))

    #expect(model.isServing == true)
    #expect(model.workingSummary == "1 session working")
}

@MainActor
@Test func theWorkingCountIsPluralisedAndCounts() throws {
    // Named bug this catches: "2 session working", and a count hard-coded to 1.
    // The line is built in the model rather than in the view because M1 design
    // §5.4 forbids asserting on rendered AppKit text — a sentence composed in
    // `PanelView` would be a sentence no check reads.
    let listener = StubListener()
    let model = makeModel(listener: listener)
    try model.startMonitoring(interval: 3600)

    listener.deliver(HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))
    listener.deliver(HookEvent(hookEventName: "PreToolUse", sessionID: "s2"))

    #expect(model.workingSummary == "2 sessions working")
}

@MainActor
@Test func aBlockedSessionIsNotCountedAsWorkingInThePanel() throws {
    // Named bug this catches: counting every tracked session. "1 session
    // working" printed beside "Not holding any assertion" tells the user the
    // app is broken at the exact moment it is doing the right thing — an agent
    // blocked on a person does not hold the machine awake.
    let listener = StubListener()
    let model = makeModel(listener: listener)
    try model.startMonitoring(interval: 3600)

    listener.deliver(HookEvent(hookEventName: "Stop", sessionID: "s1"))

    #expect(model.attention.map(\.sessionID) == ["s1"])
    #expect(model.isServing == false)
    #expect(model.workingSummary == nil, "a session blocked on the user was counted as working")
}

@MainActor
@Test func aStaleSessionIsNeitherWaitingNorWorking() throws {
    // The stale timeout is a SAFETY property (design §5), and the panel has to
    // follow it. Named bug this catches: an `attention` or a count computed once
    // in `ingest` and never recomputed in `refresh()`. A crashed agent sends no
    // further event, so its row would sit under "waiting on you" for the life of
    // the process, telling the user to go answer a dead terminal.
    let listener = StubListener()
    let clock = TestClock()
    let model = makeModel(listener: listener, clock: clock,
                          policy: StalePolicy(workingTimeout: 100, blockedTimeout: 200))
    try model.startMonitoring(interval: 3600)

    listener.deliver(HookEvent(hookEventName: "PreToolUse", sessionID: "busy"))
    listener.deliver(HookEvent(hookEventName: "Stop", sessionID: "blocked"))
    #expect(model.workingSummary == "1 session working")
    #expect(model.attention.map(\.sessionID) == ["blocked"])

    // Only the clock moves. The one route from here to the panel is `refresh()`.
    clock.advance(200)
    model.refresh()

    #expect(model.sessions.allSatisfy { $0.state == .stale },
            "the fixture did not go stale, so the expectations below prove nothing")
    #expect(model.workingSummary == nil, "a dead agent was still counted as working")
    #expect(model.attention.isEmpty, "a dead agent was still listed as waiting on the user")
}

// MARK: - The listener's lifecycle

@MainActor
@Test func startMonitoringStartsTheListenerExactlyOnce() throws {
    // Named bug this catches: `startMonitoring` starting the listener on every
    // call. The second `start()` throws `alreadyServing` — the real listener
    // refuses a path it already answers on — so a repeat call would leave the
    // app with no ingest and an error nobody sees.
    let listener = StubListener()
    let model = makeModel(listener: listener)

    try model.startMonitoring(interval: 3600)
    #expect(listener.startCount == 1)

    try model.startMonitoring(interval: 3600)
    #expect(listener.startCount == 1, "a repeat startMonitoring started the listener again")

    // Events still reach the model after the repeat call.
    listener.deliver(HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))
    #expect(model.isServing == true)

    model.timer?.invalidate()
}

@MainActor
@Test func aListenerThatCannotStartStillLeavesTheFloorEnforced() {
    // Named bug this catches: `startMonitoring` starting the listener BEFORE
    // installing the timer. The socket is the likeliest thing to fail — a
    // second instance already owns it — and an app that then enforces no
    // battery floor at all is a worse failure than an app with no ingest.
    //
    // `main.swift` catches this error and launches anyway, so the timer has to
    // survive it.
    let model = makeModel(listener: RefusingListener())

    #expect(throws: ListenerRefused.self) {
        try model.startMonitoring(interval: 3600)
    }
    #expect(model.timer?.isValid == true,
            "a refused socket left the app with no ticker and no battery floor")

    model.timer?.invalidate()
}

// MARK: - Is this process actually serving?

// Two DIFFERENT questions, and the panel must never merge them:
//
//   `hookHealth`      — are the hooks installed? A read of a settings FILE.
//                       It cannot see this process at all.
//   `ingestListening` — is this process serving? A read of the LISTENER.
//                       It cannot see the user's settings at all.
//
// PE finding B2 is why. A second app instance stealing the socket path kills
// ingest and leaves the settings file exactly as it was, so `hookHealth` stays
// `.wired` while nothing can arrive. Before this, `startMonitoring` threw and
// `main.swift` wrote the error to NSLog, where no user looks.

@MainActor
@Test func aListenerThatIsNotServingIsSaidSoInThePanel() {
    // Named bug this catches: a refused socket that is invisible. The app
    // launches, the panel looks healthy, `.auto` never holds because no session
    // ever arrives, and the only record is a line in the system log.
    let model = makeModel(listener: RefusingListener())

    #expect(throws: ListenerRefused.self) {
        try model.startMonitoring(interval: 3600)
    }
    model.refresh()

    #expect(model.ingestListening == false)
    #expect(model.ingestAdvisory != nil, "a refused socket reached the user nowhere")

    model.timer?.invalidate()
}

@MainActor
@Test func aServingListenerSaysNothingAboutItself() throws {
    // A panel that announces its own health every time it opens is noise the
    // user learns to skip past, and the line beside it would then be skipped
    // too. Nothing to report means nothing on screen.
    let listener = StubListener()
    let model = makeModel(listener: listener)

    try model.startMonitoring(interval: 3600)
    model.refresh()

    #expect(model.ingestListening == true)
    #expect(model.ingestAdvisory == nil)

    model.timer?.invalidate()
}

@MainActor
@Test func aListenerThatStopsServingIsNoticedOnTheNextRefresh() throws {
    // Named bug this catches, and it is the whole reason this reads the
    // listener rather than remembering the one `start()` call: a `start()` that
    // returns without throwing has created an `NWListener`, not proved a bind.
    // The bind lands asynchronously and can still fail. A model that cached
    // "started successfully" would claim to be serving for the life of the
    // process, which is the same false claim in a new place.
    let listener = StubListener()
    let model = makeModel(listener: listener)

    try model.startMonitoring(interval: 3600)
    model.refresh()
    // Precondition: it really was serving, so the flip below is a change and
    // not a value that was false all along.
    #expect(model.ingestListening == true)

    listener.stop()
    model.refresh()

    #expect(model.ingestListening == false,
            "the model kept claiming to serve after the listener stopped")
    #expect(model.ingestAdvisory != nil)

    model.timer?.invalidate()
}

@MainActor
@Test func theListenerClaimIsSeparateFromTheHookHealthClaim() {
    // PE finding B2, held as a check. Named bug this catches: one merged
    // "ingest is fine" claim. `HookHealthReader` reads
    // `~/.claude/settings.json` and NOTHING else — it cannot see this process,
    // so a wired settings file would hide a dead socket, and the panel would
    // tell the user everything is fine while no event could possibly arrive.
    //
    // The fixture is `wired.json`, so the hook half is deliberately healthy and
    // silent. The listener half must still speak.
    let model = makeModel(listener: RefusingListener())

    #expect(throws: ListenerRefused.self) {
        try model.startMonitoring(interval: 3600)
    }
    model.refresh()

    #expect(model.hookHealth == .wired)
    #expect(model.hookAdvisory == nil, "the fixture is not the healthy one, so this proves nothing")
    #expect(model.ingestAdvisory != nil,
            "a wired settings file silenced the report that this process is not serving")

    model.timer?.invalidate()
}

@MainActor
@Test func aStolenSocketNamesThePathAndTheFix() {
    // `IngestError.alreadyServing` is the failure design §4 says is likeliest:
    // a second copy of coffee-bar already answers on the path. Named bug this
    // catches: a generic "ingest is not working" that leaves the user with no
    // idea what to do next. The panel names the path and names the fix.
    let model = makeModel(listener: AlreadyServingListener())

    #expect(throws: IngestError.self) {
        try model.startMonitoring(interval: 3600)
    }
    model.refresh()

    let advisory = model.ingestAdvisory ?? ""
    #expect(advisory.contains(AlreadyServingListener.takenPath),
            "the advisory does not name the path: \(advisory)")
    #expect(advisory.contains("Quit"),
            "the advisory does not name the fix: \(advisory)")

    model.timer?.invalidate()
}

@MainActor
@Test func aRetryThatWorksStopsExplainingTheOldRefusal() throws {
    // The same discipline `reason(_:stillTrueOf:)` applies to the battery line:
    // the panel explains a condition that is still true, or it says nothing.
    //
    // Named bug this catches: a refusal recorded once and never cleared. The
    // socket is retried, binds, and the panel is quiet — so the stale text is
    // invisible until the listener stops later, at which point the user is told
    // to go quit a copy of coffee-bar that stopped being the problem long ago.
    //
    // This check was written after the implementation, driven by an unkilled
    // mutant: deleting the line that clears the refusal left every other check
    // in this file green.
    let listener = FlakyListener()
    let model = makeModel(listener: listener)

    #expect(throws: IngestError.self) {
        try model.startMonitoring(interval: 3600)
    }
    model.refresh()
    #expect(model.ingestAdvisory?.contains(AlreadyServingListener.takenPath) == true,
            "the first refusal was never explained, so the clearing below proves nothing")

    // `listenerStarted` is set only on success, so the socket really is retried.
    try model.startMonitoring(interval: 3600)
    model.refresh()
    #expect(model.ingestListening == true)
    #expect(model.ingestAdvisory == nil)

    // Gone, not merely hidden behind a healthy socket. Stopping the listener is
    // what makes the difference visible.
    listener.stop()
    model.refresh()

    let advisory = try #require(model.ingestAdvisory)
    #expect(!advisory.contains(AlreadyServingListener.takenPath),
            "the panel still explains a refusal that has stopped: \(advisory)")

    model.timer?.invalidate()
}

@MainActor
@Test func aModelThatGoesAwayLeavesTheListenerAlone() throws {
    // PE finding B2, held as a check rather than as a comment. One extra `App`
    // build makes one orphaned `ServingModel`, and an orphan that stops the
    // listener from a `deinit` took down the LIVE instance's ingest while the
    // panel still reported the hooks wired.
    //
    // The model goes away inside the `do` block. Named bug this catches:
    // `deinit { listener.stop() }` — the shape the plan originally carried, and
    // the shape that needs the experimental `isolated deinit` to compile at
    // all. `stop()` no longer unlinks the node, so today's damage is bounded,
    // but nothing here should depend on a fix in another module.
    let listener = StubListener()
    var captured: Timer?
    do {
        let model = makeModel(listener: listener)
        try model.startMonitoring(interval: 3600)
        captured = model.timer
        // Preconditions: the model really did wire itself to this listener, so
        // the assertion below is about a model that had something to stop.
        #expect(listener.startCount == 1)
        listener.deliver(HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))
        #expect(model.isServing == true)
    }

    #expect(listener.stopCount == 0,
            "a discarded ServingModel stopped a listener whose lifetime it does not own")

    captured?.invalidate()
}
