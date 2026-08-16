// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Who the two ends of the privileged channel are, and what each must prove.
///
/// Lid-closed mode needs root. Until issue #71 the only way to get there was
/// two `sudo` commands the user pasted into a terminal, and the reason was
/// recorded rather than assumed: `SECURITY.md` requires an XPC peer to be
/// authenticated by **Team ID and bundle ID**, and while the only shipping
/// bundle was ad-hoc signed there was no team to pin and no certificate chain
/// to pin it against. v0.2.0 ships Developer ID signed and notarised —
/// measured 2026-08-10, `codesign -R='anchor apple generic'` rc=0,
/// `TeamIdentifier=85FN4Z37V8` — so the bar became implementable, and this type
/// is where it is implemented.
///
/// **Everything here is a compiled constant, and that is a security property
/// rather than a convenience.** A requirement assembled from a runtime value —
/// a preference, an argument, a path — is a requirement an attacker can
/// influence, and the thing it guards is a root daemon. `requirement(for:)` is
/// `private` for exactly that reason: there is no way, from anywhere in this
/// package, to ask for a requirement pinning some other program. Two constants
/// exist and no caller can make a third.
public enum PrivilegedHelperIdentity {
    /// The Developer ID team every peer on this channel must belong to.
    ///
    /// The Organizational Unit of a Developer ID leaf certificate is the team
    /// identifier. Apple issues it, and it cannot be chosen by whoever signs —
    /// which is what makes it worth pinning, and which is also why it means
    /// nothing without the anchor below.
    public static let teamIdentifier = "85FN4Z37V8"

    /// The app's bundle identifier, and the signing identifier `codesign`
    /// derives from it.
    ///
    /// Measured 2026-08-16 on a fixture assembled exactly the way
    /// `scripts/build-app.sh` assembles one: signing the BUNDLE yields
    /// `Identifier=com.coffeebar.app`, taken from `CFBundleIdentifier`. So the
    /// name the daemon pins is the name the build already writes into
    /// `Info.plist`, and `BUNDLE_ID` in that script is the same string.
    public static let appIdentifier = "com.coffeebar.app"

    /// The helper's signing identifier, which is ALSO its launchd label.
    ///
    /// **This one does not come for free, and the measurement is the reason
    /// `scripts/sign-bundle.sh` had to change.** `codesign` derives the signing
    /// identifier of a bare Mach-O from its filename plus a hash of its own,
    /// measured 2026-08-16 on the probe this package builds:
    ///
    ///     Identifier=coffee-bar-probe-5555494425cf766ad0ee3fa09a60a3a47d0cb04b
    ///
    /// Nothing can pin that. Signing the nested binary with an explicit
    /// `-i com.coffeebar.probehelper` yields exactly this string, measured in
    /// the same session, and `theHelperIsSignedWithAStableIdentifier` holds the
    /// script to it.
    public static let helperIdentifier = "com.coffeebar.probehelper"

    /// The label launchd knows the helper by.
    ///
    /// Deliberately NOT `LaunchDaemonInstaller.label`. That job is
    /// `com.coffeebar.probewatchdog`, it lives in `/Library/LaunchDaemons`, and
    /// the user installs it themselves with `sudo coffee-bar-probe arm`. This
    /// one is registered from inside the app bundle. **Both paths coexist and
    /// must**: a Homebrew install gets an ad-hoc bundle that cannot register
    /// anything, so the CLI is the only route those users have, and a user who
    /// armed the CLI path before upgrading must not be broken.
    ///
    /// Sharing a label would be the failure: registering this helper would boot
    /// out a watchdog that is supervising a live hold, leaving nothing alive to
    /// put `SleepDisabled` back. `theHelperLabelIsNotTheWatchdogLabel` refuses
    /// it.
    public static let helperLabel = helperIdentifier

    /// The file `SMAppService.daemon(plistName:)` looks for inside
    /// `Contents/Library/LaunchDaemons/`.
    ///
    /// A NAME and not a path: that API takes neither a path nor a dictionary,
    /// and macOS reads the plist out of the app bundle's own signed contents.
    /// That is the whole reason a code-signed bundle is a hard precondition
    /// here — see `PrivilegedHelperClient`.
    public static let daemonPlistName = "\(helperIdentifier).plist"

    /// The endpoint the helper publishes and the app dials.
    ///
    /// One string, spelled once. The plist `scripts/build-app.sh` writes
    /// declares it, the daemon publishes it and the app dials it;
    /// `theDaemonPlistAgreesWithTheAppOnEveryName` reads the script and this
    /// constant together, because no compiler crosses that boundary.
    public static let endpointName = helperIdentifier

    /// What a peer must prove: Apple's anchor, the Developer ID chain, this
    /// team, and this exact program.
    ///
    /// **Four clauses, and dropping any one of them is a different attack.**
    ///
    /// - `anchor apple generic` — the certificate chain leads to an Apple root.
    ///   Without it the two clauses below are worthless: `identifier` and
    ///   `subject.OU` are both fields the SIGNER chooses, so a local attacker
    ///   self-signs a binary claiming this bundle ID and this team and walks
    ///   straight in. Measured 2026-08-16 on an ad-hoc fixture:
    ///   `codesign -v -R='identifier "com.coffeebar.app"'` returns rc=0.
    /// - `certificate 1[…6.2.6]` and `certificate leaf[…6.1.13]` — the Apple
    ///   marker OIDs for the Developer ID CA and a Developer ID Application
    ///   leaf. They rule out the other chains that also lead to an Apple root:
    ///   a development certificate, or a Mac App Store receipt.
    /// - `certificate leaf[subject.OU]` — the team. Apple issues it and the
    ///   signer cannot pick it.
    /// - `identifier` — the program. A team is an AUTHOR, not a program; this
    ///   is what stops any other tool this team ever signs, coffee-bar's own
    ///   unprivileged app included, from being accepted as the peer.
    ///
    /// `PrivilegedHelperIdentity_test.swift` evaluates both results through
    /// Security.framework rather than reading them, and it compiles them with
    /// the parser the call site uses — an unparseable requirement raises
    /// `NSInvalidArgumentException` at the moment a user clicks the button.
    private static func requirement(for identifier: String) -> String {
        "anchor apple generic"
        + " and identifier \"\(identifier)\""
        + " and certificate 1[field.1.2.840.113635.100.6.2.6]"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
        + " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    /// What the ROOT DAEMON demands of whoever dialled it.
    ///
    /// The dangerous direction. This clause is the only thing standing between
    /// a root process that disables sleep and every other program on the Mac.
    public static let appPeerRequirement = requirement(for: appIdentifier)

    /// What the APP demands of the daemon it dialled.
    ///
    /// The direction a user meets first: without it, coffee-bar hands its arm
    /// request to whatever has claimed the Mach name.
    public static let helperPeerRequirement = requirement(for: helperIdentifier)
}

/// The only thing the app may ask the root helper to do.
///
/// **A fixed, tiny surface, and it is the same discipline `ProbeVerb` already
/// follows**: no verb takes a path, a command, or any other arbitrary string.
/// The one parameter that crosses is an `Int` of seconds, and the helper clamps
/// it against `JournalRecord.maxTTLSeconds` on its own side — a peer that
/// passed the code-signing pin is still not trusted to bound a root hold, since
/// "signed by the right team" and "not currently compromised" are different
/// claims.
///
/// `@objc` because that is what `NSXPCInterface` requires. Replies are
/// `@Sendable` closures because a reply arrives on the connection's own queue,
/// not on the caller's.
@objc public protocol LidClosedControl {
    /// Disables sleep for at most `ttlSeconds`, and answers with the hold the
    /// helper actually recorded.
    ///
    /// The GRANTED value comes back rather than the requested one, for the
    /// reason `.arm` in the CLI prints what it read off the disk: the journal
    /// clamps, so a caller that echoed its own request would tell the user
    /// about a hold the daemon is not keeping.
    func arm(ttlSeconds: Int, reply: @escaping @Sendable (Int, String?) -> Void)

    /// Restores the prior sleep setting. Answers `true` when something was
    /// armed.
    func revert(reply: @escaping @Sendable (Bool, String?) -> Void)
}
