// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum HookHealthStatus: Equatable, Sendable {
    case wired
    /// Sorted event names, so the panel's line is stable between refreshes.
    case missing([String])
    /// The file is absent, unreadable, or not JSON. NOT the same as missing:
    /// telling the user to paste entries that are already there is how a
    /// settings file gets clobbered.
    case unreadable
}

/// Checks that the user's Claude Code settings still point at our socket.
///
/// Design §6: coffee-bar PRINTS the snippet and NEVER writes
/// `~/.claude/settings.json`. That file is shared territory, and this workspace
/// records a critical last-writer-wins clobber pattern in exactly it. Reading
/// costs nothing and turns silent failure into visible, recoverable failure.
///
/// **This measures the settings file and nothing else.** PE finding B2: two app
/// instances fighting over the socket node leave the settings file untouched,
/// so a dead ingest path still reports `.wired` here. `.wired` means "the hook
/// entries are installed", never "events are arriving". Whatever renders this
/// must say the first and must not imply the second.
///
/// Pure, and it never throws — a settings file is user-editable, so every
/// malformed shape has to reach a verdict rather than an error the panel would
/// have to handle.
public enum HookHealth {

    /// The events `SessionHub` acts on, for **Claude Code**.
    ///
    /// `PreCompact` is excluded because the hub maps it to nothing. `SessionEnd`
    /// is excluded because design §10.4 leaves it open. `UserPromptSubmit` is
    /// excluded because no Claude Code payload for it was ever captured.
    ///
    /// Already sorted, and `Tests/CoffeeBarCoreTests/HookHealth_test.swift`
    /// pins that. `status(ofSettings:)` filters this array and a filter
    /// preserves order, so the sorted panel line rests on this constant.
    ///
    /// Kept as a constant, and kept Claude-Code-shaped, because `DocsClaims_test`
    /// and `SiteClaims_test` check the documented hook block against it. The
    /// documented block IS the Claude Code one. `requiredEvents(for:)` is the
    /// general form, and a test pins the two together.
    public static let requiredEvents = ["PermissionDenied", "PostToolUse",
                                        "PreToolUse", "SessionStart", "Stop"]

    /// The hook entries `tool` needs wired, or `nil` when there is no advisory.
    ///
    /// **Each list holds only events with a recorded payload for that tool.**
    /// `everyRequiredEventHasARecordedPayloadForThatTool` enforces it. Telling a
    /// user to wire an entry their tool may never send would leave the panel
    /// permanently reporting a fault they cannot clear.
    ///
    /// The two lists differ even though Claude Code and Codex share one event
    /// vocabulary, and the differences are the measurement, not a preference:
    ///
    /// - `PermissionDenied` is Claude Code only. No Codex capture recorded one.
    /// - `UserPromptSubmit` is Codex only. Claude Code sends it, but no Claude
    ///   Code payload for it was ever captured.
    ///
    /// **`nil` is not `[]`.** An empty list would satisfy every filter and make
    /// the panel report `.wired` for a tool this app cannot advise on at all —
    /// a green light for a check that never ran. `nil` says there is no advice.
    public static func requiredEvents(for tool: AgentTool) -> [String]? {
        switch tool {
        case .claudeCode:
            return requiredEvents
        case .codex:
            return ["PostToolUse", "PreToolUse", "SessionStart", "Stop",
                    "UserPromptSubmit"]
        case .cursor:
            // Cursor's payloads are recorded, but nothing in this build ingests
            // them yet, and `~/.cursor/hooks.json` is a different file in a
            // different shape from the one `status(ofSettings:)` parses. An
            // advisory here would tell the user to wire hooks this app would
            // then drop.
            return nil
        }
    }

    /// What an installed hook command must contain to be ours.
    ///
    /// Matched on the COMMAND, not on the event key: another tool's
    /// `SessionStart` hook must not make us report healthy while no event ever
    /// arrives. It carries the directory as well as the file name because
    /// `ingest.sock` alone is a name any tool could pick.
    public static let commandMarker = "coffee-bar/ingest.sock"

    /// Reads a settings file's bytes, or `nil` when there were none to read.
    ///
    /// **This parses Claude Code's `~/.claude/settings.json` shape and no
    /// other.** The nesting it walks — `hooks.<Event>[].hooks[].command` — is
    /// Claude Code's. Codex keeps its hooks in `~/.codex/config.toml`, which is
    /// TOML and not JSON at all, and Cursor keeps them in `~/.cursor/hooks.json`
    /// under a different nesting. Neither of those files has been captured and
    /// measured the way the payloads were, so no parser for them is written
    /// here. A reader that guessed at their shape would report a fault the user
    /// could not clear, or worse, report healthy over a file it misread.
    public static func status(ofSettings data: Data?) -> HookHealthStatus {
        guard let data, let root = decodeObject(data) else { return .unreadable }

        // A readable settings file with no `hooks` key simply has no entries.
        // That is MISSING, not unreadable: the user can fix it by pasting, and
        // telling them the file is broken would send them somewhere else.
        guard let hooks = root["hooks"] as? [String: Any] else {
            return .missing(requiredEvents)
        }

        let missing = requiredEvents.filter { !isWired(hooks[$0]) }.sorted()
        return missing.isEmpty ? .wired : .missing(missing)
    }

    /// The parsed top level, or `nil` when the bytes are not a JSON object.
    ///
    /// A top-level array or string parses as JSON and is still not a settings
    /// file, so it reports unreadable rather than sending the user to paste
    /// five hooks into a file that is not theirs to fix.
    private static func decodeObject(_ data: Data) -> [String: Any]? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return parsed as? [String: Any]
    }

    /// The settings shape is `hooks.<Event>[].hooks[].command`.
    ///
    /// Every level is an optional cast rather than a forced one. The file is
    /// hand-edited, so any key can hold any JSON, and a wrong shape has to mean
    /// "not wired" instead of a trap.
    private static func isWired(_ entry: Any?) -> Bool {
        guard let matchers = entry as? [[String: Any]] else { return false }
        for matcher in matchers {
            guard let commands = matcher["hooks"] as? [[String: Any]] else { continue }
            for command in commands {
                if let text = command["command"] as? String,
                   text.contains(commandMarker) {
                    return true
                }
            }
        }
        return false
    }
}
