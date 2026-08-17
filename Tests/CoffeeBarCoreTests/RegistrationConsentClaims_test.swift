// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

// MARK: - The claim this repository is not allowed to make again

/// Refuses any tracked file that says macOS puts a consent prompt on screen when
/// the app registers its privileged helper.
///
/// **What macOS actually does.** `SMAppService.register()` throws
/// `NSPOSIXErrorDomain 1`. No prompt appears, no sheet appears, and nothing
/// tells the user anything happened. The item is filed away disabled, and the
/// user has to walk to System Settings › General › Login Items & Extensions
/// unprompted and turn it on. Consent is a switch the user finds, not a
/// question the system asks.
///
/// **Why a guard and not a fix.** Thirteen separate places in this repository
/// asserted the flow macOS does not implement — comments, a user-visible
/// string, the security policy, the build guide, and two test files. They were
/// corrected one at a time across #71, and nothing whatsoever stopped a
/// fourteenth. A prose defect that has recurred thirteen times is not a typo,
/// it is an invariant nobody wrote down.
///
/// ## The two things this guard does that a `grep` does not
///
/// **1. A line break cannot hide a claim from it.** Two of the thirteen hid
/// inside a wrap and were invisible to every line-oriented search run against
/// them:
///
/// - `Sources/CoffeeBarProbe/main.swift` split `macOS presenting` from
///   `its own authorisation prompt` across a newline AND a `//` marker.
/// - `docs/BUILDING.md` split `approve the prompt` from `macOS presents`
///   across a plain paragraph wrap.
///
/// TWO separate mechanisms deliver that, and they are worth telling apart
/// because the obvious one is not the one doing the work.
///
/// The DETECTION comes from the gap between the tokens being `\W`-tolerant.
/// `upToSixWords` steps over a newline, a `//` and a `>` alike, because none of
/// them is a word character. Measured 2026-08-17, by making
/// `consentClaimProse(_:)` line-local: BOTH wrapped fixtures were still found.
/// So the normaliser is not what makes a wrapped claim visible, and an earlier
/// draft of this comment saying it was, was wrong.
///
/// The NORMALISER earns its place somewhere quieter: it fixes the SPAN this
/// scan reports, and therefore the span `trueStatementsThatMayKeepThisPhrasing`
/// is compared against. Without it, the day somebody re-wraps `SECURITY.md`'s
/// true sentence across its comma, the matched span grows a newline, stops
/// equalling its allowlist entry, and this guard goes red on a sentence that is
/// true. That is why `aClaimSplitAcrossALineBreakIsStillFound()` asserts the
/// EXACT spans rather than merely that something matched — the weaker
/// assertion was measured to stay green through a normaliser regression.
///
/// **2. It discriminates, so the true sentences survive.** Saying a prompt does
/// not exist, or would be needed by some product that is not this one, is TRUE
/// and has to stay sayable. Three of them are in the tree today and they are
/// not exceptions to the rule, they are the rule stated backwards:
///
/// - `SECURITY.md` — "The app shows **no** authorization prompt", about the
///   v0.2 `sudo` path, where nothing is shown and nothing is installed.
/// - `Sources/CoffeeBarUI/PreferencesView.swift` — a switch there "would have
///   to grow an authorization prompt".
/// - `Tests/CoffeeBarUITests/LidClosedPanel_test.swift` — a softened sentence
///   "describes a product that would need an authorization prompt to exist".
///
/// The last two carry no verb of presenting, so no pattern below reaches them
/// and they need no exemption at all. That is the design working: the rule
/// forbids the ASSERTION that something is shown, not the word "prompt".
///
/// ## The allowlist, and why it is three strings and not three files
///
/// `trueStatementsThatMayKeepThisPhrasing` holds the exact spans, byte for
/// byte, that the patterns below match inside a sentence that is true. Two
/// sentences produce them: `SECURITY.md`'s negated one, and the failure message
/// in `Tests/CoffeeBarUITests/PrivilegedHelperClient_test.swift`, which quotes
/// the forbidden promise in order to refuse it and matches under two patterns
/// at two different spans.
///
/// The exemption is keyed to the MATCHED CLAIM and to nothing else — not to a
/// file, not to a line, not to a surrounding window. Two consequences, both
/// deliberate:
///
/// - A path-keyed exemption would excuse every future sentence in that file.
///   These three strings are true wherever they appear, because each states
///   that a prompt is absent, so binding them to a path would buy brittleness
///   and no safety.
/// - The comparison is CASE SENSITIVE and whole-span. A re-cased or re-worded
///   near-miss is not exempt and turns this red. That is the intent: the
///   allowlist names the sentences that exist, not a family they belong to.
///
/// ## What this guard does NOT catch — stated so nobody over-trusts it
///
/// 1. **Phrasings with no noun.** The shipped string that started #71 read
///    "macOS will ask you to approve it once", which names no prompt, no sheet
///    and no dialog, so nothing here would see it. That exact sentence is
///    pinned by whole-string equality in
///    `Tests/CoffeeBarUITests/PrivilegedHelperClient_test.swift`, which is the
///    right shape for a user-visible constant and the wrong shape for a
///    tree-wide sweep. The two guards are complements, not substitutes.
/// 2. **This file.** It quotes the forbidden phrasings as fixtures and as
///    allowlist entries, so it would report itself forever. It is skipped by
///    repo-relative PATH derived from `#filePath` — never a basename, because
///    `main.swift` alone occurs twice in this tree and a basename would exempt
///    every file that shares one. The cost is real: a false claim written into
///    THIS file is unguarded.
/// 3. **Paraphrase.** "macOS asks first" carries the same false mechanism with
///    none of these tokens. This refuses the shapes that have actually been
///    written thirteen times; it is not a semantic reader.
/// 4. **Untracked and binary files.** The corpus is `trackedTextFiles()`. An
///    untracked scratch file is nobody's problem, and a file the scan cannot
///    read as UTF-8 is reported rather than skipped in silence.

// MARK: - Reading prose with the author's line breaks taken out

/// One tracked file reduced to a single line of prose.
///
/// Strips the leading comment or quote marker off each line and then collapses
/// every run of whitespace — including the newlines — into one space, so a
/// claim spanning a wrap reads exactly as it would on one line.
///
/// The markers are stripped LEADING only. Stripping them anywhere would eat the
/// `//` inside a URL and the `*` inside markdown emphasis, changing prose this
/// scan then reports on.
///
/// **The known cost of collapsing blank lines.** Two adjacent paragraphs join,
/// so a verb ending one and a noun opening the next could in principle read as
/// one claim. That is a FALSE POSITIVE — loud, and fixed by looking at the
/// report. The opposite mistake is silent, and it is the one that let two sites
/// through. Measured 2026-08-17 over all 303 tracked text files: zero false
/// positives.
func consentClaimProse(_ text: String) -> String {
    let unmarked = text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line in
            line.replacingOccurrences(of: "^[ \t]*(?:///|//|/\\*+|\\*/|\\*|>)[ \t]?",
                                      with: "",
                                      options: .regularExpression)
        }

    return unmarked
        .joined(separator: " ")
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

// MARK: - The shapes the false claim has actually been written in

/// A verb of putting something on screen.
///
/// Spelled out one form at a time rather than as a stem plus `\w*`. `put` as a
/// stem matches inside `output`, and `pop` inside `population`, and either
/// would fire this guard on prose that says nothing about consent.
private let presentingVerb =
    "\\b(?:present|presents|presenting|presented"
    + "|show|shows|showing|shown"
    + "|display|displays|displaying|displayed"
    + "|put|puts|putting"
    + "|raise|raises|raising|raised"
    + "|surface|surfaces|surfacing|surfaced"
    + "|pop|pops|popping|popped)\\b"

/// A prompt named as an authorisation prompt. Both spellings, because the tree
/// carries both, and hyphenated because "authorisation-sheet" is one keystroke
/// away.
private let authorisationNoun =
    "\\b(?:authorisation|authorization|approval)[\\s\\-]+"
    + "(?:prompt|prompts|sheet|sheets|dialog|dialogs)\\b"

/// A prompt named without the qualifier. On its own this is far too common to
/// forbid — SwiftUI's `.sheet(isPresented:)` alone accounts for several — so it
/// is only ever matched together with an explicit macOS subject below.
private let bareConsentNoun = "\\b(?:prompt|prompts|sheet|sheets|dialog|dialogs)\\b"

/// The subject that turns a bare noun into a claim about the operating system.
private let operatingSystemSubject = "\\b(?:macOS|the OS|the system)\\b"

/// At most six words between two tokens. Bounded so a verb in one sentence
/// cannot pair with a noun three sentences later; the widest real site needed
/// two.
private let upToSixWords = "(?:\\W+\\w+){0,6}\\W+"

/// Every shape of the claim, in both word orders.
///
/// Both orders are needed, and that is measured rather than defensive:
/// `Sources/CoffeeBarPower/PrivilegedHelperService.swift` wrote it as "an
/// authorisation prompt macOS presented", noun first, while
/// `Sources/CoffeeBarProbe/main.swift` wrote it as "presenting its own
/// authorisation prompt", verb first. A one-directional guard is blind to half
/// of the thirteen.
private let forbiddenConsentClaimPatterns = [
    presentingVerb + upToSixWords + authorisationNoun,
    authorisationNoun + upToSixWords + presentingVerb,
    operatingSystemSubject + upToSixWords + presentingVerb + upToSixWords + bareConsentNoun,
    bareConsentNoun + upToSixWords + operatingSystemSubject + upToSixWords + presentingVerb,
]

/// The exact spans that appear inside a sentence which is TRUE.
///
/// Three entries for two sentences: `SECURITY.md`'s negated one, and the
/// failure message in `PrivilegedHelperClient_test.swift`, which the third and
/// fourth patterns both reach at different spans. Compared whole and case
/// sensitively — see the note on the allowlist at the top of this file.
private let trueStatementsThatMayKeepThisPhrasing: Set<String> = [
    "shows no authorization prompt",
    "approval prompt macOS does not show",
    "prompt macOS does not show",
]

/// Every claim in `text` that macOS presents a consent prompt, with the true
/// statements taken out.
///
/// A pattern that fails to compile is REPORTED, not skipped. A guard that
/// silently scans nothing passes for ever, which is the failure this whole file
/// exists to prevent.
func consentPromptClaims(in text: String) -> [String] {
    let prose = consentClaimProse(text)
    var claims: [String] = []

    for pattern in forbiddenConsentClaimPatterns {
        guard let expression = try? NSRegularExpression(pattern: pattern,
                                                        options: [.caseInsensitive]) else {
            claims.append("this guard is broken: a pattern failed to compile")
            continue
        }

        let whole = NSRange(prose.startIndex..., in: prose)
        for match in expression.matches(in: prose, range: whole) {
            guard let range = Range(match.range, in: prose) else { continue }
            let claim = String(prose[range])
            guard !trueStatementsThatMayKeepThisPhrasing.contains(claim) else { continue }
            claims.append(claim)
        }
    }

    return claims
}

// MARK: - The guards

@Test func noTrackedFileClaimsMacOSPresentsAPromptForTheRegistration() throws {
    let root = repoRoot()
    let files = try trackedTextFiles()

    // ANTI-VACUITY. A scan that resolved the wrong root reads nothing, asserts
    // nothing and reports success. The count catches a broken root; the named
    // controls catch a corpus that reaches part of the tree and not the part
    // this issue is about — one of the thirteen lived in each of them.
    #expect(files.count >= 200,
            "scanned \(files.count) tracked text files at \(root.path); this scan is reading almost nothing")
    for control in ["SECURITY.md",
                    "docs/BUILDING.md",
                    "Sources/CoffeeBarProbe/main.swift",
                    "Sources/CoffeeBarPower/ProbeVerb.swift",
                    "Tests/CoffeeBarUITests/PrivilegedHelperClient_test.swift"] {
        #expect(files.contains(control),
                "the corpus never reached \(control), one of the files #71 corrected")
    }

    // THE ONE FILE EXEMPTION, and it is this one — it quotes the forbidden
    // phrasings as fixtures. A repo-relative PATH, never a basename: this tree
    // already has two files called `main.swift`.
    let selfPath = String(#filePath.dropFirst(root.path.count + 1))

    // A file the scan could not READ is a file the scan did not CHECK.
    var unreadable: [String] = []
    var offenders: [String] = []

    for name in files where name != selfPath {
        guard let text = try? String(contentsOf: root.appending(path: name), encoding: .utf8) else {
            unreadable.append(name)
            continue
        }
        for claim in consentPromptClaims(in: text) {
            offenders.append("\(name): \(claim)")
        }
    }

    #expect(offenders.isEmpty, """
        \(offenders.count) place(s) still say macOS presents a prompt when the helper registers. \
        It does not: `register()` throws `NSPOSIXErrorDomain 1`, nothing appears on screen, and \
        the user has to enable the item in System Settings › General › Login Items & Extensions \
        themselves. Say that instead.
        \(offenders.sorted().joined(separator: "\n"))
        """)

    #expect(unreadable.isEmpty, """
        \(unreadable.count) tracked file(s) could not be read as UTF-8, so this scan never \
        checked them: \(unreadable.sorted())
        An unread file is an unguarded file.
        """)
}

@Test func aClaimSplitAcrossALineBreakIsStillFound() {
    // The two real texts, verbatim, as they stood before #71f corrected them.
    // Not invented: the first is `Sources/CoffeeBarProbe/main.swift` lines
    // 26-29 and hides the claim behind a newline AND a `//` marker; the second
    // is `docs/BUILDING.md` and hides it behind a plain markdown wrap, with no
    // marker to strip. Both shapes have to work or the guard is theater on the
    // exact cases that already escaped.
    let wrappedInAComment = """
        // What has NOT changed: no code path in this binary elevates its own
        // privilege. Path (1) is the user's own `sudo`. Path (2) is macOS presenting
        // its own authorisation prompt for a registration the user asked for by
        // clicking, and installing the job itself.
        """
    let wrappedInMarkdown = """
        `SMAppService` when you click the button in Preferences and approve the prompt
        macOS presents. It publishes an XPC endpoint, and every peer on that channel is
        pinned by Team ID **and** bundle ID.
        """

    // The EXACT spans, and not merely that something matched.
    //
    // Named bug this catches, and it was a live one in this file: asserting
    // only `!isEmpty` here is theater against `consentClaimProse(_:)`. Measured
    // 2026-08-17 with the normaliser made line-local — joining on "\n" and
    // collapsing only spaces and tabs — both fixtures were STILL found, because
    // `upToSixWords` steps over a newline by itself, and this test stayed green
    // while every reported span silently grew a newline through its middle. A
    // span with a newline in it no longer equals its entry in
    // `trueStatementsThatMayKeepThisPhrasing`, so the regression this weaker
    // form waved through would have turned the tree scan red on `SECURITY.md`'s
    // true sentence the first time somebody re-wrapped that paragraph.
    #expect(consentPromptClaims(in: wrappedInAComment).sorted() == [
        "macOS presenting its own authorisation prompt",
        "presenting its own authorisation prompt",
    ], "the comment-wrapped claim from main.swift did not normalise to one line")

    #expect(consentPromptClaims(in: wrappedInMarkdown).sorted() == [
        "prompt macOS presents",
    ], "the markdown-wrapped claim from docs/BUILDING.md did not normalise to one line")

    // The control, and the reason this file does not scan line by line. This is
    // not a restatement of the implementation: it is what a line-oriented
    // search REALLY returns over the same bytes, computed here rather than
    // asserted from memory. Both sweeps that missed these two sites read them
    // this way. If a future refactor makes the scan line-local, this goes red
    // while the two expectations above stay green.
    for text in [wrappedInAComment, wrappedInMarkdown] {
        let lineByLine = text.split(separator: "\n").flatMap { consentPromptClaims(in: String($0)) }
        #expect(lineByLine.isEmpty,
                "a line-at-a-time reading found \(lineByLine.count) claim(s), so this control no longer proves the wrap is what hides them")
    }
}

@Test func theTrueStatementsAboutAPromptSurviveTheScan() throws {
    // Each entry is a sentence that is TRUE and must stay sayable, paired with
    // the tracked file it lives in today.
    //
    // Asserting BOTH halves is the point. `isEmpty` alone would stay green if
    // someone deleted the sentence from the tree — the allowlist would then
    // exempt nothing, and this test would be certifying that the guard tolerates
    // near-misses it never actually meets. The presence check makes the corpus
    // carry a real near-miss for the scan above to walk past.
    let mustSurvive = [
        ("SECURITY.md",
         "The app shows no authorization prompt, installs no privileged helper of its own,"),
        ("Sources/CoffeeBarUI/PreferencesView.swift",
         "a switch here would have to grow an authorization prompt"),
        ("Tests/CoffeeBarUITests/LidClosedPanel_test.swift",
         "would need an authorization prompt to exist"),
        ("Tests/CoffeeBarUITests/PrivilegedHelperClient_test.swift",
         "the button again promises an approval prompt macOS does not show"),
    ]

    for (path, sentence) in mustSurvive {
        let claims = consentPromptClaims(in: sentence)
        #expect(claims.isEmpty,
                "the scan reports \(path)'s true sentence as a false claim: \(claims)")

        let url = repoRoot().appending(path: path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("cannot read \(path); this half of the guard cannot run and will not pretend it passed")
            continue
        }

        // Compared through the same normaliser, so re-wrapping the paragraph is
        // allowed and re-wording it is not.
        let stillThere = consentClaimProse(text).contains(consentClaimProse(sentence))
        #expect(stillThere,
                "\(path) no longer carries the true sentence this guard is built to let through; the allowlist now exempts nothing")
    }
}
