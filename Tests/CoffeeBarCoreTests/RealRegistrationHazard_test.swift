// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import CoffeeBarTestSupport

// MARK: - The thing no check in this package may ever do

/// Refuses any test that could make `swift test` perform a REAL registration of
/// the privileged helper on the machine running it.
///
/// **The hazard, and it is new as of #71h.** `PrivilegedHelperClient.register()`
/// opens with `guard availability() == .registrable`. `availability()` reads the
/// team identifier through the `signature` seam, and that seam became injectable
/// in #71h so a cache could be counted. Before it existed the guard closed one
/// line in for everything in this package — the `swift test` runner is
/// linker-signed ad-hoc and names no team — and the body below it was
/// unreachable. It is reachable now:
///
/// ```swift
/// let client = PrivilegedHelperClient(
///     signature: RunningSignature { PrivilegedHelperIdentity.teamIdentifier })
/// _ = client.register()
/// ```
///
/// That opens the gate and reaches `try service.register()` on the REAL
/// `SMAppService`, because `register()` spells
/// `SMAppService.daemon(plistName:)` inline and does NOT go through the `daemon`
/// seam beside it. `arm(seconds:)` is the same hazard one call further out: it
/// opens with `if let refusal = register()`.
///
/// **Why this is worth a guard rather than a comment.** The consequence is not a
/// red test. It is an item filed into the maintainer's System Settings › General
/// › Login Items & Extensions, and a registration already granted there being
/// burnt — taking it back needs `sfltool resetbtm` and re-approving by hand.
/// A machine-wide side effect from `swift test` is not something the next author
/// finds out about from a failing assertion.
///
/// The risk is primed rather than hypothetical: #71h and #71i added two seams to
/// this exact file, so "let me drive `register()` too" is the obvious next move.
/// And this branch's own headline defect shipped because the rule was left as
/// something the caller had to remember.
///
/// ## What makes the shape dangerous is the PAIR, not the signature
///
/// This is the trap a first draft of this guard falls into. Four tests in
/// `Tests/CoffeeBarUITests/PrivilegedHelperClient_test.swift` ALREADY build a
/// `RunningSignature` that yields the real team identifier:
///
/// - `theSignatureIsReadOnceHoweverOftenAvailabilityIsAsked`
/// - `theRegistrationStateIsAskedAfreshOnEveryCallUnlikeTheSignature`
/// - `aHelperEnabledWhileTheAppRunsIsReportedWithoutARelaunch`
/// - `aHelperWaitingOnTheUsersApprovalIsNotReportedAsActive`
///
/// Every one of them is SAFE, and they have to stay green. They call
/// `availability()` and `registeredHelperIsActive()`, and the latter reads
/// through the injected `daemon` seam, so macOS is never asked to install
/// anything. A guard that reddened on a real-team signature alone would be red
/// on the suite as it stands, and would be deleted by the first person it
/// annoyed.
///
/// So the offence is a real-team signature source AND a call into the
/// registration path, meeting in one scope.
///
/// ## What this guard does NOT catch — stated so nobody over-trusts it
///
/// 1. **A construction and a call split across two functions.** Scopes are found
///    by a line-oriented split on `func` declarations, not by parsing. A factory
///    `func armedClient() -> PrivilegedHelperClient` in one scope, called from a
///    `@Test` in another, pairs no signals and walks through. File-level
///    declarations ARE paired with every function, which covers the stored-property
///    version of the same trick, but a factory FUNCTION is not covered.
/// 2. **A team identifier that arrives indirectly.** Only the literal
///    `85FN4Z37V8` and the constant name `PrivilegedHelperIdentity.teamIdentifier`
///    are recognised. Reading the team out of a fixture file, or assembling the
///    string, defeats this.
/// 3. **A future entry point spelled differently.** The calls recognised are
///    `.register()`, `.arm(seconds:`, `.unregisterHelper()`, `.revert()` and the
///    direct `SMAppService.daemon(`/`.agent(`/`.loginItem(` constructions. A new
///    method on `PrivilegedHelperClient` that reaches the real service under
///    another name is unguarded until it is added to
///    `privilegedPathReachingCall`.
///    `ServingModel.removeRegisteredHelper()` is deliberately NOT on that list:
///    it reaches the client only through the `HelperRemovalControlling` seam,
///    whose
///    default is spelled in `ServingModel.swift` and not in any test.
/// 4. **Text inside a string literal.** The lexer strips comments and KEEPS
///    string literals on purpose, so a fixture STRING containing
///    `client.register()` beside a real-team signature reads as a real call and
///    is a FALSE POSITIVE. That direction is loud and is fixed by looking at the
///    report. The opposite — stripping literals — would hide the real thing, so
///    the noisy choice is the deliberate one.
/// 5. **This file.** It quotes every dangerous spelling as a fixture, so it
///    would report itself for ever. Skipped by repo-relative PATH from
///    `#filePath`, never a basename. The cost is real: a hazard written into
///    THIS file is unguarded.
/// 6. **How the runner is signed.** `PrivilegedHelperClient()` is flagged when it
///    meets a registration call, because its default `signature` is
///    `RunningSignature.shared`, which reads the REAL running binary. Under
///    `swift test` today that answers `nil` and the gate closes — but that is a
///    property of how the runner happens to be signed, not a guarantee, and this
///    scan cannot see it either way.

// MARK: - Reading a Swift file as scopes

/// The signals that make a scope dangerous, and the spellings they are found by.
///
/// Two independent halves. `realTeamSignature` opens the gate in
/// `availability()`; `privilegedPathReachingCall` walks through it. Neither is an
/// offence on its own and the suite contains the first one four times over.
private let realTeamSignatureSource = [
    // A `RunningSignature` handed the real team, in any body shape — the
    // one-liner and the multi-line closure that bumps a counter first.
    "PrivilegedHelperIdentity\\.teamIdentifier",
    "\"85FN4Z37V8\"",
    // The default client: `signature` is `RunningSignature.shared`, which reads
    // the real running binary rather than a stub.
    "PrivilegedHelperClient\\s*\\(\\s*\\)",
    "RunningSignature\\s*\\.\\s*shared",
    "signature\\s*:\\s*\\.shared",
]

/// A call that can reach the REAL privileged path on something this package did
/// not substitute.
///
/// **Renamed from `registrationReachingCall` when issue #71's removal landed,
/// because the set genuinely widened.** Three of these reach
/// `SMAppService` — `register()`, `arm(seconds:)` and `unregisterHelper()`. The
/// fourth, `revert()`, reaches no registration at all: it opens a channel to the
/// ROOT DAEMON and asks it to change a system power setting. Both are
/// machine-wide side effects from `swift test`, which is what this file is
/// about, and a list named for only one of them would invite the next author to
/// leave the other off.
///
/// A leading `.` is required and it is load-bearing: three test files declare
/// `func register() throws` or `func revert() async -> …` on a double, and a
/// declaration is not a call. `arm` is matched with its `seconds:` label ONLY —
/// `PrivilegedHelperService.arm(ttlSeconds:)` is a different type on the other
/// side of the XPC boundary and is driven ~20 times in `CoffeeBarPowerTests`,
/// which must stay green. `revert` is matched with EMPTY parentheses only, for
/// the same reason: `WatchdogDecision.revert(_:)` is an enum case driven ~30
/// times in `CoffeeBarCoreTests` and always carries an argument, and the
/// service's own `revert(reply:)` takes a closure.
private let privilegedPathReachingCall = [
    "\\.\\s*register\\s*\\(\\s*\\)",
    "\\.\\s*arm\\s*\\(\\s*seconds\\s*:",
    // Issue #71's removal path, and it is the same hazard pointed the other
    // way. `unregisterHelper()` opens with the same `availability()` guard and,
    // past it, reaches the `daemon` seam whose DEFAULT is the real
    // `SMAppService`. A test that hands in the real team and takes that default
    // unregisters the maintainer's helper for real, which costs a manual
    // approval cycle in System Settings to undo.
    //
    // The leading `.` does the same work it does above:
    // `HelperRemoval_test.swift` declares `func unregisterHelper() throws` on a
    // `HelperRemovalControlling` double, and a declaration is not a call. It is
    // the only real one in the tree: the other spellings live inside the fixture
    // STRINGS in this file, which is limit 4 above and not a second double.
    "\\.\\s*unregisterHelper\\s*\\(\\s*\\)",
    // Issue #71's revert, and the ONE entry here that reaches no registration.
    // Past `availability()` it opens a channel to the root daemon and asks it
    // to put `SleepDisabled` back. On a Mac with an approved helper that is a
    // live change to a system power setting, made by a test run.
    "\\.\\s*revert\\s*\\(\\s*\\)",
]

/// Building a REAL `SMAppService` inside a test, which is an offence on its own.
///
/// No pairing needed and no signature needed. `outcome(ofRegistering:)` takes a
/// service as a plain argument and calls `register()` on it, so a real service
/// constructed in a test is one call from a real registration with the
/// `availability()` gate bypassed entirely.
private let realServiceConstruction = "SMAppService\\s*\\.\\s*(?:daemon|agent|loginItem)\\s*\\("

/// Whether any of `patterns` appears in `code`.
private func anyMatch(_ patterns: [String], in code: String) -> Bool {
    patterns.contains { code.range(of: $0, options: .regularExpression) != nil }
}

/// A Swift file split into its file-level text and one chunk per function.
///
/// A LINE-ORIENTED split and not a parse: a line whose only content before
/// `func` is attributes and declaration modifiers opens a new chunk, which runs
/// to the next such line. A nested `func` therefore ends its parent's chunk
/// early, and a trailing closure after the last `func` stays with it. Both are
/// documented limits rather than bugs to fix here — the alternative is a Swift
/// parser, and this file is a guard, not a compiler.
func swiftScopes(_ code: String) -> (fileLevel: String, functions: [String]) {
    let opensAFunction = "^\\s*(?:(?:@\\w+(?:\\([^)]*\\))?|public|internal|private|fileprivate|"
        + "static|final|override|nonisolated|mutating|class|open)\\s+)*func\\s"

    var fileLevel: [String] = []
    var functions: [[String]] = []

    for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.range(of: opensAFunction, options: .regularExpression) != nil {
            functions.append([String(line)])
        } else if functions.isEmpty {
            fileLevel.append(String(line))
        } else {
            functions[functions.count - 1].append(String(line))
        }
    }

    return (fileLevel.joined(separator: "\n"),
            functions.map { $0.joined(separator: "\n") })
}

/// Every way `source` could make a real registration happen, as readable
/// reasons.
///
/// The file-level chunk is folded into EVERY function scope, because a client
/// built into a stored property at file level is in scope for all of them. A
/// signal found inside one function stays in that function.
func realRegistrationHazards(in source: String) -> [String] {
    let reading = swiftSourceReading(source)
    var hazards: [String] = []

    // A file the lexer cannot tokenise is a file this scan did not check, and
    // it says so rather than reporting green. Same one-sided refusal as issue
    // #54, for the same reason.
    if let suspect = reading.regexLiteralSuspect {
        hazards.append("""
            this scan REFUSES a verdict: the source carries what may be a bare \
            regex literal — \(suspect.debugDescription) — so the code and the \
            comments after it may be swapped and a real registration could be \
            hiding in what came back as a comment
            """)
        return hazards
    }

    let (fileLevel, functions) = swiftScopes(reading.code)

    if reading.code.range(of: realServiceConstruction, options: .regularExpression) != nil {
        hazards.append("""
            builds a REAL SMAppService. `outcome(ofRegistering:)` calls \
            `register()` on whatever service it is handed, so this is one call \
            from registering the helper on the machine running the suite — with \
            the `availability()` gate not even involved
            """)
    }

    for scope in [fileLevel] + functions {
        let code = scope == fileLevel ? fileLevel : fileLevel + "\n" + scope
        guard anyMatch(realTeamSignatureSource, in: code),
              anyMatch(privilegedPathReachingCall, in: code) else { continue }

        let name = scope.range(of: "func\\s+\\w+", options: .regularExpression)
            .map { String(scope[$0]).replacingOccurrences(of: "func ", with: "") }
            ?? "file level"
        hazards.append("""
            \(name): opens the `availability()` gate with the real team \
            identifier AND calls into the registration path. That reaches \
            `try service.register()` on the real SMAppService and registers the \
            helper on the machine running the suite
            """)
    }

    return hazards
}

// MARK: - The guards

@Test func noTestCanMakeTheSuiteRegisterTheHelperForReal() throws {
    let root = repoRoot()
    let files = try trackedTextFiles().filter {
        $0.hasPrefix("Tests/") && $0.hasSuffix(".swift")
    }

    // ANTI-VACUITY. A scan that resolved the wrong root reads nothing and
    // reports success. The named control is the file the hazard actually lives
    // next to — it holds all four safe real-team constructions — so a corpus
    // that misses it is a corpus that cannot see the thing this guard is for.
    #expect(files.count >= 20,
            "scanned \(files.count) Swift test files at \(root.path); this scan is reading almost nothing")
    #expect(files.contains("Tests/CoffeeBarUITests/PrivilegedHelperClient_test.swift"),
            "the corpus never reached the file the register() hazard is one line away from")

    // THE ONE FILE EXEMPTION, and it is this one — it quotes every dangerous
    // spelling as a fixture. A repo-relative PATH, never a basename.
    let selfPath = String(#filePath.dropFirst(root.path.count + 1))

    var unreadable: [String] = []
    var offenders: [String] = []

    for name in files where name != selfPath {
        guard let text = try? String(contentsOf: root.appending(path: name), encoding: .utf8) else {
            unreadable.append(name)
            continue
        }
        for hazard in realRegistrationHazards(in: text) {
            offenders.append("\(name): \(hazard)")
        }
    }

    #expect(offenders.isEmpty, """
        \(offenders.count) test(s) could make `swift test` register the privileged helper \
        FOR REAL on the machine running it. That files an item into System Settings › \
        General › Login Items & Extensions, and burns any registration already granted \
        there — taking it back needs `sfltool resetbtm` and re-approving by hand.
        Drive `outcome(ofRegistering:)` with a `HelperRegistering` double instead: it takes \
        the service as a plain argument and is the seam for exactly this.
        \(offenders.sorted().joined(separator: "\n"))
        """)

    #expect(unreadable.isEmpty, """
        \(unreadable.count) test file(s) could not be read as UTF-8, so this scan never \
        checked them: \(unreadable.sorted())
        An unread file is an unguarded file.
        """)
}

@Test func theDangerousConstructionIsReportedInTheShapeAnAuthorWouldWriteIt() {
    // The EXACT text of the test somebody is going to add, as a fixture rather
    // than as code — compiling it would be one `swift test` away from doing the
    // thing this file exists to prevent. The scan is textual, so the `@Test`
    // attribute is immaterial to detection and this fixture is the real
    // spelling in every way that the scan can see.
    let whatTheNextAuthorWrites = """
        @Test func theRegistrationOutcomeIsWhatMacOSSaid() {
            let client = PrivilegedHelperClient(
                signature: RunningSignature { PrivilegedHelperIdentity.teamIdentifier })
            #expect(client.register() == nil)
        }
        """

    let hazards = realRegistrationHazards(in: whatTheNextAuthorWrites)
    #expect(hazards.count == 1,
            "the plain dangerous construction was reported \(hazards.count) time(s): \(hazards)")
    #expect(hazards.first?.hasPrefix("theRegistrationOutcomeIsWhatMacOSSaid:") == true,
            "the report does not name the offending function: \(hazards)")

    // `arm(seconds:)` is the same hazard one call further out — it opens with
    // `if let refusal = register()`. Named bug: a guard that lists `.register()`
    // and forgets the method that calls it.
    let throughArm = """
        @Test func armingReportsWhatTheHelperSaid() async {
            let client = PrivilegedHelperClient(
                signature: RunningSignature { PrivilegedHelperIdentity.teamIdentifier })
            _ = await client.arm(seconds: 30)
        }
        """
    #expect(realRegistrationHazards(in: throughArm).count == 1,
            "the arm(seconds:) route was not reported")

    // The team spelled as its literal rather than through the constant.
    let literalTeam = """
        @Test func viaTheLiteral() {
            let client = PrivilegedHelperClient(signature: RunningSignature { "85FN4Z37V8" })
            _ = client.register()
        }
        """
    #expect(realRegistrationHazards(in: literalTeam).count == 1,
            "the team identifier written as a literal was not reported")

    // The default client, whose signature is the REAL running binary.
    let defaultClient = """
        @Test func viaTheDefaultInit() {
            _ = PrivilegedHelperClient().register()
        }
        """
    #expect(realRegistrationHazards(in: defaultClient).count == 1,
            "a default-constructed client reaching register() was not reported")

    // The stored-property version: the client is built ONCE at file level and
    // the call is in a function, so the two signals are never in the same
    // scope. This is the case the file-level fold exists for, and it is
    // asserted rather than merely claimed in the doc comment above — the
    // sibling limit (a factory FUNCTION) is documented as NOT caught, and the
    // difference between the two is only credible if this half is measured.
    let acrossFileLevelAndAFunction = """
        private let sharedClient = PrivilegedHelperClient(
            signature: RunningSignature { PrivilegedHelperIdentity.teamIdentifier })

        @Test func armingUsesTheSharedClient() async {
            _ = await sharedClient.arm(seconds: 30)
        }
        """
    #expect(realRegistrationHazards(in: acrossFileLevelAndAFunction).isEmpty == false,
            "a file-level dangerous client reached from a function was not reported")

    // A real service built in a test, which needs no signature at all: it goes
    // straight into `outcome(ofRegistering:)`, gate and all bypassed.
    let realService = """
        @Test func viaTheRealService() {
            _ = PrivilegedHelperClient.outcome(ofRegistering:
                SMAppService.daemon(plistName: PrivilegedHelperIdentity.daemonPlistName))
        }
        """
    #expect(realRegistrationHazards(in: realService).count >= 1,
            "a real SMAppService constructed inside a test was not reported")

    // THE DOCUMENTED HOLE, pinned so it cannot close silently. Limit 1 in the
    // doc comment above says a factory FUNCTION defeats the scope pairing, and
    // an unmeasured "does not catch" is the kind of claim this branch has
    // already had to correct twice. So it is asserted in the direction it is
    // true in: if somebody widens the guard to catch this, THIS goes red and
    // the doc comment above has to be rewritten in the same commit.
    let throughAFactoryFunction = """
        func armedClient() -> PrivilegedHelperClient {
            PrivilegedHelperClient(
                signature: RunningSignature { PrivilegedHelperIdentity.teamIdentifier })
        }

        @Test func armingReportsWhatTheHelperSaid() async {
            _ = await armedClient().arm(seconds: 30)
        }
        """
    #expect(realRegistrationHazards(in: throughAFactoryFunction).isEmpty, """
        the factory-function route is now CAUGHT. That is an improvement, not a \
        failure — but limit 1 in this file's doc comment still says it is not, \
        and a guard that overclaims is the defect this branch has fixed twice. \
        Rewrite that limit, then delete this expectation.
        """)
}

@Test func theSafeConstructionsAlreadyInThisSuiteStayGreen() {
    // Every one of these is in the tree today and every one must stay sayable.
    // This is the half that decides whether the guard survives contact with the
    // next author: a guard that reddens on the four real-team tests that are
    // already here would be deleted, correctly, by whoever it blocked.
    //
    // Verbatim in shape from `PrivilegedHelperClient_test.swift`.
    let countingTheReadsThroughTheDaemonSeam = """
        @Test func theRegistrationStateIsAskedAfreshOnEveryCallUnlikeTheSignature() {
            let machine = CountingRegistration(.enabled)
            let client = PrivilegedHelperClient(
                signature: RunningSignature { PrivilegedHelperIdentity.teamIdentifier },
                daemon: { machine })
            for _ in 0..<3 {
                #expect(client.registeredHelperIsActive())
            }
            #expect(machine.readCount == 3)
        }
        """
    #expect(realRegistrationHazards(in: countingTheReadsThroughTheDaemonSeam).isEmpty,
            "the daemon-seam freshness check was reported as a hazard; it registers nothing")

    let countingTheSignatureReads = """
        @Test func theSignatureIsReadOnceHoweverOftenAvailabilityIsAsked() {
            let reads = ReadCounter()
            let client = PrivilegedHelperClient(signature: RunningSignature {
                reads.bump()
                return PrivilegedHelperIdentity.teamIdentifier
            })
            for _ in 0..<5 {
                #expect(client.availability() == .registrable)
            }
            #expect(reads.value == 1)
        }
        """
    #expect(realRegistrationHazards(in: countingTheSignatureReads).isEmpty,
            "the signature cache check was reported as a hazard; it only reads availability()")

    // A double's own conformance declares `func register() throws`. A
    // DECLARATION is not a CALL, and this is the discrimination the leading `.`
    // in the pattern buys. Named bug: dropping that `.` turns every
    // `HelperRegistering` double in the suite into an offender.
    let theDoubleThatDeclaresRegister = """
        private final class CountingRegistration: HelperRegistering, @unchecked Sendable {
            var registrationState: HelperRegistrationState { .enabled }
            func register() throws {
                Issue.record("a read on the refresh timer registered a daemon")
            }
        }
        @Test func aHelperWaitingOnTheUsersApprovalIsNotReportedAsActive() {
            let client = PrivilegedHelperClient(
                signature: RunningSignature { PrivilegedHelperIdentity.teamIdentifier },
                daemon: { CountingRegistration() })
            #expect(client.registeredHelperIsActive() == false)
        }
        """
    #expect(realRegistrationHazards(in: theDoubleThatDeclaresRegister).isEmpty,
            "a double DECLARING register() was read as CALLING it")

    // The XPC service on the other side of the boundary. `arm(ttlSeconds:)` is
    // a different type and is driven ~20 times in CoffeeBarPowerTests. Named
    // bug: matching a bare `arm(` and reddening all of them.
    let theOtherArm = """
        @Test func armStampsTheJournal() throws {
            let service = PrivilegedHelperService(journal: journal)
            try service.arm(ttlSeconds: 3600)
        }
        """
    #expect(realRegistrationHazards(in: theOtherArm).isEmpty,
            "PrivilegedHelperService.arm(ttlSeconds:) was mistaken for the client's arm(seconds:)")

    // Driving the registration OUTCOME through the seam built for it. This is
    // the thing an author SHOULD write, and a guard that blocked it would leave
    // them nowhere to go.
    let theSeamThatExistsForThis = """
        @Test func aFirstClickIsToldToApproveInSystemSettings() {
            let service = StubRegistration(.other, throwing: POSIXError(.EPERM), then: .requiresApproval)
            #expect(PrivilegedHelperClient.outcome(ofRegistering: service) == .refused(approvalGuidance))
        }
        """
    #expect(realRegistrationHazards(in: theSeamThatExistsForThis).isEmpty,
            "driving outcome(ofRegistering:) with a double was reported as a hazard")

    // The gate closing, which is a real thing to want to check and is SAFE: a
    // nil team never reaches SMAppService.
    let theClosedGate = """
        @Test func anUnsignedBuildIsRefused() {
            let client = PrivilegedHelperClient(signature: RunningSignature { nil })
            #expect(client.register() != nil)
        }
        """
    #expect(realRegistrationHazards(in: theClosedGate).isEmpty,
            "a stub signature yielding nil was reported; that build cannot register anything")
}

@Test func theRemovalEntryPointIsGuardedTheSameWayTheRegistrationOneIs() {
    // Issue #71's removal path, added to `privilegedPathReachingCall` for the
    // reason limit 3 above predicted: a new method on `PrivilegedHelperClient`
    // that reaches the real service is unguarded until it is listed.
    //
    // `unregisterHelper()` is worse than `register()` in one respect and better
    // in another. Better: it installs nothing. Worse: what it takes away is an
    // approval the maintainer granted by hand in System Settings, and getting it
    // back is a manual cycle there — the same cost `sfltool resetbtm` carries,
    // arrived at without the reset.
    let theDangerousRemoval = """
        @Test func removingTheHelperTellsTheUserWhatHappened() throws {
            let client = PrivilegedHelperClient(
                signature: RunningSignature { PrivilegedHelperIdentity.teamIdentifier })
            try client.unregisterHelper()
        }
        """
    let hazards = realRegistrationHazards(in: theDangerousRemoval)
    #expect(hazards.count == 1,
            "the removal route was reported \(hazards.count) time(s): \(hazards)")
    #expect(hazards.first?.hasPrefix("removingTheHelperTellsTheUserWhatHappened:") == true,
            "the report does not name the offending function: \(hazards)")

    // A double DECLARING the seam method. The leading `.` in the pattern is what
    // holds these apart, exactly as it does for `register()`. Named bug:
    // dropping it turns every `HelperRemovalControlling` double in the suite into an
    // offender, and the guard gets deleted by the first person it annoys.
    let theDoubleThatDeclaresIt = """
        private final class FakeHelper: RegisteredHelperReporting, HelperRemovalControlling {
            func registeredHelperIsActive() -> Bool { true }
            func unregisterHelper() throws {}
        }
        @Test func theHelperIsUnregisteredOnlyAfterTheHoldIsReleased() {
            let helper = FakeHelper()
            let model = ServingModel(registration: helper, removal: helper)
            #expect(model.removeRegisteredHelper() == .removed)
        }
        """
    #expect(realRegistrationHazards(in: theDoubleThatDeclaresIt).isEmpty,
            "a double DECLARING unregisterHelper() was read as CALLING it")

    // Driving the CLOSED gate, which is what `HelperRemoval_test.swift` really
    // does and which is SAFE: a build naming no team never reaches the service.
    let theClosedRemovalGate = """
        @Test func anUnsignableBuildNeverAsksMacOSToUnregisterAnything() {
            let client = PrivilegedHelperClient(signature: RunningSignature { nil },
                                                daemon: { RecordingService() })
            #expect(throws: (any Error).self) { try client.unregisterHelper() }
        }
        """
    #expect(realRegistrationHazards(in: theClosedRemovalGate).isEmpty,
            "the closed-gate removal check was reported; a nil team reaches nothing")
}

@Test func theRevertRouteIsGuardedEvenThoughItRegistersNothing() {
    // `revert()` is the entry point on this list that reaches no registration.
    // Past `availability()` it opens a channel to the ROOT DAEMON and asks it to
    // put `SleepDisabled` back — a live change to a system power setting, made
    // by a test run, on any machine whose helper is approved. That is the same
    // class of harm the rest of this file refuses, arrived at by a different
    // door, which is why the list was renamed rather than extended quietly.
    let theDangerousRevert = """
        @Test func revertingEndsTheHold() async {
            let client = PrivilegedHelperClient(
                signature: RunningSignature { PrivilegedHelperIdentity.teamIdentifier })
            _ = await client.revert()
        }
        """
    let hazards = realRegistrationHazards(in: theDangerousRevert)
    #expect(hazards.count == 1,
            "the revert route was reported \(hazards.count) time(s): \(hazards)")

    // `WatchdogDecision.revert(_:)` is an enum CASE, driven ~30 times in this
    // very target, and it always carries an argument. Named bug: matching a bare
    // `.revert(` and reddening the whole decision suite.
    let theDecisionCase = """
        @Test func aTTLThatHasExpiredReverts() {
            #expect(decide(inputs(age: 3601, ttl: 3600)) == .revert(.ttlExpired))
            #expect(decide(inputs(boot: true)) == .revert(.dirtyJournalAtBoot))
        }
        """
    #expect(realRegistrationHazards(in: theDecisionCase).isEmpty,
            "WatchdogDecision.revert(_:) was mistaken for the client's revert()")

    // The service's own `revert(reply:)`, on the other side of the XPC boundary.
    // It takes a closure, so it never presents empty parentheses either.
    let theServiceRevert = """
        @Test func revertPutsTheSettingBack() {
            let service = PrivilegedHelperService(journal: journal)
            service.revert { wasArmed, message in
                #expect(message == nil)
            }
        }
        """
    #expect(realRegistrationHazards(in: theServiceRevert).isEmpty,
            "PrivilegedHelperService.revert(reply:) was mistaken for the client's revert()")

    // A double DECLARING the seam method, which is what every check in
    // `HelperRemoval_test.swift` does. The leading `.` holds them apart.
    let theDoubleThatDeclaresIt = """
        private final class FakeHelper: HelperRemovalControlling {
            func revert() async -> HelperRevertOutcome { .reverted(wasArmed: true) }
            func unregisterHelper() throws {}
        }
        """
    #expect(realRegistrationHazards(in: theDoubleThatDeclaresIt).isEmpty,
            "a double DECLARING revert() was read as CALLING it")
}
