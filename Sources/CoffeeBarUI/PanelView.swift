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

    // Read here rather than inside BrandPalette so the palette stays a pure
    // value type that a test can call without an Environment.
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private func brand(_ role: ColorRole) -> Color {
        BrandPalette.color(role, scheme: colorScheme, contrast: colorSchemeContrast)
    }

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
    /// `nonisolated` is LOAD-BEARING, and no local run catches it.
    ///
    /// SwiftUICore declares the protocol as
    /// `@preconcurrency @_Concurrency.MainActor public protocol View`, so a
    /// conforming type infers main-actor isolation for its members, this static
    /// one included. A swift-testing `@Test` function is nonisolated, so calling
    /// it from one is "call to main actor-isolated static method
    /// 'versionLine(from:)' in a synchronous nonisolated context" — a hard
    /// error, and exactly how this first shipped RED to CI.
    ///
    /// The two toolchains disagree, and the `@preconcurrency` half is why. It
    /// compiled on Swift 6.3.3 locally and failed on the macos-15 runner's
    /// 6.1.2. Which later rule relaxes the inference is NOT diagnosed here; only
    /// the split itself is measured. The repo pins no toolchain, so a green
    /// local suite is not evidence for this line — treat CI as the authority.
    ///
    /// The keyword is right on the merits, not a workaround for the test: this
    /// takes a dictionary, returns a String, and touches no main-actor state, so
    /// it has no business holding the main actor. Annotating the tests
    /// `@MainActor` would have hidden the property rather than fixed it.
    ///
    /// - Parameter info: a bundle info dictionary, or `nil` when running
    ///   outside a bundle.
    nonisolated static func versionLine(from info: [String: Any]?) -> String {
        "Version " + AppVersion.display(from: info)
    }

    /// The licence and warranty position, as one line for the panel.
    ///
    /// Composed here rather than inline in `body` for the reason
    /// `versionLine(from:)` gives: a sentence built in the view is a sentence no
    /// check can read. `PanelLegalLine_test` pins the licence name to the
    /// `LICENSE` file the repository actually ships.
    ///
    /// A `func` and not a `let`, for the reason `versionLine(from:)` documents
    /// above: `nonisolated` here is load-bearing and no local run catches a
    /// mistake. That form is the only one in this codebase measured to compile
    /// on both the local toolchain and the macos-15 runner's.
    nonisolated static func legalLine() -> String { "Apache-2.0 · no warranty" }

    /// Where the line points. The published terms page, not the repository.
    ///
    /// Force-unwrapped because the string is a literal checked by a test in the
    /// same commit: `theLegalLinkPointsAtThePublishedTermsPage` fails before a
    /// bad URL could ever reach a build.
    nonisolated static func legalURL() -> URL {
        URL(string: "https://arangogutierrez.github.io/coffee-bar/terms.html")!
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
            // `state` colours the held segments and nothing else
            // (assets/art/README.md lines 18-20). Placed per-picker rather than
            // on the enclosing VStack: `.tint` is an Environment value, so one
            // call up there also painted the Quit button and every focus ring —
            // controls the brand doc assigns to `action`, which is web-only.
            .tint(brand(.state))

            // The second control, and a SEPARATE question from the one above.
            // That one says whether to hold at all; this says whether a hold
            // covers the screen. Issue #12 settled that "coffee-bar never holds
            // the display" is a DEFAULT and not a promise, so the user needs
            // somewhere to change it — a setting nobody can find is a setting
            // that does not exist.
            //
            // A fourth position on the Serving picker was the alternative and
            // is rejected: it would make "keep my screen on" imply "hold
            // unconditionally", which is not what a user asking for the screen
            // means, and it would put the off switch and the screen on one
            // control where they cannot be chosen independently.
            //
            // Same `.segmented` shape as above, and the labels come from the
            // model for the same reason: `servingSummary` describes these two
            // states in prose, and two literals here could drift from it with
            // nothing to catch the drift (design §5.4).
            Text("Display").font(.headline)

            Picker("Display", selection: $model.holdDisplayAwake) {
                Text(ServingModel.displayLabel(for: false)).tag(false)
                Text(ServingModel.displayLabel(for: true)).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(brand(.state))

            // The third control, and a third separate question: how much
            // battery a hold may spend. Issue #11 made the floor a setting
            // because 20% is a guess about somebody else's day — a user on a
            // train wants it higher, a user beside a charger wants it lower —
            // and a safety limit nobody can reach is one they work around by
            // turning the product off.
            //
            // The segments come from `BatteryFloor.choices`, in CoffeeBarCore
            // beside the permitted range, so an offered value the decision
            // would bound away cannot be listed here. The labels come from the
            // model for the reason the two controls above use it: design §5.4
            // rules out asserting on rendered AppKit text, so a label written
            // in this file is a label no check reads.
            Text("Battery floor").font(.headline)

            Picker("Battery floor", selection: $model.batteryFloorPercent) {
                ForEach(BatteryFloor.choices, id: \.self) { percent in
                    Text(ServingModel.floorLabel(for: percent)).tag(percent)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(brand(.state))

            // The fourth control, and a fourth separate question: what happens
            // to everything that is NOT the agent. Issue #14 built the governor
            // and shipped it with no caller at all, which is the shape issue
            // #13 complains about one milestone earlier — so the user needs
            // somewhere to turn it on, or it is a feature that does not exist.
            //
            // A TOGGLE and not a segmented picker, unlike the three controls
            // above. Those choose between states of one thing: the screen
            // sleeps or stays on, the floor is one of several percentages.
            // This asks whether to do an extra thing at all, which is a binary
            // opt-in, and the label carries the whole meaning.
            //
            // The label comes from the model, for the reason the others do:
            // design §5.4 rules out asserting on rendered AppKit text, so a
            // literal here is a literal no check reads — and the wording is
            // constrained. macOS cannot promote a process, so any label
            // implying a speed-up is a false claim (handoff §2.2).
            //
            // The SECOND of two opt-ins. It does nothing on its own: the
            // demotable set is empty by default, and a user who has named
            // nothing sees this switch change nothing whatever.
            Text("Other apps").font(.headline)

            Toggle(ServingModel.quietOthersLabel, isOn: $model.quietEverythingElse)
                .toggleStyle(.switch)
                .controlSize(.small)

            // What is ACTUALLY held, beside the two controls that asked for it.
            // The user has to be able to see that Auto is holding right now, or
            // is not — the controls say what was asked for and this line says
            // what happened.
            //
            // Rendered verbatim from the model, with no text built here. This
            // view composed the sentence until issue #12, and it read "the
            // display may still sleep" whatever the user had chosen — a false
            // claim no check could reach, because M1 design §5.4 rules out
            // asserting on this view. The wording now lives on
            // `ServingModel.servingSummary` and is asserted there.
            // The indicator is the only place brand colour touches the panel
            // body, and it is a GRAPHIC, not text — 3:1, not 4.5:1. The symbol
            // changes shape as well as colour (filled versus outline), so the
            // state survives Differentiate Without Color. The sentence beside
            // it stays, so colour is never the sole carrier.
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                let spec = ServingModel.indicator(isServing: model.isServing)
                Image(systemName: spec.symbolName)
                    .foregroundStyle(brand(spec.role))
                    .accessibilityHidden(true)
                Text(model.servingSummary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)

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

            // Lid-closed mode, which this panel deliberately cannot switch on.
            //
            // It needs root, and coffee-bar never elevates its own privilege,
            // so the honest surface is the command rather than a control. The
            // sentence also says what the app CANNOT see: the journal is
            // root-owned and unreadable here, measured, so a panel that stayed
            // silent would read as "lid-closed mode is off" — a claim with no
            // evidence behind it.
            //
            // Rendered verbatim from the model, with no text built here, for
            // the reason every other line in this file gives: M1 design §5.4
            // forbids asserting on rendered AppKit text, so a sentence composed
            // in this view is a sentence no check reads. The wording lives on
            // `ServingModel.lidClosedAdvisory` and is asserted there.
            //
            // Unconditional, unlike the advisories above. There is no state to
            // condition it on — that is the point of it.
            Text(ServingModel.lidClosedAdvisory)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

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

            // One line, not an About sheet. The panel is 260pt wide and already
            // dense, and the DMG now reaches people who never saw the
            // repository: this is the only route from the product to its terms.
            Link(PanelView.legalLine(), destination: PanelView.legalURL())
                .font(.caption)
                .foregroundStyle(.secondary)

            // The route to the Preferences window, and the only one this panel
            // offers.
            //
            // `SettingsLink` rather than a `Button` that sends an action:
            // AppKit's selector for this has changed spelling across releases,
            // so `NSApp.sendAction(Selector(("showSettingsWindow:")))` is a
            // string that compiles on every OS and works on some. This is the
            // typed equivalent, and it needs macOS 14 — which is already this
            // package's deployment target.
            SettingsLink {
                Text("Preferences…")
            }

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
