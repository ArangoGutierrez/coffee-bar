// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoffeeBarCore

/// Reads each agent tool's hook file and reports whether our hooks are
/// installed in it.
///
/// **One file per tool, and each is parsed in its own shape.** Until issue #10c
/// this read `~/.claude/settings.json` alone and filtered the Claude Code event
/// list whatever tool the user ran, so a Codex user and a Cursor user were both
/// told to paste PascalCase Claude Code entries into a file their tool never
/// reads. `HookHealth.settingsPath(for:)` now says where each file lives and
/// `HookHealth.status(of:for:)` says how to read it.
///
/// **This type only ever reads.** Design §6 forbids putting bytes into these
/// files: each is shared territory, and this workspace records a critical
/// six-occurrence last-writer-wins clobber pattern in exactly one of them.
/// coffee-bar prints the snippet for the user to paste, and reads the file back
/// so a clobbered snippet becomes visible failure rather than silent failure.
///
/// Two checks hold that line, from two directions —
/// `readingTheStatusLeavesTheFileExactlyAsItWas` runs this type and compares
/// the bytes on disk, and `noSourceFileThatKnowsTheSettingsPathCanWriteToIt`
/// reads this source for any call that puts bytes on disk.
///
/// **What it can and cannot see.** `.wired` means the entries are in the file.
/// It does NOT mean an event has ever arrived: PE finding B2 measured a second
/// app instance stealing the socket path, after which ingest is dead and this
/// file is untouched. A live-socket probe is the separate check that would
/// close that gap.
///
/// Design §8 puts the file read in `CoffeeBarIngest`, so that `CoffeeBarCore`
/// keeps its no-I/O rule. This landed first, before that target existed, and
/// `CoffeeBarUI` is the nearest home that keeps the pure parse in
/// `CoffeeBarCore` — `ServingModel`, the one caller, lives here.
///
/// `CoffeeBarIngest` exists now, and both targets are in the app layer, so the
/// move is a file move and a module change with no behaviour in it. It is
/// DEFERRED rather than done: it buys no correctness, and both directories are
/// scanned by `AppLayerBoundary_test.swift` either way.
/// What `ServingModel` needs from a hook-health source.
///
/// A protocol so a check can inject a source whose two reads DISAGREE, which is
/// the only way to prove `ServingModel.hookHealth` is DERIVED from the
/// collection rather than read a second time. A guard driven by real files
/// cannot see that bug: both reads land microseconds apart against one
/// unchanging file, so they agree even when the model is wrong.
///
/// It also puts this type beside the four `ServingModel` seams that were
/// already protocols — the assertion holder, the power reader, the ingest
/// listener and the settings store. `HookHealthReader` was the one concrete
/// dependency left. None of the four is named in code or in prose here, because
/// a boundary check in `AppLayerBoundary_test.swift` reserves the holder's type
/// names to `ServingModel.swift` and reads this file RAW, comments included.
/// That check is right to, so this comment works around it rather than the
/// other way about.
public protocol HookHealthProviding: Sendable {
    /// Claude Code's verdict, with no existence gate.
    func status() -> HookHealthStatus
    /// Every tool this source has something to say about.
    func statuses() -> [AgentTool: HookHealthStatus]
}

public struct HookHealthReader: HookHealthProviding {
    /// The hook file this reader inspects for each tool it covers.
    ///
    /// A map and not three stored properties, because ABSENCE FROM IT is
    /// meaningful: a reader built for Claude Code alone must not reach the
    /// machine's real `~/.codex/hooks.json`. Every check that injects a fixture
    /// would otherwise read the developer's own configuration, pass on a laptop
    /// with no Codex installed and fail on one that has it.
    /// `aReaderBuiltForClaudeCodeAloneReadsNoOtherToolsFile` holds that line.
    public let hookFiles: [AgentTool: URL]

    /// Covers all three tools. `HookHealth.settingsPath(for:)` is the one place
    /// that says where each file lives.
    public init(hookFiles: [AgentTool: URL] = HookHealthReader.defaultHookFiles) {
        self.hookFiles = hookFiles
    }

    /// A Claude-Code-ONLY reader.
    ///
    /// No default argument, so `HookHealthReader()` still resolves to the
    /// three-tool initialiser above.
    public init(settingsURL: URL) {
        self.init(hookFiles: [.claudeCode: settingsURL])
    }

    /// Where each tool keeps its hook file on this machine.
    public static var defaultHookFiles: [AgentTool: URL] {
        var found: [AgentTool: URL] = [:]
        for tool in AgentTool.allCases { found[tool] = defaultURL(for: tool) }
        return found
    }

    /// Design §6 fixes the Claude Code location; the other two were measured off
    /// the running tools. This is the ONLY place a home directory is resolved.
    public static func defaultURL(for tool: AgentTool) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: HookHealth.settingsPath(for: tool))
    }

    /// Design §6 fixes the location.
    public static var defaultSettingsURL: URL { defaultURL(for: .claudeCode) }

    /// Claude Code's settings file, or the design §6 default when this reader
    /// does not cover Claude Code at all.
    ///
    /// Kept as a named property because `theDefaultSettingsURLIsTheUsersClaudeSettings`
    /// pins it, and because `noSourceFileThatKnowsTheSettingsPathCanWriteToIt`
    /// finds this file through the name. Both initialisers above supply a Claude
    /// Code entry, so the fallback is unreachable through this package's API.
    public var settingsURL: URL {
        hookFiles[.claudeCode] ?? HookHealthReader.defaultSettingsURL
    }

    /// Never throws. An absent file, a directory, a permission refusal and a
    /// half-saved file all reach the panel as `.unreadable`, because none of
    /// them is evidence that the entries are gone.
    ///
    /// Claude Code's verdict with NO existence gate, unlike `status(for:)`. The
    /// difference is deliberate and `ServingModel` depends on it: this answers
    /// "what does the file say", and the panel separately decides whether the
    /// user runs the tool at all.
    public func status() -> HookHealthStatus {
        HookHealth.status(ofSettings: try? Data(contentsOf: settingsURL))
    }

    /// What `tool`'s hook file says, or `nil` when there is nothing to say.
    ///
    /// `nil` means this reader does not cover the tool, or the tool's file is
    /// not on disk. **An absent file means the user does not run that tool**, so
    /// a Claude-Code-only user is never told to wire Cursor.
    ///
    /// The gate is FILE EXISTENCE and never "has this tool ever posted an
    /// event". That second rule is circular: a tool with no hooks wired never
    /// posts, so it would never be advised, and the advisory exists for exactly
    /// that user.
    ///
    /// **`.claudeCode` is EXEMPT from the gate, and the exemption is narrow on
    /// purpose.** An absent file carries a DIFFERENT meaning for each cohort:
    ///
    /// - Claude Code is the primary integration and the first-run path. No file
    ///   there means "not set up yet". The README tells the reader coffee-bar
    ///   does nothing until those hooks exist, so this is the user who most
    ///   needs the advisory — and the first round of issue #10c gated them into
    ///   silence.
    /// - Codex and Cursor are opt-in. No file there means "does not run this
    ///   tool", and advising that user is the noise this task exists to remove.
    ///
    /// What the exemption COSTS, stated rather than hidden: a Codex-only user
    /// who has never run Claude Code still reads one line about
    /// `~/.claude/settings.json`. That line is true — coffee-bar genuinely
    /// cannot confirm those hooks — but it is not the most useful thing to tell
    /// them. Silence for a first-run user is the worse failure of the two,
    /// because it hides the one action that makes the product work at all.
    ///
    /// `.unreadable` stays reserved for a file this app could not parse, whether
    /// it is absent or malformed. It never tells the user to paste entries that
    /// may already be there, which is how a shared settings file gets clobbered.
    public func status(for tool: AgentTool) -> HookHealthStatus? {
        guard let url = hookFiles[tool] else { return nil }
        guard tool == .claudeCode
                || FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return HookHealth.status(of: try? Data(contentsOf: url), for: tool)
    }

    /// Every tool whose hook file is on disk, with what that file says.
    ///
    /// This is what the panel reads. Assigning a `nil` through a dictionary
    /// subscript REMOVES the key, so the tools `status(for:)` had nothing to say
    /// about are simply absent — which is the claim the panel needs.
    public func statuses() -> [AgentTool: HookHealthStatus] {
        var found: [AgentTool: HookHealthStatus] = [:]
        for tool in AgentTool.allCases { found[tool] = status(for: tool) }
        return found
    }
}
