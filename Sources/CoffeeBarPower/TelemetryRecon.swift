// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoffeeBarCore

/// Handoff §15.4's three modes.
public enum TelemetryMode: String, Codable, Sendable {
    case ownIt    // no existing config; coffee-bar may write its own
    case fanOut   // user-scope config exists; forward to their endpoint
    case passive  // managed settings present; Token Tap disabled, and says so
}

/// S8 — determine which telemetry mode applies before the Token Tap (§15)
/// is designed. Pure file inspection; no network, no process launch.
///
/// This must be re-evaluated at runtime and never cached: an MDM-managed
/// machine can acquire managed settings at any time.
public struct TelemetryRecon {
    public static let defaultManagedSettingsURL = URL(fileURLWithPath:
        "/Library/Application Support/ClaudeCode/managed-settings.json")

    private let managedSettingsURL: URL
    private let userSettingsURL: URL
    private let codexConfigURL: URL

    public init(managedSettingsURL: URL = TelemetryRecon.defaultManagedSettingsURL,
                userSettingsURL: URL = FileManager.default
                    .homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude/settings.json"),
                codexConfigURL: URL = FileManager.default
                    .homeDirectoryForCurrentUser
                    .appendingPathComponent(".codex/config.toml")) {
        self.managedSettingsURL = managedSettingsURL
        self.userSettingsURL = userSettingsURL
        self.codexConfigURL = codexConfigURL
    }

    public func detectMode() -> TelemetryMode {
        if fileMentionsOTEL(managedSettingsURL) { return .passive }
        if fileMentionsOTEL(userSettingsURL) { return .fanOut }
        if fileHasOtelSection(codexConfigURL) { return .fanOut }
        return .ownIt
    }

    public func run() -> SpikeResult {
        let start = Date()
        let mode = detectMode()
        return SpikeResult(
            id: .s8TelemetryCollision,
            verdict: .pass,
            detail: "telemetry mode: \(mode.rawValue)",
            durationMS: Int(Date().timeIntervalSince(start) * 1000),
            evidence: [
                "mode": mode.rawValue,
                "managedSettingsPresent":
                    String(FileManager.default.fileExists(
                        atPath: managedSettingsURL.path)),
                "userSettingsHasOTEL": String(fileMentionsOTEL(userSettingsURL)),
                "codexHasOtelSection": String(fileHasOtelSection(codexConfigURL)),
            ])
    }

    private func fileMentionsOTEL(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return String(decoding: data, as: UTF8.self).contains("OTEL_")
    }

    private func fileHasOtelSection(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces) == "[otel]" }
    }
}
