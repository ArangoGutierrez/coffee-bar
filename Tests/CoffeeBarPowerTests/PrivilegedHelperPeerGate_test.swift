// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import CoffeeBarCore
@testable import CoffeeBarPower

/// Who gets to speak on the channel, and in what ORDER the question is asked.
///
/// `PrivilegedHelperIdentity_test.swift` decides whether the requirement
/// STRINGS pin the right team and the right bundle. This file decides whether
/// the shipped code applies them — to the right end of the channel, and before
/// the channel carries anything.
///
/// The seam is `PinnableConnection` rather than `NSXPCConnection`, and that is
/// the only way this is testable at all: a real connection needs a live Mach
/// service, which needs a registered daemon, which needs a code-signed bundle
/// this build does not produce. The double records what it was told to do, in
/// order.

/// One thing that happened to a connection.
private enum ConnectionEvent: Equatable {
    case pinned(String)
    case resumed
}

/// A connection that does nothing but remember, in order.
private final class RecordingConnection: PinnableConnection, @unchecked Sendable {
    private(set) var events: [ConnectionEvent] = []

    func setCodeSigningRequirement(_ requirement: String) {
        events.append(.pinned(requirement))
    }

    func resume() {
        events.append(.resumed)
    }
}

@Test func anIncomingConnectionIsPinnedBeforeItIsResumed() throws {
    // Named bug, and it is a real ordering hazard rather than style: a resumed
    // NSXPCConnection begins dispatching messages that have already arrived.
    // Pinning it afterwards closes a door the caller is already through, and
    // the window is widest exactly when the machine is busy — which is when a
    // privileged helper is worth attacking.
    let connection = RecordingConnection()

    #expect(PrivilegedHelperPeerGate.acceptFromApp(connection))

    #expect(connection.events == [
        .pinned(PrivilegedHelperIdentity.appPeerRequirement),
        .resumed,
    ])
}

@Test func theDaemonSideDemandsTheAPPSignature() throws {
    // Named bug: the two requirements are swapped. Each end then authenticates
    // ITSELF — the daemon demands the helper's identifier, which the helper it
    // is answering does not have, and the whole channel is pinned to a program
    // that never dials it. It compiles, both constants are "used", and the pin
    // is inert.
    let connection = RecordingConnection()
    _ = PrivilegedHelperPeerGate.acceptFromApp(connection)

    #expect(connection.events.contains(.pinned(PrivilegedHelperIdentity.appPeerRequirement)))
    #expect(!connection.events.contains(.pinned(PrivilegedHelperIdentity.helperPeerRequirement)))
}

@Test func theAppSideDemandsTheHELPERSignature() throws {
    // The other half of the swap above, and the direction a user is exposed to
    // first: an app that does not pin the daemon it dialled will hand its arm
    // request to whatever has claimed the Mach name.
    let connection = RecordingConnection()
    PrivilegedHelperPeerGate.dialHelper(connection)

    #expect(connection.events == [
        .pinned(PrivilegedHelperIdentity.helperPeerRequirement),
        .resumed,
    ])
}

@Test func neitherEndIsEverResumedUnpinned() throws {
    // The property both checks above are instances of, stated once over both
    // call sites: no connection this package configures reaches `.resumed`
    // without a `.pinned` before it. Named bug: a third call site is added
    // later — a reply channel, an endpoint handed across — and it resumes bare.
    let inbound = RecordingConnection()
    _ = PrivilegedHelperPeerGate.acceptFromApp(inbound)
    let outbound = RecordingConnection()
    PrivilegedHelperPeerGate.dialHelper(outbound)

    for connection in [inbound, outbound] {
        let resumeIndex = try #require(connection.events.firstIndex(of: .resumed))
        let pinIndex = try #require(connection.events.firstIndex {
            if case .pinned = $0 { return true }
            return false
        })
        #expect(pinIndex < resumeIndex)
    }
}

@Test func theServeVerbIsRootOnlyAndIsNotTheDefault() throws {
    // `serve` is the verb launchd starts for the SMAppService job, and it is
    // the first verb in this binary that LISTENS. Two named bugs:
    //
    //  - it is advertised as unprivileged, so a user runs it in their own
    //    shell, it publishes nothing, and they conclude the feature is broken;
    //  - it becomes the default, so a bare `coffee-bar-probe` — a mistyped
    //    flag, a stray argument — starts a listener nobody asked for.
    #expect(ProbeVerb.serve.requiresRoot)
    #expect(ProbeVerb.default != ProbeVerb.serve)
}

@Test func theSudoArmPathIsUnchangedByTheHelper() throws {
    // #71b scope: BOTH PATHS COEXIST. A user who already ran
    // `sudo coffee-bar-probe arm` must not be broken by an app that gained a
    // button, and a Homebrew user gets an ad-hoc bundle that cannot register a
    // helper at all — the CLI is the only route they have.
    //
    // Named bug: `arm` is quietly re-pointed at the XPC channel, so the
    // privileged CLI stops working on exactly the installs that need it.
    #expect(ProbeVerb.arm.requiresRoot)
    #expect(ProbeVerb.allCases.map(\.rawValue).contains("arm"))
    #expect(LaunchDaemonInstaller.label == "com.coffeebar.probewatchdog")
    #expect(LaunchDaemonInstaller.systemPlistURL.path
            == "/Library/LaunchDaemons/com.coffeebar.probewatchdog.plist")
}
