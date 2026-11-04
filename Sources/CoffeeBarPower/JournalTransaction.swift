// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin

@_silgen_name("flock")
private func journalFlock(_ fd: Int32, _ operation: Int32) -> Int32

enum JournalTransactionError: Error {
    case busy
    case unsafeLock
    case system(Int32)
}

extension GuardedJournalReader {
    /// A stable inode serializes all journal and power changes across processes.
    func withTransaction<T>(_ body: () throws -> T) throws -> T {
        try validateTransactionPath()
        let directory = transactionDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try validateTransactionPath()
        let path = directory.appendingPathComponent(".journal.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw JournalTransactionError.system(errno) }
        defer { close(fd) }
        func validateInode() throws {
            var opened = stat()
            var named = stat()
            guard fstat(fd, &opened) == 0, lstat(path, &named) == 0,
                  (opened.st_mode & S_IFMT) == S_IFREG,
                  opened.st_nlink == 1, named.st_nlink == 1,
                  opened.st_uid == transactionOwner, (opened.st_mode & 0o7777) == 0o600,
                  opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
                throw JournalTransactionError.unsafeLock
            }
        }
        try validateInode()
        guard journalFlock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { throw JournalTransactionError.busy }
            throw JournalTransactionError.system(errno)
        }
        defer { _ = journalFlock(fd, LOCK_UN) }
        try validateTransactionPath()
        try validateInode()
        return try body()
    }
}
