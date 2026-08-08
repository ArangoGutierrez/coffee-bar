// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarPower

private func monotonicClockSource() throws -> String {
    let url = URL(fileURLWithPath: #filePath)   // …/Tests/CoffeeBarPowerTests/…
        .deletingLastPathComponent()            // …/Tests/CoffeeBarPowerTests
        .deletingLastPathComponent()            // …/Tests
        .deletingLastPathComponent()            // the package root
        .appending(path: "Sources/CoffeeBarPower/MonotonicClock.swift")
    return try String(contentsOf: url, encoding: .utf8)
}

/// The source with its comment lines removed.
///
/// Load-bearing: the file's own doc comment names `mach_absolute_time()` in
/// order to say it is the wrong call, so a check run over the raw text would
/// find the forbidden token in the very sentence forbidding it.
private func codeLines(of source: String) -> String {
    source.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}

@Test func theMonotonicClockKeepsCountingWhileTheMachineSleeps() throws {
    // The property this whole type exists for, and the one no test on a running
    // machine can observe directly: `mach_absolute_time()` STOPS while the
    // system naps, and `mach_continuous_time()` does not.
    //
    // A lid-closed hold is exactly the case where a Mac naps. The stopping
    // clock would under-count the hold by every second slept and hand those
    // seconds straight back to it — issue #77 again, in a disguise a CI runner
    // that never sleeps would never expose. The two calls differ by one word
    // and have the same type, so the substitution is a plausible edit.
    //
    // STRUCTURAL, deliberately. Suspending the host from a test suite is not
    // available, and the alternative is no guard at all on the one edit that
    // puts the defect back.
    let code = codeLines(of: try monotonicClockSource())

    // ANTI-VACUITY. A mis-resolved path or an over-eager comment filter reads
    // as an empty string, on which every `contains(…) == false` below passes.
    #expect(code.contains("public static func now()"), """
        the comment-stripped source of MonotonicClock.swift no longer contains \
        its own entry point, so this guard is reading nothing
        """)

    #expect(code.contains("mach_continuous_time()"), """
        MonotonicClock no longer calls mach_continuous_time(). The cap is \
        measured against this reading, and a clock that stops while the lid is \
        shut gives a lid-closed hold back every second the machine napped.
        """)
    #expect(code.contains("mach_absolute_time") == false, """
        MonotonicClock calls mach_absolute_time(), which does not advance while \
        the system is asleep. On the one workload this feature is for — a \
        laptop holding sleep with its lid closed — that under-counts elapsed \
        time and extends the hold past `JournalRecord.maxTTLSeconds`.
        """)
}

@Test func theMonotonicClockIsAtLeastTheAwakeUptimeItContains() throws {
    // `ProcessInfo.systemUptime` is the AWAKE-only clock: how long the machine
    // has been up excluding sleep. Continuous time is that plus the sleep, so
    // it can never be the smaller of the two. Foundation derives it
    // independently, which is what makes this a comparison rather than a
    // restatement of the implementation.
    //
    // Named bug this catches: reading `mach_continuous_time()`'s TICKS as
    // nanoseconds. On Apple silicon one tick is 125/3 ns, so a raw count runs
    // about 41 times slow — an 8-hour cap becomes a fortnight — and 1/41 of the
    // uptime lands far below the awake uptime this compares against.
    let awake = ProcessInfo.processInfo.systemUptime
    let continuous = SystemMonotonicClock.now()

    #expect(continuous >= awake, """
        continuous time reads \(continuous) s while this machine has been AWAKE \
        for \(awake) s. Continuous time contains the awake time, so a smaller \
        value means the timebase conversion is wrong and every elapsed time \
        measured from it is scaled with it.
        """)
}

@Test func theMonotonicClockAdvancesInSecondsAndNotInMachTicks() throws {
    // The rate, against the only other clock available here. Bounded loosely on
    // the upper side because a loaded runner oversleeps, and tightly on the
    // LOWER side, which is where the timebase bug lands: 0.2 s of real waiting
    // measures 0.005 s when ticks are read as nanoseconds.
    let before = SystemMonotonicClock.now()
    Thread.sleep(forTimeInterval: 0.2)
    let elapsed = SystemMonotonicClock.now() - before

    #expect(elapsed >= 0.15, """
        0.2 s of sleeping measured \(elapsed) s of monotonic time. A clock that \
        runs slow makes every hold outlive its TTL by the same factor.
        """)
    #expect(elapsed <= 5, """
        0.2 s of sleeping measured \(elapsed) s of monotonic time, which is a \
        clock running fast enough to end holds that have barely started.
        """)
}
