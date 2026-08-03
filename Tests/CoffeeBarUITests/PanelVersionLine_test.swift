// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import CoffeeBarUI

/// The panel has to SHOW which build is running, not merely be able to compute
/// it.
///
/// `AppVersion.display(from:)` landed with its own checks and every one of them
/// was green, yet the maintainer still reported "I still don't see the version
/// on the current installed coffee-bar". The value existed and no view read it,
/// which is the same shipped failure as commit 5116326 and the hook advisory: a
/// published value no view reads is a feature that does not exist.
///
/// These checks assert `PanelView.versionLine(from:)` — the seam the panel
/// renders — rather than the drawn text. M1 design §5.4 forbids asserting on
/// rendered AppKit text, so a sentence composed inline in `body` would be a
/// sentence no check reads. Composing it here makes the wiring load-bearing:
/// replace the `AppVersion.display(...)` call with any literal and all three
/// checks below go red.

@Test func theVersionLineCarriesTheStampTheBuildScriptWrote() {
    // Named bug: rendering a placeholder, a hard-coded number, or the marketing
    // version instead of the stamp `scripts/build-app.sh` wrote. That reports a
    // build that is not running, which design calls worse than reporting
    // nothing.
    #expect(PanelView.versionLine(from: ["CFBundleShortVersionString": "0.1.0"])
            == "Version 0.1.0")
}

@Test func theVersionLineKeepsTheCommitSoTwoDevBuildsAreTellableApart() {
    // Named bug: shortening the stamp in the view layer to keep the 260pt panel
    // tidy — taking the first dot-component, or cutting at the dash. Every
    // build-from-source would then read "Version HEAD", which is exactly the
    // question this line exists to answer.
    #expect(PanelView.versionLine(from: ["CFBundleShortVersionString": "HEAD-984ff32"])
            == "Version HEAD-984ff32")
}

@Test func theVersionLineSaysUnknownRatherThanTrailingOffBlank() {
    // Named bug: the panel reading `CFBundleShortVersionString` itself and
    // defaulting to "", which draws the line "Version " with nothing after it.
    // That reads as a UI glitch rather than as an answer. Routing through
    // `AppVersion.display(from:)` is what makes both of these say "unknown".
    //
    // `nil` is the live case, not a contrived one: `swift run` outside an app
    // bundle has no info dictionary at all.
    #expect(PanelView.versionLine(from: nil) == "Version unknown")
    #expect(PanelView.versionLine(from: [:]) == "Version unknown")
}
