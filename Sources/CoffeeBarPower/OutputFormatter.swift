// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoffeeBarCore

public enum OutputFormatter {
    /// Generic over `Encodable` rather than fixed to `ProbeReport`: M5's
    /// `report` verb emits a `JournalRecord`, and a second function would mean
    /// a second copy of the date strategy below — which is exactly the kind of
    /// pair that drifts. One encoder configuration, every payload.
    public static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // ISO-8601, not the default .deferredToDate. The reason is
        // READABILITY, not precision: a probe report is a human-inspected
        // artifact and a bare epoch number in it is hostile to whoever is
        // reading a verdict at 2am.
        //
        // Do NOT re-justify this as a precision fix. It was originally
        // claimed as one and that claim is false, disproven by measurement:
        // `Date` IS a `Double` and JSONEncoder emits the
        // shortest-round-trippable form, so `.deferredToDate` is lossless by
        // construction (2000/2000 live `Date()` values round-tripped
        // bit-identical).
        //
        // The real consequence is the opposite of a free win: ISO-8601 has
        // SECOND granularity, so this strategy is strictly lossier than the
        // default. That is why report timestamps are stamped with
        // `HostInfo.now()`, which truncates — see `ProbeRun.report`.
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Decoder matching `json(_:)`. Any consumer parsing a probe report must
    /// use this, or `.iso8601` explicitly — a default `JSONDecoder` will fail
    /// on the date field.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func human(_ report: ProbeReport) -> String {
        var lines: [String] = []
        lines.append("coffee-bar capability probe")
        lines.append("  host   \(report.host.hardwareModel) "
                     + "\(report.host.arch)")
        lines.append("  os     \(report.host.osVersion) "
                     + "(build \(report.host.osBuild))")
        lines.append("")
        for spike in report.spikes {
            lines.append("  \(spike.id.rawValue.padded(to: 9))"
                         + "\(label(spike.verdict).padded(to: 12))"
                         + spike.detail)
        }
        return lines.joined(separator: "\n")
    }

    /// The human form of `report`.
    ///
    /// The ENFORCED value is the prominent one and the wall-clock date is
    /// labelled a projection, which is the shape #85 asked for: a date is more
    /// readable, so it stays, but it must not be the line the reader takes for
    /// the answer. Both come off `ArmedHoldReport`, so this and the `--json`
    /// path cannot give different answers.
    public static func human(_ hold: ArmedHoldReport) -> String {
        let record = hold.record
        let seconds = Int(hold.enforcedSecondsRemaining.rounded())
        // Past the cap reads as past the cap. See `enforcedSecondsRemaining`
        // for why this is not folded into "0s left".
        let enforced = seconds < 0
            ? "cap passed \(-seconds)s ago, revert pending"
            : "\(seconds)s left"
        return """
            armed:     \(record.intent.rawValue)
            since:     \(record.setAt)
            enforced:  \(enforced)
            projected: \(hold.projectedEndWallClock) \
            (wall clock, projected from the line above; not the value enforced)
            restore:   SleepDisabled=\(record.priorValue ? 1 : 0)
            armedBy:   pid \(record.armedBy.pid), uid \(record.armedBy.uid), \
            \(record.armedBy.binaryPath)
            """
    }

    private static func label(_ v: Verdict) -> String {
        switch v {
        case .pass:           return "pass"
        case .fail:           return "FAIL"
        case .notApplicable:  return "n/a"
        case .notYetRun:      return "not-yet-run"
        case .error:          return "ERROR"
        }
    }
}

private extension String {
    func padded(to width: Int) -> String {
        count >= width ? self + " " : self + String(repeating: " ", count: width - count)
    }
}
