// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The hook entry a user pastes into their agent tool's settings file.
///
/// **Derived, never a literal.** Every event comes from
/// `HookHealth.requiredEvents(for:)`, the same source the health check reads, so
/// a snippet cannot tell the user to wire a set the checker does not look for.
/// The endpoint comes from `AgentTool.ingestEndpoint`, the same source the
/// listener attributes an arriving payload by.
///
/// **coffee-bar PRINTS this and never writes the file** — design §6. That file
/// is shared territory, and this workspace records a last-writer-wins clobber in
/// exactly it. The pasteboard is the user's; their settings file is not.
///
/// Pure, like everything else in `CoffeeBarCore`: no I/O, and no home directory
/// resolved (design §8).
public enum HookSnippet {

    /// The command every tool runs, ending at that tool's own ingest endpoint.
    ///
    /// **`curl` for all three tools, and never `coffeebar-hook`.** Measured
    /// 2026-08-06: nothing installs the shim on a `PATH`, and
    /// `docs/QUICKSTART.md` says so itself. A snippet naming it hands the user a
    /// command that cannot run — and `HookHealth` would still report `.wired`,
    /// because the binary name is one of its two markers. The shim stays
    /// documented as an alternative for a reader who has built it; it is not
    /// what a button pastes.
    ///
    /// **`$HOME` stays UNEXPANDED.** This type resolves no home directory
    /// (design §8), and an expanded path is correct on exactly one machine.
    ///
    /// **The endpoint is per tool, and that is not cosmetic.** A payload cannot
    /// say which agent produced it — `AgentTool`'s own comment records the two
    /// measurements that closed off sniffing — so the SENDER declares it by
    /// choosing the path, and `AgentTool.declared(byEndpoint:)` reads it back.
    /// One shared `/event` would file every Codex and Cursor session as a Claude
    /// Code session, silently: `HookHealth` matches the socket path inside the
    /// command and never the URL, so it reports `.wired` over exactly that
    /// mistake. `eachToolsCommandDeclaresThatToolsOwnOrigin` is what catches it.
    static func command(for tool: AgentTool) -> String {
        """
        curl -sS -o /dev/null --fail-with-body --max-time 5 \
        --unix-socket "$HOME/Library/Application Support/coffee-bar/ingest.sock" \
        -X POST --data-binary @- http://localhost\(tool.ingestEndpoint)
        """
    }

    /// The events Claude Code and Codex run only when the entry carries a
    /// `matcher`. Everything else takes NO `matcher` key.
    ///
    /// Measured 2026-08-06 from a working `~/.claude/settings.json`, and stated
    /// on the page the user follows: "The two tool events take `"matcher": "*"`;
    /// the other three take no matcher."
    ///
    /// **Omitting it is not harmless, and no health check will catch it.** A
    /// Codex config merged without it was measured dead for a full day while the
    /// panel reported the install wired — issue #55. `HookHealth` reads the
    /// command and ignores the matcher, so the writing side is the only place
    /// this can be enforced, and
    /// `theTwoToolEventsCarryAMatcherAndTheOthersCarryNoMatcherKey` enforces it.
    ///
    /// The key is ABSENT on the other events rather than empty: `""` is a
    /// pattern, and it is the pattern that matches nothing.
    static let matchedEvents: Set<String> = ["PostToolUse", "PreToolUse"]

    /// The `matcher` value the two tool events take: every tool call, unfiltered.
    static let toolEventMatcher = "*"

    /// The pasteable fragment for `tool`, or `nil` when there is no advice to
    /// give — mirroring `requiredEvents(for:)`, where `nil` is not `[]`.
    ///
    /// A FRAGMENT: a `hooks` object and nothing beside it, because the user
    /// merges it into a file that already holds their own settings. The quick
    /// start tells them so, and design §6 is why this cannot merge it for them.
    ///
    /// `.sortedKeys` keeps the output stable between runs, so a user comparing
    /// what they pasted last time against what the button gives them now sees a
    /// difference only when there is one.
    public static func json(for tool: AgentTool) -> String? {
        guard let events = HookHealth.requiredEvents(for: tool) else { return nil }

        let command = command(for: tool)
        let entries = isFlat(tool)
            ? flat(events: events, command: command)
            : nested(events: events, command: command)

        guard let data = try? JSONSerialization.data(
            withJSONObject: ["hooks": entries],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether `tool`'s hook file nests the command one level LESS.
    ///
    /// A `switch` with no `default`, so a fourth `AgentTool` fails to compile
    /// here rather than silently inheriting another tool's shape — the same
    /// discipline `HookHealth.nesting(of:)` keeps on the reading side. The two
    /// must agree, and `theCheckerReportsOurOwnSnippetAsWired` is what proves
    /// they still do.
    private static func isFlat(_ tool: AgentTool) -> Bool {
        switch tool {
        case .claudeCode, .codex: return false
        case .cursor: return true
        }
    }

    /// Claude Code and Codex: `hooks.<Event>[].hooks[].command`, with `matcher`
    /// on the two tool events and on nothing else.
    ///
    /// Codex shares this shape exactly, `matcher` key and all — the capture from
    /// codex-cli 0.146.0 is recorded on `HookHealth`'s nested case.
    private static func nested(events: [String], command: String) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in events {
            var group: [String: Any] = [
                "hooks": [["type": "command", "command": command]]
            ]
            if matchedEvents.contains(event) { group["matcher"] = toolEventMatcher }
            hooks[event] = [group]
        }
        return hooks
    }

    /// Cursor: `hooks.<event>[].command`, and Cursor alone.
    ///
    /// One level LESS. The command sits directly on the element, with no `type`
    /// key, no inner `hooks` array and no `matcher`. `HookHealth`'s flat reader
    /// accepts nothing else, and neither does Cursor.
    private static func flat(events: [String], command: String) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in events {
            hooks[event] = [["command": command]]
        }
        return hooks
    }
}
