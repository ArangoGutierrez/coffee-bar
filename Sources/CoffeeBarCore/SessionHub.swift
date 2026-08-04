// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Turns hook events from any supported agent into `AgentSession` values.
///
/// A caseless enum of static functions, the shape `PowerBroker` uses: no I/O,
/// no clock, no stored state. `apply` is a pure function of
/// `(sessions, event, now)`, so every transition in design §3.1 tests from a
/// recorded payload with no socket and no Mac in the loop. `now` is a parameter
/// for that reason — a `Date()` read in here would make the result depend on
/// when it ran.
///
/// **Every transition below is driven by a payload under `Tests/Fixtures/`.**
/// Design §9: writing the state machine first and inventing payloads to match it
/// is the failure mode this project has already paid for.
///
/// `PreCompact` is the one `HookEventKind` with no recorded payload, and it maps
/// to no state — the corpus carries seven of the eight kinds, six from Claude
/// Code and `UserPromptSubmit` from Codex.
///
/// The tool a session belongs to arrives as a parameter, not as a guess about
/// the payload. `AgentTool.declared(byEndpoint:)` carries the reasoning and the
/// measurement that rejected the alternatives.
///
/// **There is no transition into `.failed`.** Design §3.2: no observed event
/// reports a failure, so a session that simply stops is retired by the stale
/// timeout in `StalePolicy`, not by a transition invented here.
public enum SessionHub {

    /// Design §7 caps the rendered message. It is attacker-influenced text.
    ///
    /// Counts `Character`s — Swift grapheme clusters. It bounds how LONG the
    /// message reads, not how LARGE it is. `messageByteCap` bounds the size.
    public static let messageCap = 140

    /// The other half of the cap, in UTF-8 bytes.
    ///
    /// A `Character` is a grapheme cluster, and a cluster is a base scalar plus
    /// ANY number of combining marks, so one `Character` has no upper bound in
    /// bytes. 140 clusters of `a` plus 150 U+0301 marks are 42,140 bytes, and
    /// the request carrying them is about 42 KB — small enough to clear every
    /// layer above and arrive here as a fully conforming payload.
    ///
    /// Why 1 KiB. It is the smallest round bound that no ordinary message
    /// reaches. 140 characters of Latin prose are at most 280 bytes. 140
    /// characters of the densest scripts the panel plausibly shows — CJK,
    /// Cyrillic, Greek, Devanagari — are at most about 420. 1 KiB leaves about
    /// 7 bytes per character of headroom above that, and it cuts the measured
    /// attack by a factor of 41. What does exceed 1 KiB is text built from long
    /// multi-scalar clusters, and 140 of those do not read as a sentence in a
    /// menu-bar row. Such text gets shorter here. It never gets corrupted.
    public static let messageByteCap = 1024

    /// Applies one event from `tool` and returns the new session list.
    ///
    /// Unknown events return the input unchanged, so an agent release that adds
    /// an event cannot mint a phantom session that holds the machine awake.
    ///
    /// **`tool` is a parameter and has no default.** It used to be the literal
    /// `.claudeCode`, written into `make` below, so every session was a Claude
    /// Code session whatever had sent the payload. A default would put that
    /// same defect back one level down: the origin has to be stated by whoever
    /// received the bytes, because that is the only layer that knows it. See
    /// `AgentTool.declared(byEndpoint:)` for how it is established and for the
    /// measurement that rules out reading it off the payload.
    public static func apply(from tool: AgentTool,
                             _ event: HookEvent,
                             to sessions: [AgentSession],
                             now: Date) -> [AgentSession] {
        guard let newState = state(of: event.hookEventName, from: tool) else {
            return sessions
        }
        let text = message(from: event)

        // Matched on (tool, sessionID) and never on position: two tools may use
        // the same session id and must not merge. Codex and Claude Code both use
        // plain UUIDs, so this is not hypothetical.
        guard let index = sessions.firstIndex(where: {
            $0.tool == tool && $0.sessionID == event.sessionID
        }) else {
            return sessions + [make(event, from: tool, message: text,
                                    state: newState, now: now)]
        }

        var updated = sessions
        updated[index] = advance(sessions[index], with: event, message: text,
                                 to: newState, now: now)
        return updated
    }

    /// Design §3.1. `preCompact` maps to nothing: it is housekeeping, and it
    /// deliberately does not even refresh `lastEventAt`. A compaction longer
    /// than the stale timeout therefore releases the assertion, which is the
    /// safe direction to be wrong in.
    ///
    /// `sessionEnd` maps to `.done` because the 2026-07-28 capture recorded one.
    /// Its payload carries `reason: "other"`, the only terminator value seen so
    /// far, so no branch here reads it: an end is an end until a payload shows
    /// otherwise.
    /// `userPromptSubmit` maps to `.working` because the human has just handed
    /// the turn back. The payload behind it is Codex's, recorded in
    /// `Tests/Fixtures/codex-hooks/user-prompt-submit.json`. Without it a
    /// session stays `.awaitingInput` from the moment the user presses return
    /// until the model's first tool call, and `.awaitingInput` does not hold the
    /// machine awake — so the Mac can sleep while the model is generating.
    private static func state(for kind: HookEventKind) -> SessionState? {
        switch kind {
        case .sessionStart: return .starting
        case .userPromptSubmit, .preToolUse, .postToolUse: return .working
        case .permissionDenied: return .awaitingPermission
        case .stop: return .awaitingInput
        case .sessionEnd: return .done
        case .preCompact: return nil
        }
    }

    /// Resolves a wire event name against the vocabulary of the tool that sent
    /// it, then maps it to a state. `nil` means "this drives nothing".
    ///
    /// The name is resolved per TOOL rather than against one merged enum. Cursor
    /// spells its start event `sessionStart` and Claude Code spells it
    /// `SessionStart`; merging the two vocabularies would need one of them bent
    /// into the other's spelling, and a raw-value collision would then be a
    /// silent mis-route rather than a compile error.
    ///
    /// An unrecognised name returns `nil`, so an agent release that adds an
    /// event cannot mint a phantom session that holds the machine awake.
    private static func state(of name: String, from tool: AgentTool) -> SessionState? {
        switch tool {
        case .claudeCode, .codex:
            // One vocabulary, deliberately. Codex sends the same event names as
            // Claude Code, which is exactly why the origin cannot be read off
            // the payload — see `AgentTool.declared(byEndpoint:)`.
            return HookEventKind(rawValue: name).flatMap(state(for:))
        case .cursor:
            return CursorEventKind(rawValue: name).flatMap(state(for:))
        }
    }

    /// Cursor's mapping. Every case here has a recorded payload behind it.
    ///
    /// All four work events mean the same thing — the agent has the turn. Cursor
    /// reports what the agent is DOING rather than whose turn it is, so there is
    /// no finer distinction to draw and inventing one would not be measurement.
    ///
    /// **No case maps to an attention state, and that is a GAP rather than a
    /// decision.** Cursor's `stop` is the event that would say the human is now
    /// the bottleneck, and no payload for it was ever captured. A Cursor session
    /// that finishes its turn therefore stays `.working` — holding the machine
    /// awake — until `sessionEnd` arrives or `StalePolicy` retires it.
    private static func state(for kind: CursorEventKind) -> SessionState? {
        switch kind {
        case .sessionStart: return .starting
        case .beforeShellExecution, .afterShellExecution,
             .beforeReadFile, .afterFileEdit: return .working
        case .sessionEnd: return .done
        }
    }

    private static func make(_ event: HookEvent,
                             from tool: AgentTool,
                             message: String?,
                             state: SessionState,
                             now: Date) -> AgentSession {
        let cwd = event.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }
        return AgentSession(
            tool: tool,
            sessionID: event.sessionID,
            cwd: cwd,
            repoName: cwd?.lastPathComponent,
            pid: nil,
            state: state,
            stateEnteredAt: now,
            lastEventAt: now,
            lastMessage: message,
            attentionSince: SessionState.attentionStates.contains(state) ? now : nil,
            turnCount: state == .awaitingInput ? 1 : 0)
    }

    private static func advance(_ session: AgentSession,
                                with event: HookEvent,
                                message: String?,
                                to state: SessionState,
                                now: Date) -> AgentSession {
        let changed = session.state != state
        // Every recorded payload carries `cwd`, but the decoder allows it to be
        // absent, and an event without one must not blank the repository name
        // out of the attention list.
        let cwd = event.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? session.cwd

        let attentionSince: Date?
        if SessionState.attentionStates.contains(state) {
            // Preserved across a re-entry into the SAME attention state, so the
            // "waiting since" the panel orders by is when the wait began, not
            // when the newest event landed.
            attentionSince = changed ? now : session.attentionSince
        } else {
            attentionSince = nil
        }

        return AgentSession(
            tool: session.tool,
            sessionID: session.sessionID,
            cwd: cwd,
            repoName: cwd?.lastPathComponent ?? session.repoName,
            pid: session.pid,
            state: state,
            stateEnteredAt: changed ? now : session.stateEnteredAt,
            lastEventAt: now,
            lastMessage: message ?? session.lastMessage,
            attentionSince: attentionSince,
            turnCount: session.turnCount + (state == .awaitingInput && changed ? 1 : 0))
    }

    /// The text the panel renders under a blocked session, capped.
    ///
    /// Read from `PermissionDenied` alone. Two recorded events carry `reason`
    /// and they mean unrelated things: on `PermissionDenied` it explains why the
    /// human is now the bottleneck, and on `SessionEnd` it is a terminator code,
    /// recorded as the bare word "other". Rendering the second would overwrite
    /// the first exactly when the user looks to see what happened.
    /// A Cursor event can never reach this with text, and no check here is
    /// needed to make that true. Cursor's event names do not resolve to
    /// `HookEventKind` at all, and `CursorHookEvent` decodes no `reason` — its
    /// only one sits on `sessionEnd`, where it is a terminator code. So a Cursor
    /// session's `lastMessage` stays nil by construction. A `tool != .cursor`
    /// guard was written here first and removed: no test could turn it red,
    /// because no input can reach it.
    private static func message(from event: HookEvent) -> String? {
        guard HookEventKind(rawValue: event.hookEventName) == .permissionDenied,
              let reason = event.reason
        else { return nil }
        return capped(reason)
    }

    /// Truncates to whichever cap binds first, always on a `Character` boundary.
    ///
    /// Walking `Character`s is what keeps the result well formed. Cutting the
    /// UTF-8 view at `messageByteCap` would sever a multi-scalar cluster and
    /// leave the panel a half scalar or a dangling ZWJ.
    ///
    /// The walk visits at most `messageCap` clusters, so a large `reason` costs
    /// a bounded number of steps rather than one per byte.
    ///
    /// A single cluster wider than `messageByteCap` returns the empty string.
    /// The panel then shows nothing, which is the right answer: the only thing
    /// it could show instead is the payload this cap exists to keep out.
    private static func capped(_ text: String) -> String {
        var out = ""
        var bytes = 0
        for character in text.prefix(messageCap) {
            let width = character.utf8.count
            guard bytes + width <= messageByteCap else { break }
            out.append(character)
            bytes += width
        }
        return out
    }
}

extension SessionState {
    /// The two states where the agent is blocked on the human.
    ///
    /// Not a second copy of a rule `PowerBroker` already owns: a test asserts
    /// this set equals the difference between the broker's two active sets, so
    /// the two definitions cannot drift apart silently.
    public static let attentionStates: Set<SessionState> = [.awaitingPermission,
                                                            .awaitingInput]
}
