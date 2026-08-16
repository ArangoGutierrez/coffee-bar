// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import CoffeeBarCore

/// The half of issue #71 that lives in the build rather than in Swift.
///
/// `SMAppService.daemon(plistName:)` does not take a path and does not take a
/// dictionary. It reads a plist out of `Contents/Library/LaunchDaemons/` inside
/// the app bundle, and macOS refuses to register one it cannot find or cannot
/// verify against the bundle's signature. So the button in the panel is
/// unreachable unless `scripts/build-app.sh` puts that file there, and no Swift
/// check in this package can see whether it did.
///
/// Read as TEXT, comment lines stripped first, exactly as
/// `BuildScriptAppIcon_test.swift` does — several of the assertions below
/// concern names those scripts also discuss in prose.

private func scriptLines(_ relativePath: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CoffeeBarUITests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
    let text = try String(contentsOf: root.appendingPathComponent(relativePath),
                          encoding: .utf8)
    return text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        .joined(separator: "\n")
}

@Test("the build script ships the daemon plist inside the bundle")
func bundleCarriesTheDaemonPlist() throws {
    let code = try scriptLines("scripts/build-app.sh")

    // The literal directory, because SMAppService will look nowhere else.
    // Named bug: the plist is written to Contents/Resources — where every other
    // non-executable in this bundle goes — `register()` throws
    // `kSMErrorJobNotFound`, and the button fails on a user's Mac with a
    // message that names no file.
    #expect(code.contains("Contents/Library/LaunchDaemons"),
            "the daemon plist must land in Contents/Library/LaunchDaemons")

    // The script must read the written plist back. `plutil -lint` accepts any
    // well-formed plist, and a heredoc that lost its Label key is well-formed.
    #expect(code.contains("plutil -extract Label raw -o -"),
            "the build must verify the Label in the plist it just wrote")
}

@Test("the plist the script writes names the label the app registers")
func theDaemonPlistAgreesWithTheAppOnEveryName() throws {
    let code = try scriptLines("scripts/build-app.sh")

    // THE SAME THREE STRINGS, on both sides of a boundary no compiler crosses.
    // `PrivilegedHelperIdentity` is what the Swift side registers, dials and
    // pins; the shell heredoc is what launchd reads. Named bug, and it is
    // silent in the worst way: the plist says `com.coffeebar.helper` while the
    // app registers `com.coffeebar.probehelper`. The bundle builds, the suite
    // is green, and `register()` fails only on a signed install — which is the
    // one configuration nobody can test from a dev build.
    #expect(code.contains(PrivilegedHelperIdentity.daemonPlistName), """
        build-app.sh writes no file named \(PrivilegedHelperIdentity.daemonPlistName)
        """)
    #expect(code.contains("<string>\(PrivilegedHelperIdentity.helperLabel)</string>"), """
        the plist's Label must be \(PrivilegedHelperIdentity.helperLabel)
        """)
    #expect(code.contains("<key>MachServices</key>"),
            "the daemon publishes no Mach endpoint, so nothing can dial it")

    // The job has to start the probe, and with the verb that listens. Named
    // bug: `ProgramArguments` carries no verb, the probe runs its default
    // `run` spike, exits 0, and launchd reports a healthy job that serves
    // nothing.
    #expect(code.contains("<string>\(ProbeVerb.serve.rawValue)</string>"), """
        the plist must start the probe with the \(ProbeVerb.serve.rawValue) verb
        """)
    #expect(code.contains("Contents/MacOS/coffee-bar-probe"),
            "the plist must point at the probe this script copies into the bundle")
}

@Test("the helper is signed with a pinnable identifier")
func theHelperIsSignedWithAStableIdentifier() throws {
    let code = try scriptLines("scripts/sign-bundle.sh")

    // MEASURED, 2026-08-16, and it is the finding that makes this file
    // necessary. `codesign` derives the signing identifier of a BARE Mach-O
    // from its filename plus a hash:
    //
    //   $ codesign -f -s - CoffeeBar.app/Contents/MacOS/coffee-bar-probe
    //   $ codesign -d --verbose=4 …
    //   Identifier=coffee-bar-probe-5555494425cf766ad0ee3fa09a60a3a47d0cb04b
    //
    // A requirement pinning `identifier "com.coffeebar.probehelper"` can never
    // be satisfied by that binary, so the app would refuse its own helper on
    // every signed build — and the failure appears only after signing, which is
    // the configuration a dev build cannot reach. Passing `-i` explicitly makes
    // it `Identifier=com.coffeebar.probehelper`, measured in the same session.
    //
    // The bundle needs no such flag: `codesign` takes a bundle's identifier
    // from CFBundleIdentifier, measured as `Identifier=com.coffeebar.app`.
    #expect(code.contains("-i \"${HELPER_IDENTIFIER}\"") || code.contains("-i ${HELPER_IDENTIFIER}"), """
        sign-bundle.sh signs the nested probe without an explicit identifier, \
        so codesign derives a per-binary hashed one and the peer pin cannot be \
        written
        """)
    #expect(code.contains(PrivilegedHelperIdentity.helperIdentifier), """
        sign-bundle.sh must sign the probe as \
        \(PrivilegedHelperIdentity.helperIdentifier), which is what \
        PrivilegedHelperIdentity.helperPeerRequirement pins
        """)
}
