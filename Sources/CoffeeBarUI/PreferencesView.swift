// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import Foundation
import CoffeeBarCore

// `import Foundation` is explicit for `Bundle.main.infoDictionary`, and
// `import CoffeeBarCore` for `BatteryFloor`. Do not rely on SwiftUI
// re-exporting either — `PanelView.swift` states the same rule.

/// The Preferences window's whole content.
///
/// One scrolling page with headed sections rather than tabs: four short groups
/// do not earn a second navigation layer.
///
/// The version line is here AND in the panel, deliberately. Every surface states
/// the running version, and both read `PanelView.versionLine(from:)` — one seam,
/// so the two can never disagree.
public struct PreferencesView: View {
    @Bindable var model: ServingModel

    public init(model: ServingModel) { self.model = model }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // The two questions about power, together, because they are
                // read together: how long a hold may last, and whether it
                // covers the screen. They arrived here from the panel, which
                // is 260pt wide and had grown four headed controls plus an
                // attention list — the floor alone wanted nine segments.
                Text("Power").font(.headline)

                // The labels come from the model, not from two literals here,
                // and that is not tidiness. Design §5.4 rules out asserting on
                // rendered AppKit text, so a label written in this file is a
                // label no check reads, while `servingSummary` describes the
                // same two states in prose that a check DOES read. The panel
                // carried these exact cases before the move.
                //
                // The label is VISIBLE here, unlike in the panel. There it sat
                // under its own `.headline` and `.labelsHidden()` because a
                // 260pt column has no room for a leading label; a settings
                // window is a form, and a form names its rows.
                Picker("Display", selection: $model.holdDisplayAwake) {
                    Text(ServingModel.displayLabel(for: false)).tag(false)
                    Text(ServingModel.displayLabel(for: true)).tag(true)
                }

                // A SLIDER, and the segmented picker it replaces is why. The
                // permitted range and step derive nine positions, and nine
                // segments across 260pt is unreadable — the defect this task
                // exists to close.
                //
                // Built OVER `BatteryFloor.permitted`, so this view holds no
                // bound of its own. It does not call `BatteryFloor.bounded`
                // and must not: bounding lives at `PowerInputs.init` and in
                // `WatchdogDecision`, and a third site is one value corrected
                // in two places by rules that can disagree. Constructing the
                // control over the range makes an out-of-range position
                // unreachable rather than corrected, which is the stronger
                // guarantee — there is nothing to correct.
                // `theFloorSliderIsBuiltOverThePolicyAndAddsNoSecondBoundingSite`
                // holds both halves.
                HStack {
                    Text("Battery floor")
                    Slider(
                        value: Binding(
                            get: { Double(model.batteryFloorPercent) },
                            set: { model.batteryFloorPercent = Int($0) }
                        ),
                        in: Double(BatteryFloor.permitted.lowerBound)
                            ... Double(BatteryFloor.permitted.upperBound),
                        step: Double(BatteryFloor.step)
                    )
                    // A slider without a readout is unreadable; the picker it
                    // replaces at least named its positions.
                    Text(ServingModel.floorLabel(for: model.batteryFloorPercent))
                        .monospacedDigit()
                }

                // Its own section and not a third row under Power, because it
                // is a different question: not how long coffee-bar holds the
                // machine, but what it does to everything that is not the
                // agent.
                //
                // The SECOND of two opt-ins, and it does nothing on its own —
                // the demotable set is empty by default, so a user who has
                // named nothing sees this switch change nothing whatever. The
                // label comes from the model for the reason the picker's do,
                // and its wording is constrained besides: macOS cannot promote
                // a process, so any label implying a speed-up is a false claim
                // (handoff §2.2).
                Text("Focus").font(.headline)

                Toggle(ServingModel.quietOthersLabel, isOn: $model.quietEverythingElse)

                Text(PanelView.versionLine(from: Bundle.main.infoDictionary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 420, height: 360)
    }
}
