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

private func mode(ofItemAtPath path: String) -> Int16? {
    (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
        as? NSNumber)??.int16Value
}

/// Posts one payload the way a real hook does. `/usr/bin/curl` ships with macOS.
@discardableResult
private func post(_ json: String, to socketPath: String) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = ["--silent", "--show-error", "--fail",
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

/// Waits until `condition` holds or the deadline passes.
///
/// The listener runs on `DispatchQueue.main`. `swift-testing` runs a test body
/// on the concurrency pool rather than on the main thread, and the harness's own
/// main-actor executor drains the main queue, so this thread only has to wait.
/// When a test body IS on the main thread, waiting would starve the very queue
/// it is waiting for, so the run loop is turned over instead.
private func pump(until condition: () -> Bool, seconds: TimeInterval = 5) {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && Date() < deadline {
        if Thread.isMainThread {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        } else {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
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
    pump(until: { listener.isReady })

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
    pump(until: { listener.isReady })

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
    pump(until: { listener.isReady })

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
    pump(until: { listener.isReady })

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
    pump(until: { listener.isReady })

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
    pump(until: { listener.isReady })

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
    pump(until: { listener.isReady })

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
    pump(until: { listener.isReady })
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
    pump(until: { first.isReady })

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
    pump(until: { first.isReady })
    first.stop()
    waitUntilNothingAnswers(at: sandbox.path)
    #expect(FileManager.default.fileExists(atPath: sandbox.path),
            "no node was left behind; the reclaim below would prove nothing")

    let collected = Collected()
    let second = UnixSocketIngestListener(socketPath: sandbox.path)
    defer { second.stop() }
    try second.start { event in collected.record(event, onMain: Thread.isMainThread) }
    pump(until: { second.isReady })

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
    pump(until: { listener.isReady })

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

@Test func startingAListenerThatIsAlreadyServingThrows() throws {
    // The same-instance case. Named bug this catches: a second `start()` that
    // silently does nothing and leaves the caller's NEW handler unwired, so
    // events keep going to a closure the caller has already replaced.
    let sandbox = SocketSandbox()
    defer { sandbox.remove() }
    let listener = UnixSocketIngestListener(socketPath: sandbox.path)
    defer { listener.stop() }
    try listener.start { _ in }
    pump(until: { listener.isReady })

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
    pump(until: { listener.isReady })

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
    pump(until: { listener.isReady })

    var parked: [RawClient] = []
    defer { parked.forEach { $0.close() } }
    for _ in 0..<2 {
        let client = try #require(RawClient(path: sandbox.path))
        client.transmit("POST /ingest HTTP/1.1\r\nHost: localhost\r\n")
        parked.append(client)
    }
    // Both must be ADMITTED before the third arrives, or this measures a race
    // rather than the cap.
    pump(until: { listener.activeConnectionCount == 2 })
    #expect(listener.activeConnectionCount == 2)

    let extra = try #require(RawClient(path: sandbox.path))
    defer { extra.close() }
    extra.transmit("POST /ingest HTTP/1.1\r\nHost: localhost\r\n")

    pump(until: { extra.peerClosed })
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
    pump(until: { listener.isReady })

    for index in 0..<3 {
        #expect(try post(#"{"hook_event_name":"Stop","session_id":"s\#(index)"}"#,
                         to: sandbox.path) == 0, "post \(index) was refused")
        pump(until: { collected.all.count == index + 1 })
    }

    #expect(collected.all.map(\.sessionID) == ["s0", "s1", "s2"])
    pump(until: { listener.activeConnectionCount == 0 })
    #expect(listener.activeConnectionCount == 0)
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
