// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoffeeBarCore

public enum JournalError: Error, Equatable {
    case writeFailed(String)
    case syncFailed(Int32)
    case corrupt(String)
}

public protocol JournalStoring: Sendable {
    func load() throws -> JournalRecord?
    func write(_ record: JournalRecord) throws
    func clear() throws
    /// Move an unreadable journal aside and return where it went.
    ///
    /// A journal that will not decode still proves something WAS armed — we
    /// just cannot tell what. Deleting it destroys the only evidence of why
    /// a machine stopped sleeping, so it is renamed rather than removed and
    /// left for a human to find.
    @discardableResult
    func quarantine() throws -> URL?
}

public struct FileJournalStore: JournalStoring {
    public static let systemURL = URL(
        fileURLWithPath:
            "/Library/Application Support/coffee-bar/state/probe-journal.json")

    private let url: URL

    // Owner-only, per SECURITY.md: 0700 for the directory and 0600 for the
    // journal. Neither is left to whichever process created the path first,
    // which without these is the umask — 0755 and 0644 on a stock account.
    //
    // Two reasons the journal is not world-readable. It carries the arming
    // provenance (pid, uid, binary path of whatever disabled sleep), which is
    // forensic detail no other user needs. And under M5 a root helper reads
    // this file as an instruction, so it must refuse anything group- or
    // other-writable; a mode nobody pins is a mode it cannot trust.
    private static let directoryMode = 0o700
    private static let fileMode = 0o600

    public init(url: URL = FileJournalStore.systemURL) {
        self.url = url
    }

    // ISO-8601 on BOTH sides, pinned here rather than left to the default.
    //
    // The reason is legibility under failure. A dirty journal is read by a
    // human during an incident — the machine did not sleep and they need to
    // know when it was armed and by what. `"setAt":"2026-07-27T14:03:07Z"`
    // answers that; `"setAt":806849904.1234568` does not.
    //
    // NOT a precision fix, despite an earlier claim in this plan that it was.
    // That claim was disproven by measurement: `Date` IS a `Double` and
    // JSONEncoder emits the shortest-round-trippable form, so
    // `.deferredToDate` is lossless. ISO-8601 is in fact LOSSIER — second
    // granularity — which is exactly why `ArmCommand` stamps `setAt` via
    // `HostInfo.now()` rather than `Date()`. The truncation is a required
    // consequence of this choice, not an independent safety measure.
    //
    // `CoffeeBarCore` stays strategy-agnostic; pinning belongs at this
    // boundary, which is the only place journals become bytes.
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

    public func load() throws -> JournalRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            return try Self.makeDecoder().decode(JournalRecord.self, from: data)
        } catch {
            // Deliberately NOT nil: a corrupt journal must not be mistaken
            // for "nothing was armed". Callers revert on this error.
            throw JournalError.corrupt(String(describing: error))
        }
    }

    /// Writes to a sibling temp file, forces it to stable storage with
    /// `F_FULLFSYNC`, atomically renames, then barriers the parent directory
    /// so the new *name* is durable and not just the bytes behind it. Plain
    /// `fsync(2)` on macOS only pushes to the drive cache and can be lost on
    /// power failure — `F_FULLFSYNC` is the documented durable barrier.
    public func write(_ record: JournalRecord) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: Self.directoryMode])

        let data = try Self.makeEncoder().encode(record)
        let tmp = dir.appendingPathComponent(".probe-journal.\(UUID().uuidString).tmp")

        guard FileManager.default.createFile(
            atPath: tmp.path, contents: nil,
            attributes: [.posixPermissions: Self.fileMode]) else {
            throw JournalError.writeFailed("could not create \(tmp.path)")
        }
        let handle = try FileHandle(forWritingTo: tmp)
        do {
            try handle.write(contentsOf: data)
            if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 {
                throw JournalError.syncFailed(errno)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }

        // `.usingNewMetadataOnly` is load-bearing, not tidiness. By default a
        // replace carries the DESTINATION's metadata onto the result, so a
        // journal an earlier build left 0644 keeps that mode through every
        // later save and upgrading never repairs it. Measured on macOS 26.5.2
        // (25F84): without this option a 0644 destination reads 0644 after the
        // replace, with it 0600.
        //
        // Chmod'ing after the rename would leave the journal world-readable for
        // the window in between — and a crash inside that window would leave it
        // 0644 permanently, which is worse than the window. The option carries
        // the temp file's mode across the rename itself, so there is no window.
        //
        // It also discards the destination's extended attributes, verified with
        // a marker xattr that does not survive the replace. That is acceptable
        // here and is part of the point: this app owns the journal completely,
        // and an xattr on it came from somewhere else.
        _ = try FileManager.default.replaceItemAt(
            url, withItemAt: tmp, options: .usingNewMetadataOnly)

        // The rename above is a directory metadata change. Syncing the file's
        // contents does not make its NAME durable — after a power failure the
        // entry can be absent while the system mutation it describes has
        // already landed. Sync the parent directory too, so the journal exists
        // before anything acts on it.
        //
        // Best-effort on purpose: a barrier we cannot take must not turn a
        // successful write into a failed arm. The bytes are already on media,
        // so failing here would refuse to arm over a guarantee that is weaker
        // than what the caller already has, not stronger.
        let dirFD = open(dir.path, O_RDONLY)
        if dirFD >= 0 {
            _ = fcntl(dirFD, F_FULLFSYNC)
            close(dirFD)
        }
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Renames rather than deletes. `pid` disambiguates repeated failures so
    /// a crash loop leaves a trail instead of overwriting one file.
    @discardableResult
    public func quarantine() throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let dest = url.deletingLastPathComponent()
            .appendingPathComponent("probe-journal.corrupt.\(getpid()).json")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }
}
