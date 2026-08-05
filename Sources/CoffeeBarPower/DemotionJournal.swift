// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin

public enum DemotionJournalError: Error, Equatable {
    case writeFailed(String)
    case syncFailed(Int32)
    case corrupt(String)
}

/// One process this app put into darwin background state.
///
/// Written and `F_FULLFSYNC`'d BEFORE the `setpriority` call it describes. A
/// journal written afterwards is defeated by a `SIGKILL` in the window between
/// the two calls: the process is demoted and nothing on disk says so, so no
/// later run can undo it. `JournalRecord` states the same ordering rule for the
/// sleep watchdog.
public struct DemotionEntry: Codable, Equatable, Sendable {

    /// Which process this was — pid AND start time. A pid alone is not an
    /// identity, because macOS reuses pids.
    public let identity: ProcIdentity
    /// Advisory forensics, so a human reading a stale journal can tell what was
    /// held down. Never used to decide a restore.
    public let name: String
    /// The flags word MEASURED before the demotion.
    ///
    /// The restore target is measured, never assumed — `JournalRecord.priorValue`
    /// takes the same line for the sleep setting.
    public let priorFlags: UInt32
    public let demotedAt: Date

    /// Whether the external background bit was this app's doing.
    ///
    /// **Invariant 2 lives here.** If a process already carried
    /// `EXT_DARWINBG` before coffee-bar touched it, some other tool put it
    /// there, and clearing it on recovery would PROMOTE a process the user never
    /// asked to promote. Handoff §5.6 warns about exactly that with
    /// `taskpolicy -B`.
    ///
    /// The SELF channel is not consulted, and that is measured rather than
    /// assumed: on macOS 26.5.2 (25F84) an external
    /// `setpriority(PRIO_DARWIN_PROCESS, pid, 0)` leaves another process's
    /// self-applied `DARWINBG` bit untouched. A process that backgrounded itself
    /// therefore cannot be promoted by this app's restore.
    public var appliedByThisApp: Bool {
        priorFlags & ProcSnapshot.externalDarwinBackground == 0
    }

    public init(identity: ProcIdentity, name: String, priorFlags: UInt32, demotedAt: Date) {
        self.identity = identity
        self.name = name
        self.priorFlags = priorFlags
        self.demotedAt = demotedAt
    }
}

public struct DemotionJournalRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let entries: [DemotionEntry]

    public init(schemaVersion: Int = DemotionJournalRecord.currentSchemaVersion,
                entries: [DemotionEntry]) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }
}

/// Where the demotion record is kept between runs.
///
/// The same shape as `JournalStoring`, deliberately not the same protocol and
/// never the same file. See `FileDemotionJournalStore.userURL`.
public protocol DemotionJournalStoring: Sendable {
    /// The record, or `nil` when no run has demoted anything.
    ///
    /// Throws on a journal that will not decode. `nil` and a throw must never be
    /// confused: "nothing was demoted" and "something was demoted and we cannot
    /// read what" call for opposite responses.
    func load() throws -> DemotionJournalRecord?
    /// Adds one entry and forces it to stable storage before returning.
    func append(_ entry: DemotionEntry) throws
    /// Replaces the whole record with `entries`, in ONE durable step.
    ///
    /// Never a `clear` followed by appends. A crash between the two loses every
    /// entry, which is the state this journal exists to prevent, and the caller
    /// that needs this method is the recovery path — the one place where losing
    /// an entry strands a process nothing else names.
    func replace(with entries: [DemotionEntry]) throws
    func clear() throws
}

/// The real store, over a file in the user's own container.
///
/// **A second file, for a security reason rather than a tidiness one.** The
/// sleep journal at `FileJournalStore.systemURL` is root-owned and, under M5, a
/// ROOT process reads it and acts on it; `SECURITY.md` calls it "an instruction
/// to a root process" and binds four preconditions to it. Process demotion is
/// unprivileged and same-uid, so this journal is written by the user's own app
/// and is user-owned. Putting user-writable data into the file a root process
/// obeys would build exactly the instruction channel those preconditions exist
/// to close.
///
/// The two therefore live in different trees — `~/Library/…` against
/// `/Library/…` — and not merely under different names, because precondition 1
/// checks every component of the path.
/// `theDemotionJournalIsNowhereNearTheFileARootProcessReads` holds them apart.
///
/// The 0700/0600 discipline and the durable-write sequence are the same as
/// `FileJournalStore`'s, and repeated here rather than shared: the two files
/// have different owners and different readers, and a shared implementation is
/// one edit away from becoming a shared path.
public struct FileDemotionJournalStore: DemotionJournalStoring {

    /// `~/Library/Application Support/coffee-bar/state/demotion-journal.json`.
    ///
    /// Under the user's home, because this file records unprivileged, same-uid
    /// work. Never under `/Library`, where the root helper reads.
    public static let userURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/coffee-bar/state")
        .appendingPathComponent("demotion-journal.json")

    private let url: URL

    // Owner-only, per SECURITY.md. Not left to the process umask, which on a
    // stock account is 0755 and 0644: this file names every process coffee-bar
    // demoted, and a world-writable one would let any local user choose which
    // pids a later run promotes.
    private static let directoryMode = 0o700
    private static let fileMode = 0o600

    public init(url: URL = FileDemotionJournalStore.userURL) {
        self.url = url
    }

    // ISO-8601 on both sides, for the reason `FileJournalStore` pins it: a stale
    // journal is read by a human during an incident, and
    // `"demotedAt":"2026-08-05T09:12:44Z"` answers "when" where a float does not.
    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func load() throws -> DemotionJournalRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            return try Self.makeDecoder().decode(DemotionJournalRecord.self, from: data)
        } catch {
            // Deliberately NOT nil. A journal that will not decode still proves
            // a run demoted something; reporting it as "nothing was demoted"
            // strands those processes with no error and no evidence.
            throw DemotionJournalError.corrupt(String(describing: error))
        }
    }

    /// `try load()` and never `try? load()`.
    ///
    /// A `try?` here confuses exactly the two answers `load()` exists to keep
    /// apart. A record that will not decode reads as "nothing was demoted", and
    /// the write that follows REPLACES it: every process the unreadable record
    /// named is stranded silently, and the error that would have said so is
    /// gone with it. Refusing costs one demotion that does not happen.
    /// `appendRefusesToWriteOverAJournalItCouldNotDecode` pins it.
    ///
    /// The same refusal now covers a record this process may not read.
    /// `replaceItemAt` already failed there with `EACCES`, so the behaviour a
    /// caller sees does not change — but it was a property of the filesystem
    /// rather than a decision this type made, and
    /// `appendRefusesOverAJournalItIsNotAllowedToRead` holds it either way.
    public func append(_ entry: DemotionEntry) throws {
        let existing = try load()?.entries ?? []
        try write(DemotionJournalRecord(entries: existing + [entry]))
    }

    /// An empty list removes the file rather than writing an empty record, so
    /// "nothing is demoted" has ONE representation on disk. Two of them — no
    /// file, and a file holding no entries — would be two things every reader
    /// has to handle and one thing a later author forgets.
    public func replace(with entries: [DemotionEntry]) throws {
        guard !entries.isEmpty else { return try clear() }
        try write(DemotionJournalRecord(entries: entries))
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Writes to a sibling temp file, forces it to stable storage with
    /// `F_FULLFSYNC`, atomically renames, then barriers the parent directory so
    /// the new NAME is durable and not only the bytes behind it.
    ///
    /// Plain `fsync(2)` on macOS pushes to the drive cache and can be lost on
    /// power failure. This runs before every demotion, so the cost is one
    /// barrier per process demoted, and the alternative is a journal that does
    /// not survive the failure it exists for.
    private func write(_ record: DemotionJournalRecord) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: Self.directoryMode])

        let data = try Self.makeEncoder().encode(record)
        let tmp = dir.appendingPathComponent(".demotion-journal.\(UUID().uuidString).tmp")

        guard FileManager.default.createFile(
            atPath: tmp.path, contents: nil,
            attributes: [.posixPermissions: Self.fileMode]) else {
            throw DemotionJournalError.writeFailed("could not create \(tmp.path)")
        }
        let handle = try FileHandle(forWritingTo: tmp)
        do {
            try handle.write(contentsOf: data)
            if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 {
                throw DemotionJournalError.syncFailed(errno)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }

        // `.usingNewMetadataOnly` carries the temp file's mode across the rename
        // rather than the destination's, so a journal an earlier build left 0644
        // is repaired by the next write instead of keeping that mode for ever.
        // Chmod'ing after the rename would leave a window in which the file is
        // world-readable, and a crash inside that window would make it permanent.
        _ = try FileManager.default.replaceItemAt(
            url, withItemAt: tmp, options: .usingNewMetadataOnly)

        // The rename is a directory metadata change: syncing the file's contents
        // does not make its NAME durable. Best-effort, because a barrier we
        // cannot take must not turn a written journal into a refused demotion —
        // the bytes are already on media.
        let dirFD = open(dir.path, O_RDONLY)
        if dirFD >= 0 {
            _ = fcntl(dirFD, F_FULLFSYNC)
            close(dirFD)
        }
    }
}
