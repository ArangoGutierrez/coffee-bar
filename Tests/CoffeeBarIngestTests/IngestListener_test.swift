// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import Darwin
import CoffeeBarCore
@testable import CoffeeBarIngest

/// A socket path inside a directory this test owns, and nothing else does.
///
/// Two constraints shape it.
///
/// `sun_path` is 104 bytes (`sys/un.h:79`) and the per-user temporary directory
/// is already 49 bytes on macOS, so the tail must stay short: `/cb-XXXXXX/i.sock`
/// adds 17, for 66. A UUID-named socket directly under the temporary directory
/// reaches 93 and a slightly longer temp root overflows.
///
/// Its OWN directory, never the shared temporary directory: `start()` sets the
/// socket's parent to 0700, and a test has no business changing the mode of a
/// directory it shares with the rest of the system.
private struct SocketSandbox {
    let directory: URL

    init() {
        let tag = String(UUID().uuidString.prefix(6)).lowercased()
        directory = FileManager.default.temporaryDirectory.appending(path: "cb-\(tag)")
    }

    var path: String { directory.appending(path: "i.sock").path }

    func makeDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    /// `stop()` deliberately leaves the socket node behind, so each test takes
    /// its own directory away with it.
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// A second directory this test owns, OUTSIDE the socket's 0700 parent.
///
/// It is where a symlink at the socket path points, and where a relocated
/// socket would land. 0755 on purpose: finding I2 is that the bind leaves the
/// one directory no other user can traverse, so the far end has to be a place
/// where that matters.
///
/// The same 104-byte `sun_path` budget applies. The per-user temporary
/// directory is 49 bytes and `/cb-rt-XXXXXX/r.sock` adds 20, for 69.
private struct RelocationTarget {
    let directory: URL

    init() {
        let tag = String(UUID().uuidString.prefix(6)).lowercased()
        directory = FileManager.default.temporaryDirectory.appending(path: "cb-rt-\(tag)")
    }

    var path: String { directory.appending(path: "r.sock").path }

    func makeDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private func mode(ofItemAtPath path: String) -> Int16? {
    (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
        as? NSNumber)??.int16Value
}

/// What kind of object sits at `path`, without following a symlink.
///
/// `attributesOfItem` is `lstat`-based, so a symlink answers
/// `.typeSymbolicLink` and never the type of its target. That distinction is
/// the whole of finding I2: a test that followed the link would report a socket
/// and never see that the socket is somewhere else.
private func fileType(ofItemAtPath path: String) -> FileAttributeType? {
    (try? FileManager.default.attributesOfItem(atPath: path)[.type]) as? FileAttributeType
}

/// The longest a post may take before the test stops waiting for it.
///
/// Bounding this is not tidiness. `curl` with no limit waits for an answer for
/// ever, and a listener that is bound but not being SERVED gives it none: the
/// node is in the listen backlog, so the connection succeeds and then nothing
/// arrives. Measured, that hung one test body permanently and took the whole run
/// with it — 375 tests started, 318 finished, and the run had to be killed after
/// ten minutes with no failure reported at all.
///
/// Sixty seconds is far longer than any post here needs. The exchange is one
/// small POST over a local socket, and even under the CPU oversubscription that
/// `pumpBudget` is sized for the whole suite finishes in about 150 s. A post
/// that reaches this limit reports `curl` exit 28.
private let postTimeoutSeconds = "60"

/// Posts one payload the way a real hook does. `/usr/bin/curl` ships with macOS.
///
/// Returns `curl`'s exit status: 0 on success, 7 when the socket could not be
/// connected to, and 28 when the listener accepted the connection and never
/// answered within `postTimeoutSeconds`.
@discardableResult
private func post(_ json: String, to socketPath: String) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = ["--silent", "--show-error", "--fail",
                         "--max-time", postTimeoutSeconds,
                         "--unix-socket", socketPath,
                         "-X", "POST",
                         "-H", "Content-Type: application/json",
                         "--data", json,
                         "http://localhost/ingest"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

/// Posts a body that is too large to pass through `argv`.
///
/// `ARG_MAX` is 1 MiB on macOS (`getconf ARG_MAX`) and bounds the arguments and
/// the environment TOGETHER, so a body near the 1 MiB request cap cannot ride on
/// the command line the way `post(_:to:)` sends one. The payload goes to a file
/// instead.
///
/// `--data-binary` rather than `--data`: `--data` strips newlines, and a test
/// about exact framing must send exactly the bytes on disk.
@discardableResult
private func post(contentsOfFile path: String, to socketPath: String) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = ["--silent", "--show-error", "--fail",
                         "--max-time", postTimeoutSeconds,
                         "--unix-socket", socketPath,
                         "-X", "POST",
                         "-H", "Content-Type: application/json",
                         "--data-binary", "@\(path)",
                         "http://localhost/ingest"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

/// A raw `AF_UNIX` client, for the two things `curl` cannot express: a half-open
/// connection that sends an incomplete header and then waits, and a direct look
/// at whether the server has closed its end.
private final class RawClient {
    private let descriptor: Int32

    init?(path: String) {
        let opened = socket(AF_UNIX, SOCK_STREAM, 0)
        guard opened >= 0 else { return nil }

        // Without this, writing to a socket the server has already closed
        // raises SIGPIPE and takes the whole test process down with it.
        var on: Int32 = 1
        setsockopt(opened, SOL_SOCKET, SO_NOSIGPIPE, &on,
                   socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(opened)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(opened, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(opened)
            return nil
        }
        descriptor = opened
    }

    func transmit(_ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer {
            Darwin.send(descriptor, $0.baseAddress, $0.count, 0)
        }
    }

    /// True once the server has closed its end of the connection.
    var peerClosed: Bool {
        var byte: UInt8 = 0
        let received = recv(descriptor, &byte, 1, Int32(MSG_DONTWAIT))
        if received == 0 { return true }
        if received < 0 { return !(errno == EAGAIN || errno == EWOULDBLOCK) }
        return false
    }

    func close() { Darwin.close(descriptor) }
}

/// Binds a raw `AF_UNIX` listening socket at `path`, the way a FOREIGN process
/// would: it unlinks whatever is there and takes the path for itself.
///
/// Deliberately NOT a second `UnixSocketIngestListener`. `start()` refuses to
/// steal a live node, so this listener can no longer reproduce the scenario the
/// file documents at the `occupant` call site — a second instance that unlinked
/// and rebound, leaving the first one `.ready` on an unlinked inode and deaf
/// for ever. Another program under the same account is under no such rule.
private final class ForeignListener {
    private let descriptor: Int32

    init?(takingOver path: String) {
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

        // `bind` fails with EADDRINUSE on an existing node, so the path has to
        // be cleared first. That unlink is the whole attack.
        Darwin.unlink(path)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(opened, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(opened, 1) == 0 else {
            Darwin.close(opened)
            return nil
        }
        descriptor = opened
    }

    func close() { Darwin.close(descriptor) }
}

/// Collects what the listener delivered, across the queue boundary.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [HookEvent] = []
    private var mainThread: [Bool] = []

    func record(_ event: HookEvent, onMain: Bool) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
        mainThread.append(onMain)
    }

    var all: [HookEvent] { lock.lock(); defer { lock.unlock() }; return events }
    var everyDeliveryWasOnMain: Bool {
        lock.lock(); defer { lock.unlock() }
        return !mainThread.isEmpty && mainThread.allSatisfy { $0 }
    }
}

/// How long every wait in this file gets, unless it states its own budget.
///
/// Five seconds was the old value and it was measured to be too short. On this
/// 14-core machine with 56 CPU burners running — roughly the pressure a 3-core
/// CI runner is under — the suite took 153 s where it takes 3.9 s idle, and NINE
/// tests in this file failed purely because a 5 s wait for the bind expired.
///
/// A generous budget is close to free. Every default-budget wait here is for
/// something that MUST happen, so a passing test leaves the loop as soon as the
/// condition holds and never spends the budget. Only an already-failing test
/// pays, and it pays in exchange for naming its real cause. The one wait for a
/// condition that must NEVER hold states its own short budget, and must keep
/// doing so.
private let pumpBudget: TimeInterval = 30

/// Waits until `condition` holds or the deadline passes.
///
/// NEVER on the main thread. That is enforced below rather than merely written
/// here, because the failure it prevents is silent and total.
///
/// Measured in this package, not assumed. Marking any test in this file
/// `@MainActor` makes `Thread.isMainThread` true here. This helper used to turn
/// the run loop over in that case, and inside the `swift test` process that does
/// not drain `DispatchQueue.main` at all: a bare `DispatchQueue.main.async`
/// block enqueued just before the wait never ran, and the listener never
/// reported `.ready`, so the whole budget went by.
///
/// What follows is worse than one slow test. `NWListener` binds on its own
/// internal queue, so the socket node DOES appear — measured at mode 0755,
/// because the handler that tightens it to 0600 is delivered to `.main` and
/// never runs. `curl` then connects into the listen backlog and waits for an
/// answer that cannot come, so the test body never returns and the main thread
/// is held for ever. One such test wedged the entire run: 375 tests started, 318
/// finished, killed after ten minutes with no failure reported.
///
/// The deleted branch is not wrong everywhere — in a plain executable, where the
/// Swift runtime does run a CFRunLoop on the main thread, the same code drains
/// the main queue correctly. That is the point. Its correctness depends on who
/// owns the main thread, which a test cannot know, so the branch is gone and a
/// trap that names the cause stands in its place.
private func pump(until condition: () -> Bool, seconds: TimeInterval = pumpBudget) {
    precondition(!Thread.isMainThread, """
        pump() ran on the main thread. Every listener in this file serves on \
        DispatchQueue.main, and waiting here never lets that queue run, so this \
        wait cannot end and the run will wedge. Remove @MainActor from the test \
        that called this.
        """)
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
}

/// Waits for the listener to bind, and SAYS SO when it does not.
///
/// Every test below needs a bound socket before it can measure anything. When
/// the bind did not happen, the old `pump(until: { listener.isReady })` said
/// nothing and the next assertion reported the consequence as if it were the
/// cause. Measured under load, all nine failures in this file read that way:
///
/// - `socket mode is absent` — reads as a permissions defect. The listener had
///   simply not bound.
/// - `an error was expected but none was thrown` — reads as the guard against
///   stealing a live node being gone. The first listener had not bound, so the
///   second one correctly found the path free.
/// - `RawClient(path:) -> nil` — reads as a refused connection. There was no
///   node to connect to.
///
/// The first of those is why this is a `#require` and not an `#expect`. A
/// maintainer triaging `socket mode is absent` hunts a permissions defect that
/// does not exist. A test with no socket has nothing left to say, so it stops
/// here and names the one thing that did go wrong.
private func requireReady(_ listener: UnixSocketIngestListener,
                          within seconds: TimeInterval = pumpBudget,
                          sourceLocation: SourceLocation = #_sourceLocation) throws {
    pump(until: { listener.isReady }, seconds: seconds)
    try #require(listener.isReady,
                 """
                 the listener did not bind within \(seconds) s. Nothing below \
                 this line had a socket to measure, so this is a timeout and \
                 not a defect in what the test asserts.
                 """,
                 sourceLocation: sourceLocation)
}

/// Waits for the node at `path` to stop answering.
///
/// `stop()` cancels the `NWListener` asynchronously, so the node keeps accepting
/// for a moment after the call returns.
private func waitUntilNothingAnswers(at path: String) {
    pump(until: {
        guard let client = RawClient(path: path) else { return true }
        client.close()
        return false
    })
}

// MARK: - Delivery

@Test func aPostedPayloadArrivesAsADecodedEvent() throws {
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    let collected = Collected()
    let listener = UnixSocketIngestListener(socketPath: sandbox.path)
    defer { listener.stop() }

    try listener.start { event in
        collected.record(event, onMain: Thread.isMainThread)
    }
    try requireReady(listener)

    #expect(try post(#"{"hook_event_name":"Stop","session_id":"s1"}"#, to: sandbox.path) == 0)
    pump(until: { !collected.all.isEmpty })

    let event = try #require(collected.all.first)
    #expect(event.hookEventName == "Stop")
    #expect(event.sessionID == "s1")
}

@Test func deliveryHappensOnTheMainThread() throws {
    // Load-bearing, and a runtime TRAP rather than a warning if it breaks.
    // `ServingModel` reaches the main actor from this callback with
    // `MainActor.assumeIsolated`, matching the discipline `startMonitoring`
    // already uses. Delivering from any other queue crashes the app.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    let collected = Collected()
    let listener = UnixSocketIngestListener(socketPath: sandbox.path)
    defer { listener.stop() }
    try listener.start { event in
        collected.record(event, onMain: Thread.isMainThread)
    }
    try requireReady(listener)

    #expect(try post(#"{"hook_event_name":"Stop","session_id":"s1"}"#, to: sandbox.path) == 0)
    pump(until: { !collected.all.isEmpty })

    #expect(collected.everyDeliveryWasOnMain)
}

@Test func anUndecodablePayloadDeliversNothingAndDoesNotKillTheListener() throws {
    // Named bug this catches: a decode failure that cancels the listener. One
    // malformed post would then silently stop ingest for the rest of the
    // session, and the panel would keep looking healthy.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    let collected = Collected()
    let listener = UnixSocketIngestListener(socketPath: sandbox.path)
    defer { listener.stop() }
    try listener.start { event in
        collected.record(event, onMain: Thread.isMainThread)
    }
    try requireReady(listener)

    _ = try post("not json at all", to: sandbox.path)
    _ = try post(#"{"hook_event_name":"Stop","session_id":"good"}"#, to: sandbox.path)
    pump(until: { !collected.all.isEmpty })

    #expect(collected.all.map(\.sessionID) == ["good"])
}

@Test func aNegativeContentLengthDoesNotTakeTheListenerDown() throws {
    // PE finding B1, end to end. `curl` will not send a negative
    // `Content-Length`, so this is posted raw. Before the framer validated the
    // declared length this trapped inside the receive callback and killed the
    // whole process — which, in the shipped app, releases the power assertion
    // and lets the machine sleep under a running agent.
    //
    // The assertion is not the 400: it is that a REAL post still works
    // afterwards. A dead process cannot answer the second one.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    let collected = Collected()
    let listener = UnixSocketIngestListener(socketPath: sandbox.path)
    defer { listener.stop() }
    try listener.start { event in
        collected.record(event, onMain: Thread.isMainThread)
    }
    try requireReady(listener)

    let attacker = try #require(RawClient(path: sandbox.path))
    attacker.transmit("POST /ingest HTTP/1.1\r\nHost: localhost\r\nContent-Length: -1\r\n\r\n")
    pump(until: { attacker.peerClosed })
    attacker.close()

    #expect(try post(#"{"hook_event_name":"Stop","session_id":"survivor"}"#,
                     to: sandbox.path) == 0)
    pump(until: { !collected.all.isEmpty })
    #expect(collected.all.map(\.sessionID) == ["survivor"])
}

// MARK: - The filesystem is the authenticator

@Test func theSocketIsNotReadableByOtherUsers() throws {
    // Design §4: the filesystem is the authenticator. There is no token, so the
    // mode IS the access control.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    let listener = UnixSocketIngestListener(socketPath: sandbox.path)
    defer { listener.stop() }
    try listener.start { _ in }
    try requireReady(listener)

    #expect(mode(ofItemAtPath: sandbox.path) == 0o600,
            "socket mode is \(mode(ofItemAtPath: sandbox.path).map { String($0, radix: 8) } ?? "absent")")
}

@Test func theParentDirectoryIsNotTraversableByOtherUsers() throws {
    // Measured, not assumed: a bare bind under umask 022 creates the node at
    // 0755, and the change to 0600 lands only once the listener reports
    // `.ready`. Any local user can connect inside that window. A 0700 parent
    // directory closes it outright, because no other user can reach the node.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    let listener = UnixSocketIngestListener(socketPath: sandbox.path)
    defer { listener.stop() }
    try listener.start { _ in }
    try requireReady(listener)

    #expect(mode(ofItemAtPath: sandbox.directory.path) == 0o700,
            "parent directory mode is \(mode(ofItemAtPath: sandbox.directory.path).map { String($0, radix: 8) } ?? "absent")")
}

@Test func anExistingParentDirectoryIsTightenedRatherThanLeftOpen() throws {
    // `createDirectory` applies its attributes only when it CREATES the
    // directory. Named bug this catches: a first run under a wider umask, or a
    // directory the user made by hand, leaving the socket reachable by every
    // local account for the life of the install.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    try FileManager.default.createDirectory(
        at: sandbox.directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755])
    #expect(mode(ofItemAtPath: sandbox.directory.path) == 0o755,
            "the directory did not start wide open; this test would prove nothing")

    let listener = UnixSocketIngestListener(socketPath: sandbox.path)
    defer { listener.stop() }
    try listener.start { _ in }
    try requireReady(listener)

    #expect(mode(ofItemAtPath: sandbox.directory.path) == 0o700)
}

// MARK: - Owning the node (PE finding B2)

@Test func stopLeavesTheSocketNodeInPlace() throws {
    // PE finding B2. `stop()` used to unlink the path unconditionally, and
    // measured, the node at that path is not always ours: a second instance had
    // already rebound it, so the orphan's `stop()` deleted the LIVE node of the
    // instance that replaced it. Ingest was then dead while the app looked
    // healthy.
    //
    // Nothing is lost by leaving it. `start()` removes a node nothing answers
    // on, which `aNodeLeftByAStoppedListenerIsReclaimedByTheNextStart` proves.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    let listener = UnixSocketIngestListener(socketPath: sandbox.path)
    try listener.start { _ in }
    try requireReady(listener)
    #expect(FileManager.default.fileExists(atPath: sandbox.path))

    listener.stop()
    waitUntilNothingAnswers(at: sandbox.path)

    #expect(FileManager.default.fileExists(atPath: sandbox.path),
            "stop() unlinked the socket node; a live node owned by another instance would go with it")
}

@Test func aSecondListenerRefusesToStealALiveNode() throws {
    // The other half of B2, reproduced end to end before the fix: instance B
    // removed A's node and bound its own. A stayed `.ready` on an unlinked
    // inode and received nothing, forever, with no error at all.
    //
    // The assertion that matters is the last one. A throw would be worth little
    // if the first listener had already been made deaf.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    let collected = Collected()

    let first = UnixSocketIngestListener(socketPath: sandbox.path)
    defer { first.stop() }
    try first.start { event in collected.record(event, onMain: Thread.isMainThread) }
    try requireReady(first)

    let second = UnixSocketIngestListener(socketPath: sandbox.path)
    #expect(throws: IngestError.alreadyServing(sandbox.path)) {
        try second.start { _ in }
    }

    #expect(try post(#"{"hook_event_name":"Stop","session_id":"first"}"#,
                     to: sandbox.path) == 0)
    pump(until: { !collected.all.isEmpty })
    #expect(collected.all.map(\.sessionID) == ["first"],
            "the first listener stopped receiving after the second one started")
}

@Test func aNodeLeftByAStoppedListenerIsReclaimedByTheNextStart() throws {
    // Because `stop()` no longer unlinks, the connect probe has to tell a dead
    // node from a live one. Named bug this catches: a probe that reads mere
    // EXISTENCE as ownership, which would leave ingest permanently refusing to
    // start after the first ordinary quit.
    //
    // Measured on macOS: connecting to a bound node whose owner has gone gives
    // ECONNREFUSED, and a live one connects.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }

    let first = UnixSocketIngestListener(socketPath: sandbox.path)
    try first.start { _ in }
    try requireReady(first)
    first.stop()
    waitUntilNothingAnswers(at: sandbox.path)
    #expect(FileManager.default.fileExists(atPath: sandbox.path),
            "no node was left behind; the reclaim below would prove nothing")

    let collected = Collected()
    let second = UnixSocketIngestListener(socketPath: sandbox.path)
    defer { second.stop() }
    try second.start { event in collected.record(event, onMain: Thread.isMainThread) }
    try requireReady(second)

    #expect(try post(#"{"hook_event_name":"Stop","session_id":"second"}"#,
                     to: sandbox.path) == 0)
    pump(until: { !collected.all.isEmpty })
    #expect(collected.all.map(\.sessionID) == ["second"])
}

@Test func aStaleSocketFileDoesNotStopTheNextStart() throws {
    // The app is force-quit and something is left at the path. Named bug this
    // catches: a bind that fails on the leftover file, so ingest never comes
    // back until the user deletes a file they do not know about.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    try sandbox.makeDirectory()
    FileManager.default.createFile(atPath: sandbox.path, contents: Data("stale".utf8))
    #expect(FileManager.default.fileExists(atPath: sandbox.path))

    let listener = UnixSocketIngestListener(socketPath: sandbox.path)
    defer { listener.stop() }
    try listener.start { _ in }
    try requireReady(listener)

    #expect(mode(ofItemAtPath: sandbox.path) == 0o600)
}

@Test func aDirectoryAtTheSocketPathIsRefusedRatherThanDeleted() throws {
    // `start()` clears what it finds at the socket path. Measured: connecting to
    // a DIRECTORY gives ENOTSOCK — the same errno a leftover regular file gives
    // — so a directory would reach `removeItem`, and `removeItem` on a directory
    // takes everything under it.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    try FileManager.default.createDirectory(atPath: sandbox.path,
                                            withIntermediateDirectories: true)
    let witness = (sandbox.path as NSString).appendingPathComponent("keep.txt")
    FileManager.default.createFile(atPath: witness, contents: Data("keep".utf8))

    let listener = UnixSocketIngestListener(socketPath: sandbox.path)
    defer { listener.stop() }
    #expect(throws: IngestError.socketPathBlocked(sandbox.path)) {
        try listener.start { _ in }
    }
    #expect(FileManager.default.fileExists(atPath: witness),
            "start() deleted a directory it found at the socket path")
}

// MARK: - A symlink at the socket path (audit finding I2)

@Test func aDanglingSymlinkAtTheSocketPathDoesNotRelocateTheLiveSocket() throws {
    // Audit finding I2, measured deterministically over three runs of three.
    // `fileExists` FOLLOWS a symlink, so a DANGLING one reads as nothing at
    // all: the directory branch was skipped, `connect` gave ENOENT, and the
    // probe answered `.absent`. `.absent` removes nothing, so `NWListener`
    // bound THROUGH the link and the live socket was created at the link's
    // TARGET. Every POST was then served from there, and `isReady` said yes.
    //
    // The harm is the loss of defence in depth, not a wide standing hole. The
    // 0755 bind window is NOT created by the link: a control with no link shows
    // the same two modes, and the window measured 0.2 ms. What the link does is
    // move that known window OUT of the 0700 directory that closes it.
    //
    // `theParentDirectoryIsNotTraversableByOtherUsers` cannot catch this. It
    // measures the CONFIGURED parent, which stays 0700 while the socket lives
    // somewhere else entirely.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    try sandbox.makeDirectory()
    let target = RelocationTarget()
    defer { target.remove() }
    try target.makeDirectory()

    try FileManager.default.createSymbolicLink(atPath: sandbox.path,
                                               withDestinationPath: target.path)
    #expect(!FileManager.default.fileExists(atPath: target.path),
            "the link is not dangling; this test would measure a different case")

    let collected = Collected()
    let listener = UnixSocketIngestListener(socketPath: sandbox.path)
    defer { listener.stop() }
    try listener.start { event in collected.record(event, onMain: Thread.isMainThread) }
    try requireReady(listener)

    #expect(!FileManager.default.fileExists(atPath: target.path),
            "the live socket was created at the link's target, outside the 0700 directory")
    #expect(fileType(ofItemAtPath: sandbox.path) == .typeSocket,
            "the configured path is \(fileType(ofItemAtPath: sandbox.path)?.rawValue ?? "absent"), not a socket")

    // The recovery has to be complete, not merely safe. A fix that refused to
    // start would also keep the socket out of the target directory.
    #expect(try post(#"{"hook_event_name":"Stop","session_id":"here"}"#,
                     to: sandbox.path) == 0)
    pump(until: { !collected.all.isEmpty })
    #expect(collected.all.map(\.sessionID) == ["here"])
}

@Test func aDanglingSymlinkThatCannotBeRemovedIsRefusedRatherThanFollowed() throws {
    // `removeItem` is called as `try?`, so its error is dropped. That is right
    // — the node may legitimately have gone by itself between the probe and the
    // delete — but it means the RETURN says nothing about what is at the path.
    //
    // Named bug this catches: the delete fails, nothing notices, and the bind
    // goes THROUGH the surviving link. That is the relocation of finding I2
    // again, reached by a different route. `UF_IMMUTABLE` is a USER flag: any
    // process running as this account can set it on its own link, and no
    // special privilege is needed.
    //
    // Refusing is the only honest answer here. Recovery is what makes `.stale`
    // the right classification for a dangling link, and when the recovery
    // cannot happen there is nothing left to prefer it for.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    try sandbox.makeDirectory()
    let target = RelocationTarget()
    defer { target.remove() }
    try target.makeDirectory()

    try FileManager.default.createSymbolicLink(atPath: sandbox.path,
                                               withDestinationPath: target.path)
    // Registered AFTER the directory cleanups, so it runs BEFORE them: an
    // immutable link cannot be deleted, and the sandbox would outlive the run.
    defer { lchflags(sandbox.path, 0) }
    #expect(lchflags(sandbox.path, UInt32(UF_IMMUTABLE)) == 0,
            "lchflags failed, errno \(errno); this test would prove nothing")

    // The flag has to really stop the delete on this machine. Without this the
    // refusal below could not be told apart from `lchflags` doing nothing.
    try? FileManager.default.removeItem(atPath: sandbox.path)
    #expect(fileType(ofItemAtPath: sandbox.path) == .typeSymbolicLink,
            "UF_IMMUTABLE did not stop the delete; this test would prove nothing")

    let listener = UnixSocketIngestListener(socketPath: sandbox.path)
    defer { listener.stop() }
    #expect(throws: IngestError.socketPathBlocked(sandbox.path)) {
        try listener.start { _ in }
    }

    // A short budget of its own, because this condition must NEVER hold.
    // `start()` returning is not the bind: `NWListener` binds asynchronously,
    // so reading the far end straight away would pass before a relocation had
    // had time to appear, and the assertion would measure nothing.
    pump(until: { FileManager.default.fileExists(atPath: target.path) }, seconds: 2)
    #expect(!FileManager.default.fileExists(atPath: target.path),
            "the bind went through the link that survived the delete")
}

@Test func aSymlinkToAnUnservedSocketIsClearedRatherThanFollowed() throws {
    // One of the three symlink cases that were already correct before I2 was
    // fixed. Connecting through the link reaches a bound node whose owner has
    // gone, which gives ECONNREFUSED, so the probe says `.stale`. `removeItem`
    // does not follow a symlink, so it takes the LINK and the far end survives.
    //
    // Named bug this catches: a fix for the dangling case that reclassifies
    // EVERY symlink, leaving the app refusing to start on a path it used to
    // reclaim without help.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    let target = RelocationTarget()
    defer { target.remove() }
    try target.makeDirectory()

    // An unserved socket node. `stop()` leaves one behind on purpose.
    let dead = UnixSocketIngestListener(socketPath: target.path)
    try dead.start { _ in }
    try requireReady(dead)
    dead.stop()
    waitUntilNothingAnswers(at: target.path)
    #expect(fileType(ofItemAtPath: target.path) == .typeSocket,
            "no unserved socket node was left; this test would measure a different case")

    try sandbox.makeDirectory()
    try FileManager.default.createSymbolicLink(atPath: sandbox.path,
                                               withDestinationPath: target.path)

    let listener = UnixSocketIngestListener(socketPath: sandbox.path)
    defer { listener.stop() }
    try listener.start { _ in }
    try requireReady(listener)

    #expect(fileType(ofItemAtPath: sandbox.path) == .typeSocket,
            "the configured path is \(fileType(ofItemAtPath: sandbox.path)?.rawValue ?? "absent"), not a socket")
    #expect(FileManager.default.fileExists(atPath: target.path),
            "removeItem followed the link and deleted the node at the far end")
}

@Test func aSymlinkToARegularFileIsClearedRatherThanFollowed() throws {
    // The second already-correct case. ENOTSOCK through the link, so `.stale`,
    // and again `removeItem` takes the link. The file at the far end surviving
    // is what proves the link was not followed.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    let target = RelocationTarget()
    defer { target.remove() }
    try target.makeDirectory()
    FileManager.default.createFile(atPath: target.path, contents: Data("keep".utf8))

    try sandbox.makeDirectory()
    try FileManager.default.createSymbolicLink(atPath: sandbox.path,
                                               withDestinationPath: target.path)

    let listener = UnixSocketIngestListener(socketPath: sandbox.path)
    defer { listener.stop() }
    try listener.start { _ in }
    try requireReady(listener)

    #expect(fileType(ofItemAtPath: sandbox.path) == .typeSocket,
            "the configured path is \(fileType(ofItemAtPath: sandbox.path)?.rawValue ?? "absent"), not a socket")
    #expect(FileManager.default.contents(atPath: target.path) == Data("keep".utf8),
            "removeItem followed the link and deleted the file at the far end")
}

@Test func aSymlinkToADirectoryAtTheSocketPathIsRefusedRatherThanDeleted() throws {
    // The third already-correct case. `fileExists` FOLLOWS the link and reports
    // a directory, so the probe says `.blocked` and `start()` throws.
    //
    // Named bug this catches: a fix for the dangling case placed BEFORE the
    // directory branch, which would send a link to a directory to `removeItem`.
    // The link itself would go, and on the next run the same path would be a
    // plain directory the existing guard already refuses — but the app would
    // have silently thrown away the user's link either way.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    let target = RelocationTarget()
    defer { target.remove() }
    try target.makeDirectory()
    let witness = target.directory.appending(path: "keep.txt").path
    FileManager.default.createFile(atPath: witness, contents: Data("keep".utf8))

    try sandbox.makeDirectory()
    try FileManager.default.createSymbolicLink(atPath: sandbox.path,
                                               withDestinationPath: target.directory.path)

    let listener = UnixSocketIngestListener(socketPath: sandbox.path)
    defer { listener.stop() }
    #expect(throws: IngestError.socketPathBlocked(sandbox.path)) {
        try listener.start { _ in }
    }
    #expect(FileManager.default.fileExists(atPath: witness),
            "start() reached a directory through the link and deleted what was under it")
    #expect(fileType(ofItemAtPath: sandbox.path) == .typeSymbolicLink,
            "start() deleted the link it refused to follow")
}

// MARK: - isReady answers for now (audit finding I3)

@Test func isReadyIsFalseOnceTheSocketNodeIsGone() throws {
    // Audit finding I3. `ready` is written at exactly three sites — the
    // initialiser, the `.ready` state, and `stop()` — so `stop()` was the only
    // thing that ever cleared it, and a vanished node left it true.
    //
    // Named bug this catches: the user deletes the node, `curl` fails at exit
    // 7, every agent event is lost, and the panel reports NO problem, because
    // `ServingModel` sets `ingestListening = listener.isReady` and
    // `ingestAdvisory` then returns nil.
    //
    // Deleting it by hand is a plausible act, not a contrived one: `stop()`
    // deliberately leaves stale nodes behind, so tidying one up is exactly what
    // the app's own behaviour invites.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    let listener = UnixSocketIngestListener(socketPath: sandbox.path)
    defer { listener.stop() }
    try listener.start { _ in }
    try requireReady(listener)

    try FileManager.default.removeItem(atPath: sandbox.path)

    // Measured rather than assumed, and measured FIRST: if a post still
    // succeeded, the answer below would be about nothing.
    #expect(try post(#"{"hook_event_name":"Stop","session_id":"lost"}"#,
                     to: sandbox.path) != 0,
            "the node was still being served; this test would measure a different case")
    #expect(!listener.isReady,
            "isReady answered for a past start(); nothing can post and the panel shows no problem")
}

@Test func isReadyIsFalseWhenTheSocketPathHoldsSomethingThatIsNotASocket() throws {
    // The node can be REPLACED as well as removed, and the replacement is what
    // separates two candidate fixes. Named bug this catches: an `isReady` that
    // asks only whether SOMETHING exists at the path. A regular file answers
    // that question yes while no connection can be made through it.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    let listener = UnixSocketIngestListener(socketPath: sandbox.path)
    defer { listener.stop() }
    try listener.start { _ in }
    try requireReady(listener)

    try FileManager.default.removeItem(atPath: sandbox.path)
    FileManager.default.createFile(atPath: sandbox.path, contents: Data("not a socket".utf8))
    #expect(FileManager.default.fileExists(atPath: sandbox.path),
            "nothing took the path; this test would measure the removal case instead")

    #expect(try post(#"{"hook_event_name":"Stop","session_id":"lost"}"#,
                     to: sandbox.path) != 0,
            "the path was still being served; this test would measure a different case")
    #expect(!listener.isReady,
            "isReady treats any node at the path as proof of serving")
}

@Test func isReadyIsFalseAfterAnotherProgramTakesThePath() throws {
    // The most documented I3 case in this file, and the one a type check cannot
    // see. The comment at the `occupant` call site records it as measured: a
    // second binder unlinks the node and binds its own, and this listener stays
    // `.ready` on an unlinked inode, deaf for ever and with no error to report.
    //
    // A socket IS at the path afterwards, and it answers connections, so
    // "something of the right type is there" says healthy. Only the identity of
    // the node can tell the two apart.
    //
    // Named bug this catches: the panel reports serving while every event goes
    // to somebody else's socket.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    let listener = UnixSocketIngestListener(socketPath: sandbox.path)
    defer { listener.stop() }
    try listener.start { _ in }
    try requireReady(listener)

    let foreign = try #require(ForeignListener(takingOver: sandbox.path),
                               "the path could not be taken over; nothing below would be measured")
    defer { foreign.close() }

    // Both preconditions matter. The first proves a real socket node is at the
    // path, and the second proves it ANSWERS — so no probe of any kind, not
    // even a connection attempt, could report this path as dead.
    #expect(fileType(ofItemAtPath: sandbox.path) == .typeSocket,
            "the path holds \(fileType(ofItemAtPath: sandbox.path)?.rawValue ?? "nothing"), not a socket")
    let probe = try #require(RawClient(path: sandbox.path),
                             "the node at the path refuses connections; this is a different case")
    probe.close()

    #expect(!listener.isReady,
            "isReady reports serving while the node at the path belongs to another program")
}

@Test func isReadyIsFalseWhenASymlinkTakesThePathToOurOwnSocket() throws {
    // The guard for `lstat` over `stat` inside `isReady`, which nothing else
    // measures. Every other case reads the same through either call: a removed
    // node is absent both ways, and a regular file is the wrong type both ways.
    //
    // This case separates them. The live socket node is MOVED and a link is put
    // in its place, so the path still resolves to the very same inode. `stat`
    // follows the link and reports this listener's own socket, identity and
    // all. `lstat` sees the link.
    //
    // False is the right answer even though the socket still serves through the
    // link. The node has left the 0700 directory, which is the whole access
    // control of design §4. Answering true would report a security property the
    // app no longer has.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    let target = RelocationTarget()
    defer { target.remove() }
    try target.makeDirectory()

    let listener = UnixSocketIngestListener(socketPath: sandbox.path)
    defer { listener.stop() }
    try listener.start { _ in }
    try requireReady(listener)

    try FileManager.default.moveItem(atPath: sandbox.path, toPath: target.path)
    try FileManager.default.createSymbolicLink(atPath: sandbox.path,
                                               withDestinationPath: target.path)
    #expect(fileType(ofItemAtPath: target.path) == .typeSocket,
            "the socket node did not move; this test would measure a different case")

    #expect(!listener.isReady,
            "isReady followed the link and answered for a node that is no longer at the path")
}

@Test func startingAListenerThatIsAlreadyServingThrows() throws {
    // The same-instance case. Named bug this catches: a second `start()` that
    // silently does nothing and leaves the caller's NEW handler unwired, so
    // events keep going to a closure the caller has already replaced.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    let listener = UnixSocketIngestListener(socketPath: sandbox.path)
    defer { listener.stop() }
    try listener.start { _ in }
    try requireReady(listener)

    #expect(throws: IngestError.alreadyServing(sandbox.path)) {
        try listener.start { _ in }
    }
}

// MARK: - Bounded connections (PE finding M1)

@Test func aHalfOpenConnectionIsClosedOnceTheIdleTimeoutPasses() throws {
    // Named bug this catches: a connection that opens, sends half a header and
    // then says nothing, parking a slot forever. The receive loop ends only on a
    // complete frame, on `isComplete`, or on an error, and a silent peer
    // produces none of the three.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    let listener = UnixSocketIngestListener(socketPath: sandbox.path,
                                            idleTimeout: 0.5)
    defer { listener.stop() }
    try listener.start { _ in }
    try requireReady(listener)

    let client = try #require(RawClient(path: sandbox.path))
    defer { client.close() }
    client.transmit("POST /ingest HTTP/1.1\r\nHost: localhost\r\n")

    pump(until: { client.peerClosed })
    #expect(client.peerClosed, "the listener parked a half-open connection forever")
}

@Test func aConnectionOverTheCapIsRefusedAndTheOnesUnderItSurvive() throws {
    // The cap is per-listener, not per-connection: `HTTPRequestFramer`'s 64 KiB
    // bounds ONE request, and nothing bounded how many could be in flight.
    //
    // The idle timeout is set long on purpose, so the only thing that can close
    // the third connection is the cap.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    let listener = UnixSocketIngestListener(socketPath: sandbox.path,
                                            idleTimeout: 60,
                                            maximumConnections: 2)
    defer { listener.stop() }
    try listener.start { _ in }
    try requireReady(listener)

    var parked: [RawClient] = []
    defer { parked.forEach { $0.close() } }
    for _ in 0..<2 {
        let client = try #require(RawClient(path: sandbox.path))
        client.transmit("POST /ingest HTTP/1.1\r\nHost: localhost\r\n")
        parked.append(client)
    }
    // Both must be ADMITTED before the third arrives, or this measures a race
    // rather than the cap.
    //
    // Commit `d6dafb2` raised the budget for `extra.peerClosed` below to 30 s
    // because a loaded 3-core runner could not close a connection inside 5 s.
    // This wait sits EARLIER in the same test and had kept the 5 s default, so
    // on that same runner it expired first and masked the fix outright.
    //
    // A `#require`, because the assertions below are only about the cap once
    // this holds. The message has to separate the two readings: a cap of 2
    // cannot refuse the FIRST two connections, so a count under 2 here is the
    // runner being slow and never the cap being wrong.
    let admitBudget: TimeInterval = 30
    pump(until: { listener.activeConnectionCount == 2 }, seconds: admitBudget)
    try #require(listener.activeConnectionCount == 2,
                 """
                 only \(listener.activeConnectionCount) of 2 connections were \
                 admitted within \(admitBudget) s. The cap is not implicated — \
                 a cap of 2 admits the first two — so this is a slow runner, \
                 and the refusal measured below would have been a race.
                 """)

    let extra = try #require(RawClient(path: sandbox.path))
    defer { extra.close() }
    extra.transmit("POST /ingest HTTP/1.1\r\nHost: localhost\r\n")

    // `peerClosed` is a CLIENT-side observation of a close that has to cross
    // Network.framework's async cancellation and then the socket. On this
    // 14-core machine it lands in milliseconds; on the 3-core GitHub runner,
    // under the full suite in parallel, it exceeded the 5s default and made
    // this the only flaky test in the suite — 3 of 5 consecutive CI runs.
    //
    // Raising the budget alone would be guessing. The PRIMARY assertion is now
    // the server's own counter, which needs no propagation at all: the cap's
    // contract is that a third connection is never ADMITTED, and that is
    // decided inside the listener. The client-side close keeps its own check
    // with a budget generous enough for a loaded runner, so a cap that stops
    // closing the refused connection still fails.
    pump(until: { listener.activeConnectionCount > 2 }, seconds: 1)
    #expect(listener.activeConnectionCount == 2,
            "a connection over the cap was ADMITTED: count reached \(listener.activeConnectionCount)")

    pump(until: { extra.peerClosed }, seconds: 30)
    #expect(extra.peerClosed, "a connection over the cap was served anyway")
    #expect(parked.allSatisfy { !$0.peerClosed },
            "the cap closed a connection that was under it")
}

@Test func aServedRequestGivesItsConnectionSlotBack() throws {
    // Named bug this catches: a slot taken and never returned. The cap would
    // then be a countdown — ingest works for exactly `maximumConnections` posts
    // and is silently dead afterwards, with the panel still reporting healthy.
    // Three posts through a cap of two is the smallest case that shows it.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    let collected = Collected()
    let listener = UnixSocketIngestListener(socketPath: sandbox.path,
                                            maximumConnections: 2)
    defer { listener.stop() }
    try listener.start { event in collected.record(event, onMain: Thread.isMainThread) }
    try requireReady(listener)

    for index in 0..<3 {
        #expect(try post(#"{"hook_event_name":"Stop","session_id":"s\#(index)"}"#,
                         to: sandbox.path) == 0, "post \(index) was refused")
        pump(until: { collected.all.count == index + 1 })
    }

    #expect(collected.all.map(\.sessionID) == ["s0", "s1", "s2"])
    pump(until: { listener.activeConnectionCount == 0 })
    #expect(listener.activeConnectionCount == 0)
}

// MARK: - The buffered payload is released (audit finding B3)

@Test func everyServedRequestReleasesTheStateHoldingItsRawBytes() throws {
    // Named bug this catches: `finish()` cancels the idle timer and leaves
    // `state.timeout` still pointing at the work item. That item's block
    // captures `state` STRONGLY, so `state -> timeout -> block -> state` is an
    // island nothing can reach and nothing ever frees. `cancel()` does not
    // release a work item's captures, so cancelling alone does not break it.
    //
    // Why it is a PRIVACY defect and not merely untidy: every `ConnectionState`
    // owns a framer, and the framer keeps the whole raw POST in a stored
    // property. A state object that outlives its connection therefore pins the
    // assistant reply text and the conversation-transcript path in memory for
    // the life of the process. Design §7 forbids that outright. The audit
    // measured 0 of 2200 states freed and 6,405,780 bytes retained.
    //
    // THE SETTLE WINDOW MUST EXCEED THE IDLE TIMEOUT, or this test proves
    // NOTHING. A pending `asyncAfter` holds its work item until the deadline in
    // the FIXED code too, so an observation taken before the deadline sees a
    // live state in BOTH arms. This exact confound produced a wrong result
    // during the audit: a 100 s deadline reported the fixed tree as leaking.
    // The injected timeout here is 1 s and the window below is 8 s.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    let collected = Collected()
    let listener = UnixSocketIngestListener(socketPath: sandbox.path,
                                            idleTimeout: 1)
    defer { listener.stop() }
    try listener.start { event in collected.record(event, onMain: Thread.isMainThread) }
    try requireReady(listener)

    let posts = 5
    for index in 0..<posts {
        let json = #"{"hook_event_name":"Stop","session_id":"s\#(index)","transcript_path":"/tmp/t.jsonl","last_assistant_message":"reply text that must not stay resident"}"#
        #expect(try post(json, to: sandbox.path) == 0, "post \(index) was refused")
    }
    pump(until: { collected.all.count == posts })
    #expect(collected.all.count == posts)

    // Without this the assertion below passes trivially whenever the posts did
    // not reach the listener at all: nothing built, so nothing alive.
    #expect(listener.connectionCensus.createdCount == posts,
            "the listener built \(listener.connectionCensus.createdCount) states for \(posts) posts; the leak assertion would be vacuous")

    pump(until: { listener.connectionCensus.liveCount == 0 }, seconds: 8)
    #expect(listener.connectionCensus.liveCount == 0,
            "\(listener.connectionCensus.liveCount) of \(posts) ConnectionState objects were never freed; each still holds the raw POST bytes")
}

// MARK: - Reassembly across receives

@Test func aBodyLargerThanTheReceiveChunkIsReassembled() throws {
    // `receiveChunkBytes` (64 KiB) is deliberately NOT `maximumBytes` (1 MiB),
    // and until now nothing exercised the gap between them. Named bug this
    // catches: a receive loop that treats ONE delivery as ONE request. A body
    // over the chunk size would then never frame — it would sit on `needMore`
    // until the idle timeout closed it — and the traffic lost is exactly the
    // traffic the cap was raised to admit: a reply carrying a large code block.
    //
    // The body is 256 KiB, four times the receive chunk and a quarter of the
    // request cap, so it can neither arrive in one receive nor be refused.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    let collected = Collected()
    let listener = UnixSocketIngestListener(socketPath: sandbox.path)
    defer { listener.stop() }
    try listener.start { event in collected.record(event, onMain: Thread.isMainThread) }
    try requireReady(listener)

    let filler = String(repeating: "x", count: 262_144)
    let json = #"{"hook_event_name":"Stop","session_id":"reassembled","last_assistant_message":"\#(filler)"}"#
    // Pinned to the two literals this test sits between. A future edit that
    // moves either bound past the body size makes the test vacuous silently.
    #expect(json.utf8.count > 65_536,
            "the body is \(json.utf8.count) bytes and never crosses the 64 KiB receive chunk")
    #expect(json.utf8.count < 1_048_576,
            "the body is \(json.utf8.count) bytes and exceeds the 1 MiB request cap")

    let payload = sandbox.directory.appending(path: "large.json").path
    try json.write(toFile: payload, atomically: true, encoding: .utf8)

    #expect(try post(contentsOfFile: payload, to: sandbox.path) == 0,
            "a request spanning several receives was refused")
    pump(until: { !collected.all.isEmpty })

    let event = try #require(collected.all.first)
    #expect(event.sessionID == "reassembled")
    #expect(collected.all.count == 1,
            "a request spanning several receives was delivered \(collected.all.count) times")
}

// MARK: - The declared surface

@Test func anOverLongSocketPathIsRefusedWithANamedError() throws {
    // `sun_path` is 104 bytes. Named bug this catches: an obscure bind failure
    // on a machine with a long user name, which would look like "ingest just
    // does not work here" with no way to tell why.
    let long = "/tmp/" + String(repeating: "a", count: 120) + ".sock"
    let listener = UnixSocketIngestListener(socketPath: long)
    #expect(throws: IngestError.socketPathTooLong(long.utf8.count)) {
        try listener.start { _ in }
    }
}

@Test func theDefaultSocketPathIsUnderApplicationSupport() {
    // Design §4 fixes the location. Pinned to the literal suffix, not rebuilt
    // from the implementation's own components.
    let path = UnixSocketIngestListener.defaultSocketPath
    #expect(path.hasSuffix("/Library/Application Support/coffee-bar/ingest.sock"))
    #expect(path.utf8.count < 104, "the default path overflows sun_path")
}

@Test func theShippedConnectionLimitsArePinned() {
    // Both are judgement calls and both are safety-relevant: the idle timeout is
    // what stops a half-open connection parking forever, and the cap bounds how
    // many can park at once. Pinned so that changing either is deliberate.
    #expect(UnixSocketIngestListener.defaultIdleTimeout == 10)
    #expect(UnixSocketIngestListener.defaultMaximumConnections == 32)
}
