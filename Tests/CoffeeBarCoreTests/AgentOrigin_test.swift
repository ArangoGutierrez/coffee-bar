// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

// The origin of a payload is DECLARED by its sender, never guessed from its
// content. `AgentTool.declared(byEndpoint:)` is where that declaration is read.
//
// The measurement that forced this design is pinned by
// `noPayloadKeyCanTellCodexFromClaudeCode` below: the recorded Codex `SessionEnd`
// carries a STRICT SUBSET of the keys the recorded Claude Code `SessionEnd`
// carries, so no key is present on every Codex payload and absent from every
// Claude Code one. A sniffer cannot exist.

private var fixturesRoot: URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarCoreTests/AgentOrigin_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarCoreTests
        .deletingLastPathComponent()    // …/Tests
        .appending(path: "Fixtures")
}

private func keys(_ corpus: String, _ file: String) throws -> Set<String> {
    let url = fixturesRoot.appending(path: "\(corpus)/\(file)")
    let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
    let payload = try #require(object as? [String: Any], "\(corpus)/\(file) is not a JSON object")
    return Set(payload.keys)
}

// MARK: - Why the origin cannot be sniffed

/// The falsifying measurement, run against the recorded corpus every build.
///
/// Named bug this catches: somebody replaces the declared origin with a sniffer
/// keyed on `model`, `turn_id` or `prompt_id`, and every session that ends
/// drives the wrong state machine. Those three keys look like reliable
/// discriminators on four of the six events. They are absent from exactly the
/// payload this check reads.
@Test func noPayloadKeyCanTellCodexFromClaudeCode() throws {
    let codex = try keys("codex-hooks", "session-end.json")
    let claude = try keys("claude-hooks", "session-end.json")

    #expect(!codex.isEmpty, "the Codex SessionEnd fixture is empty; this cannot discriminate")
    #expect(codex.isSubset(of: claude),
            "the recorded Codex SessionEnd keys \(codex.sorted()) are no longer a subset of the Claude Code ones \(claude.sorted())")

    // The two keys a sniffer would reach for, absent from the payload above.
    for key in ["model", "turn_id"] {
        #expect(!codex.contains(key),
                "\(key) is present on the Codex SessionEnd after all; re-examine the sniffing option")
    }
}

/// Cursor IS separable by envelope — and that is still not how it is decided.
///
/// This records the asymmetry honestly. `cursor_version` is on all six recorded
/// Cursor payloads and on none of the other twelve, so a sniffer would work for
/// Cursor. It is not used, because an origin rule that is declared for two tools
/// and sniffed for the third has two failure modes instead of one.
@Test func cursorWouldBeSeparableByEnvelopeButIsStillDeclared() throws {
    let cursor = try keys("cursor-hooks", "session-start.json")
    let claude = try keys("claude-hooks", "session-start.json")
    #expect(cursor.contains("cursor_version"))
    #expect(!claude.contains("cursor_version"))

    // Declared anyway. The endpoint is what decides.
    #expect(AgentTool.declared(byEndpoint: AgentTool.cursor.ingestEndpoint) == .cursor)
}

// MARK: - The endpoint each tool declares itself with

@Test func theLegacyEndpointMeansClaudeCode() {
    // Every hook already pasted into a user's settings file posts to this exact
    // path. It has to keep meaning Claude Code, or an upgrade silently retags
    // every existing session.
    #expect(AgentTool.declared(byEndpoint: "/event") == .claudeCode)
    #expect(AgentTool.claudeCode.ingestEndpoint == "/event")
}

@Test func eachToolHasItsOwnEndpoint() {
    #expect(AgentTool.declared(byEndpoint: "/event/codex") == .codex)
    #expect(AgentTool.declared(byEndpoint: "/event/cursor") == .cursor)
}

@Test func everyToolRoundTripsThroughItsEndpointAndNoTwoShareOne() {
    // Named bug this catches: a new tool added to `AgentTool` with a copied
    // endpoint literal, which routes its events to the other tool's state
    // machine. A `switch` returning the same string twice is invisible to a
    // per-case check.
    var seen: [String: AgentTool] = [:]
    for tool in AgentTool.allCases {
        let endpoint = tool.ingestEndpoint
        #expect(seen[endpoint] == nil,
                "\(tool.rawValue) and \(seen[endpoint]?.rawValue ?? "?") share the endpoint \(endpoint)")
        seen[endpoint] = tool
        #expect(AgentTool.declared(byEndpoint: endpoint) == tool,
                "\(endpoint) does not resolve back to \(tool.rawValue)")
    }
    #expect(seen.count == AgentTool.allCases.count)
}

@Test func anUndeclaredEndpointResolvesToNoToolAtAll() {
    // Fail CLOSED. Guessing a default here is exactly the defect this whole
    // mechanism exists to remove: a typo in a pasted hook command would mint
    // sessions under the wrong tool for ever, and nothing would report it.
    for path in ["/", "/event/", "/events", "/event/claude", "/hook",
                 "/event/CODEX", "", "/event/codex/extra"] {
        #expect(AgentTool.declared(byEndpoint: path) == nil,
                "\(path) resolved to a tool; unknown endpoints must be refused")
    }
}

/// The endpoint constant and the command the docs tell users to paste.
///
/// Named bug this catches: the endpoint changed in code while
/// `docs/QUICKSTART.md` keeps telling users to post somewhere else. Every hook
/// pasted from the page would then be refused, and no test in the suite could
/// see it — the ingest tests build their own requests.
@Test func theDocumentedHookCommandPostsToTheLegacyEndpoint() throws {
    let quickstart = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "docs/QUICKSTART.md")
    let text = try String(contentsOf: quickstart, encoding: .utf8)

    let documented = "http://localhost\(AgentTool.claudeCode.ingestEndpoint)"
    #expect(text.contains(documented),
            "docs/QUICKSTART.md never posts to \(documented)")

    // Anti-vacuity: the page really does carry curl hook commands, so the check
    // above is reading the block it thinks it is.
    let posts = text.components(separatedBy: "http://localhost").count - 1
    #expect(posts >= 5, "found \(posts) hook URLs in the quick start; expected the five required events")
}
