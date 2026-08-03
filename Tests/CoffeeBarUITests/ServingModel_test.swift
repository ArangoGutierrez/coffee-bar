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
    func start(onEvent: @escaping @Sendable (HookEvent) -> Void) throws {}
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
    reader.set(source: .battery, percent: 19)
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
    // 21% holds, 19% does not. Named bug this catches: a `refresh()` that
    // updates `isServing` from the decision but never tells the holder, so the
    // switch reads off while the machine is still pinned awake by a live IOKit
    // assertion — exactly the failure a user cannot see and cannot undo.
    let reader = FakeReader(source: .battery, percent: 21)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
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
    let model = ServingModel(holder: spy, reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
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
    let model = ServingModel(holder: spy, reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
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
    let model = ServingModel(holder: spy, reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
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
    let model = ServingModel(holder: spy, reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
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
    let model = ServingModel(holder: spy, reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
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
    let model = ServingModel(holder: spy, reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
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
    let model = ServingModel(holder: spy, reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
    reader.set(source: .battery, percent: 19)
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
    // The reason `startMonitoring` exists at all. The doc comment at
    // `ServingModel.swift:91` puts it plainly: `MenuBarExtra` with
    // `.menuBarExtraStyle(.window)` builds its content only while the panel is
    // open, so a floor enforced only by the panel does not enforce the floor.
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
    let reader = FakeReader(source: .battery, percent: 21)
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
    reader.set(source: .battery, percent: 19)

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
    #expect(model.suppression == .batteryFloor(percent: 19, floor: 20),
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
    // doc comment at `ServingModel.swift:107` names a repeat call on the same
    // instance and closes it with `timer?.invalidate()`; that line was closed
    // in code and open in the suite.
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
    // `Tests/CoffeeBarCoreTests/PowerBroker_test.swift:29` guards it there
    // across every input combination.
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
    reader.set(source: .battery, percent: 19)
    model.refresh()
    let suppressed = try #require(model.desired)
    #expect(suppressed.idleSleepAssertion == model.isServing)
    #expect(suppressed.suppression == .batteryFloor(percent: 19, floor: 20))
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
    let model = ServingModel(holder: SpyHolder(),
                             reader: FakeReader(source: .ac, percent: 80),
                             health: fixtureHealth("definitely-not-here.json"),
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
    let reader = FakeReader(source: .battery, percent: 19)
    let model = ServingModel(holder: SpyHolder(), reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve

    #expect(model.intent == .auto, "the I4 fix must still return the control to the standing position")
    #expect(model.suppressionAdvisory == """
        At 19% — coffee-bar does not hold at or below 20%. Your On click was \
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
    let reader = FakeReader(source: .battery, percent: 19)
    let model = ServingModel(holder: SpyHolder(), reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.ingest(HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))

    #expect(model.intent == .auto, "no click happened")
    #expect(model.suppression == .batteryFloor(percent: 19, floor: 20),
            "precondition: without a live suppression there is no sentence to get wrong")
    #expect(model.suppressionAdvisory == "At 19% — coffee-bar does not hold at or below 20%.")
}

@MainActor
@Test func theRefusalSentenceGoesWhenTheBatteryRecovers() {
    // The refusal claim must not outlive the condition. It goes exactly when the
    // orange line goes.
    //
    // Named bug this catches: latching the refusal outside the filter in
    // `reason(_:stillTrueOf:)`. The battery recovers, the floor stops refusing
    // anything, and the panel goes on telling the user their click was refused.
    let reader = FakeReader(source: .battery, percent: 19)
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

    reader.set(source: .battery, percent: 19)
    model.refresh()

    #expect(model.isServing == false, "precondition: the floor released the hold")
    #expect(model.intent == .auto)
    #expect(model.suppressionAdvisory == """
        At 19% — coffee-bar does not hold at or below 20%. coffee-bar released \
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

    reader.set(source: .battery, percent: 19)
    model.refresh()

    #expect(model.intent == .stop, "the veto survives a released hold")
    #expect(model.suppressionAdvisory == """
        At 19% — coffee-bar does not hold at or below 20%. coffee-bar released \
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

    reader.set(source: .battery, percent: 19)
    model.refresh()

    #expect(model.suppressionAdvisory?.contains("released the hold") == false,
            "claims a hold was released when none was ever taken: \(model.suppressionAdvisory ?? "nil")")
    #expect(model.suppressionAdvisory == """
        At 19% — coffee-bar does not hold at or below 20%. Your On click was \
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

    model.ingest(HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))
    model.intent = .serve
    #expect(model.isServing == true, "precondition: an earlier On click asked for, and got, a hold")

    // Back to Auto. The working session keeps the machine held, so the hold
    // that outlives this click belongs to `.auto` and not to the click.
    model.intent = .auto
    #expect(model.isServing == true, "precondition: .auto holds the machine for the session")

    // The reading falls, and the user clicks On before any refresh sees it.
    reader.set(source: .battery, percent: 19)
    model.intent = .serve

    #expect(model.isServing == false)
    #expect(model.suppressionAdvisory?.contains("released the hold") == false,
            "credits .auto's hold to a click that never held: \(model.suppressionAdvisory ?? "nil")")
    #expect(model.suppressionAdvisory == """
        At 19% — coffee-bar does not hold at or below 20%. Your On click was \
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
    let reader = FakeReader(source: .battery, percent: 19)
    let model = ServingModel(holder: SpyHolder(), reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve
    #expect(model.suppressionAdvisory?.contains("was refused") == true,
            "precondition: the first refusal reached the panel")

    model.intent = .serve

    #expect(model.intent == .auto)
    #expect(model.suppressionAdvisory == """
        At 19% — coffee-bar does not hold at or below 20%. Your On click was \
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
        At 15% — coffee-bar does not hold at or below 20%. Your On click was \
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
    let reader = FakeReader(source: .battery, percent: 19)
    let model = ServingModel(holder: SpyHolder(), reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.ingest(HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))
    model.intent = .serve

    let refusal = """
        At 19% — coffee-bar does not hold at or below 20%. Your On click was \
        refused, so the control is back on Auto.
        """
    #expect(model.suppressionAdvisory == refusal, "precondition: the refusal reached the panel")

    // The next hook event. The session is still working, so the floor refuses a
    // hold this user never asked for — and that must not speak for their click.
    model.ingest(HookEvent(hookEventName: "PreToolUse", sessionID: "s1"))
    #expect(model.suppression == .batteryFloor(percent: 19, floor: 20),
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
    // for the reason. `PowerBroker` suppresses at `percent <= floor`, so 20%
    // refuses the click, and the rule that decides how long the record lives has
    // to use the same comparison.
    //
    // Named bug this catches: `percent < floor` in that rule. It throws the
    // record away in the very call that wrote it, so the user clicks On at
    // exactly 20%, the control snaps back to Auto on its own, and the one
    // sentence that says why is missing — while every check at 19% stays green.
    let reader = FakeReader(source: .battery, percent: 20)
    let model = ServingModel(holder: SpyHolder(), reader: reader,
                             health: fixtureHealth(), settings: FakeSettings())

    model.intent = .serve

    let refusal = """
        At 20% — coffee-bar does not hold at or below 20%. Your On click was \
        refused, so the control is back on Auto.
        """
    #expect(model.intent == .auto)
    #expect(model.suppressionAdvisory == refusal)

    // And it survives the next refresh at that same reading. The click itself
    // cannot test the boundary: `userToggled` clears `lastSuppression`, so the
    // rule that ends the episode has no record to judge on the very call that
    // writes one. Only a LATER reading puts `percent > floor` to the test, and
    // 20% is the one value where `>` and `>=` disagree.
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
    reader.set(source: .battery, percent: 21)
    model.refresh()
    #expect(model.suppressionAdvisory == nil, "precondition: the episode ended")

    // A later drain, days on. Nothing was clicked in between.
    reader.set(source: .battery, percent: 19)
    model.refresh()

    #expect(model.cancelledServe == nil)
    // The battery half of the line returns, and that half is correct: it names
    // the reading the DECISION was made on, which is what
    // `theSuppressionLineNamesTheMeasuredPercent` pins. Only the claim about the
    // user's click is stale, so only that claim goes.
    #expect(model.suppressionAdvisory == "At 5% — coffee-bar does not hold at or below 20%.")
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
    // segment again — and that write arrives before any refresh sees 19%.
    reader.set(source: .battery, percent: 19)
    model.intent = .serve

    #expect(model.isServing == false, "precondition: the floor released the hold")
    #expect(model.intent == .auto)
    #expect(model.suppressionAdvisory == """
        At 19% — coffee-bar does not hold at or below 20%. coffee-bar released \
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

    reader.set(source: .battery, percent: 19)
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

    let decided = try? #require(model.desired)
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

    reader.set(source: .battery, percent: 19)
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
