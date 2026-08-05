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
    /// **`nil` is not `[]`.** Every tool has an advisory today, but the return
    /// stays optional because those are different claims: an empty list would
    /// satisfy every filter and report `.wired` for a check that never ran,
    /// whereas `nil` says there is no advice to give.
    public static func requiredEvents(for tool: AgentTool) -> [String]? {
        switch tool {
        case .claudeCode:
            return requiredEvents
        case .codex:
            return ["PostToolUse", "PreToolUse", "SessionStart", "Stop",
                    "UserPromptSubmit"]
        case .cursor:
            // Cursor's own vocabulary, not a translation of Claude Code's.
            // `sessionEnd` is left out for the same reason `SessionEnd` is.
            //
            // Cursor's `stop` is absent because no payload for it exists, not
            // because it would be unwanted — it is the one event that would tell
            // the panel a Cursor session is waiting on the human.
            return ["afterFileEdit", "afterShellExecution", "beforeReadFile",
                    "beforeShellExecution", "sessionStart"]
        }
    }

    /// Where `tool` keeps the hook file this check reads, relative to the user's
    /// home directory.
    ///
    /// **All three are JSON, and that is measured rather than researched.** An
    /// earlier version of this comment named `~/.codex/config.toml` as Codex's
    /// location and called it TOML rather than JSON. That is FALSE for
    /// codex-cli 0.146.0, and believing it is why no Codex reader was ever
    /// written. The real file is `~/.codex/hooks.json`, in Claude Code's exact
    /// nesting. `config.toml` carries a `[features] hooks = true` gate and a
    /// `[hooks.state]` table of trust hashes, and every one of those hash keys
    /// points AT `~/.codex/hooks.json`.
    ///
    /// So this package parses no TOML and takes no dependency to do it.
    /// `noSourceOrDocumentStillPutsTheCodexHooksInConfigToml` goes red if the
    /// claim returns.
    ///
    /// A RELATIVE path, because `CoffeeBarCore` performs no I/O — design §8. The
    /// app layer resolves these against the home directory, and
    /// `HookHealthReader` is the one place that does.
    ///
    /// Design §6 fixes the Claude Code location. The other two were read off the
    /// running tools.
    public static func settingsPath(for tool: AgentTool) -> String {
        switch tool {
        case .claudeCode: return ".claude/settings.json"
        case .codex: return ".codex/hooks.json"
        case .cursor: return ".cursor/hooks.json"
        }
    }

    /// What an installed hook command must contain to be ours.
    ///
    /// Matched on the COMMAND, not on the event key: another tool's
    /// `SessionStart` hook must not make us report healthy while no event ever
    /// arrives. It carries the directory as well as the file name because
    /// `ingest.sock` alone is a name any tool could pick.
    public static let commandMarker = "coffee-bar/ingest.sock"

    /// The `coffeebar-hook` shim's binary name.
    ///
    /// Codex and Cursor accept COMMAND handlers only — neither has an HTTP
    /// handler type — so neither can post to the socket the way Claude Code's
    /// `curl` line does. Their wiring invokes this binary instead, and that
    /// command string need never name the socket at all.
    ///
    /// With `commandMarker` as the only marker, the panel reports a correctly
    /// wired Codex or Cursor user as broken, permanently, with nothing they can
    /// do to clear it.
    public static let shimCommandName = "coffeebar-hook"

    /// Every string that identifies an installed command as coffee-bar's.
    ///
    /// Two routes to one socket, so two markers. Both are SPECIFIC: one carries
    /// a directory as well as a file name, the other is a binary name this
    /// project owns. A marker widened to `curl`, to `--unix-socket`, to `hook`
    /// or to `coffee` would match another tool's command, and three checks
    /// refuse exactly that — `anEntryPointingSomewhereElseDoesNotCount`,
    /// `anotherToolsFlatCursorEntryDoesNotCount` and
    /// `noMarkerIsLooseEnoughToMatchAnotherToolsCommand`.
    public static let commandMarkers = [commandMarker, shimCommandName]

    /// Reads a Claude Code settings file's bytes, or `nil` when there were none.
    ///
    /// Kept as the Claude Code entry point because design §6, `HookHealthReader`
    /// and a dozen existing checks are written in terms of it. It DELEGATES, so
    /// there is one parser and never two: two readers agree until they do not,
    /// and the disagreement is invisible.
    /// `theClaudeCodeVerdictIsTheSameThroughBothEntryPoints` pins the pair over
    /// every committed fixture.
    ///
    /// `.claudeCode` always has an advisory, so the optional below is never
    /// `nil` — `aToolWithAnAdvisoryAlwaysReachesAVerdict` holds that. `??` is
    /// the safe direction anyway: a tool with nothing to check must never report
    /// `.wired`.
    public static func status(ofSettings data: Data?) -> HookHealthStatus {
        status(of: data, for: .claudeCode) ?? .unreadable
    }

    /// What `tool`'s hook file says, or `nil` when that tool has no advisory.
    ///
    /// **`nil` is not `.wired`.** It means there is no advice to give, which is
    /// the distinction `requiredEvents(for:)` draws: an empty required list
    /// would satisfy every filter and report `.wired` for a check that never
    /// ran. Reporting healthy over a file nothing examined is the strongest form
    /// of the silent failure design §6 exists to remove.
    ///
    /// Pure, and it never throws. All three files are user-editable, so every
    /// malformed shape has to reach a verdict rather than an error the panel
    /// would have to handle.
    public static func status(of data: Data?, for tool: AgentTool) -> HookHealthStatus? {
        guard let required = requiredEvents(for: tool) else { return nil }
        guard let data, let root = decodeObject(data) else { return .unreadable }

        // A readable hook file with no `hooks` key simply has no entries. That
        // is MISSING, not unreadable: the user can fix it by pasting, and
        // telling them the file is broken would send them somewhere else.
        guard let hooks = root["hooks"] as? [String: Any] else {
            return .missing(required)
        }

        let nesting = nesting(of: tool)
        let missing = required.filter { !isWired(hooks[$0], nesting: nesting) }.sorted()
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

    /// How one tool's hook file nests the command inside an event's entry.
    ///
    /// Two shapes, both measured from the running tools rather than researched.
    private enum HookNesting {
        /// `hooks.<Event>[].hooks[].command` — Claude Code AND Codex.
        ///
        /// Codex shares this exactly, `matcher` key and all. `~/.codex/hooks.json`
        /// on codex-cli 0.146.0 is one `PreToolUse` entry carrying
        /// `"matcher": "Bash|apply_patch|Edit|Write"` beside an inner `hooks`
        /// array. Its event names are PascalCase, like Claude Code's.
        case nested

        /// `hooks.<event>[].command` — Cursor, and Cursor alone.
        ///
        /// One level LESS. No `matcher`, no inner array, and camelCase event
        /// names. The nested reader casts a Cursor entry to `[[String: Any]]`
        /// successfully and then finds no `hooks` key inside it, so it reports
        /// EVERY Cursor entry as unwired — which is the defect issue #10c fixes.
        case flat
    }

    /// Which nesting `tool`'s hook file uses.
    ///
    /// Exhaustive on purpose: a fourth `AgentTool` fails to compile here, which
    /// is the moment somebody measures that tool's file instead of guessing. A
    /// reader that guessed would report a fault the user could not clear, or
    /// worse, report healthy over a file it misread.
    private static func nesting(of tool: AgentTool) -> HookNesting {
        switch tool {
        case .claudeCode, .codex: return .nested
        case .cursor: return .flat
        }
    }

    /// Whether one event's entry runs a coffee-bar command.
    ///
    /// Every level is an optional cast rather than a forced one. All three files
    /// are hand-edited, so any key can hold any JSON, and a wrong shape has to
    /// mean "not wired" instead of a trap.
    ///
    /// The two nestings are kept apart rather than tried in turn. Accepting
    /// either shape for either tool would report a file healthy that the tool
    /// itself runs nothing from — `theNestedShapeIsNotAcceptedForCursor` and
    /// `theFlatShapeIsNotAcceptedForCodex` refuse both directions.
    private static func isWired(_ entry: Any?, nesting: HookNesting) -> Bool {
        guard let entries = entry as? [[String: Any]] else { return false }

        switch nesting {
        case .nested:
            for matcher in entries {
                guard let commands = matcher["hooks"] as? [[String: Any]] else { continue }
                if commands.contains(where: { isOurCommand($0["command"]) }) { return true }
            }
            return false
        case .flat:
            return entries.contains { isOurCommand($0["command"]) }
        }
    }

    /// Whether an installed command string is one of ours.
    ///
    /// Matched on the COMMAND and never on the event key, for the reason
    /// `commandMarker` records: another tool's `SessionStart` hook must not make
    /// us report healthy while no event ever arrives.
    private static func isOurCommand(_ value: Any?) -> Bool {
        guard let text = value as? String else { return false }
        return commandMarkers.contains { text.contains($0) }
    }
}
