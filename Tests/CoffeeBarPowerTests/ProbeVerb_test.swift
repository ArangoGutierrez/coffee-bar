// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarPower

// The shipped `--help` defect, and the guard that stops it coming back.
//
// At 389f10e `Sources/CoffeeBarProbe/main.swift` handled four privileged verbs
// in one `case` — `arm`, `report`, `revert`, `watchdog` — while its usage text
// advertised only three. `watchdog` was reachable and undocumented, and each of
// the three advertised ones told a v0.1 user to run `sudo` for a stub that
// exited 64.
//
// A usage string and a `switch` are two lists of the same thing, so they drift.
// The fix is to stop having two: `ProbeVerb.allCases` is the list, the usage
// text is BUILT from it, and `main.swift` switches over the enum with no
// `default`, which makes a missing verb a compile error rather than a silent
// omission. These tests pin the half the compiler cannot see.

@Test func theUsageTextAdvertisesEveryVerbTheBinaryHandles() {
    // Named bug this catches, and it SHIPPED in v0.1: `watchdog` handled and
    // unadvertised. A user reading `--help` cannot find a verb that exists.
    for verb in ProbeVerb.allCases {
        #expect(ProbeVerb.usage.contains(verb.rawValue), """
            the usage text never names "\(verb.rawValue)", which the binary \
            handles. That is the v0.1 defect exactly.
            usage:
            \(ProbeVerb.usage)
            """)
    }
}

@Test func theUsageTextAdvertisesNothingTheBinaryCannotHandle() {
    // The other direction, which the check above cannot see: a verb advertised
    // and NOT handled sends the user to run a command that exits 64. Both
    // directions are needed — v0.1 was wrong one way, and a hand-edited usage
    // string is just as easily wrong the other.
    let advertised = ProbeVerb.usage
        .split(separator: "\n")
        // The verb rows are the indented ones; the "usage:" banner is not.
        .filter { $0.hasPrefix("  ") }
        .compactMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) }

    #expect(advertised.isEmpty == false,
            "no verb rows were parsed out of the usage text, so this check read nothing")

    for token in advertised {
        #expect(ProbeVerb(rawValue: token) != nil, """
            the usage text advertises "\(token)", which is not a verb the \
            binary handles. Running it exits 64.
            """)
    }

    // Both lists are the same SET, not merely overlapping. A row parsed twice,
    // or a verb listed twice and another dropped, passes both loops above.
    #expect(Set(advertised) == Set(ProbeVerb.allCases.map(\.rawValue)))
}

@Test func everyVerbCarriesItsOwnSummaryLine() {
    // A usage text is only truthful if each row says what the verb does. An
    // empty or duplicated summary is how a generated list degenerates into
    // five identical rows that technically name every verb.
    let summaries = ProbeVerb.allCases.map(\.summary)

    for (verb, summary) in zip(ProbeVerb.allCases, summaries) {
        #expect(summary.isEmpty == false, "\(verb.rawValue) has no summary")
    }
    #expect(Set(summaries).count == ProbeVerb.allCases.count,
            "two verbs share a summary line: \(summaries)")
}

@Test func theVerbsRequiringRootSaySoAndTheOthersDoNot() {
    // A user deciding whether to prefix `sudo` reads this and nothing else, so
    // the answer is per-verb rather than a blanket warning.
    //
    // `arm`, `revert` and `watchdog` mutate or supervise a system power
    // setting. `report` is privileged for a less obvious reason: the journal it
    // prints is root-owned and 0600, so an unprivileged read cannot open it.
    //
    // Named bug this catches: `run` acquiring a root marker, which would train
    // a user to run the one safe verb as root for no reason at all.
    #expect(ProbeVerb.arm.requiresRoot)
    #expect(ProbeVerb.revert.requiresRoot)
    #expect(ProbeVerb.watchdog.requiresRoot)
    #expect(ProbeVerb.report.requiresRoot)
    #expect(ProbeVerb.run.requiresRoot == false)

    // The marker has to reach the text, or the flag is invisible to the user.
    for verb in ProbeVerb.allCases where verb.requiresRoot {
        let row = try? #require(ProbeVerb.usage
            .split(separator: "\n")
            .first { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) == verb.rawValue })
        #expect(row?.contains("root") == true,
                "the usage row for \(verb.rawValue) does not say it needs root")
    }
}

@Test func theDefaultVerbIsTheUnprivilegedOne() {
    // `main.swift` falls back to a verb when argv carries none. That fallback
    // must never be a privileged one: a bare `sudo coffee-bar-probe` that armed
    // the machine because a flag was misspelled is the accident this pins.
    #expect(ProbeVerb.default == .run)
    #expect(ProbeVerb.default.requiresRoot == false)
}
