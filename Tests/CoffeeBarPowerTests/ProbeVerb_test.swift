// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarPower
@testable import CoffeeBarCore

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

/// The verb each usage ROW advertises, in order.
///
/// A row is an indented line, and its first token is the verb. Parsing rows is
/// the whole point: a plain `usage.contains("watchdog")` is satisfied by the
/// word appearing ANYWHERE, and `revert`'s summary line legitimately reads
/// "restore the prior sleep setting and remove the watchdog".
///
/// That is not hypothetical. Mutation testing built exactly that hole: deleting
/// the `watchdog` ROW left a `contains` check green, because the word survived
/// inside another verb's description. A guard that cannot tell a row from a
/// mention does not guard the list.
func advertisedVerbs(in usage: String) -> [String] {
    usage
        .split(separator: "\n")
        .filter { $0.hasPrefix("  ") }
        .compactMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) }
        .filter { ProbeVerb(rawValue: $0) != nil }
}

@Test func theUsageTextAdvertisesEveryVerbTheBinaryHandles() {
    // Named bug this catches, and it SHIPPED in v0.1: `watchdog` handled and
    // unadvertised. A user reading `--help` cannot find a verb that exists.
    let advertised = advertisedVerbs(in: ProbeVerb.usage)

    #expect(advertised.isEmpty == false,
            "no verb rows were parsed, so this check read nothing")

    for verb in ProbeVerb.allCases {
        #expect(advertised.contains(verb.rawValue), """
            the usage text carries no ROW for "\(verb.rawValue)", which the \
            binary handles. That is the v0.1 defect exactly.
            rows found: \(advertised)
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
    // Deliberately NOT `advertisedVerbs(in:)`, which discards anything that is
    // not a known verb — the exact thing this check is hunting for.
    let tokens = ProbeVerb.usage
        .split(separator: "\n")
        // The verb rows are the indented ones; the "usage:" banner is not.
        .filter { $0.hasPrefix("  ") }
        .compactMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) }

    #expect(tokens.isEmpty == false,
            "no verb rows were parsed out of the usage text, so this check read nothing")

    for token in tokens {
        #expect(ProbeVerb(rawValue: token) != nil, """
            the usage text advertises "\(token)", which is not a verb the \
            binary handles. Running it exits 64.
            """)
    }

    // Both lists are the same SET, not merely overlapping. A row parsed twice,
    // or a verb listed twice and another dropped, passes both loops above.
    #expect(Set(tokens) == Set(ProbeVerb.allCases.map(\.rawValue)))
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

@Test func theVerbsRequiringRootSaySoAndTheOthersDoNot() throws {
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
    //
    // The EXACT suffix, not `contains("root")`. That looser shape is the same
    // defect mutation testing already found once in this file: it passes today
    // only because no summary happens to contain the word "root", and a summary
    // reading "restore the prior setting as root saw it" would satisfy it for a
    // verb whose marker had been dropped.
    for verb in ProbeVerb.allCases {
        let row = try #require(ProbeVerb.usage
            .split(separator: "\n")
            .first { $0.split(whereSeparator: \.isWhitespace).first.map(String.init)
                        == verb.rawValue },
            "no usage row for \(verb.rawValue)")

        if verb.requiresRoot {
            #expect(row.hasSuffix(" (root)"), """
                the usage row for \(verb.rawValue) does not end in " (root)", \
                so the user is not told it needs privilege.
                row: \(row)
                """)
        } else {
            #expect(row.hasSuffix(" (root)") == false, """
                the usage row for \(verb.rawValue) claims it needs root. It \
                does not, and marking it so trains the user to run everything \
                under sudo.
                row: \(row)
                """)
        }
    }
}

@Test func theDefaultTTLIsMinutesRatherThanTheEightHourCap() throws {
    // §8.2(5) makes 8 h a CAP, "hard-capped regardless of settings". It was
    // also the DEFAULT, which is a different claim and a much worse one.
    //
    // Supervision on this path is TTL-only: there is no heartbeat writer, so
    // nothing shortens a hold that is running long. The default TTL therefore
    // IS the worst case — a user who runs `sudo coffee-bar-probe arm`, walks
    // away and never returns kept the machine awake for the full default.
    // Eight hours of that is an overnight battery.
    #expect(ProbeVerb.defaultTTLSeconds < JournalRecord.maxTTLSeconds, """
        the default TTL is the cap. A cap bounds the worst case a user asks \
        for; a default is what they get for asking nothing.
        """)
    // Minutes, not hours. The bound is deliberately loose — this pins the
    // ORDER OF MAGNITUDE, which is the property that was wrong, not one
    // particular number somebody may tune later.
    #expect(ProbeVerb.defaultTTLSeconds <= 60 * 60)
    #expect(ProbeVerb.defaultTTLSeconds >= 5 * 60,
            "a default this short makes the feature useless without --ttl")

    // And it survives the clamp unchanged, so the default a user is told about
    // is the default they get.
    let record = JournalRecord(
        intent: .sleepDisabled, priorValue: false, setAt: Date(),
        setAtMonotonic: SystemMonotonicClock.now(),
        bootSessionID: SystemBootTime.currentSessionID() ?? "",
        ttlSeconds: ProbeVerb.defaultTTLSeconds,
        armedBy: ArmProvenance(pid: 1, binaryPath: "/x", uid: 501))
    #expect(record.ttlSeconds == ProbeVerb.defaultTTLSeconds)
}

@Test func theDefaultVerbIsTheUnprivilegedOne() {
    // `main.swift` falls back to a verb when argv carries none. That fallback
    // must never be a privileged one: a bare `sudo coffee-bar-probe` that armed
    // the machine because a flag was misspelled is the accident this pins.
    #expect(ProbeVerb.default == .run)
    #expect(ProbeVerb.default.requiresRoot == false)
}
