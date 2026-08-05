// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import Darwin
@testable import CoffeeBarPower

// The demotion journal, and why it is a SECOND file rather than a second field
// on the one that already exists.
//
// The sleep journal is root-owned, mode 0600, and under M5 a ROOT process reads
// it and acts on it. `SECURITY.md` calls that file "an instruction to a root
// process" and binds four preconditions to it, one of which is that the helper
// refuses a journal it did not write.
//
// Process demotion is unprivileged and same-uid, so its journal is written by
// the user's own app and is user-owned. Putting user-writable data into the file
// a root process obeys would build exactly the instruction channel those four
// preconditions exist to close. So: a second store, a second record type, a
// second path — and the two live in different directory trees, not merely under
// different names.
//
// `theDemotionJournalIsNowhereNearTheFileARootProcessReads` is the check that
// holds that apart. It is a security guard, not tidiness.

/// The permission bits, read through `stat(2)`.
///
/// Not through `FileManager.attributesOfItem`: reading the mode back through the
/// same API that set it can agree with a bug in that API. Matches
/// `JournalStore_test.swift`, which takes the same line for the same reason.
private func posixMode(of path: String) -> mode_t? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    return info.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)
}

/// A journal under a throwaway directory, never the user's real one.
private func throwawayJournal() throws -> (store: FileDemotionJournalStore, url: URL, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cb-demotion-journal-\(UUID().uuidString)")
    let url = root.appendingPathComponent("state").appendingPathComponent("demotion-journal.json")
    return (FileDemotionJournalStore(url: url), url, root)
}

private func entry(pid: pid_t, seconds: UInt64 = 1_785_911_481,
                   microseconds: UInt64 = 335_072,
                   name: String = "cb-ordinary",
                   priorFlags: UInt32 = 0x1404010) -> DemotionEntry {
    DemotionEntry(
        identity: ProcIdentity(pid: pid, startedAtSeconds: seconds,
                               startedAtMicroseconds: microseconds),
        name: name, priorFlags: priorFlags,
        demotedAt: Date(timeIntervalSince1970: 1_785_911_500))
}

@Suite struct DemotionJournalTests {

    // MARK: - The security boundary

    @Test func theDemotionJournalIsNowhereNearTheFileARootProcessReads() {
        // THE security check for this task. The bug it catches is a later author
        // deciding that one journal is simpler than two and pointing this store
        // at the sleep journal, or at its directory. That would put data any
        // same-uid process can write into the file the M5 root helper reads as
        // an instruction, defeating SECURITY.md preconditions 1 and 2.
        //
        // Different NAMES are not enough, because precondition 1 checks every
        // component of the path: the two must not share a directory either.
        let mine = FileDemotionJournalStore.userURL
        let root = FileJournalStore.systemURL

        #expect(mine != root)
        #expect(mine.deletingLastPathComponent() != root.deletingLastPathComponent())

        // The sleep journal is a system path a root helper owns. This one is
        // under the user's own home, which is what makes it unprivileged data.
        #expect(root.path.hasPrefix("/Library/"))
        #expect(mine.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
        #expect(!mine.path.hasPrefix("/Library/"))
    }

    @Test func theDirectoryIsOwnerOnlyAndTheFileIsOwnerReadWrite() throws {
        // The bug: leaving the modes to the process umask, which on a stock
        // account is 0755 and 0644. This journal names every process coffee-bar
        // demoted — forensic detail no other user needs — and a world-writable
        // one would let any local user choose which pids a later run promotes.
        //
        // Read BACK from the filesystem with `stat(2)`. Asserting the attributes
        // the store passed in would only restate the request.
        let journal = try throwawayJournal()
        defer { try? FileManager.default.removeItem(at: journal.root) }

        try journal.store.append(entry(pid: 5000))

        #expect(posixMode(of: journal.url.deletingLastPathComponent().path) == 0o700)
        #expect(posixMode(of: journal.url.path) == 0o600)
    }

    // MARK: - Round trip

    @Test func anEntryComesBackWithEveryFieldARestoreNeeds() throws {
        // The bug: dropping a field on the way to disk. Three of the four
        // conditions a restore must satisfy are decided by fields in this
        // record — the identity settles pid reuse and `priorFlags` settles
        // whether this app set the bit — so a field lost in encoding turns the
        // recovery path into a blind one.
        let journal = try throwawayJournal()
        defer { try? FileManager.default.removeItem(at: journal.root) }
        let written = entry(pid: 5000, name: "cb-round-trip", priorFlags: 0x1404010)

        try journal.store.append(written)
        let read = try #require(try journal.store.load())

        #expect(read.entries == [written])
        #expect(read.schemaVersion == DemotionJournalRecord.currentSchemaVersion)
    }

    @Test func appendKeepsWhatWasAlreadyThere() throws {
        // The bug: an "append" that overwrites. coffee-bar demotes a set of
        // processes, one call at a time, and a store that keeps only the last
        // one strands every earlier process for ever.
        let journal = try throwawayJournal()
        defer { try? FileManager.default.removeItem(at: journal.root) }

        try journal.store.append(entry(pid: 5000, name: "first"))
        try journal.store.append(entry(pid: 5001, name: "second"))
        try journal.store.append(entry(pid: 5002, name: "third"))

        let read = try #require(try journal.store.load())
        #expect(read.entries.map(\.name) == ["first", "second", "third"])
    }

    @Test func aSecondStoreOverTheSamePathReadsWhatTheFirstWrote() throws {
        // This IS the recovery mechanism, in miniature: the whole design rests
        // on a LATER RUN reading back what an earlier one wrote. A store that
        // could only read its own in-memory state would pass every check above
        // and recover nothing after a crash.
        let journal = try throwawayJournal()
        defer { try? FileManager.default.removeItem(at: journal.root) }

        try journal.store.append(entry(pid: 5000, name: "cb-survivor"))

        let laterRun = FileDemotionJournalStore(url: journal.url)
        let read = try #require(try laterRun.load())
        #expect(read.entries.map(\.name) == ["cb-survivor"])
    }

    // MARK: - Failure

    @Test func aMissingJournalIsNilAndAnUnreadableOneIsAnError() throws {
        // Two answers that must never be confused. No journal means no run
        // demoted anything, and there is nothing to do. A journal that will not
        // decode means a run DID demote something and we cannot tell what —
        // reporting that as "nothing" strands those processes silently, with no
        // error and no evidence.
        let journal = try throwawayJournal()
        defer { try? FileManager.default.removeItem(at: journal.root) }

        #expect(try journal.store.load() == nil)

        try FileManager.default.createDirectory(
            at: journal.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("this is not the journal you are looking for".utf8).write(to: journal.url)

        #expect(throws: DemotionJournalError.self) { try journal.store.load() }
    }

    @Test func clearRemovesTheJournalAndToleratesAMissingOne() throws {
        // The bug: a `clear` that throws when there is nothing to clear. It runs
        // at the end of every recovery, including the ordinary case where no
        // journal existed, and a throw there would turn a clean start into a
        // reported failure.
        let journal = try throwawayJournal()
        defer { try? FileManager.default.removeItem(at: journal.root) }

        try journal.store.clear()

        try journal.store.append(entry(pid: 5000))
        #expect(FileManager.default.fileExists(atPath: journal.url.path))

        try journal.store.clear()
        #expect(!FileManager.default.fileExists(atPath: journal.url.path))
        #expect(try journal.store.load() == nil)
    }

    // MARK: - What the record means

    @Test func anEntryKnowsWhetherThisAppSetTheBackgroundBit() {
        // Invariant 2, carried on the record itself. `-B` on a process that was
        // already background PROMOTES it, which is a change the user never asked
        // for — handoff §5.6 warns about it. The flags word measured BEFORE the
        // demotion is the only thing that can tell the two cases apart, and
        // measuring it after would always read the bit set.
        let ours = entry(pid: 5000, priorFlags: 0x1404010)
        #expect(ours.appliedByThisApp)

        let alreadyBackground = entry(pid: 5001, priorFlags: 0x1014010)
        #expect(!alreadyBackground.appliedByThisApp)

        // A process that backgrounded ITSELF is a different channel and does not
        // block a restore: measured on macOS 26.5.2 (25F84), an external restore
        // leaves the self bit alone.
        let selfBackgrounded = entry(pid: 5002, priorFlags: 0x140c010)
        #expect(selfBackgrounded.appliedByThisApp)
    }
}
