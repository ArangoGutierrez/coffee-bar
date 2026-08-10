// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
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
private func htmlProse(_ text: String) -> String {
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
func matches(_ pattern: String, in text: String) throws -> [[String]] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
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

    let readme = try surfaceProse("README.md")
    #expect(try !matches(percentPattern, in: readme).isEmpty, "no percentage in the README")

    let site = try surfaceProse("site/index.html")
    #expect(try !matches(hookCountPattern, in: site).isEmpty, "no '<number> hooks' phrase on the site")
    #expect(try !matches(percentPattern, in: site).isEmpty, "no percentage on the site")
}

private let hookCountPattern = "\\b(three|four|five|six|seven)\\b[\\s\\S]{0,25}?hooks?"
private let durationPattern = "(\\d[\\d,_]*)[\\s-]*(second|minute|hour)s?"
private let percentPattern = "(\\d+)\\s*%"
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

@Test(arguments: documentedSurfaces)
func theBatteryFloorStatedIsTheRealDefault(_ name: String) throws {
    let prose = try surfaceProse(name)

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
@Test(arguments: documentedSurfaces)
func aBoundaryPhraseMatchesTheRealBoundary(_ name: String) throws {
    let prose = try surfaceProse(name)

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

@Test(arguments: documentedSurfaces)
func everyControlNamedExistsInTheProduct(_ name: String) throws {
    let prose = try surfaceProse(name)

    // A quoted phrase in a sentence that offers it as something the reader can
    // operate. "unless you turn on \"stay awake while blocked\"" is the shape
    // that shipped a control existing in no build.
    let controlVerbs = "(?:turn on|turn off|enable|disable|toggle|switch on|switch off|tick|check)"
    let found = try matches(controlVerbs + "[^\\n\"]{0,40}\"([^\"\\n]{4,60})\"", in: prose)

    for m in found {
        let phrase = m[1]
        #expect(sourcesContain(phrase),
                "\(name) offers a control named \"\(phrase)\", but no file under Sources/ contains that string")
    }
}

/// True when any `.swift` file under `Sources/` contains `phrase` verbatim.
private func sourcesContain(_ phrase: String) -> Bool {
    let sources = repoRoot().appending(path: "Sources")
    guard let walker = FileManager.default.enumerator(atPath: sources.path) else { return false }
    for case let rel as String in walker where rel.hasSuffix(".swift") {
        let url = sources.appending(path: rel)
        if let body = try? String(contentsOf: url, encoding: .utf8), body.contains(phrase) {
            return true
        }
    }
    return false
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
