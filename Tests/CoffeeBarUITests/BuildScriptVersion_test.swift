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

    // Slice out the ASSIGNMENT and assert against that line alone. A
    // whole-file `contains` asks only whether the right text appears
    // SOMEWHERE, which two edits satisfy without stamping anything:
    //
    //   VERSION_RAW="$(git rev-parse --short HEAD)"
    //   VERSION="${VERSION_RAW#v}"  # was: git -C "${REPO_ROOT}" describe --tags --dirty
    //
    // That version stamp has fully regressed, yet all three assertions below
    // passed against the whole file. Dropping comment LINES did not help: the
    // second line is code, so its trailing comment survived the filter. There
    // is no comment strip here now because the assignment is a code line and
    // carries no leading `#` — the slice does the work the filter was doing.
    let assignment = script.split(separator: "\n")
        .first { $0.hasPrefix("VERSION_RAW=") }
        .map(String.init) ?? ""

    #expect(!assignment.isEmpty, "build-app.sh must assign VERSION_RAW")

    // The bug this catches: `--abbrev=0` prints the bare tag and drops the
    // commit distance, so a build 16 commits past v0.1.1 displayed
    // "Version 0.1.1". A maintainer reading that line on someone else's machine
    // is told a released build is running when it is not.
    #expect(!assignment.contains("--abbrev=0"),
            "git describe --abbrev=0 makes every descendant of a tag claim to BE that tag")

    #expect(assignment.contains("git -C \"${REPO_ROOT}\" describe --tags"),
            "the version must still come from git describe: \(assignment)")

    // `--dirty` is the other half of the fix and needs its own check: a build
    // from modified sources is not the commit it names.
    #expect(assignment.contains("describe --tags --dirty"),
            "--dirty must mark a build made from an uncommitted tree: \(assignment)")
}
