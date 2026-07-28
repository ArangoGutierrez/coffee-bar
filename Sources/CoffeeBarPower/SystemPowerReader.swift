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

    public func read() -> PowerReading {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue()
                as? [CFTypeRef]
        else {
            // Unreadable is reported as AC with no battery: the safe default,
            // because it never suppresses a hold the user asked for.
            return PowerReading(source: .ac, percent: nil)
        }

        for source in sources {
            // `IOPSGetPowerSourceDescription` is an unaudited Get — the result
            // must be taken unretained. See docs/ENGINEERING-NOTES.md.
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any]
            else { continue }

            let onAC = (description[kIOPSPowerSourceStateKey] as? String)
                == kIOPSACPowerValue

            guard let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0
            else { continue }

            let percent = Int((Double(current) / Double(maximum) * 100).rounded())
            return PowerReading(source: onAC ? .ac : .battery, percent: percent)
        }

        return PowerReading(source: .ac, percent: nil)
    }
}
