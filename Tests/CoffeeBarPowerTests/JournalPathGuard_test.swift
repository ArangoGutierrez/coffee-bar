// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import Darwin
@testable import CoffeeBarPower
@testable import CoffeeBarCore

// SECURITY.md items 1 and 2, on the READER.
//
// The journal is an instruction to a root process. `FileJournalStore` pins
// 0700/0600 on the paths it CREATES, and SECURITY.md:184-190 records the gap
// that leaves open: a directory that already exists keeps whatever mode it had,
// because an unprivileged writer that repairs a path another user may control
// is not a fix. Item 1 therefore puts the check on the reader, which is the
// privileged side, and these are that check's tests.
//
// Every test here drives a scratch path. Nothing reads or writes
// `/Library/Application Support/coffee-bar`, and nothing runs as root.

/// A scratch directory tree, owner-only, removed when the test finishes.
///
/// `NSTemporaryDirectory()` resolves to `/private/var/folders/<…>/T` on this
/// platform. Measured: every component of it is owned by uid 0 down to the
/// per-user folder, which is owned by the running user, and NONE is group- or
/// other-writable. That is what lets `requiredOwner: getuid()` exercise the
/// passing path without a root-owned fixture.
private func makeScratchRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "coffee-bar-journal-guard-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    return root
}

private func makeRecord(priorValue: Bool = false,
                        setAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
                        ttlSeconds: Int = 3600) -> JournalRecord {
    JournalRecord(intent: .sleepDisabled, priorValue: priorValue, setAt: setAt,
                  ttlSeconds: ttlSeconds,
                  armedBy: ArmProvenance(pid: 1234, binaryPath: "/usr/local/bin/probe",
                                         uid: 501))
}

private func mode(of url: URL) throws -> mode_t {
    var info = stat()
    try #require(lstat(url.path, &info) == 0, "could not stat \(url.path)")
    return info.st_mode & 0o7777
}

// MARK: - The positive control

@Test func theGuardedReaderReturnsAJournalWhoseWholePathIsSound() throws {
    // Without this every refusal below could pass for the wrong reason — a
    // reader that refused EVERYTHING would satisfy all of them. This is the
    // one case that proves the guard can say yes.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let url = root.appending(path: "state/probe-journal.json")
    let store = FileJournalStore(url: url)
    let written = makeRecord(priorValue: true)
    try store.write(written)

    // The store's own promise, re-checked here because every refusal test
    // below assumes this starting state.
    #expect(try mode(of: url) == 0o600)
    #expect(try mode(of: url.deletingLastPathComponent()) == 0o700)

    let reader = GuardedJournalReader(url: url, store: store,
                                      requiredOwner: getuid())
    #expect(try reader.read() == written)
}

@Test func theGuardedReaderReportsNoJournalRatherThanRefusingWhenNothingIsArmed() throws {
    // "Nothing armed" is the ordinary state and must not look like a refusal.
    // A reader that threw here would make every unarmed boot an incident.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let url = root.appending(path: "state/probe-journal.json")
    let reader = GuardedJournalReader(url: url, store: FileJournalStore(url: url),
                                      requiredOwner: getuid())
    #expect(try reader.read() == nil)
}

// MARK: - Item 1: every component, before it reads anything

@Test func aGroupWritableJournalDirectoryIsRefusedAndQuarantined() throws {
    // SECURITY.md items 1 and 2 together, and the exact gap SECURITY.md:184-190
    // names: `FileJournalStore` cannot repair a directory it did not create, so
    // a journal sitting in a 0770 directory is one any member of that group can
    // rewrite. A root process that obeyed it would restore an attacker's
    // chosen `priorValue`.
    //
    // Named bug this catches: a reader that checks only the journal FILE. The
    // file below is a perfect 0600; only the directory is wrong.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let url = root.appending(path: "state/probe-journal.json")
    let store = FileJournalStore(url: url)
    try store.write(makeRecord())

    let stateDir = url.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o770],
                                          ofItemAtPath: stateDir.path)

    let reader = GuardedJournalReader(url: url, store: store,
                                      requiredOwner: getuid())

    var refusal: JournalRefusal?
    #expect(throws: JournalRefusal.self) {
        do { _ = try reader.read() } catch let error as JournalRefusal {
            refusal = error
            throw error
        }
    }

    guard case .insecurePath(_, let components)? = refusal else {
        Issue.record("expected an insecurePath refusal, got \(String(describing: refusal))")
        return
    }
    // The offending component is NAMED, and it is the directory rather than
    // the file. An operator who has to `chmod` their way out needs to be told
    // which one.
    #expect(components.contains { $0.path == stateDir.path && $0.groupOrOtherWritable })

    // Item 2: quarantined, not deleted and not obeyed. A journal that will not
    // pass still proves something WAS armed.
    #expect(FileManager.default.fileExists(atPath: url.path) == false,
            "the refused journal was left in place for the next reader to trust")
    let siblings = try FileManager.default.contentsOfDirectory(atPath: stateDir.path)
    #expect(siblings.contains { $0.hasPrefix("probe-journal.corrupt.") },
            "nothing was quarantined; the evidence is gone: \(siblings)")
}

@Test func anInsecurePathIsRefusedBeforeTheJournalBytesAreDecoded() throws {
    // "before it reads anything" is the load-bearing half of item 1, and it is
    // invisible to a test that only checks THAT a refusal happened.
    //
    // The journal below is not decodable at all. A reader that loaded first and
    // validated afterwards throws `.corrupt`; one that validates first throws
    // `.insecurePath`. The two are distinguishable only because the bytes are
    // garbage, which is exactly why they are.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let stateDir = root.appending(path: "state")
    try FileManager.default.createDirectory(
        at: stateDir, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    let url = stateDir.appending(path: "probe-journal.json")
    try #require(FileManager.default.createFile(
        atPath: url.path, contents: Data("not json at all".utf8),
        attributes: [.posixPermissions: 0o600]))

    try FileManager.default.setAttributes([.posixPermissions: 0o777],
                                          ofItemAtPath: stateDir.path)

    let reader = GuardedJournalReader(url: url, store: FileJournalStore(url: url),
                                      requiredOwner: getuid())
    var refusal: JournalRefusal?
    #expect(throws: JournalRefusal.self) {
        do { _ = try reader.read() } catch let error as JournalRefusal {
            refusal = error
            throw error
        }
    }
    guard case .insecurePath? = refusal else {
        Issue.record("""
            the reader decoded the journal before it checked the path: got \
            \(String(describing: refusal)). Item 1 says the check comes first.
            """)
        return
    }
}

@Test func anInsecureAncestorIsRefusedEvenWhenTheDirectoryAndFileArePerfect() throws {
    // "EVERY component of the journal path", not the last two. A 0600 journal
    // inside a 0700 directory inside a 0777 one can be replaced wholesale by
    // renaming the directory out from under it.
    //
    // Named bug this catches: a reader that walks up only as far as the
    // journal's own parent.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let url = root.appending(path: "state/probe-journal.json")
    let store = FileJournalStore(url: url)
    try store.write(makeRecord())

    // The grandparent, left untouched by the two checks a shallow guard makes.
    try FileManager.default.setAttributes([.posixPermissions: 0o777],
                                          ofItemAtPath: root.path)

    let reader = GuardedJournalReader(url: url, store: store,
                                      requiredOwner: getuid())
    var refusal: JournalRefusal?
    #expect(throws: JournalRefusal.self) {
        do { _ = try reader.read() } catch let error as JournalRefusal {
            refusal = error
            throw error
        }
    }
    guard case .insecurePath(_, let components)? = refusal else {
        Issue.record("expected insecurePath, got \(String(describing: refusal))")
        return
    }
    #expect(components.contains { $0.path == root.path },
            "the grandparent was never checked: \(components.map(\.path))")
}

// MARK: - Item 2: ownership and mode must match expectation

@Test func aWorldWritableJournalFileIsRefusedInsideASoundDirectory() throws {
    // The mirror of the directory case. Here the whole ancestry is sound and
    // only the file is wrong, so a guard that checked ancestors and forgot the
    // leaf passes every other test in this file.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let url = root.appending(path: "state/probe-journal.json")
    let store = FileJournalStore(url: url)
    try store.write(makeRecord())
    try FileManager.default.setAttributes([.posixPermissions: 0o666],
                                          ofItemAtPath: url.path)

    let reader = GuardedJournalReader(url: url, store: store,
                                      requiredOwner: getuid())
    #expect(throws: JournalRefusal.self) { _ = try reader.read() }
}

@Test func aGroupReadableJournalIsRefusedBecauseTheModeMustMatchExactly() throws {
    // 0640 is not group-WRITABLE, so a guard built only on the write bits lets
    // it through. Item 2 refuses a journal "whose ownership or mode does not
    // match expectation", and item 3 fixes that expectation at 0600.
    //
    // This is the one case that discriminates the exact-mode rule from the
    // writability rule. The journal carries `armedBy` provenance — pid, uid and
    // binary path — which no other user has any business reading.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let url = root.appending(path: "state/probe-journal.json")
    let store = FileJournalStore(url: url)
    try store.write(makeRecord())
    try FileManager.default.setAttributes([.posixPermissions: 0o640],
                                          ofItemAtPath: url.path)

    let reader = GuardedJournalReader(url: url, store: store,
                                      requiredOwner: getuid())
    #expect(throws: JournalRefusal.self) { _ = try reader.read() }
}

@Test func theGuardedReaderRequiresRootOwnershipByDefault() throws {
    // The production bar, pinned. Every other test in this file passes
    // `requiredOwner: getuid()` so a scratch path can exercise the logic at
    // all, and that affordance is worthless if the DEFAULT drifts with it.
    //
    // Named bug this catches: someone widening the default to `getuid()` to
    // make a test go green, which would let any local user's journal instruct
    // the root helper.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let url = root.appending(path: "state/probe-journal.json")
    let store = FileJournalStore(url: url)
    try store.write(makeRecord())

    // No `requiredOwner:`. The scratch path is owned by this user, not by root.
    let reader = GuardedJournalReader(url: url, store: store)
    #expect(throws: JournalRefusal.self) { _ = try reader.read() }

    try #require(getuid() != 0, "this test is vacuous when the suite runs as root")
}

// MARK: - One rule, two callers

@Test func theProgramPathAndTheJournalPathAreJudgedByTheSameRule() throws {
    // `LaunchDaemonInstaller` has enforced this bar on the program path since
    // M0; the journal reader is the second caller. Two copies of a security
    // rule drift the moment one is edited — the precedent is
    // `BatteryFloor.bounded`, which exists because a second clamp with its own
    // literals had already drifted once.
    //
    // Named bug this catches: a fix applied to one path check and not the
    // other. Both are asked about the SAME directory and must agree.
    let root = try makeScratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let victim = root.appending(path: "program")
    try #require(FileManager.default.createFile(
        atPath: victim.path, contents: Data(), attributes: [.posixPermissions: 0o755]))
    try FileManager.default.setAttributes([.posixPermissions: 0o777],
                                          ofItemAtPath: root.path)

    var installerComponents: [InsecurePathComponent] = []
    do {
        _ = try LaunchDaemonInstaller.validatedProgramPath(victim.path)
        Issue.record("the installer accepted a program inside a 0777 directory")
    } catch let error as WatchdogInstallError {
        guard case .programPathInsecure(_, let components) = error else {
            Issue.record("expected programPathInsecure, got \(error)")
            return
        }
        installerComponents = components
    }

    // The shared rule, asked directly, with the SAME required owner the
    // installer uses.
    let shared = try PathSecurity.insecureComponents(
        of: victim.path, requiredOwner: 0)

    #expect(installerComponents == shared, """
        the installer's program-path check and the shared path rule disagree.
          installer: \(installerComponents)
          shared:    \(shared)
        They must be one rule with two callers, or a fix lands in one and not \
        the other.
        """)
    #expect(shared.isEmpty == false,
            "the shared rule found nothing wrong with a 0777 directory")
}
