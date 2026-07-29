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
    func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }; acquires += 1; return true
    }

    func release() {
        lock.lock(); defer { lock.unlock() }; releases += 1
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
    ServingModel(holder: holder, reader: reader, health: fixtureHealth(),
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
