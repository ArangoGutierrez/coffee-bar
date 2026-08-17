// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import CoffeeBarCore
@testable import CoffeeBarPower

/// What the root helper does when the app asks it for something.
///
/// The channel is `PrivilegedHelperPeerGate_test.swift`'s subject. This file is
/// about the ANSWER: whether the number that comes back is the hold the machine
/// is really keeping, whether a failure is distinguishable from a success, and
/// whether the registered job installs a second daemon it must not.
///
/// The fakes are local rather than shared, matching `LidClosedSession_test.swift`
/// — every double in that file is `private`, which in Swift is file-scoped, so
/// they are unreachable from here by construction rather than by preference.

/// A real `FileJournalStore` with one seam: writes can be made to fail.
///
/// Backed by the real store rather than by a dictionary, because `ArmService`
/// reads the journal BACK through `GuardedJournalReader` after it writes — and
/// that reader opens the file on disk. An in-memory double satisfies the write
/// and then the read-back finds nothing, which surfaces as `journalVanished`:
/// a rollback the service is right to perform and a fixture that was wrong to
/// provoke.
private final class ScratchJournal: JournalStoring, @unchecked Sendable {
    private let backing: FileJournalStore
    /// When set, every write fails with this. Nothing else in this double can
    /// fail, so a test that wants a failure says which one it wants.
    private let writeFailure: (any Error)?

    init(url: URL, writeFailure: (any Error)? = nil) {
        self.backing = FileJournalStore(url: url)
        self.writeFailure = writeFailure
    }

    func load() throws -> JournalRecord? { try backing.load() }

    func write(_ record: JournalRecord) throws {
        if let writeFailure { throw writeFailure }
        try backing.write(record)
    }

    func clear() throws { try backing.clear() }

    @discardableResult
    func quarantine() throws -> URL? { try backing.quarantine() }
}

private struct ScratchPower: SleepDisabledControlling {
    func isEnabled() throws -> Bool { false }
    func set(_ on: Bool) throws {}
}

/// A display that really does go dark, so §8.3's abort does not fire.
private struct SleepingDisplay: DisplaySleepForcing {
    func forceSleep() throws {}
    func isDisplayAwake() -> Bool? { false }
}

private final class CapturingNotifier: Notifying, @unchecked Sendable {
    private(set) var messages: [String] = []
    func notify(_ message: String) { messages.append(message) }
}

private enum ScratchFailure: Error { case diskFull }

/// A directory the journal guard will accept: 0700 and owned by this user.
private func scratchJournalURL() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cb-helper-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    return dir.appendingPathComponent("probe-journal.json")
}

private func makeService(writeFailure: (any Error)? = nil,
                         supervisor: any WatchdogSupervising,
                         notifier: CapturingNotifier) throws -> LidClosedHelperService {
    let url = try scratchJournalURL()
    let journal = ScratchJournal(url: url, writeFailure: writeFailure)
    // The reader keeps its OWN `FileJournalStore` for this url — the same file
    // the journal above writes. Handing it the double would let a write that
    // never reached disk read back as a success.
    let reader = GuardedJournalReader(url: url,
                                      requiredOwner: getuid(),
                                      quarantineOnRefusal: false)
    return LidClosedHelperService(
        armService: ArmService(journal: journal,
                               reader: reader,
                               power: ScratchPower(),
                               supervisor: supervisor,
                               display: SleepingDisplay(),
                               displayVerifyDelay: 0),
        watchdog: WatchdogService(reader: reader,
                                  power: ScratchPower(),
                                  supervisor: supervisor,
                                  notifier: notifier,
                                  environment: SystemWatchdogEnvironment()),
        notifier: notifier)
}

/// Drives an `@objc` reply block to completion. The helper replies inline, so
/// no waiting is needed — and asserting that is itself worth something: a
/// helper that replied asynchronously would leave the button spinning.
private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: (Int, String?)?

    func record(_ granted: Int, _ message: String?) {
        lock.lock(); defer { lock.unlock() }
        answer = (granted, message)
    }

    var value: (granted: Int, error: String?) {
        lock.lock(); defer { lock.unlock() }
        // A sentinel rather than a nil: "never replied" and "replied 0" are
        // different failures, and one of the checks below turns on the second.
        return answer.map { (granted: $0.0, error: $0.1) }
            ?? (granted: -1, error: "the helper never replied")
    }
}

private func armAndWait(_ service: LidClosedHelperService,
                        seconds: Int) -> (granted: Int, error: String?) {
    let box = ReplyBox()
    service.arm(ttlSeconds: seconds) { granted, message in
        box.record(granted, message)
    }
    return box.value
}

@Test func theHelperAnswersWithTheHoldItRecordedAndNotTheOneAskedFor() throws {
    // Named bug, and it is the same one `.arm` fixed for the terminal: the
    // caller asks for 999999 seconds, `JournalRecord` clamps it, and a helper
    // that echoed the REQUEST would have the window promise a hold of eleven
    // days over a daemon that ends it after one. The user walks away trusting
    // the number they were shown.
    //
    // The expectation is derived from the clamp itself, not from a literal 86400
    // copied out of the source, so a change to the ceiling moves both together.
    let service = try makeService(supervisor: RegisteredJobSupervisor(),
                                  notifier: CapturingNotifier())

    let answer = armAndWait(service, seconds: 999_999)

    #expect(answer.error == nil)
    #expect(answer.granted == JournalRecord.maxTTLSeconds)
    #expect(answer.granted < 999_999)
}

@Test func aFailedArmIsNotMistakableForAGrantedHold() throws {
    // Named bug: the reply carries the requested seconds on the failure path
    // too, so a caller reading only the number believes it holds a hold that
    // was never armed — and never reverts it, because as far as it knows the
    // daemon is supervising one. Zero plus a sentence cannot be misread that
    // way.
    let service = try makeService(writeFailure: ScratchFailure.diskFull,
                                  supervisor: RegisteredJobSupervisor(),
                                  notifier: CapturingNotifier())

    let answer = armAndWait(service, seconds: 3600)

    #expect(answer.granted == 0)
    #expect(answer.error != nil)
}

@Test func theRegisteredJobArmsWhereTheLaunchdInstallerCouldNot() throws {
    // THE DISCRIMINATING CHECK for `RegisteredJobSupervisor`, and the reason it
    // is a type rather than an empty closure.
    //
    // `LaunchDaemonInstaller` refuses any program path with a component that is
    // not root-owned or is group/other-writable. The helper's own executable
    // lives inside the app bundle, and `/Applications` is writable by `admin`,
    // so wiring the real installer in here makes EVERY arm from the registered
    // helper fail with `programPathInsecure` — on a signed install only, which
    // is the configuration a dev build cannot reach.
    //
    // The control is the point: the same service, the same journal, the same
    // request, differing ONLY in the supervisor. One refuses, one arms. Without
    // the refusing half this would pass over an installer that silently did
    // nothing.
    let insecurePath = NSTemporaryDirectory() + "coffee-bar-probe"
    FileManager.default.createFile(atPath: insecurePath, contents: Data("x".utf8))
    defer { try? FileManager.default.removeItem(atPath: insecurePath) }

    let refusing = try makeService(
        supervisor: LaunchDaemonInstaller(
            runner: SystemCommandRunner(),
            plistURL: URL(fileURLWithPath: NSTemporaryDirectory() + "unused.plist"),
            programPath: insecurePath),
        notifier: CapturingNotifier())
    let refused = armAndWait(refusing, seconds: 3600)
    #expect(refused.granted == 0)
    #expect(refused.error != nil)

    let registered = try makeService(supervisor: RegisteredJobSupervisor(),
                                     notifier: CapturingNotifier())
    let armed = armAndWait(registered, seconds: 3600)
    #expect(armed.error == nil)
    #expect(armed.granted == 3600)
}

@Test func unregisteringIsNeverSomethingARevertDoes() throws {
    // Named bug, and it is the one a user would actually meet: `revert` is
    // wired to tear the registration down, so the next click of the button
    // sends the user back to System Settings to enable the item again.
    // Registration is a decision the user made once; ending a hold is not
    // un-making it.
    //
    // Stated over the supervisor because that is the seam `WatchdogService`
    // calls `uninstall()` through. A conformer that did anything at all here
    // would have to do it to launchd.
    let supervisor = RegisteredJobSupervisor()
    try supervisor.uninstall()
    try supervisor.uninstall()
    try supervisor.install()

    // And it cannot reach launchd even in principle: it holds no runner and no
    // path, so there is no `launchctl` for a later edit to point somewhere.
    #expect(MemoryLayout<RegisteredJobSupervisor>.size == 0)
}
