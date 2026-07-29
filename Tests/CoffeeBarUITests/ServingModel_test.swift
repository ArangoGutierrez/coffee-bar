// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import CoffeeBarCore
import CoffeeBarPower
@testable import CoffeeBarUI

// MARK: - Test doubles

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

    @discardableResult
    func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        acquires += 1
        return true
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        releases += 1
    }
}

// MARK: - The toggle reaches the assertion

@MainActor
@Test func togglingServingOnAcquiresTheAssertion() {
    let reader = FakeReader(source: .ac, percent: 80)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader)

    // Precondition: nothing is held before the user asks for anything.
    #expect(model.isServing == false)
    #expect(spy.acquireCount == 0)

    model.serving = true

    #expect(model.isServing == true)
    #expect(spy.acquireCount == 1)
}

@MainActor
@Test func togglingServingOffReleasesTheAssertion() {
    let reader = FakeReader(source: .ac, percent: 80)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader)

    model.serving = true
    #expect(model.isServing == true)
    #expect(spy.releaseCount == 0)

    model.serving = false

    #expect(model.isServing == false)
    #expect(spy.releaseCount >= 1)
}

// MARK: - The battery floor

@MainActor
@Test func crossingTheBatteryFloorReleasesTheAssertion() {
    // 21% holds, 19% does not. Named bug this catches: a `refresh()` that
    // updates `isServing` from the decision but never tells the holder, so the
    // switch reads off while the machine is still pinned awake by a live IOKit
    // assertion — exactly the failure a user cannot see and cannot undo.
    let reader = FakeReader(source: .battery, percent: 21)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader)

    model.serving = true
    #expect(model.isServing == true)
    #expect(spy.releaseCount == 0)

    reader.set(source: .battery, percent: 19)
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
    let reader = FakeReader(source: .battery, percent: 21)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader)

    model.serving = true
    #expect(spy.acquireCount == 1)

    reader.set(source: .battery, percent: 19)
    model.refresh()
    #expect(model.isServing == false)

    reader.set(source: .battery, percent: 21)
    model.refresh()

    #expect(model.isServing == false)
    #expect(spy.acquireCount == 1)
}

// MARK: - What the panel is told

@MainActor
@Test func theSuppressionLineNamesTheMeasuredPercent() {
    // Design §5.4: the reason is asserted on the enum, never on rendered text.
    let reader = FakeReader(source: .battery, percent: 21)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader)

    model.serving = true
    reader.set(source: .battery, percent: 19)
    model.refresh()

    #expect(model.suppression == .batteryFloor(percent: 19, floor: 20))

    // The line reports the reading that RELEASED the hold, not the newest one.
    // Named bug this catches: publishing the current sample instead of the
    // latch. The battery drains on to 12% while nothing is held, and the panel
    // then reads "Released at 12%" — a release that never happened.
    reader.set(source: .battery, percent: 12)
    model.refresh()

    #expect(model.suppression == .batteryFloor(percent: 19, floor: 20))
    #expect(model.reading.percent == 12)
}

@MainActor
@Test func theSuppressionLineSurvivesAtExactlyTheFloor() {
    // The boundary, where the panel and the broker must agree. `PowerBroker`
    // suppresses at `percent <= floor`, so 20% releases the hold. The filter in
    // `ServingModel.reason` has to use the same comparison.
    //
    // Named bug this catches: `percent < floor` in that filter. The battery
    // sits at exactly 20%, the switch refuses to stay on, and the panel drops
    // the one sentence that says why. The user gets a refusal with no reason.
    let reader = FakeReader(source: .battery, percent: 21)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader)

    model.serving = true
    #expect(model.isServing == true)

    reader.set(source: .battery, percent: 20)
    model.refresh()

    #expect(model.isServing == false)
    #expect(model.suppression == .batteryFloor(percent: 20, floor: 20))
}

@MainActor
@Test func theSuppressionLineSurvivesARecoveryToExactlyTheFloor() {
    // The filter compares the NEWEST reading against the FLOOR. Every other
    // filter test here latches at 19 with floor 20, or at 20 with floor 20, so
    // the latched percent and the floor are either equal or one apart and no
    // reading ever lands between them. That leaves the region
    // `latched < reading <= floor` — here the single value 20 after a release
    // at 19 — untested, and it is the only region where the two operands
    // disagree.
    //
    // Named bug this catches: `percent <= latched` in place of
    // `percent <= floor`. The hold releases at 19%, the battery recovers a
    // point to 20%, and the line vanishes — but 20% is still at the floor, so
    // the switch goes on refusing. The user gets a refusal with no reason,
    // which is the same defect `theSuppressionLineSurvivesAtExactlyTheFloor`
    // catches from the side where the reading crosses the floor directly.
    let reader = FakeReader(source: .battery, percent: 21)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader)

    model.serving = true
    #expect(model.isServing == true)

    reader.set(source: .battery, percent: 19)
    model.refresh()
    // Precondition: the latch is BELOW the floor, so the two operands differ
    // for the reading below. Without it this test repeats the equal-operand
    // fixtures it exists to complement.
    #expect(model.suppression == .batteryFloor(percent: 19, floor: 20))
    #expect(model.isServing == false)

    reader.set(source: .battery, percent: 20)
    model.refresh()

    // Still at or below the floor, so the reason is still true and still shown.
    // It names the reading that RELEASED the hold, not the newest one.
    #expect(model.suppression == .batteryFloor(percent: 19, floor: 20))
    #expect(model.reading.percent == 20)
    // And the switch still refuses, which is what makes a missing line a bug
    // rather than a cosmetic difference.
    #expect(model.isServing == false)
}

@MainActor
@Test func theSuppressionLineClearsOnACPower() {
    // The line explains a condition that is still true. Once the machine is
    // back on AC it is no longer true, so the line goes. The latch does not:
    // `isServing` stays false until the user toggles again.
    let reader = FakeReader(source: .battery, percent: 21)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader)

    model.serving = true
    reader.set(source: .battery, percent: 19)
    model.refresh()
    // Precondition: without a line to clear, the assertion below would hold for
    // a model that never publishes one at all.
    #expect(model.suppression != nil)

    reader.set(source: .ac, percent: 19)
    model.refresh()

    #expect(model.suppression == nil)
    #expect(model.isServing == false)
}

@MainActor
@Test func theSuppressionLineClearsOnePointAboveTheFloor() {
    // The mirror of `theSuppressionLineSurvivesAtExactlyTheFloor`, at the first
    // percentage the filter must let go of. `PowerBroker` suppresses at
    // `percent <= floor`, so 21% is above the floor and the line must clear.
    //
    // Named bug this catches: `percent <= floor + 1` in the filter. The macOS
    // battery reading is an estimate and does climb a point or two as the load
    // falls, with no charger attached. The hold releases at 19%, the reading
    // recovers to 21%, and the panel keeps showing "At 19% — coffee-bar does
    // not hold at or below 20%" beside a battery line that reads 21%. That is
    // the stale-reason defect this filter exists to prevent, from the side the
    // 19% -> 40% test cannot see: 40% is twenty points clear of the floor, so a
    // one-point error stays green there.
    let reader = FakeReader(source: .battery, percent: 21)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader)

    model.serving = true
    reader.set(source: .battery, percent: 19)
    model.refresh()
    // Precondition: without a line to clear, the assertion below would hold for
    // a model that never publishes one at all.
    #expect(model.suppression == .batteryFloor(percent: 19, floor: 20))

    reader.set(source: .battery, percent: 21)
    model.refresh()

    #expect(model.suppression == nil)
    #expect(model.reading.percent == 21)
    #expect(model.isServing == false)
}

@MainActor
@Test func theSuppressionLineClearsWhenTheBatteryRisesAboveTheFloor() {
    let reader = FakeReader(source: .battery, percent: 21)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader)

    model.serving = true
    reader.set(source: .battery, percent: 19)
    model.refresh()
    #expect(model.suppression != nil)

    reader.set(source: .battery, percent: 40)
    model.refresh()

    #expect(model.suppression == nil)
    #expect(model.isServing == false)
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
                                 reader: FakeReader(source: .ac, percent: 80))
        model.startMonitoring(interval: 0.01)
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
    // `Tests/CoffeeBarCoreTests/PowerBroker_test.swift:29` guards it there
    // across every input combination.
    let reader = FakeReader(source: .battery, percent: 50)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader)

    model.serving = true
    let held = try #require(model.desired)
    #expect(held.idleSleepAssertion == model.isServing)
    #expect(held.idleSleepAssertion == true)
    #expect(held.displaySleepAssertion == false)

    model.serving = false
    let stopped = try #require(model.desired)
    #expect(stopped.idleSleepAssertion == model.isServing)
    #expect(stopped.idleSleepAssertion == false)
    #expect(stopped.displaySleepAssertion == false)

    model.serving = true
    reader.set(source: .battery, percent: 19)
    model.refresh()
    let suppressed = try #require(model.desired)
    #expect(suppressed.idleSleepAssertion == model.isServing)
    #expect(suppressed.suppression == .batteryFloor(percent: 19, floor: 20))
    #expect(suppressed.idleSleepAssertion == false)
    #expect(suppressed.displaySleepAssertion == false)
}
