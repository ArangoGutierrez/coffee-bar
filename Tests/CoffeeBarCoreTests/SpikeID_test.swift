import Testing
@testable import CoffeeBarCore

@Test func spikeIDRawValuesMatchHandoffNumbering() {
    // Handoff numbering is authoritative (spec D2). The kickoff engine
    // renumbered S3-S6; those values are rejected.
    #expect(SpikeID.s1LidCloseSleep.rawValue == "S1")
    #expect(SpikeID.s2DisplayUnderClosedLid.rawValue == "S2")
    #expect(SpikeID.s3EnergyFields.rawValue == "S3")
    #expect(SpikeID.s5DemotionPrivilege.rawValue == "S5")
    #expect(SpikeID.s8TelemetryCollision.rawValue == "S8")
}

@Test func spikeIDDoesNotClaimDeferredSpikes() {
    // S4 (Cursor runtime hooks) and S6 (drain harness) are out of M0 scope
    // per spec D3. A raw value of "S4" or "S6" means scope crept.
    let raws = Set(SpikeID.allCases.map(\.rawValue))
    #expect(!raws.contains("S4"))
    #expect(!raws.contains("S6"))
}

@Test func spikeIDCoversBaselineAndNothingElse() {
    // `baseline` is a real case the brief mandates; without this assertion
    // deleting it leaves the suite green.
    #expect(SpikeID.baseline.rawValue == "baseline")
    // Pins the total so a silently-added or silently-dropped case fails here.
    #expect(SpikeID.allCases.count == 6)
}
