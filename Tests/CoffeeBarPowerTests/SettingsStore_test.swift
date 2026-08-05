// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import CoffeeBarPower

/// The settings seam, tested against a THROWAWAY suite.
///
/// Never `UserDefaults.standard`. A check that wrote there would edit the
/// preferences of whoever ran the suite, and would then read whatever the
/// previous run left behind — so it would pass on a machine where the feature
/// was broken and the key happened to be set by hand.
///
/// Each check owns a suite named after a fresh UUID and removes the persistent
/// domain on the way out, so no two runs and no two checks can see each other.
@Suite(.serialized)
struct SettingsStoreTests {

    /// A store over a private suite, plus the domain name so the check can
    /// build a SECOND store over the same storage.
    private func throwawaySuite() throws -> (name: String, defaults: UserDefaults) {
        let name = "coffee-bar-settings-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name),
                                    "UserDefaults refused the suite \(name)")
        return (name, defaults)
    }

    // MARK: - Unset is not false

    @Test func anUnreadKeyAnswersNilRatherThanFalse() throws {
        let suite = try throwawaySuite()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let store = UserDefaultsSettingsStore(defaults: suite.defaults)

        // Named bug this catches, and it is the reason these return optionals:
        // `UserDefaults.bool(forKey:)` answers `false` for a key nobody ever
        // wrote, and `integer(forKey:)` answers 0. A caller cannot then tell
        // "the user turned it off" from "the user has never been asked", and
        // issue #11's battery floor would read a 0% floor as a real setting —
        // a floor that never suppresses, silently.
        #expect(store.bool(forKey: "neverWritten") == nil)
        #expect(store.integer(forKey: "neverWrittenEither") == nil)
    }

    @Test func anExplicitFalseIsNotTheSameAsUnset() throws {
        let suite = try throwawaySuite()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let store = UserDefaultsSettingsStore(defaults: suite.defaults)

        #expect(store.bool(forKey: SettingsKey.holdDisplayAwake) == nil)

        store.setBool(false, forKey: SettingsKey.holdDisplayAwake)

        // `false`, not `nil`. A store that wrote nothing for `false` would pass
        // the check above for ever and could never record a deliberate opt-out.
        #expect(store.bool(forKey: SettingsKey.holdDisplayAwake) == false)
    }

    // MARK: - Round trip

    @Test func aBoolReadsBackAsItWasWritten() throws {
        let suite = try throwawaySuite()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let store = UserDefaultsSettingsStore(defaults: suite.defaults)

        store.setBool(true, forKey: SettingsKey.holdDisplayAwake)
        #expect(store.bool(forKey: SettingsKey.holdDisplayAwake) == true)

        store.setBool(false, forKey: SettingsKey.holdDisplayAwake)
        #expect(store.bool(forKey: SettingsKey.holdDisplayAwake) == false)
    }

    @Test func anIntegerReadsBackAsItWasWritten() throws {
        let suite = try throwawaySuite()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let store = UserDefaultsSettingsStore(defaults: suite.defaults)

        // The store is a KEY-VALUE store and not a display-only flag, because
        // issue #11 puts a configurable battery floor through this same seam.
        // An Int half nothing exercises is an Int half nobody has run.
        store.setInteger(35, forKey: "batteryFloorPercent")
        #expect(store.integer(forKey: "batteryFloorPercent") == 35)
    }

    @Test func twoKeysDoNotOverwriteEachOther() throws {
        let suite = try throwawaySuite()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let store = UserDefaultsSettingsStore(defaults: suite.defaults)

        store.setBool(true, forKey: SettingsKey.holdDisplayAwake)
        store.setInteger(35, forKey: "batteryFloorPercent")

        #expect(store.bool(forKey: SettingsKey.holdDisplayAwake) == true)
        #expect(store.integer(forKey: "batteryFloorPercent") == 35)
    }

    // MARK: - Surviving a restart

    @Test func aSettingWrittenByOneStoreIsReadByTheNextOne() throws {
        let suite = try throwawaySuite()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }

        UserDefaultsSettingsStore(defaults: suite.defaults)
            .setBool(true, forKey: SettingsKey.holdDisplayAwake)

        // A SECOND store, built the way the NEXT launch builds one: from the
        // suite name and nothing else. A store that kept the value in a
        // property of the instance that wrote it passes every check above and
        // fails this one.
        let relaunched = UserDefaultsSettingsStore(
            defaults: try #require(UserDefaults(suiteName: suite.name)))

        #expect(relaunched.bool(forKey: SettingsKey.holdDisplayAwake) == true)
    }

    @Test func theSettingLandsInThePersistentDomainAndNotInAVolatileOne() throws {
        let suite = try throwawaySuite()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }

        UserDefaultsSettingsStore(defaults: suite.defaults)
            .setBool(true, forKey: SettingsKey.holdDisplayAwake)

        // This is the half a second in-process store CANNOT prove, and the
        // limit is stated rather than hidden: the check above builds a fresh
        // store, but `UserDefaults` caches a suite for the life of the process,
        // so a value held only in memory would still satisfy it.
        //
        // The PERSISTENT domain is the one written to disk and re-read at the
        // next launch. `setVolatileDomain` — the obvious way to get a setting
        // that works all session and is gone tomorrow — never appears here.
        let persisted = suite.defaults.persistentDomain(forName: suite.name)
        #expect(persisted?[SettingsKey.holdDisplayAwake] as? Bool == true,
                "the setting is not in the persistent domain: \(persisted ?? [:])")
    }

    // MARK: - The key is a stored format, not an implementation detail

    @Test func theDisplayHoldKeyStringNeverChanges() {
        // The key is written to the user's preferences on ONE launch and read
        // back on the NEXT, so it is a stored format and not a name that may be
        // tidied. Renaming the constant silently discards the setting of every
        // user who already opted in: the next launch reads a key nobody wrote,
        // gets `nil`, and falls back to the default with no error anywhere.
        //
        // Every round-trip check above stays green through such a rename,
        // because each one writes and reads through the SAME constant. Only a
        // literal can hold this line.
        #expect(SettingsKey.holdDisplayAwake == "holdDisplayAwake")
    }

    @Test func theBatteryFloorKeyStringNeverChanges() {
        // Issue #11's key, held for the reason above: renaming the constant
        // discards the floor of every user who already chose one, and the next
        // launch falls back to the default with nothing to report.
        //
        // The round-trip checks in this file write the literal directly, so a
        // rename leaves every one of them green. Only this line holds the name.
        #expect(SettingsKey.batteryFloorPercent == "batteryFloorPercent")
    }

    @Test func theTwoKeysAreDifferentStrings() {
        // One key for two settings is the failure the `SettingsKey` doc comment
        // describes: the display opt-in and the battery floor would overwrite
        // each other, and the type mismatch on the read would then answer `nil`
        // for both. `twoKeysDoNotOverwriteEachOther` above proves the STORE
        // keeps two keys apart; this proves the app asks it for two.
        #expect(SettingsKey.holdDisplayAwake != SettingsKey.batteryFloorPercent)
    }

    // MARK: - The demotable set (issue #14)

    @Test func theDemotableKeyStringNeverChangesAndCollidesWithNothing() {
        // Held for the reason the other two keys are: a rename discards the
        // demotable set of every user who chose one, silently, and the next
        // launch demotes nothing with nothing to report.
        #expect(SettingsKey.demotableProcessNames == "demotableProcessNames")
        #expect(SettingsKey.demotableProcessNames != SettingsKey.holdDisplayAwake)
        #expect(SettingsKey.demotableProcessNames != SettingsKey.batteryFloorPercent)
    }

    @Test func anUnsetDemotableSetIsEmptyAndNotEverything() throws {
        // Handoff §2.3: "Default `demotable` to empty. Opt-in only." THE bug
        // this catches is an unset list read as "no restriction", which is how
        // an allow list becomes a deny list by accident — every same-uid process
        // on the machine would become eligible for throttling, with no user
        // having asked for any of it.
        let suite = try throwawaySuite()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let store = UserDefaultsSettingsStore(defaults: suite.defaults)

        #expect(store.stringArray(forKey: SettingsKey.demotableProcessNames) == nil)
        #expect(store.demotableProcessNames().isEmpty)
    }

    @Test func aDemotableSetSurvivesARestart() throws {
        // The setting is a STORED FORMAT: written on one launch and read on the
        // next. A second store over the same storage is what a restart looks
        // like, and an in-memory-only setting would pass a same-store read-back.
        let suite = try throwawaySuite()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let store = UserDefaultsSettingsStore(defaults: suite.defaults)

        store.setStringArray(["Xcode", "node"], forKey: SettingsKey.demotableProcessNames)

        let nextLaunch = UserDefaultsSettingsStore(defaults: suite.defaults)
        #expect(nextLaunch.demotableProcessNames() == ["Xcode", "node"])
    }

    @Test func aValueOfTheWrongTypeReadsAsEmptyRatherThanCrashing() throws {
        // `UserDefaults` holds whatever anybody writes, and a plist a user or an
        // older build edited by hand can carry a string where a list belongs.
        // The bug this catches is a force-cast: the app would trap at launch on
        // a preference file it does not control. Empty is the safe answer,
        // because empty demotes nothing.
        let suite = try throwawaySuite()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        suite.defaults.set("Xcode", forKey: SettingsKey.demotableProcessNames)
        let store = UserDefaultsSettingsStore(defaults: suite.defaults)

        #expect(store.stringArray(forKey: SettingsKey.demotableProcessNames) == nil)
        #expect(store.demotableProcessNames().isEmpty)
    }

    @Test func aDuplicatedEntryIsOneMemberOfTheSet() throws {
        // A list is what a user edits; a set is what the policy needs. The bug
        // this catches is a policy fed an array, where a duplicate would make
        // `contains` do the same work twice and, worse, would let the count of
        // the demotable set disagree with the number of processes it names.
        let suite = try throwawaySuite()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let store = UserDefaultsSettingsStore(defaults: suite.defaults)

        store.setStringArray(["node", "node", "Xcode"], forKey: SettingsKey.demotableProcessNames)

        #expect(store.demotableProcessNames() == ["node", "Xcode"])
    }
}
