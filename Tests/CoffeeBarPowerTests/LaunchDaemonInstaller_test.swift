// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarPower

// MARK: - Fixtures

/// A stateful model of the two `launchctl` subcommands this component issues.
///
/// It is a *model*, not a spy that returns 0 to everything, because the one
/// behaviour that matters here is stateful: `bootstrap` on a label that is
/// ALREADY loaded exits non-zero. A runner that always succeeds green-lights
/// an installer which throws on every second `arm` — and the caller's rollback
/// path then re-disables sleep and deletes the journal, so nothing ever
/// reverts. Modelling launchd honestly is what makes that reachable in a test.
///
/// Nothing in this file ever reaches the real `launchctl`, and no plist is ever
/// written under `/Library/LaunchDaemons`. Installing a live root daemon on a
/// developer machine is precisely the harm this component exists to bound.
private final class LaunchctlFake: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [[String]] = []
    private var recordedPlistOnDisk: [Bool] = []
    private var loadedLabels: Set<String> = []

    private let plistPath: String
    /// Forces `bootstrap` to a fixed result, for the failure paths. `bootout`
    /// keeps its modelled behaviour so the failure is the one under test.
    private let bootstrapOverride: CommandResult?

    init(plistPath: String, bootstrapOverride: CommandResult? = nil) {
        self.plistPath = plistPath
        self.bootstrapOverride = bootstrapOverride
    }

    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return recordedCalls
    }

    /// The `launchctl` subcommand of each call, in order — `["bootout", …]`.
    var subcommands: [String] {
        calls.compactMap { $0.count > 1 ? $0[1] : nil }
    }

    /// Whether the plist was on disk at the moment each call was issued.
    var plistOnDiskAtCall: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return recordedPlistOnDisk
    }

    func isLoaded(_ label: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return loadedLabels.contains(label)
    }

    func run(_ executable: String, _ arguments: [String],
             timeout: TimeInterval) throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        recordedCalls.append([executable] + arguments)
        recordedPlistOnDisk.append(
            FileManager.default.fileExists(atPath: plistPath))

        switch arguments.first {
        case "bootout":
            // `bootout system/<label>`. Exits non-zero when nothing is loaded,
            // which is the ordinary case on a first install.
            let label = String(arguments.last?
                .split(separator: "/").last ?? "")
            guard loadedLabels.remove(label) != nil else {
                return CommandResult(exitCode: 3, stdout: "",
                                     stderr: "Boot-out failed: 3: No such process")
            }
            return CommandResult(exitCode: 0, stdout: "", stderr: "")

        case "bootstrap":
            if let bootstrapOverride { return bootstrapOverride }
            // `bootstrap system <path>` READS the file at that path, so a
            // missing or unparseable plist is a failure, not a no-op.
            guard let path = arguments.last,
                  let data = FileManager.default.contents(atPath: path) else {
                return CommandResult(
                    exitCode: 112, stdout: "",
                    stderr: "Bootstrap failed: 112: Could not find specified service")
            }
            let decoded = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)
            guard let plist = decoded as? [String: Any],
                  let label = plist["Label"] as? String else {
                return CommandResult(
                    exitCode: 112, stdout: "",
                    stderr: "Bootstrap failed: 112: Could not find specified service")
            }
            // The behaviour C1 exists for.
            guard !loadedLabels.contains(label) else {
                return CommandResult(
                    exitCode: 5, stdout: "",
                    stderr: "Bootstrap failed: 5: Input/output error")
            }
            loadedLabels.insert(label)
            return CommandResult(exitCode: 0, stdout: "", stderr: "")

        default:
            return CommandResult(exitCode: 1, stdout: "",
                                 stderr: "unmodelled: \(arguments)")
        }
    }
}

/// A `launchctl` model in which `bootout` NEVER RETURNS.
///
/// `LaunchctlFake` hands `bootout` a `CommandResult`, which is what the real
/// command does for a caller that is not the job. `uninstall()` runs INSIDE the
/// job: `bootout system/<label>` terminates the very process issuing it, so no
/// statement sequenced after that call is reached. Modelling it as a call that
/// comes back is what let bootout-then-unlink pass a green suite while, measured
/// on the machine, `launchctl print system/com.coffeebar.probewatchdog` said
/// "Could not find service" and
/// `/Library/LaunchDaemons/com.coffeebar.probewatchdog.plist` was still on disk
/// with `RunAtLoad` and `KeepAlive` set — so launchd started the daemon again at
/// the next boot.
///
/// Modelled as a call that BLOCKS FOREVER rather than one that throws. The call
/// site is `_ = try? runner.run(…)`, which swallows a throw and carries straight
/// on to the next statement, so a throwing fake is green on both orderings and
/// proves nothing. Blocking is the one shape `try?` cannot absorb.
private final class DyingLaunchctlFake: CommandRunning, @unchecked Sendable {
    private let issued = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    /// Blocks until `bootout` is issued — the last instant at which the code
    /// under test is still running in production.
    func waitForBootout(within seconds: Double) -> DispatchTimeoutResult {
        issued.wait(timeout: .now() + seconds)
    }

    /// Lets the modelled process finish, so the test leaves no thread parked on
    /// the semaphore.
    func releaseTheCaller() { release.signal() }

    func run(_ executable: String, _ arguments: [String],
             timeout: TimeInterval) throws -> CommandResult {
        guard arguments.first == "bootout" else {
            return CommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        issued.signal()
        release.wait()
        return CommandResult(exitCode: 0, stdout: "", stderr: "")
    }
}

/// A genuinely root-owned, non-group-writable program, standing in for an
/// installed `coffee-bar-probe`. Verified on macOS: `/`, `/usr`, `/usr/bin`
/// and `/usr/bin/true` are all root:wheel 0755, so this is the only kind of
/// path `install()` is allowed to hand to launchd as a root daemon's program.
private let rootOwnedProgram = "/usr/bin/true"
/// A second one, for the tests that need two distinguishable plists.
private let otherRootOwnedProgram = "/bin/ls"

/// A plist path under a fresh temp directory — never `/Library/LaunchDaemons`.
private func scratchPlist() throws -> URL {
    try scratchDir().appendingPathComponent(
        "\(LaunchDaemonInstaller.label).plist")
}

private func scratchDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cb-plist-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true)
    return dir
}

/// The path `realpath(3)` yields, which is what the validator reports.
///
/// `FileManager.temporaryDirectory` hands back `/var/folders/…` and `/var` is
/// a symlink to `private/var` on macOS, so comparing the raw forms is a
/// guaranteed miss. `URL.resolvingSymlinksInPath()` does NOT close the gap —
/// measured, it returns `/var/folders/…` unchanged, because Foundation
/// deliberately preserves the `/var`, `/tmp` and `/etc` spellings. libc is
/// used directly so the expected value comes from an independent
/// canonicaliser rather than from a second copy of the code under test.
private func canonical(_ url: URL) -> String {
    guard let buffer = realpath(url.path, nil) else { return url.path }
    defer { free(buffer) }
    return String(cString: buffer)
}

private func makeInstaller(
    at url: URL,
    programPath: String = rootOwnedProgram,
    bootstrapOverride: CommandResult? = nil
) -> (LaunchDaemonInstaller, LaunchctlFake) {
    let fake = LaunchctlFake(plistPath: url.path,
                             bootstrapOverride: bootstrapOverride)
    return (LaunchDaemonInstaller(runner: fake, plistURL: url,
                                  programPath: programPath), fake)
}

/// Decodes through `PropertyListSerialization` rather than substring-matching
/// the XML the generator just produced. A `contains("<key>RunAtLoad</key>")`
/// check compares a literal against a literal in the same file and stays green
/// against a plist launchd cannot parse at all.
private func decodePlist(_ url: URL) throws -> [String: Any] {
    try decodePlist(data: try Data(contentsOf: url))
}

private func decodePlist(data: Data) throws -> [String: Any] {
    let object = try PropertyListSerialization.propertyList(
        from: data, options: [], format: nil)
    return object as? [String: Any] ?? [:]
}

private func generatedPlist(
    programPath: String = rootOwnedProgram
) throws -> [String: Any] {
    let (installer, _) = makeInstaller(at: try scratchPlist())
    return try decodePlist(data: installer.plistData(programPath: programPath))
}

/// Runs the program-path validator and returns the components it objected to,
/// or `[]` when it accepted the path. Any other error is rethrown rather than
/// flattened, so a test cannot pass by way of the wrong failure.
private func insecureComponents(of path: String) throws -> [InsecurePathComponent] {
    do {
        _ = try LaunchDaemonInstaller.validatedProgramPath(path)
        return []
    } catch let error as WatchdogInstallError {
        guard case .programPathInsecure(_, let components) = error else {
            throw error
        }
        return components
    }
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
            == [rootOwnedProgram, "watchdog"])
}

@Test func plistDeclaresABackgroundProcessTypeSoItIsNotThrottledAsInteractive() throws {
    #expect(try generatedPlist()["ProcessType"] as? String == "Background")
}

@Test func aCraftedProgramPathCannotIntroduceKeysOrArgumentsIntoThePlist() throws {
    // MEASURED against the string-interpolated generator this replaced: the
    // payload below rendered to a plist `plutil -p` parsed with rc=0 and no
    // complaint, carrying an injected `UserName`, a `Junk` key, and
    // `EnvironmentVariables => {DYLD_INSERT_LIBRARIES => /tmp/evil.dylib}`
    // beside a truncated `ProgramArguments`. That is a root-capability
    // primitive: launchd would run `/bin/sh -c …` as root at every boot with
    // an attacker's dylib injected.
    //
    // The dangerous case is precisely the one that stays WELL-FORMED. A bare
    // `&` or `<` produces XML launchd rejects, which the existing exit-code
    // check already catches; escaping is what is easy to get subtly wrong.
    // Serialising a dictionary is what makes an injected KEY unrepresentable
    // rather than merely escaped.
    let payload = "/bin/sh</string><string>-c</string>"
        + "<string>echo INJECTED</string></array>"
        + "<key>UserName</key><string>root</string>"
        + "<key>EnvironmentVariables</key><dict>"
        + "<key>DYLD_INSERT_LIBRARIES</key><string>/tmp/evil.dylib</string>"
        + "</dict><key>Junk</key><array><string>x"

    let plist = try generatedPlist(programPath: payload)

    // EXACTLY this key set: an injected key is a new capability, so an
    // "expected keys are present" check would miss the entire attack.
    #expect(Set(plist.keys) == Set(["Label", "ProgramArguments", "RunAtLoad",
                                    "KeepAlive", "ProcessType"]))
    // Two elements, the payload inert in the first. Under interpolation this
    // was three, and none of them the payload.
    #expect(plist["ProgramArguments"] as? [String] == [payload, "watchdog"])
}

// MARK: - install: program-path validation

@Test func aRelativeProgramPathIsRefusedBeforeAnythingIsWritten() throws {
    // launchd resolves a relative `ProgramArguments[0]` against `/`, so
    // "./coffee-bar-probe" becomes "/coffee-bar-probe" — a path an
    // unprivileged process may well be able to create. Nothing may reach disk
    // or launchd on this path.
    let url = try scratchPlist()
    let (installer, fake) = makeInstaller(
        at: url, programPath: "./coffee-bar-probe")

    #expect(throws: WatchdogInstallError
        .programPathNotAbsolute("./coffee-bar-probe")) {
        try installer.install()
    }
    #expect(fake.calls.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func aProgramPathThatDoesNotResolveIsRefused() throws {
    let missing = "/usr/bin/coffee-bar-probe-\(UUID().uuidString)"
    let url = try scratchPlist()
    let (installer, fake) = makeInstaller(at: url, programPath: missing)

    #expect(throws: WatchdogInstallError
        .programPathUnresolvable(path: missing, errno: ENOENT)) {
        try installer.install()
    }
    #expect(fake.calls.isEmpty)
}

@Test func pathValidationSeparatesWhoOwnsAComponentFromWhoCanWriteIt() throws {
    // The natural first live run is `sudo .build/debug/coffee-bar-probe arm`,
    // which would install a RunAtLoad+KeepAlive ROOT daemon whose program is a
    // file inside $HOME that `swift build` rewrites and any process running as
    // that user can replace. That is root persistence handed to any local code.
    //
    // Both conditions are asserted independently, on the same run, because
    // without real root no fixture can be root-owned AND group-writable at
    // once: `writable` is pinned on a directory this test chmods 0775, and
    // `notOwnedByRoot` on a sibling left at 0755. Deleting either check leaves
    // one of these four expectations red.
    let root = try scratchDir()
    let groupWritable = root.appendingPathComponent("gw")
    let tight = root.appendingPathComponent("tight")
    for dir in [groupWritable, tight] {
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8)
            .write(to: dir.appendingPathComponent("probe"))
    }
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o775], ofItemAtPath: groupWritable.path)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: tight.path)

    let fromGroupWritable = try insecureComponents(
        of: groupWritable.appendingPathComponent("probe").path)
    let offender = fromGroupWritable
        .first { $0.path == canonical(groupWritable) }
    #expect(offender?.groupOrOtherWritable == true)

    let fromTight = try insecureComponents(
        of: tight.appendingPathComponent("probe").path)
    let userOwned = fromTight.first { $0.path == canonical(tight) }
    #expect(userOwned?.notOwnedByRoot == true)
    #expect(userOwned?.groupOrOtherWritable == false)
    // And the walk covers ancestors, not just the leaf: the per-user temp
    // directory two levels up is user-owned too and must be reported.
    #expect(fromTight.contains { $0.path == canonical(root) })
}

@Test func aRootOwnedProgramPathIsAcceptedAndCanonicalised() throws {
    // The positive control. A validator that refused everything would satisfy
    // every rejection test above while making `arm` impossible.
    #expect(try LaunchDaemonInstaller.validatedProgramPath(rootOwnedProgram)
            == rootOwnedProgram)
}

@Test func aSymlinkedProgramPathIsResolvedBeforeItReachesThePlist() throws {
    // launchd execs whatever string lands in ProgramArguments[0]. Writing the
    // path as GIVEN would leave a symlink in the chain, and every component
    // check would then have been performed on a name whose target someone else
    // can repoint between validation and the next boot — a TOCTOU that hands
    // over root. Writing the resolved path removes the indirection entirely,
    // so the checked components and the exec'd file are the same objects.
    //
    // `/var` -> `private/var` means real installs traverse symlinks whether or
    // not anyone intended them to.
    let link = try scratchDir().appendingPathComponent("coffee-bar-probe")
    try FileManager.default.createSymbolicLink(
        at: link, withDestinationURL: URL(fileURLWithPath: rootOwnedProgram))

    // Accepted despite living in a user-owned temp directory, because the
    // symlink's own path is not what launchd will execute.
    #expect(try LaunchDaemonInstaller.validatedProgramPath(link.path)
            == rootOwnedProgram)

    let url = try scratchPlist()
    let (installer, _) = makeInstaller(at: url, programPath: link.path)
    try installer.install()
    #expect(try decodePlist(url)["ProgramArguments"] as? [String]
            == [rootOwnedProgram, "watchdog"])
}

// MARK: - install

@Test func installWritesAPlistThatLaunchdCanActuallyParse() throws {
    let url = try scratchPlist()
    let (installer, _) = makeInstaller(at: url)
    try installer.install()

    // Existence alone is not the guarantee: launchd rejects a malformed plist
    // and the daemon silently never loads. Decoding from DISK is what pins it.
    let onDisk = try decodePlist(url)
    #expect(onDisk["Label"] as? String == "com.coffeebar.probewatchdog")
    #expect(onDisk["ProgramArguments"] as? [String]
            == [rootOwnedProgram, "watchdog"])
}

@Test func installBootsOutTheLabelBeforeBootstrappingIt() throws {
    let url = try scratchPlist()
    let (installer, fake) = makeInstaller(at: url)
    try installer.install()

    #expect(fake.calls == [
        ["/bin/launchctl", "bootout", "system/com.coffeebar.probewatchdog"],
        ["/bin/launchctl", "bootstrap", "system", url.path],
    ])
}

@Test func asecondInstallOnAnAlreadyLoadedLabelSucceedsRatherThanThrowing() throws {
    // `launchctl bootstrap system <plist>` on an ALREADY-LOADED label exits
    // non-zero. Without a preceding `bootout` the second `arm` on a machine
    // that is already armed throws — and the caller's rollback then re-applies
    // the SleepDisabled value it just read back (its own `true`) and DELETES
    // the journal. The watchdog boots, finds nothing, holds, and the machine
    // never sleeps again. Two `sudo arm` invocations and no attacker.
    let url = try scratchPlist()
    let (installer, fake) = makeInstaller(at: url)
    try installer.install()

    try installer.install()

    #expect(fake.subcommands == ["bootout", "bootstrap", "bootout", "bootstrap"])
    #expect(fake.isLoaded(LaunchDaemonInstaller.label))
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func bootstrapIsIssuedOnlyOnceThePlistIsOnDisk() throws {
    // `launchctl bootstrap system <path>` READS the file at that path. Issuing
    // it before the write lands fails with "path not found" — and because the
    // caller then believes the watchdog is supervising, `arm` would go on to
    // set SleepDisabled with nothing alive to revert it.
    let url = try scratchPlist()
    let (installer, fake) = makeInstaller(at: url)
    try installer.install()

    let bootstrapIndex = try #require(fake.subcommands.firstIndex(of: "bootstrap"))
    #expect(fake.plistOnDiskAtCall[bootstrapIndex])
}

@Test func installedPlistIsNotGroupOrWorldWritable() throws {
    // This file is loaded by launchd as root. A group- or world-writable plist
    // in /Library/LaunchDaemons is a local privilege escalation: anyone who can
    // rewrite ProgramArguments gets root at the next load. launchd itself
    // refuses to load one, so a wrong mode is also a silent no-daemon.
    let url = try scratchPlist()
    let (installer, _) = makeInstaller(at: url)
    try installer.install()

    let mode = try FileManager.default
        .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    #expect(mode?.uint16Value == 0o644)
}

@Test func reinstallingOverAWidenedPlistRestoresTheSafeMode() throws {
    // An atomic replace that inherits the ORIGINAL file's metadata would carry
    // a 0666 plist forward across every reinstall, silently preserving exactly
    // the privilege escalation the mode is there to close.
    let url = try scratchPlist()
    try Data("stale".utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o666], ofItemAtPath: url.path)

    let (installer, _) = makeInstaller(at: url)
    try installer.install()

    let mode = try FileManager.default
        .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    #expect(mode?.uint16Value == 0o644)
}

@Test func thePlistWriteIsAtomicSoACrashCannotLeaveATruncatedOne() throws {
    // A half-written plist is not a cosmetic problem: launchd cannot parse it,
    // so the boot-with-a-dirty-journal case — the entire reason RunAtLoad
    // exists — comes up with no daemon and nothing ever reverts SleepDisabled.
    //
    // Atomicity IS observable, so assert it rather than "the last write won",
    // which an in-place `data.write(to:)` satisfies just as well. A replace by
    // rename leaves a reader that already opened the file on the ORIGINAL
    // inode; an in-place write truncates the very file that descriptor points
    // at. That difference is the whole test.
    let url = try scratchPlist()
    let (first, _) = makeInstaller(at: url)
    try first.install()
    let original = try Data(contentsOf: url)

    let fd = open(url.path, O_RDONLY)
    try #require(fd >= 0)
    defer { close(fd) }

    let (second, _) = makeInstaller(at: url, programPath: otherRootOwnedProgram)
    try second.install()

    let held = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    #expect(held.readDataToEndOfFile() == original)
    // And the path now resolves to the new plist, so this is an atomic
    // REPLACEMENT and not a write that quietly failed.
    #expect(try decodePlist(url)["ProgramArguments"] as? [String]
            == [otherRootOwnedProgram, "watchdog"])
}

@Test func aFailedBootstrapIsSurfacedRatherThanReportedAsSuccess() throws {
    // `launchctl bootstrap` reports failure through its EXIT CODE, not by
    // writing to a pipe the caller happens to read — "Bootstrap failed: 5:
    // Input/output error" exits non-zero. Swallowing that makes `install`
    // return normally with no daemon loaded, and `arm` then sets SleepDisabled
    // believing it is supervised. Nothing would ever revert it.
    let url = try scratchPlist()
    let (installer, _) = makeInstaller(
        at: url,
        bootstrapOverride: CommandResult(
            exitCode: 5, stdout: "",
            stderr: "Bootstrap failed: 5: Input/output error"))

    #expect(throws: PowerControlError.commandFailed(
        exitCode: 5, stderr: "Bootstrap failed: 5: Input/output error")) {
        try installer.install()
    }
}

@Test func aFailedBootstrapLeavesNoOrphanPlistToAutoLoadAtTheNextBoot() throws {
    // launchd bootstraps EVERYTHING in /Library/LaunchDaemons at boot. A plist
    // left behind by a failed, rolled-back `arm` therefore resurrects a root
    // daemon the user believes was never installed — pointed at a path that
    // may by then be missing or attacker-owned. The caller cannot distinguish
    // "failed before the write" from "failed after", so removing it is the
    // installer's job, not the caller's.
    let url = try scratchPlist()
    let (installer, _) = makeInstaller(
        at: url,
        bootstrapOverride: CommandResult(
            exitCode: 5, stdout: "",
            stderr: "Bootstrap failed: 5: Input/output error"))

    #expect(throws: (any Error).self) { try installer.install() }

    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func aFailedInstallLeavesNoTemporaryFileBehindEither() throws {
    // The atomic write stages a sibling. Leaving one in /Library/LaunchDaemons
    // is not itself loadable — launchd only reads `.plist` — but it accumulates
    // one root-owned turd per failed arm, and a directory listing is how an
    // operator decides whether this machine is armed.
    let url = try scratchPlist()
    let (installer, _) = makeInstaller(
        at: url,
        bootstrapOverride: CommandResult(exitCode: 5, stdout: "", stderr: "x"))

    #expect(throws: (any Error).self) { try installer.install() }

    let leftovers = try FileManager.default.contentsOfDirectory(
        atPath: url.deletingLastPathComponent().path)
    #expect(leftovers == [])
}

// MARK: - uninstall

@Test func uninstallBootsOutTheDaemonAndRemovesThePlist() throws {
    // Deleting the plist does NOT stop a loaded daemon: launchd keeps running
    // the service it already bootstrapped, and with KeepAlive it restarts it.
    // A `revert` that only unlinks the file leaves a live root process behind
    // while reporting success.
    let url = try scratchPlist()
    let (installer, fake) = makeInstaller(at: url)
    try installer.install()

    try installer.uninstall()

    #expect(fake.calls.last
            == ["/bin/launchctl", "bootout", "system/com.coffeebar.probewatchdog"])
    #expect(!fake.isLoaded(LaunchDaemonInstaller.label))
    #expect(!FileManager.default.fileExists(atPath: url.path))
    // And the plist was ALREADY gone when that last bootout was issued. The end
    // state above is reachable only in a test, where the call returns; in
    // production it kills the caller, so the removal has to precede it.
    #expect(fake.plistOnDiskAtCall.last == false, """
        the bootout was issued with the plist still on disk: \
        \(fake.plistOnDiskAtCall)
        """)
}

@Test func theBootoutTargetNamesTheServiceThePlistDeclares() throws {
    // The label is one external contract written in two independent places:
    // the Label key launchd registers, and the domain target `bootout` names.
    // If they drift, install succeeds and uninstall boots out nothing.
    let url = try scratchPlist()
    let (installer, fake) = makeInstaller(at: url)
    try installer.install()
    let declaredLabel = try decodePlist(url)["Label"] as? String
    try installer.uninstall()

    #expect(declaredLabel == "com.coffeebar.probewatchdog")
    let bootout = fake.calls.last { $0.contains("bootout") }
    #expect(bootout?.last == "system/" + (declaredLabel ?? "<no label>"))
}

@Test func uninstallOnAMissingPlistStillBootsOutAndDoesNotThrow() throws {
    // The plist can be gone while the service is still loaded — someone tidied
    // /Library/LaunchDaemons by hand, or a previous uninstall died between the
    // two steps. Skipping bootout because the file is absent would strand a
    // live root daemon, so the bootout is unconditional.
    let url = try scratchPlist()
    let (installer, fake) = makeInstaller(at: url)

    try installer.uninstall()

    #expect(fake.calls
            == [["/bin/launchctl", "bootout", "system/com.coffeebar.probewatchdog"]])
}

@Test func aFailedBootoutStillRemovesThePlist() throws {
    // Deliberately asymmetric with install. `bootout` exits non-zero when
    // nothing is loaded, which is the ordinary case on a second uninstall, and
    // `revert` must reach `controller.set(prior)` regardless: refusing to
    // finish because launchd had nothing to unload would leave sleep disabled.
    let url = try scratchPlist()
    let (installer, fake) = makeInstaller(at: url)
    try Data("placeholder".utf8).write(to: url)

    try installer.uninstall()

    // Nothing was ever loaded, so the modelled bootout genuinely failed here.
    #expect(fake.calls.count == 1)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(fake.plistOnDiskAtCall == [false], """
        the plist was still on disk when the bootout was issued: \
        \(fake.plistOnDiskAtCall)
        """)
}

@Test func uninstallRemovesThePlistBeforeIssuingTheBootoutThatEndsTheProcess() throws {
    // #76, observed on the real machine after a TTL revert: the service was
    // gone — `launchctl print system/com.coffeebar.probewatchdog` answered
    // "Could not find service" — and the plist was still in
    // /Library/LaunchDaemons with `RunAtLoad => true` and `KeepAlive => true`.
    // launchd bootstraps that directory at every boot, so the revert undid
    // nothing durable and the daemon came back for good.
    //
    // Named bug this catches: the removal sequenced AFTER the bootout.
    // `bootout system/<label>` ends the process that issues it when that
    // process IS the job, so the only work that counts is the work already done
    // at the moment of the call — which is exactly where the assertion is
    // taken. The end-state checks above cannot see this, because their fake
    // returns from a call production never returns from.
    let url = try scratchPlist()
    try Data("placeholder".utf8).write(to: url)
    let fake = DyingLaunchctlFake()
    let installer = LaunchDaemonInstaller(runner: fake, plistURL: url,
                                          programPath: rootOwnedProgram)

    let thread = Thread { try? installer.uninstall() }
    thread.start()
    defer { fake.releaseTheCaller() }

    #expect(fake.waitForBootout(within: 10) == .success,
            "uninstall never issued a bootout at all")
    #expect(!FileManager.default.fileExists(atPath: url.path), """
        uninstall issued `bootout system/com.coffeebar.probewatchdog` with the \
        plist still on disk. That call does not return, so the removal after it \
        never runs and launchd starts the daemon again at every boot.
        """)
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
