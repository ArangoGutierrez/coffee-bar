// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult
}

/// The only place in the codebase that constructs a `Process`. Keeping this
/// a single seam is what lets tests inject a failing binary via PATH rather
/// than via environment tricks that only misbehave inside a sandbox.
public struct SystemCommandRunner: CommandRunning {
    private let searchPath: [String]?

    public init(searchPath: [String]? = nil) {
        self.searchPath = searchPath
    }

    public func run(_ executable: String,
                    _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let searchPath {
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = searchPath.joined(separator: ":")
            process.environment = env
        }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()

        // Both pipes are drained concurrently. Reading stdout to EOF first and
        // stderr only afterwards deadlocks the moment a child fills the 64 KB
        // stderr pipe buffer: the child blocks writing stderr, so it never
        // closes stdout, so this process never returns from the stdout read.
        // The later probe spikes shell out to commands that are more than
        // capable of a megabyte of output, so this is not hypothetical.
        let sink = OutputSink()
        let group = DispatchGroup()
        Self.drain(out.fileHandleForReading.fileDescriptor,
                   into: sink, isStdout: true, group: group)
        Self.drain(err.fileHandleForReading.fileDescriptor,
                   into: sink, isStdout: false, group: group)
        group.wait()
        process.waitUntilExit()
        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: sink.stdout,
            stderr: sink.stderr)
    }

    /// Reads one descriptor to EOF on a background queue. The descriptor is
    /// passed as an `Int32` rather than a `FileHandle` because the pipe's
    /// handle is not `Sendable` under the v6 language mode.
    private static func drain(_ descriptor: Int32, into sink: OutputSink,
                              isStdout: Bool, group: DispatchGroup) {
        DispatchQueue.global().async(group: group) {
            let handle = FileHandle(fileDescriptor: descriptor,
                                    closeOnDealloc: false)
            sink.append(handle.readDataToEndOfFile(), isStdout: isStdout)
        }
    }
}

/// Accumulates the two output streams written from the reader queues.
/// `@unchecked Sendable` because the buffers are mutable state guarded by the
/// lock, matching how `AssertionHolder` handles its own mutable state.
private final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var outBuffer = Data()
    private var errBuffer = Data()

    func append(_ data: Data, isStdout: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isStdout { outBuffer.append(data) } else { errBuffer.append(data) }
    }

    var stdout: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: outBuffer, as: UTF8.self)
    }

    var stderr: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: errBuffer, as: UTF8.self)
    }
}
