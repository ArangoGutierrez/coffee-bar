// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Every verb `coffee-bar-probe` accepts, and the usage text, from one list.
///
/// v0.1 shipped these as two lists that disagreed: `main.swift` handled `arm`,
/// `report`, `revert` and `watchdog`, while the usage text named only the first
/// three. `watchdog` was reachable and undocumented.
///
/// A usage string and a `switch` are two spellings of the same list, so they
/// drift. This type removes the second spelling: `usage` is BUILT from
/// `allCases`, and `main.swift` switches over the enum with no `default`, which
/// makes an unhandled verb a compile error rather than a silent omission.
///
/// The verb list is FIXED and none of these takes a path to execute, per
/// SECURITY.md. `LaunchDaemonInstaller.swift` "taking the program path from an argument" records what the
/// alternative bought: taking a program path from an argument made
/// `sudo .build/debug/coffee-bar-probe arm` a one-line root persistence
/// primitive.
public enum ProbeVerb: String, CaseIterable, Sendable {
    case run
    case arm
    case report
    case revert
    case watchdog
    /// The registered helper's entry point (#71).
    ///
    /// **The first verb in this binary that LISTENS**, and the only one nobody
    /// types. `launchd` starts it for the `SMAppService` job whose plist ships
    /// inside the app bundle; the user's part is clicking a button and
    /// approving the prompt macOS presents.
    ///
    /// It does NOT replace `arm`. Both paths coexist: a Homebrew install gets
    /// an ad-hoc bundle that can register nothing, so `sudo coffee-bar-probe
    /// arm` stays the only route those users have — and a user who armed it
    /// before upgrading must not be broken.
    case serve

    /// How long `arm` holds the setting when the caller names no `--ttl`.
    ///
    /// 8 hours, and deliberately NOT `JournalRecord.maxTTLSeconds`. §8.2(5)
    /// makes that a CEILING — the longest hold a user may ASK for — and using
    /// it as the default confuses two different numbers.
    ///
    /// **Was 30 minutes, and the argument for that was wrong rather than
    /// merely conservative (#74).** It ran: supervision here is TTL-only, there
    /// is no heartbeat writer, so the default is the WORST CASE for a user who
    /// arms, walks away and never comes back — and eight hours of that is an
    /// overnight battery.
    ///
    /// The overnight battery is the case the TTL never covered. It runs ON
    /// BATTERY, and `WatchdogDecision.decide` checks the battery floor at rung
    /// 5, one rung ABOVE this. That hold ends at the daemon's built-in 15%
    /// floor whatever the TTL says; the floor was doing the work the TTL was
    /// being credited with. What half an hour actually ended was a hold on AC,
    /// where the machine is plugged in and nothing whatever is at risk — and it
    /// ended it in the middle of the long unattended run the mode exists for.
    ///
    /// So this is the AC hold: long enough to outlast a real agent run, and
    /// adjustable. The Preferences window writes the value a user chose into
    /// the `--ttl` on the command it prints, up to the ceiling. That is the
    /// only route the setting takes — nothing here reads a preference file,
    /// because this process runs as root and the preferences belong to a user.
    /// SECURITY.md states the same thing under "Supervision is TTL-only".
    public static let defaultTTLSeconds = 8 * 60 * 60

    /// The flag that carries a hold on the command line, spelled ONCE.
    ///
    /// **Two programs read this string and they are not the same program.**
    /// `main.swift` matches on it to parse argv; `ServingModel` interpolates the
    /// user's chosen hold beside it into the command the Preferences window
    /// prints. Before this constant those were two literals in two modules, and
    /// the drift between them is silent in the worst way: `parse()` ignores
    /// unknown flags by design, so renaming the flag in `main.swift` — to
    /// `--hold`, say — leaves the window printing a command that succeeds,
    /// reports success, and arms the DEFAULT hold rather than the one the user
    /// chose. Nothing errors, and every other check in the package stays green.
    ///
    /// This is the whole channel issue #74's setting travels down. The value a
    /// user picks reaches the root daemon by being typed into a shell as part of
    /// this flag and by no other route, because a root process reading an
    /// unprivileged user's preferences is a data flow SECURITY.md declines to
    /// create. A channel with one link in it is worth naming.
    /// `theTTLFlagThePrintedCommandUsesIsTheOneTheBinaryParses` reads both sides.
    public static let ttlFlag = "--ttl"

    /// What `main.swift` runs when argv names no verb.
    ///
    /// Deliberately the unprivileged one. A privileged default would let a
    /// bare `sudo coffee-bar-probe` — a mistyped flag, a stray argument — arm
    /// the machine by accident.
    public static let `default` = ProbeVerb.run

    /// Whether the verb needs uid 0.
    ///
    /// Per-verb rather than a blanket warning: telling a user to `sudo`
    /// everything trains them to run the reading verbs as root for no reason.
    /// `report` is privileged for a reason that is easy to miss: the journal it
    /// prints is a root-owned 0600 file, so an unprivileged read cannot open it
    /// at all. Advertising it as unprivileged would send a user to a permission
    /// error rather than to `sudo`.
    public var requiresRoot: Bool {
        switch self {
        case .run: return false
        case .arm, .report, .revert, .watchdog, .serve: return true
        }
    }

    public var summary: String {
        switch self {
        case .run:
            return "unprivileged capability spikes (default)"
        case .arm:
            return "disable sleep with a TTL watchdog, and force the display off"
        case .report:
            return "print the current journal: what is armed, since when, until when"
        case .revert:
            return "restore the prior sleep setting and remove the watchdog"
        case .watchdog:
            return "supervise an armed run; launchd starts this, you do not"
        case .serve:
            return "serve the app's arm requests; the registered helper, not for you"
        }
    }

    /// The usage text, generated from `allCases` so it cannot omit a verb.
    ///
    /// The rows are indented by two spaces and start with the verb, which is
    /// the shape `theUsageTextAdvertisesNothingTheBinaryCannotHandle` parses
    /// back out.
    public static var usage: String {
        let width = allCases.map(\.rawValue.count).max() ?? 0
        let rows = allCases.map { verb -> String in
            let padded = verb.rawValue.padding(toLength: width, withPad: " ",
                                               startingAt: 0)
            let root = verb.requiresRoot ? " (root)" : ""
            return "  \(padded)  \(verb.summary)\(root)"
        }
        return """
        usage: coffee-bar-probe <verb> [--json] [--ttl <seconds>]

        \(rows.joined(separator: "\n"))

        """
    }
}
