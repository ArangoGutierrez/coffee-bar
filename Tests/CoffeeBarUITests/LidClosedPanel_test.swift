// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import CoffeeBarPower
@testable import CoffeeBarUI

/// The panel's lid-closed surface, and the measurement that bounds it.
///
/// **What the app can show, and what it measurably cannot.** Issue #13 asked the
/// panel to read the journal unprivileged and show whether lid-closed mode is
/// armed and until when. It cannot, and this is not a guess:
///
///   `FileJournalStore.systemURL` is
///   `/Library/Application Support/coffee-bar/state/probe-journal.json`.
///   `GuardedJournalReader` requires that directory to be exactly `0700` and
///   root-owned. Measured on macOS 26.5.2 as uid 502 against `/var/root`, a
///   root-owned directory with no execute bit for this process: `stat(2)` on a
///   path INSIDE it fails with EACCES, and so does `open(2)`. The user cannot
///   learn the journal's mode, its contents, or whether it exists at all.
///
/// So the panel does not invent a state display. It prints the command, states
/// that it cannot read the state, and names the command that can. Weakening the
/// journal's modes to make a nicer panel was rejected: the modes are a security
/// property and they outrank the panel.
///
/// **What these checks CANNOT do, stated so nobody over-trusts them.** M1 design
/// §5.4 forbids asserting on rendered AppKit text, so nothing here watches the
/// panel draw. `thePanelTellsTheUserHowToArmLidClosedMode` in
/// `AppLayerBoundary_test.swift` is the tripwire against deleting the render,
/// and it proves the view NAMES the property, never that the pixels are right.

/// The package root, resolved from `#filePath`.
///
/// A second resolver in this target, deliberately: `AppLayerBoundary_test.swift`
/// declares its own `packageRoot` as `private`, which in Swift is scoped to that
/// file and cannot be reached from here. Duplicating four lines is better than
/// widening a boundary guard's internals for a neighbour's convenience.
private func uiPackageRoot() -> URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarUITests/LidClosedPanel_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarUITests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // the package root
}

@MainActor
@Test func theLidClosedCommandNamesAVerbTheBinaryAcceptsAndItIsArm() {
    // Named bug this catches: `ProbeVerb.arm` renamed, or the panel's command
    // typed as a literal that drifts from it. The panel would then print a
    // command that exits with a usage error at the one moment a user has
    // already typed `sudo`.
    //
    // The verb is read back OUT of the printed command and put through
    // `ProbeVerb(rawValue:)`, rather than compared against the string this test
    // would otherwise restate. A command naming a verb the binary refuses is
    // the defect; a command naming the wrong REAL verb is the other one, so
    // both are asserted.
    let words = ServingModel.lidClosedCommand.split(separator: " ").map(String.init)
    let verb = words.last

    #expect(verb.flatMap { ProbeVerb(rawValue: $0) } == .arm, """
        the panel prints "\(ServingModel.lidClosedCommand)", whose last word is \
        \(words.last ?? "(none)"). ProbeVerb.arm is "\(ProbeVerb.arm.rawValue)".
        """)

    // `arm` needs root, and the printed command has to say so. A user handed
    // the command without `sudo` meets a permission error instead of the mode.
    #expect(ProbeVerb.arm.requiresRoot,
            "ProbeVerb.arm no longer requires root; the printed sudo is now wrong")
    #expect(ServingModel.lidClosedCommand.hasPrefix("sudo "),
            "the panel prints \"\(ServingModel.lidClosedCommand)\", which does not start with sudo")
}

@MainActor
@Test func theLidClosedCommandNamesARealExecutableProduct() throws {
    // Named bug this catches: the `coffee-bar-probe` product renamed in
    // Package.swift while the panel keeps printing the old name. The user
    // pastes a command for a binary that is not on their machine, and no other
    // check in this package reads both sides.
    let manifest = try String(contentsOf: uiPackageRoot().appending(path: "Package.swift"),
                              encoding: .utf8)

    let pattern = try NSRegularExpression(pattern: "\\.executable\\(name: \"([^\"]+)\"")
    let ns = manifest as NSString
    let products = pattern.matches(in: manifest,
                                   range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range(at: 1)) }

    // Anti-vacuity: a rotted pattern yields [] and every containment below
    // would fail for the wrong reason, or an `isEmpty` guard would pass.
    #expect(products.count >= 3,
            "parsed \(products.count) executable product(s) from Package.swift: \(products)")

    let words = ServingModel.lidClosedCommand.split(separator: " ").map(String.init)
    let binary = try #require(words.dropFirst().first,
                              "the printed command has no binary: \(ServingModel.lidClosedCommand)")

    #expect(products.contains(binary), """
        the panel prints the binary "\(binary)"; Package.swift declares the \
        executable products \(products.sorted()). A command naming a binary \
        that is not built is a command the user cannot run.
        """)
}

@MainActor
@Test func theLidClosedAdvisoryStatesTheRealDefaultHold() {
    // The panel tells the user how long arming holds. That number is
    // `ProbeVerb.defaultTTLSeconds`, and a literal typed into the sentence
    // drifts the moment the constant moves.
    //
    // Named bug this catches: the default raised to an hour for a good reason,
    // and a panel that goes on promising 30 minutes to somebody deciding
    // whether to walk away from a laptop on battery.
    let minutes = ProbeVerb.defaultTTLSeconds / 60
    #expect(ServingModel.lidClosedAdvisory.contains("\(minutes) minutes"), """
        the advisory does not state \(minutes) minutes, which is what \
        ProbeVerb.defaultTTLSeconds is. It reads:
        \(ServingModel.lidClosedAdvisory)
        """)
}

@MainActor
@Test func theLidClosedAdvisoryCarriesBothTheCommandAndWhatTheAppCannotSee() {
    // **ONE property, never two**, for the reason `suppressionAdvisory` is one:
    // the two halves are meaningless apart. A panel that printed the command
    // and dropped the caveat would tell a user to arm a mode the panel then
    // appears to report on. A panel that printed the caveat and dropped the
    // command would report an absence with no way to act.
    //
    // Split across two properties, `PanelView` can render one and drop the
    // other, and design §5.4 rules out any check seeing it happen. Merged, that
    // mistake cannot be made.
    let advisory = ServingModel.lidClosedAdvisory

    #expect(advisory.contains(ServingModel.lidClosedCommand), """
        the advisory never prints \(ServingModel.lidClosedCommand), so the user \
        is told about a mode with no way to turn it on. It reads:
        \(advisory)
        """)

    #expect(advisory.contains(ServingModel.lidClosedReportCommand), """
        the advisory never prints \(ServingModel.lidClosedReportCommand). The \
        app cannot read the journal, so the command that CAN is the only \
        honest answer to "is it on?". It reads:
        \(advisory)
        """)

    // The measured impossibility has to reach the user as a statement, not as
    // silence. "cannot" is the load-bearing word: a panel that simply omits the
    // state reads as "nothing is armed", which is a claim this app has no
    // evidence for.
    #expect(advisory.lowercased().contains("cannot"), """
        the advisory never says the app CANNOT read the state, so a user reads \
        its silence as "lid-closed mode is off". It reads:
        \(advisory)
        """)
}

@MainActor
@Test func theLidClosedAdvisoryPromisesNoControlTheAppDoesNotHave() {
    // Design §6.3 and SECURITY.md: coffee-bar never elevates its own privilege.
    // The advisory must not offer to do the arming, because there is no code
    // that could and adding some is the thing the policy forbids.
    //
    // Named bug this catches: the sentence softened to "coffee-bar will arm
    // lid-closed mode for you", which reads better and describes a product that
    // would need an authorization prompt to exist.
    let advisory = ServingModel.lidClosedAdvisory.lowercased()

    for promise in ["click", "toggle", "turn it on here", "arm it for you",
                    "we will arm", "coffee-bar will arm"] {
        #expect(!advisory.contains(promise), """
            the advisory says "\(promise)", which offers a control this app does \
            not have and must not gain. It prints a command for the user to run. \
            It reads:
            \(ServingModel.lidClosedAdvisory)
            """)
    }
}
