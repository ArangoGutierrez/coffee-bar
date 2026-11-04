// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import CoffeeBarPower

@MainActor
public struct SystemSleepRequester: SystemSleepRequesting {
    public init() {}

    public func requestSleep() throws {
        try SystemSleep.request()
    }
}
