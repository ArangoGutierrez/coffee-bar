// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoffeeBarCore
import CoffeeBarPower

let arguments = Array(CommandLine.arguments.dropFirst())
let wantsJSON = arguments.contains("--json")
let verb = arguments.first(where: { !$0.hasPrefix("--") }) ?? "run"

switch verb {
case "run":
    let report = RunCommand.execute()
    if wantsJSON {
        print((try? OutputFormatter.json(report)) ?? "{}")
    } else {
        print(OutputFormatter.human(report))
    }
    // Exit 0 whenever the probe itself ran. A spike reporting `fail` is a
    // finding about the machine, not a probe malfunction, and must not be
    // conflated with one.
    exit(0)

case "arm", "report", "revert", "watchdog":
    FileHandle.standardError.write(Data(
        "coffee-bar-probe: '\(verb)' lands in Task 11\n".utf8))
    exit(64)

default:
    FileHandle.standardError.write(Data("""
    usage: coffee-bar-probe <verb> [--json]
      run       unprivileged spikes (default)
      arm       set SleepDisabled with a TTL watchdog (root)
      report    read an armed run's samples and verdict
      revert    developer escape hatch: revert and uninstall (root)

    """.utf8))
    exit(64)
}
