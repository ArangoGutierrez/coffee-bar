// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarPower

// Issue #48: the menu-bar app does not survive a reboot.
//
// NOTHING IN THIS FILE EVER TOUCHES `~/Library/LaunchAgents`. Every installer
// built here is handed a scratch directory AND an in-memory settings store, for
// the same reason `LaunchDaemonInstaller_test.swift` never reaches the real
// `launchctl`: installing a live login item on the machine running the suite is
// exactly the harm the opt-in exists to bound. `theDefaultPlistPathIsUnderTheUsersOwnHome`
// is the one check that names the real directory, and it computes a path
// without going near it.

// MARK: - Fixtures

/// A settings store held in memory.
///
/// The shipping default is `UserDefaultsSettingsStore()` over `.standard` — the
/// preferences of whoever runs the suite — so an installer that took the default
/// would read that person's own opt-in. On this component that is not merely
/// untidy: a developer who HAS turned the login item on would give every check
/// below a store that says `true`, and the refusal checks would pass for the
/// wrong reason on their machine and fail on everybody else's.
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

/// A scratch directory that stands in for `~/Library/LaunchAgents`, and the
/// plist path inside it.
///
/// It does NOT pre-create the directory. `install()` has to make its own — a
/// user who has never had a launch agent has no `~/Library/LaunchAgents` at
/// all, which is the ordinary first-run state and the one a check that scaffolds
/// the directory would never exercise.
private struct ScratchAgents {
    let directory: URL
    var plistURL: URL { directory.appending(path: "\(LoginItemInstaller.label).plist") }

    init() {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "coffee-bar-loginitem-\(UUID().uuidString)")
    }

    /// The directory's contents, sorted, or `nil` when it does not exist.
    ///
    /// `nil` and `[]` are kept apart deliberately: "the directory was never
    /// created" and "the directory is empty" are different states, and the
    /// round-trip check below has to return to whichever one it started in.
    func contents() -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    func clean() { try? FileManager.default.removeItem(at: directory) }
}

/// A program path that exists, is absolute, and is not the test runner.
private let stubProgramPath = "/Applications/coffee-bar.app/Contents/MacOS/coffee-bar"

/// The plist an installer wrote, parsed back the way launchd would read it.
private func writtenJob(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    let parsed = try PropertyListSerialization.propertyList(
        from: data, options: [], format: nil)
    return try #require(parsed as? [String: Any],
                        "the file at \(url.path) is not a plist dictionary")
}

@Suite struct LoginItemInstallerTests {

    // MARK: - Nothing is installed until the user asks

    @Test func installingWithoutTheOptInWritesNothingAndSaysSo() throws {
        // THE GUARD THIS WHOLE COMPONENT RESTS ON, and the one a mutation must
        // turn red. Named bug it catches: a login item that appears because the
        // app ran once. Design §6 refuses even to merge a hook snippet into a
        // settings file the user already owns; a launch agent that installs
        // itself is that rule broken in the loudest possible place, because the
        // artifact outlives the process and the next boot acts on it.
        //
        // The refusal is checked HERE, inside the installer, and not only at the
        // model's call site. One caller is one line away from two, and the
        // second one will not repeat the check.
        //
        // BOTH HALVES are asserted. A throw with a file on disk is the worst
        // outcome of the three — the caller reports failure while the machine
        // has been changed — so the disk is checked as well as the error.
        let scratch = ScratchAgents()
        defer { scratch.clean() }

        let installer = LoginItemInstaller(settings: FakeSettings(),
                                           plistURL: scratch.plistURL,
                                           programPath: stubProgramPath)

        #expect(throws: LoginItemError.notOptedIn) { try installer.install() }
        #expect(installer.isInstalled() == false)
        #expect(scratch.contents() == nil,
                "install() created \(scratch.directory.path) for a user who never asked")
    }

    @Test func anExplicitlyRefusedOptInIsRefusedAndNotMerelyAnUnsetOne() throws {
        // The discriminator between `bool(forKey:) == true` and the two spellings
        // that look equivalent and are not. `!= nil` installs for a user who
        // turned the switch OFF — their stored `false` is a written key — and
        // `?? true` installs for everyone. Both compile, both pass the check
        // above, and both ship a login item the user declined.
        let scratch = ScratchAgents()
        defer { scratch.clean() }

        let installer = LoginItemInstaller(
            settings: FakeSettings([SettingsKey.launchAtLogin: false]),
            plistURL: scratch.plistURL,
            programPath: stubProgramPath)

        #expect(throws: LoginItemError.notOptedIn) { try installer.install() }
        #expect(scratch.contents() == nil)
    }

    @Test func aValueOfTheWrongTypeUnderTheKeyIsNotAnOptIn() throws {
        // `UserDefaults` holds whatever anybody writes, and a preferences file a
        // user or an older build edited by hand can carry a string where a flag
        // belongs. `bool(forKey:)` answers `nil` for it — see `SettingsStoring`
        // — and nothing about "yes" as a string is a user asking for anything.
        let scratch = ScratchAgents()
        defer { scratch.clean() }

        let installer = LoginItemInstaller(
            settings: FakeSettings([SettingsKey.launchAtLogin: "yes"]),
            plistURL: scratch.plistURL,
            programPath: stubProgramPath)

        #expect(throws: LoginItemError.notOptedIn) { try installer.install() }
        #expect(scratch.contents() == nil)
    }

    // MARK: - What the opt-in installs

    @Test func theOptedInInstallWritesALaunchAgentThatStartsTheAppAtLogin() throws {
        // The feature itself. launchd bootstraps `~/Library/LaunchAgents` at
        // every login, so `RunAtLoad` on a job in that directory is what makes
        // the cup come back after a reboot — the whole of issue #48.
        //
        // The plist is PARSED rather than string-matched, because launchd parses
        // it: a file that `contains("RunAtLoad")` and does not decode is a login
        // item that silently never loads, which is the exact failure mode issue
        // #48 reports and would be indistinguishable from it.
        let scratch = ScratchAgents()
        defer { scratch.clean() }

        let installer = LoginItemInstaller(
            settings: FakeSettings([SettingsKey.launchAtLogin: true]),
            plistURL: scratch.plistURL,
            programPath: stubProgramPath)

        try installer.install()

        #expect(installer.isInstalled())
        let job = try writtenJob(at: scratch.plistURL)

        #expect(job["Label"] as? String == "com.coffeebar.loginitem")
        #expect(job["ProgramArguments"] as? [String] == [stubProgramPath])
        #expect(job["RunAtLoad"] as? Bool == true)
    }

    @Test func theLoginItemDoesNotRelaunchTheAppTheUserJustQuit() throws {
        // Named bug this catches: `KeepAlive: true` copied across from
        // `LaunchDaemonInstaller`, where it is load-bearing. On the root
        // watchdog it means a SIGKILLed supervisor comes back, which is what
        // makes the revert reliable. On a menu-bar app it means the Quit button
        // does nothing you can see: launchd restarts the process within the
        // second, and the only way out is to remove the plist the user does not
        // know exists.
        //
        // ABSENCE is asserted, not `== false`. Writing `KeepAlive: false` would
        // also be correct behaviour, but the key is not the product's to state
        // — the two are asserted apart so that the plist stays the three keys
        // this component means to write.
        let scratch = ScratchAgents()
        defer { scratch.clean() }

        let installer = LoginItemInstaller(
            settings: FakeSettings([SettingsKey.launchAtLogin: true]),
            plistURL: scratch.plistURL,
            programPath: stubProgramPath)

        try installer.install()
        let job = try writtenJob(at: scratch.plistURL)

        #expect(job["KeepAlive"] == nil,
                "the login item keeps the app alive, so Quit cannot be obeyed")
        #expect(job.keys.sorted() == ["Label", "ProgramArguments", "RunAtLoad"],
                "the job gained a key nobody decided on: \(job.keys.sorted())")
    }

    @Test func theLoginItemLabelIsNotTheRootWatchdogsLabel() throws {
        // Two launchd jobs, one label. launchd keys a service by its label
        // within a domain, and `docs/` records what a label collision already
        // cost this package once: a plist left in place resurrected a daemon the
        // user believed was gone. These two live in different domains today —
        // `gui/<uid>` against `system` — so the collision is not fatal now, and
        // that is precisely why nothing else would report it if the two names
        // converged in a later edit.
        #expect(LoginItemInstaller.label != LaunchDaemonInstaller.label)
        #expect(LoginItemInstaller.label == "com.coffeebar.loginitem")
    }

    @Test func theDefaultPlistPathIsUnderTheUsersOwnHomeAndNeedsNoRoot() throws {
        // The mechanism choice, made checkable. `/Library/LaunchDaemons` needs
        // root and is where `LaunchDaemonInstaller` writes; `~/Library/LaunchAgents`
        // is the user's own directory and needs no privilege whatever, which is
        // why this feature can ship as a switch while lid-closed mode ships as a
        // command the user types.
        //
        // It COMPUTES the path and never touches it. A check that wrote there
        // would install a live login item on the machine running the suite.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expected = home + "/Library/LaunchAgents/com.coffeebar.loginitem.plist"

        #expect(LoginItemInstaller.userPlistURL().path == expected)
        #expect(LoginItemInstaller.userPlistURL().path.hasPrefix("/Library/") == false,
                "the default path is the ROOT LaunchDaemons tree, which needs privilege")
    }

    // MARK: - Turning it off must return the machine to where it started

    @Test func turningItOffRemovesEverythingTheInstallPutOnDisk() throws {
        // "An install with no uninstall is a trap." The acceptance bullet, and
        // the reason it is a round trip rather than two separate checks: what
        // matters is not that `uninstall()` deletes A file, it is that the
        // directory is indistinguishable afterwards from the one that existed
        // before anybody opted in.
        //
        // The BEFORE state here is `nil` — no directory at all — which is the
        // state of a machine that has never had a launch agent, and the state a
        // check that scaffolded the directory could never restore to.
        let scratch = ScratchAgents()
        defer { scratch.clean() }

        let before = scratch.contents()
        #expect(before == nil, "the scratch directory existed before the install")

        let settings = FakeSettings([SettingsKey.launchAtLogin: true])
        let installer = LoginItemInstaller(settings: settings,
                                           plistURL: scratch.plistURL,
                                           programPath: stubProgramPath)

        try installer.install()
        #expect(scratch.contents() == ["com.coffeebar.loginitem.plist"],
                "the install did not leave the one file this check is about")

        // The user flips the switch back, which is what the model does: the key
        // goes to `false` and THEN the item comes out.
        settings.setBool(false, forKey: SettingsKey.launchAtLogin)
        try installer.uninstall()

        #expect(installer.isInstalled() == false)
        #expect(scratch.contents() == [],
                "uninstall left \(scratch.contents() ?? []) behind")
    }

    @Test func uninstallingIsNotGatedOnTheOptInTheWayInstallingIs() throws {
        // The asymmetry, deliberate and load-bearing. Named bug this catches: a
        // symmetrical `guard settings.bool(...) == true` copied onto
        // `uninstall()`. It reads tidy and it builds the trap: the model writes
        // the key to `false` first, so the guard would refuse exactly the call
        // that removes the item, and a user could never get back to the state
        // they started in. Their only remaining route is a plist path nothing on
        // any surface has ever shown them.
        //
        // Driven with the key set to `false`, which is the state the model
        // leaves behind — not with it absent, because absent is also the state
        // in which nothing was ever installed and the check would pass without
        // discriminating.
        let scratch = ScratchAgents()
        defer { scratch.clean() }

        let settings = FakeSettings([SettingsKey.launchAtLogin: true])
        let installer = LoginItemInstaller(settings: settings,
                                           plistURL: scratch.plistURL,
                                           programPath: stubProgramPath)
        try installer.install()
        #expect(installer.isInstalled())

        settings.setBool(false, forKey: SettingsKey.launchAtLogin)
        try installer.uninstall()

        #expect(installer.isInstalled() == false,
                "uninstall refused because the user had already turned the switch off")
    }

    @Test func uninstallingWhatWasNeverInstalledIsNotAFailure() throws {
        // Idempotence, and it is not tidiness. The model calls `uninstall()`
        // whenever the switch goes to `false`, including for a user who has
        // never turned it on and for one who removed the plist by hand. A throw
        // there would surface as a failure on a machine that is exactly right.
        let scratch = ScratchAgents()
        defer { scratch.clean() }

        let installer = LoginItemInstaller(settings: FakeSettings(),
                                           plistURL: scratch.plistURL,
                                           programPath: stubProgramPath)

        try installer.uninstall()
        #expect(installer.isInstalled() == false)
        #expect(scratch.contents() == nil,
                "uninstall created \(scratch.directory.path) on its way to removing nothing")
    }

    @Test func installingTwiceLeavesOneLoginItemAndNotTwo() throws {
        // A user who toggles the switch, or a second launch that reconciles.
        // launchd reads the directory, so a stale sibling — a `.tmp` from an
        // interrupted write, or a second file under another name — is a second
        // job it will try to load.
        let scratch = ScratchAgents()
        defer { scratch.clean() }

        let installer = LoginItemInstaller(
            settings: FakeSettings([SettingsKey.launchAtLogin: true]),
            plistURL: scratch.plistURL,
            programPath: stubProgramPath)

        try installer.install()
        try installer.install()

        #expect(scratch.contents() == ["com.coffeebar.loginitem.plist"],
                "a second install left \(scratch.contents() ?? []) in the directory")
    }

    // MARK: - What may reach the plist

    @Test func aRelativeProgramPathIsRefusedBecauseLaunchdResolvesItAgainstRoot() throws {
        // Measured on the sibling component and true here for the same reason:
        // launchd resolves a relative `ProgramArguments[0]` against `/`, so
        // `./coffee-bar` becomes `/coffee-bar` and the job fails to spawn at
        // every login with nothing on any surface saying why.
        //
        // `Bundle.main.executablePath` is `nil` for some hosts and the default
        // coalesces to `""`, so the empty path is the same refusal and is
        // checked with it.
        let scratch = ScratchAgents()
        defer { scratch.clean() }
        let settings = FakeSettings([SettingsKey.launchAtLogin: true])

        for path in ["./coffee-bar", "coffee-bar", ""] {
            let installer = LoginItemInstaller(settings: settings,
                                               plistURL: scratch.plistURL,
                                               programPath: path)
            #expect(throws: LoginItemError.programPathNotAbsolute(path)) {
                try installer.install()
            }
        }

        // Refused BEFORE anything touches disk, which is the ordering half:
        // validation and serialisation happen first, so a refused path leaves
        // no trace at all rather than a half-written job launchd would read.
        #expect(scratch.contents() == nil,
                "a refused program path still created \(scratch.directory.path)")
    }

    @Test func aCraftedProgramPathCannotInjectAKeyIntoTheJob() throws {
        // The plist is SERIALISED from a dictionary, never interpolated into an
        // XML template. Measured on `LaunchDaemonInstaller`: under interpolation
        // a crafted path rendered a plist `plutil -p` parsed cleanly, carrying an
        // injected `UserName` beside a truncated `ProgramArguments`.
        //
        // The stakes are lower here than there — this job runs as the user
        // already — but the property is free and its absence is invisible. What
        // it buys is that an injected KEY is unrepresentable rather than merely
        // escaped: whatever the string contains, it can only ever be the single
        // element of `ProgramArguments`.
        let scratch = ScratchAgents()
        defer { scratch.clean() }

        let crafted = "/tmp/x</string><key>UserName</key><string>root</string><string>"
        let installer = LoginItemInstaller(
            settings: FakeSettings([SettingsKey.launchAtLogin: true]),
            plistURL: scratch.plistURL,
            programPath: crafted)

        try installer.install()
        let job = try writtenJob(at: scratch.plistURL)

        #expect(job["UserName"] == nil, "the crafted path injected a UserName key")
        #expect(job.keys.sorted() == ["Label", "ProgramArguments", "RunAtLoad"])
        #expect(job["ProgramArguments"] as? [String] == [crafted],
                "the crafted path was escaped away rather than carried whole")
    }

    @Test func aSymlinkedProgramPathIsWrittenResolvedRatherThanAsTheLink() throws {
        // launchd execs whatever the name points at when the job loads, which is
        // the next login and may be months away. A link this process can read
        // today is a link that can be repointed in between, and the plist would
        // carry the name rather than the object it was validated against.
        let scratch = ScratchAgents()
        defer { scratch.clean() }
        let files = FileManager.default
        try files.createDirectory(at: scratch.directory, withIntermediateDirectories: true)

        let real = scratch.directory.appending(path: "coffee-bar")
        #expect(files.createFile(atPath: real.path, contents: Data()))
        let link = scratch.directory.appending(path: "link-to-coffee-bar")
        try files.createSymbolicLink(at: link, withDestinationURL: real)

        let installer = LoginItemInstaller(
            settings: FakeSettings([SettingsKey.launchAtLogin: true]),
            plistURL: scratch.plistURL,
            programPath: link.path)
        try installer.install()

        let job = try writtenJob(at: scratch.plistURL)
        let written = try #require((job["ProgramArguments"] as? [String])?.first)

        #expect(written.hasSuffix("/coffee-bar"),
                "the plist carries \(written) rather than the file the link points at")
        #expect(written.hasSuffix("/link-to-coffee-bar") == false,
                "the plist carries the symlink, which can be repointed before the next login")
    }
}
