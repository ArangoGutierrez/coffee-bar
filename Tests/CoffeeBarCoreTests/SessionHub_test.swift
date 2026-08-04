// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

/// A fixed clock. `SessionHub.apply` takes `now` as a parameter and calls no
/// clock of its own, so every timestamp asserted below is a value this file
/// chose rather than one the implementation computed.
private let t0 = Date(timeIntervalSince1970: 1_000_000)

/// The fixture directory, resolved from `#filePath`.
///
/// Never from the working directory: under `swift test` the working directory
/// is not the package root, and a fixture test that silently reads nothing is
/// worse than no test at all.
private var fixturesDir: URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarCoreTests/SessionHub_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarCoreTests
        .deletingLastPathComponent()    // …/Tests
        .appending(path: "Fixtures/claude-hooks")
}

private func fixtureFileNames() throws -> [String] {
    try FileManager.default
        .contentsOfDirectory(atPath: fixturesDir.path)
        .filter { $0.hasSuffix(".json") }
        .sorted()
}

/// Loads a recorded payload. Design §9 forbids inventing one.
private func recorded(_ name: String) throws -> HookEvent {
    try JSONDecoder().decode(
        HookEvent.self, from: Data(contentsOf: fixturesDir.appending(path: name)))
}

/// The raw payload, read by a decoder that is not the one under test. Used for
/// the preconditions that prove a fixture can still discriminate.
private func rawPayload(_ name: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(
        with: try Data(contentsOf: fixturesDir.appending(path: name)))
    return try #require(object as? [String: Any])
}

/// The state a session list ends in after one recorded event.
private func stateAfter(_ fixture: String,
                        from sessions: [AgentSession] = [],
                        at now: Date = t0) throws -> SessionState? {
    SessionHub.apply(from: .claudeCode, try recorded(fixture), to: sessions, now: now).first?.state
}

private func session(_ state: SessionState,
                     id: String = "s1",
                     tool: AgentTool = .claudeCode,
                     lastMessage: String? = nil,
                     lastEventAt: Date = t0) -> AgentSession {
    AgentSession(tool: tool, sessionID: id, cwd: nil, repoName: nil,
                 pid: nil, state: state, stateEnteredAt: t0,
                 lastEventAt: lastEventAt, lastMessage: lastMessage,
                 attentionSince: nil, turnCount: 0)
}

/// The session id every recorded payload carries, read from the corpus rather
/// than transcribed, so a re-capture cannot leave a stale literal behind that
/// makes the identity tests match nothing.
private func recordedSessionID() throws -> String {
    try recorded("stop.json").sessionID
}

// MARK: - The corpus these transitions rest on

@Test func everyTransitionRestsOnARecordedPayload() throws {
    // Design §9: the fixtures come first. This is the guard that the six
    // transitions below are each driven by real recorded bytes.
    //
    // Named bug this catches: a fixture deleted or renamed while the transition
    // tests keep passing against something else. `contentsOfDirectory` on an
    // empty or wrong directory returns an empty list, and every `for` loop over
    // it then passes vacuously — so the count is asserted before anything else.
    let names = try fixtureFileNames()
    #expect(names.count >= 6,
            "read \(names.count) fixtures at \(fixturesDir.path); this suite drives six")

    var recordedKinds: [HookEventKind: String] = [:]
    for name in names {
        let event = try recorded(name)
        let kind = try #require(event.kind,
                                "\(name) decodes to no kind; SessionHub would ignore it")
        recordedKinds[kind] = name
    }

    let driven: [(HookEventKind, String)] = [
        (.sessionStart, "session-start.json"),
        (.preToolUse, "pre-tool-use.json"),
        (.postToolUse, "post-tool-use.json"),
        (.permissionDenied, "permission-denied.json"),
        (.stop, "stop.json"),
        (.sessionEnd, "session-end.json"),
    ]
    for (kind, file) in driven {
        #expect(recordedKinds[kind] == file,
                "no recorded \(kind.rawValue) payload at \(file); its transition has no evidence")
    }
}

// MARK: - The mapping in design §3.1, driven by recorded payloads

@Test func sessionStartCreatesAStartingSession() throws {
    // Written only because a real SessionStart payload landed in the corpus on
    // 2026-07-28. Design §3.2 forbids a transition no observed event produces.
    let out = SessionHub.apply(from: .claudeCode, try recorded("session-start.json"), to: [], now: t0)
    #expect(out.count == 1)
    #expect(out.first?.state == .starting)
    #expect(out.first?.tool == .claudeCode)
    #expect(out.first?.sessionID == (try recordedSessionID()))
}

@Test func preToolUseMovesToWorking() throws {
    #expect(try stateAfter("pre-tool-use.json",
                           from: [session(.starting, id: try recordedSessionID())]) == .working)
}

@Test func postToolUseMovesToWorking() throws {
    #expect(try stateAfter("post-tool-use.json",
                           from: [session(.awaitingInput, id: try recordedSessionID())]) == .working)
}

@Test func permissionDeniedMovesToAwaitingPermission() throws {
    #expect(try stateAfter("permission-denied.json",
                           from: [session(.working, id: try recordedSessionID())]) == .awaitingPermission)
}

@Test func stopMovesToAwaitingInput() throws {
    // The behaviour the product exists for. The agent has finished its turn and
    // the human is the bottleneck, so with `holdAwakeWhileBlocked` at its
    // default of false the assertion drops and the machine sleeps while it
    // waits.
    #expect(try stateAfter("stop.json",
                           from: [session(.working, id: try recordedSessionID())]) == .awaitingInput)
}

@Test func sessionEndRetiresTheSession() throws {
    // Written only because a real SessionEnd payload landed in the corpus.
    // Design §3.2 recorded `.done` as unreachable; a capture that crossed a
    // real session boundary made it reachable.
    //
    // The recorded `reason` is "other". No fixture carries `clear`, `logout` or
    // `prompt_input_exit`, so no branch below reads `reason` on this event: an
    // end is an end until a payload says otherwise.
    let out = SessionHub.apply(from: .claudeCode, try recorded("session-end.json"),
                               to: [session(.working, id: try recordedSessionID())],
                               now: t0.addingTimeInterval(60))
    #expect(out.first?.state == .done)
    #expect(out.first?.attentionSince == nil)

    // The reason this transition is worth having: `.done` releases the machine.
    // Named bug this catches: `.done` added to the wake set, which would make a
    // finished session hold the machine awake until the stale timeout.
    #expect(!PowerBroker.activeStates(holdAwakeWhileBlocked: true).contains(.done))
}

@Test func preCompactChangesNothing() {
    // §3.1 calls PreCompact housekeeping. It does not even refresh
    // `lastEventAt`: a compaction that outlives the stale timeout releases the
    // assertion, and releasing is the SAFE direction to fail in.
    //
    // NO PreCompact payload was captured — the corpus has six fixtures and
    // seven `HookEventKind` cases. The wire name below comes from design §3,
    // not from measurement, so this test pins only "no transition"; it makes no
    // claim about the payload's shape. It still discriminates: a mutant that
    // maps `.preCompact` to a state turns it red.
    let before = [session(.working)]
    let event = HookEvent(hookEventName: "PreCompact", sessionID: "s1")
    #expect(SessionHub.apply(from: .claudeCode, event, to: before, now: t0.addingTimeInterval(60)) == before)
}

@Test func anUnknownEventChangesNothing() {
    // Named bug this catches: a hub that creates a session for any payload. A
    // future Claude Code event would then mint a phantom `.starting` session
    // that holds the machine awake until the stale timeout retires it.
    let before = [session(.working)]
    let unknown = HookEvent(hookEventName: "SomeFutureEvent", sessionID: "s2")
    #expect(SessionHub.apply(from: .claudeCode, unknown, to: before, now: t0) == before)
}

// MARK: - Identity and ordering

@Test func aSecondSessionIsAppendedRatherThanReplacing() throws {
    // Named bug this catches: a hub keyed by nothing, which merges two agents
    // into one row. The user then sees one session while two machines-worth of
    // work runs.
    let first = [session(.working, id: "already-running")]
    let out = SessionHub.apply(from: .claudeCode, try recorded("session-start.json"), to: first, now: t0)
    #expect(out.count == 2)
    #expect(out.map(\.sessionID) == ["already-running", try recordedSessionID()])
}

@Test func anEventForALaterSessionLeavesTheOrderAlone() throws {
    // Order is asserted because everything downstream reads this list. A hub
    // that rebuilds the array from a dictionary returns a different order on
    // every call, and the attention list then reshuffles under the user's
    // cursor. Position-based access into the result is the defect this pins:
    // writing to index 0 stays green against every single-session test above.
    let middle = try recordedSessionID()
    let before = [session(.working, id: "a"),
                  session(.working, id: middle),
                  session(.working, id: "c")]
    let out = SessionHub.apply(from: .claudeCode, try recorded("stop.json"), to: before, now: t0)
    #expect(out.map(\.sessionID) == ["a", middle, "c"])
    #expect(out.map(\.state) == [.working, .awaitingInput, .working])
}

@Test func theSameSessionIDUnderADifferentToolDoesNotMerge() throws {
    // M1 keyed sessions by (tool, sessionID) for this reason. The hub now
    // produces every tool, and `CodexAdapter_test` drives the same pairing from
    // the Codex side, so both halves of the key are exercised by real payloads.
    let shared = try recordedSessionID()
    let existing = [session(.working, id: shared, tool: .codex)]
    let out = SessionHub.apply(from: .claudeCode, try recorded("stop.json"), to: existing, now: t0)
    #expect(out.count == 2)
    #expect(out.map(\.id) == ["codex:\(shared)", "claudeCode:\(shared)"])
    #expect(out.first?.state == .working, "the codex session must not have moved")
}

// MARK: - Purity

@Test func theSameInputsGiveTheSameResult() throws {
    // `SessionHub` must be a pure function of (sessions, event, now). Named bug
    // this catches: a `Date()` read inside the hub. Two calls with identical
    // arguments would then differ by however long the first call took, the
    // panel would jitter, and Task 4's staleness rule would be untestable.
    let before = [session(.working, id: try recordedSessionID())]
    let event = try recorded("stop.json")
    #expect(SessionHub.apply(from: .claudeCode, event, to: before, now: t0)
            == SessionHub.apply(from: .claudeCode, event, to: before, now: t0))
}

// MARK: - The timestamps staleness depends on

@Test func everyAcceptedEventRefreshesLastEventAt() throws {
    // Task 4 measures staleness from `lastEventAt`. An event that does not
    // refresh it makes a busy agent go stale mid-work and drops the assertion
    // while the agent is still running.
    let later = t0.addingTimeInterval(120)
    let names = try fixtureFileNames()
    #expect(names.count >= 6, "read \(names.count) fixtures; this loop would pass vacuously")

    for name in names {
        let out = SessionHub.apply(from: .claudeCode, try recorded(name),
                                   to: [session(.working, id: try recordedSessionID())],
                                   now: later)
        #expect(out.first?.lastEventAt == later, "\(name) did not refresh lastEventAt")
    }
}

@Test func stateEnteredAtMovesOnlyWhenTheStateChanges() throws {
    // Named bug this catches: `stateEnteredAt` reset on every event. "Working
    // for 40 minutes" would then read "working for 3 seconds" forever, and any
    // later rule keyed on time-in-state silently never fires.
    let later = t0.addingTimeInterval(120)
    let out = SessionHub.apply(from: .claudeCode, try recorded("pre-tool-use.json"),
                               to: [session(.working, id: try recordedSessionID())],
                               now: later)
    #expect(out.first?.state == .working)
    #expect(out.first?.stateEnteredAt == t0)

    let changed = SessionHub.apply(from: .claudeCode, try recorded("stop.json"),
                                   to: [session(.working, id: try recordedSessionID())],
                                   now: later)
    #expect(changed.first?.state == .awaitingInput)
    #expect(changed.first?.stateEnteredAt == later)
}

@Test func attentionSinceIsSetOnEntryAndClearedOnExit() throws {
    let later = t0.addingTimeInterval(60)
    let blocked = SessionHub.apply(from: .claudeCode, try recorded("stop.json"),
                                   to: [session(.working, id: try recordedSessionID())],
                                   now: later)
    #expect(blocked.first?.attentionSince == later)

    let resumed = SessionHub.apply(from: .claudeCode, try recorded("pre-tool-use.json"),
                                   to: blocked, now: later.addingTimeInterval(30))
    #expect(resumed.first?.state == .working)
    #expect(resumed.first?.attentionSince == nil)
}

@Test func attentionSinceSurvivesASecondEventInTheSameState() throws {
    // Named bug this catches: `attentionSince` refreshed on every event while
    // the state is unchanged. The panel orders the attention list by how long
    // the human has been the bottleneck, so a session that keeps receiving
    // events would forever look freshly blocked and never rise to the top.
    let blocked = SessionHub.apply(from: .claudeCode, try recorded("stop.json"),
                                   to: [session(.working, id: try recordedSessionID())],
                                   now: t0)
    let again = SessionHub.apply(from: .claudeCode, try recorded("stop.json"),
                                 to: blocked, now: t0.addingTimeInterval(300))
    #expect(again.first?.state == .awaitingInput)
    #expect(again.first?.attentionSince == t0)
}

@Test func turnCountRisesOncePerStop() throws {
    let sid = try recordedSessionID()
    var sessions = [session(.working, id: sid)]
    sessions = SessionHub.apply(from: .claudeCode, try recorded("stop.json"), to: sessions, now: t0)
    #expect(sessions.first?.turnCount == 1)
    sessions = SessionHub.apply(from: .claudeCode, try recorded("stop.json"), to: sessions, now: t0)
    #expect(sessions.first?.turnCount == 1, "a repeated Stop is the same turn")
    sessions = SessionHub.apply(from: .claudeCode, try recorded("pre-tool-use.json"), to: sessions, now: t0)
    #expect(sessions.first?.turnCount == 1)
    sessions = SessionHub.apply(from: .claudeCode, try recorded("stop.json"), to: sessions, now: t0)
    #expect(sessions.first?.turnCount == 2)
}

// MARK: - The untrusted text

@Test func lastMessageIsCappedAt140Characters() throws {
    // Design §7: `lastMessage` is attacker-influenced text the panel renders.
    // 140 is compared against a literal the implementation does not compute,
    // and the input is the recorded denial rather than a made-up string.
    let reason = try #require(try recorded("permission-denied.json").reason)
    #expect(reason.count > 140,
            "the recorded reason is \(reason.count) characters; it can no longer prove a cap")

    let out = SessionHub.apply(from: .claudeCode, try recorded("permission-denied.json"),
                               to: [session(.working, id: try recordedSessionID())],
                               now: t0)
    #expect(out.first?.lastMessage?.count == 140)
    #expect(out.first?.lastMessage == String(reason.prefix(140)))
}

@Test func aShortMessageIsNotPadded() {
    // The other side of the cap. Named bug this catches: a truncation written
    // against a fixed range, or padding out to the cap.
    //
    // The reason text is synthesized because no recorded PermissionDenied
    // carries a short one. The event's SHAPE is still the measured one: design
    // §3 claimed `message`, and the capture showed `reason`.
    let out = SessionHub.apply(from: .claudeCode, 
        HookEvent(hookEventName: "PermissionDenied", sessionID: "s1", reason: "no"),
        to: [session(.working)], now: t0)
    #expect(out.first?.lastMessage == "no")
}

@Test func aMessageOfOversizedGraphemeClustersIsBoundedInBytes() throws {
    // The audit's input. `String.prefix` counts Characters — Swift grapheme
    // clusters — and one cluster is a base letter plus ANY number of combining
    // marks. A "140-character" cap therefore let 42,140 bytes through onto a
    // session and into the menu-bar panel.
    //
    // Named bug this catches: a cap that bounds anything except bytes on the
    // way out. Every assertion here is a byte count, because `.count` is the
    // view that cannot see this defect.
    let hostile = String(repeating: "a" + String(repeating: "\u{0301}", count: 150),
                         count: 140)
    #expect(hostile.count == 140,
            "precondition: the input is \(hostile.count) Characters, so it no longer sits exactly at the character cap")
    #expect(hostile.utf8.count == 42_140,
            "precondition: the input is \(hostile.utf8.count) bytes; the audit measurement this test rests on has moved")

    let out = SessionHub.apply(from: .claudeCode, 
        HookEvent(hookEventName: "PermissionDenied", sessionID: "s1", reason: hostile),
        to: [session(.working)], now: t0)
    let message = try #require(out.first?.lastMessage)

    // The property that matters, then the exact result. One cluster is 301
    // bytes, so three of them are 903 and a fourth would reach 1204 — derived
    // by hand, never by repeating the implementation's arithmetic here.
    #expect(message.utf8.count <= 1024,
            "the message the panel renders is \(message.utf8.count) bytes")
    #expect(message.count == 3)
    #expect(message.utf8.count == 903)
}

@Test func truncationAtTheByteCapKeepsEveryGraphemeClusterWhole() throws {
    // A cluster that straddles the byte boundary. The four-person family emoji
    // is ONE Character built from seven scalars — 25 UTF-8 bytes — so 40 of
    // them are 1000 bytes and a 41st would end at 1025. The cut lands inside a
    // cluster unless the truncation walks Characters.
    //
    // Named bug this catches: truncating the UTF-8 view instead, as in
    // `String(decoding: reason.utf8.prefix(1024), as: UTF8.self)`. That returns
    // 1024 bytes ending in a severed sequence — half a scalar, or a trailing
    // ZWJ with nothing after it — which the panel renders as a broken glyph.
    let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
    #expect(family.count == 1,
            "precondition: the family emoji is \(family.count) Characters; it can no longer straddle a boundary")
    #expect(family.utf8.count == 25,
            "precondition: the family emoji is \(family.utf8.count) bytes, so the numbers below no longer hold")

    let out = SessionHub.apply(from: .claudeCode, 
        HookEvent(hookEventName: "PermissionDenied", sessionID: "s1",
                  reason: String(repeating: family, count: 140)),
        to: [session(.working)], now: t0)
    let message = try #require(out.first?.lastMessage)

    #expect(message == String(repeating: family, count: 40))
    #expect(message.count == 40)
    #expect(message.utf8.count == 1000)
}

@Test func aDenseScriptKeepsItsFullCharacterAllowance() throws {
    // The mirror of the fix. A byte cap tight enough to bite ordinary text is
    // the same defect pointing the other way, and it is invisible in a suite
    // whose only untrusted input is ASCII.
    //
    // Named bug this catches: a byte cap at or below 420, or a truncation that
    // counts bytes first. U+6F22 is 3 UTF-8 bytes and one Character, so 140 of
    // them are 420 bytes and a correct cap hands back every one.
    let out = SessionHub.apply(from: .claudeCode, 
        HookEvent(hookEventName: "PermissionDenied", sessionID: "s1",
                  reason: String(repeating: "\u{6F22}", count: 200)),
        to: [session(.working)], now: t0)
    let message = try #require(out.first?.lastMessage)

    #expect(message.count == 140)
    #expect(message.utf8.count == 420)
}

@Test func aSessionEndReasonIsNotRenderedAsAMessage() throws {
    // `reason` is carried by TWO recorded events with unrelated meanings: the
    // PermissionDenied explanation the panel shows the human, and SessionEnd's
    // terminator code, which the corpus records as the bare word "other".
    //
    // Named bug this catches: one `reason` field read for both, so closing a
    // session overwrites "Claude needs permission to run …" with "other" —
    // exactly at the moment the user looks to see what happened.
    let denial = try recorded("permission-denied.json")
    let denied = SessionHub.apply(from: .claudeCode, denial, to: [session(.working, id: try recordedSessionID())],
                                  now: t0)
    let ended = SessionHub.apply(from: .claudeCode, try recorded("session-end.json"), to: denied, now: t0)

    #expect(try rawPayload("session-end.json")["reason"] as? String == "other",
            "the recorded SessionEnd lost its reason; this test no longer discriminates")
    #expect(ended.first?.state == .done)
    #expect(ended.first?.lastMessage == denied.first?.lastMessage)
    #expect(ended.first?.lastMessage != "other")
}

// MARK: - The repository the panel names

@Test func repoNameIsTheLastComponentOfTheCwd() throws {
    let raw = try #require(try rawPayload("session-start.json")["cwd"] as? String)
    #expect(raw.hasSuffix("/coffee-bar"),
            "the recorded cwd is \(raw); the literal below no longer matches it")

    let out = SessionHub.apply(from: .claudeCode, try recorded("session-start.json"), to: [], now: t0)
    #expect(out.first?.repoName == "coffee-bar")

    // Compare the PATH, not the URL. This used to read
    // `out.first?.cwd == URL(fileURLWithPath: raw)`, which built the expectation
    // with the very call under test — so when that call was reading the
    // filesystem and appending a trailing slash for directories that happened to
    // exist, both sides agreed and the test stayed green while the behaviour was
    // wrong. `path` is stable across the `isDirectory:` form and does not
    // re-derive the construction being asserted.
    #expect(out.first?.cwd?.path == raw)
}

@Test func anEventWithNoCwdKeepsTheOneAlreadyKnown() throws {
    // Every one of the six recorded payloads carries `cwd`, so this pins the
    // optional path the decoder allows rather than an observed payload: a Stop
    // that arrives without one must not blank the repository name out of the
    // attention list.
    let start = SessionHub.apply(from: .claudeCode, try recorded("session-start.json"), to: [], now: t0)
    let stopped = SessionHub.apply(from: .claudeCode, 
        HookEvent(hookEventName: "Stop", sessionID: try recordedSessionID()),
        to: start, now: t0)
    #expect(stopped.first?.state == .awaitingInput)
    #expect(stopped.first?.repoName == "coffee-bar")
    #expect(stopped.first?.cwd == start.first?.cwd)
}

// MARK: - The drift guard between two independent definitions

@Test func theAttentionStatesAreExactlyWhatTheKnobAddsToTheWakeSet() {
    // Two definitions written independently — `PowerBroker.activeStates` and
    // `SessionState.attentionStates` — compared against each other rather than
    // against a literal either one computes.
    //
    // Named bug this catches: `holdAwakeWhileBlocked` gaining a third state
    // while the attention list keeps showing two, so a session holds the
    // machine awake and never appears in the list that explains why.
    let added = PowerBroker.activeStates(holdAwakeWhileBlocked: true)
        .subtracting(PowerBroker.activeStates(holdAwakeWhileBlocked: false))
    #expect(SessionState.attentionStates == added)
}

@Test func theSameEventYieldsTheSameSessionWhetherTheDirectoryExistsOrNot() throws {
    // PE finding I2. `URL(fileURLWithPath:)` STATS THE DISK: an existing
    // directory comes back with a trailing slash, a missing one does not.
    // Measured:
    //   existing, no flag -> file:///…/exists/
    //   missing,  no flag -> file:///…/missing
    // So `apply` stopped being a pure function of (state, event, now) — the
    // same payload produced two different `cwd` values depending on whether
    // that directory happened to be on disk when it was decoded.
    //
    // Named bug this catches: dropping `isDirectory:` again. It is invisible in
    // every other test here, because they all use paths that do not exist.
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appending(path: "coffeebar-purity-\(UInt32.random(in: 0..<UInt32.max))")
    let fm = FileManager.default
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    let event = HookEvent(hookEventName: "SessionStart",
                          sessionID: "purity-1",
                          cwd: base.path,
                          source: "startup")

    let whenPresent = SessionHub.apply(from: .claudeCode, event, to: [], now: t0).first?.cwd

    try fm.removeItem(at: base)
    #expect(fm.fileExists(atPath: base.path) == false,
            "precondition failed: the directory is still on disk, so this cannot discriminate")

    let whenAbsent = SessionHub.apply(from: .claudeCode, event, to: [], now: t0).first?.cwd

    #expect(whenPresent != nil)
    #expect(whenPresent == whenAbsent,
            "apply() read the filesystem: \(String(describing: whenPresent)) vs \(String(describing: whenAbsent))")
}
