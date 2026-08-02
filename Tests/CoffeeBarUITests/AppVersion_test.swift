// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import CoffeeBarUI

/// The panel must be able to answer "which build is this?".
///
/// On 2026-08-01 the only way to learn which build was running on a machine was
/// to diff `Sources/` between the installed keg's SHA and HEAD. `defaults read
/// com.coffeebar.app` reports no domain, the ingest socket answers HTTP 400 to
/// every read path, and nothing was rendered on screen. A maintainer debugging a
/// report had no way to establish what the reporter was running.
///
/// The value already existed — `scripts/build-app.sh` stamps
/// `CFBundleShortVersionString` from `git describe`, falling back to
/// `0.0.0-dev`. It simply was not shown.

@Test func aStampedReleaseVersionIsShownVerbatim() {
    #expect(AppVersion.display(from: ["CFBundleShortVersionString": "0.1.0"]) == "0.1.0")
}

@Test func aHeadBuildKeepsItsCommitSoTwoDevBuildsAreTellableApart() {
    // Named bug: collapsing this to "dev" or "HEAD" would make every
    // build-from-source report identical, which is the exact question this
    // feature exists to answer.
    #expect(AppVersion.display(from: ["CFBundleShortVersionString": "HEAD-984ff32"])
            == "HEAD-984ff32")
}

@Test func anUntaggedBuildSaysSoRatherThanLookingLikeARelease() {
    #expect(AppVersion.display(from: ["CFBundleShortVersionString": "0.0.0-dev"])
            == "0.0.0-dev")
}

@Test func anAbsentKeyReportsUnknownRatherThanInventingAVersion() {
    // Named bug: returning "" renders a blank line that reads as a UI glitch,
    // and returning any number at all would state a build that is not running.
    #expect(AppVersion.display(from: [:]) == "unknown")
}

@Test func anAbsentInfoDictionaryReportsUnknown() {
    // `swift run` outside a bundle has no info dictionary at all.
    #expect(AppVersion.display(from: nil) == "unknown")
}

@Test func aBlankOrWhitespaceStampReportsUnknown() {
    // A stamp that exists but carries nothing is the same failure as an absent
    // one, and it is the shape a broken build script produces.
    #expect(AppVersion.display(from: ["CFBundleShortVersionString": ""]) == "unknown")
    #expect(AppVersion.display(from: ["CFBundleShortVersionString": "   "]) == "unknown")
}

@Test func aNonStringStampReportsUnknownRatherThanCrashing() {
    // A hand-edited Info.plist can put a number here.
    #expect(AppVersion.display(from: ["CFBundleShortVersionString": 3]) == "unknown")
}

@Test func surroundingWhitespaceIsTrimmedSoTheLineCannotDriftInTheLayout() {
    #expect(AppVersion.display(from: ["CFBundleShortVersionString": " 0.1.0\n"]) == "0.1.0")
}
