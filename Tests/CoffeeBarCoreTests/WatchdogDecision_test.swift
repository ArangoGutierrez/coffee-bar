import Testing
import Foundation
@testable import CoffeeBarCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private let prov = ArmProvenance(pid: 1, binaryPath: "/x", uid: 501)

private func journal(ttl: Int = 900, schema: Int = 1,
                     prior: Bool = false) -> JournalRecord {
    JournalRecord(schemaVersion: schema, intent: .sleepDisabled,
                  priorValue: prior, setAt: t0, ttlSeconds: ttl, armedBy: prov)
}

private func inputs(journal j: JournalRecord? = journal(),
                    now: Date = t0.addingTimeInterval(10),
                    heartbeat: Date? = t0.addingTimeInterval(10),
                    boot: Bool = false,
                    thermal: ThermalLevel = .nominal,
                    battery: Int? = 80,
                    onBattery: Bool = false) -> WatchdogInputs {
    WatchdogInputs(journal: j, now: now, lastHeartbeat: heartbeat,
                   isBootEvaluation: boot, thermal: thermal,
                   batteryPercent: battery, onBattery: onBattery)
}

@Test func noJournalMeansNothingToRevert() {
    #expect(decide(inputs(journal: nil)) == .hold)
}

@Test func healthyArmedStateHolds() {
    #expect(decide(inputs()) == .hold)
}

@Test func expiredTTLReverts() {
    #expect(decide(inputs(now: t0.addingTimeInterval(901),
                          heartbeat: t0.addingTimeInterval(900)))
            == .revert(.ttlExpired))
}

@Test func ttlBoundaryIsNotYetExpired() {
    // Exactly at expiry is still live; one second later is not.
    #expect(decide(inputs(now: t0.addingTimeInterval(900),
                          heartbeat: t0.addingTimeInterval(900))) == .hold)
}

@Test func staleHeartbeatReverts() {
    #expect(decide(inputs(now: t0.addingTimeInterval(100),
                          heartbeat: t0.addingTimeInterval(50)))
            == .revert(.heartbeatLost))
}

@Test func missingHeartbeatReverts() {
    #expect(decide(inputs(now: t0.addingTimeInterval(100), heartbeat: nil))
            == .revert(.heartbeatLost))
}

@Test func bootWithDirtyJournalRevertsUnconditionally() {
    // Handoff §8.2(4): an unclean exit is not a state we reason about.
    // Even a perfectly live TTL and fresh heartbeat must revert at boot.
    #expect(decide(inputs(boot: true)) == .revert(.dirtyJournalAtBoot))
}

@Test func unknownSchemaOutranksEverything() {
    #expect(decide(inputs(journal: journal(schema: 99)))
            == .revert(.unknownSchema))
}

@Test func clockJumpBackwardsReverts() {
    // now < setAt means the clock moved; TTL arithmetic is untrustworthy.
    #expect(decide(inputs(now: t0.addingTimeInterval(-60),
                          heartbeat: t0.addingTimeInterval(-60)))
            == .revert(.clockAnomaly))
}

@Test func seriousThermalRevertsWhileArmed() {
    #expect(decide(inputs(thermal: .serious)) == .revert(.thermalAbort))
    #expect(decide(inputs(thermal: .critical)) == .revert(.thermalAbort))
}

@Test func fairThermalDoesNotRevert() {
    #expect(decide(inputs(thermal: .fair)) == .hold)
}

@Test func batteryFloorRevertsOnlyOnBattery() {
    #expect(decide(inputs(battery: 20, onBattery: true))
            == .revert(.batteryFloor))
    #expect(decide(inputs(battery: 19, onBattery: true))
            == .revert(.batteryFloor))
    // Same percentage on AC is fine — it is charging.
    #expect(decide(inputs(battery: 19, onBattery: false)) == .hold)
}

@Test func unknownBatteryDoesNotTriggerFloor() {
    #expect(decide(inputs(battery: nil, onBattery: true)) == .hold)
}

@Test func bootEvaluationOutranksThermalAndTTL() {
    #expect(decide(inputs(now: t0.addingTimeInterval(99_999), boot: true,
                          thermal: .critical))
            == .revert(.dirtyJournalAtBoot))
}
