// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarPower
@testable import CoffeeBarCore

// The shape of the control issue #74 adds, held against the two constants it
// sits between.
//
// `LidClosedHold` describes what the Preferences slider may offer; it does not
// enforce the cap. `JournalRecord.clamp` does that, on both the init and the
// decode path, and it is the only thing a hand-edited journal meets. So every
// check here is about a CONTROL being able to express what the product already
// enforces — a slider that stops at eight hours while the journal accepts
// twenty-four is a setting the user cannot reach and no other guard reports.

@Test func theHoldControlReachesTheJournalCeiling() {
    // THE #74 REQUIREMENT, and the one assertion that fails if the control and
    // the enforcement drift apart. Carlos's decision was a cap "user-configurable
    // up to 24h", so the top of the slider IS the ceiling the journal clamps to.
    //
    // Both halves, deliberately. The identity is definitional while `permitted`
    // is DERIVED from `JournalRecord.maxTTLSeconds` — and that is exactly why
    // the literal is here beside it. Somebody replacing the derivation with a
    // typed `24 * 60 * 60` leaves the identity green, and somebody typing
    // `8 * 60 * 60` there leaves it green too until the ceiling moves. The
    // literal is what says which number this is.
    #expect(LidClosedHold.permitted.upperBound == 86_400)
    #expect(LidClosedHold.permitted.upperBound == JournalRecord.maxTTLSeconds)
}

@Test func theHoldControlStartsAtHalfAnHour() {
    // The old default, kept as the FLOOR of what a user may choose rather than
    // as what they get. #74's argument is that half an hour is wrong as a
    // default, not that it is wrong as a choice: a user who genuinely wants a
    // short leash on AC can still ask for one.
    //
    // Below this the control stops being useful — at one second the slider's
    // first position arms a hold that has already expired — and `--ttl` remains
    // the way to ask for anything the slider does not offer.
    #expect(LidClosedHold.permitted.lowerBound == 1_800)
    #expect(LidClosedHold.step == 1_800)
}

@Test func everyPositionTheSliderCanTakeIsAHoldTheProductHonours() {
    // The two properties `BatteryFloor.choices` holds for the floor, computed
    // here rather than read off a constant the policy also derives.
    //
    // The stride IS the slider's semantics: `Slider(in:step:)` yields
    // `lowerBound + n * step`. Recomputing it here and comparing the result
    // against the two constants that bound the product is an independent
    // derivation — the policy never runs this code.
    let positions = Array(stride(from: LidClosedHold.permitted.lowerBound,
                                 through: LidClosedHold.permitted.upperBound,
                                 by: LidClosedHold.step))

    // Anti-vacuity: a step larger than the range yields one position and every
    // check below would pass on a control with nothing to drag.
    #expect(positions.count == 48, """
        the hold slider offers \(positions.count) position(s) between \
        \(LidClosedHold.permitted.lowerBound) s and \
        \(LidClosedHold.permitted.upperBound) s at a step of \
        \(LidClosedHold.step) s. Half-hourly across a day is 48.
        """)

    // 1. THE CEILING IS REACHABLE. A step that does not divide the range leaves
    //    the top position short of it — under `step = 2000` the slider stops at
    //    85 800 s while `--ttl 86400` is still accepted, so the product honours
    //    a hold the control cannot express and #74's "up to 24h" is false in
    //    the one place the user meets it.
    #expect(positions.last == JournalRecord.maxTTLSeconds, """
        the top of the hold slider is \(positions.last ?? -1) s and the journal \
        clamps at \(JournalRecord.maxTTLSeconds) s. A user cannot drag to the \
        ceiling the product enforces.
        """)

    // 2. THE DEFAULT IS REACHABLE. A default the control cannot return to is a
    //    default with no undo: a user who moves the slider once can never get
    //    back to the hold they were shipped.
    #expect(positions.contains(ProbeVerb.defaultTTLSeconds), """
        the hold slider offers \(positions.prefix(3))… and the default hold is \
        \(ProbeVerb.defaultTTLSeconds) s, which is not among its positions. A \
        user who moves this control cannot get back to the shipped hold.
        """)
}

@Test func aHandEditedHoldOutsideTheRangeIsBoundedAndNotTrapped() {
    // The preferences file is not this app's to trust. `defaults write` takes
    // any integer, and a negative one would otherwise reach the printed command
    // as `--ttl -3600` — a command the user pastes into a root shell.
    //
    // BOUNDED, never trapped, following the `BatteryFloor` and `WatchdogPolicy`
    // precedent: this runs while an assertion may be held, and a trap there
    // aborts with `SleepDisabled` still set.
    //
    // Literals on both sides. Recomputing `min(max(…))` here would restate the
    // implementation and assert nothing.
    #expect(LidClosedHold.bounded(-3_600) == 1_800)
    #expect(LidClosedHold.bounded(0) == 1_800)
    #expect(LidClosedHold.bounded(999_999_999) == 86_400)
    #expect(LidClosedHold.bounded(28_800) == 28_800)

    // Idempotent, which is what makes "bounded exactly once" safe to state as a
    // property of the value rather than as a promise about call order.
    #expect(LidClosedHold.bounded(LidClosedHold.bounded(999_999_999)) == 86_400)
}

@Test func theDefaultHoldSitsInsideWhatTheControlOffers() {
    // The two constants live in different modules — the default in `ProbeVerb`,
    // the ceiling in `JournalRecord` — and nothing but this reads them together.
    //
    // Named bug this catches: the default tuned up to twelve hours while the
    // slider still stops at eight. The window would then peg at its top, print a
    // `--ttl` shorter than the hold a bare `arm` takes, and tell the user their
    // maximum is less than their default.
    #expect(LidClosedHold.permitted.contains(ProbeVerb.defaultTTLSeconds), """
        the default hold is \(ProbeVerb.defaultTTLSeconds) s and the control \
        offers \(LidClosedHold.permitted.lowerBound)…\
        \(LidClosedHold.permitted.upperBound) s.
        """)
}

@Test func theTTLFlagThePrintedCommandUsesIsTheOneTheBinaryParses() throws {
    // The Preferences window now writes a NUMBER into the command it prints, and
    // that number only means anything if the flag carrying it is the flag the
    // probe's argument parser matches on.
    //
    // Named bug this catches, and it is silent in the worst way: the flag
    // renamed in `main.swift` — to `--hold`, say — while `ServingModel` goes on
    // printing `--ttl`. `parse()` ignores unknown flags by design, so the user
    // pastes a command that succeeds, reports success, and arms the DEFAULT hold
    // rather than the one they chose. Nothing errors and nothing else in this
    // package reads both sides.
    #expect(ProbeVerb.ttlFlag == "--ttl")

    let main = try String(contentsOf: probeSourceRoot()
        .appending(path: "Sources/CoffeeBarProbe/main.swift"), encoding: .utf8)

    // The SYMBOL, not the string. `main.swift` matching a literal "--ttl" is
    // precisely the drift this constant exists to remove, and a `contains("--ttl")`
    // here would be satisfied by it.
    #expect(main.contains("case ProbeVerb.ttlFlag:"), """
        Sources/CoffeeBarProbe/main.swift does not switch on ProbeVerb.ttlFlag, \
        so the flag it parses and the flag the Preferences window prints are two \
        strings that can differ. An unknown flag is ignored by parse(), so they \
        differ silently and the user's chosen hold is discarded.
        """)
}

/// The package root, resolved from `#filePath`.
private func probeSourceRoot() -> URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarPowerTests/LidClosedHold_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarPowerTests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // the package root
}
