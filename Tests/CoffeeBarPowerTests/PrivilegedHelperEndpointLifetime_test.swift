// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import CoffeeBarCore
@testable import CoffeeBarPower

/// Whether the object that answers for the root daemon is still there to answer.
///
/// `PrivilegedHelperPeerGate_test.swift` decides what happens to a connection
/// the delegate is handed. This file decides whether the delegate EXISTS when
/// one arrives, which is a question no check in this package could ask and
/// which the shipped daemon answered "no" to.
///
/// The defect it was written against: `serveForever()` said
/// `PrivilegedHelperEndpoint(exporting: self).resume()`. The endpoint was a
/// temporary, its only strong reference died at the end of that statement, ARC
/// freed it, and `NSXPCListener.delegate` — which `NSXPCConnection.h` declares
/// `weak` and documents as "if no delegate is set, all new connections will be
/// rejected" — went nil. Measured on the shipped build 2026-08-16: `launchd`
/// spawned the helper, it stayed running, and every client got
/// `Peer connection was rejected by the listener (xpc_connection_cancel())`
/// out of `libxpc` with nothing logged on the helper's side, because
/// `listener(_:shouldAcceptNewConnection:)` never ran.
///
/// Every existing check passed. `anIncomingConnectionIsPinnedBeforeItIsResumed`
/// drives a `PinnableConnection` double and asserts the gate's ORDER — it never
/// had a listener to ask about, so the seam that made the pin testable is the
/// seam that hid this.

/// A listener that records, and that holds its delegate exactly as weakly as
/// the real one does.
///
/// **`weak` is the fixture, not a detail.** Held strongly, this double would
/// report a delegate that the real `NSXPCListener` has already dropped, and the
/// two checks below would pass over the shipped defect —
/// `anEndpointThatWasNeverResumedIsNotKeptAlive` is here to prove it is really
/// weak rather than to leave that resting on a keyword nobody re-reads.
private final class RecordingListener: ResumableListener, @unchecked Sendable {
    weak var delegate: (any NSXPCListenerDelegate)?
    private(set) var resumeCount = 0

    func resume() { resumeCount += 1 }
}

/// Something for the endpoint to export. Its lifetime is the subject here; what
/// it carries is `PrivilegedHelperService_test.swift`'s.
private final class SilentControl: NSObject, LidClosedControl, @unchecked Sendable {
    func arm(ttlSeconds: Int, reply: @escaping @Sendable (Int, String?) -> Void) {
        reply(0, nil)
    }

    func revert(reply: @escaping @Sendable (Bool, String?) -> Void) {
        reply(false, nil)
    }
}

/// A weak handle that survives the frame the endpoint was built in.
private final class WeakEndpoint {
    weak var value: PrivilegedHelperEndpoint?
    init(_ value: PrivilegedHelperEndpoint?) { self.value = value }
}

/// Builds an endpoint, resumes it, and drops the only strong reference the
/// caller ever held — the exact shape `serveForever()` shipped.
///
/// A FUNCTION rather than a `do { }` block inside the check. A scope-based
/// version rests on where the optimiser decides to release a local that is
/// still in scope; a frame that has returned has no locals left to argue about,
/// at any optimisation level.
private func resumeAndForget(on listener: RecordingListener) -> WeakEndpoint {
    let endpoint = PrivilegedHelperEndpoint(exporting: SilentControl(), listener: listener)
    endpoint.resume()
    return WeakEndpoint(endpoint)
}

/// The same, without the `resume()`. The control's fixture.
///
/// The endpoint is BOUND rather than passed straight into `WeakEndpoint(_:)`.
/// Written inline it is a temporary the compiler can see dying inside the
/// expression, and it says so — "weak reference will always be nil because the
/// referenced object is deallocated here" — which is a warning on a tree that
/// carries none, over a fact this check is supposed to MEASURE rather than be
/// told at compile time.
private func buildAndForget(on listener: RecordingListener) -> WeakEndpoint {
    let endpoint = PrivilegedHelperEndpoint(exporting: SilentControl(), listener: listener)
    return WeakEndpoint(endpoint)
}

@Test func theEndpointOutlivesTheScopeThatResumedIt() throws {
    // Named bug: `PrivilegedHelperEndpoint(exporting: self).resume()`. It
    // compiles, `launchd` reports the job healthy, `launchctl` shows the
    // endpoint active and managed, the helper never crashes and logs nothing —
    // and every single client is refused, because the delegate the listener
    // needs was freed one statement after it was set.
    //
    // The lifetime is asserted rather than the delegate here, because it is the
    // mechanism: a listener resumed by an object nothing retains is the whole
    // defect, and `aResumedEndpointIsStillTheListenersDelegate` states the
    // consequence macOS actually reads.
    let listener = RecordingListener()
    let endpoint = resumeAndForget(on: listener)

    // Not decoration. An endpoint that never reached `listener.resume()`
    // publishes nothing, and would satisfy a lifetime assertion by being kept
    // alive for a listener that was never started.
    #expect(listener.resumeCount == 1)

    #expect(endpoint.value != nil, """
        the endpoint was freed as soon as the frame that resumed it returned. \
        NSXPCListener holds its delegate weakly, so the delegate is now nil and \
        macOS refuses every incoming connection — the daemon runs, reports \
        healthy, and answers nobody.
        """)
}

@Test func aResumedEndpointIsStillTheListenersDelegate() throws {
    // The property macOS reads, stated over the mechanism above.
    // `NSXPCConnection.h`: "The delegate for the connection listener. If no
    // delegate is set, all new connections will be rejected."
    //
    // Named bug this catches that the lifetime check alone does not: an
    // endpoint kept alive by some other route while `delegate` is assigned
    // somewhere the listener no longer holds — reordered init, a second
    // listener built after the assignment, a `delegate = nil` on the way into
    // `resume()`. The object being alive and the listener having a delegate are
    // two different claims.
    let listener = RecordingListener()
    _ = resumeAndForget(on: listener)

    #expect(listener.resumeCount == 1)

    #expect(listener.delegate != nil, """
        the resumed listener has no delegate. NSXPCConnection.h: "If no delegate \
        is set, all new connections will be rejected." The daemon is up and \
        refuses every client.
        """)
}

@Test func anEndpointThatWasNeverResumedIsNotKeptAlive() throws {
    // THE CONTROL, and the reason the two checks above mean anything.
    //
    // Both of them are satisfied by a `RecordingListener` that holds its
    // delegate STRONGLY — which is what a well-meaning edit to the double would
    // do, and which the real `NSXPCListener` does not. This check fails on that
    // double: a listener with a strong delegate keeps an unresumed endpoint
    // alive, and the two assertions below go red.
    //
    // It fails on the other half too, and that half is a real hazard rather
    // than a hypothetical: retaining in `init` instead of in `resume()` also
    // makes both checks above pass, and leaks every endpoint anybody
    // constructs. Only a resumed one is published, so only a resumed one is
    // owed a process-long life.
    //
    // It passes before the fix as well as after, which is what a control is
    // for: it is not the RED, it is what stops the RED being satisfied cheaply.
    let listener = RecordingListener()
    let endpoint = buildAndForget(on: listener)

    #expect(listener.resumeCount == 0)

    #expect(endpoint.value == nil, """
        an endpoint that was never resumed is being kept alive. Either the \
        retention moved into init — which leaks every endpoint constructed — or \
        RecordingListener is holding its delegate strongly, in which case the \
        lifetime checks in this file are asserting nothing.
        """)

    #expect(listener.delegate == nil, """
        RecordingListener is holding its delegate strongly. NSXPCListener holds \
        it weakly, so this double no longer models the object under test and the \
        lifetime checks in this file pass vacuously.
        """)
}
