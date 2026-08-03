// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import Foundation
import CoffeeBarCore

// `import AppKit` is explicit for `NSApplication.shared.terminate`, and
// `import Foundation` for `Bundle.main.infoDictionary`. Do not rely on SwiftUI
// re-exporting either.

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

    /// The line that answers "which build is this?".
    ///
    /// A `static func` taking the dictionary, rather than a sentence built
    /// inline in `body`, for the reason stated all through this file: M1 design
    /// §5.4 forbids asserting on rendered AppKit text, so a string composed in
    /// `body` is a string no check reads. Taking `info` as a parameter instead
    /// of reading `Bundle.main` here is what lets a check reach this without
    /// rendering the view or living inside an app bundle. It is asserted in
    /// `PanelVersionLine_test.swift`.
    ///
    /// The stamp itself is not interpreted here. `display(from:)` on
    /// `AppVersion` owns the rule that an unusable stamp reports `unknown`, so
    /// this never invents a version and never draws a blank tail.
    ///
    /// That prose names the call WITHOUT its parentheses on purpose. The
    /// acceptance script mutates every call to `display` on `AppVersion` in
    /// this file and rejects a mutation wider than 6 diff lines. A second
    /// mention written in the shape of a call spends that budget on a comment,
    /// which compiles to nothing and so proves nothing.
    ///
    /// - Parameter info: a bundle info dictionary, or `nil` when running
    ///   outside a bundle.
    static func versionLine(from info: [String: Any]?) -> String {
        "Version " + AppVersion.display(from: info)
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

            // The labels come from the model, not from three literals here.
            // `suppressionAdvisory` names one of these positions in a sentence
            // the user then has to find on this picker, and a second list of
            // labels can drift from it silently — design §5.4 rules out
            // asserting on this control, so nothing would catch the drift.
            Picker("Serving", selection: $model.intent) {
                Text(ServingModel.label(for: .stop)).tag(UserIntent.stop)
                Text(ServingModel.label(for: .auto)).tag(UserIntent.auto)
                Text(ServingModel.label(for: .serve)).tag(UserIntent.serve)
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

            // Rendered verbatim from the model, with no text built here. This
            // view composed the sentence until now, and that is how it came to
            // read the same for a refused On click as for a hold nobody asked
            // for: a sentence built here is a sentence no check reads, because
            // M1 design §5.4 rules out asserting on this view. The wording and
            // both situations now live on `ServingModel.suppressionAdvisory`
            // and are asserted there.
            if let line = model.suppressionAdvisory {
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

            // A SECOND line, beside the one above and never merged into it.
            // The two answer different questions from different evidence: the
            // one above reads the user's settings FILE and cannot see this
            // process, this one reads this PROCESS and cannot see the settings.
            // Merged, a wired settings file would hide a dead socket — PE
            // finding B2, measured.
            //
            // Both are silent when there is nothing to report, so the usual
            // panel carries neither.
            if let line = model.ingestAdvisory {
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

            // Which build is this. On screen rather than in a log, because the
            // question is always asked ABOUT a machine the maintainer is not
            // sitting at: until now the only way to answer it was to diff
            // `Sources/` between the installed keg's SHA and HEAD.
            //
            // The sentence is composed in `versionLine(from:)`, not here, so a
            // check can read it. `Bundle.main.infoDictionary` is nil under
            // `swift run`, and that case is asserted rather than avoided.
            Text(PanelView.versionLine(from: Bundle.main.infoDictionary))
                .font(.caption)
                .foregroundStyle(.secondary)

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
