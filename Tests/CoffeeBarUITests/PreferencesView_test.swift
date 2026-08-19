// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import CoffeeBarCore
import CoffeeBarTestSupport

/// What the Preferences window must SAY, held by a source scan.
///
/// M1 design §5.4 forbids asserting on rendered AppKit text, so nothing here
/// watches the window draw. This reads the sources instead, which is the only
/// route to a `body` no test target can render.
///
/// LIMIT, stated rather than hidden: this proves each surface NAMES the version
/// seam, never that the pixels are right. `PanelVersionLine_test.swift` holds
/// what the seam returns.

/// The package root, resolved from `#filePath`.
///
/// A third resolver in this target, for the reason `LidClosedPanel_test.swift`
/// gives: the others are `private`, which in Swift is scoped to their own file.
/// Duplicating four lines is better than widening a boundary guard's internals.
private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarUITests/PreferencesView_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarUITests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // the package root
}

private enum SurfaceScanError: Error, CustomStringConvertible {
    /// The scan did not resolve exactly one file by that name.
    ///
    /// Never a shrug and an empty string: a surface this guard names and cannot
    /// find is the failure, not a reason to pass.
    case notOneFile(name: String, found: [String])

    var description: String {
        switch self {
        case .notOneFile(let name, let found):
            return found.isEmpty
                ? "no \(name) anywhere under Sources/; the surface this guard names does not exist"
                : "\(found.count) files are named \(name) under Sources/: \(found)"
        }
    }
}

/// The CODE of a surface, located by file name under `Sources/`.
///
/// COMMENT-STRIPPED, and that is the whole discriminator. Every file in this
/// package explains the version seam in prose — `PanelView.swift` names
/// `versionLine(from:)` in four comments — so a RAW `contains` is satisfied by
/// the explanation of the render it deleted. Measured against 635720c: removing
/// the one `Text(PanelView.versionLine(...))` line from `PanelView.swift` left
/// four matches standing, all of them comments.
/// `PanelView.swift` "compiles to nothing and so proves nothing" already
/// documents this hazard for the acceptance script.
///
/// `swiftCodeWithoutComments` is the lexer `AppLayerBoundary_test.swift` rests
/// its below-app scan on, pinned by
/// `swiftCodeWithoutCommentsKeepsCodeAndDropsComments`. Reused rather than
/// re-implemented: a second stripper is a second thing to get wrong.
///
/// Located by NAME rather than by a hard-coded directory, so a surface that
/// moves within `Sources/` is still read instead of silently reported absent.
private func surfaceCode(named name: String) throws -> String {
    let sources = packageRoot.appending(path: "Sources")
    let walk = FileManager.default.enumerator(atPath: sources.path)
    let found = (walk?.compactMap { $0 as? String } ?? [])
        .filter { $0.hasSuffix(".swift") && ($0 as NSString).lastPathComponent == name }

    guard found.count == 1, let relative = found.first else {
        throw SurfaceScanError.notOneFile(name: name, found: found)
    }
    return swiftCodeWithoutComments(
        try String(contentsOf: sources.appending(path: relative), encoding: .utf8))
}

/// Each surface, and the type whose `body` has to render the version.
///
/// The TYPE is named as well as the file, and that is load-bearing rather than
/// tidy. `PanelView.swift` declares TWO `View`s — `MenuBarLabel` at the top,
/// `PanelView` below it — so a scoper anchored on the first
/// `var body: some View` in the file reads `MenuBarLabel`'s body, which renders
/// no version and correctly never should. Scoping that way makes the check fail
/// on a CORRECT tree, which is worse than not scoping at all: a guard that is
/// wrong when the code is right teaches people to silence it.
///
/// THIS LIST IS THE DESIGNED UPDATE POINT, the same shape as
/// `expectedAppLayerEntries`. Naming the type buys the scoping above and costs
/// a maintenance step: a version rendered by a type not listed here reads as
/// absent.
///
/// The concrete case, and it compiles — extract the line into a sibling
/// top-level `struct VersionFooter: View` in `PreferencesView.swift` and render
/// `VersionFooter()` from `PreferencesView.body`. The window SHOWS the version
/// and this guard goes RED, because `PreferencesView.body` no longer names the
/// seam. That is not exotic: `PanelView.swift` already declares two Views this
/// way, and Task 5 breaks this window into sections, which is exactly when
/// somebody extracts one.
///
/// THE RIGHT FIX IS TO ADD THE PAIR, never to loosen the assertion. Adding
/// `(file: "PreferencesView.swift", type: "VersionFooter")` keeps every surface
/// covered. Widening the check back to the whole file to make the red go away
/// restores the D3 hole this scoping exists to close — a helper that names the
/// seam while `body` renders nothing.
private let versionSurfaces = [(file: "PanelView.swift", type: "PanelView"),
                               (file: "PreferencesView.swift", type: "PreferencesView")]

@Test func everyTopLevelSurfaceShowsTheRunningVersion() throws {
    // Named bug this catches: a second surface that composes its own version
    // sentence, or none at all. Two spellings of the version leave the user
    // comparing numbers that disagree with no way to tell which app is running
    // — the confusion issue #47 already cost this project once.
    for surface in versionSurfaces {
        let code = try surfaceCode(named: surface.file)

        // Scoped to the TYPE, then to that type's `body`. A `contains` over the
        // whole file proves the seam is NAMED somewhere in it, which is not the
        // invariant: extract the version into a helper and drop the call from
        // `body` and the file still names it, while the window shows nothing.
        // Measured before this scoping landed — that surface compiled with no
        // warning and the whole suite stayed green at 837 tests.
        //
        // `braceBlock` is the reader `AppLayerBoundary_test.swift` already uses
        // to hold two call sites of one method apart. Reused rather than
        // rewritten, for the reason `surfaceCode` reuses the lexer.
        let declared = try #require(braceBlock(after: "struct \(surface.type): View", in: code), """
            \(surface.file) declares no `struct \(surface.type): View`. The guard \
            names a surface this package no longer has, so it can prove nothing \
            about it.
            """)
        let body = try #require(braceBlock(after: "var body: some View", in: declared.block), """
            \(surface.type) declares no body, so nothing in it can render the \
            version.
            """)

        // The message names the REMEDY, because this check has a legitimate red
        // that is not a bug in the product: the version moved into another View
        // in the same file. Someone meeting that red without being told what to
        // do reaches for the assertion, and deleting it reopens D3.
        #expect(body.block.contains("versionLine(from:"), """
            \(surface.type).body does not render the running version. A helper \
            that names the seam is not enough — the user reads the window, not \
            the file.

            If the version is now rendered by ANOTHER View in \(surface.file) — \
            a sibling `struct VersionFooter: View`, say — then add that pair to \
            `versionSurfaces` above: (file: "\(surface.file)", type: "<that \
            type>"). That is the fix.

            Do NOT delete this expectation and do NOT widen it back to the whole \
            file. The file-wide form is what an orphaned helper defeats: it names \
            the seam while `body` renders nothing, and the window shows no \
            version with the suite green.
            """)

        // FILE-WIDE, deliberately, unlike the check above. This one asks whether
        // the surface goes around the seam, and a helper reading
        // `CFBundleShortVersionString` directly is exactly as wrong as `body`
        // doing it — worse, since it is further from the eye. Narrowing this to
        // `body` would lose that and fix nothing.
        //
        // A SECOND LATENT INVERSION lives here, and it is worth knowing before
        // it fires rather than after. This passes today only because the key
        // sits in exactly one place — the `bundleKey` constant that
        // `AppVersion.swift` "The Info.plist key that `scripts/build-app.sh` stamps"
        // documents — and neither scanned file is that one. Fold
        // `AppVersion.display(from:)` into `PanelView.swift` and this
        // expectation goes RED over a correct tree,
        // because the surface would then legitimately contain the key it is
        // being told not to name.
        //
        // The remedy then is to keep the key's OWNER out of the scanned
        // surfaces — that is the invariant, one reader of the stamp — not to
        // drop this expectation. Same trap as the selector guard in
        // `AppLayerBoundary_test.swift`: a guard that is wrong on a correct tree
        // teaches people to silence it, so the reason is recorded here instead
        // of being rediscovered.
        #expect(!code.contains("CFBundleShortVersionString"), """
            \(surface.file) reads the version key directly instead of using the \
            one seam. Two readings of the stamp can disagree, and \
            AppVersion.display(from:) owns the rule that an unusable one says \
            "unknown" rather than drawing a blank tail.
            """)
    }
}

/// Where each moved control is allowed to be named, and where it is not.
///
/// Read through `surfaceCode(named:)`, so COMMENT-STRIPPED, and that is
/// load-bearing rather than incidental — the same discriminator the version
/// guard above rests on, pointed the other way.
///
/// THE INVERSION THIS AVOIDS, which is the third instance of the pattern in
/// this file's neighbourhood. The version guard was BLIND when read raw: a
/// comment naming the seam satisfied it while `body` rendered nothing. The
/// selector guard in `AppLayerBoundary_test.swift` was INVERTED when read raw:
/// prose describing the thing it forbade turned it red on a correct tree. The
/// negative half below — `!panel.contains(control)` — is inverted the same way,
/// because moving a control is exactly when somebody writes a comment in the
/// old surface saying where it went.
///
/// That comment is not hypothetical and this guard is not merely protected from
/// it — it is PINNED BY IT. `PanelView.swift` names all three of these
/// properties in the prose beside its `SettingsLink`, deliberately, so that a
/// raw read here fails. Swap `surfaceCode` for `String(contentsOf:)` and this
/// guard goes RED on a correct tree rather than silently widening, which is the
/// difference between a guard that defends the invariant and one that merely
/// happens to hold today. Measured, not reasoned: that mutation is run in
/// `.superpowers/sdd/2026-08-06-preferences-window/task-5-report.md` §6.
///
/// So the negative half discriminates CODE from PROSE, and both directions are
/// proven: prose naming the control keeps it green, a real binding turns it red.
@Test func eachMovedControlLivesInExactlyOneSurface() throws {
    // Named bug this catches: a control left behind in the panel during the
    // move, so the user has two of them and they disagree — or a refactor that
    // silently moves one back.
    //
    // WHICH SURFACE, not whether the user can reach it. `prefs.contains` below
    // is satisfied by `if false { … }` around every one of these three, which
    // was measured. `everyMovedControlIsRenderedAsUnconditionallyAsTheHeadingsAboveIt`
    // holds that half.
    let panel = try surfaceCode(named: "PanelView.swift")
    let prefs = try surfaceCode(named: "PreferencesView.swift")

    for control in ["holdDisplayAwake", "batteryFloorPercent", "quietEverythingElse"] {
        #expect(prefs.contains(control), "Preferences lost \(control)")
        #expect(!panel.contains(control), "\(control) is still in the panel")
    }
    // The Serving picker STAYS. This half is what makes the guard discriminate
    // rather than just assert everything moved.
    #expect(panel.contains("$model.intent"))
    #expect(!prefs.contains("$model.intent"))
}

@Test func theFloorSliderIsBuiltOverThePolicyAndAddsNoSecondBoundingSite() throws {
    // Named bug this catches: a UI that clamps. Bounding lives at PowerInputs.init
    // and WatchdogDecision — a third site is a value corrected in two places with
    // different rules.
    //
    // Comment-stripped, for the reason the guard above states, and here the
    // negative half needs it most: the honest way to record this decision is a
    // comment in `PreferencesView.swift` saying the view does NOT call
    // `BatteryFloor.bounded`, and against raw text that sentence is what turns
    // the guard red.
    let prefs = try surfaceCode(named: "PreferencesView.swift")
    #expect(prefs.contains("BatteryFloor.permitted"))
    #expect(prefs.contains("BatteryFloor.step"))
    #expect(!prefs.contains("BatteryFloor.bounded"))

    // REACHABILITY is held by
    // `everyMovedControlIsRenderedAsUnconditionallyAsTheHeadingsAboveIt` below.
    // The three assertions here are `contains`, and a `contains` cannot tell a
    // live control from a dead one.
}

/// The three moved controls are RENDERED, not merely SPELLED.
///
/// Every findability guard on this branch was a file-wide `contains` with no
/// reachability half, and a measured mutation defeated all four at once:
/// wrapping the Display `Picker`, the Battery floor `HStack` and the Focus
/// `Toggle` each in `if false { … }` left `swift test` at rc=0 with 856 tests
/// passing. The shipped window drew the two headings, the lid-closed sentence
/// and the Agent tools rows, and NO CONTROLS AT ALL — the three settings this
/// whole branch exists to relocate.
///
/// The four that were satisfied by that build:
///
///   - `thePreferencesWindowOffersTheDisplayHoldControlAndThePanelReportsItsResult`
///   - `thePreferencesWindowOffersTheQuietOthersControl`
///   - `theFloorSliderIsBuiltOverThePolicyAndAddsNoSecondBoundingSite`
///   - `eachMovedControlLivesInExactlyOneSurface`
///
/// THE REMEDY WAS ALREADY IN THE PACKAGE, one file over and a few lines away
/// from the controls it failed to cover.
/// `theLidClosedSummaryIsInThePreferencesWindowAndNotInThePanel`
/// (`AppLayerBoundary_test.swift`) holds the SENTENCE beside these controls with
/// exactly this mechanism, and its comment names `if false { … }` as the defeat
/// it closes. The prose was better defended than the settings.
///
/// BRACE DEPTH against an unconditional neighbour, which is that mechanism.
/// `Text("Power")` is the anchor because it is a section heading: a build where
/// THAT is conditional is not a build where this check is the problem. Wrapping
/// a sibling in an `if`, a `switch` or a closure adds a brace and moves it.
///
/// COMMENT-STRIPPED through `surfaceCode`, so the prose in `PreferencesView.swift`
/// that explains each control at length cannot satisfy any of this.
///
/// LIMITS, stated rather than hidden, and they are the sibling guard's limits
/// because it is the sibling guard's mechanism:
///
///   1. `swiftCodeWithoutComments` KEEPS string literals, so a `{` inside one
///      ahead of a needle would miscount. There is none today — the literals in
///      this file are labels like "Power" and "Battery floor".
///   2. It cannot prove the `ScrollView` and the `VStack` are themselves
///      reachable — a `body` that returns `EmptyView()` around the whole page
///      is invisible to a brace counter. Everything INSIDE them is held: the
///      anchor's depth is pinned absolutely rather than by inequality, so no
///      container may be added around a section without saying so, and the two
///      headings are compared to each other so neither section can be wrapped
///      as a unit.
///   3. It reads structure, not AppKit. M1 design §5.4 rules out asserting on a
///      rendered window, so no check in this package can watch a picker appear.
@Test func everyMovedControlIsRenderedAsUnconditionallyAsTheHeadingsAboveIt() throws {
    // Named bug this catches: a control disabled rather than deleted. `if false`
    // is the honest spelling; `if FeatureFlags.showDisplayControl` is the one
    // that arrives in a real change and reads as deliberate.
    let prefs = try surfaceCode(named: "PreferencesView.swift")

    let anchorDepth = try #require(braceDepth(atFirst: "Text(\"Power\")", in: prefs), """
        PreferencesView.swift no longer contains Text("Power"), so this guard \
        has no unconditional neighbour to compare against and measured nothing.
        """)

    // EXACTLY FOUR, and not `>= 3` like the sibling guard this borrows from.
    // The four are named: the `struct`, `body`, the `ScrollView` and the
    // `VStack`. Nothing else may enclose a section heading.
    //
    // The inequality is what leaves the hole, and the hole is reachable rather
    // than theoretical. Every other assertion here is RELATIVE, so wrapping the
    // Power section AND the Focus section in two separate `if false { … }`
    // blocks shifts every depth by one uniformly: the headings still agree with
    // each other, each control still agrees with its heading, `>= 3` still
    // holds, and the window ships with no controls at all. That is the same
    // defeat this guard exists to close, applied twice.
    //
    // THIS NUMBER IS A DESIGNED UPDATE POINT. A legitimate container — a `Form`,
    // a `GroupBox`, a `Section` — around the page turns this red, and the fix is
    // to change the number here and say which brace was added. Restoring the
    // inequality to silence it puts the hole back.
    #expect(anchorDepth == 4, """
        the section heading in PreferencesView.swift sits at brace depth \
        \(anchorDepth), not the four that the struct, body, ScrollView and \
        VStack account for. Either the page grew a container — say so here and \
        raise the number — or the Power section is wrapped in something, which \
        every relative check below would pass over because it moves the \
        controls and their heading together.
        """)

    // BOTH HEADINGS, compared to each other, and that is the half that stops a
    // whole section disappearing as a unit. Wrapping `Text("Power")` and the two
    // Power controls together moves all three equally, and every per-control
    // comparison below would still hold — the Focus heading is what stays put
    // and reports it.
    let focusDepth = try #require(braceDepth(atFirst: "Text(\"Focus\")", in: prefs), """
        PreferencesView.swift no longer contains Text("Focus"), so the Focus \
        section has no heading and this guard lost the neighbour that pins the \
        Power section against being wrapped as a whole.
        """)
    #expect(focusDepth == anchorDepth, """
        PreferencesView.swift puts Text("Focus") at brace depth \(focusDepth) \
        while Text("Power") sits at \(anchorDepth). One section heading is \
        inside something the other is not, so a whole section can be disabled \
        with every per-control check below still green.
        """)

    // Issue #48's section, held the same way and for the same reason. It is the
    // only section on this page whose control leaves an artifact on disk, so a
    // section wrapped as a unit here does not merely hide a switch: it hides the
    // switch that REMOVES the launch agent, from a user who can still have one.
    let startupDepth = try #require(braceDepth(atFirst: "Text(\"Startup\")", in: prefs), """
        PreferencesView.swift no longer contains Text("Startup"), so the login \
        item has no section and the user has no way to turn it off.
        """)
    #expect(startupDepth == anchorDepth, """
        PreferencesView.swift puts Text("Startup") at brace depth \(startupDepth) \
        while Text("Power") sits at \(anchorDepth). The Startup section is inside \
        something the Power section is not, so it can be disabled as a unit with \
        the per-control check below still green.
        """)

    // The nesting each control is ALLOWED, and naming what the braces are is
    // what makes this readable. Nought means a direct child of the `VStack`,
    // beside the headings. The slider's one is the `HStack` that carries its
    // label and its readout — a row, not a condition.
    //
    // THIS TABLE IS A DESIGNED UPDATE POINT, the same shape as
    // `versionSurfaces` above. Wrapping the floor row in a `GroupBox` for
    // legitimate reasons turns this red, and the fix is to say so here. Widening
    // the assertion to `<=` is what must NOT happen: `if false { Slider(…) }` in
    // the VStack sits at exactly the depth the HStack row does, so an inequality
    // passes over the mutation this guard exists to catch.
    let allowedNesting = [
        (needle: "$model.holdDisplayAwake", braces: 0, control: "the Display picker", enclosing: "nothing"),
        (needle: "Slider(", braces: 1, control: "the Battery floor slider", enclosing: "its HStack row"),
        // Issue #74's control, and its needle is the POLICY rather than
        // `Slider(` because `braceDepth(atFirst:)` takes the first match and the
        // battery floor's slider is spelled first. `LidClosedHold.permitted`
        // sits in the `in:` argument, which is one brace — the `HStack` row —
        // below the heading, exactly where the floor's `Slider(` sits. A
        // `if false { Slider(… in: LidClosedHold.permitted …) }` in the VStack
        // lands one brace deeper and turns this red.
        (needle: "LidClosedHold.permitted", braces: 1, control: "the Lid-closed hold slider",
         enclosing: "its HStack row"),
        (needle: "$model.quietEverythingElse", braces: 0, control: "the Quiet everything else toggle", enclosing: "nothing"),
        // Issue #48's control. Its needle is the BINDING rather than
        // `Toggle(`, for the reason the agent-tool row's is `Toggle(isOn:`:
        // `braceDepth(atFirst:)` takes the first match and the Quiet everything
        // else toggle is spelled earlier in the file. A binding also refuses
        // what a property would satisfy — `model.launchAtLogin` alone displays
        // the value, and a switch the user can read and not flip is not a
        // switch. That distinction matters more here than anywhere else on the
        // page: an unflippable control over an installed launch agent is an
        // install with no uninstall.
        (needle: "$model.launchAtLogin", braces: 0, control: "the Open at login toggle", enclosing: "nothing"),
        // Issue #51's control, and the two braces are its row rather than a
        // condition: the `ForEach` closure over `AgentTool.allCases`, then the
        // `HStack` that carries the path and the buttons. `Toggle(isOn:` and not
        // `Toggle(`, because the Quiet everything else toggle above spells its
        // label first and `braceDepth(atFirst:)` would find that one.
        (needle: "Toggle(isOn:", braces: 2, control: "the agent tool selection",
         enclosing: "its ForEach row and that row's HStack"),
    ]

    for control in allowedNesting {
        let depth = try #require(braceDepth(atFirst: control.needle, in: prefs), """
            PreferencesView.swift names \(control.needle) nowhere in code, so \
            \(control.control) is gone from the window this branch moved it to.
            """)

        #expect(depth == anchorDepth + control.braces, """
            PreferencesView.swift renders \(control.control) at brace depth \
            \(depth), and the only brace between it and the unconditional \
            Text("Power") at \(anchorDepth) should be \(control.enclosing). It \
            is inside something the heading is not — an `if`, a `switch`, a \
            closure — so the control is present in the file and the user may \
            never reach it. `if false { … }` around this control keeps every \
            `contains` check in this package green while the window ships with \
            nothing to click.
            """)
    }
}

@Test func thePreferencesWindowOffersTheLoginItemAndSaysWhatItWrites() throws {
    // PRESENCE, the same tripwire shape as `thePreferencesWindowOffersTheQuietOthersControl`
    // and for a sharper version of the same reason: `SettingsKey` can hold the
    // key, `ServingModel` can store it and `LoginItemInstaller` can write a
    // perfectly good launch agent with every check in this package green while
    // no surface offers a way to turn ANY of it on — the shape `ProcGovernor`
    // and `LaunchDaemonInstaller` both shipped in, which issue #13 exists to
    // complain about.
    //
    // The issue asks for this on the PANEL. The panel is not available this
    // wave, so it is here; a panel affordance is a follow-up, and both surfaces
    // would bind this same property when it arrives.
    //
    // The NOTE is held beside the control rather than in a separate check,
    // because the two are one decision: this is the only control on the page
    // that puts a file in the user's home directory, and the sentence naming
    // that file is what makes the switch honest. A window that offered the
    // toggle and dropped the sentence would install an artifact nothing on any
    // surface accounts for.
    //
    // COMMENT-STRIPPED through `surfaceCode`, for the reason the quiet-others
    // guard gives: `PreferencesView.swift` explains every control at length, so
    // a raw read would be satisfied by the prose about the thing it deleted.
    //
    // REACHABILITY is held by `everyMovedControlIsRenderedAsUnconditionallyAsTheHeadingsAboveIt`
    // above, which pins this binding's brace depth. The assertions here are
    // `contains`, and a `contains` cannot tell a live control from a dead one.
    let prefs = try surfaceCode(named: "PreferencesView.swift")

    // The BINDING, not the property: `model.launchAtLogin` would be satisfied
    // by a line that merely displays the position.
    #expect(prefs.contains("$model.launchAtLogin"), """
        PreferencesView.swift binds no control to model.launchAtLogin, so the \
        login item can be stored, installed and honoured and the user can \
        neither turn it on nor take it off again.
        """)

    #expect(prefs.contains("ServingModel.launchAtLoginLabel"), """
        PreferencesView.swift names its own label for the login-item control. It \
        belongs on ServingModel beside the other control labels, where \
        theLoginItemLabelSaysWhatTheSwitchDoesAndPromisesNothingElse reads it — \
        design §5.4 rules out asserting on rendered AppKit text, so a literal \
        here is a claim nothing in this package could check.
        """)

    #expect(prefs.contains("ServingModel.launchAtLoginNote"), """
        PreferencesView.swift renders no note beside the login-item switch, so \
        the one control on this page that writes a file into the user's home \
        directory does not say which file. Rendered verbatim from the model for \
        the reason every other sentence on this page is.
        """)
}

@Test func thePreferencesWindowNeverWritesAnAgentToolsSettingsFile() throws {
    // Named bug this catches: phase 2 arriving by accident. M2 ingest design §6
    // is "print, never write" — each of those files is shared territory, and
    // this workspace records a six-occurrence last-writer-wins clobber in
    // exactly that kind of config. A window offering a Copy button is one small
    // step from a window offering to do the paste for you, and the step is the
    // sort a helpful refactor takes without being asked.
    //
    // COMMENT-STRIPPED, and here that matters in the INVERTED direction rather
    // than the blind one, the way it does for the slider guard above: the
    // honest way to record this decision is a sentence in
    // `PreferencesView.swift` saying the window writes nothing, and against raw
    // text that sentence is what would turn this guard red on a correct tree.
    //
    // `forbiddenWriteCalls` is the list `HookHealthReader_test.swift` already
    // holds this same line with, one target over. Reused rather than restated,
    // for the reason this file reuses the lexer and the brace reader: a second
    // list disagrees with the first eventually, and then two guards argue about
    // what a write is.
    let prefs = try surfaceCode(named: "PreferencesView.swift")

    for call in forbiddenWriteCalls {
        #expect(!prefs.contains(call), """
            PreferencesView.swift names \(call). Design §6 forbids this window \
            putting bytes into an agent tool's settings file: print the snippet \
            to the pasteboard and let the user paste it.
            """)
    }

    // DISCRIMINATES. Without this half the guard passes over a window with no
    // Agent tools section at all — including this very window as it stood
    // before this task, which wrote nothing because it did nothing. A guard
    // that holds over the empty case is not holding anything.
    #expect(prefs.contains("NSPasteboard"), """
        PreferencesView.swift never reaches the pasteboard, so the no-write \
        loop above is asserting over a window that offers no snippet to copy. \
        It would hold just as well over an empty view.
        """)
}

@Test func theCopyActionOffersEveryToolTheCheckerCanAdviseAbout() throws {
    // Named bug this catches: a section wired to a hardcoded two tools, so the
    // third stays uncopyable for ever. `ServingModel.hookAdvisory` iterates
    // `AgentTool.allCases`, so it will tell the user about a file this window
    // would then give them no way to fix — advice with no remedy beside it.
    for tool in AgentTool.allCases {
        #expect(HookSnippet.json(for: tool) != nil, "\(tool) has no snippet to copy")
    }

    // That loop is a claim about `HookSnippet`, and `HookSnippet_test.swift`
    // holds the deep version of it. On its own it says NOTHING about this
    // window: it stays green over a window that offers one tool, or none.
    //
    // So the half that matters here is that the section is built OVER the same
    // list. Scoped to `body` with the two `braceBlock` calls the version guard
    // above uses, and for the same reason — a `contains` over the whole file is
    // satisfied by a helper that no rendered surface reaches.
    let code = try surfaceCode(named: "PreferencesView.swift")
    let declared = try #require(braceBlock(after: "struct PreferencesView: View", in: code), """
        PreferencesView.swift declares no `struct PreferencesView: View`, so \
        this guard names a surface the package no longer has.
        """)
    let body = try #require(braceBlock(after: "var body: some View", in: declared.block),
                            "PreferencesView declares no body to render a section into.")

    // Each seam is the ONLY public route to what it provides, so naming it is
    // not a stylistic preference. `HookSnippet.command(for:)` is internal to
    // `CoffeeBarCore` and cannot be reached from here at all; `defaultURL(for:)`
    // is the one place in the package that resolves a home directory.
    for seam in ["AgentTool.allCases",
                 "HookSnippet.json(for:",
                 "HookHealthReader.defaultURL(for:"] {
        #expect(body.block.contains(seam), """
            PreferencesView.body does not name \(seam), so the Agent tools \
            section is not built over the tool list the advisory beside it is \
            built over. A section naming its tools one at a time leaves the \
            next tool uncopyable and nothing here would see it.
            """)
    }
}

@Test func everyToolRowOffersTheChoiceTheAdvisoryIsNarrowedBy() throws {
    // Issue #51: the user says which tools they run, and until this window
    // offers that choice the setting is one only `defaults write` can reach.
    //
    // Named bug this catches: the model gaining `advises(_:)` and
    // `setAdvises(_:for:)` with nothing bound to them. Every model-side check
    // stays green — the property works perfectly — and the window ships with no
    // way to answer the question, which is the state this task found the
    // product in.
    //
    // BOTH DIRECTIONS, and that is what makes it a control rather than a
    // readout. A row that reads `model.advises(tool)` and never writes back is a
    // checkbox that cannot be ticked; one that writes without reading shows the
    // wrong state until the window is reopened.
    //
    // Scoped to `body` with the same two `braceBlock` calls the guards above
    // use, and for the same reason: a `contains` over the whole file is
    // satisfied by a helper no rendered surface reaches.
    // `everyMovedControlIsRenderedAsUnconditionallyAsTheHeadingsAboveIt` holds
    // the reachability half, through the entry this task adds to its table.
    let code = try surfaceCode(named: "PreferencesView.swift")
    let declared = try #require(braceBlock(after: "struct PreferencesView: View", in: code), """
        PreferencesView.swift declares no `struct PreferencesView: View`, so \
        this guard names a surface the package no longer has.
        """)
    let body = try #require(braceBlock(after: "var body: some View", in: declared.block),
                            "PreferencesView declares no body to render a section into.")

    #expect(body.block.contains("model.advises("), """
        PreferencesView.body never reads which tools the user runs, so the \
        selection control shows a state the panel does not act on.
        """)
    #expect(body.block.contains("model.setAdvises("), """
        PreferencesView.body never records the user's choice, so the only way \
        to reach the setting issue #51 adds is `defaults write`.
        """)
    #expect(body.block.contains("ServingModel.agentToolsLabel"), """
        PreferencesView.body composes its own sentence about the selection. M1 \
        design §5.4 rules out asserting on rendered AppKit text, so a sentence \
        written here is a sentence no check reads.
        """)
}

/// The label the copy button carries, read out of `PreferencesView.body`.
///
/// **Derived, never restated.** The point of the guard below is that the
/// DOCUMENTS follow the WINDOW, so the window's own literal is the only
/// admissible source for it. A label typed into the test as well would make the
/// test agree with itself while the button was renamed underneath both.
///
/// Identified by what the button DOES rather than by what it says: the one whose
/// action reaches `HookSnippet.json(for:`. That is the seam
/// `theCopyActionOffersEveryToolTheCheckerCanAdviseAbout` already pins, so the
/// two guards name the same button by the same evidence.
///
/// The `{0,240}` bound is a real limit and not a round number: `[\s\S]*?` would
/// let this match a `Button` several controls earlier whose closure happens to
/// be followed, much later in `body`, by an unrelated call to `json(for:)`. The
/// bound keeps the match inside one control. Measured against the current file,
/// the gap from `Button(` to `HookSnippet.json(for:` is 46 characters.
private func copyButtonLabel(in body: String) throws -> String {
    let pattern = try NSRegularExpression(
        pattern: "Button\\(\"([^\"]+)\"\\)\\s*\\{[\\s\\S]{0,240}?HookSnippet\\.json\\(for:")
    let ns = body as NSString
    let found = pattern.matches(in: body, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range(at: 1)) }

    // EXACTLY one. Zero means the button is gone — which is the failure this
    // whole guard exists for — and it must not read as "nothing to check".
    // More than one means the scan cannot say which label the docs should
    // quote, and picking the first would be a coin toss dressed as a check.
    guard found.count == 1, let label = found.first else {
        throw SurfaceScanError.notOneFile(name: "Button(…) { … HookSnippet.json(for: …",
                                          found: found)
    }
    return label
}

@Test func theDocumentedCopyFlowNamesTheButtonTheWindowOffers() throws {
    // Named bug this catches, and it is issue #66 in both directions.
    //
    // FORWARD: the button shipped as this branch's answer to #37 and no
    // document mentioned it — `grep -i "copy hook" README.md docs/ site/`
    // returned nothing, while `docs/QUICKSTART.md` §2 went on teaching a reader
    // to hand-copy a curl line into three files. The documented path was the
    // error-prone one, and #55 and #64 are both hand-written hook configs
    // failing invisibly.
    //
    // BACKWARD, which is the half the issue asks for explicitly: the button is
    // deleted or renamed in a later refactor and two pages are left describing
    // a control that is not there. A reader then hunts a Preferences window for
    // something that does not exist and concludes the app is broken.
    //
    // COMMENT-STRIPPED, for the reason every guard in this file is: the section
    // is explained at length in `PreferencesView.swift`'s own comments, and a
    // raw read would find the label in prose describing a button that had been
    // deleted.
    let code = try surfaceCode(named: "PreferencesView.swift")
    let declared = try #require(braceBlock(after: "struct PreferencesView: View", in: code), """
        PreferencesView.swift declares no `struct PreferencesView: View`, so \
        this guard names a surface the package no longer has.
        """)
    let body = try #require(braceBlock(after: "var body: some View", in: declared.block),
                            "PreferencesView declares no body to render a section into.")

    let label = try copyButtonLabel(in: body.block)

    // The two pages a stranger follows. Both, because they are separate
    // documents with separate readers: the quick start is what a builder reads
    // and the install page is what a downloader reads, and #66 names both.
    for page in ["docs/QUICKSTART.md", "site/install.html"] {
        let text = try String(contentsOf: packageRoot.appending(path: page), encoding: .utf8)
        #expect(text.contains(label), """
            \(page) never names "\(label)", the button PreferencesView offers \
            beside each agent tool's settings file. The page therefore teaches \
            hand-editing as the only route, and the button emits the events the \
            health check actually looks for and the endpoint for the tool the \
            reader picked — neither of which the hand-written block explains.
            """)
    }
}

/// The scope note issue #73 adds is RENDERED, and it sits under BOTH controls.
///
/// Two properties, and the second is the one #74 made necessary. A sentence
/// that scopes the battery floor is worth nothing if the user never reaches it,
/// and it is worse than nothing if it sits ABOVE the "Lid-closed hold" slider:
/// `PreferencesView.swift` states the placement rule itself — "a paragraph above
/// a slider reads as instructions for the slider" — so a note placed between the
/// two controls would be read as describing the lid-closed one alone, which is
/// the confusion it exists to remove.
///
/// BRACE DEPTH for the first half, borrowed from
/// `everyMovedControlIsRenderedAsUnconditionallyAsTheHeadingsAboveIt` above
/// along with the defect that guard records: wrapping a member of this page in
/// `if false { … }` left the whole suite green while the window shipped without
/// it. A `contains` cannot tell a live paragraph from a dead one.
///
/// SOURCE ORDER for the second half. It reads the comment-stripped body, so the
/// long prose in `PreferencesView.swift` explaining each control cannot satisfy
/// any of it, and each anchor is the needle that file's own guards already use
/// for that control.
@Test func theScopeNoteIsRenderedUnconditionallyUnderBothPowerControls() throws {
    // Named bug this catches: the note added to the file, disabled behind a
    // condition, or filed under the lid-closed paragraph as a third sentence
    // about the mode rather than as a statement about the two sliders.
    let prefs = try surfaceCode(named: "PreferencesView.swift")

    let anchorDepth = try #require(braceDepth(atFirst: "Text(\"Power\")", in: prefs), """
        PreferencesView.swift no longer contains Text("Power"), so this guard \
        has no unconditional neighbour to compare against and measured nothing.
        """)
    let noteDepth = try #require(braceDepth(atFirst: "powerScopeNote", in: prefs), """
        PreferencesView.swift names powerScopeNote nowhere in code, so the \
        window never tells the user which holds the battery floor governs — \
        which is issue #73 with a string added to the model and nothing shown.
        """)
    // EQUAL, not `<=`. The note is a direct child of the same `VStack` the two
    // headings sit in, so any brace between it and `Text("Power")` is a
    // condition or a closure the heading is not inside.
    #expect(noteDepth == anchorDepth, """
        PreferencesView.swift renders the scope note at brace depth \(noteDepth) \
        while the unconditional Text("Power") sits at \(anchorDepth). The \
        sentence is inside something the heading is not — an `if`, a `switch`, a \
        closure — so it is in the file and the user may never see it.
        """)

    // Each anchor is the needle the control's own guard uses:
    // `BatteryFloor.permitted` and `LidClosedHold.permitted` are how
    // `everyMovedControlIsRenderedAsUnconditionallyAsTheHeadingsAboveIt` finds
    // the two sliders, and `lidClosedSummary` is the paragraph about the mode
    // itself — which since issue #71k is silent whenever the registered helper
    // is the one holding the machine, so it is also the one member of this
    // group whose height is not fixed.
    let floorSlider = try #require(prefs.range(of: "BatteryFloor.permitted"),
                                   "the Battery floor slider is gone from the window")
    let holdSlider = try #require(prefs.range(of: "LidClosedHold.permitted"),
                                  "the Lid-closed hold slider is gone from the window")
    let note = try #require(prefs.range(of: "powerScopeNote"))
    let command = try #require(prefs.range(of: "lidClosedSummary"),
                               "the paragraph carrying the root command is gone from the window")

    #expect(floorSlider.upperBound < note.lowerBound, """
        the scope note is rendered ABOVE the Battery floor slider, so the \
        sentence that says what that slider governs arrives before the reader \
        has met it.
        """)
    #expect(holdSlider.upperBound < note.lowerBound, """
        the scope note is rendered between the Battery floor slider and the \
        Lid-closed hold slider. PreferencesView.swift's own rule is that a \
        paragraph above a slider reads as instructions for that slider, so a \
        note placed here scopes the lid-closed control instead of both — the \
        #74 confusion it was added to remove.
        """)
    #expect(note.upperBound < command.lowerBound, """
        the scope note is rendered below the lid-closed paragraph. It belongs \
        directly beneath the two sliders it scopes, which is where a caption is \
        read from — and that paragraph is silent whenever the registered helper \
        is active (#71k), so a note placed under it slides up and down the \
        window with a state it says nothing about.
        """)
}

@Test func theUpdateSectionStatesItsIntervalAndItsLastCheckUnconditionally() throws {
    // CONSTRAINT 4 of issue #29, and `docs/ROADMAP.md`'s "no hidden durations"
    // is what makes it a constraint rather than a nicety: a period the user
    // cannot see, cannot change and did not ask for is exactly what that
    // principle forbids. coffee-bar posts one request a day off this machine,
    // so the sentence saying so has to be on the window rather than in a commit
    // message — and the time of the last one has to be there beside it, because
    // an interval nobody can check against anything is a claim, not a fact.
    //
    // Named bug this catches: the section shipped behind `if false`, or behind
    // an `if model.updateVerdict != nil` that hides the interval note from
    // every user who has not checked yet — which is every user at first launch,
    // the exact moment the sentence is worth reading.
    let prefs = try surfaceCode(named: "PreferencesView.swift")

    let anchorDepth = try #require(braceDepth(atFirst: "Text(\"Power\")", in: prefs), """
        PreferencesView.swift no longer contains Text("Power"), so this guard \
        has no unconditional neighbour to compare against and measured nothing.
        """)

    // The heading first, held against the OTHER headings rather than against a
    // number, so a legitimate container added around the whole page moves all
    // of them together and this stays green while
    // `everyMovedControlIsRenderedAsUnconditionallyAsTheHeadingsAboveIt` — which
    // pins the absolute depth — is the one that reports it.
    let headingDepth = try #require(braceDepth(atFirst: "Text(\"Updates\")", in: prefs), """
        PreferencesView.swift no longer contains Text("Updates"), so the window \
        has no update section at all.
        """)
    #expect(headingDepth == anchorDepth, """
        PreferencesView.swift puts Text("Updates") at brace depth \
        \(headingDepth) while Text("Power") sits at \(anchorDepth), so the \
        update section is inside something the other sections are not.
        """)

    // Each line of the section, and the braces it is ALLOWED. Nought is a
    // direct child of the `VStack`, beside the headings; the button and the
    // last-check line share one `HStack` row.
    //
    // EQUALITY and not `<=`, for the reason the sibling table gives: an
    // `if false { … }` inside the VStack lands at exactly the depth an HStack
    // row does, so an inequality passes over the mutation this exists to catch.
    let allowedNesting = [
        (needle: "UpdateCheck.intervalNote", braces: 0,
         line: "the sentence stating how often coffee-bar checks", enclosing: "nothing"),
        (needle: "model.updateStatusLine", braces: 0,
         line: "the sentence stating what the last check concluded", enclosing: "nothing"),
        (needle: "Button(\"Check now\")", braces: 1,
         line: "the Check now button", enclosing: "its HStack row"),
        (needle: "model.lastUpdateCheckLine", braces: 1,
         line: "the last-checked time", enclosing: "its HStack row"),
    ]

    for line in allowedNesting {
        let depth = try #require(braceDepth(atFirst: line.needle, in: prefs), """
            PreferencesView.swift names \(line.needle) nowhere in code, so \
            \(line.line) is absent from the window.
            """)
        #expect(depth == anchorDepth + line.braces, """
            PreferencesView.swift renders \(line.line) at brace depth \(depth), \
            and the only brace between it and the unconditional Text("Power") \
            at \(anchorDepth) should be \(line.enclosing). It is inside \
            something the headings are not — an `if`, a `switch`, a closure — \
            so the user may never see it, and the interval this feature runs on \
            becomes a hidden duration.
            """)
    }
}

@Test func thePreferencesWindowComposesNoUpdateSentenceOfItsOwn() throws {
    // M1 design §5.4 forbids asserting on rendered AppKit text, so a sentence
    // written in this file is a sentence no check reads — which is how this
    // window came to promise a scope nobody had checked (issue #73). The update
    // section makes two claims a user will act on: how often coffee-bar reaches
    // the network, and whether they are running the newest build. Both are
    // rendered verbatim from a seam that IS checked.
    //
    // Named bug this catches: `Text("Checks daily")` written here, beside an
    // `interval` constant that says something else.
    let prefs = try surfaceCode(named: "PreferencesView.swift")

    for invented in ["once a day", "installs nothing", "up to date", "Last checked"] {
        #expect(!prefs.contains(invented), """
            PreferencesView.swift composes the phrase "\(invented)" itself. The \
            update sentences live on UpdateCheck and on the model, where \
            UpdateCheck_test.swift reads them against the constant they \
            describe; a second spelling here can disagree with the interval the \
            code enforces and nothing would see it.
            """)
    }
}

@Test func thePreferencesWindowNeverReachesTheNetworkItself() throws {
    // The window OFFERS the check and does not MAKE it. Issue #29 permits
    // exactly one file to reach the network, and a view that built its own
    // session would be a second — reached from a button, which is the shortest
    // path anyone would take.
    //
    // `AppLayerBoundary_test.swift` holds the same line over every linked file
    // and is the authority. This is stated here as well because this is the
    // surface where the temptation lives, and a reader of this window's guards
    // should not have to go and find that out.
    let prefs = try surfaceCode(named: "PreferencesView.swift")

    for name in ["URLSession", "URLRequest", "PublishedManifestFetcher"] {
        #expect(!prefs.contains(name), """
            PreferencesView.swift names \(name) in CODE. The window asks the \
            model, the model asks the one entitled fetcher, and nothing else in \
            this application opens a connection.
            """)
    }
}

/// The app layer's entry point, comment-stripped.
///
/// A resolver of its own, because `surfaceCode(named:)` walks `Sources/` by file
/// name and FOUR targets in this package compile a `main.swift` — it would
/// resolve four files and throw rather than answer. The path is explicit here.
///
/// SwiftPM treats `main.swift` as top-level code that no test target can import,
/// which is why a source read is the only route to it at all;
/// `theAppDeclaresTheSettingsSceneThePanelLinksTo` says the same about the scene.
private func appEntryPointCode() throws -> String {
    return swiftCodeWithoutComments(
        try String(contentsOf: packageRoot.appending(path: "Sources/CoffeeBarApp/main.swift"),
                   encoding: .utf8))
}

@Test func theAppDrivesTheAutomaticUpdateCheckAtLaunchAndTheWindowNoLongerDoes() throws {
    // RETARGETED from `PreferencesView.onAppear` to `main.swift`, and this is
    // the move `PreferencesView.swift` itself booked: "WHEN THE PANEL GAINS ITS
    // OWN COPY (the deferred half of issue #29) this moves to App.init, because
    // the answer will then be visible without opening anything." The panel now
    // has it, so this is that move. The invariant did not change — exactly one
    // automatic trigger, honouring the interval — only the surface that owns it.
    //
    // WHY IT HAD TO MOVE RATHER THAN BE ADDED. `.onAppear` fires when the
    // window is CREATED and not when an existing one is re-presented; issue
    // #126 established that by measurement, and it is why the trigger was never
    // going to stay there. Leaving it in place beside a launch trigger would
    // also be the "no duplicate scheduling" failure: two callers of the same
    // interval-gated check, each able to make the request the other's stamp was
    // meant to prevent.
    //
    // BOTH ENDS ARE HELD, because either alone reads as a working feature. The
    // launch trigger without the removal is two schedulers; the removal without
    // the launch trigger is a stated daily check that nothing ever makes, and
    // the panel would say "has not looked yet" for ever to every user who never
    // presses the button.
    let main = try appEntryPointCode()
    let prefs = try surfaceCode(named: "PreferencesView.swift")

    // `checkForUpdatesIfDue` and NOT `checkForUpdates`, and the difference is
    // the interval itself. A guard that accepted either name would pass the
    // version of this line that turns a stated daily check into a request every
    // time the app is launched — and a menu-bar app is launched at login.
    #expect(main.contains("checkForUpdatesIfDue()"), """
        main.swift never asks whether a newer version is published, so the \
        automatic half of issue #29 is wired nowhere. The interval both \
        surfaces state then governs nothing: coffee-bar would look only when \
        the user presses Check now, and a user who never presses it is never \
        told about a release.
        """)

    #expect(!prefs.contains("checkForUpdatesIfDue"), """
        PreferencesView.swift still drives the automatic check. It is driven \
        from main.swift at launch now, so this is a SECOND scheduler for one \
        request: opening the window can post the check the launch stamp was \
        meant to have covered, and the sentence saying when coffee-bar looks \
        can no longer be true of both.
        """)

    // The window keeps its BUTTON, and that is not the same thing. Removing the
    // automatic trigger from this file is correct; removing the manual one
    // would take the control the update section is built around.
    #expect(prefs.contains("model.checkForUpdates()"), """
        PreferencesView.swift no longer offers the manual check either. Moving \
        the automatic trigger to launch was the change; the Check now button is \
        the surface's own control and stays.
        """)
}

// MARK: - Issue #142: the button whose title offers a copy it refused to make

/// The arm button's trailing closure, and the `.disabled(...)` argument chained
/// onto it, read out of `code` by balancing delimiters.
///
/// `braceBlock` alone cannot answer this. It returns the closure and "the rest",
/// which puts the text BEFORE the button and the text AFTER it into one string,
/// so a `contains` over the rest cannot tell this control's `.disabled` clause
/// from the removal control's identical-looking one forty lines below. What is
/// at issue here is precisely WHICH clause carries the availability term, so the
/// reader has to stay anchored.
///
/// LIMIT, stated rather than hidden. If the arm button loses its `.disabled`
/// modifier entirely this walks forward to the next one it finds, which is a
/// different control. The `Button(` check below refuses that case rather than
/// reading the wrong clause and passing. Delimiters are balanced structurally,
/// not parsed, which is the same limit `braceBlock` carries: a brace or a paren
/// inside a string literal would misbalance the count, and there is none on this
/// surface today.
private func armButtonParts(in code: String) -> (closure: String, disabled: String)? {
    guard let anchor = code.range(of: "Button(helperAvailability.buttonTitle)"),
          let open = code[anchor.upperBound...].firstIndex(of: "{") else { return nil }

    var braces = 0
    var cursor = open
    var closureEnd: String.Index?
    while cursor < code.endIndex {
        if code[cursor] == "{" { braces += 1 }
        if code[cursor] == "}" {
            braces -= 1
            if braces == 0 {
                closureEnd = code.index(after: cursor)
                break
            }
        }
        cursor = code.index(after: cursor)
    }
    guard let closureEnd else { return nil }

    guard let modifier = code[closureEnd...].range(of: ".disabled(") else { return nil }
    // Nothing between the closure and the modifier may open another control.
    // Without this, a button that lost its own `.disabled` would be measured by
    // the removal control's, which carries no availability term and would pass.
    guard !code[closureEnd ..< modifier.lowerBound].contains("Button(") else { return nil }

    var parens = 0
    var scan = code.index(before: modifier.upperBound)
    while scan < code.endIndex {
        if code[scan] == "(" { parens += 1 }
        if code[scan] == ")" {
            parens -= 1
            if parens == 0 {
                return (String(code[open ..< closureEnd]),
                        String(code[modifier.upperBound ..< scan]))
            }
        }
        scan = code.index(after: scan)
    }
    return nil
}

@Test func theArmButtonIsNotDisabledOnTheBuildWhoseTitleOffersACopy() throws {
    // Issue #142, observed on a local build stamped 0.3.0-unsigned. It is ONE
    // button whose title flips: `.registrable` reads "Arm lid-closed mode" and
    // `.unavailable` reads "Copy the command instead". The clause
    // `|| helperAvailability == .unavailable` in the `.disabled` modifier is
    // exactly what greys out the second title, so the control names an action
    // and refuses to perform it.
    //
    // The Homebrew bundle is where this bites. It is ad-hoc signed, so it always
    // takes that branch, and the greyed button is the only route the product
    // offers to lid-closed mode there.
    //
    // COMMENT-STRIPPED, for the reason `surfaceCode` gives: this file explains
    // every control at length, and the paragraph above the button discusses
    // availability. A raw read would find the term in the prose and report the
    // defect present on a corrected view.
    //
    // WHITESPACE REMOVED, for the reason the boundary guards give: the calls
    // here wrap over several lines, so a needle carrying an argument label never
    // matches the raw text.
    let code = try surfaceCode(named: "PreferencesView.swift")
        .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)

    let parts = try #require(armButtonParts(in: code), """
        PreferencesView.swift no longer has a Button(helperAvailability.buttonTitle) \
        with a closure and a .disabled modifier of its own reachable after it, so \
        this guard measured nothing at all.
        """)

    // THE DEFECT. Availability decides what the click DOES, and it must not
    // decide whether the click is possible.
    #expect(!parts.disabled.contains("helperAvailability"), """
        the arm button is disabled on a term derived from helperAvailability:
          .disabled(\(parts.disabled))
        On an unsigned or Homebrew build that is the button titled "Copy the \
        command instead", greyed out, and it is the only route that build has \
        to lid-closed mode.
        """)

    // ANTI-VACUITY, and the in-flight gate in its own right. An empty or
    // unrelated argument would satisfy the assertion above while proving
    // nothing, and dropping `armingInFlight` queues a second root request behind
    // an approval the user has not answered yet.
    #expect(parts.disabled.contains("armingInFlight"), """
        the .disabled clause read as "\(parts.disabled)", which does not gate on \
        a click already in flight. Either this guard is reading the wrong \
        modifier, or a second press can queue a second registration request \
        against a decision macOS is still waiting on.
        """)

    // WHAT the click does comes from the model side. A `switch` on
    // `helperAvailability` written in the closure would work and would be a
    // decision no check can read, because M1 design §5.4 forbids asserting on
    // rendered AppKit text. `theButtonThatOffersToCopyTheCommandCopiesTheCommand`
    // holds the mapping itself.
    #expect(parts.closure.contains("helperAvailability.buttonAction"), """
        the button's closure does not read helperAvailability.buttonAction, so \
        what the click does is decided in a View and no check can reach it.
        """)

    // The copy REACHES THE PASTEBOARD, and carries the action's own payload
    // rather than a second spelling of the command composed here. Named bug: a
    // closure that flips the title, enables the control and copies nothing, or
    // copies a string this file built that has drifted from lidClosedCommand.
    #expect(parts.closure.contains("setString(command,forType:.string)"), """
        the button's closure never writes the copyCommand payload to the \
        pasteboard, so the enabled control still performs no copy.
        """)

    // BOTH branches are present. Named bug: a fix that turns every press into a
    // copy, which passes every assertion above and deletes the control issue #71
    // added on the one build that can register a helper.
    //
    // The arm branch is named by its CASE and by what it does with the reply,
    // never by spelling the call. `RealRegistrationHazard_test.swift` scans this
    // tree for a real-team signature source meeting a privileged call, and its
    // lexer keeps string literals on purpose (limit 4 on that file): a needle
    // reading `PrivilegedHelperClient().arm(seconds:` here is text, but it reads
    // to that scan as the real thing, and it reported this test as one that
    // could register the helper on the machine running `swift test`. The noisy
    // direction is deliberate there, so the needle moves rather than the scan.
    #expect(parts.closure.contains("case.arm:"), """
        the button's closure has no arm branch, so the signed build's button \
        does not arm anything.
        """)
    #expect(parts.closure.contains("helperStatus=outcome.statusLine"), """
        the arm branch does not show the helper's own reply, so the sentence \
        after a click is composed somewhere no check reads, or not at all.
        """)
    #expect(parts.closure.contains("case.copyCommand(letcommand):"), """
        the button's closure does not bind the command out of the action, so \
        whatever it copies is a second spelling built in this View.
        """)
}
