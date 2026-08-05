// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import Darwin
import CoffeeBarCore
@testable import CoffeeBarIngest

// The BUILT `coffeebar-hook` binary against a REAL `UnixSocketIngestListener`.
//
// `HookShim_test.swift` in `CoffeeBarCoreTests` proves the request bytes are
// right. That is the seam, not the integration, and this project already
// shipped the mistake of calling a green seam an integration once. Nothing in
// this file mocks anything: a listener binds a real socket, a real child
// process is spawned from the product SwiftPM built for this run, a real hook
// payload goes in on its standard input, and the assertion is what the listener
// delivered.
//
// Every wait here has a ceiling and every child has a watchdog. A shim that
// hangs is the single worst failure this product can have — it holds up the
// agent on every tool call — so a test that hung waiting for one would be
// hiding exactly the defect it exists to catch.

/// Anchors `Bundle(for:)` to the test bundle, whose containing directory is
/// also where SwiftPM puts the executable products. Same device as
/// `DemotionCrashPath_test.swift` uses for `coffee-bar-probe`, and for the same
/// reason: it finds the binary built for THIS run rather than a stale one from
/// the other configuration.
private final class CoffeeBarHookShimAnchor: NSObject {}

/// The product name is part of the contract, not an implementation detail.
///
/// `HookHealth.commandMarker` recognises a wired hook by matching this literal
/// in the user's settings file, and `docs/QUICKSTART.md` prints it. Renaming
/// the product silently stops every wired hook being recognised as coffee-bar's.
private let shimProductName = "coffeebar-hook"

private func shimBinaryPath() throws -> String {
    let path = Bundle(for: CoffeeBarHookShimAnchor.self).bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent(shimProductName)
        .path
    try #require(FileManager.default.isExecutableFile(atPath: path),
                 """
                 no \(shimProductName) at \(path). Every assertion in this file \
                 would be vacuous, so this stops here rather than reporting the \
                 consequence.
                 """)
    return path
}

// MARK: - A socket this test owns

/// `sun_path` is 104 bytes, so the tail stays short. Same budget and the same
/// reasoning as `IngestListener_test.swift`; a second copy because that one is
/// file-private and a shared one would be a third thing to keep in step.
private struct ShimSocketSandbox {
    let directory: URL

    init() {
        let tag = String(UUID().uuidString.prefix(6)).lowercased()
        directory = FileManager.default.temporaryDirectory.appending(path: "cb-sh-\(tag)")
    }

    var path: String { directory.appending(path: "i.sock").path }

    func makeDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// Collects what the listener delivered, across the queue boundary.
private final class ShimCollected: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [(tool: AgentTool, event: HookEvent)] = []

    func record(_ tool: AgentTool, _ event: HookEvent) {
        lock.lock(); defer { lock.unlock() }
        received.append((tool, event))
    }

    var all: [(tool: AgentTool, event: HookEvent)] {
        lock.lock(); defer { lock.unlock() }
        return received
    }
}

/// Same budget as `IngestListener_test.swift`, and for the measured reason
/// recorded there: under the CPU oversubscription this suite is sized for, a
/// 5 s wait for a bind expired and took nine tests with it.
private let shimPumpBudget: TimeInterval = 30

private func shimPump(until condition: () -> Bool, seconds: TimeInterval = shimPumpBudget) {
    precondition(!Thread.isMainThread, """
        shimPump() ran on the main thread. The listener serves on \
        DispatchQueue.main and waiting here never lets that queue run, so this \
        wait cannot end. Remove @MainActor from the test that called this.
        """)
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
}

private func requireShimListenerReady(_ listener: UnixSocketIngestListener,
                                      sourceLocation: SourceLocation = #_sourceLocation) throws {
    shimPump(until: { listener.isReady })
    try #require(listener.isReady,
                 """
                 the listener did not bind within \(shimPumpBudget) s. Nothing \
                 below had a socket to measure, so this is a timeout and not a \
                 defect in what the test asserts.
                 """,
                 sourceLocation: sourceLocation)
}

/// Starts a bound listener and hands back what it collects.
private func startCollectingListener(at sandbox: ShimSocketSandbox) throws
    -> (listener: UnixSocketIngestListener, collected: ShimCollected) {
    let collected = ShimCollected()
    let listener = UnixSocketIngestListener(socketPath: sandbox.path)
    try listener.start { tool, event in collected.record(tool, event) }
    try requireShimListenerReady(listener)
    return (listener, collected)
}

// MARK: - Running the binary

private struct ShimRun {
    let status: Int32
    /// `.uncaughtSignal` means the shim died rather than exiting. A hook that
    /// dies on a signal reports a non-zero status to the agent.
    let reason: Process.TerminationReason
    let standardOutput: Data
    let standardError: Data
    let elapsed: TimeInterval
    /// True when the watchdog had to kill it. The shim is then not bounded at
    /// all, whatever the elapsed time says.
    let wasKilled: Bool

    var errorText: String { String(decoding: standardError, as: UTF8.self) }
}

/// How long the watchdog gives the shim before it kills it.
///
/// Deliberately far above `HookShim.totalTimeout` (1 s) and far below anything
/// that would wedge the run. It is not the assertion — the assertion is that
/// the shim finished on its own — it is what turns "the shim hangs" from a
/// wedged suite with no failure reported into a named red test.
private let shimWatchdogSeconds: TimeInterval = 10

/// Runs the built shim with `stdin` on its standard input, and never lets it
/// outlive `shimWatchdogSeconds`.
private func runShim(_ arguments: [String], stdin: Data) throws -> ShimRun {
    let binary = try shimBinaryPath()

    let inputFile = FileManager.default.temporaryDirectory
        .appending(path: "cb-shim-stdin-\(UUID().uuidString)")
    try stdin.write(to: inputFile)
    defer { try? FileManager.default.removeItem(at: inputFile) }
    let input = try #require(FileHandle(forReadingAtPath: inputFile.path))
    defer { try? input.close() }

    let outPipe = Pipe()
    let errPipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    process.standardInput = input
    process.standardOutput = outPipe
    process.standardError = errPipe

    let started = Date()
    try process.run()

    // The watchdog. A killed shim is reported, never silently tolerated.
    let killed = KilledFlag()
    let watchdog = DispatchWorkItem {
        if process.isRunning {
            killed.set()
            kill(process.processIdentifier, SIGKILL)
        }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + shimWatchdogSeconds, execute: watchdog)
    defer { watchdog.cancel() }

    // Read to end of stream BEFORE waiting: a child that filled a pipe buffer
    // would otherwise block on the write while this thread blocks on the exit.
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return ShimRun(status: process.terminationStatus,
                   reason: process.terminationReason,
                   standardOutput: outData,
                   standardError: errData,
                   elapsed: Date().timeIntervalSince(started),
                   wasKilled: killed.isSet)
}

private final class KilledFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// The checks that hold for EVERY hook-mode run, whatever else it did.
///
/// `docs/coffee-bar-HANDOFF.md` states both: never exit non-zero, and never
/// print to standard output, because Codex and Claude Code both read a hook's
/// stdout as a decision. A single stray byte there can veto a tool call.
private func expectHookModeContract(_ run: ShimRun,
                                    sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!run.wasKilled,
            "the shim had to be killed after \(shimWatchdogSeconds) s; it is not bounded",
            sourceLocation: sourceLocation)
    #expect(run.reason == .exit,
            "the shim died on a signal rather than exiting; the agent sees a non-zero status",
            sourceLocation: sourceLocation)
    #expect(run.status == 0,
            "the shim exited \(run.status); a non-zero hook holds up the agent",
            sourceLocation: sourceLocation)
    #expect(run.standardOutput.isEmpty,
            Comment(rawValue: "the shim wrote \(run.standardOutput.count) bytes to stdout, "
                    + "which Codex and Claude Code read as a decision: "
                    + String(decoding: run.standardOutput.prefix(80), as: UTF8.self)),
            sourceLocation: sourceLocation)
}

// MARK: - Fixtures

private var fixtureRoot: URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarIngestTests/…_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarIngestTests
        .deletingLastPathComponent()    // …/Tests
        .appending(path: "Fixtures")
}

private var fixtureDirectory: URL { fixtureRoot.appending(path: "claude-hooks") }

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureDirectory.appending(path: name))
}

/// Which recorded corpus belongs to which tool.
///
/// A literal per tool, because the directory names are not derivable from the
/// enum and a wrong pairing is exactly the defect the round-trip test looks for.
private func fixtureDirectoryName(for tool: AgentTool) -> String {
    switch tool {
    case .claudeCode: return "claude-hooks"
    case .codex: return "codex-hooks"
    case .cursor: return "cursor-hooks"
    }
}

/// A value out of the recorded payload, read from the file rather than written
/// here, so a re-capture moves the expectation with it.
private func fixtureString(_ key: String, in name: String) throws -> String {
    let object = try JSONSerialization.jsonObject(with: try fixture(name))
    let payload = try #require(object as? [String: Any], "\(name) is not a JSON object")
    let value = try #require(payload[key] as? String, "\(name) carries no `\(key)`")
    #expect(!value.isEmpty, "\(name) carries an empty `\(key)`; the check would be vacuous")
    return value
}

// MARK: - The two ends agree on where the socket is

@Test func theShimAndTheListenerNameTheSameDefaultSocket() {
    // The one constant both halves must agree on, and the only place either
    // can be seen from.
    //
    // `CoffeeBarCore` is Foundation-only by design — no syscalls, no I/O — so
    // it cannot ask for the home directory, and `CoffeeBarShim` depends on
    // `CoffeeBarCore` alone, so it cannot read `UnixSocketIngestListener`. The
    // tail therefore exists twice: once as a pure function taking the home
    // directory, and once inside the listener.
    //
    // Two copies drift. This is the guard that makes them not: change either
    // side and it goes red. Without it a shim built against a renamed
    // directory would post into a socket nothing serves, for ever, in silence
    // — the shim's whole contract is to say nothing when the app is not there.
    #expect(HookShim.socketPath(inHome: FileManager.default.homeDirectoryForCurrentUser)
            == UnixSocketIngestListener.defaultSocketPath)

    // And the tail itself, against the literal design §4 states. Deriving both
    // sides from the same expression above would let them agree on a wrong
    // value.
    #expect(HookShim.socketPath(inHome: URL(fileURLWithPath: "/tmp/home"))
            == "/tmp/home/Library/Application Support/coffee-bar/ingest.sock")
}

// MARK: - Delivery, end to end

@Test func aRecordedHookPayloadPipedThroughTheShimArrivesAsADecodedEvent() throws {
    // THE test this task exists for. Real binary, real socket, real payload.
    let sandbox = ShimSocketSandbox()
    defer { sandbox.remove() }
    let (listener, collected) = try startCollectingListener(at: sandbox)
    defer { listener.stop() }

    let payload = try fixture("pre-tool-use.json")
    let run = try runShim(["--socket=\(sandbox.path)"], stdin: payload)
    expectHookModeContract(run)

    shimPump(until: { !collected.all.isEmpty })
    let delivered = try #require(collected.all.first,
                                 "nothing reached the listener: \(run.errorText)")

    // The origin, which is the whole reason the endpoint carries a declaration.
    // A run with no `--tool` must still land on `/event` and be attributed to
    // Claude Code, because that is the cohort already wired.
    #expect(delivered.tool == .claudeCode)
    #expect(delivered.event.hookEventName == "PreToolUse")
    #expect(delivered.event.sessionID == (try fixtureString("session_id", in: "pre-tool-use.json")))
    #expect(delivered.event.toolName == "Bash")
    #expect(collected.all.count == 1, "the shim posted more than once")
    #expect(run.standardError.isEmpty,
            Comment(rawValue: "a successful post wrote to stderr: \(run.errorText)"))
}

@Test func theToolFlagDecidesWhichOriginTheListenerRecords() throws {
    // The reason the shim exists at all: one binary, three endpoints, and the
    // user picks with a flag instead of pasting a different URL per tool.
    //
    // `codex` and `claude-code` share the payload vocabulary — `AgentTool`
    // records the measurement that no payload key can tell them apart — so the
    // SAME bytes must land under a different origin purely because of the flag.
    // That is what makes this test discriminate: a shim that ignored `--tool`
    // and always posted to `/event` would deliver an identical event with the
    // wrong `tool`, and only this assertion sees it.
    let sandbox = ShimSocketSandbox()
    defer { sandbox.remove() }
    let (listener, collected) = try startCollectingListener(at: sandbox)
    defer { listener.stop() }

    let payload = try fixture("stop.json")
    for name in ["claude-code", "codex"] {
        let run = try runShim(["--tool=\(name)", "--socket=\(sandbox.path)"], stdin: payload)
        expectHookModeContract(run)
    }

    shimPump(until: { collected.all.count == 2 })
    #expect(collected.all.map(\.tool) == [.claudeCode, .codex])
    #expect(collected.all.allSatisfy { $0.event.hookEventName == "Stop" })
}

@Test(arguments: AgentTool.allCases)
func eachToolsOwnRecordedPayloadArrivesUnderItsOwnOrigin(_ tool: AgentTool) throws {
    // The claim the documentation makes: ONE binary serves all three adapters.
    //
    // The other delivery tests send Claude-shaped bytes, which only prove the
    // two tools that share a vocabulary. Cursor does not share it — its events
    // are camelCase and it keys the session as `conversation_id` — so only its
    // OWN recorded payload can show that `--tool=cursor` reaches a decoder that
    // understands it. Without this, the shim could post Cursor's payload to
    // Cursor's endpoint and have it refused 400 for ever, and every other test
    // here would stay green.
    let sandbox = ShimSocketSandbox()
    defer { sandbox.remove() }
    let (listener, collected) = try startCollectingListener(at: sandbox)
    defer { listener.stop() }

    let directory = fixtureRoot.appending(path: fixtureDirectoryName(for: tool))
    let payload = try Data(contentsOf: directory.appending(path: "session-start.json"))
    #expect(!payload.isEmpty, "the recorded payload is empty; the run below would be vacuous")

    let run = try runShim(["--tool=\(tool.shimName)", "--socket=\(sandbox.path)"], stdin: payload)
    expectHookModeContract(run)
    #expect(run.standardError.isEmpty,
            Comment(rawValue: "\(tool.shimName) was refused: \(run.errorText)"))

    shimPump(until: { !collected.all.isEmpty })
    let delivered = try #require(collected.all.first,
                                 "nothing reached the listener for \(tool.shimName): \(run.errorText)")
    #expect(delivered.tool == tool)

    // Read out of the recorded file, never written here. Cursor keeps its OWN
    // vocabulary through the adapter — `sessionStart`, where Claude Code and
    // Codex both send `SessionStart` — so a literal would be wrong for one of
    // the three and a shared enum case cannot express all three either.
    let recorded = try #require(
        (try JSONSerialization.jsonObject(with: payload) as? [String: Any])?["hook_event_name"]
            as? String,
        "the \(tool.shimName) fixture carries no hook_event_name")
    #expect(delivered.event.hookEventName == recorded)
}

@Test func aCursorFlagPostsToTheCursorEndpointAndTheShimSurvivesTheRefusal() throws {
    // The brief calls this the 404 path. It is not: `/event/cursor` IS a
    // recognised endpoint, so `AgentTool.declared(byEndpoint:)` resolves it and
    // the 404 branch is never reached. A Claude-shaped body posted there fails
    // to decode as a `CursorHookEvent` — which keys `session_id` as
    // `conversation_id` — so the listener answers 400.
    //
    // The shim cannot produce a 404 at all, because it only ever posts to an
    // endpoint `AgentTool` declares. That is a property worth having, not a
    // gap: the 404 branch guards against a hand-written `curl` line with a typo
    // in it, and `IngestListener_test.swift` covers it directly.
    //
    // What this test IS for: a refusal must not become a non-zero exit, and the
    // diagnostic must name the status without ever naming the payload.
    let sandbox = ShimSocketSandbox()
    defer { sandbox.remove() }
    let (listener, collected) = try startCollectingListener(at: sandbox)
    defer { listener.stop() }

    let needle = "NEEDLE-THAT-MUST-NEVER-BE-PRINTED"
    let body = Data(#"{"hook_event_name":"Stop","session_id":"\#(needle)"}"#.utf8)
    let run = try runShim(["--tool=cursor", "--socket=\(sandbox.path)"], stdin: body)
    expectHookModeContract(run)

    #expect(run.errorText.contains("400"),
            Comment(rawValue: "the refusal was not reported: \(run.errorText.isEmpty ? "<nothing on stderr>" : run.errorText)"))

    // The privacy boundary, at the process level. `SECURITY.md` and design §7
    // make the shim a PIPE: it may name the STATUS and never the payload. A
    // diagnostic that echoed the body would put conversation content into the
    // agent's own log, which is the one place the listener's dropping cannot
    // reach.
    #expect(!run.errorText.contains(needle),
            "the diagnostic echoed the payload")
    #expect(!run.errorText.contains("hook_event_name"),
            "the diagnostic echoed the payload")

    // Nothing was stored. A 400 that still delivered would be worse than the
    // refusal.
    shimPump(until: { !collected.all.isEmpty }, seconds: 1)
    #expect(collected.all.isEmpty)
}

// MARK: - The app is not running

@Test func anAbsentSocketIsSilentAndCostsNothing() throws {
    // The commonest state of all: coffee-bar is not running. Every tool call
    // still fires a hook, so this path must be silent, fast and successful.
    let sandbox = ShimSocketSandbox()
    defer { sandbox.remove() }
    try sandbox.makeDirectory()
    #expect(!FileManager.default.fileExists(atPath: sandbox.path),
            "the premise is wrong: something is at the socket path")

    let run = try runShim(["--socket=\(sandbox.path)"], stdin: try fixture("stop.json"))
    expectHookModeContract(run)
    #expect(run.standardError.isEmpty,
            Comment(rawValue: "a not-running app is normal and must be silent: \(run.errorText)"))
}

@Test func aStaleSocketNodeLeftByACrashIsSilentToo() throws {
    // A node outlives the process that bound it, so this is what every hook
    // finds after the app crashes. `connect` answers ECONNREFUSED rather than
    // ENOENT, which is a different branch from the one above and the reason
    // both are tested.
    let sandbox = ShimSocketSandbox()
    defer { sandbox.remove() }
    try sandbox.makeDirectory()

    let abandoned = try #require(BoundSocket(at: sandbox.path, listening: true))
    abandoned.close()
    #expect(FileManager.default.fileExists(atPath: sandbox.path),
            "the node did not survive its process; this test is not about a stale node")

    let run = try runShim(["--socket=\(sandbox.path)"], stdin: try fixture("stop.json"))
    expectHookModeContract(run)
    #expect(run.standardError.isEmpty,
            Comment(rawValue: "a stale node after a crash is normal and must be silent: \(run.errorText)"))
}

@Test func aListenerThatNeverAnswersDoesNotHoldTheAgent() throws {
    // The one hang that is real. A bound socket that is never SERVED accepts
    // the connection into the listen backlog, takes the write into the socket
    // buffer, and then answers nothing at all — `IngestListener_test.swift`
    // records the measurement, where an unbounded `curl` held one test body for
    // ever and took the whole run with it.
    //
    // The assertion is `!wasKilled`: the shim must give up BY ITSELF. Delete
    // the receive timeout and the watchdog fires, `wasKilled` is true, and this
    // test goes red instead of wedging the suite.
    let sandbox = ShimSocketSandbox()
    defer { sandbox.remove() }
    try sandbox.makeDirectory()

    let deaf = try #require(BoundSocket(at: sandbox.path, listening: true))
    defer { deaf.close() }

    let run = try runShim(["--socket=\(sandbox.path)"], stdin: try fixture("stop.json"))
    expectHookModeContract(run)

    // Five seconds against a 1 s bound. The slack absorbs the CPU
    // oversubscription this suite is sized for, and is still far below the
    // 10 s `UnixSocketIngestListener.defaultIdleTimeout` a shim with no bound
    // of its own would wait out.
    #expect(run.elapsed < 5,
            Comment(rawValue: "one shim run took \(run.elapsed) s against a "
                    + "\(HookShim.totalTimeout) s bound"))
    #expect(HookShim.totalTimeout < UnixSocketIngestListener.defaultIdleTimeout,
            "the shim waits at least as long as the listener would; its bound buys nothing")
}

// MARK: - Nothing to post

@Test func emptyStandardInputPostsNothing() throws {
    // A hook fires with no payload during agent start-up and shutdown races.
    // An empty POST would reach the listener, fail to decode and be answered
    // 400 — noise in the log for an event that never existed.
    let sandbox = ShimSocketSandbox()
    defer { sandbox.remove() }
    let (listener, collected) = try startCollectingListener(at: sandbox)
    defer { listener.stop() }

    let run = try runShim(["--socket=\(sandbox.path)"], stdin: Data())
    expectHookModeContract(run)

    shimPump(until: { !collected.all.isEmpty }, seconds: 1)
    #expect(collected.all.isEmpty, "an empty stdin was posted anyway")
    #expect(run.standardError.isEmpty,
            Comment(rawValue: "nothing to post is not a fault: \(run.errorText)"))
}

@Test func anUnrecognisedToolNamePostsNothingAndSaysSo() throws {
    // The user mistyped the flag. Posting anyway would attribute the session to
    // whichever tool the shim guessed, and `AgentTool` is explicit that a
    // misidentified origin drives the wrong state machine silently.
    //
    // The load-bearing assertion is that the listener received NOTHING. A shim
    // that fell back to `claude-code` would pass every other check here.
    let sandbox = ShimSocketSandbox()
    defer { sandbox.remove() }
    let (listener, collected) = try startCollectingListener(at: sandbox)
    defer { listener.stop() }

    let run = try runShim(["--tool=claudecode", "--socket=\(sandbox.path)"],
                          stdin: try fixture("stop.json"))
    expectHookModeContract(run)

    shimPump(until: { !collected.all.isEmpty }, seconds: 1)
    #expect(collected.all.isEmpty, "an unrecognised tool name was posted anyway")
    #expect(run.errorText.contains("claudecode"),
            Comment(rawValue: "the diagnostic does not say which name was rejected: \(run.errorText)"))
    #expect(run.errorText.contains("claude-code"),
            Comment(rawValue: "the diagnostic does not name a value that would work: \(run.errorText)"))
}

@Test func anUnrecognisedFlagPostsNothingAndSaysSo() throws {
    // Same reasoning as an unrecognised tool: a flag the shim does not
    // understand may be the user asking for something it will not do, so
    // posting regardless would be a guess.
    let sandbox = ShimSocketSandbox()
    defer { sandbox.remove() }
    let (listener, collected) = try startCollectingListener(at: sandbox)
    defer { listener.stop() }

    let run = try runShim(["--endpoint=/event/cursor", "--socket=\(sandbox.path)"],
                          stdin: try fixture("stop.json"))
    expectHookModeContract(run)

    shimPump(until: { !collected.all.isEmpty }, seconds: 1)
    #expect(collected.all.isEmpty, "an unrecognised flag was posted anyway")
    #expect(run.errorText.contains("--endpoint"),
            Comment(rawValue: "the diagnostic does not name the rejected flag: \(run.errorText)"))
}

@Test func helpIsWrittenToStandardErrorAndNeverToStandardOutput() throws {
    // `--help` is the one run a human starts, and it still may not write to
    // standard output: the same binary is wired into an agent, and a user who
    // runs it by hand must not learn a habit the hook path forbids.
    // `coffee-bar-probe` writes its usage to standard error for the same reason.
    let run = try runShim(["--help"], stdin: Data())
    #expect(!run.wasKilled)
    #expect(run.reason == .exit)
    #expect(run.status == 0, "asking for help is not an error")
    #expect(run.standardOutput.isEmpty,
            "usage went to stdout, which the agent reads as a decision")
    #expect(run.errorText.contains(shimProductName))
    #expect(run.errorText.contains("--tool="))
    for tool in AgentTool.allCases {
        #expect(run.errorText.contains(tool.shimName),
                Comment(rawValue: "usage does not mention \(tool.shimName)"))
    }
}

// MARK: - A human at a terminal is not hook mode

/// A real pseudo-terminal, so the child's `isatty(0)` is true.
///
/// Nothing else will do. Handing the child a pipe, a file or `/dev/null` all
/// report false, which is the hook-mode branch — so a test built on any of them
/// could never reach the code below and would be green whatever it asserted.
private final class PseudoTerminal {
    let primary: Int32
    let secondary: Int32

    init?() {
        let opened = posix_openpt(O_RDWR | O_NOCTTY)
        guard opened >= 0, grantpt(opened) == 0, unlockpt(opened) == 0,
              let name = ptsname(opened)
        else {
            if opened >= 0 { Darwin.close(opened) }
            return nil
        }
        let follower = open(String(cString: name), O_RDWR | O_NOCTTY)
        guard follower >= 0 else {
            Darwin.close(opened)
            return nil
        }
        primary = opened
        secondary = follower
    }

    func close() {
        Darwin.close(secondary)
        Darwin.close(primary)
    }
}

@Test func aUsageErrorFromATerminalExitsSixtyFourInsteadOfZero() throws {
    // The one exception to "always exit 0", and the reason it is safe: exit 0
    // exists so a failing hook cannot hold up an agent, and a person typing at
    // a terminal is not an agent. `coffee-bar-probe` already exits 64 for a
    // verb it does not implement, so this matches a convention the project has.
    //
    // Named bug this catches: the terminal branch keyed off something other
    // than `isatty` — an environment variable, or the absence of `--socket` —
    // which would make a real hook exit 64 under whatever condition it picked
    // and hold up the agent on every tool call. Only a REAL pty can tell the
    // two branches apart, so this test builds one.
    let binary = try shimBinaryPath()
    let terminal = try #require(PseudoTerminal(), "could not open a pty; this guard cannot run")
    defer { terminal.close() }

    let outPipe = Pipe()
    let errPipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = ["--tool=nonsense"]
    process.standardInput = FileHandle(fileDescriptor: terminal.secondary, closeOnDealloc: false)
    process.standardOutput = outPipe
    process.standardError = errPipe

    try process.run()
    let killed = KilledFlag()
    let watchdog = DispatchWorkItem {
        if process.isRunning {
            killed.set()
            kill(process.processIdentifier, SIGKILL)
        }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + shimWatchdogSeconds, execute: watchdog)
    defer { watchdog.cancel() }

    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    #expect(!killed.isSet, "the shim hung on a terminal instead of reporting the usage error")
    #expect(process.terminationReason == .exit)
    #expect(process.terminationStatus == 64,
            "a usage error from a terminal exited \(process.terminationStatus); coffee-bar-probe uses 64")

    // Still not standard output, even here. The same binary is wired into an
    // agent, and a person who runs it by hand must not learn a habit the hook
    // path forbids.
    #expect(outData.isEmpty,
            Comment(rawValue: "usage went to stdout: "
                    + String(decoding: outData.prefix(80), as: UTF8.self)))
    let text = String(decoding: errData, as: UTF8.self)
    #expect(text.contains("nonsense"))
    #expect(text.contains("usage:"), "a terminal user got no usage text")
}

// MARK: - Too large

@Test func aPayloadOverTheListenersCapIsRefusedAndTheShimStillExitsZero() throws {
    // `HTTPRequestFramer.maximumBytes` refuses on the DECLARED length, before
    // the bytes are buffered, so the listener answers 413 and closes while the
    // shim is still writing.
    //
    // Named bug, and the reason this test is not merely a status check: writing
    // to a socket whose peer has closed raises SIGPIPE, which no exit code can
    // survive. A shim without `SO_NOSIGPIPE` dies here with `.uncaughtSignal`
    // and status 13, the agent sees a failed hook, and the failure appears only
    // for large payloads — which is to say, on real replies carrying code.
    let sandbox = ShimSocketSandbox()
    defer { sandbox.remove() }
    let (listener, collected) = try startCollectingListener(at: sandbox)
    defer { listener.stop() }

    let filler = String(repeating: "x", count: HTTPRequestFramer.maximumBytes + 1024)
    let body = Data(#"{"hook_event_name":"Stop","session_id":"s1","cwd":"\#(filler)"}"#.utf8)
    #expect(body.count > HTTPRequestFramer.maximumBytes,
            "the payload is under the cap; this test would exercise the success path")

    let run = try runShim(["--socket=\(sandbox.path)"], stdin: body)
    expectHookModeContract(run)
    #expect(run.errorText.contains("413"),
            Comment(rawValue: "the refusal was not reported: \(run.errorText.isEmpty ? "<nothing on stderr>" : run.errorText)"))

    shimPump(until: { !collected.all.isEmpty }, seconds: 1)
    #expect(collected.all.isEmpty, "an over-cap payload was stored")
}

// MARK: - What one run costs

@Test func oneShimRunFitsInsideTheBudgetTheHandoffStates() throws {
    // `docs/coffee-bar-HANDOFF.md` states the contract as "always exit 0,
    // ≤50 ms". A hook runs on every tool call, so this is the number that
    // decides whether the shim is usable at all.
    //
    // Measured against a real listener, not asserted from a document. The bound
    // checked here is deliberately looser than 50 ms: `Process` spawn plus this
    // suite's CPU oversubscription both land inside the measurement, and a
    // flaky performance gate teaches people to ignore it. The REPORT carries
    // the measured number; this only catches a regression of the order that
    // would make the shim unusable.
    let sandbox = ShimSocketSandbox()
    defer { sandbox.remove() }
    let (listener, collected) = try startCollectingListener(at: sandbox)
    defer { listener.stop() }

    let payload = try fixture("post-tool-use.json")
    var samples: [TimeInterval] = []
    for _ in 0..<5 {
        let run = try runShim(["--socket=\(sandbox.path)"], stdin: payload)
        expectHookModeContract(run)
        samples.append(run.elapsed)
    }

    shimPump(until: { collected.all.count == 5 })
    #expect(collected.all.count == 5, "not every run was delivered; the timings are not of a real post")

    let best = try #require(samples.min())
    #expect(best < 0.5,
            Comment(rawValue: "the fastest of five runs took \(best) s; the stated budget is 0.05 s "
                    + "and this bound is ten times looser. Samples: \(samples)"))
}

// MARK: - A raw socket the shim can find

/// Binds an `AF_UNIX` socket at `path` without serving it.
///
/// Two states this file needs and no listener can produce: a node abandoned by
/// a crashed process, and a node that is bound and listening but never
/// accepted. Both are ordinary after a crash, and both are indistinguishable
/// from a healthy socket until something tries to talk to them.
private final class BoundSocket {
    private let descriptor: Int32

    init?(at path: String, listening: Bool) {
        let opened = socket(AF_UNIX, SOCK_STREAM, 0)
        guard opened >= 0 else { return nil }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(opened)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }

        Darwin.unlink(path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(opened, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(opened)
            return nil
        }
        if listening, Darwin.listen(opened, 4) != 0 {
            Darwin.close(opened)
            return nil
        }
        descriptor = opened
    }

    func close() { Darwin.close(descriptor) }
}
