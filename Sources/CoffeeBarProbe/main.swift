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
        // Deliberately not `(try? …) ?? "{}"`. That form printed valid JSON to
        // stdout and exited 0 on an encode failure: an exit-code-only consumer
        // read SUCCESS, and a downstream `jq` read a probe that had found
        // nothing. A failure must not be mistakable for either. stdout stays
        // empty so `jq` gets nothing to parse, the reason goes to stderr, and
        // the exit code carries it to everyone who reads only that.
        do {
            print(try OutputFormatter.json(report))
        } catch {
            FileHandle.standardError.write(Data(
                "coffee-bar-probe: could not encode the report: \(error)\n".utf8))
            // EX_SOFTWARE (sysexits.h): an internal failure. Not EX_USAGE (64),
            // which this binary already uses for an unimplemented verb, and not
            // 0 — the probe produced no report, which is a different thing from
            // a report whose spikes failed.
            exit(70)
        }
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
