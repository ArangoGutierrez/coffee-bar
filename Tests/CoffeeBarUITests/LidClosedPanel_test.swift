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

/// The one probe location every check below composes its expectations from.
///
/// **Fixed, and never this machine's.** The app derives the probe's path from
/// its own bundle, so on a developer's Mac the printed command names a worktree
/// and on a user's it names wherever they dragged the app. A check that read the
/// live value would assert a different string on every machine and could not be
/// compared against a documentation page at all.
///
/// `documentedProbePath` is the disk-image location, which is the one a page can
/// print, and `theBundleTheScriptAssemblesCarriesTheProbe` holds it against the
/// APP_NAME `scripts/build-app.sh` actually assembles. That two of these checks
/// then read the SAME constant is not circular: what they hold is the composed
/// COMMAND — the sudo, the verb, the ordering — and
/// `theProbePathIsDerivedFromTheBundleAndNotAHardcodedLiteral` is what holds the
/// derivation itself, against locations that are not this one.
private let documentedProbe = ServingModel.documentedProbePath

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
    let words = ServingModel.lidClosedCommand(probeAt: documentedProbe).split(separator: " ").map(String.init)
    let verb = words.last

    #expect(verb.flatMap { ProbeVerb(rawValue: $0) } == .arm, """
        coffee-bar prints "\(ServingModel.lidClosedCommand(probeAt: documentedProbe))", whose last word is \
        \(words.last ?? "(none)"). ProbeVerb.arm is "\(ProbeVerb.arm.rawValue)".
        """)

    // `arm` needs root, and the printed command has to say so. A user handed
    // the command without `sudo` meets a permission error instead of the mode.
    #expect(ProbeVerb.arm.requiresRoot,
            "ProbeVerb.arm no longer requires root; the printed sudo is now wrong")
    #expect(ServingModel.lidClosedCommand(probeAt: documentedProbe).hasPrefix("sudo "),
            "coffee-bar prints \"\(ServingModel.lidClosedCommand(probeAt: documentedProbe))\", which does not start with sudo")
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

    let words = ServingModel.lidClosedCommand(probeAt: documentedProbe).split(separator: " ").map(String.init)
    let invocation = try #require(words.dropFirst().first,
                                  "the printed command has no binary: \(ServingModel.lidClosedCommand(probeAt: documentedProbe))")

    // The LAST PATH COMPONENT, since issue #64. The command names an absolute
    // path now — the probe ships inside the bundle and is not on any PATH — so
    // the second word is `/…/Contents/MacOS/coffee-bar-probe` rather than a bare
    // product name. Comparing the whole word against `Package.swift` would fail
    // on a CORRECT tree.
    //
    // The INVARIANT this assertion exists for is unchanged and still bites: the
    // thing invoked has to be an executable this package actually builds. Rename
    // the product in `Package.swift` while the app keeps printing the old name
    // and this goes red exactly as before.
    let binary = (invocation as NSString).lastPathComponent

    #expect(products.contains(binary), """
        coffee-bar invokes "\(invocation)", whose binary is "\(binary)"; \
        Package.swift declares the executable products \(products.sorted()). A \
        command naming a binary that is not built is a command the user cannot \
        run.
        """)

    // The path half, which the last-component check above deliberately discards.
    // Without this, `sudo coffee-bar-probe arm` — the pre-#64 string, which is
    // not on any PATH and which no user could run — would satisfy this test.
    #expect(invocation.hasPrefix("/"), """
        coffee-bar prints "\(invocation)", which is not an absolute path. The \
        probe ships inside the app bundle and nothing puts it on the user's \
        PATH, so a bare product name is a command their shell answers with \
        "command not found".
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
    #expect(ServingModel.lidClosedSummary(probeAt: documentedProbe).contains("\(minutes) minutes"), """
        the summary does not state \(minutes) minutes, which is what \
        ProbeVerb.defaultTTLSeconds is. It reads:
        \(ServingModel.lidClosedSummary(probeAt: documentedProbe))
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
    let summary = ServingModel.lidClosedSummary(probeAt: documentedProbe)

    #expect(summary.contains(ServingModel.lidClosedCommand(probeAt: documentedProbe)), """
        the summary never prints \(ServingModel.lidClosedCommand(probeAt: documentedProbe)), so the user \
        is told about a mode with no way to turn it on. It reads:
        \(summary)
        """)

    #expect(summary.contains(ServingModel.lidClosedReportCommand(probeAt: documentedProbe)), """
        the summary never prints \(ServingModel.lidClosedReportCommand(probeAt: documentedProbe)). The \
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
    let summary = ServingModel.lidClosedSummary(probeAt: documentedProbe)
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
    let summary = ServingModel.lidClosedSummary(probeAt: documentedProbe).lowercased()

    for promise in ["click", "toggle", "turn it on here", "arm it for you",
                    "we will arm", "coffee-bar will arm"] {
        #expect(!summary.contains(promise), """
            the summary says "\(promise)", which offers a control this app does \
            not have and must not gain. It prints a command for the user to run. \
            It reads:
            \(ServingModel.lidClosedSummary(probeAt: documentedProbe))
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
    for command in [ServingModel.lidClosedCommand(probeAt: documentedProbe), ServingModel.lidClosedReportCommand(probeAt: documentedProbe)] {
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
        prints "\(ServingModel.lidClosedCommand(probeAt: documentedProbe))" regardless.
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

@MainActor
@Test func theBuildingGuideSaysWhereTheProbeBinaryComesFrom() throws {
    // Named bug this catches, and it is the second half of issue #64.
    // `docs/BUILDING.md` said of `arm`, `report`, `revert` and `watchdog`:
    // "**They are not implemented.** Each exits 64 with a message naming the
    // task that would add it. Nothing in the shipped app reaches the privileged
    // code path."
    //
    // Both sentences were FALSE when they were read on 2026-08-07. #13 shipped
    // lid-closed mode in v0.2.0, `.arm` reaches a real ArmService with a journal
    // and a refusal path, and the Preferences window prints the command. A
    // reader who went looking for the feature was told by the project's own
    // build guide that it did not exist.
    //
    // Nothing could see it. The document is prose about an enum, and prose is
    // exactly what a compiler does not read.
    let guide = try String(contentsOf: uiPackageRoot().appending(path: "docs/BUILDING.md"),
                           encoding: .utf8)
    #expect(guide.count > 1000,
            "docs/BUILDING.md is \(guide.count) bytes; every check below would pass vacuously")

    // WHITESPACE-NORMALISED, and that is not tidiness. Markdown wraps prose at
    // the column, so "Nothing in the shipped app reaches the privileged code
    // path" is split across two lines in the file. Checked against the raw text
    // that phrase NEVER MATCHES — measured: it was the one of these three that
    // stayed silent while the sentence was present, which is a guard that reads
    // as passing and is asserting nothing.
    let prose = guide.replacingOccurrences(of: "\\s+", with: " ",
                                           options: .regularExpression)

    // The claim, in the words it was written in. A phrase check catches this
    // spelling and no other, which is why the two positive assertions below
    // carry the weight — but the sentence is quotable and it is worth naming, so
    // that a reinstated copy fails on the exact text rather than on a synonym
    // nobody chose.
    for claim in ["are not implemented", "They are not implemented",
                  "Nothing in the shipped app reaches the privileged code path"] {
        #expect(!prose.contains(claim), """
            docs/BUILDING.md still says "\(claim)". The privileged verbs ARE \
            implemented — `.arm` reaches a real ArmService — and lid-closed mode \
            shipped in v0.2.0. A reader who goes looking is told the feature does \
            not exist.
            """)
    }

    // POSITIVE, and derived: every verb the binary refuses without root is a
    // verb the build guide has to account for. Read out of `ProbeVerb` so a
    // fifth root verb makes this fail rather than quietly go undocumented.
    let rootVerbs = ProbeVerb.allCases.filter(\.requiresRoot).map(\.rawValue)
    #expect(rootVerbs.count >= 4,
            "ProbeVerb reports \(rootVerbs.count) root verb(s): \(rootVerbs); this guard would sweep almost nothing")
    for verb in rootVerbs {
        #expect(guide.contains(verb), """
            docs/BUILDING.md never names the root verb "\(verb)". The guide is \
            where a reader goes to find out what the probe does, and a verb it \
            omits is a verb that exists only in the source.
            """)
    }

    // WHERE THE BINARY COMES FROM, which is the acceptance criterion in the
    // issue's own words. The path is composed from `APP_NAME` in
    // `scripts/build-app.sh` and the product name that script bundles, so a
    // rename on either side fails here instead of publishing a path that does
    // not exist.
    let script = try bundleAssembler()
    let appName = try #require(try shellValue(of: "APP_NAME", in: script),
                               "scripts/build-app.sh sets no APP_NAME this guard can read")
    let bundlePath = "/Applications/\(appName).app/Contents/MacOS/coffee-bar-probe"

    #expect(guide.contains(bundlePath), """
        docs/BUILDING.md never prints "\(bundlePath)". The probe now ships inside \
        the bundle and is NOT on the user's PATH, so a page that names \
        `coffee-bar-probe` without its path hands the reader a command their \
        shell answers with "command not found".
        """)
}

@MainActor
@Test func theProbePathIsDerivedFromTheBundleAndNotAHardcodedLiteral() {
    // Named bug this catches, and it is the one a `/Applications` literal WOULD
    // have shipped. The app knows where it is; a literal only knows where the
    // author imagined it would be. Every one of these is a real install:
    //
    //   - the disk image, which does land in /Applications;
    //   - Homebrew, which does NOT — `docs/QUICKSTART.md` says so itself, the
    //     formula installs into the Homebrew prefix and prints a command to link
    //     it — so a literal names a path that is not there;
    //   - a `swift build` tree, which is what the maintainer launches while
    //     testing this very feature;
    //   - a copy dragged to the Desktop, which macOS permits and users do.
    //
    // Under a literal the app would print /Applications/… to all four, and three
    // of the four users would type a path their shell cannot find.
    let cases: [(label: String, executable: String, expected: String)] = [
        ("the disk image",
         "/Applications/CoffeeBar.app/Contents/MacOS/coffee-bar",
         "/Applications/CoffeeBar.app/Contents/MacOS/coffee-bar-probe"),
        ("a Homebrew prefix",
         "/opt/homebrew/Cellar/coffee-bar/0.2.1/CoffeeBar.app/Contents/MacOS/coffee-bar",
         "/opt/homebrew/Cellar/coffee-bar/0.2.1/CoffeeBar.app/Contents/MacOS/coffee-bar-probe"),
        ("a swift build tree",
         "/Users/somebody/src/coffee-bar/.build/debug/coffee-bar",
         "/Users/somebody/src/coffee-bar/.build/debug/coffee-bar-probe"),
        ("a copy on the Desktop",
         "/Users/somebody/Desktop/CoffeeBar.app/Contents/MacOS/coffee-bar",
         "/Users/somebody/Desktop/CoffeeBar.app/Contents/MacOS/coffee-bar-probe"),
    ]

    for probe in cases {
        let actual = ServingModel.probePath(
            besideExecutable: URL(fileURLWithPath: probe.executable))
        #expect(actual == probe.expected, """
            for \(probe.label), coffee-bar running at
              \(probe.executable)
            names the probe at
              \(actual)
            and the probe it ships beside is at
              \(probe.expected)
            """)
    }

    // THE DISCRIMINATOR. Every assertion above passes for a function that
    // returns a hardcoded /Applications path — the first case IS that path, and
    // the other three would each fail individually, but a reader scanning a
    // green run learns nothing from that. This says the property directly: four
    // different homes give four different answers. A literal collapses them to
    // one and this is the line that goes red.
    let answers = Set(cases.map {
        ServingModel.probePath(besideExecutable: URL(fileURLWithPath: $0.executable))
    })
    #expect(answers.count == cases.count, """
        \(cases.count) different install locations produced \(answers.count) \
        distinct probe path(s): \(answers.sorted()). The path is not derived \
        from the running bundle — it is a literal, and it is correct for at most \
        one of these.
        """)

    // The fallback, which is a real branch rather than defensive padding:
    // `Bundle.main.executableURL` is documented as optional and this must reach
    // a printable command rather than an empty one. The documented location is
    // the honest answer when the app cannot locate itself.
    #expect(ServingModel.probePath(besideExecutable: nil) == ServingModel.documentedProbePath, """
        with no executable URL the model answers \
        "\(ServingModel.probePath(besideExecutable: nil))". It should fall back \
        to the documented location, \(ServingModel.documentedProbePath).
        """)
}

// MARK: - Issue #75: the sequence the window prints has to be one root accepts

@MainActor
@Test func theArmedProbeIsNeverTheCopyInsideTheAppBundle() throws {
    // Named bug this catches, and it is issue #75 exactly. The window printed
    // `sudo /Applications/CoffeeBar.app/Contents/MacOS/coffee-bar-probe arm`,
    // and that command CANNOT succeed on any Mac. Measured on 2026-08-07:
    //
    //   $ sudo /Applications/CoffeeBar.app/Contents/MacOS/coffee-bar-probe arm
    //   coffee-bar-probe: could not arm: programPathInsecure(...)
    //     /Applications                groupOrOtherWritable: true
    //     /Applications/CoffeeBar.app  notOwnedByRoot: true
    //
    // `arm` reaches `LaunchDaemonInstaller.install()`, which puts its own
    // program path through `PathSecurity.validate` before it writes anything —
    // launchd execs that file as uid 0 with `RunAtLoad` and `KeepAlive`, so a
    // program file another local account can rewrite is root persistence handed
    // to whoever gets there first. Apple ships `/Applications` as
    // `drwxrwxr-x root:admin`, so EVERY component below it fails that bar. The
    // check is right; the printed command was wrong.
    //
    // This reads `lidClosedSummary`, which is the string `PreferencesView`
    // renders, rather than any one command accessor — what the user is handed is
    // the sentence, and a fix that corrects a helper the sentence stops calling
    // is not a fix.
    //
    // It is the MIRROR of `theProbePathIsDerivedFromTheBundleAndNotAHardcodedLiteral`
    // above, and the contrast is the point. Where the probe SHIPS depends on the
    // install and must be derived; where it is ARMED cannot depend on the install
    // at all, because only a root-owned location is armable. Four homes, one arm
    // target.
    let installs: [(label: String, path: String)] = [
        ("the disk image", "/Applications/CoffeeBar.app/Contents/MacOS/coffee-bar-probe"),
        ("a Homebrew prefix",
         "/opt/homebrew/Cellar/coffee-bar/0.2.1/CoffeeBar.app/Contents/MacOS/coffee-bar-probe"),
        ("a swift build tree", "/Users/somebody/src/coffee-bar/.build/debug/coffee-bar-probe"),
        ("a copy on the Desktop",
         "/Users/somebody/Desktop/CoffeeBar.app/Contents/MacOS/coffee-bar-probe"),
    ]

    // The verb comes from `ProbeVerb`, never typed, for the reason
    // `theLidClosedCommandNamesAVerbTheBinaryAcceptsAndItIsArm` gives. The
    // trailing lookahead keeps `arm` from matching the head of a longer word,
    // and the leading `sudo ` keeps the prose "you arm it yourself" out of the
    // match — that phrase carries the verb and no path.
    let armPattern = try NSRegularExpression(
        pattern: "sudo (/\\S+) \(ProbeVerb.arm.rawValue)(?![-A-Za-z0-9])")

    var armTargets: Set<String> = []

    for install in installs {
        let summary = ServingModel.lidClosedSummary(probeAt: install.path)
        let ns = summary as NSString
        let matches = armPattern.matches(in: summary,
                                         range: NSRange(location: 0, length: ns.length))

        // ANTI-VACUITY, and it is the failure mode of every scraped guard: a
        // reworded summary that matches nothing leaves the assertions below
        // asserting about a value that was never found.
        #expect(matches.count == 1, """
            for \(install.label), the summary names \(matches.count) arm \
            command(s); this guard reads exactly one. It reads:
            \(summary)
            """)
        guard let match = matches.first else { continue }
        let armed = ns.substring(with: match.range(at: 1))
        armTargets.insert(armed)

        #expect(!armed.contains("/Applications/"), """
            for \(install.label), the window says to arm \(armed). Apple ships \
            /Applications as drwxrwxr-x root:admin, so PathSecurity refuses \
            every component under it and `arm` exits before it changes \
            anything. Issue #75. It reads:
            \(summary)
            """)

        #expect(armed != install.path, """
            for \(install.label), the window says to arm the probe where it \
            SHIPS, \(armed). No install location is root-owned — the disk image \
            lands under a group-writable /Applications, Homebrew and a Desktop \
            copy and a build tree all belong to the user — so the binary has to \
            be copied somewhere root can trust before it can be armed. Issue \
            #75. It reads:
            \(summary)
            """)

        // The other half of the same property. The user cannot be told to arm a
        // path with no account of how a binary got there, so the sentence has to
        // name the copy they actually have.
        #expect(summary.contains(install.path), """
            for \(install.label), the window never names the probe this copy of \
            coffee-bar ships with, \(install.path), so the path it does name \
            appears from nowhere and there is nothing on that machine to run. \
            It reads:
            \(summary)
            """)
    }

    // THE DISCRIMINATOR. Each assertion above is per-install and a reader
    // scanning a red run sees four separate failures rather than the property.
    // This states it once: the arm target is a property of the SYSTEM, not of
    // where the user dragged the app.
    #expect(armTargets.count == 1, """
        \(installs.count) install locations produced \(armTargets.count) \
        distinct arm target(s): \(armTargets.sorted()). Arming succeeds from \
        exactly one kind of place — a path whose every component is root-owned \
        and not group-writable — so a command that varies with the install is a \
        command most users cannot run. Issue #75.
        """)
}

@MainActor
@Test func thePreferencesWindowAsksTheRunningBundleWhereTheProbeIs() throws {
    // The half the pure checks above cannot reach. `probePath(besideExecutable:)`
    // can be perfectly derived and still be dead code, if the view calls it with
    // the documented literal — or never calls it at all and prints
    // `documentedProbePath` directly. Both compile, both look right in a diff,
    // and both reintroduce exactly the defect the derivation exists to remove.
    //
    // COMMENT-STRIPPED, for the reason every source scan in this target is: the
    // derivation is explained in prose in `ServingModel.swift` and a raw read
    // would find `Bundle.main.executableURL` in an explanation of a call that
    // had been deleted.
    let window = uiPackageRoot().appending(path: "Sources/CoffeeBarUI/PreferencesView.swift")
    let stripped = swiftCodeWithoutComments(try String(contentsOf: window, encoding: .utf8))

    // WHITESPACE REMOVED, not merely collapsed, and this was measured rather
    // than anticipated: the call is long enough that the view wraps it over
    // three lines, so a needle containing `(besideExecutable:` never matches the
    // raw text. The first run of this guard failed against a CORRECT view — a
    // guard that is red when the code is right teaches people to silence it.
    //
    // Removing every space also makes this indifferent to how the call is later
    // reformatted, which is the right sensitivity: what is under test is that
    // the call is MADE, never how it is laid out.
    let code = stripped.replacingOccurrences(of: "\\s+", with: "",
                                             options: .regularExpression)

    #expect(code.contains("Bundle.main.executableURL"), """
        PreferencesView.swift never reads Bundle.main.executableURL, so the \
        probe path it prints cannot depend on where this copy of coffee-bar is \
        installed. `versionLine(from: Bundle.main.infoDictionary)` in this same \
        file is the shape: the view supplies the machine-dependent value and the \
        model stays pure.
        """)

    #expect(code.contains("ServingModel.probePath(besideExecutable:"), """
        PreferencesView.swift never calls ServingModel.probePath(besideExecutable:), \
        so whatever it prints is not the derivation this package holds under test.
        """)

    // DISCRIMINATES against the other way to get this wrong: calling the
    // derivation AND then printing the documented literal anyway. The literal is
    // for documents, which cannot ask a running process anything; a window can,
    // and a window that prints it has thrown the answer away.
    #expect(!code.contains("ServingModel.documentedProbePath"), """
        PreferencesView.swift names ServingModel.documentedProbePath. That \
        constant is the DISK-IMAGE location, for pages that cannot ask a running \
        process where it lives. This window can ask. Printing the literal tells \
        a Homebrew user — and the maintainer running a build from source — to \
        type a path that is not on their machine.
        """)
}
