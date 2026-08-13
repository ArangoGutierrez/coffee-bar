// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarPower
@testable import CoffeeBarCore

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("cb-journal-\(UUID().uuidString)")
        .appendingPathComponent("probe-journal.json")
}

/// The permission bits the FILESYSTEM reports for `path`, or `nil` when the
/// path cannot be stat'd.
///
/// Read through `stat(2)` rather than through `FileManager.attributesOfItem`,
/// so the reading cannot agree with a wrong implementation by going through the
/// same API that set the mode. `st_mode` also carries the file type, so the
/// permission bits are masked out explicitly.
private func posixMode(of path: String) -> mode_t? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    return info.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)
}

/// The body of the function declared by `signature` in `source`, with comments
/// removed, or `nil` when there is no such declaration.
///
/// Comments are stripped so that prose ABOUT an API cannot satisfy — or break —
/// a check that the CALL is present. Braces inside string literals would
/// confuse the matching; neither function read this way contains one.
private func functionBody(_ signature: String, in source: String) -> String? {
    let code = source
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> Substring in
            guard let marker = line.range(of: "//") else { return line }
            return line[line.startIndex ..< marker.lowerBound]
        }
        .joined(separator: "\n")

    guard let declaration = code.range(of: signature),
          let open = code[declaration.upperBound...].firstIndex(of: "{") else { return nil }

    var depth = 0
    var cursor = open
    while cursor < code.endIndex {
        if code[cursor] == "{" { depth += 1 }
        if code[cursor] == "}" {
            depth -= 1
            if depth == 0 { return String(code[code.index(after: open) ..< cursor]) }
        }
        cursor = code.index(after: cursor)
    }
    return nil
}

private let prov = ArmProvenance(pid: 7, binaryPath: "/x", uid: 501)

private func sample(prior: Bool = false) -> JournalRecord {
    JournalRecord(intent: .sleepDisabled, priorValue: prior,
                  setAt: Date(timeIntervalSince1970: 1_000_000),
                  setAtMonotonic: 10_000, ttlSeconds: 900, armedBy: prov)
}

@Test func loadOnMissingFileReturnsNil() throws {
    let store = FileJournalStore(url: tempURL())
    #expect(try store.load() == nil)
}

@Test func writeThenLoadRoundTrips() throws {
    let store = FileJournalStore(url: tempURL())
    let record = sample(prior: true)
    try store.write(record)
    #expect(try store.load() == record)
}

@Test func writeCreatesIntermediateDirectories() throws {
    // TWO levels missing, deliberately. M5's real path is
    // …/coffee-bar/state/probe-journal.json, so both `coffee-bar` and `state`
    // can be absent on a first arm. `tempURL()` alone leaves only ONE level
    // absent, and `createDirectory` creates a single missing level whether or
    // not `withIntermediateDirectories` is set — so one level proves nothing.
    let url = tempURL().deletingLastPathComponent()
        .appendingPathComponent("state")
        .appendingPathComponent("probe-journal.json")
    let store = FileJournalStore(url: url)
    try store.write(sample())
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(try store.load() == sample())
}

// MARK: - Modes
//
// SECURITY.md records the target: the directory is 0700 and the journal is
// 0600, and neither is left to whichever process created the path first. The
// journal is an instruction to a root process under M5, so a mode the helper
// cannot trust is a mode that stops it acting.
//
// Every assertion below reads the mode BACK from the filesystem. Asserting the
// attributes dictionary the store passed in would only restate the request.

@Test func aFirstWriteCreatesThePrivateDirectoryAndFileModes() throws {
    // The create path. With no `attributes:` the modes come from the process
    // umask — 022 on a stock account, so 0755 and 0644, which is exactly what
    // SECURITY.md reported. A world-readable journal publishes the arming
    // provenance: pid, uid and binary path of whatever disabled sleep.
    let url = tempURL()
    try FileJournalStore(url: url).write(sample())

    #expect(posixMode(of: url.deletingLastPathComponent().path) == 0o700)
    #expect(posixMode(of: url.path) == 0o600)
}

@Test func everyLaterSaveKeepsThePrivateModes() throws {
    // The REPLACE path: on the second write the destination already exists, so
    // `replaceItemAt` runs against a live file rather than an absent one.
    //
    // Be precise about what this catches, because the obvious claim is wrong.
    // It does NOT catch the destination-metadata defect: with the store's own
    // 0600 file at the destination, dropping `.usingNewMetadataOnly` leaves
    // this test GREEN — measured. That defect belongs to
    // `aWriteRepairsAJournalAnEarlierBuildLeftWorldReadable`, which is the only
    // test that goes red for it.
    //
    // What this one catches is a save that stops pinning the mode at all, and
    // it catches it on the second write rather than the first: removing either
    // `attributes:` argument turns it red. A future replace that reset the mode
    // to the umask would land here too, and the create-path test would not see
    // it.
    let url = tempURL()
    let store = FileJournalStore(url: url)
    try store.write(sample(prior: false))
    try store.write(sample(prior: true))

    #expect(posixMode(of: url.deletingLastPathComponent().path) == 0o700)
    #expect(posixMode(of: url.path) == 0o600)
    // Pins the premise: without this the assertions above could be reading the
    // FIRST write's file, and the replace path would go unexercised.
    #expect(try store.load()?.priorValue == true)
}

@Test func aWriteRepairsAJournalAnEarlierBuildLeftWorldReadable() throws {
    // Every journal written before the modes were pinned is 0644 on disk. If
    // the replace preserves the DESTINATION's metadata, that mode outlives the
    // upgrade and every later save, and the file stays world-readable forever.
    // Upgrading would silently fix nothing.
    let url = tempURL()
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    try Data("{}".utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: url.path)
    // Pins the premise: if the legacy mode were not really 0644, the assertion
    // below would pass without the repair ever being exercised.
    try #require(posixMode(of: url.path) == 0o644)

    try FileJournalStore(url: url).write(sample())

    #expect(posixMode(of: url.path) == 0o600)
}

@Test func everyDirectoryLevelTheStoreCreatesIsPrivate() throws {
    // SECURITY.md item 1: the M5 helper verifies EVERY component of the journal
    // path, not only the final file. The real path is
    // …/coffee-bar/state/probe-journal.json, so a first arm can create TWO
    // levels — and a 0700 leaf inside a 0755 parent still fails that check,
    // because anyone who can write the parent can swap the leaf.
    let outer = tempURL().deletingLastPathComponent()
    let url = outer.appendingPathComponent("state")
        .appendingPathComponent("probe-journal.json")
    try FileJournalStore(url: url).write(sample())

    #expect(posixMode(of: outer.path) == 0o700)
    #expect(posixMode(of: url.deletingLastPathComponent().path) == 0o700)
    #expect(posixMode(of: url.path) == 0o600)
}

// Root bypasses the permission denial this test depends on, which would leave
// it vacuously green rather than failing honestly.
@Test(.enabled(if: geteuid() != 0))
func anUncreatableTempFileSurfacesWriteFailed() throws {
    // `JournalError.writeFailed` is the arm path's "the journal did not land"
    // signal — the caller must NOT go on to disable sleep — and nothing
    // reached it, so the arm sequence's own failure branch was unexercised.
    //
    // Mode 0o500 (read + execute, no write) is that case exactly: the
    // directory already exists so `createDirectory` is a no-op, then
    // `createFile` on the sibling temp file fails with EACCES.
    let url = tempURL()
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: dir.path)
    }

    // Pins the premise: if 0o500 ever stopped denying the create, this test
    // would pass without exercising the failure path at all.
    let probeFD = open(dir.appendingPathComponent("probe").path,
                       O_WRONLY | O_CREAT, 0o644)
    if probeFD >= 0 { close(probeFD) }
    #expect(probeFD == -1)

    let thrown = #expect(throws: JournalError.self) {
        try FileJournalStore(url: url).write(sample())
    }
    // The message names the file that could not be created, so an incident
    // reader can tell a permission problem from a full disk. Only the UUID in
    // the temp name is unpinnable.
    if case .writeFailed(let message) = thrown {
        #expect(message.hasPrefix("could not create \(dir.path)/.probe-journal."))
        #expect(message.hasSuffix(".tmp"))
    } else {
        Issue.record("expected .writeFailed, got \(String(describing: thrown))")
    }
}

@Test func clearRemovesTheJournal() throws {
    let url = tempURL()
    let store = FileJournalStore(url: url)
    try store.write(sample())
    try store.clear()
    #expect(try store.load() == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func clearOnMissingFileIsNotAnError() throws {
    // Unchanged text, changed meaning. While `clear()` began with an existence
    // check this passed because the guard short-circuited on a file that never
    // existed, and it said nothing about the removal. It now drives the removal
    // for real and is the behavioural half of the not-found tolerance: the
    // journal is absent, `removeItem` reports `.fileNoSuchFile`, and the caller
    // still sees success.
    let store = FileJournalStore(url: tempURL())
    try store.clear()   // must not throw
    #expect(try store.load() == nil)
}

// MARK: - The delete race
//
// `applyRevert` restores the sleep setting and THEN clears the journal. A
// failure from `clear()` therefore reports `could not revert` (exit 70) after a
// revert that already worked, and leaves an idle root daemon loaded.

@Test func clearNeverAsksWhetherTheJournalExistsBeforeRemovingIt() throws {
    // The defect is a check-then-act: `fileExists` then `removeItem`. Whoever
    // loses the unlink throws, and `applyRevert` turns that into
    // `could not revert` and exit 70 after a revert that already worked.
    //
    // The race IS real and was reproduced before this guard was written, not
    // reasoned about: driving the original check-then-act from a hot loop
    // produced 669 failures over 32,000 clears, every single one
    // NSCocoaErrorDomain 4 (NSFileNoSuchFileError) wrapping POSIX ENOENT.
    //
    // That reproduction is deliberately NOT the test. Its detection is
    // load-sensitive — measured in-suite at 6 of 8 runs with 4 threads and 7 of
    // 8 with 16, costing between 2.2 and 12.3 seconds — so as a shipped guard
    // it would be a coin flip that sometimes certifies the bug as fixed. This
    // check is the deterministic half: the window cannot exist if the existence
    // check does not, and no in-process test can observe the window itself.
    //
    // LIMIT, stated rather than hidden: this reads the SOURCE, exactly as
    // `theJournalIsForcedToStableStorageBeforeItIsRenamedIntoPlace` does. It is
    // a tripwire against re-introducing the check, not proof that no race
    // exists.
    let source = try String(
        contentsOf: packageRootForSyncCheck
            .appending(path: "Sources/CoffeeBarPower/JournalStore.swift"),
        encoding: .utf8)

    let body = try #require(functionBody("public func clear() throws", in: source), """
        clear() was not found in JournalStore.swift, so this check can no longer \
        see the code it exists to assert on.
        """)
    // Pins the premise that the body really was extracted: absence of a match
    // in an empty string is not absence of the check.
    try #require(body.contains("removeItem"))

    // Control. `quarantine()` legitimately checks first and must keep doing so,
    // which proves the extractor finds a real body and that these probes DO hit
    // when the code contains one. Without it, a broken extractor would report
    // the clean result this test is looking for.
    let quarantineBody = try #require(
        functionBody("public func quarantine() throws -> URL?", in: source))
    try #require(quarantineBody.contains("fileExists"))

    for probe in ["fileExists", "attributesOfItem", "isReadableFile", "access("] {
        #expect(!body.contains(probe), """
            clear() consults `\(probe)` before removing the journal. That is the \
            check-then-act window: another process can delete the journal in \
            between, and the loser reports a revert that worked as a failure.
            """)
    }
}

@Test func anAbsentJournalIsReportedAsFileNoSuchFileAndNothingElse() throws {
    // Pins the premise the tolerance is keyed on. `clear()` must swallow
    // exactly one error code, so if Foundation ever reported an absent file as
    // something else the tolerance would silently stop matching and the race
    // would come back. This is the measurement that decided the code: absence
    // arrives as NSCocoaErrorDomain 4 (NSFileNoSuchFileError) wrapping POSIX
    // ENOENT — NOT as a `POSIXError`, which is the shape it is easiest to
    // reach for and which would never match.
    //
    // Every level of absence reports the same code, which is why the fix does
    // not need to care which one it met: a missing file under an existing
    // directory, and a missing file under a directory that does not exist
    // either — the shape `tempURL()` produces.
    let existingParent = tempURL()
    try FileManager.default.createDirectory(
        at: existingParent.deletingLastPathComponent(), withIntermediateDirectories: true)

    for absent in [existingParent, tempURL()] {
        let thrown = #expect(throws: CocoaError.self) {
            try FileManager.default.removeItem(at: absent)
        }
        #expect(thrown?.code == .fileNoSuchFile)
        #expect((thrown?.underlying as? NSError)?.code == Int(ENOENT))
    }
}

// Root bypasses the permission denial this test depends on, which would leave
// it vacuously green rather than failing honestly.
@Test(.enabled(if: geteuid() != 0))
func clearStillThrowsWhenTheJournalCannotBeRemoved() throws {
    // The discriminating negative. Tolerating a not-found removal must not
    // decay into swallowing every removal failure: a journal still on disk
    // because of a permissions problem is a real failure, and hiding it leaves
    // a root-owned file the user cannot clear and a caller that believes the
    // arming record is gone.
    //
    // Mode 0o500 on the parent (read + execute, no write) is that case exactly:
    // the journal is still stat-able, so the removal is genuinely attempted,
    // and `unlink` fails with EACCES.
    let url = tempURL()
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: dir.path)
    }

    // Pins the premise: unlinking needs write on the DIRECTORY, exactly as
    // creating does. If 0o500 ever stopped denying that, this test would pass
    // without the failure path being exercised at all.
    let probeFD = open(dir.appendingPathComponent("probe").path,
                       O_WRONLY | O_CREAT, 0o644)
    if probeFD >= 0 { close(probeFD) }
    #expect(probeFD == -1)

    let thrown = #expect(throws: CocoaError.self) {
        try FileJournalStore(url: url).clear()
    }
    // The exact code, not merely "it threw": `.fileNoSuchFile` here would mean
    // the tolerance had matched the wrong failure.
    #expect(thrown?.code == .fileWriteNoPermission)
    // And the journal really is still there — the throw described a removal
    // that did not happen.
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func corruptJournalThrowsRatherThanReturningNil() throws {
    // A corrupt journal must NOT look like "no journal" — that would let a
    // set SleepDisabled flag go unnoticed. The caller reverts on error.
    let url = tempURL()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: url)
    let store = FileJournalStore(url: url)
    #expect(throws: JournalError.self) { try store.load() }
}

@Test func journalIsWrittenAsISO8601NotAnEpochDouble() throws {
    // Pins the coder strategy at this boundary. Under the default
    // .deferredToDate the date lands as a bare Double: unreadable in an
    // incident, and not bit-exact on reload for a live Date().
    let url = tempURL()
    try FileJournalStore(url: url).write(sample())
    let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
    #expect(text.contains("\"setAt\":\"19"))     // ISO-8601 string form
    #expect(!text.contains("\"setAt\":-"))       // reference-date double form
}

@Test func subSecondStampsDoNotSurviveAndMustNotBeUsed() throws {
    // Documents the contract rather than pretending it does not exist:
    // ISO-8601 has SECOND granularity, so a sub-second setAt cannot
    // round-trip. Journals are therefore stamped with HostInfo.now(), which
    // truncates. This test fails loudly if someone "improves" the strategy
    // to something lossy in a different way.
    let url = tempURL()
    let store = FileJournalStore(url: url)
    let fractional = JournalRecord(
        intent: .sleepDisabled, priorValue: false,
        setAt: Date(timeIntervalSince1970: 1_000_000.75),
        setAtMonotonic: 10_000, ttlSeconds: 900, armedBy: prov)
    try store.write(fractional)
    let reloaded = try store.load()
    #expect(reloaded != fractional)                      // the lossy case
    #expect(reloaded?.setAt.timeIntervalSince1970 == 1_000_000)

    // And the whole-second form, which is what HostInfo.now() produces,
    // round-trips exactly.
    let whole = JournalRecord(
        intent: .sleepDisabled, priorValue: false,
        setAt: Date(timeIntervalSince1970: 1_000_000),
        setAtMonotonic: 10_000, ttlSeconds: 900, armedBy: prov)
    try store.write(whole)
    #expect(try store.load() == whole)
}

@Test func quarantineMovesTheFileAsideRatherThanDeletingIt() throws {
    // A journal that will not decode is the only evidence of why a machine
    // stopped sleeping. Deleting it destroys that; renaming preserves it.
    let url = tempURL()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: url)

    let store = FileJournalStore(url: url)
    let moved = try store.quarantine()

    #expect(moved != nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(FileManager.default.fileExists(atPath: moved!.path))
    // Contents preserved verbatim — this is forensic evidence.
    #expect(String(decoding: try Data(contentsOf: moved!), as: UTF8.self)
            == "{ not json")
}

@Test func quarantineOnMissingJournalReturnsNil() throws {
    #expect(try FileJournalStore(url: tempURL()).quarantine() == nil)
}

@Test func writeIsAtomicUnderOverwrite() throws {
    // Atomicity IS observable, so assert it rather than asserting "the last
    // write won" — an in-place `data.write(to: url)` satisfies that just as
    // well, which left the previous version of this test green with the
    // guarantee gone.
    //
    // `replaceItemAt` swaps a fully-written sibling in by rename, so a reader
    // that already opened the journal keeps its descriptor on the ORIGINAL
    // inode and goes on seeing the original bytes. An in-place write truncates
    // the very file that descriptor points at, so the held reader sees the new
    // bytes or a torn prefix instead. That difference is the whole test.
    let url = tempURL()
    let store = FileJournalStore(url: url)
    try store.write(sample(prior: false))
    let original = try Data(contentsOf: url)

    let fd = open(url.path, O_RDONLY)
    try #require(fd >= 0)
    defer { close(fd) }

    try store.write(sample(prior: true))

    let held = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    #expect(held.readDataToEndOfFile() == original)
    // And the path itself now resolves to the new record — so this is an
    // atomic REPLACEMENT, not a write that quietly failed.
    #expect(try store.load()?.priorValue == true)
}

// Root bypasses the permission check this test depends on, which would leave
// it vacuously green rather than failing honestly.
@Test(.enabled(if: geteuid() != 0))
func aFailedDirectoryBarrierStillLeavesTheWriteSuccessful() throws {
    // write() takes a barrier on the PARENT DIRECTORY after the rename, so the
    // journal's NAME is durable and not merely its contents. That barrier is
    // best-effort by design: a directory that cannot be opened must not turn a
    // successful write into a failed arm. The bytes are already on media, and
    // the caller is about to disable sleep on the strength of this call
    // returning — failing here would refuse to arm over a lost guarantee we
    // never had before this code existed.
    //
    // Mode 0o300 (write + execute, no read) is that case exactly: createFile,
    // F_FULLFSYNC and replaceItemAt all succeed while open(dir, O_RDONLY)
    // fails with EACCES.
    //
    // This does NOT test durability. No user-space API reports whether a
    // barrier reached media; only a real power cut can. It tests the barrier's
    // failure path, which is observable.
    let url = tempURL()
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o300], ofItemAtPath: dir.path)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: dir.path)
    }

    // Pins the premise: if 0o300 ever stopped denying the open, the rest of
    // this test would pass without exercising the failure path at all.
    let probeFD = open(dir.path, O_RDONLY)
    if probeFD >= 0 { close(probeFD) }
    #expect(probeFD == -1)

    let store = FileJournalStore(url: url)
    let record = sample(prior: true)
    try store.write(record)          // must not throw
    #expect(try store.load() == record)
}

// MARK: - §8.2(1)'s other half: the sync

/// The package root, resolved from `#filePath` rather than the working
/// directory, which under `swift test` is not the package root.
private var packageRootForSyncCheck: URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarPowerTests/JournalStore_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarPowerTests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // the package root
}

@Test func theJournalIsForcedToStableStorageBeforeItIsRenamedIntoPlace() throws {
    // §8.2(1) says the journal is written "and `fsync`s", and the ordering
    // guards in `LidClosedSession_test` cover only the first half: they prove
    // `write` RETURNS before `pmset` runs, which a `write` that never synced
    // would also satisfy. The durability is the whole point — a journal still
    // in the drive cache when the power fails is a journal that was never
    // written, and the machine comes back holding a setting with no record of
    // it.
    //
    // Plain `fsync(2)` on macOS pushes only to the drive cache. `F_FULLFSYNC`
    // is the documented durable barrier, so the constant itself is what has to
    // be there.
    //
    // LIMIT, stated rather than hidden: this reads the SOURCE. It proves the
    // barrier is CALLED and that it precedes the rename; it cannot prove the
    // call succeeded, and no in-process test can, because forcing `fcntl` to
    // fail needs a filesystem that refuses `F_FULLFSYNC`. It is a tripwire
    // against deleting the barrier, not proof of durability.
    let source = try String(
        contentsOf: packageRootForSyncCheck
            .appending(path: "Sources/CoffeeBarPower/JournalStore.swift"),
        encoding: .utf8)

    // Comments are stripped so the doc comment ABOUT F_FULLFSYNC cannot
    // satisfy a check that the CALL exists.
    let code = source
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> Substring in
            guard let marker = line.range(of: "//") else { return line }
            return line[line.startIndex ..< marker.lowerBound]
        }
        .joined(separator: "\n")

    let rename = try #require(code.range(of: "replaceItemAt"), """
        JournalStore.swift no longer renames the temp file into place, so this \
        check can no longer see the ordering it exists to assert.
        """)

    // BOTH barriers, found separately. `range(of:)` returns only the FIRST
    // match, so a guard built on one call sees the file barrier and is blind to
    // the directory barrier entirely — measured: replacing the directory
    // `F_FULLFSYNC` with a no-op left that shape green.
    //
    // They protect different things. The first makes the journal's BYTES
    // durable; the second (JournalStore.swift:141-150) makes its NAME durable,
    // because the rename is a directory metadata change and a power failure can
    // otherwise leave the entry absent while the mutation it describes has
    // already landed.
    var barriers: [Range<String.Index>] = []
    var cursor = code.startIndex
    while let found = code.range(of: "F_FULLFSYNC", range: cursor ..< code.endIndex) {
        barriers.append(found)
        cursor = found.upperBound
    }

    #expect(barriers.count >= 2, """
        JournalStore.swift calls F_FULLFSYNC \(barriers.count) time(s) in code. \
        The write needs two: one for the file's bytes and one for the parent \
        directory, so the journal's name is durable and not just its contents.
        """)

    #expect(barriers.contains { $0.lowerBound < rename.lowerBound }, """
        no F_FULLFSYNC precedes the rename. The name becomes visible while the \
        bytes behind it are still in the drive cache, which is the window the \
        barrier exists to close.
        """)

    #expect(barriers.contains { $0.lowerBound > rename.upperBound }, """
        no F_FULLFSYNC follows the rename, so the parent directory is never \
        barriered. After a power failure the journal entry can be absent while \
        the system mutation it describes has already landed — which is the \
        state §8.2 exists to make impossible.
        """)
}
