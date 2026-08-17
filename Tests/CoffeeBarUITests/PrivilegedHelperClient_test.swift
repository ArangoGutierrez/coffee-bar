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
