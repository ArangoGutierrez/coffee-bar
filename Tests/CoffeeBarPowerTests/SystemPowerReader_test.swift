// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import CoffeeBarCore
@testable import CoffeeBarPower

/// What `pmset -g batt` reports about this machine.
///
/// This is the independent oracle the live-machine assertions below compare
/// against. `pmset` is Apple's own reader over the same power subsystem, in a
/// separate process with a separate parse. Re-deriving the answer from
/// `IOPSCopyPowerSourcesList` inside the test would copy the implementation
/// under test, which asserts nothing.
private struct PmsetReport {
    /// True when the machine has an internal battery at all. A property of the
    /// hardware, so it cannot change between the reader's call and this one.
    let hasInternalBattery: Bool
    /// True when the machine is currently running off that battery. This one
    /// *can* change if someone pulls the plug mid-test; the window is the few
    /// milliseconds between the IOKit read and this process spawn.
    let drawingFromBattery: Bool
    let percent: Int?

    static func read() throws -> PmsetReport {
        let text = try SystemCommandRunner()
            .run("/usr/bin/pmset", ["-g", "batt"]).stdout
        // Two shapes, exactly:
        //   "Now drawing from 'Battery Power'\n
        //    -InternalBattery-0 (id=36044899)\t77%; discharging; 3:07 ..."
        //   "Now drawing from 'AC Power'"          <- no battery at all
        let percent = text.split(whereSeparator: \.isWhitespace)
            .first { $0.hasSuffix("%;") }
            .flatMap { Int($0.dropLast(2)) }
        return PmsetReport(
            hasInternalBattery: text.contains("InternalBattery"),
            drawingFromBattery: text.contains("'Battery Power'"),
            percent: percent)
    }
}

@Test func aRealReadingIsInternallyConsistent() throws {
    // Reads the live machine, so it asserts invariants rather than a fixed
    // value. Deliberately NOT the bare `if let percent { ... }` form: on a
    // machine reporting no battery that body never runs, so a reader that
    // returned nil for everything would pass while asserting nothing. Same
    // reasoning as `batteryAndPowerSourceReadingsAreMutuallyConsistent` in
    // BaselineProbe_test.swift. Every branch below asserts something that can
    // fail, and the two unconditional lines assert on any host.
    //
    // Typed as the protocol on purpose: `PowerReadingProviding` is the seam
    // the app depends on, so conformance is load-bearing for this test rather
    // than checked by a separate structural one.
    let reader: any PowerReadingProviding = SystemPowerReader()
    let reading = reader.read()
    let pmset = try PmsetReport.read()

    // Unconditional. Battery presence is hardware, so this discriminates on
    // every host: it fails for a reader that invents a percent on a desktop,
    // and for one that reports nil on a laptop.
    #expect((reading.percent != nil) == pmset.hasInternalBattery,
            """
            reader percent=\(String(describing: reading.percent)), \
            pmset battery present=\(pmset.hasInternalBattery)
            """)

    // Unconditional. Fails for a reader that hardcodes either case, which the
    // percent assertions alone would not catch. UPS power is neither branch's
    // problem: `pmset` prints 'UPS Power', and a machine drawing from a UPS is
    // not drawing from its internal battery, so both sides read false.
    #expect((reading.source == .battery) == pmset.drawingFromBattery,
            """
            reader source=\(reading.source), \
            pmset drawing from battery=\(pmset.drawingFromBattery)
            """)

    if let percent = reading.percent {
        #expect(percent >= 0 && percent <= 100,
                "percent out of range: \(percent)")
        // A tolerance of 2 absorbs a real discharge between the two reads and
        // pmset's own rounding. A reader that parsed the wrong power source or
        // got the arithmetic wrong misses by far more than 2.
        let reported = try #require(pmset.percent,
                                    "pmset saw a battery but printed no percent")
        #expect(abs(percent - reported) <= 2,
                "reader \(percent)% vs pmset \(reported)%")
    } else {
        // The documented fallback in `read()`: absent or unreadable is
        // reported as AC, because that never suppresses a hold the user asked
        // for. Asserted so this branch is not empty either.
        #expect(reading.source == .ac,
                "no battery, so the reading must fall back to AC")
    }
}

@Test func repeatedReadsAgreeOnWhetherABatteryExists() {
    // A battery does not appear and vanish between two calls. Disagreement
    // means the parse is reading a different power source each time — the
    // ordering bug that index-based access into an IOKit list produces.
    //
    // The whole reading is compared, not just whether `percent` is nil. The
    // nil-ness comparison could not fail on any host: the bug it names —
    // picking a different source on each call — changes the VALUE, and both
    // values are non-nil. `PowerReading` is Equatable, so one `==` covers the
    // percent and the source together.
    let first = SystemPowerReader().read()
    let second = SystemPowerReader().read()
    #expect(first == second)
}

@Test func readingIsCheapEnoughToPoll() {
    // The app polls this on a timer. A read that blocks would freeze the UI.
    let start = Date()
    _ = SystemPowerReader().read()
    #expect(Date().timeIntervalSince(start) < 0.5)
}
