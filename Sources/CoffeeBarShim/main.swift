// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin
import CoffeeBarCore

// `coffeebar-hook` — the one command a user wires into an agent's hooks.
//
// Before this existed the user pasted a bespoke `curl` line per hook, six times
// in `docs/QUICKSTART.md` alone, each one hardcoding the socket path and the
// endpoint. Codex and Cursor need DIFFERENT endpoints, so three long lines had
// to be copied and kept apart. This makes an adapter one binary and one flag.
//
// **Two rules govern everything below, and both come from
// `docs/coffee-bar-HANDOFF.md`.**
//
// 1. Never exit non-zero. A hook that fails holds up the agent, and none of the
//    conditions here are the user's fault or the user's problem: the app not
//    running is the normal state.
// 2. Never write to standard output. Codex and Claude Code both read a hook's
//    stdout as a DECISION, so one stray byte there can veto a tool call.
//    Diagnostics go to standard error, and they name the STATUS only.
//
// **The shim is a PIPE.** Design §7 and `SECURITY.md` put the privacy boundary
// in the listener, which drops the transcript path and the assistant reply at
// the decode boundary. Nothing here parses the body, writes it to a file, or
// puts it in a diagnostic.
//
// **No `Network.framework`, no dependency beyond `CoffeeBarCore`.** A hook runs
// on every tool call, so process start-up is the dominant cost and the budget
// is 50 ms. Raw `socket(2)`/`connect(2)`/`write(2)`/`read(2)` it is.

// MARK: - Saying things

/// The ONLY way anything leaves this process. `stdout` is never touched.
func warn(_ message: String) {
    FileHandle.standardError.write(Data("coffeebar-hook: \(message)\n".utf8))
}

let usage = """
    usage: coffeebar-hook [--tool=<name>] [--socket=<path>]

    Reads one hook payload on standard input and posts it to a running
    coffee-bar. Wire it as the command of an agent hook.

      --tool=<name>    which agent sent the payload; one of
                       \(AgentTool.allCases.map(\.shimName).joined(separator: ", ")).
                       Defaults to \(HookShim.defaultTool.shimName).
      --socket=<path>  the ingest socket. Defaults to
                       ~/Library/Application Support/coffee-bar/ingest.sock
      --help           this text.

    Exits 0 whatever happens, and writes nothing to standard output: an agent
    reads a hook's stdout as a decision, and a failing hook holds up the agent.
    When coffee-bar is not running the payload is dropped in silence.

    """

/// Leaves without posting anything.
///
/// Exit 64 (`EX_USAGE`) only when a HUMAN is at a terminal, matching
/// `coffee-bar-probe`. Being run from a terminal is not hook mode, and a person
/// who mistyped a flag deserves to be told. An agent gets 0 regardless.
func giveUp(_ message: String) -> Never {
    warn(message)
    if isatty(FileHandle.standardInput.fileDescriptor) == 1 {
        FileHandle.standardError.write(Data(usage.utf8))
        exit(64)
    }
    exit(0)
}

// MARK: - What the user asked for

var tool = HookShim.defaultTool
var socketPath = HookShim.socketPath(inHome: FileManager.default.homeDirectoryForCurrentUser)

for argument in CommandLine.arguments.dropFirst() {
    switch argument {
    case "--help", "-h":
        FileHandle.standardError.write(Data(usage.utf8))
        exit(0)

    case let value where value.hasPrefix("--tool="):
        let name = String(value.dropFirst("--tool=".count))
        // Refused, never defaulted — the rule `AgentTool.declared(byEndpoint:)`
        // states for endpoints. A near miss filed under the wrong tool drives
        // the wrong state machine with nothing to show for it.
        guard let declared = AgentTool.declared(byShimName: name) else {
            giveUp("""
                unknown --tool value "\(name)". Use one of \
                \(AgentTool.allCases.map(\.shimName).joined(separator: ", ")). \
                Nothing was posted.
                """)
        }
        tool = declared

    case let value where value.hasPrefix("--socket="):
        socketPath = String(value.dropFirst("--socket=".count))

    default:
        giveUp("unknown argument \"\(argument)\". Nothing was posted.")
    }
}

// MARK: - The payload

/// Read to end of stream, and NOT truncated at the listener's cap.
///
/// A shim that cut the body short would deliver something the agent never sent,
/// which is worse than the refusal: the listener refuses an over-cap request
/// with 413 and stores nothing, and that is a visible answer this process can
/// report. Truncation would be a silent corruption instead.
let body = FileHandle.standardInput.readDataToEndOfFile()

// Nothing to say. A hook fires with no payload during start-up and shutdown
// races, and an empty POST would only earn a 400 for an event that never was.
if body.isEmpty { exit(0) }

// MARK: - Posting it

/// The deadline for the whole run, fixed before the first syscall.
///
/// Every wait below takes what is LEFT of it, so the total cannot grow with the
/// number of steps.
let deadline = Date().addingTimeInterval(HookShim.totalTimeout)

func remaining(cappedAt ceiling: TimeInterval) -> TimeInterval {
    max(0, min(ceiling, deadline.timeIntervalSinceNow))
}

func timeval(_ seconds: TimeInterval) -> Darwin.timeval {
    Darwin.timeval(tv_sec: Int(seconds),
                   tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
}

let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
if descriptor < 0 { exit(0) }
defer { Darwin.close(descriptor) }

// Writing to a socket whose peer has closed raises SIGPIPE, and no exit code
// survives a signal. The listener DOES close early — it answers 413 on the
// declared length before the body has arrived — so without this a large payload
// kills this process and the agent sees a failed hook.
var on: Int32 = 1
setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
let pathBytes = Array(socketPath.utf8)
// `sun_path` is 104 bytes in `sys/un.h`. A longer path cannot be expressed, so
// there is nothing to connect to and nothing to say about it.
if pathBytes.count >= MemoryLayout.size(ofValue: address.sun_path) { exit(0) }
withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }

// Non-blocking for the connect, so the wait is OURS and bounded. A local
// `AF_UNIX` connect normally settles at once — ENOENT when the app is not
// running, ECONNREFUSED on a node a crash left behind — but a full listen
// backlog blocks, and that must not become the agent's problem.
let originalFlags = fcntl(descriptor, F_GETFL, 0)
_ = fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK)

let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}

if connected != 0 {
    // Anything other than "in progress" means there is nobody there. Silence is
    // the contract: coffee-bar not running is the normal state, and a hook that
    // complained on every tool call would be worse than useless.
    if errno != EINPROGRESS { exit(0) }

    var pending = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
    let milliseconds = Int32(remaining(cappedAt: HookShim.connectTimeout) * 1000)
    guard poll(&pending, 1, milliseconds) > 0 else { exit(0) }

    // `poll` reports the descriptor writable for a REFUSED connection too. The
    // pending error is the only thing that tells the two apart, and treating a
    // refusal as a success would post into nothing and then wait out the read.
    var pendingError: Int32 = 0
    var size = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &pendingError, &size) == 0,
          pendingError == 0
    else { exit(0) }
}

_ = fcntl(descriptor, F_SETFL, originalFlags)

// Blocking again, but with the rest of the deadline as the ceiling on each
// side. A zero timeout means "wait for ever" to the kernel, so a spent budget
// leaves now rather than blocking without a bound.
let writeBudget = remaining(cappedAt: HookShim.totalTimeout)
if writeBudget <= 0 { exit(0) }
var sendTimeout = timeval(writeBudget)
setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout,
           socklen_t(MemoryLayout<Darwin.timeval>.size))

let request = HookShim.request(posting: body, as: tool)
var written = 0
request.withUnsafeBytes { buffer in
    while written < buffer.count {
        let sent = Darwin.write(descriptor, buffer.baseAddress! + written, buffer.count - written)
        if sent <= 0 { break }
        written += sent
    }
}

// A write that stopped short is NOT a reason to leave. The listener refuses an
// over-cap request on the DECLARED length, before the body arrives: it answers
// 413 and closes while this process is still writing, so the write fails with
// EPIPE and the answer is already sitting in the receive buffer. Leaving here
// threw that answer away and the user saw nothing at all — which is how a
// payload that is silently never stored looks from the outside.
//
// Measured, not reasoned about: the end-to-end test for the cap failed on an
// empty stderr until this stopped exiting early.

// Half-close, so the listener sees the end of the request even though this
// process is still here to read the answer.
shutdown(descriptor, SHUT_WR)

let readBudget = remaining(cappedAt: HookShim.totalTimeout)
if readBudget <= 0 { exit(0) }
var receiveTimeout = timeval(readBudget)
setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout,
           socklen_t(MemoryLayout<Darwin.timeval>.size))

// Only the status line is wanted, so one small read is enough. `Connection:
// close` means there is no length to parse and nothing to keep reading for.
var answer = [UInt8](repeating: 0, count: 256)
let received = Darwin.read(descriptor, &answer, answer.count)

// A lost answer is NOT a failure to report. The event was written and may well
// have been stored; only the confirmation went missing, and saying so on every
// slow tool call would train the user to ignore this channel.
if received <= 0 { exit(0) }

let code = HookShim.statusCode(inResponse: Data(answer[0..<received]))
if !HookShim.isSuccess(code) {
    // The STATUS, never the payload. This diagnostic lands in the agent's own
    // log, which is the one place the listener's dropping cannot reach.
    warn("coffee-bar refused the event: \(code.map(String.init) ?? "no HTTP answer")")
}

exit(0)
