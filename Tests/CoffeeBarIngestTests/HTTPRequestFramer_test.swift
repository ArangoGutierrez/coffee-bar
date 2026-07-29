// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarIngest

private let body = #"{"hook_event_name":"Stop","session_id":"s1"}"#

private func request(body: String, contentLength: Int? = nil) -> Data {
    let length = contentLength ?? body.utf8.count
    return Data("""
        POST /ingest HTTP/1.1\r
        Host: localhost\r
        Content-Type: application/json\r
        Content-Length: \(length)\r
        \r
        \(body)
        """.utf8)
}

/// Builds a request whose `Content-Length` is not a number this type can use.
///
/// Separate from `request(body:contentLength:)` because that one takes an `Int`,
/// and the whole point of these cases is a value no `Int` can hold.
private func requestWithRawContentLength(_ raw: String, body: String = "") -> Data {
    Data("""
        POST /ingest HTTP/1.1\r
        Host: localhost\r
        Content-Length: \(raw)\r
        \r
        \(body)
        """.utf8)
}

@Test func aWholeRequestInOneChunkYieldsExactlyTheBody() {
    var framer = HTTPRequestFramer()
    #expect(framer.append(request(body: body)) == .body(Data(body.utf8)))
}

@Test func aRequestSplitAcrossChunksIsReassembled() {
    // The case the curl spike could NOT produce: it delivered all 216 bytes in
    // one receive. Named bug this catches: a framer that parses whatever the
    // first receive happened to contain, which works on a developer's machine
    // and drops events under load.
    let whole = request(body: body)
    var framer = HTTPRequestFramer()

    // Split INSIDE the header block, so the header terminator itself straddles
    // two chunks.
    #expect(framer.append(whole.prefix(20)) == .needMore)
    #expect(framer.append(whole.dropFirst(20).prefix(60)) == .needMore)
    #expect(framer.append(whole.dropFirst(80)) == .body(Data(body.utf8)))
}

@Test func aBodyArrivingAfterTheHeadersIsWaitedFor() {
    let whole = request(body: body)
    let headerEnd = whole.count - body.utf8.count
    var framer = HTTPRequestFramer()
    #expect(framer.append(whole.prefix(headerEnd)) == .needMore)
    #expect(framer.append(whole.suffix(body.utf8.count)) == .body(Data(body.utf8)))
}

@Test func onlyContentLengthBytesAreTaken() {
    // Named bug this catches: returning everything after the headers. A client
    // that pipelines a second request would have both bodies concatenated into
    // one unparseable blob, and every event on that connection would be lost.
    var framer = HTTPRequestFramer()
    let padded = request(body: body + "TRAILING-GARBAGE",
                         contentLength: body.utf8.count)
    #expect(framer.append(padded) == .body(Data(body.utf8)))
}

@Test func headersWithNoContentLengthAreRejected() {
    var framer = HTTPRequestFramer()
    let raw = Data("POST /ingest HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
    #expect(framer.append(raw) == .malformed)
}

@Test func contentLengthIsMatchedWithoutRegardToCase() {
    // curl sends `Content-Length`. Nothing stops another client sending
    // `content-length`, and RFC 9110 makes field names case-insensitive.
    var framer = HTTPRequestFramer()
    let raw = Data("POST / HTTP/1.1\r\ncontent-length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
    #expect(framer.append(raw) == .body(Data(body.utf8)))
}

@Test func anOversizedRequestIsRefusedRatherThanBuffered() {
    // Design §4.1: a same-user process can post. Without a cap it can also pin
    // unbounded memory in a menu-bar app that is meant to be invisible.
    var framer = HTTPRequestFramer()
    let huge = Data(repeating: 0x41, count: HTTPRequestFramer.maximumBytes + 1)
    #expect(framer.append(huge) == .tooLarge)
}

@Test func aRequestExactlyAtTheCapIsAccepted() {
    // The other side of the cap. Named bug this catches: `>=` where `>` belongs,
    // which refuses a legal request one byte under the limit.
    let filler = String(repeating: "x", count: 100)
    let payload = #"{"hook_event_name":"Stop","session_id":"\#(filler)"}"#
    var framer = HTTPRequestFramer()
    let raw = request(body: payload)
    #expect(raw.count < HTTPRequestFramer.maximumBytes)
    #expect(framer.append(raw) == .body(Data(payload.utf8)))
}

// MARK: - The declared length itself (PE finding B1)

@Test func aNegativeContentLengthIsRejectedRatherThanCrashingTheApp() {
    // THE crash. `Int("-1")` is -1, the `available >= length` guard passes
    // (0 >= -1), `bodyEnd` lands BEFORE `bodyStart`, and the range subscript
    // traps with "Range requires lowerBound <= upperBound".
    //
    // Reproduced by a principal-engineer spike against a raw AF_UNIX client: one
    // 60-byte POST from any same-user process killed the menu-bar app. The app
    // holds the power assertion, so the crash releases it and the machine sleeps
    // under a running agent, with nothing left to restart it.
    //
    // `headersWithNoContentLengthAreRejected` does NOT reach this: an ABSENT
    // header returns nil from the parse and lands on `.malformed` already. A
    // PRESENT, negative one parses fine and reaches the subscript.
    var framer = HTTPRequestFramer()
    #expect(framer.append(request(body: "", contentLength: -1)) == .malformed)
}

@Test func aZeroContentLengthYieldsAnEmptyBody() {
    // The mirror of the guard above, and the reason it is `>= 0` and not `> 0`.
    // Named bug this catches: rejecting the negative case with `length > 0`,
    // which also rejects a legal body-less POST.
    var framer = HTTPRequestFramer()
    #expect(framer.append(request(body: "", contentLength: 0)) == .body(Data()))
}

@Test func aNonNumericContentLengthIsRejected() {
    var framer = HTTPRequestFramer()
    #expect(framer.append(requestWithRawContentLength("banana")) == .malformed)
}

@Test func aContentLengthThatOverflowsIntIsRejected() {
    // `Int("99999999999999999999")` is nil rather than a wrapped value, so this
    // lands on the same branch as a non-numeric header. Asserted rather than
    // assumed: a parse that ever gained a clamping fallback would put an absurd
    // length back into the arithmetic below it.
    var framer = HTTPRequestFramer()
    #expect(framer.append(requestWithRawContentLength("99999999999999999999")) == .malformed)
}

@Test func aDeclaredLengthOverTheCapIsRefusedBeforeTheBytesArrive() {
    // Named bug this catches: capping only what has already been buffered. A
    // client that declares 4 GiB and then dribbles bytes is accepted one receive
    // at a time until the buffer itself crosses the cap, so the app holds the
    // partial request in memory for as long as the client cares to keep sending.
    // Refusing on the DECLARED length ends it at the first header block.
    var framer = HTTPRequestFramer()
    let raw = request(body: "x", contentLength: HTTPRequestFramer.maximumBytes + 1)
    #expect(raw.count < HTTPRequestFramer.maximumBytes,
            "the request itself must be small, or the buffer cap would fire instead")
    #expect(framer.append(raw) == .tooLarge)
}

@Test func aDeclaredLengthExactlyAtTheCapIsStillAccepted() {
    // The other side of the declared-length guard. Named bug this catches:
    // `length < maximumBytes`, which refuses the largest legal request.
    var framer = HTTPRequestFramer()
    let raw = request(body: "x", contentLength: HTTPRequestFramer.maximumBytes)
    #expect(framer.append(raw) == .needMore)
}
