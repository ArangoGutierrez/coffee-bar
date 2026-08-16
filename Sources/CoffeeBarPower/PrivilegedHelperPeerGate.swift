// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoffeeBarCore

/// The ONE file in this package that may create, accept or configure an XPC
/// connection.
///
/// That is enforced rather than intended: `privilegedHelperEntitlement` in
/// `Tests/CoffeeBarUITests/AppLayerBoundary_test.swift` relieves this file — and
/// only this file — of the ban on `NSXPCListener`, `NSXPCConnection`,
/// `setCodeSigningRequirement` and `machServiceName`, and
/// `theEntitledChannelFilePinsEveryPeerItOpens` bounds what that bought. The
/// point of the concentration is that every peer pin in this product sits in one
/// file a reviewer can read end to end, rather than being a line somebody has to
/// notice in a view controller.
///
/// It may not name `SMAppService`. Registering the daemon is
/// `PrivilegedHelperClient`'s job, and that file may name nothing else — it
/// holds no connection object, because this file hands it an opaque channel, so
/// there is nowhere in it to resume one unpinned.

/// The two things this file does to a connection, behind a protocol.
///
/// A seam, and it is the only reason any of this is testable. A real
/// `NSXPCConnection` needs a live Mach service, which needs a registered
/// daemon, which needs a code-signed app bundle — and `scripts/build-app.sh`
/// signs only when `SIGN_IDENTITY` is set, so a default dev build is ad-hoc and
/// can register nothing. Without this protocol the peer pin would be a line no
/// check in this repository could reach.
///
/// `NSXPCConnection` already declares both members with these exact signatures,
/// so the conformance below adds no code and cannot drift from what the real
/// object does.
public protocol PinnableConnection: AnyObject {
    /// Refuses any peer that does not satisfy `requirement`.
    func setCodeSigningRequirement(_ requirement: String)
    /// Starts carrying messages. Everything that bounds who may send them has
    /// to be in place before this.
    func resume()
}

extension NSXPCConnection: PinnableConnection {}

/// Who is allowed to speak, decided before anything is said.
///
/// **The ORDER is the property, not the pinning.** A resumed `NSXPCConnection`
/// begins dispatching messages that have already arrived, so pinning afterwards
/// closes a door the caller is already through — and that window is widest
/// exactly when the machine is busy, which is when a root helper is worth
/// attacking. `anIncomingConnectionIsPinnedBeforeItIsResumed` asserts the
/// sequence rather than the fact.
///
/// **Each end demands the OTHER program's signature.** Wiring both to one
/// requirement is the mistake that survives a smoke test: the two ends still
/// agree, both constants are still "used", and the pin authenticates nobody.
public enum PrivilegedHelperPeerGate {
    /// Configures a connection the root helper has just been handed.
    ///
    /// Returns `true` because the listener delegate has to answer with one.
    /// There is no branch here that returns `false`: a peer that fails the
    /// requirement is refused by the connection itself, which is the whole
    /// reason the requirement is set rather than a check being written by hand.
    /// A hand-rolled audit-token comparison is the thing this API exists to
    /// replace, and getting it subtly wrong is a well-travelled way to ship a
    /// root service that trusts the wrong process.
    @discardableResult
    public static func acceptFromApp(_ connection: any PinnableConnection) -> Bool {
        connection.setCodeSigningRequirement(PrivilegedHelperIdentity.appPeerRequirement)
        connection.resume()
        return true
    }

    /// Configures a connection the app has just opened to the root helper.
    public static func dialHelper(_ connection: any PinnableConnection) {
        connection.setCodeSigningRequirement(PrivilegedHelperIdentity.helperPeerRequirement)
        connection.resume()
    }
}

/// The root helper's side: publishes the endpoint and pins every caller.
///
/// Constructed by `coffee-bar-probe serve`, which is the verb `launchd` starts
/// for the registered job and which no user runs by hand.
public final class PrivilegedHelperEndpoint: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener: NSXPCListener
    private let exported: any LidClosedControl

    /// `exporting` is the object that actually does the work. Held as the
    /// protocol so the transport knows nothing about arming, and so the
    /// privileged logic stays in a type that has no opinion about XPC.
    public init(exporting object: any LidClosedControl) {
        self.listener = NSXPCListener(machServiceName: PrivilegedHelperIdentity.endpointName)
        self.exported = object
        super.init()
        self.listener.delegate = self
    }

    /// Starts listening. Never returns to the caller's control flow in the
    /// daemon — `serve` parks after this.
    public func resume() {
        listener.resume()
    }

    public func listener(_ listener: NSXPCListener,
                         shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // The interface and the object are attached BEFORE the gate resumes the
        // connection. Attaching them afterwards races the first message: the
        // connection would be live with no exported object and the caller's
        // invocation would fail with an error that names neither side.
        newConnection.exportedInterface = NSXPCInterface(with: LidClosedControl.self)
        newConnection.exportedObject = exported
        return PrivilegedHelperPeerGate.acceptFromApp(newConnection)
    }
}

/// The app's side: an opaque handle on a pinned connection.
///
/// Opaque on purpose. `PrivilegedHelperClient` never sees an
/// `NSXPCConnection`, so there is no object in the app layer on which somebody
/// could call `resume()` without the pin, and the boundary guard can hold the
/// app layer to naming `SMAppService` and nothing else.
public final class PrivilegedHelperChannel: @unchecked Sendable {
    private let connection: NSXPCConnection

    public init() {
        connection = NSXPCConnection(machServiceName: PrivilegedHelperIdentity.endpointName,
                                     options: .privileged)
        // Set before the gate resumes, for the reason the listener sets its
        // exported interface first.
        connection.remoteObjectInterface = NSXPCInterface(with: LidClosedControl.self)
        PrivilegedHelperPeerGate.dialHelper(connection)
    }

    /// The remote object, or `nil` when the proxy cannot be formed.
    ///
    /// `remoteObjectProxyWithErrorHandler` rather than the plain proxy: a peer
    /// that fails the pin surfaces as a connection error on the handler, and
    /// with the plain proxy that error has nowhere to go — the call simply does
    /// nothing and the button spins for ever.
    public func control(
        onFailure: @escaping @Sendable (any Error) -> Void
    ) -> (any LidClosedControl)? {
        connection.remoteObjectProxyWithErrorHandler(onFailure) as? any LidClosedControl
    }

    public func invalidate() {
        connection.invalidate()
    }
}
