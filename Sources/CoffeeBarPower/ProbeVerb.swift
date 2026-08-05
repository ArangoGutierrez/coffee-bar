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
/// SECURITY.md. `LaunchDaemonInstaller.swift:63-67` records what the
/// alternative bought: taking a program path from an argument made
/// `sudo .build/debug/coffee-bar-probe arm` a one-line root persistence
/// primitive.
public enum ProbeVerb: String, CaseIterable, Sendable {
    case run
    case arm
    case report
    case revert
    case watchdog

    /// How long `arm` holds the setting when the caller names no `--ttl`.
    ///
    /// 30 minutes, and deliberately NOT `JournalRecord.maxTTLSeconds`. §8.2(5)
    /// makes 8 h a CAP — the longest hold a user may ASK for — and using it as
    /// the default confuses two different numbers.
    ///
    /// Supervision on this path is TTL-only. There is no heartbeat writer, so
    /// nothing cuts a hold short when the work finishes early: the default is
    /// the WORST CASE for a user who arms, walks away and never comes back.
    /// Eight hours of that is an overnight battery. Half an hour covers an
    /// ordinary agent run, and `--ttl` buys more, up to the cap.
    public static let defaultTTLSeconds = 30 * 60

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
        case .arm, .report, .revert, .watchdog: return true
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
