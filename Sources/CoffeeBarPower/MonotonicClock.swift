// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Seconds of real elapsed time since this machine last booted.
///
/// `mach_continuous_time()`, and deliberately NOT `mach_absolute_time()`. The
/// two differ by exactly the time the machine spent asleep, and this feature
/// exists for a laptop with its lid shut — the one state in which a Mac naps.
/// A clock that stopped during the nap would under-count the hold and hand back
/// every second it slept through, which is the same defect the monotonic stamp
/// exists to close, wearing a subtler disguise that no test on a running
/// machine would catch.
///
/// The value resets at boot, and that is exactly the lifetime the journal
/// needs. `WatchdogService` compares the journal's `bootSessionID` against the
/// identity this boot reports and reverts anything stamped in a different one,
/// so no deadline here ever has to survive a reboot.
public enum SystemMonotonicClock {
    /// The tick that `mach_continuous_time()` counts is NOT a nanosecond. On
    /// Apple silicon the timebase is 125/3, so one tick is about 41.67 ns, and
    /// a raw count read as nanoseconds under-counts elapsed time by that
    /// factor — an 8-hour cap becomes a fortnight.
    ///
    /// Measured once: the timebase is fixed for the life of the machine.
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else {
            // A timebase this build cannot read must not silently become 1:1.
            // Too SMALL a ratio under-counts elapsed time and EXTENDS the hold,
            // which is the open failure; too large ends it early, which merely
            // loses the feature. So the fallback is the largest ratio this
            // platform ships, resolving the unknown the way the boot rung still
            // does: an unreadable `kern.bootsessionuuid` is stamped as `""`,
            // and `isFromAnotherBoot` reads an empty identity on either side as
            // a DIFFERENT boot, so it reverts rather than checks nothing.
            return appleSiliconTimebase
        }
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    /// 125/3 ns per tick, the ratio every arm64 Mac reports.
    private static let appleSiliconTimebase = 125.0 / 3.0 / 1_000_000_000

    public static func now() -> TimeInterval {
        Double(mach_continuous_time()) * secondsPerTick
    }
}
