// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import CoffeeBarTestSupport
@testable import CoffeeBarUI

/// The view draws the name `CoffeeBarCore` decided, and no longer `repoName`.
///
/// M1 design §5.4 forbids asserting on rendered AppKit text, so what the row
/// SAYS is asserted in `Tests/CoffeeBarCoreTests/SessionLabel_test.swift`,
/// where a check can read it. This file is the other half of that pair, the
/// route `PanelLegalLine_test.swift` and `AppLayerBoundary_test.swift` already
/// take: a decision with no reader is not a fix, so these guards read
/// `AttentionListView.swift` as SOURCE and fail if the view stops applying it.
///
/// CODE, never the raw file. The doc comment at the head of the view explains
/// the defect and names `repoName` while doing it, so a raw read cannot tell a
/// live call from a note about one.

private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarUITests/AttentionListRowName_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarUITests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // the package root
}

private func attentionListCode() throws -> String {
    let path = packageRoot.appending(path: "Sources/CoffeeBarUI/AttentionListView.swift")
    #expect(FileManager.default.fileExists(atPath: path.path),
            "the app layer no longer compiles an AttentionListView.swift at \(path.path)")
    return swiftCodeWithoutComments(try String(contentsOf: path, encoding: .utf8))
}

@Test func theWaitingRowDrawsTheNameTheCoreLayerDecided() throws {
    // Named bug, and it is the defect this change exists for: the row drew
    // `cwd.lastPathComponent` under the name `repoName`, so a session in
    // …/coffee-bar/.worktrees/release-v020 read "release-v020" and two sessions
    // in the same checkout both read "stayconnected".
    let code = try attentionListCode()

    #expect(code.contains("SessionLabel.rowNames(for: sessions)"), """
        AttentionListView.swift never asks SessionLabel for the row names in \
        code, so whatever SessionLabel decides reaches nobody. A comment naming \
        it does not satisfy this.
        """)

    #expect(!code.contains("session.repoName"), """
        AttentionListView.swift still draws session.repoName, which is the \
        basename of whatever directory the session runs in and is not the \
        repository's name. That is the defect.
        """)
}

@Test func theRowNameIsDerivedOncePerListAndNotOncePerRow() throws {
    // Cross-row context is what makes the tie-break possible, so the names have
    // to be computed for the WHOLE list and then read per row. Named bug: the
    // lookup is moved inside `ForEach`, rebuilding the dictionary — and with it
    // every collision decision — once per row, at O(n²), for an answer that is
    // the same every time.
    let code = try attentionListCode()

    let rows = try #require(braceBlock(after: "ForEach(sessions)", in: code)?.block, """
        AttentionListView.swift names no ForEach(sessions) opening a balanced \
        block, so this guard cannot tell what a row draws.
        """)

    #expect(!rows.contains("SessionLabel."), """
        the ForEach block in AttentionListView.swift derives names per ROW; the \
        list-wide derivation that tells two identical rows apart cannot be done \
        one row at a time.
        """)
}

@Test func theRowStillFallsBackToTheSessionIDInTheView() throws {
    // The property `AttentionListView` documents and issue-driving comment at
    // the row calls out: a row with no name at all is a row the user cannot act
    // on. `SessionLabel` already falls back for a session it is handed, and
    // this is the second half — a lookup miss must not draw an empty line.
    let code = try attentionListCode()

    let rows = try #require(braceBlock(after: "ForEach(sessions)", in: code)?.block)
    #expect(rows.contains("?? session.sessionID"), """
        the row in AttentionListView.swift no longer falls back to \
        session.sessionID, so a name the derivation does not carry draws an \
        empty first line.
        """)
}
