// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoffeeBarCore

/// What `coffee-bar-probe report` has to say about a live hold: the journal's
/// own record, plus the deadline the daemon will actually act on.
///
/// THE INVARIANT: the deadline here is derived from `setAtMonotonic`, because
/// that is the clock the cap is enforced against. `WatchdogDecision.decide`
/// ends a hold when ELAPSED MONOTONIC time passes `ttlSeconds`;
/// `JournalRecord.expiry` is that same TTL added to `setAt`, a wall-clock
/// value. The two disagree by the size of any step taken since the arm, and
/// `report` printed the second one until #85. Nothing misbehaved — the user was
/// told a time the machine would not honour, and `report` is the only way to
/// learn it at all, because the journal belongs to root and the app runs as the
/// user.
///
/// Both clocks are taken as arguments rather than read here, so the answer is
/// testable without stepping the machine's clock — and so the pair is sampled
/// ONCE, together, by the caller. `main.swift`'s watchdog loop samples them the
/// same way, for the same reason.
public struct ArmedHoldReport: Encodable, Sendable {
    public let record: JournalRecord

    /// Real seconds until the cap fires, on the clock that enforces it.
    ///
    /// NEGATIVE when the cap has already passed and the revert has not run yet.
    /// That is reachable rather than theoretical — the daemon ticks every 5 s,
    /// so a record read between its cap and its revert is an ordinary sighting
    /// — and it is deliberately NOT clamped to zero: "0s left" renders a hold
    /// whose revert is late identically to a healthy one in its final instant,
    /// which is the single moment the difference is worth anything.
    public let enforcedSecondsRemaining: TimeInterval

    /// `enforcedSecondsRemaining` projected onto the wall clock a human reads
    /// dates from.
    ///
    /// A PROJECTION, and labelled as one wherever it is shown. It assumes
    /// nobody steps the wall clock between now and then — the assumption #85
    /// exists because of. Only `enforcedSecondsRemaining` survives a step.
    public let projectedEndWallClock: Date

    public init(record: JournalRecord, now: Date, monotonicNow: TimeInterval) {
        self.record = record
        let remaining =
            record.setAtMonotonic + TimeInterval(record.ttlSeconds) - monotonicNow
        self.enforcedSecondsRemaining = remaining
        self.projectedEndWallClock = now.addingTimeInterval(remaining)
    }

    private enum CodingKeys: String, CodingKey {
        case enforcedSecondsRemaining
        case projectedEndWallClock
    }

    /// FLAT and ADDITIVE, not `{"record": …, "enforced": …}`.
    ///
    /// The record encodes itself into this same container first, so every key a
    /// `--json` consumer already reads keeps its name and its value, and a
    /// field the journal gains later appears here without anyone remembering to
    /// list it. Hand-listing the record's fields would have made this a second
    /// copy of the schema, and the pair would drift the first time one side
    /// changed.
    public func encode(to encoder: any Encoder) throws {
        try record.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enforcedSecondsRemaining,
                             forKey: .enforcedSecondsRemaining)
        try container.encode(projectedEndWallClock, forKey: .projectedEndWallClock)
    }
}
