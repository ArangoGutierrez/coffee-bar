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

    /// The charge at or below which coffee-bar stops holding the machine awake
    /// (issue #11).
    ///
    /// Absent by default, and the default is `BatteryFloor.default`. Absent is
    /// NOT zero here, and this is the key the `Int?` on `integer(forKey:)`
    /// exists for: a missing key read as 0 is a floor that fires only once the
    /// machine is already dead. `theBatteryFloorKeyStringNeverChanges` holds the
    /// string itself.
    public static let batteryFloorPercent = "batteryFloorPercent"

    /// The process names the user opted in to E-core demotion (issue #14).
    ///
    /// Absent by default, and the default is EMPTY. Absent is not "everything"
    /// here, and that difference is the whole setting: handoff §2.3 makes the
    /// demotable set opt-in only, because an app that silently E-core-demotes a
    /// compile job or a video call will be uninstalled the same day.
    /// `anUnsetDemotableSetIsEmptyAndNotEverything` holds it.
    ///
    /// A name is matched EXACTLY against the name the kernel reports, never as a
    /// prefix or a substring. This list decides what MAY be demoted, so a loose
    /// match widens the blast radius rather than narrowing it.
    public static let demotableProcessNames = "demotableProcessNames"
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

    /// The stored list, or `nil` when the key has never been written OR holds
    /// something that is not a list of strings.
    ///
    /// The two are folded together on purpose. `UserDefaults` holds whatever
    /// anybody writes, and a preferences file a user or an older build edited by
    /// hand can carry a bare string where a list belongs. Both cases mean the
    /// same thing to every caller — there is no usable list — and the demotable
    /// set reads either as empty, which demotes nothing.
    func stringArray(forKey key: String) -> [String]?
    func setStringArray(_ value: [String], forKey key: String)
}

extension SettingsStoring {

    /// The demotable set the user configured, as a set. Empty when unset.
    ///
    /// **Empty is the default and empty means nothing is demotable.** Handoff
    /// §2.3 makes this opt-in only. Reading an absent key as "no restriction"
    /// turns an allow list into a deny list and makes every same-uid process on
    /// the machine eligible, which is the failure this whole seam exists to
    /// prevent.
    ///
    /// A set rather than the stored array, because that is what
    /// `DemotionPolicy` needs and a user's list may repeat an entry.
    public func demotableProcessNames() -> Set<String> {
        Set(stringArray(forKey: SettingsKey.demotableProcessNames) ?? [])
    }
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

    /// `object(forKey:)` and a conditional cast, never `stringArray(forKey:)`.
    ///
    /// The built-in `UserDefaults.stringArray(forKey:)` also answers `nil` for a
    /// wrong type, so the difference here is smaller than for the two above —
    /// but the cast is written out so a preferences file carrying a string, a
    /// number or a list of numbers under this key reads as `nil` rather than
    /// trapping. The app does not own that file and cannot assume its shape.
    public func stringArray(forKey key: String) -> [String]? {
        defaults.object(forKey: key) as? [String]
    }

    public func setStringArray(_ value: [String], forKey key: String) {
        defaults.set(value, forKey: key)
    }
}
