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

// MARK: - The product's central difference

@MainActor
@Test func theModelNeverRequestsADisplaySleepAssertion() throws {
    // Design §6.1: letting the display sleep while the machine stays awake is
    // what separates coffee-bar from `caffeinate -d`. The invariant is asserted
    // on the decision the model acts on, so a future change that starts asking
    // for the display assertion has to set this field and goes red here.
    let reader = FakeReader(source: .battery, percent: 50)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader)

    model.serving = true
    let held = try #require(model.desired)
    #expect(held.idleSleepAssertion == true)
    #expect(held.displaySleepAssertion == false)

    model.serving = false
    let stopped = try #require(model.desired)
    #expect(stopped.idleSleepAssertion == false)
    #expect(stopped.displaySleepAssertion == false)

    model.serving = true
    reader.set(source: .battery, percent: 19)
    model.refresh()
    let suppressed = try #require(model.desired)
    #expect(suppressed.suppression == .batteryFloor(percent: 19, floor: 20))
    #expect(suppressed.idleSleepAssertion == false)
    #expect(suppressed.displaySleepAssertion == false)
}
