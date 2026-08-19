// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import CoffeeBarCore
import CoffeeBarPower
@testable import CoffeeBarUI

/// Whether this copy of coffee-bar may offer the button at all.
///
/// **The gate, and it is not a nicety.** `SMAppService.daemon(plistName:)`
/// registers a plist that lives inside a CODE-SIGNED app bundle, and the peer
/// pin authenticates by Team ID. `scripts/build-app.sh` signs only when
/// `SIGN_IDENTITY` is set — deliberately, per issue #71a, because
/// auto-detection made `brew install` sign with the installing user's own
/// private key. So the shipping Homebrew bundle is ad-hoc with no team, it can
/// register nothing, and a button offered there fails with an OS error that
/// names neither the bundle nor the reason.
///
/// The app therefore reads its OWN signature and decides. These checks drive
/// that decision over values, and one of them measures the real running bundle
/// — which under `swift test` is exactly the ad-hoc case the gate exists for.

@Test func anAdHocBundleIsNotOfferedTheButton() throws {
    // Named bug, and it is every Homebrew user: the button appears, the click
    // calls `register()`, macOS refuses a job it cannot verify, and the user is
    // shown a failure about a feature the maintainer told them exists.
    #expect(HelperAvailability.decide(teamIdentifier: nil) == .unavailable)

    // `codesign` prints the literal string "not set" for an unsigned bundle,
    // and `scripts/build-app.sh` already parses that exact spelling out of
    // `codesign -dv` to decide what to print. A reader that passed it through
    // as a team name would treat "not set" as a team — and it is not this one,
    // so the branch above is reached anyway. Pinned so it stays reached for the
    // right reason.
    #expect(HelperAvailability.decide(teamIdentifier: "not set") == .unavailable)
    #expect(HelperAvailability.decide(teamIdentifier: "") == .unavailable)
}

@Test func aBundleSignedByAnotherTeamIsNotOfferedTheButton() throws {
    // Not a formality, and the reason is the pin rather than the registration.
    // A fork signed by somebody else registers its own helper perfectly well —
    // and then `PrivilegedHelperIdentity.helperPeerRequirement` pins team
    // 85FN4Z37V8, which that helper cannot satisfy. The connection is refused
    // and the button fails at the LAST step instead of the first.
    //
    // Named bug: a fork's users get a button that registers a root daemon and
    // then never speaks to it.
    #expect(HelperAvailability.decide(teamIdentifier: "ABCDE12345") == .unavailable)
}

@Test func aBundleFromThisTeamIsOfferedTheButton() throws {
    // The positive half. Without it the check above passes over a `decide` that
    // returns `.unavailable` unconditionally — which would be a button no build
    // ever shows, and every one of the negative checks would still be green.
    #expect(HelperAvailability.decide(
        teamIdentifier: PrivilegedHelperIdentity.teamIdentifier) == .registrable)
}

@Test func theRunningBuildReadsItsOwnSignatureRatherThanAssumingOne() throws {
    // MEASURED, in this process, with Security.framework: what does this build
    // actually carry?
    //
    // Under `swift test` the answer is nil — the test runner is linker-signed
    // ad-hoc and names no team, which is the same state a `brew install` bundle
    // is in. So this check pins the GATE closed for exactly the configuration
    // that cannot register a helper, and it does it by reading the artifact
    // rather than by trusting a constant.
    //
    // Named bug: `runningTeamIdentifier()` is written to return a hard-coded
    // team, or to fall back to one when the read fails. Either turns the gate
    // into an unconditional "yes" and puts the broken button back in front of
    // every Homebrew user.
    #expect(PrivilegedHelperClient.runningTeamIdentifier() == nil)
    #expect(PrivilegedHelperClient().availability() == .unavailable)
}

@Test func theUnavailableCaseStillNamesARouteThatWorks() throws {
    // A gate that only says "no" leaves the user with nothing. Lid-closed mode
    // IS available to them — through the command they have always had — so the
    // sentence has to carry it.
    //
    // Named bug: the Homebrew build shows a disabled button and no explanation,
    // and a user concludes the feature is broken rather than that this build
    // takes the other route.
    let sentence = HelperAvailability.unavailable.explanation
    #expect(sentence.contains("sudo"))
    #expect(sentence.contains(ProbeVerb.arm.rawValue))
    #expect(!sentence.isEmpty)

    // And the registrable case must NOT print a command: that is the whole
    // point of the button.
    #expect(!HelperAvailability.registrable.explanation.contains("sudo"))
}

@Test func theRegistrableCasePromisesNoPromptMacOSDoesNotShow() throws {
    // Named bug, and it is the one that actually stranded a user: this sentence
    // read "macOS will ask you to approve it once". No prompt comes. A daemon
    // registration is refused with a bare EPERM and the item is left disallowed
    // under System Settings › General › Login Items & Extensions, so the user
    // waits for a dialog that does not exist and is shown "macOS refused to
    // install the helper: … Operation not permitted" instead. The sentence read
    // BEFORE the click is the only surface that can set that expectation —
    // `approvalGuidance` speaks only after a click has already failed.
    //
    // The WHOLE sentence as a literal, not substrings. `contains("System
    // Settings")` stays green over a wording that names the pane and still
    // promises a prompt, which is exactly the drift this has to pin shut;
    // `cad2577` on this branch caught that shape in the guidance string.
    //
    // Written out rather than compared against the enum's own property:
    // comparing the implementation against itself is an assertion that cannot
    // fail. This literal IS the contract.
    #expect(HelperAvailability.registrable.explanation == """
        coffee-bar can install the privileged helper for you. macOS will not \
        run it until you approve it in System Settings yourself.
        """)

    // The discriminating half, and it earns its place by outliving the equality
    // above: a later maintainer who loosens `==` to a `contains` still cannot
    // ship the exact promise that caused this. It names the literal rather than
    // describing it, so the failure message is the sentence a reader recognises.
    #expect(!HelperAvailability.registrable.explanation.contains("ask you to approve"), """
        the button again promises an approval prompt macOS does not show: \
        \(HelperAvailability.registrable.explanation)
        """)
}

// MARK: - Issue #71h: the signature is read once for the life of the process

/// Counts the reads a cache did not make.
///
/// A locked class rather than a captured `var`: the closure the cache holds is
/// `@Sendable`, so Swift 6 refuses the capture outright, and these checks run
/// in parallel with everything else in the suite.
private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func bump() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@Test func theSignatureIsReadOnceHoweverOftenAvailabilityIsAsked() throws {
    // Named bug, and it is what this file did until #71h: every `availability()`
    // ran `SecCodeCopySelf` + `SecCodeCopySigningInformation` afresh. Measured on
    // a Developer-ID-signed app bundle at the app's REAL 30-second cadence
    // (issue #71e), that read is 4.97 ms of the 5.84 ms `ServingModel.refresh()`
    // holds the `@MainActor` for — 85% of it — and `refresh()` has eight callers,
    // one of which (`ingest(from:_:)`) runs on every hook event rather than on
    // the timer.
    //
    // A cache has NO behaviour a check can observe EXCEPT the reads it did not
    // make, so this counts them. Asserting that the returned VALUE is equal
    // across calls would be green on the uncached code too — the signature does
    // not change either way — which is why the source is a seam and not a value,
    // the same shape `HelperRegistering` and `RegisteredHelperReporting` already
    // are in this file.
    let reads = ReadCounter()
    let client = PrivilegedHelperClient(signature: RunningSignature {
        reads.bump()
        return PrivilegedHelperIdentity.teamIdentifier
    })

    for _ in 0..<5 {
        #expect(client.availability() == .registrable,
                "the remembered reading stopped answering what the source said")
    }

    #expect(reads.value == 1, """
        the signature was read \(reads.value) times to answer 5 questions about \
        it. A running process cannot change its own code signature, so every \
        read after the first spends ~5 ms of the main actor re-deriving a value \
        that cannot have moved.
        """)
}

@Test func aBuildCarryingNoTeamIsAlsoReadOnlyOnce() throws {
    // Named bug, and it is the one a plain `String?` cache ships with: store the
    // reading as `String?`, re-read whenever it holds `nil`, and the cache
    // engages for signed builds and for nobody else.
    //
    // `nil` IS the answer on every unsigned copy — every `brew install` bundle,
    // and this test runner, which is why the check above has to hand in a team
    // of its own to reach the other branch. So that defect would leave the users
    // there are most of paying the full read on every tick, with
    // `theSignatureIsReadOnceHoweverOftenAvailabilityIsAsked` still green over it.
    let reads = ReadCounter()
    let client = PrivilegedHelperClient(signature: RunningSignature {
        reads.bump()
        return nil
    })

    for _ in 0..<5 {
        #expect(client.availability() == .unavailable,
                "an absent team identifier stopped closing the gate")
    }

    #expect(reads.value == 1, """
        an absent team identifier was re-read \(reads.value) times: the cache \
        remembers a reading that found something and forgets one that did not, \
        which is the state every unsigned build is permanently in.
        """)
}

@Test func everyClientBuiltTheOrdinaryWayAnswersFromOneProcessWideReading() throws {
    // The WIRING, and it is a separate fact from the two above: a cache that
    // memoises perfectly and is rebuilt inside `PrivilegedHelperClient()` caches
    // nothing at all. `PreferencesView` builds one on a stored property and
    // `ServingModel` holds another, so a per-instance cache would leave the
    // window paying the COLD read — 5.39 ms measured, ~7x a warm one — on every
    // open.
    //
    // Named bug: `public init() { self.init(signature: RunningSignature(...)) }`.
    // Both checks above stay green over it, because each hands in an instance of
    // its own; only the shared one can see this.
    //
    // `== 1` and not `>= 1`, and it holds whatever else ran first: a shared cache
    // reads once for the life of the process however many checks asked, and a
    // per-instance one never touches `shared`, so it reads 0. An `availability()`
    // that skipped the cache and called `runningTeamIdentifier()` directly reads
    // 0 as well.
    _ = PrivilegedHelperClient().availability()
    _ = PrivilegedHelperClient().availability()

    // SAMPLED ONCE into a local, and that is not a style preference. Read twice
    // — once by the expectation and once by the message interpolating it — this
    // counter can report two different numbers for one failure, because the rest
    // of the suite runs in parallel and any of it may call `availability()`
    // between the two reads. Mutating the cache away printed exactly that:
    // `readCount → 2` beside a message claiming 3. A failure message that
    // disagrees with the value asserted sends the next reader after the wrong bug.
    let reads = RunningSignature.shared.readCount
    #expect(reads == 1, """
        the process-wide signature reading was made \(reads) times across two \
        clients built the ordinary way
        """)
}

// MARK: - Issue #71i: the registration state is never remembered beside it

/// An `SMAppService` that counts the questions and can change its answer.
///
/// A second double for `HelperRegistering`, and it is not a duplicate of
/// `PrivilegedHelperRegistration_test.swift`'s `StubRegistration`: that one
/// scripts a status that moves ACROSS a `register()` call, which is what the
/// registration OUTCOME turns on. This one counts reads and moves BETWEEN calls,
/// which is what the registration FRESHNESS turns on. Both are `private` to
/// their file, so neither can drift into answering the other's question.
private final class CountingRegistration: HelperRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private var state: HelperRegistrationState
    private var reads = 0

    init(_ state: HelperRegistrationState) { self.state = state }

    var registrationState: HelperRegistrationState {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return state
    }

    /// The user flips the switch in System Settings while the app is running.
    func set(_ next: HelperRegistrationState) {
        lock.lock()
        defer { lock.unlock() }
        state = next
    }

    /// How many times macOS was actually asked.
    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    /// A read must not write. `registeredHelperIsActive()` runs on a 30-second
    /// timer, so a `register()` reached from it would put an item in the Login
    /// Items & Extensions list of a user who clicked nothing — the nag
    /// `outcome(ofRegistering:)` refuses to become, arriving by the back door.
    func register() throws {
        Issue.record("""
            a read on the refresh timer registered a daemon: the user is now \
            listed under Login Items & Extensions having clicked nothing
            """)
    }

    /// A read must not unregister either, and this direction is the worse of
    /// the two. Registering a daemon the user did not ask for is a nag they can
    /// undo; taking one off on a 30-second timer removes the process that is
    /// holding lid-closed mode, mid-hold, on a Mac with the lid shut.
    func unregister() throws {
        Issue.record("""
            a read on the refresh timer unregistered the daemon: whatever hold \
            it was supervising is now held by nothing
            """)
    }
}

@Test func theRegistrationStateIsAskedAfreshOnEveryCallUnlikeTheSignature() {
    // Named bug, and it is the one #71h primed rather than caused: a cache next
    // to the signature's. `37da19f` put a remembered reading in this file, so
    // the obvious next optimisation is to remember the expensive call beside it
    // — and the registration is the ONE thing here that changes while the app
    // runs, because the user enables the item in System Settings mid-session.
    // Issue #71c exists because a stale reading of it tells them to
    // sudo-install a legacy root binary that is playing no part in the hold.
    //
    // `armingThroughTheHelperClearsTheStaleAdvisoryOnTheNextRefresh` drives
    // `StubRegisteredHelper` through the `RegisteredHelperReporting` seam, one
    // layer ABOVE this one, so a cache added inside `registeredHelperIsActive()`
    // never reaches it and it stays green over the defect. This is the same rule
    // at the layer that would hold the cache.
    //
    // Counting the reads OF THE STATE rather than the calls to the seam is
    // deliberate: hoisting `SMAppService.daemon(plistName:)` into a stored
    // property would be fewer seam calls and exactly as fresh, because `.status`
    // asks macOS every time it is read. That is not the defect and must not go
    // red.
    let machine = CountingRegistration(.enabled)
    let client = PrivilegedHelperClient(
        signature: RunningSignature { PrivilegedHelperIdentity.teamIdentifier },
        daemon: { machine })

    for _ in 0..<3 {
        #expect(client.registeredHelperIsActive(),
                "a daemon macOS reports as enabled was not reported as active")
    }

    // `== 3` and not `>= 3`: once per call, no more and no less. A second read
    // per call is 0.92 ms of the main actor twice over — measured in #71h, where
    // this call is 97.5% of what `refresh()` still costs.
    let asks = machine.readCount
    #expect(asks == 3, """
        macOS was asked \(asks) times whether the helper is registered, to \
        answer 3 questions about it. Anything but 3 means the answer was \
        remembered — and it is precisely the answer that changes while the app \
        runs, the moment the user enables the item in System Settings.
        """)
}

@Test func aHelperEnabledWhileTheAppRunsIsReportedWithoutARelaunch() {
    // The same rule stated as behaviour rather than as a count, and it is the
    // user's own story: the click that registers the daemon happens in the
    // Preferences window of a RUNNING app. An answer frozen at the first call
    // leaves them reading the advisory their click just disproved until they
    // relaunch.
    //
    // Not redundant with the counter above. A cache that re-read and re-stored
    // would keep the count at 3 and still answer stale; a cache that engaged
    // only for one of the two answers — the exact shape of the `String?` defect
    // `aBuildCarryingNoTeamIsAlsoReadOnlyOnce` was written for — would be caught
    // by whichever of the two directions below it froze.
    let machine = CountingRegistration(.other)
    let client = PrivilegedHelperClient(
        signature: RunningSignature { PrivilegedHelperIdentity.teamIdentifier },
        daemon: { machine })

    #expect(client.registeredHelperIsActive() == false,
            "precondition: nothing is registered on this machine yet")

    // The user clicks "Arm lid-closed mode" and approves it in System Settings.
    machine.set(.enabled)
    #expect(client.registeredHelperIsActive(), """
        the registration the user just granted was not reported until relaunch, \
        so the stale-helper advisory outlives the click that made it false
        """)

    // And back: macOS drops a registration when the bundle moves or the user
    // switches the item off. A cache that only remembered the good news would
    // report a helper that is no longer running as the one holding the machine,
    // silencing the advisory on exactly the Mac that needs it.
    machine.set(.other)
    #expect(client.registeredHelperIsActive() == false, """
        a registration macOS has dropped was still reported as active, so the \
        window is silent about the legacy root binary that is now the only thing \
        holding the lid closed
        """)
}

@Test func aHelperWaitingOnTheUsersApprovalIsNotReportedAsActive() {
    // `.enabled` and nothing looser, which the doc comment claims and nothing
    // could check until this seam existed.
    //
    // Named bug: `!= .other`, or a `switch` that folds `.requiresApproval` in
    // with `.enabled`. A helper waiting on approval is a helper macOS is NOT
    // running — so whatever holds that machine's lid closed is the legacy binary
    // at `ServingModel.privilegedProbePath`, which is the exact case the
    // stale-helper advisory was written for. Loosening this silences it there.
    let machine = CountingRegistration(.requiresApproval)
    let client = PrivilegedHelperClient(
        signature: RunningSignature { PrivilegedHelperIdentity.teamIdentifier },
        daemon: { machine })

    #expect(client.registeredHelperIsActive() == false, """
        a helper macOS is not running — it is waiting on an approval the user \
        has not given — was reported as the one holding this machine's lid closed
        """)
}

@Test func aBuildThatCouldNotHaveRegisteredAnythingDoesNotAskMacOS() {
    // The ORDER the doc comment claims, and the half of it that is not about
    // speed. `availability()` runs FIRST: a bundle that cannot register a helper
    // cannot have registered THIS one, so asking `SMAppService` about a job it
    // could never install answers about somebody else's registration — a
    // developer's own signed copy on the same Mac, say — and silences the
    // advisory on the unsigned build where `sudo` is genuinely the only route
    // there is.
    //
    // Named bug: dropping the `guard`, or reordering the two halves. The
    // fixture makes them disagree on purpose — no team, and a daemon macOS
    // would report as enabled — so a check that only read the returned value
    // could not tell "gated" from "asked and answered".
    let machine = CountingRegistration(.enabled)
    let client = PrivilegedHelperClient(
        signature: RunningSignature { nil },
        daemon: { machine })

    #expect(client.registeredHelperIsActive() == false, """
        an unsigned build reported a registered helper: it cannot have \
        registered one, so that answer is about a registration belonging to \
        somebody else
        """)

    let asks = machine.readCount
    #expect(asks == 0, """
        macOS was asked \(asks) times about a job this bundle could never have \
        installed. The signature gate is meant to close before the question is \
        put.
        """)
}

// MARK: - What the button says, before and after a click

@Test func theArmedStatusCarriesTheGRANTEDHoldAndNotTheRequestedOne() throws {
    // Named bug, and it is the whole reason the reply carries a number at all:
    // the window formats `model.holdInForce` — the value the SLIDER holds —
    // instead of the seconds the helper answered with. The journal clamps, so
    // the two differ exactly when it matters, and the user is shown a hold the
    // daemon is not keeping.
    //
    // Two different payloads must produce two different sentences. A
    // `statusLine` that ignored its payload would satisfy any single-value
    // assertion, which is how this defect survives a check written the obvious
    // way.
    #expect(HelperArmOutcome.armed(seconds: 3600).statusLine
            != HelperArmOutcome.armed(seconds: 7200).statusLine)
    #expect(HelperArmOutcome.armed(seconds: 3600).statusLine
        .contains(ServingModel.holdLabel(for: 3600)))
}

@Test func aRefusalShowsTheReasonItWasGiven() throws {
    // Named bug: the refusal is swallowed and replaced with a house sentence
    // like "could not arm". The two failures a user can actually act on —
    // "approve the helper in System Settings" and "this build is not signed" —
    // become indistinguishable from the ones they cannot, and the only surface
    // that could have told them says nothing.
    #expect(HelperArmOutcome.refused("approve it in System Settings").statusLine
            == "approve it in System Settings")
}

@Test func theButtonSaysSomethingDifferentOnABuildThatCannotArm() throws {
    // Named bug: an unsigned build renders the same "Arm lid-closed mode"
    // title, the user clicks it, and the only thing that happens is an error.
    // A control that cannot work must not look like one that can.
    #expect(HelperAvailability.registrable.buttonTitle
            != HelperAvailability.unavailable.buttonTitle)
    #expect(!HelperAvailability.registrable.buttonTitle.isEmpty)
}

@Test func theArmedSentenceSaysTheDisplayWasPutToSleepAndTheLidMayClose() {
    // Issue #143, reported by the maintainer on first live use of the shipped
    // button: "we should document that once the user clicks, the screen goes
    // black, meaning the laptop is ready to close the lid, so the user doesn't
    // think is a bug."
    //
    // The blanking is REQUIRED behaviour and not a side effect. `ArmService` is
    // constructed with `display: PmsetDisplaySleeper(runner:)`, whose
    // `forceSleep()` runs `pmset displaysleepnow`, and
    // `docs/coffee-bar-HANDOFF.md` records it as "Force display off ... Required
    // alongside disablesleep". The screen going dark is the single most visible
    // consequence of the click and the sentence after it said nothing about it.
    //
    // "was put to sleep" states what coffee-bar DID rather than what the display
    // now IS, deliberately. `LidClosedSession.arm` treats a `nil` from
    // `DisplayStateProbe` as not-awake — the measured Apple Silicon answer — so
    // an `.armed` reply does not prove the panel is dark, only that
    // `pmset displaysleepnow` returned nought. Promising the observation would
    // be the claim this product keeps refusing to make.
    let line = HelperArmOutcome.armed(seconds: 28_800).statusLine

    // WORD FOR WORD, for the reason `withoutARegisteredHelperTheStaleAdvisoryIs\
    // WordForWordWhatItWas` gives: `contains` assertions pass over a sentence
    // that dropped everything around the needle, and this string is the only
    // thing the window says after the screen goes black.
    #expect(line == """
        Lid-closed mode is armed for 8 hours, and the display was put to sleep \
        so you can close the lid. coffee-bar's helper is supervising it and will \
        put the setting back.
        """, """
        the sentence a user reads while their screen is dark has changed:
          \(line)
        """)

    // The two halves the issue asked for, named separately so a failure says
    // WHICH one went missing. A rewrite that drops either is the defect again.
    #expect(line.contains("the display was put to sleep"), """
        the armed sentence never mentions the display, so a user watching their \
        screen go black is left to read it as a crash: \(line)
        """)
    #expect(line.contains("close the lid"), """
        the armed sentence never says the lid may now be closed, which is the \
        whole point of the mode being armed: \(line)
        """)

    // The hold is still reported from the OUTCOME's seconds.
    // `theArmedStatusCarriesTheGRANTEDHoldAndNotTheRequestedOne` holds that
    // property; this pins that the new clause did not swallow it.
    #expect(line.contains(ServingModel.holdLabel(for: 28_800)), """
        the armed sentence no longer names the hold the helper granted: \(line)
        """)
}
