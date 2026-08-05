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
    /// Ownership or mode of the journal file or its directory did not match.
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

    /// The mode the privileged writer gives the journal's own directory.
    ///
    /// Exactly 0700, which closes the gap SECURITY.md:184-190 names: the store
    /// pins the mode of a directory it CREATES and cannot repair one that
    /// already exists, so a directory an earlier build left 0755 keeps that
    /// mode and the reader must refuse it.
    ///
    /// The document contradicted itself here. Item 1 (SECURITY.md:165-167) asks
    /// only that a component be root-owned and not group- or other-writable,
    /// which 0755 satisfies; :187-190 says the helper must refuse exactly that.
    /// Carlos settled it toward safety. Nothing `FileJournalStore` creates can
    /// fail this, because it creates 0700.
    ///
    /// It binds the journal's OWN directory and no ancestor. Measured on this
    /// platform, `/`, `/Library` and `/Library/Application Support` are all
    /// root-owned 0755, so an ancestor-wide rule would refuse every journal in
    /// production. Ancestors keep the weaker rule, which is also the rule the
    /// shared `PathSecurity` applies to the program path, where `/usr/bin` is
    /// 0755 too.
    static let requiredDirectoryMode: mode_t = 0o700

    private let url: URL
    private let store: any JournalStoring
    private let requiredOwner: uid_t
    private let quarantineOnRefusal: Bool

    /// `requiredOwner` defaults to 0, which is the production bar. It widens
    /// only so tests can drive a scratch path; see `PathSecurity`
    /// `.insecureComponents`.
    ///
    /// `quarantineOnRefusal` is true for the watchdog and false for `report`.
    /// Quarantining is a WRITE, and it belongs to the party that also RESTORES
    /// the setting. A `report` that moved a refused journal aside would leave
    /// the daemon's next tick reading nothing, answering `.hold`, and holding
    /// `SleepDisabled` with no record of why — an open-ended hold reached by a
    /// user merely asking what was armed.
    public init(url: URL = FileJournalStore.systemURL,
                store: (any JournalStoring)? = nil,
                requiredOwner: uid_t = 0,
                quarantineOnRefusal: Bool = true) {
        self.url = url
        self.store = store ?? FileJournalStore(url: url)
        self.requiredOwner = requiredOwner
        self.quarantineOnRefusal = quarantineOnRefusal
    }

    /// Moves a refused journal aside, unless this reader only inspects.
    private func quarantineIfPermitted() {
        guard quarantineOnRefusal else { return }
        try? store.quarantine()
    }

    /// The path preconditions alone: nothing is read, nothing is moved.
    ///
    /// `ArmService` calls this BEFORE it writes, so a path this reader would
    /// refuse never gets armed in the first place.
    ///
    /// That partner check is not belt-and-braces. Refusing safely on the READ
    /// side restores the setting, clears and uninstalls — and an `arm` that
    /// then carried on setting the flag turned "refuse safely" into "hold
    /// forever", which is the opposite of what SECURITY.md:187-190 asks for.
    /// The measured end state was `sleepDisabled=true journalLoads=false
    /// daemonLoaded=false`, from a successful `arm`.
    public func validatePath() throws {
        let directory = url.deletingLastPathComponent()

        if FileManager.default.fileExists(atPath: directory.path) {
            if let refusal = pathRefusal(directory.path) { throw refusal }
            if let refusal = directoryModeRefusal(directory) { throw refusal }
            return
        }

        // Nothing has been armed on this machine yet. `FileJournalStore` will
        // create the missing levels at 0700, so the only question left is
        // whether the nearest EXISTING ancestor is sound.
        var ancestor = directory.deletingLastPathComponent()
        while ancestor.path != "/",
              !FileManager.default.fileExists(atPath: ancestor.path) {
            ancestor = ancestor.deletingLastPathComponent()
        }
        if let refusal = pathRefusal(ancestor.path) { throw refusal }
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
        if let refusal = pathRefusal(directory.path) {
            quarantineIfPermitted()
            throw refusal
        }

        // And the journal's own directory to the exact mode, which the
        // ancestry rule alone does not reach. See `requiredDirectoryMode`.
        if let refusal = directoryModeRefusal(directory) {
            quarantineIfPermitted()
            throw refusal
        }

        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        // Item 2: the journal's own ownership and mode. `lstat`, so a symlink
        // dropped in its place is judged as the symlink it is rather than
        // followed to whatever it points at.
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            let failure = JournalRefusal.unreadablePath(path: url.path, errno: errno)
            quarantineIfPermitted()
            throw failure
        }
        let mode = info.st_mode & 0o7777
        let ownerWrong = info.st_uid != 0 && info.st_uid != requiredOwner
        guard !ownerWrong, mode == Self.requiredFileMode else {
            quarantineIfPermitted()
            throw JournalRefusal.wrongOwnerOrMode(
                path: url.path, uid: info.st_uid, mode: mode)
        }

        do {
            return try store.load()
        } catch {
            // A corrupt journal is quarantined for the same reason an insecure
            // one is: it proves something was armed and cannot say what.
            quarantineIfPermitted()
            throw JournalRefusal.corrupt(String(describing: error))
        }
    }

    /// Removes the journal after a successful revert.
    public func clear() throws {
        try store.clear()
    }

    /// Item 1, as a value rather than a throw, so both `read()` and
    /// `validatePath()` apply one rule and only `read()` quarantines.
    private func pathRefusal(_ path: String) -> JournalRefusal? {
        do {
            _ = try PathSecurity.validate(path, requiredOwner: requiredOwner)
            return nil
        } catch let error as PathSecurityError {
            switch error {
            case .notAbsolute(let path):
                return .pathNotAbsolute(path)
            case .unresolvable(let path, let code):
                return .unreadablePath(path: path, errno: code)
            case .insecure(let path, let components):
                return .insecurePath(path: path, components: components)
            }
        } catch {
            return .corrupt(String(describing: error))
        }
    }

    /// The exact-0700 rule on the journal's own directory.
    private func directoryModeRefusal(_ directory: URL) -> JournalRefusal? {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            return .unreadablePath(path: directory.path, errno: errno)
        }
        let mode = info.st_mode & 0o7777
        guard mode == Self.requiredDirectoryMode else {
            return .wrongOwnerOrMode(path: directory.path, uid: info.st_uid,
                                     mode: mode)
        }
        return nil
    }
}
