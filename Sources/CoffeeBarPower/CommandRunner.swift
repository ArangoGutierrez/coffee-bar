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

public enum CommandError: Error, Equatable {
    /// The child did not finish — or left a descendant holding its pipes —
    /// within the caller's bound. Carries the bound that actually applied,
    /// which is not necessarily the one passed in (see `boundedTimeout`).
    ///
    /// Partial output is deliberately NOT returned as a success: a truncated
    /// `pmset -g` read as complete is how a caller concludes `SleepDisabled`
    /// is unset when it is in fact held.
    case timedOut(after: TimeInterval)

    /// A reader could not be given its own copy of a pipe's read end. Carries
    /// `errno` from the failed `dup(2)` — `EMFILE` (24) once this process has
    /// exhausted its descriptor table.
    ///
    /// Deliberately fatal to the call rather than a fallback to reading the
    /// shared descriptor. `run` closes the pipe's own descriptors on the way
    /// out, so a reader left holding one would be reading a descriptor this
    /// function had already closed — and a closed number is handed to the next
    /// `open`, at which point the parked read steals bytes from an unrelated
    /// file. Failing the call is the only outcome that stays correct, and a
    /// caller that is out of descriptors needs to hear about it rather than
    /// receive quietly corrupted output.
    case descriptorUnavailable(errno: Int32)
}

public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String],
             timeout: TimeInterval) throws -> CommandResult
}

public extension CommandRunning {
    /// Every command in this codebase is a short power-state query. 30 s is
    /// far beyond any of them on a loaded machine and far below "hung
    /// forever", which is the failure being bounded.
    static var defaultTimeout: TimeInterval { 30 }

    /// The two-argument form every existing call site uses. It lives in an
    /// extension because Swift does not permit a default argument on a
    /// protocol *requirement*.
    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        try run(executable, arguments, timeout: Self.defaultTimeout)
    }
}

/// The only place in the codebase that constructs a `Process`. Keeping this
/// a single seam is what lets tests inject a failing binary via PATH rather
/// than via environment tricks that only misbehave inside a sandbox.
public struct SystemCommandRunner: CommandRunning {
    private let searchPath: [String]?

    public init(searchPath: [String]? = nil) {
        self.searchPath = searchPath
    }

    public func run(_ executable: String, _ arguments: [String],
                    timeout: TimeInterval) throws -> CommandResult {
        let bound = Self.boundedTimeout(timeout)
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
        // Nothing else closes these four descriptors. `Pipe` does not close
        // them when it is deallocated, and `Process` takes ownership of only
        // the two WRITE ends — it invalidates those handles during spawn, so
        // closing them again here is a no-op. Nothing owns the READ ends but
        // this function, and nothing owns any of the four if the spawn below
        // throws. Measured before this `defer` existed: +2 descriptors per
        // successful call and +4 per failed spawn, linear and unbounded, with
        // the census over 40 successful runs sampled every 8 reading
        // [6, 22, 38, 54, 70, 86].
        //
        // That mattered beyond tidiness: M5's watchdog runs this in a loop for
        // days, and the first casualty of an exhausted table is the `dup`
        // below — the very thing keeping a parked reader off a shared
        // descriptor. Closing the originals here is safe against that parked
        // reader precisely because it holds a dup, not one of these.
        defer {
            try? out.fileHandleForReading.close()
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForReading.close()
            try? err.fileHandleForWriting.close()
        }
        try process.run()

        // Both pipes are drained concurrently. Reading stdout to EOF first and
        // stderr only afterwards deadlocks the moment a child fills the 64 KB
        // stderr pipe buffer: the child blocks writing stderr, so it never
        // closes stdout, so this process never returns from the stdout read.
        // The later probe spikes shell out to commands that are more than
        // capable of a megabyte of output, so this is not hypothetical.
        let sink = OutputSink()
        let group = DispatchGroup()
        // Each reader gets its own copy of the pipe's read end, and BOTH are
        // taken before either reader starts: a failure here then leaves
        // nothing already parked on a queue to reason about. `errno` is
        // captured per call because a later successful call is permitted to
        // overwrite it.
        let outFD = dup(out.fileHandleForReading.fileDescriptor)
        let outErrno = errno
        let errFD = dup(err.fileHandleForReading.fileDescriptor)
        let errErrno = errno
        guard outFD >= 0, errFD >= 0 else {
            if outFD >= 0 { close(outFD) }
            if errFD >= 0 { close(errFD) }
            if process.isRunning { process.terminate() }
            throw CommandError.descriptorUnavailable(
                errno: outFD < 0 ? outErrno : errErrno)
        }
        Self.drain(outFD, into: sink, isStdout: true, group: group)
        Self.drain(errFD, into: sink, isStdout: false, group: group)
        // Waiting on the drain BEFORE `waitUntilExit()` is the ordering the
        // comment above is about; the bound goes on the drain wait because
        // that is the one that can block indefinitely.
        //
        // What it bounds is subtler than a slow child: EOF arrives when the
        // last HOLDER of the write end closes it, and that need not be the
        // child. A child that exits immediately having backgrounded
        // `( sleep 20; … ) &` leaves the grandchild holding the pipes, and the
        // drain then waits on the grandchild — measured at 12.35 s for a child
        // that had already exited, with the grandchild's late bytes folded
        // into stdout as if the child had produced them.
        guard group.wait(timeout: .now() + bound) == .success else {
            // Terminate what can be terminated, then abandon the read rather
            // than block on it — waiting is precisely the hang being bounded,
            // and the grandchild will not be reached by this signal anyway.
            // The drain queues stay parked on their own dup'd descriptors
            // until whoever holds the write end lets go.
            if process.isRunning { process.terminate() }
            throw CommandError.timedOut(after: bound)
        }
        process.waitUntilExit()
        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: sink.stdout,
            stderr: sink.stderr)
    }

    /// Clamps a caller's timeout into something `DispatchTime` can represent.
    ///
    /// `DispatchTime.now() + Double.nan` yields a deadline that NEVER arrives:
    /// measured on macOS 26.5.2, a group with an outstanding `enter()` waited
    /// on that deadline was still blocked when the probe was killed at five
    /// minutes. Passing a degenerate interval through would therefore
    /// reintroduce, via the bound itself, the unbounded hang the bound exists
    /// to prevent.
    ///
    /// `min`/`max` propagate NaN — every comparison against NaN is false — so
    /// finiteness is tested AFTER clamping, matching `WatchdogPolicy`.
    static func boundedTimeout(_ timeout: TimeInterval) -> TimeInterval {
        let clamped = min(max(timeout, 0.001), 86_400)
        return clamped.isFinite ? clamped : defaultTimeout
    }

    /// Reads one descriptor to EOF on a background queue, then closes it. The
    /// descriptor is passed as an `Int32` rather than a `FileHandle` because
    /// the pipe's handle is not `Sendable` under the v6 language mode.
    ///
    /// Ownership is the point: the caller hands over a `dup` of the pipe's
    /// read end, never the pipe's own. On the timeout path `run` returns while
    /// this read is still blocked on a grandchild that inherited the pipe, and
    /// closes the pipe's descriptors as it goes. Closing a descriptor another
    /// thread is sitting in `read(2)` on does not unblock that thread, and the
    /// number can then be handed to the next `open` — at which point the
    /// parked read would steal bytes from an unrelated file.
    private static func drain(_ descriptor: Int32, into sink: OutputSink,
                              isStdout: Bool, group: DispatchGroup) {
        DispatchQueue.global().async(group: group) {
            let handle = FileHandle(fileDescriptor: descriptor,
                                    closeOnDealloc: false)
            sink.append(handle.readDataToEndOfFile(), isStdout: isStdout)
            close(descriptor)
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
