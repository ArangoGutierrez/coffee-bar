// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoffeeBarCore

/// Why a journal was refused.
///
/// Every case means the same thing to the caller: the file on disk cannot be
/// trusted to say what to restore. The distinctions are for the human reading
/// the log afterwards.
public enum JournalRefusal: Error, Equatable {
    case pathNotAbsolute(String)
    case unreadablePath(path: String, errno: Int32)
    case insecurePath(path: String, components: [InsecurePathComponent])
    /// Ownership or mode of the journal file itself did not match.
    case wrongOwnerOrMode(path: String, uid: uid_t, mode: mode_t)
    case corrupt(String)
}

/// Reads the journal the way a root process has to read it.
///
/// SECURITY.md items 1 and 2. The journal is an instruction to a root process,
/// so before a single byte is decoded, every component of its path must be
/// owned by root and neither group- nor other-writable, and the file itself
/// must carry exactly the mode the privileged writer gives it.
///
/// Item 1 lives HERE, on the reader, rather than on the writer, and
/// SECURITY.md:184-190 records why: `FileJournalStore` pins 0700/0600 on the
/// paths it CREATES but cannot repair a directory that already exists, because
/// an unprivileged process that chmods a path another user may control is not a
/// fix. The privileged reader is the only party that can refuse.
///
/// A refusal QUARANTINES rather than deletes. A journal that will not pass
/// still proves something WAS armed, and it is the only evidence of why a
/// machine stopped sleeping.
public struct GuardedJournalReader: Sendable {
    /// The mode the privileged writer gives the journal, per SECURITY.md item
    /// 3. Checked exactly rather than as "not group-writable": 0640 is not
    /// writable by anyone else and still leaks the `armedBy` provenance — pid,
    /// uid and binary path — to every account on the machine.
    static let requiredFileMode: mode_t = 0o600

    private let url: URL
    private let store: any JournalStoring
    private let requiredOwner: uid_t

    /// `requiredOwner` defaults to 0, which is the production bar. It widens
    /// only so tests can drive a scratch path; see `PathSecurity`
    /// `.insecureComponents`.
    public init(url: URL = FileJournalStore.systemURL,
                store: (any JournalStoring)? = nil,
                requiredOwner: uid_t = 0) {
        self.url = url
        self.store = store ?? FileJournalStore(url: url)
        self.requiredOwner = requiredOwner
    }

    /// The journal, or nil when nothing is armed.
    ///
    /// Throws `JournalRefusal` when the path or the file fails the bar, having
    /// quarantined whatever was there. "Nothing armed" is the ordinary state
    /// and is never a refusal — a reader that threw for it would make every
    /// unarmed boot an incident.
    public func read() throws -> JournalRecord? {
        let directory = url.deletingLastPathComponent()

        // Nothing has ever been armed on this machine. There is no path to
        // judge and nothing to quarantine.
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }

        // Item 1: the whole ancestry, BEFORE anything reads the file. The
        // directory is judged even when the journal is absent, because a
        // group-writable state directory is where the next journal would land.
        try refuseInsecurePath(directory.path)

        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        // Item 2: the journal's own ownership and mode. `lstat`, so a symlink
        // dropped in its place is judged as the symlink it is rather than
        // followed to whatever it points at.
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            let failure = JournalRefusal.unreadablePath(path: url.path, errno: errno)
            try? store.quarantine()
            throw failure
        }
        let mode = info.st_mode & 0o7777
        let ownerWrong = info.st_uid != 0 && info.st_uid != requiredOwner
        guard !ownerWrong, mode == Self.requiredFileMode else {
            try? store.quarantine()
            throw JournalRefusal.wrongOwnerOrMode(
                path: url.path, uid: info.st_uid, mode: mode)
        }

        do {
            return try store.load()
        } catch {
            // A corrupt journal is quarantined for the same reason an insecure
            // one is: it proves something was armed and cannot say what.
            try? store.quarantine()
            throw JournalRefusal.corrupt(String(describing: error))
        }
    }

    /// Removes the journal after a successful revert.
    public func clear() throws {
        try store.clear()
    }

    private func refuseInsecurePath(_ path: String) throws {
        do {
            _ = try PathSecurity.validate(path, requiredOwner: requiredOwner)
        } catch let error as PathSecurityError {
            try? store.quarantine()
            switch error {
            case .notAbsolute(let path):
                throw JournalRefusal.pathNotAbsolute(path)
            case .unresolvable(let path, let code):
                throw JournalRefusal.unreadablePath(path: path, errno: code)
            case .insecure(let path, let components):
                throw JournalRefusal.insecurePath(path: path, components: components)
            }
        }
    }
}
