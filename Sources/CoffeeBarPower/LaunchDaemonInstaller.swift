// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Installs and removes whatever supervises the watchdog.
///
/// The conformer writes a plist and shells out to `launchctl`.
///
/// This comment used to say M5 would replace that with
/// `SMAppService.daemon(plistName:).register()`. It will not, and the reason is
/// measured rather than stylistic: that API registers a plist shipped inside a
/// code-signed app bundle, and the only bundle that ships is built from source
/// by the Homebrew formula and is ad-hoc signed — `Signature=adhoc`,
/// `TeamIdentifier=not set`, and `codesign -R='anchor apple generic'` exits 1.
/// The same absence rules out the XPC peer pinning SECURITY.md "It cannot pin a peer"
/// requires. M5 therefore ships as a root CLI plus this launchd daemon.
///
/// The interface keeps no `install(binaryPath:)` requirement all the same.
/// Resolving and validating the program path *inside* the conformer is what
/// keeps a caller-supplied path unrepresentable, which is the property
/// `:63-67` below is about.
public protocol WatchdogSupervising: Sendable {
    func install() throws
    func uninstall() throws
}

/// One path component that failed the root-daemon program-path bar, and why.
///
/// Both conditions are carried rather than a single reason: a component can be
/// user-owned *and* group-writable, and the two are independently fixable. The
/// whole list is reported rather than the first offender because an operator
/// who has to `chown` their way out wants every component at once.
public struct InsecurePathComponent: Equatable, Sendable {
    public let path: String
    public let notOwnedByRoot: Bool
    public let groupOrOtherWritable: Bool
}

public enum WatchdogInstallError: Error, Equatable {
    /// launchd resolves a relative `ProgramArguments[0]` against `/`, so
    /// `"./coffee-bar-probe"` becomes `/coffee-bar-probe`.
    case programPathNotAbsolute(String)
    case programPathUnresolvable(path: String, errno: Int32)
    case programPathInsecure(path: String, components: [InsecurePathComponent])
    case plistWriteFailed(String)
    case plistSyncFailed(Int32)
}

/// Installs the watchdog as a launchd daemon.
///
/// M0 deliberately used a plain plist plus `launchctl bootstrap system` rather
/// than `SMAppService`: it needs no app bundle, no code signing and no Xcode.
/// That property is exactly why M5 keeps it — see the note above on the ad-hoc
/// signature — so this is the shipped mechanism, not an interim one.
///
/// The daemon exists because the app cannot supervise its own death. Handoff
/// §8.2(4): a boot with a dirty journal must revert unconditionally, which is
/// what `RunAtLoad` buys; a SIGKILLed watchdog must come back, which is what
/// `KeepAlive` buys. Both are load-bearing, not hygiene.
public struct LaunchDaemonInstaller: WatchdogSupervising {
    public static let label = "com.coffeebar.probewatchdog"
    public static let launchctlPath = "/bin/launchctl"
    public static let systemPlistURL = URL(fileURLWithPath:
        "/Library/LaunchDaemons/\(LaunchDaemonInstaller.label).plist")

    private let runner: any CommandRunning
    private let plistURL: URL
    private let programPath: String

    /// `programPath` and `plistURL` stay injectable so tests can drive this
    /// against a scratch directory and a modelled `launchctl`. Production
    /// callers pass neither: taking the program path from an argument is what
    /// made `sudo .build/debug/coffee-bar-probe arm` a one-line root
    /// persistence primitive, and what M5 cannot express at all.
    public init(runner: any CommandRunning,
                plistURL: URL = LaunchDaemonInstaller.systemPlistURL,
                programPath: String = LaunchDaemonInstaller.runningExecutablePath()) {
        self.runner = runner
        self.plistURL = plistURL
        self.programPath = programPath
    }

    /// The absolute path of the running executable.
    ///
    /// `Bundle.main.executablePath` rather than `CommandLine.arguments[0]`:
    /// measured, argv[0] is `"./coffee-bar-probe"` when the binary is invoked
    /// relatively, while `executablePath` is the absolute, symlink-resolved
    /// path in both cases. A relative path here would be written straight into
    /// the plist for launchd to resolve against `/`.
    public static func runningExecutablePath() -> String {
        Bundle.main.executablePath ?? ""
    }

    /// Serialises the launchd job description.
    ///
    /// Built as a dictionary and serialised, NOT interpolated into an XML
    /// template. `programPath` is attacker-influenced in the M5 threat model
    /// and was, measured, a root-capability primitive under interpolation: a
    /// crafted path rendered a plist `plutil -p` parsed cleanly, carrying an
    /// injected `UserName`, a `Junk` key and
    /// `EnvironmentVariables => {DYLD_INSERT_LIBRARIES => …}` beside a
    /// truncated `ProgramArguments` of `["/bin/sh", "-c", "echo INJECTED"]`.
    ///
    /// The dangerous payloads are the ones that stay WELL-FORMED — a bare `&`
    /// or `<` yields XML launchd rejects, which the exit-code check already
    /// catches. Escaping is what is easy to get subtly wrong; serialisation
    /// makes an injected KEY unrepresentable rather than merely escaped.
    ///
    /// Internal rather than public: it is the unit the injection guard drives
    /// directly, and defence in depth means it must hold even for paths
    /// `validatedProgramPath` would have refused.
    func plistData(programPath: String) throws -> Data {
        let job: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [programPath, "watchdog"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: job, format: .xml, options: 0)
    }

    /// Canonicalises a program path and refuses it unless every component is
    /// root-owned and not group- or other-writable.
    ///
    /// This is the same bar `docs/ENGINEERING-NOTES.md` sets for the journal
    /// path, for the same reason and one step earlier: the journal is an
    /// instruction to a root process, and this is the root process. launchd
    /// execs `ProgramArguments[0]` as uid 0 with `RunAtLoad` and `KeepAlive`,
    /// so a program file any local process can rewrite is root persistence
    /// handed to whoever gets there first. Unvalidated, the natural first live
    /// run — `sudo .build/debug/coffee-bar-probe arm` — installs exactly that,
    /// pointed at a file inside `$HOME` that `swift build` itself rewrites.
    ///
    /// EVERY component is checked, not just the leaf: a root-owned binary in a
    /// user-writable directory can simply be replaced by rename.
    ///
    /// The path is resolved first and the RESOLVED form is what is returned and
    /// ultimately written. Checking components of a name that still contains a
    /// symlink would validate one object and exec another, which someone else
    /// can repoint between the two.
    /// The rule itself lives in `PathSecurity`, which the M5 journal reader
    /// asks the same question. Two copies of a security check drift the moment
    /// one is edited, so this maps the shared verdict onto this type's error
    /// vocabulary and adds nothing of its own.
    static func validatedProgramPath(_ path: String) throws -> String {
        do {
            return try PathSecurity.validate(path)
        } catch let error as PathSecurityError {
            switch error {
            case .notAbsolute(let path):
                throw WatchdogInstallError.programPathNotAbsolute(path)
            case .unresolvable(let path, let code):
                throw WatchdogInstallError.programPathUnresolvable(
                    path: path, errno: code)
            case .insecure(let path, let components):
                throw WatchdogInstallError.programPathInsecure(
                    path: path, components: components)
            }
        }
    }

    /// Validates, writes the plist, then hands it to launchd.
    ///
    /// Ordering is not incidental. Validation and serialisation happen before
    /// anything touches disk, so a refused path leaves no trace at all; and
    /// `bootstrap system <path>` READS the file at that path, so the write has
    /// to land before it.
    public func install() throws {
        let program = try Self.validatedProgramPath(programPath)
        let data = try plistData(programPath: program)
        try writeAtomically(data, to: plistURL)

        do {
            // Idempotence, and it is load-bearing rather than tidiness.
            // `bootstrap` on an ALREADY-LOADED label exits non-zero, so
            // without this a second `arm` on an already-armed machine throws —
            // and the caller's rollback then re-applies the SleepDisabled
            // value it just read back (its own `true`) and deletes the
            // journal. The watchdog boots, finds nothing, and the machine
            // never sleeps again. Two `sudo arm` invocations, no attacker.
            //
            // The failure is ignored on purpose: nothing loaded is the
            // ordinary case, and `bootout` exits non-zero for it.
            _ = try? runner.run(Self.launchctlPath,
                                ["bootout", "system/\(Self.label)"])

            let result = try runner.run(Self.launchctlPath,
                                        ["bootstrap", "system", plistURL.path])
            // `launchctl` reports failure through its exit code. Swallowing it
            // would let `install` return normally with NO daemon loaded, and
            // `arm` would then set SleepDisabled believing it is supervised —
            // leaving nothing alive to ever revert it. Throwing here is what
            // drives `arm`'s rollback path.
            guard result.exitCode == 0 else {
                throw PowerControlError.commandFailed(
                    exitCode: result.exitCode, stderr: result.stderr)
            }
        } catch {
            // launchd bootstraps EVERYTHING in /Library/LaunchDaemons at boot.
            // A plist left behind by a failed, rolled-back `arm` therefore
            // resurrects a root daemon the user believes was never installed,
            // pointed at a path that may by then be missing or attacker-owned.
            // The caller cannot tell "failed before the write" from "failed
            // after", so cleanup is this function's responsibility.
            try? FileManager.default.removeItem(at: plistURL)
            throw error
        }
    }

    /// Writes to a sibling temp file, forces it to stable storage with
    /// `F_FULLFSYNC`, atomically renames, then barriers the parent directory —
    /// the house idiom, matching `FileJournalStore.write`.
    ///
    /// Atomicity is not hygiene here. A crash mid-write leaves a truncated
    /// plist launchd cannot parse, so the boot-with-a-dirty-journal case —
    /// the entire reason `RunAtLoad` exists — comes up with no daemon and
    /// nothing ever reverts `SleepDisabled`. Plain `fsync(2)` on macOS only
    /// pushes to the drive cache; `F_FULLFSYNC` is the documented durable
    /// barrier.
    private func writeAtomically(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)

        let tmp = dir.appendingPathComponent(".\(Self.label).\(UUID().uuidString).tmp")
        // 0644 is a security bound, not tidiness. This file is loaded as root;
        // a group- or world-writable copy in /Library/LaunchDaemons hands root
        // to anyone who can rewrite ProgramArguments. launchd refuses to load
        // one, so a wrong mode also means no daemon at all. Setting the mode
        // at CREATION closes the window a later `chmod` would leave open.
        guard FileManager.default.createFile(
            atPath: tmp.path, contents: nil,
            attributes: [.posixPermissions: 0o644]) else {
            throw WatchdogInstallError.plistWriteFailed(
                "could not create \(tmp.path)")
        }
        let handle = try FileHandle(forWritingTo: tmp)
        do {
            try handle.write(contentsOf: data)
            if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 {
                throw WatchdogInstallError.plistSyncFailed(errno)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }

        // `.usingNewMetadataOnly` because the default preserves the ORIGINAL
        // item's metadata: a plist someone had widened to 0666 would otherwise
        // carry that mode forward through every reinstall, silently keeping
        // open exactly the escalation the mode above closes.
        do {
            _ = try FileManager.default.replaceItemAt(
                url, withItemAt: tmp, options: [.usingNewMetadataOnly])
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }

        // The rename above is a directory metadata change. Syncing the file's
        // contents does not make its NAME durable — after a power failure the
        // entry can be absent while the system mutation it describes has
        // already landed.
        //
        // Best-effort on purpose: a barrier we cannot take must not turn a
        // successful write into a failed arm. The bytes are already on media.
        let dirFD = open(dir.path, O_RDONLY)
        if dirFD >= 0 {
            _ = fcntl(dirFD, F_FULLFSYNC)
            close(dirFD)
        }
    }

    /// Removes the plist, then unloads the daemon.
    ///
    /// That order is the fix for a measured failure, not a preference. This
    /// runs INSIDE the job it is booting out, and `bootout system/<label>`
    /// terminates the process that issues it, so nothing sequenced after it is
    /// reached. Unloading first therefore never got as far as the removal:
    /// observed on the machine after a TTL revert, `launchctl print
    /// system/com.coffeebar.probewatchdog` answered "Could not find service"
    /// while `/Library/LaunchDaemons/com.coffeebar.probewatchdog.plist` was
    /// still on disk with `RunAtLoad` and `KeepAlive` set. launchd bootstraps
    /// that directory at every boot, so the daemon came back for good.
    ///
    /// Inverting the two makes the artifact that can survive the harmless one:
    /// a loaded service with no plist dies at the next reboot and stays dead,
    /// while a plist with no service comes back forever.
    ///
    /// Deliberately asymmetric with `install`: the bootout failure is tolerated
    /// and the plist is removed regardless. `bootout` exits non-zero whenever
    /// nothing is loaded — the ordinary case on a second `revert` — and a
    /// `revert` that refused to finish for that reason would leave sleep
    /// disabled, which is the outcome this whole component exists to prevent.
    ///
    /// The bootout is unconditional rather than gated on the plist existing:
    /// the file can be gone while the service is still loaded, and skipping it
    /// then would strand a live root daemon that `KeepAlive` keeps restarting.
    public func uninstall() throws {
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
        // Last, because it does not come back.
        _ = try? runner.run(Self.launchctlPath,
                            ["bootout", "system/\(Self.label)"])
    }
}
