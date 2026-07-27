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
    /// `F_FULLFSYNC`, then atomically renames. Plain `fsync(2)` on macOS
    /// only pushes to the drive cache and can be lost on power failure —
    /// `F_FULLFSYNC` is the documented durable barrier.
    public func write(_ record: JournalRecord) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)

        let data = try Self.makeEncoder().encode(record)
        let tmp = dir.appendingPathComponent(".probe-journal.\(UUID().uuidString).tmp")

        guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else {
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

        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
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
