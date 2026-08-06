// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IOKit

/// S2 — is the internal panel actually powered while the lid is shut?
///
/// Handoff §2.2: raw `disablesleep` leaves the internal panel lit under a
/// closed lid, silently burning the battery the feature exists to save. This
/// probe reads `IODisplayWrangler`'s power state so the spike can tell.
///
/// Measured on the M0 development host (Apple Silicon, macOS 26.5.2):
/// `IODisplayWrangler` matches, but its property dictionary carries no
/// `IOPowerManagement` key at all, so this probe answers `nil` there. That is
/// the honest answer rather than a defect — `IOMobileFramebufferAP` is the
/// service that publishes a power state on that hardware, and its
/// `MaxPowerState` is 1 rather than 4, so the wrangler's scale does not carry
/// over. Retargeting is a design decision for the spike write-up, not
/// something to guess at here.
/// `Sendable` because its whole state is one immutable `String`; the IOKit
/// handles it opens live inside a single call and never outlive it. M5's
/// `PmsetDisplaySleeper` holds one across the concurrency boundary.
public struct DisplayStateProbe: Sendable {
    /// Overridable only so the unreadable-registry path can be exercised
    /// deterministically; every caller uses the default.
    private let serviceName: String

    public init(serviceName: String = "IODisplayWrangler") {
        self.serviceName = serviceName
    }

    /// Returns `nil` when the wrangler cannot be read, so callers can
    /// distinguish "unknown" from "asleep". Collapsing the two would report a
    /// lit screen as dark — the exact false negative that would make S2
    /// conclude the drain it is hunting for is absent.
    public func isInternalDisplayAwake() -> Bool? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching(serviceName))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
                service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return nil }

        return Self.displayAwake(fromProperties: properties)
    }

    /// The decision, split from the registry read so the power-state ladder can
    /// be tested against fixtures rather than against whatever hardware the
    /// suite happens to run on.
    ///
    /// `IODisplayWrangler` runs states 0...4 and only 4 is fully on; 3 is the
    /// dimmed state entered just before display sleep, so treating anything
    /// below 4 as awake would fire on every idle machine.
    static func displayAwake(fromProperties properties: [String: Any]) -> Bool? {
        guard let management = properties["IOPowerManagement"] as? [String: Any],
              let current = management["CurrentPowerState"] as? Int
        else { return nil }
        return current >= 4
    }
}
