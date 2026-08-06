// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

// `HookSnippet` is what the Preferences window's "Copy hook snippet" button puts
// on the pasteboard. These checks PARSE the snippet and assert on its structure
// rather than searching the text for substrings, because a snippet can name
// every required event, be valid JSON, carry our socket path, and still be inert
// in the tool that reads it.
//
// That is not hypothetical. A Codex config merged WITHOUT `"matcher": "*"` on
// the two tool events was measured dead for a full day while the panel reported
// it wired — issue #55. `HookHealth` cannot see that fault: it reads the command
// and ignores the matcher. So the ONLY place a dropped matcher can be caught is
// here, on the writing side.
//
// Every expectation is a literal or comes from `HookHealth` and `AgentTool`.
// Nothing here recomputes what `HookSnippet` computes.

// MARK: - Reading the snippet back

/// The snippet for `tool`, parsed.
///
/// Throws on a `nil` snippet rather than returning one. A `guard … else
/// { continue }` over three tools skips the body and reads as success, which is
/// exactly how a generator that stopped producing anything would pass.
private func snippetObject(_ tool: AgentTool) throws -> [String: Any] {
    let text = try #require(HookSnippet.json(for: tool),
                            "\(tool) has a required-event list but no snippet to paste")
    let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8))
    return try #require(parsed as? [String: Any],
                        "\(tool) snippet is JSON but not an object; a reader merging it gets a broken settings file")
}

/// The `hooks` object inside `tool`'s snippet.
private func hooksObject(_ tool: AgentTool) throws -> [String: Any] {
    let root = try snippetObject(tool)
    return try #require(root["hooks"] as? [String: Any],
                        "\(tool) snippet has no `hooks` object; HookHealth reports .missing over it")
}

/// Every command string in `tool`'s snippet, whichever shape it takes.
///
/// Walks both nestings so one helper serves all three tools, and so a snippet
/// that silently changed shape yields its commands anyway rather than yielding
/// an empty list the caller would read as nothing to check.
private func commands(in tool: AgentTool) throws -> [String] {
    let hooks = try hooksObject(tool)
    var found: [String] = []
    for (_, entry) in hooks {
        guard let elements = entry as? [[String: Any]] else { continue }
        for element in elements {
            if let command = element["command"] as? String { found.append(command) }
            if let inner = element["hooks"] as? [[String: Any]] {
                found += inner.compactMap { $0["command"] as? String }
            }
        }
    }
    return found
}

/// The events Claude Code and Codex run only with a `matcher`.
///
/// A LITERAL here, deliberately. `HookSnippet` owns a set of the same name, and
/// reading it would compare the implementation against itself. `docs/QUICKSTART.md`
/// states this pair: "The two tool events take `"matcher": "*"`; the other three
/// take no matcher."
private let toolEvents: Set<String> = ["PostToolUse", "PreToolUse"]

/// The tools whose hook file uses Claude Code's nesting. Codex shares it exactly,
/// `matcher` key and all — `HookHealth.HookNesting.nested` records the capture.
private let nestedTools: [AgentTool] = [.claudeCode, .codex]

// MARK: - The events come from the checker, not from a literal

@Test(arguments: AgentTool.allCases)
func theSnippetWiresExactlyTheEventsTheCheckerLooksFor(_ tool: AgentTool) throws {
    // Named bug this catches: a hardcoded snippet wiring five events while
    // `requiredEvents(for:)` looks for six, or Claude Code's PascalCase names
    // handed to a Cursor user. The health check then reports broken for ever
    // with nothing the user can paste to clear it.
    //
    // Set EQUALITY and not containment. A snippet carrying the required events
    // plus three more sends the user to wire entries their tool may never send,
    // which is the same unclearable fault from the other direction.
    let required = try #require(HookHealth.requiredEvents(for: tool))
    let hooks = try hooksObject(tool)

    #expect(Set(hooks.keys) == Set(required),
            "\(tool) snippet wires \(hooks.keys.sorted()); the checker requires \(required.sorted())")
}

// MARK: - The matcher: present on two events, ABSENT on the rest

@Test(arguments: nestedTools)
func theTwoToolEventsCarryAMatcherAndTheOthersCarryNoMatcherKey(_ tool: AgentTool) throws {
    // Issue #55, on the writing side. A Codex config merged without
    // `"matcher": "*"` on `PreToolUse` and `PostToolUse` ran nothing for a full
    // day while the panel reported it wired, because `HookHealth` reads the
    // command and never the matcher.
    //
    // Named bug this catches, in both directions: dropping the matcher from the
    // tool events, which makes the pasted hook inert; and adding one to the
    // lifecycle events, which is not what either tool was measured to accept.
    let hooks = try hooksObject(tool)
    var matched = 0
    var bare = 0

    for (event, entry) in hooks {
        let groups = try #require(entry as? [[String: Any]],
                                  "\(tool) \(event) is not an array of objects")
        let group = try #require(groups.first, "\(tool) \(event) has no entry to paste")

        if toolEvents.contains(event) {
            #expect(group["matcher"] as? String == "*",
                    """
                    \(tool) \(event) carries matcher \
                    \(String(describing: group["matcher"])). Without "*" the tool \
                    runs this hook for nothing and the panel still reports wired (#55).
                    """)
            matched += 1
        } else {
            #expect(group["matcher"] == nil,
                    "\(tool) \(event) carries a matcher key; the lifecycle events take none")
            bare += 1
        }
    }

    // The count guard is not decoration. A loop over a renamed or empty key set
    // asserts nothing at all and reads as success.
    #expect(matched == 2, "\(tool) snippet has \(matched) matcher-bearing events, expected 2")
    #expect(bare == 3, "\(tool) snippet has \(bare) matcher-free events, expected 3")
}

@Test(arguments: nestedTools)
func theNestedShapePutsTheCommandUnderAnInnerHooksArray(_ tool: AgentTool) throws {
    // Named bug this catches: emitting Cursor's flat element for Claude Code or
    // Codex. `HookHealth.isWired` casts the entry, looks for an inner `hooks`
    // key, finds none, and reports every event missing — so the user pastes what
    // the button gave them and the panel repeats the same complaint.
    let hooks = try hooksObject(tool)
    var checked = 0

    for (event, entry) in hooks {
        let groups = try #require(entry as? [[String: Any]])
        let group = try #require(groups.first, "\(tool) \(event) has no entry")
        let inner = try #require(group["hooks"] as? [[String: Any]],
                                 "\(tool) \(event) has no inner hooks array; the nested reader sees nothing wired")
        let handler = try #require(inner.first, "\(tool) \(event) has an empty inner hooks array")

        #expect(handler["type"] as? String == "command",
                "\(tool) \(event) declares type \(String(describing: handler["type"])); neither tool has an HTTP handler")
        #expect(handler["command"] is String, "\(tool) \(event) has no command string")
        checked += 1
    }

    #expect(checked == 5, "\(tool) snippet has \(checked) events, expected 5")
}

// MARK: - Cursor nests one level less

@Test func theCursorSnippetIsFlatWithNoMatcherAndNoTypeKey() throws {
    // Cursor's file is `hooks.<event>[].command` — the command sits DIRECTLY on
    // the element. `HookHealth`'s flat reader accepts nothing else, and
    // `theNestedShapeIsNotAcceptedForCursor` pins that from the reading side.
    //
    // Named bug this catches: giving a Cursor user Claude Code's nesting. Cursor
    // runs nothing, and the panel reports the very fault the user just tried to
    // clear.
    let hooks = try hooksObject(.cursor)
    #expect(hooks.count == 5, "the cursor snippet wires \(hooks.count) events, expected 5")

    for (event, entry) in hooks {
        let elements = try #require(entry as? [[String: Any]],
                                    "cursor \(event) is not an array of objects")
        let element = try #require(elements.first, "cursor \(event) has no entry")

        #expect(element["command"] is String,
                "cursor \(event) has no command on the element itself")
        #expect(Set(element.keys) == ["command"],
                """
                cursor \(event) carries \(element.keys.sorted()). Cursor takes the \
                command alone: a `type` key, an inner `hooks` array or a `matcher` \
                is Claude Code's shape, which Cursor does not read.
                """)
    }
}

// MARK: - What the user actually pastes

@Test(arguments: AgentTool.allCases)
func theSnippetIsValidJSONWithNothingBesideTheHooksObject(_ tool: AgentTool) throws {
    // The button writes this to the pasteboard and the user merges it by hand.
    // Anything at the root beside `hooks` would be pasted into a settings file
    // that never asked for it.
    let root = try snippetObject(tool)
    #expect(Set(root.keys) == ["hooks"],
            "\(tool) snippet's root carries \(root.keys.sorted()); only `hooks` belongs in a fragment")
}

@Test(arguments: AgentTool.allCases)
func everySnippetCarriesAMarkerTheCheckerRecognises(_ tool: AgentTool) throws {
    // A snippet the checker cannot recognise leaves the user correctly wired and
    // still reported broken. Asserted on every command rather than on the text
    // once: one recognisable command among five would pass a text search and
    // leave four events reported missing.
    let found = try commands(in: tool)
    #expect(found.count == 5, "\(tool) snippet holds \(found.count) commands, expected 5")

    for command in found {
        #expect(HookHealth.commandMarkers.contains { command.contains($0) },
                "\(tool) command is not one HookHealth recognises: \(command)")
    }
}

@Test(arguments: AgentTool.allCases)
func everyCommandIsTheCurlFormAndNamesNoUninstalledBinary(_ tool: AgentTool) throws {
    // **`HookHealth` cannot be relied on for this one, and that is the point.**
    // `HookHealth.commandMarkers` accepts `shimCommandName` as well as the socket
    // path, so a snippet whose command is `coffeebar-hook …` satisfies the
    // checker completely — and nothing installs that binary on a `PATH`.
    // `everySnippetCarriesAMarkerTheCheckerRecognises` above passes over exactly
    // that snippet. So does the round trip. The command FORM has no reader-side
    // guard anywhere, which leaves this the only place it can be pinned.
    //
    // Named bug this catches: somebody later swaps the shim back in, or renames
    // a flag. Every other check stays green, the panel reports `.wired`, and
    // every user who clicks Copy pastes a command that cannot run.
    //
    // Pinned in three pieces rather than as `contains("curl")`, because the
    // requirement is the command's FORM: a snippet that merely mentions `curl`
    // somewhere while transporting over the wrong flag posts nothing at all.
    let found = try commands(in: tool)
    #expect(found.count == 5, "\(tool) snippet holds \(found.count) commands, expected 5")

    for command in found {
        #expect(command.hasPrefix("curl "),
                "\(tool) runs \(command.prefix(40))…; the snippet must invoke curl")

        #expect(!command.contains(HookHealth.shimCommandName),
                """
                \(tool) command names \(HookHealth.shimCommandName), which nothing \
                installs on a PATH. HookHealth accepts it as a marker, so the panel \
                would report .wired over a command the user cannot run.
                """)

        // `range(of:)` and not `contains`: a renamed flag has to fail to RESOLVE
        // here rather than be satisfied by the socket path appearing elsewhere
        // in the line.
        let flag = "--unix-socket "
        let range = try #require(command.range(of: flag),
                                 "\(tool) command carries no \(flag)argument: \(command)")
        #expect(command[range.upperBound...]
                    .hasPrefix("\"$HOME/Library/Application Support/coffee-bar/ingest.sock\""),
                "\(tool) passes something other than the quoted socket path to \(flag)")
    }
}

@Test(arguments: AgentTool.allCases)
func noSnippetCarriesAnAbsoluteHomePath(_ tool: AgentTool) throws {
    // `CoffeeBarCore` does no I/O and resolves no home directory (design §8). A
    // literal `/Users/…` in a snippet is also a path that is wrong on every
    // machine but the one that generated it, and a tracked file carrying one
    // turns `noTrackedFileCarriesLiveSessionProse` red.
    let text = try #require(HookSnippet.json(for: tool))
    #expect(!text.contains("/Users/"), "\(tool) snippet carries an absolute home path")
    #expect(text.contains("$HOME"), "\(tool) snippet does not defer the home directory to the shell")
}

// MARK: - The endpoint declares the origin

/// The ingest endpoint one command posts to, read out of the command STRING.
///
/// Read rather than taken from `tool.ingestEndpoint`: the subject is what the
/// user pastes, and asking the constant would compare it against itself.
private func declaredEndpoint(in command: String) throws -> String {
    let url = try #require(command.split(separator: " ").last.map(String.init),
                           "the command is empty")
    let prefix = "http://localhost"
    #expect(url.hasPrefix(prefix), "the command's last token is not an ingest URL: \(url)")
    return String(url.dropFirst(prefix.count))
}

@Test(arguments: AgentTool.allCases)
func eachToolsCommandDeclaresThatToolsOwnOrigin(_ tool: AgentTool) throws {
    // Named bug this catches: every tool posting to `http://localhost/event`.
    // That is Claude Code's endpoint, so every Codex and Cursor session is filed
    // as a Claude Code session — silently, because a payload cannot say which
    // agent produced it (`AgentTool`'s own comment measured that) and because
    // `HookHealth` matches the socket path in the command, never the URL. The
    // panel reports `.wired` over a snippet that misattributes every session.
    let found = try commands(in: tool)
    #expect(found.count == 5, "\(tool) snippet holds \(found.count) commands, expected 5")

    for command in found {
        let endpoint = try declaredEndpoint(in: command)
        #expect(AgentTool.declared(byEndpoint: endpoint) == tool,
                """
                \(tool) snippet posts to \(endpoint), which \
                AgentTool.declared(byEndpoint:) resolves to \
                \(String(describing: AgentTool.declared(byEndpoint: endpoint))). \
                Sessions wired from this snippet are filed under the wrong tool.
                """)
    }
}

// MARK: - The generator and the checker agree

@Test(arguments: AgentTool.allCases)
func theCheckerReportsOurOwnSnippetAsWired(_ tool: AgentTool) throws {
    // THE round trip. The fixture is the GENERATOR'S OUTPUT and not a literal: a
    // literal would only prove somebody typed the shape `HookHealth` wanted,
    // which the committed `wired.json` fixtures already prove.
    //
    // If the generator and the checker disagree, one of them is wrong, and this
    // is the check that says so. Named bug: the button hands the user a snippet
    // they paste correctly and the panel goes on reporting the install as
    // incomplete, which is the silent failure design §6 exists to remove.
    let text = try #require(HookSnippet.json(for: tool))
    let verdict = HookHealth.status(of: Data(text.utf8), for: tool)

    #expect(verdict == .wired,
            "pasting our own \(tool) snippet reports \(String(describing: verdict))")
}
