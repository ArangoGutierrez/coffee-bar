// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

/// Reads `scripts/build-app.sh` as text. `#filePath` anchors the lookup to THIS
/// source file, so the guard cannot green-light a different tree.
private func buildScript() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CoffeeBarUITests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
    return try String(
        contentsOf: root.appendingPathComponent("scripts/build-app.sh"),
        encoding: .utf8)
}

@Test("the version stamp distinguishes a dev build from the release it descends from")
func versionStampCarriesCommitDistance() throws {
    let script = try buildScript()

    // Comment lines come out first, so this reads what the script DOES rather
    // than what it says about itself. The comment above the assignment names
    // `--abbrev=0` to record why the flag is gone; a whole-file `contains`
    // reads that prose as the flag and can never go green.
    let code = script
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        .joined(separator: "\n")

    // The bug this catches: `--abbrev=0` prints the bare tag and drops the
    // commit distance, so a build 16 commits past v0.1.1 displayed
    // "Version 0.1.1". A maintainer reading that line on someone else's machine
    // is told a released build is running when it is not.
    #expect(!code.contains("--abbrev=0"),
            "git describe --abbrev=0 makes every descendant of a tag claim to BE that tag")

    #expect(code.contains("git -C \"${REPO_ROOT}\" describe --tags"),
            "the version must still come from git describe")

    // `--dirty` is the other half of the fix and needs its own check: a build
    // from modified sources is not the commit it names.
    #expect(code.contains("describe --tags --dirty"),
            "--dirty must mark a build made from an uncommitted tree")
}
