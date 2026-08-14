// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import CoffeeBarCore
@testable import CoffeeBarIngest

// The command the "Copy hook snippet" button puts on the pasteboard, RUN.
//
// `HookSnippet_test.swift` reads that command as TEXT, and text is the wrong
// instrument for the question it asks. Eleven edits have broken this command
// while its substring checks stayed green; five of them are green in this tree
// today. Each leaves `curl` at the front, the socket path present exactly once
// and `--data-binary @-` intact, and each delivers nothing:
//
//   - `--abstract-unix-socket` appended — a Linux namespace curl never connects
//     to on macOS, and the last socket option wins.
//   - `.old` glued outside the closing quote, so the shell hands curl a path
//     that is one node away from the live socket.
//   - `-G` in front of the body flag, which turns the POST body into a query
//     string and the URL into one curl rejects.
//   - `@-x` in place of `@-`, which reads a file named `-x` that is not there.
//   - a second `-d` beside `--data-binary @-`, because curl CONCATENATES data
//     arguments, so what arrives is the payload with `&EXTRA=1` welded on.
//
// No substring separates those five from a working command, and no larger
// substring would: whether a command line works is a property of curl's
// argument parser, of the shell that splits it and of the kernel that routes
// it, not of the string. So this file stops reading and runs it — a real
// `/bin/sh`, a real `curl`, a real AF_UNIX socket, and the real listener on the
// far end. A command that does not deliver fails here whatever it looks like,
// including the defeat nobody has thought of yet.
//
// It lives in `CoffeeBarIngestTests` rather than beside its subject because
// this is where the listener is. `CoffeeBarCore` holds no socket and does no
// I/O (design §8), which is exactly why the guard there had to be a text one.

/// A `HOME` whose `Library/Application Support/coffee-bar/ingest.sock` is a
/// socket this test owns, and nothing else does.
///
/// Moving `HOME` is the ONLY substitution here. The snippet leaves `$HOME`
/// unexpanded and hardcodes every byte after it, so pointing the command at a
/// test socket is a matter of changing the environment rather than rewriting
/// the command — which means the command runs byte for byte as the button
/// emits it, expansion and all, and the deferral itself is under test.
///
/// Under `/tmp` rather than `FileManager.temporaryDirectory`, and that is
/// forced rather than chosen. `sun_path` is 104 bytes (`sys/un.h:79`); the tail
/// the snippet hardcodes is 51 of them and the per-user temporary directory is
/// already 49, which would leave four bytes for a unique name. `/tmp/cb-home-`
/// plus six hex reaches 70 in total.
///
/// A per-run UUID and never a fixed basename: two `swift test` runs at once
/// would otherwise fight over one node, and `start()` correctly refuses a path
/// something else is already answering on.
private struct HomeSandbox {
    let home: String

    init() {
        let tag = String(UUID().uuidString.prefix(6)).lowercased()
        home = "/tmp/cb-home-\(tag)"
    }

    /// What `$HOME/Library/Application Support/coffee-bar/ingest.sock` expands
    /// to under this `HOME`.
    ///
    /// A LITERAL, and deliberately not built from anything `HookSnippet` owns.
    /// The listener binds here; a snippet that moved the socket a byte stops
    /// arriving rather than following the change.
    var socketPath: String {
        home + "/Library/Application Support/coffee-bar/ingest.sock"
    }

    func remove() { try? FileManager.default.removeItem(atPath: home) }
}

/// Every command string in `tool`'s snippet, whichever shape the tool's file
/// takes.
///
/// A second copy of the walker in `HookSnippet_test.swift`. SwiftPM gives two
/// test targets no way to share code, and that file is in `CoffeeBarCoreTests`.
/// Both walk BOTH nestings, so a snippet that silently changed shape yields its
/// commands anyway rather than yielding an empty list a caller reads as nothing
/// to check.
private func commands(in tool: AgentTool) throws -> [String] {
    let text = try #require(HookSnippet.json(for: tool),
                            "\(tool) has a required-event list but no snippet to paste")
    let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8))
    let root = try #require(parsed as? [String: Any],
                            "\(tool) snippet is JSON but not an object")
    let hooks = try #require(root["hooks"] as? [String: Any],
                             "\(tool) snippet carries no `hooks` object")

    var found: [String] = []
    for (_, entry) in hooks {
        guard let elements = entry as? [[String: Any]] else { continue }
        for element in elements {
            if let command = element["command"] as? String { found.append(command) }
            if let inner = element["hooks"] as? [[String: Any]] {
                found += inner.compactMap { $0["command"] as? String }
            }
        }
    }
    return found
}

/// The identifier every payload below declares, echoed back by the listener.
private let postedSessionID = "11111111-2222-3333-4444-555555555555"

/// A payload `tool`'s own endpoint accepts, and the event name it carries.
///
/// Literals rather than the recorded corpus, because the subject here is the
/// COMMAND: each body wants to be the smallest thing its endpoint will take.
/// Cursor reads the identifier from `conversation_id` where the other two read
/// `session_id`, which one shared literal would hide — and posting a body the
/// endpoint refuses would turn every assertion below into a report about the
/// payload instead of about the command.
///
/// A `switch` with no `default`, so a fourth `AgentTool` fails to compile here
/// rather than silently borrowing another tool's envelope.
private func payload(for tool: AgentTool) -> (json: String, eventName: String) {
    switch tool {
    case .claudeCode, .codex:
        return (#"{"hook_event_name":"Stop","session_id":"\#(postedSessionID)"}"#, "Stop")
    case .cursor:
        return (#"{"hook_event_name":"sessionStart","conversation_id":"\#(postedSessionID)"}"#,
                "sessionStart")
    }
}

/// What one run of a snippet command left behind.
private struct CommandRun {
    let status: Int32
    /// Standard error. Diagnostics only — carried so a failure names curl's own
    /// complaint instead of leaving a bare exit code to be looked up.
    let complained: String
}

/// Runs `command` the way an agent tool runs it, and waits for it.
///
/// `/bin/sh -c` with the command as ONE STRING, and never an argv this test
/// assembles. The user pastes a single string into a settings file and their
/// tool hands it to a shell, so the quoting, the `$HOME` expansion and the
/// argument splitting are all part of what is under test. Splitting it here
/// would test a command this project never emits, and would see straight past
/// a broken quote.
///
/// A MINIMAL environment rather than this process's. `curl` reads proxy and CA
/// settings from the environment, so inheriting one would let a stray
/// `ALL_PROXY` in a developer's shell decide whether this passes. `PATH` is the
/// stock pair because the snippet says `curl` and not `/usr/bin/curl`: that the
/// command resolves on a machine where nobody installed anything is part of the
/// claim.
private func run(_ command: String, in sandbox: HomeSandbox,
                 posting body: String) throws -> CommandRun {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.environment = ["HOME": sandbox.home, "PATH": "/usr/bin:/bin"]

    let input = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors

    try process.run()
    // The payload is well under the 64 KiB pipe buffer, so this cannot block
    // against a reader that has not started.
    input.fileHandleForWriting.write(Data(body.utf8))
    try input.fileHandleForWriting.close()

    let complained = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return CommandRun(status: process.terminationStatus,
                      complained: String(decoding: complained, as: UTF8.self)
                          .trimmingCharacters(in: .whitespacesAndNewlines))
}

// MARK: - The acceptance

@Test(arguments: AgentTool.allCases)
func everyCommandTheSnippetPastesDeliversItsEvent(_ tool: AgentTool) throws {
    // Named bug this catches: any edit to the emitted command that leaves it
    // looking right and stops it working. That is not a category invented here
    // — eleven such edits are on record, and the five listed at the top of this
    // file pass every text check in `HookSnippet_test.swift` today.
    //
    // Two separate claims, and both are needed. The exit status says curl ran
    // and the request was served; the arrival count says the bytes reached the
    // listener. Neither implies the other: replacing `curl` with `echo` exits 0
    // and delivers nothing, and a command that delivers to the WRONG socket can
    // also exit 0 when something else is listening there.
    let sandbox = HomeSandbox()
    defer { sandbox.remove() }

    let collected = CollectedOrigins()
    let listener = UnixSocketIngestListener(socketPath: sandbox.socketPath)
    defer { listener.stop() }
    try listener.start { origin, event in collected.record(origin, event) }
    try requireReady(listener)

    let found = try commands(in: tool)
    #expect(found.count == 5, "\(tool) snippet holds \(found.count) commands, expected 5")

    let body = payload(for: tool)
    for command in found {
        let result = try run(command, in: sandbox, posting: body.json)
        #expect(result.status == 0, """
            the \(tool) snippet's command exited \(result.status) instead of \
            delivering. curl said: \(result.complained). The command was: \(command)
            """)
    }

    pump(until: { collected.count >= found.count })

    // EVERY command, not one of them. A snippet whose first four events post to
    // a dead socket and whose fifth works would satisfy any assertion that only
    // asked whether anything had arrived — and it is the count guard, not the
    // loop below, that fails when nothing arrives at all: a loop over an empty
    // list asserts nothing and reads as success.
    #expect(collected.count == found.count, """
        the \(tool) snippet ran \(found.count) command(s) and \(collected.count) \
        event(s) reached the listener
        """)

    for (origin, event) in collected.all {
        #expect(origin == tool,
                "an event the \(tool) snippet sent was filed as \(origin)")
        #expect(event.hookEventName == body.eventName, """
            the \(tool) snippet delivered \(event.hookEventName) for a posted \
            \(body.eventName)
            """)
        #expect(event.sessionID == postedSessionID,
                "the \(tool) snippet delivered session \(event.sessionID)")
    }
}

@Test(arguments: AgentTool.allCases)
func aRefusedPostIsReportedThroughTheCommandsExitStatus(_ tool: AgentTool) throws {
    // The `--fail` family, proved rather than spelled out in a comment. Without
    // it curl exits 0 on a 4xx, so an ingest refusing every payload would be
    // indistinguishable from one storing them all.
    //
    // On this channel the exit status is the ONLY signal there is.
    // `everyAnswerTheEventPathGivesCarriesNoBody` measures that every answer
    // `POST /event` gives — 204, 400, 413 alike — carries a zero-length body,
    // deliberately, because curl writes a response body to stdout and an agent
    // reads a hook's stdout as a decision. So there is nothing to print and
    // nothing for a caller to parse; a status of 0 over a refusal is silence.
    //
    // Named bug this catches: dropping the fail flag from the emitted command.
    // The hook then reports success on every refused post for ever, and no
    // check in the package would see it — `HookHealth` reads the settings file,
    // not the wire.
    let sandbox = HomeSandbox()
    defer { sandbox.remove() }

    let collected = CollectedOrigins()
    let listener = UnixSocketIngestListener(socketPath: sandbox.socketPath)
    defer { listener.stop() }
    try listener.start { origin, event in collected.record(origin, event) }
    try requireReady(listener)

    let command = try #require(try commands(in: tool).first,
                               "\(tool) snippet holds no command to run")

    // Framed correctly and refused on its contents: the listener answers 400,
    // which is the case a user actually meets when a tool changes its envelope.
    let result = try run(command, in: sandbox, posting: "not json at all")

    // 22 is curl's own code for "the HTTP server returned an error status", and
    // it is pinned rather than tested for non-zero: a command that failed to
    // START also exits non-zero, and that is a different defect wearing the
    // same clothes. Measured against curl 8.7.1.
    #expect(result.status == 22, """
        a refused post exited \(result.status); the \(tool) hook cannot tell a \
        stored event from a rejected one. curl said: \(result.complained)
        """)

    // The refusal was of the PAYLOAD and not of the route. Without this, a
    // command posting to a path the listener does not serve would draw a 404,
    // exit 22 as well, and pass the assertion above while delivering nothing
    // for a completely different reason.
    let accepted = payload(for: tool)
    let second = try run(command, in: sandbox, posting: accepted.json)
    #expect(second.status == 0,
            "the same command exited \(second.status) on a payload the endpoint accepts")

    pump(until: { collected.count >= 1 })
    #expect(collected.count == 1, """
        \(collected.count) event(s) arrived from two posts; exactly one of them \
        carried a payload this endpoint decodes
        """)
}
