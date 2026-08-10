// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoffeeBarCore

/// What `ServingModel` needs from a source of the root helper's state.
///
/// A protocol so a check can inject a machine this one is not. The states that
/// matter — `.stale` above all — describe a Mac whose privileged copy of the
/// probe is an older build, and no arrangement of files in this repository
/// produces that through the shipping default: it resolves the probe beside the
/// RUNNING executable, which under `swift test` is the test binary.
///
/// It also puts this dependency beside the five `ServingModel` seams that were
/// already protocols — the power reader, the hook-health source, the ingest
/// listener, the settings store and the one that talks to IOKit. Each is held as
/// `any <Protocol>` with a concrete default, and a sixth stored as a concrete
/// type would be the one dependency no check could stand in for. None of those
/// five is named here, in code or in prose, because a boundary check in
/// `AppLayerBoundary_test.swift` reserves one of their type names to
/// `ServingModel.swift` and reads this file RAW, comments included. That check is
/// right to, so this comment works around it rather than the other way about.
///
/// **Honest limit, because the seam below is weaker than `HookHealthProviding`'s.**
/// That protocol exists because a source whose two reads DISAGREE cannot be built
/// from files at all. This one can be driven to every state it has through
/// `PrivilegedHelperReader`'s injectable URLs, and
/// `PrivilegedHelperReader_test.swift` does exactly that. What the protocol buys
/// is the composition root's uniformity and a double that changes its answer
/// between refreshes without a file moving — not a state that is otherwise out of
/// reach.
public protocol PrivilegedHelperStateProviding: Sendable {
    /// What the privileged copy of the probe is, relative to this build's.
    func state() -> PrivilegedHelperState
}

/// Compares the probe this build ships with the one root actually runs.
///
/// **This type only ever reads, and it needs no privilege to.** `install(1)`
/// puts the privileged copy at mode 755 under a `drwxr-xr-x root:wheel`
/// directory — measured on macOS 26.5.2 — so any user can open it. Nothing here
/// runs `sudo`, and nothing here executes the probe: the comparison is over
/// BYTES, which is what `PrivilegedHelper.state` decides on. coffee-bar never
/// elevates its own privilege (SECURITY.md, design §6.3), and a stale-helper
/// check that did would be a worse fault than the one it reports.
///
/// **It reads only the files it was GIVEN.** Both locations arrive through
/// `init`, so a reader built for a check cannot reach the machine's real
/// `/Library/PrivilegedHelperTools` and report a verdict about the developer's
/// own install. That is the same rule `HookHealthReader.hookFiles` states, for
/// the same reason.
///
/// **The installed copy is read only when there is something to compare it
/// against.** Without a bundled copy the answer is `.unverifiable` whatever is
/// installed — `PrivilegedHelper.state` decides that case first — so opening the
/// second file would be a read of a machine-dependent path whose result is
/// discarded. Under `swift test` that is exactly the position the default reader
/// is in.
///
/// **What it can and cannot see.** `.current` means the two files hold the same
/// bytes. It does NOT mean lid-closed mode is armed: the launchd job and the
/// journal that records it are root-owned and this process measurably cannot
/// read either, which is what `ServingModel.lidClosedSummary` tells the user.
/// A byte-identical probe that was never armed reports `.current` here and is
/// right to — there is nothing stale about it.
public struct PrivilegedHelperReader: PrivilegedHelperStateProviding {
    /// The copy this build ships, beside the running executable.
    public let bundledProbe: URL

    /// The copy root runs, which is the one the printed command writes.
    public let installedProbe: URL

    public init(bundledProbe: URL = PrivilegedHelperReader.defaultBundledProbe,
                installedProbe: URL = PrivilegedHelperReader.defaultInstalledProbe) {
        self.bundledProbe = bundledProbe
        self.installedProbe = installedProbe
    }

    /// The probe beside THIS copy of the app.
    ///
    /// `Bundle.main` is read here and nowhere in the model, which is the split
    /// `ServingModel.probePath(besideExecutable:)` documents: the sentence the
    /// user reads is composed from a path the VIEW supplies, and this reader
    /// resolves its own because it is the thing doing the I/O. Both go through
    /// that one function, so the file this opens and the file the printed
    /// command copies cannot become two different answers.
    ///
    /// Machine-dependent by construction, exactly like
    /// `HookHealthReader.defaultHookFiles`. Every check supplies its own URLs.
    public static var defaultBundledProbe: URL {
        URL(fileURLWithPath: ServingModel.probePath(besideExecutable: Bundle.main.executableURL))
    }

    /// Where root runs the probe from.
    ///
    /// `ServingModel.privilegedProbePath` and never a literal. That constant is
    /// what the install command writes to and what the advisory names, so a
    /// second spelling here would check a file the user was never told to
    /// create — and report `.notInstalled` for ever on a correctly armed Mac.
    public static var defaultInstalledProbe: URL {
        URL(fileURLWithPath: ServingModel.privilegedProbePath)
    }

    /// Never throws. An absent file, a directory and a permission refusal all
    /// arrive as `nil`, and `PrivilegedHelper.state` turns each into a verdict
    /// the panel can render. A read that failed is not evidence the machine is
    /// fine.
    public func state() -> PrivilegedHelperState {
        guard let bundled = try? Data(contentsOf: bundledProbe) else {
            return PrivilegedHelper.state(bundled: nil, installed: nil)
        }
        return PrivilegedHelper.state(bundled: bundled,
                                      installed: try? Data(contentsOf: installedProbe))
    }
}
