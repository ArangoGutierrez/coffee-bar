// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import CoffeeBarPower
@testable import CoffeeBarUI

/// The lid-closed surfaces, and the measurement that bounds them.
///
/// **Three surfaces, and issue #56 is why there are three.** The Serving panel
/// carried roughly 80 words of documentation about lid-closed mode inside a
/// 260pt popover — neither live state nor a control, which is what that panel is
/// for. It now carries nothing. The Preferences window carries the SHORT
/// version, beside the other power settings, and `site/docs.html` carries the
/// explanation for a reader who has never seen the source. Each of the three has
/// its own check below, and the panel's is a NEGATIVE one in
/// `AppLayerBoundary_test.swift`.
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
/// So coffee-bar does not invent a state display. It prints the command, states
/// that it cannot read the state, and names the command that can. Weakening the
/// journal's modes to make a nicer surface was rejected: the modes are a
/// security property and they outrank any panel.
///
/// **What these checks CANNOT do, stated so nobody over-trusts them.** M1 design
/// §5.4 forbids asserting on rendered AppKit text, so nothing here watches
/// anything draw. `theLidClosedSummaryIsInThePreferencesWindowAndNotInThePanel`
/// in `AppLayerBoundary_test.swift` is the tripwire on both sides of the move,
/// and it proves which view NAMES the property, never that the pixels are right.
/// The site check reads a file on disk, so it proves the page SAYS this; it
/// cannot prove the page was ever published.

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
    // Named bug this catches: `ProbeVerb.arm` renamed, or coffee-bar's command
    // typed as a literal that drifts from it. The product would then print a
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
        coffee-bar prints "\(ServingModel.lidClosedCommand)", whose last word is \
        \(words.last ?? "(none)"). ProbeVerb.arm is "\(ProbeVerb.arm.rawValue)".
        """)

    // `arm` needs root, and the printed command has to say so. A user handed
    // the command without `sudo` meets a permission error instead of the mode.
    #expect(ProbeVerb.arm.requiresRoot,
            "ProbeVerb.arm no longer requires root; the printed sudo is now wrong")
    #expect(ServingModel.lidClosedCommand.hasPrefix("sudo "),
            "coffee-bar prints \"\(ServingModel.lidClosedCommand)\", which does not start with sudo")
}

@MainActor
@Test func theLidClosedCommandNamesARealExecutableProduct() throws {
    // Named bug this catches: the `coffee-bar-probe` product renamed in
    // Package.swift while coffee-bar keeps printing the old name. The user
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
        coffee-bar prints the binary "\(binary)"; Package.swift declares the \
        executable products \(products.sorted()). A command naming a binary \
        that is not built is a command the user cannot run.
        """)
}

@MainActor
@Test func theLidClosedSummaryStatesTheRealDefaultHold() {
    // The window tells the user how long arming holds. That number is
    // `ProbeVerb.defaultTTLSeconds`, and a literal typed into the sentence
    // drifts the moment the constant moves.
    //
    // Named bug this catches: the default raised to an hour for a good reason,
    // and a settings window that goes on promising 30 minutes to somebody
    // deciding whether to walk away from a laptop on battery.
    let minutes = ProbeVerb.defaultTTLSeconds / 60
    #expect(ServingModel.lidClosedSummary.contains("\(minutes) minutes"), """
        the summary does not state \(minutes) minutes, which is what \
        ProbeVerb.defaultTTLSeconds is. It reads:
        \(ServingModel.lidClosedSummary)
        """)
}

@MainActor
@Test func theLidClosedSummaryCarriesBothTheCommandAndWhatTheAppCannotSee() {
    // **ONE property, never two**, for the reason `suppressionAdvisory` is one:
    // the two halves are meaningless apart. A surface that printed the command
    // and dropped the caveat would tell a user to arm a mode it then appears to
    // report on. A surface that printed the caveat and dropped the command
    // would report an absence with no way to act.
    //
    // Split across two properties, a view can render one and drop the other,
    // and design §5.4 rules out any check seeing it happen. Merged, that
    // mistake cannot be made.
    //
    // **This is the sentence issue #56 says must not be lost.** The rest of the
    // paragraph was explanation and moved to `site/docs.html`; this half is a
    // product LIMITATION, and a user who armed the mode and meets no signal
    // anywhere has been told nothing. Shortening the summary must not take it.
    let summary = ServingModel.lidClosedSummary

    #expect(summary.contains(ServingModel.lidClosedCommand), """
        the summary never prints \(ServingModel.lidClosedCommand), so the user \
        is told about a mode with no way to turn it on. It reads:
        \(summary)
        """)

    #expect(summary.contains(ServingModel.lidClosedReportCommand), """
        the summary never prints \(ServingModel.lidClosedReportCommand). The \
        app cannot read the journal, so the command that CAN is the only \
        honest answer to "is it on?". It reads:
        \(summary)
        """)

    // The measured impossibility has to reach the user as a statement, not as
    // silence. "cannot" is the load-bearing word: a surface that simply omits
    // the state reads as "nothing is armed", which is a claim this app has no
    // evidence for.
    #expect(summary.lowercased().contains("cannot"), """
        the summary never says the app CANNOT read the state, so a user reads \
        its silence as "lid-closed mode is off". It reads:
        \(summary)
        """)
}

@MainActor
@Test func theLidClosedSummaryIsTheShortVersionAndNotTheMovedParagraph() {
    // Issue #56, the half that is easiest to get wrong. The paragraph did not
    // need a new home; it needed to STOP being a paragraph on a control
    // surface. Moving 80 words from a 260pt popover into a 420pt window
    // reproduces the defect one window over.
    //
    // Named bug this catches: `lidClosedAdvisory` renamed to
    // `lidClosedSummary`, rendered in `PreferencesView`, and every other check
    // in this file green — because every other check here asks what the text
    // CONTAINS, and a paragraph contains everything a summary does.
    //
    // SENTENCES, not a word budget. A word count needs a threshold somebody
    // has to defend; the count of full stops is the thing the issue actually
    // names ("no longer renders a multi-sentence paragraph"), and it
    // discriminates without a magic number: the text this replaced had five.
    //
    // A full stop only ends a sentence when whitespace or the end of the string
    // follows it, which is not pedantry — `coffee-bar-probe` carries no period
    // but a version or an abbreviation would, and splitting on every `.` would
    // count sentences that no reader sees.
    let summary = ServingModel.lidClosedSummary
    let characters = Array(summary)
    var sentences = 0
    for (index, character) in characters.enumerated() where ".!?".contains(character) {
        let next = index + 1 < characters.count ? characters[index + 1] : " "
        if next == " " { sentences += 1 }
    }

    #expect(sentences <= 2, """
        the lid-closed summary runs to \(sentences) sentences. Preferences gets \
        the SHORT version and site/docs.html gets the explanation — a paragraph \
        moved between two windows is issue #56 reopened. It reads:
        \(summary)
        """)

    // ANTI-VACUITY. A summary with no terminal punctuation counts ZERO
    // sentences and sails past the bound above while being exactly the
    // run-on this check exists to refuse.
    #expect(sentences >= 1, """
        the lid-closed summary ends no sentence at all, so the bound above \
        counted nothing and asserted nothing. It reads:
        \(summary)
        """)
}

@MainActor
@Test func theLidClosedSummaryPromisesNoControlTheAppDoesNotHave() {
    // Design §6.3 and SECURITY.md: coffee-bar never elevates its own privilege.
    // The summary must not offer to do the arming, because there is no code
    // that could and adding some is the thing the policy forbids.
    //
    // This matters MORE now than it did in the panel. The sentence sits in a
    // settings window, among rows that really are controls — a Display picker,
    // a Battery floor slider, a Focus toggle — so a wording that sounds like a
    // switch has a switch beside it to be mistaken for.
    //
    // Named bug this catches: the sentence softened to "coffee-bar will arm
    // lid-closed mode for you", which reads better and describes a product that
    // would need an authorization prompt to exist.
    let summary = ServingModel.lidClosedSummary.lowercased()

    for promise in ["click", "toggle", "turn it on here", "arm it for you",
                    "we will arm", "coffee-bar will arm"] {
        #expect(!summary.contains(promise), """
            the summary says "\(promise)", which offers a control this app does \
            not have and must not gain. It prints a command for the user to run. \
            It reads:
            \(ServingModel.lidClosedSummary)
            """)
    }
}

// MARK: - The third surface: the explanation the short version points at

/// `site/docs.html` explains lid-closed mode to somebody who has never read the
/// source.
///
/// **Why this check lives HERE and not in `DocsClaims_test.swift`.** The number
/// on that page is `ProbeVerb.defaultTTLSeconds / 60`, and `ProbeVerb` is in
/// `CoffeeBarPower`. `CoffeeBarCoreTests` depends on `CoffeeBarCore` alone and
/// structurally cannot reach it — the same reason `SECURITY.md` is excluded from
/// that file's duration sweep. This target reaches the constant, so the page's
/// number is compared against it rather than against a second copy of it.
///
/// **Scoped to the section, not to the page.** Every containment below is asked
/// of the lid-closed section only. Asked of the whole page, "cannot" would be
/// satisfied by a sentence in the battery paragraph and the guard would report a
/// limitation the page never states.
///
/// **What this CANNOT do.** It reads a file in the working tree. It cannot prove
/// the page was published, and it cannot prove a reader understands it. It is a
/// guard against the destination silently not existing, which is exactly what
/// issue #56 found: the panel's paragraph pointed at documentation that had
/// never been written.
@MainActor
@Test func theSiteExplainsLidClosedModeAndStatesTheShippedHold() throws {
    let page = try String(contentsOf: uiPackageRoot().appending(path: "site/docs.html"),
                          encoding: .utf8)

    // The section, from its heading to the next one. A named anchor rather than
    // a line range: line numbers rot the first time anything above moves.
    let pattern = try NSRegularExpression(
        pattern: "<h2[^>]*>\\s*Lid-closed mode\\s*</h2>([\\s\\S]*?)(?=<h2|</div>)")
    let ns = page as NSString
    let found = pattern.matches(in: page, range: NSRange(location: 0, length: ns.length))

    #expect(found.count == 1, """
        site/docs.html carries \(found.count) sections headed "Lid-closed mode". \
        The panel no longer explains the mode, so a page that does not explain \
        it either leaves the explanation nowhere. Issue #56.
        """)
    let section = try #require(found.first.map { ns.substring(with: $0.range(at: 1)) })

    // ANTI-VACUITY. A heading with nothing under it matches the pattern above
    // and every containment would then fail for the right reason — but a
    // pattern that captured only whitespace would look like a page problem
    // rather than a guard problem, so the size is asserted separately.
    #expect(section.count > 600, """
        the lid-closed section of site/docs.html is \(section.count) characters. \
        It replaced roughly 80 words in the panel and has to say MORE than the \
        summary in Preferences, not less.
        """)

    // Both commands, verbatim from the model. The page and the window print one
    // string, and it is composed from `ProbeVerb` in exactly one place.
    for command in [ServingModel.lidClosedCommand, ServingModel.lidClosedReportCommand] {
        #expect(section.contains(command), """
            the lid-closed section of site/docs.html never prints "\(command)", \
            so the page documents a mode the reader cannot operate.
            """)
    }

    // The limitation, which issue #56 names as the thing that must not be lost.
    // Both words are required together: "cannot" alone matches any sentence
    // about any limit, and "armed" alone matches the explanation of arming.
    #expect(section.lowercased().contains("cannot")
            && section.lowercased().contains("armed"), """
        the lid-closed section of site/docs.html never states that coffee-bar \
        CANNOT show whether the mode is ARMED. That sentence is a product \
        limitation rather than an explanation, and deleting it leaves a user \
        who armed the mode with no signal anywhere.
        """)

    // EVERY duration in the section, not merely the presence of the right one.
    // A section stating both "30 minutes" and "45 minutes" satisfies a
    // containment check while telling the reader two different things.
    let minutes = ProbeVerb.defaultTTLSeconds / 60
    let durations = try NSRegularExpression(pattern: "(\\d+)\\s*minutes?")
    let sectionNS = section as NSString
    let stated = durations
        .matches(in: section, range: NSRange(location: 0, length: sectionNS.length))
        .map { sectionNS.substring(with: $0.range(at: 1)) }

    #expect(stated.count >= 1, """
        the lid-closed section of site/docs.html states no hold at all. A reader \
        deciding whether to shut the lid and walk away needs the \(minutes) \
        minutes ProbeVerb.defaultTTLSeconds gives them.
        """)

    for value in stated {
        #expect(Int(value) == minutes, """
            the lid-closed section of site/docs.html states "\(value) minutes"; \
            ProbeVerb.defaultTTLSeconds is \(ProbeVerb.defaultTTLSeconds) s = \
            \(minutes) minutes. A number typed onto the page drifts the moment \
            the constant moves, and it drifts on the surface a stranger reads.
            """)
    }
}

// MARK: - Issue #64: the binary the docs send people to has to be in the bundle

/// The bundle assembler, read as text.
///
/// `scripts/build-app.sh` is the only thing that decides what lands in
/// `CoffeeBar.app/Contents/MacOS/`, and no Swift target imports it. Reading it
/// is the only route from this suite to that decision.
private func bundleAssembler() throws -> String {
    try String(contentsOf: uiPackageRoot().appending(path: "scripts/build-app.sh"),
               encoding: .utf8)
}

/// One shell assignment's value, e.g. `APP_NAME="CoffeeBar"` -> `CoffeeBar`.
///
/// Anchored to the start of a line so a mention inside a comment or a string
/// cannot answer for the real assignment.
private func shellValue(of name: String, in script: String) throws -> String? {
    let pattern = try NSRegularExpression(pattern: "(?m)^\(name)=\"?([A-Za-z0-9._-]+)\"?\\s*$")
    let ns = script as NSString
    return pattern.firstMatch(in: script, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range(at: 1)) }
}

/// The executable products `scripts/build-app.sh` puts in the bundle.
private func bundledProducts(in script: String) throws -> [String] {
    let pattern = try NSRegularExpression(pattern: "(?m)^PRODUCTS=\\(([^)]*)\\)")
    let ns = script as NSString
    guard let match = pattern.firstMatch(in: script,
                                         range: NSRange(location: 0, length: ns.length))
    else { return [] }
    return ns.substring(with: match.range(at: 1))
        .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        .filter { !$0.isEmpty }
}

/// The executable products `Package.swift` declares.
private func declaredExecutables() throws -> [String] {
    let manifest = try String(contentsOf: uiPackageRoot().appending(path: "Package.swift"),
                              encoding: .utf8)
    let pattern = try NSRegularExpression(pattern: "\\.executable\\(name: \"([^\"]+)\"")
    let ns = manifest as NSString
    return pattern.matches(in: manifest, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range(at: 1)) }
}

@MainActor
@Test func theBundleTheScriptAssemblesCarriesTheProbe() throws {
    // Named bug this catches, and it is issue #64 exactly. `build-app.sh` built
    // `--product coffee-bar` alone, so `Contents/MacOS/` held one binary and the
    // DMG held one binary. Lid-closed mode's ONLY entry point is the probe, and
    // `Sources/CoffeeBarProbe/main.swift` implements `.arm` against a real
    // `ArmService`. A headline feature of v0.2.0 shipped with no way to reach it
    // for every user who installed from the disk image, while the app's own
    // Preferences window told them to run it.
    //
    // Nothing in this package could see that. `Package.swift` declares the
    // product, `swift test` builds it, and every probe test in
    // `CoffeeBarPowerTests` runs the binary out of `.build/` — which exists
    // whatever the bundle contains. The one file that decides is a shell script
    // no target imports, so a guard has to read it as text.
    let script = try bundleAssembler()
    let products = try bundledProducts(in: script)

    // ANTI-VACUITY, and it is the whole failure mode of a text-scraped guard: a
    // renamed variable makes `products` empty, `contains` then fails for a
    // reason that reads like the defect, and a `products.isEmpty` early return
    // would instead pass over a script that bundles nothing at all.
    #expect(products.count >= 2, """
        parsed \(products.count) product(s) from the PRODUCTS array in \
        scripts/build-app.sh: \(products). The bundle carries at least the app \
        and the probe, so fewer than two means this guard read the wrong thing \
        rather than that the script is thin.
        """)

    #expect(products.contains("coffee-bar-probe"), """
        scripts/build-app.sh bundles \(products.sorted()). `coffee-bar-probe` is \
        not among them, so CoffeeBar.app — and the DMG built from it — ships \
        without the only entry point lid-closed mode has. The Preferences window \
        prints "\(ServingModel.lidClosedCommand)" regardless.
        """)

    // A product name the manifest does not declare fails the BUILD, not this
    // check — but it fails it at release time, on the maintainer's machine,
    // after a tag. Catching a typo here costs one comparison.
    let declared = try declaredExecutables()
    #expect(declared.count >= 3,
            "parsed \(declared.count) executable product(s) from Package.swift: \(declared)")
    for product in products {
        #expect(declared.contains(product), """
            scripts/build-app.sh bundles "\(product)", which Package.swift does \
            not declare as an executable product. Package.swift declares \
            \(declared.sorted()). `swift build --product \(product)` cannot \
            succeed, so the release build fails at the tag.
            """)
    }

    // The bundle layout the printed command depends on. `APP_NAME` is what names
    // `CoffeeBar.app`, and the path the user is told to type is built from it —
    // so a rename here silently invalidates every document that prints the path.
    let appName = try #require(try shellValue(of: "APP_NAME", in: script), """
        scripts/build-app.sh sets no APP_NAME this guard can read, so the bundle \
        path the documents print rests on nothing.
        """)
    #expect(appName == "CoffeeBar", """
        scripts/build-app.sh assembles \(appName).app; every surface that prints \
        the probe's path names /Applications/CoffeeBar.app/Contents/MacOS/. \
        Rename one and the other is a path that does not exist.
        """)
}
