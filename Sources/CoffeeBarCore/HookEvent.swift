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

// MARK: - Cursor, the second envelope

/// The Cursor hook events with a recorded payload.
///
/// Raw values are pinned to literals for the same reason `HookEventKind` pins
/// its own: renaming a case must not silently stop matching what Cursor sends.
///
/// **Four real Cursor events are deliberately absent** — `beforeSubmitPrompt`,
/// `stop`, `beforeMCPExecution` and `preCompact`. Issue #10a could not reach any
/// of them headlessly, so no payload exists for them. Leaving out the case is
/// stronger than adding one that maps to nil: a transition cannot be written for
/// a name this type cannot express.
///
/// `stop` is the costly absence. It is the event that would say the human is now
/// the bottleneck, so without it a Cursor session that finishes its turn stays
/// `.working` until `sessionEnd` or the stale timeout.
/// `noRecordedCursorEventReachesAnAttentionState` pins that gap.
public enum CursorEventKind: String, Sendable, CaseIterable {
    case sessionStart = "sessionStart"
    case beforeShellExecution = "beforeShellExecution"
    case afterShellExecution = "afterShellExecution"
    case beforeReadFile = "beforeReadFile"
    case afterFileEdit = "afterFileEdit"
    case sessionEnd = "sessionEnd"
}

/// One Cursor hook payload, reduced to the fields M3 acts on.
///
/// Cursor needs its own decoder, and that is measured rather than assumed: four
/// of the six recorded payloads carry NO `session_id` at all. `HookEvent` makes
/// that field non-optional, so it throws on every one of them.
/// `cursorPayloadsTheSharedDecoderCannotRead` re-runs the measurement.
///
/// **The identifier is `conversation_id`.** Issue #10a measured
/// `conversation_id == generation_id == session_id` on 33 of 33 captured lines,
/// across three captures including a two-generation experiment inside one
/// conversation. `generation_id` tracks the CONVERSATION, not the response — the
/// name misleads, and round 1 of that issue was misled by it. `conversation_id`
/// is chosen because it is the one of the three present on ALL six payloads.
///
/// **Four fields of the real payload are absent on purpose**, because design §7
/// forbids reading conversation content, and Cursor delivers that content
/// directly rather than behind a path:
///
/// - the text of a file the agent read;
/// - the whole standard output of a command it ran;
/// - the before and after text of every edit it made;
/// - the command line itself.
///
/// A fifth is absent for a different reason. Cursor stamps the signed-in
/// account's address on EVERY event. Issue #10a found twelve occurrences of a
/// real address in a single capture bound for a public repository. It is not
/// conversation content; it is personal data this product has no use for.
///
/// None of those keys is named anywhere in this file, and
/// `noSourceFileNamesTheCursorAccountOrEditKeys` scans every source file for the
/// ones specific enough to scan for.
public struct CursorHookEvent: Codable, Equatable, Sendable {
    public let hookEventName: String
    public let sessionID: String

    /// Present on `beforeShellExecution` and nowhere else, and CONDITIONAL even
    /// there — issue #10a measured it on 1 of 3 occurrences in a fresh capture.
    /// The committed fixture keeps the occurrence that has it, so the JSON alone
    /// would mislead a reader into making this required.
    public let cwd: String?

    /// The open workspace directories. On all six recorded payloads.
    ///
    /// The only thing that can name the repository for the five events with no
    /// `cwd`. Read only when there is exactly ONE — see `workingDirectory`.
    public let workspaceRoots: [String]?

    private enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionID = "conversation_id"
        case cwd
        case workspaceRoots = "workspace_roots"
    }

    /// `nil` for an event with no recorded payload behind it.
    public var kind: CursorEventKind? { CursorEventKind(rawValue: hookEventName) }

    /// The directory the panel names this session's repository after.
    ///
    /// `cwd` when the payload carries one, otherwise the workspace root — but
    /// ONLY when there is exactly one. The order of `workspace_roots` is
    /// specified nowhere, so with two roots the panel would name whichever
    /// happened to be first and could change its mind between captures. Naming
    /// no repository is honest; naming an arbitrary one is not.
    public var workingDirectory: String? {
        if let cwd { return cwd }
        guard let roots = workspaceRoots, roots.count == 1 else { return nil }
        return roots.first
    }

    /// This payload in the shape `SessionHub` applies.
    ///
    /// Cursor's own vocabulary is preserved in `hookEventName` rather than
    /// translated into Claude Code's. The hub resolves the name against
    /// `CursorEventKind` because it knows the origin, so two tools that both
    /// have a "start" event keep their own spellings and neither has to be
    /// bent into the other's.
    public var normalised: HookEvent {
        HookEvent(hookEventName: hookEventName,
                  sessionID: sessionID,
                  cwd: workingDirectory)
    }

    public init(hookEventName: String, sessionID: String, cwd: String? = nil,
                workspaceRoots: [String]? = nil) {
        self.hookEventName = hookEventName
        self.sessionID = sessionID
        self.cwd = cwd
        self.workspaceRoots = workspaceRoots
    }
}
