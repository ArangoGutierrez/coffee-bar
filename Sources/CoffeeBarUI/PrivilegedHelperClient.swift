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
public struct PrivilegedHelperClient: Sendable {
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
        let service = SMAppService.daemon(plistName: PrivilegedHelperIdentity.daemonPlistName)
        switch service.status {
        case .enabled:
            return nil                        // already ours; nothing to do
        case .requiresApproval:
            return .refused("Approve coffee-bar's helper in System Settings › "
                            + "General › Login Items, then try again.")
        default:
            do {
                try service.register()
                return nil
            } catch {
                return .refused("macOS refused to install the helper: \(error.localizedDescription)")
            }
        }
    }

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
