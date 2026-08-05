// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import CoffeeBarCore

/// Guards the STRUCTURE the site publishes, where `DocsClaims_test.swift` guards
/// the PROSE it writes.
///
/// **Why the split.** Those checks read a page as sentences: they strip markup
/// and code and ask whether a number in a sentence is a real product constant.
/// These checks need the opposite — the markup IS the subject. A policy table,
/// a version string, a sidebar and a pasteable JSON block are all things
/// `htmlProse` deletes on its way to the prose, so a guard built on it could
/// never see them. Two files, two readings of the same pages.
///
/// **What these checks CANNOT do, stated so nobody over-trusts them.**
///
/// 1. They compare the site against the repository, not against reality. Guard 3
///    proves the page and the newest git tag agree; it cannot prove a release
///    with that tag was ever published, or that the disk image behind the link
///    exists. A tag pushed with no release passes here.
/// 2. Guard 5 compares `site/changelog.html` against `CHANGELOG.md` and treats
///    the Markdown as true. A wrong SHA-256 written into both stays green. This
///    catches DRIFT between a copy and its source, which is the failure that
///    actually happened, and not a false fact agreed on by both.
/// 3. Guard 4a proves the four sidebars are the same. It does not prove they are
///    RIGHT. Four identical sidebars all linking to a deleted page pass.
///
/// Each guard says under its own name what it would miss.

// MARK: - Shared reading helpers

/// HTML entities turned back into the characters they stand for.
///
/// `&amp;` goes LAST and that order is the whole point: unescaping it first
/// turns `&amp;lt;` into `&lt;` and then into `<`, inventing a tag the author
/// never wrote.
private func htmlUnescaped(_ text: String) -> String {
    var s = text
    for (entity, character) in [("&lt;", "<"), ("&gt;", ">"),
                                ("&quot;", "\""), ("&#39;", "'")] {
        s = s.replacingOccurrences(of: entity, with: character)
    }
    return s.replacingOccurrences(of: "&amp;", with: "&")
}

/// The first line on which two blocks differ, for a failure message a person can
/// act on.
///
/// Printing two whole `<nav>` blocks and leaving the reader to diff them by eye
/// is how a real failure gets dismissed as noise.
private func firstDifference(_ a: String, _ b: String) -> String {
    let left = a.split(separator: "\n", omittingEmptySubsequences: false)
    let right = b.split(separator: "\n", omittingEmptySubsequences: false)
    for i in 0..<max(left.count, right.count) {
        let l = i < left.count ? String(left[i]) : "<no line \(i + 1)>"
        let r = i < right.count ? String(right[i]) : "<no line \(i + 1)>"
        if l != r { return "line \(i + 1):\n  \(l)\n  \(r)" }
    }
    return "<no difference>"
}

/// A table cell reduced to the text a reader sees, on either side of the mirror.
///
/// Markdown writes a literal in backticks and HTML writes it in `<code>`, so the
/// two spellings of one value must collapse to the same string before they can
/// be compared. Whitespace collapses too: HTML folds runs of space and a
/// Markdown table pads its columns, and neither is a difference a reader could
/// ever see.
private func plainValue(_ raw: String) -> String {
    var s = htmlUnescaped(raw.replacingOccurrences(of: "<[^>]+>", with: "",
                                                   options: .regularExpression))
    s = s.replacingOccurrences(of: "`", with: "")
    s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Guard 2: the published table cannot disagree with the policy

/// One row of the decision table `site/index.html` embeds at `#policy-table`.
///
/// `Decodable` rather than a hand-rolled cast, so a row missing a field is a
/// decode error — a loud failure — instead of a silently defaulted `false` that
/// would happen to agree with the policy for half the table.
private struct PolicyRow: Decodable {
    let intent: String
    let displayOptIn: Bool
    let atOrBelowFloor: Bool
    let sessionsActive: Bool
    let system: Bool
    let displayHeld: Bool
    let suppressed: Bool

    /// The four inputs, which are what the table is keyed by.
    var key: String {
        "\(intent)|\(displayOptIn)|\(atOrBelowFloor)|\(sessionsActive)"
    }
}

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func workingSession() -> AgentSession {
    AgentSession(tool: .claudeCode, sessionID: "s", cwd: nil, repoName: nil,
                 pid: nil, state: .working, stateEnteredAt: t0, lastEventAt: t0,
                 lastMessage: nil, attentionSince: nil, turnCount: 0)
}

/// Every row the site publishes is what `PowerBroker.decide` actually returns.
///
/// The page prints 24 rows and calls them "the data the bench reads". A reader
/// takes that table as the product's behaviour, so a stale row is a false claim
/// with a table's authority behind it — worse than a sentence, because a table
/// looks generated even when it was typed.
///
/// The battery floor is deliberately NOT passed into `PowerInputs`. Feeding the
/// page's own number back in as `batteryFloorPercent` would make every floor row
/// agree with itself whatever the number said. The DEFAULT decides, and the
/// page's published floor is checked against that default separately, which is
/// the same reasoning `theBatteryFloorStatedIsTheRealDefault` carries.
///
/// `atOrBelowFloor` is tested at EXACTLY the floor, not below it. `decide`
/// suppresses at `percent <= floor`; a row tested at 5% would still pass if that
/// comparison were `<`, and the boundary is the part a reader gets wrong.
/// The rows of `#policy-table`, the JSON the bench reads.
///
/// A throwing helper rather than a check, so both the policy comparison and the
/// visible-table comparison read the one source. Its own anti-vacuity assertions
/// live in `everyPublishedPolicyRowIsWhatPowerBrokerDecides`.
private func publishedPolicyRows(_ page: String) throws -> [PolicyRow] {
    let tables = try matches(
        "<script type=\"application/json\" id=\"policy-table\">([\\s\\S]*?)</script>",
        in: page)
    guard tables.count == 1, let raw = tables.first?[1] else {
        throw BadPattern(pattern: "site/index.html has \(tables.count) #policy-table blocks; this guard needs exactly one")
    }
    return try JSONDecoder().decode([PolicyRow].self, from: Data(raw.utf8))
}

@Test func everyPublishedPolicyRowIsWhatPowerBrokerDecides() throws {
    let page = try surfaceText("site/index.html")
    let rows = try publishedPolicyRows(page)

    // Anti-vacuity, and the reason it is not optional: a typo that yields `[]`
    // parses cleanly, the loop below runs zero times, and the guard reports
    // success while checking nothing.
    #expect(rows.count == 24,
            "#policy-table parsed to \(rows.count) rows; the table covers 3 intents x 2 x 2 x 2 = 24")
    #expect(Set(rows.map(\.key)).count == 24,
            "#policy-table has \(Set(rows.map(\.key)).count) distinct input keys across \(rows.count) rows; a duplicated row means a combination is missing")

    let metas = try matches("id=\"policy-meta\">([\\s\\S]*?)</script>", in: page)
    #expect(metas.count == 1,
            "site/index.html has \(metas.count) #policy-meta blocks; this guard needs exactly one")
    guard let metaRaw = metas.first?[1],
          let meta = try? JSONDecoder().decode([String: Int].self, from: Data(metaRaw.utf8)),
          let publishedFloor = meta["batteryFloorPercent"]
    else {
        Issue.record("cannot read batteryFloorPercent from #policy-meta in site/index.html")
        return
    }

    let realFloor = PowerInputs(powerSource: .ac, batteryPercent: nil).batteryFloorPercent
    #expect(publishedFloor == realFloor,
            "site/index.html publishes a \(publishedFloor)% floor; the PowerInputs default is \(realFloor)%")

    for row in rows {
        guard let intent = UserIntent(rawValue: row.intent) else {
            Issue.record("#policy-table row \(row.key) names intent \"\(row.intent)\", which is not a UserIntent case")
            continue
        }

        let real = PowerBroker.decide(PowerInputs(
            sessions: row.sessionsActive ? [workingSession()] : [],
            powerSource: row.atOrBelowFloor ? .battery : .ac,
            batteryPercent: row.atOrBelowFloor ? realFloor : nil,
            userIntent: intent,
            holdDisplayAwake: row.displayOptIn))

        #expect(real.idleSleepAssertion == row.system,
                "#policy-table row \(row.key) publishes system=\(row.system); PowerBroker.decide returns \(real.idleSleepAssertion)")
        #expect(real.displaySleepAssertion == row.displayHeld,
                "#policy-table row \(row.key) publishes displayHeld=\(row.displayHeld); PowerBroker.decide returns \(real.displaySleepAssertion)")
        #expect((real.suppression != nil) == row.suppressed,
                "#policy-table row \(row.key) publishes suppressed=\(row.suppressed); PowerBroker.decide returns \(String(describing: real.suppression))")
    }
}

/// The seven column headings of the visible table, in order.
///
/// Asserted as literals because the row reading below is POSITIONAL. Reordering
/// two columns would otherwise silently change what every cell means, and the
/// comparison would go on passing against a table that now says something else.
private let visibleTableHeadings = [
    "Serving", "Display", "On battery at or below 20%", "An agent is working",
    "Holds the system awake", "Holds the display awake",
    "Held back by the battery floor",
]

private let intentByLabel = ["Off": "stop", "Auto": "auto", "On": "serve"]
private let displayOptInByLabel = ["Sleeps": false, "Stays on": true]
private let boolByLabel = ["No": false, "Yes": true]

/// The table a reader without JavaScript sees says what the bench says.
///
/// `bench.js` promises in its own header that "the visitor reads the same 24
/// rows as a real HTML table". Nothing enforced that: the reviewer flipped one
/// `<td>` in the visible table, left `#policy-table` untouched, and the suite
/// stayed green at 495 with the bench's own tests at 23/23.
///
/// A wrong cell there is a false claim aimed at the one reader who cannot check
/// it against anything else — no JavaScript means no bench to cross-read. It is
/// also the copy that survives in a text browser, in Reader mode, and in a
/// printout.
///
/// Compared against `#policy-table` rather than against `PowerBroker` directly.
/// `everyPublishedPolicyRowIsWhatPowerBrokerDecides` already pins the JSON to
/// the product, so pinning the table to the JSON makes the chain complete while
/// keeping each link's failure message about one thing.
@Test func theVisibleTableSaysWhatTheBenchTableSays() throws {
    let page = try surfaceText("site/index.html")

    // Scoped to the bench's own `<details>`. The page carries a second table,
    // and a bare `<table>` selector would read whichever came first.
    let blocks = try matches("<details class=\"bench-table\">([\\s\\S]*?)</details>", in: page)
    #expect(blocks.count == 1,
            "site/index.html has \(blocks.count) bench-table blocks; this guard needs exactly one")
    guard let block = blocks.first?[1] else { return }

    let headings = try matches("<th scope=\"col\">([^<]*)</th>", in: block).map { plainValue($0[1]) }
    #expect(headings == visibleTableHeadings,
            "the visible table's columns are \(headings); this guard reads them by position and expects \(visibleTableHeadings)")

    let rowMarkup = try matches("<tr><td>([\\s\\S]*?)</td></tr>", in: block).map { $0[1] }
    #expect(rowMarkup.count == 24,
            "parsed \(rowMarkup.count) rows from the visible table; a selector matching nothing must fail here rather than compare nothing")

    let published = try publishedPolicyRows(page)
    #expect(published.count == 24,
            "#policy-table parsed to \(published.count) rows; this guard cannot compare against a table it could not read")

    var byKey: [String: PolicyRow] = [:]
    for row in published { byKey[row.key] = row }

    var comparedRows = 0
    for (index, markup) in rowMarkup.enumerated() {
        let cells = markup.components(separatedBy: "</td><td>").map { plainValue($0) }
        guard cells.count == visibleTableHeadings.count else {
            Issue.record("visible row \(index + 1) has \(cells.count) cells, not \(visibleTableHeadings.count): \(cells)")
            continue
        }

        guard let intent = intentByLabel[cells[0]],
              let displayOptIn = displayOptInByLabel[cells[1]],
              let atOrBelowFloor = boolByLabel[cells[2]],
              let sessionsActive = boolByLabel[cells[3]],
              let system = boolByLabel[cells[4]],
              let displayHeld = boolByLabel[cells[5]],
              let suppressed = boolByLabel[cells[6]]
        else {
            Issue.record("visible row \(index + 1) uses labels this guard does not know: \(cells)")
            continue
        }

        let key = "\(intent)|\(displayOptIn)|\(atOrBelowFloor)|\(sessionsActive)"
        guard let published = byKey[key] else {
            Issue.record("visible row \(index + 1) states inputs \(key), which #policy-table has no row for")
            continue
        }
        comparedRows += 1

        #expect(system == published.system,
                "visible row \(index + 1) (\(key)) says the system hold is \(cells[4]); #policy-table says \(published.system)")
        #expect(displayHeld == published.displayHeld,
                "visible row \(index + 1) (\(key)) says the display hold is \(cells[5]); #policy-table says \(published.displayHeld)")
        #expect(suppressed == published.suppressed,
                "visible row \(index + 1) (\(key)) says the floor holds it back: \(cells[6]); #policy-table says \(published.suppressed)")
    }

    // Every row reached a comparison. Without this, rows that failed to map
    // would be recorded above but the guard would still look thorough.
    #expect(comparedRows == 24,
            "compared \(comparedRows) of 24 visible rows against #policy-table")
}

// MARK: - Guard 3: the version cannot drift

private struct GitUnavailable: Error, CustomStringConvertible {
    let reason: String
    var description: String {
        "cannot read the newest tag (\(reason)); this guard cannot run and will not pretend it passed"
    }
}

/// The shape of a released version tag. Anything else is not a release.
private let releaseTagPattern = "^v\\d+\\.\\d+\\.\\d+$"

/// The newest RELEASE tag, from git.
///
/// **This throws rather than skipping, and that is the design.** A version guard
/// that returns "no tags, nothing to check" is worse than no guard: it is green
/// on a machine where it never ran, so it reports safety it did not establish.
/// The same false-absence trap `matches` throws over in `DocsClaims_test.swift`.
///
/// **Pre-release tags are filtered out, and that filter is load-bearing.**
/// `--sort=-v:refname` ranks `v0.2.0-rc1` above `v0.1.1`, so without it, cutting
/// a release candidate — ordinary release engineering, not a mistake — would
/// make four correct pages look stale. Worse, the failure would name the wrong
/// culprit: `everyDownloadLinkPointsAtTheNewestReleasedVersion` would report
/// "site/install.html links into release v0.1.1; the newest release tag is
/// v0.2.0-rc1", accusing a page of a defect the page does not have. A guard that
/// cries wolf at correct pages teaches the reader to distrust the whole suite,
/// which costs more than the guard is worth.
///
/// Filtering fails CLOSED: if the pattern ever matches nothing, this throws with
/// the tags it saw rather than falling back to an unfiltered newest.
private func newestReleaseTag() throws -> String {
    let git = Process()
    git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    git.arguments = ["git", "-C", repoRoot().path, "tag", "--sort=-v:refname"]

    let out = Pipe()
    git.standardOutput = out
    git.standardError = Pipe()

    do { try git.run() } catch { throw GitUnavailable(reason: "git did not start: \(error)") }

    // Read before waiting. A tag list is small, but draining the pipe only after
    // the process exits deadlocks the moment the output outgrows the buffer.
    let data = out.fileHandleForReading.readDataToEndOfFile()
    git.waitUntilExit()

    guard git.terminationStatus == 0 else {
        throw GitUnavailable(reason: "git tag exited \(git.terminationStatus)")
    }

    let tags = String(decoding: data, as: UTF8.self)
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

    guard !tags.isEmpty else { throw GitUnavailable(reason: "no tags in the repository") }

    let releases = tags.filter { $0.range(of: releaseTagPattern, options: .regularExpression) != nil }
    guard let newest = releases.first else {
        throw GitUnavailable(
            reason: "none of the \(tags.count) tag(s) is a vMAJOR.MINOR.PATCH release: \(tags.prefix(8).joined(separator: ", "))")
    }
    return newest
}

/// Every page shows the newest released version, not the one it shipped with.
///
/// The four pages each hardcode a version in the sidebar because there is no
/// build step. Cutting a release therefore means editing four files, and the
/// fourth is the one that gets forgotten.
///
/// Only the sidebar is compared, not every version-shaped string on the page:
/// the pages legitimately name 0.1.0 while telling a reader that Homebrew still
/// installs it, and a guard that failed on a true sentence would be turned off
/// within a week.
/// A pre-release tag is ignored, not treated as the newest release. That is
/// `newestReleaseTag`'s job, and it is why this test asserts nothing about the
/// tag's SHAPE: the filter guarantees it, so an assertion here would restate the
/// filter rather than test it, and would hold whether the filter worked or not.
@Test func everyPageShowsTheNewestReleasedVersion() throws {
    let tag = try newestReleaseTag()
    let pages = discoveredSitePages()
    #expect(pages.count >= 4, "discovery found \(pages.count) page(s) under site/; this guard would sweep almost nothing")

    for page in pages {
        let shown = try matches(
            "<p class=\"sidebar-version\">[\\s\\S]{0,120}?(v\\d+\\.\\d+\\.\\d+)[\\s\\S]{0,40}?</p>",
            in: try surfaceText(page))
        #expect(shown.count == 1,
                "\(page) shows \(shown.count) sidebar versions; every page carries exactly one")
        for m in shown {
            #expect(m[1] == tag,
                    "\(page) shows \(m[1]) in its sidebar; the newest release tag is \(tag)")
        }
    }
}

/// Every download link points at the newest tag, and names a file that matches.
///
/// The URL carries the version TWICE — once in the release path and once in the
/// file name — so a half-finished edit produces a link to a file that does not
/// exist inside a release that does. Both halves are checked against the tag.
///
/// This cannot tell you the artifact was uploaded. It tells you the link is
/// self-consistent and current; publishing is verified by downloading it.
@Test func everyDownloadLinkPointsAtTheNewestReleasedVersion() throws {
    let tag = try newestReleaseTag()
    let version = String(tag.dropFirst())   // v0.1.1 -> 0.1.1

    var checked = 0
    for page in discoveredSitePages() {
        for m in try matches("releases/download/([^/\"]+)/coffee-bar-([^\"]+?)\\.dmg",
                             in: try surfaceText(page)) {
            checked += 1
            #expect(m[1] == tag,
                    "\(page) links into release \(m[1]); the newest release tag is \(tag)")
            #expect(m[2] == version,
                    "\(page) links to coffee-bar-\(m[2]).dmg; the newest release is \(version)")
        }
    }

    // The download button and the JSON-LD `downloadUrl` on the home page, and
    // the button on the install page. Fewer than three means a selector rotted
    // and this guard swept a site with no download links on it.
    #expect(checked >= 3,
            "found \(checked) download link(s) across the site; the home and install pages carry three between them")
}

// MARK: - Guard 4a: the duplicated sidebar cannot drift

/// The sidebar is byte-identical on every page.
///
/// There is no build step and no template, so the sidebar is copied by hand into
/// each page. That duplication is a deliberate trade — no toolchain to install
/// before editing a page — and this check is the whole price of it. Without it,
/// adding a fifth page means four edits and no way to notice the fourth was
/// missed.
///
/// `aria-current="page"` is removed before comparing, and it is the only thing
/// removed. It marks which entry is the current page, so it MUST differ; every
/// other byte must not.
@Test func everyPageCarriesTheSameSidebar() throws {
    let pages = discoveredSitePages()
    #expect(pages.count >= 4,
            "discovery found \(pages.count) page(s) under site/; comparing fewer than two sidebars proves nothing")

    var sidebars: [(page: String, block: String)] = []
    for page in pages {
        let found = try matches("<nav class=\"sidebar\"[\\s\\S]*?</nav>", in: try surfaceText(page))
        #expect(found.count == 1,
                "\(page) has \(found.count) sidebar blocks; every page carries exactly one")
        guard let block = found.first?[0] else { continue }
        sidebars.append((page, block.replacingOccurrences(of: " aria-current=\"page\"", with: "")))
    }

    #expect(sidebars.count == pages.count,
            "read a sidebar from \(sidebars.count) of \(pages.count) pages; a page with no sidebar is a page this guard skipped")

    guard let reference = sidebars.first else { return }
    for entry in sidebars.dropFirst() {
        #expect(entry.block == reference.block,
                "the sidebar on \(entry.page) differs from the one on \(reference.page). First difference, \(reference.page) then \(entry.page), \(firstDifference(reference.block, entry.block))")
    }
}

// MARK: - Guard 4b: the pasteable hook block cannot drift

/// The JSON `site/install.html` tells a user to paste parses, and wires exactly
/// the events the app requires.
///
/// This is the site copy of `theHookBlockIsExactlyTheRequiredEvents`, which
/// reads `docs/QUICKSTART.md` alone. The site block is what a stranger actually
/// pastes, so an event missing here is an app that silently sees nothing — the
/// exact failure `HookHealth` exists to report.
///
/// The block is found by its `class="hooks"`, not by position. `htmlProse` looks
/// for a bare `<pre>` and so does not strip this one, which is a second reason
/// to read the raw page here: prose and markup disagree about what this block is.
@Test func theHookBlockOnTheInstallPageIsExactlyTheRequiredEvents() throws {
    let page = try surfaceText("site/install.html")

    let blocks = try matches("<pre class=\"hooks\">([\\s\\S]*?)</pre>", in: page)
    #expect(blocks.count == 1,
            "site/install.html has \(blocks.count) hook blocks; this guard needs exactly one")
    guard let raw = blocks.first?[1] else { return }

    // The page escapes entities where it must. Unescape before parsing rather
    // than assuming: a `&quot;` reaching JSONSerialization is a parse error that
    // would read as "the block is broken" when the block is fine.
    let parsed = try? JSONSerialization.jsonObject(with: Data(htmlUnescaped(raw).utf8))
    guard let hooks = (parsed as? [String: Any])?["hooks"] as? [String: Any] else {
        Issue.record("the hook block on site/install.html does not parse as JSON with a `hooks` object; a user pasting it would get a broken settings file")
        return
    }

    let documented = Set(hooks.keys)
    let required = Set(HookHealth.requiredEvents)
    #expect(documented == required,
            "site/install.html wires \(documented.sorted()); HookHealth.requiredEvents is \(required.sorted())")
}

/// The site block is a copy of the quick start's block, down to the command.
///
/// `site/install.html` carries a comment saying `docs/QUICKSTART.md` is the
/// original and to re-copy rather than edit. Nothing enforced that. The keys
/// check above would stay green while the two blocks disagreed about the curl
/// command, the timeout or the socket path — and the socket path is the one
/// that stops the app receiving anything at all.
///
/// Compared as parsed JSON with sorted keys, not as text: key order and
/// indentation are not claims about anything, and failing on them would make
/// this guard fire on a reformat.
///
/// Canonicalised PRETTY-PRINTED rather than compact, purely for the failure
/// message. Comparing two compact blobs reports "1177 bytes == 1177 bytes" and
/// prints two unbroken 1177-character lines, which is a failure a reader gives
/// up on. Pretty-printing puts one value per line so `firstDifference` can name
/// the line that actually changed.
@Test func theSiteHookBlockIsStillACopyOfTheQuickStartBlock() throws {
    let quickstart = try surfaceText("docs/QUICKSTART.md")
    let install = try surfaceText("site/install.html")

    let fenced = try matches("```json\\n([\\s\\S]*?)\\n```", in: quickstart).map { $0[1] }
    #expect(!fenced.isEmpty, "no json block in docs/QUICKSTART.md; this guard cannot run")

    let onPage = try matches("<pre class=\"hooks\">([\\s\\S]*?)</pre>", in: install).map { $0[1] }
    #expect(onPage.count == 1, "site/install.html has \(onPage.count) hook blocks; this guard needs exactly one")

    guard let source = fenced.first, let copy = onPage.first else { return }

    func canonical(_ text: String, _ label: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(htmlUnescaped(text).utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .prettyPrinted])
        else {
            Issue.record("the hook block in \(label) does not parse as JSON")
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    guard let a = canonical(source, "docs/QUICKSTART.md"),
          let b = canonical(copy, "site/install.html") else { return }

    #expect(a == b,
            "site/install.html no longer matches docs/QUICKSTART.md. First difference, quick start then install page, \(firstDifference(a, b))")
}

// MARK: - Guard 5: the changelog page cannot drift from its source

/// The eight rows of the release-facts table, named.
///
/// A literal list, so a row silently disappearing from BOTH sides still fails.
/// Deriving the list from either document would let the two agree on nothing at
/// all and call it a match.
private let releaseFacts = ["File", "Size", "SHA-256", "Architecture",
                            "Minimum macOS", "Signature", "Notarisation", "Staple"]

/// The text from the first release heading up to the second one.
///
/// Throws rather than returning the whole document when no heading matches.
/// Falling back to everything is the false-absence trap in its most expensive
/// form here: the caller would compare two whole files, find the values it
/// wanted somewhere in each, and report a clean mirror it never checked.
private func newestReleaseSection(of text: String,
                                  startingAt heading: String,
                                  named label: String) throws -> String {
    let starts = try matches(heading, in: text)
    guard starts.count >= 1 else {
        throw BadPattern(pattern: "no release heading in \(label); this guard cannot find a section to compare")
    }

    let ns = text as NSString
    guard let first = ns.range(of: starts[0][0]).location as Int?, first != NSNotFound else {
        throw BadPattern(pattern: "cannot locate the first release heading in \(label)")
    }
    let rest = ns.substring(from: first + (starts[0][0] as NSString).length)

    // Up to the next heading, or the end of the file for a single-release
    // document. Both are legitimate; neither may silently become "everything".
    if starts.count >= 2, case let next = (rest as NSString).range(of: starts[1][0]),
       next.location != NSNotFound {
        return (rest as NSString).substring(to: next.location)
    }
    return rest
}

/// Every release in `CHANGELOG.md` is on the page, and the page invents none.
///
/// **This has already gone wrong on this branch.** Commit `3a3f73e` weakened
/// three claims in the Markdown and left `site/changelog.html` asserting more
/// than its source, including a Gatekeeper promise deleted for being unprovable.
/// Commit `60ca6a5` re-synced it by hand. Nothing would have caught it.
///
/// The count is compared in BOTH directions on purpose. Checking only that every
/// Markdown release reaches the page would have stayed green through exactly
/// that incident, because the page's problem was carrying MORE than its source.
@Test func everyReleaseInTheChangelogIsOnTheChangelogPage() throws {
    let source = try surfaceText("CHANGELOG.md")
    let page = try surfaceText("site/changelog.html")

    let released = try matches(
        "(?m)^##\\s+\\[(\\d+\\.\\d+\\.\\d+)\\]\\s*[\u{2014}\u{2013}-]\\s*(\\d{4}-\\d{2}-\\d{2})",
        in: source)
    #expect(released.count >= 2,
            "parsed \(released.count) release heading(s) from CHANGELOG.md; the project has shipped at least two")

    let onPage = try matches(
        "<h2[^>]*>\\s*(\\d+\\.\\d+\\.\\d+)\\s*[\u{2014}\u{2013}-]\\s*(\\d{4}-\\d{2}-\\d{2})\\s*</h2>",
        in: page)
    #expect(onPage.count >= 2,
            "parsed \(onPage.count) release heading(s) from site/changelog.html; the selector matches nothing rather than the page being empty")

    let headingsOnPage = Set(onPage.map { "\($0[1]) \($0[2])" })
    for m in released {
        #expect(headingsOnPage.contains("\(m[1]) \(m[2])"),
                "CHANGELOG.md releases \(m[1]) on \(m[2]); site/changelog.html carries \(headingsOnPage.sorted())")
    }

    #expect(headingsOnPage.count == released.count,
            "site/changelog.html carries \(headingsOnPage.count) releases and CHANGELOG.md carries \(released.count); the page announces a release its source does not")
}

/// The eight release facts are the same on both sides of the mirror.
///
/// The SHA-256 is the one that matters most: it is the value a careful user
/// checks a download against, and a stale digit makes an honest download look
/// tampered with.
///
/// This proves the page COPIES its source faithfully. It does not prove the
/// source is true — a wrong digest written into `CHANGELOG.md` and mirrored
/// correctly passes here. Verifying the artifact is a different job, and
/// `site/install.html` prints the `shasum` command for a reader to do it.
///
/// **Both sides are narrowed to the newest release first.** Sweeping every
/// two-column row in the file into one dictionary works only while exactly one
/// release carries a facts table. The moment 0.1.2 adds its own, the LAST table
/// read would silently win and this guard would compare the wrong release's
/// digest while looking green. Narrowing first is what stops that, and it costs
/// one regex per side.
@Test func theReleaseFactsOnThePageAreTheOnesInTheChangelog() throws {
    let source = try newestReleaseSection(of: try surfaceText("CHANGELOG.md"),
                                          startingAt: "(?m)^##\\s+\\[\\d+\\.\\d+\\.\\d+\\]",
                                          named: "CHANGELOG.md")
    let page = try newestReleaseSection(of: try surfaceText("site/changelog.html"),
                                        startingAt: "<h2[^>]*>\\s*\\d+\\.\\d+\\.\\d+\\s*[\u{2014}\u{2013}-]",
                                        named: "site/changelog.html")

    var fromMarkdown: [String: String] = [:]
    for m in try matches("(?m)^\\|\\s*([^|\\n]+?)\\s*\\|\\s*([^|\\n]+?)\\s*\\|\\s*$", in: source) {
        fromMarkdown[plainValue(m[1])] = plainValue(m[2])
    }

    // Parsed from the table cells, not grepped out of the raw HTML. A regex over
    // the page for the digest itself would find it wherever it appeared and
    // would not notice it had left the table.
    var fromPage: [String: String] = [:]
    for m in try matches("<tr><th scope=\"row\">([\\s\\S]*?)</th><td>([\\s\\S]*?)</td></tr>", in: page) {
        fromPage[plainValue(m[1])] = plainValue(m[2])
    }

    // Anti-vacuity. Without this, a selector that matched nothing would leave
    // both dictionaries empty, every comparison below would be skipped, and the
    // guard would report that the mirror is perfect.
    let inMarkdown = releaseFacts.filter { fromMarkdown[$0] != nil }
    let inPage = releaseFacts.filter { fromPage[$0] != nil }
    #expect(inMarkdown.count == releaseFacts.count,
            "found \(inMarkdown.count) of the \(releaseFacts.count) release-fact rows in CHANGELOG.md: \(inMarkdown)")
    #expect(inPage.count == releaseFacts.count,
            "found \(inPage.count) of the \(releaseFacts.count) release-fact rows on site/changelog.html: \(inPage)")

    for fact in releaseFacts {
        guard let stated = fromMarkdown[fact], let mirrored = fromPage[fact] else { continue }
        #expect(stated == mirrored,
                "the \(fact) row reads \"\(stated)\" in CHANGELOG.md and \"\(mirrored)\" on site/changelog.html")
    }
}

// MARK: - Guard 4c: the duplicated footer cannot drift

/// The footer is byte-identical on every page.
///
/// Guard 4a makes this argument for the sidebar. The footer has the same shape
/// and the same failure: no build step, no template, one copy per page edited by
/// hand. It went unguarded until the terms and privacy pages took the count from
/// four footers to six.
///
/// Unlike the sidebar, nothing is stripped before comparing. The footer carries
/// no per-page attribute, so every byte must match.
///
/// **What this cannot do.** It proves the six footers agree. It does not prove
/// they are right. Six identical footers all linking to a deleted page pass.
@Test func everyPageCarriesTheSameFooter() throws {
    let pages = discoveredSitePages()
    #expect(pages.count >= 4,
            "discovery found \(pages.count) page(s) under site/; comparing fewer than two footers proves nothing")

    var footers: [(page: String, block: String)] = []
    for page in pages {
        let found = try matches("<footer[\\s\\S]*?</footer>", in: try surfaceText(page))
        #expect(found.count == 1,
                "\(page) has \(found.count) footer blocks; every page carries exactly one")
        guard let block = found.first?[0] else { continue }
        footers.append((page, block))
    }

    #expect(footers.count == pages.count,
            "read a footer from \(footers.count) of \(pages.count) pages; a page with no footer is a page this guard skipped")

    guard let reference = footers.first else { return }
    for entry in footers.dropFirst() {
        #expect(entry.block == reference.block,
                "the footer on \(entry.page) differs from the one on \(reference.page). First difference, \(reference.page) then \(entry.page), \(firstDifference(reference.block, entry.block))")
    }
}
