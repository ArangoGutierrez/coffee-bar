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

    One environment variable is read, and all it changes is how long THIS
    process waits for its own answer:

      \(HookShim.totalTimeoutVariable)
                       how long the whole run may take, in seconds. Defaults
                       to \(HookShim.totalTimeout). Anything unparseable, zero, negative or
                       above \(HookShim.maximumTotalTimeout) falls back to that default, in silence.

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

/// How long the whole run gets, after the environment has had its say.
///
/// `HookShim.resolvedTotalTimeout(from:)` holds the bounds and the reasons; the
/// shipped default is what runs unless a shell says otherwise, and every value
/// it cannot use falls back to that default in silence.
///
/// **The security shape of reading a variable here.** It buys TIME in a process
/// the invoking user already started with their own privileges, and nothing
/// else. It cannot widen privilege, name a different destination — `--socket=`
/// is the only thing that does that — change what is sent, or change what is
/// said about it: the diagnostic below still carries a status and never a
/// payload. The one abuse worth bounding is the opposite of a leak, and
/// `HookShim.maximumTotalTimeout` is what bounds it: this runs on EVERY tool
/// call, so a large value left in a shell profile would hold the agent up on
/// all of them.
let totalTimeout = HookShim.resolvedTotalTimeout(from: ProcessInfo.processInfo.environment)

/// The deadline for the whole run, fixed before the first syscall.
///
/// Every wait below takes what is LEFT of it, so the total cannot grow with the
/// number of steps.
let deadline = DispatchTime.now() + totalTimeout

// Every retry uses the same monotonic deadline, including interrupted calls.
func ready(_ fd: Int32, _ events: Int16, until limit: DispatchTime) -> Bool {
    while true {
        let now = DispatchTime.now().uptimeNanoseconds
        let end = limit.uptimeNanoseconds
        if now >= end { return false }
        let milliseconds = Int32(min((end - now + 999_999) / 1_000_000, UInt64(Int32.max)))
        var pending = pollfd(fd: fd, events: events, revents: 0)
        let result = poll(&pending, 1, milliseconds)
        if result > 0 { return true }
        if result == 0 || errno != EINTR { return false }
    }
}

// Read the whole body within the same budget. An over-cap body is dropped,
// never posted in part. Its contents are never included in diagnostics.
func readBody() -> Data? {
    let input = FileHandle.standardInput.fileDescriptor
    let flags = fcntl(input, F_GETFL, 0)
    guard flags >= 0, fcntl(input, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
    defer { _ = fcntl(input, F_SETFL, flags) }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while ready(input, Int16(POLLIN), until: deadline) {
        let count = Darwin.read(input, &buffer, buffer.count)
        if count == 0 { return body }
        if count < 0 {
            if errno == EINTR || errno == EAGAIN { continue }
            return nil
        }
        if count > HookShim.maximumRequestBytes - body.count {
            warn("event exceeds the size limit: 413")
            return nil
        }
        body.append(contentsOf: buffer[0..<count])
    }
    return nil
}
guard let body = readBody(), !body.isEmpty else { exit(0) }

// MARK: - Posting it

// The listener applies its limit to headers and body together.
let request = HookShim.request(posting: body, as: tool)
guard request.count <= HookShim.maximumRequestBytes else {
    warn("event exceeds the size limit: 413")
    exit(0)
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
guard originalFlags >= 0, fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else { exit(0) }

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

    let connectDeadline = min(deadline, DispatchTime.now() + HookShim.connectTimeout)
    guard ready(descriptor, Int16(POLLOUT), until: connectDeadline) else { exit(0) }

    // `poll` reports the descriptor writable for a REFUSED connection too. The
    // pending error is the only thing that tells the two apart, and treating a
    // refusal as a success would post into nothing and then wait out the read.
    var pendingError: Int32 = 0
    var size = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &pendingError, &size) == 0,
          pendingError == 0
    else { exit(0) }
}

var written = 0
request.withUnsafeBytes { buffer in
    while written < buffer.count {
        guard ready(descriptor, Int16(POLLOUT), until: deadline) else { break }
        let sent = Darwin.write(descriptor, buffer.baseAddress! + written, buffer.count - written)
        if sent < 0 {
            if errno == EINTR || errno == EAGAIN { continue }
            break
        }
        if sent == 0 { break }
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

// Collect a possibly fragmented status line, with a fixed memory bound.
var answer = [UInt8]()
var responseBuffer = [UInt8](repeating: 0, count: 256)
while answer.count < responseBuffer.count,
      ready(descriptor, Int16(POLLIN), until: deadline) {
    let received = Darwin.read(descriptor, &responseBuffer, responseBuffer.count - answer.count)
    if received < 0 {
        if errno == EINTR || errno == EAGAIN { continue }
        break
    }
    if received == 0 { break }
    answer.append(contentsOf: responseBuffer[0..<received])
    if answer.contains(10) { break }
}

// A lost answer is NOT a failure to report. The event was written and may well
// have been stored; only the confirmation went missing, and saying so on every
// slow tool call would train the user to ignore this channel.
if answer.isEmpty { exit(0) }

let code = HookShim.statusCode(inResponse: Data(answer))
if !HookShim.isSuccess(code) {
    // The STATUS, never the payload. This diagnostic lands in the agent's own
    // log, which is the one place the listener's dropping cannot reach.
    warn("coffee-bar refused the event: \(code.map(String.init) ?? "no HTTP answer")")
}

exit(0)
