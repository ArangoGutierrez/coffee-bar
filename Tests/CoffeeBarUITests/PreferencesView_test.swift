// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import CoffeeBarCore

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
/// four matches standing, all of them comments. `PanelView.swift:64-69` already
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
        // sits in exactly one place — `AppVersion.swift:16`,
        // `static let bundleKey = "CFBundleShortVersionString"` — and neither
        // scanned file is that one. Fold `AppVersion.display(from:)` into
        // `PanelView.swift` and this expectation goes RED over a correct tree,
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
