// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IOKit.pwr_mgt

/// The power-layer operation for an explicit system sleep request.
public enum SystemSleep {
    public static func request() throws {
        let connection = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard connection != MACH_PORT_NULL else {
            throw NSError(domain: "coffee-bar.sleep", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Power management is unavailable."])
        }
        defer { IOServiceClose(connection) }
        let result = IOPMSleepSystem(connection)
        guard result == kIOReturnSuccess else {
            throw NSError(domain: "coffee-bar.sleep", code: Int(result),
                          userInfo: [NSLocalizedDescriptionKey: "macOS refused the sleep request (\(result))."])
        }
    }
}
