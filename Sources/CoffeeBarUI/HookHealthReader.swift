// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoffeeBarCore

/// What `ServingModel` needs from a hook-health source.
///
/// A protocol so a check can inject a source whose two reads DISAGREE, which is
/// the only way to prove `ServingModel.hookHealth` is DERIVED from the
/// collection rather than read a second time. A guard driven by real files
/// cannot see that bug: both reads land microseconds apart against one
/// unchanging file, so they agree even when the model is wrong.
///
/// It also puts this type beside the four `ServingModel` seams that were
/// already protocols — the assertion holder, the power reader, the ingest
/// listener and the settings store. `HookHealthReader` was the one concrete
/// dependency left. None of the four is named in code or in prose here, because
/// a boundary check in `AppLayerBoundary_test.swift` reserves the holder's type
/// names to `ServingModel.swift` and reads this file RAW, comments included.
/// That check is right to, so this comment works around it rather than the
/// other way about.
public protocol HookHealthProviding: Sendable {
    /// Claude Code's verdict, or `.unreadable` when this source has no Claude
    /// Code file. No existence gate: an absent file still reaches `.unreadable`,
    /// because that user is the first-run user the advisory exists for.
    func status() -> HookHealthStatus
    /// Every tool this source has something to say about, given the tools the
    /// user says they run.
    ///
    /// **`selected` widens what is read; it never narrows it.** A tool the user
    /// named is reported on whether or not its file is there — that user is
    /// mid-setup and the advisory is for them — and a tool they did not name is
    /// still reported on when its file IS there, because the file is evidence
    /// and throwing it away would silence every user who has never opened
    /// Preferences. Deciding what to SAY out of what is reported is
    /// `ServingModel.hookAdvisory`'s job, one layer up, where the user's choice
    /// lives.
    func statuses(advising selected: Set<AgentTool>) -> [AgentTool: HookHealthStatus]
}

extension HookHealthProviding {
    /// Every tool this source has something to say about when nobody has named
    /// any: the tools whose hook file is on disk, and nothing else.
    ///
    /// A convenience over the requirement above rather than a second
    /// requirement, deliberately. Written the other way about — a defaulted
    /// `statuses(advising:)` forwarding to a required `statuses()` — a
    /// conformer that implemented only the second would ignore the user's
    /// selection silently, which is the trap this file's own history is full
    /// of.
    public func statuses() -> [AgentTool: HookHealthStatus] { statuses(advising: []) }
}

/// Reads each agent tool's hook file and reports whether our hooks are
/// installed in it.
///
/// **One file per tool, and each is parsed in its own shape.** Until issue #10c
/// this read `~/.claude/settings.json` alone and filtered the Claude Code event
/// list whatever tool the user ran, so a Codex user and a Cursor user were both
/// told to paste PascalCase Claude Code entries into a file their tool never
/// reads. `HookHealth.settingsPath(for:)` now says where each file lives and
/// `HookHealth.status(of:for:)` says how to read it.
///
/// **This type only ever reads.** Design §6 forbids putting bytes into these
/// files: each is shared territory, and this workspace records a critical
/// six-occurrence last-writer-wins clobber pattern in exactly one of them.
/// coffee-bar prints the snippet for the user to paste, and reads the file back
/// so a clobbered snippet becomes visible failure rather than silent failure.
///
/// Two checks hold that line, from two directions —
/// `readingTheStatusLeavesTheFileExactlyAsItWas` runs this type and compares
/// the bytes on disk, and `noSourceFileThatKnowsTheSettingsPathCanWriteToIt`
/// reads this source for any call that puts bytes on disk.
/// `readingEveryToolsStatusLeavesEveryFileExactlyAsItWas` extends the first to
/// all three files.
///
/// **It reads only the files it was GIVEN.** Every read goes through
/// `hookFiles`, so a reader built for one tool cannot reach another tool's file
/// or the machine's real home directory. That is what keeps a check driven by a
/// fixture from quietly reading the developer's own configuration.
///
/// **What it can and cannot see.** `.wired` means the entries are in the file.
/// It does NOT mean an event has ever arrived: PE finding B2 measured a second
/// app instance stealing the socket path, after which ingest is dead and this
/// file is untouched. A live-socket probe is the separate check that would
/// close that gap.
///
/// Design §8 puts the file read in `CoffeeBarIngest`, so that `CoffeeBarCore`
/// keeps its no-I/O rule. This landed first, before that target existed, and
/// `CoffeeBarUI` is the nearest home that keeps the pure parse in
/// `CoffeeBarCore` — `ServingModel`, the one caller, lives here.
///
/// `CoffeeBarIngest` exists now, and both targets are in the app layer, so the
/// move is a file move and a module change with no behaviour in it. It is
/// DEFERRED rather than done: it buys no correctness, and both directories are
/// scanned by `AppLayerBoundary_test.swift` either way.
public struct HookHealthReader: HookHealthProviding {
    /// The hook file this reader inspects for each tool it covers.
    ///
    /// A map and not three stored properties, because ABSENCE FROM IT is
    /// meaningful: a reader built for Claude Code alone must not reach the
    /// machine's real `~/.codex/hooks.json`. Every check that injects a fixture
    /// would otherwise read the developer's own configuration, pass on a laptop
    /// with no Codex installed and fail on one that has it.
    /// `aReaderBuiltForClaudeCodeAloneReadsNoOtherToolsFile` holds that line.
    public let hookFiles: [AgentTool: URL]

    /// Covers all three tools. `HookHealth.settingsPath(for:)` is the one place
    /// that says where each file lives.
    public init(hookFiles: [AgentTool: URL] = HookHealthReader.defaultHookFiles) {
        self.hookFiles = hookFiles
    }

    /// A Claude-Code-ONLY reader.
    ///
    /// No default argument, so `HookHealthReader()` still resolves to the
    /// three-tool initialiser above.
    public init(settingsURL: URL) {
        self.init(hookFiles: [.claudeCode: settingsURL])
    }

    /// Where each tool keeps its hook file on this machine.
    public static var defaultHookFiles: [AgentTool: URL] {
        var found: [AgentTool: URL] = [:]
        for tool in AgentTool.allCases { found[tool] = defaultURL(for: tool) }
        return found
    }

    /// Design §6 fixes the Claude Code location; the other two were measured off
    /// the running tools. This is the ONLY place a home directory is resolved.
    public static func defaultURL(for tool: AgentTool) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: HookHealth.settingsPath(for: tool))
    }

    /// Design §6 fixes the location.
    public static var defaultSettingsURL: URL { defaultURL(for: .claudeCode) }

    /// Where Claude Code's settings file lives for this reader, or the design §6
    /// default when this reader does not cover Claude Code at all.
    ///
    /// Kept as a named property because `theDefaultSettingsURLIsTheUsersClaudeSettings`
    /// pins it, and because `noSourceFileThatKnowsTheSettingsPathCanWriteToIt`
    /// finds this file through the name.
    ///
    /// **The fallback IS reachable, and no read goes through it.** An earlier
    /// version of this comment claimed both initialisers always supply a Claude
    /// Code entry, so the fallback could never fire. That was FALSE:
    /// `init(hookFiles:)` is public and takes any map, and this branch's own
    /// `aToolWithNoFileOnDiskGetsNoVerdictAtAll` builds a reader from `.codex`
    /// and `.cursor` alone.
    ///
    /// It once mattered. `status()` read this property, so a reader covering no
    /// Claude Code file opened the machine's REAL `~/.claude/settings.json` and
    /// returned a verdict about a file nobody had asked it to read. `status()`
    /// now reads `hookFiles` directly, so this property reports a LOCATION and
    /// nothing opens a file through it.
    public var settingsURL: URL {
        hookFiles[.claudeCode] ?? HookHealthReader.defaultSettingsURL
    }

    /// Claude Code's verdict, or `.unreadable` when this reader has no Claude
    /// Code file.
    ///
    /// Never throws. An absent file, a directory, a permission refusal and a
    /// half-saved file all reach the panel as `.unreadable`, because none of
    /// them is evidence that the entries are gone. A reader that covers no
    /// Claude Code file reaches the same verdict, for the same reason: it has
    /// seen nothing that says the entries are gone.
    ///
    /// **It reads `hookFiles`, never `settingsURL`.** Going through that
    /// property let a Codex-only reader fall back to the machine's real home
    /// file, which is the machine-dependent read the `hookFiles` comment above
    /// exists to prevent. No production path called it, so nothing shipped
    /// wrong; it was a trap laid for the next caller.
    /// `statusReadsThisReadersOwnFileAndNeverTheRealHomeOne` holds the line.
    ///
    /// **It applies NO existence gate, and since issue #51 that is a real
    /// difference from `status(for:advising:)` rather than the agreement an
    /// earlier version of this comment recorded.** That one now asks whether the
    /// user named the tool; this one has nowhere to be told, so it answers about
    /// the file it holds whether or not the file is there.
    ///
    /// Nothing in the product reads this property — `ServingModel.hookHealth` is
    /// derived from the collection — so the difference costs no user anything.
    /// It is stated because a caller who reached for this one expecting the
    /// gated answer would get a verdict about a tool the user does not run.
    public func status() -> HookHealthStatus {
        guard let url = hookFiles[.claudeCode] else { return .unreadable }
        return HookHealth.status(ofSettings: try? Data(contentsOf: url))
    }

    /// What `tool`'s hook file says, or `nil` when there is nothing to say.
    ///
    /// `nil` means this reader does not cover the tool, or nothing says the user
    /// runs it: **the user did not name it and its file is not on disk**. So a
    /// Claude-Code-only user is never told to wire Cursor.
    ///
    /// **TWO signals, and the user's own is the strong one.** An absent file
    /// carries a different meaning depending on what the user has said:
    ///
    /// - They NAMED the tool. No file means "not set up yet", which is the
    ///   first-run state and the one the advisory was written for. The README
    ///   tells the reader coffee-bar does nothing until those hooks exist, so
    ///   this user needs the advice most — and the first round of issue #10c
    ///   gated them into silence.
    /// - They did NOT name it. No file means "does not run this tool", and
    ///   advising that user is the noise issue #10c set out to remove.
    ///
    /// The file being there is still evidence in its own right, which is why
    /// this is an `||` and not a replacement. A user who has never opened
    /// Preferences has named nothing, and coffee-bar has to keep working for
    /// them: `ServingModel` decides what an empty answer means, and this reader
    /// only ever reports what it can see.
    ///
    /// **`.claudeCode` gets NO special treatment here, and issue #51 is why.**
    /// This branch used to read `tool == .claudeCode || fileExists`, standing in
    /// for a question nobody had asked the user: which tools do you run. The
    /// exemption bought the first-run user their advisory and charged a
    /// Codex-only user a line about `~/.claude/settings.json` they could do
    /// nothing with. Now that the user can answer, the answer is the signal, and
    /// the same protection reaches a first-run CODEX user the exemption never
    /// covered.
    ///
    /// The gate is never "has this tool ever posted an event". That rule is
    /// circular: a tool with no hooks wired never posts, so it would never be
    /// advised, and the advisory exists for exactly that user.
    ///
    /// `.unreadable` stays reserved for a file this app could not parse, whether
    /// it is absent or malformed. It never tells the user to paste entries that
    /// may already be there, which is how a shared settings file gets clobbered.
    ///
    /// The default is NOBODY named, which is the pure existence gate. It is the
    /// honest default for a lookup with no context — every caller that HAS the
    /// user's answer passes it.
    public func status(for tool: AgentTool,
                       advising selected: Set<AgentTool> = []) -> HookHealthStatus? {
        guard let url = hookFiles[tool] else { return nil }
        guard selected.contains(tool)
                || FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return HookHealth.status(of: try? Data(contentsOf: url), for: tool)
    }

    /// Every tool the user named or has a hook file for, with what that file
    /// says.
    ///
    /// This is what the panel reads. Assigning a `nil` through a dictionary
    /// subscript REMOVES the key, so the tools `status(for:advising:)` had
    /// nothing to say about are simply absent — which is the claim the panel
    /// needs.
    public func statuses(advising selected: Set<AgentTool>) -> [AgentTool: HookHealthStatus] {
        var found: [AgentTool: HookHealthStatus] = [:]
        for tool in AgentTool.allCases {
            found[tool] = status(for: tool, advising: selected)
        }
        return found
    }
}
