// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarPower
@testable import CoffeeBarCore

private let report = ProbeReport(
    generatedAt: Date(timeIntervalSince1970: 1_785_000_000),
    host: HostStamp(hardwareModel: "Mac16,6", osVersion: "26.5.2",
                    osBuild: "25F84", arch: "arm64"),
    spikes: [
        SpikeResult(id: .s1LidCloseSleep, verdict: .notYetRun,
                    detail: "requires an armed run", durationMS: 0, evidence: [:]),
        SpikeResult(id: .s3EnergyFields, verdict: .pass,
                    detail: "populated", durationMS: 4, evidence: [:]),
    ])

@Test func jsonOutputContainsEverySpikeIdentifier() throws {
    let json = try OutputFormatter.json(report)
    #expect(json.contains("\"S1\""))
    #expect(json.contains("\"S3\""))
}

@Test func jsonOutputIsParseableBackIntoAReport() throws {
    let json = try OutputFormatter.json(report)
    let decoded = try OutputFormatter.makeDecoder()
        .decode(ProbeReport.self, from: Data(json.utf8))
    #expect(decoded == report)
}

@Test func jsonDatesAreISO8601NotEpochDoubles() throws {
    // Guards the encoder strategy itself. Under the default .deferredToDate
    // the date serialises as a bare Double — unreadable to jq and not what
    // `makeDecoder()` expects.
    let json = try OutputFormatter.json(report)
    #expect(json.contains("\"generatedAt\" : \"2026-"))

    // The value must be a JSON *string*, not a bare number. Deriving this
    // from the character that follows the key makes it fail under *any*
    // numeric strategy rather than only one whose leading digit was guessed:
    // the original form of this assertion looked for `"generatedAt" : 7`,
    // but .deferredToDate encodes this fixture as 806692800 (seconds since
    // the 2001 reference date), so it held under the very mutant it named.
    let marker = "\"generatedAt\" : "
    let afterKey = try #require(json.range(of: marker))
    #expect(json[afterKey.upperBound...].hasPrefix("\""))
}

@Test func reportTimestampsAreWholeSecondsSoRoundTripIsExact() throws {
    // .iso8601 has SECOND granularity. A report stamped with a sub-second
    // Date cannot round-trip, so emitters must truncate — see HostInfo.now().
    // This test pins that contract rather than leaving it to comments.
    let fractional = Date(timeIntervalSince1970: 1_785_000_000.75)
    let truncated = Date(
        timeIntervalSince1970: fractional.timeIntervalSince1970.rounded(.down))
    let r = ProbeReport(generatedAt: truncated,
                        host: report.host, spikes: [])
    let back = try OutputFormatter.makeDecoder()
        .decode(ProbeReport.self, from: Data(try OutputFormatter.json(r).utf8))
    #expect(back == r)
}

@Test func humanOutputNamesTheOSBuild() {
    let text = OutputFormatter.human(report)
    #expect(text.contains("25F84"))
    #expect(text.contains("Mac16,6"))
}

@Test func humanOutputMarksNotYetRunDistinctlyFromFailure() throws {
    // S1 must never read as a failure just because nobody closed a lid.
    // Asserted against S1's OWN line: a whole-text search for "s1 fail" can
    // never match, because the columns are space-padded — it would hold even
    // if the formatter printed every verdict as FAIL.
    let text = OutputFormatter.human(report)
    let s1Line = try #require(
        text.split(separator: "\n").first { $0.contains("S1") })
    #expect(s1Line.contains("not-yet-run"))
    #expect(!s1Line.lowercased().contains("fail"))
}

// MARK: - The deadline `report` announces (#85)

/// Armed at epoch 1_786_000_000, 1000 s after this machine booted, for 900 s.
///
/// So the ENFORCED deadline is monotonic 1900, and the wall-clock `expiry` the
/// record computes for itself is epoch 1_786_000_900. The two agree only while
/// nobody steps the wall clock — which is the whole of #85.
private let heldRecord = JournalRecord(
    intent: .sleepDisabled,
    priorValue: false,
    setAt: Date(timeIntervalSince1970: 1_786_000_000),
    setAtMonotonic: 1000,
    ttlSeconds: 900,
    armedBy: ArmProvenance(pid: 42,
                           binaryPath: "/usr/local/bin/coffee-bar-probe",
                           uid: 0))

@Test func theEnforcedDeadlineIsMeasuredOnTheMonotonicClockNotTheWallClock() throws {
    // Named bug this catches: deriving the reported deadline from `setAt`,
    // which is exactly what `JournalRecord.expiry` does and what `report`
    // printed until #85. The wall clock here has been stepped an hour FORWARD
    // since the arm, so the two answers land on opposite sides of zero: 400 s
    // still to run on the clock `WatchdogDecision.decide` enforces, 2700 s
    // expired on the one it ignores.
    let steppedNow = heldRecord.setAt.addingTimeInterval(3600)
    let hold = ArmedHoldReport(record: heldRecord, now: steppedNow,
                               monotonicNow: 1500)

    // 1000 + 900 - 1500, worked out here rather than by the implementation.
    #expect(hold.enforcedSecondsRemaining == 400)
    #expect(hold.projectedEndWallClock == steppedNow.addingTimeInterval(400))

    // The wall-clock answer, spelled out so this test states what it is
    // rejecting instead of only what it wants.
    #expect(heldRecord.expiry.timeIntervalSince(steppedNow) == -2700)
}

@Test func theHumanReportNeverShowsTheWallClockExpiryAsIfItBound() throws {
    let steppedNow = heldRecord.setAt.addingTimeInterval(3600)
    let hold = ArmedHoldReport(record: heldRecord, now: steppedNow,
                               monotonicNow: 1500)

    // ANTI-VACUITY: the two dates must actually differ, or the absence below
    // holds just as well for a formatter that prints `expiry` and nothing else.
    try #require(hold.projectedEndWallClock != heldRecord.expiry)

    let text = OutputFormatter.human(hold)
    #expect(!text.contains("\(heldRecord.expiry)"), """
        the report shows \(heldRecord.expiry) — `setAt` plus the TTL, both in \
        the wall frame — and not the deadline the daemon acts on:
        \(text)
        """)
    #expect(text.contains("400s"), """
        the report never names the 400 s the cap actually has left:
        \(text)
        """)
    #expect(text.contains("\(hold.projectedEndWallClock)"), """
        the report drops the wall-clock projection a human reads a date from:
        \(text)
        """)
}

@Test func aHoldPastItsCapReadsDifferentlyFromOneExactlyAtIt() throws {
    // Reachable, not hypothetical: the daemon ticks every 5 s, so a record can
    // be read after its cap and before its revert. Named bug this catches:
    // clamping the remaining time at zero, which renders a hold whose revert is
    // LATE identically to a healthy one in its final instant — the one moment
    // the difference is worth anything.
    let late = ArmedHoldReport(record: heldRecord,
                               now: Date(timeIntervalSince1970: 1_786_000_912),
                               monotonicNow: 1912)   // 12 s past monotonic 1900
    let atTheLine = ArmedHoldReport(record: heldRecord,
                                    now: Date(timeIntervalSince1970: 1_786_000_900),
                                    monotonicNow: 1900)

    #expect(late.enforcedSecondsRemaining == -12)
    #expect(atTheLine.enforcedSecondsRemaining == 0)

    func enforcedLine(_ hold: ArmedHoldReport) throws -> String {
        let text = OutputFormatter.human(hold)
        return try #require(
            text.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("enforced:") },
            "the human report carries no `enforced:` line:\n\(text)")
    }

    let lateLine = try enforcedLine(late)
    #expect(lateLine != (try enforcedLine(atTheLine)), """
        a hold 12 s past its cap and one exactly at it both report
          \(lateLine)
        """)
    #expect(lateLine.contains("12"), """
        the report says a cap has passed without saying by how long:
          \(lateLine)
        """)
}

@Test func reportJSONKeepsEveryJournalKeyAndAddsTheEnforcedDeadline() throws {
    // The machine path must not be left re-deriving the enforced deadline for
    // itself — re-deriving it is what went wrong. Named bugs this catches:
    // nesting the record under a `record` key (every existing consumer breaks
    // at once), and a hand-listed `encode(to:)` that silently drops whatever
    // field the journal gains next.
    let hold = ArmedHoldReport(record: heldRecord,
                               now: Date(timeIntervalSince1970: 1_786_000_500),
                               monotonicNow: 1500)

    let bare = try #require(try JSONSerialization.jsonObject(
        with: Data(try OutputFormatter.json(heldRecord).utf8)) as? [String: Any])
    let full = try #require(try JSONSerialization.jsonObject(
        with: Data(try OutputFormatter.json(hold).utf8)) as? [String: Any])

    // ANTI-VACUITY: a record that encoded nothing would satisfy the loop below
    // without comparing a single value.
    #expect(bare.count >= 7,
            "the journal record encodes \(bare.count) keys: \(bare.keys.sorted())")
    for named in ["schemaVersion", "intent", "priorValue", "setAt",
                  "setAtMonotonic", "ttlSeconds", "armedBy"] {
        #expect(bare[named] != nil,
                "the journal record no longer encodes `\(named)`: \(bare.keys.sorted())")
    }

    for (key, value) in bare {
        #expect((value as? NSObject) == (full[key] as? NSObject), """
            `report --json` lost or changed `\(key)`: the record alone encodes \
            \(value), the report encodes \(full[key].map { "\($0)" } ?? "nothing")
            """)
    }

    // 1000 + 900 - 1500, on the clock the cap is enforced against.
    #expect(try #require(full["enforcedSecondsRemaining"] as? Double) == 400)
    // Independently formatted, by a different implementation than the encoder's.
    #expect(try #require(full["projectedEndWallClock"] as? String)
            == ISO8601DateFormatter().string(
                from: Date(timeIntervalSince1970: 1_786_000_900)))
}

@Test func everyVerdictPrintsADistinctHumanLabel() {
    // A formatter that collapsed two verdicts onto one label — say .notYetRun
    // and .fail both rendering "FAIL" — would still satisfy every assertion
    // above, each of which inspects a single row.
    let verdicts: [Verdict] = [.pass, .fail, .notApplicable, .notYetRun, .error]
    let labels = verdicts.map { verdict -> String in
        let r = SpikeResult(id: .baseline, verdict: verdict, detail: "d",
                            durationMS: 0, evidence: [:])
        let line = OutputFormatter.human(
            ProbeReport(generatedAt: Date(timeIntervalSince1970: 0),
                        host: report.host, spikes: [r]))
        return line.split(separator: "\n").last.map(String.init) ?? ""
    }
    #expect(Set(labels).count == verdicts.count)
}
