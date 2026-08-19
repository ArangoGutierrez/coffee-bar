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

    /// Whether issue #71 entitled two named files to USE this mechanism.
    ///
    /// The distinction the documents turn on. A mechanism nothing may call must
    /// never be described affirmatively in a policy document, because a reader
    /// would be told the product does something it structurally cannot. A
    /// mechanism two entitled files DO call is a mechanism the policy has to
    /// describe — and describing it under a negator would be the false claim
    /// instead.
    ///
    /// This is a NARROWING and not a deletion. `SMJobBless` is entitled for
    /// nobody, so the rule still bites, and
    /// `everyEntitledMechanismInTheDocumentsArrivesWithItsPin` below replaces
    /// what the negator was buying for the other six.
    let entitled: Bool

    init(token: String, wholeWord: Bool, entitled: Bool = false) {
        self.token = token
        self.wholeWord = wholeWord
        self.entitled = entitled
    }
}

/// The same list `AppLayerBoundary_test.swift` forbids in code, plus the bare
/// word a document uses where code names a type.
///
/// Kept in step with that list BY HAND, and that is a stated weakness rather
/// than a hidden one: the two files are in different test targets and cannot
/// share a constant. `theRefusedListStillNamesTheMechanismsTheCodeGuardRefuses`
/// below is what stops the two drifting silently — and it is why every token
/// stays here after #71 even though six of them are now reachable: the code
/// guard still FORBIDS all six everywhere outside two entitled files, and a
/// token dropped from this list would be a token no document is checked for at
/// all.
private let refusedMechanisms = [
    RefusedMechanism(token: "SMAppService", wholeWord: false, entitled: true),
    RefusedMechanism(token: "SMJobBless", wholeWord: false),
    RefusedMechanism(token: "NSXPCListener", wholeWord: false, entitled: true),
    RefusedMechanism(token: "NSXPCConnection", wholeWord: false, entitled: true),
    RefusedMechanism(token: "setCodeSigningRequirement", wholeWord: false, entitled: true),
    RefusedMechanism(token: "machServiceName", wholeWord: false, entitled: true),
    RefusedMechanism(token: "XPC", wholeWord: true, entitled: true),
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

    // ENTITLED mechanisms are exempt from the negator, and only those (#71).
    // The rule is unchanged for everything else: a document may not describe a
    // mechanism the code cannot call. What changed is that six of these CAN now
    // be called, from two named files, so requiring a denial beside them would
    // force the policy to state the opposite of what ships.
    //
    // `SMJobBless` is entitled for nobody and still needs its negator, which is
    // what keeps this loop discriminating rather than vacuous.
    let entitledTokens = Set(refusedMechanisms.filter(\.entitled).map(\.token))
    for mention in found where !entitledTokens.contains(mention.token) {
        #expect(carriesANegator(mention.before), """
            \(mention.document):\(mention.line) names \(mention.token) with \
            nothing on the line before it that denies it:
              \(mention.text)
            noTargetOnThePrivilegedPathReachesForXPCOrSMAppService refuses this \
            API in code, in EVERY file — it is not one of the two the #71 \
            entitlement names. A document may explain why the mechanism is NOT \
            used; stating that it IS used bounds the shipped product against a \
            design nobody built. Put the denial on the same line as the name.
            """)
    }
}

@Test func everyEntitledMechanismInTheDocumentsArrivesWithItsPin() throws {
    // What replaces the negator for the six mechanisms #71 entitled, and the
    // reason dropping the negator is a narrowing rather than a hole.
    //
    // The old rule bought one thing: a reader could not be told coffee-bar
    // speaks XPC, because it did not. It does now — so the claim that has to be
    // held true instead is the one the whole design rests on. An XPC channel
    // whose peer is unpinned accepts every local process and is strictly worse
    // than the sudo command it replaces, because it looks safe. A policy that
    // describes the channel and omits the pin describes exactly that product.
    //
    // Named bug: somebody trims this section for length, the paragraph
    // explaining the peer requirement goes, and SECURITY.md then documents a
    // root Mach service with no stated authentication at all.
    let text = try policyDocument("SECURITY.md")

    // ANTI-VACUITY: this check means nothing unless the document really does
    // describe the channel.
    #expect(text.contains("SMAppService") || text.contains("Mach service"), """
        SECURITY.md describes no XPC helper at all, so this check is asserting \
        nothing. The channel ships; the policy has to bound it.
        """)

    // BOTH pins, by name, because either one alone is a different product. A
    // team identifier is an AUTHOR — pinning it alone accepts every tool this
    // team ever signs. A bundle identifier is a NAME anybody may choose —
    // pinning it alone accepts a self-signed impostor.
    #expect(text.contains(PrivilegedHelperIdentity.teamIdentifier), """
        SECURITY.md never names the team identifier the XPC peer is pinned to
        """)
    #expect(text.contains(PrivilegedHelperIdentity.appIdentifier), """
        SECURITY.md never names the app bundle identifier the helper demands
        """)
    #expect(text.contains(PrivilegedHelperIdentity.helperIdentifier), """
        SECURITY.md never names the helper bundle identifier the app demands
        """)

    // And the anchor without which the other two clauses are decoration: both
    // `identifier` and `subject.OU` are fields the signer chooses.
    #expect(text.contains("anchor apple generic"), """
        SECURITY.md states the identifier and team pins without the Apple \
        anchor that makes either of them mean anything
        """)
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

/// Where Markdown ends a sentence without writing a full stop.
///
/// Named rather than inlined because a second reader needs exactly the same
/// list: `everyStatedElevationNameCountMatchesTheCodeGuardsList` below keeps the
/// backticks `readerFacingProse` deletes and so cannot reuse that function, but
/// two copies of these four patterns would drift the first time one was fixed.
private let markdownSentenceBoundaries = ["\\n\\s*\\n", "\\n(?=#{1,6}\\s)",
                                          "\\n(?=[-*+]\\s)", "\\n(?=[0-9]+\\.\\s)"]

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
        s = s.replacingOccurrences(of: "`[^`]*`", with: " ",
                                   options: .regularExpression)

        // Markdown has the same merging problem HTML does, and this file found
        // it: `docs/ROADMAP.md` was judged on a sentence that began with the
        // heading "## Why this differs from the handoff" and ran straight into
        // the paragraph below it. A heading, a bullet and a blank line all end a
        // sentence for a reader, and none of them carries a full stop.
        for boundary in markdownSentenceBoundaries {
            s = s.replacingOccurrences(of: boundary, with: " . ",
                                       options: .regularExpression)
        }
        return s
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

    // CHROME GOES WHOLE, before anything else is read. `<nav>` and `<title>`
    // carry no sentence-ending punctuation, so tag-stripping alone glues them
    // onto whatever prose follows. That is not hypothetical: an unqualified
    // "It needs no root." planted at the top of `site/privacy.html` was judged
    // as the sentence "Privacy — coffee-bar coffee-bar Home Install Docs
    // Changelog v0.1.1 Privacy It needs no root.", and the nav's version badge
    // qualified it. Every page's highest-visibility position was unguarded.
    for element in ["nav", "title", "header", "footer"] {
        s = s.replacingOccurrences(of: "<\(element)[^>]*>[\\s\\S]*?</\(element)>",
                                   with: " ", options: .regularExpression)
    }

    // A BLOCK BOUNDARY ENDS A SENTENCE. Removing the chrome above is not enough
    // on its own — `<h1>Privacy</h1>` is page content, not chrome, and it merged
    // into the planted sentence just as the nav did. Closing block tags become a
    // full stop so a heading, a list item or a table cell cannot lend its words
    // to the next claim. Inline tags are deliberately absent from this list:
    // `<strong>` inside a sentence must not split it.
    let blockElements = ["p", "div", "li", "ul", "ol", "dl", "dd", "dt",
                         "h1", "h2", "h3", "h4", "h5", "h6", "section",
                         "article", "aside", "main", "blockquote", "figcaption",
                         "td", "th", "tr", "table", "form", "fieldset", "legend"]
    for element in blockElements {
        s = s.replacingOccurrences(of: "</\(element)>", with: " . ",
                                   options: [.caseInsensitive])
    }

    s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    // Each preview is its own sentence for the same reason: two `<meta>` tags
    // concatenated would let one description qualify the other.
    return (previews.map { $0 + " . " } + [s]).joined(separator: " ")
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
private let rootPromiseQualifiers = ["the app", "menu-bar app", "opt-in",
                                     "never elevates", "sudo coffee-bar-probe"]

/// An explicit version, matched as a COMPLETE token.
///
/// This replaces the literals `v0.1` and `v0.2`, and the reason is a defect that
/// a partial fix would have hidden. Requiring those two literals to match as
/// whole tokens is correct — `v0.2` must not be satisfied by `v0.20` — but it
/// also rejects `v0.1.0`, which is a REAL version and the exact word
/// `CHANGELOG.md` uses to scope its own claim. Tightening the literals alone
/// turned a true sentence red.
///
/// A version qualifier is therefore a version NUMBER, not a prefix of one. The
/// patch component is optional so `v0.2` still qualifies, and the token must end
/// where the pattern does, so `v0.2` never matches inside `v0.20`.
///
/// The trailing guard is `(?!\.?\d)` rather than `\b`: a word boundary sits
/// between the `1` and the `.` in `v0.1.1`, so `\b` would accept a prefix.
private let versionQualifierPattern =
    "(?<![\\w.])v[0-9]+\\.[0-9]+(?:\\.[0-9]+)?(?!\\.?\\d)"

/// One qualifier as a pattern that matches the WHOLE token and not a prefix.
///
/// `v0.1` is a prefix of `v0.1.1`, and a plain `contains` treated the two as the
/// same word. The sidebar of every page carries a `v0.1.1` version badge, so a
/// substring match let that badge qualify a claim — a version the sentence never
/// mentioned, scoping a promise the author never scoped.
///
/// The trailing guard is `(?!\.?\d)` and not `\b`, deliberately. A word boundary
/// sits between the `1` and the `.` of `v0.1.1`, so `\b` matches there and would
/// keep the defect. This refuses a following digit, with or without a dot
/// between, which is what tells `v0.1` from `v0.1.1`. It still allows `v0.1` at
/// the end of a sentence, where the next character is a full stop and no digit
/// follows.
private func qualifierPattern(for qualifier: String) -> String {
    "(?<![\\w.])" + NSRegularExpression.escapedPattern(for: qualifier) + "(?!\\.?\\d)"
}

/// A sentence that makes a claim about needing privilege.
///
/// TWO shapes, because the first one alone missed a real defect. The original
/// pattern looked for "no root" and nothing else, so it read straight past
/// `site/terms.html` saying "That needs a privileged helper, and this release
/// does not have one" — a privilege claim that named root nowhere, on the very
/// page `PanelView.legalURL()` sends users to. The gap was the PATTERN, not the
/// surface list: that page was already being swept.
///
/// "privileged helper" is matched WITHOUT a negator in front of it, unlike the
/// root half. Any sentence that raises the subject at all must say who it is
/// true of, because the failure here was a version-relative promise — true when
/// written, false the moment v0.2.0 is tagged — rather than a negation.
private let rootPromisePattern = "\\b(?:no|without)\\s+root\\b|\\bprivileged helper\\b"

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
                sentence.range(of: qualifierPattern(for: $0),
                               options: [.regularExpression, .caseInsensitive]) != nil
            } || sentence.range(of: versionQualifierPattern,
                                options: [.regularExpression, .caseInsensitive]) != nil
            #expect(qualified, """
                \(name) makes a claim about privilege without a qualifier, but \
                coffee-bar-probe ships \(rootVerbs.sorted()) behind uid 0. Say \
                who the claim is true of — the app, or a version — and never a \
                version-relative phrase like "this release", which stops being \
                true at the next tag. Sentence: \
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

// MARK: - Guard: a duration in a policy document is a real product constant

/// Every duration a policy document may state, each read from the symbol that
/// defines it.
///
/// **Why this sweep lives here and not in `DocsClaims_test.swift`.** That file's
/// `everyDurationStatedIsARealProductConstant` knows `StalePolicy` alone,
/// because `CoffeeBarCoreTests` depends on `CoffeeBarCore` and
/// `ProbeVerb.defaultTTLSeconds` lives in `CoffeeBarPower`. It cannot reach half
/// the numbers `SECURITY.md` states. Writing 1800 there as a literal would break
/// the single rule that guard exists to enforce — that a number in prose is a
/// real constant rather than a second copy of one. `CoffeeBarPowerTests` reaches
/// all four, so the sweep moves rather than the rule bending.
///
/// This was not a theory. `SECURITY.md` joined `markdownSurfaces` on main while
/// this branch added the M5 TTLs to that document. Each side was green alone and
/// the two together were red, with no textual conflict for git to report.
private let policyDurationConstants: [String: Int] = [
    "StalePolicy.standard.workingTimeout": Int(StalePolicy.standard.workingTimeout),
    "StalePolicy.standard.blockedTimeout": Int(StalePolicy.standard.blockedTimeout),
    "ProbeVerb.defaultTTLSeconds": ProbeVerb.defaultTTLSeconds,
    "JournalRecord.maxTTLSeconds": JournalRecord.maxTTLSeconds,
]

/// Deliberately the same shape `DocsClaims_test.swift` uses, so the two sweeps
/// read one document the same way.
///
/// `[\s-]*` is the load-bearing part and it crosses newlines. `SECURITY.md`
/// wraps "gives 30\n  minutes" across a line break, and a line-oriented pattern
/// reports that document as carrying no duration at all — which is exactly how
/// a hand grep of this file came back empty while three real durations sat in
/// it.
private let policyDurationPattern = "(\\d[\\d,_]*)[\\s-]*(second|minute|hour)s?"

private let policySecondsPerUnit = ["second": 1, "minute": 60, "hour": 3600]

/// Both capture groups of every duration in `text`.
private func durationsStated(in text: String) throws -> [(digits: String, unit: String)] {
    guard let expression = try? NSRegularExpression(pattern: policyDurationPattern,
                                                    options: [.caseInsensitive])
    else { throw BadMechanismPattern(pattern: policyDurationPattern) }
    let ns = text as NSString
    return expression.matches(in: text, range: NSRange(location: 0, length: ns.length))
        .map { (ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2))) }
}

/// Every duration a policy document states is a constant the product really
/// holds.
///
/// **Named bug this catches.** `SECURITY.md` states the default hold and the
/// hard ceiling. Change `ProbeVerb.defaultTTLSeconds` and the document keeps
/// promising the old figure — a security policy describing a bound the code no
/// longer enforces. `theDocumentedTTLBoundsAreTheShippedConstants` catches that
/// only where the number sits on the SAME LINE as its backticked symbol,
/// because its anchor is `[^\n]{0,60}?`. It therefore misses the third mention,
/// the one in the sentence about what a hold you walk away from will spend,
/// which names no symbol at all. This guard reads the prose instead of the
/// neighbourhood of a symbol, so it sees all three.
///
/// STRUCTURAL / EQUALITY, with a PRESENCE anti-vacuity half below.
///
/// **What this CANNOT do.** It proves a stated duration EQUALS some product
/// constant. It cannot prove the document attached the right constant to the
/// right sentence: swapping "30 minutes" and "8 hours" in one paragraph leaves
/// both numbers real, and both wrong. `theDocumentedTTLBoundsAreTheShippedConstants`
/// is what pairs a number with its symbol, so the two guards are complementary
/// rather than redundant.
@Test func everyDurationInAPolicyDocumentIsARealProductConstant() throws {
    let known = Set(policyDurationConstants.values)
    var seen: Set<Int> = []
    var sweptInSecurity = 0

    for name in policyDocuments {
        let prose = try readerFacingProse(name)
        for stated in try durationsStated(in: prose) {
            let digits = stated.digits.replacingOccurrences(of: ",", with: "")
                                      .replacingOccurrences(of: "_", with: "")
            guard let value = Int(digits),
                  let scale = policySecondsPerUnit[stated.unit.lowercased()] else { continue }
            let seconds = value * scale
            seen.insert(seconds)
            if name == "SECURITY.md" { sweptInSecurity += 1 }

            #expect(known.contains(seconds), """
                \(name) states "\(stated.digits) \(stated.unit)" = \(seconds) s, \
                which is no product constant. Known: \
                \(policyDurationConstants.sorted { $0.value < $1.value }
                    .map { "\($0.key)=\($0.value)" })
                """)
        }
    }

    // ANTI-VACUITY. A rotted pattern matches nothing and this guard would pass
    // on a document full of wrong numbers — the defect
    // `everyControlNamedExistsInTheProduct` shipped with, where a regex that
    // produced zero phrases asserted nothing at all and stayed green.
    #expect(sweptInSecurity >= 3, """
        the duration sweep found \(sweptInSecurity) duration(s) in SECURITY.md \
        and that document states at least three: the default hold twice and \
        the hard ceiling once. The pattern has rotted, so this guard is \
        reading nothing.
        """)
    #expect(seen.contains(ProbeVerb.defaultTTLSeconds), """
        the sweep never saw ProbeVerb.defaultTTLSeconds stated in a policy \
        document, so the default TTL is described nowhere a reader can find it
        """)
    #expect(seen.contains(JournalRecord.maxTTLSeconds), """
        the sweep never saw JournalRecord.maxTTLSeconds stated in a policy \
        document, so the TTL cap is described nowhere a reader can find it
        """)
}

/// The site pages `DocsClaims_test.swift` hands over, and why each is here.
///
/// `site/docs.html` states how long `sudo coffee-bar-probe arm` holds — issue
/// #56 moved the lid-closed explanation out of the menu-bar panel and onto that
/// page, and the panel's paragraph had pointed at documentation that did not
/// exist. The number is `ProbeVerb.defaultTTLSeconds`, and `CoffeeBarCoreTests`
/// depends on `CoffeeBarCore` alone, so `everyDurationStatedIsARealProductConstant`
/// cannot judge it. It is listed in that file's `durationSweepExclusions`, and
/// `theDurationSweepExcludesOnlySurfacesAnotherGuardCovers` names this check as
/// the guard that fills the hole.
///
/// A LIST and not `publishedSitePages()`, deliberately. Discovery would be the
/// better default — it is what that helper exists for — but this list mirrors an
/// exclusion list in another target that a glob could silently outgrow: a page
/// discovered HERE and not excluded THERE is swept twice, which is harmless, while
/// a page excluded there and never added here is swept by nobody. The pairing
/// check below refuses the second case.
private let handedOverSitePages = ["site/docs.html"]

/// The site page excluded from the core sweep is the one this file sweeps.
///
/// Named bug this catches: somebody adds a third surface to
/// `durationSweepExclusions` to quiet a red sweep, and the coverage disappears
/// with nothing to say so. The two lists live in different test targets and
/// cannot share a constant, so this reads the other file as text — ugly, and
/// better than a coverage hole that looks like thorough work.
@Test func everySitePageHandedOverByTheCoreSweepIsSweptHere() throws {
    let other = policyRoot()
        .appending(path: "Tests/CoffeeBarCoreTests/DocsClaims_test.swift")
    guard let source = try? String(contentsOf: other, encoding: .utf8) else {
        Issue.record("cannot read \(other.path); this cross-check cannot run")
        return
    }

    let declaration = "private let durationSweepExclusions: Set<String> = "
    guard let start = source.range(of: declaration),
          let end = source[start.upperBound...].firstIndex(of: "]") else {
        Issue.record("""
            DocsClaims_test.swift no longer declares durationSweepExclusions on \
            one line, so this cross-check read nothing. Re-anchor it.
            """)
        return
    }
    let excluded = source[start.upperBound...end]

    for page in handedOverSitePages {
        #expect(excluded.contains("\"\(page)\""), """
            \(page) is swept here as a hand-over from DocsClaims_test.swift, but \
            that file no longer excludes it. Either the hand-over ended — drop it \
            from handedOverSitePages — or the exclusion was lost.
            """)
    }

    // The other direction, which is the one that loses coverage. Any `site/`
    // page excluded there and absent here is a page no duration sweep reads.
    for match in try matchedGroups("\"(site/[^\"]+)\"", in: String(excluded)) {
        #expect(handedOverSitePages.contains(match), """
            DocsClaims_test.swift excludes \(match) from its duration sweep and \
            this file does not sweep it, so no guard reads the durations on that \
            page at all.
            """)
    }
}

/// Every duration on a handed-over site page is a constant the product holds.
///
/// **Named bug this catches.** `site/docs.html` tells the reader that arming
/// lid-closed mode holds for 30 minutes. Raise `ProbeVerb.defaultTTLSeconds` to
/// 45 and the page goes on promising 30 to a stranger deciding whether to shut
/// the lid on a laptop and walk away. Nothing else reads that page's durations:
/// the core sweep hands it over precisely because it cannot reach the constant.
///
/// STRUCTURAL / EQUALITY, with a PRESENCE anti-vacuity half.
///
/// **What this CANNOT do.** It proves a stated duration EQUALS some product
/// constant, not that the page attached the right constant to the right
/// sentence. `theSiteExplainsLidClosedModeAndStatesTheShippedHold` in
/// `Tests/CoffeeBarUITests/LidClosedPanel_test.swift` is what pairs the number
/// with the lid-closed section it belongs to, so the two are complementary.
@Test func everyDurationOnADocumentedSitePageIsARealProductConstant() throws {
    let known = Set(policyDurationConstants.values)
    var swept = 0

    for name in handedOverSitePages {
        let prose = try readerFacingProse(name)
        for stated in try durationsStated(in: prose) {
            let digits = stated.digits.replacingOccurrences(of: ",", with: "")
                                      .replacingOccurrences(of: "_", with: "")
            guard let value = Int(digits),
                  let scale = policySecondsPerUnit[stated.unit.lowercased()] else { continue }
            swept += 1

            #expect(known.contains(value * scale), """
                \(name) states "\(stated.digits) \(stated.unit)" = \
                \(value * scale) s, which is no product constant. Known: \
                \(policyDurationConstants.sorted { $0.value < $1.value }
                    .map { "\($0.key)=\($0.value)" })
                """)
        }
    }

    // ANTI-VACUITY, and it is not a formality here. `readerFacingProse` strips
    // `<code>` blocks before this reads a word, so a duration wrapped in one is
    // invisible to this guard AND to the core sweep it took over from — the
    // page would carry a number no check anywhere reads, which is the exact
    // shape of the hole `durationSweepExclusions` exists to close.
    #expect(swept >= 1, """
        the sweep found no duration in \(handedOverSitePages.joined(separator: ", ")). \
        Those pages are excluded from the core duration sweep on the grounds \
        that this one reads them, so a page with nothing readable here is a page \
        nothing checks. Is the number inside a <code> block?
        """)
}

// MARK: - Guard: a citation points at text, and text does not renumber

/// Every `.swift` file under `Sources/` and `Tests/`.
private func allSwiftFiles() -> [URL] {
    var found: [URL] = []
    for base in ["Sources", "Tests"] {
        let dir = policyRoot().appending(path: base)
        guard let walker = FileManager.default.enumerator(atPath: dir.path) else { continue }
        for case let rel as String in walker where rel.hasSuffix(".swift") {
            found.append(dir.appending(path: rel))
        }
    }
    return found.sorted { $0.path < $1.path }
}

/// Text reduced so a citation can be compared against a document that wraps.
///
/// Three things go, and each one is a real failure this had to survive. Comment
/// markers go, because the cited rationale in a `.swift` file is itself a doc
/// comment. Backticks and `**` go, because `SECURITY.md` writes
/// **Every ancestor** in bold and a citation should quote the sentence, not the
/// Markdown. Whitespace collapses LAST and across newlines, because the anchor
/// this guard exists to protect — "Every ancestor is owned by root" — is split
/// over two lines in the document it cites.
private func citationNormalised(_ text: String) -> String {
    var s = text.replacingOccurrences(of: "^\\s*///?\\s?", with: "",
                                      options: [.regularExpression])
    s = s.replacingOccurrences(of: "(?m)^\\s*///?\\s?", with: "",
                               options: [.regularExpression])
    s = s.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
    return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
}

/// Every capture group of every match, local because `DocsClaims_test.swift`'s
/// `matches` is internal to `CoffeeBarCoreTests` and this is a different target.
///
/// Throws on a bad pattern rather than returning `[]`. An empty result from a
/// pattern that never compiled looks exactly like a clean tree.
private func citationMatches(_ pattern: String, in text: String) throws -> [[String]] {
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
        throw BadMechanismPattern(pattern: pattern)
    }
    let ns = text as NSString
    return expression.matches(in: text, range: NSRange(location: 0, length: ns.length))
        .map { match in
            (0..<match.numberOfRanges).map { i in
                match.range(at: i).location == NSNotFound
                    ? "" : ns.substring(with: match.range(at: i))
            }
        }
}

/// Every comment in one Swift file, with the line each one starts on.
///
/// BOTH forms, because a citation is invisible to the guard in whichever form it
/// does not read. The line form was covered first and the block form was not;
/// today that is latent — the only block comments in this tree are in the
/// embedded C stand-in and hold no citations — but a guard that reads one of two
/// comment syntaxes fails open the first time somebody writes the other.
///
/// STATED LIMIT. This finds comment SYNTAX, not comments: `/*` or `//` inside a
/// string literal is read as opening one. That imprecision is not new here — the
/// line scan already had it, and a URL in a literal contains `//` — and it can
/// only cause a FALSE POSITIVE, never a missed citation, because the extra text
/// is scanned rather than skipped. A precise answer needs the tokenizer that
/// `swiftCodeWithoutComments` has, in a target this one cannot import.
private func commentFragments(of body: String) throws -> [(Int, String)] {
    var found: [(Int, String)] = []

    for (index, raw) in body.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = String(raw)
        if let start = line.range(of: "//") {
            found.append((index, String(line[start.upperBound...])))
        }
    }

    // Block comments are matched over the whole file, so one spanning ten lines
    // is one fragment. The line number is counted from the text before it, which
    // keeps a failure message pointing at something a reader can open.
    let ns = body as NSString
    guard let expression = try? NSRegularExpression(pattern: "/\\*[\\s\\S]*?\\*/") else {
        throw BadMechanismPattern(pattern: "/\\*[\\s\\S]*?\\*/")
    }
    for match in expression.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
        let before = ns.substring(to: match.range.location)
        found.append((before.filter { $0 == "\n" }.count, ns.substring(with: match.range)))
    }
    return found
}

/// A file named in a citation, resolved to one path or to nothing.
///
/// Exactly one match is required. A basename that resolves to two files would
/// let this guard check the wrong one and report success.
private func citedFile(named name: String) -> URL? {
    if name.contains("/") {
        let direct = policyRoot().appending(path: name)
        return FileManager.default.fileExists(atPath: direct.path) ? direct : nil
    }
    let atRoot = policyRoot().appending(path: name)
    if FileManager.default.fileExists(atPath: atRoot.path) { return atRoot }
    let matches = allSwiftFiles().filter { $0.lastPathComponent == name }
    return matches.count == 1 ? matches[0] : nil
}

/// No source or test cites a document by LINE NUMBER, and every anchor a
/// citation quotes still exists in the file it names.
///
/// **Named bug this catches.** Commit `46404fb` rewrote `SECURITY.md` and moved
/// every heading in it. Fifteen citations across `Sources/` and `Tests/` named
/// that document by line range, and every one kept pointing at its old numbers,
/// which by then held unrelated prose — one cited range had become hook-snippet
/// text and another had become "M5 adds a root path". Shipped security code
/// pointed readers at the wrong paragraphs, and the branch's own review brief
/// then inherited a stale pointer and repeated it. A line number is a reference
/// that rots silently on every edit above it.
///
/// **Scope.** The line-number half refuses BOTH `.md` and `.swift` targets. It
/// refused `.md` alone when it landed, because the Swift citations were a wider
/// edit than that round could carry; they were recorded as follow-up rather
/// than quietly excluded, and this is that follow-up. A Swift line number rots
/// exactly as an `.md` one does, and it rotted here before anyone converted it:
/// two of the fourteen pointed more than a thousand lines away from the prose
/// they claimed, into unrelated declarations. The ANCHOR half below covers
/// every cited file, `.md` and `.swift` alike.
///
/// Every number here is measured, and no example of the refused shape is
/// written out. An earlier draft named two, and those two then counted
/// themselves: a grep returned twelve where the tree held ten. That is the same
/// self-reference trap described below, met a second time while writing the
/// note about it.
///
/// The line-number pattern is deliberately not written out in this comment. An
/// earlier draft spelled one as an example, and this guard read its own
/// explanation and reported the file that defines it — the same false positive
/// `refusedMechanisms` records above, where corrective prose citing a mechanism
/// by name turned the check red on the very sentence that fixed it.
///
/// **This guard reads the RAW file on purpose, and must.** A citation lives in a
/// comment, so the comments ARE its subject — `swiftCodeWithoutComments` would
/// blind it to every single thing it checks. That is the opposite of the panel
/// tripwires, which must strip comments to avoid matching their own prose. The
/// rule decides the reading: this one is "must not NAME a line citation".
///
/// **What this CANNOT do.** It proves the quoted words still appear in the cited
/// file. It cannot prove they still mean what the citing comment claims, and it
/// cannot see a citation written without quotes.
@Test func noSourceCitesADocumentByLineNumberAndEveryAnchorResolves() throws {
    var lineCitations: [String] = []
    var anchorsChecked = 0

    for file in allSwiftFiles() {
        guard let body = try? String(contentsOf: file, encoding: .utf8) else { continue }
        let short = file.lastPathComponent

        for (index, comment) in try commentFragments(of: body) {

            for m in try citationMatches("[A-Za-z0-9_/.]+\\.(?:md|swift):[0-9]+", in: comment) {
                lineCitations.append("\(short):\(index + 1) cites \(m[0])")
            }

            for m in try citationMatches("`?([A-Za-z0-9_/.]+\\.(?:md|swift))`?\\s+\"([^\"]{8,90})\"",
                                 in: comment) {
                let name = m[1], anchor = citationNormalised(m[2])
                guard let target = citedFile(named: name) else {
                    Issue.record("\(short):\(index + 1) cites \(name), which resolves to no single file")
                    continue
                }
                guard let text = try? String(contentsOf: target, encoding: .utf8) else {
                    Issue.record("\(short):\(index + 1) cites \(name), which cannot be read")
                    continue
                }
                anchorsChecked += 1
                #expect(citationNormalised(text).contains(anchor), """
                    \(short):\(index + 1) cites \(name) "\(anchor)", and that text \
                    is no longer in \(name). Quote text that exists, or update the \
                    citation — a reference nobody can follow is worse than none.
                    """)
            }
        }
    }

    #expect(lineCitations.isEmpty, """
        \(lineCitations.count) citation(s) name a file by LINE NUMBER, which \
        rots on the next edit above it. Quote anchor TEXT instead. \
        \(lineCitations.sorted())
        """)

    // ANTI-VACUITY. A pattern that matches nothing passes silently, which is the
    // defect `everyControlNamedExistsInTheProduct` ships with today.
    //
    // The floor is the MEASURED total, not a round number under it. It was 15
    // when only the `.md` citations had been converted; the Swift round added
    // fourteen more, and leaving the floor at 15 after the population doubled
    // would let half of them stop resolving with this guard still green. Raise
    // it with every conversion round, for the same reason.
    #expect(anchorsChecked >= 29, """
        resolved \(anchorsChecked) anchor citation(s) against a measured floor of \
        29, so the citation pattern has rotted and this guard is reading less \
        than the tree holds
        """)
}

// MARK: - Guard: a retired capability promise cannot outlive the capability

/// One thing the shipped app does, and the declaration that proves it does.
///
/// The capability is DERIVED and never typed. Writing `let appCanArm = true`
/// here would restate the defect this guard exists to catch rather than detect
/// it, and it would keep asserting the same thing on the day the button is
/// taken out again.
private struct ShippedHelperCapability {
    /// What a reader would call it.
    let what: String
    /// A repo-relative path, never a basename.
    let file: String
    /// An exact declaration, matched as text. Never a call: a leading `.` before
    /// any of these names is the shape `noTestCanMakeTheSuiteRegisterTheHelperForReal`
    /// refuses, and a guard that spells one would file an item into the
    /// maintainer's System Settings the first time the suite ran.
    let declaration: String
}

/// The four things `SECURITY.md` said the app could not do, each read off the
/// declaration that does it.
///
/// All four live in one file because #71 put them there: that file is the only
/// place in the app layer entitled to name the registration API, and
/// `theAppLayerNeverReachesForPrivilegeEscalation` holds the entitlement to
/// exactly it. A capability that moves to a second file turns this red with a
/// message saying so, which is the loud failure and not a false one.
private let shippedHelperCapabilities = [
    ShippedHelperCapability(
        what: "installs the privileged helper",
        file: "Sources/CoffeeBarUI/PrivilegedHelperClient.swift",
        declaration: "public func register() -> HelperArmOutcome?"),
    ShippedHelperCapability(
        what: "arms lid-closed mode",
        file: "Sources/CoffeeBarUI/PrivilegedHelperClient.swift",
        declaration: "public func arm(seconds: Int) async -> HelperArmOutcome"),
    ShippedHelperCapability(
        what: "reverts a lid-closed hold",
        file: "Sources/CoffeeBarUI/PrivilegedHelperClient.swift",
        declaration: "public func revert() async -> HelperRevertOutcome"),
    ShippedHelperCapability(
        what: "takes the helper back off",
        file: "Sources/CoffeeBarUI/PrivilegedHelperClient.swift",
        declaration: "public func unregisterHelper() throws"),
]

/// The sentences `SECURITY.md` may no longer ASSERT, byte for byte.
///
/// **Whole sentences, never substrings, and the difference is the whole design.**
/// The fix for a claim that has stopped being true is to restate it — the
/// document says so about v0.2 in the paragraph above these — so the retired
/// wording has to stay QUOTABLE while it stops being sayable. A substring test
/// cannot tell the two apart: it goes red on the correction and on the defect
/// alike, and the author's only way out is to delete the history. Comparing the
/// whole sentence lets the document quote its own past, which is the behaviour
/// this file is here to protect.
///
/// Each is written as `sentences(of:)` yields it: single spaces, trimmed. That
/// is not a formatting nicety — a claim spelled with a stray double space would
/// never match anything, and the guard would pass for ever.
private let retiredElevationClaims = [
    "The app shows no authorization prompt, installs no privileged helper of "
        + "its own, and has no route to becoming root.",
    "It cannot arm lid-closed mode, cannot install that daemon, and cannot "
        + "revert one.",
]

/// Emphasis taken off BEFORE the prose is cut into sentences, which is the only
/// place it does anything.
///
/// **Measured, not assumed.** Stripping `**` from each finished sentence was the
/// first draft, and it caught nothing: planting
/// `**It cannot arm lid-closed mode, cannot install that daemon, and cannot
/// revert one.**` as its own paragraph left this guard GREEN. `sentences(of:)`
/// ends a sentence at a full stop followed by WHITESPACE, deliberately, so that
/// `v0.1` survives; a bolded sentence puts a `*` there instead. The claim was
/// therefore never a sentence of its own to normalise, and it ran on into the
/// paragraph after it. Taking the markers off first restores the boundary, and
/// the same planted paragraph is red.
///
/// Quotation marks are deliberately KEPT. They are what tells a document
/// quoting its own retired wording from a document still asserting it, and that
/// distinction is the reason these claims are matched whole. Stripping `"` here
/// would turn the correction red along with the defect.
///
/// `_underscore_` italics are not stripped. This tree writes emphasis with
/// asterisks, and `_` is a word character in the file names both documents are
/// full of: `JournalStore_test.swift` would be mangled to buy a laundering route
/// nobody has used.
private func emphasisRemoved(_ prose: String) -> String {
    prose.replacingOccurrences(of: "*", with: "")
}

/// One sentence reduced to the claim it makes.
///
/// A leading blockquote marker goes, for the reason emphasis does: `> It cannot
/// arm lid-closed mode…` asserts to a skimming reader exactly what the unmarked
/// sentence asserts, and the marker is one keystroke.
///
/// KNOWN CONSEQUENCE, stated rather than discovered: quoting a retired claim as
/// a standalone blockquoted sentence turns this red even though the surrounding
/// paragraph disowns it. The document's own convention is to quote inline, which
/// is what the corrected section does, and a bare blockquote of a false sentence
/// is what a skimming reader takes for an assertion anyway.
private func claimNormalised(_ sentence: String) -> String {
    let s = sentence.trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: "^>\\s*", with: "", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespaces)
}

/// Which of the retired claims `prose` asserts as a sentence of its own.
private func retiredClaimsAsserted(in prose: String) -> [String] {
    let said = Set(sentences(of: emphasisRemoved(prose)).map { claimNormalised($0).lowercased() })
    return retiredElevationClaims.filter { said.contains(claimNormalised($0).lowercased()) }
}

/// `SECURITY.md` does not deny a capability the app ships, and does not airbrush
/// the denial it used to make.
///
/// **Named bug this catches.** `It never elevates its own privilege` was written
/// for v0.2 and kept its v0.2 sentences after M5's successor shipped: the app
/// "installs no privileged helper of its own" and "cannot arm lid-closed mode,
/// cannot install that daemon, and cannot revert one", while the section three
/// screens further down described the app installing, arming and reverting
/// exactly that helper. One document, both claims, and nothing in the suite read
/// either one. `noPolicyDocumentClaimsAMechanismThePrivilegedPathRefuses` reads
/// API names and not capabilities; `noPublishedSurfacePromisesNoRootWhileTheProbeShipsARootVerb`
/// asks a privilege sentence for a qualifier, and both of those sentences carry
/// one — "the app" — so both went through it green.
///
/// **Why the capability half is derived from `Sources/`.** A retired claim is
/// only retired while the code contradicts it. Were the button taken out again,
/// "it cannot arm lid-closed mode" would go back to being TRUE, and a guard that
/// kept refusing it would be forcing a false sentence into a security policy.
/// The declarations are therefore asserted rather than assumed: lose one and
/// this fails loudly, pointing at the claims that have to be revisited with it.
///
/// **What this CANNOT do.**
///
/// 1. It matches the sentences that were actually written, not the family they
///    belong to. "The app installs no helper of its own" is a paraphrase and
///    goes straight through. This is a regression guard on prose that shipped,
///    not a semantic reader — the same limit `RegistrationConsentClaims_test.swift`
///    states about paraphrase.
/// 2. It proves a sentence is ABSENT, never that what replaced it is true. The
///    replacement paragraph is prose, and no check here reads it for honesty.
/// 3. The quotation half proves the retired wording is still ON the page, never
///    that the sentence around it disowns it rather than endorsing it.
@Test func noPolicyDocumentDeniesTheHelperTheAppNowInstallsArmsAndReverts() throws {
    // 1. THE CAPABILITY, read off the code. Stated as an assertion and not an
    //    `if`, for the reason the root-verb guard above gives: a capability
    //    quietly removed would switch this guard off and leave the retired
    //    claims below refused on nobody's authority.
    for capability in shippedHelperCapabilities {
        let source = try policyDocument(capability.file)
        #expect(source.contains(capability.declaration), """
            \(capability.file) no longer declares `\(capability.declaration)`, so \
            this guard can no longer show that the app \(capability.what). Either \
            the declaration moved — point this at it — or the capability went, in \
            which case the sentences in `retiredElevationClaims` may be true again \
            and have to be revisited WITH this check, not without it.
            """)
    }

    // 2. THE CLAIM, refused as a whole sentence.
    let prose = try readerFacingProse("SECURITY.md")
    let asserted = retiredClaimsAsserted(in: prose)
    #expect(asserted.isEmpty, """
        SECURITY.md still asserts \(asserted.count) sentence(s) that the shipped \
        app contradicts — it installs the helper, arms lid-closed mode and reverts \
        a hold, all of which are declared in \
        \(Set(shippedHelperCapabilities.map(\.file)).sorted()). Restate the claim \
        the way the paragraph above restates v0.2's; do not delete it.
        \(asserted.map { "  • \($0)" }.joined(separator: "\n"))
        """)

    // 3. THE CONTROL. Every check above is an ABSENCE, and an absence is what a
    //    broken matcher reports too. This puts the retired claims into the prose
    //    and requires all of them back: a normaliser that stopped normalising, a
    //    claim written with a double space, a sentence splitter that stopped
    //    splitting — each one is green at step 2 and red here.
    let planted = prose + " " + retiredElevationClaims.joined(separator: " ")
    #expect(Set(retiredClaimsAsserted(in: planted)) == Set(retiredElevationClaims), """
        the retired claims were planted back into SECURITY.md's prose and \
        \(retiredClaimsAsserted(in: planted).count) of \(retiredElevationClaims.count) \
        came back. This guard cannot see the sentence it exists to refuse, so its \
        silence at step 2 means nothing.
        """)

    // 4. THE HISTORY. The document promises, about v0.2, that a changed promise
    //    is "restated here rather than quietly dropped". A correction that
    //    deletes the old wording instead of quoting it leaves a reader diffing
    //    two releases with no record that anything moved, and that is the
    //    credibility this section trades on.
    let onThePage = try policyDocument("SECURITY.md")
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    for claim in retiredElevationClaims {
        #expect(onThePage.contains(claim), """
            SECURITY.md no longer quotes the retired claim "\(claim)" anywhere. It \
            was true of v0.2 and a reader who remembers it is owed the correction; \
            quote it and say what changed, as the v0.2 paragraph does for v0.1.
            """)
    }

    // 5. THE PROMISE THAT SURVIVES. The app process really does never become
    //    root, and the failure mode of a correction like this one is to lose the
    //    true half along with the false half.
    #expect(onThePage.contains("### It never elevates its own privilege"), """
        SECURITY.md has lost the heading `It never elevates its own privilege`. \
        The promise is still true of the app process and two guards cite this \
        heading by name.
        """)
    #expect(onThePage.contains("never elevates its own privilege."), """
        SECURITY.md no longer states that coffee-bar never elevates its own \
        privilege. macOS running a helper the user approved does not make that \
        false, and dropping it answers a correction with a weaker document.
        """)
}

// MARK: - Guard: a stated name count is the code guard's real name count

/// The check whose forbidden list `SECURITY.md` counts out loud.
private let elevationCheckName = "theAppLayerNeverReachesForPrivilegeEscalation"

private struct ElevationListUnparsable: Error, CustomStringConvertible {
    let why: String
    var description: String {
        "cannot read \(elevationCheckName)'s forbidden list: \(why); this guard "
            + "cannot run and will not pretend it passed"
    }
}

/// The names `theAppLayerNeverReachesForPrivilegeEscalation` forbids, read off
/// that check and never typed here.
///
/// **Scoped to that ONE function, and the scoping is the whole difficulty.**
/// `AppLayerBoundary_test.swift` declares `forbidden` six times, for six
/// different checks. A whole-file match returns 51 names, and a guard built on
/// one would assert confident nonsense — every sentence below wrong, against a
/// number that describes no list anybody wrote. That is worse than no guard,
/// because it looks rigorous while measuring nothing.
///
/// The slice therefore ends at the NEXT `@Test`, not at the end of the file.
/// Anchoring on the check's name alone is not enough: if this function ever
/// stopped declaring `forbidden`, an unbounded search would run straight on into
/// `noLinkedTargetCanReachTheNetworkByAddress`'s list — network APIs, nothing to
/// do with privilege — and silently measure that instead. Bounded, the same case
/// is an error.
private func forbiddenElevationNames() throws -> [String] {
    let file = policyRoot()
        .appending(path: "Tests/CoffeeBarUITests/AppLayerBoundary_test.swift")
    guard let source = try? String(contentsOf: file, encoding: .utf8) else {
        throw ElevationListUnparsable(why: "cannot read \(file.path)")
    }
    guard let anchor = source.range(of: "func \(elevationCheckName)") else {
        throw ElevationListUnparsable(
            why: "\(file.lastPathComponent) no longer declares it")
    }
    let nextCheck = source.range(of: "\n@Test",
                                 range: anchor.upperBound..<source.endIndex)?.lowerBound
        ?? source.endIndex
    let body = source[anchor.upperBound..<nextCheck]
    guard let listStart = body.range(of: "let forbidden = ["),
          let listEnd = body.range(of: "]", range: listStart.upperBound..<body.endIndex)
    else {
        throw ElevationListUnparsable(
            why: "it declares no `forbidden` list before the next @Test")
    }

    // Line comments go before the string literals are read. One of them is
    // `// "with administrator privileges"`, and a quoted phrase in a comment is
    // a gloss on a name rather than a name on the list.
    let list = String(body[listStart.upperBound..<listEnd.lowerBound])
        .replacingOccurrences(of: "//[^\n]*", with: "", options: .regularExpression)
    return try matchedGroups("\"([A-Za-z]+)\"", in: list)
}

/// Number words a count sentence may use.
///
/// Spelled out because English is what the document is written in and
/// `Int("seven")` is nil. Digits are accepted as well: "and 7 more names" states
/// the same thing, and a guard that read only words would let the digit form
/// through unchecked.
private let numberWords = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
                           "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
                           "eleven": 11, "twelve": 12, "thirteen": 13,
                           "fourteen": 14, "fifteen": 15, "sixteen": 16,
                           "seventeen": 17, "eighteen": 18, "nineteen": 19,
                           "twenty": 20]

private func numberValue(_ word: String) -> Int? {
    numberWords[word.lowercased()] ?? Int(word)
}

private func numberWord(_ value: Int) -> String {
    numberWords.first { $0.value == value }?.key ?? String(value)
}

/// One sentence that states how many names the elevation check refuses.
///
/// The arithmetic is split the way the document splits it: some names spelled
/// out, then "and N more names". BOTH halves are read from the prose. Deriving
/// one and assuming the other is how these sentences drifted — the numeral was
/// written once and never revisited when the list grew.
private struct StatedNameCount {
    /// The sentence as `sentences(of:)` yielded it.
    let sentence: String
    /// Forbidden names the sentence spells out, deduplicated.
    let named: Set<String>
    /// The word the document used for the remainder, kept verbatim so the
    /// control below can rewrite exactly it.
    let moreWord: String
    /// That word as a number.
    let more: Int

    var stated: Int { named.count + more }
}

/// Which forbidden names a sentence spells out.
///
/// Read from the BACKTICK SPANS and nowhere else. The surrounding prose is
/// English about names, denylists and privilege, and a plain `contains` over the
/// whole sentence would count the check's own name against the list it
/// describes: `theAppLayerNeverReachesForPrivilegeEscalation` is cited in both
/// sentences, and a matcher reading `…PrivilegeEscalation` as an API would
/// inflate every count by one and hide the very error this catches.
///
/// A span need not BE a name. `NSAppleScript "with administrator privileges"` is
/// one span naming one API, and the quoted phrase after it is how the document
/// tells that route from the others.
///
/// The boundaries are letters-only on both sides. `setuid` must not be found
/// inside `seteuid`, and `AuthorizationCreate` must not be counted a second time
/// by matching inside `AuthorizationCreateFromExternalForm`.
private func namesSpelledOut(in sentence: String,
                             from forbidden: [String]) throws -> Set<String> {
    let spans = try matchedGroups("`([^`]*)`", in: sentence)
    return Set(try forbidden.filter { name in
        let pattern = "(?<![A-Za-z])"
            + NSRegularExpression.escapedPattern(for: name)
            + "(?![A-Za-z])"
        guard (try? NSRegularExpression(pattern: pattern)) != nil else {
            throw BadMechanismPattern(pattern: pattern)
        }
        return spans.contains { $0.range(of: pattern, options: .regularExpression) != nil }
    })
}

/// Every sentence of `prose` that cites the elevation check and states a count,
/// plus the ones that state a count this guard could not read.
///
/// The unreadable half is returned rather than dropped. A remainder written as
/// "a further six" parses to nothing, and a parser that quietly skipped it would
/// leave that sentence unguarded while reporting success — the failure mode this
/// whole section exists to refuse.
private func statedNameCounts(in prose: String,
                              from forbidden: [String]) throws -> (claims: [StatedNameCount],
                                                                   unreadable: [String]) {
    var claims: [StatedNameCount] = []
    var unreadable: [String] = []
    for sentence in sentences(of: prose) where sentence.contains(elevationCheckName) {
        let words = try matchedGroups("(\\S+)\\s+more\\s+names", in: sentence)
        guard !words.isEmpty else { continue }
        guard words.count == 1, let value = numberValue(words[0]) else {
            unreadable.append(sentence)
            continue
        }
        claims.append(StatedNameCount(sentence: sentence,
                                      named: try namesSpelledOut(in: sentence, from: forbidden),
                                      moreWord: words[0],
                                      more: value))
    }
    return (claims, unreadable)
}

/// `SECURITY.md`'s stated name counts are the number of names the code guard
/// actually refuses.
///
/// **Named bug this catches, and it is the one that happened.** The forbidden
/// list grew to ten when #71 added `SMAppService`. Two sentences state its size
/// indirectly — "`AuthorizationExecuteWithPrivileges` and `NSAppleScript …` …
/// refuses them, and seven more names", and "still refuses `setuid`,
/// `launchctl`, `AuthorizationRef` and six more names" — and both still totalled
/// the nine that were there before. Nothing in the suite read either number, and
/// the newer sentence inherited the stale arithmetic from the older one it was
/// modelled on. A reader auditing the policy against the code would have found
/// one name the document does not account for, and no way to tell which of the
/// two sentences was wrong.
///
/// **Why the total is derived and never written down.** A literal `10` here
/// would move the staleness rather than remove it: the next name added would
/// leave the literal, the prose and the code all disagreeing, and this guard
/// would defend the wrong one of the three.
///
/// **What this CANNOT do.**
///
/// 1. It checks arithmetic, never truth. A sentence naming two APIs the list
///    does not contain and claiming eight more totals ten and passes. Whether
///    the names are the right names is
///    `theRefusedListStillNamesTheMechanismsTheCodeGuardRefuses`'s business and
///    `noPolicyDocumentClaimsAMechanismThePrivilegedPathRefuses`'s.
/// 2. It only reads sentences that CITE the check by name and phrase the
///    remainder as "N more names". "and a further six" is invisible to it, which
///    is why the floor below refuses to run on fewer than the two sentences that
///    exist.
/// 3. It reads `SECURITY.md` alone. The same arithmetic written into a comment
///    inside `AppLayerBoundary_test.swift` — "the other nine names are relieved
///    for nobody" — is a second unguarded count, stated here rather than hidden.
@Test func everyStatedElevationNameCountMatchesTheCodeGuardsList() throws {
    let forbidden = try forbiddenElevationNames()

    // This is the one guard in the file that reads backticks rather than through
    // them. `readerFacingProse` deletes every code span, and a code span is
    // exactly where this document puts an API name — so the names half of the
    // arithmetic would always be nought. Fences and comments still go: a sample
    // in a fence is not a promise, and a maintainer note is not prose a reader
    // meets.
    var prose = try policyDocument("SECURITY.md")
        .replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        .replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
    for boundary in markdownSentenceBoundaries {
        prose = prose.replacingOccurrences(of: boundary, with: " . ",
                                           options: .regularExpression)
    }

    let found = try statedNameCounts(in: prose, from: forbidden)

    for sentence in found.unreadable {
        Issue.record("""
            SECURITY.md states a remainder this guard cannot read as a single \
            number, so that sentence's arithmetic goes unchecked. Write it as one \
            number word or one numeral: "\(sentence)"
            """)
    }

    // ANTI-VACUITY, and it is the assertion the rest rests on. Every check below
    // sits inside a loop over the sentences found, so nought sentences is a
    // silent and permanent pass.
    #expect(found.claims.count >= 2, """
        SECURITY.md states \(found.claims.count) name count(s) for \
        \(elevationCheckName), and two sections state one. This guard is the only \
        thing holding either in step with the code. If a sentence was deliberately \
        reworded, move this floor with it rather than leaving the remaining one \
        unwatched.
        """)

    for claim in found.claims {
        #expect(claim.stated == forbidden.count, """
            SECURITY.md accounts for \(claim.stated) name(s) — it spells out \
            \(claim.named.count), \(claim.named.sorted()), and says \
            "\(claim.moreWord) more names" — but \(elevationCheckName) forbids \
            \(forbidden.count): \(forbidden.sorted()). Write \
            "\(numberWord(forbidden.count - claim.named.count)) more names".
              • \(claim.sentence)
            """)
    }

    // THE CONTROL, in both directions. Every assertion above reports AGREEMENT,
    // and a matcher that has stopped matching reports agreement too. Both halves
    // of the arithmetic are mutated here and required to be seen.
    for claim in found.claims {
        // (a) THE NUMERAL. Raise the stated remainder by one. Were the number not
        //     really read off the page, a wrong one would still agree.
        let renumberedProse = claim.sentence.replacingOccurrences(
            of: "\(claim.moreWord) more names",
            with: "\(numberWord(claim.more + 1)) more names")
        #expect(renumberedProse != claim.sentence, """
            the remainder in "\(claim.sentence)" could not be rewritten, so \
            control (a) proves nothing about whether the numeral is read.
            """)
        let renumbered = try statedNameCounts(in: renumberedProse, from: forbidden).claims
        #expect(renumbered.map(\.stated) == [claim.stated + 1], """
            the stated remainder was raised by one and this guard read \
            \(renumbered.map(\.stated)) rather than [\(claim.stated + 1)]. It is \
            not reading the numeral off the page, so its agreement above says \
            nothing: "\(claim.sentence)"
            """)

        // (b) THE NAMES. This is the direction the defect actually came from —
        //     the list grew by `SMAppService` and the prose did not move — so a
        //     control that exercised only the numeral would be half a control.
        //     The name is written INSIDE the sentence, beside the citation, so
        //     the injection cannot escape into a sentence of its own; closing and
        //     reopening the citation's own backticks keeps them balanced.
        guard let extra = forbidden.sorted().first(where: { !claim.named.contains($0) }) else {
            Issue.record("""
                "\(claim.sentence)" already spells out every name \
                \(elevationCheckName) forbids, so control (b) cannot run on it.
                """)
            continue
        }
        let widenedProse = claim.sentence.replacingOccurrences(
            of: elevationCheckName, with: "\(elevationCheckName)` and `\(extra)")
        let widened = try statedNameCounts(in: widenedProse, from: forbidden).claims
        #expect(widened.map(\.named) == [claim.named.union([extra])], """
            `\(extra)` was written into the sentence and this guard still reads \
            \(widened.map { $0.named.sorted() }) rather than \
            \(claim.named.union([extra]).sorted()). It is not reading the names \
            off the page, so a name added to \(elevationCheckName)'s list would \
            leave the arithmetic above green and stale — which is exactly how \
            these two sentences drifted: "\(claim.sentence)"
            """)
    }
}
