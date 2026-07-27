// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum PowerControlError: Error, Equatable {
    case commandFailed(exitCode: Int32, stderr: String)
    case unreadableState(String)
}

public protocol SleepDisabledControlling: Sendable {
    func isEnabled() throws -> Bool
    func set(_ on: Bool) throws
}

/// Reads and writes the undocumented `SleepDisabled` system power setting.
///
/// Verified on macOS 26.5.2 (25F84): `disablesleep` appears zero times in
/// `man pmset`, and when unset the key is omitted from `pmset -g` entirely
/// rather than printed as 0. It persists in
/// `/Library/Preferences/com.apple.PowerManagement.plist` under
/// `SystemPowerSettings`, so it survives reboot.
public struct PmsetSleepDisabledController: SleepDisabledControlling {
    public static let pmsetPath = "/usr/bin/pmset"

    private let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    public func isEnabled() throws -> Bool {
        let r = try runner.run(Self.pmsetPath, ["-g"])
        guard r.exitCode == 0 else {
            throw PowerControlError.commandFailed(
                exitCode: r.exitCode, stderr: r.stderr)
        }
        for line in r.stdout.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count >= 2, fields[0] == "SleepDisabled" {
                switch fields[1] {
                case "1": return true
                case "0": return false
                // A value we cannot interpret must not collapse to "off". The
                // caller would conclude there is nothing to revert and leave a
                // genuinely-held flag set across the next reboot, which is the
                // failure this whole component exists to prevent.
                default:
                    throw PowerControlError.unreadableState(
                        "SleepDisabled=\(fields[1])")
                }
            }
        }
        return false   // key absent means unset
    }

    public func set(_ on: Bool) throws {
        let r = try runner.run(Self.pmsetPath,
                               ["-a", "disablesleep", on ? "1" : "0"])
        guard r.exitCode == 0 else {
            throw PowerControlError.commandFailed(
                exitCode: r.exitCode, stderr: r.stderr)
        }
    }
}
