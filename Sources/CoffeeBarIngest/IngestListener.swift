// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin
import Network
import CoffeeBarCore

public enum IngestError: Error, Equatable {
    /// `sun_path` is 104 bytes. See `/usr/include/sys/un.h`.
    case socketPathTooLong(Int)
    case directoryUnwritable(String)
    /// Another listener already answers at this path, or this one already does.
    case alreadyServing(String)
    /// Something sits at the socket path that must not be cleared out.
    case socketPathBlocked(String)
}

/// Injection seam, the third of the three `ServingModel` is built on —
/// `PowerReadingProviding` reads the battery, one more holds the assertion, and
/// this one delivers events.
///
/// `ServingModel` depends on this rather than on the concrete listener, so the
/// model's tests run with no socket at all.
///
/// The sibling seam is NOT named here on purpose. This file now ships inside
/// the `coffee-bar` binary, so `AppLayerBoundary_test.swift` reads it, and the
/// check there treats that name itself as the tripwire — a mention in a comment
/// is enough to turn it red. That is the check working, not a false positive:
/// only `ServingModel.swift` may reach the holder, and a denylist cannot tell a
/// comment from a call.
public protocol IngestListening: Sendable {
    /// Delivers every decoded event ON THE MAIN THREAD. See `start(queue:)`.
    func start(onEvent: @escaping @Sendable (HookEvent) -> Void) throws
    func stop()

    /// Whether this listener is serving RIGHT NOW.
    ///
    /// A requirement rather than a detail of the concrete type, because the
    /// panel has to be able to say so. `startMonitoring` throwing was the only
    /// report before, and `main.swift` writes that to NSLog, where no user
    /// looks.
    ///
    /// It must answer for the CURRENT state, never for a past `start()`. A
    /// `start()` that returns without throwing has created a listener, not
    /// proved a bind — `UnixSocketIngestListener` binds asynchronously — so a
    /// conformance that returned "started successfully once" would let the
    /// panel claim to be serving while nothing was.
    var isReady: Bool { get }
}

/// An HTTP-over-unix-socket ingest endpoint.
///
/// Design §4: the filesystem is the authenticator. There is no port to collide
/// with, no token to leak or rotate, and no other local user can post.
/// `SECURITY.md`'s "no network egress" stays true — a unix socket is not
/// network egress and this opens no outbound connection.
///
/// Design §4.1 states the residual risk plainly: a process running as the same
/// user can still post. The socket stops other users and remote hosts, not you.
public final class UnixSocketIngestListener: IngestListening, @unchecked Sendable {

    /// `~/Library/Application Support/coffee-bar/ingest.sock`, per design §4.
    public static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/coffee-bar/ingest.sock")
            .path
    }

    /// How long a connection may go without completing a request.
    ///
    /// The whole exchange is one small POST over a local socket, so ten seconds
    /// is far more than a real hook needs and short enough that a silent peer
    /// cannot hold a slot.
    public static let defaultIdleTimeout: TimeInterval = 10

    /// How many connections may be in flight at once.
    ///
    /// `HTTPRequestFramer.maximumBytes` bounds ONE request; this bounds how many
    /// requests can be buffering at the same time.
    public static let defaultMaximumConnections = 32

    /// `sun_path[104]` in `sys/un.h`, minus the terminating NUL.
    private static let maximumPathBytes = 103

    private let socketPath: String
    private let idleTimeout: TimeInterval
    private let maximumConnections: Int
    private let lock = NSLock()
    private var listener: NWListener?
    private var activeConnections = 0
    private var ready = false

    public init(socketPath: String = UnixSocketIngestListener.defaultSocketPath,
                idleTimeout: TimeInterval = UnixSocketIngestListener.defaultIdleTimeout,
                maximumConnections: Int = UnixSocketIngestListener.defaultMaximumConnections) {
        self.socketPath = socketPath
        self.idleTimeout = idleTimeout
        self.maximumConnections = maximumConnections
    }

    /// True once the socket is bound AND its mode has been tightened.
    ///
    /// The tests use it to wait for the bind instead of racing it: the node
    /// appears at bind time but the mode only changes on `.ready`, so
    /// `fileExists` is not the same question.
    ///
    /// `public` since it became an `IngestListening` requirement. It is the
    /// panel's answer to "is this process serving", which no read of the user's
    /// settings file can give. `stop()` clears it, and a bind that never
    /// reaches `.ready` never sets it, so a false answer here means the socket
    /// really is not serving.
    public var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return ready
    }

    /// How many connections are being served right now.
    ///
    /// Internal, so the connection-cap tests can sequence a flood deterministically
    /// rather than guessing when the listener has accepted.
    var activeConnectionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return activeConnections
    }

    public func start(onEvent: @escaping @Sendable (HookEvent) -> Void) throws {
        guard socketPath.utf8.count <= Self.maximumPathBytes else {
            throw IngestError.socketPathTooLong(socketPath.utf8.count)
        }

        lock.lock()
        let alreadyRunning = listener != nil
        lock.unlock()
        // Checked before the probe below, which cannot tell our own live node
        // from another process's. Reported rather than silently ignored: a
        // second `start()` that does nothing leaves the caller's NEW handler
        // unwired while events keep reaching the old one.
        guard !alreadyRunning else { throw IngestError.alreadyServing(socketPath) }

        let path = socketPath
        let directory = (path as NSString).deletingLastPathComponent

        // The 0700 directory is created BEFORE the bind, and that ordering is
        // load-bearing. A bare bind under umask 022 creates the node at 0755 —
        // measured — and the change to 0600 only lands once the listener reports
        // `.ready`. Inside that window the socket is world-connectable. A parent
        // directory no other user can traverse closes it outright.
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            // `createDirectory` applies the attributes only when it CREATES the
            // directory, so an existing one keeps whatever mode it had.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory)
        } catch {
            throw IngestError.directoryUnwritable(directory)
        }

        // Never take a path something else is answering on. Measured: a second
        // instance that unlinked and rebound left the first one `.ready` on an
        // unlinked inode, deaf forever and with no error to report.
        switch Self.occupant(atPath: path) {
        case .absent:
            break
        case .live:
            throw IngestError.alreadyServing(path)
        case .blocked:
            throw IngestError.socketPathBlocked(path)
        case .stale:
            // A force-quit leaves the node behind and the next bind would fail
            // on it. Removing a node NOTHING answers on is how every unix-socket
            // server starts.
            try? FileManager.default.removeItem(atPath: path)
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters)

        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            // The node exists only once the bind has happened.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: path)
            guard let self else { return }
            self.lock.lock()
            self.ready = true
            self.lock.unlock()
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.accept(connection, onEvent: onEvent)
        }

        // This queue carries `stateUpdateHandler` and `newConnectionHandler`.
        // Both take the lock and are correct on any queue; `.main` is chosen so
        // that the listener, every connection and every idle timer are
        // serialised by ONE queue.
        //
        // It is NOT the line that pins the delivery thread. Measured by
        // mutation: moving this alone to `.global()` left
        // `deliveryHappensOnTheMainThread` GREEN. The line that carries that
        // invariant is `connection.start(queue: .main)` in `accept`.
        listener.start(queue: .main)

        lock.lock()
        self.listener = listener
        self.activeConnections = 0
        lock.unlock()
    }

    /// Cancels the listener and LEAVES the socket node in place.
    ///
    /// Unlinking here was a measured defect. The node at the path is not always
    /// ours: once a second instance had rebound it, this call deleted the LIVE
    /// node of the instance that had replaced us, and ingest was dead while the
    /// app looked healthy. Nothing is lost by leaving it — `start()` removes a
    /// node nothing answers on.
    public func stop() {
        lock.lock()
        let cancelling = listener
        listener = nil
        activeConnections = 0
        ready = false
        lock.unlock()
        cancelling?.cancel()
    }

    // MARK: - Who owns the node

    private enum Occupant {
        /// Nothing at the path.
        case absent
        /// Something is there, and nothing answers on it.
        case stale
        /// Something answers, or we cannot prove otherwise.
        case live
        /// Something is there that must not be cleared out.
        case blocked
    }

    /// Asks the node itself whether anybody is serving on it.
    ///
    /// Existence proves nothing: the node outlives the process that bound it.
    /// A connection attempt is the only answer that distinguishes the cases.
    private static func occupant(atPath path: String) -> Occupant {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            // `removeItem` on a directory takes everything under it, and a
            // directory answers exactly like a leftover regular file does
            // (ENOTSOCK). Refuse rather than delete.
            return .blocked
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        // Unprovable is treated as live throughout: refusing to start is
        // recoverable and visible, and taking a live node away from another
        // instance is neither.
        guard descriptor >= 0 else { return .live }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            return .live
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected == 0 { return .live }

        // Measured on macOS, not read from a manual page: ENOENT for no node at
        // all, ECONNREFUSED for a bound node whose owner has gone, ENOTSOCK for
        // a plain file left at the path.
        switch errno {
        case ENOENT: return .absent
        case ECONNREFUSED, ENOTSOCK: return .stale
        default: return .live
        }
    }

    // MARK: - Serving one connection

    /// Per-connection state.
    ///
    /// Every field is touched only on `DispatchQueue.main` — the listener, each
    /// connection and the idle timer all run there, so the main queue serialises
    /// them. It is a class because the receive closure escapes and has to keep
    /// mutating the same framer across receives.
    private final class ConnectionState: @unchecked Sendable {
        var framer = HTTPRequestFramer()
        var timeout: DispatchWorkItem?
        private var released = false

        /// True exactly once. The idle timer and the final frame race each
        /// other, and the connection slot must come back exactly one time.
        func claimRelease() -> Bool {
            if released { return false }
            released = true
            return true
        }
    }

    private func accept(_ connection: NWConnection,
                        onEvent: @escaping @Sendable (HookEvent) -> Void) {
        lock.lock()
        let admitted = activeConnections < maximumConnections
        if admitted { activeConnections += 1 }
        lock.unlock()

        // `.main` is load-bearing, not a default. THIS is the queue every
        // receive callback runs on, so it is the queue `onEvent` is delivered
        // on. `ServingModel` reaches the main actor from that callback with
        // `MainActor.assumeIsolated`, the same discipline `startMonitoring`
        // already uses for its `Timer`, and delivering from any other queue
        // makes that call TRAP at runtime. Proved by mutation: `.global()` here
        // turns `deliveryHappensOnTheMainThread` red.
        connection.start(queue: .main)

        guard admitted else {
            // Answered rather than dropped, so a client that is merely too eager
            // reads a status instead of a bare disconnect.
            Self.refuse(connection, status: "503 Service Unavailable")
            return
        }

        let state = ConnectionState()
        // A peer that opens a connection and then says nothing produces no
        // complete frame, no `isComplete` and no error, so nothing else in the
        // receive loop would ever end it.
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { connection.cancel(); return }
            self.finish(connection, state: state)
        }
        state.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + idleTimeout, execute: timeout)

        receive(connection, state: state, onEvent: onEvent)
    }

    /// Cancels the connection and gives its slot back, exactly once.
    private func finish(_ connection: NWConnection, state: ConnectionState) {
        guard state.claimRelease() else { return }
        state.timeout?.cancel()
        lock.lock()
        // Clamped because `stop()` zeroes the counter while connections may
        // still be draining.
        activeConnections = max(0, activeConnections - 1)
        lock.unlock()
        connection.cancel()
    }

    private func receive(_ connection: NWConnection,
                         state: ConnectionState,
                         onEvent: @escaping @Sendable (HookEvent) -> Void) {
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: HTTPRequestFramer.maximumBytes) {
            [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }

            if let data, !data.isEmpty {
                switch state.framer.append(data) {
                case .needMore:
                    if !isComplete && error == nil {
                        self.receive(connection, state: state, onEvent: onEvent)
                        return
                    }
                    self.respond(connection, status: "400 Bad Request", state: state)
                    return

                case .body(let body):
                    // A payload that will not decode is DROPPED, and the
                    // listener survives. Cancelling here would let one malformed
                    // post silently stop ingest for the session while the panel
                    // kept looking healthy.
                    if let event = try? JSONDecoder().decode(HookEvent.self, from: body) {
                        onEvent(event)
                        self.respond(connection, status: "204 No Content", state: state)
                    } else {
                        self.respond(connection, status: "400 Bad Request", state: state)
                    }
                    return

                case .tooLarge:
                    self.respond(connection, status: "413 Content Too Large", state: state)
                    return

                case .malformed:
                    self.respond(connection, status: "400 Bad Request", state: state)
                    return
                }
            }

            if isComplete || error != nil {
                self.finish(connection, state: state)
                return
            }
            self.receive(connection, state: state, onEvent: onEvent)
        }
    }

    private func respond(_ connection: NWConnection, status: String,
                         state: ConnectionState) {
        connection.send(content: Self.response(status),
                        completion: .contentProcessed { [weak self] _ in
                            guard let self else { connection.cancel(); return }
                            self.finish(connection, state: state)
                        })
    }

    /// Answers a connection that was never admitted, so it holds no slot to
    /// give back.
    private static func refuse(_ connection: NWConnection, status: String) {
        connection.send(content: response(status),
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func response(_ status: String) -> Data {
        Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }
}
