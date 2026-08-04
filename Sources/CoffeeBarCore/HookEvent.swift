// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The hook events M2 and M3 act on, in the PascalCase envelope. Design §3.
///
/// Raw values are the wire names, pinned to literals rather than derived from
/// the case names, so renaming a case cannot silently stop matching what the
/// agent sends.
///
/// **This vocabulary is shared by Claude Code AND Codex CLI.** Both send these
/// exact names under the `hook_event_name` key, which is why one enum and one
/// decoder serve both. It is also why neither the names nor the payload can say
/// which of the two sent it — see `AgentTool.declared(byEndpoint:)`. Cursor uses
/// a different vocabulary and has its own enum, `CursorEventKind`.
///
/// Seven of the eight have a recorded payload. Six are in
/// `Tests/Fixtures/claude-hooks/`, including `sessionStart` and `sessionEnd`: a
/// later capture crossed a real session boundary and closed the gap design §3.2
/// recorded. `userPromptSubmit` is recorded in `Tests/Fixtures/codex-hooks/`.
/// `preCompact` is the one with no payload behind it. Write no transition
/// against an event until a real payload lands in one of those directories.
public enum HookEventKind: String, Sendable, CaseIterable {
    case sessionStart = "SessionStart"

    /// The human has handed a prompt back to the agent.
    ///
    /// Added for Codex CLI, which sends it and whose capture recorded it. Claude
    /// Code sends this event too, but no Claude Code payload for it was ever
    /// captured, so `HookHealth` does not ask a Claude Code user to wire it. The
    /// transition is the same for both, because nothing measured distinguishes
    /// the two tools on this event.
    case userPromptSubmit = "UserPromptSubmit"

    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case permissionDenied = "PermissionDenied"
    case stop = "Stop"
    case preCompact = "PreCompact"
    case sessionEnd = "SessionEnd"
}

/// One Claude Code hook payload, reduced to the fields M2 acts on.
///
/// **Two fields of the real payload are absent on purpose**, because design §7
/// forbids reading conversation content:
///
/// - the path to the transcript, which every payload carries;
/// - the last assistant message, which the `Stop` payload carries directly.
///   Design §7.1 measured 2747 characters of reply text in the first sample.
///
/// A property that does not exist cannot be read, logged or rendered, and
/// `Decodable` drops unknown keys, so both are discarded here and neither
/// reaches a variable. `Tests/CoffeeBarCoreTests/PrivacyBoundary_test.swift`
/// holds that line, with the recorded payloads as its positive control.
///
/// Neither field is named anywhere in this file, by design: that same test
/// scans every source file for the two keys, so naming one here — even in a
/// comment — turns the scan red.
///
/// `hookEventName` is a `String`, not a `HookEventKind`. Decoding straight into
/// the enum would make an unrecognised event fail the whole payload, and Claude
/// Code adds events over time. An unknown name decodes and classifies as `nil`.
public struct HookEvent: Codable, Equatable, Sendable {
    public let hookEventName: String
    public let sessionID: String
    public let cwd: String?

    /// `startup`, `resume`, `clear` or `compact`, on `SessionStart` only.
    ///
    /// The recorded payload carries `startup`; the other three values come from
    /// design §3 and none has been observed. `SessionHub` therefore reads the
    /// event, not this field: no transition branches on a value with no
    /// evidence behind it.
    public let source: String?

    public let toolName: String?

    /// Why the permission was denied, on `PermissionDenied`.
    ///
    /// Design §3 says that event carries `message`. The recorded payload
    /// carries `reason` and no `message` at all, so this follows the payload.
    public let reason: String?

    private enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionID = "session_id"
        case cwd
        case source
        case toolName = "tool_name"
        case reason
    }

    /// `nil` for an event this version does not act on.
    public var kind: HookEventKind? { HookEventKind(rawValue: hookEventName) }

    public init(hookEventName: String, sessionID: String, cwd: String? = nil,
                source: String? = nil, toolName: String? = nil,
                reason: String? = nil) {
        self.hookEventName = hookEventName
        self.sessionID = sessionID
        self.cwd = cwd
        self.source = source
        self.toolName = toolName
        self.reason = reason
    }
}
