// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IOKit.ps
import CoffeeBarCore

/// A single power-source sample.
public struct PowerReading: Equatable, Sendable {
    public let source: PowerSource
    /// `nil` where the machine reports no battery, such as a desktop.
    public let percent: Int?

    public init(source: PowerSource, percent: Int?) {
        self.source = source
        self.percent = percent
    }
}

/// Injection seam: the app depends on this, tests supply a fake.
public protocol PowerReadingProviding: Sendable {
    func read() -> PowerReading
}

/// Reads battery percentage and AC state from IOKit.
///
/// This is an extension, not a new type, because `SystemPowerReader` already
/// exists in `BaselineProbes.swift` as the M0 host reader. Two types in one
/// module both named for reading this machine's power would be a name clash at
/// best and a silent split of one concept at worst, so `read()` joins the
/// reader that is already here.
extension SystemPowerReader: PowerReadingProviding {

    /// Pure decision, extracted for the same reason as `level(from:)` and
    /// `onBattery(providingType:)` in BaselineProbes.swift: which sources this
    /// machine reports is a property of what is plugged into it, and a UPS is
    /// not something a developer or a CI runner has. Machine topology is not a
    /// test, so the decision is testable on its own here and `read()` is the
    /// thin IOKit shim over it.
    ///
    /// `source` comes from `IOPSGetProvidingPowerSourceType` by way of the M0
    /// decision, not from any one source's `kIOPSPowerSourceStateKey`. The
    /// per-source key describes the source that was picked first, so it made
    /// this type answer "is this machine on battery" by a second mechanism that
    /// could disagree with `isOnBattery()`.
    ///
    /// `percent` comes only from a source of type `kIOPSInternalBatteryType`. A
    /// UPS charge is not the battery percentage: §8.1 suppresses a hold because
    /// a depleting internal battery invalidates the run, and a UPS is an
    /// external supply the run is not draining.
    static func reading(from descriptions: [[String: Any]],
                        providingType: String?) -> PowerReading {
        let source: PowerSource =
            onBattery(providingType: providingType) ? .battery : .ac

        for description in descriptions {
            guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0
            else { continue }

            let percent = Int((Double(current) / Double(maximum) * 100).rounded())
            return PowerReading(source: source, percent: percent)
        }

        return PowerReading(source: source, percent: nil)
    }

    public func read() -> PowerReading {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue()
                as? [CFTypeRef]
        else {
            // Unreadable is reported as AC with no battery: the safe default,
            // because it never suppresses a hold the user asked for.
            return PowerReading(source: .ac, percent: nil)
        }

        // `IOPSGetPowerSourceDescription` is an unaudited Get — the result
        // must be taken unretained. See docs/ENGINEERING-NOTES.md.
        let descriptions = sources.compactMap {
            IOPSGetPowerSourceDescription(blob, $0)?
                .takeUnretainedValue() as? [String: Any]
        }
        // `IOPSGetProvidingPowerSourceType` is a Get for the same reason, so it
        // takes the same accessor as `isOnBattery()` in BaselineProbes.swift.
        // The two calls answer one question and must not differ, in mechanism
        // or in memory management.
        let providingType = IOPSGetProvidingPowerSourceType(blob)?
            .takeUnretainedValue() as String?

        return Self.reading(from: descriptions, providingType: providingType)
    }
}
