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

    /// One advisory: a warning symbol, then the sentence the model published.
    ///
    /// SHAPE, NOT COLOUR, and that is issue #30. All four advisory lines took
    /// SwiftUI's semantic orange as their foreground style — systemOrange, the
    /// same pigment the brand doc calls `action`. As caption TEXT it measures
    /// 1.75:1 to 2.31:1 on the light backdrops this panel draws on, where WCAG
    /// asks 4.5:1 below ~18pt. The pigment is named nowhere in this file now,
    /// not even in this note: a literal written in prose is what a guard
    /// reading raw source counts, and issue #30's acceptance greps for it.
    /// The dark appearance was never the problem: it clears 7.62:1. Darkening
    /// the orange until it passes on light reaches roughly `#8C5200`, which is
    /// the roast `state` colour — so the fix that keeps the colour deletes the
    /// hue separation the panel depends on, where roast means coffee-bar is
    /// acting and orange means attention. Moving the pigment onto an icon does
    /// not rescue it either; systemOrange fails even the 3:1 non-text floor on
    /// a light backdrop.
    ///
    /// So the meaning moves to a symbol, which no appearance and no contrast
    /// setting can wash out, and `assets/art/README.md` line 22 gets its own
    /// rule back: neither accent carries body text.
    ///
    /// The KNOWN COST, in issue #30's words: the warnings get quieter, and the
    /// dead-socket line is the one users most need to notice. Three things pay
    /// it, none of them a colour:
    ///
    ///   - the filled triangle rather than the outline, because a 1pt stroke at
    ///     caption size is nearly nothing;
    ///   - `.imageScale(.large)`, so the symbol reads as a mark beside the text
    ///     rather than as a character in it;
    ///   - `.primary` and `.semibold` on the sentence, against the `.secondary`
    ///     of the serving summary directly above. An advisory now draws DARKER
    ///     than the neutral line it interrupts, which is the one axis left once
    ///     hue is spent — and it is the axis that survives Increase Contrast,
    ///     Differentiate Without Color and a greyscale display.
    ///
    /// Placement is unchanged and deliberately so. Each advisory already sits
    /// directly beneath the control it explains rather than in a footer, which
    /// is the placement half of the compensation; moving them would separate
    /// each sentence from the thing it is about.
    ///
    /// The symbol is `accessibilityHidden`, exactly as the serving indicator's
    /// is: it restates what the sentence beside it already says, and VoiceOver
    /// reading "warning triangle" before every advisory is noise, not access.
    /// The sentence is the accessible carrier and always was — colour never
    /// reached that route at all.
    ///
    /// A shared row rather than the treatment written out four times. The four
    /// advisories are one class of thing, and the guard
    /// `advisoriesCarryShapeRatherThanColour` reads them through this one
    /// declaration, so they cannot drift apart a site at a time.
    private func advisoryRow(_ line: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .imageScale(.large)
                .accessibilityHidden(true)
            Text(line)
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.primary)
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
                advisoryRow(line)
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
                advisoryRow(line)
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
                advisoryRow(line)
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
                advisoryRow(line)
                    // The one advisory whose sentence carries a command meant to
                    // be pasted into a root shell. Chained here rather than put
                    // in `advisoryRow` because the other three carry nothing
                    // worth selecting; `.textSelection` reaches the Text through
                    // the Environment.
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

            // One line, not an About sheet. The panel is 260pt wide and already
            // dense, and the DMG now reaches people who never saw the
            // repository: this is the only route from the product to its terms.
            Link(PanelView.legalLine(), destination: PanelView.legalURL())
                .font(.caption)
                .foregroundStyle(.secondary)

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
            // `SettingsLink` rather than a `Button` that sends an action:
            // AppKit's selector for this has changed spelling across releases,
            // so `NSApp.sendAction(Selector(("showSettingsWindow:")))` is a
            // string that compiles on every OS and works on some. This is the
            // typed equivalent, and it needs macOS 14 — which is already this
            // package's deployment target.
            //
            // `SettingsLink` OPENS the window and does not ACTIVATE the app,
            // and for an `LSUIElement` process those are different things —
            // measured, see `PreferencesView.swift`, which is where the fix
            // lives. NOTHING may be hung off this link to do it: a
            // `simultaneousGesture` attached here was measured never to fire.
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
