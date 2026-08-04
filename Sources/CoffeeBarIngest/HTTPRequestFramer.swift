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
    /// stops it pinning unbounded memory in a menu-bar app. That intent is
    /// unchanged; only the number moved.
    ///
    /// It moved because 64 KiB dropped real traffic. Measured end to end against
    /// this listener with `/usr/bin/curl`: a `Stop` body of 65,386 bytes
    /// returned 204, and one of 65,387 bytes returned 413 and was never
    /// delivered. A reply carrying a large code block passes 64 KiB routinely,
    /// and design §7.1 already measured 2747 characters of reply text in an
    /// ORDINARY one.
    ///
    /// The refusal was worse than the loss. The documented hook command had no
    /// `--fail`, so curl exited 0 and printed nothing, the event vanished with
    /// no signal anywhere, and the session never left `.working` — which means
    /// the hold never released. `docs/V0.1-ACCEPTANCE.md` now carries
    /// `--fail-with-body` so a refusal is at least visible.
    ///
    /// The cap counts HEADERS, which is why the measured body threshold sits
    /// about 150 bytes under this number rather than on it.
    ///
    /// `UnixSocketIngestListener.receiveChunkBytes` is deliberately NOT this
    /// value. See the comment there.
    static let maximumBytes = 1_048_576

    enum Outcome: Equatable {
        case needMore
        case body(Data)
        case tooLarge
        case malformed
    }

    private static let terminator = Data("\r\n\r\n".utf8)

    private var buffer = Data()

    /// The path the client posted to, once the header block has arrived.
    ///
    /// This is how coffee-bar learns which agent tool sent the payload:
    /// `AgentTool.declared(byEndpoint:)` turns it into an origin. The user
    /// pastes a different hook command per tool, so the sender declares itself
    /// here, in the one place a payload's own bytes cannot.
    ///
    /// `nil` until the headers are complete, and `nil` for a request line this
    /// type cannot parse. Both mean the same thing to the caller — no tool was
    /// declared — and the caller refuses rather than guessing.
    private(set) var requestTarget: String?

    mutating func append(_ chunk: Data) -> Outcome {
        buffer.append(chunk)
        if buffer.count > Self.maximumBytes { return .tooLarge }

        guard let separator = buffer.range(of: Self.terminator) else {
            return .needMore
        }

        let headers = buffer[..<separator.lowerBound]
        requestTarget = Self.target(in: headers)

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

    /// The request target from the first line of `headers`, or `nil`.
    ///
    /// RFC 9112 §3 fixes the request line as three space-separated fields:
    /// method, target, version. The arity is checked rather than assumed —
    /// splitting and reaching for component 1 with no check returns the METHOD
    /// as the target for a one-field line, and that string would then be handed
    /// to the origin lookup as if the client had declared it.
    ///
    /// Anything else is `nil`, which the caller treats as no declaration at all.
    private static func target(in headers: Data) -> String? {
        guard let text = String(data: headers, encoding: .utf8),
              let line = text.split(separator: "\r\n", maxSplits: 1).first
        else { return nil }
        let fields = line.split(separator: " ")
        guard fields.count == 3 else { return nil }
        return String(fields[1])
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
