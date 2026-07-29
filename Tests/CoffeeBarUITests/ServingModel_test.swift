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
    let model = ServingModel(holder: SpyHolder(), reader: reader, health: fixtureHealth())

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
    let model = ServingModel(holder: SpyHolder(), reader: reader, health: fixtureHealth())

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
    // the floor refuses drops the CONTROLLER's intent to `.stop`, so a model
    // holding its own copy still reports `.serve` at the end.
    //
    // Named bug 2: a setter that forwards but never calls `refresh()`. The
    // control moves, IOKit is never told, and nothing happens until the
    // 30-second ticker catches up — up to half a minute of a panel that
    // disagrees with the machine.
    let reader = FakeReader(source: .ac, percent: 80)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader, health: fixtureHealth())

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
    #expect(model.intent == .stop,
            "the model reported its own copy of the intent, not the controller's")
}

// MARK: - The control reaches the assertion

@MainActor
@Test func togglingServingOnAcquiresTheAssertion() {
    let reader = FakeReader(source: .ac, percent: 80)
    let spy = SpyHolder()
    let model = ServingModel(holder: spy, reader: reader, health: fixtureHealth())

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
    let model = ServingModel(holder: spy, reader: reader, health: fixtureHealth())

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
    let model = ServingModel(holder: spy, reader: reader, health: fixtureHealth())

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
    let model = ServingModel(holder: spy, reader: reader, health: fixtureHealth())

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
    let model = ServingModel(holder: spy, reader: reader, health: fixtureHealth())

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
    let model = ServingModel(holder: spy, reader: reader, health: fixtureHealth())

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
    let model = ServingModel(holder: spy, reader: reader, health: fixtureHealth())

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
    let model = ServingModel(holder: spy, reader: reader, health: fixtureHealth())

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
    let model = ServingModel(holder: spy, reader: reader, health: fixtureHealth())

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
    let model = ServingModel(holder: spy, reader: reader, health: fixtureHealth())

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
    let model = ServingModel(holder: spy, reader: reader, health: fixtureHealth(),
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
                                 reader: FakeReader(source: .ac, percent: 80), health: fixtureHealth(),
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
                             reader: FakeReader(source: .ac, percent: 80), health: fixtureHealth(),
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
    let model = ServingModel(holder: spy, reader: reader, health: fixtureHealth())

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
                             health: fixtureHealth("missing-stop.json"))

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
                             health: fixtureHealth("definitely-not-here.json"))

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
                             health: HookHealthReader(settingsURL: settings))
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
                             health: fixtureHealth("wired.json"))

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
                             health: fixtureHealth("missing-two.json"))

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
                             health: fixtureHealth("definitely-not-here.json"))

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
                             health: fixtureHealth("missing-two.json"))
    model.refresh()

    let advisory = try #require(model.hookAdvisory)

    #expect(advisory.contains("settings.json"),
            "the advisory must name the file it actually inspected")
    #expect(advisory.lowercased().contains("not receiving") == false,
            "claims events are not arriving, which a file read cannot establish: \(advisory)")
}
