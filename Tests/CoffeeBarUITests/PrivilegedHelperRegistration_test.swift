// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import CoffeeBarCore
@testable import CoffeeBarUI

/// What a click on the button tells the user when the helper is not installed
/// yet.
///
/// `PrivilegedHelperClient_test.swift` decides whether the button is OFFERED —
/// the signature gate, and the sentences each availability carries. This file
/// decides what the FIRST click says, which is a different question and the one
/// every new user meets.
///
/// The defect it was written against: an `SMAppService` **daemon** gets no modal
/// prompt. macOS wants the approval in System Settings › General › Login Items
/// & Extensions, so on a first click `register()` throws and the window showed
/// the raw POSIX error —
/// "macOS refused to install the helper: The operation couldn't be completed.
/// Operation not permitted" — with no hint that there is a switch to flip.
/// Measured: `smd` logged `Found status: 3` (`.notFound`) at that click, so the
/// `.requiresApproval` branch that already held the right words was never
/// reached. It was not a missing sentence; it was an unreachable one.
///
/// **No end-to-end re-test is available for this.** Approval has already been
/// granted on the development machine, and revoking it means `sfltool resetbtm`,
/// which is system-wide and destructive. So the branch is driven through
/// `HelperRegistering` instead.

/// EPERM, spelled the way macOS spelled it to the user.
///
/// `SMAppService.register()` threw a plain POSIX error and the window rendered
/// its `localizedDescription`. That text is asserted PRESENT by
/// `aFailureThatIsNotAboutApprovalIsStillReportedVerbatim` and asserted ABSENT
/// by the approval check — so the "does not contain" half is over a string this
/// fixture is proven to carry, rather than over one it never had.
private let permissionDenied = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))

/// An `SMAppService` that answers a scripted status and can be made to throw.
///
/// **The status MOVES, and that is the whole fixture.** A double with one fixed
/// status cannot express what macOS actually does: the registration is refused
/// and the job goes to `.requiresApproval` in the same breath, so the question
/// "is this failure about approval" can only be answered AFTER the throw. A
/// check driven by a fixed-status double would pass over the defect.
private final class StubRegistration: HelperRegistering, @unchecked Sendable {
    private let before: HelperRegistrationState
    private let after: HelperRegistrationState
    private let failure: (any Error)?
    private var hasRegistered = false
    private(set) var registerCalls = 0

    init(_ before: HelperRegistrationState,
         failingWith failure: (any Error)? = nil,
         thenReporting after: HelperRegistrationState) {
        self.before = before
        self.failure = failure
        self.after = after
    }

    var registrationState: HelperRegistrationState { hasRegistered ? after : before }

    func register() throws {
        registerCalls += 1
        hasRegistered = true
        if let failure { throw failure }
    }
}

/// The refusal sentence, or a failure naming what came back instead.
private func refusal(_ outcome: HelperArmOutcome?,
                     _ comment: Comment,
                     sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
    let outcome = try #require(outcome, comment, sourceLocation: sourceLocation)
    guard case .refused(let reason) = outcome else {
        Issue.record("expected a refusal, got \(outcome)", sourceLocation: sourceLocation)
        return ""
    }
    return reason
}

@Test func aRegistrationRefusedForApprovalTellsTheUserWhereToApprove() throws {
    // Named bug, and it is EVERY new user's first click: `register()` throws
    // because a daemon needs approval nobody has granted yet, and the raw POSIX
    // error goes to the window. "Operation not permitted" names no operation the
    // user performed, no permission they can grant, and no place to go — and
    // the app already had the right sentence, three lines up, behind a branch
    // this path never reaches.
    let service = StubRegistration(.other,
                                   failingWith: permissionDenied,
                                   thenReporting: .requiresApproval)

    let reason = try refusal(PrivilegedHelperClient.outcome(ofRegistering: service),
                             "a registration macOS refused must refuse the click too")

    // It TRIED. A guidance sentence returned without attempting the
    // registration would satisfy every assertion below while quietly making the
    // button do nothing on the machines where it would have worked.
    #expect(service.registerCalls == 1)

    // WHERE to go, and it takes both halves: macOS puts this under
    // System Settings › General › Login Items & Extensions, and a sentence
    // naming only the app is not something a user can act on.
    #expect(reason.contains("System Settings"))
    #expect(reason.contains("Login Items"))

    // The discriminating half. This is the literal the user was shown, and it
    // is what the fix has to stop shipping.
    #expect(!reason.contains("Operation not permitted"), """
        the click still surfaces macOS's raw POSIX error: \(reason)
        """)
}

@Test func aFailureThatIsNotAboutApprovalIsStillReportedVerbatim() throws {
    // THE CONTROL, and it does two jobs.
    //
    // It proves the fixture DISCRIMINATES: the same error object, thrown by the
    // same stub, does surface "Operation not permitted" when the status has not
    // moved to `.requiresApproval`. Without this, the "does not contain"
    // assertion above could be green over a string that fixture never carried,
    // which is a guard that cannot fail.
    //
    // And it names the over-fix: a catch block that answers with the approval
    // guidance unconditionally. Every failure would then read as "approve it in
    // System Settings", including the ones no approval will fix — a bad plist
    // name, a bundle macOS will not verify — and the user follows advice that
    // cannot work.
    let service = StubRegistration(.other,
                                   failingWith: permissionDenied,
                                   thenReporting: .other)

    let reason = try refusal(PrivilegedHelperClient.outcome(ofRegistering: service),
                             "a registration that threw must refuse the click")

    #expect(service.registerCalls == 1)
    #expect(reason.contains("Operation not permitted"), """
        the failure macOS reported was replaced with something else: \(reason)
        """)
    #expect(!reason.contains("System Settings"), """
        a failure that approval cannot fix is telling the user to go and approve \
        something: \(reason)
        """)
}

@Test func anApprovalAlreadyOutstandingIsNotAskedForTwice() throws {
    // The branch that was already right, pinned so the fix does not swallow it.
    //
    // Named bug: the re-read replaces this branch rather than joining it, and a
    // user who has been told to approve gets a second `register()` on every
    // click. Nothing here retries and nothing here loops — asking again is how
    // a prompt becomes a nag.
    let service = StubRegistration(.requiresApproval, thenReporting: .requiresApproval)

    let reason = try refusal(PrivilegedHelperClient.outcome(ofRegistering: service),
                             "a service awaiting approval must refuse the click")

    #expect(service.registerCalls == 0)
    #expect(reason.contains("System Settings"))
    #expect(reason.contains("Login Items"))
}

@Test func anAlreadyEnabledHelperIsNotRegisteredAgain() throws {
    // The ordinary case on every launch after the first. `register()` throws
    // once the job is already registered, so a path that called it here would
    // show an error sheet to a user whose helper is working.
    let service = StubRegistration(.enabled, thenReporting: .enabled)

    #expect(PrivilegedHelperClient.outcome(ofRegistering: service) == nil)
    #expect(service.registerCalls == 0)
}

@Test func aRegistrationThatSucceedsRefusesNothing() throws {
    // The positive half. Without it every check in this file is satisfied by an
    // `outcome(ofRegistering:)` that refuses unconditionally — a button that
    // never works, reported as four passing guards.
    let service = StubRegistration(.other, thenReporting: .enabled)

    #expect(PrivilegedHelperClient.outcome(ofRegistering: service) == nil)
    #expect(service.registerCalls == 1)
}
