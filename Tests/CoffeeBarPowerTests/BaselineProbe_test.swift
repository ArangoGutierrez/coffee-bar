// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
@testable import CoffeeBarPower
@testable import CoffeeBarCore

/// Power-management assertions currently owned by *this* process, filtered to a
/// given assertion name.
///
/// Key strings are the documented literals (`kIOPMAssertionNameKey` ==
/// `"AssertName"`), spelled out so the test does not depend on the same
/// constants the implementation uses. Deliberately a second copy of the helper
/// in `AssertionHolder_test.swift`: that one is private to its suite, and this
/// file is the only other place that needs to read live IOKit state.
private func liveAssertions(named name: String) -> [[String: Any]] {
    var unmanaged: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
        let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
    else {
        return []
    }
    let pid = NSNumber(value: ProcessInfo.processInfo.processIdentifier)
    return (byProcess[pid] ?? []).filter { $0["AssertName"] as? String == name }
}

@Test func nowIsTruncatedToWholeSeconds() {
    // Contract for ISO-8601 round-tripping: no sub-second component.
    // Fails immediately if someone "simplifies" now() back to Date().
    let t = HostInfo.now().timeIntervalSince1970
    #expect(t == t.rounded(.down))

    // ...and truncated *downwards*. Whole-second-ness alone is equally
    // satisfied by rounding up, which would stamp every journal up to a second
    // in the future. `decide()` reverts with `.clockAnomaly` when `now` is
    // before the journal's `setAt`, so a report stamped ahead of the clock that
    // later reads it is a spurious revert — arming and immediately disarming.
    #expect(HostInfo.now() <= Date())
}

@Test func hostStampIsPopulatedFromTheRunningMachine() {
    let s = HostInfo.stamp()
    #expect(!s.hardwareModel.isEmpty)
    #expect(!s.osBuild.isEmpty)
    #expect(s.osVersion.split(separator: ".").count >= 2)
    #expect(s.arch == "arm64" || s.arch == "x86_64")
}

@Test func hostStampBuildLooksLikeADarwinBuildIdentifier() {
    // e.g. "25F84" — digits, letter, digits. A verdict is worthless without it.
    let build = HostInfo.stamp().osBuild
    #expect(build.rangeOfCharacter(from: .decimalDigits) != nil)
    #expect(build.rangeOfCharacter(from: .uppercaseLetters) != nil)
}

@Test func assertionProbeAcquiresAndReleasesCleanly() {
    // Verified reachable in this environment: IOPMAssertionCreateWithName
    // returned rc=0 on macOS 26.5.2.
    //
    // The verdict alone cannot tell these three probes apart: one that holds
    // the right assertion, one that holds `PreventUserIdleDisplaySleep`, and
    // one that acquires and never releases. All three report `.pass`. So the
    // assertion is read back out of live IOKit state instead, on both sides of
    // the release — holding the display assertion would delete the product's
    // entire reason to exist (§6.1), and a leak would keep this machine awake
    // for the rest of the process's life with nothing left to release it.
    #expect(liveAssertions(named: AssertionProbe.assertionName).isEmpty,
            "stale probe assertion before the run; the readings below would be its")

    var heldTypes: [String]?
    let result = AssertionProbe().run(whileHeld: {
        heldTypes = liveAssertions(named: AssertionProbe.assertionName)
            .compactMap { $0["AssertType"] as? String }
    })

    // Deliberately NOT `if let heldTypes { ... }` — that form is vacuously
    // green for a `run` that never enters the seam at all.
    #expect(heldTypes == ["PreventUserIdleSystemSleep"])
    #expect(liveAssertions(named: AssertionProbe.assertionName).isEmpty,
            "probe returned with its assertion still live: it leaked")

    #expect(result.id == .baseline)
    #expect(result.verdict == .pass)
    #expect(result.evidence["assertionReturnCode"] == "0")
    #expect(result.evidence["released"] == "true")
}

@Test func thermalMappingCoversEveryDocumentedState() {
    // The live reader cannot be driven to .serious on demand, so the MAPPING
    // is extracted and tested directly. This is the part with a bug budget:
    // an off-by-one here silently disarms the thermal abort in §8.1.
    #expect(SystemPowerReader.level(from: .nominal)  == .nominal)
    #expect(SystemPowerReader.level(from: .fair)     == .fair)
    #expect(SystemPowerReader.level(from: .serious)  == .serious)
    #expect(SystemPowerReader.level(from: .critical) == .critical)
}

@Test func unknownFutureThermalStateFailsSafeToCritical() throws {
    // The four cases above leave `@unknown default` — the whole point of the
    // mapping — unexercised: flipping it to `.nominal` keeps every other
    // assertion in this file green. `ProcessInfo.ThermalState` is an imported
    // NS_ENUM whose `init(rawValue:)` accepts values Apple has not defined
    // yet, so a state added in a future macOS is both constructible here and
    // deliverable at runtime. It must map to the WORST level: mapping it to
    // `.nominal` would leave the §8.1 thermal abort disarmed while the
    // machine cooks.
    let future = try #require(ProcessInfo.ThermalState(rawValue: 99),
                              "unknown raw states must stay constructible for this guard to bite")
    #expect(SystemPowerReader.level(from: future) == .critical)
}

@Test func seriousAndCriticalOutrankTheAbortThreshold() {
    // decide() aborts on `>= .serious`. Pin the ordering the comparison
    // depends on, so reordering the enum cannot silently raise the threshold.
    #expect(ThermalLevel.nominal.rawValue < ThermalLevel.serious.rawValue)
    #expect(ThermalLevel.fair.rawValue    < ThermalLevel.serious.rawValue)
    #expect(ThermalLevel.critical.rawValue >= ThermalLevel.serious.rawValue)
}

@Test func onlyBatteryPowerCountsAsRunningOnBattery() {
    // The live `isOnBattery()` cannot discriminate its own sense: on a host
    // WITH a battery, inverting the comparison flips which branch of the test
    // below runs and every assertion still holds, and on the battery-less CI
    // runner it is never true at all. Machine topology is not a test, so the
    // decision is extracted and tabled — exactly like `level(from:)`.
    //
    // Spelled with the `kIOPM*Key` constants IOPowerSources.h documents as the
    // return values of `IOPSGetProvidingPowerSourceType`, NOT the `kIOPS*Value`
    // constants the implementation compares against. Same strings, different
    // header: the test cannot agree with a wrong implementation by sharing its
    // constant, and it pins the real API contract.
    #expect(SystemPowerReader.onBattery(providingType: kIOPMBatteryPowerKey) == true)
    #expect(SystemPowerReader.onBattery(providingType: kIOPMACPowerKey) == false)

    // A UPS is a deliberate `false`, not an oversight: §8.1 aborts on a
    // *depleting* battery at or below the floor, and a UPS is an external
    // supply the probe run is not draining.
    #expect(SystemPowerReader.onBattery(providingType: kIOPMUPSPowerKey) == false)

    // No snapshot at all, or a source type Apple adds later.
    #expect(SystemPowerReader.onBattery(providingType: nil) == false)
}

@Test func batteryAndPowerSourceReadingsAreMutuallyConsistent() {
    // Deliberately NOT `if let pct { ... }` — that form passes for a reader
    // that always returns nil, which is the failure it should catch.
    // Asserted instead: a real invariant that CAN fail. Running on battery
    // requires a battery to exist, so a nil percentage while onBattery is a
    // genuine contradiction. Both branches are meaningful, and neither is
    // vacuous on a CI runner with no battery.
    let reader = SystemPowerReader()
    let pct = reader.batteryPercent()
    if reader.isOnBattery() {
        #expect(pct != nil, "drawing from battery but no battery percentage")
    }
    #expect(pct == nil || (pct! >= 0 && pct! <= 100))
}
