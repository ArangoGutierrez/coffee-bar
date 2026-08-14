// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation

/// Holds `scripts/sign-bundle.sh` — the step that gives a locally built bundle a
/// real signature — to what `codesign` actually does.
///
/// **These tests EXECUTE the script.** They assemble a fixture bundle from
/// `/bin/echo`, a genuine Mach-O, so `codesign` behaves as it does on the real
/// product, and then read the signature back off the bundle the script wrote.
/// `ReleaseDmg_test.swift` established that shape here and the reasoning is the
/// same: what is under test is what the tools DO.
///
/// The signing step lives in its own script for exactly this reason. Reaching it
/// through `build-app.sh` would cost a full `-c release` build of both products
/// per test — minutes — and would write into the shared `build/` directory that
/// the script's own foreign-bundle guard polices.
///
/// **Why a text guard could not do this job.** Measured 2026-08-14 on a fixture
/// carrying `coffee-bar` and `coffee-bar-probe`: signing ONLY the bundle leaves
/// `codesign --verify --deep --strict` returning rc=0 while the nested probe
/// still carries the signature the linker gave it. The bundle's verification
/// exit code cannot tell a covered nested binary from an uncovered one, so the
/// assertions below read each binary individually.

// MARK: - Running things

/// Runs a command and returns its exit code and combined output.
///
/// Reads the pipe BEFORE waiting, because waiting first deadlocks once the
/// output outgrows the pipe buffer.
///
/// A second copy of the helper `ReleaseDmg_test.swift` declares `private`. Four
/// lines duplicated is better than widening a neighbour's internals, which is
/// the trade `everySwiftFileInSourcesAndTests` in `DocsClaims_test.swift`
/// records for its own walk.
///
/// `unset` removes a variable the test process happens to carry. The default
/// case below is defined by `SIGN_IDENTITY` being ABSENT, and a maintainer who
/// exported it in the shell that ran `swift test` would otherwise hand it
/// straight to the script and test the opt-IN path under the opt-out name.
@discardableResult
private func runTool(_ args: [String],
                     env extra: [String: String] = [:],
                     unset: [String] = []) throws -> (rc: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    for (k, v) in extra { env[k] = v }
    for k in unset { env.removeValue(forKey: k) }
    p.environment = env

    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func signBundleScript() -> URL {
    repoRoot().appending(path: "scripts/sign-bundle.sh")
}

/// A minimal but REAL app bundle carrying the two executables `PRODUCTS` ships.
///
/// `/bin/echo` rather than a stub file: `codesign` refuses a non-Mach-O, and a
/// fixture the tool would not accept proves nothing about the tool.
private func makeFixtureApp(at root: URL) throws {
    let macOS = root.appending(path: "Contents/MacOS")
    let resources = root.appending(path: "Contents/Resources")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

    for name in ["coffee-bar", "coffee-bar-probe"] {
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"),
                                         to: macOS.appending(path: name))
    }
    try Data("icon".utf8).write(to: resources.appending(path: "AppIcon.icns"))
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>coffee-bar</string>
    <key>CFBundleIdentifier</key><string>com.coffeebar.fixture</string>
    <key>CFBundleName</key><string>CoffeeBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>9.9.9</string>
    </dict></plist>
    """.write(to: root.appending(path: "Contents/Info.plist"), atomically: true, encoding: .utf8)
}

/// A fresh temporary directory holding a fixture bundle, removed afterwards.
private func withFixtureApp(_ body: (URL, URL) throws -> Void) throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "cb-signing-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let app = tmp.appending(path: "CoffeeBar.app")
    try makeFixtureApp(at: app)
    try body(tmp, app)
}

// MARK: - Reading a signature back off a bundle

/// Everything `codesign` reports about one path.
///
/// `codesign -d` writes its report to STDERR, which is why the merged stream is
/// what gets parsed. Reading stdout alone returns the empty string for every
/// binary, and every assertion built on it would pass vacuously.
private func codesignReport(_ path: String) throws -> String {
    try runTool(["codesign", "-dv", "--verbose=4", path]).out
}

/// The value of a `key=` line in a `codesign -d` report, or nil.
private func codesignField(_ key: String, in report: String) -> String? {
    report.split(separator: "\n", omittingEmptySubsequences: false)
        .first { $0.hasPrefix("\(key)=") }
        .map { String($0.dropFirst(key.count + 1)) }
}

/// The team identifier `codesign` reports for `path`, or nil when it names none.
///
/// The "no team" spelling is assembled from two literals ON PURPOSE, and it is
/// not style. `noSourceFileClaimsTheShippingBundleIsAdHocSigned` in
/// `DocsClaims_test.swift` fails any `.swift` file under `Sources` or `Tests`
/// that carries that sentence whole, because it is the dead premise issue #86 is
/// about. A guard whose own fixture is the forbidden string must make the fixture
/// unmatchable rather than ask to be skipped: an exemption would carve a blind
/// spot in that scan exactly the size of this file.
private let noTeamReported = "not" + " set"

private func teamIdentifier(in report: String) -> String? {
    guard let value = codesignField("TeamIdentifier", in: report),
          value != noTeamReported, !value.isEmpty
    else { return nil }
    return value
}

/// True when `path` carries a signature THIS PROJECT made.
///
/// The hardened runtime is the discriminator, and it is the only one that works
/// on every machine. Measured 2026-08-14: every binary here arrives ALREADY
/// signed — a `/bin/echo` copy at `flags=0x0(none)`, and the real
/// `swift build -c release` products at `flags=0x20002(adhoc,linker-signed)` —
/// so "carries a signature" separates nothing at all. `--options runtime` is a
/// flag only a deliberate `codesign --sign` sets, so `runtime` in the flags
/// means this script signed this file, with a Developer ID or ad hoc.
private func carriesHardenedRuntime(in report: String) -> Bool {
    report.split(separator: "\n")
        .first { $0.contains("flags=") }
        .map { $0.contains("runtime") } ?? false
}

/// The first `Developer ID Application` identity `security` reports, or nil.
///
/// Parsed HERE rather than asked of `sign-bundle.sh`, because the script's own
/// answer is part of what is under test. `find-identity` prints
/// `  1) <hex> "Developer ID Application: Name (TEAM)"`, so the value runs from
/// the prefix to the closing quote.
private func firstDeveloperIDIdentity(in report: String) -> String? {
    for line in report.split(separator: "\n") {
        guard let prefix = line.range(of: "Developer ID Application:") else { continue }
        let rest = line[prefix.lowerBound...]
        guard let closingQuote = rest.firstIndex(of: "\"") else { continue }
        return String(rest[rest.startIndex..<closingQuote])
    }
    return nil
}

/// The bundle's own executables, sorted. Fails loudly rather than returning [].
private func nestedBinaries(of app: URL) throws -> [URL] {
    let macOS = app.appending(path: "Contents/MacOS")
    return try FileManager.default.contentsOfDirectory(atPath: macOS.path)
        .sorted()
        .map { macOS.appending(path: $0) }
}

// MARK: - The signing contract

/// Every executable in the bundle gets its own signature, and the bundle is
/// signed last.
///
/// Ad hoc (`SIGN_IDENTITY=-`) so this holds on any machine, with or without a
/// Developer ID in its keychain. What is under test is the SHAPE of the signing
/// — which files, in which order — and that shape is identical either way.
/// `theRealKeychainIdentityIsWhatTheScriptReachesFor` covers the Developer ID.
///
/// **Named bug 1: only the bundle is signed.** `codesign` on a bundle signs the
/// main executable and SEALS the rest, so a second Mach-O in `Contents/MacOS` is
/// covered by the seal but carries no signature of its own. Measured on this
/// fixture: with only the bundle signed, `codesign --verify --deep --strict`
/// returns **rc=0** and the nested probe reports no team, and its own
/// requirement check fails with rc=3. Notarisation refuses that bundle before
/// Gatekeeper ever sees it. The per-binary loop below is the only assertion here
/// that can see the difference.
///
/// **Named bug 2: the bundle is signed BEFORE its nested binaries.** Signing a
/// nested binary afterwards changes the file the bundle's seal covers. Measured
/// on this fixture: `codesign --verify --deep --strict` then returns rc=1,
/// `nested code is modified or invalid`.
@Test func everyExecutableInTheBundleCarriesItsOwnSignature() throws {
    try withFixtureApp { _, app in
        let r = try runTool([signBundleScript().path, app.path],
                            env: ["SIGN_IDENTITY": "-"])
        #expect(r.rc == 0, "sign-bundle.sh exited \(r.rc):\n\(r.out)")

        // Named bug 2 lives here: the order is what this exit code sees.
        let verify = try runTool(["codesign", "--verify", "--deep", "--strict",
                                  "--verbose=2", app.path])
        #expect(verify.rc == 0,
                "codesign --verify --deep --strict rejected the signed bundle:\n\(verify.out)")

        // ANTI-VACUITY. An empty directory would satisfy the loop below without
        // signing anything, and the fixture is built rather than found.
        let binaries = try nestedBinaries(of: app)
        #expect(binaries.map { $0.lastPathComponent } == ["coffee-bar", "coffee-bar-probe"],
                "the fixture no longer carries the two executables PRODUCTS ships: \(binaries)")

        // Named bug 1 lives here, and nowhere else in this function.
        for binary in binaries {
            let report = try codesignReport(binary.path)
            #expect(carriesHardenedRuntime(in: report), """
                \(binary.lastPathComponent) carries no hardened-runtime flag, so \
                this script never signed it — it holds whatever the linker left. \
                The bundle's own verification passes either way:
                \(report)
                """)
        }

        let bundleReport = try codesignReport(app.path)
        #expect(carriesHardenedRuntime(in: bundleReport), """
            the bundle itself was signed without --options runtime; notarisation \
            refuses that, and #71b needs notarisation:
            \(bundleReport)
            """)
    }
}

/// A machine with no Developer ID still gets a bundle, and is told why it is
/// limited.
///
/// **Named bug: the build fails on a contributor's machine because they lack a
/// private key.** That is a worse outcome than an unsigned bundle — it turns a
/// signing improvement into a broken `git clone && scripts/build-app.sh` for
/// everyone who is not the maintainer, and it would break the CI job that runs
/// `build-app.sh` on a hosted runner, where no keychain identity exists.
///
/// Absence is simulated with a PATH shim rather than by touching the keychain.
/// The shim is a real `security` binary earlier on PATH that reports what a
/// machine with no identity reports, so the script's own lookup and its own
/// parse are what run. The keychain is never read, never modified, and the real
/// identity on this machine is left exactly as it was.
///
/// The shim records the arguments it was called with, and the test asserts that
/// record exists. Without it this test would pass on a machine that HAS no
/// identity even if the script had stopped consulting the shim entirely — for
/// instance by hard-coding an absolute `/usr/bin/security` — and a guard that
/// green-lights the wrong artifact is the failure `ReleaseDmg_test.swift` calls
/// reading blind.
@Test func aMachineWithNoSigningIdentityStillGetsABundle() throws {
    try withFixtureApp { tmp, app in
        let shimDir = tmp.appending(path: "shim")
        try FileManager.default.createDirectory(at: shimDir, withIntermediateDirectories: true)
        let marker = tmp.appending(path: "security-was-called.txt")
        let shim = shimDir.appending(path: "security")
        try """
        #!/bin/bash
        printf '%s\\n' "$*" >> "${CB_SHIM_MARKER}"
        echo "     0 valid identities found"
        exit 0
        """.write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: shim.path)

        let path = shimDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        let r = try runTool([signBundleScript().path, app.path],
                            env: ["PATH": path, "CB_SHIM_MARKER": marker.path])

        // The whole point: no key, no failure.
        #expect(r.rc == 0, """
            sign-bundle.sh exited \(r.rc) on a machine with no signing identity. \
            A contributor without a private key must still get a bundle:
            \(r.out)
            """)

        // Proof that the lookup went through the shim. Without this the
        // assertions above are satisfied by a script that never looked.
        let called = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
        #expect(called.contains("find-identity"), """
            the script never ran `security find-identity` through PATH, so this \
            test never simulated anything. It recorded: \(called.debugDescription)
            """)

        // Named bug: the build goes quiet and the user learns their bundle is
        // unsigned from Gatekeeper on someone else's Mac.
        #expect(r.out.lowercased().contains("unsigned"),
                "the run never says the bundle is unsigned:\n\(r.out)")
        #expect(r.out.contains("Gatekeeper"), """
            the run says the bundle is unsigned but not what that costs; \
            "unsigned" alone is not a reason:
            \(r.out)
            """)

        // …and it really did leave the bundle alone. A script that printed the
        // warning and signed anyway would satisfy every assertion above.
        for binary in try nestedBinaries(of: app) {
            let report = try codesignReport(binary.path)
            #expect(!carriesHardenedRuntime(in: report), """
                \(binary.lastPathComponent) carries a hardened-runtime flag after \
                a run that found no identity, so something signed it:
                \(report)
                """)
        }
    }
}

/// Signing is OPT-IN: an unasked run does not reach for anybody's signing key.
///
/// **Named bug, and it is the one this test exists for: `build-app.sh` signs
/// with whatever Developer ID it finds lying in the keychain.** That script is
/// also the Homebrew formula's build path, so auto-detection means
/// `brew install coffee-bar` runs `codesign --sign <a stranger's private key>`
/// on a bundle they are merely installing — a third party's signing identity
/// used without their consent, on the distribution path most likely to reach
/// people who never read this repository. It also falsifies `SECURITY.md`,
/// which promises under "Things that are not vulnerabilities" that a
/// Homebrew-installed bundle names no team.
///
/// **The discrimination does not depend on this machine's keychain**, which is
/// the flaw in asserting the default only against the real one: on a runner with
/// no identity, auto-detection and opt-in produce the same unsigned bundle and
/// the test is green either way. So the first half OFFERS an identity through a
/// PATH shim — a `Developer ID Application` line naming a certificate no
/// keychain holds — and requires the script to walk past it. Restore
/// `IDENTITY="${SIGN_IDENTITY:-$(detect_identity)}"` and the script takes the
/// bait: `codesign --sign` fails on the missing certificate, `die` runs, and the
/// rc assertion goes red on any machine.
///
/// The second half then pins the same rule against the REAL keychain, which is
/// the sharpest form of it where an identity exists: a machine that CAN produce
/// a Developer ID signature must not produce one unasked.
///
/// The shim is read-only and the keychain is never written. `security` is still
/// consulted on this path — `detect_identity` reports what is AVAILABLE so the
/// message can name it — and that is the distinction under test: reading which
/// certificates exist is not the same as signing with one.
@Test func signingIsOptInSoAnUnaskedRunLeavesTheBundleUnsigned() throws {
    // --- offered an identity, and must decline it ---------------------------
    try withFixtureApp { tmp, app in
        let shimDir = tmp.appending(path: "shim")
        try FileManager.default.createDirectory(at: shimDir, withIntermediateDirectories: true)
        let marker = tmp.appending(path: "security-was-called.txt")
        let shim = shimDir.appending(path: "security")
        try """
        #!/bin/bash
        printf '%s\\n' "$*" >> "${CB_SHIM_MARKER}"
        echo '  1) DEADBEEF "Developer ID Application: Nobody At All (ZZZZZZZZZZ)"'
        echo "     1 valid identities found"
        exit 0
        """.write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: shim.path)

        let path = shimDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        let r = try runTool([signBundleScript().path, app.path],
                            env: ["PATH": path, "CB_SHIM_MARKER": marker.path],
                            unset: ["SIGN_IDENTITY"])

        #expect(r.rc == 0, """
            sign-bundle.sh exited \(r.rc) when it was offered an identity it was \
            never asked to use. Signing is opt-in; an unasked run assembles an \
            unsigned bundle and exits 0:
            \(r.out)
            """)

        // ANTI-VACUITY. Without this the run above proves nothing: a PATH that
        // never reached the shim would leave the bundle unsigned for the
        // uninteresting reason that nothing was offered.
        let called = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
        #expect(called.contains("find-identity"), """
            the script never ran `security find-identity` through PATH, so the \
            shim offered nothing and this half tested nothing. It recorded: \
            \(called.debugDescription)
            """)

        // The bundle is what it is, read off the artifact.
        let bundleReport = try codesignReport(app.path)
        #expect(teamIdentifier(in: bundleReport) == nil, """
            the bundle names a team after a run that was never asked to sign it:
            \(bundleReport)
            """)
        for binary in try nestedBinaries(of: app) {
            let report = try codesignReport(binary.path)
            #expect(!carriesHardenedRuntime(in: report), """
                \(binary.lastPathComponent) carries a hardened-runtime flag, so \
                this script signed it without being asked to:
                \(report)
                """)
        }

        // Opt-in is worth nothing if the way in is undiscoverable.
        #expect(r.out.contains("SIGN_IDENTITY"), """
            the run declines to sign and never says how to ask for a signature, \
            so the maintainer's own build has no way in:
            \(r.out)
            """)
    }

    // --- and the same rule against the real keychain -------------------------
    let identities = try runTool(["security", "find-identity", "-v", "-p", "codesigning"])
    try withFixtureApp { _, app in
        let r = try runTool([signBundleScript().path, app.path], unset: ["SIGN_IDENTITY"])
        #expect(r.rc == 0, "sign-bundle.sh exited \(r.rc):\n\(r.out)")

        let bundleReport = try codesignReport(app.path)
        #expect(teamIdentifier(in: bundleReport) == nil, """
            this machine holds \(firstDeveloperIDIdentity(in: identities.out) ?? "no Developer ID") \
            and the bundle came back naming a team, so the script signed with a \
            key nobody asked it to use:
            \(bundleReport)
            """)
        #expect(r.out.lowercased().contains("unsigned"),
                "the run leaves the bundle unsigned and never says so:\n\(r.out)")
    }
}

/// Asked for the real keychain's Developer ID, the script produces a bundle a
/// peer pin can check.
///
/// **This is the assertion issue #71 says is impossible.** The refusal recorded
/// in `Sources/CoffeeBarProbe/main.swift` and `LaunchDaemonInstaller.swift` is
/// that there is no Team ID to pin an XPC peer against. There is one, and this
/// test is what makes that true of a bundle rather than of a certificate sitting
/// unused in a keychain.
///
/// The identity is passed EXPLICITLY, which is the whole change
/// `signingIsOptInSoAnUnaskedRunLeavesTheBundleUnsigned` guards: the script no
/// longer goes looking for a key, so a test of the signing path has to ask for
/// one. It is read out of `security` here rather than hard-coded, so this holds
/// for any maintainer's certificate and not only for the one team ID.
///
/// **Both branches assert, and neither is a skip.** The machine's state is read
/// HERE, independently of anything the script reports:
///
/// - an identity is present — the bundle and every nested binary must name a
///   team, which is what a peer pin needs and what notarisation checks;
/// - none is present — asking for one is a build failure with a reason, not a
///   silent unsigned bundle. Opt-in makes that case reachable for the first
///   time: the user named an identity, so falling back to unsigned would be
///   answering a different question than the one they asked.
///
/// A test that returned early on the second branch would be green on a CI
/// runner for a script that had stopped signing altogether.
@Test func theRealKeychainIdentityProducesATeamPinnedBundle() throws {
    let identities = try runTool(["security", "find-identity", "-v", "-p", "codesigning"])

    guard let identity = firstDeveloperIDIdentity(in: identities.out) else {
        try withFixtureApp { _, app in
            let r = try runTool([signBundleScript().path, app.path],
                                env: ["SIGN_IDENTITY": "Developer ID Application: Nobody At All (ZZZZZZZZZZ)"])
            #expect(r.rc != 0, """
                this machine holds no Developer ID Application identity, the run \
                asked for one by name, and the script reported success anyway:
                \(r.out)
                """)
        }
        return
    }

    try withFixtureApp { _, app in
        let r = try runTool([signBundleScript().path, app.path],
                            env: ["SIGN_IDENTITY": identity])
        #expect(r.rc == 0, "sign-bundle.sh exited \(r.rc):\n\(r.out)")

        let bundleReport = try codesignReport(app.path)
        let bundleTeam = teamIdentifier(in: bundleReport)
        #expect(bundleTeam != nil, """
            the keychain holds a Developer ID Application identity, but the \
            bundle names no team, so `codesign -R` cannot pin it:
            \(bundleReport)
            """)

        // The nested binary is the half a bundle-only signature misses, and the
        // half that #71b's peer pin would be checked against.
        for binary in try nestedBinaries(of: app) {
            let report = try codesignReport(binary.path)
            #expect(teamIdentifier(in: report) == bundleTeam, """
                \(binary.lastPathComponent) does not name the same team as the \
                bundle, so it is sealed rather than signed:
                \(report)
                """)
        }

        // The requirement #71 recorded as impossible, run against the artifact.
        let team = try #require(bundleTeam)
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        let pinned = try runTool(["codesign", "--verify", "-R=\(requirement)", app.path])
        #expect(pinned.rc == 0, """
            the bundle does not satisfy `\(requirement)`, the check #71 rests on:
            \(pinned.out)
            """)
    }
}

/// The build must actually call the signing step.
///
/// **Named bug: `sign-bundle.sh` is perfect and orphaned.** Every test above
/// would stay green while `scripts/build-app.sh` shipped unsigned bundles,
/// because they run the signing script directly. Nothing else in this file
/// reaches the wiring.
///
/// Read as text, and the limit is stated rather than hidden: executing
/// `build-app.sh` costs a full `-c release` build of both products. The anchor
/// is therefore pinned to the START of a line — a comment begins with `#`, so a
/// line whose first non-blank characters are the invocation cannot be one,
/// whether the comment is on its own line or trailing. `BuildScriptVersion_test`
/// records why a whole-file `contains` is not enough: this script explains its
/// own signing rule in prose at the top, and prose satisfies `contains`.
@Test func theBuildScriptInvokesTheSigningStep() throws {
    let script = try String(contentsOf: repoRoot().appending(path: "scripts/build-app.sh"),
                            encoding: .utf8)

    let invocation = "\"${SCRIPT_DIR}/sign-bundle.sh\""
    let callSites = script.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix(invocation) }

    #expect(!callSites.isEmpty, """
        build-app.sh never runs \(invocation) as a command. The signing step is \
        not wired into the build, so every bundle it assembles is unsigned no \
        matter what sign-bundle.sh does.
        """)

    // The signature seals Contents/Resources, so anything copied in afterwards
    // breaks it. Named bug: the call is moved up next to the binary copies and
    // the glyphs, the LICENCE and the icon land after it.
    let sign = try #require(script.range(of: invocation))
    let icon = try #require(script.range(of: "iconutil -c icns"))
    #expect(icon.lowerBound < sign.lowerBound,
            "the bundle is signed before the icon is written into it, which breaks the seal")
}
