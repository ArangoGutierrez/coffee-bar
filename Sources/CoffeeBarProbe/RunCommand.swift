// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoffeeBarCore
import CoffeeBarPower

enum RunCommand {
    /// Runs every unprivileged spike against this process.
    ///
    /// The assembly itself is `CoffeeBarPower.ProbeRun` so that the test
    /// target can reach it; nothing but the choice of measurement target
    /// belongs to the CLI.
    ///
    /// That choice is the whole content of this type and it is not reachable
    /// from any in-process test — an executable target cannot be imported.
    /// `nil` here would still compile, still exit 0, and make the shipped
    /// probe report S3 and S5 `notApplicable` forever, because every
    /// in-process test passes `nil` on purpose. `ProbeBinary_test.swift` runs
    /// this binary and asserts neither row comes back `notApplicable`.
    static func execute() -> ProbeReport {
        ProbeRun.report(targetPID: getpid())
    }
}
