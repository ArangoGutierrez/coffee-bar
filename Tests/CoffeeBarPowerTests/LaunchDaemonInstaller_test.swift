// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarPower

// MARK: - Fixtures

/// Records every `launchctl` invocation, and whether the plist was on disk at
/// the moment each one was issued.
///
/// Nothing in this file ever reaches the real `launchctl`, and no plist is ever
/// written under `/Library/LaunchDaemons`. Installing a live root daemon on a
/// developer machine is precisely the harm this component exists to bound.
private struct LaunchctlSpy: CommandRunning, @unchecked Sendable {
    final class Box: @unchecked Sendable {
        var calls: [[String]] = []
        var plistOnDiskAtCall: [Bool] = []
    }

    let box = Box()
    let plistPath: String
    var result = CommandResult(exitCode: 0, stdout: "", stderr: "")

    func run(_ executable: String, _ arguments: [String],
             timeout: TimeInterval) throws -> CommandResult {
        box.calls.append([executable] + arguments)
        box.plistOnDiskAtCall.append(
            FileManager.default.fileExists(atPath: plistPath))
        return result
    }
}

private let testBinary = "/usr/local/bin/coffee-bar-probe"

/// A plist path under a fresh temp directory — never `/Library/LaunchDaemons`.
private func scratchPlist() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cb-plist-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("\(LaunchDaemonInstaller.label).plist")
}

private func makeInstaller(
    at url: URL, exitCode: Int32 = 0, stderr: String = ""
) -> (LaunchDaemonInstaller, LaunchctlSpy) {
    let spy = LaunchctlSpy(
        plistPath: url.path,
        result: CommandResult(exitCode: exitCode, stdout: "", stderr: stderr))
    return (LaunchDaemonInstaller(runner: spy, plistURL: url), spy)
}

/// Decodes through `PropertyListSerialization` rather than substring-matching
/// the XML the generator just produced. A `contains("<key>RunAtLoad</key>")`
/// check compares a literal against a literal in the same file and stays green
/// against a plist launchd cannot parse at all.
private func decodePlist(_ url: URL) throws -> [String: Any] {
    try decodePlist(string: String(decoding: try Data(contentsOf: url),
                                   as: UTF8.self))
}

private func decodePlist(string: String) throws -> [String: Any] {
    let object = try PropertyListSerialization.propertyList(
        from: Data(string.utf8), options: [], format: nil)
    return object as? [String: Any] ?? [:]
}

private func generatedPlist() throws -> [String: Any] {
    let url = try scratchPlist()
    let (installer, _) = makeInstaller(at: url)
    return try decodePlist(string: installer.plistContents(binaryPath: testBinary))
}

// MARK: - The plist launchd loads

@Test func plistRunsTheWatchdogAtLoadSoARebootWithADirtyJournalReverts() throws {
    // Handoff §8.2(4): a boot with a dirty journal must revert
    // UNCONDITIONALLY. Without RunAtLoad the daemon is merely registered and
    // never started, so a machine rebooted while armed comes back with
    // SleepDisabled still set and nothing running that would notice.
    #expect(try generatedPlist()["RunAtLoad"] as? Bool == true)
}

@Test func plistKeepsTheWatchdogAliveSoAKilledWatchdogIsRestarted() throws {
    // The watchdog is the only thing that reverts SleepDisabled on TTL expiry.
    // Without KeepAlive a SIGKILL — or any crash — retires the supervisor
    // permanently and the flag survives to the next reboot, which is the
    // failure mode the whole journal/TTL design is built around.
    #expect(try generatedPlist()["KeepAlive"] as? Bool == true)
}

@Test func plistInvokesTheWatchdogVerbOnTheGivenBinary() throws {
    // Asserted as the whole argv, not `contains`. A plist that invokes the
    // right binary with the WRONG verb — `arm`, say — would satisfy any
    // membership check while re-arming the machine on every boot.
    #expect(try generatedPlist()["ProgramArguments"] as? [String]
            == [testBinary, "watchdog"])
}

@Test func plistDeclaresABackgroundProcessTypeSoItIsNotThrottledAsInteractive() throws {
    #expect(try generatedPlist()["ProcessType"] as? String == "Background")
}

// MARK: - install

@Test func installWritesAPlistThatLaunchdCanActuallyParse() throws {
    let url = try scratchPlist()
    let (installer, _) = makeInstaller(at: url)
    try installer.install(binaryPath: testBinary)

    // Existence alone is not the guarantee: launchd rejects a malformed plist
    // and the daemon silently never loads. Decoding from DISK is what pins it.
    let onDisk = try decodePlist(url)
    #expect(onDisk["Label"] as? String == "com.coffeebar.probewatchdog")
    #expect(onDisk["ProgramArguments"] as? [String] == [testBinary, "watchdog"])
}

@Test func installIssuesTheExactBootstrapInvocation() throws {
    let url = try scratchPlist()
    let (installer, spy) = makeInstaller(at: url)
    try installer.install(binaryPath: testBinary)

    #expect(spy.box.calls
            == [["/bin/launchctl", "bootstrap", "system", url.path]])
}

@Test func bootstrapIsIssuedOnlyOnceThePlistIsOnDisk() throws {
    // `launchctl bootstrap system <path>` READS the file at that path. Issuing
    // it before the write lands fails with "path not found" — and because the
    // caller then believes the watchdog is supervising, `arm` would go on to
    // set SleepDisabled with nothing alive to revert it.
    let url = try scratchPlist()
    let (installer, spy) = makeInstaller(at: url)
    try installer.install(binaryPath: testBinary)

    #expect(spy.box.plistOnDiskAtCall == [true])
}

@Test func installedPlistIsNotGroupOrWorldWritable() throws {
    // This file is loaded by launchd as root. A group- or world-writable plist
    // in /Library/LaunchDaemons is a local privilege escalation: anyone who can
    // rewrite ProgramArguments gets root at the next load. launchd itself
    // refuses to load one, so a wrong mode is also a silent no-daemon.
    let url = try scratchPlist()
    let (installer, _) = makeInstaller(at: url)
    try installer.install(binaryPath: testBinary)

    let mode = try FileManager.default
        .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    #expect(mode?.uint16Value == 0o644)
}

@Test func aFailedBootstrapIsSurfacedRatherThanReportedAsSuccess() throws {
    // `launchctl bootstrap` reports failure through its EXIT CODE, not by
    // writing to a pipe the caller happens to read — "Bootstrap failed: 5:
    // Input/output error" exits non-zero. Swallowing that makes `install`
    // return normally with no daemon loaded, and `arm` then sets SleepDisabled
    // believing it is supervised. Nothing would ever revert it.
    let url = try scratchPlist()
    let (installer, _) = makeInstaller(
        at: url, exitCode: 5, stderr: "Bootstrap failed: 5: Input/output error")

    #expect(throws: PowerControlError.commandFailed(
        exitCode: 5, stderr: "Bootstrap failed: 5: Input/output error")) {
        try installer.install(binaryPath: testBinary)
    }
}

// MARK: - uninstall

@Test func uninstallBootsOutTheDaemonAndRemovesThePlist() throws {
    // Deleting the plist does NOT stop a loaded daemon: launchd keeps running
    // the service it already bootstrapped, and with KeepAlive it restarts it.
    // A `revert` that only unlinks the file leaves a live root process behind
    // while reporting success.
    let url = try scratchPlist()
    let (installer, spy) = makeInstaller(at: url)
    try installer.install(binaryPath: testBinary)
    spy.box.calls.removeAll()
    spy.box.plistOnDiskAtCall.removeAll()

    try installer.uninstall()

    #expect(spy.box.calls
            == [["/bin/launchctl", "bootout", "system/com.coffeebar.probewatchdog"]])
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func theBootoutTargetNamesTheServiceThePlistDeclares() throws {
    // The label is one external contract written in two independent places:
    // the Label key launchd registers, and the domain target `bootout` names.
    // If they drift, install succeeds and uninstall boots out nothing.
    let url = try scratchPlist()
    let (installer, spy) = makeInstaller(at: url)
    try installer.install(binaryPath: testBinary)
    let declaredLabel = try decodePlist(url)["Label"] as? String
    try installer.uninstall()

    #expect(declaredLabel == "com.coffeebar.probewatchdog")
    let bootout = spy.box.calls.first { $0.contains("bootout") }
    #expect(bootout?.last == "system/" + (declaredLabel ?? "<no label>"))
}

@Test func uninstallOnAMissingPlistStillBootsOutAndDoesNotThrow() throws {
    // The plist can be gone while the service is still loaded — someone tidied
    // /Library/LaunchDaemons by hand, or a previous uninstall died between the
    // two steps. Skipping bootout because the file is absent would strand a
    // live root daemon, so the bootout is unconditional.
    let url = try scratchPlist()
    let (installer, spy) = makeInstaller(at: url)

    try installer.uninstall()

    #expect(spy.box.calls
            == [["/bin/launchctl", "bootout", "system/com.coffeebar.probewatchdog"]])
}

@Test func aFailedBootoutStillRemovesThePlist() throws {
    // Deliberately asymmetric with install. `bootout` exits non-zero when
    // nothing is loaded, which is the ordinary case on a second uninstall, and
    // `revert` must reach `controller.set(prior)` regardless: refusing to
    // finish because launchd had nothing to unload would leave sleep disabled.
    let url = try scratchPlist()
    let (installer, _) = makeInstaller(
        at: url, exitCode: 3, stderr: "Boot-out failed: 3: No such process")
    try Data("placeholder".utf8).write(to: url)

    try installer.uninstall()

    #expect(!FileManager.default.fileExists(atPath: url.path))
}

// MARK: - DisplayStateProbe (spike S2)

@Test func anUnreadableWranglerIsUnknownNotAsleep() {
    // Handoff §2.2 asks whether the internal panel stays lit under a closed
    // lid. Collapsing "cannot read the registry" into `false` reports a LIT
    // screen as dark, so the spike would conclude the battery drain it exists
    // to find is absent. `nil` is the only honest answer.
    //
    // The unreadable case is forced with a service name that cannot exist,
    // which is deterministic on every host — unlike relying on this machine
    // happening to lack the wrangler.
    let probe = DisplayStateProbe(serviceName: "CoffeeBarNoSuchServiceEverExists")
    #expect(probe.isInternalDisplayAwake() == nil)
}

@Test func aFullyPoweredPanelReadsAsAwake() {
    #expect(DisplayStateProbe.displayAwake(
        fromProperties: ["IOPowerManagement": ["CurrentPowerState": 4]]) == true)
}

@Test func aDimmedOrOffPanelReadsAsAsleep() {
    // IODisplayWrangler runs 0...4; only 4 is fully on. 3 is the dimmed state
    // the display enters just before sleeping, and reading it as awake would
    // report a false positive on every idle machine.
    for state in [0, 1, 2, 3] {
        #expect(DisplayStateProbe.displayAwake(
            fromProperties: ["IOPowerManagement": ["CurrentPowerState": state]])
                == false)
    }
}

@Test func aWranglerWithoutPowerManagementIsUnknownNotAsleep() {
    // Not hypothetical: measured on this Apple Silicon host (macOS 26.5.2),
    // IODisplayWrangler EXISTS but publishes no IOPowerManagement dictionary
    // at all. Defaulting a present-but-silent service to `false` would report
    // a confident "panel asleep" on every Apple Silicon Mac without ever
    // having read a power state.
    #expect(DisplayStateProbe.displayAwake(fromProperties: [:]) == nil)
    #expect(DisplayStateProbe.displayAwake(
        fromProperties: ["IOPowerManagement": [String: Any]()]) == nil)
}

@Test func aNonNumericPowerStateIsUnknownNotAsleep() {
    #expect(DisplayStateProbe.displayAwake(
        fromProperties: ["IOPowerManagement": ["CurrentPowerState": "on"]]) == nil)
}
