// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Testing
@testable import CoffeeBarIngest

@_silgen_name("flock")
private func ownershipTestFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

@Test func listenerLockBlocksStartAndIsReleasedAfterCancellation() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "cb-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "i.sock").path
    let fd = Darwin.open(path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, mode_t(0o600))
    try #require(fd >= 0)
    defer { Darwin.close(fd) }
    try #require(ownershipTestFlock(fd, LOCK_EX | LOCK_NB) == 0)

    let listener = UnixSocketIngestListener(socketPath: path)
    defer { listener.stop() }
    // There is no socket to probe: refusal must come from the held file lock.
    #expect(throws: IngestError.alreadyServing(path)) { try listener.start { _, _ in } }
    #expect(!FileManager.default.fileExists(atPath: path))
    try #require(ownershipTestFlock(fd, LOCK_UN) == 0)

    try listener.start { _, _ in }
    try requireReady(listener)
    #expect(ownershipTestFlock(fd, LOCK_EX | LOCK_NB) == -1 && errno == EWOULDBLOCK)
    listener.stop()
    var acquired = false
    pump(until: {
        acquired = ownershipTestFlock(fd, LOCK_EX | LOCK_NB) == 0
        return acquired
    })
    try #require(acquired, "cancellation did not release the lock")
    try #require(ownershipTestFlock(fd, LOCK_UN) == 0)

    try listener.start { _, _ in }
    try requireReady(listener)
    #expect(ownershipTestFlock(fd, LOCK_EX | LOCK_NB) == -1 && errno == EWOULDBLOCK)
}

@Test func saturatedLegacySocketIsNotReclaimed() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "cb-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "i.sock").path
    let server = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(server >= 0)
    defer { Darwin.close(server) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(server, $0, length) } }
    try #require(bound == 0 && Darwin.listen(server, 1) == 0)
    let client = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(client >= 0)
    defer { Darwin.close(client) }
    let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, length) } }
    try #require(connected == 0)
    var before = stat()
    try #require(lstat(path, &before) == 0)
    let candidate = UnixSocketIngestListener(socketPath: path)
    defer { candidate.stop() }
    #expect(throws: IngestError.alreadyServing(path)) { try candidate.start { _, _ in } }
    var after = stat()
    #expect(lstat(path, &after) == 0 && before.st_ino == after.st_ino && before.st_dev == after.st_dev)

    // A link to the same saturated legacy socket is also an ambiguous owner.
    let link = directory.appending(path: "link.sock").path
    try #require(symlink(path, link) == 0)
    let throughLink = UnixSocketIngestListener(socketPath: link)
    defer { throughLink.stop() }
    #expect(throws: IngestError.alreadyServing(link)) { try throughLink.start { _, _ in } }
    var linkStatus = stat()
    #expect(lstat(link, &linkStatus) == 0 && linkStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK))
}
