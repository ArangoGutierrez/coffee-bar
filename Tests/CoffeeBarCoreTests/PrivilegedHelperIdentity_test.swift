// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import Security
@testable import CoffeeBarCore

/// The peer pin, which is the whole security argument for issue #71.
///
/// `SECURITY.md` requires an XPC peer to be authenticated by **Team ID AND
/// bundle ID**. That requirement is why the helper was deferred through M5, and
/// an unpinned channel is strictly worse than the `sudo` command it replaces:
/// the command has exactly one caller and you are it, whereas a Mach service
/// with no peer check accepts every local process on the machine.
///
/// So these checks are not about a string being tidy. Each one names the
/// process that gets in when it fails.
///
/// **The literals below are written out independently and NOT derived from the
/// implementation.** Deriving them — `#expect(requirement.contains(teamID))`
/// with `teamID` read back off the same enum — is the tautology this repository
/// already keeps a rule about: it passes for every value the constant could
/// ever hold, including an empty one.

// MARK: - The two pins, stated as literals

@Test func theHelperPinNamesTheDeveloperIDTeam() throws {
    // Named bug: the team clause is dropped in a refactor, so the requirement
    // reduces to "some Developer ID signed program calling itself
    // com.coffeebar.probehelper". Anybody with a $99 Apple Developer account
    // can sign a binary with an arbitrary `-i`, so that requirement is
    // satisfied by an attacker's helper and the app hands it the arm request.
    #expect(PrivilegedHelperIdentity.helperPeerRequirement
        .contains(#"certificate leaf[subject.OU] = "85FN4Z37V8""#))
}

@Test func theHelperPinNamesTheHelperBundle() throws {
    // Named bug: the identifier clause is dropped, so ANY binary this team
    // ever signed satisfies the requirement — including coffee-bar's own
    // unprivileged app, and including a future notarised tool that has no
    // business speaking to a root daemon. A Team ID is an author, not a
    // program.
    #expect(PrivilegedHelperIdentity.helperPeerRequirement
        .contains(#"identifier "com.coffeebar.probehelper""#))
}

@Test func theAppPinNamesTheDeveloperIDTeam() throws {
    // Same bug on the daemon's side of the channel, and this is the dangerous
    // direction: the daemon runs as root and this clause is what stops any
    // Developer ID signed program on the machine arming lid-closed mode.
    #expect(PrivilegedHelperIdentity.appPeerRequirement
        .contains(#"certificate leaf[subject.OU] = "85FN4Z37V8""#))
}

@Test func theAppPinNamesTheAppBundle() throws {
    // Named bug: the root daemon accepts any binary signed by this team. That
    // includes `coffee-bar-probe` itself, which is the one program on the
    // machine an attacker can already start as an unprivileged user.
    #expect(PrivilegedHelperIdentity.appPeerRequirement
        .contains(#"identifier "com.coffeebar.app""#))
}

@Test func neitherPinAcceptsAnAdHocSignature() throws {
    // Named bug, and it is the one that ships silently: a requirement written
    // as `identifier "…"` with no anchor is satisfied by a SELF-SIGNED or
    // ad-hoc binary, because `identifier` and `subject.OU` are both fields the
    // signer chooses. `anchor apple generic` is what makes the other two
    // clauses mean anything at all — without it a local attacker signs their
    // own helper with `-i com.coffeebar.probehelper` and a fabricated OU.
    //
    // Measured on this machine 2026-08-16, on an ad-hoc fixture bundle:
    //   codesign -v -R='identifier "com.coffeebar.app"'                 -> rc=0
    //   codesign -v -R='… and certificate leaf[subject.OU] = "85FN…"'   -> rc=3
    for requirement in [PrivilegedHelperIdentity.appPeerRequirement,
                        PrivilegedHelperIdentity.helperPeerRequirement] {
        #expect(requirement.contains("anchor apple generic"))
    }
}

@Test func theTwoPinsAreNotTheSameProgram() throws {
    // Named bug: both constants are wired to one identifier by a copy-paste, so
    // each end of the channel authenticates the wrong program — and the two
    // still "match", which is exactly what makes it survive a smoke test.
    #expect(PrivilegedHelperIdentity.appPeerRequirement
            != PrivilegedHelperIdentity.helperPeerRequirement)
}

// MARK: - What the system evaluator says, rather than what the string looks like

/// Compiles a requirement the way `NSXPCConnection` will, and answers with the
/// `OSStatus` rather than a Bool so a failure names itself.
private func compile(_ requirement: String) -> OSStatus {
    var compiled: SecRequirement?
    return SecRequirementCreateWithString(requirement as CFString, [], &compiled)
}

/// Whether `path` satisfies `requirement`, decided by Security.framework.
private func satisfies(_ path: String, _ requirement: String) throws -> Bool {
    var code: SecStaticCode?
    #expect(SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code)
            == errSecSuccess)
    let staticCode = try #require(code)

    var compiled: SecRequirement?
    #expect(SecRequirementCreateWithString(requirement as CFString, [], &compiled)
            == errSecSuccess)
    let rule = try #require(compiled)

    return SecStaticCodeCheckValidity(staticCode, [], rule) == errSecSuccess
}

@Test func bothPinsCompileAsCodeSigningRequirements() throws {
    // Named bug, and it is a CRASH rather than a weakness:
    // `NSXPCConnection.setCodeSigningRequirement` raises
    // NSInvalidArgumentException on a requirement it cannot parse. A misplaced
    // bracket in `certificate 1[field.…]` therefore takes the app down the
    // first time a user clicks the button — on their Mac, not here, because
    // nothing else in this package ever parses the string.
    //
    // This is the check that reads the requirement with the SAME parser the
    // shipped call site uses, instead of eyeballing it.
    #expect(compile(PrivilegedHelperIdentity.appPeerRequirement) == errSecSuccess)
    #expect(compile(PrivilegedHelperIdentity.helperPeerRequirement) == errSecSuccess)
}

@Test func theEvaluatorThisCheckUsesCanSayYes() throws {
    // POSITIVE CONTROL, and without it the check below passes vacuously.
    //
    // `SecStaticCodeCheckValidity` returns non-zero for a great many reasons —
    // an unreadable path, an unparseable requirement, a sandbox refusal — and
    // every one of them looks like "the pin rejected it". So first prove this
    // harness can return TRUE at all, against a requirement that is deliberately
    // weak and a binary Apple signed.
    //
    // Measured 2026-08-16: `codesign -v -R='anchor apple' /bin/ls` -> rc=0.
    #expect(try satisfies("/bin/ls", "anchor apple"))
}

@Test func thePinRefusesAnApplePlatformBinary() throws {
    // The discriminating half, and the reason the control above exists.
    //
    // `/bin/ls` is a real, validly signed, Apple-anchored Mach-O — a far harder
    // case than an unsigned file, and the exact shape of "a program that is
    // properly signed by SOMEBODY ELSE". Named bug: the requirement is
    // weakened to `anchor apple generic` alone, or to an empty string, and the
    // root daemon then accepts every signed binary on macOS.
    //
    // Measured 2026-08-16: the same requirement through `codesign -R` returns
    // rc=3, "code failed to satisfy specified code requirement(s)".
    #expect(try !satisfies("/bin/ls", PrivilegedHelperIdentity.appPeerRequirement))
    #expect(try !satisfies("/bin/ls", PrivilegedHelperIdentity.helperPeerRequirement))
}

// MARK: - The names the bundle layout and the daemon plist both have to agree on

@Test func theDaemonPlistNameIsTheHelperLabelWithAPlistSuffix() throws {
    // `SMAppService.daemon(plistName:)` takes a FILE NAME inside
    // Contents/Library/LaunchDaemons, and `launchd` takes a LABEL out of that
    // file. Named bug: the two drift, `register()` throws
    // `kSMErrorJobNotFound`, and the button reports a failure whose message
    // names neither file.
    #expect(PrivilegedHelperIdentity.daemonPlistName == "com.coffeebar.probehelper.plist")
    #expect(PrivilegedHelperIdentity.helperLabel == "com.coffeebar.probehelper")
}

@Test func theHelperLabelIsNotTheWatchdogLabel() throws {
    // BOTH PATHS COEXIST (#71b scope). `sudo coffee-bar-probe arm` installs
    // `com.coffeebar.probewatchdog` into /Library/LaunchDaemons; this helper is
    // a separate job registered from the app bundle. Named bug: they share a
    // label, so registering the helper boots out a watchdog that is supervising
    // a live hold — and nothing is then left to put `SleepDisabled` back.
    #expect(PrivilegedHelperIdentity.helperLabel != "com.coffeebar.probewatchdog")
}
