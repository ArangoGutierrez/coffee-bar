import Testing
import Foundation
@testable import CoffeeBarCore

private func makeReport(_ spikes: [SpikeResult]) -> ProbeReport {
    ProbeReport(
        schemaVersion: 1,
        generatedAt: Date(timeIntervalSince1970: 1_785_000_000),
        host: HostStamp(hardwareModel: "Mac16,6", osVersion: "26.5.2",
                        osBuild: "25F84", arch: "arm64"),
        spikes: spikes
    )
}

@Test func reportRoundTripsThroughJSON() throws {
    let original = makeReport([
        SpikeResult(id: .s3EnergyFields, verdict: .pass,
                    detail: "ri_billed_energy populated",
                    durationMS: 12, evidence: ["rusageVersion": "V4"])
    ])
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ProbeReport.self, from: data)
    #expect(decoded == original)
}

@Test func reportJSONUsesHandoffSpikeIdentifiers() throws {
    let report = makeReport([
        SpikeResult(id: .s1LidCloseSleep, verdict: .notYetRun,
                    detail: "requires an armed run", durationMS: 0, evidence: [:])
    ])
    let data = try JSONEncoder().encode(report)
    let json = String(decoding: data, as: UTF8.self)
    // The acceptance command greps spike ids out of this envelope.
    #expect(json.contains("\"S1\""))
    #expect(json.contains("\"notYetRun\""))
}

@Test func resultLookupFindsBySpikeID() {
    let report = makeReport([
        SpikeResult(id: .s5DemotionPrivilege, verdict: .fail,
                    detail: "EPERM", durationMS: 3, evidence: [:]),
        SpikeResult(id: .s8TelemetryCollision, verdict: .pass,
                    detail: "mode 1", durationMS: 1, evidence: [:]),
    ])
    #expect(report.result(for: .s5DemotionPrivilege)?.verdict == .fail)
    #expect(report.result(for: .s8TelemetryCollision)?.verdict == .pass)
    #expect(report.result(for: .s1LidCloseSleep) == nil)
}

@Test func hostStampIsRequiredAndSurvivesEncoding() throws {
    // Spec §4: a verdict without the OS build it was measured on is worthless.
    let report = makeReport([])
    let data = try JSONEncoder().encode(report)
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("25F84"))
    #expect(json.contains("26.5.2"))
}
