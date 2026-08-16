// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Whether coffee-bar comes back after a reboot.
///
/// A protocol, so the app layer can be handed one that writes nothing, and so
/// no check ever installs a live login item on the machine running the suite.
/// It is the same shape of seam as `AssertionHolding` and `SettingsStoring`:
/// one real implementation, injected at the boundary.
public protocol LoginItemInstalling: Sendable {
    /// Installs the login item. Throws `LoginItemError.notOptedIn` unless the
    /// user has asked for it.
    func install() throws
    /// Removes it. Succeeds when there was nothing to remove, and is NOT gated
    /// on the opt-in — see the note on the conformer.
    func uninstall() throws
    func isInstalled() -> Bool
}

public enum LoginItemError: Error, Equatable {
    /// The user has not asked for a login item, so none is installed.
    ///
    /// It is an ERROR and not a silent return. A caller that got `Void` back
    /// could not tell "installed" from "declined", and the one place that
    /// difference matters is a future second caller.
    case notOptedIn

    /// launchd resolves a relative `ProgramArguments[0]` against `/`, so
    /// `"./coffee-bar"` becomes `/coffee-bar`.
    case programPathNotAbsolute(String)

    case plistWriteFailed(String)
}

/// Installs coffee-bar as a per-user launchd AGENT, on an explicit opt-in.
///
/// # Why this exists
///
/// Issue #48, measured after a restart: no coffee-bar launch agent, process not
/// running. The cup vanishes, nothing relaunches it, there is no error and no
/// notification — and the hooks carry on firing into a socket nobody serves,
/// which is the state `HookHealth` treats as a real failure. The only surface
/// that would report it is the panel the user cannot see, because the app is
/// not running.
///
/// # What it is NOT
///
/// It is not `LaunchDaemonInstaller`, and the difference is privilege rather
/// than style. That one writes `/Library/LaunchDaemons` and needs root, because
/// the watchdog it supervises has to revert a system-wide `SleepDisabled` a
/// user process cannot touch. This one writes `~/Library/LaunchAgents`, inside
/// the user's own home, and needs no privilege whatever: launchd bootstraps
/// that directory into the user's own GUI session at every login.
///
/// It is not `SMAppService.loginItem` either. That API is refused across every
/// target linked into `coffee-bar` by
/// `noTargetOnThePrivilegedPathReachesForXPCOrSMAppService`, which is a
/// security decision issue #71 owns; adopting it is that issue's change to
/// make, and a second copy written here would be the drift the guard exists to
/// prevent. A plist plus `RunAtLoad` needs no app bundle, no code signing and
/// no framework — the same property that made M0 choose a plain plist for the
/// daemon.
///
/// # Why it WRITES a file, when the rest of this product prints one
///
/// Design §6 is "print, never write", and the Agent tools section obeys it: it
/// copies a hook snippet to the pasteboard and refuses to merge it into the
/// agent tool's own configuration file. That rule is about SHARED TERRITORY.
/// Those files belong to another tool that is also editing them, and this
/// workspace records a six-occurrence last-writer-wins clobber in exactly that
/// kind of config — coffee-bar merging its own entry is how a user loses
/// settings they never told anyone about.
///
/// (The path itself is deliberately not spelled here.
/// `noSourceFileThatKnowsTheSettingsPathCanWriteToIt` reads every file under
/// `Sources/` that can reach it and refuses one that names a way to put bytes
/// on disk. This file is exactly such a way, and it must stay outside that set:
/// admitting it would either turn a correct tree red or force the guard to be
/// widened around the one file it should never be widened around.)
///
/// `~/Library/LaunchAgents/com.coffeebar.loginitem.plist` is a path coffee-bar
/// alone owns. Nothing else writes it, so there is nothing to clobber, and
/// removing the file returns the machine to the state it was in before anybody
/// opted in — which is the property the "print it" alternative cannot match
/// here. Lid-closed mode prints its command because arming needs ROOT and
/// SECURITY.md forbids this app elevating its own privilege; that reason does
/// not reach a file in the user's own home. Printing this one would hand the
/// user a plist to hand-write and, worse, a second hand-edit to undo it —
/// making an install with no uninstall out of the one feature whose acceptance
/// criterion is that the user can get back.
///
/// # What it does NOT do
///
/// It runs no `launchctl`, on either path, and both halves of that are
/// deliberate:
///
///   - On INSTALL, `launchctl bootstrap gui/<uid>` would load the job
///     immediately, and `RunAtLoad` would then start a SECOND coffee-bar beside
///     the one the user is clicking in. The second copy loses the race for the
///     ingest socket and reports `alreadyServing` — a failure invented entirely
///     by the install. The plist alone is enough: launchd reads the directory
///     at the next login, which is exactly when the user asked to be started.
///   - On UNINSTALL, `launchctl bootout gui/<uid>/<label>` would terminate the
///     running process — and after the first reboot that process IS this one.
///     A user who unticks "open at login" is asking not to be started next
///     time, not to be quit now.
///
/// The honest cost, stated rather than buried: turning the switch on takes
/// effect at the NEXT login, not immediately. That is what the switch says, and
/// there is nothing to observe in between.
public struct LoginItemInstaller: LoginItemInstalling {
    /// The launchd job name.
    ///
    /// DISTINCT from `LaunchDaemonInstaller.label`, and the distinctness is
    /// asserted. launchd keys a service by its label within a domain; these two
    /// live in different domains today — `gui/<uid>` against `system` — so a
    /// collision would not be fatal now, which is precisely why nothing would
    /// report it if a later edit converged the two names.
    public static let label = "com.coffeebar.loginitem"

    private let settings: any SettingsStoring
    private let plistURL: URL
    private let programPath: String

    /// `plistURL` and `programPath` stay injectable so checks can drive this
    /// against a scratch directory. Production callers pass neither.
    public init(settings: any SettingsStoring = UserDefaultsSettingsStore(),
                plistURL: URL = LoginItemInstaller.userPlistURL(),
                programPath: String = LoginItemInstaller.runningExecutablePath()) {
        self.settings = settings
        self.plistURL = plistURL
        self.programPath = programPath
    }

    /// `~/Library/LaunchAgents/com.coffeebar.loginitem.plist`.
    ///
    /// The USER's tree, never `/Library/LaunchAgents` and never
    /// `/Library/LaunchDaemons`. Both of those need root, and this feature ships
    /// as a switch precisely because it needs none.
    public static func userPlistURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(LoginItemInstaller.label).plist")
    }

    /// The absolute path of the running executable.
    ///
    /// `Bundle.main.executablePath` rather than `CommandLine.arguments[0]`, for
    /// the reason `LaunchDaemonInstaller` gives: measured, argv[0] is
    /// `"./coffee-bar"` when the binary is invoked relatively, while
    /// `executablePath` is the absolute, symlink-resolved path in both cases.
    ///
    /// `?? ""` rather than a trap. An empty path is not absolute, so it takes
    /// the refusal below and reports itself — a `fatalError` here would take the
    /// app down for a preference.
    public static func runningExecutablePath() -> String {
        Bundle.main.executablePath ?? ""
    }

    /// Serialises the launchd job description.
    ///
    /// Built as a dictionary and serialised, NOT interpolated into an XML
    /// template — the same construction `LaunchDaemonInstaller.plistData` uses
    /// and for a weaker version of the same reason. There, a crafted
    /// `programPath` was measured producing a plist `plutil -p` parsed cleanly
    /// while carrying an injected `UserName` and
    /// `EnvironmentVariables => {DYLD_INSERT_LIBRARIES => …}`. Here the job runs
    /// as the user already, so an injected key buys an attacker nothing they
    /// could not have anyway — but serialisation makes an injected KEY
    /// unrepresentable rather than merely escaped, it costs one line, and its
    /// absence would be invisible.
    ///
    /// THREE KEYS, and the fourth is the one that matters. `KeepAlive` is
    /// deliberately absent: on the root watchdog it is load-bearing, because a
    /// SIGKILLed supervisor must come back or nothing reverts `SleepDisabled`.
    /// On a menu-bar app it makes the Quit button inert — launchd restarts the
    /// process within the second, and the only way out is a plist the user does
    /// not know exists. `RunAtLoad` alone is "start it at login", which is what
    /// the switch says and all it says.
    ///
    /// `ProcessType` is absent for the same reason: `Background` is right for
    /// the watchdog and wrong for a process that draws in the user's menu bar.
    ///
    /// Internal rather than public: it is the unit the injection check drives
    /// directly, and defence in depth means it must hold even for paths
    /// `validatedProgramPath` would have refused.
    func plistData(programPath: String) throws -> Data {
        let job: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [programPath],
            "RunAtLoad": true,
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: job, format: .xml, options: 0)
    }

    /// Canonicalises a program path and refuses it unless it is absolute.
    ///
    /// **This is deliberately NOT the bar `LaunchDaemonInstaller` sets, and the
    /// difference is reasoned rather than lax.** That one refuses any path with
    /// a component not owned by root or writable by group or other, because
    /// launchd execs it as uid 0: a program file any local process can rewrite
    /// is root persistence handed to whoever gets there first. This job runs as
    /// the user who installed it, with that user's own privileges, so a
    /// rewritable program file grants an attacker nothing they did not already
    /// have — anyone who can rewrite it can run code as that user by a hundred
    /// shorter routes.
    ///
    /// Applying the root bar here would also be wrong in the ordinary case
    /// rather than merely strict: it refuses `~/Applications/coffee-bar.app`, it
    /// refuses the Homebrew prefix on Apple Silicon, and it refuses a
    /// `swift build` tree — three of the four ways this product is installed. A
    /// guard that is red on correct code is deleted rather than obeyed.
    ///
    /// What IS refused is a relative path, because launchd resolves
    /// `ProgramArguments[0]` against `/`: `./coffee-bar` becomes `/coffee-bar`,
    /// the job fails to spawn at every login, and nothing on any surface says
    /// why. The check is on the STRING, before any `URL` is built —
    /// `URL(fileURLWithPath:)` resolves a relative path against the working
    /// directory and would hand back something absolute and wrong.
    ///
    /// The RESOLVED form is what is returned and written. launchd execs whatever
    /// the name points at when the job loads, which is the next login and may be
    /// months away; a symlink readable today can be repointed in between.
    static func validatedProgramPath(_ path: String) throws -> String {
        guard path.hasPrefix("/") else {
            throw LoginItemError.programPathNotAbsolute(path)
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Refuses unless the user asked, then writes the job description.
    ///
    /// **The opt-in is checked HERE and not only at the call site**, and that is
    /// the whole security posture of this component rather than belt-and-braces.
    /// One caller is one line away from two, and the second one will not repeat
    /// the check; a login item that appears because the app ran once is exactly
    /// what design §6 forbids, in the loudest possible place, because the
    /// artifact outlives the process and the next boot acts on it.
    ///
    /// `== true` and not `!= nil`, and not `?? true`. All three compile. `!= nil`
    /// installs for a user who turned the switch OFF, because their stored
    /// `false` is a written key; `?? true` installs for everyone.
    ///
    /// Validation and serialisation happen BEFORE anything touches disk, so a
    /// refused path leaves no trace at all rather than a half-written job
    /// launchd would read at the next login.
    public func install() throws {
        guard settings.bool(forKey: SettingsKey.launchAtLogin) == true else {
            throw LoginItemError.notOptedIn
        }

        let program = try Self.validatedProgramPath(programPath)
        let data = try plistData(programPath: program)

        let directory = plistURL.deletingLastPathComponent()
        do {
            // A user who has never had a launch agent has no
            // `~/Library/LaunchAgents` at all, which is the ordinary first-run
            // state rather than an edge case.
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            // `.atomic` writes a sibling temporary and renames, so launchd never
            // reads a truncated job — a plist it cannot parse is a login item
            // that silently never loads, indistinguishable from the defect this
            // component exists to fix.
            //
            // NO `F_FULLFSYNC`, unlike `LaunchDaemonInstaller.writeAtomically`,
            // and the asymmetry is the consequence rather than the effort. There,
            // a power failure between the write and the barrier leaves a machine
            // whose sleep is disabled with no daemon alive to ever re-enable it.
            // Here it leaves a login item that did not get installed, on a
            // machine that is otherwise untouched, which the switch reinstalls.
            try data.write(to: plistURL, options: [.atomic])
        } catch {
            throw LoginItemError.plistWriteFailed("\(plistURL.path): \(error)")
        }
    }

    /// Removes the job description, if there is one.
    ///
    /// **NOT gated on the opt-in, deliberately, and the asymmetry with `install`
    /// is the acceptance criterion rather than an oversight.** A symmetrical
    /// `guard settings.bool(…) == true` reads tidy and builds the trap: the
    /// model records the user's `false` before it reconciles, so the guard would
    /// refuse exactly the call that removes the item. The user would be left
    /// with a launch agent, a switch that says they have none, and no route back
    /// short of a plist path no surface has ever shown them.
    ///
    /// Removing what is not there is not a failure. The model calls this
    /// whenever the switch goes to `false`, including for a user who never
    /// turned it on and for one who deleted the file by hand; a throw there
    /// would report a failure on a machine that is exactly right.
    public func uninstall() throws {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        try FileManager.default.removeItem(at: plistURL)
    }

    /// Whether the job description is on disk.
    ///
    /// The FILE and not the setting, deliberately: the two can disagree — a
    /// hand-deleted plist, a preferences domain cleared with `defaults delete` —
    /// and this is the one that says what launchd will do at the next login.
    public func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }
}
