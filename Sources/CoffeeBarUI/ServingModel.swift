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
    private var controller = HoldController()

    @ObservationIgnored private var timer: Timer?

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
    public private(set) var desired: DesiredPowerState?

    public init(holder: any AssertionHolding = AssertionHolder(),
                reader: any PowerReadingProviding = SystemPowerReader()) {
        self.holder = holder
        self.reader = reader
        self.reading = reader.read()
    }

    /// Bound to the toggle. `isServing` reflects what actually happened, not
    /// what was asked for: a refused hold leaves the switch off.
    public var serving: Bool {
        get { isServing }
        set {
            controller.userToggled(to: newValue ? .serve : .stop)
            refresh()
        }
    }

    /// Re-samples power and reconciles the assertion. Safe to call on a timer.
    public func refresh() {
        reading = reader.read()
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
    public func startMonitoring(interval: TimeInterval = 30) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The panel explains a condition that is still true, or it says nothing.
    ///
    /// `HoldController.lastSuppression` latches: it is cleared only when the
    /// user toggles back on, and a floor release forces the switch off by
    /// itself, so the latch would otherwise keep the line on screen through a
    /// return to AC power and through a full recharge. The latch is deliberate
    /// and is left alone — recovery must never re-arm the hold — so the
    /// filtering happens here, on the way to the panel.
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
