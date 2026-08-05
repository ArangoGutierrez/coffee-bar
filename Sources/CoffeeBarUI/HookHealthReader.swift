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
public struct HookHealthReader: Sendable {
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
    /// `nil` means one of two things, and neither is a fault the user can act
    /// on: this reader does not cover the tool, or the tool's file is not on
    /// disk. **An absent file means the user does not run that tool**, so a
    /// Claude-Code-only user is never told to wire Cursor.
    ///
    /// The gate is FILE EXISTENCE and never "has this tool ever posted an
    /// event". That second rule is circular: a tool with no hooks wired never
    /// posts, so it would never be advised, and the advisory exists for exactly
    /// that user.
    ///
    /// `.unreadable` stays reserved for a file that EXISTS and will not parse.
    /// Folding an absent file into it would send a user to fix a file that is
    /// not theirs to fix — which is how a shared settings file gets clobbered.
    public func status(for tool: AgentTool) -> HookHealthStatus? {
        guard let url = hookFiles[tool],
              FileManager.default.fileExists(atPath: url.path)
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
