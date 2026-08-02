// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Answers "which build is this?" for the panel.
///
/// `scripts/build-app.sh` stamps `CFBundleShortVersionString` from `git
/// describe`, falling back to `0.0.0-dev`. This renders that stamp for display.
///
/// The rule is that it never invents a version. Every unusable stamp — absent
/// dictionary, missing key, non-string value, blank string — reports `unknown`,
/// because stating a build that is not running is worse than stating nothing.
public enum AppVersion {
    /// The Info.plist key that `scripts/build-app.sh` stamps.
    static let bundleKey = "CFBundleShortVersionString"

    /// Reported whenever no usable stamp exists.
    static let unknown = "unknown"

    /// Render the version stamp for display.
    ///
    /// - Parameter info: a bundle info dictionary, or `nil` when running
    ///   outside a bundle (`swift run` has no info dictionary at all).
    /// - Returns: the stamp with surrounding whitespace trimmed, or `unknown`.
    public static func display(from info: [String: Any]?) -> String {
        guard let raw = info?[bundleKey] as? String else { return unknown }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? unknown : trimmed
    }
}
