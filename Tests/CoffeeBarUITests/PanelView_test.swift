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
    (".close()",
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

    // ORDER, and it is not cosmetic. The dismissal closes the KEY window; once
    // the Settings window is up it is the key window, so a close that runs after
    // openSettings() shuts the window it just opened. This is the one ordering
    // in the action that changes behaviour rather than reading nicely.
    let action = try #require(settingsActionBlock(in: source), """
        no Button in PanelView.swift has an action that calls openSettings(, so \
        there is no Preferences action to read.
        """)
    let dismissAt = try #require(action.range(of: ".close()"),
                                 "the Preferences action never closes the panel")
    let openAt = try #require(action.range(of: "openSettings("),
                              "the Preferences action never opens Settings")
    #expect(dismissAt.lowerBound < openAt.lowerBound, """
        PanelView.swift closes the key window AFTER opening Settings. By then the \
        key window IS the Settings window, so this closes the window it has just \
        opened. Dismiss first.
        """)
}

@Test("the Preferences control still says Preferences…")
func thePreferencesControlKeepsItsLabel() throws {
    let source = try panelSource()

    // The label is not decoration: `scripts/preferences-activation-acceptance.sh`
    // resolves which of the panel's two untitled AXButtons to click by reading
    // this literal out of this file, because SwiftUI gives neither button a
    // title and the other one is Quit. Rename it and the acceptance script
    // REFUSES rather than clicking — which is the safe direction, and still a
    // regression, because the check that measures issue #63 stops running.
    let labels = source.components(separatedBy: "\"Preferences…\"").count - 1
    #expect(labels == 1, """
        PanelView.swift carries the "Preferences…" label \(labels) times, \
        expected exactly 1. The acceptance script resolves the button to click \
        by reading this literal; at any other count it cannot tell which control \
        it is about to click, and the panel's other button is Quit.
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
            NSApp.keyWindow?.close()
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
            NSApp.keyWindow?.close()
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
