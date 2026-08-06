// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin
import CoffeeBarPower

// A demoter that can be killed.
//
// `ProcGovernorCrashRecovery_test.swift` has to prove that a demotion applied by
// the real `ProcGovernor` outlives a `SIGKILL` on whatever applied it, and that
// a later run reads the journal back and undoes it. A SIGKILL cannot be caught,
// blocked or handled, so the demoter has to be a SEPARATE process: running the
// governor inside the test process and skipping the kill would exercise
// everything except the thing that check exists for.
//
// **A target and NOT a product.** `scripts/build-app.sh` builds
// `--product coffee-bar`, so nothing here reaches a release. It exists so the
// acceptance criterion is measured rather than argued.
//
// It is also not a general demotion tool. It applies the real `DemotionPolicy`,
// so every protected-set rule stops it exactly as it stops the app, and it moves
// only the single pid it is given.
//
// Usage:
//
//     coffee-bar-governor-harness <pid> <journal-path> <demotable-name> <report-path> [agent|frontmost]
//
// It writes one word to `<report-path>` — `demoted`, `refused(<rule>)`, or an
// error — and then blocks for ever, holding the demotion in place so the caller
// can kill it mid-flight.

let arguments = CommandLine.arguments
guard arguments.count >= 5, let target = pid_t(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: <pid> <journal> <name> <report> [agent|frontmost]\n".utf8))
    exit(2)
}
let journalURL = URL(fileURLWithPath: arguments[2])
let demotableName = arguments[3]
let reportPath = arguments[4]
let extraRule = arguments.count > 5 ? arguments[5] : ""

func report(_ text: String) {
    try? Data(text.utf8).write(to: URL(fileURLWithPath: reportPath))
}

// The composition root, in miniature. Every deny rule that depends on live state
// is read here and passed down: the policy itself stays pure and takes values,
// which is what lets it be checked against processes no suite could create.
let inspector = SystemProcessInspector()
let policy = DemotionPolicy(
    demotableNames: [demotableName],
    agentPIDs: extraRule == "agent" ? [target] : [],
    frontmostPID: extraRule == "frontmost" ? target : nil,
    selfPID: getpid(),
    selfUID: getuid(),
    selfPGID: pid_t(getpgrp()),
    ancestorPIDs: inspector.ancestors(of: getpid()))

let governor = ProcGovernor(
    policy: policy,
    journal: FileDemotionJournalStore(url: journalURL),
    inspector: inspector,
    setter: SystemDarwinBackground())

do {
    try governor.demote(target)
    report("demoted")
} catch let error as ProcGovernorError {
    switch error {
    case .refused(let rule): report("refused(\(rule.rawValue))")
    case .vanished(let pid): report("vanished(\(pid))")
    case .unidentifiable(let pid): report("unidentifiable(\(pid))")
    case .setBackgroundFailed(let pid, let code): report("failed(\(pid),\(code))")
    }
    exit(0)
} catch {
    report("error(\(error))")
    exit(1)
}

// Hold the demotion in place. The caller kills this process here, which is the
// crash the whole design answers: no cleanup runs, and the victim stays demoted
// with only the journal to say so.
while true { pause() }
