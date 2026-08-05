// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

// The pure half of `coffeebar-hook`: turning a tool and a body into the bytes
// of one POST, and reading a status code back out of the answer.
//
// It lives in `CoffeeBarCore` rather than in the executable for the reason
// `Package.swift` already records at the `CoffeeBarUI` target: SwiftPM treats an
// executable target's `main.swift` as top-level code, which a test target
// cannot import. Everything here would otherwise be untestable.
//
// It also has no I/O, so it respects `CoffeeBarCore`'s no-I/O rule. The socket
// work stays in `Sources/CoffeeBarShim/main.swift`, and the END-TO-END proof
// that the two halves fit is `Tests/CoffeeBarIngestTests/CoffeeBarHookShim_test.swift`,
// which runs the built binary against a real listener. Nothing in this file
// proves the shim works; it proves the bytes are right.

// MARK: - Which tool the user named

@Test func eachToolAnswersToTheNameTheDocumentedCommandUses() {
    // Literals, never `tool.shimName`: these are what the user types after
    // `--tool=` and what `docs/QUICKSTART.md` prints. Deriving the expectation
    // from the subject would let a rename pass unseen here and break every
    // hook the user has already wired.
    #expect(AgentTool.declared(byShimName: "claude-code") == .claudeCode)
    #expect(AgentTool.declared(byShimName: "codex") == .codex)
    #expect(AgentTool.declared(byShimName: "cursor") == .cursor)
}

@Test func anUnrecognisedToolNameDeclaresNothing() {
    // The same rule `AgentTool.declared(byEndpoint:)` states for endpoints: an
    // origin that is not recognised is REFUSED, never defaulted. A fallback
    // here would file a Cursor session under Claude Code because the user
    // mistyped one character, and the wrong state machine would run silently.
    //
    // Matched exactly, so case and whitespace are both rejected. `--tool=`
    // values come from a line the user pastes, not from free text.
    for name in ["", "claudecode", "claude_code", "Claude-Code", "claude-code ",
                 " cursor", "cursor/", "CODEX", "cline"] {
        #expect(AgentTool.declared(byShimName: name) == nil,
                Comment(rawValue: "\"\(name)\" was accepted as a tool declaration"))
    }
}

@Test func everyToolHasADistinctNameThatRoundTrips() {
    // Catches the reverse lookup going stale when a fourth `AgentTool` case
    // arrives. `shimName` itself is a `switch` with no `default`, so the
    // forward direction fails to COMPILE; this is the half a compiler cannot
    // see, plus the collision a copy-paste would introduce.
    for tool in AgentTool.allCases {
        #expect(AgentTool.declared(byShimName: tool.shimName) == tool,
                Comment(rawValue: "\(tool).shimName is \"\(tool.shimName)\", which maps back to "
                        + "\(String(describing: AgentTool.declared(byShimName: tool.shimName)))"))
    }
    #expect(Set(AgentTool.allCases.map(\.shimName)).count == AgentTool.allCases.count,
            "two tools share a shim name; one of them is unreachable from the command line")
}

@Test func aShimRunWithNoToolFlagStillMeansClaudeCode() {
    // `/event` is the endpoint every hook already installed posts to, and
    // `AgentTool.declared(byEndpoint:)` explains why that legacy path keeps
    // meaning Claude Code. A shim that defaulted to anything else would retag
    // the only cohort this product has.
    #expect(HookShim.defaultTool == .claudeCode)
    #expect(HookShim.defaultTool.ingestEndpoint == "/event")
}

// MARK: - The bytes of the request

@Test func theRequestLineCarriesTheEndpointTheToolDeclares() {
    // Literals rather than `tool.ingestEndpoint`: these three strings are the
    // user-visible contract the listener matches on, and `AgentOrigin_test`
    // pins the same three. An expectation built from the same expression as
    // the subject would agree with a wrong implementation.
    let expected: [AgentTool: String] = [
        .claudeCode: "POST /event HTTP/1.1",
        .codex: "POST /event/codex HTTP/1.1",
        .cursor: "POST /event/cursor HTTP/1.1",
    ]
    #expect(expected.count == AgentTool.allCases.count,
            "a tool has no expected request line here; the loop below would skip it")

    for tool in AgentTool.allCases {
        let request = HookShim.request(posting: Data("{}".utf8), as: tool)
        let text = String(decoding: request, as: UTF8.self)
        let line = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init)
        #expect(line == expected[tool],
                Comment(rawValue: "\(tool) posted to \(line ?? "<no request line>")"))
    }
}

@Test func theWholeRequestIsExactlyTheseBytes() {
    // The strongest pin in this file, and the cheapest to read. RFC 9112 §3
    // fixes the request line at three space-separated fields, and
    // `HTTPRequestFramer.target(in:)` returns `nil` — no declaration at all —
    // for any other arity. `Connection: close` is what lets the shim read the
    // answer to end of stream instead of guessing at a length.
    let request = HookShim.request(posting: Data(#"{"hook_event_name":"Stop"}"#.utf8),
                                   as: .claudeCode)
    #expect(String(decoding: request, as: UTF8.self) == """
        POST /event HTTP/1.1\r
        Host: localhost\r
        Content-Type: application/json\r
        Content-Length: 26\r
        Connection: close\r
        \r
        {"hook_event_name":"Stop"}
        """)
}

@Test func theContentLengthCountsBytesAndNotCharacters() {
    // Named bug: `Content-Length` taken from a `String`'s `count`, which is
    // CHARACTERS. One emoji in an assistant reply then makes the shim declare
    // fewer bytes than it sends. `HTTPRequestFramer` takes exactly the declared
    // length as the body, so the payload arrives TRUNCATED and decodes to a
    // 400, while the remaining bytes sit in the buffer as a second malformed
    // request. Agent payloads carry reply text, so this is routine traffic and
    // not an edge case.
    let json = #"{"m":"☕"}"#
    #expect(json.count == 9, "the fixture is single-byte; the check below would be vacuous")
    let body = Data(json.utf8)
    #expect(body.count == 11, "U+2615 is three UTF-8 bytes; the fixture changed")

    let text = String(decoding: HookShim.request(posting: body, as: .claudeCode), as: UTF8.self)
    #expect(text.contains("Content-Length: 11\r\n"))
    #expect(!text.contains("Content-Length: 9\r\n"),
            "the length was counted in characters, so the body arrives truncated")
}

@Test func theBodyIsCarriedThroughByteForByte() throws {
    // The shim is a PIPE. Design §7 and `SECURITY.md` put the privacy boundary
    // in the LISTENER, which can only hold it if it receives what the agent
    // really sent. Bytes that are not JSON at all must still arrive unchanged:
    // deciding a payload is malformed is the listener's job, and answering 400
    // is how the user finds out.
    //
    // A NUL and a 0xFF are in here on purpose. Any implementation that routes
    // the body through `String` mangles both, and a UTF-8 round trip would
    // replace 0xFF with U+FFFD — three bytes where one went in.
    let body = Data([0x7B, 0x00, 0xFF, 0x0A, 0x7D])
    let request = HookShim.request(posting: body, as: .codex)

    let separator = try #require(request.range(of: Data("\r\n\r\n".utf8)),
                                 "the request has no header terminator at all")
    #expect(Data(request[separator.upperBound...]) == body)
    #expect(String(decoding: request[..<separator.lowerBound], as: UTF8.self)
        .contains("Content-Length: 5\r\n"))
}

@Test func aBodyIsFollowedByNothingAtAll() throws {
    // No trailing newline, and no second request. `HTTPRequestFramer` reads
    // exactly `Content-Length` bytes and leaves the rest in its buffer, so a
    // stray byte after the body is not an error the sender ever sees — it is a
    // silent difference between what the agent sent and what was stored.
    let body = Data(#"{"hook_event_name":"Stop","session_id":"s1"}"#.utf8)
    let request = HookShim.request(posting: body, as: .cursor)
    let separator = try #require(request.range(of: Data("\r\n\r\n".utf8)))
    #expect(request.distance(from: separator.upperBound, to: request.endIndex) == body.count)
}

// MARK: - Reading the answer

@Test func theStatusCodeIsReadOffTheStatusLine() {
    // The four the listener sends. `IngestListener` answers 204 on success,
    // 400 on a body that will not decode, 404 on an endpoint it does not
    // recognise, and 413 when the request passes `HTTPRequestFramer.maximumBytes`.
    #expect(HookShim.statusCode(inResponse: Data("HTTP/1.1 204 No Content\r\n\r\n".utf8)) == 204)
    #expect(HookShim.statusCode(inResponse: Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8)) == 400)
    #expect(HookShim.statusCode(inResponse: Data("HTTP/1.1 404 Not Found\r\n\r\n".utf8)) == 404)
    #expect(HookShim.statusCode(inResponse: Data("HTTP/1.1 413 Content Too Large\r\n\r\n".utf8)) == 413)
}

@Test func anAnswerThatIsNotAStatusLineYieldsNoCode() {
    // Named bug: a parser that splits on spaces and reaches for field 1 of
    // whatever arrived. The shim would then report a number the listener never
    // sent. The empty case is the one that matters most in practice — it is
    // what a timed-out read returns, and reading `204` out of nothing would
    // turn every lost answer into a silent success.
    #expect(HookShim.statusCode(inResponse: Data()) == nil)
    #expect(HookShim.statusCode(inResponse: Data("204 No Content\r\n".utf8)) == nil)
    #expect(HookShim.statusCode(inResponse: Data("HTTP/1.1\r\n".utf8)) == nil)
    #expect(HookShim.statusCode(inResponse: Data("HTTP/1.1 two-oh-four\r\n".utf8)) == nil)
    #expect(HookShim.statusCode(inResponse: Data("HTTP/1.1 20 Short\r\n".utf8)) == nil)
    #expect(HookShim.statusCode(inResponse: Data("garbage".utf8)) == nil)
    #expect(HookShim.statusCode(inResponse: Data([0xFF, 0xFE, 0x00])) == nil)
}

@Test func onlyTwoHundredAndFourIsSuccess() {
    // What the shim decides to report on. 204 is the only answer that means
    // the event was stored; every other code is a refusal the user must be
    // able to see on stderr, and a lost answer is not a success either.
    #expect(HookShim.isSuccess(204))
    #expect(!HookShim.isSuccess(200))
    #expect(!HookShim.isSuccess(400))
    #expect(!HookShim.isSuccess(404))
    #expect(!HookShim.isSuccess(413))
    #expect(!HookShim.isSuccess(nil))
}

// MARK: - The bound on one run

@Test func theRunIsBoundedWellUnderWhatAHookCanAfford() {
    // `docs/coffee-bar-HANDOFF.md` fixes the connect timeout at 250 ms and the
    // whole-run budget at 50 ms for the normal path. These two numbers are
    // CEILINGS on the abnormal path, not costs: a hook that reaches either is
    // already talking to a listener that is not answering.
    //
    // The total is an order of magnitude above the 50 ms budget and an order
    // of magnitude below `UnixSocketIngestListener.defaultIdleTimeout`, which
    // is 10 s. Sitting between the two is the whole point: the shim gives up
    // long before the listener would, so a wedged listener cannot hold the
    // agent for ten seconds on every tool call.
    #expect(HookShim.connectTimeout == 0.25)
    #expect(HookShim.totalTimeout == 1.0)
    #expect(HookShim.connectTimeout < HookShim.totalTimeout,
            "the connect bound is not inside the total bound; the total does not bound the run")
}
