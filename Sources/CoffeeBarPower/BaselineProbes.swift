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
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        // `String(cString:)` over an array is deprecated. sysctl writes a
        // NUL-terminated C string into a buffer it sized to include that
        // terminator, so the bytes before the first NUL are the value.
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
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

    /// Pure decision, extracted for the same reason as `level(from:)`: the
    /// live reader's answer is a property of what this machine is plugged
    /// into. On a host with a battery, inverting this comparison changes which
    /// branch of a live test runs but nothing it can observe; on a CI runner
    /// with no battery the true branch is unreachable. Machine topology is not
    /// a test, so the decision is testable on its own here.
    ///
    /// `IOPSGetProvidingPowerSourceType` returns exactly one of
    /// `kIOPMACPowerKey`, `kIOPMBatteryPowerKey` or `kIOPMUPSPowerKey`
    /// (IOPowerSources.h). UPS power is deliberately *not* "on battery":
    /// §8.1 aborts at the battery floor because a depleting internal battery
    /// invalidates a probe run, whereas a UPS is an external supply the run is
    /// not draining. `nil` — no snapshot, or a source type added in a future
    /// macOS — is likewise not "on battery", so an unreadable power source
    /// cannot trigger a spurious abort.
    public static func onBattery(providingType: String?) -> Bool {
        providingType == kIOPSBatteryPowerValue
    }

    public func isOnBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return false
        }
        // `IOPSGetProvidingPowerSourceType` is a CF *Get*, not a Copy or
        // Create: it returns a reference this call does not own, so the
        // unretained accessor is the correct one — matching the sibling Get at
        // `IOPSGetPowerSourceDescription` above. `takeRetainedValue()` here
        // would consume a retain nobody performed.
        let source = IOPSGetProvidingPowerSourceType(blob)?
            .takeUnretainedValue() as String?
        return Self.onBattery(providingType: source)
    }
}

/// Baseline: prove we can hold and release the assertion KeepingYouAwake
/// uses. This is the M1 floor — if it fails, nothing else matters.
public struct AssertionProbe {

    /// The name this probe's assertion carries in `pmset -g assertions`.
    ///
    /// Public for the same reason `AssertionHolder.assertionName` is: it is
    /// what a user greps for to find out what is holding the machine awake,
    /// and the handle a test needs to find this assertion in live IOKit state.
    /// Deliberately distinct from the holder's name — this one is a one-shot
    /// capability check, and sharing a name would make a stranded assertion
    /// impossible to attribute to the code that stranded it.
    public static let assertionName = "coffee-bar probe baseline"

    public init() {}

    public func run() -> SpikeResult {
        run(whileHeld: {})
    }

    /// `run()` with an observation seam.
    ///
    /// `whileHeld` is invoked after the assertion is created and before it is
    /// released — the only window in which the assertion exists to be read
    /// back out of `IOPMCopyAssertionsByProcess`. Without it, acquire and
    /// release are atomic from outside and the returned `SpikeResult` cannot
    /// distinguish this probe from one holding `PreventUserIdleDisplaySleep`,
    /// the assertion coffee-bar exists in order *not* to hold (§6.1).
    /// `run()` is the only production caller and passes an empty body.
    func run(whileHeld: () -> Void) -> SpikeResult {
        let start = Date()
        var assertionID: IOPMAssertionID = 0
        let rc = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.assertionName as CFString,
            &assertionID)
        let released: Bool
        if rc == kIOReturnSuccess {
            whileHeld()
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
