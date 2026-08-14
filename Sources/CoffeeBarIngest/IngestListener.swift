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
    /// Something sits at the socket path that must not, or cannot, be cleared
    /// out.
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
    func start(onEvent: @escaping @Sendable (AgentTool, HookEvent) -> Void) throws
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

    /// Installs what the READ route answers with, or `nil` for nothing to say.
    ///
    /// The direction is the opposite of `start(onEvent:)` and that is the whole
    /// point: events are pushed at the model, and this is pulled out of it at
    /// the moment somebody asks. A snapshot pushed on a timer would be a second
    /// copy of the state that can disagree with the panel's, which design §14
    /// rules out for exactly this reason.
    ///
    /// Called ON THE MAIN THREAD, like every `onEvent` delivery, because it is
    /// called from the same connection queue. `ServingModel` reaches the main
    /// actor from inside it with `MainActor.assumeIsolated`, and a delivery
    /// from any other queue makes that TRAP.
    ///
    /// It must do no work worth speaking of. Any process running as this user
    /// can call the route, so whatever this closure does, it does at a rate
    /// somebody else chooses, on the main thread of a menu-bar app.
    func serveStatus(_ answer: @escaping @Sendable () -> IngestStatus?)
}

extension IngestListening {
    /// A conformance that answers no read route, which is every double in the
    /// test suites and nothing that ships.
    ///
    /// **A default on a requirement is normally how a missing wire ships
    /// silently, and here it is bounded rather than free.** What is silent is a
    /// LISTENER that ignores the installation; what would matter is the MODEL
    /// never installing one, and `theModelIsWhatAnswersTheReadRoute` reads
    /// `ServingModel.swift` for that call. The alternative — no default —
    /// forces six test doubles across three files to grow a method that answers
    /// nothing, which is the same silence written six more times.
    public func serveStatus(_ answer: @escaping @Sendable () -> IngestStatus?) {}
}

// MARK: - What the read route publishes

/// Everything coffee-bar will tell a reader about itself, and the whole of it.
///
/// **This is a SEPARATE channel from the hook one, and the difference is who
/// asked.** A hook reply is something an agent tool draws on your behalf and
/// you never see, so it carries no body at all — see `response(_:allow:)`. This
/// is answered only to a caller that chose to ask for it, over the same
/// filesystem socket, and it describes coffee-bar rather than your work.
///
/// **What it deliberately cannot carry.** Design §7 keeps conversation content
/// out of this product: no session identity, no working directory, no
/// transcript path, no message text. That is a property of the TYPE and not of
/// the code that fills it — there is no field to put any of them in — and
/// `theReadPayloadCarriesASchemaVersionAndNothingUnlisted` pins the key set so
/// a later field has to be read against §7 before it can ship.
///
/// **`hookHealth` is a word, not a `HookHealthStatus`.** That enum carries the
/// names of the events a user has left unwired, and this channel publishes the
/// state and not the list.
public struct IngestStatus: Codable, Equatable, Sendable {
    /// The shape a reader is holding, as the hook payloads and the on-disk
    /// records do — `JournalRecord.currentSchemaVersion` is the precedent.
    ///
    /// A reader that outlives this build has no other way to know whether a
    /// missing key means "this build does not publish it" or "this build is
    /// older than the key".
    public static let currentSchemaVersion = 1

    /// How healthy the hook channel is, as one word.
    public enum HookChannel: String, Codable, Sendable {
        case wired
        case missing
        case unreadable
    }

    public let schemaVersion: Int
    /// What `AppVersion.display(from:)` renders, `unknown` included. Whoever
    /// builds this reads the bundle; this type never guesses.
    public let version: String
    /// The control position the user chose, not what the machine is doing.
    public let intent: UserIntent
    /// Whether a power assertion is held RIGHT NOW. What actually happened,
    /// never what was asked for — `intent` above is the asking.
    public let holding: Bool
    /// How many agent sessions are working. A COUNT, never the sessions.
    public let working: Int
    /// How many agent sessions are blocked on the human. A count, as above.
    public let attention: Int
    public let hookHealth: HookChannel
    /// Whether this process is answering on the ingest socket. A reader that
    /// got this far knows it is, so the honest use of the field is a second
    /// process asking about the first.
    public let listening: Bool

    /// The schema version is set here and is never a parameter: a caller that
    /// could choose it could publish a shape it does not produce.
    public init(version: String,
                intent: UserIntent,
                holding: Bool,
                working: Int,
                attention: Int,
                hookHealth: HookHealthStatus,
                listening: Bool) {
        self.schemaVersion = Self.currentSchemaVersion
        self.version = version
        self.intent = intent
        self.holding = holding
        self.working = working
        self.attention = attention
        // Written as a switch rather than a default, so a fourth
        // `HookHealthStatus` case stops the build here instead of quietly
        // reporting one of the three that exist today.
        switch hookHealth {
        case .wired: self.hookHealth = .wired
        case .missing: self.hookHealth = .missing
        case .unreadable: self.hookHealth = .unreadable
        }
        self.listening = listening
    }
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

    /// Where a reader asks this process what is happening.
    ///
    /// NOT under `/event`, and not resolvable by `AgentTool.declared(byEndpoint:)`:
    /// the two channels have to stay tellable apart at the routing line, and an
    /// endpoint that resolved to a tool would put a read on the hook path.
    ///
    /// The command a reader runs is
    ///
    ///     curl --fail-with-body --unix-socket <socket> \
    ///          -H 'Content-Length: 0' http://localhost/status
    ///
    /// and the header is not decoration. `HTTPRequestFramer` requires a
    /// declared length on EVERY request; the read route is framed by that
    /// framer rather than by a lenient second one, so a request it cannot frame
    /// is refused whatever it was aimed at.
    /// `aReadRequestThatDeclaresNoLengthIsRefusedLikeAnyOther` pins that, and
    /// pins why serving this route out of the framer's `.malformed` outcome —
    /// which is what "make a bare curl work" comes to — is refused.
    public static let readEndpoint = "/status"

    /// `sun_path[104]` in `sys/un.h`, minus the terminating NUL.
    private static let maximumPathBytes = 103

    private let socketPath: String
    private let idleTimeout: TimeInterval
    private let maximumConnections: Int
    private let lock = NSLock()
    private var listener: NWListener?
    private var activeConnections = 0

    /// What the read route asks, or `nil` while nothing has been installed.
    ///
    /// Guarded by `lock` like every other field here, and READ OUT of the lock
    /// before it is called: it reaches the main actor, and calling it while
    /// holding this lock puts the model's work inside the lock every `accept`
    /// takes.
    private var statusAnswer: (@Sendable () -> IngestStatus?)?

    /// Which socket node this listener bound, captured when it reported
    /// `.ready`. Non-nil IS "ready". See `isReady`.
    ///
    /// It replaces a plain `Bool`. Two fields that have to agree would be one
    /// more invariant to keep, and this one carries strictly more than the flag
    /// did. The three write sites are unchanged: here, the `.ready` state, and
    /// `stop()`.
    private var boundNode: NodeIdentity?

    /// Identifies one node on one filesystem.
    ///
    /// Device AND inode. An inode number is unique only within a filesystem,
    /// and the socket path is user-configurable at the initialiser, so the two
    /// have to travel together.
    private struct NodeIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    /// Lifetime census for the per-connection state. See `ConnectionCensus`.
    ///
    /// Internal, so a test can prove those objects are RELEASED. Nothing on the
    /// serving path reads it.
    let connectionCensus = ConnectionCensus()

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
    /// settings file can give.
    ///
    /// A stored flag alone answered for the PAST. It was written at exactly
    /// three sites — the initialiser, the `.ready` state, and `stop()` — so
    /// `stop()` was the only thing that ever cleared it, and a node that went
    /// away while the process ran left it true. Measured: the user deletes the
    /// node, `curl` fails at exit 7, every event is lost, and the panel reports
    /// no problem at all, because `ingestListening` is this value.
    ///
    /// So the flag became a precondition and the node became the proof. The
    /// question asked is IDENTITY, not existence: is the node at the path the
    /// one this listener bound. A type check cannot answer it. The scenario
    /// recorded at the `occupant` call site below — a second binder unlinks the
    /// node and binds its own, and this listener is left `.ready` on an
    /// unlinked inode, deaf for ever — leaves a socket of exactly the right
    /// type at the path. Only device and inode tell the two apart.
    ///
    /// `lstat`, never `stat`. A symlink at the path answers false even when it
    /// resolves to this listener's own socket. The node has then left the 0700
    /// directory, which is the whole access control of design §4, so answering
    /// true would report a security property the app no longer has.
    ///
    /// The lock is released BEFORE the syscall. This is polled in tight loops,
    /// not only on the 30 s refresh, and `accept` takes the same lock on every
    /// connection. Measured at 1.3 µs per call, which is 0.0067 % of a core at
    /// one call per 20 ms. No ratio against the bare flag is quoted: that
    /// multiplier moves with machine load, where both absolutes reproduce.
    ///
    /// `stop()` still clears the identity, and that is still load-bearing: it
    /// leaves the node in place on purpose, so the node alone cannot say that
    /// this listener stopped.
    public var isReady: Bool {
        lock.lock()
        let bound = boundNode
        lock.unlock()
        guard let bound else { return false }
        return Self.nodeIdentity(atPath: socketPath) == bound
    }

    /// Installs what the read route answers with. See `IngestListening`.
    ///
    /// Separate from `start(onEvent:)` rather than a parameter of it, because
    /// the answer comes from the model and the model is built holding the
    /// listener: there is no moment at construction when both exist. It is also
    /// idempotent, so a second `startMonitoring` re-points the route at the
    /// model that is actually live.
    public func serveStatus(_ answer: @escaping @Sendable () -> IngestStatus?) {
        lock.lock(); defer { lock.unlock() }
        statusAnswer = answer
    }

    /// How many connections are being served right now.
    ///
    /// Internal, so the connection-cap tests can sequence a flood deterministically
    /// rather than guessing when the listener has accepted.
    var activeConnectionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return activeConnections
    }

    public func start(onEvent: @escaping @Sendable (AgentTool, HookEvent) -> Void) throws {
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
            // The AFTER-STATE, not the return. `try?` is right here — the node
            // may legitimately have gone by itself between the probe and this
            // line, and that error means nothing — but a node that SURVIVES
            // means everything. Measured: a dangling symlink plus
            // `lchflags(path, UF_IMMUTABLE)`, a USER flag any process under this
            // account can set on its own link, made the delete fail silently.
            // The bind then went THROUGH the surviving link and the socket
            // landed at the far end, which is the relocation this probe exists
            // to stop, reached by a second route.
            //
            // Refusing is the only honest answer. Recovery is what makes
            // `.stale` the right classification for a link, and where the
            // recovery cannot happen there is nothing left to prefer it for.
            guard Self.nodeType(atPath: path) == nil else {
                throw IngestError.socketPathBlocked(path)
            }
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
            // Identity, not existence. A capture that fails means no socket of
            // ours is at the path, which is what `isReady` would answer in any
            // case, so nothing is stored and this listener reports false.
            guard let identity = Self.nodeIdentity(atPath: path) else { return }
            self.lock.lock()
            self.boundNode = identity
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
        boundNode = nil
        lock.unlock()
        cancelling?.cancel()
    }

    /// Decodes a payload with the decoder its declared origin calls for.
    ///
    /// Two envelopes exist, and which one applies is settled by the origin
    /// rather than by trying both. Claude Code and Codex share
    /// `HookEvent`. Cursor has its own, because four of its six recorded
    /// payloads carry no `session_id` at all and `HookEvent` makes that field
    /// non-optional — so they throw rather than decode.
    ///
    /// Trying both decoders in turn would be worse than useless here: a Cursor
    /// `sessionStart` DOES carry `session_id`, so it would decode as a
    /// `HookEvent`, resolve against the wrong vocabulary and drive nothing,
    /// while its four sibling events failed outright. The origin is known, so
    /// it is used.
    ///
    /// `nil` means the bytes are not that tool's envelope, and the caller
    /// answers 400.
    private static func decode(_ body: Data, from tool: AgentTool) -> HookEvent? {
        switch tool {
        case .claudeCode, .codex:
            return try? JSONDecoder().decode(HookEvent.self, from: body)
        case .cursor:
            return (try? JSONDecoder().decode(CursorHookEvent.self, from: body))?.normalised
        }
    }

    // MARK: - Who owns the node

    private enum Occupant {
        /// Nothing at the path.
        case absent
        /// Something is there, and nothing answers on it.
        case stale
        /// Something answers, or we cannot prove otherwise.
        case live
        /// Something is there that must not, or cannot, be cleared out.
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
        case ENOENT:
            // `connect` FOLLOWS a symlink, so a DANGLING one answers ENOENT —
            // the same errno an empty path gives. `lstat` tells the two apart,
            // because it does not follow the link.
            //
            // Answering `.absent` for both was measured to RELOCATE the live
            // socket. `.absent` removes nothing, so `NWListener` bound through
            // the link and created the node at the link's target. The 0700
            // directory above then guarded a path nothing was serving on. The
            // 0755 bind window documented there is not created by the link and
            // measured 0.2 ms; what the link does is move that known window out
            // of the directory that closes it. The loss is defence in depth.
            //
            // `.stale` rather than `.blocked`, deliberately. `removeItem` does
            // not follow a symlink, so it takes the LINK, and a dangling link
            // has no target left to take. A link to an unserved socket and a
            // link to a regular file already resolve here, so all three
            // removable link cases now follow one rule. It also RECOVERS from a
            // planted link rather than only reporting it, and recovery here is
            // free: a dangling link has no target to lose.
            //
            // That is a preference, not an absolute. A refusal is NOT uniquely
            // bad — a link to a directory already gives a standing refusal this
            // app cannot clear itself, and the design accepts that outcome. So
            // `.blocked` is chosen wherever recovery is not free, including a
            // delete that fails, above.
            //
            // A live node is never reached by this branch. It answers `connect`
            // or gives ECONNREFUSED, and it is not a symlink either way.
            return Self.nodeType(atPath: path) == mode_t(S_IFLNK) ? .stale : .absent
        case ECONNREFUSED, ENOTSOCK: return .stale
        default: return .live
        }
    }

    /// The type bits of the node AT `path`, or nil when there is nothing there.
    ///
    /// `lstat`, never `stat`. Both callers ask about the object at the path
    /// itself rather than about what it resolves to.
    private static func nodeType(atPath path: String) -> mode_t? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        return status.st_mode & mode_t(S_IFMT)
    }

    /// Which SOCKET node is at `path`, or nil when the path does not hold one.
    ///
    /// `lstat`, never `stat`, for the reason `isReady` gives: a symlink must
    /// answer nil even when it resolves to this listener's own socket.
    private static func nodeIdentity(atPath path: String) -> NodeIdentity? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else { return nil }
        return NodeIdentity(device: status.st_dev, inode: status.st_ino)
    }

    // MARK: - Serving one connection

    /// Counts the `ConnectionState` objects made and freed.
    ///
    /// It exists so a test can prove they are FREED. `ConnectionState` owns a
    /// framer, and the framer keeps the entire raw POST — headers and body — in
    /// a stored property. One state object that outlives its connection
    /// therefore pins that request's bytes, the assistant reply text among them,
    /// for the life of the process. Design §7 forbids reading conversation
    /// content at all, so retaining it is the same defect at rest.
    ///
    /// Per listener rather than process-wide, deliberately. `swift-testing` runs
    /// tests in parallel, so a global counter would be moved by every other test
    /// that serves a connection, and no test could own its own reading.
    ///
    /// `made` carries as much weight as `live`: an assertion that nothing is
    /// alive passes on its own whenever nothing was ever built, so a test needs
    /// both numbers to say anything.
    final class ConnectionCensus: @unchecked Sendable {
        private let lock = NSLock()
        private var made = 0
        private var live = 0

        fileprivate func noteMade() {
            lock.lock(); defer { lock.unlock() }
            made += 1
            live += 1
        }

        fileprivate func noteFreed() {
            lock.lock(); defer { lock.unlock() }
            live -= 1
        }

        /// How many per-connection state objects exist right now.
        var liveCount: Int {
            lock.lock(); defer { lock.unlock() }
            return live
        }

        /// How many have been made since this listener was created.
        var createdCount: Int {
            lock.lock(); defer { lock.unlock() }
            return made
        }
    }

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
        private let census: ConnectionCensus

        init(census: ConnectionCensus) {
            self.census = census
            census.noteMade()
        }

        deinit { census.noteFreed() }

        /// True exactly once. The idle timer and the final frame race each
        /// other, and the connection slot must come back exactly one time.
        func claimRelease() -> Bool {
            if released { return false }
            released = true
            return true
        }
    }

    private func accept(_ connection: NWConnection,
                        onEvent: @escaping @Sendable (AgentTool, HookEvent) -> Void) {
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

        let state = ConnectionState(census: connectionCensus)
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
        // Cancelling is NOT releasing. The work item's block captures `state`
        // strongly, and `state` owns the item, so leaving this set keeps
        // `state -> timeout -> block -> state` alive as an island nothing can
        // reach and nothing ever frees. `state.framer` holds the whole raw POST,
        // so every served request would pin its bytes for the life of the
        // process. Measured before this line existed: 0 of 2200 states freed.
        state.timeout = nil
        lock.lock()
        // Clamped because `stop()` zeroes the counter while connections may
        // still be draining.
        activeConnections = max(0, activeConnections - 1)
        lock.unlock()
        connection.cancel()
    }

    /// The most bytes one `receive` may hand back at a time.
    ///
    /// Deliberately NOT `HTTPRequestFramer.maximumBytes`, which this used to be.
    /// The two answer different questions. That constant is a PROTOCOL limit —
    /// how large one request may be. This one is a TRANSPORT limit — how much of
    /// that request may arrive in a single delivery. Tying the second to the
    /// first means every rise in the request cap silently retunes the socket.
    ///
    /// It matters in bytes, not only in tidiness. The framer refuses only AFTER
    /// it appends, so a connection peaks at `maximumBytes + receiveChunkBytes`.
    /// With `defaultMaximumConnections` at 32 and the cap now 1 MiB, holding
    /// this at 64 KiB keeps the worst case near 34 MiB, where copying the cap
    /// here would allow 64 MiB — in an app that is meant to stay invisible.
    ///
    /// A smaller value costs more receives, never a stalled read:
    /// `minimumIncompleteLength` is 1, so each receive returns as soon as any
    /// byte is available and never waits for this many.
    private static let receiveChunkBytes = 65_536

    private func receive(_ connection: NWConnection,
                         state: ConnectionState,
                         onEvent: @escaping @Sendable (AgentTool, HookEvent) -> Void) {
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: Self.receiveChunkBytes) {
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
                    // THE ROUTING LINE BETWEEN THE TWO CHANNELS, and it comes
                    // first so that everything below it is the hook channel and
                    // nothing else. `readEndpoint` resolves to no `AgentTool`,
                    // so a read can never fall through into the path that mints
                    // sessions, and a hook post can never reach the one builder
                    // in this file that can carry a body.
                    if state.framer.requestTarget == Self.readEndpoint {
                        self.answerRead(connection,
                                        method: state.framer.requestMethod,
                                        state: state)
                        return
                    }

                    // A payload that will not decode is DROPPED, and the
                    // listener survives. Cancelling here would let one malformed
                    // post silently stop ingest for the session while the panel
                    // kept looking healthy.
                    //
                    // The endpoint is read BEFORE the body. It is how the sender
                    // declares which agent it is, and a payload whose origin is
                    // unknown is refused rather than attributed to a default:
                    // the wrong tool drives the wrong state machine silently,
                    // which is worse than a visible 400. See
                    // `AgentTool.declared(byEndpoint:)`.
                    guard let target = state.framer.requestTarget,
                          let tool = AgentTool.declared(byEndpoint: target) else {
                        self.respond(connection, status: "404 Not Found", state: state)
                        return
                    }

                    // The method is checked AFTER the target resolves, and only
                    // then. 405 asserts that this resource exists and rejects
                    // the verb, so a path serving nothing stays a 404; and a
                    // request line the framer could not parse has already left
                    // through that 404 above, which is what it did before this
                    // check existed. The refusal is for a WRONG method, not a
                    // new answer for a malformed request.
                    //
                    // Compared EXACTLY. RFC 9110 §9.1 makes methods
                    // case-sensitive, so `post` is not `POST`. The framer
                    // lowercases field names a few lines away under §5.1, which
                    // makes those case-insensitive — the two are correctly
                    // different and must not be made to match.
                    //
                    // This makes an existing statement enforceable rather than
                    // adding a defence: every snippet this project emits, and
                    // docs/QUICKSTART.md, already specify `-X POST`. It is not
                    // a privilege boundary. Design §4.1 says plainly that any
                    // process running as this user can post here, and the unix
                    // socket's filesystem permissions are what bound that.
                    guard state.framer.requestMethod == "POST" else {
                        // RFC 9110 §15.5.6 requires `Allow` on a 405.
                        self.respond(connection, status: "405 Method Not Allowed",
                                     allow: "POST", state: state)
                        return
                    }

                    if let event = Self.decode(body, from: tool) {
                        onEvent(tool, event)
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
                         allow: String? = nil, state: ConnectionState) {
        connection.send(content: Self.response(status, allow: allow),
                        completion: .contentProcessed { [weak self] _ in
                            guard let self else { connection.cancel(); return }
                            self.finish(connection, state: state)
                        })
    }

    /// Answers the read route, and refuses everything that is not a read.
    ///
    /// Issue #9 answer 1: READ-ONLY. There is no write route and no control
    /// route, so every other verb is refused HERE, before the answer is asked
    /// for — a refusal that had already read the state would be a channel
    /// answering to a verb nobody documented.
    ///
    /// Compared EXACTLY, for the reason the hook channel's method check gives:
    /// RFC 9110 §9.1 makes methods case-sensitive, so `get` is not `GET`.
    ///
    /// Every refusal below goes through `respond`, which cannot carry a body.
    /// The only thing in this file that can is one line down from here, and
    /// this method is its only caller.
    private func answerRead(_ connection: NWConnection, method: String?,
                            state: ConnectionState) {
        guard method == "GET" else {
            // RFC 9110 §15.5.6 requires `Allow` on a 405, and it names GET
            // rather than the hook channel's POST: this resource exists and
            // serves one verb.
            respond(connection, status: "405 Method Not Allowed",
                    allow: "GET", state: state)
            return
        }

        lock.lock()
        let answer = statusAnswer
        lock.unlock()

        // 503 and NOT `200 {}`. Nothing has been wired, or the model it was
        // wired to has gone, and an empty object is a confident claim that
        // coffee-bar is holding nothing and tracking nothing — which a reader
        // cannot tell from the truth. Silence is the honest answer, and it is
        // the same one an unbound socket gives.
        guard let status = answer?() else {
            respond(connection, status: "503 Service Unavailable", state: state)
            return
        }

        // `.sortedKeys`, so two reads of the same state are the same bytes and
        // a reader diffing them sees only what changed.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let json = try? encoder.encode(status) else {
            // Unreachable for a payload of counts, words and flags, and handled
            // anyway: the alternative is a `try!` that takes the menu-bar app
            // down, and this app holds the power assertion.
            respond(connection, status: "500 Internal Server Error", state: state)
            return
        }

        respond(connection, status: "200 OK", json: json, state: state)
    }

    /// The ONE response path in this file that carries a body, and it serves
    /// `readEndpoint` alone.
    ///
    /// **Read `response(_:allow:)` below before adding a second caller.** The
    /// hook channel answers with a zero-length body on every code path, because
    /// Claude Code executes hooks and can act on what they print: a body there
    /// is coffee-bar talking into an agent nobody asked it to talk to.
    /// `everyAnswerTheEventPathGivesCarriesNoBody` and
    /// `aConnectionRefusedOverTheCapAlsoCarriesNoBody` measure that on the
    /// wire, and they are what stands in for the structural guarantee this
    /// method removed.
    private func respond(_ connection: NWConnection, status: String,
                         json: Data, state: ConnectionState) {
        connection.send(content: Self.response(status, json: json),
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

    /// `allow` names the methods a resource does accept, and exists for one
    /// status: RFC 9110 §15.5.6 requires `Allow` on a 405. It is a named
    /// parameter rather than a general list of extra headers because there is
    /// one header to send and one status that must send it; the other six
    /// statuses this file emits pass `nil` and are unchanged on the wire.
    private static func response(_ status: String, allow: String? = nil) -> Data {
        let allowed = allow.map { "Allow: \($0)\r\n" } ?? ""
        return Data("HTTP/1.1 \(status)\r\n\(allowed)Content-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }

    /// The read route's answer, headers and body.
    ///
    /// Kept apart from `response(_:allow:)` rather than folded into it behind a
    /// defaulted `body` parameter, and that separation is the point. The hook
    /// channel's builder has NO WAY to carry a body — not a parameter it
    /// happens not to pass — so the promise `SECURITY.md` makes about that
    /// channel survives a maintainer who has not read this file.
    ///
    /// The length is measured from the bytes rather than declared beside them.
    /// A `Content-Length` that disagrees with what follows makes a reader hang
    /// waiting for bytes that never come, or truncate the answer.
    private static func response(_ status: String, json: Data) -> Data {
        var answer = Data(("HTTP/1.1 \(status)\r\n"
                           + "Content-Type: application/json\r\n"
                           + "Content-Length: \(json.count)\r\n"
                           + "Connection: close\r\n\r\n").utf8)
        answer.append(json)
        return answer
    }
}
