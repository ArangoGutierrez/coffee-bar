// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

/// What one waiting row is CALLED.
///
/// The defect, observed twice in the maintainer's own menu bar. The row drew
/// `cwd.lastPathComponent` under the name `repoName`, so:
///
///   * a session working in `…/coffee-bar/.worktrees/release-v020` read
///     "release-v020" — a worktree named after a release two versions old, and
///     nothing a reader can act on;
///   * "stayconnected" appeared TWICE in the same list, two different sessions
///     drawing the identical row.
///
/// Every expectation below is an EXACT string. A `contains` check would pass
/// over "release-v020" for a row meant to read "coffee-bar [release-v020]",
/// which is the defect itself, and would pass over two identical rows for the
/// collision case, which is the other half of it.
///
/// The derivation is PURE STRING PARSING and opens nothing.
/// `AppLayerBoundary_test.theCoreLayerReadsNoFilesAtAll` is the guard that
/// holds it, and it is why this cannot ask git where the repository root is:
/// `CoffeeBarCore` performs no I/O, which is exactly why `lastPathComponent`
/// was reached for in the first place.

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func session(_ tool: AgentTool = .claudeCode,
                     id: String,
                     cwd: String?) -> AgentSession {
    let url = cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }
    return AgentSession(
        tool: tool, sessionID: id, cwd: url,
        // Deliberately the OLD field, carrying the OLD value. Nothing the row
        // draws may read it: leaving it populated here means a row that still
        // reads `repoName` renders "release-v020" and fails loudly, rather than
        // rendering nil and failing for the wrong reason.
        repoName: url?.lastPathComponent,
        pid: nil, state: .awaitingInput, stateEnteredAt: t0, lastEventAt: t0,
        lastMessage: nil, attentionSince: t0, turnCount: 1)
}

// MARK: - Naming the repository from a path alone

private struct PathCase {
    let path: String
    let expected: String?
    let why: String
}

/// One row per layout, each with the bug it catches.
///
/// Every marker `SessionLabel` knows has a row here, and
/// `everyMarkerTheParserKnowsHasARowProvingWhatItDraws` is what holds that: a
/// marker added to the parser with nothing here saying what it draws turns
/// that test red. The expectations stay literals, so the table never asserts
/// the parser against itself.
///
/// The rows marked LIMIT are STATED limits rather than wishes. Four of them
/// assert a value that is not what a human would ideally read, and they are
/// here so the limit is a decision somebody signed rather than a surprise in
/// the menu bar.
private let pathCases: [PathCase] = [
    PathCase(path: "/Users/carlos/src/coffee-bar",
             expected: "coffee-bar",
             why: "a plain checkout must still read as its own directory name"),

    PathCase(path: "/Users/carlos/src/coffee-bar/",
             expected: "coffee-bar",
             why: """
                SessionHub builds the URL with isDirectory: true, so a trailing \
                slash reaches this function; splitting on it must not leave an \
                empty last component
                """),

    PathCase(path: "/Users/carlos/src/coffee-bar/.worktrees/release-v020",
             expected: "coffee-bar [release-v020]",
             why: "the observed defect: the row read release-v020 and named no repository"),

    PathCase(path: "/Users/carlos/src/coffee-bar/.wt/hotfix-101",
             expected: "coffee-bar [hotfix-101]",
             why: ".wt is the sibling convention in the maintainer's toolkit"),

    PathCase(path: "/Users/carlos/src/stayconnected/.claude/worktrees/w3",
             expected: "stayconnected [w3]",
             why: """
                THE observed defect. src/stayconnected keeps its worktrees \
                under .claude/worktrees/, so every session in it drew the leaf \
                — which is how "stayconnected" came to appear twice in one panel
                """),

    PathCase(path: "/Users/carlos/src/coffee-bar/.claude/worktrees/wf_2f1a",
             expected: "coffee-bar [wf_2f1a]",
             why: """
                a two-component marker: .claude is not a marker on its own and \
                the pair .claude/worktrees is
                """),

    PathCase(path: "/Users/carlos/src/colombia/.orchestrate/worktrees/task-7",
             expected: "colombia [task-7]",
             why: "the second two-component marker, measured on this machine"),

    PathCase(path: "/Users/carlos/src/coffee-bar/.worktrees/release-v020/Sources/CoffeeBarUI",
             expected: "coffee-bar [release-v020]",
             why: """
                an agent started BELOW the worktree root would otherwise read \
                CoffeeBarUI, which names neither the repository nor the worktree
                """),

    PathCase(path: "/Users/carlos/src/stayconnected/.claude/worktrees/w3/apps/web",
             expected: "stayconnected [w3]",
             why: """
                the same, one marker component longer: the qualifier is the \
                component after the WHOLE marker, not after its first
                """),

    PathCase(path: "/Users/carlos/src/coffee-bar/.worktrees",
             expected: "coffee-bar",
             why: "the marker directory itself is not a name; the repository is"),

    PathCase(path: "/Users/carlos/src/stayconnected/.claude/worktrees",
             expected: "stayconnected",
             why: "the same boundary for a two-component marker, one component further out"),

    PathCase(path: "/Users/carlos/src/coffee-bar/.claude/hooks",
             expected: "hooks",
             why: """
                the discriminating row: .claude alone is NOT a marker. Matching \
                only a marker's first component would read this as \
                "coffee-bar [hooks]" and rename half the dot-directories on the \
                machine into worktrees
                """),

    PathCase(path: "/.worktrees/orphan",
             expected: "orphan",
             why: "a marker with nothing before it names no repository, so the leaf stands"),

    PathCase(path: "/",
             expected: nil,
             why: """
                the root directory carries no name at all, so the row has to \
                fall back to the session id rather than draw an empty line
                """),

    // The three stated LIMITS.
    PathCase(path: "/Users/carlos/src/coffee-bar/Sources",
             expected: "Sources",
             why: """
                LIMIT: with no filesystem access a subdirectory of a repository \
                is indistinguishable from a repository, so the leaf stands
                """),

    PathCase(path: "/Users/carlos/src/coffee-bar-release-v020",
             expected: "coffee-bar-release-v020",
             why: """
                LIMIT: a worktree checked out as a plain sibling directory \
                (git worktree add ../name) carries no marker and cannot be seen
                """),

    PathCase(path: "/Users/carlos/.claude/worktrees/wf_2f1a",
             expected: "carlos [wf_2f1a]",
             why: """
                LIMIT, and it is a real directory on this machine: what a \
                marker names is whatever CONTAINS it, and here that is a home \
                directory rather than a checkout. No I/O may confirm otherwise
                """),

    PathCase(path: "/Users/carlos/.codex/.worktrees/w1",
             expected: ".codex [w1]",
             why: """
                LIMIT, the same shape one convention over: .codex/.worktrees/ \
                puts the marker inside a tool directory, so the tool directory \
                is what gets named
                """),
]

@Test func theRowNamesTheRepositoryAndQualifiesTheWorktree() {
    for testCase in pathCases {
        let got = SessionLabel.repositoryLabel(
            for: URL(fileURLWithPath: testCase.path, isDirectory: true))
        #expect(got == testCase.expected, """
            \(testCase.path) named \(got.map { "\"\($0)\"" } ?? "nothing") \
            rather than \(testCase.expected.map { "\"\($0)\"" } ?? "nothing"). \
            \(testCase.why)
            """)
    }
}

@Test func everyMarkerTheParserKnowsHasARowProvingWhatItDraws() {
    // A table this long is easy to gut by deleting rows, and a shorter table
    // still passes — and a marker ADDED to the parser with no row here would
    // ship a layout nothing says the wording of.
    //
    // This reads `SessionLabel.worktreeMarkers` rather than restating it, and
    // that is deliberate: the assertion is COVERAGE, not behaviour. What each
    // layout draws is asserted against literals in the table above, so the
    // parser is never held against itself. A count would say neither thing and
    // would go stale the first time a row was added.
    for marker in SessionLabel.worktreeMarkers {
        let segment = "/" + marker.joined(separator: "/") + "/"
        #expect(pathCases.contains { $0.path.contains(segment) }, """
            SessionLabel detects \(segment) and no row in this table says what \
            it draws, so the wording of that layout is shipped unasserted.
            """)
    }

    // A loop over an empty collection asserts nothing at all.
    #expect(!SessionLabel.worktreeMarkers.isEmpty,
            "the parser knows no markers, so the loop above checked nothing")

    // The fallback case, which no marker names.
    #expect(pathCases.contains { $0.expected == nil },
            "no row exercises a path that names nothing, so the fallback is unpinned")
}

// MARK: - Which tool the row belongs to

@Test func everyToolHasItsOwnShortLowercaseLabel() {
    // Named bug: the label is spelled at the call site, so the panel says
    // "claudeCode" in one place and "Claude Code" in another, and adding a tool
    // means finding every spelling. `AgentTool.displayName` is the one owner.
    #expect(AgentTool.allCases.map(\.displayName) == ["claude", "codex", "cursor"])

    // Distinct, because the label is the only thing separating two rows in the
    // same repository, and lowercase because it sits in 10pt caption text
    // beside a repository name that is already lowercase.
    #expect(Set(AgentTool.allCases.map(\.displayName)).count == AgentTool.allCases.count)
    for name in AgentTool.allCases.map(\.displayName) {
        #expect(name == name.lowercased(), "\(name) is not lowercase")
        #expect(!name.contains(" "), "\(name) carries a space; the row is 260pt wide")
    }
}

@Test func theRowSaysWhichToolItBelongsTo() {
    // Named bug: two agents working in the same checkout draw the identical
    // row, which is half of the observed "stayconnected twice". The tool is
    // known for certain — it is decided by the endpoint the hook posted to —
    // and it was simply never displayed.
    #expect(SessionLabel.rowName(for: session(.claudeCode, id: "s1",
                                              cwd: "/Users/carlos/src/coffee-bar"))
            == "claude · coffee-bar")
    #expect(SessionLabel.rowName(for: session(.codex, id: "s2",
                                              cwd: "/Users/carlos/src/coffee-bar"))
            == "codex · coffee-bar")
    #expect(SessionLabel.rowName(for: session(.cursor, id: "s3",
                                              cwd: "/Users/carlos/src/coffee-bar"))
            == "cursor · coffee-bar")
    #expect(SessionLabel.rowName(for: session(.claudeCode, id: "s4",
                                              cwd: "/Users/carlos/src/coffee-bar/.worktrees/release-v020"))
            == "claude · coffee-bar [release-v020]")
}

// MARK: - The fallback, which is load-bearing

@Test func aSessionWithNoWorkingDirectoryStillNamesItsSessionID() {
    // The property `AttentionListView` documents and must keep: a row with no
    // name at all is a row the user cannot act on. Every recorded payload
    // carries `cwd`, but the decoder allows it to be absent, so this path is
    // reachable from the wire.
    #expect(SessionLabel.rowName(for: session(.claudeCode,
                                              id: "8c1d0e2f-4b6a-4f21-9d55-0a1b2c3d4e5f",
                                              cwd: nil))
            == "claude · 8c1d0e2f-4b6a-4f21-9d55-0a1b2c3d4e5f")
}

@Test func aWorkingDirectoryThatNamesNothingFallsBackTheSameWay() {
    // A `cwd` of "/" decodes fine and carries no name. The fallback has to be
    // the same one, or the row draws an empty line.
    #expect(SessionLabel.rowName(for: session(.codex, id: "root-session", cwd: "/"))
            == "codex · root-session")
}

// MARK: - Two rows that would read the same

@Test func twoRowsThatWouldReadTheSameAreToldApartByTheirSessionID() {
    // The observed defect's other half: "stayconnected" appeared twice in the
    // same list, two different sessions, no way to tell them apart.
    //
    // Cross-row context, so it cannot live in `rowName(for:)` — that function
    // sees one session and could only disambiguate by always appending an id,
    // which `aRowThatIsAlreadyUniqueCarriesNoSessionID` refuses.
    let first = session(.claudeCode, id: "a1b2c3d4-1111-4f21-9d55-0a1b2c3d4e5f",
                        cwd: "/Users/carlos/src/stayconnected")
    let second = session(.claudeCode, id: "9f8e7d6c-2222-4f21-9d55-0a1b2c3d4e5f",
                         cwd: "/Users/carlos/src/stayconnected")

    let names = SessionLabel.rowNames(for: [first, second])

    #expect(names[first.id] == "claude · stayconnected (a1b2c3d4)")
    #expect(names[second.id] == "claude · stayconnected (9f8e7d6c)")
    #expect(names[first.id] != names[second.id])
}

@Test func aRowThatIsAlreadyUniqueCarriesNoSessionID() {
    // The discriminating half. Appending the id to EVERY row would satisfy the
    // collision check above while spending a third of a 260pt row on a UUID
    // nobody needs to read. The suffix appears only where it settles something.
    //
    // The middle pair also pins that the tool label alone separates two rows in
    // the same checkout: neither may pick up a suffix.
    let alone = session(.claudeCode, id: "1111aaaa-0000-4f21-9d55-0a1b2c3d4e5f",
                        cwd: "/Users/carlos/src/coffee-bar")
    let otherTool = session(.codex, id: "2222bbbb-0000-4f21-9d55-0a1b2c3d4e5f",
                            cwd: "/Users/carlos/src/coffee-bar")
    let otherRepo = session(.claudeCode, id: "3333cccc-0000-4f21-9d55-0a1b2c3d4e5f",
                            cwd: "/Users/carlos/src/stayconnected")

    let names = SessionLabel.rowNames(for: [alone, otherTool, otherRepo])

    #expect(names[alone.id] == "claude · coffee-bar")
    #expect(names[otherTool.id] == "codex · coffee-bar")
    #expect(names[otherRepo.id] == "claude · stayconnected")
    #expect(names.count == 3, "every row handed in must come back with a name")
}

@Test func theShortIDGrowsUntilItActuallySeparatesTheRows() {
    // Named bug: a FIXED eight characters, which is the obvious first cut and
    // which draws two identical rows again the moment two ids share a prefix.
    // Codex and Cursor session ids are not all UUIDs, so this is not a
    // hypothetical about UUID collisions.
    //
    // The two ids below first differ at index 10, so eleven characters is the
    // shortest prefix that separates them — and the whole id, which would also
    // separate them, is refused here as too long to read.
    let first = session(.claudeCode, id: "aaaaaaaaaa1zzzz",
                        cwd: "/Users/carlos/src/twin")
    let second = session(.claudeCode, id: "aaaaaaaaaa2zzzz",
                         cwd: "/Users/carlos/src/twin")

    let names = SessionLabel.rowNames(for: [first, second])

    #expect(names[first.id] == "claude · twin (aaaaaaaaaa1)")
    #expect(names[second.id] == "claude · twin (aaaaaaaaaa2)")
}

@Test func anEmptyListNamesNothing() {
    #expect(SessionLabel.rowNames(for: []).isEmpty)
}
