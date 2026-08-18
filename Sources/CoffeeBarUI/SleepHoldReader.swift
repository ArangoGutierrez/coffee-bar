// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoffeeBarPower

/// Whether this machine's sleep is currently disabled, as `ServingModel` needs
/// to know it before it removes the helper (issue #71).
///
/// **A READ and nothing else, which is the reason this protocol exists at all
/// rather than the model holding `SleepDisabledControlling` directly.** That
/// protocol pairs `isEnabled()` with `set(_:)`, and `set` is a write to a
/// system power setting: the root helper's job, decided by `LidClosedSession`
/// against a journal, a TTL and a battery floor. An app-layer object holding
/// the writer would be holding a second route to the flag with none of those
/// checks in front of it. The same argument `RegisteredHelperReporting` makes
/// one file over: a protocol that carries ONE answer across a boundary rather
/// than moving the capability with it.
///
/// The answer needs no privilege. `pmset -g` prints `SleepDisabled` to any
/// user; only writing it needs root.
public protocol SleepHoldReporting: Sendable {
    /// `true` while the machine's `SleepDisabled` setting is set.
    ///
    /// THROWS rather than answering `false` for a reading it could not make.
    /// The caller is about to decide whether it is safe to remove the daemon
    /// that puts this setting back, and "I could not find out" is not evidence
    /// the machine is free. `PmsetSleepDisabledController.isEnabled()` refuses
    /// the same collapse one layer down, for the same reason.
    ///
    /// **ASYNC because the only real answer comes from a subprocess.** The sole
    /// caller is `ServingModel.removeRegisteredHelper()`, and `ServingModel` is
    /// `@MainActor`: a synchronous requirement here forces the fork-and-wait
    /// onto the thread that draws the window, for as long as
    /// `CommandRunning.defaultTimeout` allows. Stating it on the PROTOCOL rather
    /// than offloading at the call site puts the obligation where the next
    /// conformer and the next caller both have to meet it, and the `await` the
    /// compiler then demands is what keeps the removal's order intact: the
    /// unregister cannot begin until this has answered.
    /// `theSleepFlagIsReadOffTheMainActorRatherThanBlockingIt` measures it on
    /// the shipped reader.
    func sleepIsDisabled() async throws -> Bool
}

/// Reads the flag by asking `pmset`, through the power layer's controller.
///
/// **A thin adapter and deliberately nothing more.** The parsing, the refusal
/// on a value that cannot be interpreted, and the "key absent means unset" rule
/// all live in `PmsetSleepDisabledController`, which the CLI and the root helper
/// already share. A second reader here would be a second answer to "is this
/// machine held", and the two would disagree the first time `pmset`'s output
/// changed shape.
///
/// **It stores the RUNNER, not the controller.** The controller is built per
/// read, so this type holds no object that can write a power setting even by
/// accident, and the file that names the writing type is this one alone.
///
/// Machine-dependent by construction, exactly like
/// `PrivilegedHelperReader.defaultBundledProbe`. Every check supplies a double
/// for `SleepHoldReporting` instead.
public struct PmsetSleepHoldReader: SleepHoldReporting {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = SystemCommandRunner()) {
        self.runner = runner
    }

    /// **A THREAD OF ITS OWN, and not `Task.detached`.** `CommandRunning.run`
    /// blocks its caller until the child has exited and both drain threads have
    /// read to EOF, bounded at 30 seconds. Swift's cooperative pool is sized
    /// from the core count, so parking one of its threads on a subprocess is
    /// the hazard `SystemCommandRunner.drain` already documents against
    /// `DispatchQueue.global()` — measured there as a 3-core runner frozen for
    /// 30 s by six process-spawning callers. `Thread.detachNewThread` blocks
    /// nothing that anything else needs, and this runs once per click on a
    /// button, not on a timer.
    ///
    /// The continuation is resumed exactly once, on whichever way out the read
    /// takes: `Result` captures the throw rather than letting it escape a
    /// closure that has no other route back.
    public func sleepIsDisabled() async throws -> Bool {
        let runner = self.runner
        return try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(with: Result {
                    try PmsetSleepDisabledController(runner: runner).isEnabled()
                })
            }
        }
    }
}
