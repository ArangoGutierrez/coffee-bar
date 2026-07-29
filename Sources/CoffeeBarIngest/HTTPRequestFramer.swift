// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Reassembles one HTTP request from however many pieces the socket delivers.
///
/// A spike against `curl 8.7.1` delivered a 216-byte request in a single
/// receive. That is a property of one small request on one machine, not a
/// guarantee, so this type accumulates and reports `needMore` until the body is
/// complete.
///
/// Only what design §4 needs: a POST with a `Content-Length` body. No chunked
/// encoding, no keep-alive, no pipelining. The client is `curl --unix-socket`
/// from a hook the user pasted in.
struct HTTPRequestFramer {

    /// The largest request accepted, headers included.
    ///
    /// Design §4.1 is explicit that a same-user process can post here. A cap
    /// stops it pinning unbounded memory in a menu-bar app.
    static let maximumBytes = 65_536

    enum Outcome: Equatable {
        case needMore
        case body(Data)
        case tooLarge
        case malformed
    }

    private static let terminator = Data("\r\n\r\n".utf8)

    private var buffer = Data()

    mutating func append(_ chunk: Data) -> Outcome {
        buffer.append(chunk)
        if buffer.count > Self.maximumBytes { return .tooLarge }

        guard let separator = buffer.range(of: Self.terminator) else {
            return .needMore
        }

        let headers = buffer[..<separator.lowerBound]

        // The declared length is VALIDATED, not merely parsed. `Int` accepts a
        // negative, and a negative length walked straight through the
        // `available >= length` guard below, put `bodyEnd` BEFORE `bodyStart`,
        // and trapped the range subscript with "Range requires lowerBound <=
        // upperBound". Reproduced against a raw AF_UNIX client: one 60-byte
        // POST from any same-user process killed the menu-bar app, which
        // released the power assertion and let the machine sleep under a
        // running agent.
        //
        // `>= 0` and not `> 0`: a body-less POST is legal and must still frame.
        guard let length = Self.contentLength(in: headers), length >= 0 else {
            return .malformed
        }

        // Refused on the DECLARED length, before the bytes are buffered. Capping
        // only what has already arrived lets a client declare 4 GiB and then
        // dribble bytes, holding the partial request in memory for as long as it
        // cares to keep sending.
        guard length <= Self.maximumBytes else { return .tooLarge }

        // `separator.upperBound` already sits past the four terminator bytes.
        let bodyStart = separator.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= length else { return .needMore }

        // Exactly `length` bytes, never everything that arrived: a pipelined
        // second request would otherwise be concatenated into the first body.
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        return .body(Data(buffer[bodyStart..<bodyEnd]))
    }

    /// RFC 9110 makes field names case-insensitive, so the match is lowercased.
    ///
    /// Returns `nil` for an absent header, for text that is not a number, and
    /// for a number too large for `Int` — `Int("99999999999999999999")` is `nil`
    /// rather than a wrapped value. Every one of those lands the caller on
    /// `.malformed`.
    private static func contentLength(in headers: Data) -> Int? {
        guard let text = String(data: headers, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                    == "content-length"
            else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
