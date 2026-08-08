// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

/// The monotonic reading taken beside `t0`. An arbitrary since-boot value —
/// only its difference from `inputs.monotonicNow` is ever read, and picking a
/// number far from `t0`'s epoch keeps the two frames from being confusable.
private let m0: TimeInterval = 10_000

private let prov = ArmProvenance(pid: 1, binaryPath: "/x", uid: 501)

// The record's own version rather than a literal 1. A schema bump is a normal
// event here — the monotonic stamp caused one — and a hard-coded version would
// make every test in this file revert as `.unknownSchema` on the next one,
// which reads as the feature breaking rather than as a stale fixture.
private func journal(ttl: Int = 900,
                     schema: Int = JournalRecord.currentSchemaVersion,
                     prior: Bool = false) -> JournalRecord {
    JournalRecord(schemaVersion: schema, intent: .sleepDisabled,
                  priorValue: prior, setAt: t0, setAtMonotonic: m0,
                  ttlSeconds: ttl, armedBy: prov)
}

private func inputs(journal j: JournalRecord? = journal(),
                    now: Date = t0.addingTimeInterval(10),
                    monotonicNow: TimeInterval? = nil,
                    heartbeat: Date? = t0.addingTimeInterval(10),
                    boot: Bool = false,
                    thermal: ThermalLevel = .nominal,
                    battery: Int? = 80,
                    onBattery: Bool = false) -> WatchdogInputs {
    WatchdogInputs(journal: j, now: now,
                   // DERIVED from `now` by default: a machine whose wall clock
                   // never moved, which is what every test written before #77
                   // silently assumed. A test that models a clock step passes
                   // its own reading and breaks the two apart — that split is
                   // the entire subject of `#77`.
                   monotonicNow: monotonicNow ?? (m0 + now.timeIntervalSince(t0)),
                   lastHeartbeat: heartbeat,
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

// MARK: - #77: the cap runs on elapsed real time, not on what the clock reads

@Test func theCapIsMeasuredOnElapsedRealTimeNotOnWhatTheWallClockReads() {
    // THE INVARIANT. `JournalRecord.maxTTLSeconds` promises a bound on how long
    // a root process may hold `SleepDisabled`, and a bound read off a wall clock
    // is a bound anyone able to set that clock can move.
    //
    // Here the wall clock sits 8 s behind real time — inside the anomaly
    // tolerance, so the clock guard stays deliberately quiet and this rung is
    // the ONLY thing that can end the hold. 901 s of real time have passed on a
    // 900 s TTL, while the wall clock still reads 893 s.
    //
    // Named bug this catches: `inputs.now > journal.expiry`. That comparison
    // answers HOLD here, and it answers hold for the whole size of any backward
    // step — 7 hours of one, in #77's report, on an 8-hour cap.
    #expect(decide(inputs(now: t0.addingTimeInterval(893),
                          monotonicNow: m0 + 901,
                          heartbeat: t0.addingTimeInterval(893)))
            == .revert(.ttlExpired))
}

@Test func theCapDoesNotEndAHoldEarlyWhenTheWallClockRanAhead() {
    // The other side, and it is what stops the rung above being satisfiable by
    // "revert whenever the clocks disagree at all". Real time is 5 s short of
    // the TTL while the wall clock has already sailed past it: the hold stands,
    // because elapsed time is what the cap counts.
    #expect(decide(inputs(now: t0.addingTimeInterval(903),
                          monotonicNow: m0 + 895,
                          heartbeat: t0.addingTimeInterval(903))) == .hold)
}

@Test func aBackwardWallClockStepLandingAfterSetAtIsAnAnomaly() {
    // #77's actual report, at the rung that reports it. The old guard tested
    // `now < setAt` and so saw only a step that overshot the arm; a step that
    // lands anywhere INSIDE the live window passed every rung on the ladder and
    // the hold simply carried on.
    //
    // Detectable at all only because the journal now carries a second reading
    // to compare against: 500 s of real time have elapsed and the wall clock
    // claims 100.
    #expect(decide(inputs(now: t0.addingTimeInterval(100),
                          monotonicNow: m0 + 500,
                          heartbeat: t0.addingTimeInterval(100)))
            == .revert(.clockAnomaly))
}

@Test func aForwardWallClockStepIsAnAnomalyToo() {
    // The guard is BIDIRECTIONAL. A forward step cannot extend a hold now that
    // the cap ignores the wall clock, so this is a signal rather than a
    // protection — but a machine whose clock jumped 400 s in either direction
    // has something wrong with it, and reporting only one direction hides half
    // of that.
    #expect(decide(inputs(now: t0.addingTimeInterval(500),
                          monotonicNow: m0 + 100,
                          heartbeat: t0.addingTimeInterval(500)))
            == .revert(.clockAnomaly))
}

@Test func theClockStepToleranceBracketsTheAnomalyGuard() {
    // Both sides of the bound, so neither `>` nor `>=` passes by luck.
    //
    // The tolerance is not zero on purpose: `HostInfo.now` truncates `setAt`
    // DOWN to the whole second and the monotonic stamp beside it is not
    // truncated, so a healthy arm starts life with the two readings up to a
    // second apart, and NTP moves the wall clock by small amounts routinely.
    #expect(decide(inputs(now: t0.addingTimeInterval(90),
                          monotonicNow: m0 + 100,
                          heartbeat: t0.addingTimeInterval(90))) == .hold)
    #expect(decide(inputs(now: t0.addingTimeInterval(89),
                          monotonicNow: m0 + 100,
                          heartbeat: t0.addingTimeInterval(89)))
            == .revert(.clockAnomaly))
}

@Test func customClockStepToleranceIsHonoured() {
    // Without this the guard could compare against a literal 10 and no test
    // would notice. Default is 10 s, under which 8 s of skew HOLDs; with a 5 s
    // policy the same inputs are an anomaly.
    let strict = WatchdogPolicy(heartbeatTimeout: 45, batteryFloorPercent: 20,
                                clockStepTolerance: 5)
    #expect(decide(inputs(now: t0.addingTimeInterval(92),
                          monotonicNow: m0 + 100,
                          heartbeat: t0.addingTimeInterval(92))) == .hold)
    #expect(decide(inputs(now: t0.addingTimeInterval(92),
                          monotonicNow: m0 + 100,
                          heartbeat: t0.addingTimeInterval(92)),
                   policy: strict) == .revert(.clockAnomaly))
}

@Test func degenerateClockStepTolerancesAreClampedAndTheSignalStillFires() {
    // The same degenerate values the heartbeat timeout is clamped against, and
    // they fail the same way round: `abs(skew) > .infinity` is never true, so
    // an unclamped policy reports a machine whose clock jumped an hour as
    // perfectly healthy.
    let wide = WatchdogPolicy(heartbeatTimeout: 45, batteryFloorPercent: 20,
                              clockStepTolerance: .infinity)
    #expect(wide.clockStepTolerance == 300)
    #expect(decide(inputs(now: t0.addingTimeInterval(100),
                          monotonicNow: m0 + 3700,
                          heartbeat: t0.addingTimeInterval(100)),
                   policy: wide) == .revert(.clockAnomaly))

    // NaN survives `min`/`max` untouched, and `abs(skew) > .nan` is false for
    // every skew there is.
    let nan = WatchdogPolicy(heartbeatTimeout: 45, batteryFloorPercent: 20,
                             clockStepTolerance: .nan)
    #expect(nan.clockStepTolerance.isFinite)
    #expect(decide(inputs(now: t0.addingTimeInterval(100),
                          monotonicNow: m0 + 3700,
                          heartbeat: t0.addingTimeInterval(100)),
                   policy: nan) == .revert(.clockAnomaly))
}

@Test func seriousThermalRevertsWhileArmed() {
    #expect(decide(inputs(thermal: .serious)) == .revert(.thermalAbort))
    #expect(decide(inputs(thermal: .critical)) == .revert(.thermalAbort))
}

@Test func fairThermalDoesNotRevert() {
    #expect(decide(inputs(thermal: .fair)) == .hold)
}

@Test func batteryFloorRevertsOnlyOnBattery() {
    #expect(decide(inputs(battery: 15, onBattery: true))
            == .revert(.batteryFloor))
    #expect(decide(inputs(battery: 14, onBattery: true))
            == .revert(.batteryFloor))
    // Same percentage on AC is fine — it is charging.
    #expect(decide(inputs(battery: 14, onBattery: false)) == .hold)
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

    // 4 clock, the #77 flavour: a wall clock stepped back to `setAt` without
    // ever going past it. Unlike the rewound flavour this one CAN hold at the
    // same time as an expired TTL, so it pins the rung above all four below it
    // at once.
    #expect(decide(inputs(now: t0, monotonicNow: m0 + 100_000,
                          heartbeat: deadBeat, thermal: hot,
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
    // Default floor is 15, under which 40% HOLDs; with a floor of 50 the same
    // inputs must revert. Pins `policy.batteryFloorPercent` against a literal.
    let strict = WatchdogPolicy(heartbeatTimeout: 45, batteryFloorPercent: 50)
    #expect(decide(inputs(battery: 40, onBattery: true), policy: strict)
            == .revert(.batteryFloor))
}

@Test func customKnownSchemaVersionIsHonoured() {
    // The default known version is the record's own, so a current journal
    // HOLDs. Under a policy that knows only the NEXT version, that same journal
    // is unknown-schema — which is how a reader refuses to act on a record it
    // cannot interpret. Written against `currentSchemaVersion` rather than
    // against literals, so the monotonic stamp's bump did not turn it into an
    // assertion about a version nobody ships.
    let next = WatchdogPolicy(
        heartbeatTimeout: 45, batteryFloorPercent: 20,
        knownSchemaVersion: JournalRecord.currentSchemaVersion + 1)
    #expect(decide(inputs()) == .hold)
    #expect(decide(inputs(), policy: next) == .revert(.unknownSchema))
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
    #expect(p.batteryFloorPercent == 10)
    #expect(decide(inputs(battery: 10, onBattery: true), policy: p)
            == .revert(.batteryFloor))
    #expect(decide(inputs(battery: 11, onBattery: true), policy: p) == .hold)
}

@Test func batteryFloorAboveOneHundredIsCapped() {
    // Percentages above 100 are unrepresentable, not merely aggressive, and
    // `BatteryFloor.permitted` stops well short of 100 — a floor above half
    // the battery refuses to hold across half of every discharge.
    let p = WatchdogPolicy(heartbeatTimeout: 45, batteryFloorPercent: 1000)
    #expect(p.batteryFloorPercent == 50)
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
