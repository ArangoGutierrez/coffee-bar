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

@Test func heartbeatExactlyAtTimeoutStillHolds() {
    // Pins `<=`. Under `<` this reverts, and nothing else in the suite notices.
    // 45s is the policy timeout: at exactly the boundary the supervisor is
    // still considered alive.
    #expect(decide(inputs(now: t0.addingTimeInterval(45),
                          heartbeat: t0)) == .hold)
}

@Test func heartbeatOneSecondPastTimeoutReverts() {
    // The other side of the same boundary, so the pair brackets it.
    #expect(decide(inputs(now: t0.addingTimeInterval(46),
                          heartbeat: t0)) == .revert(.heartbeatLost))
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

@Test func clockExactlyAtSetAtIsNotAnAnomaly() {
    // Pins `<`. Under `<=` this returns .revert(.clockAnomaly).
    // now == setAt is the normal case at arm time, not a clock jump.
    #expect(decide(inputs(now: t0, heartbeat: t0)) == .hold)
}

@Test func clockOneSecondBeforeSetAtIsAnAnomaly() {
    // Brackets the other side: strictly before setAt is a real jump.
    #expect(decide(inputs(now: t0.addingTimeInterval(-1),
                          heartbeat: t0.addingTimeInterval(-1)))
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

@Test func precedenceLadderIsDeterministic() {
    // The order IS the spec: several inputs can hold at once and the reported
    // reason must be deterministic. Each rung turns on its own condition AND
    // every lower-precedence one that can hold at the same time, so swapping
    // it with either neighbour changes the answer. Without this rung-by-rung
    // pinning, all six adjacent swaps pass the suite.
    //
    // `clockAnomaly` (now < setAt) and `ttlExpired` (now > setAt + ttl) can
    // never both hold, so the two rungs above the clock guard are asserted in
    // both flavours: one `now` rewound before setAt, one advanced past expiry.
    let hot: ThermalLevel = .critical
    let rewound = t0.addingTimeInterval(-10_000)  // now < setAt: clock anomaly
    let expired = t0.addingTimeInterval(100_000)  // now > expiry (setAt + 900)
    let deadBeat = rewound.addingTimeInterval(-100)  // >45s before `rewound`

    // 2 schema — over boot, clock, thermal, battery, heartbeat …
    #expect(decide(inputs(journal: journal(schema: 99), now: rewound,
                          heartbeat: deadBeat, boot: true, thermal: hot,
                          battery: 1, onBattery: true))
            == .revert(.unknownSchema))
    // … and over TTL.
    #expect(decide(inputs(journal: journal(schema: 99), now: expired,
                          heartbeat: t0, boot: true, thermal: hot,
                          battery: 1, onBattery: true))
            == .revert(.unknownSchema))

    // 3 boot — over clock, thermal, battery, heartbeat …
    #expect(decide(inputs(now: rewound, heartbeat: deadBeat, boot: true,
                          thermal: hot, battery: 1, onBattery: true))
            == .revert(.dirtyJournalAtBoot))
    // … and over TTL.
    #expect(decide(inputs(now: expired, heartbeat: t0, boot: true,
                          thermal: hot, battery: 1, onBattery: true))
            == .revert(.dirtyJournalAtBoot))

    // 4 clock — over thermal, battery, heartbeat (TTL cannot also hold).
    #expect(decide(inputs(now: rewound, heartbeat: deadBeat, thermal: hot,
                          battery: 1, onBattery: true))
            == .revert(.clockAnomaly))

    // 5 thermal — over battery, TTL, heartbeat.
    #expect(decide(inputs(now: expired, heartbeat: t0, thermal: hot,
                          battery: 1, onBattery: true))
            == .revert(.thermalAbort))

    // 6 battery — over TTL, heartbeat.
    #expect(decide(inputs(now: expired, heartbeat: t0, battery: 1,
                          onBattery: true))
            == .revert(.batteryFloor))

    // 7 TTL — over heartbeat.
    #expect(decide(inputs(now: expired, heartbeat: t0))
            == .revert(.ttlExpired))

    // 8 heartbeat alone: the last rung, with the TTL still live.
    #expect(decide(inputs(now: t0.addingTimeInterval(100), heartbeat: t0))
            == .revert(.heartbeatLost))
}

@Test func customHeartbeatTimeoutIsHonoured() {
    // Nothing else in the suite passes a policy, so `policy.heartbeatTimeout`
    // could be the literal 45 and no test would notice. Default is 45s, under
    // which 20s HOLDs; with a 10s policy the same inputs must revert.
    let strict = WatchdogPolicy(heartbeatTimeout: 10, batteryFloorPercent: 20)
    #expect(decide(inputs(now: t0.addingTimeInterval(20), heartbeat: t0),
                   policy: strict) == .revert(.heartbeatLost))
}

@Test func customBatteryFloorIsHonoured() {
    // Default floor is 20, under which 40% HOLDs; with a floor of 50 the same
    // inputs must revert. Pins `policy.batteryFloorPercent` against a literal.
    let strict = WatchdogPolicy(heartbeatTimeout: 45, batteryFloorPercent: 50)
    #expect(decide(inputs(battery: 40, onBattery: true), policy: strict)
            == .revert(.batteryFloor))
}

@Test func customKnownSchemaVersionIsHonoured() {
    // Default known version is 1, so a v1 journal HOLDs. Under a policy that
    // knows only v2, that same journal is unknown-schema — which is how a
    // future reader refuses to act on a record it cannot interpret.
    let v2 = WatchdogPolicy(heartbeatTimeout: 45, batteryFloorPercent: 20,
                            knownSchemaVersion: 2)
    #expect(decide(inputs(journal: journal(schema: 1)), policy: v2)
            == .revert(.unknownSchema))
}

@Test func policyDefaultsToTheCurrentSchemaVersion() {
    // Without the default, a policy carries whatever literal its author typed.
    // A stale one makes every armed journal revert as `.unknownSchema`: safe,
    // but the feature silently stops working, and no other test would notice
    // because they all pin the version they themselves passed in.
    let p = WatchdogPolicy(heartbeatTimeout: 45, batteryFloorPercent: 20)
    #expect(p.knownSchemaVersion == JournalRecord.currentSchemaVersion)
    #expect(decide(inputs(), policy: p) == .hold)
}

@Test func infiniteHeartbeatTimeoutIsClampedAndTheGuardStillFires() {
    // The dangerous degenerate value. `gap <= .infinity` is ALWAYS true, so
    // the heartbeat guard never fires and the machine never sleeps — the
    // policy fails OPEN, which is the exact harm this project prevents.
    let p = WatchdogPolicy(heartbeatTimeout: .infinity, batteryFloorPercent: 20)
    #expect(p.heartbeatTimeout == 300)
    // Brackets the clamped bound: at exactly 300s the supervisor is still
    // alive, one second later it is not. Unclamped, BOTH would hold.
    #expect(decide(inputs(now: t0.addingTimeInterval(300), heartbeat: t0),
                   policy: p) == .hold)
    #expect(decide(inputs(now: t0.addingTimeInterval(301), heartbeat: t0),
                   policy: p) == .revert(.heartbeatLost))
}

@Test func nanHeartbeatTimeoutYieldsAFiniteInRangeValue() {
    // `min`/`max` PROPAGATE NaN — every comparison against NaN is false, so
    // `min(max(.nan, 1), 300)` returns .nan and a naive clamp lets the
    // degenerate value straight through. Downstream, `gap <= .nan` is always
    // false, so the policy reverts unconditionally: safe, but the feature is
    // dead and nothing says why.
    let p = WatchdogPolicy(heartbeatTimeout: .nan, batteryFloorPercent: 20)
    #expect(p.heartbeatTimeout.isFinite)
    #expect(p.heartbeatTimeout == 45)
    #expect(decide(inputs(now: t0.addingTimeInterval(10), heartbeat: t0),
                   policy: p) == .hold)
}

@Test func zeroBatteryFloorIsRaisedToTheMinimum() {
    // A floor of 0 fires only at exactly 0%, i.e. after the machine is dead.
    let p = WatchdogPolicy(heartbeatTimeout: 45, batteryFloorPercent: 0)
    #expect(p.batteryFloorPercent == 5)
    #expect(decide(inputs(battery: 5, onBattery: true), policy: p)
            == .revert(.batteryFloor))
    #expect(decide(inputs(battery: 6, onBattery: true), policy: p) == .hold)
}

@Test func batteryFloorAboveOneHundredIsCapped() {
    // Percentages above 100 are unrepresentable, not merely aggressive.
    let p = WatchdogPolicy(heartbeatTimeout: 45, batteryFloorPercent: 1000)
    #expect(p.batteryFloorPercent == 100)
}

@Test func thermalLevelRawValuesMatchProcessInfo() {
    // Core redeclares ThermalLevel to stay Foundation-only. If these drift, a
    // Power-side rawValue mapping silently misreads the machine's thermal
    // state.
    #expect(ThermalLevel.nominal.rawValue  == ProcessInfo.ThermalState.nominal.rawValue)
    #expect(ThermalLevel.fair.rawValue     == ProcessInfo.ThermalState.fair.rawValue)
    #expect(ThermalLevel.serious.rawValue  == ProcessInfo.ThermalState.serious.rawValue)
    #expect(ThermalLevel.critical.rawValue == ProcessInfo.ThermalState.critical.rawValue)
    // A value beyond the known set must NOT construct — forcing callers to
    // choose a fallback explicitly rather than getting .nominal by accident.
    #expect(ThermalLevel(rawValue: 99) == nil)
}
