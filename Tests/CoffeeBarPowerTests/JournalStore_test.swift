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
    let url = tempURL()
    let store = FileJournalStore(url: url)
    try store.write(sample())
    #expect(FileManager.default.fileExists(atPath: url.path))
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
    let url = tempURL()
    let store = FileJournalStore(url: url)
    try store.write(sample(prior: false))
    try store.write(sample(prior: true))
    #expect(try store.load()?.priorValue == true)
}
