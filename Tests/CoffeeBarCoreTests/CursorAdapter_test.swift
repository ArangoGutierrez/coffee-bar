// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

// Cursor does NOT share Claude Code's envelope. It carries `hook_event_name`,
// but the names are camelCase and the session identifier is under a different
// key — `conversation_id`, which four of the six recorded payloads carry INSTEAD
// of `session_id` rather than beside it.
//
// `cursorPayloadsTheSharedDecoderCannotRead` is the measurement that forced a
// second decoder rather than a widened first one.
//
// Every transition below is driven by a payload in `Tests/Fixtures/cursor-hooks/`.

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private var cursorFixtures: URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarCoreTests/CursorAdapter_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarCoreTests
        .deletingLastPathComponent()    // …/Tests
        .appending(path: "Fixtures/cursor-hooks")
}

private func cursorNames() throws -> [String] {
    try FileManager.default
        .contentsOfDirectory(atPath: cursorFixtures.path)
        .filter { $0.hasSuffix(".json") }
        .sorted()
}

private func cursorData(_ name: String) throws -> Data {
    try Data(contentsOf: cursorFixtures.appending(path: name))
}

private func cursorText(_ name: String) throws -> String {
    try String(contentsOf: cursorFixtures.appending(path: name), encoding: .utf8)
}

private func cursor(_ name: String) throws -> CursorHookEvent {
    try JSONDecoder().decode(CursorHookEvent.self, from: try cursorData(name))
}

private func cursorRaw(_ name: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: try cursorData(name))
    return try #require(object as? [String: Any])
}

private func session(_ state: SessionState, id: String,
                     tool: AgentTool = .cursor) -> AgentSession {
    AgentSession(tool: tool, sessionID: id, cwd: nil, repoName: nil, pid: nil,
                 state: state, stateEnteredAt: t0, lastEventAt: t0,
                 lastMessage: nil, attentionSince: nil, turnCount: 0)
}

/// Applies a recorded Cursor payload through the same path the listener uses.
private func applyCursor(_ name: String, to sessions: [AgentSession] = [],
                         now: Date = t0) throws -> [AgentSession] {
    SessionHub.apply(from: .cursor, try cursor(name).normalised, to: sessions, now: now)
}

private func cursorSessionID() throws -> String {
    try cursor("session-start.json").sessionID
}

// MARK: - Why Cursor needs its own decoder

/// The falsifying measurement. Four of six Cursor payloads have no `session_id`.
///
/// Named bug this catches: somebody deletes `CursorHookEvent` and routes Cursor
/// through `HookEvent`, whose `sessionID` is non-optional. Those four payloads
/// then throw at the decode boundary, the listener answers 400, and a Cursor
/// session never leaves `.starting` — so it holds the machine awake until the
/// stale timeout, silently.
@Test func cursorPayloadsTheSharedDecoderCannotRead() throws {
    let withoutSessionID = ["before-shell-execution.json", "after-shell-execution.json",
                            "before-read-file.json", "after-file-edit.json"]

    for name in withoutSessionID {
        let raw = try cursorRaw(name)
        #expect(raw["session_id"] == nil,
                "\(name) now carries session_id; this measurement has moved")
        #expect(raw["conversation_id"] is String,
                "\(name) carries no conversation_id; the Cursor decoder has nothing to key on")

        #expect(throws: (any Error).self, "the shared decoder read \(name); it should not be able to") {
            try JSONDecoder().decode(HookEvent.self, from: try cursorData(name))
        }
    }
}

/// `conversation_id`, `generation_id` and `session_id` are the same value.
///
/// Measured across three captures in issue #10a, 33 of 33 lines, including a
/// two-generation experiment inside one conversation. `generation_id` tracks the
/// CONVERSATION, not the response — the name misleads. This pins the corpus half
/// of that finding so a re-capture that breaks the equality is caught here rather
/// than by sessions silently splitting in the panel.
@Test func allThreeCursorIdentifiersAreTheSameValue() throws {
    let names = try cursorNames()
    #expect(names.count == 6, "read \(names.count) Cursor fixtures; this loop would pass vacuously")

    for name in names {
        let raw = try cursorRaw(name)
        let conversation = try #require(raw["conversation_id"] as? String, "\(name) has no conversation_id")
        let generation = try #require(raw["generation_id"] as? String, "\(name) has no generation_id")
        #expect(conversation == generation, "\(name): conversation_id and generation_id differ")

        if let sessionID = raw["session_id"] as? String {
            #expect(sessionID == conversation, "\(name): session_id and conversation_id differ")
        }
    }
}

@Test func theSessionIDIsTakenFromTheConversation() throws {
    // `conversation_id` and not `session_id`: only two of the six payloads carry
    // `session_id` at all, so keying on it would drop four events per turn.
    for name in try cursorNames() {
        let raw = try cursorRaw(name)
        let conversation = try #require(raw["conversation_id"] as? String)
        #expect(try cursor(name).sessionID == conversation,
                "\(name) keyed on something other than conversation_id")
    }
}

// MARK: - The corpus these transitions rest on

@Test func everyCursorTransitionRestsOnARecordedPayload() throws {
    let names = try cursorNames()
    #expect(names.count == 6, "read \(names.count) Cursor fixtures at \(cursorFixtures.path); the capture recorded six")

    var recorded: [CursorEventKind: String] = [:]
    for name in names {
        let kind = try #require(try cursor(name).kind,
                                "\(name) decodes to no CursorEventKind; SessionHub would ignore it")
        recorded[kind] = name
    }

    let driven: [(CursorEventKind, String)] = [
        (.sessionStart, "session-start.json"),
        (.beforeShellExecution, "before-shell-execution.json"),
        (.afterShellExecution, "after-shell-execution.json"),
        (.beforeReadFile, "before-read-file.json"),
        (.afterFileEdit, "after-file-edit.json"),
        (.sessionEnd, "session-end.json"),
    ]
    for (kind, file) in driven {
        #expect(recorded[kind] == file,
                "no recorded Cursor \(kind.rawValue) payload at \(file); its transition has no evidence")
    }
    #expect(CursorEventKind.allCases.count == driven.count,
            "CursorEventKind has \(CursorEventKind.allCases.count) cases and \(driven.count) are driven by a payload")
}

/// The four Cursor events with NO recorded payload map to nothing.
///
/// `beforeSubmitPrompt`, `stop`, `beforeMCPExecution` and `preCompact` are real
/// Cursor events. Issue #10a could not reach any of them headlessly, so no
/// payload exists. They get no case at all, which is stronger than a case
/// mapping to nil: a transition cannot be written for a name the type cannot
/// express.
///
/// Named bug this catches: mapping Cursor's `stop` to `.awaitingInput` from the
/// documentation rather than from a capture. The event name is a guess until a
/// payload proves the shape, and this project has already paid for that mistake.
@Test func cursorEventsWithNoRecordedPayloadDriveNothing() throws {
    let before = [session(.working, id: "c1")]

    for name in ["beforeSubmitPrompt", "stop", "beforeMCPExecution", "preCompact"] {
        #expect(CursorEventKind(rawValue: name) == nil,
                "\(name) has a CursorEventKind case but no recorded payload")

        let invented = HookEvent(hookEventName: name, sessionID: "c1")
        #expect(SessionHub.apply(from: .cursor, invented, to: before, now: t0.addingTimeInterval(60))
                == before,
                "\(name) changed the session list with no payload behind it")
    }
}

// MARK: - The mapping, driven by recorded payloads

@Test func cursorSessionStartStartsASession() throws {
    let out = try applyCursor("session-start.json")
    #expect(out.count == 1)
    #expect(out.first?.state == .starting)
    #expect(out.first?.tool == .cursor)
    #expect(out.first?.sessionID == (try cursorSessionID()))
}

@Test func everyCursorWorkEventIsWorking() throws {
    // Cursor reports what the agent is DOING — running a command, reading a
    // file, editing one. All four mean the agent has the turn.
    let sid = try cursorSessionID()
    for name in ["before-shell-execution.json", "after-shell-execution.json",
                 "before-read-file.json", "after-file-edit.json"] {
        let out = try applyCursor(name, to: [session(.starting, id: sid)])
        #expect(out.first?.state == .working, "\(name) did not reach .working")
        #expect(out.count == 1, "\(name) minted a second session instead of matching the first")
    }
}

@Test func cursorSessionEndRetiresTheSession() throws {
    let out = try applyCursor("session-end.json", to: [session(.working, id: try cursorSessionID())])
    #expect(out.first?.state == .done)
    #expect(out.first?.attentionSince == nil)
}

/// No recorded Cursor payload puts a session in an attention state.
///
/// This is a GAP, recorded rather than papered over. Cursor's `stop` would be
/// the event that says "the human is now the bottleneck", and issue #10a could
/// not capture it. So a Cursor session that finishes its turn stays `.working`
/// until `sessionEnd` arrives or the stale timeout retires it, and it holds the
/// machine awake for that whole time.
///
/// Named bug this catches: somebody adding a Cursor attention transition from
/// the documentation. If a real payload lands and a transition is written, this
/// turns red and forces the gap note above to be corrected with it.
@Test func noRecordedCursorEventReachesAnAttentionState() throws {
    let sid = try cursorSessionID()
    for name in try cursorNames() {
        let out = try applyCursor(name, to: [session(.working, id: sid)])
        let state = try #require(out.first?.state)
        #expect(!SessionState.attentionStates.contains(state),
                "\(name) reached \(state), an attention state, with no recorded evidence for it")
    }
}

@Test func everyCursorEventRefreshesLastEventAt() throws {
    let later = t0.addingTimeInterval(120)
    let names = try cursorNames()
    #expect(names.count == 6, "read \(names.count) fixtures; this loop would pass vacuously")

    for name in names {
        let out = try applyCursor(name, to: [session(.working, id: try cursorSessionID())], now: later)
        #expect(out.first?.lastEventAt == later, "\(name) did not refresh lastEventAt")
    }
}

// MARK: - The working directory, which Cursor mostly does not send

/// `cwd` is CONDITIONAL on `beforeShellExecution` and absent everywhere else.
///
/// Issue #10a measured it on 1 of 3 occurrences of that event in a fresh
/// capture, and on none of the other events. The committed fixture happens to
/// keep the occurrence that HAS it, so the JSON alone would mislead a reader
/// into making it required.
///
/// Named bug this catches: decoding `cwd` as non-optional. Five of the six
/// recorded payloads would then fail to decode.
@Test func cursorCwdIsOptionalAndOnlyOneRecordedEventCarriesIt() throws {
    var carrying: [String] = []
    for name in try cursorNames() where try cursorRaw(name)["cwd"] != nil {
        carrying.append(name)
    }
    #expect(carrying == ["before-shell-execution.json"],
            "cwd now appears on \(carrying); the optional decode rests on it being rare")

    // Every payload still decodes, whether it carries one or not.
    for name in try cursorNames() {
        _ = try cursor(name)
    }
}

/// The workspace root names the repository when `cwd` is absent.
///
/// `workspace_roots` is on all six payloads. It is the only thing that can name
/// the repository in the attention list for the five events with no `cwd`.
@Test func theWorkspaceRootNamesTheRepositoryWhenThereIsNoCwd() throws {
    let raw = try cursorRaw("after-file-edit.json")
    #expect(raw["cwd"] == nil, "after-file-edit now carries a cwd; this no longer tests the fallback")
    let roots = try #require(raw["workspace_roots"] as? [String])
    #expect(roots.count == 1, "the fixture has \(roots.count) workspace roots; the fallback needs exactly one")

    let out = try applyCursor("after-file-edit.json")
    #expect(out.first?.cwd?.path == roots.first)
    #expect(out.first?.repoName == "cursor-ws")
}

/// More than one workspace root names nothing at all.
///
/// Named bug this catches: taking `workspace_roots[0]`. The order of that list
/// is not specified anywhere, so with two roots the panel would name whichever
/// one happened to be first and would change its mind between captures. Naming
/// no repository is honest; naming an arbitrary one is not.
@Test func twoWorkspaceRootsNameNoRepositoryRatherThanAnArbitraryOne() throws {
    let two = Data("""
        {"hook_event_name": "sessionStart", "conversation_id": "c1",
         "workspace_roots": ["/tmp/alpha", "/tmp/beta"]}
        """.utf8)
    let event = try JSONDecoder().decode(CursorHookEvent.self, from: two)
    let out = SessionHub.apply(from: .cursor, event.normalised, to: [], now: t0)

    #expect(out.first?.cwd == nil)
    #expect(out.first?.repoName == nil)

    // The one-root case still works, so the check above is not passing because
    // the fallback is broken outright.
    let one = Data("""
        {"hook_event_name": "sessionStart", "conversation_id": "c2",
         "workspace_roots": ["/tmp/alpha"]}
        """.utf8)
    let single = try JSONDecoder().decode(CursorHookEvent.self, from: one)
    let named = SessionHub.apply(from: .cursor, single.normalised, to: [], now: t0)
    #expect(named.first?.repoName == "alpha")
}

@Test func anExplicitCwdWinsOverTheWorkspaceRoot() throws {
    let raw = try cursorRaw("before-shell-execution.json")
    let cwd = try #require(raw["cwd"] as? String)
    let out = try applyCursor("before-shell-execution.json")
    #expect(out.first?.cwd?.path == cwd)
}

// MARK: - The privacy boundary, design §7

// Cursor delivers conversation content DIRECTLY in the payload, under four keys
// that Claude Code does not use at all:
//
//   content      — the whole text of a file the agent read
//   output       — the whole stdout of a command it ran
//   edits        — the before and after text of every edit it made
//   command      — the command line itself
//
// It also stamps the signed-in account address on EVERY event as `user_email`.
// Issue #10a found twelve occurrences of a real address in one capture destined
// for a public repository.
//
// `CursorHookEvent` declares NO property for any of them, on the same reasoning
// `HookEvent` drops the transcript path: a field that does not exist cannot be
// read, logged or rendered, and `Decodable` discards unknown keys.

private let forbiddenCursorKeys = ["content", "output", "edits", "user_email",
                                   "command", "attachments", "old_string", "new_string"]

/// The positive control. Without it every guard below is vacuous.
@Test func theCursorFixturesDoCarryTheFieldsTheseGuardsForbid() throws {
    var found: Set<String> = []
    for name in try cursorNames() {
        let raw = try cursorRaw(name)
        for key in forbiddenCursorKeys where raw[key] != nil { found.insert(key) }
    }

    // `old_string` and `new_string` are nested inside `edits`, so they are found
    // by text rather than at the top level.
    let edited = try cursorText("after-file-edit.json")
    #expect(edited.contains("old_string") && edited.contains("new_string"),
            "after-file-edit no longer carries the edit strings; that guard is vacuous")

    for key in ["content", "output", "edits", "user_email", "command", "attachments"] {
        #expect(found.contains(key),
                "no Cursor fixture carries `\(key)`; the guard for it tests nothing")
    }
}

@Test func theCursorEventDropsEveryContentField() throws {
    for name in try cursorNames() {
        let event = try cursor(name)

        // Guard 1 — the wire key survives no round trip.
        let reencoded = try #require(String(data: try JSONEncoder().encode(event), encoding: .utf8))
        for key in forbiddenCursorKeys {
            #expect(!reencoded.contains(key),
                    "CursorHookEvent round-tripped `\(key)` from \(name); design §7 forbids carrying it")
        }

        // Guard 2 — no stored property holds the value, whatever it is named.
        let properties = Mirror(reflecting: event).children.map {
            ($0.label ?? "<unlabelled>", String(describing: $0.value))
        }
        #expect(properties.count >= 3,
                "reflected \(properties.count) properties of CursorHookEvent; the scan would be vacuous")

        let raw = try cursorRaw(name)
        for key in forbiddenCursorKeys {
            guard let recorded = raw[key] as? String, !recorded.isEmpty else { continue }
            for property in properties {
                #expect(!property.1.contains(recorded),
                        "CursorHookEvent.\(property.0) holds the `\(key)` of \(name)")
            }
            for rendered in [String(describing: event), String(reflecting: event)] {
                #expect(!rendered.contains(recorded),
                        "a rendered CursorHookEvent shows the `\(key)` of \(name)")
            }
        }
    }
}

@Test func theSessionACursorEventProducesCarriesNoContent() throws {
    // The boundary that matters to the user: what reaches the panel. A field
    // dropped at decode but rebuilt into `lastMessage` would leak just the same.
    for name in try cursorNames() {
        let out = try applyCursor(name, to: [], now: t0)
        let rendered = String(describing: out)
        let raw = try cursorRaw(name)
        for key in forbiddenCursorKeys {
            guard let recorded = raw[key] as? String, !recorded.isEmpty else { continue }
            #expect(!rendered.contains(recorded),
                    "the AgentSession from \(name) renders the `\(key)`")
        }
        #expect(out.first?.lastMessage == nil,
                "\(name) produced a lastMessage; no recorded Cursor event carries text fit to render")
    }
}

/// No source file names the account address key.
///
/// The second line of defence, mirroring `noSourceFileNamesAForbiddenField`.
/// Narrow on purpose: `content` and `command` are ordinary English words that
/// appear all over a codebase, so scanning for them would produce noise that
/// trains the reader to ignore this. `user_email` and the edit-string keys are
/// specific enough to mean only one thing.
@Test func noSourceFileNamesTheCursorAccountOrEditKeys() throws {
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources")

    var files: [URL] = []
    if let walk = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles]) {
        for case let entry as URL in walk where entry.pathExtension == "swift" {
            files.append(entry)
        }
    }
    #expect(files.count >= 20, "the scan reached \(files.count) files at \(sources.path)")

    for file in files {
        let source = try String(contentsOf: file, encoding: .utf8)
        for needle in ["user_email", "userEmail", "old_string", "new_string"] {
            #expect(!source.contains(needle),
                    "\(file.lastPathComponent) names \(needle); design §7 forbids reading it")
        }
    }
}
