// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Where the machine is drawing power from.
public enum PowerSource: String, Codable, Sendable {
    case ac
    case battery
}

/// What the user last asked for through the menu-bar toggle.
public enum UserIntent: String, Codable, Sendable {
    case serve
    case stop
}

/// Why a requested hold is not being honoured.
///
/// Carries the measured value, not just the case, so the UI can say "battery
/// 18%, floor 20%" rather than something vague the user cannot check.
public enum HoldSuppression: Equatable, Sendable {
    case batteryFloor(percent: Int, floor: Int)
}
