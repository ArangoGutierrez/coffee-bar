// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import CoffeeBarTestSupport

/// How the panel reaches the Preferences window — issue #63.
///
/// WHAT THIS CAN AND CANNOT SEE. Design §5.4 forbids asserting on rendered
/// AppKit state, and the defect this guards lives in the window server's notion
/// of which application is active. No test in this package can watch a window
/// come forward. `scripts/preferences-activation-acceptance.sh` does that, and it
/// measured both halves of the defect at `54f0058`:
///
///     invocation 1 (no window open)      -> frontmost=coffee-bar, panel STILL OPEN
///     invocation 2 (window already open) -> frontmost=Finder,     panel STILL OPEN
///
/// What THIS file guards is the MECHANISM those measurements indicted, read out
/// of `PanelView.swift` as code. That is a weaker claim than "the app activates",
/// and it is deliberately the claim that can be checked here: the reason
/// invocation 2 left Finder frontmost is structural, and structure is exactly
/// what a source read can hold.
///
/// THE ROOT CAUSE, stated so these guards are not mistaken for style rules.
/// `SettingsLink` is a link, not a closure — nothing can be hung off it, and a
/// `simultaneousGesture` attached to one was measured never to fire. So the #50
/// fix went to `PreferencesView.onAppear`, which fires when the window is
/// CREATED. Clicking Preferences with the window already open re-presents it,
/// `onAppear` does not run, and the activation never happens. An action that
/// runs on the click itself runs on every click, which is the whole of the fix.
///
/// COMMENT-STRIPPED, and here that is load-bearing rather than hygiene.
/// `PanelView.swift` explains in prose why it no longer uses `SettingsLink` —
/// the paragraph names the type — so `theSettingsRouteIsNotASettingsLink` read
/// raw would fail on the corrected tree, and the obvious way to green it is to
/// weaken the guard. `PanelPaletteWiring_test.swift` records the same trap
/// measured in both directions.
///
/// `#filePath` anchors the lookup to THIS source file, never to an installed or
/// deployed copy, so the guard cannot green-light a different tree than the one
/// under test.
private func panelSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CoffeeBarUITests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
    return swiftCodeWithoutComments(try String(
        contentsOf: root.appendingPathComponent("Sources/CoffeeBarUI/PanelView.swift"),
        encoding: .utf8))
}

/// The action closure of the `Button` that opens Settings, or `nil` when no
/// button opens Settings at all.
///
/// EVERY `Button` is walked and the one whose action calls `openSettings(` is
/// returned, rather than taking the first button in the file. The panel has two
/// — Preferences and Quit — and "the first one" is a rule that silently starts
/// reading the wrong control the day somebody reorders them. `braceBlock`
/// returns the first match in the string it is handed, so the search is
/// restarted from each occurrence instead.
///
/// A `Button` with no balanced block is skipped, which makes a file this cannot
/// parse fail the guards rather than pass them.
private func settingsActionBlock(in code: String) -> String? {
    var searchFrom = code.startIndex
    while let site = code.range(of: "Button", range: searchFrom..<code.endIndex) {
        if let found = braceBlock(after: "Button", in: String(code[site.lowerBound...])),
           found.block.contains("openSettings(") {
            return found.block
        }
        searchFrom = site.upperBound
    }
    return nil
}

/// What the Preferences action must do, in the order it must do it.
///
/// Each entry is a needle and the sentence explaining what its absence COSTS —
/// the message is the failure report, so it says what breaks for a user rather
/// than naming a missing token.
private let requiredInSettingsAction: [(needle: String, cost: String)] = [
    ("dismiss()",
     "the panel is never dismissed, so it draws over the window it just opened"),
    ("setActivationPolicy(.regular)",
     "macOS 14 declines a foreground request from an .accessory app, so the window opens grey and takes no keystrokes"),
    ("openSettings(",
     "nothing opens the Settings window"),
    ("activate(",
     "the window opens without the app ever coming forward"),
]

/// The requirements the Preferences action does NOT satisfy.
///
/// A sentinel is returned when no button opens Settings at all, so "no control"
/// can never be mistaken for "a control that satisfies everything" — the empty
/// list has to mean exactly one thing.
private func missingFromSettingsAction(in code: String) -> [String] {
    guard let action = settingsActionBlock(in: code) else {
        return ["<no Button action calls openSettings(>"]
    }
    return requiredInSettingsAction
        .filter { action.contains($0.needle) == false }
        .map { "\($0.needle) — without it, \($0.cost)" }
}

@Test("the panel opens Settings through an action, not a SettingsLink that cannot re-fire")
func theSettingsRouteIsNotASettingsLink() throws {
    let source = try panelSource()

    // The bug this catches: the panel goes back to `SettingsLink`, and issue
    // #63's second residual returns silently. Nothing about the FIRST click
    // changes when it does — `PreferencesView.onAppear` still fires on creation
    // — so the regression is invisible to anyone who tests by opening
    // Preferences once, which is how it survived #50.
    #expect(source.contains("SettingsLink") == false, """
        PanelView.swift reaches Settings through SettingsLink. A link is not a \
        closure: nothing can run on the click, so the app can only be activated \
        from the Settings scene's onAppear — which fires when the window is \
        CREATED and not when an existing one is re-presented. Measured at \
        54f0058: a second click left Finder frontmost.
        """)

    // The positive half. Deleting `SettingsLink` and putting nothing in its
    // place satisfies the assertion above and ships a panel with no route to
    // Preferences at all — the three settings that live only in that window
    // become unreachable.
    #expect(source.contains("@Environment(\\.openSettings)"), """
        PanelView.swift declares no @Environment(\\.openSettings). That is the \
        typed, macOS 14 route to the Settings scene and the only one that lets \
        code run on the same click.
        """)
}

@Test("the Preferences action dismisses the panel and takes the foreground")
func thePreferencesActionDismissesAndActivates() throws {
    let source = try panelSource()

    let missing = missingFromSettingsAction(in: source)
    #expect(missing.isEmpty, """
        the Preferences action in PanelView.swift is incomplete:
          \(missing.joined(separator: "\n  "))
        """)

    // ORDER. The dismissal is about the panel THIS click came from, so it runs
    // before the window that click opens.
    //
    // This rationale used to claim the ordering was load-bearing because the
    // dismissal closed the KEY window, and a close after `openSettings()` would
    // shut the window it had just opened. That argument belonged to a mechanism
    // that was built, measured and REJECTED — `NSApp.keyWindow?.close()` — and it
    // does not transfer to `dismiss()`, which addresses the panel's own
    // presentation and cannot reach the Settings window at all. The ordering is
    // kept because it is the one that reads correctly and the one that shipped
    // green; it is no longer claimed to prevent a specific measured failure.
    let action = try #require(settingsActionBlock(in: source), """
        no Button in PanelView.swift has an action that calls openSettings(, so \
        there is no Preferences action to read.
        """)
    let dismissAt = try #require(action.range(of: "dismiss()"),
                                 "the Preferences action never dismisses the panel")
    let openAt = try #require(action.range(of: "openSettings("),
                              "the Preferences action never opens Settings")
    #expect(dismissAt.lowerBound < openAt.lowerBound, """
        PanelView.swift dismisses the panel AFTER opening Settings. Dismiss \
        first: the dismissal is about the panel this click came from, and \
        ordering it after the window it opens has no reason to be correct.
        """)
}

@Test("the Preferences control still says Preferences…")
func thePreferencesControlKeepsItsLabel() throws {
    let source = try panelSource()

    // The label is not decoration: `scripts/preferences-activation-acceptance.sh`
    // resolves which of the panel's untitled AXButtons to click by reading this
    // literal out of this file, because SwiftUI gives none of them a title. It
    // counts the `Button` sites at or before this line to get the position of
    // Preferences from the top, so the literal is the ANCHOR for the whole
    // resolution. Rename it and the script REFUSES rather than clicking — the
    // safe direction, and still a regression, because the check that measures
    // issue #63 stops running.
    //
    // EXACTLY ONE, and that matters more since issue #29 added a third button:
    // a second occurrence would move the rank by one and the script would click
    // whatever sits at that position instead. Quit is one row below it.
    let labels = source.components(separatedBy: "\"Preferences…\"").count - 1
    #expect(labels == 1, """
        PanelView.swift carries the "Preferences…" label \(labels) times, \
        expected exactly 1. The acceptance script resolves which button to \
        click by counting Button sites up to this literal; at any other count \
        it resolves the wrong row, and the row below Preferences is Quit.
        """)
}

@Test("these guards read the mechanism, and go red on the shape that shipped before the fix")
func theGuardsDiscriminateTheOldShapeFromTheNew() throws {
    // THE PRE-FIX SHAPE, written out. Without this the assertions above are
    // satisfied by a reader that answers "fine" to anything, and a guard that
    // cannot be shown failing is theater. This is the code that was in
    // PanelView.swift at 54f0058 while the acceptance script measured
    // `after=Finder` on a second click.
    let settingsLinkShape = """
        SettingsLink {
            Text("Preferences…")
        }

        Button("Quit coffee-bar") { NSApplication.shared.terminate(nil) }
        """
    #expect(settingsLinkShape.contains("SettingsLink"),
            "the pre-fix fixture must contain the very thing the guard refuses")
    #expect(missingFromSettingsAction(in: settingsLinkShape)
                == ["<no Button action calls openSettings(>"], """
        the pre-fix shape has a Button — Quit — whose action opens nothing. The \
        reader must report NO settings action rather than reading Quit's \
        closure and finding it wanting.
        """)

    // THE POST-FIX SHAPE. The negative control alone is satisfied by a reader
    // that finds nothing anywhere.
    let actionShape = """
        Button {
            dismiss()
            NSApp.setActivationPolicy(.regular)
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Text("Preferences…")
        }

        Button("Quit coffee-bar") { NSApplication.shared.terminate(nil) }
        """
    #expect(missingFromSettingsAction(in: actionShape).isEmpty, """
        the shipped post-fix shape must satisfy every requirement, or these \
        guards are red on a correct tree and will be deleted rather than believed
        """)

    // ONE REQUIREMENT AT A TIME. A reader that returns the whole list whenever
    // anything is wrong would pass the two checks above and still not tell the
    // maintainer which half broke.
    for dropped in requiredInSettingsAction {
        let mutant = actionShape.replacingOccurrences(of: dropped.needle, with: "noOp(")
        let reported = missingFromSettingsAction(in: mutant)
        #expect(reported.count == 1, """
            removing \(dropped.needle) should leave exactly one unmet \
            requirement, got \(reported.count): \(reported)
            """)
        // `openSettings(` is the one requirement whose removal does not leave a
        // settings action MISSING something — it leaves no settings action to
        // find, because that call is how this reader identifies which of the
        // panel's buttons is the settings control in the first place. The
        // sentinel is the correct answer there, and this loop said otherwise
        // until the run reported it. Asserting the needle would be asserting
        // the reader behaves in a way it deliberately does not.
        let expected = dropped.needle == "openSettings(" ? "<no Button action" : dropped.needle
        #expect(reported.first?.hasPrefix(expected) == true, """
            removing \(dropped.needle) must be reported as that requirement, \
            got \(reported)
            """)
    }

    // The Quit button must never be mistaken for the settings control, whichever
    // order the two are written in. Reading "the first Button" would take Quit's
    // closure here and report a settings action that terminates the app.
    let reordered = """
        Button("Quit coffee-bar") { NSApplication.shared.terminate(nil) }

        Button {
            dismiss()
            NSApp.setActivationPolicy(.regular)
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Text("Preferences…")
        }
        """
    #expect(missingFromSettingsAction(in: reordered).isEmpty, """
        the settings action must be found by what it DOES, not by being the \
        first Button in the file
        """)
}

// MARK: - Is there a newer coffee-bar? The panel's half of issue #29

@Test("the panel offers Check now, and says what the last check concluded and when")
func thePanelOffersTheUpdateCheckUnconditionally() throws {
    // ISSUE #29's OPENING SENTENCE: "Two triggers: a Check now button in the
    // PANEL, and an automatic check on a visible interval." The feature shipped
    // in #127 with both on the Preferences window, and `PreferencesView.swift`
    // recorded the panel's copy as deferred rather than dropped. This is it.
    //
    // Named bug this catches: the section written into the file and unreachable
    // — `if model.updateVerdict != nil { … }` around it hides the button from
    // every user who has not checked yet, which before the launch trigger was
    // every user, and is exactly the state a manual check exists for.
    //
    // BRACE DEPTH against an unconditional neighbour, the mechanism
    // `theUpdateSectionStatesItsIntervalAndItsLastCheckUnconditionally` uses on
    // the window. EQUALITY and not `<=`: an `if false { … }` inside the VStack
    // lands at exactly the depth an `HStack` row does, so an inequality passes
    // over the mutation this exists to catch.
    let source = try panelSource()

    let anchorDepth = try #require(braceDepth(atFirst: "Text(\"Waiting on you\")", in: source), """
        PanelView.swift no longer contains Text("Waiting on you"), so this \
        guard has no unconditional neighbour to compare against and measured \
        nothing.
        """)

    // All three at the VStack's own depth. The panel is 260 points wide, so
    // unlike the window these are stacked rather than sharing an `HStack` row —
    // "Last checked: 2026-08-16 09:30." beside a button does not fit that
    // column, and a caption that wraps under its own button reads as broken.
    let required = [
        (needle: "model.updateStatusLine",
         line: "the sentence saying what the last check concluded"),
        (needle: "model.lastUpdateCheckLine",
         line: "the time of the last check"),
        (needle: "Button(\"Check now\")",
         line: "the Check now button"),
    ]

    for item in required {
        let depth = try #require(braceDepth(atFirst: item.needle, in: source), """
            PanelView.swift names \(item.needle) nowhere in code, so \
            \(item.line) is absent from the panel — the surface issue #29 asks \
            for it on.
            """)
        #expect(depth == anchorDepth, """
            PanelView.swift renders \(item.line) at brace depth \(depth) while \
            the unconditional Text("Waiting on you") sits at \(anchorDepth). It \
            is inside something the headings are not — an `if`, a `switch`, a \
            closure — so the user may never see it.
            """)
    }
}

@Test("the panel's button asks unconditionally; only the launch trigger honours the interval")
func thePanelButtonIsTheManualCheckAndNotTheScheduledOne() throws {
    // THE PRESS IS THE ASK. `checkForUpdatesIfDue()` here would make the button
    // do nothing for a user who pressed it twice, or who pressed it an hour
    // after coffee-bar started — and a button that silently declines is a
    // button lying about having a job. The window's copy of this control is
    // held to the same rule, at its own call site.
    //
    // Named bug this catches, and it is the likelier direction: somebody sees
    // "no duplicate scheduling" in the issue, reaches for the interval-gated
    // spelling on both surfaces, and the manual check stops being manual.
    //
    // SCOPED to the button's own action. A `contains` over the file would be
    // satisfied by the launch trigger's spelling if one were ever written here.
    let source = try panelSource()

    let action = try #require(braceBlock(after: "Button(\"Check now\")", in: source), """
        PanelView.swift declares no Button("Check now") with a block, so the \
        panel offers no manual check at all.
        """)

    #expect(action.block.contains("model.checkForUpdates()"), """
        the panel's Check now button does not call model.checkForUpdates(). \
        The check has exactly one implementation and the button's whole job is \
        to reach it; a second spelling of the request in this file would be a \
        second thing to keep honest.
        """)

    #expect(!action.block.contains("checkForUpdatesIfDue"), """
        the panel's Check now button honours the interval, so a user who \
        presses it twice — or who presses it at all on the day coffee-bar \
        already checked at launch — gets nothing and no explanation. IfDue is \
        the automatic half and belongs at the launch trigger.
        """)

    // NO SECOND SPELLING OF THE REQUEST. The panel asks the model, the model
    // asks the one entitled fetcher, and nothing else in this application opens
    // a connection — `noLinkedTargetCanReachTheNetworkByAddress` is the
    // authority and this is stated here because a button is the shortest path
    // anyone would take to a URLSession.
    for name in ["URLSession", "URLRequest", "PublishedManifestFetcher"] {
        #expect(!source.contains(name), """
            PanelView.swift names \(name) in CODE. Issue #29 entitles exactly \
            one file to reach the network and this is not it.
            """)
    }
}

@Test("the panel composes no update sentence of its own")
func thePanelComposesNoUpdateSentenceOfItsOwn() throws {
    // M1 design §5.4 forbids asserting on rendered AppKit text, so a sentence
    // written in this file is a sentence no check reads. The panel now makes
    // the same two claims the window does — how often coffee-bar reaches the
    // network, and whether this is the newest build — and both are rendered
    // verbatim from a seam that IS checked.
    //
    // Named bug this catches: `Text("coffee-bar is up to date.")` written here
    // beside a model that concluded something else, or a second "once a day"
    // that disagrees with `UpdateCheck.interval`. The window is held to exactly
    // this list by `thePreferencesWindowComposesNoUpdateSentenceOfItsOwn`; two
    // surfaces rendering the same feature need the same rule, and #30 is the
    // precedent — the Preferences window wrote its own copy of an advisory
    // sentence it could not reach, and shipped the pigment #30 had removed.
    let source = try panelSource()

    for invented in ["once a day", "installs nothing", "up to date", "Last checked"] {
        #expect(!source.contains(invented), """
            PanelView.swift composes the phrase "\(invented)" itself. The \
            update sentences live on UpdateCheck and on the model, where \
            UpdateCheck_test.swift reads them against the constant they \
            describe; a second spelling here can disagree with what the code \
            does and nothing would see it.
            """)
    }
}
