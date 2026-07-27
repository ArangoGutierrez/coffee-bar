// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarPower
@testable import CoffeeBarCore

@Test func nowIsTruncatedToWholeSeconds() {
    // Contract for ISO-8601 round-tripping: no sub-second component.
    // Fails immediately if someone "simplifies" now() back to Date().
    let t = HostInfo.now().timeIntervalSince1970
    #expect(t == t.rounded(.down))
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
    let result = AssertionProbe().run()
    #expect(result.id == .baseline)
    #expect(result.verdict == .pass)
    #expect(result.evidence["assertionReturnCode"] == "0")
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
