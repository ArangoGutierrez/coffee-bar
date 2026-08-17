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

    // The typed way to raise the Settings scene, and the reason the Preferences
    // control below is a `Button` rather than a `SettingsLink`. Both open the
    // same window; only this one lets code run on the SAME click, which is the
    // whole of issue #63. macOS 14, already this package's deployment target.
    @Environment(\.openSettings) private var openSettings

    // Dismisses the panel this view is rendered in. `MenuBarExtra(.window)`
    // presents it, so the request goes through the Environment rather than to
    // the `NSWindow` behind SwiftUI's back — see the Preferences action below,
    // where two window-level spellings were built and rejected.
    @Environment(\.dismiss) private var dismiss

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

    // The advisory treatment is `AdvisoryRow`, in its own file, and the reasons
    // it moved there are on the type. It was private to this view, which is
    // exactly why issue #30 shipped with a fifth advisory still painted: the
    // Preferences window renders the same `staleHelperAdvisory` sentence, could
    // not reach this treatment, and wrote its own in the pigment #30 removed.
    //
    // PLACEMENT stays here and deliberately so. Each advisory sits directly
    // beneath the control it explains rather than in a footer, which is the
    // placement half of the compensation for the lost colour; moving them would
    // separate each sentence from the thing it is about. What was lifted is the
    // treatment, not the layout.

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

            // What is ACTUALLY held, right under the control that asked for it.
            // The user has to be able to see that Auto is holding right now, or
            // is not — the control says what was asked for and this line says
            // what happened.
            //
            // This matters MORE since the Display, Battery floor and Focus
            // controls moved into the Preferences window, not less: their
            // settings still decide what is held, and this is now the only
            // place the panel reports the result of them.
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
                AdvisoryRow(line: line)
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
                AdvisoryRow(line: line)
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
                AdvisoryRow(line: line)
            }

            // A THIRD advisory, and issue #81 is why it is on this surface at
            // all. Issue #56 took the lid-closed EXPLANATION out of this panel,
            // and that stands: 80 words of documentation do not belong in a
            // 260pt column. This is not that. It is a fault on the machine in
            // front of the user, discovered by a read this app performs on every
            // refresh — live state, which is exactly what this panel is for, and
            // the user cannot act on what they are never shown.
            //
            // Rendered verbatim from the model with no text built here, for the
            // reason every other line in this file gives: M1 design §5.4 forbids
            // asserting on rendered AppKit text, so a sentence composed here
            // would be a sentence no check reads.
            //
            // `Bundle.main.executableURL` is read HERE and the model stays pure,
            // the same split `versionLine(from: Bundle.main.infoDictionary)`
            // uses below. The probe is this app's neighbour in `Contents/MacOS`,
            // so the running bundle is the only thing that knows the path — a
            // literal would be right for a disk-image install and wrong for
            // Homebrew, for a `swift build` tree, and for a copy on the Desktop,
            // and the command in this sentence is meant to be pasted into a root
            // shell.
            //
            // Silent on a machine whose helper is current or was never armed.
            if let line = model.staleHelperAdvisory(
                probeAt: ServingModel.probePath(
                    besideExecutable: Bundle.main.executableURL)) {
                AdvisoryRow(line: line)
                    // The one advisory whose sentence carries a command meant to
                    // be pasted into a root shell. Chained here rather than put
                    // in `AdvisoryRow` because the other three carry nothing
                    // worth selecting; `.textSelection` reaches the Text through
                    // the Environment. The Preferences window's copy of this
                    // line does the same, at its own call site, for the same
                    // reason.
                    .textSelection(.enabled)
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

            // NOTHING ABOUT LID-CLOSED MODE LIVES HERE, and this note is the
            // whole of what replaced it. Issue #56: this panel rendered roughly
            // 80 words explaining the mode, unconditionally, in a 260pt column.
            //
            // It is neither live state nor a control, so it belongs to neither
            // half of the split #50 established — this surface says what
            // coffee-bar is doing NOW, and Preferences holds what the user
            // configures. The short version moved to Preferences → Power beside
            // the other power settings, and the explanation is on
            // `site/docs.html`, which had none until that issue.
            //
            // `theLidClosedSummaryIsInThePreferencesWindowAndNotInThePanel`
            // holds both ends of that move and reads this file with its
            // comments stripped, so this paragraph cannot satisfy it. Putting
            // the render back turns it red.

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

            // IS THERE A NEWER ONE — issue #29's opening sentence, and the half
            // of it that shipped missing. "Two triggers: a Check now button in
            // the PANEL, and an automatic check on a visible interval." #127
            // built both on the Preferences window and `PreferencesView.swift`
            // booked this copy as deferred rather than dropped.
            //
            // DIRECTLY UNDER THE VERSION LINE, because it is the same question
            // continued: that line answers "which build is this?" and this one
            // answers "is it the current one?". A user reading the first has
            // already asked the second.
            //
            // UNCONDITIONAL, all three of them, like the version line above and
            // unlike the four advisories. There is always something true to say
            // here — including before any check has run, which is the state a
            // silently broken check leaves behind for ever. An `if` around this
            // would hide exactly the case the button exists for.
            //
            // Rendered verbatim from the model, with no sentence built here,
            // for the reason every other line in this file gives: M1 design
            // §5.4 forbids asserting on rendered AppKit text, so a sentence
            // composed here would be a sentence no check reads. `nil` is not
            // "up to date" and `ServingModel.updateStatusLine` owns that
            // distinction.
            Text(model.updateStatusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // WHEN, beside WHAT, because an interval nobody can check against
            // anything is a claim rather than a fact — `docs/ROADMAP.md`'s "no
            // hidden durations", which issue #29 restates as a constraint.
            //
            // The ATTEMPT and not the last success. `ServingModel.lastUpdateCheck`
            // documents why the two are kept apart: the sentence above says what
            // the attempt concluded, so the pair cannot read as a check that
            // worked.
            Text(model.lastUpdateCheckLine)
                .font(.caption)
                .foregroundStyle(.secondary)

            // THE MANUAL TRIGGER.
            //
            // `checkForUpdates()` and not `checkForUpdatesIfDue()` — the press
            // IS the ask, and honouring the interval here would make the button
            // do nothing for a user who pressed it twice, or who pressed it at
            // all on a day coffee-bar already checked at launch. The window's
            // copy of this control makes the same call for the same reason.
            //
            // STACKED rather than sharing a row with the time above it, which
            // is where the window puts it. This column is 260 points wide:
            // "Last checked: 2026-08-16 09:30." beside a button does not fit,
            // and a caption that wraps under its own button reads as broken.
            Button("Check now") {
                Task { await model.checkForUpdates() }
            }

            // The route to the Preferences window, and the only one this panel
            // offers. Display, Battery floor and Focus are THERE now, so this
            // link is the only way to reach three settings the panel used to
            // carry — a control nobody can find is a control that does not
            // exist, and this one link now stands for all three.
            //
            // Named precisely, because "they moved" without saying what moved
            // sends the next reader back to the diff: `holdDisplayAwake`,
            // `batteryFloorPercent` and `quietEverythingElse` are bound in
            // `PreferencesView.swift`, not here.
            //
            // That sentence is also a FIXTURE, and deliberately so. This file
            // must not NAME those three in code, and
            // `eachMovedControlLivesInExactlyOneSurface` holds that by reading
            // this file COMMENT-STRIPPED. Written raw, its negative half would
            // fail on this correct tree — the paragraph you are reading is what
            // would fail it. So this prose is load-bearing twice over: it tells
            // a reader where the controls went, and it keeps that guard honest,
            // because swapping the stripped read for a raw one turns the guard
            // RED instead of quietly widening it.
            //
            // A `Button` calling `openSettings()`, and neither of the two
            // spellings this file used before. AppKit's selector has changed
            // across releases, so
            // `NSApp.sendAction(Selector(("showSettingsWindow:")))` is a string
            // that compiles on every OS and works on some;
            // `@Environment(\.openSettings)` is the typed equivalent and needs
            // macOS 14, already this package's deployment target.
            //
            // `SettingsLink` WAS here and is the tidier spelling. It was
            // replaced because a link is not a closure, and issue #63 needs code
            // to run on the click. OPENING the window and ACTIVATING the app are
            // different things for an `LSUIElement` process, and nothing could
            // be hung off the link to do the second: a `simultaneousGesture`
            // attached to `SettingsLink` was measured never to fire.
            //
            // So #50 put the activation on `PreferencesView.onAppear` instead,
            // which fires when the window is CREATED. Measured at 54f0058 with
            // the window already open, clicking Preferences a second time:
            //     before = [coffee-bar Settings]  ->  after = Finder
            // The window came forward and the app did not — issue #63. Doing it
            // HERE does it on every click, so re-presenting an existing window
            // activates exactly like creating one.
            //
            // The dismissal is the same click's job and lives here for the same
            // reason: the panel drew over the window it had just opened, and
            // there is no other moment that knows both that a click happened and
            // that the panel is still up.
            Button {
                // `dismiss()` and NOT a close on the window, and the two
                // rejected spellings are recorded because both LOOK right and
                // both reach past SwiftUI to the window it is managing:
                // `NSApp.keyWindow?.close()` and `NSApp.keyWindow?.orderOut(nil)`
                // were each built and measured. Both dismiss the panel, so both
                // pass the criterion on a single run; neither tells SwiftUI, and
                // `MenuBarExtra` owns this window's presentation. `close()` in
                // particular can release the window a `MenuBarExtra` intends to
                // present again. `dismiss()` is the same request made through the
                // Environment, which is what the panel is presented by.
                dismiss()

                // Policy, then window, then foreground, and the ORDER is the
                // fix. macOS 14 made activation cooperative, so an `.accessory`
                // app asking for the foreground is declined — the policy change
                // is what makes the ask legal. `PreferencesView` does the same
                // pair in `.onAppear`, which fires only when the window is
                // CREATED; measured, a second click on an existing window left
                // Finder frontmost. Running it HERE runs it on every click.
                NSApp.setActivationPolicy(.regular)
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Text("Preferences…")
            }

            Button("Quit coffee-bar") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")

            // One line, not an About sheet. The panel is 260pt wide and already
            // dense, and the DMG now reaches people who never saw the
            // repository: this is the only route from the product to its terms.
            //
            // LAST, under the three controls rather than wedged between them.
            // It sat between "Check now" and "Preferences…" until now, which
            // split the controls into two groups with a sentence in the gap:
            // a user scanning this column for Quit read past a licence to reach
            // it. Nothing on this line is a control, and nothing that is not a
            // control should interrupt the ones that are.
            //
            // `theLicenceLineIsDrawnUnderTheFooterControlsAndNotBetweenThem`
            // holds that order and reads this file COMMENT-STRIPPED, so the
            // paragraph you are reading cannot satisfy it. Moving the line back
            // above the buttons turns it red, and
            // `theLicenceLineIsRenderedAsUnconditionallyAsTheControlsItSitsUnder`
            // holds the other half: last is not last if it is wrapped in a
            // condition, or dropped inside the button above it.
            Link(PanelView.legalLine(), destination: PanelView.legalURL())
                .font(.caption)
                .foregroundStyle(.secondary)
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
