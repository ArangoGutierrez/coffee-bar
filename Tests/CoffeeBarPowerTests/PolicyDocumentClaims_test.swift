// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import CoffeeBarCore
@testable import CoffeeBarPower

/// Guards `SECURITY.md` and `docs/ROADMAP.md` against the privileged path that
/// actually shipped.
///
/// **Why this file exists.** `SECURITY.md` bounded M5 before M5 was built, and it
/// bounded a DIFFERENT design: it required the helper to be installed through
/// `SMAppService.daemon(plistName:)` and to listen on an XPC Mach service pinned
/// with `setCodeSigningRequirement(_:)`. None of that shipped, and
/// `noTargetOnThePrivilegedPathReachesForXPCOrSMAppService` now refuses all of it
/// in code. A policy that says "a shipped helper that exceeds any clause below is
/// a vulnerability", above clauses the shipped helper cannot satisfy, declares
/// the shipped product a vulnerability. Nothing could see that: neither
/// `DocsClaims_test.swift` nor `SiteClaims_test.swift` reads either document.
///
/// **Why the guards live HERE rather than in `DocsClaims_test.swift`.** Every
/// check below compares a document against a constant in `CoffeeBarPower` or
/// `CoffeeBarCore` — `ProbeVerb.allCases`, `ProbeVerb.defaultTTLSeconds`,
/// `GuardedJournalReader.requiredDirectoryMode`. `CoffeeBarCoreTests` depends on
/// `CoffeeBarCore` alone and cannot reach the first two, so putting these there
/// would mean either moving a constant out of the target that owns it or
/// checking the numbers against a second copy written in the test. Both are
/// worse than a second document reader.
///
/// **What these checks CANNOT do, stated so nobody over-trusts them.**
///
/// 1. `noPolicyDocumentClaimsAMechanismThePrivilegedPathRefuses` reads the words
///    immediately before a mechanism's name, on ITS OWN LINE. It proves the
///    phrasing is negative, never that the surrounding paragraph is true. A
///    false sentence written with a negator in front of the token passes.
/// 2. The line bound is load-bearing and is the reason a mention and its negator
///    must sit on ONE line. Allowing the scan to run backwards past a newline
///    made the original bullet pair pass: `- It listens on an XPC Mach service
///    through NSXPCListener(...)` was preceded, one line earlier, by `not the
///    deprecated SMJobBless path` — so a window of 90 characters found "not" and
///    cleared a claim that was entirely affirmative.
/// 3. They read the two documents a reader is pointed at for policy.
///    `docs/coffee-bar-HANDOFF.md` is deliberately NOT among them: its §5.3
///    records the XPC design in full, as a design note about a road not taken,
///    and holding a design archive to a shipped-product rule would be red on a
///    document that is doing its job. That gap is real and is stated rather than
///    hidden.

/// The package root, resolved from `#filePath`.
///
/// Never from the working directory: under `swift test` the working directory is
/// not the package root, and a guard that silently reads nothing is worse than
/// no guard.
private func policyRoot() -> URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarPowerTests/PolicyDocumentClaims_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarPowerTests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // the package root
}

private struct PolicyDocumentUnreadable: Error, CustomStringConvertible {
    let path: String
    var description: String {
        "cannot read \(path); this guard cannot run and will not pretend it passed"
    }
}

/// Throws rather than returning "" so a mis-resolved root fails loudly. An empty
/// string satisfies every `contains` and every loop below.
private func policyDocument(_ name: String) throws -> String {
    let url = policyRoot().appending(path: name)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        throw PolicyDocumentUnreadable(path: url.path)
    }
    return text
}

/// The documents that bound the privileged path for a reader.
private let policyDocuments = ["SECURITY.md", "docs/ROADMAP.md"]

/// One mechanism the privileged-path check refuses in code.
///
/// `wholeWord` adds a TRAILING boundary and exists for `XPC` alone. Without it
/// the bare token matches inside `NSXPCListener`, which is already listed on its
/// own, and every failure would be reported twice against the same characters.
///
/// A LEADING boundary is applied to every token, always, and it is not
/// symmetry — it is the discrimination this guard is for. The corrective prose
/// cites the code guard by name, and that name ENDS in one of these tokens:
/// `…ReachesForXPCOrSMAppService`. Without the leading boundary the citation
/// itself reads as an affirmative claim, so the check went red on the very
/// sentence that fixes the document. A guard that cannot tell a mechanism from
/// a description of refusing that mechanism is the defect, not the fix.
private struct RefusedMechanism {
    let token: String
    let wholeWord: Bool
}

/// The same list `AppLayerBoundary_test.swift` forbids in code, plus the bare
/// word a document uses where code names a type.
///
/// Kept in step with that list BY HAND, and that is a stated weakness rather
/// than a hidden one: the two files are in different test targets and cannot
/// share a constant. `theRefusedListStillNamesTheMechanismsTheCodeGuardRefuses`
/// below is what stops the two drifting silently.
private let refusedMechanisms = [
    RefusedMechanism(token: "SMAppService", wholeWord: false),
    RefusedMechanism(token: "SMJobBless", wholeWord: false),
    RefusedMechanism(token: "NSXPCListener", wholeWord: false),
    RefusedMechanism(token: "NSXPCConnection", wholeWord: false),
    RefusedMechanism(token: "setCodeSigningRequirement", wholeWord: false),
    RefusedMechanism(token: "machServiceName", wholeWord: false),
    RefusedMechanism(token: "XPC", wholeWord: true),
]

/// Words that turn a mechanism's name into a statement about what does NOT
/// happen.
///
/// Deliberately short. A generous list stops discriminating: "instead" and
/// "rather" read as negation to a human and clear an affirmative claim that
/// merely mentions an alternative somewhere earlier on the line.
private let negators = ["no", "not", "never", "cannot", "neither", "nor",
                        "without", "refuses", "refused", "rejected"]

/// Where one mechanism is named, and what the line says before it.
private struct MechanismMention {
    let document: String
    let line: Int
    let text: String
    /// The part of THIS LINE before the token. Never the previous line.
    let before: String
    let token: String
}

private struct BadMechanismPattern: Error, CustomStringConvertible {
    let pattern: String
    var description: String {
        "the regex \(pattern) does not compile, so this guard scanned nothing"
    }
}

/// Every place `mechanism` is named in `document`, one entry per occurrence.
private func mentions(of mechanism: RefusedMechanism,
                      in document: String,
                      named name: String) throws -> [MechanismMention] {
    let escaped = NSRegularExpression.escapedPattern(for: mechanism.token)
    let pattern = "\\b\(escaped)" + (mechanism.wholeWord ? "\\b" : "")
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
        throw BadMechanismPattern(pattern: pattern)
    }

    var found: [MechanismMention] = []
    let lines = document.split(separator: "\n", omittingEmptySubsequences: false)
    for (index, line) in lines.enumerated() {
        let text = String(line)
        let ns = text as NSString
        for match in expression.matches(in: text,
                                        range: NSRange(location: 0, length: ns.length)) {
            found.append(MechanismMention(document: name,
                                          line: index + 1,
                                          text: text,
                                          before: ns.substring(to: match.range.location),
                                          token: mechanism.token))
        }
    }
    return found
}

/// Whether `text` denies something, by whole word.
///
/// Whole-word matching is not decoration: a substring test reads "not" inside
/// "notarisation" and "no" inside "notify", both of which appear in these
/// documents and neither of which denies anything.
private func carriesANegator(_ text: String) -> Bool {
    for word in negators {
        if text.range(of: "\\b\(word)\\b",
                      options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
    }
    return false
}

/// Every mention of every refused mechanism, across both policy documents.
private func allMechanismMentions() throws -> [MechanismMention] {
    var found: [MechanismMention] = []
    for name in policyDocuments {
        let text = try policyDocument(name)
        for mechanism in refusedMechanisms {
            found += try mentions(of: mechanism, in: text, named: name)
        }
    }
    return found
}

// MARK: - The guard cannot pass vacuously

@Test(arguments: policyDocuments)
func everyPolicyDocumentIsReadableAndSubstantial(_ name: String) throws {
    let text = try policyDocument(name)
    #expect(text.count > 1000,
            "\(name) is \(text.count) bytes; every check here would pass vacuously")
}

/// The hand-copied list still names what the code guard refuses.
///
/// Named bug this catches: somebody adds a seventh API to
/// `noTargetOnThePrivilegedPathReachesForXPCOrSMAppService`, the documents start
/// recommending it, and this file never looks for it. The two lists cannot share
/// a constant across test targets, so this reads the OTHER TEST FILE and
/// compares. Reading a test as text is ugly; a coverage hole that looks like
/// thorough work is worse.
@Test func theRefusedListStillNamesTheMechanismsTheCodeGuardRefuses() throws {
    let guardFile = policyRoot()
        .appending(path: "Tests/CoffeeBarUITests/AppLayerBoundary_test.swift")
    guard let source = try? String(contentsOf: guardFile, encoding: .utf8) else {
        Issue.record("cannot read \(guardFile.path); this cross-check cannot run")
        return
    }

    // The forbidden list inside the privileged-path check, not the several other
    // `forbidden` lists in that file. Anchored on the check's own name.
    let anchor = "func noTargetOnThePrivilegedPathReachesForXPCOrSMAppService"
    guard let start = source.range(of: anchor) else {
        Issue.record("\(guardFile.lastPathComponent) no longer declares \(anchor)")
        return
    }
    let body = source[start.upperBound...]
    guard let listStart = body.range(of: "let forbidden = ["),
          let listEnd = body.range(of: "]", range: listStart.upperBound..<body.endIndex) else {
        Issue.record("cannot find the forbidden list inside \(anchor)")
        return
    }

    let list = String(body[listStart.upperBound..<listEnd.lowerBound])
    let named = Set(try matchedGroups("\"([A-Za-z]+)\"", in: list))

    // Anti-vacuity: an empty parse would make every containment below trivial.
    #expect(named.count >= 6,
            "parsed \(named.count) mechanism(s) from \(anchor); the code guard lists six")

    let mine = Set(refusedMechanisms.map(\.token))
    let missing = named.subtracting(mine)
    #expect(missing.isEmpty, """
        \(anchor) refuses \(missing.sorted()) in code, and this file never looks \
        for it in the policy documents. Add it to `refusedMechanisms`.
        """)
}

/// The capture groups of every match of `pattern` in `text`.
private func matchedGroups(_ pattern: String, in text: String) throws -> [String] {
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
        throw BadMechanismPattern(pattern: pattern)
    }
    let ns = text as NSString
    return expression.matches(in: text, range: NSRange(location: 0, length: ns.length))
        .compactMap { match in
            match.range(at: 1).location == NSNotFound
                ? nil : ns.substring(with: match.range(at: 1))
        }
}

// MARK: - Claim 1: the documents may not recommend what the code refuses

@Test func noPolicyDocumentClaimsAMechanismThePrivilegedPathRefuses() throws {
    let found = try allMechanismMentions()

    // Anti-vacuity, and it is a REQUIREMENT rather than a formality. SECURITY.md
    // is meant to keep explaining why the XPC design was abandoned and what
    // would bring it back, so deleting the reasoning to make this guard pass is
    // itself the failure. A document that names none of these has lost the
    // explanation, not earned a clean bill.
    #expect(found.count >= 4, """
        the policy documents name \(found.count) refused mechanism(s). The XPC \
        reasoning is supposed to survive as the record of a decision — replacing \
        the false premise is the fix, deleting the section is not.
        """)

    for mention in found {
        #expect(carriesANegator(mention.before), """
            \(mention.document):\(mention.line) names \(mention.token) with \
            nothing on the line before it that denies it:
              \(mention.text)
            M5 ships as a root CLI plus a launchd watchdog, and \
            noTargetOnThePrivilegedPathReachesForXPCOrSMAppService refuses this \
            API in code. A document may explain why the mechanism is NOT used; \
            stating that it IS used bounds the shipped product against a design \
            nobody built. Put the denial on the same line as the name.
            """)
    }
}

// MARK: - Claim 2: the documented verb list is the shipped verb list

/// `SECURITY.md` names every verb the binary accepts, and invents none.
///
/// Named bug this catches: `SECURITY.md` listed six verbs — including
/// `heartbeat`, which no build has ever had — while `ProbeVerb` declares five.
/// The list is the whole point of the clause ("its verbs are a fixed list"), so
/// a list that does not match the binary bounds nothing.
@Test func theDocumentedVerbListIsExactlyTheVerbsTheBinaryAccepts() throws {
    let text = try policyDocument("SECURITY.md")

    let anchor = "The complete verb list is"
    let sentences = try matchedGroups("\(anchor)([^\\n]*)", in: text)
    #expect(sentences.count == 1, """
        SECURITY.md carries \(sentences.count) sentence(s) starting "\(anchor)"; \
        this guard needs exactly one, on one line
        """)
    guard let sentence = sentences.first else { return }

    let documented = Set(try matchedGroups("`([a-z]+)`", in: sentence))
    let shipped = Set(ProbeVerb.allCases.map(\.rawValue))

    // A sentence that parsed to nothing would make the comparison below fail
    // with a message about the wrong thing.
    #expect(documented.isEmpty == false,
            "no backticked verb in \"\(anchor)\(sentence)\"")

    #expect(documented == shipped, """
        SECURITY.md documents the verbs \(documented.sorted()); \
        ProbeVerb.allCases is \(shipped.sorted()).
          documented but not shipped: \(documented.subtracting(shipped).sorted())
          shipped but not documented: \(shipped.subtracting(documented).sorted())
        """)
}

// MARK: - Claim 3: the documented journal modes are the enforced modes

/// The modes in the policy are the modes `GuardedJournalReader` refuses to
/// deviate from.
///
/// Read from the constants, not written here as literals. Named bug this
/// catches: `requiredDirectoryMode` relaxed to 0750 to make some path work,
/// leaving SECURITY.md promising a stricter rule than the code enforces — which
/// is exactly the direction a policy must never drift.
@Test func theDocumentedJournalModesAreTheModesTheReaderEnforces() throws {
    let text = try policyDocument("SECURITY.md")

    let directory = String(format: "%04o", GuardedJournalReader.requiredDirectoryMode)
    let file = String(format: "%04o", GuardedJournalReader.requiredFileMode)

    // Both phrases must sit UNBROKEN on one line. A Markdown paragraph that
    // wraps between "exactly" and the mode would defeat `contains`, and the
    // failure would read as a missing promise rather than as a line break.
    #expect(text.contains("journal's own directory is exactly `\(directory)`"), """
        SECURITY.md does not state, on one line, that the journal's own \
        directory is exactly `\(directory)`, which is what \
        GuardedJournalReader.requiredDirectoryMode enforces
        """)
    #expect(text.contains("journal file is exactly `\(file)`"), """
        SECURITY.md does not state, on one line, that the journal file is \
        exactly `\(file)`, which is what GuardedJournalReader.requiredFileMode \
        enforces
        """)
}

// MARK: - Claim 4: the documented TTL bounds are the shipped constants

/// A duration stated beside a named constant is that constant's real value.
///
/// The same shape as `everyNamedConstantMatchesTheNumberBesideIt` in
/// `DocsClaims_test.swift`, against the two constants that bound how long a
/// root process may hold `SleepDisabled`. Naming the constant in backticks is
/// what makes the sentence checkable, so the guard rewards naming it.
@Test func theDocumentedTTLBoundsAreTheShippedConstants() throws {
    let secondsPerUnit: [String: Int] = ["minute": 60, "hour": 3600]
    let bounds: [String: Int] = [
        "ProbeVerb.defaultTTLSeconds": ProbeVerb.defaultTTLSeconds,
        "JournalRecord.maxTTLSeconds": JournalRecord.maxTTLSeconds,
    ]

    for name in policyDocuments {
        let text = try policyDocument(name)
        for (constant, expected) in bounds {
            let pattern = "`\(NSRegularExpression.escapedPattern(for: constant))`"
                        + "[^\\n]{0,60}?(\\d+)\\s*(minute|hour)s?"
            guard let expression = try? NSRegularExpression(pattern: pattern,
                                                            options: [.caseInsensitive])
            else { throw BadMechanismPattern(pattern: pattern) }

            let ns = text as NSString
            for match in expression.matches(in: text,
                                            range: NSRange(location: 0, length: ns.length)) {
                let digits = ns.substring(with: match.range(at: 1))
                let unit = ns.substring(with: match.range(at: 2)).lowercased()
                guard let value = Int(digits), let scale = secondsPerUnit[unit] else { continue }
                #expect(value * scale == expected, """
                    \(name) puts \(digits) \(unit)s beside `\(constant)`, but \
                    that constant is \(expected) s
                    """)
            }
        }
    }

    // Anti-vacuity: the loop above is silent when no document names either
    // constant, which is also what a rotted anchor looks like.
    let security = try policyDocument("SECURITY.md")
    #expect(security.contains("`ProbeVerb.defaultTTLSeconds`"),
            "SECURITY.md no longer names ProbeVerb.defaultTTLSeconds, so the TTL default is unchecked")
    #expect(security.contains("`JournalRecord.maxTTLSeconds`"),
            "SECURITY.md no longer names JournalRecord.maxTTLSeconds, so the TTL cap is unchecked")
}

// MARK: - Guard: a "no root" promise cannot outlive the root path

/// Every page a reader is shown, discovered rather than listed.
///
/// Discovery for `site/`, because that is the directory that grew: `docs.html`
/// was invisible to `DocsClaims_test.swift` for a week behind a four-element
/// literal, and two planted defects survived it. A new page inherits this guard
/// on the day it is added.
private func publishedSitePages() -> [String] {
    let dir = policyRoot().appending(path: "site")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasSuffix(".html") }.map { "site/\($0)" }.sorted()
}

/// The Markdown a reader is pointed at, which is a LIST and not a glob.
///
/// A glob over `docs/` would sweep in `docs/probe-results.md` and
/// `docs/coffee-bar-HANDOFF.md`, which ask "…without root?" as a research
/// QUESTION, and `docs/HANDOFF-M0.md`, which records a superseded scope. Holding
/// a research log to a product-promise rule is red on a document doing its job —
/// the same reason note 3 above keeps the handoff out of `policyDocuments`.
/// `docs/superpowers/` is excluded for the same reason: it is a design archive.
private let publishedMarkdown = ["README.md", "CHANGELOG.md", "SECURITY.md",
                                 "docs/ROADMAP.md", "docs/QUICKSTART.md"]

private var rootPromiseSurfaces: [String] { publishedSitePages() + publishedMarkdown }

/// One surface reduced to the words a reader actually meets.
///
/// The `<meta>` descriptions are pulled out FIRST and kept, which is the whole
/// reason this cannot reuse a plain tag-stripper: a description lives in a tag
/// ATTRIBUTE, so stripping `<[^>]+>` deletes the claim along with the tag. That
/// text is the link preview — for most readers it is the first and only claim
/// they see — and it carried "no root" on both `description` and
/// `og:description`.
///
/// Comments go next, and that ordering is the lesson from `2247ae4`: a guard
/// that reads a maintainer note matches its own explanation and proves nothing.
private func readerFacingProse(_ name: String) throws -> String {
    var s = try policyDocument(name)
    guard name.hasSuffix(".html") else {
        s = s.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ",
                                   options: .regularExpression)
        return s.replacingOccurrences(of: "`[^`]*`", with: " ",
                                      options: .regularExpression)
    }

    let metaPattern = "<meta[^>]*(?:name|property)=\"(?:og:)?description\""
                    + "[^>]*content=\"([^\"]*)\""
    let previews = (try? matchedGroups(metaPattern, in: s)) ?? []

    s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ",
                               options: .regularExpression)
    s = s.replacingOccurrences(of: "<pre>[\\s\\S]*?</pre>", with: " ",
                               options: .regularExpression)
    s = s.replacingOccurrences(of: "<style>[\\s\\S]*?</style>", with: " ",
                               options: .regularExpression)
    s = s.replacingOccurrences(of: "<code>[^<]*</code>", with: " ",
                               options: .regularExpression)
    s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    return (previews + [s]).joined(separator: " ")
}

/// Prose cut into sentences, without cutting a version number in half.
///
/// A period only ends a sentence when whitespace follows it. `v0.1 needed no
/// root at all` is ONE sentence; splitting on every period makes it `v0` and
/// `1 needed no root at all`, and the second fragment has lost the very
/// qualifier that makes the claim true. The scope is a sentence and not a
/// character window on purpose: note 2 above records a 90-character window
/// clearing an entirely affirmative claim by reaching backwards into an
/// unrelated line.
private func sentences(of prose: String) -> [String] {
    let flat = prose.replacingOccurrences(of: "\\s+", with: " ",
                                          options: .regularExpression)
    let characters = Array(flat)
    var found: [String] = []
    var current = ""
    for (index, character) in characters.enumerated() {
        current.append(character)
        guard character == "." || character == "!" || character == "?" else { continue }
        let next = index + 1 < characters.count ? characters[index + 1] : " "
        if next == " " {
            found.append(current)
            current = ""
        }
    }
    if !current.trimmingCharacters(in: .whitespaces).isEmpty { found.append(current) }
    return found
}

/// The words that scope a root promise to something that stays true.
///
/// Deliberately short, for the reason `negators` above is short. Each one names
/// either the SUBJECT the promise is true of — the menu-bar app — or the VERSION
/// it was true of. A generous list stops discriminating: "simple", "local" and
/// "private" all sound reassuring beside "no root" and scope nothing.
private let rootPromiseQualifiers = ["the app", "menu-bar app", "v0.1", "v0.2",
                                     "opt-in", "never elevates",
                                     "sudo coffee-bar-probe"]

/// A sentence promising that root is not needed.
private let rootPromisePattern = "\\b(?:no|without)\\s+root\\b"

/// No published surface promises "no root" without saying who or what that is
/// true of, while `coffee-bar-probe` ships a verb that needs uid 0.
///
/// **Named bug this catches.** M5 added `sudo coffee-bar-probe arm` and the panel
/// began printing that command, while six sentences across the site and the docs
/// kept their v0.1 phrasing: "No root. No password prompt." A reader met an
/// unqualified promise on the home page and a `sudo` command in the app. The
/// promise was not a lie — the app really does hold one unprivileged assertion —
/// it was INCOMPLETE, and nothing in the suite could see the gap because no guard
/// read a claim about privilege at all.
///
/// **Why the root fact is derived and not typed.** `ProbeVerb.requiresRoot` is
/// the source of truth for which verbs need uid 0, and this check imports it.
/// Writing `let probeNeedsRoot = true` here would restate the defect rather than
/// detect it, and would keep asserting it after the root path was removed.
///
/// **What this CANNOT do.**
///
/// 1. It proves a qualifier sits in the sentence, never that the sentence is
///    true. "The app needs no root" passes whether or not the app is honest.
/// 2. It reads the surfaces that EXIST in this repository. The same claim in a
///    release note, a README badge or a Homebrew tap description is invisible.
/// 3. `rootPromiseQualifiers` is a judgement call. A drafter who writes "the
///    app" into a sentence that is really about the daemon passes this guard.
@Test func noPublishedSurfacePromisesNoRootWhileTheProbeShipsARootVerb() throws {
    let rootVerbs = ProbeVerb.allCases.filter(\.requiresRoot).map(\.rawValue)

    // Derived, and stated as an assertion rather than an `if`: were the root
    // path removed, this guard would silently switch off and leave every
    // qualification below unexplained. That change should be loud.
    #expect(!rootVerbs.isEmpty, """
        no ProbeVerb requires root any more, so the qualifications this guard \
        enforces are stale. Revisit them and this check together.
        """)

    var promisesSeen = 0
    for name in rootPromiseSurfaces {
        let prose = try readerFacingProse(name)
        for sentence in sentences(of: prose) {
            guard sentence.range(of: rootPromisePattern,
                                 options: [.regularExpression, .caseInsensitive]) != nil
            else { continue }
            promisesSeen += 1

            let qualified = rootPromiseQualifiers.contains {
                sentence.range(of: $0, options: .caseInsensitive) != nil
            }
            #expect(qualified, """
                \(name) promises "no root" without a qualifier, but \
                coffee-bar-probe ships \(rootVerbs.sorted()) behind uid 0. Say \
                who the promise is true of — the app, or a version. Sentence: \
                \(sentence.trimmingCharacters(in: .whitespaces))
                """)
        }
    }

    // Anti-vacuity, and a second job: the promise is TRUE of the app and worth
    // keeping, so deleting it rather than qualifying it is also a failure here.
    #expect(promisesSeen >= 4,
            "found \(promisesSeen) root promise(s) across \(rootPromiseSurfaces.count) surfaces; this guard swept air")
    let home = try readerFacingProse("site/index.html")
    #expect(home.range(of: rootPromisePattern,
                       options: [.regularExpression, .caseInsensitive]) != nil, """
        site/index.html no longer promises "no root". The app really does need \
        none, so the fix for an incomplete promise is to qualify it, never to \
        drop it.
        """)
}
