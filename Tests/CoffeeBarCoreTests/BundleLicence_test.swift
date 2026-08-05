// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation

/// Guards the PRECONDITION of the bundle copy, not the copy itself.
///
/// **What this cannot do, stated so nobody over-trusts it.** It does not run
/// `scripts/build-app.sh` and it never looks inside a built bundle. Running a
/// release build inside the unit suite would add minutes to every run for one
/// assertion. The runtime check lives in the script, where it aborts the build,
/// and the acceptance step for this task is a real build with pasted output.
///
/// What it DOES catch is the failure that would make the script's own check
/// vacuous: `LICENSE` going missing, being emptied, or being replaced by a
/// different licence while the panel and the site still say Apache-2.0.

private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarCoreTests/BundleLicence_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarCoreTests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // the package root
}

@Test func theRepositoryShipsTheLicenceTheBundleCopyDependsOn() throws {
    // Named bug: `build-app.sh` copies a file that is missing or empty, and the
    // DMG ships with no licence while every surface claims Apache-2.0.
    let licence = try String(contentsOf: packageRoot.appending(path: "LICENSE"),
                             encoding: .utf8)
    #expect(licence.contains("Apache License"),
            "LICENSE does not name the Apache License; the bundle copy would ship the wrong text")
    #expect(licence.contains("Version 2.0"),
            "LICENSE does not name Version 2.0; the bundle copy would ship the wrong version")
    #expect(licence.count > 10_000,
            "LICENSE is \(licence.count) bytes; the full Apache-2.0 text is about 11kB, so this file is truncated")
}

@Test func theBuildScriptCopiesTheLicenceAndChecksItArrived() throws {
    // Named bug: the copy line is removed in a refactor, or is written without
    // the arrival check, so a failed `cp` leaves a bundle with no licence and
    // the script still exits 0. `rules/shell-conventions.md` records that `cp`
    // returns 0 while doing nothing useful.
    let script = try String(contentsOf: packageRoot.appending(path: "scripts/build-app.sh"),
                            encoding: .utf8)
    #expect(script.contains("${REPO_ROOT}/LICENSE"),
            "build-app.sh no longer reads LICENSE from the repository root")
    #expect(script.contains("${CONTENTS}/Resources/LICENSE"),
            "build-app.sh no longer writes LICENSE into the bundle")
    #expect(script.contains("[ -s \"${CONTENTS}/Resources/LICENSE\" ]"),
            "build-app.sh copies LICENSE without checking it arrived and is non-empty")
}
