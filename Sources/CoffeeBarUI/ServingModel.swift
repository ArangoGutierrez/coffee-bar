// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import CoffeeBarCore
import CoffeeBarPower

// `import Observation` is required: the `@Observable` macro lives there. The
// POC got it transitively from `import SwiftUI` in the same file. This file
// has no SwiftUI import, so it must ask for Observation directly.

/// Wires the reader and the controller to the assertion.
///
/// This type holds no policy. It samples power, asks `HoldController` what the
/// state should be, and makes IOKit match. Every decision lives in
/// `CoffeeBarCore`.
@MainActor
@Observable
public final class ServingModel {
    private let holder: any AssertionHolding
    private let reader: any PowerReadingProviding
    private let health: HookHealthReader
    private var controller = HoldController()

    /// The repeating refresh installed by `startMonitoring`.
    ///
    /// Internal `private(set)` for the same reason `desired` is: the one thing
    /// worth asserting about this timer is that it is not still live after the
    /// model goes away, and a test cannot see that through a `private` handle.
    /// No production code outside this type reads it, so nothing here is
    /// `public`.
    @ObservationIgnored private(set) var timer: Timer?

    /// Whether an assertion is held right now. Reflects what actually happened,
    /// not what was asked for.
    public private(set) var isServing = false

    /// The newest power sample, for the panel's battery line.
    public private(set) var reading: PowerReading

    /// Why the hold is not running, when that reason is still true of the
    /// newest reading. `nil` otherwise — see `refresh()`.
    public private(set) var suppression: HoldSuppression?

    /// The state `refresh()` last reconciled to, or `nil` before the first
    /// `refresh()`.
    ///
    /// Exposed for the same reason `DesiredPowerState.displaySleepAssertion`
    /// exists at all: the "never hold the display awake" invariant is asserted
    /// on the decision object, so a change that starts asking for a display
    /// assertion has to set that field and goes red immediately.
    ///
    /// Internal, not `public`. No production code reads it — the test target
    /// gets at it through `@testable import CoffeeBarUI`, so widening the
    /// module's public surface for a test would buy nothing.
    private(set) var desired: DesiredPowerState?

    /// Whether the user's Claude Code hooks still point at our socket.
    ///
    /// `.unreadable` until the first `refresh()`, which is what "not read yet"
    /// looks like here. Nothing renders it before then: `PanelView.onAppear`
    /// calls `refresh()`, and the menu-bar label reads `isServing` only.
    ///
    /// **This is a statement about the settings FILE, not about ingest.** PE
    /// finding B2 measured a second app instance stealing the socket path,
    /// which kills ingest and leaves the settings file exactly as it was — so
    /// this stays `.wired` while no event can arrive. Whatever renders it must
    /// say the hooks are installed and must not claim events are flowing. A
    /// live-socket probe is the separate check that would close that gap.
    public private(set) var hookHealth: HookHealthStatus = .unreadable

    public init(holder: any AssertionHolding = AssertionHolder(),
                reader: any PowerReadingProviding = SystemPowerReader(),
                health: HookHealthReader = HookHealthReader()) {
        self.holder = holder
        self.reader = reader
        self.health = health
        self.reading = reader.read()
    }

    /// Bound to the panel's 3-way control. What the user ASKED FOR.
    ///
    /// This replaced a `serving: Bool` whose getter returned `isServing` — the
    /// actual hold — and whose setter wrote `newValue ? .serve : .stop`. Both
    /// halves were wrong once `.auto` existed:
    ///
    ///   - the getter made the control move by itself as agent sessions came
    ///     and went, because it reported what the machine was doing rather
    ///     than what had been asked of it;
    ///   - the setter could only express two of the three positions, so one
    ///     click wrote an explicit `.stop` or `.serve` the user never chose
    ///     and `.auto` — the position the product SHIPS in — could never be
    ///     selected again.
    ///
    /// The getter reads the controller, not a copy held here, so the `.serve`
    /// latch is visible to the panel: a hold the battery floor refuses moves
    /// the control to Off, which is exactly what has happened to the intent.
    ///
    /// `isServing` stays as the read-only ACTUAL state and stays on screen
    /// beside this. The two answer different questions and the panel shows
    /// both.
    public var intent: UserIntent {
        get { controller.intent }
        set {
            controller.userToggled(to: newValue)
            refresh()
        }
    }

    /// Re-samples power and reconciles the assertion. Safe to call on a timer.
    public func refresh() {
        reading = reader.read()
        // Re-read every time, not once in `init`. The user's recovery path is
        // to paste the snippet back, and this app runs for days.
        hookHealth = health.status()
        let state = controller.evaluate(powerSource: reading.source,
                                        batteryPercent: reading.percent)
        desired = state
        suppression = Self.reason(controller.lastSuppression, stillTrueOf: reading)

        if state.idleSleepAssertion {
            isServing = holder.acquire()
        } else {
            holder.release()
            isServing = false
        }
    }

    /// Starts the repeating refresh, so a battery crossing the floor is noticed
    /// without the user opening the panel.
    ///
    /// The ticker belongs to the model rather than to `PanelView` because
    /// `MenuBarExtra` with `.menuBarExtraStyle(.window)` builds its content only
    /// while the panel is open. A floor that is enforced only while the panel is
    /// open does not enforce the floor.
    ///
    /// 30s is frequent enough to matter and cheap enough to ignore —
    /// `SystemPowerReader.read()` is a non-blocking IOKit call. `.common` mode,
    /// not `.default`, so menu tracking does not stall the refresh. `[weak self]`
    /// so the run loop's reference to the timer cannot keep the model alive.
    ///
    /// `main.swift` calls this from `App.init()`. There are two ways a second
    /// `Timer` could end up on `RunLoop.main`, and both are closed:
    ///
    ///   - a repeat call on the SAME instance — `timer?.invalidate()` below;
    ///   - a second `App` build. That second `ServingModel` installs its own
    ///     timer, and SwiftUI keeps one `@State` box, so the orphan model
    ///     deallocates — the block below then invalidates its own timer.
    ///
    /// `[weak self]` does not cover the second case on its own. It stops the
    /// orphan's block from doing anything, but the run loop still holds the
    /// timer, so a main-thread wake-up every 30s survives for the life of the
    /// process. Only `invalidate()` takes it off the run loop.
    ///
    /// This was an `isolated deinit` until CI disproved it. That feature is
    /// EXPERIMENTAL before Swift 6.3: it compiles on a 6.3 developer machine and
    /// fails on the 6.1.2 GitHub runner with "requires frontend flag
    /// -enable-experimental-feature IsolatedDeinit". Verifying a language
    /// feature against a single toolchain is not verifying it.
    ///
    /// So the block invalidates the timer it is HANDED, rather than a `deinit`
    /// reaching for a stored property. No experimental feature, no weakened
    /// isolation, and the orphan survives at most one further tick.
    /// `nonisolated(unsafe)` and `@unchecked Sendable` stay rejected.
    ///
    /// Nobody has observed a second `App.init()`; it is inferred, not measured.
    /// This ships anyway because it is correct either way and costs nothing.
    /// The two alternatives stay rejected: moving the call to the view
    /// reintroduces the ticker-dies-with-the-panel defect this design exists to
    /// close, and a process-wide static guard adds hidden global state.
    public func startMonitoring(interval: TimeInterval = 30) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] tick in
            // `tick` stays OUT of the `assumeIsolated` closure: it is
            // task-isolated, and capturing it in a main-actor closure is a
            // sending violation under strict concurrency. Calling
            // `invalidate()` here is safe because this block runs on the run
            // loop the timer was added to, which is `RunLoop.main`.
            guard let model = self else {
                tick.invalidate()
                return
            }
            MainActor.assumeIsolated { model.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The panel explains a condition that is still true, or it says nothing.
    ///
    /// `HoldController.lastSuppression` latches: it is cleared only when the
    /// user picks Serve again, so it would otherwise keep the line on screen
    /// through a return to AC power and through a full recharge. That latch is
    /// deliberate and is left alone — under `.serve`, recovery must never
    /// re-arm the hold — so the filtering happens here, on the way to the
    /// panel.
    ///
    /// This filter is what makes the narrow `.serve`-only intent latch safe to
    /// rely on. Under `.auto` the hold DOES come back once the reading
    /// recovers, and this drops the stale line at the same moment, so the panel
    /// never explains a refusal that has stopped happening. Were the intent
    /// latch still unconditional, this filter would be actively harmful: it
    /// would hide the reason a permanently disabled app gave for disabling
    /// itself.
    private static func reason(_ suppression: HoldSuppression?,
                               stillTrueOf reading: PowerReading) -> HoldSuppression? {
        guard case .batteryFloor(_, let floor) = suppression,
              reading.source == .battery,
              let percent = reading.percent,
              percent <= floor
        else { return nil }

        return suppression
    }
}
