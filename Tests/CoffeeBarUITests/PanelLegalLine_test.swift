// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarUI

/// Asserts the seam the panel renders, not the drawn text.
///
/// M1 design §5.4 forbids asserting on rendered AppKit text, so a sentence
/// composed inline in `body` is a sentence no check reads. `PanelVersionLine_test`
/// makes the same argument for the version line.

private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarUITests/PanelLegalLine_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarUITests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // the package root
}

@Test func thePanelNamesTheLicenceTheRepositoryActuallyShips() throws {
    // Named bug: the panel keeps saying Apache-2.0 after the project relicenses.
    // That is a false legal claim displayed inside the product, and the two
    // facts live in different files, so nothing else would notice.
    let licence = try String(contentsOf: packageRoot.appending(path: "LICENSE"),
                             encoding: .utf8)
    #expect(licence.contains("Apache License") && licence.contains("Version 2.0"),
            "LICENSE is not Apache-2.0, so the panel line is a false claim")
    #expect(PanelView.legalLine().contains("Apache-2.0"),
            "the panel no longer names the licence the repository ships")
}

@Test func thePanelSaysThereIsNoWarranty() {
    // Named bug: the line is shortened to just the licence name to fit the
    // 260pt panel. The licence name alone tells a user nothing; "no warranty"
    // is the part that sets an expectation.
    #expect(PanelView.legalLine().contains("no warranty"))
}

@Test func theLegalLinkPointsAtThePublishedTermsPage() {
    // Named bug: a typo in the URL, or a link left pointing at the repository
    // root, so the one route from the product to its terms is dead.
    #expect(PanelView.legalURL().absoluteString
            == "https://arangogutierrez.github.io/coffee-bar/terms.html")
}

@Test func theTermsPageTheLinkPromisesExistsInThisRepository() {
    // Named bug: the link ships before the page does, or the page is renamed
    // and the panel is not updated. The site is served from `site/`, so the
    // last path component must be a file there.
    let file = PanelView.legalURL().lastPathComponent
    #expect(FileManager.default.fileExists(
        atPath: packageRoot.appending(path: "site/\(file)").path),
        "the panel links to \(file), which does not exist under site/")
}
