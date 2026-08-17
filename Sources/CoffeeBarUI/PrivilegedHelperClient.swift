// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security
import ServiceManagement
import CoffeeBarCore
import CoffeeBarPower

/// Whether THIS copy of coffee-bar can register a privileged helper.
///
/// Decided from the bundle's own signature rather than assumed, and the reason
/// is that two different builds of this app ship with two different answers.
/// `scripts/build-app.sh` signs only when `SIGN_IDENTITY` is set — deliberately
/// (#71a): auto-detection made `brew install` sign with the installing user's
/// private key, and falsified `SECURITY.md`'s promise about what a Homebrew
/// bundle carries. That bundle names no team, so it can register nothing, and
/// it must not be offered a button that cannot work.
public enum HelperAvailability: Equatable, Sendable {
    /// Developer ID, this team. The button is real.
    case registrable

    /// Ad-hoc, unsigned, or signed by somebody else. The `sudo` route is the
    /// only one this build has, and it still works.
    case unavailable

    /// What the bundle's team identifier means for the button.
    ///
    /// **A foreign team is `unavailable` too, and that is about the PIN rather
    /// than about registration.** A fork signed by somebody else registers its
    /// helper perfectly well — and then
    /// `PrivilegedHelperIdentity.helperPeerRequirement` demands team
    /// 85FN4Z37V8, which that helper cannot present. The connection is refused
    /// and the failure lands at the last step instead of the first, after a
    /// root daemon has already been installed. Refusing early is the honest
    /// answer for a build that cannot complete the round trip.
    ///
    /// `"not set"` is checked because that is the literal `codesign -dv` prints
    /// for an unsigned bundle, and `scripts/build-app.sh` already parses that
    /// exact spelling.
    public static func decide(teamIdentifier: String?) -> HelperAvailability {
        guard let teamIdentifier,
              !teamIdentifier.isEmpty,
              teamIdentifier != "not set",
              teamIdentifier == PrivilegedHelperIdentity.teamIdentifier else {
            return .unavailable
        }
        return .registrable
    }

    /// What the control is called.
    ///
    /// The two cases differ, deliberately. A button that cannot work must not
    /// look like one that can: on an unsigned build the click has no outcome
    /// but an error, so the title says what the build can actually do rather
    /// than inviting a press.
    public var buttonTitle: String {
        switch self {
        case .registrable:
            return "Arm lid-closed mode"
        case .unavailable:
            return "Copy the command instead"
        }
    }

    /// The sentence the window shows beside the button.
    ///
    /// Composed here rather than in the view, for the reason every other
    /// sentence in this layer is: M1 design §5.4 forbids asserting on rendered
    /// AppKit text, so a paragraph written in a `View` is a paragraph no check
    /// reads.
    ///
    /// The unavailable case NAMES THE COMMAND. A gate that only says "no"
    /// leaves the user with nothing, and lid-closed mode is genuinely available
    /// to them — by the route it has always been available by.
    public var explanation: String {
        switch self {
        case .registrable:
            return "coffee-bar can install the privileged helper for you. "
                + "macOS will ask you to approve it once."
        case .unavailable:
            return "This build is not signed by coffee-bar's developer, so it "
                + "cannot install a privileged helper. Lid-closed mode still "
                + "works the way it always has: run "
                + "\(ServingModel.lidClosedCommand) yourself."
        }
    }
}

/// What a click on the button did.
public enum HelperArmOutcome: Equatable, Sendable {
    /// The helper armed, for this many seconds — the value IT recorded.
    case armed(seconds: Int)
    /// It did not. The sentence is the helper's own, or this layer's.
    case refused(String)

    /// The line the window shows after a click.
    ///
    /// **Formatted from the OUTCOME's seconds and never from the slider.** The
    /// two differ exactly when it matters: `JournalRecord` clamps, so a window
    /// that printed `model.holdInForce` would promise a hold the daemon is not
    /// keeping — the same defect `.arm` fixed for the terminal by announcing
    /// what it read back off the disk.
    ///
    /// A refusal is passed through VERBATIM. "Approve the helper in System
    /// Settings" and "this build is not signed" are the two failures a user can
    /// act on, and a house sentence like "could not arm" makes them
    /// indistinguishable from the ones they cannot.
    ///
    /// Composed here rather than in the view, for the reason every other
    /// sentence in this layer is: M1 design §5.4 forbids asserting on rendered
    /// AppKit text.
    public var statusLine: String {
        switch self {
        case .armed(let seconds):
            return "Lid-closed mode is armed for \(ServingModel.holdLabel(for: seconds)). "
                + "coffee-bar's helper is supervising it and will put the setting back."
        case .refused(let reason):
            return reason
        }
    }
}

/// Where a registration stands, as this file needs to know it.
///
/// A local enum rather than `SMAppService.Status`, and that is a boundary
/// decision rather than a taste one. `theAppLayerNeverReachesForPrivilegeEscalation`
/// holds the set of app-layer files that may name `SMAppService` to exactly
/// this one, so a status type spelled `SMAppService.Status` could not appear in
/// a second file — including the check that drives the seam below.
///
/// `.other` collapses `.notRegistered`, `.notFound` and anything macOS adds
/// later, because this file treats all of them the same way: try to register.
enum HelperRegistrationState: Equatable, Sendable {
    case enabled
    case requiresApproval
    case other
}

/// The two things this file asks of `SMAppService`, behind a protocol.
///
/// The same seam `PinnableConnection` is in the power layer, and for the same
/// reason: registering a daemon needs a code-signed bundle, an approval the
/// user grants in System Settings, and a `launchd` that will accept the job —
/// none of which a check can produce. Approval on the development machine has
/// already been granted, and taking it away again means `sfltool resetbtm`,
/// which is system-wide and destructive. So the branch that tells the user to
/// approve is reachable to a check only through a double.
///
/// `SMAppService` already declares `register()` with this exact signature, so
/// half of the conformance below adds no code and cannot drift.
protocol HelperRegistering {
    var registrationState: HelperRegistrationState { get }
    func register() throws
}

extension SMAppService: HelperRegistering {
    var registrationState: HelperRegistrationState {
        switch status {
        case .enabled:          return .enabled
        case .requiresApproval: return .requiresApproval
        default:                return .other
        }
    }
}

/// Whether the daemon macOS is running is the one THIS build registers.
///
/// A protocol, and it is the seam issue #71c could not be written without.
/// `theAppLayerNeverReachesForPrivilegeEscalation` holds the set of app-layer
/// files entitled to name `SMAppService` to exactly one, and this is not the
/// file that composes the stale-helper advisory — so `ServingModel` cannot ask
/// macOS the question and the answer has to arrive through a type it may hold.
///
/// It is also the only route a check has to the `true` side. `availability()`
/// reads THIS binary's signature, and under `swift test` the runner is
/// linker-signed ad-hoc and names no team —
/// `theRunningBuildReadsItsOwnSignatureRatherThanAssumingOne` measures exactly
/// that — so no arrangement of files in this repository produces a registered
/// helper for the shipping implementation to report.
public protocol RegisteredHelperReporting: Sendable {
    /// `true` only while macOS reports this build's daemon as enabled.
    func registeredHelperIsActive() -> Bool
}

/// Registers the privileged helper and asks it to arm.
///
/// **The ONE file in the app layer entitled to name `SMAppService`**, and
/// `theAppLayerNeverReachesForPrivilegeEscalation` holds the set to exactly
/// this file. The other nine names on that list — `AuthorizationCreate`,
/// `AuthorizationExecuteWithPrivileges`, `NSAppleScript`, `setuid`, `launchctl`
/// and the rest — remain refused for everybody, and the difference is not one
/// of degree. Those routes take the user's password inside coffee-bar's own
/// process, or run an interpreter as root. `SMAppService.register()` hands the
/// decision to the OPERATING SYSTEM: macOS presents its own authorisation
/// sheet, names the app, and installs the job itself. coffee-bar still elevates
/// nothing on its own initiative; what changed is who collects the consent.
///
/// **It holds no connection object.** `PrivilegedHelperChannel` is opaque, so
/// there is nowhere in this file to resume a connection unpinned — which is why
/// the entitlement can be one symbol wide.
public struct PrivilegedHelperClient: Sendable, RegisteredHelperReporting {
    public init() {}

    /// The team identifier of the running code, read off the signature.
    ///
    /// `SecCodeCopySelf` rather than `Bundle.main` or a compiled constant: the
    /// question is what this binary IS, and only the signature answers that. A
    /// constant here would return `.registrable` on every build, including the
    /// ad-hoc ones the gate exists for.
    ///
    /// Measured under `swift test`: nil. The test runner is linker-signed
    /// ad-hoc and names no team, which is the same state a `brew install`
    /// bundle is in.
    public static func runningTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            unsafeBitCast(code, to: SecStaticCode.self),
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information) == errSecSuccess,
            let fields = information as? [String: Any] else { return nil }

        return fields[kSecCodeInfoTeamIdentifier as String] as? String
    }

    public func availability() -> HelperAvailability {
        HelperAvailability.decide(teamIdentifier: Self.runningTeamIdentifier())
    }

    /// What the stale-helper advisory asks before it reports an old root binary.
    ///
    /// **Both halves are load-bearing, in this order.** `availability()` first,
    /// because a bundle that cannot register a helper cannot have registered
    /// this one — asking `SMAppService` about a job it could never install would
    /// answer about somebody else's registration, and on an unsigned build the
    /// `sudo` route is genuinely the only one there is. Then the status, because
    /// a build that CAN register is not one that HAS: a signed copy whose owner
    /// has never clicked the button is exactly the Mac the advisory was written
    /// for.
    ///
    /// `.enabled` and nothing looser. `.requiresApproval` is a helper macOS is
    /// NOT running, so whatever holds that machine's lid closed is the binary at
    /// `ServingModel.privilegedProbePath` — the case the advisory is about.
    ///
    /// **It registers nothing.** This is a read, on a timer, and a `register()`
    /// here would put an OS authorisation sheet in front of a user who clicked
    /// nothing — the nag `outcome(ofRegistering:)` refuses to become, arriving
    /// through the back door instead.
    public func registeredHelperIsActive() -> Bool {
        guard availability() == .registrable else { return false }
        return SMAppService.daemon(plistName: PrivilegedHelperIdentity.daemonPlistName)
            .registrationState == .enabled
    }

    /// Asks macOS to install the helper, and answers with what it did.
    ///
    /// **Registration is idempotent from the app's side and NOT idempotent from
    /// the user's.** `register()` throws once the job is already registered,
    /// which is the ordinary case on every launch after the first, so that
    /// error is not a failure. Reporting it as one would show an error sheet to
    /// a user whose helper is working.
    ///
    /// Nothing here retries and nothing here loops. A registration macOS
    /// declined is a decision the user made, and asking again is how a prompt
    /// becomes a nag.
    public func register() -> HelperArmOutcome? {
        guard availability() == .registrable else {
            return .refused(HelperAvailability.unavailable.explanation)
        }
        return Self.outcome(ofRegistering:
            SMAppService.daemon(plistName: PrivilegedHelperIdentity.daemonPlistName))
    }

    /// What a user is told, decided over the registration alone.
    ///
    /// Split out from `register()` so a check can drive it. The half above is
    /// the part no check can reach — `availability()` reads THIS binary's
    /// signature, and under `swift test` that answer is `nil` — so the branches
    /// a user actually meets would otherwise be unreachable to everything in
    /// this package.
    static func outcome(ofRegistering service: any HelperRegistering) -> HelperArmOutcome? {
        switch service.registrationState {
        case .enabled:
            return nil                        // already ours; nothing to do
        case .requiresApproval:
            return .refused(approvalGuidance)
        case .other:
            do {
                try service.register()
                return nil
            } catch {
                // THE STATUS IS RE-READ, because macOS answers this question
                // only after the attempt. A daemon gets no modal prompt: the
                // registration is refused with a bare `EPERM` and the job moves
                // to `.requiresApproval` in the same breath, so at the moment
                // the switch above ran the status was still `.notFound` and the
                // branch holding the guidance could not be reached. Every new
                // user's first click lands here.
                //
                // The raw error is still what a failure NOT about approval
                // reports. "Approve it in System Settings" is advice that
                // cannot work for a bad plist name or a bundle macOS will not
                // verify, and advice that cannot work is worse than the POSIX
                // error, because the user spends the afternoon on it.
                if service.registrationState == .requiresApproval {
                    return .refused(approvalGuidance)
                }
                return .refused("macOS refused to install the helper: \(error.localizedDescription)")
            }
        }
    }

    /// What to tell a user whose helper is waiting on them.
    ///
    /// A constant because more than one branch answers with it, and a sentence
    /// that drifts between two of them is a user told two different things
    /// about one state.
    static let approvalGuidance = "Approve coffee-bar's helper in System Settings › "
        + "General › Login Items, then try again."

    /// Registers if needed, then asks the helper to hold sleep for `seconds`.
    ///
    /// The channel is opened per request and invalidated after, rather than
    /// held open for the life of the app. A long-lived connection to a root
    /// daemon is a long-lived thing to attack, and this one carries two calls a
    /// day at most.
    public func arm(seconds: Int) async -> HelperArmOutcome {
        if let refusal = register() { return refusal }

        let channel = PrivilegedHelperChannel()
        defer { channel.invalidate() }

        return await withCheckedContinuation { continuation in
            let resume = OneShot(continuation)
            guard let control = channel.control(onFailure: { error in
                // The pin lands here. A peer that fails
                // `helperPeerRequirement` never becomes a proxy, and the
                // connection reports it as an invalidation — so this is also
                // the message a user sees if the helper on disk is not the one
                // this app was built to trust.
                resume.finish(.refused("The helper did not answer, or is not the "
                                       + "one this build trusts: \(error.localizedDescription)"))
            }) else {
                resume.finish(.refused("The helper is not reachable."))
                return
            }

            control.arm(ttlSeconds: seconds) { granted, message in
                if let message {
                    resume.finish(.refused(message))
                } else {
                    resume.finish(.armed(seconds: granted))
                }
            }
        }
    }
}

/// Resumes a continuation exactly once.
///
/// Both the error handler and the reply block can fire — a connection that
/// fails after the invocation is dispatched is the ordinary shape of a peer
/// that failed the pin — and resuming a `CheckedContinuation` twice is a crash,
/// not a warning. The button would take the app down on precisely the failure
/// the pin exists to produce.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HelperArmOutcome, Never>?

    init(_ continuation: CheckedContinuation<HelperArmOutcome, Never>) {
        self.continuation = continuation
    }

    func finish(_ outcome: HelperArmOutcome) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: outcome)
    }
}
