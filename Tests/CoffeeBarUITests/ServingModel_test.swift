// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import CoffeeBarCore
import CoffeeBarIngest
import CoffeeBarPower
@testable import CoffeeBarUI

// MARK: - Test doubles

/// Starts nothing.
///
/// The three checks below that call `startMonitoring` are handed one. The
/// SHIPPING default is the real listener, deliberately — see `ServingModel` —
/// so without this the suite would bind
/// `~/Library/Application Support/coffee-bar/ingest.sock`, and a `swift test`
/// run alongside a live coffee-bar would be refused by it.
///
/// `ServingModelIngest_test.swift` holds the checks about ingest itself. This
/// one exists only to keep the socket out of the tests that are about the
/// ticker.
private final class NoopIngestListener: IngestListening, @unchecked Sendable {
    func start(onEvent: @escaping @Sendable (AgentTool, HookEvent) -> Void) throws {}
    func stop() {}
    /// It binds nothing, so it serves nothing. The checks in this file are
    /// about the ticker and read nothing off this; the honest answer is still
    /// `false`, so a model that read it would not be told a comfortable lie.
    var isReady: Bool { false }
}

/// The power reader the tests drive.
///
/// `PowerReadingProviding` is `Sendable`, so the mutable reading is guarded by
/// a lock — the same single discipline `AssertionHolder` uses, rather than an
/// unchecked global.
private final class FakeReader: PowerReadingProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var next: PowerReading

    init(source: PowerSource, percent: Int?) {
        next = PowerReading(source: source, percent: percent)
    }

    func set(source: PowerSource, percent: Int?) {
        lock.lock()
        defer { lock.unlock() }
        next = PowerReading(source: source, percent: percent)
    }

    func read() -> PowerReading {
        lock.lock()
        defer { lock.unlock() }
        return next
    }
}

/// Counts what the model asked IOKit to do, without asking IOKit to do it.
///
/// `acquire()` returns `true` so `isServing` follows the model's own logic
/// rather than a refusal injected here.
private final class SpyHolder: AssertionHolding, @unchecked Sendable {
    private let lock = NSLock()
    private var acquires = 0
    private var releases = 0
    private var displayFlags: [Bool] = []

    var acquireCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return acquires
    }

    var releaseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return releases
    }

    /// The `displaySleep` argument of every `acquire`, in order.
    ///
    /// The whole SEQUENCE and not the last value. A model that asked for the
    /// display hold once and dropped it on the next tick would look identical
    /// to one that never asked, read through a single flag.
    var displaySleepRequests: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return displayFlags
    }

    @discardableResult
    func acquire(displaySleep: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        acquires += 1
        displayFlags.append(displaySleep)
        return true
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        releases += 1
    }
}

/// An assertion holder that always refuses.
///
/// `AssertionHolder.acquire(displaySleep:)` returns `false` when IOKit refuses
/// the assertion, and `ServingModel` then leaves `isServing` false. Without a
/// double for that, every check here runs against a holder that never fails,
/// and the panel's claims about a hold go untested on the path where no hold
/// exists.
private final class FailingHolder: AssertionHolding, @unchecked Sendable {
    @discardableResult
    func acquire(displaySleep: Bool) -> Bool { false }
    func release() {}
}

/// A settings store held in memory.
///
/// EVERY `ServingModel` built in this file is handed one. The shipping default
/// is `UserDefaultsSettingsStore()` over `.standard` — the preferences of
/// whoever runs the suite — so a check that took the default would read that
/// person's own setting and would edit it on the way past.
private final class FakeSettings: SettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init(_ initial: [String: Any] = [:]) { values = initial }

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

    // `as?` and not a force cast, for the reason `UserDefaultsSettingsStore`
    // gives: this store answers `nil` both for a key nobody wrote and for one
    // holding something that is not a list of strings.
    func stringArray(forKey key: String) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        return values[key] as? [String]
    }

    func setStringArray(_ value: [String], forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }
}

/// A hook-health reader pointed at a committed fixture.
///
/// EVERY `ServingModel` built in this file is handed one. `refresh()` reads the
/// settings file, and the shipping default is the user's real
/// `~/.claude/settings.json` — so a test that took the default would read the
/// machine's own configuration and report a different `hookHealth` on every
/// developer's laptop.
private func fixtureHealth(_ name: String = "wired.json") -> HookHealthReader {
    HookHealthReader(settingsURL: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()    // …/Tests/CoffeeBarUITests
        .deletingLastPathComponent()    // …/Tests
        .appending(path: "Fixtures/claude-settings/\(name)"))
}

// MARK: - The control carries the intent, not the hold state

@MainActor
@Test func theModelReportsTheIntentAndNotTheHoldState() {
    // Named bug this catches: the M1 `serving: Bool`, whose getter returned
    // `isServing` — the ACTUAL hold state rather than what the user asked for.
    // A control bound to that moves by itself as sessions come and go, and the
    // click that moves it back writes an intent the user never chose.
    //
    // The two expectations below are the discriminating pair: `.auto` and
    // `.stop` are DIFFERENT intents that produce the SAME `isServing` here, so
    // no getter derived from `isServing` can satisfy both.
    let reader = FakeReader(source: .ac, percent: 80)
    let model = ServingModel(holder: SpyHolder(), reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    // The shipped default, before the user has touched anything. `.auto` holds
    // nothing while no session is running — M2 ingest is what will feed them —
    // so the hold state here is false while the intent is not `.stop`.
    #expect(model.intent == .auto)
    #expect(model.isServing == false)

    model.intent = .stop
    #expect(model.intent == .stop)
    #expect(model.isServing == false)
}

@MainActor
@Test func everyControlPositionStaysReachable() {
    // PE's finding on the M1 toggle: its setter wrote
    // `newValue ? .serve : .stop`, so the enum's third position was
    // unreachable from the UI. After one click `.auto` could never be selected
    // again — the state the product SHIPS in became one the user could leave
    // and never return to.
    //
    // The order matters: `.auto` is asserted LAST, after both explicit
    // positions have been used, because that is the sequence the Bool could
    // not express.
    let reader = FakeReader(source: .ac, percent: 80)
    let model = ServingModel(holder: SpyHolder(), reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
    #expect(model.intent == .serve)

    model.intent = .stop
    #expect(model.intent == .stop)

    model.intent = .auto
    #expect(model.intent == .auto)
}

@MainActor
@Test func theIntentSetterReachesTheControllerAndReconciles() {
    // Two claims about the setter, each with its own mutant.
    //
    // Named bug 1: a setter that stores the value on the MODEL instead of
    // forwarding it to `HoldController`. The controller then decides against a
    // stale intent forever. The latch proves the forwarding: a `.serve` that
    // the floor refuses drops the CONTROLLER's intent back to the standing
    // position — `.auto` here — so a model holding its own copy still reports
    // `.serve` at the end.
    //
    // Named bug 2: a setter that forwards but never calls `refresh()`. The
    // control moves, IOKit is never told, and nothing happens until the
    // 30-second ticker catches up — up to half a minute of a panel that
    // disagrees with the machine.
    let reader = FakeReader(source: .ac, percent: 80)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    // Precondition: nothing acquired before the set, so the count below cannot
    // come from anywhere else.
    #expect(spy.acquireCount == 0)

    // Bug 2: the acquire has to happen on the SET. Nothing here calls refresh().
    model.intent = .serve
    #expect(spy.acquireCount == 1, "setting the intent did not reconcile the assertion")
    #expect(model.isServing == true)

    // Bug 1: the controller latches the intent away under the model.
    reader.set(source: .battery, percent: 14)
    model.refresh()
    #expect(model.isServing == false)
    #expect(model.intent == .auto,
            "the model reported its own copy of the intent, not the controller's")
}

// MARK: - The control reaches the assertion

@MainActor
@Test func togglingServingOnAcquiresTheAssertion() {
    let reader = FakeReader(source: .ac, percent: 80)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    // Precondition: nothing is held before the user asks for anything.
    #expect(model.isServing == false)
    #expect(spy.acquireCount == 0)

    model.intent = .serve

    #expect(model.isServing == true)
    #expect(spy.acquireCount == 1)
}

@MainActor
@Test func togglingServingOffReleasesTheAssertion() {
    let reader = FakeReader(source: .ac, percent: 80)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
    #expect(model.isServing == true)
    #expect(spy.releaseCount == 0)

    model.intent = .stop

    #expect(model.isServing == false)
    #expect(spy.releaseCount >= 1)
}

// MARK: - The battery floor

@MainActor
@Test func crossingTheBatteryFloorReleasesTheAssertion() {
    // 16% holds, 14% does not. Named bug this catches: a `refresh()` that
    // updates `isServing` from the decision but never tells the holder, so the
    // switch reads off while the machine is still pinned awake by a live IOKit
    // assertion — exactly the failure a user cannot see and cannot undo.
    let reader = FakeReader(source: .battery, percent: 16)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
    #expect(model.isServing == true)
    #expect(spy.releaseCount == 0)

    reader.set(source: .battery, percent: 14)
    model.refresh()

    #expect(model.isServing == false)
    #expect(spy.releaseCount == 1)
}

@MainActor
@Test func arecoveringBatteryDoesNotReArmTheHold() {
    // The latch, seen from the app layer. 21 -> 19 -> 21 must acquire exactly
    // once. Named bug this catches: `refresh()` building a fresh
    // `HoldController` each call, or reading the user's intent from
    // `isServing`, either of which switches the hold back on by itself when the
    // battery recovers.
    let reader = FakeReader(source: .battery, percent: 16)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
    #expect(spy.acquireCount == 1)

    reader.set(source: .battery, percent: 14)
    model.refresh()
    #expect(model.isServing == false)

    reader.set(source: .battery, percent: 16)
    model.refresh()

    #expect(model.isServing == false)
    #expect(spy.acquireCount == 1)
}

// MARK: - What the panel is told

@MainActor
@Test func theSuppressionLineNamesTheMeasuredPercent() {
    // Design §5.4: the reason is asserted on the enum, never on rendered text.
    let reader = FakeReader(source: .battery, percent: 16)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
    reader.set(source: .battery, percent: 14)
    model.refresh()

    #expect(model.suppression == .batteryFloor(percent: 14, floor: 15))

    // The line reports the reading that RELEASED the hold, not the newest one.
    // Named bug this catches: publishing the current sample instead of the
    // latch. The battery drains on to 12% while nothing is held, and the panel
    // then reads "Released at 12%" — a release that never happened.
    reader.set(source: .battery, percent: 12)
    model.refresh()

    #expect(model.suppression == .batteryFloor(percent: 14, floor: 15))
    #expect(model.reading.percent == 12)
}

@MainActor
@Test func theSuppressionLineSurvivesAtExactlyTheFloor() {
    // The boundary, where the panel and the broker must agree. `PowerBroker`
    // suppresses at `percent <= floor`, so 15% releases the hold. The filter in
    // `ServingModel.reason` has to use the same comparison.
    //
    // Named bug this catches: `percent < floor` in that filter. The battery
    // sits at exactly 15%, the switch refuses to stay on, and the panel drops
    // the one sentence that says why. The user gets a refusal with no reason.
    let reader = FakeReader(source: .battery, percent: 16)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
    #expect(model.isServing == true)

    reader.set(source: .battery, percent: 15)
    model.refresh()

    #expect(model.isServing == false)
    #expect(model.suppression == .batteryFloor(percent: 15, floor: 15))
}

@MainActor
@Test func theSuppressionLineSurvivesARecoveryToExactlyTheFloor() {
    // The filter compares the NEWEST reading against the FLOOR. Every other
    // filter test here latches at 14 with floor 15, or at 15 with floor 15, so
    // the latched percent and the floor are either equal or one apart and no
    // reading ever lands between them. That leaves the region
    // `latched < reading <= floor` — here the single value 15, reached by
    // recovering from a release at 14 — untested, and it is the only region
    // where the two operands disagree.
    //
    // Named bug this catches: `percent <= latched` in place of
    // `percent <= floor`. The hold releases at 14%, the battery recovers a
    // point to 15%, and the line vanishes — but 15% is still at the floor, so
    // the switch goes on refusing. The user gets a refusal with no reason,
    // which is the same defect `theSuppressionLineSurvivesAtExactlyTheFloor`
    // catches from the side where the reading crosses the floor directly.
    let reader = FakeReader(source: .battery, percent: 16)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
    #expect(model.isServing == true)

    reader.set(source: .battery, percent: 14)
    model.refresh()
    // Precondition: the latch is BELOW the floor, so the two operands differ
    // for the reading below. Without it this test repeats the equal-operand
    // fixtures it exists to complement.
    #expect(model.suppression == .batteryFloor(percent: 14, floor: 15))
    #expect(model.isServing == false)

    reader.set(source: .battery, percent: 15)
    model.refresh()

    // Still at or below the floor, so the reason is still true and still shown.
    // It names the reading that RELEASED the hold, not the newest one.
    #expect(model.suppression == .batteryFloor(percent: 14, floor: 15))
    #expect(model.reading.percent == 15)
    // And the switch still refuses, which is what makes a missing line a bug
    // rather than a cosmetic difference.
    #expect(model.isServing == false)
}

@MainActor
@Test func theSuppressionLineClearsOnACPower() {
    // The line explains a condition that is still true. Once the machine is
    // back on AC it is no longer true, so the line goes. The latch does not:
    // `isServing` stays false until the user toggles again.
    let reader = FakeReader(source: .battery, percent: 16)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
    reader.set(source: .battery, percent: 14)
    model.refresh()
    // Precondition: without a line to clear, the assertion below would hold for
    // a model that never publishes one at all.
    #expect(model.suppression != nil)

    reader.set(source: .ac, percent: 14)
    model.refresh()

    #expect(model.suppression == nil)
    #expect(model.isServing == false)
}

@MainActor
@Test func theSuppressionLineClearsOnePointAboveTheFloor() {
    // The mirror of `theSuppressionLineSurvivesAtExactlyTheFloor`, at the first
    // percentage the filter must let go of. `PowerBroker` suppresses at
    // `percent <= floor`, so 16% is above the floor and the line must clear.
    //
    // Named bug this catches: `percent <= floor + 1` in the filter. The macOS
    // battery reading is an estimate and does climb a point or two as the load
    // falls, with no charger attached. The hold releases at 14%, the reading
    // recovers to 16%, and the panel keeps showing "At 14% — coffee-bar does
    // not hold at or below 15%" beside a battery line that reads 16%. That is
    // the stale-reason defect this filter exists to prevent, from the side the
    // 14% -> 40% test cannot see: 40% is twenty-five points clear of the floor, so a
    // one-point error stays green there.
    let reader = FakeReader(source: .battery, percent: 16)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
    reader.set(source: .battery, percent: 14)
    model.refresh()
    // Precondition: without a line to clear, the assertion below would hold for
    // a model that never publishes one at all.
    #expect(model.suppression == .batteryFloor(percent: 14, floor: 15))

    reader.set(source: .battery, percent: 16)
    model.refresh()

    #expect(model.suppression == nil)
    #expect(model.reading.percent == 16)
    #expect(model.isServing == false)
}

@MainActor
@Test func theSuppressionLineClearsWhenTheBatteryRisesAboveTheFloor() {
    let reader = FakeReader(source: .battery, percent: 16)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
    reader.set(source: .battery, percent: 14)
    model.refresh()
    #expect(model.suppression != nil)

    reader.set(source: .battery, percent: 40)
    model.refresh()

    #expect(model.suppression == nil)
    #expect(model.isServing == false)
}

// MARK: - The ticker does its job

@MainActor
@Test func theTickerEnforcesTheFloorWithNobodyWatching() throws {
    // The reason `startMonitoring` exists at all. Its doc comment puts it
    // plainly — `ServingModel.swift` "builds its content only while the panel is open"
    // — because `MenuBarExtra` with `.menuBarExtraStyle(.window)` builds nothing
    // while the panel is shut, so a floor enforced only by the panel does not
    // enforce the floor.
    //
    // Named bug this catches: `MainActor.assumeIsolated { model.refresh() }`
    // reduced to `_ = model`. `startMonitoring` then installs a timer that
    // fires forever and does nothing, and the battery floor is enforced only
    // when the user opens the panel or moves the toggle — the exact defect
    // this design exists to prevent, with the machine held awake below the
    // floor for as long as nobody looks.
    // `theModelInvalidatesItsTimerWhenItGoesAway` cannot see it: that test
    // asserts only that the timer stops after dealloc, never that a tick does
    // anything while the model is alive.
    //
    // Nothing here calls `refresh()`. The only route from the reader's new
    // value to the holder is the tick.
    let reader = FakeReader(source: .battery, percent: 16)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader,
                             health: fixtureHealth(), settings: FakeSettings(),
                             listener: NoopIngestListener())

    model.intent = .serve
    // Preconditions: the hold is live and nothing has been released, so the
    // assertions below cannot hold for a model that never acquired anything.
    #expect(model.isServing == true)
    #expect(spy.releaseCount == 0)

    // SHORT, and the run loop is pumped: the 30s default could never fire
    // inside a test, and the test would then fail for the wrong reason.
    try model.startMonitoring(interval: 0.01)
    defer { model.timer?.invalidate() }

    // The battery crosses the floor with the panel shut.
    reader.set(source: .battery, percent: 14)

    // Bounded, so a regression fails rather than hangs the suite.
    let deadline = Date().addingTimeInterval(2.0)
    while model.isServing, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    #expect(model.isServing == false,
            "the ticker fired but never re-sampled: the floor is enforced only while the panel is open")
    // `>= 1` rather than `== 1`: once the hold is down every further tick
    // releases again, and how many ticks land inside one pump is the run
    // loop's business. One release is the whole claim.
    #expect(spy.releaseCount >= 1,
            "the model reported the hold down without telling the holder")
    #expect(model.suppression == .batteryFloor(percent: 14, floor: 15),
            "the tick released the hold without recording why")
}

// MARK: - The ticker outlives nothing

@MainActor
@Test func theModelInvalidatesItsTimerWhenItGoesAway() throws {
    // Named bug this catches: a model that deallocates and leaves its repeating
    // `Timer` installed on `RunLoop.main`. `[weak self]` stops the block from
    // doing anything, but it does not remove the timer — the run loop holds the
    // last strong reference, so the wake-up survives every 30s for the life of
    // the process. `main.swift` calls `startMonitoring()` from `App.init()`, so
    // one extra `App` build is one permanent orphan.
    //
    // The test holds the timer itself, so the run loop's own reference cannot
    // decide the outcome: after the model goes, `isValid` is the whole answer.
    // The contract is LAZY, not eager. This was an `isolated deinit`, which
    // invalidated the moment the model died; CI proved that feature is
    // experimental before Swift 6.3 and does not compile on the 6.1.2 runner.
    // The timer block now invalidates the timer it is handed once `self` has
    // gone, so the orphan survives at most one further tick. The interval is
    // therefore SHORT and the run loop is pumped — an hour-long interval could
    // never fire, and the test would fail for the wrong reason.
    var captured: Timer?
    do {
        let model = ServingModel(holder: SpyHolder(),
                                 reader: FakeReader(source: .ac, percent: 80),
                                 health: fixtureHealth(), settings: FakeSettings(),
                                 listener: NoopIngestListener())
        try model.startMonitoring(interval: 0.01)
        captured = model.timer
        // Precondition: without a live timer to invalidate, the assertion below
        // would hold for a `startMonitoring` that installs nothing at all.
        #expect(captured?.isValid == true)
    }

    let timer = try #require(captured, "startMonitoring installed no timer")

    // Bounded, so a regression fails rather than hangs the suite.
    let deadline = Date().addingTimeInterval(2.0)
    while timer.isValid, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    #expect(timer.isValid == false,
            "the model deallocated and left a live timer on RunLoop.main")
}

@MainActor
@Test func startMonitoringTwiceLeavesOnlyOneLiveTimer() throws {
    // The other of the two ways a second `Timer` reaches `RunLoop.main`. The
    // doc comment on `startMonitoring` names it —
    // `ServingModel.swift` "a repeat call on the SAME instance" — and closes it
    // with `timer?.invalidate()`; that line was closed in code and open in the
    // suite.
    //
    // Named bug this catches: deleting that one line. `self.timer` is then
    // overwritten by the second call, so the first timer keeps its place on
    // the run loop with nothing left pointing at it — a permanent 30s
    // main-thread wake-up that no handle can reach to stop. The block's
    // `[weak self]` does not help: the model is still alive, so every tick
    // does a full `refresh()`, and the machine pays for two tickers for the
    // life of the process.
    //
    // The interval is LONG on purpose. This test is about what `invalidate()`
    // does, not about what a tick does, so neither timer should fire while it
    // runs — a short interval would let the run loop decide the outcome.
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth(), settings: FakeSettings(),
                             listener: NoopIngestListener())

    try model.startMonitoring(interval: 60)
    let first = try #require(model.timer, "startMonitoring installed no timer")
    // Precondition: without a live first timer, the assertions below would
    // hold for a `startMonitoring` that installs nothing at all.
    #expect(first.isValid == true)

    try model.startMonitoring(interval: 60)
    let second = try #require(model.timer, "the second startMonitoring installed no timer")

    // A second call that reused the same object would satisfy the two
    // `isValid` checks below trivially and prove nothing about invalidation.
    #expect(second !== first, "the second call reused the first timer")
    #expect(first.isValid == false,
            "the first timer is still installed on RunLoop.main and is now unreachable")
    #expect(second.isValid == true,
            "the second call invalidated the timer it had just installed")

    // Leave nothing of this test's own on the shared run loop.
    second.invalidate()
}

// MARK: - The product's central difference

@MainActor
@Test func theModelActsOnTheDecisionTheBrokerReturns() throws {
    // The property this owns is a UI-layer one: what the model REPORTS having
    // decided and what it actually DID must be the same thing. `isServing` is
    // set from the holder's answer, `desired` from the broker's; nothing forces
    // the two to agree except `refresh()` being wired correctly.
    //
    // Named bug this catches: a `refresh()` that reconciles the holder against
    // something other than the state it publishes — a stale `desired`, or an
    // `isServing` computed from the reading rather than the decision. The panel
    // would then explain one state while the machine sat in another.
    //
    // `displaySleepAssertion == false` rides along as a cheap cross-check.
    // Design §6.1 — letting the display sleep while the machine stays awake is
    // what separates coffee-bar from `caffeinate -d`. That half cannot be
    // killed from this layer: `DesiredPowerState` is built only in
    // `Sources/CoffeeBarCore/PowerBroker.swift`, and
    // `Tests/CoffeeBarCoreTests/PowerBroker_test.swift` "the SERVING control can reach the display assertion"
    // guards it there across every input combination.
    let reader = FakeReader(source: .battery, percent: 50)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
    let held = try #require(model.desired)
    #expect(held.idleSleepAssertion == model.isServing)
    #expect(held.idleSleepAssertion == true)
    #expect(held.displaySleepAssertion == false)

    model.intent = .stop
    let stopped = try #require(model.desired)
    #expect(stopped.idleSleepAssertion == model.isServing)
    #expect(stopped.idleSleepAssertion == false)
    #expect(stopped.displaySleepAssertion == false)

    model.intent = .serve
    reader.set(source: .battery, percent: 14)
    model.refresh()
    let suppressed = try #require(model.desired)
    #expect(suppressed.idleSleepAssertion == model.isServing)
    #expect(suppressed.suppression == .batteryFloor(percent: 14, floor: 15))
    #expect(suppressed.idleSleepAssertion == false)
    #expect(suppressed.displaySleepAssertion == false)
}

// MARK: - The hook health the panel reports
//
// LIMIT, and it is deliberate: this reads `~/.claude/settings.json` and NOTHING
// ELSE. `.wired` means the entries are in the file. It does NOT mean an event
// has ever arrived, and it cannot see PE finding B2 — a second app instance
// that unlinks the live socket leaves the file untouched, so the status stays
// `.wired` while ingest is dead. Whatever renders this must say what it
// measured, not that ingest works.

@MainActor
@Test func theModelPublishesTheHookHealthItReads() {
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth("missing-stop.json"),
                             settings: FakeSettings())

    // Before the first refresh nothing has been read. `PanelView.onAppear`
    // calls `refresh()`, so this value never reaches the screen.
    #expect(model.hookHealth == .unreadable)

    model.refresh()
    #expect(model.hookHealth == .missing(["Stop"]))
}

@MainActor
@Test func theModelReportsUnreadableWhenTheSettingsFileIsAbsent() {
    // A user who has never run Claude Code. The model must publish a verdict
    // rather than fail to build.
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth("definitely-not-here.json"),
                             settings: FakeSettings())

    model.refresh()
    #expect(model.hookHealth == .unreadable)
}

@MainActor
@Test func theModelRereadsTheSettingsFileOnEveryRefresh() throws {
    // Named bug this catches: reading the settings file ONCE, in `init`. The
    // user's whole recovery path is "paste the snippet back", and the app runs
    // for days — a status frozen at launch would still say the hooks are
    // missing after they had been restored, which is the same silent-failure
    // dishonesty design §6 exists to remove, pointing the other way.
    let files = FileManager.default
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "coffee-bar-health-\(UUID().uuidString)")
    try files.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: scratch) }

    let settings = scratch.appending(path: "settings.json")
    let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/claude-settings")

    try Data(contentsOf: source.appending(path: "missing-stop.json")).write(to: settings)

    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: HookHealthReader(settingsURL: settings),
                             settings: FakeSettings())
    model.refresh()
    #expect(model.hookHealth == .missing(["Stop"]))

    // The user pastes the Stop entry back while the app is running.
    try Data(contentsOf: source.appending(path: "wired.json")).write(to: settings)
    model.refresh()
    #expect(model.hookHealth == .wired)
}

// MARK: - The line the panel shows for that health
//
// The copy is asserted HERE, on the model, and never on rendered AppKit text —
// M1 design §5.4. `PanelView` renders `hookAdvisory` and transforms nothing, so
// this is the whole decision: what the line says, and whether there is a line
// at all.

@MainActor
@Test func theAdvisorySaysNothingAtAllWhenTheHooksAreWired() {
    // Named bug this catches: a panel that reports its own health every time it
    // opens. Silence is also what keeps the panel honest — the check reads the
    // settings FILE, so it can never prove an event arrived, and a line saying
    // so would be a claim it has no evidence for. PE finding B2: a second app
    // instance stealing the socket kills ingest and leaves this file `.wired`.
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth("wired.json"),
                             settings: FakeSettings())

    model.refresh()
    #expect(model.hookHealth == .wired)
    #expect(model.hookAdvisory == nil)
}

@MainActor
@Test func theAdvisoryNamesEveryMissingEventAndTheFileThatFixesIt() {
    // `missing-two.json` wires SessionStart, PreToolUse and PostToolUse, gives
    // Stop somebody else's command, and omits PermissionDenied entirely.
    //
    // TWO missing events, deliberately: one would leave the separator between
    // them unasserted, and the panel line is the only place that list is ever
    // joined.
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth("missing-two.json"),
                             settings: FakeSettings())

    model.refresh()
    #expect(model.hookHealth == .missing(["PermissionDenied", "Stop"]))

    // A literal. Building the expectation from `hookHealth` would let both
    // sides agree on a line that names no file and tells the user nothing.
    //
    // The wording no longer says "Not receiving". A settings-file read cannot
    // establish that events are absent: Claude Code merges hooks from the user
    // file, a project's .claude/settings.json and settings.local.json, and this
    // reader sees only the first. See
    // theMissingAdvisoryClaimsNothingAboutEventsActuallyFlowing.
    #expect(model.hookAdvisory == """
        No coffee-bar hooks for PermissionDenied, Stop in \
        ~/.claude/settings.json. If yours are in a project's \
        .claude/settings.json, ingest may still be working.
        """)
}

@MainActor
@Test func theAdvisoryNeverTellsTheUserToPasteIntoAFileItCouldNotRead() {
    // Named bug this catches: folding `.unreadable` into the `.missing` line.
    //
    // `.unreadable` is not evidence that the entries are gone — it is a file
    // this app could not parse. Telling that user to add entries that may
    // already be there is how a shared settings file gets clobbered, which is
    // the exact six-occurrence pattern design §6 exists to avoid.
    //
    // BOTH sources of `.unreadable` drive this wording, and both are checked:
    // a Claude Code file that is ABSENT, and one that EXISTS and will not
    // parse. The absent case is the first-run user — see
    // `aFirstRunUserWithNoSettingsFileIsStillToldToWireTheHooks` — and this
    // model has an unset selection, which `ServingModel.assumedAgentTools`
    // resolves to Claude Code for exactly that reason.
    for fixture in ["definitely-not-here.json", "malformed.json"] {
        let unreadable = ServingModel(holder: SpyHolder(),
                                      reader: FakeReader(source: .ac, percent: 80),
                                      health: fixtureHealth(fixture),
                                      settings: FakeSettings())
        unreadable.refresh()
        #expect(unreadable.hookHealth == .unreadable, "\(fixture) is not unreadable")
        #expect(unreadable.hookAdvisory == """
            Cannot read ~/.claude/settings.json, so coffee-bar cannot confirm its \
            hooks are installed. Agent sessions may not arrive.
            """, "\(fixture) reached the wrong advisory")
    }

    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth("malformed.json"),
                             settings: FakeSettings())

    model.refresh()
    #expect(model.hookHealth == .unreadable)

    #expect(model.hookAdvisory == """
        Cannot read ~/.claude/settings.json, so coffee-bar cannot confirm its \
        hooks are installed. Agent sessions may not arrive.
        """)

    // The discriminating half: the two states must not reach the same advice.
    let advisory = model.hookAdvisory ?? ""
    #expect(!advisory.contains("Add the coffee-bar hooks"))
}

@MainActor
@Test func theMissingAdvisoryClaimsNothingAboutEventsActuallyFlowing() throws {
    // MEASURED on the maintainer's machine while this was written: the six hook
    // entries capturing events at that moment lived in the PROJECT file,
    // <repo>/.claude/settings.json, NOT in ~/.claude/settings.json. Claude Code
    // merges hooks from the user file, the project file and settings.local.json.
    // This reader sees only the first.
    //
    // So "Not receiving PermissionDenied, Stop" was FALSE on that machine: 311
    // events had already flowed. Worse, it then sent the user to hand-edit the
    // one file this design deliberately never writes.
    //
    // The check reads a FILE. It may claim only what a file can tell it.
    //
    // Named bug this catches: any future wording that asserts event flow, or the
    // absence of it, from a settings-file read alone.
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth("missing-two.json"),
                             settings: FakeSettings())
    model.refresh()

    let advisory = try #require(model.hookAdvisory)

    #expect(advisory.contains("settings.json"),
            "the advisory must name the file it actually inspected")
    #expect(advisory.lowercased().contains("not receiving") == false,
            "claims events are not arriving, which a file read cannot establish: \(advisory)")
}

// MARK: - The advisory is correct PER AGENT
//
// Issue #10c. `HookHealth.requiredEvents(for:)` existed as data and nothing
// called it: `status(ofSettings:)` filtered the Claude Code CONSTANT and read
// `~/.claude/settings.json` whatever tool the user runs. So a Codex user and a
// Cursor user were both handed a Claude Code advisory naming a file their tool
// never reads.

/// A reader pointed at the committed fixture for each named tool.
///
/// Every model below is handed one, for the reason `fixtureHealth` exists: the
/// shipping default reads the machine's own `~/.codex/hooks.json` and
/// `~/.cursor/hooks.json`, so a check that took the default would report a
/// different advisory on every developer's laptop.
private func fixtureHealth(_ files: [AgentTool: String]) -> HookHealthReader {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()    // …/Tests/CoffeeBarUITests
        .deletingLastPathComponent()    // …/Tests
        .appending(path: "Fixtures")
    let directories: [AgentTool: String] = [.claudeCode: "claude-settings",
                                            .codex: "codex-settings",
                                            .cursor: "cursor-settings"]
    return HookHealthReader(hookFiles: files.reduce(into: [:]) { found, entry in
        found[entry.key] = root.appending(path: "\(directories[entry.key]!)/\(entry.value)")
    })
}

@MainActor
@Test func aCursorUserIsSentToTheCursorFileAndNeverToTheClaudeCodeOne() {
    // **The defect this task exists to fix**, stated as the panel line a Cursor
    // user reads. Before #10c this user was told to paste five PascalCase Claude
    // Code entries into `~/.claude/settings.json` — a file Cursor never reads,
    // naming events Cursor never sends.
    //
    // The captured fixture is the real `~/.cursor/hooks.json`. Three of the five
    // required event KEYS are in it and none of the commands is coffee-bar's, so
    // all five are missing.
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth([.cursor: "captured.json"]),
                             settings: FakeSettings())
    model.refresh()

    // A literal. Building it from `hookHealths` would let both sides agree on a
    // line that names the wrong file and tells the user nothing.
    #expect(model.hookAdvisory == """
        No coffee-bar hooks for afterFileEdit, afterShellExecution, \
        beforeReadFile, beforeShellExecution, sessionStart in ~/.cursor/hooks.json.
        """)
}

@MainActor
@Test func aCodexUserIsSentToTheCodexFileWithCodexEventNames() {
    // The same defect through the other tool, and the sharper half of it: Codex
    // shares Claude Code's event VOCABULARY, so a wrong advisory here reads as
    // plausible. `PermissionDenied` is the tell — it is required for Claude Code
    // and has never appeared in a captured Codex payload.
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth([.codex: "missing-two.json"]),
                             settings: FakeSettings())
    model.refresh()

    #expect(model.hookAdvisory == """
        No coffee-bar hooks for Stop, UserPromptSubmit in ~/.codex/hooks.json.
        """)
}

@MainActor
@Test func onlyTheClaudeCodeLineMentionsAProjectSettingsFile() {
    // Named bug this catches: copying Claude Code's closing sentence onto the
    // other two tools. Claude Code merges hooks from the user file, a project's
    // `.claude/settings.json` and `settings.local.json`, and that measurement is
    // why the sentence exists. NOTHING equivalent was measured for Codex or for
    // Cursor, so stating it for them would be an invented claim in the one place
    // this product promises to tell the truth.
    let claudeCode = ServingModel(holder: SpyHolder(),
                                  reader: FakeReader(source: .ac, percent: 80),
                                  health: fixtureHealth([.claudeCode: "missing-two.json"]),
                                  settings: FakeSettings())
    claudeCode.refresh()
    let claudeLine = claudeCode.hookAdvisory ?? ""
    #expect(claudeLine.contains("If yours are in a project's"),
            "the Claude Code line lost the merge sentence its own measurement earned")

    for (tool, fixture) in [(AgentTool.codex, "missing-two.json"),
                            (AgentTool.cursor, "missing-two.json")] {
        let model = ServingModel(holder: SpyHolder(),
                                 reader: FakeReader(source: .ac, percent: 80),
                                 health: fixtureHealth([tool: fixture]),
                                 settings: FakeSettings())
        model.refresh()
        let line = model.hookAdvisory ?? ""
        #expect(!line.isEmpty, "\(tool.rawValue) produced no advisory to check")
        #expect(!line.contains("If yours are in a project's"),
                "the \(tool.rawValue) line claims a project-file merge nobody measured: \(line)")
        #expect(!line.contains(".claude/"),
                "the \(tool.rawValue) line sends the user to a Claude Code file: \(line)")
    }
}

@MainActor
@Test func aFirstRunUserWithNoSettingsFileIsStillToldToWireTheHooks() {
    // **A user who has never chosen is assumed to run Claude Code, and this is
    // why.**
    //
    // Named bug this catches, and it shipped in the first round of #10c: the
    // gate was applied to all three tools, so a user who had never created
    // `~/.claude/settings.json` got NO line at all. README says coffee-bar does
    // nothing until those hooks exist, so that user is the one who most needs
    // the advice, and the panel said nothing to them.
    //
    // An absent file means "not set up yet" for Claude Code, which is the
    // primary integration and the first-run path. It means "does not use this
    // tool" for Codex and for Cursor. The two readings are different claims
    // about different cohorts, so the two are treated differently.
    //
    // WHAT CHANGED IN ISSUE #51, and why this check did not: the difference used
    // to be a hard-coded `tool == .claudeCode` branch inside
    // `HookHealthReader.status(for:)`, which stood in for a question nobody had
    // asked the user. It is now `ServingModel.assumedAgentTools`, the selection
    // coffee-bar assumes while the user has not made one — and this model's
    // `FakeSettings()` holds no selection. Every expectation below is the one
    // that was here before, unchanged: the behaviour a user sees is the point,
    // and it must not move when the mechanism under it does.
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth([.claudeCode: "definitely-not-here.json",
                                                    .codex: "definitely-not-here.json",
                                                    .cursor: "definitely-not-here.json"]),
                             settings: FakeSettings())
    model.refresh()

    // Claude Code reaches a verdict even with no file; the other two do not.
    #expect(model.hookHealths[.claudeCode] == .unreadable,
            "a first-run user gets no Claude Code verdict at all")
    #expect(model.hookHealths[.codex] == nil, "an absent Codex file reached a verdict")
    #expect(model.hookHealths[.cursor] == nil, "an absent Cursor file reached a verdict")

    // Exactly ONE line, and it is Claude Code's. A gate applied to all three
    // returns nil here; a gate applied to none returns three lines.
    #expect(model.hookAdvisory == """
        Cannot read ~/.claude/settings.json, so coffee-bar cannot confirm its \
        hooks are installed. Agent sessions may not arrive.
        """)
}

@MainActor
@Test func aToolWithNoConfigurationFileGetsNoAdvisoryAboutIt() {
    // Design decision this pins, and the reason the check above can exist: an
    // ABSENT hook file means the user does not run that tool.
    //
    // Named bug this catches: a Claude-Code-only user reading two extra lines
    // telling them to wire Codex and Cursor. The panel would then be noise, and
    // a user who learns to skip it skips the line that mattered.
    //
    // The gate is FILE EXISTENCE, never "has this tool ever posted an event".
    // That rule is circular: a tool with no hooks wired never posts, so it would
    // never be advised, and the advisory exists for exactly that user.
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth([.claudeCode: "wired.json",
                                                    .codex: "definitely-not-here.json"]),
                             settings: FakeSettings())
    model.refresh()

    #expect(model.hookHealths[.codex] == nil, "an absent Codex file reached a verdict")
    #expect(model.hookHealths[.claudeCode] == .wired,
            "the file that IS on disk was not read; this check would pass on nothing")
    #expect(model.hookAdvisory == nil)
}

@MainActor
@Test func everyToolWithSomethingToSayGetsItsOwnLineInAFixedOrder() {
    // Named bug this catches: one tool's advisory silently replacing another's.
    // A user who runs all three has to be told about all three, and the panel
    // renders `hookAdvisory` verbatim — so a property returning only the first
    // finding would drop two-thirds of the advice with no check able to see it.
    //
    // The ORDER is pinned because a dictionary has none. An order that reshuffled
    // between refreshes would rewrite the panel every 30 seconds under a user
    // trying to read it.
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth([.claudeCode: "missing-stop.json",
                                                    .codex: "missing-stop.json",
                                                    .cursor: "missing-session-start.json"]),
                             settings: FakeSettings())
    model.refresh()

    #expect(model.hookAdvisory == """
        No coffee-bar hooks for Stop in ~/.claude/settings.json. If yours are in \
        a project's .claude/settings.json, ingest may still be working.

        No coffee-bar hooks for Stop in ~/.codex/hooks.json.

        No coffee-bar hooks for sessionStart in ~/.cursor/hooks.json.
        """)
}

@MainActor
@Test func aWiredToolAddsNoLineWhileABrokenOneStillReportsIt() {
    // The discriminating half of the check above. `.wired` says NOTHING, for the
    // reason `theAdvisorySaysNothingAtAllWhenTheHooksAreWired` gives — this
    // check reads a FILE and can never prove an event arrived.
    //
    // Named bug this catches: a joiner that emits a blank line, a stray
    // separator, or the word "wired" for the healthy tool. The Codex line must
    // stand alone and read exactly as it does when it is the only tool present.
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth([.claudeCode: "wired.json",
                                                    .codex: "missing-stop.json",
                                                    .cursor: "wired.json"]),
                             settings: FakeSettings())
    model.refresh()

    #expect(model.hookHealths[.claudeCode] == .wired)
    #expect(model.hookHealths[.cursor] == .wired,
            "the Cursor fixture is fully wired; a nested parse would report it broken")
    #expect(model.hookAdvisory == """
        No coffee-bar hooks for Stop in ~/.codex/hooks.json.
        """)
}

// MARK: - Which tools the user says they run (issue #51)
//
// coffee-bar used to decide which tools to advise about by looking for their
// files. The user never said. This section holds what the answer is when they
// have not said, and what changes the moment they do.

@MainActor
@Test func anUnsetSelectionAdvisesExactlyAsTheFileGateAlwaysHas() {
    // **The unset case, pinned against the build that shipped before issue
    // #51.** An existing user who has never opened Preferences must read exactly
    // what they read yesterday, and the fifth key is `Optional` throughout, so
    // that has to be a DECISION rather than a `?? []` that happens to work.
    //
    // The decision, in two named halves:
    //
    //   - `ServingModel.assumedAgentTools` says which tools coffee-bar assumes
    //     when nobody has chosen. It is `[.claudeCode]`, which is the old
    //     hard-coded exemption restated as a default the user may now override.
    //   - `advises(_:)` falls back to "the reader had something to say about
    //     it", which is the old file-existence inference, unchanged.
    //
    // All three tools are driven at once, because the unset behaviour is a
    // different claim for each cohort and a check that drove one would pass over
    // a change to the others:
    //
    //   - Claude Code, NO FILE — a line, because that is the first-run user.
    //   - Codex, a file that IS there and is missing entries — a line.
    //   - Cursor, NO FILE — silence, because nothing says the user runs it.
    //
    // Mutating either half turns this red: `assumedAgentTools = []` drops the
    // Claude Code line, and an `advises(_:)` whose unset branch answers `true`
    // adds a Cursor one.
    let settings = FakeSettings()
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth([.claudeCode: "definitely-not-here.json",
                                                    .codex: "missing-two.json",
                                                    .cursor: "definitely-not-here.json"]),
                             settings: settings)
    model.refresh()

    #expect(model.selectedAgentTools == nil,
            "the model invented a selection for a user who has never chosen")

    // A literal. Building it from `hookHealths` would let both sides agree on a
    // line that names no file and tells the user nothing.
    #expect(model.hookAdvisory == """
        Cannot read ~/.claude/settings.json, so coffee-bar cannot confirm its \
        hooks are installed. Agent sessions may not arrive.

        No coffee-bar hooks for Stop, UserPromptSubmit in ~/.codex/hooks.json.
        """)

    // NOT SEEDED. Writing the key as a side effect of reading it makes a default
    // indistinguishable from a choice, and issue #52's wizard has to tell those
    // apart to know whom it is for.
    #expect(settings.stringArray(forKey: SettingsKey.agentTools) == nil,
            "reading the selection wrote it; a default is now indistinguishable from a choice")
}

@MainActor
@Test func aSelectedSubsetNarrowsTheAdvisoryToThatSubset() {
    // **The defect issue #51 exists to fix**, stated as the panel a user reads.
    // Every one of these three files is on disk and every one of them is
    // missing entries, so the build before this task printed three lines — two
    // of them about tools this user does not run and cannot act on.
    //
    // Named bug this catches: a narrowing applied to the READ rather than to
    // what is SAID. `hookHealths` still carries the evidence for all three —
    // asserted below — and the advisory speaks about one. A model that dropped
    // the other two from the collection would pass a check that only read
    // `hookAdvisory`, and would then have to re-read the files the moment the
    // user changed their mind.
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth([.claudeCode: "missing-stop.json",
                                                    .codex: "missing-stop.json",
                                                    .cursor: "missing-session-start.json"]),
                             settings: FakeSettings([SettingsKey.agentTools: ["codex"]]))
    model.refresh()

    #expect(model.hookHealths[.claudeCode] == .missing(["Stop"]),
            "the evidence for an unselected tool was thrown away rather than left unspoken")
    #expect(model.hookHealths[.cursor] == .missing(["sessionStart"]))

    #expect(model.hookAdvisory == """
        No coffee-bar hooks for Stop in ~/.codex/hooks.json.
        """)
}

@MainActor
@Test func aToolTheUserRunsIsAdvisedAboutEvenWithNoFileOnDisk() {
    // The signal the deleted `.claudeCode` exemption was standing in for, now
    // supplied by the user — and supplied for a tool the exemption never
    // covered. A Codex user who has not wired anything yet has no
    // `~/.codex/hooks.json` at all, which is exactly the first-run state the
    // advisory exists for, and the old build told them nothing.
    //
    // Named bug this catches: a selection that only ever narrows. Filtering
    // `AgentTool.allCases` down to the chosen set, with the existence gate left
    // whole underneath it, keeps every check above green and leaves this user in
    // the silence issue #51 is meant to end.
    //
    // `.claudeCode` is deliberately NOT the selected tool here: with the old
    // exemption still in place this check would pass on it.
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth([.claudeCode: "wired.json",
                                                    .codex: "definitely-not-here.json"]),
                             settings: FakeSettings([SettingsKey.agentTools: ["codex"]]))
    model.refresh()

    #expect(model.hookAdvisory == """
        Cannot read ~/.codex/hooks.json, so coffee-bar cannot confirm its \
        hooks are installed. Agent sessions may not arrive.
        """)
}

@MainActor
@Test func turningAToolOffRecordsTheChoiceAndSilencesItAtOnce() {
    // The control's whole job, driven through the model the window binds to.
    //
    // Named bug 1: a setter that changes the property and never reaches the
    // store, so the choice is lost on the next launch and the app goes back to
    // guessing with nothing to report.
    //
    // Named bug 2: a setter that stores the choice and does not reconcile, so
    // the panel keeps printing the advisory the user just switched off until the
    // next 30-second tick. `holdDisplayAwake` and `quietEverythingElse` both
    // reconcile on the set for the same reason.
    //
    // Named bug 3: a setter that writes only the tool it was handed. The user
    // ticks Codex off and Claude Code — inferred until that moment — goes with
    // it, because the implicit selection was never frozen before being edited.
    let settings = FakeSettings()
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth([.claudeCode: "missing-stop.json",
                                                    .codex: "missing-stop.json"]),
                             settings: settings)
    model.refresh()

    // Both tools are advised about while nobody has chosen: that is the state
    // being edited, and without it the assertions below would measure nothing.
    #expect(model.advises(.claudeCode))
    #expect(model.advises(.codex))

    model.setAdvises(false, for: .codex)

    #expect(model.advises(.codex) == false)
    #expect(model.advises(.claudeCode),
            "switching Codex off took Claude Code with it")
    #expect(settings.stringArray(forKey: SettingsKey.agentTools) == ["claudeCode"],
            """
            the choice never reached the store: \
            \(String(describing: settings.stringArray(forKey: SettingsKey.agentTools)))
            """)

    #expect(model.hookAdvisory == """
        No coffee-bar hooks for Stop in ~/.claude/settings.json. If yours are in \
        a project's .claude/settings.json, ingest may still be working.
        """)
}

@MainActor
@Test func aUserWhoSelectsNothingIsToldNothing() {
    // The third state, and the reason the stored value is `Optional`: choosing
    // NO tool is an answer, and it is not the same answer as never having been
    // asked. The same fixtures under an unset key print two lines —
    // `turningAToolOffRecordsTheChoiceAndSilencesItAtOnce` asserts that
    // directly — so this is the pair that proves `[]` is honoured rather than
    // read as "never chosen".
    //
    // Named bug this catches: `?? []` folded the other way, `selection ?? all`,
    // or any read that treats an empty list as absent. The user asked for
    // silence and would keep hearing about every file on their disk.
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth([.claudeCode: "missing-stop.json",
                                                    .codex: "missing-stop.json"]),
                             settings: FakeSettings([SettingsKey.agentTools: [String]()]))
    model.refresh()

    #expect(model.selectedAgentTools == [],
            "an empty selection read back as \(String(describing: model.selectedAgentTools))")
    #expect(model.hookAdvisory == nil)
}

@MainActor
@Test func theSelectionLabelNamesNoToolAndPromisesNoWriting() {
    // The sentence the window shows above the tool rows, asserted here because
    // M1 design §5.4 rules out asserting on rendered AppKit text — a label
    // written in the view is a label no check reads.
    //
    // Named bug 1: a sentence that lists the tools. `AgentTool.allCases` is the
    // one place the list lives; a fourth tool would arrive with the caption
    // above it still naming three, and no check would see it.
    //
    // Named bug 2: a sentence that offers to install anything. Design §6 is
    // print-never-touch for every one of these files, and the section below this
    // caption offers a Copy button for exactly that reason.
    let label = ServingModel.agentToolsLabel

    for tool in AgentTool.allCases {
        #expect(!label.localizedCaseInsensitiveContains(tool.rawValue),
                "the caption names \(tool.rawValue), so a fourth tool makes it a lie: \(label)")
    }
    #expect(!label.localizedCaseInsensitiveContains("install"),
            "the caption offers to install something: \(label)")
    #expect(label.localizedCaseInsensitiveContains("hook"),
            "the caption says nothing about what the selection is for: \(label)")
}

/// A reader whose two read methods deliberately DISAGREE.
///
/// This is the only way to catch the bug below, and the reason is worth stating.
/// A guard driven by real fixture files cannot see it: `refresh()` would make
/// both reads microseconds apart against one unchanging file, so a SECOND read
/// returns exactly what the first did and the two agree even when the model is
/// wrong. Only a source whose reads differ can tell a DERIVED value from a
/// separately-read one.
private struct DisagreeingHealth: HookHealthProviding {
    /// What the collection says. `hookHealth` must be THIS.
    ///
    /// The selection is ignored: the disagreement this double exists to stage is
    /// between the two READS, and making it turn on the selection as well would
    /// stage two faults at once and tell the reader nothing about either.
    func statuses(advising selected: Set<AgentTool>) -> [AgentTool: HookHealthStatus] {
        [.claudeCode: .wired]
    }
    /// What a second, independent read would say. `hookHealth` must NOT be this.
    func status() -> HookHealthStatus { .missing(["Stop"]) }
}

@MainActor
@Test func theClaudeCodeHealthTheModelPublishesIsTheOneInTheCollection() {
    // `hookHealth` and `hookHealths[.claudeCode]` are ONE value, not two.
    //
    // Named bug this catches: `hookHealth` kept as a stored property fed by its
    // own `health.status()` call in `refresh()`. The panel would render one
    // value while every other check drove the other, and nothing could see the
    // disagreement.
    //
    // **The earlier version of this check was THEATER and is deleted.** It
    // looped over three fixtures that all EXIST, so `hookHealths[.claudeCode]`
    // was never nil and the assertion reduced to `X ?? .unreadable == X` with X
    // non-nil — true whatever the model did. The stored-property bug it names
    // was planted and the whole suite stayed green at 610.
    //
    // Adding an ABSENT fixture to that loop does NOT fix it: `hookHealth` falls
    // back to `.unreadable` by design while the collection has no key, so the
    // check would go red against CORRECT code. Measured before it was rejected.
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: DisagreeingHealth(),
                             settings: FakeSettings())
    model.refresh()

    // The collection's value, not the second read's. Both are literals, so
    // neither side restates the model's own logic.
    #expect(model.hookHealth == .wired,
            "hookHealth is a SECOND read of the health source, not the collection's value")
    #expect(model.hookHealth != .missing(["Stop"]),
            "hookHealth carries what a separate status() call returned")
    #expect(model.hookHealth == model.hookHealths[.claudeCode])
}

// MARK: - A refused On click says so, and says where the control landed

// M1 design §5.4 rules out asserting on rendered AppKit text, so the wording
// lives on the model and is asserted here. `PanelView` renders it verbatim. A
// sentence composed in the view would be a sentence no check reads, which is
// how this defect stayed invisible: `suppressionLine` used to be built there.

@MainActor
@Test func aRefusedOnClickSaysItWasRefusedAndWhereTheControlLanded() {
    // Situation A. The user stood on Auto, clicked On, and the floor refused.
    // The app moved their control for them.
    //
    // Named bug this catches: rendering the battery sentence alone. The picker
    // snaps back to Auto and no sentence says the app moved it, so a user who
    // clicked On reads a line about the battery and believes On is honoured.
    let reader = FakeReader(source: .battery, percent: 14)
    let model = ServingModel(holder: SpyHolder(), reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve

    #expect(model.intent == .auto, "the I4 fix must still return the control to the standing position")
    #expect(model.suppressionAdvisory == """
        At 14% — coffee-bar does not hold at or below 15%. Your On click was \
        refused, so the control is back on Auto.
        """)
}

@MainActor
@Test func aSuppressedAutoHoldNeverClaimsAClickWasRefused() {
    // Situation B. The user clicked NOTHING. A working session asks for the
    // hold, the floor refuses it, and the control has not moved.
    //
    // Named bug this catches: situation B borrowing situation A's sentence. The
    // panel tells a user who touched nothing that their click was refused, and
    // points at a control that is exactly where they left it.
    let reader = FakeReader(source: .battery, percent: 14)
    let model = ServingModel(holder: SpyHolder(), reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.ingest(from: .claudeCode, HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))

    #expect(model.intent == .auto, "no click happened")
    #expect(model.suppression == .batteryFloor(percent: 14, floor: 15),
            "precondition: without a live suppression there is no sentence to get wrong")
    #expect(model.suppressionAdvisory == "At 14% — coffee-bar does not hold at or below 15%.")
}

@MainActor
@Test func theRefusalSentenceGoesWhenTheBatteryRecovers() {
    // The refusal claim must not outlive the condition. It goes exactly when the
    // orange line goes.
    //
    // Named bug this catches: latching the refusal outside the filter in
    // `reason(_:stillTrueOf:)`. The battery recovers, the floor stops refusing
    // anything, and the panel goes on telling the user their click was refused.
    let reader = FakeReader(source: .battery, percent: 14)
    let model = ServingModel(holder: SpyHolder(), reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
    #expect(model.suppressionAdvisory?.contains("was refused") == true,
            "precondition: the refusal reached the panel at all")

    reader.set(source: .battery, percent: 25)
    model.refresh()

    #expect(model.suppressionAdvisory == nil)
    // The STATE behind the sentence, not the sentence alone. Two mechanisms
    // drop the line — the filter in `refresh()` and the `suppression` guard in
    // `suppressionAdvisory` — so asserting the string only is green with either
    // one broken, and a refusal latched past its condition sits there waiting
    // for the first reader that does not guard. Measured: deleting the filter
    // leaves the string assertion above passing.
    #expect(model.cancelledServe == nil)
}

@MainActor
@Test func anHonouredOnClickReleasedByTheFloorNeverSaysItWasRefused() {
    // `PowerBroker` holds for `.serve` unconditionally, so a click at 50% is
    // HONOURED and the Mac stays awake. The battery then drains under it and the
    // floor releases the hold. That is the normal end of the On position.
    //
    // Named bug this catches: calling that a refusal. The panel tells a user
    // whose click worked for hours that it was refused — a sentence that is
    // simply false, and false on the commonest exit from On rather than on an
    // edge case. Shipped in round 1 of this task and measured before this fix.
    let reader = FakeReader(source: .battery, percent: 50)
    let model = ServingModel(holder: SpyHolder(), reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
    // The two preconditions that make this the RELEASE path and not the refusal
    // path. Without them the check passes for a click that was never served.
    #expect(model.isServing == true, "precondition: the click was honoured and the Mac is held")
    #expect(model.suppressionAdvisory == nil, "precondition: nothing is refusing anything yet")

    reader.set(source: .battery, percent: 14)
    model.refresh()

    #expect(model.isServing == false, "precondition: the floor released the hold")
    #expect(model.intent == .auto)
    #expect(model.suppressionAdvisory == """
        At 14% — coffee-bar does not hold at or below 15%. coffee-bar released \
        the hold from your On click, so the control is back on Auto.
        """)
}

@MainActor
@Test func aReleasedHoldFromOffNamesOffNotAuto() {
    // The RELEASE sentence names a position too, and the standing position is
    // not always Auto. `aRefusedOnClickFromOffNamesOffNotAuto` drives only the
    // REFUSED wording, so without this the release half is unguarded.
    //
    // Named bug this catches: hard-coding "Auto" in the release sentence, or
    // returning `.auto` instead of `standing` from the release branch. Both
    // survive the whole suite otherwise — measured. A user who vetoed serving
    // reads that they are back on Auto while the control shows Off, so the one
    // sentence explaining the move describes a move that did not happen.
    let reader = FakeReader(source: .battery, percent: 50)
    let model = ServingModel(holder: SpyHolder(), reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .stop
    model.intent = .serve
    #expect(model.isServing == true, "precondition: the click was honoured from the Off position")

    reader.set(source: .battery, percent: 14)
    model.refresh()

    #expect(model.intent == .stop, "the veto survives a released hold")
    #expect(model.suppressionAdvisory == """
        At 14% — coffee-bar does not hold at or below 15%. coffee-bar released \
        the hold from your On click, so the control is back on Off.
        """)
}

@MainActor
@Test func aHoldThatWasNeverTakenIsNotCalledAReleasedHold() {
    // `holder.acquire()` can fail: IOKit refuses, and `isServing` stays false.
    // Nothing is ever held, so nothing can be released.
    //
    // Named bug this catches: sourcing "this request has held" from the DESIRED
    // state rather than the actual acquisition. The panel then reads "coffee-bar
    // released the hold from your On click" directly beside its own line "Not
    // holding any assertion." — two sentences that contradict each other on one
    // screen. The word "released" is new, so this falsehood is new.
    let reader = FakeReader(source: .battery, percent: 50)
    let model = ServingModel(holder: FailingHolder(), reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
    // The precondition that makes this the failing-holder path. Without it the
    // check passes for a click that was simply never honoured.
    #expect(model.isServing == false, "precondition: acquire() refused, so NO hold exists")
    #expect(model.desired?.idleSleepAssertion == true,
            "precondition: the hold was DESIRED, so only the acquisition failed")

    reader.set(source: .battery, percent: 14)
    model.refresh()

    #expect(model.suppressionAdvisory?.contains("released the hold") == false,
            "claims a hold was released when none was ever taken: \(model.suppressionAdvisory ?? "nil")")
    #expect(model.suppressionAdvisory == """
        At 14% — coffee-bar does not hold at or below 15%. Your On click was \
        refused, so the control is back on Auto.
        """)
}

@MainActor
@Test func aHoldInheritedFromAutoIsNotCreditedToALaterRefusedClick() {
    // The battery can cross the floor between ticks. `.auto` is holding for a
    // working session, the reading drops, and the user clicks On before the next
    // refresh — a click that is refused AT CLICK TIME and never holds.
    //
    // Named bug this catches: reading "is a hold active?" off the previous tick
    // and crediting it to this request. The hold belonged to `.auto`, not to the
    // click, so "coffee-bar released the hold from your On click" names the
    // wrong cause. This is the case a naive fix for the failing holder breaks.
    // The user has served before, so BOTH stale signals are live: an earlier
    // request that asked for a hold, and a hold that is still up when the next
    // click lands. Without the earlier On click this check misses the case
    // where the "did this request ask for a hold?" flag survives the new click.
    let reader = FakeReader(source: .battery, percent: 50)
    let model = ServingModel(holder: SpyHolder(), reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.ingest(from: .claudeCode, HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))
    model.intent = .serve
    #expect(model.isServing == true, "precondition: an earlier On click asked for, and got, a hold")

    // Back to Auto. The working session keeps the machine held, so the hold
    // that outlives this click belongs to `.auto` and not to the click.
    model.intent = .auto
    #expect(model.isServing == true, "precondition: .auto holds the machine for the session")

    // The reading falls, and the user clicks On before any refresh sees it.
    reader.set(source: .battery, percent: 14)
    model.intent = .serve

    #expect(model.isServing == false)
    #expect(model.suppressionAdvisory?.contains("released the hold") == false,
            "credits .auto's hold to a click that never held: \(model.suppressionAdvisory ?? "nil")")
    #expect(model.suppressionAdvisory == """
        At 14% — coffee-bar does not hold at or below 15%. Your On click was \
        refused, so the control is back on Auto.
        """)
}

@MainActor
@Test func aSecondRefusedOnClickStillReportsTheRefusal() {
    // The user tries again. The floor has not moved, so the answer is the same
    // — and it has to be SAID again.
    //
    // Named bug this catches: a one-shot flag that is consumed on the first
    // read, or one that `userToggled(to: .serve)` clears and nothing re-arms.
    // The second refusal is then silent, which is the failure this whole task
    // exists to remove.
    let reader = FakeReader(source: .battery, percent: 14)
    let model = ServingModel(holder: SpyHolder(), reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
    #expect(model.suppressionAdvisory?.contains("was refused") == true,
            "precondition: the first refusal reached the panel")

    model.intent = .serve

    #expect(model.intent == .auto)
    #expect(model.suppressionAdvisory == """
        At 14% — coffee-bar does not hold at or below 15%. Your On click was \
        refused, so the control is back on Auto.
        """)
}

@MainActor
@Test func aRefusedOnClickFromOffNamesOffNotAuto() {
    // The standing position is not always Auto. A user who vetoed serving
    // outright, then clicked On, lands back on the veto — and the sentence has
    // to name the position they actually landed on.
    //
    // Named bug this catches: hard-coding "Auto" in the sentence. The control
    // reads Off and the panel says Auto, so the one line that exists to explain
    // the move describes a move that did not happen.
    let reader = FakeReader(source: .battery, percent: 15)
    let model = ServingModel(holder: SpyHolder(), reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .stop
    model.intent = .serve

    #expect(model.intent == .stop)
    #expect(model.suppressionAdvisory == """
        At 15% — coffee-bar does not hold at or below 15%. Your On click was \
        refused, so the control is back on Off.
        """)
}

// MARK: - The refusal sentence lives exactly as long as the episode it explains

// The checks above prove the sentence ARRIVES. These prove it stays for as long
// as it is true and never comes back afterwards, which is where audit findings 1
// and 2 landed. Both run through `refresh()` — the one path every wipe and every
// replay goes through — because the record they are about is filtered there,
// against `reason(_:stillTrueOf:)`. A check one layer down at `HoldController`
// cannot see either: nothing in the controller changes during the replay.

@MainActor
@Test func theRefusalSentenceSurvivesTheNextIngestEvent() {
    // Audit finding 1, in the situation it targets. The user clicks On precisely
    // when an agent is running, and under a live agent the next hook event
    // arrives sub-second — so a sentence that dies on the next refresh is a
    // sentence nobody reads.
    //
    // Named bug this catches: clearing the cancel record on any suppression that
    // cancels no click. The working session asks for the hold, the same floor
    // refuses it, and the user is left with the battery line alone — the line a
    // user who touched NOTHING gets. The disclosure is then inoperative in
    // exactly the case it exists for.
    let reader = FakeReader(source: .battery, percent: 14)
    let model = ServingModel(holder: SpyHolder(), reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.ingest(from: .claudeCode, HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))
    model.intent = .serve

    let refusal = """
        At 14% — coffee-bar does not hold at or below 15%. Your On click was \
        refused, so the control is back on Auto.
        """
    #expect(model.suppressionAdvisory == refusal, "precondition: the refusal reached the panel")

    // The next hook event. The session is still working, so the floor refuses a
    // hold this user never asked for — and that must not speak for their click.
    model.ingest(from: .claudeCode, HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))
    #expect(model.suppression == .batteryFloor(percent: 14, floor: 15),
            "precondition: that refresh really did suppress")
    #expect(model.suppressionAdvisory == refusal)

    // The 30-second ticker and `PanelView.onAppear` reach the same `refresh()`,
    // and the panel is opened by the user who wants to read this sentence.
    model.refresh()
    #expect(model.suppressionAdvisory == refusal)
}

@MainActor
@Test func aRefusalAtExactlyTheFloorStillSaysItWasRefused() {
    // The boundary of that lifetime rule, and the mirror of
    // `theSuppressionLineSurvivesAtExactlyTheFloor` for the record rather than
    // for the reason. `PowerBroker` suppresses at `percent <= floor`, so 15%
    // refuses the click, and the rule that decides how long the record lives has
    // to use the same comparison.
    //
    // Named bug this catches: `percent < floor` in that rule. It throws the
    // record away in the very call that wrote it, so the user clicks On at
    // exactly 15%, the control snaps back to Auto on its own, and the one
    // sentence that says why is missing — while every check at 14% stays green.
    let reader = FakeReader(source: .battery, percent: 15)
    let model = ServingModel(holder: SpyHolder(), reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve

    let refusal = """
        At 15% — coffee-bar does not hold at or below 15%. Your On click was \
        refused, so the control is back on Auto.
        """
    #expect(model.intent == .auto)
    #expect(model.suppressionAdvisory == refusal)

    // And it survives the next refresh at that same reading. The click itself
    // cannot test the boundary: `userToggled` clears `lastSuppression`, so the
    // rule that ends the episode has no record to judge on the very call that
    // writes one. Only a LATER reading puts `percent > floor` to the test, and
    // 15% is the one value where `>` and `>=` disagree.
    model.refresh()
    #expect(model.suppressionAdvisory == refusal)
}

@MainActor
@Test func aRefusalFromAnEarlierDrainNeverReturnsAtALaterOne() {
    // Audit finding 2, and the mirror of the check above: the same record that
    // must survive a refresh must STAY GONE once its episode ends.
    //
    // Named bug this catches: clearing the record inside the suppression branch
    // only. With no session there is nothing to hold for, `PowerBroker` returns
    // early, and no suppression ever fires under `.auto` — so nothing clears the
    // record and `reason(_:stillTrueOf:)` re-admits the old suppression the
    // moment the reading is at or below the floor again. The user reads "Your On
    // click was refused" for a click they made days ago, at a reading that is
    // not the one on screen, with the control back on Auto and no session
    // running.
    let reader = FakeReader(source: .battery, percent: 5)
    let model = ServingModel(holder: SpyHolder(), reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
    #expect(model.suppressionAdvisory?.contains("was refused") == true,
            "precondition: the refusal reached the panel")
    #expect(model.intent == .auto, "precondition: the control is back on the standing position")

    // The battery recovers past the floor, on battery power throughout. The line
    // goes, and the record behind it has to go with it.
    reader.set(source: .battery, percent: 16)
    model.refresh()
    #expect(model.suppressionAdvisory == nil, "precondition: the episode ended")

    // A later drain, days on. Nothing was clicked in between.
    reader.set(source: .battery, percent: 14)
    model.refresh()

    #expect(model.cancelledServe == nil)
    // The battery half of the line returns, and that half is correct: it names
    // the reading the DECISION was made on, which is what
    // `theSuppressionLineNamesTheMeasuredPercent` pins. Only the claim about the
    // user's click is stale, so only that claim goes.
    #expect(model.suppressionAdvisory == "At 5% — coffee-bar does not hold at or below 15%.")
}

@MainActor
@Test func aRepeatedOnClickNeverTurnsAReleaseIntoARefusal() {
    // Audit finding 3, at the layer the panel reads. A segmented SwiftUI picker
    // writes its binding on a re-tap of the segment that is ALREADY selected, so
    // one click on a control that does not move reaches this setter.
    //
    // Named bug this catches: `userToggled` treating that write as a NEW request
    // and clearing the two hold flags. The re-tap lands after the reading falls
    // and before any refresh has seen it — the battery crosses the floor between
    // 30-second ticks — so the flag that says "this request asked for a hold" is
    // gone by the time the floor releases it. The panel then tells a user whose
    // click held the Mac awake that it was refused, which is the exact falsehood
    // `anHonouredOnClickReleasedByTheFloorNeverSaysItWasRefused` exists to stop,
    // reached through a different door.
    let reader = FakeReader(source: .battery, percent: 25)
    let model = ServingModel(holder: SpyHolder(), reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
    #expect(model.isServing == true, "precondition: the click was honoured and the Mac is held")

    // The reading falls between ticks. The user, seeing nothing yet, taps the On
    // segment again — and that write arrives before any refresh sees 14%.
    reader.set(source: .battery, percent: 14)
    model.intent = .serve

    #expect(model.isServing == false, "precondition: the floor released the hold")
    #expect(model.intent == .auto)
    #expect(model.suppressionAdvisory == """
        At 14% — coffee-bar does not hold at or below 15%. coffee-bar released \
        the hold from your On click, so the control is back on Auto.
        """)
}

// MARK: - The display hold (issue #12)
//
// Issue #12 asked whether "coffee-bar never holds a display assertion" is a
// product promise or a default. The user settled it: a DEFAULT. So these check
// two things that are not the same — that the default is still off, and that
// the opt-in actually reaches IOKit. Either one alone can be green while the
// product is wrong.

@MainActor
@Test func theDisplayHoldIsOffOnAFreshInstall() {
    // The shipped state, for a user who has never opened the panel. A store
    // with nothing in it is what a first launch reads.
    let reader = FakeReader(source: .ac, percent: 80)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    #expect(model.holdDisplayAwake == false)

    model.intent = .serve

    #expect(model.isServing == true, "precondition: the machine is held at all")
    #expect(spy.displaySleepRequests == [false], """
        the model asked for a display hold nobody turned on: \
        \(spy.displaySleepRequests)
        """)
}

@MainActor
@Test func theDisplayHoldReachesTheHolderOnlyWhileTheSettingIsOn() {
    // The whole feature, end to end through the model's own seam. Named bug
    // this catches: a setting the panel writes and stores and NOTHING reads —
    // a control that moves and changes nothing, which is the failure mode
    // `thePanelReadsTheHookAdvisoryTheModelPublishes` exists for one layer up.
    let reader = FakeReader(source: .ac, percent: 80)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
    #expect(spy.displaySleepRequests == [false], "precondition: the default is off")

    model.holdDisplayAwake = true

    // The SEQUENCE, not the last value: the setting has to reach IOKit on the
    // next reconcile, not merely be remembered.
    #expect(spy.displaySleepRequests == [false, true], """
        turning the setting on did not ask the holder for the display: \
        \(spy.displaySleepRequests)
        """)

    model.holdDisplayAwake = false

    // And back off again. A model that only ever adds leaves the screen lit
    // after the user unticks the box.
    #expect(spy.displaySleepRequests == [false, true, false], """
        turning the setting off did not withdraw the display request: \
        \(spy.displaySleepRequests)
        """)
}

@MainActor
@Test func theOffPositionWithdrawsTheDisplayHoldAsWell() {
    // The absolute veto, one layer above `theOffPositionVetoesTheDisplayHoldToo`.
    // The user has opted in AND switched the product off; the screen must go to
    // sleep with the machine. Named bug this catches: an opt-in read straight
    // off the setting rather than off `DesiredPowerState`, which would keep the
    // screen lit after the off switch.
    let reader = FakeReader(source: .ac, percent: 80)
    let spy = SpyHolder()
    let model = ServingModel(
        holder: spy, reader: reader, health: fixtureHealth(),
        settings: FakeSettings([SettingsKey.holdDisplayAwake: true]))

    model.intent = .serve
    #expect(spy.displaySleepRequests == [true], "precondition: the opt-in reached the holder")

    model.intent = .stop

    #expect(model.isServing == false)
    #expect(spy.releaseCount >= 1, "the off switch released nothing")
    // No further acquire happened, so nothing re-asked for the display.
    #expect(spy.displaySleepRequests == [true], """
        something asked for a hold after the off switch: \(spy.displaySleepRequests)
        """)
}

@MainActor
@Test func theBatteryFloorWithdrawsTheDisplayHoldAsWell() {
    // §8.1 through the model. A screen held below the floor drains the battery
    // faster than the hold the floor has just refused.
    let reader = FakeReader(source: .battery, percent: 25)
    let spy = SpyHolder()
    let model = ServingModel(
        holder: spy, reader: reader, health: fixtureHealth(),
        settings: FakeSettings([SettingsKey.holdDisplayAwake: true]))

    model.intent = .serve
    #expect(model.isServing == true, "precondition: the hold was honoured above the floor")
    #expect(spy.displaySleepRequests == [true], "precondition: the display went up with it")

    reader.set(source: .battery, percent: 14)
    model.refresh()

    #expect(model.isServing == false)
    #expect(spy.releaseCount >= 1, "the floor released nothing")
    #expect(spy.displaySleepRequests == [true], """
        something asked for a display hold below the floor: \(spy.displaySleepRequests)
        """)
}

@MainActor
@Test func theSettingIsWrittenToTheStoreWhenTheUserChangesIt() {
    // The write half of persistence. Without it the panel remembers the choice
    // for exactly as long as the app runs, and every check above stays green.
    let store = FakeSettings()
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth(), settings: store)

    #expect(store.bool(forKey: SettingsKey.holdDisplayAwake) == nil,
            "precondition: nothing was stored before the user touched anything")

    model.holdDisplayAwake = true
    #expect(store.bool(forKey: SettingsKey.holdDisplayAwake) == true)

    model.holdDisplayAwake = false
    // `false`, not absent. A store that deleted the key on an opt-out would
    // read as "never asked" and could never distinguish the two.
    #expect(store.bool(forKey: SettingsKey.holdDisplayAwake) == false)
}

@MainActor
@Test func aStoredSettingIsReadBackAtTheNextLaunch() {
    // The read half, which is what "survives a restart" means at this layer:
    // a NEW model over a store that already holds the value starts opted in.
    // `SettingsStore_test.swift` proves the value reaches the disk; this proves
    // the model asks for it at all.
    //
    // Named bug this catches: an `init` that ignores the store and starts every
    // launch at `false`. Every check above still passes, because each one sets
    // the value itself before reading it.
    let spy = SpyHolder()
    let model = ServingModel(
        holder: spy, reader: FakeReader(source: .ac, percent: 80),
        health: fixtureHealth(),
        settings: FakeSettings([SettingsKey.holdDisplayAwake: true]))

    #expect(model.holdDisplayAwake == true)

    model.intent = .serve
    #expect(spy.displaySleepRequests == [true], """
        a model that read the stored opt-in never asked the holder for it: \
        \(spy.displaySleepRequests)
        """)
}

@MainActor
@Test func theDisplayHoldMatchesWhatTheDecisionAskedFor() {
    // The two must never disagree. `desired` is the decision object every
    // guard in this repository asserts against, and the holder is what actually
    // reaches IOKit — so a model that read the setting directly on its way to
    // `acquire` would pin the screen awake while `desired.displaySleepAssertion`
    // still read `false`, which is the exact blind spot §6.1's guard rests on.
    let spy = SpyHolder()
    let model = ServingModel(
        holder: spy, reader: FakeReader(source: .ac, percent: 80),
        health: fixtureHealth(),
        settings: FakeSettings([SettingsKey.holdDisplayAwake: true]))

    model.intent = .serve

    let decided = model.desired
    #expect(decided?.displaySleepAssertion == true)
    #expect(spy.displaySleepRequests.last == decided?.displaySleepAssertion)
}

// MARK: - What the panel says is held

@MainActor
@Test func theServingLineNamesTheDisplayOnlyWhenTheDisplayIsHeld() {
    // The sentence beside the control, and the reason it moved out of
    // `PanelView`: it read "Holding the system awake. The display may still
    // sleep." unconditionally, which is FALSE the moment a user opts in — a
    // false claim in the UI of a product whose pitch is that it tells you the
    // truth about what is keeping your Mac awake. Composed in the view, no
    // check in this package could read it (design §5.4).
    let reader = FakeReader(source: .ac, percent: 80)
    let store = FakeSettings()
    let model = ServingModel(holder: SpyHolder(), reader: reader,
                             health: fixtureHealth(), settings: store)

    // Nothing held at all.
    #expect(model.servingSummary == "Not holding any assertion.")

    // Held, screen free to sleep — the shipped default.
    model.intent = .serve
    #expect(model.isServing == true, "precondition: the machine is held")
    #expect(model.servingSummary == "Holding the system awake. The display may still sleep.")

    // Held, screen held too.
    model.holdDisplayAwake = true
    #expect(model.servingSummary == "Holding the system awake, and the display with it.")

    // And back. The three sentences are distinct, so no one of them can stand
    // in for another.
    model.holdDisplayAwake = false
    #expect(model.servingSummary == "Holding the system awake. The display may still sleep.")
}

@MainActor
@Test func theServingLineNamesTheDisplayHoldAndTheFloorRelease() {
    // Named bug this catches: a wrong or stale SUMMARY STRING. Mutating either
    // literal in `servingSummary` turns this red. That is the whole of its
    // value, and the name now says so.
    //
    // What it does NOT catch, corrected after a mutation proved it: this cannot
    // tell `desired?.displaySleepAssertion` from `holdDisplayAwake`. An earlier
    // name and comment here claimed it caught exactly that substitution. It does
    // not, and no check at this level can. `PowerBroker.decide` grants the
    // display assertion only in the branch that also grants the system hold, and
    // `servingSummary` guards on `isServing` before reading the expression, so
    // the two agree in every reachable state. Planting the substitution left the
    // full suite green — 486 tests, zero failures.
    //
    // The decision-not-the-setting invariant is pinned where it IS falsifiable:
    // `theOffPositionVetoesTheDisplayHoldToo` and
    // `theBatteryFloorReleasesTheDisplayHoldToo` in `PowerBroker_test.swift`.
    let reader = FakeReader(source: .battery, percent: 25)
    let model = ServingModel(
        holder: SpyHolder(), reader: reader, health: fixtureHealth(),
        settings: FakeSettings([SettingsKey.holdDisplayAwake: true]))

    model.intent = .serve
    #expect(model.servingSummary == "Holding the system awake, and the display with it.",
            "precondition: the opt-in reached the panel above the floor")

    reader.set(source: .battery, percent: 14)
    model.refresh()

    #expect(model.holdDisplayAwake == true, "precondition: the setting itself did not change")
    #expect(model.servingSummary == "Not holding any assertion.")
}

@MainActor
@Test func theDisplayLabelsAreTwoDistinctWordsForTheTwoPositions() {
    // The picker's two segments read from here, so a check can see what the
    // control says. Named bug this catches: both segments rendering the same
    // word, which makes the control unusable and which design §5.4 rules out
    // catching on the rendered view.
    #expect(ServingModel.displayLabel(for: true) != ServingModel.displayLabel(for: false))
    #expect(ServingModel.displayLabel(for: false).isEmpty == false)
    #expect(ServingModel.displayLabel(for: true).isEmpty == false)
}

// MARK: - The battery floor is a setting (issue #11)

@MainActor
@Test func aStoredBatteryFloorReachesTheDecision() {
    // Named bug this catches: a model that reads the store and then never hands
    // the value to `HoldController.evaluate`, which takes its own default of
    // `BatteryFloor.default`. The setting would round-trip through the
    // preferences perfectly and change nothing about when the Mac sleeps.
    //
    // 35% is ABOVE the 15 default and BELOW the stored 40, so the two floors
    // give opposite answers here. A model still on the default holds.
    let reader = FakeReader(source: .battery, percent: 35)
    let model = ServingModel(
        holder: SpyHolder(), reader: reader, health: fixtureHealth(),
        settings: FakeSettings([SettingsKey.batteryFloorPercent: 40]))

    model.intent = .serve

    #expect(model.isServing == false,
            "35% cleared a stored 40% floor; the setting never reached the decision")
    // The floor the DECISION used, not the one the model remembers. A model
    // that passed its default while storing 40 would satisfy the line above
    // only by accident and would print the wrong number to the user.
    #expect(model.desired?.suppression == .batteryFloor(percent: 35, floor: 40))
    #expect(model.suppressionAdvisory?.contains("at or below 40%") == true,
            "the panel line quoted the wrong floor: \(model.suppressionAdvisory ?? "nil")")
}

@MainActor
@Test func anUnsetBatteryFloorUsesTheDocumentedDefault() {
    // A fresh install has written nothing. The floor must be the number the
    // README states, and `theBatteryFloorStatedIsTheRealDefault` reads that
    // document against `PowerInputs`'s own default — so these two have to be
    // the same number or the docs describe a floor the app does not enforce.
    let atFloor = ServingModel(holder: SpyHolder(),
                               reader: FakeReader(source: .battery, percent: 15),
                               health: fixtureHealth(), settings: FakeSettings())
    atFloor.intent = .serve
    #expect(atFloor.isServing == false, "an unset floor did not refuse at 15%")

    // The control. Without it a model whose unset floor read as 100 would pass
    // the line above and never hold on battery again.
    let above = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .battery, percent: 16),
                             health: fixtureHealth(), settings: FakeSettings())
    above.intent = .serve
    #expect(above.isServing == true, "an unset floor refused at 16%")

    #expect(above.batteryFloorPercent == BatteryFloor.default)
}

@MainActor
@Test func aStoredZeroIsNotTheSameAsAnUnsetKey() {
    // THE reason `SettingsStoring.integer(forKey:)` answers `Int?`. A model
    // reading `UserDefaults.integer(forKey:)` directly gets 0 for a key nobody
    // ever wrote, and 0 is a legitimate percentage — so a fresh install would
    // silently run with no floor at all.
    //
    // The DISCRIMINATING pair, both read at 11% on battery:
    //   unset    -> 15, so 11% is at or below the floor and the hold is refused;
    //   stored 0 -> bounded to 10, so 11% clears it and the hold stands.
    // A model that folded the two together cannot satisfy both lines.
    //
    // The reading is 11 and not 10 BY NECESSITY: the bounded minimum IS 10, so
    // at a 10% reading `10 <= 10` suppresses under both branches and the pair
    // collapses into two identical refusals that would pass for a model with no
    // distinction at all.
    let unset = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .battery, percent: 11),
                             health: fixtureHealth(), settings: FakeSettings())
    unset.intent = .serve
    #expect(unset.isServing == false, "an unset floor behaved like a stored 0")

    let storedZero = ServingModel(
        holder: SpyHolder(), reader: FakeReader(source: .battery, percent: 11),
        health: fixtureHealth(),
        settings: FakeSettings([SettingsKey.batteryFloorPercent: 0]))
    storedZero.intent = .serve
    #expect(storedZero.isServing == true, "a deliberately stored 0 behaved like an unset key")

    // And the stored 0 is still BOUNDED on the way to the decision, so the
    // lowest floor a user can reach is 10 rather than a floor that never fires.
    // Stated as the positive. `desired?.suppression == nil` is also satisfied by
    // a `desired` that is itself nil, so it would pass for a model that never
    // decided anything.
    #expect(storedZero.desired?.idleSleepAssertion == true)
    let dead = ServingModel(
        holder: SpyHolder(), reader: FakeReader(source: .battery, percent: 5),
        health: fixtureHealth(),
        settings: FakeSettings([SettingsKey.batteryFloorPercent: 0]))
    dead.intent = .serve
    #expect(dead.desired?.suppression == .batteryFloor(percent: 5, floor: 10))
}

@MainActor
@Test func theBatteryFloorIsWrittenToTheStoreWhenTheUserChangesIt() {
    // The write half of persistence. Without it the panel remembers the choice
    // for exactly as long as the app runs.
    let store = FakeSettings()
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .battery, percent: 80),
                             health: fixtureHealth(), settings: store)

    #expect(store.integer(forKey: SettingsKey.batteryFloorPercent) == nil,
            "precondition: nothing was stored before the user touched anything")

    model.batteryFloorPercent = 40
    #expect(store.integer(forKey: SettingsKey.batteryFloorPercent) == 40)
    #expect(model.batteryFloorPercent == 40)
}

@MainActor
@Test func aStoredBatteryFloorIsReadBackAtTheNextLaunch() {
    // The read half, and what "survives a relaunch" means at this layer: a
    // SECOND model over the store the first one wrote starts where the user
    // left it. `SettingsStore_test.swift` proves the value reaches the disk;
    // this proves the model writes it and asks for it again.
    //
    // Named bug this catches: a floor held in a property of the instance that
    // set it. Every check above passes for such a model, because each one sets
    // the value itself before reading it.
    let store = FakeSettings()
    let first = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .battery, percent: 80),
                             health: fixtureHealth(), settings: store)
    first.batteryFloorPercent = 40

    let relaunched = ServingModel(holder: SpyHolder(),
                                  reader: FakeReader(source: .battery, percent: 35),
                                  health: fixtureHealth(), settings: store)
    #expect(relaunched.batteryFloorPercent == 40)

    // Asserted through the DECISION too, not on the property alone. A model
    // that read the store into a field it never passed on would satisfy the
    // line above while the machine kept holding at 35%.
    relaunched.intent = .serve
    #expect(relaunched.isServing == false,
            "the reloaded floor never reached the decision")
}

@MainActor
@Test func changingTheFloorReconcilesImmediatelyRatherThanAtTheNextTick() {
    // A user who raises the floor because the battery is low is asking for the
    // hold to STOP, now. Named bug this catches: a setter that stores the value
    // and waits for the 30-second ticker, which leaves the machine held for up
    // to half a minute after the user asked it not to be.
    let spy = SpyHolder()
    let model = ServingModel(holder: spy,
                             reader: FakeReader(source: .battery, percent: 35),
                             health: fixtureHealth(), settings: FakeSettings())
    model.intent = .serve
    #expect(model.isServing == true, "precondition: 35% cleared the default floor")

    model.batteryFloorPercent = 40

    #expect(model.isServing == false)
    #expect(spy.releaseCount >= 1, "raising the floor released nothing")
}

@MainActor
@Test func everyOfferedFloorSitsInsideThePermittedRange() {
    // What this guard can no longer do, stated so nobody over-trusts it.
    //
    // It used to sweep `choices` asserting `permitted.contains(choice)` and
    // `bounded(choice) == choice`. Those were real while `choices` was the
    // hand-written literal [10, 20, 30, 40, 50] — the literal could name 120.
    // `choices` is now DERIVED, `stride` from `permitted.lowerBound` through
    // `permitted.upperBound`, so both hold BY CONSTRUCTION for every value of
    // `step` and neither can ever fail. Keeping them would be theater: they
    // would report coverage this test no longer has. They are deleted rather
    // than left green, and this paragraph is why their absence is not a gap.
    //
    // What the derivation does NOT give for free is below.
    //
    // THE CONTROL IS A SLIDER, not a picker, since the floor moved into the
    // Preferences window. `choices` describes the STEP-ALIGNED POSITIONS that
    // slider can produce — it is built `in: permitted, step: step`, so the
    // values it yields are `lowerBound + n * step`, which is what `stride`
    // computes. Nothing renders `choices`; it is a derived DESCRIPTION of the
    // control, never a source of truth for it.
    //
    // So both assertions below are properties of the POLICY CONSTANTS, and
    // they survived the picker's deletion because they were never about a
    // picker. The wording was, and that is what changed here.
    #expect(BatteryFloor.choices.isEmpty == false,
            "permitted and step yield no position at all, so the slider can express nothing")

    // 1. The most conservative floor must be REACHABLE. `stride(through:)`
    //    stops short whenever `step` does not divide the range: a step of 7
    //    offers 10…45, so the user can never pick 50 while the app goes on
    //    accepting 50 from `defaults write`. The control would then be unable
    //    to express a floor the product honours, which is the same class of
    //    defect as a default outside the offered set.
    //
    //    What this proves and what it does not. It proves the POLICY property
    //    — `step` divides the range, so `upperBound` sits on a step boundary
    //    and is reachable under any sane rounding. It does NOT prove what
    //    SwiftUI's stepped `Slider` actually snaps to; design §5.4 rules out
    //    asserting on the rendered control, so no check here can watch it. The
    //    rendering rides on the manual acceptance pass.
    #expect(BatteryFloor.choices.last == BatteryFloor.permitted.upperBound,
            """
            the control tops out at \
            \(BatteryFloor.choices.last.map(String.init(describing:)) ?? "nothing"), \
            but the app accepts floors up to \(BatteryFloor.permitted.upperBound). \
            `step` (\(BatteryFloor.step)) does not divide the permitted range.
            """)

    // 2. The shipped default has to be reachable from the control, or a user who
    //    moves off it can never get back.
    #expect(BatteryFloor.choices.contains(BatteryFloor.default),
            "the default \(BatteryFloor.default) is not offered: \(BatteryFloor.choices)")
}

@MainActor
@Test func theFloorLabelsAreDistinctAndNameTheirPercentage() {
    // The slider's READOUT reads from here, so a check can see what the control
    // says — design §5.4 rules out asserting on the rendered view. Named bug
    // this catches: one label for every position, which makes the readout
    // useless and which nothing else in this package could see.
    //
    // It matters MORE for a slider than it did for the picker it replaces. The
    // picker drew every position at once, so a duplicated label was visible on
    // screen; the slider shows one value at a time, and two positions reading
    // "20%" look like a control that has stopped responding to the drag.
    let labels = BatteryFloor.choices.map { ServingModel.floorLabel(for: $0) }
    #expect(Set(labels).count == BatteryFloor.choices.count,
            "two floors share a label: \(labels)")
    #expect(ServingModel.floorLabel(for: 20) == "20%")
}

@MainActor
@Test func theFloorReadoutNamesTheFloorEnforcedAndNotTheOneStored() {
    // Issue #68. The stored floor is UNBOUNDED — reachable by `defaults write`,
    // and reached by every user who chose one under the old `5...100` policy —
    // so a readout built from the setting states a number the product will not
    // honour. Named bug this catches: "1000%" beside a decision made on 50, and
    // "0%" beside one made on 10.
    //
    // The suppression sentence is asserted BESIDE the readout on purpose. The
    // two quote the same floor one line apart in the same window, so the defect
    // that matters is not a wrong string in isolation, it is two surfaces
    // naming different floors for one setting.
    let high = ServingModel(
        holder: SpyHolder(), reader: FakeReader(source: .battery, percent: 45),
        health: fixtureHealth(),
        settings: FakeSettings([SettingsKey.batteryFloorPercent: 1000]))
    high.intent = .serve

    #expect(high.floorReadout == "50%",
            "the readout quoted a floor nothing enforces: \(high.floorReadout)")
    #expect(high.suppressionAdvisory?.contains("at or below 50%") == true,
            "the sentence and the readout disagree: \(high.suppressionAdvisory ?? "nil")")
    // REPORTED, never rewritten. Issue #68 weighed clamping the stored value on
    // read and rejected it: this project does not silently edit a preference a
    // user set. The disagreement is removed by showing the enforced number, not
    // by destroying the stored one.
    #expect(high.batteryFloorPercent == 1000,
            "the readout fix rewrote the user's stored setting")

    // 5% and a stored 0, which is the pair the comment on `refresh()` records:
    // `5 <= 0` is false, so a readout on the raw setting printed "0%" while the
    // decision refused on the bounded 10.
    let low = ServingModel(
        holder: SpyHolder(), reader: FakeReader(source: .battery, percent: 5),
        health: fixtureHealth(),
        settings: FakeSettings([SettingsKey.batteryFloorPercent: 0]))
    low.intent = .serve

    #expect(low.floorReadout == "10%",
            "the readout quoted a floor nothing enforces: \(low.floorReadout)")
    #expect(low.suppressionAdvisory?.contains("at or below 10%") == true,
            "the sentence and the readout disagree: \(low.suppressionAdvisory ?? "nil")")
    #expect(low.batteryFloorPercent == 0,
            "the readout fix rewrote the user's stored setting")
}

@MainActor
@Test func anInRangeStoredFloorIsReadOutUnchanged() {
    // The regression that matters. Every floor a user can actually reach on the
    // slider is inside `BatteryFloor.permitted`, so the fix above is worthless
    // if it moves any of them. Named bug this catches: a readout wired to a
    // floor that has not been evaluated yet, or to the wrong end of a bound —
    // both of which would leave the ordinary case naming a number the user
    // never chose.
    //
    // Literal pairs rather than a `map` over `BatteryFloor.choices`: an
    // expectation computed the way the subject computes it agrees with a broken
    // subject.
    for (stored, expected) in [(10, "10%"), (15, "15%"), (40, "40%"), (50, "50%")] {
        let model = ServingModel(
            holder: SpyHolder(), reader: FakeReader(source: .battery, percent: 80),
            health: fixtureHealth(),
            settings: FakeSettings([SettingsKey.batteryFloorPercent: stored]))
        model.refresh()
        #expect(model.floorReadout == expected,
                "a stored \(stored) read out as \(model.floorReadout)")
    }

    // And the live path: dragging the slider moves the readout on the same
    // pass, not at the next 30-second tick. The setter reconciles, so the floor
    // in force is current by the time the view reads it back.
    let model = ServingModel(
        holder: SpyHolder(), reader: FakeReader(source: .battery, percent: 80),
        health: fixtureHealth(), settings: FakeSettings())
    model.batteryFloorPercent = 30
    #expect(model.floorReadout == "30%",
            "the readout lagged the control: \(model.floorReadout)")
}

@MainActor
@Test func theFloorReadoutNamesTheDefaultUntilTheFirstRefresh() {
    // The LIMIT of reporting instead of re-deriving, pinned rather than left in
    // prose. `HoldController.floorInForce` is `BatteryFloor.default` until the
    // first `evaluate`, and `ServingModel.init` deliberately makes no decision,
    // so a readout drawn before the first `refresh()` names 15 rather than the
    // stored 40.
    //
    // It is also the DISCRIMINATOR against the fix issue #68 forbids: a readout
    // that called `BatteryFloor.bounded` on the stored setting — a third
    // bounding site — would answer "40%" on the first line here and pass every
    // other check in this file. This one goes red on it.
    let model = ServingModel(
        holder: SpyHolder(), reader: FakeReader(source: .battery, percent: 80),
        health: fixtureHealth(),
        settings: FakeSettings([SettingsKey.batteryFloorPercent: 40]))

    #expect(model.floorReadout == "15%",
            "the readout re-derived a floor no decision has used: \(model.floorReadout)")

    // And one refresh heals it, which is what makes the window above narrow
    // rather than permanent: the panel refreshes on appear, `SettingsLink`
    // inside that panel is the route to this window, and the ticker refreshes
    // every 30 seconds regardless.
    model.refresh()
    #expect(model.floorReadout == "40%",
            "the first refresh did not heal the readout: \(model.floorReadout)")
}

@MainActor
@Test func loweringTheFloorDropsTheSentenceThatNamedTheOldOne() {
    // A defect issue #11 CREATES, and the reason `reason(_:stillTrueOf:)` had
    // to change. Before the floor was settable it could not move, so judging a
    // recorded refusal against the floor recorded WITH it was always the same
    // as judging it against the floor in force.
    //
    // Named bug this catches: the panel explaining a refusal under the OLD
    // floor while the machine is held under the NEW one. `lastSuppression`
    // latches and `userToggled(to: .serve)` is the only thing that clears it —
    // so under `.auto`, which is the position the product ships in, the stale
    // record survives the change.
    //
    // `.auto` with a working session, deliberately. Clicking On a second time
    // would clear the record on its way past and prove nothing.
    let reader = FakeReader(source: .battery, percent: 15)
    let model = ServingModel(holder: SpyHolder(), reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.ingest(from: .claudeCode, HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))

    #expect(model.isServing == false, "precondition: the default floor refused at 15%")
    #expect(model.suppressionAdvisory == "At 15% — coffee-bar does not hold at or below 15%.",
            "precondition: the panel explained that refusal")

    model.batteryFloorPercent = 10

    // The machine is now held, so any sentence saying it is not is false.
    #expect(model.isServing == true, "the lowered floor did not let the hold through")
    #expect(model.suppressionAdvisory == nil, """
        the panel explains a refusal under the OLD floor while the machine is \
        held under the new one: \(model.suppressionAdvisory ?? "nil")
        """)
    #expect(model.suppression == nil)
}

@MainActor
@Test func raisingTheFloorRestatesTheSentenceWithTheNewNumber() {
    // The other direction, and the control for the check above. A filter that
    // simply dropped every sentence whenever the floor moved would satisfy that
    // one and leave a user who has just raised the floor with no explanation
    // for the hold that stopped.
    let reader = FakeReader(source: .battery, percent: 25)
    let model = ServingModel(holder: SpyHolder(), reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.ingest(from: .claudeCode, HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))
    #expect(model.isServing == true, "precondition: 25% cleared the default floor")

    model.batteryFloorPercent = 30

    #expect(model.isServing == false)
    // The NEW number, not the old one. The record is rewritten by the
    // suppression this change produced.
    #expect(model.suppressionAdvisory == "At 25% — coffee-bar does not hold at or below 30%.")
}

@MainActor
@Test func theLeftoverSentenceQuotesTheFloorInForceNotTheOneItWasRecordedUnder() {
    // The sentence is a PRESENT-TENSE claim about what coffee-bar does, so the
    // number in it has to be the floor in force. The measured percent stays the
    // reading the decision was made on — that half is deliberate and unchanged.
    //
    // Named bug this catches: a user raises the floor, nothing is running to
    // produce a fresh suppression, and the leftover line keeps quoting the old
    // number — so the change they just made appears not to have taken.
    let reader = FakeReader(source: .battery, percent: 14)
    let model = ServingModel(holder: SpyHolder(), reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    // A refused On click, which leaves a record and no session behind it.
    model.intent = .serve
    #expect(model.intent == .auto, "precondition: the refused click landed back on Auto")
    #expect(model.suppressionAdvisory?.contains("at or below 15%") == true,
            "precondition: the panel explained the refusal under the old floor")

    model.batteryFloorPercent = 30

    // Nothing wants a hold, so no fresh suppression was produced and only the
    // latched record is left. It must still describe the policy in force.
    #expect(model.suppression == .batteryFloor(percent: 14, floor: 30))
    #expect(model.suppressionAdvisory?.contains("at or below 30%") == true,
            "the leftover line quotes a floor nobody is enforcing: \(model.suppressionAdvisory ?? "nil")")
}

@MainActor
@Test func aFloorHandWrittenAboveTheMaximumIsQuotedAsTheOneEnforced() {
    // A regression the issue #11 fix introduced. The DECISION bounds the floor
    // and the SENTENCE did not, so the panel printed the raw setting.
    //
    // Named bug this catches: "coffee-bar does not hold at or below 1000%" — a
    // percentage that cannot exist, which is the exact defect
    // `aFloorAboveOneHundredIsCappedBeforeTheDecisionUsesIt` names in Core. The
    // UI must not put back what the decision took out.
    //
    // 1000 reaches the store only by hand, through `defaults write`. That is
    // still a real user, and the panel is the product's claim about itself.
    let model = ServingModel(
        holder: SpyHolder(), reader: FakeReader(source: .battery, percent: 50),
        health: fixtureHealth(),
        settings: FakeSettings([SettingsKey.batteryFloorPercent: 1000]))

    model.intent = .serve

    #expect(model.isServing == false, "precondition: the bounded floor refused at 50%")
    #expect(model.desired?.suppression == .batteryFloor(percent: 50, floor: 50),
            "precondition: the decision bounded the floor")

    // The panel must agree with the decision it is reporting.
    #expect(model.suppression == .batteryFloor(percent: 50, floor: 50))
    let line = model.suppressionAdvisory ?? ""
    #expect(line.contains("at or below 50%"), "the panel quoted a floor nobody enforced: \(line)")
    #expect(!line.contains("1000%"), "the panel printed a percentage that cannot exist: \(line)")
}

@MainActor
@Test func aFloorHandWrittenBelowTheMinimumStillExplainsTheRefusal() {
    // The other half of the same regression, and the worse half. With the raw
    // setting used as the filter, `3 <= 0` is false, so the whole reason is
    // dropped — while the DECISION refuses on the bounded floor of 10.
    //
    // Named bug this catches: coffee-bar refuses the click, moves the user's
    // control back to Auto on its own, and says NOTHING. `cancelledServe` is
    // gated on the filtered suppression, so the explanation dies with it. That
    // is the silent-snap-back failure `suppressionAdvisory` exists to prevent.
    let model = ServingModel(
        holder: SpyHolder(), reader: FakeReader(source: .battery, percent: 3),
        health: fixtureHealth(),
        settings: FakeSettings([SettingsKey.batteryFloorPercent: 0]))

    model.intent = .serve

    #expect(model.isServing == false, "precondition: the bounded floor refused at 3%")
    #expect(model.desired?.suppression == .batteryFloor(percent: 3, floor: 10),
            "precondition: the decision refused on the bounded floor")
    #expect(model.intent == .auto, "precondition: the refused click snapped back")

    // A control the product moved on the user's behalf, with a reason.
    #expect(model.suppression == .batteryFloor(percent: 3, floor: 10))
    let line = model.suppressionAdvisory ?? ""
    #expect(line.contains("at or below 10%"), "no reason for the refusal: \(line)")
    #expect(line.contains("was refused"),
            "the control snapped back to Auto with no explanation: \(line)")
}

// MARK: - The root helper the panel reports on

// Issue #81. `PrivilegedHelper.state` and `ServingModel.staleHelperAdvisory`
// landed together with a correct verdict and a correct sentence that NOTHING
// called, so the app could detect a stale root binary and tell nobody. These are
// the checks on the wire between them. `AppLayerBoundary_test.swift` holds the
// two views, and `LidClosedPanel_test.swift` holds the copy.
//
// What is asserted HERE is which state the model publishes, when a line appears
// and when it goes away — M1 design §5.4 rules out reading the drawn panel.

/// A source of helper state whose answer can CHANGE between refreshes.
///
/// The states these checks need describe a machine whose root helper is out of
/// date, and the shipping reader cannot be made to produce them here: it
/// resolves the probe beside the RUNNING executable, which under `swift test` is
/// the test binary. `PrivilegedHelperReader_test.swift` drives the real reader
/// over real files, so the read itself is never mocked away — this double stands
/// in for the machine, not for the reader.
private final class StubHelperState: PrivilegedHelperStateProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var answer: PrivilegedHelperState

    init(_ answer: PrivilegedHelperState) { self.answer = answer }

    /// What the machine looks like from now on. A model that re-reads sees this.
    func set(_ next: PrivilegedHelperState) {
        lock.lock()
        defer { lock.unlock() }
        answer = next
    }

    func state() -> PrivilegedHelperState {
        lock.lock()
        defer { lock.unlock() }
        return answer
    }
}

/// The install these checks name.
///
/// FIXED, and never this machine's, for the reason `LidClosedPanel_test.swift`
/// gives about its own: the app derives this path from its own bundle, so a
/// check that read the live value would assert a different string on every Mac.
/// It carries no home directory, because `noTrackedFileCarriesLiveSessionProse`
/// scans every tracked file for the real account name.
private let installedElsewhere = "/Volumes/Spare/CoffeeBar.app/Contents/MacOS/coffee-bar-probe"

@MainActor
@Test func theModelRaisesTheStaleHelperAdvisoryTheSourceReports() throws {
    // Named bug this catches, and it is the whole of issue #81 as v0.2.1 left
    // it: a verdict computed correctly and published nowhere. Delete the
    // `refresh()` line that asks, or the property that derives the sentence, and
    // the app is back to knowing the root binary is old and saying nothing.
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth(),
                             helper: StubHelperState(.stale),
                             settings: FakeSettings())

    // Nothing has been asked yet, so there is nothing to report.
    // `PanelView.onAppear` calls `refresh()`, so this state never reaches the
    // screen — and a model that announced a fault it had not measured would be
    // the same claim-without-evidence this release exists to remove, pointing
    // the other way.
    #expect(model.helperState == nil)
    #expect(model.staleHelperAdvisory(probeAt: installedElsewhere) == nil,
            "the model raised an advisory before it had read anything")

    model.refresh()

    #expect(model.helperState == .stale)

    let line = try #require(model.staleHelperAdvisory(probeAt: installedElsewhere), """
        the model read a stale root helper and raised no line, so the fault \
        reaches the user nowhere
        """)
    #expect(line.contains(ServingModel.privilegedProbePath),
            "the advisory does not name the path that is out of date: \(line)")

    // The PARAMETER reaches the sentence. Named bug: an advisory that ignores
    // what the view handed it and prints the documented disk-image path, which
    // is right for one install in four and names a file a Homebrew user does not
    // have.
    #expect(line.contains(ServingModel.lidClosedInstallCommand(probeAt: installedElsewhere)),
            "the advisory does not carry a command that copies THIS build: \(line)")
    #expect(!line.contains(ServingModel.documentedProbePath), """
        the advisory names the documented disk-image path rather than the one \
        the caller supplied: \(line)
        """)
}

@MainActor
@Test func aCurrentRootHelperAddsNoLineAtAll() {
    // The mirror, and the half that keeps this usable. An advisory nobody can
    // clear is noise the user learns to skip past, and the panel would then be
    // carrying a permanent complaint about a machine that is fine.
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth(),
                             helper: StubHelperState(.current),
                             settings: FakeSettings())
    model.refresh()

    #expect(model.helperState == .current)
    #expect(model.staleHelperAdvisory(probeAt: installedElsewhere) == nil,
            "an up-to-date helper produced a line: \(model.staleHelperAdvisory(probeAt: installedElsewhere) ?? "")")
}

@MainActor
@Test func theStaleHelperAdvisoryClearsOnTheNextRefreshWithoutARelaunch() {
    // Named bug this catches: reading the helper ONCE, in `init`. The user's
    // whole recovery path is to paste the install command the advisory carries,
    // and this app runs for days — a state frozen at launch would still report
    // an old root binary after it had been replaced, which is the same frozen
    // -status defect `theModelRereadsTheSettingsFileOnEveryRefresh` names for
    // the hook file.
    let machine = StubHelperState(.stale)
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth(),
                             helper: machine,
                             settings: FakeSettings())
    model.refresh()
    #expect(model.staleHelperAdvisory(probeAt: installedElsewhere) != nil,
            "precondition: the stale helper is being reported")

    // The user pastes the command while the app is running.
    machine.set(.current)
    model.refresh()

    #expect(model.helperState == .current)
    #expect(model.staleHelperAdvisory(probeAt: installedElsewhere) == nil, """
        the advisory survived the fix it told the user to apply, so pasting the \
        command appears to do nothing until coffee-bar is relaunched
        """)
}

// MARK: - Issue #71c: the advisory the registered helper makes false

// The defect, measured on this machine on 2026-08-17. A signed build with the
// helper registered armed lid-closed mode by clicking the button: the hold was
// granted by the registered helper at pid 60528, and the XPC round trip is in
// the system log. The legacy binary at
// `/Library/PrivilegedHelperTools/coffee-bar-probe` was present, was a DIFFERENT
// build, and was not running — it played no part in the hold whatever.
//
// The window said "lid-closed mode is running an older root binary" and told the
// user to `sudo install` over it. Both halves are false in that state, and
// following the advice re-introduces the manual path issue #71 exists to delete.
//
// The staleness check reads two files and knows nothing about the registration,
// which is correct as far as it goes and is exactly why the answer had to arrive
// from somewhere else.

/// A registered helper whose answer these checks choose, and can change.
///
/// The `true` side is unreachable to this package by construction:
/// `PrivilegedHelperClient.availability()` reads THIS binary's signature, the
/// test runner is linker-signed ad-hoc, and
/// `theRunningBuildReadsItsOwnSignatureRatherThanAssumingOne` measures it
/// answering `.unavailable`. So the state the user was actually in reaches a
/// check only through a double — the same position `StubHelperState` above is in
/// for a stale root binary.
private final class StubRegisteredHelper: RegisteredHelperReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var active: Bool

    init(active: Bool) { self.active = active }

    /// The user clicks the button, or macOS drops the registration.
    func set(active next: Bool) {
        lock.lock()
        defer { lock.unlock() }
        active = next
    }

    func registeredHelperIsActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }
}

@MainActor
@Test func theStaleAdvisoryIsSilentWhileTheRegisteredHelperIsTheOneHoldingTheMachine() {
    // Named bug: the one measured above. The model reads a legacy binary that
    // really is a different build, and says so, on a Mac where that binary is
    // not what lid-closed mode runs.
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth(),
                             helper: StubHelperState(.stale),
                             registration: StubRegisteredHelper(active: true),
                             settings: FakeSettings())
    model.refresh()

    // The premise, pinned. Without this the check below could pass because the
    // machine looks CURRENT, which is a different state and not the one at
    // issue — and the silence would then prove nothing at all.
    #expect(model.helperState == .stale,
            "precondition: the legacy binary is present and is a different build")
    #expect(model.registeredHelperIsActive,
            "precondition: the model asked whether the registered helper is active")

    #expect(model.staleHelperAdvisory(probeAt: installedElsewhere) == nil, """
        the window told a user whose hold is held by the REGISTERED helper that \
        lid-closed mode is running an older root binary, and to sudo-install \
        over it. Both halves are false in that state, and following the advice \
        puts the manual root binary back:
          \(model.staleHelperAdvisory(probeAt: installedElsewhere) ?? "")
        """)
}

@MainActor
@Test func aRegisteredHelperAlsoSilencesTheAdvisoryTheAppCannotVerify() {
    // The rule is about the ADVISORY and not about one of its cases, so the
    // `.unverifiable` sentence goes quiet on the same machines. It names the
    // same legacy path — "it cannot tell whether the probe at … is current" —
    // and points at reinstalling the app to repair a file the registered helper
    // has made irrelevant.
    //
    // Named bug: silencing `.stale` alone. The user then clicks the button,
    // watches "running an older root binary" disappear, and is handed a second
    // paragraph about the same file it was never about.
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth(),
                             helper: StubHelperState(.unverifiable),
                             registration: StubRegisteredHelper(active: true),
                             settings: FakeSettings())
    model.refresh()

    #expect(model.helperState == .unverifiable, "precondition: the comparison did not run")
    #expect(model.staleHelperAdvisory(probeAt: installedElsewhere) == nil, """
        the advisory speaks about the legacy probe on a Mac the registered \
        helper is running:
          \(model.staleHelperAdvisory(probeAt: installedElsewhere) ?? "")
        """)
}

@MainActor
@Test func withoutARegisteredHelperTheStaleAdvisoryIsWordForWordWhatItWas() throws {
    // The other half of the rule, and the half that keeps the fix from being a
    // deletion. On an unsigned build, and on a signed one whose owner has never
    // clicked the button, the `sudo` route is the only route there is and the
    // advisory earns its place.
    //
    // The WHOLE SENTENCE, against a literal. `cad2577` on this branch is the
    // precedent: two `contains(...)` assertions passed over a message that named
    // no action at all, because a substring check cannot see what was dropped
    // around it. This one goes red if a single word of the user-visible string
    // moves — which is the point, since "unchanged, word for word" is the
    // requirement being enforced.
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth(),
                             helper: StubHelperState(.stale),
                             registration: StubRegisteredHelper(active: false),
                             settings: FakeSettings())
    model.refresh()

    #expect(model.registeredHelperIsActive == false,
            "precondition: no registered helper on this machine")

    let line = try #require(model.staleHelperAdvisory(probeAt: installedElsewhere), """
        the fix silenced the advisory on a machine that has no registered helper, \
        so the only route this build has to lid-closed mode is now documented \
        nowhere the user will look
        """)
    #expect(line == """
        The probe at /Library/PrivilegedHelperTools/coffee-bar-probe is not the one in \
        this build, so lid-closed mode is running an older root binary. Replace it with \
        sudo install -o root -g wheel -m 755 \
        /Volumes/Spare/CoffeeBar.app/Contents/MacOS/coffee-bar-probe \
        /Library/PrivilegedHelperTools/coffee-bar-probe and arm it again.
        """, """
        the sentence a user without a registered helper reads has changed:
          \(line)
        """)
}

@MainActor
@Test func armingThroughTheHelperClearsTheStaleAdvisoryOnTheNextRefresh() {
    // Named bug this catches: reading the registration ONCE, in `init`. The
    // click that makes the advisory false happens in the Preferences window of a
    // running app, so a value frozen at launch leaves the user staring at the
    // sentence their click just disproved — the same frozen-state defect
    // `theStaleHelperAdvisoryClearsOnTheNextRefreshWithoutARelaunch` names for
    // the file read beside it.
    let machine = StubRegisteredHelper(active: false)
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth(),
                             helper: StubHelperState(.stale),
                             registration: machine,
                             settings: FakeSettings())
    model.refresh()
    #expect(model.staleHelperAdvisory(probeAt: installedElsewhere) != nil,
            "precondition: the stale legacy binary is being reported")

    // The user clicks "Arm lid-closed mode" and macOS registers the daemon. The
    // legacy binary on disk has not moved and is still a different build.
    machine.set(active: true)
    model.refresh()

    #expect(model.helperState == .stale,
            "precondition: nothing touched the legacy binary; only the registration changed")
    #expect(model.staleHelperAdvisory(probeAt: installedElsewhere) == nil, """
        the advisory outlived the click that made it false, so a user who armed \
        through the helper is told to sudo-install an older root binary until \
        coffee-bar is relaunched:
          \(model.staleHelperAdvisory(probeAt: installedElsewhere) ?? "")
        """)
}

// MARK: - Issue #71k: the two paragraphs above the button

// The defect, observed by the maintainer on signed 0.3.0-rc2 with the helper
// registered. Two paragraphs render above the arm button and both describe the
// product as it was before issue #71 gave that button a mechanism:
//
//   `lidClosedSummary` tells the user to `sudo install` the probe, to arm it
//   themselves with `sudo … arm --ttl`, and — the sharpest of the three — that
//   coffee-bar CANNOT show whether it is armed, so run `sudo … report` to find
//   out. The window is showing them the hold as they read it.
//
//   `powerScopeNote` says a lid-closed hold "is armed by the root command
//   below". It is armed by the button below.
//
// #71c silenced the stale ADVISORY and that silence does reach this window.
// These are two OTHER strings, and nothing here asserted either against the
// registered-helper world — which is how both stayed readable, as this file's
// whole design intends, and went false anyway.

@MainActor
@Test func theLidClosedSummaryIsSilentWhileTheRegisteredHelperIsTheOneHoldingTheMachine() {
    // Named bug this catches: the paragraph rendered on a Mac whose hold the
    // registered helper is already holding. Every clause is then wrong in a
    // different direction — it names a manual install issue #71 exists to
    // delete, an arm command the button has replaced, and a limitation the
    // window disproves a few rows further down.
    //
    // The gate is the same seam #71c uses and is read the same way: the model
    // asks `registration` on every `refresh()` and this reads what it stored.
    // A second reading here would agree with the first until it did not.
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth(),
                             registration: StubRegisteredHelper(active: true),
                             settings: FakeSettings())
    model.refresh()

    // The premise, pinned, for the reason the stale-advisory checks above pin
    // theirs: without it a silence could be a model that never asked.
    #expect(model.registeredHelperIsActive,
            "precondition: the model asked whether the registered helper is active")

    #expect(model.lidClosedSummary(probeAt: installedElsewhere,
                                   holdingFor: 4 * 60 * 60) == nil, """
        the window told a user whose hold the REGISTERED helper is holding to \
        install a root probe by hand, to arm it themselves, and that coffee-bar \
        cannot show them whether it is armed — while the button below and the \
        panel were showing them exactly that:
          \(model.lidClosedSummary(probeAt: installedElsewhere, holdingFor: 4 * 60 * 60) ?? "")
        """)
}

@MainActor
@Test func withoutARegisteredHelperTheLidClosedSummaryIsWordForWordWhatItWas() throws {
    // The other half of the rule, and the half that keeps the fix from being a
    // deletion. On an unsigned build, and on a signed one whose owner has never
    // clicked the button, the `sudo` route is the only route to lid-closed mode
    // and every clause of this paragraph is true.
    //
    // THE WHOLE PARAGRAPH against a literal, for the reason
    // `withoutARegisteredHelperTheStaleAdvisoryIsWordForWordWhatItWas` gives:
    // `cad2577` on this branch passed two `contains(...)` assertions over a
    // message that named no action at all, because a substring check cannot see
    // what was dropped around it. This goes red if a single word moves, which
    // is the point — "unchanged, word for word" is the requirement.
    //
    // FOUR HOURS, which is neither `ProbeVerb.defaultTTLSeconds` nor the
    // ceiling, so the literal below also fails a summary that ignores its own
    // argument — the #74 defect, one indirection along.
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth(),
                             registration: StubRegisteredHelper(active: false),
                             settings: FakeSettings())
    model.refresh()

    #expect(model.registeredHelperIsActive == false,
            "precondition: no registered helper on this machine")

    let summary = try #require(model.lidClosedSummary(probeAt: installedElsewhere,
                                                      holdingFor: 4 * 60 * 60), """
        the fix silenced the paragraph on a machine that has no registered \
        helper, so the only route this build has to lid-closed mode is now \
        documented nowhere the user will look
        """)
    #expect(summary == """
        Lid-closed mode needs root, so you install the probe where root can trust it \
        with sudo install -o root -g wheel -m 755 \
        /Volumes/Spare/CoffeeBar.app/Contents/MacOS/coffee-bar-probe \
        /Library/PrivilegedHelperTools/coffee-bar-probe and arm it yourself with \
        sudo /Library/PrivilegedHelperTools/coffee-bar-probe arm --ttl 14400, which \
        holds for 4 hours. coffee-bar cannot show you whether it is armed — the \
        journal belongs to root and this app runs as you — so run \
        sudo /Library/PrivilegedHelperTools/coffee-bar-probe report to find out.
        """, """
        the paragraph a user without a registered helper reads has changed:
          \(summary)
        """)
}

@MainActor
@Test func armingThroughTheHelperSilencesTheLidClosedParagraphOnTheNextRefresh() {
    // Named bug this catches: reading the registration ONCE, in `init`. The
    // click that makes this paragraph false happens in the Preferences window of
    // a running app, and the paragraph sits directly above the button that was
    // clicked — a value frozen at launch leaves the user reading instructions
    // their own click just disproved, which is what
    // `armingThroughTheHelperClearsTheStaleAdvisoryOnTheNextRefresh` names for
    // the advisory below it.
    let machine = StubRegisteredHelper(active: false)
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth(),
                             registration: machine,
                             settings: FakeSettings())
    model.refresh()
    #expect(model.lidClosedSummary(probeAt: installedElsewhere, holdingFor: 4 * 60 * 60) != nil,
            "precondition: the CLI route is documented on a machine that has only that route")

    // The user clicks "Arm lid-closed mode" and macOS registers the daemon.
    // Nothing else about the machine moved.
    machine.set(active: true)
    model.refresh()

    #expect(model.lidClosedSummary(probeAt: installedElsewhere,
                                   holdingFor: 4 * 60 * 60) == nil, """
        the paragraph outlived the click that made it false, so a user who armed \
        through the button goes on being told to install a root probe by hand \
        until coffee-bar is relaunched:
          \(model.lidClosedSummary(probeAt: installedElsewhere, holdingFor: 4 * 60 * 60) ?? "")
        """)
}

@MainActor
@Test func theScopeNoteNamesNoMechanismForArmingALidClosedHold() {
    // The second paragraph, and it is CORRECTED rather than silenced: what the
    // battery floor governs, that the lid-closed daemon reads no preference of
    // the user's, and how the chosen hold reaches it are all still true and all
    // still worth saying. The MECHANISM claim is what went false.
    //
    // NOT made to vary, and that is the trap this check exists beside.
    // `powerScopeNote` is a static so that it has no instance to read a setting
    // from, which is what makes the substitution
    // `theScopeNoteDescribesTheDaemonWhileTheReadoutDescribesTheUser` refuses
    // UNWRITABLE rather than merely refused. A note gated on the registration
    // would buy a true sentence by dismantling that guarantee, so the repair is
    // a wording true in both worlds.
    //
    // Named bug this catches: the summary above gated and this left alone. The
    // user then clicks the button, watches the paragraph naming the command
    // disappear, and is left with a sentence pointing at "the root command
    // below" — below which there is now nothing.
    let armed = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth(),
                             registration: StubRegisteredHelper(active: true),
                             settings: FakeSettings())
    armed.refresh()

    // The premise, MEASURED rather than asserted in prose: on a machine with a
    // registered helper the paragraph this note pointed at is not rendered at
    // all, so "below" names nothing the reader can see.
    #expect(armed.lidClosedSummary(probeAt: installedElsewhere,
                                   holdingFor: 4 * 60 * 60) == nil,
            "precondition: the lid-closed paragraph is silent while the helper is registered")

    // LOWERCASED, so a mechanism that opens a sentence is caught too.
    let note = ServingModel.powerScopeNote.lowercased()
    for mechanism in ["armed by", "the root command", "command below", "the button"] {
        #expect(!note.contains(mechanism), """
            the scope note says "\(mechanism)", which names ONE of the two ways a \
            lid-closed hold gets armed. This sentence is a static precisely so it \
            cannot vary with the machine, so a mechanism named here is wrong on \
            every machine in the other state. It reads:
            \(ServingModel.powerScopeNote)
            """)
    }

    // The command itself, not only the words that point at it. A note that
    // printed `lidClosedCommand` outright would name the CLI route without any
    // of the phrases above.
    #expect(!ServingModel.powerScopeNote.contains(ServingModel.lidClosedCommand), """
        the scope note prints \(ServingModel.lidClosedCommand). That is the CLI \
        route, and the paragraph that carries it is silent whenever the \
        registered helper is the one holding the machine. It reads:
        \(ServingModel.powerScopeNote)
        """)

    // ANTI-VACUITY, and the substance the correction had to keep. Every
    // assertion above is a negative, and a DELETED note satisfies all of them —
    // which would be issue #73 reopened with the paragraph removed rather than
    // repaired. These two are the note's two claims: which holds the battery
    // floor governs, and the one shape the chosen hold takes on its way to the
    // daemon. The floor VALUE is held by
    // `theScopeNoteNamesTheFloorTheLidClosedDaemonActuallyEnforces`, which
    // derives it by running the ladder rather than by reading the constant back.
    #expect(note.contains("battery floor"), """
        the scope note no longer names the battery floor, so nothing under the \
        two Power sliders says which holds that floor governs. Issue #73. It reads:
        \(ServingModel.powerScopeNote)
        """)
    #expect(ServingModel.powerScopeNote.contains(ProbeVerb.ttlFlag), """
        the scope note no longer names \(ProbeVerb.ttlFlag), so it says nothing \
        about how the Lid-closed hold slider reaches the daemon. It reads:
        \(ServingModel.powerScopeNote)
        """)
}

// MARK: - Issue #74: the lid-closed hold the user chose

@MainActor
@Test func theStoredLidClosedHoldIsWhatTheWindowOffersAndTheDefaultWhenUnset() {
    // The fifth setting, read once in `init` like the other four, and the `Int?`
    // on `integer(forKey:)` earning its keep a second time.
    //
    // Named bug this catches: `?? 0`, or the built-in `integer(forKey:)` whose
    // missing-key answer IS 0. Every user who has never opened Preferences would
    // be handed `--ttl 0` — a hold that has expired before the watchdog's first
    // tick — and lid-closed mode would appear to do nothing whatever, with no
    // error anywhere and nothing in the window to say why.
    let unset = ServingModel(holder: SpyHolder(), reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth(), settings: FakeSettings())
    #expect(unset.lidClosedHoldSeconds == ProbeVerb.defaultTTLSeconds, """
        a user who never chose a hold gets \(unset.lidClosedHoldSeconds) s rather \
        than the shipped \(ProbeVerb.defaultTTLSeconds) s.
        """)

    let chosen = ServingModel(
        holder: SpyHolder(), reader: FakeReader(source: .ac, percent: 80),
        health: fixtureHealth(),
        settings: FakeSettings([SettingsKey.lidClosedHoldSeconds: 5_400]))
    #expect(chosen.lidClosedHoldSeconds == 5_400)
}

@MainActor
@Test func draggingTheHoldSliderSurvivesARelaunch() {
    // A setting that is not written is a control that appears to work and
    // silently forgets, which is the failure `SettingsKey`'s doc comment
    // describes. Two models over ONE store, which is what a relaunch is.
    //
    // Named bug this catches: a setter that updates the backing property and
    // never reaches the store. Every in-session assertion stays green — the
    // getter reads the property it just wrote — and the choice is gone at the
    // next launch.
    let store = FakeSettings()
    #expect(store.integer(forKey: SettingsKey.lidClosedHoldSeconds) == nil,
            "precondition: nothing has written the hold yet")

    let first = ServingModel(holder: SpyHolder(), reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth(), settings: store)
    first.lidClosedHoldSeconds = 5_400
    #expect(store.integer(forKey: SettingsKey.lidClosedHoldSeconds) == 5_400,
            "the setter never reached the store")

    let relaunched = ServingModel(holder: SpyHolder(), reader: FakeReader(source: .ac, percent: 80),
                                  health: fixtureHealth(), settings: store)
    #expect(relaunched.lidClosedHoldSeconds == 5_400,
            "the hold the user chose did not survive a relaunch")
}

@MainActor
@Test func aHoldOutsideThePermittedRangeIsReadOutBoundedAndPrintedBounded() {
    // Issue #68's defect, refused in advance for the second numeric setting.
    // There the stored floor was unbounded, the slider was built over the
    // permitted range, and the decision bounded — three numbers for one setting
    // in one window.
    //
    // Here the stakes are higher than a wrong label: this number is interpolated
    // into a string the user pastes into a ROOT shell. `defaults write … -int
    // -3600` is one command away, and `--ttl -3600` in a sudo command is a
    // product telling its user something has gone wrong without saying what.
    //
    // BOUNDED ONCE, at `holdInForce`. The readout and the printed command both
    // read that one property, so they cannot disagree.
    let store = FakeSettings([SettingsKey.lidClosedHoldSeconds: -3_600])
    let low = ServingModel(holder: SpyHolder(), reader: FakeReader(source: .ac, percent: 80),
                           health: fixtureHealth(), settings: store)

    #expect(low.holdInForce == 1_800, "a stored -3600 reached the window as \(low.holdInForce)")
    #expect(low.holdReadout == "30 minutes", "the readout quoted \(low.holdReadout)")
    #expect(!ServingModel.lidClosedCommand(holdingFor: low.holdInForce).contains("-3600"), """
        the window prints "\(ServingModel.lidClosedCommand(holdingFor: low.holdInForce))" \
        into a root shell.
        """)

    // The far end, which the journal would clamp anyway — and the window must
    // not be the surface that first tells the user about it.
    let high = ServingModel(
        holder: SpyHolder(), reader: FakeReader(source: .ac, percent: 80),
        health: fixtureHealth(),
        settings: FakeSettings([SettingsKey.lidClosedHoldSeconds: 999_999_999]))
    #expect(high.holdInForce == 86_400, "a stored 999999999 reached the window as \(high.holdInForce)")
    #expect(high.holdReadout == "24 hours", "the readout quoted \(high.holdReadout)")

    // REPORTED, never rewritten — the rule issue #68 settled for the floor. This
    // project does not silently edit a preference a user set; it declines to act
    // on it.
    #expect(low.lidClosedHoldSeconds == -3_600, "the window rewrote the user's stored hold")
    #expect(high.lidClosedHoldSeconds == 999_999_999, "the window rewrote the user's stored hold")
}

@MainActor
@Test func anInRangeStoredHoldIsReadOutUnchanged() {
    // The regression half, for the reason `anInRangeStoredFloorIsReadOutUnchanged`
    // exists: every hold a user can reach on the slider is inside
    // `LidClosedHold.permitted`, so the bounding above is worthless if it moves
    // any of them.
    //
    // Literal pairs rather than a computation over `LidClosedHold`: an
    // expectation derived the way the subject derives it agrees with a broken
    // subject.
    for (stored, expected) in [(1_800, "30 minutes"), (28_800, "8 hours"),
                               (45_000, "12 hours 30 minutes"), (86_400, "24 hours")] {
        let model = ServingModel(
            holder: SpyHolder(), reader: FakeReader(source: .ac, percent: 80),
            health: fixtureHealth(),
            settings: FakeSettings([SettingsKey.lidClosedHoldSeconds: stored]))
        #expect(model.holdReadout == expected,
                "a stored \(stored) read out as \(model.holdReadout)")
    }

    // And the live path: dragging the slider moves the readout on the same pass
    // rather than at the next launch.
    let model = ServingModel(holder: SpyHolder(), reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth(), settings: FakeSettings())
    model.lidClosedHoldSeconds = 3_600
    #expect(model.holdReadout == "1 hour", "the readout lagged the control: \(model.holdReadout)")
}

// MARK: - Issue #73: the scope the window claims against the scope the daemon has

/// Every percentage a sentence NAMES, in the order it names them.
///
/// A scan rather than a `contains("15%")`, and the difference is the whole
/// point of the guards below. `contains` answers "is the right number in
/// there somewhere", which a sentence naming TWO floors also satisfies — and a
/// window that quotes two floors for one question is the defect #73 reports
/// with an extra number added. This answers "which numbers does it name", so a
/// second one is visible.
///
/// Hand-written rather than a regex: `%` is the only terminator that matters
/// and the scan is four lines. `\(digits)%` is how `suppressionAdvisory` and
/// `floorLabel(for:)` both spell a charge, so it is the spelling this reads.
private func percentagesNamed(in sentence: String) -> [Int] {
    var found: [Int] = []
    var digits = ""
    for character in sentence {
        if character.isNumber { digits.append(character); continue }
        if character == "%", let value = Int(digits) { found.append(value) }
        digits = ""
    }
    return found
}

/// The charge at which the lid-closed daemon's own ladder ends a hold, OBSERVED
/// by running it rather than read off a constant.
///
/// **This is what makes the guard below more than a restatement.** The obvious
/// spelling is `WatchdogPolicy.default.batteryFloorPercent`, which is the
/// expression the sentence itself interpolates — an expectation derived the way
/// the subject derives it agrees with a broken subject, which is the rule
/// `anInRangeStoredFloorIsReadOutUnchanged` states one screen up. Asking
/// `decide` instead reaches the number by a different route: the policy, the
/// comparison at rung 5, and the ordering of the rungs above it all have to
/// agree with the window before this returns what the window says.
///
/// Concretely, three edits it catches that reading the constant does not:
/// flipping rung 5 from `pct <= floor` to `pct < floor` (the daemon then ends
/// holds at one percent lower than the window states), moving rung 5 below the
/// TTL, and giving `WatchdogService` a policy of its own. `main.swift` builds
/// that service with no `policy:` argument, so `.default` here is the policy
/// the shipped probe runs under.
///
/// `nil` when NO charge ends a hold, which is a failure and not a shrug: a
/// ladder that never reverts on battery is a floor that does not exist, and the
/// guard `#require`s a value rather than passing over one.
private func floorTheWatchdogLadderEnforces() -> Int? {
    let armedAt = Date(timeIntervalSince1970: 1_000_000)
    let armedAtMonotonic: TimeInterval = 10_000
    let record = JournalRecord(
        intent: .sleepDisabled, priorValue: false,
        setAt: armedAt, setAtMonotonic: armedAtMonotonic,
        bootSessionID: "1BE0B007-0000-4000-8000-000000000001",
        ttlSeconds: 900,
        armedBy: ArmProvenance(pid: 1, binaryPath: "/x", uid: 501))
    // Ten seconds into a fifteen-minute hold, wall and monotonic frames in
    // step, heartbeat fresh, thermal nominal: every rung above and below the
    // floor is satisfied, so rung 5 is the only one that can answer.
    let now = armedAt.addingTimeInterval(10)
    let endsTheHold = (0...100).filter { percent in
        CoffeeBarCore.decide(
            WatchdogInputs(journal: record, now: now,
                           monotonicNow: armedAtMonotonic + 10,
                           lastHeartbeat: now,
                           isBootEvaluation: false, thermal: .nominal,
                           batteryPercent: percent, onBattery: true),
            policy: .default) == .revert(.batteryFloor)
    }
    // The HIGHEST charge that still reverts is the floor. `PowerBroker` and
    // rung 5 both suppress at `percent <= floor`, so the boundary charge is the
    // floor itself rather than one below it.
    return endsTheHold.max()
}

@MainActor
@Test func theScopeNoteNamesTheFloorTheLidClosedDaemonActuallyEnforces() throws {
    // ISSUE #73, AND THE HARD HALF OF IT. The window's battery slider reads as
    // though it governs every hold; it governs none of the lid-closed one. The
    // remedy is a sentence that says so, and a sentence is worth nothing if it
    // can go on naming 15% after the daemon has moved to 20 — that is the same
    // defect one indirection along, and it would ship green.
    //
    // Named bug this catches: the scope note written with a literal. `"…the
    // built-in floor of 15%…"` is the shortest way to write this sentence, it
    // is correct on the day it is written, and `BatteryFloor.default` is a
    // constant with an editable value that four other call sites already derive
    // from. The moment somebody raises it, this window states a floor no part of
    // the product enforces — in the one paragraph whose entire job is to say
    // what the daemon actually does.
    let enforced = try #require(floorTheWatchdogLadderEnforces(), """
        no battery charge from 0 to 100 makes the watchdog ladder end a hold \
        under WatchdogPolicy.default, so the floor the Preferences window \
        describes is not a floor the daemon has. Either rung 5 stopped firing \
        or the policy lost its floor; the window's sentence is wrong either way.
        """)

    let claimed = percentagesNamed(in: ServingModel.powerScopeNote)

    // EXACTLY ONE, and the equality is against a one-element array rather than
    // a `first ==`. A sentence that names two floors is the failure this shape
    // catches and a `contains`/`first` cannot: quoting the user's own setting
    // beside the built-in one puts two answers to one question in one caption,
    // which is #73 restated rather than closed.
    #expect(claimed == [enforced], """
        the Preferences window names the floors \(claimed) while the watchdog \
        ladder ends a hold at \(enforced)%. The window is claiming a scope the \
        daemon does not have, which is the whole of issue #73. Derive the number \
        from WatchdogPolicy.default rather than writing it out.
        """)
}

@MainActor
@Test func theScopeNoteDescribesTheDaemonWhileTheReadoutDescribesTheUser() throws {
    // The SHORTER fix, refused. Building the note from `batteryFloorPercent`
    // makes the sentence agree with the slider it sits under, reads as correct
    // in every screenshot, and restores exactly the lie #73 reports: the window
    // would announce that a lid-closed hold ends at the floor the user dragged
    // to while the daemon went on ending it at the built-in one.
    //
    // Named bug this catches: that substitution. It is invisible to the guard
    // above whenever the user has left the floor on its default, which is the
    // state every developer's machine is in.
    //
    // A floor CHOSEN to differ from the daemon's rather than a literal 10:
    // under a `BatteryFloor.default` of 10 a hard-coded pair would agree by
    // accident and this guard would report a defect that is not there.
    let chosen = try #require(BatteryFloor.choices.first {
        $0 != WatchdogPolicy.default.batteryFloorPercent
    }, "every floor the control offers equals the daemon's, so this cannot discriminate")

    let model = ServingModel(
        holder: SpyHolder(), reader: FakeReader(source: .battery, percent: 80),
        health: fixtureHealth(), settings: FakeSettings())
    model.batteryFloorPercent = chosen

    // The two surfaces sit a few points apart in one window and they must
    // DISAGREE, which is the disclosure this task exists to make. Asserting the
    // readout too is what stops the check passing on a model that never took
    // the setting.
    #expect(model.floorReadout == "\(chosen)%",
            "the readout did not take the user's floor: \(model.floorReadout)")
    #expect(!ServingModel.powerScopeNote.contains(model.floorReadout), """
        the scope note quotes \(model.floorReadout), which is the floor the USER \
        chose. That number governs the holds coffee-bar runs itself and governs \
        nothing the root daemon does, so a note carrying it tells the user the \
        lid-closed hold obeys a setting it has never read.
        """)

    // THE SECOND SLIDER'S SCOPE, which #74 made urgent: the window now shows a
    // control labelled "Lid-closed hold" directly under the battery floor, and
    // a note explaining only the floor reads as confirming that the two are one
    // group. The route that hold actually takes to the daemon is the `--ttl` of
    // a command the user types, and naming it is what separates the two.
    //
    // `ProbeVerb.ttlFlag` and never the literal, for the reason
    // `theTTLFlagThePrintedCommandUsesIsTheOneTheBinaryParses` gives about the
    // command itself: a flag renamed on one side leaves this paragraph
    // describing a route the binary no longer offers.
    #expect(ServingModel.powerScopeNote.contains(ProbeVerb.ttlFlag), """
        the scope note never names \(ProbeVerb.ttlFlag), so it says nothing \
        about how the Lid-closed hold slider above it reaches the daemon. A note \
        that scopes only the battery floor leaves the second control under a \
        lid-closed heading with its scope still unstated.
        """)
}
