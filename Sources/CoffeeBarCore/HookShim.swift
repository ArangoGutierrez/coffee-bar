// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The pure half of the `coffeebar-hook` shim.
///
/// **Why it is here and not in the executable.** `Package.swift` records the
/// constraint at the `CoffeeBarUI` target: SwiftPM treats an executable
/// target's `main.swift` as top-level code, which a test target cannot import.
/// Everything in this file would otherwise be untestable, so the socket work
/// stays in `Sources/CoffeeBarShim/main.swift` and the byte-level decisions
/// live here.
///
/// **It respects `CoffeeBarCore`'s no-I/O rule.** Turning a tool and a body
/// into the bytes of one POST is a pure function. Nothing here opens, reads or
/// writes anything.
///
/// **The shim is a PIPE.** Design §7 and `SECURITY.md` put the privacy boundary
/// in the LISTENER, which drops the transcript path and the assistant reply at
/// the decode boundary. Nothing here parses the body, and nothing here may ever
/// log it: a diagnostic names the STATUS, never the payload.
public enum HookShim {

    /// Where a run with no `--tool` is attributed.
    ///
    /// `/event` is the endpoint every hook already installed posts to, and
    /// `AgentTool.declared(byEndpoint:)` sets out why that legacy path keeps
    /// meaning Claude Code. Defaulting anywhere else would retag the only
    /// cohort this product has.
    public static let defaultTool: AgentTool = .claudeCode

    /// How long `connect(2)` gets.
    ///
    /// 250 ms, the figure `docs/coffee-bar-HANDOFF.md` fixes for the shim.
    /// A local `AF_UNIX` connect either succeeds at once or fails at once, so
    /// this is a ceiling on a case that should not arise rather than a cost.
    public static let connectTimeout: TimeInterval = 0.25

    /// How long the WHOLE run gets, connect included.
    ///
    /// One second, chosen to sit between two numbers that are already fixed.
    /// It is an order of magnitude above the 50 ms budget the handoff states
    /// for the normal path, so no healthy post ever reaches it. It is an order
    /// of magnitude below `UnixSocketIngestListener.defaultIdleTimeout`, which
    /// is 10 s, so a listener that is bound but not being SERVED cannot hold
    /// the agent for its own timeout on every tool call.
    ///
    /// That middle case is the only real hang. A socket in the listen backlog
    /// accepts the connection and buffers the write, then answers nothing —
    /// measured in `IngestListener_test.swift`, where it held one test body for
    /// ever and took the whole run with it.
    public static let totalTimeout: TimeInterval = 1.0

    /// The environment variable that may change the budget above, in seconds.
    ///
    /// **What it can and cannot do, so the next reader need not re-derive it.**
    /// It buys TIME inside a process the invoking user already started with
    /// their own privileges, and nothing else. It cannot widen privilege, name a
    /// different destination — `--socket=` is the only thing that does that —
    /// change what is sent, or change what is said about it: the diagnostic
    /// still carries a status and never a payload. The one abuse worth bounding
    /// is the opposite of a leak, which is why `maximumTotalTimeout` exists: the
    /// shim runs on EVERY tool call, so a large value left in a shell profile
    /// would hold the agent up on all of them.
    ///
    /// Why it exists: `CoffeeBarHookShim_test.swift` runs the real binary
    /// against a real listener under a suite that oversubscribes the CPU, where
    /// 1 s is not always enough for a refusal to come back — issue #90. Moving
    /// the constant instead would have changed production to suit a test.
    ///
    /// `COFFEE_BAR_` is the prefix `COFFEE_BAR_VERSION` already established.
    public static let totalTimeoutVariable = "COFFEE_BAR_SHIM_TIMEOUT_SECONDS"

    /// The largest budget `totalTimeoutVariable` may buy.
    ///
    /// Five seconds: half of `UnixSocketIngestListener.defaultIdleTimeout`,
    /// which is 10 s. `totalTimeout` above sets out why the shim's give-up point
    /// has to sit BELOW the listener's, and that ordering has to survive the
    /// largest value a shell can ask for. Without a ceiling one stray variable
    /// would put the shim back to waiting out a wedged listener on every tool
    /// call, which is a worse fault than the flake this variable fixes.
    public static let maximumTotalTimeout: TimeInterval = 5.0

    /// The whole-run budget for a shim started with `environment`.
    ///
    /// Takes the environment rather than reading it: `CoffeeBarCore` opens
    /// nothing, and a resolver handed its input is one a table-driven test can
    /// cover without touching the process it runs in.
    ///
    /// Every reason to distrust the value ends in the same place, the shipped
    /// `totalTimeout`, and none of them says anything. The shim runs on every
    /// tool call, and a hook that complained about the user's shell would be
    /// worse than useless.
    ///
    /// **The bounds are stated as what a usable value IS, never as what a bad
    /// one is, and that is load-bearing.** `Double` parses `"nan"` and `"inf"`
    /// happily, and no comparison with NaN is true. Written the other way round
    /// — `if seconds <= 0 || seconds > maximumTotalTimeout { return totalTimeout }`
    /// — both of those tests are false for NaN, so NaN is not rejected: it
    /// reaches `Date.addingTimeInterval` and the deadline stops bounding
    /// anything. Written as a `guard` that must be satisfied, the same two
    /// comparisons refuse it, because false is the answer either way round.
    /// Measured, not reasoned about, and `"nan"` is a row in the table.
    ///
    /// That is also why there is no `isFinite` here. It would never change an
    /// answer — `inf > 0` is true but `inf <= maximumTotalTimeout` is not — and
    /// a condition that cannot change an answer reads like a guard without being
    /// one.
    public static func resolvedTotalTimeout(from environment: [String: String]) -> TimeInterval {
        guard let spelling = environment[totalTimeoutVariable],
              let seconds = Double(spelling.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds > 0,
              seconds <= maximumTotalTimeout
        else { return totalTimeout }
        return seconds
    }

    /// Where the ingest socket sits under `home`, per design §4.
    ///
    /// Takes the home directory rather than asking for it: `CoffeeBarCore` is
    /// Foundation-only, with no syscalls and no I/O, and the shim supplies the
    /// one value this needs.
    ///
    /// It is the SECOND copy of this tail — `UnixSocketIngestListener`
    /// computes the first — because the shim depends on `CoffeeBarCore` alone
    /// and cannot see the listener. `theShimAndTheListenerNameTheSameDefaultSocket`
    /// in `CoffeeBarIngestTests` is what stops the two drifting apart.
    public static func socketPath(inHome home: URL) -> String {
        home.appending(path: "Library/Application Support/coffee-bar/ingest.sock").path
    }

    /// The bytes of one POST, ready to write.
    ///
    /// `Connection: close` is what lets the caller read the answer to end of
    /// stream rather than parse a length out of it. `Content-Length` counts
    /// BYTES: `HTTPRequestFramer` takes exactly the declared count as the body,
    /// so a length measured in characters truncates any payload carrying
    /// multi-byte text — which agent payloads routinely do.
    public static func request(posting body: Data, as tool: AgentTool) -> Data {
        var request = Data("""
            POST \(tool.ingestEndpoint) HTTP/1.1\r
            Host: localhost\r
            Content-Type: application/json\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r

            """.utf8)
        request.append(body)
        return request
    }

    /// The status code on the first line of `response`, or `nil`.
    ///
    /// RFC 9112 §4 fixes the status line as version, code, reason. The version
    /// is checked and the code must be exactly three digits, so a reply that is
    /// not an HTTP answer yields nothing rather than a number read out of
    /// whatever arrived. `nil` matters most for the empty case: it is what a
    /// timed-out read returns, and inventing a code there would turn every lost
    /// answer into a silent success.
    public static func statusCode(inResponse response: Data) -> Int? {
        guard let text = String(data: response.prefix(256), encoding: .utf8),
              let line = text.split(separator: "\r\n", maxSplits: 1,
                                    omittingEmptySubsequences: false).first
        else { return nil }

        let fields = line.split(separator: " ", maxSplits: 2)
        guard fields.count >= 2, fields[0].hasPrefix("HTTP/") else { return nil }
        let code = fields[1]
        guard code.count == 3, code.allSatisfy(\.isNumber) else { return nil }
        return Int(code)
    }

    /// Whether `code` means the event was stored.
    ///
    /// Only 204. `IngestListener` answers 400, 404 and 413 for the three ways a
    /// post can be refused, and a `nil` code means no answer arrived at all —
    /// which is not a success either.
    public static func isSuccess(_ code: Int?) -> Bool { code == 204 }
}

// MARK: - Naming a tool on the command line

/// How the user names an agent tool to `coffeebar-hook`.
///
/// The endpoint is the wire-level declaration and stays as it is; this is the
/// human-facing spelling of the same choice. They are kept apart on purpose: a
/// URL path is not a thing to ask a user to type, and the two vocabularies can
/// then move independently.
extension AgentTool {

    /// The value after `--tool=`.
    ///
    /// A `switch` with no `default`, so a new `AgentTool` case fails to compile
    /// here rather than silently inheriting another tool's name.
    public var shimName: String {
        switch self {
        case .claudeCode: return "claude-code"
        case .codex: return "codex"
        case .cursor: return "cursor"
        }
    }

    /// The tool the user named, or `nil`.
    ///
    /// Matched exactly, for the reason `declared(byEndpoint:)` gives: an origin
    /// that is not recognised is refused rather than guessed at. Accepting a
    /// near miss would file one tool's session under another because of a typo,
    /// and the wrong state machine would then run with nothing to show for it.
    public static func declared(byShimName name: String) -> AgentTool? {
        allCases.first { $0.shimName == name }
    }
}
