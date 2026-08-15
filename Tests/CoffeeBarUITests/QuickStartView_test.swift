// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import CoffeeBarCore
import CoffeeBarPower
import CoffeeBarTestSupport
@testable import CoffeeBarUI

/// The first-run quick start (issue #52): what it asks, what it writes, and —
/// the sharp half — what it must never write.
///
/// It is ALSO AN UPGRADE EXPERIENCE. It is shown once to everyone rather than
/// only to a user with no settings, and it arrives with the answers that user
/// already has pre-filled. That decision is what makes the fourth acceptance
/// bullet the dangerous one: pre-filling means READING the current values and
/// showing them, and a wizard that seeds its defaults on the way in turns a
/// deliberate 40% battery floor into 15% for a user who did nothing but click
/// through. `theQuickStartWritesNothingWhateverOnTheWayIn` is the guard for
/// exactly that, and it is mutation-checked in the task report.
///
/// M1 design §5.4 forbids asserting on rendered AppKit text, so the checks that
/// read the window read its SOURCE. The behaviour checks drive the model, which
/// is where every sentence and every decision lives.

// MARK: - Test doubles

/// A settings store that remembers WHAT WAS WRITTEN, not only what it holds.
///
/// **The write log is the whole point of this double** and is why the suite's
/// existing `FakeSettings` is not reused. A value assertion cannot see a store
/// rewritten with the value it already had, and that is precisely the shape of
/// the defect this file guards: a wizard that "pre-fills" by writing the
/// current values back has changed nothing observable in the store and has
/// still destroyed the one distinction issue #51 built —
/// `SettingsKey.agentTools` absent is a user who was never asked, and the same
/// key written as `[]` is a user who asked for silence.
private final class RecordingSettings: SettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    private var writeLog: [String] = []

    init(_ initial: [String: Any] = [:]) { values = initial }

    /// Every key written THROUGH this store, in order, seeded state excluded.
    var writes: [String] {
        lock.lock(); defer { lock.unlock() }
        return writeLog
    }

    /// Every key the store holds, sorted.
    var storedKeys: [String] {
        lock.lock(); defer { lock.unlock() }
        return values.keys.sorted()
    }

    func bool(forKey key: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return values[key] as? Bool
    }

    func setBool(_ value: Bool, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
        writeLog.append(key)
    }

    func integer(forKey key: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return values[key] as? Int
    }

    func setInteger(_ value: Int, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
        writeLog.append(key)
    }

    func stringArray(forKey key: String) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        return values[key] as? [String]
    }

    func setStringArray(_ value: [String], forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
        writeLog.append(key)
    }
}

/// A power reader that answers the same reading every time.
///
/// Declared here rather than shared: the doubles in `ServingModel_test.swift`
/// are `private`, which Swift scopes to that file. Four lines duplicated is
/// better than widening another file's internals.
private struct StillReader: PowerReadingProviding {
    func read() -> PowerReading { PowerReading(source: .ac, percent: 80) }
}

/// An assertion holder that records nothing and refuses nothing.
///
/// `acquire` answers `true` so `isServing` follows the model's own logic rather
/// than a refusal injected here. Nothing in this file reads the hold state; the
/// double exists so the SHIPPING default — real IOKit — is never reached.
private struct NullHolder: AssertionHolding {
    @discardableResult func acquire(displaySleep: Bool) -> Bool { true }
    func release() {}
}

/// A hook-health reader pointed at a committed fixture.
///
/// Every model built here is handed one, for the reason `ServingModel_test.swift`
/// gives: the shipping default reads the machine's own `~/.claude/settings.json`,
/// so a check that took it would report differently on every laptop.
private func fixtureHealth(_ name: String = "wired.json") -> HookHealthReader {
    HookHealthReader(settingsURL: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()    // …/Tests/CoffeeBarUITests
        .deletingLastPathComponent()    // …/Tests
        .appending(path: "Fixtures/claude-settings/\(name)"))
}

@MainActor
private func freshModel(over store: RecordingSettings) -> ServingModel {
    ServingModel(holder: NullHolder(), reader: StillReader(),
                 health: fixtureHealth(), settings: store)
}

/// The preferences an EXISTING user has already configured, deliberately unlike
/// every default the product ships.
///
/// 40 is not `BatteryFloor.default` (15), `true` is not the display default
/// (`false`), and `["codex"]` is neither `nil` nor
/// `ServingModel.assumedAgentTools` (`[.claudeCode]`). Each one differs from
/// what a wizard would seed, so a wizard that seeds is visible in the value and
/// not only in the write log.
///
/// A function rather than a `let`, because `[String: Any]` is not `Sendable` and
/// a global one is shared mutable state the compiler refuses under Swift 6.
private func configuredUser() -> [String: Any] {
    [
        SettingsKey.batteryFloorPercent: 40,
        SettingsKey.holdDisplayAwake: true,
        SettingsKey.agentTools: [AgentTool.codex.rawValue],
    ]
}

// MARK: - Whom the wizard is for

@MainActor
@Test func theQuickStartIsPendingForAUserWhoHasNeverSeenIt() {
    // Named bug this catches: a wizard nobody is ever shown, because the record
    // it reads defaults the wrong way. An unset key must mean "not yet shown"
    // — the same direction every other key in this package reads, and the only
    // one that survives a user clearing their preferences.
    #expect(freshModel(over: RecordingSettings()).quickStartPending)
}

@MainActor
@Test func theQuickStartIsShownToAnUpgradingUserAndNotOnlyToAnEmptyOne() {
    // Named bug this catches, and it is a DESIGN decision rather than an
    // oversight: gating the wizard on "this user has no settings" so that
    // everybody who ever opened Preferences is skipped. Carlos closed the
    // issue's open question the other way — the quick start is an UPGRADE
    // experience, shown once to everyone, with existing answers pre-filled.
    //
    // This is the discriminating fixture for that: `configuredUser` has three
    // settings and no completion record, which is exactly the state a
    // has-settings gate would read as "already sorted".
    #expect(freshModel(over: RecordingSettings(configuredUser())).quickStartPending)
}

@MainActor
@Test func theQuickStartIsShownOnce() {
    // Named bug this catches: a completion that lives only in the object, so
    // the wizard returns at every launch. `ServingModel` is built afresh each
    // time the process starts, so the SECOND model here is what a relaunch is.
    let store = RecordingSettings()
    let first = freshModel(over: store)
    first.completeQuickStart()
    #expect(first.quickStartPending == false)

    // The relaunch. A completion held in memory passes the line above and fails
    // this one.
    #expect(freshModel(over: store).quickStartPending == false)
}

// MARK: - The sharp one: an existing user's preferences are never overwritten

@MainActor
@Test func theQuickStartWritesNothingWhateverOnTheWayIn() {
    // THE ACCEPTANCE BULLET MOST LIKELY TO BE GOT WRONG, and the one this file
    // exists for. Named bug this catches: a wizard that "pre-fills" by seeding
    // its controls into the store when it opens. A user who clicks through
    // without touching anything then finds their deliberate 40% floor is 15%,
    // their display hold off, and — worst, because it is not recoverable — the
    // never-asked `agentTools` key written as an answer.
    //
    // THE WRITE LOG, not the values, is what makes this discriminate. A seed
    // that happens to write the value already there changes nothing a value
    // assertion can see, and has still destroyed the absent/empty distinction
    // `SettingsKey.agentTools` is built on.
    //
    // The mutation is run in the task report: making the model seed defaults in
    // `init` turns this red.
    let store = RecordingSettings(configuredUser())
    let model = freshModel(over: store)

    // Everything the wizard reads to draw itself. If any of these is the write,
    // the log below reports it.
    _ = model.quickStartPending
    _ = model.holdDisplayAwake
    _ = model.batteryFloorPercent
    for tool in AgentTool.allCases { _ = model.advises(tool) }

    #expect(store.writes.isEmpty, """
        opening the quick start wrote \(store.writes) to the preferences. \
        Pre-filling is READING the user's values and showing them. A wizard \
        that writes on the way in has answered three questions on behalf of a \
        user who has not been asked them yet, and for agentTools that is not \
        recoverable: absent means never asked, and any written value means \
        asked and answered.
        """)

    // The store is untouched by value as well as by count, so a write logged
    // somewhere this double cannot see would still be caught here.
    #expect(store.storedKeys == configuredUser().keys.sorted())
}

@MainActor
@Test func theQuickStartShowsTheAnswersTheUserAlreadyHas() {
    // Named bug this catches: a wizard that opens on the product's defaults
    // rather than on the user's answers. That is the same defect as writing
    // them — the user sees 15% beside a question, answers "yes that is fine",
    // and their 40 is gone the moment any control is touched.
    //
    // Every expectation below is against a value that DIFFERS from the default
    // the wizard would otherwise show, so a defaults-seeded wizard fails each
    // one rather than passing by coincidence.
    let model = freshModel(over: RecordingSettings(configuredUser()))

    #expect(model.batteryFloorPercent == 40)
    #expect(model.batteryFloorPercent != BatteryFloor.default)
    #expect(model.holdDisplayAwake == true)

    // The tools half, and it needs both directions. `advises(.codex)` alone is
    // satisfied by a wizard that ticked every box; `advises(.claudeCode)` is
    // the one that proves it read the user's list rather than
    // `assumedAgentTools`, which is `[.claudeCode]`.
    #expect(model.advises(.codex))
    #expect(model.advises(.claudeCode) == false)
    #expect(ServingModel.assumedAgentTools.contains(.claudeCode))
}

// MARK: - What an answer writes

@MainActor
@Test func everyQuickStartAnswerWritesTheKeyTheSettingsWindowWrites() {
    // Named bug this catches: a second spelling. A key is a STORED FORMAT —
    // written on one launch, read on the next — so a wizard that records the
    // battery floor as `quickstart.batteryFloor` works perfectly until the app
    // restarts, and then the user's answer quietly reverts with nothing to
    // report and no error to read. `SettingsKey`'s own doc comment says so.
    //
    // THE KEY SET IS ASSERTED WHOLE, against the `SettingsKey` symbols and
    // never against string literals. A `contains` per key would pass a wizard
    // that wrote the right four AND a fifth of its own; equality will not.
    let store = RecordingSettings()
    let model = freshModel(over: store)

    // Driven exactly as the wizard's controls drive it — through the same
    // properties the Preferences window binds to. There is no second write path
    // for the wizard to get wrong, which is the design; this check is what
    // stops one being added.
    model.holdDisplayAwake = true
    model.batteryFloorPercent = 35
    model.setAdvises(true, for: .cursor)
    model.completeQuickStart()

    #expect(Set(store.writes) == Set([SettingsKey.holdDisplayAwake,
                                      SettingsKey.batteryFloorPercent,
                                      SettingsKey.agentTools,
                                      SettingsKey.quickStartCompleted]), """
        the quick start wrote \(Set(store.writes).sorted()). Every answer must \
        land on the key the Settings window writes and on no other: a divergent \
        spelling reverts at the next launch, silently.
        """)

    #expect(store.bool(forKey: SettingsKey.holdDisplayAwake) == true)
    #expect(store.integer(forKey: SettingsKey.batteryFloorPercent) == 35)

    // BOTH TOOLS, and the one that was NOT ticked here is the interesting half.
    // `setAdvises` freezes the whole answer rather than the tool it was handed:
    // until the first call there is no stored selection at all, only the
    // inference from `hookHealths`, so writing `[cursor]` would silently discard
    // Claude Code — which the `wired.json` fixture has on disk and which the
    // page was therefore SHOWING as ticked. A wizard is where that costs most: a
    // user answering "yes I run Cursor too" would switch off the tool they
    // actually use.
    //
    // This expectation was `[cursor]` when it was written, and the run corrected
    // it. That is the documented behaviour of `setAdvises(_:for:)`, not an
    // accident of it.
    #expect(store.stringArray(forKey: SettingsKey.agentTools)
                == [AgentTool.claudeCode.rawValue, AgentTool.cursor.rawValue])
}

@MainActor
@Test func finishingTheQuickStartRecordsOnlyThatItWasShown() {
    // Named bug this catches: a Done button that "applies" the pre-filled
    // answers by writing all of them. For a user who touched nothing that is
    // the overwrite this whole file guards against, arriving through the exit
    // rather than through the entrance — and it is the likelier of the two,
    // because writing on Done reads as obviously correct.
    let store = RecordingSettings(configuredUser())
    let model = freshModel(over: store)

    model.completeQuickStart()

    #expect(store.writes == [SettingsKey.quickStartCompleted], """
        finishing the quick start wrote \(store.writes). A user who answered \
        nothing has answered nothing: the only thing there is to record is that \
        they were asked.
        """)
    #expect(store.integer(forKey: SettingsKey.batteryFloorPercent) == 40)
    #expect(store.stringArray(forKey: SettingsKey.agentTools) == [AgentTool.codex.rawValue])
}

// MARK: - Dismissal, and getting back

@MainActor
@Test func dismissingTheQuickStartWritesNothingAndBringsItBackNextLaunch() {
    // Named bug this catches: "Not now" spelled as "never". Recording the
    // completion on a deferral is one line and reads as harmless, and it leaves
    // a user who wanted to answer later with no route back short of clearing
    // their preferences.
    //
    // Per issue #51 a dismissal leaves nothing broken: the three keys stay
    // unset, an unset `agentTools` is a user who has not been asked, and the
    // app behaves exactly as it did before the wizard existed.
    let store = RecordingSettings()
    let model = freshModel(over: store)

    model.deferQuickStart()

    #expect(model.quickStartPending == false, "the deferral did not put the page away")
    #expect(store.writes.isEmpty, """
        dismissing the quick start wrote \(store.writes). A deferral records \
        nothing — not the answers, and not the fact it was shown.
        """)

    // The relaunch. This is the half that separates "not now" from "never".
    #expect(freshModel(over: store).quickStartPending, """
        the quick start did not come back after a deferral, so "not now" is \
        "never" and the user has no route back to it.
        """)
}

@MainActor
@Test func clearingThePreferencesBringsTheQuickStartBack() {
    // Named bug this catches: the completion recorded OUTSIDE the preferences
    // — a marker file under Application Support, say. That reads as tidy and it
    // strands the user: clearing preferences resets all three answers and the
    // wizard that would ask them again never appears, with nothing anywhere
    // saying why.
    let store = RecordingSettings()
    freshModel(over: store).completeQuickStart()
    #expect(freshModel(over: store).quickStartPending == false)

    // What `defaults delete` leaves behind. An empty store is the whole of a
    // cleared preferences domain, so a record kept anywhere else survives it.
    #expect(freshModel(over: RecordingSettings()).quickStartPending, """
        the quick start stayed away over an empty preferences domain, so \
        whatever records "already shown" outlives the user's own reset.
        """)
}

// MARK: - What the page says

@MainActor
@Test func theQuickStartAsksThreeDistinctQuestions() {
    // Named bug this catches: a copy-paste that asks the same question three
    // times, or a question with no text at all. The sentences live on the model
    // rather than in the view because design §5.4 rules out asserting on
    // rendered AppKit text — copy composed in a view is copy no check reads,
    // which is how this window came to promise a scope nobody had checked
    // (issue #73).
    let questions = [ServingModel.quickStartDisplayQuestion,
                     ServingModel.quickStartFloorQuestion,
                     ServingModel.quickStartToolsQuestion]

    for question in questions {
        #expect(question.isEmpty == false)
    }
    #expect(Set(questions).count == 3, "the quick start asks \(Set(questions).count) distinct questions, not three")

    // The two exits are named differently, because they do different things.
    #expect(ServingModel.quickStartFinishLabel != ServingModel.quickStartDeferLabel)
    #expect(ServingModel.quickStartIntro.isEmpty == false)
}

// MARK: - The page is wired to the window

/// The CODE of a surface under `Sources/`, comment-stripped.
///
/// A fourth resolver in this target, for the reason `PreferencesView_test.swift`
/// gives for its third: the others are `private`, which Swift scopes to their
/// own file.
///
/// COMMENT-STRIPPED is load-bearing rather than tidy, and this file is a case
/// that proves it: every paragraph below names the seams it asserts on, so a
/// raw `contains` would be satisfied by this file's own explanation of the code
/// it is checking for.
private func quickStartSurface(named name: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()    // …/Tests/CoffeeBarUITests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // the package root
    return swiftCodeWithoutComments(
        try String(contentsOf: root.appending(path: "Sources/CoffeeBarUI/\(name)"),
                   encoding: .utf8))
}

@Test func theQuickStartPageAsksAllThreeQuestionsThroughTheModel() throws {
    // Named bug this catches: a page that draws two of the three questions, or
    // one that holds its own `@State` copy of an answer. The copy is the
    // subtler of the two — it works for the length of one window and disagrees
    // with the Settings window the moment either changes, which is the defect
    // `eachMovedControlLivesInExactlyOneSurface` exists to prevent for the
    // controls that moved out of the panel.
    //
    // Scoped to the TYPE and then to its `body`, the mechanism
    // `everyTopLevelSurfaceShowsTheRunningVersion` uses: a `contains` over the
    // whole file proves the seam is NAMED somewhere in it, and a helper that
    // names it while `body` renders nothing is exactly the hole that scoping
    // closes.
    let code = try quickStartSurface(named: "QuickStartView.swift")
    let declared = try #require(braceBlock(after: "struct QuickStartView: View", in: code), """
        QuickStartView.swift declares no `struct QuickStartView: View`, so the \
        guard names a page this package does not have.
        """)
    let body = try #require(braceBlock(after: "var body: some View", in: declared.block)?.block, """
        QuickStartView declares no body, so nothing in it asks the user anything.
        """)

    // The three questions, each named by the SEAM it is bound to rather than by
    // its wording. A label is a string this check cannot read; a binding is the
    // thing that makes the answer land on the right key.
    for seam in ["$model.holdDisplayAwake", "model.batteryFloorPercent", "model.setAdvises("] {
        #expect(body.contains(seam), """
            QuickStartView.body never names \(seam), so one of the three \
            questions is not asked — or is asked through a path that does not \
            write the key the Settings window writes.
            """)
    }

    // BOTH EXITS. A page with no way out of it is a first-run experience the
    // user cannot leave.
    #expect(body.contains("model.completeQuickStart()"))
    #expect(body.contains("model.deferQuickStart()"))

    // NO PRIVATE COPY of any answer. `@State` here is the mirror that goes
    // stale: the wizard and the Settings window bind to the same model
    // properties precisely so that they cannot disagree.
    #expect(code.contains("@State") == false, """
        QuickStartView.swift declares @State. Every answer this page shows is \
        owned by ServingModel, and a copy held here disagrees with the Settings \
        window the moment either changes.
        """)

    // NO SECOND BOUNDING SITE, the rule `PreferencesView.swift` is already held
    // to: the floor is bounded at `PowerInputs.init` and nowhere else, so this
    // page builds its control OVER the permitted range rather than correcting a
    // value after the fact.
    #expect(code.contains("BatteryFloor.permitted"))
    #expect(code.contains("BatteryFloor.bounded") == false)
}

@Test func theQuickStartPageIsRenderedUnconditionallyByThePreferencesWindow() throws {
    // Named bug this catches: the page present in the file and unreachable —
    // `if false { QuickStartView(model: model) }` keeps every `contains` in
    // this package green while no user is ever asked anything. That is not a
    // hypothetical mutation: `everyMovedControlIsRenderedAsUnconditionallyAsTheHeadingsAboveIt`
    // records a build where wrapping three controls that way left the suite at
    // rc=0 with 856 tests passing and the window shipped with nothing to click.
    //
    // BRACE DEPTH against an unconditional neighbour, which is that guard's
    // mechanism. `Text("Power")` is the anchor for the same reason it is there:
    // a build where a section heading is conditional is not a build where this
    // check is the problem.
    let prefs = try quickStartSurface(named: "PreferencesView.swift")

    let anchorDepth = try #require(braceDepth(atFirst: "Text(\"Power\")", in: prefs), """
        PreferencesView.swift no longer contains Text("Power"), so this guard \
        has no unconditional neighbour and measured nothing.
        """)

    // ONE BRACE SHALLOWER than the page's own children, and that is structural
    // rather than a magic number: the quick start is presented as a modifier on
    // the `ScrollView`, so its content closure opens inside `body` while
    // `Text("Power")` sits inside the `ScrollView`'s `VStack`.
    //
    // THIS RELATIONSHIP IS A DESIGNED UPDATE POINT, the shape
    // `everyMovedControlIsRenderedAsUnconditionallyAsTheHeadingsAboveIt` uses.
    // A legitimate container around the presentation turns this red, and the
    // fix is to say which brace was added — not to widen the comparison to an
    // inequality, which is what `if false { … }` passes straight through.
    let pageDepth = try #require(braceDepth(atFirst: "QuickStartView(model:", in: prefs), """
        PreferencesView.swift never builds a QuickStartView, so the one window \
        this product has does not present the quick start and no user is ever \
        asked.
        """)
    #expect(pageDepth == anchorDepth - 1, """
        PreferencesView.swift builds the quick start at brace depth \
        \(pageDepth) while the page's own children sit at \(anchorDepth). It is \
        inside something they are not — an `if`, a `switch`, a closure — so the \
        page exists in the file and no user may ever reach it.
        """)

    // The GATE is the model's, and it is the only one. A second condition here
    // is a second place the wizard can be switched off, and the model's is the
    // one every behaviour check above reads.
    #expect(prefs.contains("model.quickStartPending"), """
        PreferencesView.swift never reads quickStartPending, so whatever \
        decides to show the quick start is not the record every check in this \
        file drives.
        """)
}
