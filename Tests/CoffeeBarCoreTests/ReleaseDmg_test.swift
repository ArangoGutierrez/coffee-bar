// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation

/// Holds `scripts/release-dmg.sh` to the layout v0.1.1 shipped.
///
/// **This test EXECUTES the script.** It builds a fixture bundle from `/bin/echo`
/// — a real Mach-O, so `codesign` behaves as it does on the real product — signs
/// it ad-hoc, and asserts against the disk image the script actually wrote. A
/// text-reading guard could not catch either bug named below, because both are
/// about what the tools DO, not what the script says.
///
/// The steps that need Apple credentials (notarise, staple, spctl) cannot run
/// here. They are covered by the text guards in Task 2, and by the real release
/// run, whose output goes in the CHANGELOG.

private func releaseDmgScript() -> URL {
    repoRoot().appending(path: "scripts/release-dmg.sh")
}

/// Runs a command and returns its exit code and combined output.
///
/// Reads the pipe BEFORE waiting. Waiting first deadlocks as soon as the output
/// outgrows the pipe buffer, which `hdiutil` output does.
@discardableResult
private func run(_ args: [String], env extra: [String: String] = [:]) throws -> (rc: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    for (k, v) in extra { env[k] = v }
    p.environment = env

    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// A minimal but REAL app bundle: two genuine Mach-O executables, an Info.plist,
/// and a non-empty icon file.
///
/// The icon's CONTENT is irrelevant — the script only copies it, and what is
/// under test is whether the custom-icon FLAG survives image creation. A dummy
/// file keeps the fixture free of `iconutil`.
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

/// Builds a DMG from a fixture and hands the caller the mounted volume.
private func withProducedImage(_ body: (URL, URL) throws -> Void) throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "cb-releasedmg-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let app = tmp.appending(path: "CoffeeBar.app")
    try makeFixtureApp(at: app)

    let out = tmp.appending(path: "dist")
    let r = try run([releaseDmgScript().path],
                    env: ["SIGN_IDENTITY": "-",
                          "NOTARIZE": "0",
                          "APP_SRC": app.path,
                          "OUT_DIR": out.path,
                          "VERSION": "9.9.9"])
    #expect(r.rc == 0, "release-dmg.sh exited \(r.rc):\n\(r.out)")

    let dmg = out.appending(path: "coffee-bar-9.9.9.dmg")
    #expect(FileManager.default.fileExists(atPath: dmg.path),
            "release-dmg.sh exited 0 but wrote no coffee-bar-9.9.9.dmg:\n\(r.out)")

    let mount = tmp.appending(path: "mnt")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    let attach = try run(["hdiutil", "attach", dmg.path, "-readonly", "-nobrowse",
                          "-mountpoint", mount.path])
    #expect(attach.rc == 0, "cannot attach the produced image:\n\(attach.out)")
    defer { _ = try? run(["hdiutil", "detach", mount.path, "-force"]) }

    try body(dmg, mount)
}

@Test func theImageCarriesTheLayoutThatShipped() throws {
    try withProducedImage { dmg, mount in
        // Named bug: `hdiutil create -srcfolder` drops the custom-icon bit, so a
        // one-shot build ships a generic-icon disk image while exiting 0. The
        // source folder having the flag is NOT enough; only the produced volume
        // counts, which is why this reads the mounted image.
        let info = try run(["/usr/bin/GetFileInfo", mount.path])
        #expect(info.out.contains("avbstC"),
                "the produced volume has no custom-icon flag; Finder will draw the generic icon:\n\(info.out)")

        // Named bug: the Applications symlink is dropped or points somewhere
        // else, so the user cannot drag-install and the image looks broken.
        let link = try FileManager.default.destinationOfSymbolicLink(
            atPath: mount.appending(path: "Applications").path)
        #expect(link == "/Applications", "the Applications symlink points at \(link)")

        // Named bug: a stale binary from a rename rides along unsigned. EXACT
        // set equality for the reason build-app.sh:350 already gives.
        let shipped = try FileManager.default.contentsOfDirectory(
            atPath: mount.appending(path: "CoffeeBar.app/Contents/MacOS").path).sorted()
        #expect(shipped == ["coffee-bar", "coffee-bar-probe"],
                "Contents/MacOS holds \(shipped)")

        let verify = try run(["hdiutil", "verify", dmg.path])
        #expect(verify.rc == 0, "hdiutil verify failed:\n\(verify.out)")
    }
}

@Test func theNestedBinaryIsSignedBeforeTheBundle() throws {
    try withProducedImage { _, mount in
        // Named bug: the bundle is signed before the nested probe. codesign then
        // SEALS an unsigned Mach-O, and notarisation rejects the whole bundle
        // before Gatekeeper ever sees it. Measured: with the nested signature
        // missing this returns rc=1, "code object is not signed at all".
        let app = mount.appending(path: "CoffeeBar.app").path
        let v = try run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", app])
        #expect(v.rc == 0, "codesign --verify --deep --strict failed:\n\(v.out)")
        #expect(v.out.contains("coffee-bar-probe"),
                "verification never mentions coffee-bar-probe, so the nested binary was not covered:\n\(v.out)")
    }
}

/// Guards the steps that CANNOT execute here.
///
/// Notarisation needs an Apple ID, a keychain profile and the network. These
/// assertions therefore read the script as text, exactly as
/// `BundleLicence_test.swift` and `BuildScriptVersion_test.swift` do. Each one
/// names the bug it catches, and each was checked by deleting the line it
/// asserts and observing this test go red.
@Test func theScriptConfirmsNotarisationRatherThanTrustingTheExitCode() throws {
    let s = try String(contentsOf: releaseDmgScript(), encoding: .utf8)

    // Named bug: `notarytool submit` exits 0 for a submission Apple REJECTED.
    // Shipping on the exit code alone publishes an unnotarised image that
    // Gatekeeper blocks on every machine but the one that built it.
    #expect(s.contains("notarytool submit"), "the script no longer submits for notarisation")
    #expect(s.contains("notarytool info"),
            "the script trusts `notarytool submit`'s exit code; exit 0 does not mean Accepted")
    #expect(s.contains("Accepted"),
            "the script never checks for the Accepted status")

    // Named bug: the ticket is never stapled, so the image needs a network
    // round-trip to Apple at first launch and fails offline.
    #expect(s.contains("stapler staple"), "the script no longer staples the ticket")
    #expect(s.contains("stapler validate"), "the script staples without validating the result")

    // Named bug: nothing ever asks Gatekeeper whether it would accept the file.
    #expect(s.contains("spctl"), "the script never asks Gatekeeper to assess the image")

    // Named bug: signing without a hardened runtime or a secure timestamp.
    // Notarisation refuses both, and the failure arrives minutes later from
    // Apple rather than immediately from codesign.
    #expect(s.contains("--options runtime"), "the script signs without the hardened runtime")
    #expect(s.contains("--timestamp"), "the script signs without a secure timestamp")
}

@Test func theScriptReportsWhatTheChangelogMustState() throws {
    let s = try String(contentsOf: releaseDmgScript(), encoding: .utf8)

    // Named bug: the CHANGELOG's size and SHA-256 get typed from memory. The
    // file's own header requires every claim be true of the SHIPPED build, and
    // a remembered number is not evidence.
    #expect(s.contains("shasum -a 256"), "the script does not compute the SHA-256")
    #expect(s.contains("lipo -archs"),
            "the script does not report the architecture; CHANGELOG.md claims arm64 only")
    #expect(s.contains("stat -f"), "the script does not report the size in bytes")
}
