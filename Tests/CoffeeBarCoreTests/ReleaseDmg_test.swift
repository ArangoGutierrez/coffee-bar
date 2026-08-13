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

/// Where an `sh` comment begins on `line`, or nil if the line carries none.
///
/// A `#` opens a comment only when it is UNQUOTED **and** starts a word — at the
/// start of the line, or after whitespace or a command separator.
///
/// NEITHER half has a live case in `release-dmg.sh` today, and saying so is more
/// useful than inventing one. Measured: the script's only `#` outside a comment
/// is `VERSION="${VERSION#v}"` at `release-dmg.sh:43`, and BOTH rules protect it
/// independently — it is inside double quotes AND it follows `N` rather than
/// whitespace. Removing either rule alone leaves that line intact, which is why
/// only `shellCodeWithoutCommentsCutsOnlyRealComments` pins them separately.
///
/// Both are here because the naive strip — cut at the first `#`, full stop — is
/// the obvious "simplification" and it is measurably wrong: it cuts that line to
/// `VERSION="${VERSION`, and `bash -n` then rejects the result with rc=2.
///
/// Scanning STOPS at the comment, so a comment's own text never reaches the quote
/// tracker. That is what makes an apostrophe in prose harmless: a lone `'` in a
/// sentence would otherwise flip the tracker into "quoted" and swallow the rest
/// of the file silently.
private func shellCommentStart(in line: Substring) -> Substring.Index? {
    var inSingle = false, inDouble = false, escaped = false
    var startsAWord = true
    var i = line.startIndex
    while i < line.endIndex {
        let c = line[i]
        if escaped {
            escaped = false
            startsAWord = false
        } else if c == "\\" && !inSingle {
            escaped = true
            startsAWord = false
        } else if c == "'" && !inDouble {
            inSingle.toggle()
            startsAWord = false
        } else if c == "\"" && !inSingle {
            inDouble.toggle()
            startsAWord = false
        } else if c == "#" && !inSingle && !inDouble && startsAWord {
            return i
        } else {
            startsAWord = c == " " || c == "\t" || c == ";" || c == "|" || c == "&" || c == "("
        }
        i = line.index(after: i)
    }
    return nil
}

/// `source` with every `sh` comment cut and everything else left byte-identical.
///
/// The shebang survives: `#!/bin/bash` on the first line is an interpreter
/// directive rather than prose, and a guard may legitimately assert it. Only the
/// first line is exempt, so a `#!` written lower down is still a comment.
///
/// Only the comment is cut, never the whole line, so code sharing a line with a
/// comment is kept and every line holds its position — failure messages still
/// quote real line numbers and `range(of:)` offsets keep the script's order.
///
/// LIMITS, stated rather than hidden. Neither is reachable in `release-dmg.sh`
/// today, and both are measured rather than assumed:
///
/// - **Heredoc bodies are not recognised.** A body line carrying a word-starting
///   `#` would be cut as if it were a comment. Measured: the script's three
///   `<<REPORT` bodies contain no `#` at all.
/// - **Quote state resets at each newline.** A quoted string spanning a newline
///   would be mis-parsed. Measured: the script has none, and `bash -n` parses the
///   stripped output clean.
///
/// `strippingCommentsLeavesTheScriptParseable` is what keeps those two honest. It
/// is not decoration: mutating this function to the naive strip makes it fail
/// with `bash` rc=2, measured.
private func shellCodeWithoutComments(_ source: String) -> String {
    source.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
        .map { index, line -> String in
            if index == 0 && line.hasPrefix("#!") { return String(line) }
            guard let cut = shellCommentStart(in: line) else { return String(line) }
            return String(line[line.startIndex..<cut])
        }
        .joined(separator: "\n")
}

/// `scripts/release-dmg.sh` with its comments cut, so an assertion reads what the
/// script DOES rather than what its prose says about itself.
///
/// Three named bugs, every one of them measured against a guard that was GREEN at
/// the time. This script explains itself in its comments and names the very
/// commands the guards anchor on:
///
/// - `ditto -c -k --keepParent` is named at `release-dmg.sh:117` and run at
///   `:119`. Replacing the command with the `zip -r` its own comment warns
///   against left the guard GREEN — it was matching the prose.
/// - `stapler staple "${APP}"` is the ORDER anchor, and order is the whole
///   correctness argument: the staged copy is taken from `${APP}`, so the app
///   must carry its ticket before `hdiutil create` reads it. Moving the staple
///   after `hdiutil convert` and leaving a whole-line comment naming it also
///   stayed GREEN, because `range(of:)` found the comment first.
/// - The same staple defeat, with the naming comment APPENDED to an existing
///   line instead of standing on its own, defeated the first repair too: that
///   strip was line-oriented, so a TRAILING comment was invisible to it. This
///   one cuts from the `#` rather than dropping the line, which is why a
///   trailing comment can no longer smuggle an anchor in.
///
/// All three are the UNSAFE direction — a shipped image carrying an unstapled
/// app, which is exactly the v0.2.0 regression #82 exists to fix.
private func releaseDmgScriptWithoutComments() throws -> String {
    shellCodeWithoutComments(try String(contentsOf: releaseDmgScript(), encoding: .utf8))
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

/// Serialises the `hdiutil` cycle in `withProducedImage`.
///
/// Named bug: CI failed with `hdiutil: create failed - Resource busy`. Every
/// other issue in that run cascaded from it — no image was written, so `attach`
/// failed, so the mount was empty, so `Applications` and the layout assertions
/// had nothing to read.
///
/// This file declares no `@Suite`, so its tests run concurrently, and THREE of
/// them call `withProducedImage`. Measured on this branch immediately before
/// this lock was added, by timestamping the region: all three of 3 pairs
/// overlapped, and all three were inside the cycle simultaneously for 30.95 s
/// of a 38.69 s window. They have been racing since the file was written and
/// mostly winning; CI load is what finally tipped one over.
///
/// A lock rather than `@Suite(.serialized)` because the contended resource is
/// the create/attach/detach cycle rather than the test functions. It states the
/// invariant — at most one cycle in flight — where the cycle actually is, and
/// leaves this file's five text-only guards parallel. The isolation is the same
/// either way, and no wider: exactly like `.serialized` (the caveat is recorded
/// in `ProbeRun_test.swift` "orders a suite's own tests, not other suites") this
/// orders THIS file's cycles and nothing else. Measured: no other test in the
/// package shells out to `hdiutil`. One
/// added elsewhere would have to take this same lock.
private let imageCycleLock = NSLock()

/// Builds a DMG from a fixture and hands the caller the mounted volume, plus
/// everything the script printed.
///
/// The script's own output is a third parameter because the report block is a
/// PRODUCT of the run, not text in a file: whether it claims a step that this
/// run skipped can only be read off the run itself.
private func withProducedImage(_ body: (URL, URL, String) throws -> Void) throws {
    // Registered FIRST, so it runs LAST: `defer` is LIFO, which puts the unlock
    // after the detach registered below. The whole cycle — produce, attach,
    // body, detach — is inside the critical section, not just the create.
    imageCycleLock.lock()
    defer { imageCycleLock.unlock() }

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

    try body(dmg, mount, r.out)
}

@Test func theImageCarriesTheLayoutThatShipped() throws {
    try withProducedImage { dmg, mount, _ in
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
    try withProducedImage { _, mount, _ in
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

    // Named bug: a row quietly leaves the report block, the maintainer pastes a
    // seven-row table into CHANGELOG.md, and
    // `theReleaseFactsOnThePageAreTheOnesInTheChangelog` fails at the END of the
    // release — after the artifact is already built and notarised.
    //
    // A LITERAL list, duplicated on purpose from the one that
    // `SiteClaims_test.swift` "let the two agree on nothing at all" explains,
    // and for the reason stated there: deriving it from the script would let the
    // script agree with itself about an empty table. These two lists are meant
    // to be compared by a human when either changes.
    for fact in ["File", "Size", "SHA-256", "Architecture",
                 "Minimum macOS", "Signature", "Notarisation", "Staple"] {
        #expect(s.contains("| \(fact) |"),
                "the report block has no \(fact) row; CHANGELOG.md's release table needs all eight")
    }

    // Named bug: the macOS floor is typed as a literal and drifts from
    // Package.swift the first time the floor moves.
    //
    // The full `${REPO_ROOT}/Package.swift` path, NOT the bare file name. The
    // bare name was the first form of this guard and it was theater: the comment
    // above the derivation says "Read from Package.swift", so replacing the whole
    // derivation with `MIN_MACOS="14.0"` left the guard GREEN. Measured, then
    // rewritten. Only a line that USES the file as an argument matches this.
    #expect(s.contains("${REPO_ROOT}/Package.swift"),
            "Minimum macOS is not read from Package.swift, so it can drift from the real platform floor")
}

/// The report cannot claim a step this run did not perform.
///
/// **This test EXECUTES the script**, on the `NOTARIZE=0` path, and reads the
/// report it actually printed. A text guard cannot catch this: the Notarisation
/// and Staple strings are present in the file either way, and the whole question
/// is whether the RUN emits them when it never notarised or stapled.
@Test func theReportRefusesToClaimTheStepsItSkipped() throws {
    try withProducedImage { _, _, out in
        // Named bug: `| Staple | `xcrun stapler validate` passes |` printed as a
        // constant by a run that never stapled. That row is then pasted into
        // CHANGELOG.md, whose header requires every claim be true of the shipped
        // build, and the document now asserts a validation nobody ran.
        #expect(out.contains("| Staple |") == false,
                "the NOTARIZE=0 run printed a Staple row; it never stapled anything:\n\(out)")
        #expect(out.contains("| Notarisation |") == false,
                "the NOTARIZE=0 run printed a Notarisation row; it never notarised anything:\n\(out)")

        // Named bug: the rows are dropped and nothing says why, so the maintainer
        // pastes a six-row table and only the site-mirror guard notices.
        //
        // A sentence unique to the REPORT block, not the bare string "NOTARIZE=0".
        // The bare string was the first form of this guard and it was theater:
        // step 6 already echoes "==> NOTARIZE=0: skipping notarisation…", so
        // deleting the report's paragraph entirely left the guard GREEN.
        // Measured, then rewritten.
        #expect(out.contains("rows are omitted rather than asserted"),
                "the run skipped notarisation and stapling but the report never says so:\n\(out)")

        // The six rows that DO NOT depend on notarisation must still be printed.
        for fact in ["File", "Size", "SHA-256", "Architecture",
                     "Minimum macOS", "Signature"] {
            #expect(out.contains("| \(fact) |"),
                    "the report omits the \(fact) row, which does not depend on notarisation:\n\(out)")
        }

        // Named bug: the floor is parsed out of Package.swift and the parse
        // silently yields an empty string, printing `| Minimum macOS |  |`.
        // 14.0 is the independent literal — Package.swift declares `.macOS(.v14)`.
        #expect(out.contains("| Minimum macOS | 14.0 |"),
                "the Minimum macOS row does not read 14.0, the floor Package.swift declares:\n\(out)")
    }
}

/// The app inside the image must carry its own ticket.
///
/// v0.1.1 shipped one and v0.2.0 did not — measured by mounting both images on
/// 2026-08-09. Stapling exists so Gatekeeper can verify WITHOUT a network round
/// trip, so an app copied out of an unstapled image has nothing local to check
/// against on a first launch offline.
///
/// **That last sentence is READ, not measured.** It is Apple's documented
/// reason for stapling, and this project has never put it to the test: no
/// offline first launch has ever been executed here — not by a release
/// acceptance, not by hand, not anywhere. Issue #91 is open on exactly that
/// gap. The design spec said so from the start, in
/// `docs/superpowers/specs/2026-08-09-v0.2.1-upgrade-trust-design.md`
/// "Not verified: the offline failure mode itself".
///
/// An earlier version of this comment claimed the release acceptance ran one.
/// It did not, and no release has. That claim is retracted; the checklist in
/// `.github/ISSUE_TEMPLATE/release.yml` stops at `stapler validate` on the
/// mounted image, which proves a ticket is attached, not that a machine with
/// no network can open the app.
///
/// So the assertions below are text-read, because notarising needs an Apple ID
/// and the network. What they prove is narrower than the paragraph above and
/// is true: the script staples the app itself, and it does so before the image
/// is assembled around it.
@Test func theAppIsNotarisedAndStapledBeforeTheImageIsBuilt() throws {
    // Comments come out FIRST, and every assertion below reads the stripped
    // text. This script names `ditto -c -k --keepParent` and `hdiutil create` in
    // its own prose, so a raw `contains` matched the explanation instead of the
    // command: both a deleted `ditto` and a staple moved after the image passed
    // GREEN. `releaseDmgScriptWithoutComments` carries the measurements.
    //
    // One read, one strip. Stripping for one assertion and not another in this
    // function would leave exactly the hole this closes.
    let s = try releaseDmgScriptWithoutComments()

    // Named bug: the app is submitted but never stapled, so the ticket lives
    // only on Apple's servers and the offline case is unchanged.
    #expect(s.contains("stapler staple \"${APP}\""),
            "the script never staples the app bundle itself")

    // Named bug: stapling the app AFTER the image is assembled, which staples
    // a copy nobody ships. The staged copy is taken from ${APP}, so the order
    // is the whole correctness argument.
    //
    // The image anchor stays `hdiutil create -volname`, the COMMAND rather than
    // the bare phrase, and that is deliberate belt-and-braces: the strip already
    // removes the two comments naming `hdiutil create`, but the flag pins the
    // anchor to the invocation even if a future non-comment line mentions it.
    let stapleApp = try #require(s.range(of: "stapler staple \"${APP}\""))
    let createImage = try #require(s.range(of: "hdiutil create -volname"))
    #expect(stapleApp.lowerBound < createImage.lowerBound,
            "the app is stapled after the image is assembled, so the image carries the unstapled copy")

    // Named bug: trusting `notarytool submit`'s exit code for the app the same
    // way the image step must not. Exit 0 does not mean Accepted.
    #expect(s.contains("ditto -c -k --keepParent"),
            "the app is not zipped for submission; notarytool cannot take a bare .app")

    // Named bug, and it was measured: the Staple row read '`xcrun stapler
    // validate` passes' and was set in the image step alone, so it printed the
    // same text whether or not the app had been stapled. Reverting that string
    // left the WHOLE suite green — the fix that made the report honest was
    // itself unguarded. This is the assertion that would have caught it.
    //
    // Read from the stripped text like everything else here, so the comment
    // above `STAPLE_FACT` in the script cannot satisfy it.
    #expect(s.contains("on the app and on the image"),
            "the Staple row does not name both staples, so it reads the same for a run that stapled the app and one that did not")
}

/// Pins `shellCodeWithoutComments`, because the guard above is only as honest as
/// this function is.
///
/// The case that matters most is `trailing comment`. The first version of this
/// strip was line-oriented — it dropped a line whose first non-whitespace
/// character was `#` — and a comment APPENDED to an existing line was therefore
/// invisible to it. That is not hypothetical: appending
/// `# xcrun stapler staple "${APP}" runs later` to the `fi` at
/// `release-dmg.sh:74`, with the staple moved after `hdiutil convert`, passed
/// GREEN while the image carried an unstapled app. Every other case here exists
/// to stop the repair over-reaching in the other direction and cutting code.
@Test func shellCodeWithoutCommentsCutsOnlyRealComments() {
    let cases: [(name: String, source: String, expected: String)] = [
        ("shebang survives", "#!/bin/bash\necho hi", "#!/bin/bash\necho hi"),
        ("a later shebang is prose", "echo a\n#!/bin/sh", "echo a\n"),
        ("whole-line comment", "echo a\n# why\necho b", "echo a\n\necho b"),
        ("indented comment", "  # why", "  "),
        ("trailing comment", "fi  # why", "fi  "),
        ("parameter expansion is not a comment", "V=\"${V#v}\"", "V=\"${V#v}\""),
        ("hash inside double quotes", "echo \"a # b\"", "echo \"a # b\""),
        ("hash inside single quotes", "echo 'a # b'", "echo 'a # b'"),
        ("hash mid-word is not a comment", "echo a#b", "echo a#b"),
        ("an apostrophe in prose does not leak", "# it's fine\necho \"x\"", "\necho \"x\""),
        ("comment after a separator", "echo a; # why", "echo a; "),
        ("escaped hash is not a comment", "echo \\#1", "echo \\#1"),
    ]

    for testCase in cases {
        #expect(shellCodeWithoutComments(testCase.source) == testCase.expected,
                """
                \(testCase.name): got \
                \(shellCodeWithoutComments(testCase.source).debugDescription), \
                want \(testCase.expected.debugDescription)
                """)
    }
}

/// Stripping the comments out of the real script must leave a script.
///
/// The table above pins the cases someone thought of. This one catches the cases
/// nobody did, against the actual file: cutting a comment can only ever remove
/// prose, so whatever survives has to still parse. A strip that swallowed a
/// quote, truncated inside a string, or ate a line continuation would leave text
/// `bash -n` rejects, and the table would not necessarily show it.
///
/// This is also what makes the LIMITS documented on `shellCodeWithoutComments`
/// true rather than merely claimed: a heredoc body cut in half, or a quoted
/// string spanning a newline, both fail here.
@Test func strippingCommentsLeavesTheScriptParseable() throws {
    let stripped = try releaseDmgScriptWithoutComments()

    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "cb-stripped-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let script = tmp.appending(path: "stripped.sh")
    try stripped.write(to: script, atomically: true, encoding: .utf8)

    let r = try run(["bash", "-n", script.path])
    #expect(r.rc == 0, "the stripped script does not parse, so the strip cut code:\n\(r.out)")

    // Anti-vacuity. `bash -n` on an empty file also exits 0, so prove the text
    // that reached it is the script rather than the wreckage of one.
    #expect(stripped.contains("hdiutil create -volname"),
            "the stripped text lost the image command, so the check above passed on wreckage")
    #expect(stripped.hasPrefix("#!/bin/bash"),
            "the stripped text lost the shebang")
}

// MARK: - Guard: the retracted offline-launch claim must not come back (#91)

/// A claim pattern that will not compile.
///
/// Thrown rather than skipped. A pattern that never compiled matches nothing,
/// and a scan that matches nothing is indistinguishable from a clean tree —
/// which is precisely the failure this whole guard exists to prevent.
private struct OfflineClaimPatternBroken: Error, CustomStringConvertible {
    let pattern: String
    var description: String {
        "the offline-claim pattern \(pattern) does not compile, so this scan would read the tree and find nothing"
    }
}

/// Text reduced so a claim that WRAPS can still be matched.
///
/// The sentence this guard exists to catch lived in a doc comment and broke
/// across two lines, so a raw read of the file it sat in never contained it in
/// one piece. Whitespace and the markers that lead a wrapped line — the slashes
/// of a doc comment, a Markdown blockquote, a bullet — collapse to one space,
/// which puts a Swift copy and a Markdown copy into the same shape. Lowercased
/// last, so the patterns need no case alternation.
private func offlineClaimNormalised(_ text: String) -> String {
    text.replacingOccurrences(of: "[\\s/#*>]+", with: " ", options: .regularExpression)
        .lowercased()
}

/// The sentence shapes that ASSERT an offline launch happened.
///
/// Each entry is keyed BY INDEX to the control at the same index in
/// `offlineLaunchClaimControls`, and the test proves every pattern still fires
/// on its own control before it scans anything.
///
/// They are deliberately narrow, and the narrowness is the design. "The v0.2.1
/// acceptance should include an actual offline launch" is the design spec being
/// honest about a gap; a guard that failed on true prose would be switched off
/// within a week rather than fixed. What is refused is the indicative: that one
/// HAS been executed, or that an acceptance DOES run one.
private let offlineLaunchClaimPatterns = [
    "acceptance[^.]{0,40}runs an (actual |real )?offline( first)? launch",
    "offline( first)? launch (is|was|has been|has ever been|have been|had been) (executed|run|performed|verified|measured)",
    "(executed|ran|performed|carried out|measured) an (actual |real )?offline( first)? launch",
    "acceptance (includes|covers|contains|has) an (actual |real )?offline( first)? launch",
]

/// Words that turn a matched shape back into an honest sentence.
///
/// Without this, "no offline first launch has ever been executed here" — the
/// retraction itself, and the truest sentence in this file — reads as the claim
/// it denies. The window is 60 characters of NORMALISED text before the match,
/// measured to be wider than any of the retractions this branch writes and
/// narrower than the sentence before them.
///
/// **The cost, stated rather than hidden.** A real claim with an unrelated "not"
/// within 60 characters is suppressed. That is the right way round: a false
/// negative here loses one tripwire, a false positive teaches the reader that
/// this guard cries wolf, and the second failure is the one that kills a guard.
private let offlineLaunchClaimNegators = ["no ", "not ", "never", "cannot", "yet to", "n't", "nothing"]

private let offlineLaunchNegationWindow = 60

/// The indices of every pattern that fires on `text`, negations excluded.
///
/// Indices and not the matched text: a failure message must name the offending
/// file without reprinting the claim, or the guard republishes the sentence it
/// was written to remove — and swift-testing prints every subexpression of an
/// `#expect`, so the obvious form would dump whole files into a public CI log.
/// `FixtureRedaction_test.swift` records that measurement.
private func offlineLaunchClaims(in text: String) throws -> [Int] {
    let normalised = offlineClaimNormalised(text)
    let ns = normalised as NSString
    var found: [Int] = []

    for (index, pattern) in offlineLaunchClaimPatterns.enumerated() {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            throw OfflineClaimPatternBroken(pattern: pattern)
        }
        let whole = NSRange(location: 0, length: ns.length)
        for match in expression.matches(in: normalised, range: whole) {
            let start = match.range.location
            let from = max(0, start - offlineLaunchNegationWindow)
            let before = ns.substring(with: NSRange(location: from, length: start - from))
            guard !offlineLaunchClaimNegators.contains(where: { before.contains($0) }) else { continue }
            found.append(index)
        }
    }
    return found
}

/// One claim per pattern, in the same order.
///
/// The first is the sentence this branch retracted, verbatim — it is what the
/// tree carried, so it is what the matcher must catch. The other three are
/// written, not quoted: no such sentence has ever been in this tree, and
/// inventing a plausible one is the only way to prove the patterns that would
/// catch it still work.
///
/// **Every one is split across literals, and every split is load bearing.** The
/// acceptance for #91 is that no sentence like these exists anywhere git
/// tracks, and this file is tracked. Each break falls inside the phrase that
/// control's own pattern keys on, so the repository never holds any of them in
/// one piece while the runtime strings stay exactly what the matcher must
/// catch. Joining any pair of fragments back up turns the scan below red on
/// this very file, which is the correct answer.
///
/// That is also what lets the scan read THIS file raw. The first version split
/// only the control above and hid the other three by REMOVING their text from
/// the file before matching it — and that removal was a hole: the retracted
/// sentence pasted back as one line was removed by the very loop meant to hide
/// the fragments, so the guard stayed green on the exact sentence #91 is about.
/// Nothing is removed now, so nothing can be removed by mistake.
private let offlineLaunchClaimControls = [
    "Text-read, because notarising needs an Apple ID and the network. "
        + "The executed proof is the release itself, whose acceptance runs an "
        + "offline launch.",
    "The offline first "
        + "launch was executed on 2026-08-09.",
    "The v0.2.2 cut ran an "
        + "offline launch on a cold machine.",
    "The release acceptance includes an "
        + "offline launch.",
]

/// True sentences about the offline gap that must stay sayable.
///
/// The first is this branch's own retraction and the second is the shape a
/// future #91 note would take; both MATCH a pattern and survive only because a
/// negator precedes them, so they are what proves that half works. The third is
/// the rationale the test above keeps, and matches nothing.
///
/// The design spec's wording is NOT copied in here — it is read from the spec
/// itself, so this control cannot drift away from the document it stands for.
private let honestOfflineSentences = [
    "No offline first launch has ever been executed here, by an acceptance or by hand.",
    "This project has never executed an offline launch, and #91 is open on it.",
    "Stapling exists so Gatekeeper can verify without a network round trip.",
]

/// The design spec, which has been honest about this gap since the day it was
/// written, and the plan whose Task 4 block seeded the false copy. Both are
/// corpus controls below: a scan that reaches neither is reading the wrong tree.
private let offlineDesignSpec = "docs/superpowers/specs/2026-08-09-v0.2.1-upgrade-trust-design.md"
private let offlineSeedPlan = "docs/superpowers/plans/2026-08-09-v0.2.1-upgrade-trust.md"

/// The design spec's own sentence about the gap, which must not read as a claim.
private let offlineSpecSentence =
    "The v0.2.1 acceptance should include an actual offline launch, because a "
    + "diagnosis is a hypothesis until it is executed."

/// No tracked file says an offline first launch has been executed.
///
/// **The invariant, stated so a future reader can attack it: while #91 is open,
/// no file git tracks may claim that an offline first launch has been executed,
/// or that a release acceptance runs one.** Saying it SHOULD happen is honest
/// and the design spec does exactly that. Saying it HAS happened is false.
///
/// **Named bug this catches.** The doc comment above
/// `theAppIsNotarisedAndStapledBeforeTheImageIsBuilt` justified a text-read
/// guard by naming the release acceptance as the executed proof of the offline
/// failure mode. No release has ever run one: the checklist stops at `stapler
/// validate` on the mounted image, and nothing in the tree touches the network
/// state. The claim was written into a plan, copied into a test file by a
/// builder following that plan, and then read as settled fact for two releases —
/// which is exactly how it would come back.
///
/// **Why a tracked-file scan and not a check on the one comment.** The claim has
/// already demonstrated its ability to travel: one sentence, two files, two
/// different languages. A guard pinned to the site it was found at would have
/// been green on the copy in the plan.
@Test func noTrackedFileClaimsAnOfflineLaunchWasExecuted() throws {
    // THE MATCHER FIRST, pattern by pattern. A clean tree is the expected state,
    // so scanning it establishes nothing about whether the scan can see. These
    // four controls are the only place the matcher is proved to fire at all.
    for (index, control) in offlineLaunchClaimControls.enumerated() {
        let hits = try offlineLaunchClaims(in: control)
        #expect(hits.contains(index), """
            claim pattern #\(index) no longer fires on the claim it was written \
            for, so every file the scan below reads is read blind
            """)
    }

    // …and it must not fire on the truth. A guard that fails on the retraction
    // forces the next reader to choose between an honest comment and a green
    // suite, and the suite wins that argument every time.
    for (index, sentence) in honestOfflineSentences.enumerated() {
        let hits = try offlineLaunchClaims(in: sentence)
        #expect(hits.isEmpty, """
            honest sentence #\(index) reads as a claim (pattern(s) \(hits)); \
            this guard would fail the tree for telling the truth
            """)
    }

    let files = try trackedTextFiles()

    // Two corpus controls, because a count alone cannot tell a full tree from a
    // partial one. These are the two documents #91 is about.
    for control in [offlineDesignSpec, offlineSeedPlan] {
        #expect(files.contains(control),
                "the tracked-file listing never reached \(control), one of the two documents #91 is about")
    }

    // The spec's honest wording is the hardest negative control there is,
    // because it is real, it is about this exact gap, and it survives only if
    // the patterns stay narrow. Read from the file so a paraphrase cannot stand
    // in for it, and normalised because the sentence wraps in the document.
    let specText = try String(contentsOf: repoRoot().appending(path: offlineDesignSpec), encoding: .utf8)
    let specCarriesIt = offlineClaimNormalised(specText).contains(offlineClaimNormalised(offlineSpecSentence))
    #expect(specCarriesIt, """
        the design spec no longer carries the sentence this guard uses as its \
        negative control; either the spec changed or the control has rotted, \
        and until that is resolved nothing here proves the patterns are narrow
        """)
    let specClaims = try offlineLaunchClaims(in: specText)
    #expect(specClaims.isEmpty, "the design spec reads as a claim (pattern(s) \(specClaims)); it is honest prose about a gap")

    // THE SCAN. One exemption, this file, handled separately below.
    let selfPath = String(#filePath.dropFirst(repoRoot().path.count + 1))
    var scanned = 0
    var unreadable: [String] = []
    var offenders: [String] = []

    for name in files where name != selfPath {
        guard let text = try? String(contentsOf: repoRoot().appending(path: name), encoding: .utf8) else {
            unreadable.append(name)
            continue
        }
        scanned += 1
        for index in try offlineLaunchClaims(in: text) {
            offenders.append("\(name) (pattern #\(index))")
        }
    }

    // ANTI-VACUITY. A listing that resolved the wrong root, or a filter that ate
    // the corpus, finds nothing and reads as success. Measured on this commit:
    // 270 files scanned, one short of the 271 the listing returns.
    #expect(scanned >= 250, """
        read \(scanned) tracked file(s) under \(repoRoot().path); the corpus \
        collapsed and this scan is weaker than it looks
        """)

    // The message describes the offending shape rather than restating it. A
    // guard that spelled its own subject out would report itself on the next
    // run, and would put the retracted sentence back into the repository.
    #expect(offenders.isEmpty, """
        \(offenders.count) tracked file(s) read as claiming that an offline \
        first launch happened, or that a release acceptance covers one. \
        Neither is true, and #91 is open on exactly that: \(offenders.sorted())
        """)

    // A file the scan could not READ is a file it did not CHECK, and skipping
    // it silently shrinks the corpus without moving the count above.
    #expect(unreadable.isEmpty, """
        \(unreadable.count) tracked file(s) could not be read as UTF-8, so this \
        scan never checked them: \(unreadable.sorted())
        """)

    // THIS FILE, READ RAW — and it is the one read that cannot be filtered. It
    // is left out of the loop above because that loop walks the git listing,
    // and a filter change there would drop the one file the claim actually
    // lived in without moving any count. `#filePath` is resolved by the
    // compiler, so this read happens whatever the listing says.
    //
    // Nothing is removed before matching, and that is the whole point. Every
    // control is split across literals, so the raw text of this file holds no
    // claim, and what it gets here is the same scan every other tracked file
    // gets. The first version stripped the joined control text out first, and
    // that strip ate a real single-line copy of the retracted sentence along
    // with the fragments it was aimed at.
    let ownText = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
    let ownClaims = try offlineLaunchClaims(in: ownText)
    #expect(ownClaims.isEmpty, """
        this file claims an offline launch outside its own controls (pattern(s) \
        \(ownClaims)); the comment that started #91 lived here, and this is the \
        assertion that refuses to let it come back
        """)
}
