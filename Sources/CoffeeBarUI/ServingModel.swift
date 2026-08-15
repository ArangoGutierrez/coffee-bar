// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import CoffeeBarCore
import CoffeeBarIngest
import CoffeeBarPower

// `import Observation` is required: the `@Observable` macro lives there. The
// POC got it transitively from `import SwiftUI` in the same file. This file
// has no SwiftUI import, so it must ask for Observation directly.

/// Wires the reader and the controller to the assertion.
///
/// This type holds no policy. It samples power, asks `HoldController` what the
/// state should be, and makes IOKit match. Every decision lives in
/// `CoffeeBarCore`.
@MainActor
@Observable
public final class ServingModel {
    private let holder: any AssertionHolding
    private let reader: any PowerReadingProviding
    private let health: any HookHealthProviding
    private let helper: any PrivilegedHelperStateProviding
    private let listener: any IngestListening
    private let settings: any SettingsStoring
    /// Where the published version manifest comes from (issue #29).
    ///
    /// A SEAM and not a call, for the reason every other dependency here is one:
    /// the real implementation reaches the project site, and a check that took
    /// it would post a request from whichever machine runs the suite — from a
    /// build server, from an aeroplane, from a laptop that never asked to.
    ///
    /// The model holds the protocol and never the fetcher's type, so this file
    /// stays out of the one place in this application allowed to name
    /// `URLSession`. `thePreferencesWindowNeverReachesTheNetworkItself` holds
    /// the same line one layer up.
    private let updates: any ReleaseManifestFetching
    private let policy: StalePolicy
    private let now: @Sendable () -> Date
    private var controller = HoldController()

    /// The composition root for process demotion, or `nil` to govern nothing.
    ///
    /// **The ONE seam on this type whose default is null rather than real, and
    /// the direction is the reason.** The listener's default is the real one
    /// because a null listener ships an app with no ingest and nothing to
    /// notice. Here the direction is inverted: a null governance ships an app
    /// that demotes nothing, which is this product's documented default and the
    /// safe answer. A real default would also point every check in this package
    /// at the user's own demotion journal and their own running applications,
    /// and no check may touch a process it does not own.
    ///
    /// The missing wire cannot ship silently.
    /// `theAppComposesTheProcessGovernanceAndRecoversAtLaunchAndOnQuit` reads
    /// `main.swift` for the construction and for the launch recovery.
    private let governance: ProcessGovernance?

    /// True once `startMonitoring` has started the listener successfully.
    ///
    /// The listener starts AT MOST ONCE per model. A second `start()` on the
    /// real listener throws `IngestError.alreadyServing` — it refuses a path it
    /// already answers on — so a repeat `startMonitoring` would otherwise leave
    /// the app with no ingest and an error nobody sees. Set only on success, so
    /// a refused socket can still be retried.
    @ObservationIgnored private var listenerStarted = false

    /// Every agent session ingest is tracking right now.
    ///
    /// This is the array `PowerBroker` reads, and design §14 requires the panel
    /// to name what is holding the machine awake FROM THIS ARRAY rather than
    /// from a second source that can disagree with the decision. Task 8 renders
    /// it.
    ///
    /// Internal, not `public`, for the reason `desired` is: the test target
    /// reaches it through `@testable import CoffeeBarUI`, and no production
    /// code outside this module reads it.
    private(set) var sessions: [AgentSession] = []

    /// The sessions blocked on the human, longest wait first.
    ///
    /// Recomputed in `refresh()` from `sessions`, never accumulated. A list
    /// built once when an event arrives would keep a crashed agent under
    /// "waiting on you" for the life of the process, because the stale timeout
    /// runs on the ticker and nothing else would ever revisit the row.
    public private(set) var attention: [AgentSession] = []

    /// The sessions holding the machine awake right now.
    ///
    /// Design §14 requires the panel to name what is causing a hold, FROM THIS
    /// ARRAY rather than from a second source that can disagree with the
    /// decision — so this is `AttentionList.working(from:)` over exactly the
    /// array handed to `evaluate` on the same line of `refresh()`.
    ///
    /// Internal: `workingSummary` below is what the panel renders, and nothing
    /// outside this module reads the sessions themselves.
    private(set) var working: [AgentSession] = []

    /// The repeating refresh installed by `startMonitoring`.
    ///
    /// Internal `private(set)` for the same reason `desired` is: the one thing
    /// worth asserting about this timer is that it is not still live after the
    /// model goes away, and a test cannot see that through a `private` handle.
    /// No production code outside this type reads it, so nothing here is
    /// `public`.
    @ObservationIgnored private(set) var timer: Timer?

    /// Whether an assertion is held right now. Reflects what actually happened,
    /// not what was asked for.
    public private(set) var isServing = false

    /// The newest power sample, for the panel's battery line.
    public private(set) var reading: PowerReading

    /// Why the hold is not running, when that reason is still true of the
    /// newest reading. `nil` otherwise — see `refresh()`.
    public private(set) var suppression: HoldSuppression?

    /// How a cancelled On click ended and where it left the control, when that
    /// cancel is still true of the newest reading. `nil` otherwise.
    ///
    /// Filtered ONCE in `refresh()`, against the same `suppression` above, so
    /// the claim has exactly the lifetime of the sentence that explains it. The
    /// two can never appear apart.
    ///
    /// Internal, not `public`, for the reason `desired` is: `suppressionAdvisory`
    /// is what the panel reads, and the test target reaches this through
    /// `@testable import CoffeeBarUI`. Design §5.4 asserts the reason on the
    /// enum, so this stays a `ServeCancellation` and not a rendered string.
    private(set) var cancelledServe: ServeCancellation?

    /// The state `refresh()` last reconciled to, or `nil` before the first
    /// `refresh()`.
    ///
    /// Exposed for the same reason `DesiredPowerState.displaySleepAssertion`
    /// exists at all: the "never hold the display awake" invariant is asserted
    /// on the decision object, so a change that starts asking for a display
    /// assertion has to set that field and goes red immediately.
    ///
    /// Internal, not `public`. No production code reads it — the test target
    /// gets at it through `@testable import CoffeeBarUI`, so widening the
    /// module's public surface for a test would buy nothing.
    private(set) var desired: DesiredPowerState?

    /// Whether the user's Claude Code hooks still point at our socket.
    ///
    /// `.unreadable` until the first `refresh()`, which is what "not read yet"
    /// looks like here. Nothing renders it before then: `PanelView.onAppear`
    /// calls `refresh()`, and the menu-bar label reads `isServing` only.
    ///
    /// **This is a statement about the settings FILE, not about ingest.** PE
    /// finding B2 measured a second app instance stealing the socket path,
    /// which kills ingest and leaves the settings file exactly as it was — so
    /// this stays `.wired` while no event can arrive. Whatever renders it must
    /// never claim events are flowing. `hookAdvisory` below renders NOTHING for
    /// `.wired`, which is the strongest form of that: a panel that says nothing
    /// cannot say something untrue.
    ///
    /// `ingestListening` is the OTHER half of that gap, and the two are kept
    /// apart deliberately. This one sees the user's settings and cannot see
    /// this process; that one sees this process and cannot see the settings.
    /// Merged into one claim, a wired settings file would hide a dead socket.
    ///
    /// DERIVED from `hookHealths`, never stored beside it. A second stored
    /// property fed by a second read would agree with the collection until it
    /// did not, the panel would render one while every existing check drove the
    /// other, and nothing could see the disagreement —
    /// `theClaudeCodeHealthTheModelPublishesIsTheOneInTheCollection` refuses it.
    ///
    /// `.unreadable` covers both "not read yet" and "no such file". Neither is
    /// evidence that the entries are gone, which is exactly what `.unreadable`
    /// means everywhere else in this type.
    public var hookHealth: HookHealthStatus {
        hookHealths[.claudeCode] ?? .unreadable
    }

    /// Every agent tool this machine has EVIDENCE for, with what that tool's
    /// hook file says about coffee-bar's entries.
    ///
    /// A tool is in this map when the user named it or when its hook file is on
    /// disk. It is absent when neither is true, and that is the claim the panel
    /// needs: nothing says the user runs it, so a Claude-Code-only user is never
    /// told to wire Cursor.
    ///
    /// **The user's choice does NOT narrow this map — it narrows `hookAdvisory`
    /// (issue #51).** Everything read is kept, so switching a tool back on says
    /// something immediately instead of waiting for the next read, and an
    /// unselected tool's evidence stays visible to a check.
    ///
    /// Empty until the first `refresh()`. Nothing renders it before then —
    /// `PanelView.onAppear` calls `refresh()`, and the menu-bar label reads
    /// `isServing` only.
    public private(set) var hookHealths: [AgentTool: HookHealthStatus] = [:]

    /// The agent tools the user chose in Preferences, or `nil` when they have
    /// never chosen (issue #51).
    ///
    /// **`nil` is a THIRD state and not a synonym for empty.** `[]` is a user
    /// who switched every tool off and asked for silence; `nil` is a user who
    /// has not been asked. They lead to opposite behaviour, and
    /// `SettingsKey.agentTools` carries the rest of that argument.
    ///
    /// Read ONCE in `init`, like the three settings below it and for the same
    /// reason: this app is the only writer, and re-reading the store on every
    /// 30-second `refresh()` would let an external edit move the user's control
    /// under them.
    public private(set) var selectedAgentTools: Set<AgentTool>?

    /// Which tools coffee-bar assumes when the user has never chosen.
    ///
    /// **`.claudeCode` and nothing else, and this constant IS the unset
    /// decision** — the hard-coded exemption that used to sit in
    /// `HookHealthReader.status(for:)`, restated in one named place the user can
    /// now override. It is what makes an unset key reproduce the behaviour that
    /// shipped before issue #51 exactly: Claude Code is spoken about with or
    /// without a file, every other tool only with one.
    ///
    /// Why Claude Code and not all three: an absent file means different things
    /// for different cohorts. Claude Code is the primary integration and the
    /// first-run path, and the README tells the reader coffee-bar does nothing
    /// until those hooks exist. Codex and Cursor are opt-in, and assuming them
    /// would hand every user two lines about files they do not have — the noise
    /// issue #10c removed.
    ///
    /// It is used for ONE thing: deciding which hook files are read even when
    /// they are not there. What is SAID is `advises(_:)` below.
    public static let assumedAgentTools: Set<AgentTool> = [.claudeCode]

    /// Whether coffee-bar speaks about `tool`.
    ///
    /// The window's checkbox and the panel's advisory are the same question, so
    /// they read the same answer. A window that showed one thing while the panel
    /// did another would be a settings screen the user cannot trust.
    ///
    /// **The unset branch is the second half of the issue #51 default**, and it
    /// is today's inference unchanged: coffee-bar speaks about a tool it found
    /// evidence for. `hookHealths` already holds exactly that — the tools whose
    /// file is on disk, plus `assumedAgentTools` — so an unset key narrows
    /// nothing and every existing user reads what they read yesterday.
    ///
    /// LIMIT, stated rather than hidden: before the first `refresh()` an unset
    /// model has no evidence and answers `false` for everything. Nothing renders
    /// this before then, for the reason `hookHealths` gives.
    public func advises(_ tool: AgentTool) -> Bool {
        if let chosen = selectedAgentTools { return chosen.contains(tool) }
        return hookHealths[tool] != nil
    }

    /// Records that the user does or does not run `tool`.
    ///
    /// **It freezes the whole answer, not the one tool it was handed.** Until
    /// the first call there is no stored selection at all, only an inference, so
    /// writing `[tool]` here would silently discard every other tool the user
    /// runs — switch Codex off and Claude Code goes with it. Building the set
    /// from `advises(_:)` writes down what the window was showing and then
    /// applies the one edit.
    ///
    /// The setter WRITES BEFORE it reconciles, like the three settings below: a
    /// crash between the two would lose a choice the user has already seen take
    /// effect. It reconciles at all because a user switching a tool off is
    /// asking for that advisory to go NOW, not at the next 30-second tick.
    public func setAdvises(_ advises: Bool, for tool: AgentTool) {
        var chosen = Set(AgentTool.allCases.filter { self.advises($0) })
        if advises { chosen.insert(tool) } else { chosen.remove(tool) }
        selectedAgentTools = chosen
        settings.setSelectedAgentTools(chosen)
        refresh()
    }

    /// What the tool selection is FOR, in one sentence above the rows.
    ///
    /// Here rather than in the window, for the reason `quietOthersLabel` is:
    /// design §5.4 rules out asserting on rendered AppKit text, so a sentence
    /// written in the view is a sentence no check reads.
    ///
    /// **It names no tool.** `AgentTool.allCases` is the one place that list
    /// lives, and a caption spelling it out would still say three when a fourth
    /// arrived, with nothing able to see it.
    ///
    /// It promises no installation either. Design §6 is print-never-touch for
    /// every one of these files, and the rows below offer a Copy button for
    /// exactly that reason.
    /// `theSelectionLabelNamesNoToolAndPromisesNoWriting` holds both halves.
    static let agentToolsLabel = "coffee-bar reports hook health for the tools selected here."

    /// What the root helper on this Mac is, relative to the one this build
    /// ships, or `nil` before anything has been read.
    ///
    /// **`nil` and not `.unverifiable`, and the two are different claims.**
    /// `.unverifiable` means the app looked and could not tell, which is a
    /// sentence the user is entitled to; `nil` means nothing has been asked yet.
    /// Defaulting to `.unverifiable` would put "coffee-bar cannot read its own
    /// copy" on the panel before a single read had happened — a fault reported
    /// with no evidence behind it, which is the failure this release exists to
    /// remove pointing the other way. `hookHealths` is empty until the first
    /// `refresh()` for the same reason.
    ///
    /// Nothing renders it before then: `PanelView.onAppear` calls `refresh()`,
    /// and the menu-bar label reads `isServing` only.
    public private(set) var helperState: PrivilegedHelperState?

    /// Whether this process is serving the ingest socket RIGHT NOW.
    ///
    /// Read off the listener on every `refresh()`, never remembered from the
    /// one `start()` call. A `start()` that returns without throwing has
    /// created an `NWListener`, not proved a bind: the bind lands
    /// asynchronously and can still fail, and `stop()` clears it again. A
    /// cached "started successfully" would be the same false claim in a new
    /// place.
    ///
    /// `false` until the first `refresh()`, which is what "not asked yet" looks
    /// like here — and it is the safe direction: the panel says the socket is
    /// not serving until something proves it is.
    public private(set) var ingestListening = false

    /// Why the socket was refused, when `startMonitoring` was told.
    ///
    /// Only `start()` reports a reason, so this is `nil` for a bind that
    /// reaches no `.ready` state on its own. `ingestAdvisory` therefore has to
    /// stand up without it.
    private var listenerRefusal: String?

    /// The one line the panel shows about that health, or `nil` for no line.
    ///
    /// Derived, not stored, so it cannot disagree with what was read. It reads
    /// `hookHealths` — the COLLECTION, not the `hookHealth` convenience above —
    /// so `@Observable` tracks it and the panel updates on the same 30-second
    /// refresh with no second timer.
    ///
    /// Naming the source exactly matters here. `hookHealth` carries a
    /// `?? .unreadable` fallback for the state before the first `refresh()`, and
    /// that fallback must never reach the panel as advice: it would print
    /// "cannot read" over a file nobody has tried to read yet. Reading the
    /// collection means an untouched model yields an EMPTY advisory rather than
    /// a false one. An earlier version of this comment claimed the property was
    /// derived from `hookHealth`, which was wrong once the collection landed.
    ///
    /// **`.wired` says nothing, and that is the honest answer rather than a
    /// terse one.** This check reads the settings FILE. It cannot see whether a
    /// single event has ever arrived — PE finding B2 measured a second app
    /// instance stealing the socket, which kills ingest and leaves the file
    /// untouched — so any line claiming ingest works would be a claim with no
    /// evidence behind it. A panel that announces its own health every time it
    /// opens is also noise the user learns to skip past.
    ///
    /// The two failing states are worded apart on purpose. `.missing` is
    /// evidence the entries are gone, so it names them and names the file.
    /// `.unreadable` is NOT that evidence — it is a file this app could not
    /// parse — so it must never tell the user to add entries that may already
    /// be there. That is how a shared settings file gets clobbered, which is
    /// the pattern design §6 exists to avoid.
    ///
    /// `HookHealth.status(of:for:)` never returns `.missing([])`: it reports
    /// `.wired` when nothing is missing. So no list below is ever empty.
    ///
    /// **One line per tool the user runs, in `AgentTool.allCases` order.** A
    /// property that returned only the first finding would drop two-thirds of
    /// the advice for a user who runs all three, and `PanelView` renders this
    /// verbatim so no check could see it happen. The order is fixed because a
    /// dictionary has none, and an order that reshuffled between refreshes would
    /// rewrite the panel every 30 seconds under a user trying to read it.
    ///
    /// **`advises(_:)` is what narrows it, and that is issue #51.** coffee-bar
    /// used to speak about every tool it found a file for, which handed a user
    /// advice about tools they do not run and cannot act on. The narrowing is
    /// applied HERE, to what is said, rather than to `hookHealths` — the
    /// evidence is worth keeping, and a user who switches a tool back on gets an
    /// answer without waiting for the next read.
    public var hookAdvisory: String? {
        let lines = AgentTool.allCases.compactMap { tool -> String? in
            guard advises(tool) else { return nil }
            return hookHealths[tool].flatMap { Self.advisory(for: tool, status: $0) }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
    }

    /// The line for ONE tool, or `nil` when that tool has nothing to report.
    ///
    /// It names the file it read, and it names that tool's OWN file: a Cursor
    /// user is sent to `~/.cursor/hooks.json`, never to `~/.claude/settings.json`.
    /// The path is the tool's canonical location rather than the URL the reader
    /// was handed, because that is the file every shipping configuration reads —
    /// an injected fixture path would name a file inside this repository.
    static func advisory(for tool: AgentTool, status: HookHealthStatus) -> String? {
        let file = "~/" + HookHealth.settingsPath(for: tool)

        switch status {
        case .wired:
            return nil
        case .missing(let events):
            // Names the FILE, and claims nothing about events arriving.
            let opening = "No coffee-bar hooks for \(events.joined(separator: ", ")) in \(file)."
            // The merge sentence is CLAUDE CODE ONLY, and that is a measurement
            // rather than a preference. Claude Code merges hooks from
            // ~/.claude/settings.json, a project's .claude/settings.json and
            // settings.local.json; this reader sees only the first. Measured
            // while writing this: the hooks actually capturing events on the
            // maintainer's machine were in the PROJECT file, so "Not receiving …"
            // was false there while 311 events had flowed — and it sent the user
            // to hand-edit the one file this design deliberately never writes.
            //
            // NOTHING equivalent was measured for Codex or for Cursor, so
            // repeating the sentence for them would invent a claim, in the one
            // place this product promises to tell the truth.
            // `onlyTheClaudeCodeLineMentionsAProjectSettingsFile` holds both
            // halves.
            guard tool == .claudeCode else { return opening }
            return opening + " If yours are in a project's .claude/settings.json, "
                 + "ingest may still be working."
        case .unreadable:
            return "Cannot read \(file), so coffee-bar cannot confirm its "
                 + "hooks are installed. Agent sessions may not arrive."
        }
    }

    /// The one line the panel shows about this process's own ingest socket, or
    /// `nil` for no line.
    ///
    /// A SEPARATE line from `hookAdvisory`, never merged with it. The two
    /// answer different questions from different evidence, and one combined
    /// "ingest is fine" would be a claim neither check can support: a wired
    /// settings file says nothing about whether this process holds the socket,
    /// which is PE finding B2 exactly.
    ///
    /// Silent while the socket is serving, for the reason `hookAdvisory` is
    /// silent on `.wired`: a panel that announces its own health every time it
    /// opens is noise the user learns to skip past, and then skips the line
    /// that mattered.
    ///
    /// It names the cause only when `start()` gave one. A bind that fails after
    /// `start()` returned reports no reason at all, so the first sentence has
    /// to stand on its own — and it does: it states what is not happening, and
    /// claims nothing about why.
    public var ingestAdvisory: String? {
        guard !ingestListening else { return nil }
        let opening = "coffee-bar is not listening for agent events, "
                    + "so no agent session can reach it."
        guard let refusal = listenerRefusal else { return opening }
        return "\(opening) \(refusal)"
    }

    /// The probe's product name, spelled once.
    ///
    /// `Package.swift` declares it and `scripts/build-app.sh` copies it into the
    /// bundle; `theLidClosedCommandNamesARealExecutableProduct` holds this
    /// against the manifest, so a rename that misses this line goes red.
    nonisolated public static let probeProductName = "coffee-bar-probe"

    /// Where a disk-image install puts the probe.
    ///
    /// **For DOCUMENTS, and for nothing that can ask a running process.** A page
    /// has to print one path, and this is the one a reader who downloaded the
    /// DMG will have. Anything with a `Bundle` in hand uses
    /// `probePath(besideExecutable:)` instead and gets the truth for that
    /// machine.
    ///
    /// The `CoffeeBar.app` spelling is `APP_NAME` in `scripts/build-app.sh`, and
    /// `theBundleTheScriptAssemblesCarriesTheProbe` pins the two together rather
    /// than trusting this line.
    nonisolated public static let documentedProbePath =
        "/Applications/CoffeeBar.app/Contents/MacOS/\(probeProductName)"

    /// The probe that sits beside `executable`.
    ///
    /// **Derived, because a literal is correct for one install out of four.**
    /// `scripts/build-app.sh` puts both binaries in the same `Contents/MacOS`,
    /// so the probe is always the app's own neighbour — and that holds wherever
    /// the app ended up. A hardcoded `/Applications` path is right for the disk
    /// image and wrong for a Homebrew prefix (`docs/QUICKSTART.md` states that
    /// Homebrew formulae do not write to `/Applications`), wrong for a
    /// `swift build` tree, and wrong for a copy dragged to the Desktop. Each of
    /// those users would be handed a path their shell cannot find.
    ///
    /// **PURE, and it touches no filesystem.** It composes a path and does not
    /// ask whether anything is there. A check that stat'd the disk would assert
    /// a different thing on every machine, and this is the seam a test has to be
    /// able to drive with a location that is not this one —
    /// `theProbePathIsDerivedFromTheBundleAndNotAHardcodedLiteral` drives four.
    ///
    /// The caller supplies the URL, mirroring
    /// `PanelView.versionLine(from: Bundle.main.infoDictionary)`: the view reads
    /// `Bundle.main`, the model stays pure. Reading `Bundle.main` in here would
    /// resolve to the TEST RUNNER under `swift test`, which is neither this app
    /// nor an error anything could detect.
    ///
    /// `nil` — which `Bundle.main.executableURL` is documented to allow — falls
    /// back to `documentedProbePath`. An app that cannot locate itself still has
    /// to print a command, and the disk-image location is the likeliest true
    /// answer at that point.
    nonisolated public static func probePath(besideExecutable executable: URL?) -> String {
        guard let executable else { return documentedProbePath }
        return executable
            .deletingLastPathComponent()
            .appendingPathComponent(probeProductName)
            .path
    }

    /// Where the probe has to be before root will run it.
    ///
    /// **The only kind of place `arm` can succeed from, and this is measured.**
    /// `arm` reaches `LaunchDaemonInstaller.install()`, which puts its own
    /// program path through `PathSecurity.validate` before it writes anything:
    /// every component must be root-owned and neither group- nor
    /// other-writable, because launchd execs that file as uid 0 with
    /// `RunAtLoad` and `KeepAlive`. Measured on macOS 26.5.2, `/`, `/Library`
    /// and `/Library/PrivilegedHelperTools` are all `drwxr-xr-x root:wheel`, so
    /// the chain passes.
    ///
    /// **`/Applications` measurably cannot, which is issue #75.** Apple ships
    /// it `drwxrwxr-x root:admin`, so `PathSecurity` refuses it and everything
    /// below it. NO app installed there can arm in place, and the window used
    /// to print that command anyway:
    ///
    ///     $ sudo /Applications/CoffeeBar.app/Contents/MacOS/coffee-bar-probe arm
    ///     coffee-bar-probe: could not arm: programPathInsecure(...)
    ///       /Applications                groupOrOtherWritable: true
    ///       /Applications/CoffeeBar.app  notOwnedByRoot: true
    ///
    /// The refusal is correct and is not the bug: a root LaunchDaemon pointed
    /// at a binary every member of `admin` can rewrite is root persistence
    /// handed to whoever gets there first. What was wrong is what the app told
    /// the user to type.
    ///
    /// **A LITERAL, unlike `probePath(besideExecutable:)`, and the contrast is
    /// the point.** Where the probe SHIPS depends on the install and has to be
    /// derived. Where it is ARMED cannot depend on the install at all, and it
    /// is the same directory on every Mac.
    /// `theArmedProbeIsNeverTheCopyInsideTheAppBundle` drives four installs and
    /// requires one answer.
    ///
    /// `/Library/PrivilegedHelperTools` is where macOS puts binaries a root
    /// process is meant to exec. coffee-bar installs nothing there itself — it
    /// never elevates its own privilege, so the user runs the copy in their own
    /// shell — but the directory's ownership is what this needs, and the
    /// convention is what makes the path recognisable to anyone auditing their
    /// own machine.
    nonisolated public static let privilegedProbePath =
        "/Library/PrivilegedHelperTools/\(probeProductName)"

    /// The command that copies the probe from `path` to where root can run it.
    ///
    /// **The step issue #75 was missing.** Without it the arm command names a
    /// binary that is not on the machine; with the old arm command in its place
    /// it names one root refuses to exec. The two are one procedure and neither
    /// half works alone.
    ///
    /// The path is a PARAMETER, and this is the one command here that still
    /// takes one: the SOURCE is wherever this copy of the app lives, which is
    /// what `probePath(besideExecutable:)` answers, and it differs for a disk
    /// image, a Homebrew prefix, a build tree and a copy on the Desktop. The
    /// DESTINATION is fixed for all four.
    ///
    /// `install(1)` rather than `cp`: it sets owner, group and mode in the same
    /// call that writes the file, so the copy is never briefly present at the
    /// wrong ownership. `-o root -g wheel -m 755` is what makes the leaf pass
    /// `PathSecurity` — a copy left owned by the user fails the same check
    /// `/Applications` fails, and the user would have followed the instructions
    /// and still met a refusal.
    nonisolated public static func lidClosedInstallCommand(probeAt path: String) -> String {
        "sudo install -o root -g wheel -m 755 "
        + "\(shellQuoted(path)) \(shellQuoted(privilegedProbePath))"
    }

    /// The sentence shown when the installed root helper is not this build's.
    ///
    /// **A SEPARATE surface from `lidClosedSummary`, and that is the design.**
    /// That summary is bounded to two sentences by
    /// `theLidClosedSummaryIsTheShortVersionAndNotTheMovedParagraph`, and the
    /// obvious implementation — one more clause — would break it. This is also
    /// a different KIND of statement: the summary explains a feature, this
    /// reports a fault on the machine in front of the user.
    ///
    /// `nil` for `.current` and `.notInstalled`. Up to date needs no sentence,
    /// and "never installed" is what the install advisory already says; two
    /// sentences about one situation read as two faults.
    ///
    /// `.unverifiable` DOES speak. The app could not read its own bundled
    /// probe, so the check did not run, and saying nothing there is
    /// indistinguishable from saying it is fine.
    nonisolated public static func staleHelperAdvisory(
        state: PrivilegedHelperState, probeAt path: String) -> String? {
        switch state {
        case .current, .notInstalled:
            return nil
        case .stale:
            return "The probe at \(privilegedProbePath) is not the one in this "
                + "build, so lid-closed mode is running an older root binary. "
                + "Replace it with \(lidClosedInstallCommand(probeAt: path)) "
                + "and arm it again."
        case .unverifiable:
            return "coffee-bar cannot read its own copy of "
                + "\(probeProductName), so it cannot tell whether the probe at "
                + "\(privilegedProbePath) is current. Reinstall the app."
        }
    }

    /// The line the panel and the Preferences window show about the root helper,
    /// or `nil` for no line.
    ///
    /// **Derived, not stored, so it cannot disagree with what was read.** It
    /// reads `helperState`, which `refresh()` sets, exactly as `hookAdvisory`
    /// reads `hookHealths`. A second stored sentence fed by a second read would
    /// agree with the state until it did not, and the views render this verbatim
    /// so nothing could see the disagreement.
    ///
    /// **`nil` before the first `refresh()`**, because `helperState` is. An
    /// untouched model yields no line rather than a false one — see that
    /// property.
    ///
    /// **`path` is a PARAMETER and `Bundle.main` is not read here.** Where this
    /// build's probe sits depends on where the app was installed, and only the
    /// running bundle knows; reading `Bundle.main` in this type would resolve to
    /// the TEST RUNNER under `swift test`, which is neither this app nor an
    /// error anything could detect. The views supply it through
    /// `probePath(besideExecutable:)`, the same split
    /// `lidClosedSummary(probeAt:)` and `versionLine(from:)` already use.
    ///
    /// It shares a base name with the static above and that is deliberate: one
    /// composes the sentence from a state, the other reports the state THIS
    /// model measured. The argument labels differ, so no call site is ambiguous,
    /// and `LidClosedPanel_test.swift` pins the static by name.
    public func staleHelperAdvisory(probeAt path: String) -> String? {
        helperState.flatMap { Self.staleHelperAdvisory(state: $0, probeAt: path) }
    }

    /// `path` as exactly ONE operand of a shell command line.
    ///
    /// **Every command on this surface is printed to be pasted into a ROOT
    /// shell**, so where the word boundaries fall is not cosmetic. The source
    /// path is composed from `Bundle.main.executableURL` — the user never chose
    /// it with a shell in mind, and `~/My Apps`, a `Coffee Bar.app` rename and
    /// any home directory with a space in it each put a space in the middle of
    /// a line that runs as uid 0. Interpolated bare, that line hands
    /// `install(1)` four operands, which makes it read the last as a
    /// destination DIRECTORY:
    ///
    ///     install: /Library/PrivilegedHelperTools/coffee-bar-probe: Not a directory
    ///
    /// The user is told their own destination is wrong about a file they were
    /// told to create. An apostrophe in the path is worse — the shell refuses
    /// the whole line — and a `$(…)` or a backtick is worse again, because that
    /// substitution RUNS, as root, measured: `$(id -u)` in a fixture path
    /// expanded to `502` before this existed.
    ///
    /// POSIX single quotes, because between them every byte is literal: no
    /// expansion, no escape sequence, no globbing. The single quote is the one
    /// character that cannot appear inside them, so it is closed, escaped and
    /// reopened as `'\''` — what `shlex.quote` produces, and what `install`
    /// then receives as one apostrophe.
    ///
    /// **Left alone when nothing needs quoting**, deliberately rather than as a
    /// shortcut. This window's whole premise is that a user READS the command
    /// before running it as root, and quotes around a path that does not need
    /// them invite the reader to wonder what is being hidden. The bare-word set
    /// is `shlex.quote`'s: alphanumerics and `_@%+=:,./-`. Everything else is
    /// quoted whether or not this author can say what a shell would do with it,
    /// which is the conservative direction — a path quoted needlessly still
    /// installs, and one that needed it does not.
    ///
    /// `aShellFindsNoSyntaxInTheProbePathHoweverItIsSpelled` holds this against
    /// a real `/bin/sh` rather than against a second implementation of these
    /// rules.
    nonisolated static func shellQuoted(_ path: String) -> String {
        let bareWord = Set(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        guard !path.isEmpty else { return "''" }
        guard path.contains(where: { !bareWord.contains($0) }) else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The command that arms lid-closed mode.
    ///
    /// The verb comes from `ProbeVerb.arm` rather than being typed here. A
    /// literal drifts the moment the verb is renamed, and the drift lands on
    /// the user at the worst possible moment: they have already typed `sudo`,
    /// and the binary answers with a usage error.
    ///
    /// **No path parameter since issue #75, and its absence is the fix.** It
    /// had one on the grounds that the path is "the one part of this string
    /// that depends on the machine". That was false. `arm` is refused from
    /// every location the app can be installed to, so the only path this
    /// command can name is `privilegedProbePath` — and a parameter with exactly
    /// one correct argument is how the bundle path came to be passed in the
    /// first place, on a surface where no guard could see it because the model
    /// and the checks read the same value.
    nonisolated public static let lidClosedCommand =
        "sudo \(shellQuoted(privilegedProbePath)) \(ProbeVerb.arm.rawValue)"

    /// The same command, carrying the hold the user chose (issue #74).
    ///
    /// **This function IS the channel the setting travels down.** The value a
    /// user picks in Preferences reaches the root daemon by being typed into a
    /// shell as part of this string, and by no other route: coffee-bar never
    /// elevates its own privilege, and a root process reading an unprivileged
    /// user's preference file is a new data flow SECURITY.md declines to create
    /// until it has had its own review. So the window prints, and the user runs.
    ///
    /// Built ON `lidClosedCommand` rather than beside it, so `sudo`, the path
    /// and the verb have one spelling. A second composition here would drift
    /// from the bare command that `site/docs.html` prints and that
    /// `theLidClosedCommandNamesAVerbTheBinaryAcceptsAndItIsArm` reads.
    ///
    /// `ProbeVerb.ttlFlag` and never a literal `--ttl`. `parse()` in
    /// `main.swift` ignores unknown flags by design, so a flag renamed on one
    /// side leaves this printing a command that succeeds, reports success, and
    /// arms the default hold instead of the chosen one — silent in both
    /// directions. `theTTLFlagThePrintedCommandUsesIsTheOneTheBinaryParses`
    /// reads the constant out of both sides.
    ///
    /// **UNCONDITIONAL, even when the hold equals the default.** Omitting the
    /// flag for the default would be shorter and is the wrong trade: the window
    /// shows a number beside a slider and then a command, and a command that
    /// sometimes carries that number and sometimes does not is one the user has
    /// to reason about before pasting. Always stating it also removes the branch
    /// that could state it wrongly.
    ///
    /// The caller passes `holdInForce`, never the raw setting. Bounding lives
    /// there; this composes a string and bounds nothing, which is the same split
    /// `floorReadout` keeps.
    nonisolated public static func lidClosedCommand(holdingFor seconds: Int) -> String {
        "\(lidClosedCommand) \(ProbeVerb.ttlFlag) \(seconds)"
    }

    /// The command that prints what is currently armed.
    ///
    /// `report` is a root verb for a reason worth repeating here: the journal
    /// it prints is a root-owned `0600` file inside a `0700` directory, so an
    /// unprivileged read cannot open it at all.
    ///
    /// **It names the installed copy too, and NOT because `report` would be
    /// refused otherwise.** Read from source rather than run, since this app
    /// cannot sudo: `.report` in `Sources/CoffeeBarProbe/main.swift` builds a
    /// `GuardedJournalReader` and nothing else, and that type validates the
    /// JOURNAL's path. `LaunchDaemonInstaller.validatedProgramPath` is the only
    /// code that judges the program's OWN path, and `install()` is its single
    /// caller — so `arm` alone reaches it. `revert` and `watchdog` reach
    /// `uninstall()`, which validates nothing. `sudo` on the in-bundle probe
    /// would therefore have printed the journal.
    ///
    /// It moves because of what `sudo` means here, not because of what the code
    /// checks. `/Applications` is writable by `admin`, so telling a user to run
    /// the in-bundle binary as root is telling them to run a file another
    /// account can replace — the same primitive `PathSecurity` refuses for
    /// `arm`, reached by a route that happens not to be guarded. The installed
    /// copy is root-owned `0755` under a root-only directory, and by the time
    /// anyone asks what is armed it is already there.
    nonisolated public static let lidClosedReportCommand =
        "sudo \(shellQuoted(privilegedProbePath)) \(ProbeVerb.report.rawValue)"

    /// The short version of lid-closed mode, for the Preferences window.
    ///
    /// **Two sentences, and the brevity is the requirement.** This replaced
    /// `lidClosedAdvisory`, roughly 80 words that the 260pt Serving panel
    /// rendered unconditionally — a man page in a popover, and issue #56. The
    /// panel keeps nothing now: that surface reports what coffee-bar is doing
    /// NOW, and this is neither live state nor a control. The explanation a
    /// reader actually needs — the root requirement, the launchd watchdog, why
    /// arm-state cannot be shown, what the TTL is for — is on `site/docs.html`,
    /// which carried no lid-closed documentation at all until that issue, which
    /// is why the panel's paragraph pointed at nothing.
    ///
    /// `theLidClosedSummaryIsTheShortVersionAndNotTheMovedParagraph` bounds the
    /// sentence count, because the failure this replaced is not "the wrong
    /// window" — it is a paragraph on a control surface, and moving one window
    /// over reproduces it.
    ///
    /// **coffee-bar cannot show whether the mode is armed, and this is measured
    /// rather than assumed.** `FileJournalStore.systemURL` lives in a directory
    /// `GuardedJournalReader` requires to be exactly `0700` and root-owned.
    /// Measured on macOS 26.5.2 as uid 502 against `/var/root`, a root-owned
    /// directory this process has no execute bit on: `stat(2)` on a path inside
    /// it fails EACCES, and so does `open(2)`. The app cannot read the journal,
    /// cannot read its mode, and cannot even learn whether it exists.
    ///
    /// Issue #13 asked for a state display. Widening the journal's modes to
    /// provide one was rejected: those modes are the security property that
    /// makes a root process safe to hand a file, and they outrank a nicer
    /// window. So this states the limit instead of inventing a reading, and
    /// names the command that CAN answer the question. That half is a product
    /// LIMITATION rather than an explanation, which is why it stayed in the
    /// short version while the rest went to the site: cut it and a user who
    /// armed the mode meets no signal anywhere.
    ///
    /// **A STATIC, and always shown.** Every other advisory here is optional
    /// and silent when it has nothing to report — but silence is exactly what
    /// this one cannot afford. There is no signal to condition it on, and a
    /// window that said nothing would read as "lid-closed mode is off", which is
    /// a claim this app has no evidence for. It is also the only route the user
    /// has to a capability with no control anywhere in the product.
    ///
    /// It offers no control, deliberately. coffee-bar never elevates its own
    /// privilege (SECURITY.md, design §6.3), so the user runs the command in
    /// their own shell — the same posture the product takes with hooks, where
    /// it prints the snippet and refuses to write `~/.claude/settings.json`.
    /// `theAppLayerNeverReachesForPrivilegeEscalation` refuses the alternative
    /// structurally.
    /// **A FUNCTION since issue #64**, and the parameter is the whole point. The
    /// probe ships inside the bundle and is not on any `PATH`, so this sentence
    /// has to name an absolute path — and the right one depends on where this
    /// copy of the app is. The window passes
    /// `probePath(besideExecutable: Bundle.main.executableURL)`.
    ///
    /// **The parameter is the install SOURCE since issue #75**, and nothing
    /// else. It used to be the path the user was told to `sudo`, which was a
    /// command no install of this app could run: `arm` validates its own
    /// program path and refuses every location the app can be dragged to. Now
    /// the sentence tells the user to copy that binary somewhere root trusts
    /// and to arm the copy, which is a sequence that was measured to work.
    ///
    /// **STILL TWO SENTENCES, and the install step is a clause rather than a
    /// third.** The brevity above is a requirement and this had to grow inside
    /// it. It cannot be met by dropping the install step: a window that names
    /// `privilegedProbePath` alone points at a file that is not on the machine
    /// yet, which is the same failure as #75 with a different error message.
    /// `theLidClosedSummaryIsTheShortVersionAndNotTheMovedParagraph` bounds the
    /// count, and `site/docs.html` carries the version with the reasoning in it.
    /// **`holdingFor` HAS NO DEFAULT, deliberately, and issue #74 is why.** The
    /// hold is now a setting, and this sentence prints the command that carries
    /// it. A default here would let a caller render the paragraph without ever
    /// deciding which hold it describes — and the failure is silent and exactly
    /// wrong: the window would show a slider reading 12 hours above a sentence
    /// promising 8, printing a command that arms 8. The one production caller,
    /// `PreferencesView`, passes `model.holdInForce`, which is the bounded
    /// value. `WatchdogService`'s `environment` parameter is required for the
    /// same reason and records what the omission cost there.
    nonisolated public static func lidClosedSummary(probeAt path: String,
                                                    holdingFor seconds: Int) -> String {
        "Lid-closed mode needs root, so you install the probe where root can "
        + "trust it with \(lidClosedInstallCommand(probeAt: path)) and arm it "
        + "yourself with \(lidClosedCommand(holdingFor: seconds)), which holds "
        + "for \(holdLabel(for: seconds)). coffee-bar cannot show "
        + "you whether it is armed — the journal belongs to root and this app "
        + "runs as you — so run \(lidClosedReportCommand) to find out."
    }

    /// Which holds the two Power controls actually govern (issue #73).
    ///
    /// **The defect is a promise, not a floor.** The battery slider sits in a
    /// window that reads as the product's settings, so it reads as governing
    /// every hold coffee-bar is involved in. It does not govern the lid-closed
    /// one at all: `main.swift` builds `WatchdogService` with no `policy:`
    /// argument, that default is `WatchdogPolicy.default`, and its floor is the
    /// compiled-in `BatteryFloor.default`. Drag the slider to 50% and an armed
    /// hold still ends at 15%, with nothing on any surface saying so.
    ///
    /// **Plumbing the setting through is the other repair and it is refused.**
    /// SECURITY.md defers it in as many words — "a root process reading an
    /// unprivileged user's preferences is a new data flow into a privileged
    /// process, and it deserves its own review before it exists rather than
    /// after" — and #74 re-confirmed the same refusal for the hold length. So
    /// the gap stays and stops being undiscoverable, which is the only half of
    /// it this layer may close.
    ///
    /// **BOTH controls, and #74 is why that is not padding.** The window now
    /// shows "Battery floor" immediately above a slider labelled "Lid-closed
    /// hold". A reader takes those as one group governing one feature, so a
    /// note scoping only the first, under a heading naming the second, reads as
    /// confirming the misreading rather than correcting it. The second sentence
    /// therefore states the route the chosen hold DOES take — an argument the
    /// user types — beside the setting that takes no route at all.
    ///
    /// **The number is DERIVED, and that is the whole durability of this.** A
    /// literal `15%` here is correct on the day it is written and becomes a
    /// false claim the moment `BatteryFloor.default` moves, in the one
    /// paragraph whose entire job is to say what the daemon really does.
    /// `WatchdogPolicy.default.batteryFloorPercent` is the value the shipped
    /// probe runs under, reached through the same symbol it reaches it through.
    /// `theScopeNoteNamesTheFloorTheLidClosedDaemonActuallyEnforces` goes red on
    /// a literal that has drifted, and it derives its own expectation by running
    /// `decide` rather than by reading this expression back.
    ///
    /// `ProbeVerb.ttlFlag` and never a literal `--ttl`, for the reason
    /// `lidClosedCommand(holdingFor:)` above gives: a flag renamed on one side
    /// leaves this describing a route the binary no longer offers.
    ///
    /// A STATIC, unlike `floorReadout`, and the isolation is the guarantee. This
    /// sentence describes a process that reads no preference of the user's, so
    /// it must not vary with one — as a static there is no instance for it to
    /// read a setting from, which makes the substitution
    /// `theScopeNoteDescribesTheDaemonWhileTheReadoutDescribesTheUser` refuses
    /// unwritable rather than merely refused.
    ///
    /// Composed here rather than in the window, for the reason every other
    /// sentence in this file is: M1 design §5.4 forbids asserting on rendered
    /// AppKit text, so a paragraph written in `PreferencesView.swift` is a
    /// paragraph no check reads — and an unread paragraph is precisely how this
    /// window came to promise a scope nobody had checked.
    nonisolated static let powerScopeNote =
        "The battery floor governs the holds coffee-bar runs itself, and only "
        + "those. A lid-closed hold is armed by the root command below, which "
        + "never reads your preferences: on battery it ends at coffee-bar's "
        + "built-in floor of \(WatchdogPolicy.default.batteryFloorPercent)% "
        + "whatever you set here, and the hold you chose reaches it only as the "
        + "\(ProbeVerb.ttlFlag) in that command."

    /// The one line the panel shows about the battery floor, or `nil` for no
    /// line.
    ///
    /// Built HERE and not in `PanelView`, for the reason `hookAdvisory` is: M1
    /// design §5.4 forbids asserting on rendered AppKit text, so a sentence
    /// composed in the view is a sentence no check reads. `PanelView` built this
    /// one until now, and that is exactly why the defect below stayed invisible.
    ///
    /// **The two sentences are ONE property, never two.** They answer the same
    /// question from the same evidence, and the refusal half is meaningless
    /// without the reason half. Split across two properties the view can render
    /// one and drop the other, and no check can see it do that. Merged, that
    /// mistake cannot be made.
    ///
    /// The first sentence is unchanged, and both halves of its wording are load
    /// bearing. It has to be true in BOTH cases that reach it: spec §5.3 refuses
    /// a toggle-on that starts below the floor, and `evaluate` records the same
    /// `lastSuppression` for that refusal as for a real release, so "Released at
    /// N%" would announce a release that never happened. "at or below" matches
    /// `PowerBroker`, which suppresses at `percent <= floor`, so at exactly 20%
    /// a line reading "below 20%" states the opposite of what the product did.
    /// The percentage is the reading the DECISION was made on, not the newest
    /// one — the battery keeps draining after a release, and the battery line in
    /// the panel carries the current value.
    ///
    /// The second sentence exists because the first cannot separate THREE
    /// histories that all reach it:
    ///
    ///   A — the user clicked On, the floor refused it outright, and coffee-bar
    ///       moved their control back to where it stood.
    ///   B — the user clicked nothing, and the floor is refusing a hold the
    ///       sessions asked for.
    ///   C — the user clicked On, coffee-bar HONOURED it and held the machine,
    ///       and the floor released that hold later as the battery drained.
    ///
    /// All three used to render the identical line. In A and C the app changed a
    /// setting for the user, the picker snaps back on its own, and nothing said
    /// so — so a return to Auto reads as On being honoured.
    ///
    /// A and C get DIFFERENT sentences, and that separation is the point. `.serve`
    /// holds unconditionally in `PowerBroker`, so C is the normal end of the On
    /// position rather than an edge case, and calling it a refusal tells a user
    /// whose click worked for hours that it did not.
    /// `anHonouredOnClickReleasedByTheFloorNeverSaysItWasRefused` goes red on
    /// exactly that, and it is the defect the first round of this task shipped.
    ///
    /// B adds NO sentence, and must not: a user who touched nothing cannot be
    /// told their click was refused.
    ///
    /// Both sentences name the position from `cancelledServe` rather than a
    /// fixed "Auto", because the standing position is not always Auto: a user
    /// who vetoed serving lands back on Off. Each wording carries its OWN check,
    /// and that is not a formality — `aRefusedOnClickFromOffNamesOffNotAuto`
    /// drives the refusal sentence only, so hard-coding the word in the release
    /// sentence survived the whole suite until
    /// `aReleasedHoldFromOffNamesOffNotAuto` was added. Measured, not assumed.
    /// A third sentence here needs a third check.
    public var suppressionAdvisory: String? {
        guard case .batteryFloor(let percent, let floor) = suppression else { return nil }
        let reason = "At \(percent)% — coffee-bar does not hold at or below \(floor)%."

        switch cancelledServe {
        case nil:
            // Situation B stops here, with the line it has always had.
            return reason
        case .refused(let landed):
            return reason + " Your On click was refused, so the control is back on "
                 + "\(Self.label(for: landed))."
        case .released(let landed):
            return reason + " coffee-bar released the hold from your On click, "
                 + "so the control is back on \(Self.label(for: landed))."
        }
    }

    /// What the three control positions are CALLED, in one place.
    ///
    /// `PanelView`'s picker reads this too. The sentence above names a position
    /// the user has to find on that picker, so a second list of labels in the
    /// view is a list that can drift — and the drift is invisible, because
    /// design §5.4 rules out asserting on the rendered control.
    static func label(for intent: UserIntent) -> String {
        switch intent {
        case .stop: return "Off"
        case .auto: return "Auto"
        case .serve: return "On"
        }
    }

    /// What the two positions of the display control are CALLED.
    ///
    /// Here rather than in `PanelView`, for the reason `label(for:)` is: design
    /// §5.4 rules out asserting on the rendered control, so two literals in the
    /// view are two literals no check reads — and `servingSummary` below
    /// describes the same two states in prose that a check DOES read.
    ///
    /// It names what the SCREEN does, not what the setting is called. "On" and
    /// "Off" sit on the Serving control one line above and would read as a
    /// second power switch.
    static func displayLabel(for holdsDisplay: Bool) -> String {
        holdsDisplay ? "Stays on" : "Sleeps"
    }

    /// What one segment of the floor control is CALLED.
    ///
    /// Here rather than in `PanelView`, for the reason `displayLabel(for:)` is:
    /// design §5.4 rules out asserting on the rendered control, so a label
    /// built in the view is a label no check reads.
    ///
    /// It carries the `%`, because the segments sit under a heading and a bare
    /// "20" beside "30" reads as a count of something rather than as a charge.
    /// `suppressionAdvisory` above quotes the same number the same way.
    ///
    /// It FORMATS a percent and chooses none. Which number the readout shows is
    /// `floorReadout`'s business, below, and issue #68 is why the two are
    /// separate: a formatter that picks its own number would be a second place
    /// the floor is decided.
    static func floorLabel(for percent: Int) -> String {
        "\(percent)%"
    }

    /// What the floor control's readout SAYS, ready to render.
    ///
    /// **`controller.floorInForce`, never `batteryFloorPercentStorage`** — the
    /// rule `refresh()` already applies to the suppression sentence, and issue
    /// #68 is what its absence cost here. The stored setting is unbounded, the
    /// slider is built over `BatteryFloor.permitted`, and `PowerInputs.init`
    /// bounds what the decision uses, so a floor of 75 left over from the old
    /// `5...100` policy pegged the slider at 50, printed "75%" beside it, and
    /// was enforced as 50. Three numbers for one setting, in one window.
    ///
    /// It READS the bounded value; it does not bound one. `BatteryFloor` names
    /// `PowerInputs.init` as the single bounding site and `PreferencesView`
    /// already refuses to add a second — a `BatteryFloor.bounded` call here
    /// would be the third, which issue #68's own acceptance rules out.
    /// `theFloorReadoutNamesTheDefaultUntilTheFirstRefresh` goes red on that
    /// mutant specifically.
    ///
    /// A finished STRING rather than an `Int`, so the view has no number left to
    /// get wrong. The defect was a call site handing the formatter the stored
    /// setting, and a readout that still takes a percent can still be handed
    /// one.
    ///
    /// It does not rewrite what the user stored. Clamping the setting on read
    /// was weighed in the issue and rejected: it removes the same disagreement
    /// by editing a preference the user set, which this project does not do
    /// silently. `batteryFloorPercent` still reports their choice.
    ///
    /// LIMIT, stated rather than hidden: `floorInForce` is `BatteryFloor.default`
    /// until the first `evaluate`, and `init` deliberately makes no decision, so
    /// a readout drawn before the first `refresh()` names the default rather
    /// than the stored floor. What makes that window narrow is the route — the
    /// panel refreshes on appear, the `SettingsLink` inside it opens this
    /// window, and the ticker refreshes every 30 seconds regardless. The window
    /// is pinned by the check named above rather than left to this paragraph.
    public var floorReadout: String {
        Self.floorLabel(for: controller.floorInForce)
    }

    /// The one line the panel shows about what is held right now.
    ///
    /// Built HERE and not in `PanelView`, and issue #12 is why. The view
    /// composed it as "Holding the system awake. The display may still sleep."
    /// — unconditional, and FALSE the moment a user opts in. M1 design §5.4
    /// forbids asserting on rendered AppKit text, so that sentence was a claim
    /// no check in this package could read, in the UI of a product whose pitch
    /// is that it tells you the truth about what is keeping your Mac awake.
    ///
    /// It reads the DECISION and not the setting, deliberately — but be honest
    /// about what that buys today. No check at this level can tell the two
    /// apart, and an earlier version of this comment wrongly claimed one did.
    /// `PowerBroker.decide` grants `displaySleepAssertion` only in the branch
    /// that also grants the system hold, and the guard below returns before the
    /// expression whenever nothing is held, so `desired?.displaySleepAssertion`
    /// and `holdDisplayAwake` agree in every state reachable here. Substituting
    /// one for the other is a semantic no-op today, proved by mutation.
    ///
    /// Reading the decision is still the correct source: it stays right if a
    /// later change ever denies the screen while granting the machine, which is
    /// exactly when a setting-derived sentence would begin to lie. The invariant
    /// is pinned where it IS falsifiable — `theOffPositionVetoesTheDisplayHoldToo`
    /// and `theBatteryFloorReleasesTheDisplayHoldToo` in `PowerBroker_test.swift`.
    ///
    /// Not `Optional`, unlike the advisories: this line is always on screen.
    /// "Nothing is held" is the answer a user opening the panel most needs.
    public var servingSummary: String {
        guard isServing else { return "Not holding any assertion." }
        return desired?.displaySleepAssertion == true
            ? "Holding the system awake, and the display with it."
            : "Holding the system awake. The display may still sleep."
    }

    /// Turns a `start()` failure into something the user can act on.
    ///
    /// Each case names the path and the next step, because "ingest is not
    /// working" leaves a user with nowhere to go. `IngestError` is matched
    /// through a cast: the parameter is `any Error`, and a listener injected by
    /// a test may throw something else entirely.
    private static func describe(_ error: any Error) -> String {
        guard let ingestError = error as? IngestError else {
            return "The socket was refused: \(error)."
        }
        switch ingestError {
        case .alreadyServing(let path):
            return "Another process already answers on \(path). "
                 + "Quit the other copy of coffee-bar, then reopen this one."
        case .socketPathBlocked(let path):
            return "Something that is not a socket sits at \(path). "
                 + "Move it out of the way, then reopen coffee-bar."
        case .directoryUnwritable(let path):
            return "\(path) could not be created or written."
        case .socketPathTooLong(let bytes):
            return "The socket path is \(bytes) bytes, over the 103-byte limit."
        }
    }

    /// The one line the panel shows about what is holding the machine awake, or
    /// `nil` for no line.
    ///
    /// PE finding I4, resolved as design §14. The attention list shows the two
    /// BLOCKED states, so without this the session actually holding the
    /// assertion appears nowhere — in a product whose whole pitch is that you
    /// can see what is keeping your Mac awake. §14 says a count is enough.
    ///
    /// The sentence is built here rather than in `PanelView` for the reason
    /// `hookAdvisory` is: M1 design §5.4 forbids asserting on rendered AppKit
    /// text, so a sentence composed in the view would be a sentence no check
    /// reads — and "1 sessions working" would ship.
    ///
    /// It states the COUNT and claims no cause. Under `.serve` the hold exists
    /// whatever the sessions are doing, and under `.stop` it exists for none of
    /// them, so "2 sessions are keeping this Mac awake" would be false in both
    /// positions. The panel already says whether it is holding, one line above.
    /// Both lines are true independently, which is the only way two lines can
    /// sit together and stay honest.
    ///
    /// Derived, not stored, so it cannot disagree with `working`.
    public var workingSummary: String? {
        guard working.isEmpty == false else { return nil }
        return working.count == 1 ? "1 session working" : "\(working.count) sessions working"
    }

    /// What the ingest socket's read route answers with (issue #9).
    ///
    /// **Derived at the moment of the read, from the properties the panel
    /// renders, and never stored.** Design §14's rule holds here for the same
    /// reason it holds for `working` and `attention`: a snapshot pushed on the
    /// 30-second refresh would be a second source that agrees with the panel
    /// until it does not, and a reader would have no way to tell which of the
    /// two was describing this machine.
    ///
    /// **It answers about coffee-bar and never about your work.** `IngestStatus`
    /// has nowhere to put a session identity, a working directory, a transcript
    /// path or any message text, and the counts below are counts: `working` and
    /// `attention` are arrays of `AgentSession`, and what crosses the socket is
    /// how many.
    ///
    /// `version` is handed in rather than read here, because `Bundle.main` is
    /// read at the composition point and the model stays pure — the same split
    /// `versionLine(from: Bundle.main.infoDictionary)` uses for the panel. See
    /// `startMonitoring`.
    func ingestStatus(version: String) -> IngestStatus {
        IngestStatus(version: version,
                     intent: intent,
                     holding: isServing,
                     working: working.count,
                     attention: attention.count,
                     hookHealth: hookHealth,
                     listening: ingestListening)
    }

    /// The listener default is the REAL one, deliberately.
    ///
    /// A null default would let a missing wire ship silently, and ingest that
    /// looks connected while delivering nothing is the exact honesty failure
    /// design §6 exists to prevent. Tests inject a double; the three checks in
    /// `ServingModel_test.swift` that call `startMonitoring` all do.
    ///
    /// `now` is injected so the stale-timeout checks move the clock by hand
    /// instead of waiting five real minutes.
    public init(holder: any AssertionHolding = AssertionHolder(),
                reader: any PowerReadingProviding = SystemPowerReader(),
                health: any HookHealthProviding = HookHealthReader(),
                helper: any PrivilegedHelperStateProviding = PrivilegedHelperReader(),
                settings: any SettingsStoring = UserDefaultsSettingsStore(),
                listener: any IngestListening = UnixSocketIngestListener(),
                policy: StalePolicy = .standard,
                now: @escaping @Sendable () -> Date = { Date() },
                governance: ProcessGovernance? = nil,
                updates: any ReleaseManifestFetching = PublishedManifestFetcher()) {
        self.holder = holder
        self.reader = reader
        self.health = health
        self.helper = helper
        self.settings = settings
        self.listener = listener
        self.policy = policy
        self.now = now
        self.governance = governance
        self.updates = updates
        self.reading = reader.read()
        // Read ONCE, here, and never again. `refresh()` runs every 30 seconds
        // and on every hook event; re-reading the store on each of those would
        // make an external write to the preferences move the user's control
        // under them, and this app is the only writer anyway.
        //
        // `?? false` is the product's default: the screen sleeps unless the
        // user has said otherwise. A key nobody wrote reads as `nil` here, not
        // as `false` — see `SettingsStoring`.
        self.holdDisplayAwakeStorage =
            settings.bool(forKey: SettingsKey.holdDisplayAwake) ?? false
        // Read once, here, for the reason above. `?? BatteryFloor.default` is
        // the product's documented floor, and the `??` is load bearing: a key
        // nobody wrote reads as `nil` here rather than as 0, and a 0 floor
        // fires only once the machine is already dead.
        //
        // NOT bounded here, deliberately. `PowerInputs.init` is the one place a
        // floor is bounded — see `BatteryFloor` — and a second application of
        // that rule on this line is the drift the invariant forbids. What this
        // costs is a display-only oddity: a floor hand-written outside the
        // permitted range with `defaults write` shows as no selection on the
        // panel's control, while the DECISION still bounds it correctly. The
        // first touch of the control heals it.
        self.batteryFloorPercentStorage =
            settings.integer(forKey: SettingsKey.batteryFloorPercent) ?? BatteryFloor.default
        // Read once, here, for the reason above, and the `??` is load-bearing in
        // a way the floor's is not. `UserDefaults.integer(forKey:)` answers 0
        // for a key nobody wrote; 0 seconds becomes `--ttl 0`, a hold that has
        // expired before the watchdog's first tick. Every user who has never
        // opened Preferences would find lid-closed mode does nothing at all,
        // with nothing to read anywhere that says why.
        //
        // NOT bounded here, for the reason the floor above is not: `holdInForce`
        // is the one place that happens, and a second application of the rule on
        // this line is the drift the invariant forbids.
        self.lidClosedHoldSecondsStorage =
            settings.integer(forKey: SettingsKey.lidClosedHoldSeconds) ?? ProbeVerb.defaultTTLSeconds
        // Read once, here, for the reason above. `?? false` is the product's
        // default and is the second of the two opt-ins issue #14 requires: a
        // key nobody wrote reads as `nil` here, never as `true`, so coffee-bar
        // demotes nothing for a user who never asked.
        self.quietEverythingElseStorage =
            settings.bool(forKey: SettingsKey.quietEverythingElse) ?? false
        // Read once, here, for the reason above. **NO `??` on this one, and that
        // is the point of issue #51's fifth key**: `nil` is a user who has never
        // been asked and `[]` is one who asked for silence, and a coalesce in
        // either direction would make the two the same user. What an unset key
        // MEANS is decided in `assumedAgentTools` and `advises(_:)`, where it is
        // named and can be read.
        //
        // Reading does NOT write. A default seeded here would be
        // indistinguishable from a choice a second later, and issue #52's wizard
        // has to tell those apart to know whom it is for.
        self.selectedAgentTools = settings.selectedAgentTools()
        // Read once, here, for the reason above, and `?? false` is the direction
        // the whole of issue #52 rests on: a key nobody wrote means NOT YET
        // SHOWN. The other way round ships a quick start no user ever sees, with
        // every check about what it asks still green.
        //
        // **This init READS the store and writes nothing to it, and that is the
        // acceptance bullet rather than a style note.** Everything the quick
        // start shows is pre-filled from the five reads above — the user's own
        // floor, their own display answer, their own tool selection — and a
        // sixth line here seeding any of them back would turn a deliberate 40%
        // floor into 15% for a user who did nothing but click through.
        self.quickStartCompletedStorage =
            settings.bool(forKey: SettingsKey.quickStartCompleted) ?? false
        // Read once, here, for the reason above, and NO `??`: an absent key is
        // a machine that has never checked, and reading it as the epoch would
        // put "Last checked: 1970-01-01 00:00" in the window for every new
        // user. Both readings make the first check due; only one of them tells
        // the truth on the surface.
        self.lastUpdateCheck = settings.integer(forKey: SettingsKey.lastUpdateCheck)
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    // There is deliberately NO `deinit` here, and none may be added.
    //
    // **The compiler will not stop you.** Measured, not read: a plain
    // `deinit { listener.stop() }` COMPILES on this toolchain — `listener` is a
    // `Sendable` `let`, so a nonisolated `deinit` may read it and no
    // `isolated deinit` is needed. The experimental feature that broke CI at
    // 6.1.2 is a different shape. So the only thing holding this line is
    // `aModelThatGoesAwayLeavesTheListenerAlone`, which goes red on exactly
    // that mutant.
    //
    // The reason is PE finding B2, which was measured rather than reasoned.
    // One extra `App` build makes one orphaned model, and an orphan that stops
    // the listener takes ingest down for the LIVE instance while the panel
    // still reports the hooks wired.
    //
    // What leaving it out costs, stated exactly, because the sentence that used
    // to sit here was FALSE. An orphan's `startMonitoring` cannot steal the
    // socket — `UnixSocketIngestListener` connect-probes first and throws
    // `alreadyServing` — but this then claimed the orphan's own `NWListener`
    // went with it when the object did. It does not. Measured against this
    // repo's own class, with a control at each step:
    //
    //   - the `UnixSocketIngestListener` DOES deallocate — a weak reference to
    //     it goes nil — which is what made the claim look right;
    //   - the `NWListener` it started does NOT. The socket still accepts
    //     connections two seconds after the last owning reference goes away,
    //     and a real `curl` post to it exits 52: accepted, then dropped;
    //   - only `cancel()` frees it. The same class stopped through `stop()`
    //     refuses the next connection.
    //
    // So an orphan that DID bind leaks its socket for the life of the process.
    // Nothing reaches that today, so this is LATENT and not a live defect:
    // `startMonitoring` runs once per model from `App.init`, and a second
    // model's `start()` throws off the FIRST model's still-live listener rather
    // than binding a second one. The instrumented bundle ran `App.init` exactly
    // once over 122 s and five real hook events.
    //
    // A bind RETRY is what would wake it up, and `main.swift` carries that
    // decision. `occupant()` cannot tell a socket this process leaked from one
    // another process owns, so a retry finds the leak `.live` and throws
    // `alreadyServing` for ever — measured — while the panel blames a second
    // instance that does not exist.

    /// Bound to the panel's 3-way control. What the user ASKED FOR.
    ///
    /// This replaced a `serving: Bool` whose getter returned `isServing` — the
    /// actual hold — and whose setter wrote `newValue ? .serve : .stop`. Both
    /// halves were wrong once `.auto` existed:
    ///
    ///   - the getter made the control move by itself as agent sessions came
    ///     and went, because it reported what the machine was doing rather
    ///     than what had been asked of it;
    ///   - the setter could only express two of the three positions, so one
    ///     click wrote an explicit `.stop` or `.serve` the user never chose
    ///     and `.auto` — the position the product SHIPS in — could never be
    ///     selected again.
    ///
    /// The getter reads the controller, not a copy held here, so the `.serve`
    /// cancel is visible to the panel: a hold the battery floor refuses moves
    /// the control off On, which is exactly what has happened to the intent.
    /// It moves back to the STANDING position — Auto or Off — rather than to
    /// Off every time, so a click that FAILED never leaves the user more
    /// restricted than before they made it. See `HoldController.evaluate`.
    ///
    /// `isServing` stays as the read-only ACTUAL state and stays on screen
    /// beside this. The two answer different questions and the panel shows
    /// both.
    public var intent: UserIntent {
        get { controller.intent }
        set {
            controller.userToggled(to: newValue)
            refresh()
        }
    }

    /// Bound to the panel's display control. Whether a hold covers the SCREEN
    /// as well as the machine (issue #12).
    ///
    /// A SETTING and not a fourth control position, because it answers a
    /// different question from `intent`: that one says whether to hold at all,
    /// this one says what a hold covers. The two are independent, so the panel
    /// shows two controls.
    ///
    /// It never reaches IOKit on its own. The setter hands it to
    /// `PowerBroker` through `refresh()`, which weighs the off switch and the
    /// battery floor first, and only `DesiredPowerState.displaySleepAssertion`
    /// reaches `AssertionHolder`. A model that passed this straight to
    /// `acquire` would keep the screen lit through the off switch and below the
    /// battery floor — `theOffPositionWithdrawsTheDisplayHoldAsWell` and
    /// `theBatteryFloorWithdrawsTheDisplayHoldAsWell` go red on exactly that.
    ///
    /// Computed over a stored property, the same shape as `intent` above, so
    /// `@Observable` tracks the read and the panel redraws.
    ///
    /// The setter WRITES BEFORE it reconciles. A crash between the two would
    /// otherwise lose a choice the user has already seen take effect, and the
    /// store is the only thing that outlives the process.
    public var holdDisplayAwake: Bool {
        get { holdDisplayAwakeStorage }
        set {
            holdDisplayAwakeStorage = newValue
            settings.setBool(newValue, forKey: SettingsKey.holdDisplayAwake)
            refresh()
        }
    }

    /// The backing store for `holdDisplayAwake`, seeded from the settings in
    /// `init`. Private: `holdDisplayAwake` is the property with the behaviour.
    private var holdDisplayAwakeStorage: Bool

    /// Bound to the panel's floor control. The charge at or below which
    /// coffee-bar stops holding the machine awake (issue #11).
    ///
    /// A SETTING, like `holdDisplayAwake` above and for the same reason: it
    /// answers a different question from `intent`. That one says whether to
    /// hold at all, this one says how much battery a hold may spend. The floor
    /// governs every position — `theBatteryFloorGovernsAutoAsWellAsServe` — so
    /// it cannot be a fourth segment on the Serving control.
    ///
    /// The value is NOT bounded here. `PowerInputs.init` bounds it, once, and
    /// `BatteryFloor` states why that is the only site. So this reports what
    /// the user chose and `desired.suppression` reports what the decision used;
    /// they differ only for a floor hand-written outside the permitted range.
    ///
    /// The setter WRITES BEFORE it reconciles, like `holdDisplayAwake`: a crash
    /// between the two would lose a choice the user has already seen take
    /// effect. It reconciles at all because a user raising the floor on a low
    /// battery is asking for the hold to stop NOW, not at the next 30-second
    /// tick — `changingTheFloorReconcilesImmediatelyRatherThanAtTheNextTick`.
    public var batteryFloorPercent: Int {
        get { batteryFloorPercentStorage }
        set {
            batteryFloorPercentStorage = newValue
            settings.setInteger(newValue, forKey: SettingsKey.batteryFloorPercent)
            refresh()
        }
    }

    /// The backing store for `batteryFloorPercent`, seeded from the settings in
    /// `init`. Private, for the reason `holdDisplayAwakeStorage` is.
    private var batteryFloorPercentStorage: Int

    /// Bound to the Preferences window's lid-closed hold slider. How long the
    /// user wants `arm` to hold the machine (issue #74).
    ///
    /// **It reports what the user STORED, unbounded**, exactly as
    /// `batteryFloorPercent` above does and for the same reason: this project
    /// does not silently rewrite a preference somebody set. What the window
    /// ACTS on is `holdInForce` below, which is the bounded one, and the two
    /// differ only for a hold hand-written outside the permitted range with
    /// `defaults write`.
    ///
    /// The setter writes through to the store on every change. A setter that
    /// updated only the property would keep every in-session assertion green —
    /// the getter reads what it just wrote — while the choice vanished at the
    /// next launch. `draggingTheHoldSliderSurvivesARelaunch` drives two models
    /// over one store, which is what a relaunch is.
    ///
    /// **No `refresh()`, unlike the floor setter.** That one reconciles because
    /// raising the floor on a low battery is a request for the hold to stop NOW.
    /// This changes nothing coffee-bar is currently doing: it changes the text
    /// of a command the user has not run yet, on a mode this process cannot
    /// arm, observe or revert. There is nothing to reconcile.
    public var lidClosedHoldSeconds: Int {
        get { lidClosedHoldSecondsStorage }
        set {
            lidClosedHoldSecondsStorage = newValue
            settings.setInteger(newValue, forKey: SettingsKey.lidClosedHoldSeconds)
        }
    }

    /// The backing store for `lidClosedHoldSeconds`, seeded from the settings in
    /// `init`. Private, for the reason `holdDisplayAwakeStorage` is.
    private var lidClosedHoldSecondsStorage: Int

    /// The hold the window ACTS on — bounded, and the single place that happens.
    ///
    /// **Issue #68's defect, refused in advance for the second numeric setting.**
    /// There the stored floor was unbounded, the slider was built over the
    /// permitted range, and the decision bounded somewhere else: three numbers
    /// for one setting in one window, with the readout naming the wrong one.
    /// Here the readout and the printed command both read THIS property, so
    /// they cannot disagree with each other whatever is in the preferences file.
    ///
    /// The stakes are higher than a mislabelled slider. This number is
    /// interpolated into a string the user pastes into a ROOT shell, and
    /// `defaults write … -int -3600` is one command away — `--ttl -3600` in a
    /// sudo command is a product telling its user something has gone wrong
    /// without saying what.
    ///
    /// It BOUNDS rather than clamps-and-stores, so `lidClosedHoldSeconds` still
    /// reports the user's own value and a hold typed outside the range is
    /// reported back inside it rather than overwritten.
    public var holdInForce: Int {
        LidClosedHold.bounded(lidClosedHoldSecondsStorage)
    }

    /// What the hold control's readout SAYS, ready to render.
    ///
    /// A finished STRING rather than an `Int`, following `floorReadout`: the
    /// view is then left no number to pick the wrong one of, which is precisely
    /// the defect issue #68 shipped when a call site handed the formatter the
    /// stored setting instead of the bounded one.
    ///
    /// HOURS AND MINUTES, not raw seconds. The stored unit is seconds because
    /// that is what `--ttl` takes, and "28800" beside a slider is a number a
    /// reader has to do arithmetic on before it means anything. Singular and
    /// plural are both spelled because "1 hours" beside a settings control reads
    /// as a bug in the product.
    ///
    /// It reads `holdInForce`, never the storage. `theFloorReadoutNamesTheDefault…`
    /// records what the equivalent mistake cost on the floor, and
    /// `aHoldOutsideThePermittedRangeIsReadOutBoundedAndPrintedBounded` goes red
    /// on this one.
    public var holdReadout: String {
        Self.holdLabel(for: holdInForce)
    }

    /// `seconds` as a phrase a person reads.
    ///
    /// `static` and taking its number as a parameter, for the reason
    /// `floorLabel(for:)` is: it FORMATS a duration and chooses none. Which
    /// duration the readout shows is `holdReadout`'s business, and a formatter
    /// that picked its own number would be a second place the hold is decided.
    ///
    /// Whole minutes, because `LidClosedHold.step` is half an hour and every
    /// position the control can take is a whole number of them. A hold with
    /// seconds in it can only arrive from `defaults write`, and it is bounded
    /// before it reaches here; the remainder is dropped rather than rendered,
    /// because "8 hours 0 minutes 30 seconds" answers a question nobody asked
    /// of a settings window.
    nonisolated static func holdLabel(for seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hour" + (hours == 1 ? "" : "s")) }
        if minutes > 0 { parts.append("\(minutes) minute" + (minutes == 1 ? "" : "s")) }
        // Only reachable for a sub-minute hold, which `LidClosedHold.bounded`
        // rules out on every path that reaches this. Spelled anyway: a readout
        // that renders as the empty string is a control with a blank beside it
        // and no way to tell that from a layout fault.
        return parts.isEmpty ? "\(seconds) seconds" : parts.joined(separator: " ")
    }

    /// Bound to the panel's fourth control. Whether coffee-bar puts the
    /// processes the user named into darwin background state while an agent
    /// works (issue #14).
    ///
    /// **A SETTING, and the SECOND of two opt-ins.** `demotableProcessNames`
    /// says WHICH processes may be touched and defaults to empty; this says
    /// whether to touch any of them and defaults to `false`. Carlos chose two
    /// over one so a user who has named a process can stop the behaviour
    /// without losing their list.
    ///
    /// It is the whole profile. There is no `Aggressive` tier in this package
    /// and none is planned — handoff §2.2 ships one switch.
    ///
    /// **macOS cannot promote a process**, so nothing here may be worded as a
    /// speed-up. The handoff cites Oakley twice: `taskpolicy` "functions as a
    /// brake, but not as an accelerator". `ServingModel.quietOthersLabel(for:)`
    /// carries the wording.
    ///
    /// It never reaches `setpriority` on its own. The setter hands it to
    /// `ProcessGovernance` through `refresh()`, which weighs it against the
    /// other three conditions first.
    ///
    /// The setter WRITES BEFORE it reconciles, like the two settings above: a
    /// crash between the two would lose a choice the user has already seen take
    /// effect. It reconciles at all because a user turning this OFF is asking
    /// for their applications back now, not at the next 30-second tick —
    /// `turningTheSwitchOffRestoresImmediatelyRatherThanAtTheNextTick`.
    public var quietEverythingElse: Bool {
        get { quietEverythingElseStorage }
        set {
            quietEverythingElseStorage = newValue
            settings.setBool(newValue, forKey: SettingsKey.quietEverythingElse)
            refresh()
        }
    }

    /// The backing store for `quietEverythingElse`, seeded from the settings in
    /// `init`. Private, for the reason `holdDisplayAwakeStorage` is.
    private var quietEverythingElseStorage: Bool

    /// What the quiet-others control is CALLED.
    ///
    /// Here rather than in `PanelView`, for the reason `displayLabel(for:)` is:
    /// design §5.4 rules out asserting on the rendered control, so a label
    /// written in the view is a label no check reads.
    ///
    /// **It names what happens to the OTHER applications, never what happens to
    /// the agent.** macOS has no mechanism to promote a process — the handoff
    /// cites Oakley twice, that `taskpolicy` "functions as a brake, but not as
    /// an accelerator" — so "Boost agents" would be a claim this product cannot
    /// support. Handoff §2.2 ships this phrase for exactly that reason.
    ///
    /// No battery saving, no percentage and no duration appears here either. A
    /// 2026-08-01 audit spent a day removing unverifiable claims of that kind,
    /// and `theQuietOthersLabelNamesWhatIsQuietedAndClaimsNoSpeedUp` refuses
    /// their return.
    ///
    /// A single constant rather than one string per position: this is a binary
    /// opt-in and the panel renders it as a toggle, so a second label would be a
    /// label nothing draws.
    static let quietOthersLabel = "Quiet everything else"

    // MARK: - The quick start (issue #52)

    /// Whether the quick start still has to be shown.
    ///
    /// **It is not a first-run flag, and the difference is the product
    /// decision.** The obvious gate — "this user has no settings yet" — skips
    /// everybody who has ever opened Preferences, and this page is also the
    /// UPGRADE experience: it is shown once to EVERYONE, with the answers they
    /// already have pre-filled. `theQuickStartIsShownToAnUpgradingUserAndNotOnlyToAnEmptyOne`
    /// drives a store holding three configured settings, which is exactly the
    /// state a has-settings gate reads as "already sorted".
    ///
    /// TWO conditions, and only one of them outlives the process.
    /// `completeQuickStart()` records the answer for good; `deferQuickStart()`
    /// puts the page away for this window only. That is what separates "not
    /// now" from "never" — see the two methods below.
    ///
    /// **Reading this writes nothing**, and that is the whole of the acceptance
    /// bullet this feature is most likely to fail. A default seeded on the way
    /// in is indistinguishable from a choice a second later, and for
    /// `SettingsKey.agentTools` the difference is not recoverable afterwards:
    /// absent is a user who has never been asked, and any written value is a
    /// user who answered. `theQuickStartWritesNothingWhateverOnTheWayIn` holds
    /// it against a store that logs writes rather than values, because a seed
    /// that happens to write back the value already there is invisible to a
    /// value assertion and has still destroyed the distinction.
    public var quickStartPending: Bool {
        !quickStartCompletedStorage && !quickStartDeferred
    }

    /// The backing store for the recorded half, seeded from the settings in
    /// `init`. Private, for the reason `holdDisplayAwakeStorage` is.
    private var quickStartCompletedStorage: Bool

    /// The session-only half, which is deliberately NOT a setting.
    ///
    /// It resets when the process does, and that IS the behaviour: a user who
    /// chose "not now" is asking to be asked again, not to be left with no route
    /// back short of clearing their preferences.
    private var quickStartDeferred = false

    /// Records that the user has been shown the quick start.
    ///
    /// **It writes the completion record and NOTHING else.** Every answer was
    /// already written as the user gave it — the page binds to
    /// `holdDisplayAwake`, `batteryFloorPercent` and `setAdvises(_:for:)`, the
    /// same properties the Settings window binds to — so there is nothing left
    /// to apply here. A Done button that "applied" the pre-filled answers would
    /// be the overwrite this feature exists to avoid, arriving through the exit
    /// rather than the entrance, and it is the likelier of the two because it
    /// reads as obviously correct.
    /// `finishingTheQuickStartRecordsOnlyThatItWasShown` asserts the write log
    /// is exactly one key long.
    ///
    /// No `refresh()`. Nothing coffee-bar is currently doing changes when the
    /// page closes; the setters that DID change something reconciled at the
    /// moment they were touched.
    public func completeQuickStart() {
        quickStartCompletedStorage = true
        settings.setBool(true, forKey: SettingsKey.quickStartCompleted)
    }

    /// Puts the quick start away for this session without recording anything.
    ///
    /// **"Not now", and it must not become "never".** Writing the completion
    /// record here is one line and reads as harmless; it leaves a user who meant
    /// to answer later with no route back except clearing their preferences.
    /// `dismissingTheQuickStartWritesNothingAndBringsItBackNextLaunch` drives a
    /// second model over the same store, which is what a relaunch is.
    ///
    /// Nothing else is written either, so a dismissal leaves the app exactly as
    /// it was: per issue #51 the three keys stay unset, an unset `agentTools` is
    /// a user who has not been asked rather than a broken state, and the panel
    /// says what it said before the page appeared.
    public func deferQuickStart() {
        quickStartDeferred = true
    }

    /// What the page says it is for, above the three questions.
    ///
    /// Here rather than in the view, for the reason `quietOthersLabel` is:
    /// design §5.4 rules out asserting on rendered AppKit text, so a sentence
    /// composed in the view is a sentence no check reads — which is how this
    /// window came to promise a scope nobody had checked (issue #73).
    ///
    /// It promises the answers can be changed later, because they can: every one
    /// of them is a control in this same window once the page is done with.
    static let quickStartIntro = """
        Three questions, and coffee-bar is set up. Every answer is a setting in \
        this window, so anything here can be changed later.
        """

    /// The display question.
    ///
    /// It names the DEFAULT rather than recommending an answer. coffee-bar lets
    /// the screen sleep unless the user says otherwise — that is the product's
    /// difference from the blunt tools — and a first-run page that talked a user
    /// into the display hold would be selling the behaviour it exists to avoid.
    static let quickStartDisplayQuestion = """
        While an agent is working, should the screen stay on? coffee-bar lets it \
        sleep unless you say otherwise.
        """

    /// The battery-floor question.
    ///
    /// It says what the number DOES, because "battery floor" names a concept
    /// this user has not met yet. The wording is the scope the two power
    /// controls share; `powerScopeNote` states the lid-closed exception where
    /// that control lives, and repeating it here would put an exception in front
    /// of a user who has not been told the rule.
    static let quickStartFloorQuestion = """
        How much battery may a hold spend? Below this charge coffee-bar stops \
        holding the machine awake and lets it sleep.
        """

    /// The agent-tools question.
    ///
    /// It NAMES NO TOOL, for the reason `agentToolsLabel` names none:
    /// `AgentTool.allCases` is the one place that list lives, and a sentence
    /// spelling it out would still say three when a fourth arrived, with nothing
    /// able to see it.
    ///
    /// It promises no installation. Design §6 is print-never-touch for every one
    /// of those files, and answering this question writes nothing but the
    /// selection itself.
    static let quickStartToolsQuestion = """
        Which agent tools do you run? coffee-bar reports hook health for the ones \
        you pick, and installs nothing.
        """

    /// The label on the exit that records the page as shown.
    static let quickStartFinishLabel = "Done"

    /// The label on the exit that records nothing.
    ///
    /// It says LATER rather than "Cancel" or "Skip", because that is what it
    /// does: the page comes back next launch. A label promising dismissal on a
    /// button that defers is a label that lies about which of the two exits the
    /// user pressed.
    static let quickStartDeferLabel = "Ask me later"

    // MARK: - Is there a newer coffee-bar? (issue #29)

    /// What the last check concluded, or `nil` when none has run.
    ///
    /// **`nil` is not "up to date"**, and keeping the two apart is the whole of
    /// the state. A window that said "up to date" before any check had run would
    /// be stating a fact nobody had established — and it would keep saying it
    /// for a user whose checks have been failing since the day they installed.
    public private(set) var updateVerdict: UpdateVerdict?

    /// When coffee-bar last ASKED, whatever came back.
    ///
    /// The ATTEMPT and not the last success, deliberately. It is what bounds the
    /// one outbound request this application makes, so a run of failures must
    /// not turn into a request on every tick. `updateStatusLine` says what the
    /// attempt concluded, separately and beside it, so the pair cannot read as a
    /// check that worked.
    public private(set) var lastUpdateCheck: Date?

    /// What the window says about the last check.
    public var updateStatusLine: String {
        guard let updateVerdict else { return UpdateCheck.neverCheckedLine }
        return UpdateCheck.sentence(for: updateVerdict)
    }

    /// When the window says that was.
    public var lastUpdateCheckLine: String { UpdateCheck.lastCheckLine(lastUpdateCheck) }

    /// Looks for a newer published version, whatever the interval says.
    ///
    /// This is the Check now button. It ignores `UpdateCheck.interval` on
    /// purpose: the user asked, and a press that silently did nothing because
    /// the last check was an hour ago is a button lying about having a job.
    ///
    /// **A build with no usable stamp does not post at all.** The request is the
    /// thing this feature spends, and there is nothing to learn from an answer
    /// that cannot be compared to anything — so the refusal happens BEFORE the
    /// fetch rather than after it. `anUnstampedBuildNeverPostsAtAll` measures
    /// that on the fetcher's own call count, because a model that fetched and
    /// then declined to compare would look identical in the window.
    ///
    /// `version` is a parameter with the bundle read at its DEFAULT, which is
    /// the same split `startMonitoring(version:)` uses: the model stays pure and
    /// a check can hand in a stamp of its own.
    ///
    /// **It replaces the bundle with nothing and downloads no release.** The
    /// entire effect is `updateVerdict` and `lastUpdateCheck`.
    public func checkForUpdates(
        version: String = AppVersion.display(from: Bundle.main.infoDictionary)
    ) async {
        guard UpdateCheck.releaseCore(of: version) != nil else {
            updateVerdict = .cannotCompare(UpdateCheck.unstampedLine)
            return
        }

        // Stamped BEFORE the request rather than after it, so a check that
        // takes the whole timeout records when it started. The alternative
        // drifts the interval outward by however long the network took.
        let attempted = now()

        do {
            let fetched = try await updates.fetch()
            switch UpdateCheck.manifest(from: fetched.body, statusCode: fetched.statusCode) {
            case .success(let manifest):
                updateVerdict = UpdateCheck.compare(running: version,
                                                    published: manifest.version)
            case .failure(let refusal):
                updateVerdict = .cannotCompare(UpdateCheck.sentence(for: refusal))
            }
        } catch {
            // Every transport failure reads the same to a user: it did not
            // happen. The error's own text is a `URLError` code that names a
            // library rather than a thing to do about it.
            updateVerdict = .cannotCompare(UpdateCheck.unreachableLine)
        }

        lastUpdateCheck = attempted
        settings.setInteger(Int(attempted.timeIntervalSince1970),
                            forKey: SettingsKey.lastUpdateCheck)
    }

    /// Looks for a newer published version only if the stated interval has run
    /// out.
    ///
    /// This is the automatic half, and `main.swift` calls it once at launch.
    /// There is no timer: a check that fires while the app sits in the menu bar
    /// for a week is a request the user is not present for, and the interval is
    /// enforced across launches by the stored stamp rather than by a ticker this
    /// process holds.
    public func checkForUpdatesIfDue(
        version: String = AppVersion.display(from: Bundle.main.infoDictionary)
    ) async {
        guard UpdateCheck.isDue(lastChecked: lastUpdateCheck, now: now()) else { return }
        await checkForUpdates(version: version)
    }

    /// Undoes every demotion the journal records. Call it at launch and on a
    /// clean exit.
    ///
    /// Both are the same operation, because the journal is what says which
    /// processes to put back and it outlives whatever wrote it. `main.swift`
    /// calls this once from `App.init()` and again from
    /// `NSApplication.willTerminateNotification`.
    ///
    /// Does nothing when no governance was supplied, which is the state every
    /// check in this package runs in.
    public func restoreDemotedProcesses() {
        governance?.restoreEverythingDemoted()
    }

    /// Re-samples power, retires silent sessions, and reconciles the assertion.
    /// Safe to call on a timer.
    ///
    /// Expiry happens HERE and not in `ingest`, and design §5 is why: the stale
    /// timeout is a SAFETY property, so it has to be evaluated on a TIMER. A
    /// crashed agent sends no further event, so an expiry that runs only on the
    /// next event never runs at all and the Mac stays awake until the user
    /// reboots.
    public func refresh() {
        sessions = SessionHub.expiring(sessions, now: now(), policy: policy)

        reading = reader.read()
        // Re-read every time, not once in `init`. The user's recovery path is
        // to paste the snippet back, and this app runs for days. It re-reads
        // every TOOL's file for the same reason, and because a user who
        // installs Cursor while the app runs must not wait for a relaunch.
        //
        // The selection WIDENS this read and never narrows it (issue #51): a
        // tool the user says they run is read whether or not its file is there,
        // because that user is mid-setup. An unset selection falls back to
        // `assumedAgentTools`, which is what makes a user who has never opened
        // Preferences see exactly what they saw before the key existed.
        hookHealths = health.statuses(
            advising: selectedAgentTools ?? Self.assumedAgentTools)
        // Re-read every time, not once in `init`, for the reason above and one
        // of its own: the user's recovery path here is to paste the install
        // command the advisory carries, and a state frozen at launch would keep
        // reporting an old root binary after it had been replaced. Issue #81's
        // whole point is that the app tells the user something they can act on,
        // so the advisory has to clear without a relaunch.
        helperState = helper.state()
        // ASKED, not remembered. The bind is asynchronous, so a `start()` that
        // returned cleanly is not proof the socket is serving, and `stop()`
        // takes it away again.
        ingestListening = listener.isReady
        // `isServing` still holds the previous reconcile's ACTUAL result here,
        // because it is only reassigned below — and that is exactly the fact the
        // controller needs. It decides what should happen; IOKit decided what
        // did. A `.serve` whose `acquire()` was refused must never be reported
        // as a released hold.
        let state = controller.evaluate(powerSource: reading.source,
                                        batteryPercent: reading.percent,
                                        sessions: sessions,
                                        batteryFloorPercent: batteryFloorPercentStorage,
                                        holdDisplayAwake: holdDisplayAwakeStorage,
                                        assertionIsHeld: isServing)
        // Derived from the SAME array handed to `evaluate` above, on purpose.
        // Design §14 forbids a second source here: a panel that disagrees with
        // the hold decision is worse than a panel with nothing on it.
        attention = AttentionList.rows(from: sessions)
        working = AttentionList.working(from: sessions)
        desired = state
        // `controller.floorInForce`, never `batteryFloorPercentStorage`. The
        // stored setting is UNBOUNDED, so passing it here printed "at or below
        // 1000%" beside a decision made on 100, and dropped the reason entirely
        // for a stored 0 — leaving a refused On click to snap back to Auto in
        // silence. The controller reports the floor the broker was actually
        // given.
        suppression = Self.reason(controller.lastSuppression, stillTrueOf: reading,
                                  underFloor: controller.floorInForce)
        // Gated on the FILTERED value above, not on the controller alone, so the
        // claim dies with the sentence that explains it. A recovery above the
        // floor drops both together —
        // `theRefusalSentenceGoesWhenTheBatteryRecovers` measures that.
        //
        // This gate HIDES a stale claim; it does not end one, and audit finding
        // 2 is the difference. The controller kept a cancel that no suppression
        // followed, this line hid it while the battery was above the floor, and
        // the next drain handed the same record back — so the record's own
        // lifetime had to be fixed in `HoldController.evaluate`. The gate stays:
        // it is what keeps the claim and the sentence from ever appearing apart,
        // and two independent mechanisms are what
        // `aRefusalFromAnEarlierDrainNeverReturnsAtALaterOne` asserts on
        // separately, one on the state and one on the wording.
        cancelledServe = suppression == nil ? nil : controller.cancelledServe

        // The DECISION reaches IOKit, never the setting. `state` has already
        // been weighed against the off switch and the battery floor, so this
        // line cannot pin the screen awake behind the decision's back — which
        // is the blind spot every §6.1 guard rests on.
        if state.idleSleepAssertion {
            isServing = holder.acquire(displaySleep: state.displaySleepAssertion)
        } else {
            holder.release()
            isServing = false
        }

        // Process demotion, AFTER the assertion is reconciled. The two are
        // independent — the trigger below weighs neither `intent` nor the
        // battery floor — and the assertion is the one the user is watching, so
        // it is not made to wait behind a walk over every running application.
        //
        // The demotable set is re-read on EVERY pass, unlike the three settings
        // seeded in `init`. Those three are bound to panel controls, and
        // re-reading would move a control under the user; this one has no
        // control at all — `docs/` gives the `defaults write` command — so a
        // read taken once in `init` would mean the user's edit did nothing until
        // they relaunched the app.
        //
        // `working` and `sessions` are the arrays `evaluate` was handed above,
        // never a second source. The count is the trigger's second condition;
        // the pids are a deny rule, and they are empty in a shipped build
        // because no hook payload carries one.
        governance?.reconcile(
            onBattery: reading.source == .battery,
            workingAgentCount: working.count,
            protectedAgentPIDs: Set(sessions.compactMap(\.pid)),
            demotableNames: settings.demotableProcessNames(),
            quietEverythingElse: quietEverythingElseStorage)
    }

    /// Applies one hook event and reconciles immediately.
    ///
    /// Immediately, not on the next tick: 30 seconds between an agent starting
    /// work and the machine staying awake is a 30-second window in which it can
    /// fall asleep under that agent.
    ///
    /// `SessionHub.apply` decides everything about the session list. This hands
    /// the array in and takes the answer back, so an event Claude Code adds
    /// later cannot mint a phantom session here.
    func ingest(from tool: AgentTool, _ event: HookEvent) {
        sessions = SessionHub.apply(from: tool, event, to: sessions, now: now())
        refresh()
    }

    /// Starts the repeating refresh, so a battery crossing the floor is noticed
    /// without the user opening the panel.
    ///
    /// The ticker belongs to the model rather than to `PanelView` because
    /// `MenuBarExtra` with `.menuBarExtraStyle(.window)` builds its content only
    /// while the panel is open. A floor that is enforced only while the panel is
    /// open does not enforce the floor.
    ///
    /// 30s is frequent enough to matter and cheap enough to ignore —
    /// `SystemPowerReader.read()` is a non-blocking IOKit call. `.common` mode,
    /// not `.default`, so menu tracking does not stall the refresh. `[weak self]`
    /// so the run loop's reference to the timer cannot keep the model alive.
    ///
    /// `main.swift` calls this from `App.init()`. There are two ways a second
    /// `Timer` could end up on `RunLoop.main`, and both are closed:
    ///
    ///   - a repeat call on the SAME instance — `timer?.invalidate()` below;
    ///   - a second `App` build. That second `ServingModel` installs its own
    ///     timer, and SwiftUI keeps one `@State` box, so the orphan model
    ///     deallocates — the block below then invalidates its own timer.
    ///
    /// `[weak self]` does not cover the second case on its own. It stops the
    /// orphan's block from doing anything, but the run loop still holds the
    /// timer, so a main-thread wake-up every 30s survives for the life of the
    /// process. Only `invalidate()` takes it off the run loop.
    ///
    /// This was an `isolated deinit` until CI disproved it. That feature is
    /// EXPERIMENTAL before Swift 6.3: it compiles on a 6.3 developer machine and
    /// fails on the 6.1.2 GitHub runner with "requires frontend flag
    /// -enable-experimental-feature IsolatedDeinit". Verifying a language
    /// feature against a single toolchain is not verifying it.
    ///
    /// So the block invalidates the timer it is HANDED, rather than a `deinit`
    /// reaching for a stored property. No experimental feature, no weakened
    /// isolation, and the orphan survives at most one further tick.
    /// `nonisolated(unsafe)` and `@unchecked Sendable` stay rejected.
    ///
    /// Nobody has observed a second `App.init()`; it is inferred, not measured.
    /// This ships anyway because it is correct either way and costs nothing.
    /// The two alternatives stay rejected: moving the call to the view
    /// reintroduces the ticker-dies-with-the-panel defect this design exists to
    /// close, and a process-wide static guard adds hidden global state.
    ///
    /// It also starts ingest, and the ORDER is load-bearing. The timer goes on
    /// the run loop FIRST, because the socket is the likeliest thing here to
    /// fail — a second instance already owns it — and an app that then enforces
    /// no battery floor at all is a worse failure than an app with no ingest.
    /// `main.swift` catches the error and launches anyway.
    public func startMonitoring(
        interval: TimeInterval = 30,
        version: String = AppVersion.display(from: Bundle.main.infoDictionary)
    ) throws {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] tick in
            // `tick` stays OUT of the `assumeIsolated` closure: it is
            // task-isolated, and capturing it in a main-actor closure is a
            // sending violation under strict concurrency. Calling
            // `invalidate()` here is safe because this block runs on the run
            // loop the timer was added to, which is `RunLoop.main`.
            guard let model = self else {
                tick.invalidate()
                return
            }
            MainActor.assumeIsolated { model.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // The read route, wired BEFORE the bind, so there is no window in which
        // the socket answers and this model does not (issue #9).
        //
        // `assumeIsolated` is sound for the reason the event callback's is, and
        // it is the same queue: `UnixSocketIngestListener` runs every connection
        // on `DispatchQueue.main`, so this closure is called there.
        //
        // `[weak self]` for the reason the timer block uses it. An orphaned
        // model must not be kept alive by the listener that outlives it, and
        // `nil` here is answered with a 503 rather than with a payload
        // describing a model nothing is driving.
        //
        // `version` is captured, not read here: the bundle is read at the
        // DEFAULT ARGUMENT above — this method's one composition point, called
        // from `App.init` — which keeps the model itself pure and lets a test
        // hand in a stamp of its own.
        listener.serveStatus { [weak self] in
            MainActor.assumeIsolated { self?.ingestStatus(version: version) }
        }

        guard !listenerStarted else { return }
        // `assumeIsolated` is sound here ONLY because the listener delivers on
        // the main thread. `UnixSocketIngestListener` starts every connection
        // on `DispatchQueue.main` for this reason, and
        // `deliveryHappensOnTheMainThread` holds that line. Delivery from any
        // other queue makes this TRAP at runtime.
        //
        // `[weak self]` for the same reason the timer block uses it: the
        // listener outlives an orphaned model, and the callback must not be
        // what keeps that model alive.
        do {
            try listener.start { [weak self] tool, event in
                MainActor.assumeIsolated { self?.ingest(from: tool, event) }
            }
        } catch {
            // Recorded on the way past, then rethrown unchanged. `main.swift`
            // still catches it and launches anyway — an app with no ingest is
            // far better than no app — but the reason now reaches the panel
            // instead of stopping at NSLog.
            listenerRefusal = Self.describe(error)
            throw error
        }
        // Cleared only on success. A retry that works must not leave the panel
        // explaining a refusal that has stopped happening.
        listenerRefusal = nil
        listenerStarted = true
    }

    /// The panel explains a condition that is still true, or it says nothing.
    ///
    /// `HoldController.lastSuppression` latches: it is cleared only when the
    /// user picks Serve again, so it would otherwise keep the line on screen
    /// through a return to AC power and through a full recharge. That latch is
    /// deliberate and is left alone — under `.serve`, recovery must never
    /// re-arm the hold — so the filtering happens here, on the way to the
    /// panel.
    ///
    /// This filter is what makes the narrow `.serve`-only intent latch safe to
    /// rely on. Under `.auto` the hold DOES come back once the reading
    /// recovers, and this drops the stale line at the same moment, so the panel
    /// never explains a refusal that has stopped happening. Were the intent
    /// latch still unconditional, this filter would be actively harmful: it
    /// would hide the reason a permanently disabled app gave for disabling
    /// itself.
    ///
    /// **It reads the newest READING and never asks whether anything currently
    /// wants a hold**, so with no sessions at all the panel still names the
    /// battery. That is measured, and it stays. With the control back on its
    /// standing position the floor is the binding constraint on whatever happens
    /// next, so the sentence predicts the next working agent exactly, and
    /// lifting the floor is enough to make the hold arrive —
    /// `theBatteryLineLeftOnScreenIsTrueOfWhatHappensNext` puts the line to that
    /// test. The case where it misled was a refused `.serve` landing on `.stop`:
    /// the battery was then not the operative reason at all, and no recharge
    /// could change the outcome. `HoldController` no longer lands there.
    ///
    /// Narrowing this to the CURRENT decision's suppression stays rejected. It
    /// would drop the line the moment the last session went idle, which is the
    /// stale-percent defect `theSuppressionLineNamesTheMeasuredPercent` and
    /// `theSuppressionLineSurvivesARecoveryToExactlyTheFloor` exist to catch,
    /// and it would leave a user who clicked On with no session running looking
    /// at a refusal and no reason for it.
    /// **The floor comes from the SETTING, not from the record, and issue #11
    /// is why.** Until the floor was settable the two were always the same
    /// number, so reading it off the record was free. A floor the user can move
    /// makes them different, and the record is the stale one:
    ///
    ///   - lowered, the recorded floor still suppresses the current reading
    ///     while the real one does not, so the panel explains a refusal while
    ///     the machine is held. Measured, not reasoned:
    ///     `loweringTheFloorDropsTheSentenceThatNamedTheOldOne` catches
    ///     `isServing` true and the sentence on screen together.
    ///   - raised with nothing running, no fresh suppression is produced, so
    ///     the record keeps the old number and the change the user just made
    ///     looks lost.
    ///
    /// So the returned reason carries the floor IN FORCE. The percent is left
    /// alone and stays the reading the DECISION was made on, which is the older
    /// deliberate half — the battery keeps draining after a release, and the
    /// panel's battery line carries the current value.
    ///
    /// Gating on the setting rather than dropping every reason when the floor
    /// moves is deliberate. Dropping would take the line away from a user who
    /// has just RAISED the floor on a quiet machine, which is the moment they
    /// most need it. `raisingTheFloorRestatesTheSentenceWithTheNewNumber` and
    /// `theLeftoverSentenceQuotesTheFloorInForceNotTheOneItWasRecordedUnder`
    /// hold that from both sides.
    ///
    /// **`floor` is the BOUNDED floor the decision used, from
    /// `HoldController.floorInForce`. Never the stored setting.** An earlier
    /// version of this comment claimed the raw setting was correct here,
    /// "because this asks what the user set". That was wrong, and it shipped
    /// two defects:
    ///
    ///   - a stored 1000 printed "at or below 1000%" — a percentage that cannot
    ///     exist — beside a decision made on 100;
    ///   - a stored 0 dropped the reason altogether, because `3 <= 0` is false
    ///     while the decision refused on the bounded 5. `cancelledServe` is
    ///     gated on this value, so a refused On click snapped back to Auto and
    ///     said nothing.
    ///
    /// The panel reports what the decision DID. It does not re-derive the
    /// decision's inputs in parallel — a second derivation agrees until it does
    /// not, and the disagreement is invisible.
    /// `aFloorHandWrittenAboveTheMaximumIsQuotedAsTheOneEnforced` and
    /// `aFloorHandWrittenBelowTheMinimumStillExplainsTheRefusal` hold both.
    private static func reason(_ suppression: HoldSuppression?,
                               stillTrueOf reading: PowerReading,
                               underFloor floor: Int) -> HoldSuppression? {
        guard case .batteryFloor(let measured, _) = suppression,
              reading.source == .battery,
              let percent = reading.percent,
              percent <= floor
        else { return nil }

        return .batteryFloor(percent: measured, floor: floor)
    }
}

extension ServingModel {
    /// What the panel draws beside `servingSummary`.
    ///
    /// `static` and `nonisolated` on purpose. A swift-testing `@Test` function
    /// is nonisolated, and `ServingModel` is main-actor isolated, so an
    /// instance method here could not be called from a test without annotating
    /// the test `@MainActor` — which would hide the property rather than test
    /// it. This takes a Bool and returns a value; it holds no actor state.
    nonisolated public static func indicator(isServing: Bool) -> IndicatorSpec {
        isServing
            ? IndicatorSpec(symbolName: "cup.and.saucer.fill", role: .state)
            : IndicatorSpec(symbolName: "cup.and.saucer", role: .rest)
    }
}
