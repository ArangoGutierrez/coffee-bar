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
            Toggle("Serving", isOn: $model.serving)
                .toggleStyle(.switch)
                .font(.headline)

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

            Divider()

            Label(batteryLine, systemImage: "bolt")
                .font(.caption)
                .foregroundStyle(.secondary)

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
