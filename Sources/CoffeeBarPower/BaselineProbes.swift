// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import CoffeeBarCore

public enum HostInfo {
    /// Whole-second timestamp for report stamping.
    ///
    /// `OutputFormatter` encodes dates as ISO-8601, which has second
    /// granularity. A sub-second `Date()` therefore cannot round-trip, and a
    /// round-trip test written against a whole-number fixture would pass for
    /// a reason that does not generalise. Truncating at the source makes
    /// `decode(encode(report)) == report` a real invariant rather than a
    /// property of the test data.
    public static func now() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    public static func stamp() -> HostStamp {
        HostStamp(hardwareModel: sysctlString("hw.model"),
                  osVersion: ProcessInfo.processInfo
                      .operatingSystemVersionString.osVersionNumber(),
                  osBuild: sysctlString("kern.osversion"),
                  arch: sysctlString("hw.machine"))
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }
}

private extension String {
    /// "Version 26.5.2 (Build 25F84)" -> "26.5.2"
    func osVersionNumber() -> String {
        let parts = split(separator: " ")
        guard parts.count >= 2 else { return self }
        return String(parts[1])
    }
}

public protocol PowerReading: Sendable {
    func thermalLevel() -> ThermalLevel
    func batteryPercent() -> Int?
    func isOnBattery() -> Bool
}

public struct SystemPowerReader: PowerReading {
    public init() {}

    /// Pure mapping, extracted so every documented state is testable without
    /// needing to drive the hardware into thermal distress. The live reader
    /// below is a one-line adapter over it.
    public static func level(from state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal:  return .nominal
        case .fair:     return .fair
        case .serious:  return .serious
        case .critical: return .critical
        @unknown default: return .critical   // unknown means treat as worst
        }
    }

    public func thermalLevel() -> ThermalLevel {
        Self.level(from: ProcessInfo.processInfo.thermalState)
    }

    public func batteryPercent() -> Int? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?
                  .takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return Int((Double(current) / Double(max)) * 100.0)
        }
        return nil
    }

    public func isOnBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return false
        }
        let source = IOPSGetProvidingPowerSourceType(blob)?
            .takeRetainedValue() as String?
        return source == kIOPSBatteryPowerValue
    }
}

/// Baseline: prove we can hold and release the assertion KeepingYouAwake
/// uses. This is the M1 floor — if it fails, nothing else matters.
public struct AssertionProbe {
    public init() {}

    public func run() -> SpikeResult {
        let start = Date()
        var assertionID: IOPMAssertionID = 0
        let rc = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "coffee-bar probe baseline" as CFString,
            &assertionID)
        let released: Bool
        if rc == kIOReturnSuccess {
            released = IOPMAssertionRelease(assertionID) == kIOReturnSuccess
        } else {
            released = false
        }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        return SpikeResult(
            id: .baseline,
            verdict: rc == kIOReturnSuccess && released ? .pass : .fail,
            detail: rc == kIOReturnSuccess
                ? "PreventUserIdleSystemSleep acquired and released"
                : "IOPMAssertionCreateWithName failed",
            durationMS: ms,
            evidence: ["assertionReturnCode": String(rc),
                       "released": String(released)])
    }
}
