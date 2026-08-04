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
private let markdownSurfaces = ["CHANGELOG.md", "README.md",
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

    // The three pages the redesign added, and the three that were unguarded
    // when this check was written. Named one by one, so losing a page fails
    // HERE, loudly, instead of quietly reducing coverage everywhere else.
    for page in ["site/install.html", "site/docs.html", "site/changelog.html"] {
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

@Test(arguments: documentedSurfaces)
func everyDurationStatedIsARealProductConstant(_ name: String) throws {
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
