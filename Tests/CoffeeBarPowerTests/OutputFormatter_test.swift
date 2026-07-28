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
