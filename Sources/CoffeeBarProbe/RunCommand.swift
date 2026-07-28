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
    static func execute() -> ProbeReport {
        ProbeRun.report(targetPID: getpid())
    }
}
