// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import CoffeeBarCore
import CoffeeBarPower
@testable import CoffeeBarUI

// Issue #48, the model half. `LoginItemInstaller_test.swift` holds what a plist
// on disk has to say; this file holds what the model does with the one switch
// that governs it.
//
// NOTHING HERE REACHES `~/Library/LaunchAgents` either. Every model below is
// handed a recording installer, and the recorder writes no file at all.

// MARK: - Test doubles

/// A settings store held in memory.
///
/// The shipping default is `UserDefaultsSettingsStore()` over `.standard`, so a
/// model that took the default would read — and write — the preferences of
/// whoever runs the suite. On this setting that would be a check that turned a
/// developer's real login item on.
private final class FakeSettings: SettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init(_ initial: [String: Any] = [:]) { values = initial }

    func bool(forKey key: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return values[key] as? Bool
    }

    func setBool(_ value: Bool, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    func integer(forKey key: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return values[key] as? Int
    }

    func setInteger(_ value: Int, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    func stringArray(forKey key: String) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        return values[key] as? [String]
    }

    func setStringArray(_ value: [String], forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }
}

/// The power reader the model reads once in `init`.
private final class FakeReader: PowerReadingProviding, @unchecked Sendable {
    func read() -> PowerReading { PowerReading(source: .ac, percent: 80) }
}

/// Counts what the model asked IOKit to do, without asking IOKit to do it.
private final class SpyHolder: AssertionHolding, @unchecked Sendable {
    @discardableResult
    func acquire(displaySleep: Bool) -> Bool { true }
    func release() {}
}

/// A hook-health reader pointed at a committed fixture, so `refresh()` never
/// reads the machine's own `~/.claude/settings.json`.
private func fixtureHealth(_ name: String = "wired.json") -> HookHealthReader {
    HookHealthReader(settingsURL: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()    // …/Tests/CoffeeBarUITests
        .deletingLastPathComponent()    // …/Tests
        .appending(path: "Fixtures/claude-settings/\(name)"))
}

/// Records install and uninstall, and — the point of it — what the SETTINGS
/// SAID at the moment each one was called.
///
/// The stored answer is what makes the ordering check possible. The real
/// installer refuses unless the key already reads `true`, so a model that
/// reconciled BEFORE it recorded the choice would drive an installer that
/// refuses every time and a switch that appears to work and installs nothing.
/// A plain call counter cannot see that; this one asks the same question the
/// real installer asks, at the same moment.
private final class RecordingLoginItem: LoginItemInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private let settings: any SettingsStoring
    private var events: [String] = []
    private var optInsSeen: [Bool?] = []
    private var installed = false

    init(settings: any SettingsStoring) { self.settings = settings }

    /// `"install"` and `"uninstall"`, in the order they were called.
    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    /// What `SettingsKey.launchAtLogin` read as at each call, in the same order.
    var optInAtEachCall: [Bool?] {
        lock.lock(); defer { lock.unlock() }
        return optInsSeen
    }

    func install() throws {
        lock.lock(); defer { lock.unlock() }
        events.append("install")
        optInsSeen.append(settings.bool(forKey: SettingsKey.launchAtLogin))
        installed = true
    }

    func uninstall() throws {
        lock.lock(); defer { lock.unlock() }
        events.append("uninstall")
        optInsSeen.append(settings.bool(forKey: SettingsKey.launchAtLogin))
        installed = false
    }

    func isInstalled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return installed
    }
}

@MainActor
private func makeModel(_ settings: FakeSettings,
                       _ loginItem: RecordingLoginItem) -> ServingModel {
    ServingModel(holder: SpyHolder(), reader: FakeReader(),
                 health: fixtureHealth(), settings: settings,
                 loginItem: loginItem)
}

// MARK: - Off by default, and nothing installed until the user asks

@MainActor
@Test func aUserWhoHasNeverBeenAskedGetsNoLoginItem() {
    // The acceptance bullet, at the surface that decides it. `?? true` on this
    // read, or a seeded default written back in `init`, installs a launch agent
    // for every existing user on the first launch after the upgrade — silently,
    // and with an artifact that outlives the process.
    //
    // BUILDING the model must also install nothing. `init` reads seven settings
    // and reconciles none of them, and this is the one where reconciling on
    // launch would be indistinguishable from the feature working.
    let settings = FakeSettings()
    let item = RecordingLoginItem(settings: settings)
    let model = makeModel(settings, item)

    #expect(model.launchAtLogin == false)
    #expect(item.calls.isEmpty,
            "building the model reached the installer: \(item.calls)")
    #expect(settings.bool(forKey: SettingsKey.launchAtLogin) == nil,
            "reading the setting wrote it, so a default is now indistinguishable from a choice")
}

@MainActor
@Test func aUserWhoTurnedItOffStaysOff() {
    // The other direction of the same read. An explicit `false` is a written
    // key, and it has to read back as the answer the user gave rather than as
    // the absence of one.
    let settings = FakeSettings([SettingsKey.launchAtLogin: false])
    let item = RecordingLoginItem(settings: settings)

    #expect(makeModel(settings, item).launchAtLogin == false)
    #expect(item.calls.isEmpty)
}

@MainActor
@Test func aUserWhoTurnedItOnSeesItOnAtTheNextLaunch() {
    // The setting is read ONCE in `init`, like the other seven, so this is what
    // makes the switch show the position the user left it in. Without it the
    // window says off while the plist is on disk and launchd is honouring it —
    // the same divergence a renamed key produces, from the other end.
    let settings = FakeSettings([SettingsKey.launchAtLogin: true])
    let item = RecordingLoginItem(settings: settings)

    #expect(makeModel(settings, item).launchAtLogin)
    // Reading the position is not reconciling it. A model that installed here
    // would put the item back for a user who removed the plist by hand.
    #expect(item.calls.isEmpty)
}

// MARK: - What the switch does

@MainActor
@Test func turningItOnRecordsTheChoiceBeforeItInstalls() {
    // THE ORDERING, and it is load-bearing rather than stylistic. The installer
    // refuses unless `SettingsKey.launchAtLogin` already reads `true` — that is
    // the guard that keeps "nothing is installed until the user asks" true even
    // for a caller that forgets. So a setter that installed FIRST would drive an
    // installer that refuses every single time: the switch would move, the key
    // would be written, no plist would ever appear, and the app would still not
    // survive a reboot.
    //
    // `optInAtEachCall` is what makes that visible. It asks the store the same
    // question the real installer asks, at the moment of the call, so a `true`
    // there is the difference between a working switch and a decorative one.
    let settings = FakeSettings()
    let item = RecordingLoginItem(settings: settings)
    let model = makeModel(settings, item)

    model.launchAtLogin = true

    #expect(model.launchAtLogin)
    #expect(settings.bool(forKey: SettingsKey.launchAtLogin) == true)
    #expect(item.calls == ["install"])
    #expect(item.optInAtEachCall == [true],
            "the installer was called before the choice was recorded, so it refuses")
}

@MainActor
@Test func turningItOffRemovesTheLoginItemRatherThanOnlyForgettingIt() {
    // Named bug this catches: a setter that records `false` and stops there.
    // The window then says the app does not open at login while the plist is
    // still in `~/Library/LaunchAgents` and launchd still starts the app at
    // every boot. The user has no route back at all — the one control that
    // would remove the item now believes there is nothing to remove — which is
    // the trap the acceptance criterion names.
    let settings = FakeSettings([SettingsKey.launchAtLogin: true])
    let item = RecordingLoginItem(settings: settings)
    let model = makeModel(settings, item)
    try? item.install()

    model.launchAtLogin = false

    #expect(model.launchAtLogin == false)
    #expect(settings.bool(forKey: SettingsKey.launchAtLogin) == false)
    #expect(item.calls.last == "uninstall")
    #expect(item.isInstalled() == false)
}

@MainActor
@Test func offThenOnThenOffLeavesNoLoginItemBehind() {
    // The round trip through the SWITCH, which is the one the user performs.
    // `turningItOffRemovesEverythingTheInstallPutOnDisk` holds the same round
    // trip against a real directory; this one holds that the model drives both
    // halves of it, in order, from the control.
    let settings = FakeSettings()
    let item = RecordingLoginItem(settings: settings)
    let model = makeModel(settings, item)

    #expect(item.isInstalled() == false)

    model.launchAtLogin = true
    #expect(item.isInstalled())

    model.launchAtLogin = false

    #expect(item.isInstalled() == false)
    #expect(model.launchAtLogin == false)
    #expect(settings.bool(forKey: SettingsKey.launchAtLogin) == false)
    #expect(item.calls == ["install", "uninstall"])
    // The opt-in was `false` when the removal was issued, which is the state
    // the real installer must NOT refuse. `uninstallingIsNotGatedOnTheOptInTheWayInstallingIs`
    // is the other half of this pair.
    #expect(item.optInAtEachCall == [true, false])
}

// MARK: - What the window says about it

@Test func theLoginItemLabelSaysWhatTheSwitchDoesAndPromisesNothingElse() {
    // The label lives on the model, where a check can read it: design §5.4
    // rules out asserting on rendered AppKit text, so a label written in the
    // view is a label nothing in this package reads.
    //
    // It names OPENING THE APP, and claims nothing about holding the machine
    // awake. A login item that read as "keep my Mac awake after a reboot" would
    // be a false claim in the one direction this product cannot afford: the
    // hold is decided by the intent, the battery floor and the sessions, none
    // of which this switch touches.
    let label = ServingModel.launchAtLoginLabel

    #expect(label == "Open coffee-bar at login")
    for claim in ["awake", "sleep", "hold", "faster", "battery"] {
        #expect(label.lowercased().contains(claim) == false,
                "the login-item label claims \(claim), which this switch does not do")
    }
}

@Test func theLoginItemNoteNamesTheFileItWritesAndSaysTurningItOffRemovesIt() {
    // HONESTY ABOUT AN ARTIFACT ON DISK, and it is the sentence that earns this
    // feature the right to write a file at all. Everywhere else this product
    // prints a command and refuses to touch the user's files; here it writes
    // one, so the surface has to say which file, in a form the user can go and
    // look at.
    //
    // Named bug this catches: a note that says "opens coffee-bar at login" and
    // nothing else. The user then has an artifact in their home directory that
    // no surface has ever named, which is the state issue #48 complains about
    // from the other side — something on the machine that nothing accounts for.
    let note = ServingModel.launchAtLoginNote

    #expect(note.contains("~/Library/LaunchAgents/com.coffeebar.loginitem.plist"), """
        the note does not name the file the switch writes: "\(note)"
        """)
    #expect(note.lowercased().contains("remove"), """
        the note does not say that turning the switch off removes the file, so a \
        user cannot tell whether they can get back: "\(note)"
        """)
    // NO ROOT ANYWHERE NEAR IT. The lid-closed paragraph on the same window
    // tells the user to type `sudo`; this one must not, and a note that
    // mentioned it would send a user to a root shell for a file in their own
    // home directory.
    #expect(note.contains("sudo") == false)
}
