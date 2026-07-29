// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CoffeeBarCore

// `import AppKit` is explicit for `NSApplication.shared.terminate`. Do not
// rely on SwiftUI re-exporting it.

public struct MenuBarLabel: View {
    let isServing: Bool

    public init(isServing: Bool) {
        self.isServing = isServing
    }

    public var body: some View {
        if let glyph = MenuBarGlyphs.image(
            named: isServing ? "coffee-bar-servingTemplate" : "coffee-bar-idleTemplate") {
            Image(nsImage: glyph)
        } else {
            Image(systemName: isServing ? "cup.and.saucer.fill" : "cup.and.saucer")
        }
    }
}

public struct PanelView: View {
    @Bindable var model: ServingModel

    public init(model: ServingModel) {
        self.model = model
    }

    private var batteryLine: String {
        let charge = model.reading.percent.map { "\($0)%" } ?? "no battery"
        return "\(charge) · \(model.reading.source == .ac ? "AC power" : "battery")"
    }

    /// Rendered from the enum, never from free text, so the reason the panel
    /// shows is the reason the controller decided.
    ///
    /// The sentence has to be true in BOTH cases that reach it. Spec §5.3
    /// refuses a toggle-on that starts below the floor, and `evaluate` records
    /// the same `lastSuppression` for that refusal as for a real release, so
    /// "Released at N%" would announce a release that never happened.
    ///
    /// "at or below" is deliberate, not padding: `PowerBroker` suppresses at
    /// `percent <= floor`, so at exactly 20% a line reading "below 20%" states
    /// the opposite of what the product just did.
    ///
    /// The percentage is the reading the decision was made on, which is not
    /// always the newest one — the battery keeps draining after a release. The
    /// battery line below carries the current value.
    private var suppressionLine: String? {
        switch model.suppression {
        case .batteryFloor(let percent, let floor):
            return "At \(percent)% — coffee-bar does not hold at or below \(floor)%."
        case nil:
            return nil
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Three positions, not a switch, and bound to the INTENT rather
            // than to `isServing`.
            //
            // A switch is a Bool, and the intent has never been one. Bound to
            // `isServing` it also reported the ACTUAL hold, so under `.auto` it
            // would move by itself as agent sessions came and went, and the
            // click that moved it back would write an explicit `.stop` or
            // `.serve` the user never chose — leaving `.auto`, the position the
            // product ships in, unreachable after the first click.
            //
            // The tags are the enum cases, so the control cannot drift from the
            // policy: a new `UserIntent` case is a compile-time decision here.
            Text("Serving").font(.headline)

            Picker("Serving", selection: $model.intent) {
                Text("Off").tag(UserIntent.stop)
                Text("Auto").tag(UserIntent.auto)
                Text("On").tag(UserIntent.serve)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // `isServing` stays on screen beside the control. The user has to
            // be able to see that Auto is holding right now, or is not — the
            // control says what was asked for and this line says what happened.
            Text(model.isServing
                 ? "Holding the system awake. The display may still sleep."
                 : "Not holding any assertion.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let line = suppressionLine {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Beside the serving state rather than in a footer, because under
            // `.auto` — the position the product ships in — missing hooks mean
            // no session ever arrives and the app can therefore never decide to
            // hold. That is an explanation of what this control is doing, not
            // an aside.
            //
            // Rendered verbatim from the model, with no text built here. The
            // wording is the honest half of design §6 and is asserted on
            // `ServingModel.hookAdvisory`; M1 design §5.4 rules out asserting on
            // this view. A second sentence composed here would be a sentence no
            // check reads.
            //
            // Nothing shows when the hooks are wired. The check reads the
            // settings file and cannot see an event arrive, so the panel has no
            // evidence for a healthy line and does not print one.
            if let line = model.hookAdvisory {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // What is holding the machine awake, right under the line that says
            // whether anything is. Design §14: the attention list below shows
            // the two BLOCKED states, so without this the session actually
            // causing the hold appears nowhere in a product whose pitch is that
            // you can see it.
            //
            // Rendered verbatim from the model, with no sentence built here —
            // M1 design §5.4 forbids asserting on rendered AppKit text, so a
            // sentence composed in this file would be a sentence no check reads.
            if let summary = model.workingSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Label(batteryLine, systemImage: "bolt")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text("Waiting on you").font(.headline)

            AttentionListView(sessions: model.attention)

            Divider()

            Button("Quit coffee-bar") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 260)
        // The panel refreshes on open so what the user sees is current. The
        // 30-second ticker is not here: `MenuBarExtra(.window)` builds this
        // view only while the panel is open, so a ticker owned by the view
        // would stop the moment the user closed it.
        .onAppear { model.refresh() }
    }
}
