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

private let prov = ArmProvenance(pid: 7, binaryPath: "/x", uid: 501)

private func sample(prior: Bool = false) -> JournalRecord {
    JournalRecord(intent: .sleepDisabled, priorValue: prior,
                  setAt: Date(timeIntervalSince1970: 1_000_000),
                  ttlSeconds: 900, armedBy: prov)
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
    let store = FileJournalStore(url: tempURL())
    try store.clear()   // must not throw
    #expect(try store.load() == nil)
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
        ttlSeconds: 900, armedBy: prov)
    try store.write(fractional)
    let reloaded = try store.load()
    #expect(reloaded != fractional)                      // the lossy case
    #expect(reloaded?.setAt.timeIntervalSince1970 == 1_000_000)

    // And the whole-second form, which is what HostInfo.now() produces,
    // round-trips exactly.
    let whole = JournalRecord(
        intent: .sleepDisabled, priorValue: false,
        setAt: Date(timeIntervalSince1970: 1_000_000),
        ttlSeconds: 900, armedBy: prov)
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
