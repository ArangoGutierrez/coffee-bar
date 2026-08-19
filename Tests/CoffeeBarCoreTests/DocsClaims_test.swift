// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import CoffeeBarTestSupport
@testable import CoffeeBarCore

/// Guards the user-facing documents' factual claims against the constants that
/// settle them.
///
/// **Why this file exists.** On 2026-08-01 an audit found that no test in this
/// repository could see documentation prose — `git grep README Tests` returned
/// nothing — and three false claims reached commits through a fully green suite:
///
/// 1. "Until these six hooks exist … no session event ever reaches it."
///    `HookHealth.requiredEvents` lists FIVE.
/// 2. "the staleness timeout … takes 15 minutes or more." A finished session
///    takes `blockedTimeout`, 14400 s, not the 900 s `workingTimeout`.
/// 3. "unless you turn on \"stay awake while blocked\"." No such control exists;
///    it was invented from the parameter name `holdAwakeWhileBlocked`.
///
/// **What these checks CANNOT do, stated so nobody over-trusts them.** They
/// cannot tell that a number which IS a real constant is the WRONG constant for
/// the sentence it sits in. Claim 2 quoted 900 s, a genuine `workingTimeout`
/// value, on a path that takes `blockedTimeout`. Only
/// `everyNamedConstantMatchesTheNumberBesideIt` addresses that, and only when
/// the prose names the constant in backticks. That is deliberate: naming the
/// constant is what makes the claim checkable, so the guard rewards naming it.

// MARK: - Reading the README

struct ReadmeUnreadable: Error, CustomStringConvertible {
    let path: String
    var description: String { "cannot read the README at \(path); this guard cannot run" }
}

/// Internal rather than private, so `SiteClaims_test.swift` shares this one
/// definition. A second copy of a path resolver is a second thing to get wrong,
/// and the two copies would not have to drift far to disagree about which
/// repository they are reading.
func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()    // …/Tests/CoffeeBarCoreTests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // repo root
}

/// The README with fenced blocks and inline code removed.
///
/// Claims live in PROSE. A `--max-time 5` inside the hook command is not a claim
/// about a product constant, and scanning it would produce a false positive that
/// trains the reader to ignore this guard.
private func readmeProse(_ text: String) -> String {
    var s = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ",
                                      options: .regularExpression)
    s = s.replacingOccurrences(of: "`[^`\n]*`", with: " ",
                               options: .regularExpression)
    return s
}

/// The user-facing documents these checks police.
///
/// `site/index.html` is the higher-risk of the two: it is what a stranger reads
/// first, and until this file existed nothing in the suite could see it.
/// The page that carries the required-hook JSON block.
///
/// It moved from README.md to the quick start on 2026-08-01. When the block
/// moves again, change THIS and `theHookBlockIsExactlyTheRequiredEvents`
/// follows. Leaving it pointed at a page that no longer holds the block does
/// not fail loudly on its own — the block check would report "no json block" —
/// but `theGuardStillMatchesRealClaims` is what stops coverage vanishing
/// quietly, so keep both in step.
private let hookBlockSurface = "docs/QUICKSTART.md"

/// The four Markdown documents, named by hand.
///
/// These stay a literal while the site half is discovered, because a glob over
/// the repository's Markdown would sweep in specs, plans and task briefs. Those
/// are working notes between maintainers, not claims to a reader, and holding
/// them to a reader's standard would produce noise that trains people to ignore
/// this file.
///
/// `CHANGELOG.md` joined them on 2026-08-04. Nothing read it before that, so a
/// future entry could have claimed token accounting and stayed green.
private let markdownSurfaces = ["CHANGELOG.md", "README.md", "SECURITY.md",
                                "docs/BUILDING.md", "docs/QUICKSTART.md"]

/// Every `.html` file under `site/`, found on disk.
///
/// Sorted because `FileManager` does not specify its enumeration order. An
/// unsorted list reorders swift-testing's per-argument test IDs and the failure
/// output between runs, which makes a real, repeatable failure look flaky.
///
/// Recursive, so a page filed in a subdirectory cannot escape either.
func discoveredSitePages() -> [String] {
    let site = repoRoot().appending(path: "site")
    guard let walker = FileManager.default.enumerator(atPath: site.path) else { return [] }
    var found: [String] = []
    for case let rel as String in walker where rel.hasSuffix(".html") {
        found.append("site/\(rel)")
    }
    return found.sorted()
}

/// The user-facing documents these checks police.
///
/// **Why this is discovered and not a list.** Until 2026-08-04 this was a
/// four-element literal naming `site/index.html` alone, while the site had grown
/// to four pages. That was measured, not suspected: `below 20%` and `42 minutes`
/// were planted in the prose of `site/docs.html` — the exact two defects
/// `aBoundaryPhraseMatchesTheRealBoundary` and
/// `everyDurationStatedIsARealProductConstant` exist to catch — and the suite
/// stayed green at 486 tests. Nothing was broken. Nothing was looking.
///
/// A hardcoded list is a coverage hole with a friendly face: it looks like
/// thorough work and it fails open, silently, the moment somebody adds a page
/// and forgets a line here. Discovery removes the remembering.
///
/// **What this still cannot do.** It guards pages that EXIST. A claim moved off
/// the site and into a blog post, a release note or an App Store description is
/// as invisible as `docs.html` was. Discovery widens the net; it does not make
/// the net universal.
private let documentedSurfaces = (markdownSurfaces + discoveredSitePages()).sorted()

/// An HTML page reduced to prose.
///
/// Comments go first and deliberately: the do-not-publish marker is a comment,
/// and it is an instruction to the maintainer rather than a claim to a reader.
/// `pre` and `style` go too, for the same reason fenced code goes from Markdown.
func htmlProse(_ text: String) -> String {
    var s = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ",
                                      options: .regularExpression)
    s = s.replacingOccurrences(of: "<pre>[\\s\\S]*?</pre>", with: " ",
                               options: .regularExpression)
    s = s.replacingOccurrences(of: "<style>[\\s\\S]*?</style>", with: " ",
                               options: .regularExpression)
    s = s.replacingOccurrences(of: "<code>[^<]*</code>", with: " ",
                               options: .regularExpression)
    s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    return s
}

/// The raw bytes of one documented surface. Internal, so the site guards read
/// pages through the same failure-closed accessor these checks use.
func surfaceText(_ name: String) throws -> String {
    let url = repoRoot().appending(path: name)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        throw ReadmeUnreadable(path: url.path)
    }
    return text
}

private func surfaceProse(_ name: String) throws -> String {
    let url = repoRoot().appending(path: name)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        throw ReadmeUnreadable(path: url.path)
    }
    return name.hasSuffix(".html") ? htmlProse(text) : readmeProse(text)
}

// MARK: - A record of a past release is not a claim about the product today

/// One documented surface reduced to the claims it makes about the product AS
/// IT SHIPS, with everything a released section RECORDS left out.
///
/// **Why this exists — issue #53, and there was a live instance.**
/// `theBatteryFloorStatedIsTheRealDefault` asserts that every percentage in
/// prose is the floor in force TODAY. A changelog's job is to say what each
/// release shipped, so that rule forbids ever writing a floor change down:
/// `CHANGELOG.md` says "It ships at 15%" under the released `## [0.2.0]`
/// heading, and that sentence passes only because 0.2.0's floor happens to
/// equal the current one. The next floor change turns a CORRECT sentence red,
/// and the cheapest way out of a red guard is to falsify the history — which is
/// a defect no test in this repository can ever detect.
///
/// The two 0.1.0 percentages were wrapped in code spans for exactly this
/// reason, with a comment saying so. Hiding a true claim from a guard is a
/// coverage hole with a note attached; teaching the guard what a release
/// section IS lets the claim be written plainly and still be read.
///
/// **What is exempt, stated narrowly.** A `##`-level version heading in
/// Markdown, and the `<section>` a version `<h2>` opens in HTML. Nothing else.
/// `CHANGELOG.md`'s own header says a version heading means a tag exists, so
/// text under one is a record by construction. Every other surface — README,
/// SECURITY, the quick start, every page but the changelog — comes back
/// BYTE-IDENTICAL, and `releaseHistoryIsExemptOnlyWhereAReleaseHistoryExists`
/// pins that for all eleven surfaces rather than trusting it.
///
/// **What this cannot do, stated rather than hidden.** A wrong number inside a
/// released section is now invisible to these guards, which is the price of
/// being able to record a floor change at all. The exemption is bounded by
/// position, never by content, so it cannot be widened by rewording a claim.
private func currentClaimProse(_ name: String) throws -> String {
    let raw = try surfaceText(name)
    if name.hasSuffix(".html") {
        return htmlProse(try htmlWithoutReleaseHistory(raw))
    }
    return readmeProse(markdownWithoutReleaseHistory(raw))
}

/// Markdown with every `##`-level version section removed.
///
/// LINE BASED rather than a multi-line regex: the boundary IS a line here, and
/// a `[\s\S]*?` reaching for the next heading is the shape that has already
/// deleted eighty-five lines when it should have deleted three.
func markdownWithoutReleaseHistory(_ text: String) -> String {
    var kept: [String] = []
    var insideARelease = false
    for line in text.components(separatedBy: "\n") {
        if line.hasPrefix("## ") {
            insideARelease = ((try? matches("^##\\s+\\[?\\d+\\.\\d+\\.\\d+\\]?", in: line)) ?? []).isEmpty == false
        }
        if !insideARelease { kept.append(line) }
    }
    return kept.joined(separator: "\n")
}

/// HTML with every `<section>` opened by a version `<h2>` removed.
///
/// The heading decides, not the `id`: `id="v0-1-0"` is a convention a page can
/// change, while the heading is what a reader sees and what
/// `everyReleaseInTheChangelogIsOnTheChangelogPage` already reads.
func htmlWithoutReleaseHistory(_ text: String) throws -> String {
    var kept = text
    for m in try matches("<section\\b[^>]*>[\\s\\S]*?</section>", in: text) {
        guard try !matches("<h2[^>]*>\\s*\\d+\\.\\d+\\.\\d+", in: m[0]).isEmpty else { continue }
        kept = kept.replacingOccurrences(of: m[0], with: " ")
    }
    return kept
}

struct BadPattern: Error, CustomStringConvertible {
    let pattern: String
    var description: String {
        "the regex \(pattern) does not compile, so this guard scanned nothing"
    }
}

/// Throws rather than returning `[]` when the pattern is invalid.
///
/// Returning an empty array on a compile failure makes a BROKEN guard look like
/// a CLEAN document — the false-absence trap. An earlier draft of this file used
/// `\u{2014}`, which is Swift escape syntax and not ICU regex syntax, so the
/// duration pattern silently matched nothing and the check passed over a README
/// full of durations.
///
/// `options` DEFAULTS to the case-insensitive reading every caller above was
/// written against, so none of them changes. The control-location guard passes
/// `[]` instead: a control's name is a proper label, and under `.caseInsensitive`
/// an ICU `[A-Z]` matches a lower-case letter too — which would read the literal
/// `"no battery"` as a control called "no battery". Measured 2026-08-13 over all
/// eleven documented surfaces: both readings extract the same 17 locating
/// claims today, so this is the semantics being pinned before it costs
/// something, not a fix for a live miss.
func matches(_ pattern: String, in text: String,
             options: NSRegularExpression.Options = [.caseInsensitive]) throws -> [[String]] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options)
    else { throw BadPattern(pattern: pattern) }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
        (0..<m.numberOfRanges).map { i in
            m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i))
        }
    }
}

// MARK: - The guard cannot pass vacuously

/// Discovery found the real documents, so the sweeps below are not sweeping air.
///
/// Every `@Test(arguments: documentedSurfaces)` in this file passes trivially
/// when that array is empty: zero arguments means zero test cases, and
/// swift-testing counts zero failures as success. One mis-resolved repository
/// root would therefore switch seven guards off and report nothing at all —
/// the same false-absence trap `matches` throws to avoid.
///
/// The names below are literals deliberately. Comparing the discovered list
/// against the discovery function would restate the glob rather than check it,
/// and would hold whether the glob worked or not.
@Test func surfaceDiscoveryFindsTheDocumentsAndCannotSweepAnEmptyList() {
    let found = Set(documentedSurfaces)

    // The four this file was born checking, plus the changelog that nothing read.
    for named in ["README.md", "docs/QUICKSTART.md", "docs/BUILDING.md",
                  "CHANGELOG.md", "site/index.html"] {
        #expect(found.contains(named),
                "\(named) is missing from the discovered surfaces \(documentedSurfaces)")
    }

    // Every page under `site/` except the home page, which the list above
    // names. Three arrived with the redesign and were unguarded when this check
    // was written; terms and privacy arrived with the legal surface. Named one
    // by one, so losing a page fails HERE, loudly, instead of quietly reducing
    // coverage everywhere else.
    //
    // The two legal pages earn their line the same way `site/docs.html` did.
    // They carry the only prose that states the warranty position and what the
    // app reads, and a reader takes both as promises. If discovery stopped
    // reaching them, the six parameterised guards below would sweep them
    // without a word and report success — which is exactly what happened to
    // `site/docs.html` for a whole milestone.
    for page in ["site/install.html", "site/docs.html", "site/changelog.html",
                 "site/terms.html", "site/privacy.html"] {
        #expect(found.contains(page),
                "\(page) is missing from the discovered surfaces \(documentedSurfaces)")
    }

    let pages = discoveredSitePages()
    #expect(pages.count >= 4,
            "discovery found \(pages.count) page(s) under site/: \(pages). The glob is not reaching the directory")
}

@Test(arguments: documentedSurfaces)
func everyDocumentedSurfaceIsReadableAndSubstantial(_ name: String) throws {
    let prose = try surfaceProse(name)
    // A path mis-resolution would otherwise make every check below pass on an
    // empty string. Same failure-closed shape the leak guard uses.
    #expect(prose.count > 1000,
            "\(name) reduces to \(prose.count) bytes of prose; the checks would pass vacuously")
}

// MARK: - Claim 1: the hook count

@Test func theHookBlockIsExactlyTheRequiredEvents() throws {
    let text = try surfaceText(hookBlockSurface)

    // The FIRST fenced json block is the required-hook block. The optional
    // SessionEnd snippet is a separate, later block on purpose.
    let blocks = try matches("```json\\n([\\s\\S]*?)\\n```", in: text).map { $0[1] }
    #expect(!blocks.isEmpty, "no json block in \(hookBlockSurface); the guard cannot run")
    guard let first = blocks.first else { return }

    let parsed = try JSONSerialization.jsonObject(with: Data(first.utf8))
    let hooks = (parsed as? [String: Any])?["hooks"] as? [String: Any]
    #expect(hooks != nil, "the first json block in \(hookBlockSurface) has no `hooks` object")
    guard let hooks else { return }

    let documented = Set(hooks.keys)
    let required = Set(HookHealth.requiredEvents)
    #expect(documented == required,
            "\(hookBlockSurface) documents \(documented.sorted()); HookHealth.requiredEvents is \(required.sorted())")
}

/// The block the page tells a user to paste is the block the app emits.
///
/// **The drift this closes, measured 2026-08-07 — issue #67.**
/// `HookSnippet.command(for:)` emitted `curl -sS -o /dev/null …` and
/// `docs/QUICKSTART.md` published the same line WITHOUT `-o /dev/null`. Nothing
/// compared them. `theHookBlockIsExactlyTheRequiredEvents` above reads the KEYS
/// of this same block, so it stayed green over two different commands, and
/// `theSiteHookBlockIsStillACopyOfTheQuickStartBlock` held the site against the
/// page — which keeps two copies of a wrong command in step with each other.
///
/// The missing flag is not cosmetic. Without `-o /dev/null`, `--fail-with-body`
/// writes the ingest error body to the hook's STANDARD OUTPUT, and an agent
/// reads a hook's standard output as a decision. A reader who followed the page
/// wired a hook that speaks to their agent whenever the socket answers with an
/// error.
///
/// **The whole block, not the command alone.** The events, the matcher split and
/// the command all come out of `HookSnippet.json(for: .claudeCode)`, so
/// comparing the documents' block against that one value covers every part of it
/// at once. Compared as re-serialised JSON so indentation and key order — which
/// are claims about nothing — cannot fail this.
@Test func theDocumentedHookBlockIsExactlyWhatTheAppEmits() throws {
    let text = try surfaceText(hookBlockSurface)

    // The FIRST fenced json block, the same one the guard above reads. The
    // optional SessionEnd snippet and the coffeebar-hook fragment are later
    // blocks and neither is what the button emits.
    let blocks = try matches("```json\\n([\\s\\S]*?)\\n```", in: text).map { $0[1] }
    #expect(!blocks.isEmpty, "no json block in \(hookBlockSurface); the guard cannot run")
    guard let documented = blocks.first else { return }

    let emitted = try #require(
        HookSnippet.json(for: .claudeCode),
        "HookSnippet has no snippet for Claude Code, so there is nothing to hold \(hookBlockSurface) against")

    // Re-serialised through ONE set of options, so the two sides are compared as
    // structure. `.withoutEscapingSlashes` is included because `json(for:)` uses
    // it: without it here the documented side comes back as
    // `http:\/\/localhost\/event` and every run fails on an escape neither
    // document contains.
    func canonical(_ raw: String, _ label: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        else {
            Issue.record("the hook block in \(label) does not parse as JSON; a reader pasting it would get a broken settings file")
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    guard let onPage = canonical(documented, hookBlockSurface),
          let fromApp = canonical(emitted, "HookSnippet.json(for: .claudeCode)")
    else { return }

    // The command on its own, named separately from the block comparison below.
    // Two identical `{}` blocks would satisfy that comparison, and this is what
    // stops it: the command is read back OUT of the page and held against the
    // generator, so a page that lost its commands fails here rather than
    // matching an equally empty expectation.
    let expected = HookSnippet.command(for: .claudeCode)
    let printed = commandStrings(in: (try? JSONSerialization.jsonObject(with: Data(documented.utf8))) ?? [:])
    #expect(!printed.isEmpty,
            "\(hookBlockSurface) prints no hook command at all; this guard would otherwise compare two empty blocks")
    for command in printed {
        #expect(command == expected, """
            \(hookBlockSurface) tells the reader to paste
              \(command)
            and the Copy hook snippet button emits
              \(expected)
            """)
    }

    #expect(onPage == fromApp, """
        \(hookBlockSurface) no longer matches HookSnippet.json(for: .claudeCode). \
        First difference, page then app, \(firstDifference(onPage, fromApp))
        """)
}

/// "The two tool events take `"matcher": "*"`; the other three take no matcher."
///
/// Both halves are claims about the block printed directly above them, and a
/// mutation check found neither was guarded: the hook-count pattern needs the
/// word "hooks" within 25 characters, and this sentence says "matcher". The
/// numbers are read back out of the block itself, so the sentence cannot drift
/// away from what the page tells a user to paste.
@Test func theMatcherSplitTheProseStatesMatchesTheBlock() throws {
    let text = try surfaceText(hookBlockSurface)
    let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5]

    let blocks = try matches("```json\\n([\\s\\S]*?)\\n```", in: text).map { $0[1] }
    guard let first = blocks.first,
          let parsed = try? JSONSerialization.jsonObject(with: Data(first.utf8)),
          let hooks = (parsed as? [String: Any])?["hooks"] as? [String: Any]
    else {
        Issue.record("cannot parse the hook block in \(hookBlockSurface)")
        return
    }

    var withMatcher = 0
    var without = 0
    for (_, value) in hooks {
        guard let groups = value as? [[String: Any]], let group = groups.first else { continue }
        if group["matcher"] == nil { without += 1 } else { withMatcher += 1 }
    }

    // RAW text, not prose. The first half of the sentence spells the word inside
    // backticks — "take `"matcher": "*"`" — and `readmeProse` strips inline code,
    // which deleted the very word this pattern looks for. Measured: prose gave 1
    // match where raw gives 2, and the single match was the SECOND half, so the
    // check compared "three" against the with-matcher count and failed
    // misleadingly rather than not at all.
    let found = try matches(
        "\\b(one|two|three|four|five)\\b[^.\\n]{0,40}?matcher", in: text)
    #expect(found.count >= 2,
            "expected both halves of the matcher sentence in \(hookBlockSurface), found \(found.count)")

    let stated = found.compactMap { words[$0[1].lowercased()] }
    #expect(stated.first == withMatcher,
            "\(hookBlockSurface) says \(found.first?[1] ?? "?") events take a matcher; the block has \(withMatcher)")
    #expect(stated.last == without,
            "\(hookBlockSurface) says \(found.last?[1] ?? "?") take no matcher; the block has \(without)")
}

/// The patterns below still match live claims.
///
/// A parameterized check cannot assert "I found something" per surface, because
/// a surface may legitimately carry none of a given claim — `site/index.html`
/// states no durations at all. So anti-vacuity is pinned HERE, against the
/// README, which is known to carry one of each. If a pattern rots, this goes red
/// instead of every other check silently scanning nothing.
@Test func theGuardStillMatchesRealClaims() throws {
    // Each claim type is pinned against the surface that actually carries it.
    // These pairings are the coverage map: if the docs are reorganised again and
    // this is not updated, this test goes red rather than every other check
    // silently scanning a page that no longer holds the claim.
    let quickstart = try surfaceProse("docs/QUICKSTART.md")
    #expect(try !matches(hookCountPattern, in: quickstart).isEmpty,
            "no '<number> hooks' phrase in the quick start")
    #expect(try !matches(durationPattern, in: quickstart).isEmpty,
            "no duration in the quick start")
    #expect(try !matches("`blockedTimeout`", in: try surfaceText("docs/QUICKSTART.md")).isEmpty,
            "the quick start no longer names blockedTimeout")

    let site = try surfaceProse("site/index.html")
    #expect(try !matches(hookCountPattern, in: site).isEmpty, "no '<number> hooks' phrase on the site")

    // `percentPattern` is pinned across ALL ELEVEN surfaces, not the two it
    // used to be. Issue #53 is why: the guards that read percentages now skip
    // release sections, and an exemption is the cheapest way for coverage to
    // vanish quietly. Two anchors could not tell "the pattern still works"
    // from "nine surfaces are no longer being read".
    //
    // BOTH directions, which is what makes this a coverage map rather than a
    // formality. A surface that should carry a percentage and does not means
    // the pattern rotted or the claim was lost; a surface that should carry
    // none and does means a new percentage claim landed somewhere nobody
    // decided it belonged, and the map has to be read before it passes.
    for name in documentedSurfaces {
        let found = try matches(percentPattern, in: try surfaceProse(name)).count
        if percentageCarryingSurfaces.contains(name) {
            #expect(found > 0, """
                \(name) states no percentage at all. It is listed as a surface \
                that carries one, so either percentPattern has rotted and every \
                sweep below is reading nothing, or the claim was deleted.
                """)
        } else {
            #expect(found == 0, """
                \(name) states \(found) percentage(s) and is not on the list of \
                surfaces that carry one. Add it deliberately — that edit is the \
                moment somebody reads the new claim against the real floor.
                """)
        }
    }

    // `controlOfferPattern` is pinned against FIXTURES and not against a
    // surface, and that is a measurement rather than a preference: it yields
    // ZERO phrases across all eleven documented surfaces today, so a
    // surface-anchored pin would be red on a correct tree.
    //
    // Which is the point. `everyControlNamedExistsInTheProduct` sweeps eleven
    // surfaces and its loop body never runs — the guard is live and judging
    // nothing, and nothing said so, because this test pinned four patterns and
    // left that one alone. The limit is now STATED: these cases prove the
    // pattern still reads the shape it was written for, never that a document
    // still carries one.
    //
    // The positive is the sentence that actually shipped. "stay awake while
    // blocked" was invented from the parameter name `holdAwakeWhileBlocked` and
    // named a control existing in no build.
    let shipped = try matches(controlOfferPattern,
                              in: "unless you turn on \"stay awake while blocked\"")
    #expect(shipped.count == 1,
            "controlOfferPattern found \(shipped.count) offers in the sentence that shipped the false claim")
    #expect(shipped.first?[1] == "stay awake while blocked",
            "controlOfferPattern read the offered control as \(shipped.first?[1] ?? "<no match>")")

    // The NEGATIVE half, which is what stops a pattern rotting into one that
    // matches everything. Each case removes exactly one of the three things the
    // pattern requires: the verb, the quoted phrase, and a phrase long enough
    // to be a control name.
    let notAnOffer = [
        "the panel shows \"a working session\" while an agent runs",
        "turn on the lamp before you read",
        "enable \"on\"",
    ]
    for text in notAnOffer {
        #expect(try matches(controlOfferPattern, in: text).isEmpty, """
            controlOfferPattern read "\(text)" as an offer of a control. A \
            pattern that matches an ordinary quoted phrase sends every reader \
            hunting a control that was never offered.
            """)
    }
}

private let hookCountPattern = "\\b(three|four|five|six|seven)\\b[\\s\\S]{0,25}?hooks?"
/// A whole number, decimal point included — never a fragment of one.
///
/// `(?<![\d.])` is the half that refuses. Without it the engine simply starts
/// one character later when the leading digits will not do, so `.5 seconds`
/// still yields `5`, which is the bug this pattern was fixed for. With it, a
/// number the pattern cannot read in full (`.5`, `1.`) matches nothing at all
/// and reaches no comparison. See `theDurationPatternReadsAWholeDecimalNumber`
/// for the reasoning and the cases.
private let durationPattern = "(?<![\\d.])(\\d[\\d,_]*(?:\\.\\d+)?)[\\s-]*(second|minute|hour)s?"
private let percentPattern = "(\\d+)\\s*%"

/// The documented surfaces that state a percentage, named one by one.
///
/// This is the anti-vacuity map for `percentPattern`, and it covers all eleven
/// surfaces rather than the README and the home page it used to. The four
/// absent from it — the build guide, the install page and the two legal pages —
/// are as load bearing as the seven in it: a percentage appearing on a page
/// that stated none is a new claim about the floor, and it has to be read
/// before it passes.
///
/// Measured over PROSE, so a number inside a code span or a `<code>` element is
/// not counted here for the same reason the sweeps do not judge it.
private let percentageCarryingSurfaces: Set<String> = [
    "CHANGELOG.md",
    "README.md",
    "SECURITY.md",
    "docs/QUICKSTART.md",
    "site/changelog.html",
    "site/docs.html",
    "site/index.html",
]
private let numberWords = ["three": 3, "four": 4, "five": 5, "six": 6, "seven": 7]

@Test(arguments: documentedSurfaces)
func theProseHookCountMatchesTheRequiredEventCount(_ name: String) throws {
    let prose = try surfaceProse(name)
    let real = HookHealth.requiredEvents.count

    for m in try matches(hookCountPattern, in: prose) {
        let stated = numberWords[m[1].lowercased()] ?? -1
        #expect(stated == real,
                "\(name) says \"\(m[1]) hooks\" but HookHealth.requiredEvents has \(real)")
    }
}

// MARK: - Claim 2: numbers must be real product constants

private let productConstants: [String: Double] = [
    "workingTimeout": StalePolicy.standard.workingTimeout,
    "blockedTimeout": StalePolicy.standard.blockedTimeout,
]

private let secondsPerUnit: [String: Double] = ["second": 1, "minute": 60, "hour": 3600]

/// Surfaces the duration sweep below cannot judge, and the reason for each.
///
/// `SECURITY.md` states two TTLs that are not `StalePolicy` numbers:
/// `ProbeVerb.defaultTTLSeconds` (30 minutes) and `JournalRecord.maxTTLSeconds`
/// (8 hours). The first lives in `CoffeeBarPower`, and `CoffeeBarCoreTests`
/// depends on `CoffeeBarCore` alone, so this target cannot reach it. Adding 1800
/// here as a literal would break the one rule this guard exists to enforce —
/// that a number in prose is a real product constant and not a second copy of
/// one that can drift from it.
///
/// **The coverage is not dropped, it MOVES, and it grows.**
/// `everyDurationInAPolicyDocumentIsARealProductConstant` in
/// `Tests/CoffeeBarPowerTests/PolicyDocumentClaims_test.swift` sweeps the same
/// prose from the one target that reaches all four constants, and it covers MORE
/// than this guard did: `SECURITY.md` states the 30-minute default a third time
/// with no symbol beside it, and `theDocumentedTTLBoundsAreTheShippedConstants`
/// cannot see that one because its anchor cannot cross a line break.
///
/// `site/docs.html` joined it on 2026-08-07 for the identical reason, and issue
/// #56 is why the page states a duration at all: the lid-closed explanation the
/// menu-bar panel used to carry now lives there, and it tells the reader how
/// long `sudo coffee-bar-probe arm` holds. That number is
/// `ProbeVerb.defaultTTLSeconds`, which this target cannot reach.
/// `everyDurationOnADocumentedSitePageIsARealProductConstant` sweeps the whole
/// page from `CoffeeBarPowerTests`, and
/// `theSiteExplainsLidClosedModeAndStatesTheShippedHold` in
/// `Tests/CoffeeBarUITests/LidClosedPanel_test.swift` pairs that number with the
/// sentence it belongs to. Two guards where this file had one.
private let durationSweepExclusions: Set<String> = ["SECURITY.md", "site/docs.html"]

/// The exclusion list cannot grow silently, and cannot rot into a dead name.
///
/// Named bug this catches: somebody excludes a second surface to make a red
/// sweep green, and the coverage disappears with nothing to say so. Every
/// exclusion is a coverage hole that another guard must fill, so adding one has
/// to be a deliberate edit here. The second check is the discriminating half —
/// a renamed or mistyped surface leaves an exclusion that silently excludes
/// nothing, which reads like coverage and is not.
@Test func theDurationSweepExcludesOnlySurfacesAnotherGuardCovers() {
    #expect(durationSweepExclusions == ["SECURITY.md", "site/docs.html"], """
        the duration sweep now skips \(durationSweepExclusions.sorted()). Each \
        exclusion needs a guard elsewhere that covers it — see \
        everyDurationInAPolicyDocumentIsARealProductConstant and \
        everyDurationOnADocumentedSitePageIsARealProductConstant in \
        CoffeeBarPowerTests — and this check exists so adding one cannot be quiet.
        """)

    for name in durationSweepExclusions {
        #expect(documentedSurfaces.contains(name), """
            \(name) is excluded from the duration sweep but is not a documented \
            surface, so the exclusion covers nothing and the name has rotted
            """)
    }
}

/// `0.93 seconds` is 0.93 seconds, not 93 of them.
///
/// Named bug this catches (#99): the capture was `(\d[\d,_]*)`, a character
/// set with no decimal point in it, so the match started AFTER the point and
/// the sweep below compared the fraction on its own. Written `0.93 seconds`,
/// read `93 seconds`. Written `1.5 hours`, read `5 hours`. Both directions are
/// live: a false claim passes whenever its tail digits happen to be a real
/// constant, and a true claim fails and sends the author hunting a defect that
/// is not there — which is how a guard teaches people to route around it.
///
/// The deliberate decision on a malformed number, which #99 asks for
/// explicitly: a bare `.5` and a trailing `1.` REFUSE TO MATCH. They are not
/// coerced, and — the part that matters — they do not match a FRAGMENT of
/// themselves either, which is what `.5 seconds` did when it yielded `5`.
/// Reading half a number produces a comparison unrelated to the claim, so a
/// number this pattern cannot read in full must produce no comparison at all.
/// The decision lives entirely in the pattern; the sweep's comparison logic is
/// untouched.
@Test func theDurationPatternReadsAWholeDecimalNumber() throws {
    // Expectations are literals. Re-deriving them from the pattern would
    // restate the implementation instead of checking it.
    let wellFormed: [(text: String, number: String, unit: String)] = [
        ("0.93 seconds", "0.93", "second"),   // #99: was read as "93"
        ("1.5 hours", "1.5", "hour"),         // #99: was read as "5"
        ("14400 seconds", "14400", "second"), // integers, unchanged
        ("1,800 seconds", "1,800", "second"),
        ("900-second", "900", "second"),
    ]

    for c in wellFormed {
        let found = try matches(durationPattern, in: c.text)
        #expect(found.count == 1,
                "\"\(c.text)\" is one duration, but the pattern found \(found.map { $0[0] })")
        #expect(found.first?[1] == c.number,
                "\"\(c.text)\" reads as \(found.first?[1] ?? "<no match>"), not \(c.number)")
        #expect(found.first?[2] == c.unit,
                "\"\(c.text)\" reads the unit as \(found.first?[2] ?? "<no match>"), not \(c.unit)")
    }

    // A number the pattern cannot read in full yields nothing at all — no
    // fragment, no comparison. `.5 seconds` matching "5" is the same defect as
    // `0.93` matching "93".
    for text in [".5 seconds", "1. seconds", "1.5.3 hours"] {
        let found = try matches(durationPattern, in: text)
        #expect(found.isEmpty,
                "\"\(text)\" is malformed and must not be read at all, but the pattern took \(found.map { $0[1] })")
    }
}

@Test(arguments: documentedSurfaces)
func everyDurationStatedIsARealProductConstant(_ name: String) throws {
    // Swept by CoffeeBarPowerTests instead, from the only target that can reach
    // every constant these documents state. See `durationSweepExclusions`.
    guard !durationSweepExclusions.contains(name) else { return }

    let prose = try surfaceProse(name)
    let known = Set(productConstants.values)

    for m in try matches(durationPattern, in: prose) {
        let digits = m[1].replacingOccurrences(of: ",", with: "")
                         .replacingOccurrences(of: "_", with: "")
        guard let value = Double(digits),
              let scale = secondsPerUnit[m[2].lowercased()] else { continue }
        let seconds = value * scale
        #expect(known.contains(seconds),
                "\(name) states \"\(m[0])\" = \(Int(seconds)) s, which is not a product constant. Known: \(known.sorted().map { Int($0) })")
    }
}

@Test(arguments: documentedSurfaces)
func everyNamedConstantMatchesTheNumberBesideIt(_ name: String) throws {
    let text = try surfaceText(name)

    // `blockedTimeout` — 14400 seconds  ->  the number must be THAT constant,
    // not merely some real constant. This is the check that catches quoting a
    // genuine value against the wrong path.
    for (constant, expected) in productConstants {
        let found = try matches("`\(constant)`[^\\n]{0,40}?(\\d[\\d,_]*)\\s*(second|minute|hour)s?",
                            in: text)
        for m in found {
            let digits = m[1].replacingOccurrences(of: ",", with: "")
                             .replacingOccurrences(of: "_", with: "")
            guard let value = Double(digits),
                  let scale = secondsPerUnit[m[2].lowercased()] else { continue }
            #expect(value * scale == expected,
                    "\(name) puts \(m[1]) \(m[2])s beside `\(constant)`, but that constant is \(Int(expected)) s")
        }
    }
}

/// The surfaces that carry a release history, and they are the only two.
///
/// A LITERAL, so that a page growing version sections — or a changelog losing
/// them — has to be read by a human before the exemption follows it.
private let releaseHistorySurfaces: Set<String> = ["CHANGELOG.md", "site/changelog.html"]

/// The exemption reaches release sections and nothing else.
///
/// **Named bug this catches.** A stripper that is a little too greedy makes
/// every guard downstream sweep an empty string, and that failure is SILENT —
/// zero percentages found is indistinguishable from zero percentages wrong.
/// Subtracting text from what a guard scans always carves a blind spot; this
/// pins the blind spot's exact edges instead of trusting them.
///
/// Both directions, per surface, for all eleven:
///
///   * the nine surfaces with no release history come back BYTE-IDENTICAL, so
///     the exemption cannot quietly spread to a page that makes live claims;
///   * the two changelogs lose text, still lose at least one percentage, and
///     still hand back a substantial preamble — a stripper that swallowed the
///     whole file would satisfy "lost text" and fail here.
@Test(arguments: documentedSurfaces)
func releaseHistoryIsExemptOnlyWhereAReleaseHistoryExists(_ name: String) throws {
    let whole = try surfaceProse(name)
    let current = try currentClaimProse(name)

    guard releaseHistorySurfaces.contains(name) else {
        #expect(current == whole, """
            \(name) carries no release history, and the exemption changed it \
            anyway: \(whole.count) bytes of prose became \(current.count). \
            Every live claim it removes is a claim no guard reads.
            """)
        return
    }

    #expect(current.count < whole.count, """
        \(name) is a changelog and the release-section exemption removed \
        nothing from it. Either the section boundaries moved or the pattern \
        rotted; a percentage recording a past release is about to be judged \
        against today's floor.
        """)

    let inWhole = try matches(percentPattern, in: whole).count
    let inCurrent = try matches(percentPattern, in: current).count
    #expect(inCurrent < inWhole, """
        \(name) states \(inWhole) percentage(s) and \(inCurrent) of them \
        survive the release-section exemption. This guard exists because those \
        numbers are release history; if none is being removed it is reading \
        the wrong regions.
        """)

    // A stripper that ate the whole file would pass both checks above. The
    // preamble is what a reader meets before the first release, and it makes
    // live claims — so it must survive.
    #expect(current.count > 400, """
        \(name) has \(current.count) bytes of prose left after the exemption. \
        The preamble states the rule the file is written to and is a live \
        claim; a guard reading almost nothing reports success at everything.
        """)
}

/// A percentage moves from claim to record by CROSSING A HEADING, and nothing
/// else about it changes.
///
/// Fixtures rather than the real documents, so the two cases differ by exactly
/// one thing: which side of the version heading the sentence sits on. Anchoring
/// this on `CHANGELOG.md` would tie it to today's wording and stop
/// discriminating the moment somebody rewrites a release note.
@Test func aPercentageBecomesHistoryOnlyByCrossingAVersionHeading() throws {
    let markdown = """
        # Changelog

        The floor is 9% today.

        ## [0.1.0] — 2026-08-03

        The floor was 20% then.
        """
    let currentMarkdown = markdownWithoutReleaseHistory(markdown)
    #expect(currentMarkdown.contains("9%"),
            "the exemption removed a percentage stated ABOVE the first version heading")
    #expect(!currentMarkdown.contains("20%"),
            "the exemption kept a percentage stated UNDER a version heading, so history is still judged as a claim")

    // A `##` heading that names no version is NOT a release section. The
    // exemption is for a record of a shipped build, not for every subheading.
    let notARelease = """
        # Notes

        ## How the floor works

        The floor is 9% today.
        """
    #expect(markdownWithoutReleaseHistory(notARelease).contains("9%"),
            "a plain ## heading was treated as a release section, which exempts live prose")

    let html = """
        <p>The floor is 9% today.</p>
        <section id="v0-1-0">
        <h2>0.1.0 — 2026-08-03</h2>
        <p>The floor was 20% then.</p>
        </section>
        """
    let currentHTML = try htmlWithoutReleaseHistory(html)
    #expect(currentHTML.contains("9%"),
            "the exemption removed a percentage stated outside any release section")
    #expect(!currentHTML.contains("20%"),
            "the exemption kept a percentage stated inside a version section")

    // A `<section>` whose heading names no version stays.
    let plainSection = """
        <section id="how-it-works">
        <h2>How the floor works</h2>
        <p>The floor is 9% today.</p>
        </section>
        """
    #expect(try htmlWithoutReleaseHistory(plainSection).contains("9%"),
            "a section with a non-version heading was treated as release history")
}

/// Every percentage a document states about the product TODAY is the floor in
/// force today.
///
/// `currentClaimProse` and not `surfaceProse`, and that is issue #53: a
/// changelog RECORDS what each release shipped, so a percentage under a
/// released heading is history and not a claim. Holding history to today's
/// constant forbids ever writing a floor change down — see `currentClaimProse`
/// for the live sentence that proved it.
@Test(arguments: documentedSurfaces)
func theBatteryFloorStatedIsTheRealDefault(_ name: String) throws {
    let prose = try currentClaimProse(name)

    // `batteryFloorPercent` is NOT passed, so the DEFAULT decides. Passing the
    // document's own number as the floor would make this tautological.
    for m in try matches(percentPattern, in: prose) {
        guard let stated = Int(m[1]) else { continue }

        let atFloor = PowerBroker.decide(PowerInputs(powerSource: .battery,
                                                     batteryPercent: stated,
                                                     userIntent: .serve))
        #expect(atFloor.idleSleepAssertion == false,
                "\(name) claims a \(stated)% floor, but a serve at \(stated)% still holds")

        let aboveFloor = PowerBroker.decide(PowerInputs(powerSource: .battery,
                                                        batteryPercent: stated + 1,
                                                        userIntent: .serve))
        #expect(aboveFloor.idleSleepAssertion == true,
                "\(name) claims a \(stated)% floor, but a serve at \(stated + 1)% does not hold")
    }
}

/// "below N%" and "at or below N%" are different claims. Only one is true.
///
/// `PowerBroker` suppresses at `percent <= floor`, so at EXACTLY the floor the
/// product does not hold. A document saying "below 20% it does not hold" states
/// the opposite of what happens at 20% itself. `ServingModel.swift` already
/// carries this reasoning for the panel line; nothing enforced it for the docs,
/// and `site/index.html` shipped the wording that comment condemns.
/// Scoped to CURRENT claims for the same reason the floor guard above is.
/// `CHANGELOG.md` records "at or below `20%`" under the released `## [0.1.0]`
/// heading; that is a true statement about 0.1.0 and a false one about today.
@Test(arguments: documentedSurfaces)
func aBoundaryPhraseMatchesTheRealBoundary(_ name: String) throws {
    let prose = try currentClaimProse(name)

    for m in try matches("(at or below|below|under)\\s*(\\d+)\\s*%", in: prose) {
        guard let stated = Int(m[2]) else { continue }
        let inclusive = m[1].lowercased().hasPrefix("at or")

        let holdsAtTheNumber = PowerBroker.decide(
            PowerInputs(powerSource: .battery,
                        batteryPercent: stated,
                        userIntent: .serve)).idleSleepAssertion

        if inclusive {
            #expect(holdsAtTheNumber == false,
                    "\(name) says \"at or below \(stated)%\", but a serve at exactly \(stated)% still holds")
        } else {
            #expect(holdsAtTheNumber == true,
                    "\(name) says \"\(m[1]) \(stated)%\", which claims \(stated)% itself is safe. A serve at exactly \(stated)% does NOT hold, so the true phrasing is \"at or below \(stated)%\"")
        }
    }
}

// MARK: - Claim 3: a named control must exist in the product

/// A quoted phrase in a sentence that offers it as something the reader can
/// operate. "unless you turn on \"stay awake while blocked\"" is the shape
/// that shipped a control existing in no build.
///
/// File scope rather than a local, so `theGuardStillMatchesRealClaims` can pin
/// it. It was a local, and it was the ONE pattern in this file nothing pinned —
/// which is exactly why it could go quiet without anybody noticing.
private let controlOfferPattern =
    "(?:turn on|turn off|enable|disable|toggle|switch on|switch off|tick|check)"
    + "[^\\n\"]{0,40}\"([^\"\\n]{4,60})\""

@Test(arguments: documentedSurfaces)
func everyControlNamedExistsInTheProduct(_ name: String) throws {
    let prose = try surfaceProse(name)
    let found = try matches(controlOfferPattern, in: prose)

    for m in found {
        let phrase = m[1]
        #expect(sourcesContain(phrase),
                "\(name) offers a control named \"\(phrase)\", but no file under Sources/ contains that string")
    }
}

/// True when the CODE of any `.swift` file under `Sources/` contains `phrase`.
private func sourcesContain(_ phrase: String) -> Bool {
    codeContains(phrase, inSwiftUnder: repoRoot().appending(path: "Sources"))
}

/// True when the CODE of any `.swift` file under `directory` contains `phrase`.
///
/// Takes the directory rather than reading `Sources/` itself, so
/// `aControlNamedOnlyInACommentIsNotAControlThatExists` can hand it two files
/// that differ by nothing but a comment marker.
func codeContains(_ phrase: String, inSwiftUnder directory: URL) -> Bool {
    guard let walker = FileManager.default.enumerator(atPath: directory.path) else { return false }
    for case let rel as String in walker where rel.hasSuffix(".swift") {
        let url = directory.appending(path: rel)
        guard let body = try? String(contentsOf: url, encoding: .utf8) else { continue }
        if swiftCodeWithoutComments(body).contains(phrase) { return true }
    }
    return false
}

/// A control named only in a COMMENT is not a control the product offers.
///
/// **Named bug this catches, and it is issue #40.** `sourcesContain` was a raw
/// `body.contains` over every `.swift` file under `Sources/`. The false claim
/// this whole file was written for — "unless you turn on \"stay awake while
/// blocked\"", a control that existed in no build — is satisfied by a doc
/// comment that merely DESCRIBES such a control. The guard would report the
/// control real because the prose explaining it is real, which is a guard
/// certifying a claim with the claim.
///
/// **A TEMPORARY DIRECTORY, never `Sources/`.** Anchoring the pin on whatever
/// phrase happens to sit in a comment in the tree today is a fixture that stops
/// discriminating the moment somebody edits that comment, and stops silently.
/// Two files differing by nothing but a `/// ` prefix cannot.
@Test func aControlNamedOnlyInACommentIsNotAControlThatExists() throws {
    let fixtures = FileManager.default.temporaryDirectory
        .appending(path: "coffee-bar-control-scan-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixtures) }

    // Not a phrase this repository uses, so the fixture cannot be satisfied by
    // something the walk found elsewhere.
    let phrase = "hold while the lid is shut"

    let described = """
        /// The panel offers "\(phrase)" beside the Serving control.
        let title = "a control with another name"
        """
    try described.write(to: fixtures.appending(path: "DescribedOnly.swift"),
                        atomically: true, encoding: .utf8)

    #expect(codeContains(phrase, inSwiftUnder: fixtures) == false, """
        a doc comment naming "\(phrase)" satisfied the control-existence scan. \
        Every false control claim this file exists to catch arrives with prose \
        explaining the control, so a scan that reads comments passes over the \
        exact defect it was written for.
        """)

    // The other direction, and it is what stops the check above passing because
    // the walk reads nothing at all. Same directory, same phrase, in CODE.
    let offered = """
        let title = "\(phrase)"
        """
    try offered.write(to: fixtures.appending(path: "ReallyOffered.swift"),
                      atomically: true, encoding: .utf8)

    #expect(codeContains(phrase, inSwiftUnder: fixtures) == true, """
        "\(phrase)" is a plain string literal in \
        \(fixtures.appending(path: "ReallyOffered.swift").path) and the scan \
        still did not find it, so this walk reads nothing and every control \
        claim would fail against a correct product.
        """)
}

// MARK: - Claim 3b: a control is documented on the surface it renders on

/// The nouns a document calls a rendering surface by, each mapped to the
/// SwiftUI `View` type that draws it.
///
/// **This is a vocabulary, and not a control map.** It records what "the panel"
/// is CALLED in prose. It says nothing about which controls are on it: which
/// surface renders a given control is read out of `Sources/` on every run by
/// `renderedControls(ofViewTypes:inSwiftUnder:)`, so a control moved from one
/// surface to the other moves here with no edit at all — which is the whole
/// point of issue #69. A hand-written control-to-surface table would have to be
/// corrected by the same person who forgot to correct the document, and a fact
/// kept in two places that must be edited together is how these documents
/// drifted in the first place.
///
/// ORDERED, longest noun first, because ICU alternation is leftmost-first: with
/// `[Pp]references` ahead of `[Pp]references window`, every claim about the
/// window would be read as a claim about a bare `Preferences`.
///
/// A bare `[Ss]ettings` is deliberately ABSENT. Every page here says "settings
/// file" about `~/.claude/settings.json`, which is not a surface of this app at
/// all, and a noun that matched it would turn pages of hook-wiring instructions
/// into control claims.
private let surfaceNouns: [(noun: String, viewType: String)] = [
    ("[Mm]enu bar panel", "PanelView"),
    ("[Pp]references window", "PreferencesView"),
    ("[Ss]ettings window", "PreferencesView"),
    ("[Pp]anel", "PanelView"),
    ("[Mm]enu bar", "PanelView"),
    ("[Pp]references", "PreferencesView"),
]

/// The `View` types the vocabulary above names, sorted.
///
/// Derived rather than written out, so a third surface added to the vocabulary
/// is scanned without a second edit that somebody has to remember.
private let documentedViewTypes = Set(surfaceNouns.map(\.viewType)).sorted()

/// A phrase that could be a control's name on screen: it opens with a capital
/// and is long enough to name something rather than to be a state or a tag.
///
/// The capture is the phrase without its quotes.
private let controlLabelPattern = "\"([A-Z][A-Za-z][A-Za-z '’-]{2,38})\""

enum SurfaceScanError: Error, CustomStringConvertible {
    case noSuchView(String)
    case noBody(String)

    var description: String {
        switch self {
        case .noSuchView(let type):
            return "no .swift file declares `struct \(type): View`, so nothing can say where a control renders"
        case .noBody(let type):
            return "`struct \(type): View` declares no `var body: some View`, so nothing says what it renders"
        }
    }
}

/// What each rendering surface actually draws, read out of Swift source.
struct RenderedControls {
    /// Every label-shaped phrase a surface's `body` renders, keyed by view type.
    let phrases: [String: Set<String>]

    /// The one surface that renders `phrase`, or `nil` when none does — or when
    /// several do.
    ///
    /// `nil` for several deliberately. A phrase two surfaces both draw cannot
    /// settle a claim about either of them, and answering with one of the two
    /// would be a guess dressed as a verdict. The sweep skips those rather than
    /// judging them, which is why `unambiguous` is what it sweeps.
    func soleSurface(rendering phrase: String) -> String? {
        let drawn = phrases.filter { $0.value.contains(phrase) }.keys
        return drawn.count == 1 ? drawn.first : nil
    }

    /// Every phrase exactly one surface renders, sorted.
    ///
    /// Sorted because `Set` does not specify its order, and an unsorted list
    /// reorders the claims in a failure message between runs — which makes a
    /// real, repeatable failure read as flaky.
    var unambiguous: [String] {
        Set(phrases.values.joined()).filter { soleSurface(rendering: $0) != nil }.sorted()
    }
}

/// Every label-shaped phrase each of `types` renders, read out of the Swift
/// under `directory`.
///
/// **How a surface is read.** `braceBlock(after:in:)` takes the declaration of
/// `struct <type>: View` and then the first `var body: some View` inside it —
/// the two composed calls `PreferencesView_test.swift` already uses, and for
/// its reason: `PanelView.swift` declares two `View`s and the first
/// `var body: some View` in the file belongs to `MenuBarLabel`. Comments go
/// first, so a surface that merely DESCRIBES a control in a doc comment does
/// not count as rendering it — issue #40's discriminator, inherited rather than
/// re-implemented.
///
/// **String literals, and the constants that stand for them.** A phrase counts
/// as rendered when the `body` block carries it as a literal, or carries the
/// name of a constant declared with that literal somewhere under `directory`.
/// The indirection is not optional: the quiet control is written
/// `Toggle(ServingModel.quietOthersLabel, …)`, and a reader that saw only
/// literals would report its name rendered by no surface at all, then skip
/// every claim made about it — silently, which is the failure mode this whole
/// file exists to end.
///
/// Takes the directory rather than reading `Sources/` itself, so
/// `aControlLocationClaimIsJudgedAgainstWhereTheControlRenders` can hand it
/// fixture views and pin the discrimination on files it wrote itself, instead
/// of on whichever control happens to sit in this tree today.
func renderedControls(ofViewTypes types: [String],
                      inSwiftUnder directory: URL) throws -> RenderedControls {
    var code: [String: String] = [:]
    if let walker = FileManager.default.enumerator(atPath: directory.path) {
        for case let relative as String in walker where relative.hasSuffix(".swift") {
            let url = directory.appending(path: relative)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            code[relative] = swiftCodeWithoutComments(text)
        }
    }

    // A constant's name to the label it holds, for names declared EXACTLY ONCE.
    // A name declared twice is a name this reader cannot resolve, and picking
    // one of the two would attribute a control to a surface on a coin toss.
    var declarations: [String: Int] = [:]
    var label: [String: String] = [:]
    for source in code.values {
        for m in try matches(
            "\\b(?:let|var)\\s+([A-Za-z_][A-Za-z0-9_]{3,})\\s*(?::\\s*String\\s*)?=\\s*\(controlLabelPattern)",
            in: source, options: []) {
            declarations[m[1], default: 0] += 1
            label[m[1]] = m[2]
        }
    }

    var phrases: [String: Set<String>] = [:]
    for type in types.sorted() {
        guard let file = code.keys.sorted()
            .first(where: { code[$0]?.contains("struct \(type): View") == true }),
              let source = code[file]
        else { throw SurfaceScanError.noSuchView(type) }

        guard let declaration = braceBlock(after: "struct \(type): View", in: source),
              let body = braceBlock(after: "var body: some View", in: declaration.block)
        else { throw SurfaceScanError.noBody(type) }

        var drawn = Set(try matches(controlLabelPattern, in: body.block, options: []).map { $0[1] })
        for (name, text) in label where declarations[name] == 1 {
            let mentioned = try matches("\\b\(NSRegularExpression.escapedPattern(for: name))\\b",
                                        in: body.block, options: [])
            if !mentioned.isEmpty { drawn.insert(text) }
        }
        phrases[type] = drawn
    }

    return RenderedControls(phrases: phrases)
}

/// One document sentence that places a named control on a surface.
struct ControlLocationClaim {
    /// The control's name, spelled as the product renders it.
    let control: String
    /// The `View` type the sentence puts it on.
    let claimedViewType: String
    /// The matched text, so a failure can quote the sentence a reader would
    /// have followed.
    let sentence: String
}

/// Every locating claim `prose` makes about one of `controls`.
///
/// **Three shapes, each demanding an explicit LOCATING phrase** rather than
/// mere proximity:
///
///   1. `<control> … in the <surface>` — "a Display control in the Preferences
///      window", "Serving in the panel", "… live in the Preferences window".
///   2. `the <surface> holds … <control>` — the same claim written backwards.
///   3. `| <control> | <surface> |` — a Markdown table row, which is how the
///      quick start registers four controls at once.
///
/// Proximity alone was tried and rejected, and there is a live sentence that
/// settles it: "The panel holds the Serving control, a battery line, the
/// Waiting on you list, the version, Preferences…, and Quit." names a control
/// and a second surface noun a few characters apart and locates nothing about
/// that noun. A proximity reader calls that a claim, fails on a correct
/// document, and teaches everybody to route around this file.
///
/// `[^.|\n]` bounds every span, so a claim cannot reach across a sentence, a
/// line, or a table cell to borrow its neighbour's surface noun.
func controlLocationClaims(in prose: String,
                           forControls controls: [String],
                           nouns: [(noun: String, viewType: String)]) throws
    -> [ControlLocationClaim] {
    let alternation = nouns.map { "(?:\($0.noun))" }.joined(separator: "|")
    var found: [ControlLocationClaim] = []

    for control in controls {
        let name = NSRegularExpression.escapedPattern(for: control)
        for pattern in [
            "\(name)\\b[^.|\\n]{0,60}?\\b(?:in|on|under|inside)\\s+the\\s+(\(alternation))\\b",
            "\\b[Tt]he\\s+(\(alternation))\\b[^.|\\n]{0,25}?\\b(?:holds|carries|has)\\b"
                + "[^.|\\n]{0,40}?\\b\(name)\\b",
            "\\|\\s*\(name)\\s*\\|\\s*(?:[Tt]he\\s+)?(\(alternation))\\s*\\|",
        ] {
            for m in try matches(pattern, in: prose, options: []) {
                guard let type = try viewType(named: m[1], among: nouns) else { continue }
                found.append(ControlLocationClaim(
                    control: control,
                    claimedViewType: type,
                    sentence: m[0].replacingOccurrences(of: "\n", with: " ")))
            }
        }
    }

    return found
}

/// The surface `noun` names, or `nil` when the vocabulary does not know it.
///
/// Anchored at both ends, so `Preferences window` cannot answer to a bare
/// `[Pp]references` entry that sits later in the list.
private func viewType(named noun: String,
                      among nouns: [(noun: String, viewType: String)]) throws -> String? {
    for candidate in nouns {
        if try !matches("^(?:\(candidate.noun))$", in: noun, options: []).isEmpty {
            return candidate.viewType
        }
    }
    return nil
}

/// A document may not put a control on a surface that does not render it.
///
/// **The defect, and it is issue #69.** `everyControlNamedExistsInTheProduct`
/// above proves a named control EXISTS somewhere under `Sources/`. It says
/// nothing about WHERE it renders, so a sentence that sends the reader to the
/// menu bar panel for a control that lives in the Preferences window is green
/// in every guard this repository had. Eight sentences did exactly that, and
/// the whole suite passed over all eight.
///
/// The surface is resolved from SOURCE every run — the `body` block of the
/// SwiftUI `View` that draws the control — so moving a control between the two
/// surfaces turns every document that still names the old one red without
/// anybody remembering to update a list.
///
/// **What this cannot do, stated rather than hidden.** It judges the claims it
/// can READ: a control's name beside a locating phrase. A page that describes
/// a control's position without naming a surface — "at the top of the second
/// group" — is invisible to it, and so is a control two surfaces both render,
/// which `soleSurface(rendering:)` refuses to guess about.
@Test(arguments: documentedSurfaces)
func everyControlLocatedInADocumentRendersOnThatSurface(_ name: String) throws {
    let rendering = try renderedControls(ofViewTypes: documentedViewTypes,
                                         inSwiftUnder: repoRoot().appending(path: "Sources"))
    let prose = try surfaceProse(name)

    for claim in try controlLocationClaims(in: prose,
                                           forControls: rendering.unambiguous,
                                           nouns: surfaceNouns) {
        let renders = rendering.soleSurface(rendering: claim.control)
        #expect(claim.claimedViewType == renders, """
            \(name) puts the \(claim.control) control on \(claim.claimedViewType) — \
            "\(claim.sentence)" — and \(claim.control) renders in \
            \(renders ?? "no surface at all"). A reader who follows that sentence \
            opens the wrong surface and does not find the control.
            """)
    }
}

/// The sweep above is reading real claims, and would notice if it stopped.
///
/// Every `@Test(arguments: documentedSurfaces)` above passes trivially when its
/// loop body never runs, and this file already learned that the expensive way:
/// `everyControlNamedExistsInTheProduct` sweeps eleven surfaces and matches
/// nothing on any of them, which nobody knew until `controlOfferPattern` was
/// pinned. A locating pattern that rotted would fail the same way — quietly,
/// while reporting success on every page.
@Test func theControlLocationSweepStillReadsRealClaims() throws {
    let rendering = try renderedControls(ofViewTypes: documentedViewTypes,
                                         inSwiftUnder: repoRoot().appending(path: "Sources"))

    // NAMES, and deliberately no surfaces. WHICH surface renders each of these
    // is the answer the sweep computes; repeating it here would let the guard
    // agree with itself instead of with the product.
    for control in ["Serving", "Display", "Battery floor", "Quiet everything else"] {
        #expect(rendering.soleSurface(rendering: control) != nil, """
            no single surface renders "\(control)", one of the four controls the \
            quick start registers by name, so every claim about it is skipped \
            in silence. Either its label left a `body` block or this reader \
            stopped finding it. Read: \(rendering.phrases.mapValues { $0.sorted() })
            """)
    }

    var claims: [ControlLocationClaim] = []
    var documentsMakingOne: Set<String> = []
    for name in documentedSurfaces {
        let here = try controlLocationClaims(in: try surfaceProse(name),
                                             forControls: rendering.unambiguous,
                                             nouns: surfaceNouns)
        claims += here
        if !here.isEmpty { documentsMakingOne.insert(name) }
    }

    // Measured 2026-08-13: 17 claims, over 4 controls, in 5 documents. The
    // floors sit below those so ordinary rewording does not fail here, and far
    // enough above zero that a rotted pattern does. Without them this sweep is
    // loudest about being correct exactly when it is reading nothing.
    #expect(claims.count >= 12, """
        the documents make \(claims.count) locating claim(s) the reader can see. \
        17 were measured when it was written, so either the patterns have \
        rotted and the sweep is judging almost nothing, or a page that told \
        readers where the controls are no longer does.
        """)
    #expect(Set(claims.map(\.control)).count >= 4, """
        the claims cover \(Set(claims.map(\.control)).sorted()) — fewer than the \
        four controls the quick start registers, so at least one control's \
        location is documented nowhere this guard can read it.
        """)
    #expect(documentsMakingOne.count >= 4, """
        only \(documentsMakingOne.sorted()) locate a control. Five documents did \
        when this was written; a page that stopped is a page whose control \
        claims nothing reads.
        """)
}

/// The claim reader answers to WHERE a control renders, not to what the
/// document says twice.
///
/// **Fixtures, never `Sources/`.** Anchoring this on whichever control sits in
/// the tree today gives a check that stops discriminating the moment somebody
/// moves one, and stops silently. Two fixture views and three fixture sentences
/// differ by exactly the thing under test: which surface the sentence names.
///
/// The mislocating sentence is SPLIT ACROSS CONCATENATED LITERALS. This guard
/// reads documents and never Swift, so it cannot read itself — but a fixture
/// written whole is a sentence sitting in the repository that says a control is
/// somewhere it is not, and the next guard to walk `Tests/` inherits it.
@Test func aControlLocationClaimIsJudgedAgainstWhereTheControlRenders() throws {
    let fixtures = FileManager.default.temporaryDirectory
        .appending(path: "coffee-bar-control-surface-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixtures) }

    try """
        struct FixturePanel: View {
            var body: some View {
                Picker("Cup strength", selection: $model.strength) { }
            }
        }
        """.write(to: fixtures.appending(path: "FixturePanel.swift"),
                  atomically: true, encoding: .utf8)

    // The label reaches this view through a CONSTANT, which is the shape
    // `Toggle(ServingModel.quietOthersLabel, …)` uses in the real window. A
    // reader that followed only literals would report "Grind fine" rendered
    // nowhere and skip every sentence below without a word.
    try """
        struct FixtureWindow: View {
            var body: some View {
                Toggle(FixtureLabels.grindLabel, isOn: $model.grind)
            }
        }
        """.write(to: fixtures.appending(path: "FixtureWindow.swift"),
                  atomically: true, encoding: .utf8)

    try """
        enum FixtureLabels {
            /// A comment naming "Cup strength" here must not move the control.
            static let grindLabel = "Grind fine"
        }
        """.write(to: fixtures.appending(path: "FixtureLabels.swift"),
                  atomically: true, encoding: .utf8)

    let rendering = try renderedControls(ofViewTypes: ["FixturePanel", "FixtureWindow"],
                                         inSwiftUnder: fixtures)
    #expect(rendering.soleSurface(rendering: "Cup strength") == "FixturePanel",
            "a literal in FixturePanel's body resolved to \(rendering.soleSurface(rendering: "Cup strength") ?? "nothing")")
    #expect(rendering.soleSurface(rendering: "Grind fine") == "FixtureWindow", """
        a label reaching a body through a constant resolved to \
        \(rendering.soleSurface(rendering: "Grind fine") ?? "nothing"). Every claim \
        about a constant-labelled control would be skipped in silence.
        """)

    let nouns = [(noun: "[Pp]references window", viewType: "FixtureWindow"),
                 (noun: "[Pp]anel", viewType: "FixturePanel")]

    // THE POSITIVE. A control documented where it renders raises nothing, so
    // this guard is not simply always-red.
    let right = try controlLocationClaims(in: "Grind fine lives in the Preferences window.",
                                          forControls: rendering.unambiguous, nouns: nouns)
    #expect(right.count == 1, "the reader found \(right.count) claim(s) in a sentence that makes one")
    #expect(right.allSatisfy { $0.claimedViewType == rendering.soleSurface(rendering: $0.control) },
            "a control documented on the surface that renders it was reported as mislocated")

    // THE NEGATIVE, and it is the defect: same sentence, other surface, no
    // change to the product.
    let wrong = try controlLocationClaims(in: "Grind fine lives in the " + "panel.",
                                          forControls: rendering.unambiguous, nouns: nouns)
    #expect(wrong.count == 1, "the reader found \(wrong.count) claim(s) in a sentence that makes one")
    #expect(wrong.contains { $0.claimedViewType != rendering.soleSurface(rendering: $0.control) }, """
        a sentence putting a control on the surface that does NOT render it was \
        read as correct. That is the entire defect: the guard would stay green \
        over a document sending every reader to the wrong window.
        """)

    // A control named near a surface noun that locates nothing. The live
    // sentence this mirrors lists Preferences… as an ITEM on the panel, a few
    // characters after a control's name; a reader matching on proximity fails
    // on it, and a guard that fails on correct prose gets routed around.
    let listing = try controlLocationClaims(
        in: "The panel holds the Cup strength control, the version, Preferences…, and Quit.",
        forControls: rendering.unambiguous, nouns: nouns)
    #expect(listing.count == 1, "the reader found \(listing.count) claim(s): \(listing.map(\.sentence))")
    #expect(listing.first?.claimedViewType == "FixturePanel", """
        "the <surface> holds the <control>" resolved to \
        \(listing.first?.claimedViewType ?? "nothing"). Read on proximity, the \
        trailing Preferences… wins and a correct sentence fails.
        """)

    // Naming a control and a surface in one sentence is not locating it.
    let mention = try controlLocationClaims(
        in: "The panel shows the reading, and Grind fine is remembered across launches.",
        forControls: rendering.unambiguous, nouns: nouns)
    #expect(mention.isEmpty, """
        a sentence that locates nothing was read as \(mention.count) claim(s). A \
        reader that treats every co-occurrence as a claim reports defects in \
        prose that has none.
        """)
}

// MARK: - Claim 4: the documented shim command works as documented

/// Every `command` string anywhere inside `object`.
///
/// Recursive, so it does not depend on the nesting a page happens to print.
private func commandStrings(in object: Any) -> [String] {
    if let dictionary = object as? [String: Any] {
        var found: [String] = []
        for (key, value) in dictionary {
            if key == "command", let text = value as? String { found.append(text) }
            found += commandStrings(in: value)
        }
        return found
    }
    if let array = object as? [Any] { return array.flatMap { commandStrings(in: $0) } }
    return []
}

/// The `coffeebar-hook` commands the quick start prints.
///
/// Read out of the page rather than written here, so the guards below test what
/// a user would actually paste.
///
/// Parsed as JSON rather than matched with a regex. The command carries escaped
/// quotes around the socket path — `\"$HOME/…\"` — and a `[^"]*` capture stops
/// dead at the first of them, which silently truncates the very argument these
/// guards are about. Measured: the capture ended at `--socket=\` and the health
/// check guard failed against a string no reader would ever paste.
///
/// The shim snippet is a FRAGMENT, printed to be merged into an existing
/// `hooks` object, so it is wrapped before parsing. That is what the page tells
/// the reader to do with it.
private func documentedShimCommands() throws -> [String] {
    let text = try surfaceText(hookBlockSurface)
    let blocks = try matches("```json\\n([\\s\\S]*?)\\n```", in: text).map { $0[1] }

    var found: [String] = []
    for block in blocks where block.contains("coffeebar-hook") {
        let candidates = [block, "{\(block)}"]
        guard let parsed = candidates.lazy
            .compactMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) })
            .first
        else {
            Issue.record("a coffeebar-hook block in \(hookBlockSurface) parses as JSON neither whole nor wrapped; a reader merging it would get a broken settings file")
            continue
        }
        found += commandStrings(in: parsed).filter { $0.contains("coffeebar-hook") }
    }
    return found
}

@Test func theDocumentedShimCommandIsOneTheHealthCheckCanSee() throws {
    // The quick start tells the reader to keep `--socket` even though it names
    // the default, and gives the reason: the health check finds its own hooks
    // by matching `HookHealth.commandMarker` in the command. That instruction
    // is only worth following if it is TRUE of the command printed beside it.
    //
    // Named bug: somebody shortens the documented command to
    // `coffeebar-hook --tool=claude-code`, which posts perfectly well. The
    // panel then reports the install as incomplete for every reader who
    // followed the page, and nothing else in this suite would notice.
    let commands = try documentedShimCommands()
    #expect(!commands.isEmpty,
            "\(hookBlockSurface) prints no coffeebar-hook command; this guard cannot run")

    for command in commands {
        #expect(command.contains(HookHealth.commandMarker),
                """
                \(hookBlockSurface) prints "\(command)", which does not contain \
                HookHealth.commandMarker ("\(HookHealth.commandMarker)"). A hook \
                wired from this page would post correctly and still be reported \
                as missing.
                """)
    }
}

@Test func theDocumentedShimCommandNamesARealToolAndTheRealBinary() throws {
    // The two literals in that command that no compiler checks: the product
    // name, and the `--tool` value.
    //
    // The product name is `Package.swift`'s, and renaming the product while
    // this page kept the old name would print a path that does not exist. The
    // tool value is `AgentTool.shimName`, and the shim REFUSES a name it does
    // not recognise — so a drifted page would tell the reader to paste a
    // command that posts nothing at all, in silence, for ever.
    let commands = try documentedShimCommands()
    #expect(!commands.isEmpty,
            "\(hookBlockSurface) prints no coffeebar-hook command; this guard cannot run")

    let names = Set(AgentTool.allCases.map(\.shimName))
    for command in commands {
        let declared = try matches("--tool=([^\\s\"]+)", in: command).map { $0[1] }
        #expect(!declared.isEmpty,
                "\(hookBlockSurface) prints a shim command with no --tool: \(command)")
        for value in declared {
            #expect(names.contains(value),
                    """
                    \(hookBlockSurface) prints --tool=\(value), which \
                    AgentTool.declared(byShimName:) refuses. That command posts \
                    nothing. Known values: \(names.sorted()).
                    """)
        }
    }
}

/// Released code must not claim the shipping bundle is ad-hoc signed.
///
/// Named bug, and it is #86: two architectural justifications — no XPC peer
/// pinning, no `SMAppService` — rest on "there is no Team ID to pin". v0.1.1
/// shipped a notarised image and v0.2.0 ships one carrying both binaries, so
/// the premise died and the comments did not move. A reader is told a check is
/// IMPOSSIBLE when it is merely unimplemented.
///
/// **A WALK, and never a list of paths.** The first round of this guard named
/// the two `Sources/` files #86 happened to mention. That shape cannot catch the
/// NEXT instance, which is the whole failure mode #86 exists to end — a comment
/// nobody noticed for two releases. Measured 2026-08-10: with the premise
/// planted verbatim in `Sources/CoffeeBarPower/LidClosedSession.swift`, a third
/// file the list did not name, the FULL suite passed at 920 tests with zero
/// failures. The list also missed the copy in `AppLayerBoundary_test.swift`,
/// inside the very guard that enforces the decision the premise justified — and
/// a false claim in a check's own reasoning is worse than one in a comment,
/// because the next reader takes it as the reason the rule exists.
///
/// So "source file" here means EVERY `.swift` file under `Sources` and `Tests`.
/// `allSwiftFiles()` in `PolicyDocumentClaims_test.swift` walks the same two
/// directories and is the shape this follows; it is `private` and compiled into
/// a different test target, so this is an equivalent local walk, not a call.
///
/// **ONE exemption, and it is this file.** The two assertions below spell both
/// forbidden claims as literals, so a walk that read this file would report the
/// guard itself, for ever.
///
/// It is a repo-relative PATH derived from `#filePath`, which is the form
/// `noTrackedFileCarriesLiveSessionProse` uses — both sides come from
/// `#filePath`, so the prefix strip is exact. Deriving it rather than writing it
/// out means renaming or moving this file cannot leave a stale literal behind
/// that exempts nothing.
///
/// **A BASENAME here was a real hole, and it is why this says path.** An earlier
/// version of this guard compared `lastPathComponent`, so a SECOND file called
/// `DocsClaims_test.swift` anywhere under `Sources` or `Tests` was skipped in
/// silence. Measured 2026-08-10: with one planted under `Tests/CoffeeBarUITests/`
/// carrying both claims, the full suite passed. Duplicate basenames are not
/// hypothetical in this tree — `main.swift` already occurs twice.
///
/// Measured 2026-08-10: this is the SOLE `.swift` file under `Sources` or
/// `Tests` carrying either string. An exemption list that grows is the hardcoded
/// allowlist returning in a new coat, so anything added here owes the reader the
/// argument this paragraph makes.
///
/// **What this walk deliberately does NOT reach: Markdown.** `SECURITY.md`,
/// `docs/coffee-bar-HANDOFF.md` and `docs/HANDOFF-V0.1.md` carry the same dead
/// premise today. Whether they are corrected in v0.2.1 is a scope decision above
/// this guard, so the gap is left visible here rather than silently closed — a
/// check that quietly grew to rewrite the security policy would be a worse
/// surprise than the hole it filled.
///
/// Matched on the claim, not on the word "adhoc". `docs/BUILDING.md` says the
/// LOCAL build-app.sh output is ad-hoc signed, which is true and must stay
/// sayable.
///
/// The second literal is `only bundle that ships`, deliberately WITHOUT the
/// leading `the `. Measured 2026-08-10: `main.swift` wraps that sentence as
/// `… bundle ID. The` / `// only bundle that ships today …`, so the article is
/// capitalised AND separated from the rest by a newline and a comment marker.
/// `the only bundle that ships` occurs ZERO times in that file — a guard using
/// it is green before the fix and after it, on the very file this issue is
/// about. `only bundle that ships` occurs once in each of the two files.
@Test func noSourceFileClaimsTheShippingBundleIsAdHocSigned() throws {
    let files = everySwiftFileInSourcesAndTests()

    // ANTI-VACUITY. A walk that resolved the wrong root finds nothing, asserts
    // nothing and reads as success — the same blindness the list had, in a new
    // hat. The count catches a broken root; the two named files catch a walk
    // that reaches part of the tree and not the part #86 is about.
    #expect(files.count >= 100,
            "walked \(files.count) Swift files under \(repoRoot().path); this scan is reading almost nothing")
    for control in ["Sources/CoffeeBarProbe/main.swift",
                    "Sources/CoffeeBarPower/LaunchDaemonInstaller.swift"] {
        #expect(files.contains { $0.path.hasSuffix(control) },
                "the walk never reached \(control), one of the two files #86 named")
    }

    // THE ONE EXEMPTION, and it is this file — see the note above. A repo
    // RELATIVE PATH, never a basename: `main.swift` already occurs twice in this
    // tree, so a basename exempts every file that shares it.
    let selfPath = String(#filePath.dropFirst(repoRoot().path.count + 1))

    // A file the walk could not READ is a file it did not CHECK.
    var unreadable: [String] = []

    for file in files {
        let path = String(file.path.dropFirst(repoRoot().path.count + 1))
        guard path != selfPath else { continue }

        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            unreadable.append(path)
            continue
        }

        #expect(!text.contains("TeamIdentifier=not set"),
                "\(path) says TeamIdentifier=not set; the shipped bundle reports 85FN4Z37V8")
        #expect(!text.contains("only bundle that ships"),
                "\(path) still claims one bundle ships and is ad-hoc signed; v0.2.0 ships a Developer ID signed, notarised image")
    }

    #expect(unreadable.isEmpty,
            "\(unreadable.count) Swift file(s) were unreadable, so this scan never checked them: \(unreadable.sorted())")
}

/// Every `.swift` file under `Sources` and `Tests`, sorted.
///
/// An equivalent of `allSwiftFiles()` in `PolicyDocumentClaims_test.swift`,
/// which is `private` and compiled into a different test target. Four lines
/// duplicated is better than widening another target's internals for a
/// neighbour's convenience — the trade `LidClosedPanel_test.swift` records
/// about its own `uiPackageRoot()`.
private func everySwiftFileInSourcesAndTests() -> [URL] {
    var found: [URL] = []
    for base in ["Sources", "Tests"] {
        let directory = repoRoot().appending(path: base)
        guard let walker = FileManager.default.enumerator(atPath: directory.path)
        else { continue }
        for case let relative as String in walker where relative.hasSuffix(".swift") {
            found.append(directory.appending(path: relative))
        }
    }
    return found.sorted { $0.path < $1.path }
}

// MARK: - Claim 8: the site may not claim the app makes no network request

/// The absolute no-egress claims the site may not make about the shipped app.
///
/// **Why this exists, and why it is a list of phrases.** v0.3.0 shipped an
/// update check: `UpdateChecker.manifestURL` is a real `GET` of a real host,
/// fired from `main.swift` at launch and from the Check now button. Two site
/// pages went on saying the opposite anyway, and the whole suite stayed green
/// through both of them, because every prose guard in this file reads NUMBERS,
/// CONTROLS and COUNTS. Nothing read the egress sentences at all. The claim was
/// corrected once by hand, a second false one survived that pass, and a fix
/// nothing enforces is a fix with a half-life.
///
/// The subject cannot be derived, so it is enumerated. There is no property of
/// the codebase that says "this sentence promises no egress": the app DOES make
/// one request, so the guard cannot compare a claim against a measurement the
/// way `everyDurationStatedIsARealProductConstant` does. What it can do is hold
/// a list of the exact phrasings that are false while that request exists, and
/// refuse to let one back onto a page.
///
/// **The discrimination this has to make, which is the hard part.**
/// `site/install.html` says "It needs no network connection" about `spctl`
/// reading a stapled ticket, and that is TRUE: the verb is what separates them.
/// A sentence about what the app NEEDS is a statement of requirement; a
/// sentence about what it SENDS, POSTS or REQUESTS is a claim about behaviour,
/// and only the second kind is banned. "no telemetry", "no analytics", "no
/// account, no sign-in, no server" and "sends no identifier" are all still true
/// of the shipped app and all stay legal.
/// `theEgressBanFiresOnAbsoluteClaimsAndSparesTheTrueOnes` pins every one of
/// those readings with the real sentences, so narrowing a pattern until it
/// catches nothing cannot happen quietly.
///
/// **What this CANNOT do, stated so nobody over-trusts it.** It catches
/// phrasings on this list and no others. A new sentence meaning the same thing
/// in new words ("it talks to nobody") passes, and the guard would have to
/// learn it. That is a real hole and it is the honest one: the alternative,
/// banning the concept, would have to ban "no telemetry" with it.
private let absoluteEgressClaimPatterns: [String] = [
    "\\bno\\s+network\\s+egress\\b",
    "\\b(?:make|makes|making|made)\\s+no\\s+network\\s+(?:request|connection)s?\\b",
    "\\b(?:send|sends|sending|sent)\\s+nothing\\b",
    "\\b(?:post|posts|posting|posted)\\s+nothing\\b",
    "\\bno\\s+update\\s+ping\\b",
    "\\bnothing\\s+(?:ever\\s+)?leaves\\s+(?:your|the|this)\\s+(?:mac|machine|computer)\\b",
]

/// No page under `site/` claims, about the app as it ships, that it makes no
/// network request.
///
/// Scoped to CURRENT claims, for the reason `currentClaimProse` documents: a
/// `<section>` under a version `<h2>` RECORDS what a release shipped. Before
/// 0.3.0 there was genuinely no outbound request, so "the single exception to
/// this app's promise to make no network request" was true of 0.2.2 when it was
/// written. Reading history as a live claim would leave only one way to green,
/// which is to falsify the changelog.
@Test(arguments: discoveredSitePages())
func noSitePageClaimsTheAppMakesNoNetworkRequest(_ page: String) throws {
    let prose = try currentClaimProse(page)

    for pattern in absoluteEgressClaimPatterns {
        for m in try matches(pattern, in: prose) {
            #expect(Bool(false), """
                \(page) carries the absolute claim "\(m[0])", which is false: \
                UpdateChecker.manifestURL is a GET of \
                https://arangogutierrez.github.io/coffee-bar/latest.json, fired \
                at launch and by Check now. Say what SECURITY.md says instead \
                ("it makes exactly one outbound request", "it downloads no \
                update"), or scope the sentence to the subject it is really \
                about. Context: ...\(egressClaimContext(m[0], in: prose))...
                """)
        }
    }
}

/// The words either side of a match, so a failure points at the sentence rather
/// than sending the reader to grep for a phrase that may occur twice.
private func egressClaimContext(_ phrase: String, in prose: String) -> String {
    let flat = prose.replacingOccurrences(of: "\\s+", with: " ",
                                          options: .regularExpression)
    guard let found = flat.range(of: phrase, options: .caseInsensitive) else { return phrase }
    let start = flat.index(found.lowerBound, offsetBy: -60, limitedBy: flat.startIndex) ?? flat.startIndex
    let end = flat.index(found.upperBound, offsetBy: 60, limitedBy: flat.endIndex) ?? flat.endIndex
    return String(flat[start..<end])
}

/// The ban catches the sentences that actually shipped, and spares the true
/// ones standing beside them.
///
/// Every string below is REAL. The banned ones are the exact sentences this
/// branch removed from `site/privacy.html`, `site/index.html` and the changelog
/// entry, plus the phrasings the brief for this work named. The allowed ones
/// are live text on the corrected tree. A pattern narrowed until it matches
/// nothing, or widened until it swallows "no telemetry", fails HERE, which is
/// the failure the sweep above cannot produce on a clean tree.
@Test func theEgressBanFiresOnAbsoluteClaimsAndSparesTheTrueOnes() throws {
    // Each of these must be caught by at least one pattern.
    let banned = [
        "GitHub's privacy policy, and it happens before coffee-bar ever runs. The app itself sends nothing.",
        "and it is the single exception to this app's promise to make no network request. (#29)",
        "coffee-bar makes no network requests at all.",
        "There is no network egress from this application.",
        "It posts nothing anywhere.",
        "There is no update ping.",
        "Nothing ever leaves your Mac.",
    ]
    for sentence in banned {
        let hit = try absoluteEgressClaimPatterns.contains { try !matches($0, in: sentence).isEmpty }
        #expect(hit, """
            no pattern in absoluteEgressClaimPatterns catches "\(sentence)". \
            That sentence is a false no-egress claim and the ban is now blind to it
            """)
    }

    // Each of these is TRUE of the shipped app and must stay legal. A guard
    // that fired on one of them would teach the author to delete a true claim.
    let allowed = [
        "The notarisation ticket is stapled to the disk image, so the second command answers from the ticket in the file. It needs no network connection.",
        "There is no telemetry, no analytics and no crash reporting.",
        "What coffee-bar reads on your Mac, what it never reads, and what leaves the machine. No account, no sign-in, no server, no telemetry.",
        "It sends no identifier, sets no header, carries no query string.",
        "One outbound request, and it is a version check.",
        "Any further outbound request will be opt-in, off by default, and named here first.",
        "The check tells you and installs nothing: no update is downloaded, and coffee-bar never replaces itself.",
        "the hook channel that agents already post to still answers with an empty body",
        "which lives in the filesystem and has no address, no port, and no route off this machine.",
    ]
    for sentence in allowed {
        for pattern in absoluteEgressClaimPatterns {
            let found = try matches(pattern, in: sentence)
            #expect(found.isEmpty, """
                the pattern \(pattern) fires on "\(sentence)", which is a TRUE \
                statement about the shipped app. It matched "\(found.first?[0] ?? "")"
                """)
        }
    }
}
