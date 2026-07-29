// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The Claude Code hook events M2 acts on. Design §3.
///
/// Raw values are the wire names, pinned to literals rather than derived from
/// the case names, so renaming a case cannot silently stop matching what
/// Claude Code sends.
///
/// `sessionStart` and `sessionEnd` are declared but not yet observed: the
/// 2026-07-28 capture never crossed a session boundary. Design §3.2 records
/// that gap. Write no transition against either until a real payload lands in
/// `Tests/Fixtures/claude-hooks/`.
public enum HookEventKind: String, Sendable, CaseIterable {
    case sessionStart = "SessionStart"
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
    /// Never yet observed — see `HookEventKind`. Declared so that adding the
    /// event later adds a producer rather than reshaping this type.
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
