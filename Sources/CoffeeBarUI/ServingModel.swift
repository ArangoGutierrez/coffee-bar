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
    private let listener: any IngestListening
    private let settings: any SettingsStoring
    private let policy: StalePolicy
    private let now: @Sendable () -> Date
    private var controller = HoldController()

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

    /// Every agent tool whose hook file is on this machine, with what that file
    /// says about coffee-bar's entries.
    ///
    /// A tool is ABSENT from this map when its hook file is not on disk, and
    /// that is the claim the panel needs: an absent file means the user does not
    /// run that tool, so a Claude-Code-only user is never told to wire Cursor.
    ///
    /// Empty until the first `refresh()`. Nothing renders it before then —
    /// `PanelView.onAppear` calls `refresh()`, and the menu-bar label reads
    /// `isServing` only.
    public private(set) var hookHealths: [AgentTool: HookHealthStatus] = [:]

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
    /// **One line per tool, in `AgentTool.allCases` order.** A property that
    /// returned only the first finding would drop two-thirds of the advice for a
    /// user who runs all three, and `PanelView` renders this verbatim so no
    /// check could see it happen. The order is fixed because a dictionary has
    /// none, and an order that reshuffled between refreshes would rewrite the
    /// panel every 30 seconds under a user trying to read it.
    public var hookAdvisory: String? {
        let lines = AgentTool.allCases.compactMap { tool in
            hookHealths[tool].flatMap { Self.advisory(for: tool, status: $0) }
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
    static func floorLabel(for percent: Int) -> String {
        "\(percent)%"
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
                settings: any SettingsStoring = UserDefaultsSettingsStore(),
                listener: any IngestListening = UnixSocketIngestListener(),
                policy: StalePolicy = .standard,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.holder = holder
        self.reader = reader
        self.health = health
        self.settings = settings
        self.listener = listener
        self.policy = policy
        self.now = now
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
        hookHealths = health.statuses()
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
    public func startMonitoring(interval: TimeInterval = 30) throws {
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
