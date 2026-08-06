// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
@testable import CoffeeBarCore

@Test func theOfferedFloorsAreDerivedFromTheRangeAndStep() {
    // Named bug this catches: a hand-edited `choices` list that disagrees with
    // `permitted` — the exact drift the old literal [10, 20, 30, 40, 50] made
    // possible, and which put `default` outside the offered set.
    #expect(BatteryFloor.choices == [10, 15, 20, 25, 30, 35, 40, 45, 50])
    #expect(BatteryFloor.choices.first == BatteryFloor.permitted.lowerBound)
    #expect(BatteryFloor.choices.last == BatteryFloor.permitted.upperBound)
}

@Test func theDefaultIsReachableFromTheControl() {
    // A default a user cannot get back to is a setting with no undo.
    #expect(BatteryFloor.choices.contains(BatteryFloor.default))
    #expect(BatteryFloor.default == 15)
}

@Test func aStoredFloorOutsideTheNewRangeIsClampedNotTrapped() {
    // Migration: someone stored 75 under the old 5...100 policy.
    #expect(BatteryFloor.bounded(75) == 50)
    #expect(BatteryFloor.bounded(5) == 10)
    #expect(BatteryFloor.bounded(15) == 15)   // idempotent inside the range
}
