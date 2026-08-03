// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Every preference key, spelled once.
///
/// A key is a STORED FORMAT: it is written on one launch and read on the next.
/// Two spellings of the same setting is not a tidiness problem — it is a
/// setting that works until the app restarts and then quietly reverts, with
/// nothing to report and no error to read. `theDisplayHoldKeyStringNeverChanges`
/// holds the string itself.
public enum SettingsKey {

    /// Whether the user asked coffee-bar to hold the display awake as well as
    /// the system (issue #12).
    ///
    /// Absent by default, and the default is `false`: coffee-bar lets the
    /// screen sleep unless the user says otherwise. That is the product's
    /// difference from the blunt tools — a default now, rather than a promise.
    public static let holdDisplayAwake = "holdDisplayAwake"
}

/// Where a user preference is kept.
///
/// A protocol, so a check never touches the preferences of whoever runs the
/// suite. It is the same shape of seam as `AssertionHolding` and
/// `PowerReadingProviding`: one real implementation, injected at the boundary.
///
/// **Every read answers `Optional`, and that is the whole reason this exists
/// rather than a bare `UserDefaults` call.** `UserDefaults.bool(forKey:)`
/// returns `false` for a key nobody has ever written and `integer(forKey:)`
/// returns 0, so a caller cannot tell a deliberate opt-out from a question
/// never asked. For issue #11's battery floor that difference is the whole
/// setting: an unset key read as 0 is a floor that never suppresses.
///
/// It stays a small KEY-VALUE store rather than a typed record of the app's
/// settings. Issue #11 puts a second, unrelated preference through it, and a
/// typed record would have to be edited for each one.
public protocol SettingsStoring: Sendable {
    /// The stored flag, or `nil` when the key has never been written.
    func bool(forKey key: String) -> Bool?
    func setBool(_ value: Bool, forKey key: String)

    /// The stored number, or `nil` when the key has never been written.
    func integer(forKey key: String) -> Int?
    func setInteger(_ value: Int, forKey key: String)
}

/// The real store, over `UserDefaults`.
///
/// `@unchecked Sendable` because `UserDefaults` carries no `Sendable`
/// conformance of its own. The conformance is sound rather than convenient:
/// Apple documents `UserDefaults` as thread-safe, this type adds no mutable
/// state beside it, and every method here is a single call into that class.
///
/// The suite is injected so a check can hand in a throwaway domain. The default
/// is `.standard`, which is the user's own preferences and is what the app
/// builds.
public struct UserDefaultsSettingsStore: SettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `object(forKey:)` and not `bool(forKey:)`, deliberately.
    ///
    /// `bool(forKey:)` maps a missing key to `false`, which is the one answer
    /// this seam exists to keep apart from a stored `false`. `object(forKey:)`
    /// returns `nil` for a key that was never written, and the cast then
    /// reports the stored type honestly.
    public func bool(forKey key: String) -> Bool? {
        defaults.object(forKey: key) as? Bool
    }

    public func setBool(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    /// `object(forKey:)` for the reason `bool(forKey:)` uses it: the built-in
    /// `integer(forKey:)` maps a missing key to 0, and 0 is a legitimate value
    /// for a percentage.
    public func integer(forKey key: String) -> Int? {
        defaults.object(forKey: key) as? Int
    }

    public func setInteger(_ value: Int, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}
