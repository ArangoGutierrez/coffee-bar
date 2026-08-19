// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import CoffeeBarCore
import CoffeeBarIngest
import CoffeeBarPower
import CoffeeBarTestSupport
@testable import CoffeeBarUI

// The update check, issue #29, and the one thing it is NOT.
//
// **It tells you. It does not update itself.** No bundle is replaced, nothing
// is downloaded but a few bytes of JSON, and the only outcome is a sentence in
// the Preferences window. `brew install coffee-bar` puts the app inside the
// Homebrew prefix, so a bundle that replaced itself would desynchronise
// Homebrew's own manifest and the next `brew upgrade` would fight it.
//
// This file holds the DECISION half: what the published bytes mean, what two
// version strings mean beside each other, when a check is due, and what the
// model does with the answer. The one file that reaches the network is guarded
// in `AppLayerBoundary_test.swift`, beside the egress rule it narrows, and its
// own shape is pinned in `UpdateChecker_test.swift`.

/// The package root, resolved from `#filePath`.
///
/// A fourth resolver in this target, for the reason `PreferencesView_test.swift`
/// gives for being the third: the others are `private`, which in Swift is scoped
/// to their own file, and widening a boundary guard's internals to save four
/// lines is the worse trade.
private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarUITests/UpdateCheck_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarUITests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // the package root
}

// MARK: - What two version strings mean beside each other

@Test func aNewerPublishedReleaseIsReportedAsAvailable() {
    // The whole point of the feature, in one line.
    #expect(UpdateCheck.compare(running: "0.2.2", published: "0.2.3")
            == .updateAvailable("0.2.3"))
}

@Test func theSameVersionReportsNothingToDo() {
    #expect(UpdateCheck.compare(running: "0.2.2", published: "0.2.2") == .upToDate)
}

@Test func aRunningBuildAheadOfThePublishedReleaseReportsNothingToDo() {
    // A maintainer running a build newer than the published file must not be
    // told to "update" to an older release. The static manifest is published by
    // hand, so it lags the tag by definition between a tag and a site edit —
    // this is the ordinary state of the repository, not an exotic one.
    #expect(UpdateCheck.compare(running: "0.3.0", published: "0.2.2") == .upToDate)
}

@Test func versionsAreComparedAsNumbersAndNeverAsText() {
    // Named bug this catches, and it is the classic one: comparing the two
    // stamps as STRINGS. "0.10.0" sorts BEFORE "0.9.0" lexically, so a user on
    // the newest build would be told to update to an older one, and a user on
    // 0.9.0 would never hear about 0.10.0 at all. Both directions are asserted
    // because a single-direction check passes under a string comparison.
    #expect(UpdateCheck.compare(running: "0.9.0", published: "0.10.0")
            == .updateAvailable("0.10.0"))
    #expect(UpdateCheck.compare(running: "0.10.0", published: "0.9.0") == .upToDate)
    #expect(UpdateCheck.compare(running: "1.2.10", published: "1.2.9") == .upToDate)
    #expect(UpdateCheck.compare(running: "1.2.9", published: "1.2.10")
            == .updateAvailable("1.2.10"))
}

@Test func eachComponentOutranksTheOnesBelowIt() {
    #expect(UpdateCheck.compare(running: "0.9.9", published: "1.0.0")
            == .updateAvailable("1.0.0"))
    #expect(UpdateCheck.compare(running: "1.0.0", published: "0.9.9") == .upToDate)
    #expect(UpdateCheck.compare(running: "1.1.0", published: "1.0.9") == .upToDate)
}

@Test func aBuildAheadOfItsTagIsComparedOnTheTagItIsAheadOf() {
    // `scripts/build-app.sh` stamps `git describe --tags`, so a tree three
    // commits past v0.2.2 reports `0.2.2-3-g1258578`. That IS a usable version —
    // it names the release it descends from — and refusing it would leave every
    // developer build unable to say anything at all.
    #expect(UpdateCheck.compare(running: "0.2.2-3-g1258578", published: "0.2.3")
            == .updateAvailable("0.2.3"))
    #expect(UpdateCheck.compare(running: "0.2.2-3-g1258578", published: "0.2.2")
            == .upToDate)
}

@Test func aDirtyTreeIsStillComparedOnItsTag() {
    // `git describe --tags --dirty` appends `-dirty`, which is a second suffix
    // on the same shape.
    #expect(UpdateCheck.compare(running: "0.2.2-3-g1258578-dirty", published: "0.2.3")
            == .updateAvailable("0.2.3"))
}

// MARK: - The two stamps that must never be compared to anything

@Test func anUnstampedBuildIsNeverComparedToARelease() {
    // `AppVersion.display` reports `unknown` for an absent, missing, mistyped or
    // blank `CFBundleShortVersionString` — a `swift run` build has no info
    // dictionary at all. There is no number in that word, and inventing one is
    // the failure `AppVersion` exists to refuse. Comparing it would either tell
    // a developer their build is current when nothing knows what it is, or
    // nag them about an update they already have.
    #expect(UpdateCheck.compare(running: AppVersion.unknown, published: "0.2.3")
            == .cannotCompare(UpdateCheck.unstampedLine))
}

@Test func anUntaggedDevelopmentBuildIsNeverComparedToARelease() {
    // `scripts/build-app.sh` stamps `0.0.0-dev` when neither `git describe` nor
    // `COFFEE_BAR_VERSION` answers. It PARSES as three numbers, which is exactly
    // why it needs naming: read as a version it is older than every release
    // ever made, so every such build would be told to update — permanently, and
    // to a release it may well already contain.
    #expect(UpdateCheck.compare(running: "0.0.0-dev", published: "0.2.3")
            == .cannotCompare(UpdateCheck.unstampedLine))
    // And the same stamp on the PUBLISHED side is refused too, rather than
    // being read as "an ancient release".
    #expect(UpdateCheck.compare(running: "0.2.2", published: "0.0.0-dev")
            == .cannotCompare(UpdateCheck.unreadablePublishedLine))
}

@Test func aPublishedVersionThatIsNotThreeNumbersIsRefusedRatherThanGuessed() {
    // The manifest is a hand-edited file on a static site. A typo in it must
    // produce a refusal a user can read, never a comparison against a number
    // the parser invented from the wreckage.
    for bad in ["", "   ", "0.2", "0.2.2.1", "v0.2.2", "0.2.x", "latest", "-1.0.0", "0..2"] {
        #expect(UpdateCheck.compare(running: "0.2.2", published: bad)
                == .cannotCompare(UpdateCheck.unreadablePublishedLine),
                "\"\(bad)\" was accepted as a published version")
    }
}

@Test func onlyASCIIDigitsCountAsAVersionNumber() {
    // `Character.isNumber` is true of `١` (Arabic-Indic one) and of `½`, so a
    // parser written on it accepts a string `Int(_:)` then refuses — or worse,
    // one it accepts with a different value than the glyphs suggest. The
    // refusal has to happen at the parse, not at the conversion.
    #expect(UpdateCheck.compare(running: "0.2.2", published: "٠.٢.٣")
            == .cannotCompare(UpdateCheck.unreadablePublishedLine))
}

@Test func aRunningStampThatIsNotAVersionIsRefusedTheSameWay() {
    // The running stamp comes out of an Info.plist, which anybody can edit and
    // which a Homebrew formula fills from `COFFEE_BAR_VERSION`.
    #expect(UpdateCheck.compare(running: "not-a-version", published: "0.2.3")
            == .cannotCompare(UpdateCheck.unstampedLine))
}

// MARK: - What the published bytes are allowed to be

@Test func aWellFormedManifestYieldsItsVersion() {
    let body = Data(#"{"version":"0.2.3"}"#.utf8)
    #expect(UpdateCheck.manifest(from: body, statusCode: 200)
            == .success(ReleaseManifest(version: "0.2.3")))
}

@Test func aKeyThisBuildDoesNotKnowIsIgnoredRatherThanRefused() {
    // The manifest is published from this repository and read by builds older
    // than the edit that added a key. A decoder that refused an unknown key
    // would make every future addition break every shipped build.
    let body = Data(#"{"version":"0.2.3","notes":"https://example.invalid"}"#.utf8)
    #expect(UpdateCheck.manifest(from: body, statusCode: 200)
            == .success(ReleaseManifest(version: "0.2.3")))
}

@Test func aManifestWithNoVersionIsRefused() {
    #expect(UpdateCheck.manifest(from: Data(#"{"latest":"0.2.3"}"#.utf8), statusCode: 200)
            == .failure(.unreadable))
}

@Test func aBlankVersionIsRefusedRatherThanComparedAsEmpty() {
    #expect(UpdateCheck.manifest(from: Data(#"{"version":"   "}"#.utf8), statusCode: 200)
            == .failure(.unreadable))
}

@Test func bytesThatAreNotJSONAreRefused() {
    // The likeliest real failure by far: a captive-portal login page, or the
    // site's own 404 HTML, arriving where JSON was expected.
    let body = Data("<!doctype html><title>Sign in to the network</title>".utf8)
    #expect(UpdateCheck.manifest(from: body, statusCode: 200) == .failure(.unreadable))
}

@Test func anAnswerThatIsNotOKIsRefusedBeforeItIsParsed() {
    // A 404 body on this site is HTML, so `.unreadable` would be reached
    // anyway — but a 500 with a valid-looking JSON body must not be believed
    // either, and the status is the honest reason to give.
    #expect(UpdateCheck.manifest(from: Data(#"{"version":"9.9.9"}"#.utf8), statusCode: 404)
            == .failure(.status(404)))
    #expect(UpdateCheck.manifest(from: Data(#"{"version":"9.9.9"}"#.utf8), statusCode: 500)
            == .failure(.status(500)))
    // Zero is what the fetcher reports when the answer carried no HTTP status
    // at all, and it must not read as "fine".
    #expect(UpdateCheck.manifest(from: Data(#"{"version":"9.9.9"}"#.utf8), statusCode: 0)
            == .failure(.status(0)))
}

@Test func anOversizedAnswerIsRefusedWithoutBeingParsed() {
    // The manifest is two dozen bytes. A body far larger than that is not this
    // file, whatever it decodes to, and handing an unbounded stranger's payload
    // to a decoder is a cost this feature has no reason to accept.
    let padding = String(repeating: "x", count: UpdateCheck.maxManifestBytes)
    let body = Data("{\"version\":\"0.2.3\",\"pad\":\"\(padding)\"}".utf8)
    #expect(body.count > UpdateCheck.maxManifestBytes)
    #expect(UpdateCheck.manifest(from: body, statusCode: 200)
            == .failure(.tooLarge(body.count)))
}

@Test func aManifestExactlyAtTheCapIsStillRead() {
    // The other side of the bound, so the cap is a bound and not an off-by-one
    // that refuses the file it was sized for.
    let head = #"{"version":"0.2.3","pad":""#
    let tail = #""}"#
    let padding = String(repeating: "x", count: UpdateCheck.maxManifestBytes - head.count - tail.count)
    let body = Data((head + padding + tail).utf8)
    #expect(body.count == UpdateCheck.maxManifestBytes)
    #expect(UpdateCheck.manifest(from: body, statusCode: 200)
            == .success(ReleaseManifest(version: "0.2.3")))
}

// MARK: - When a check is due, which is the only timer this feature has

@Test func aCheckIsDueWhenNothingHasEverBeenChecked() {
    #expect(UpdateCheck.isDue(lastChecked: nil, now: Date(timeIntervalSince1970: 1)) == true)
}

@Test func aCheckIsNotDueBeforeTheIntervalHasElapsed() {
    let last = Date(timeIntervalSince1970: 1_000_000)
    #expect(UpdateCheck.isDue(lastChecked: last,
                              now: last.addingTimeInterval(UpdateCheck.interval - 1)) == false)
}

@Test func aCheckIsDueOnceTheIntervalHasElapsed() {
    let last = Date(timeIntervalSince1970: 1_000_000)
    #expect(UpdateCheck.isDue(lastChecked: last,
                              now: last.addingTimeInterval(UpdateCheck.interval)) == true)
}

@Test func aLastCheckInTheFutureIsDueRatherThanNeverDueAgain() {
    // Named bug this catches: a subtraction that goes negative and compares
    // false for ever. A stamp ahead of now arrives from a clock the user moved
    // back, or from a preferences file copied off another machine, and the
    // wrong answer here is the one that silently disables the feature until
    // the wall clock catches up — which for a year-ahead stamp is a year.
    let last = Date(timeIntervalSince1970: 2_000_000)
    #expect(UpdateCheck.isDue(lastChecked: last,
                              now: last.addingTimeInterval(-1)) == true)
}

@Test func theIntervalIsTheOneStatedInTheWindow() {
    // NO HIDDEN DURATIONS — `docs/ROADMAP.md`. A period the user cannot see is
    // exactly what that principle forbids, so the sentence the window renders
    // has to name the same period the code enforces. This pins the two
    // together: change the constant to an hour and the note still says "once a
    // day", and this goes red.
    #expect(UpdateCheck.interval == 24 * 60 * 60)
    #expect(UpdateCheck.intervalNote.contains("once a day"))
    // And it says what the check does NOT do, because that is the half a user
    // cannot verify by waiting.
    #expect(UpdateCheck.intervalNote.contains("installs nothing"))
}

// MARK: - The sentence the user reads

@Test func theLastCheckLineNamesAnAbsentCheckRatherThanADate() {
    #expect(UpdateCheck.lastCheckLine(nil) == "Last checked: never.")
}

@Test func theLastCheckLineRendersAStableUnambiguousStamp() {
    // A FIXED format and `en_US_POSIX`, not the user's locale conventions, and
    // the reason is that this line ends up pasted into bug reports. "8/14/26,
    // 12:34 AM" is ambiguous to half the world and re-orders itself per locale;
    // a maintainer reading two of them side by side cannot tell which is newer.
    //
    // The time zone stays the machine's, because the question the line answers
    // is "how long ago was that" and the user thinks in local time.
    let when = Date(timeIntervalSince1970: 1_786_000_000)
    #expect(UpdateCheck.lastCheckLine(when, timeZone: TimeZone(identifier: "UTC")!)
            == "Last checked: 2026-08-06 07:06.")
}

@Test func theSentenceForEachVerdictSaysWhatHappenedAndNeverGuesses() {
    #expect(UpdateCheck.sentence(for: .upToDate) == UpdateCheck.upToDateLine)
    #expect(UpdateCheck.sentence(for: .updateAvailable("0.2.3"))
            == "coffee-bar 0.2.3 is published. coffee-bar installs nothing: update it the way you installed it.")
    // A refusal's own words are carried through verbatim rather than folded
    // into one vague sentence — "could not compare" tells a user nothing they
    // can act on, and the three reasons want three different actions.
    #expect(UpdateCheck.sentence(for: .cannotCompare(UpdateCheck.unreachableLine))
            == UpdateCheck.unreachableLine)
}

@Test func eachRefusalReasonReachesTheUserAsItsOwnSentence() {
    #expect(UpdateCheck.sentence(for: .status(503)).contains("503"))
    #expect(UpdateCheck.sentence(for: .tooLarge(9_000)) == UpdateCheck.tooLargeLine)
    #expect(UpdateCheck.sentence(for: .unreadable) == UpdateCheck.unreadablePublishedLine)
    // Three distinct sentences, so a user reading one knows which happened.
    let sentences = Set([UpdateCheck.sentence(for: .status(503)),
                         UpdateCheck.sentence(for: .tooLarge(9_000)),
                         UpdateCheck.sentence(for: .unreadable)])
    #expect(sentences.count == 3)
}

// MARK: - The manifest this repository actually publishes

@Test func thePublishedManifestStatesTheNewestReleaseTheChangelogRecords() {
    // The recorded objection to the static-file design, answered where it can
    // be: a file published by hand drifts from the release it claims to
    // describe. `CHANGELOG.md` calls itself "the source of truth for the version
    // history", and `site/changelog.html` and every sidebar are already held
    // against it, so this closes the loop for the one file the app reads.
    //
    // Named bug this catches: cutting a release, editing the four site pages,
    // and forgetting the fifth file — which now tells every running copy of
    // coffee-bar that the OLD version is current.
    let changelog = try! String(contentsOf: packageRoot.appending(path: "CHANGELOG.md"),
                                encoding: .utf8)
    let headings = changelog.split(separator: "\n")
        .compactMap { line -> String? in
            guard line.hasPrefix("## [") else { return nil }
            return line.dropFirst(4).prefix { $0 != "]" }.description
        }
        .filter { UpdateCheck.releaseCore(of: $0) != nil }

    #expect(headings.count >= 3,
            "the changelog scan found \(headings.count) release heading(s); it has rotted")

    let newest = headings[0]
    let published = try! Data(contentsOf: packageRoot.appending(path: "site/latest.json"))

    #expect(UpdateCheck.manifest(from: published, statusCode: 200)
            == .success(ReleaseManifest(version: newest)),
            "site/latest.json does not state \(newest), the newest release in CHANGELOG.md")
}

@Test func thePublishedManifestCarriesNothingButTheVersion() {
    // The reply is the only thing this feature brings back onto the machine, so
    // its whole key set is pinned rather than merely parsed. A field added here
    // later has to be read against §12's non-goals before it ships, which is the
    // same friction `theReadPayloadCarriesASchemaVersionAndNothingUnlisted` puts
    // on the ingest socket's own payload.
    let published = try! Data(contentsOf: packageRoot.appending(path: "site/latest.json"))
    let object = try! JSONSerialization.jsonObject(with: published)
    let keys = Set((object as? [String: Any] ?? [:]).keys)

    #expect(keys == ["version"],
            "site/latest.json carries \(keys.sorted()); it may carry only the version")
}

// MARK: - What the model does with the answer

/// A settings store held in memory.
///
/// Every `ServingModel` built in this file is handed one, for the reason
/// `ServingModel_test.swift` gives: the shipping default is the preferences of
/// whoever runs the suite, and a check that took it would read and edit them.
private final class FakeSettings: SettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init(_ initial: [String: Any] = [:]) { values = initial }

    func bool(forKey key: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return values[key] as? Bool
    }

    func setBool(_ value: Bool, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    func integer(forKey key: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return values[key] as? Int
    }

    func setInteger(_ value: Int, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    func stringArray(forKey key: String) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        return values[key] as? [String]
    }

    func setStringArray(_ value: [String], forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }
}

/// A fetcher that answers from memory and counts how often it was asked.
///
/// It reaches no network, which is the point: every check in this file drives
/// the model's decision, and a suite that opened a socket to a real host would
/// fail on an aeroplane and would post from a machine that never asked to.
private final class FakeFetcher: ReleaseManifestFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var answer: Result<FetchedManifest, any Error>
    private var asked = 0

    init(_ answer: Result<FetchedManifest, any Error>) { self.answer = answer }

    convenience init(version: String) {
        self.init(.success(FetchedManifest(body: Data("{\"version\":\"\(version)\"}".utf8),
                                           statusCode: 200)))
    }

    var askCount: Int {
        lock.lock(); defer { lock.unlock() }
        return asked
    }

    /// Records the ask and hands back the answer, SYNCHRONOUSLY.
    ///
    /// Split out of `fetch()` because `NSLock.lock()` is unavailable from an
    /// asynchronous context — a lock held across a suspension point deadlocks
    /// under a cooperative thread pool. Nothing here suspends, and keeping the
    /// whole critical section in a non-async method is what says so.
    private func take() -> Result<FetchedManifest, any Error> {
        lock.lock()
        defer { lock.unlock() }
        asked += 1
        return answer
    }

    func fetch() async throws -> FetchedManifest { try take().get() }
}

private struct NoAnswer: Error {}

/// A power reader that holds still.
private final class SteadyReader: PowerReadingProviding, @unchecked Sendable {
    func read() -> PowerReading { PowerReading(source: .ac, percent: 80) }
}

/// An assertion holder that records nothing and refuses nothing.
private final class QuietHolder: AssertionHolding, @unchecked Sendable {
    @discardableResult
    func acquire(displaySleep: Bool) -> Bool { true }
    func release() {}
}

/// Starts nothing, for the reason `ServingModel_test.swift` gives: the shipping
/// default binds the real ingest socket.
private final class NoopListener: IngestListening, @unchecked Sendable {
    func start(onEvent: @escaping @Sendable (AgentTool, HookEvent) -> Void) throws {}
    func stop() {}
    var isReady: Bool { false }
}

/// A hook-health reader pointed at the committed fixture, so no check reads the
/// settings file of whoever runs the suite.
private func fixtureHealth() -> HookHealthReader {
    HookHealthReader(settingsURL: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/claude-settings/wired.json"))
}

@MainActor
private func model(fetching fetcher: any ReleaseManifestFetching,
                   settings: FakeSettings = FakeSettings(),
                   now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_786_000_000) })
    -> ServingModel {
    ServingModel(holder: QuietHolder(),
                 reader: SteadyReader(),
                 health: fixtureHealth(),
                 settings: settings,
                 listener: NoopListener(),
                 now: now,
                 updates: fetcher)
}

@MainActor
@Test func aModelThatHasNotCheckedSaysSoRatherThanClaimingItIsCurrent() {
    // The state every user is in at first launch, and the one a "silence means
    // fine" design gets wrong: a window that said "up to date" before any check
    // had run would be stating a fact nobody had established.
    let model = model(fetching: FakeFetcher(version: "0.2.3"))

    #expect(model.updateVerdict == nil)
    #expect(model.updateStatusLine == UpdateCheck.neverCheckedLine)
    #expect(model.lastUpdateCheckLine == "Last checked: never.")
}

@MainActor
@Test func aNewerPublishedVersionReachesTheWindowAsASentence() async {
    let model = model(fetching: FakeFetcher(version: "0.2.3"))

    await model.checkForUpdates(version: "0.2.2")

    #expect(model.updateVerdict == .updateAvailable("0.2.3"))
    #expect(model.updateStatusLine.contains("0.2.3"))
}

@MainActor
@Test func aHostThatCannotBeReachedIsReportedAndNotSwallowed() async {
    // Named bug this catches: a `try?` that leaves the previous verdict — or
    // no verdict — on screen. A user who pressed Check now on a train has to
    // be told the check did not happen, or they read a stale "up to date" as
    // this minute's answer.
    let model = model(fetching: FakeFetcher(.failure(NoAnswer())))

    await model.checkForUpdates(version: "0.2.2")

    #expect(model.updateVerdict == .cannotCompare(UpdateCheck.unreachableLine))
}

@MainActor
@Test func aFailedCheckStillMovesTheLastCheckedTimeOn() async {
    // Deliberate, and it is the difference between a bounded feature and a
    // retry loop: an attempt that failed is still an attempt, and recording it
    // is what stops a machine with no network asking again on every tick. The
    // window says what the attempt CONCLUDED separately, so the pair cannot
    // read as a successful check.
    let settings = FakeSettings()
    let when = Date(timeIntervalSince1970: 1_786_000_000)
    let model = model(fetching: FakeFetcher(.failure(NoAnswer())),
                      settings: settings, now: { when })

    await model.checkForUpdates(version: "0.2.2")

    #expect(model.lastUpdateCheck == when)
    #expect(settings.integer(forKey: SettingsKey.lastUpdateCheck)
            == Int(when.timeIntervalSince1970))
    #expect(model.updateStatusLine == UpdateCheck.unreachableLine)
}

@MainActor
@Test func theLastCheckedTimeSurvivesARelaunch() async {
    // A relaunch is a second model over the same store. Without the read below
    // the interval resets on every launch, so a user who opens and closes the
    // app four times in an afternoon posts four requests — the "at most once a
    // day" the window states would be false.
    let settings = FakeSettings()
    let when = Date(timeIntervalSince1970: 1_786_000_000)
    let first = model(fetching: FakeFetcher(version: "0.2.3"), settings: settings, now: { when })
    await first.checkForUpdates(version: "0.2.2")

    let second = model(fetching: FakeFetcher(version: "0.2.3"), settings: settings, now: { when })
    #expect(second.lastUpdateCheck == when)
    #expect(second.lastUpdateCheckLine != "Last checked: never.")
}

@MainActor
@Test func aDueCheckRunsAndAnUndueOneDoesNotPostAtAll() async {
    // The interval enforced where it matters — on the wire, not on the label.
    // `askCount` is the discriminator: a model that "respected" the interval by
    // discarding the ANSWER would still have made the request, which is the one
    // thing this feature is allowed to do at all and must therefore do rarely.
    let when = Date(timeIntervalSince1970: 1_786_000_000)
    let fresh = FakeSettings([SettingsKey.lastUpdateCheck: Int(when.timeIntervalSince1970)])
    let quiet = FakeFetcher(version: "0.2.3")
    let unchanged = model(fetching: quiet, settings: fresh, now: { when.addingTimeInterval(60) })

    await unchanged.checkForUpdatesIfDue(version: "0.2.2")
    #expect(quiet.askCount == 0)

    let stale = FakeSettings([SettingsKey.lastUpdateCheck: Int(when.timeIntervalSince1970)])
    let busy = FakeFetcher(version: "0.2.3")
    let due = model(fetching: busy, settings: stale,
                    now: { when.addingTimeInterval(UpdateCheck.interval) })

    await due.checkForUpdatesIfDue(version: "0.2.2")
    #expect(busy.askCount == 1)
    #expect(due.updateVerdict == .updateAvailable("0.2.3"))
}

@MainActor
@Test func pressingCheckNowIgnoresTheIntervalCompletely() async {
    // The user asked. An explicit press that silently did nothing because the
    // last check was an hour ago is a button that lies about having a job.
    let when = Date(timeIntervalSince1970: 1_786_000_000)
    let fresh = FakeSettings([SettingsKey.lastUpdateCheck: Int(when.timeIntervalSince1970)])
    let fetcher = FakeFetcher(version: "0.2.3")
    let model = model(fetching: fetcher, settings: fresh, now: { when.addingTimeInterval(60) })

    await model.checkForUpdates(version: "0.2.2")

    #expect(fetcher.askCount == 1)
}

@MainActor
@Test func anUnstampedBuildNeverPostsAtAll() async {
    // The request is the thing this feature spends, and a build whose stamp
    // cannot be compared to anything has nothing to learn from the answer. So
    // the refusal happens BEFORE the fetch rather than after it — measured on
    // `askCount`, because a model that fetched and then refused to compare
    // would look identical in the window and would still have posted.
    let fetcher = FakeFetcher(version: "0.2.3")
    let model = model(fetching: fetcher)

    await model.checkForUpdates(version: AppVersion.unknown)

    #expect(fetcher.askCount == 0)
    #expect(model.updateVerdict == .cannotCompare(UpdateCheck.unstampedLine))
}

@MainActor
@Test func aRefusedPublishedFileIsReportedWithItsOwnReason() async {
    let fetcher = FakeFetcher(.success(FetchedManifest(body: Data("<html>".utf8),
                                                       statusCode: 200)))
    let model = model(fetching: fetcher)

    await model.checkForUpdates(version: "0.2.2")

    #expect(model.updateVerdict == .cannotCompare(UpdateCheck.unreadablePublishedLine))
}

// MARK: - Issue #147: the stamp and the verdict must survive together

@MainActor
@Test func aRestoredStampWithNoVerdictNeverSaysItHasNotLooked() {
    // Issue #147, read off the maintainer's machine: `defaults read` carried
    // `lastUpdateCheck = 1787135748` and no verdict whatever, which is the state
    // every install made before the verdict key existed is in at its first
    // launch on this build. The window then printed both of these, one directly
    // under the other:
    //
    //     coffee-bar has not looked for a newer version yet.
    //     Last checked: 2026-08-19 12:35.
    //
    // A user reads the two lines as one sentence, so the check is on the PAIR.
    // Either line alone is correct; together they are the defect. It is asserted
    // as the never-checked line NOT appearing beside a real time, rather than as
    // some string being non-empty, because a model that returned "" would have
    // satisfied the second and still shipped the first.
    let when = Date(timeIntervalSince1970: 1_787_135_748)
    let settings = FakeSettings([SettingsKey.lastUpdateCheck: Int(when.timeIntervalSince1970)])
    let model = model(fetching: FakeFetcher(version: "0.2.3"), settings: settings)

    #expect(model.lastUpdateCheck == when)
    #expect(model.lastUpdateCheckLine != "Last checked: never.")
    #expect(model.updateStatusLine != UpdateCheck.neverCheckedLine)

    // And it invented nothing to fill the gap. A verdict conjured here would be
    // the opposite failure: a conclusion reported that no check ever reached.
    #expect(model.updateVerdict == nil)
    #expect(model.updateStatusLine != UpdateCheck.upToDateLine)
    #expect(model.updateStatusLine == UpdateCheck.verdictNotRecordedLine)
}

@MainActor
@Test func aVerdictSurvivesARelaunchBesideItsStamp() async {
    // The other half of issue #147, and the half a third sentence cannot do. A
    // relaunch is a second model over the same store, checking nothing.
    let when = Date(timeIntervalSince1970: 1_786_000_000)
    let settings = FakeSettings()
    let first = model(fetching: FakeFetcher(version: "0.2.3"), settings: settings, now: { when })
    await first.checkForUpdates(version: "0.2.2")
    #expect(first.updateVerdict == .updateAvailable("0.2.3"))

    let second = model(fetching: FakeFetcher(version: "0.2.3"), settings: settings, now: { when })

    #expect(second.updateVerdict == .updateAvailable("0.2.3"))
    #expect(second.updateStatusLine == first.updateStatusLine)
    #expect(second.updateStatusLine.contains("0.2.3"))
    #expect(second.updateStatusLine != UpdateCheck.neverCheckedLine)
    #expect(second.updateStatusLine != UpdateCheck.verdictNotRecordedLine)
}

@MainActor
@Test func whatIsWrittenDownIsATagAndNotTheSentence() async {
    // Named bug this catches: storing `UpdateCheck.sentence(for:)` output. That
    // restores perfectly today and shows a retired sentence the first time
    // anybody edits one, which is issue #147's own shape a release later. The
    // published version is data and is carried; the words around it are not.
    let settings = FakeSettings()
    let model = model(fetching: FakeFetcher(version: "0.2.3"), settings: settings)

    await model.checkForUpdates(version: "0.2.2")

    #expect(settings.stringArray(forKey: SettingsKey.lastUpdateVerdict)
            == ["updateAvailable", "0.2.3"])
}

@MainActor
@Test func aRestoredReasonIsSpelledByTheBuildThatShowsIt() async {
    // A failed check is the state the machine in issue #147 was actually in, so
    // it is the one a relaunch has to carry. The tag goes in; the sentence comes
    // out of this build's constant on the way back.
    let when = Date(timeIntervalSince1970: 1_786_000_000)
    let settings = FakeSettings()
    let first = model(fetching: FakeFetcher(.failure(NoAnswer())),
                      settings: settings, now: { when })
    await first.checkForUpdates(version: "0.2.2")

    #expect(settings.stringArray(forKey: SettingsKey.lastUpdateVerdict) == ["unreachable"])

    let second = model(fetching: FakeFetcher(version: "0.2.3"), settings: settings, now: { when })

    #expect(second.updateVerdict == .cannotCompare(UpdateCheck.unreachableLine))
    #expect(second.updateStatusLine != UpdateCheck.neverCheckedLine)
}

@MainActor
@Test func aStoredVerdictThisBuildCannotReadInventsNothing() {
    // A newer build can write a case this one has never heard of, a preferences
    // file can be hand edited, and a key collision can put a list of process
    // names here. Reading any of them as `upToDate` would report a conclusion no
    // check reached; reading them as never-checked is issue #147 again, since
    // the stamp beside them is real.
    let when = Date(timeIntervalSince1970: 1_787_135_748)
    let settings = FakeSettings([
        SettingsKey.lastUpdateCheck: Int(when.timeIntervalSince1970),
        SettingsKey.lastUpdateVerdict: ["somethingThisBuildHasNeverHeardOf", "7"]
    ])
    let model = model(fetching: FakeFetcher(version: "0.2.3"), settings: settings)

    #expect(model.updateVerdict == nil)
    #expect(model.updateStatusLine != UpdateCheck.upToDateLine)
    #expect(model.updateStatusLine != UpdateCheck.neverCheckedLine)
    #expect(model.updateStatusLine == UpdateCheck.verdictNotRecordedLine)
}

@Test func everyStoredVerdictReadsBackAsItself() {
    // The stored form is a FORMAT: written by one launch and read by the next,
    // so a writer and a reader that disagree lose the verdict silently while
    // both halves still compile.
    let all: [UpdateCheck.StoredVerdict] = [
        .upToDate,
        .updateAvailable("0.10.0"),
        .unreachable,
        .refused(.status(503)),
        .refused(.tooLarge(9001)),
        .refused(.unreadable)
    ]

    for stored in all {
        #expect(UpdateCheck.storedVerdict(from: UpdateCheck.fields(of: stored)) == stored,
                "\(stored) did not read back as itself")
    }

    // Named bug: a payload that is missing, doubled, blank or not an ASCII
    // number read as a NEIGHBOURING case rather than as unknown. Every one of
    // these has to answer nil, because the caller's only other move is to state
    // a conclusion nothing reached.
    #expect(UpdateCheck.storedVerdict(from: []) == nil)
    #expect(UpdateCheck.storedVerdict(from: ["upToDate", "0.2.3"]) == nil)
    #expect(UpdateCheck.storedVerdict(from: ["updateAvailable"]) == nil)
    #expect(UpdateCheck.storedVerdict(from: ["updateAvailable", "   "]) == nil)
    #expect(UpdateCheck.storedVerdict(from: ["unreachable", "why"]) == nil)
    #expect(UpdateCheck.storedVerdict(from: ["status"]) == nil)
    #expect(UpdateCheck.storedVerdict(from: ["status", "50\u{0663}"]) == nil)
    #expect(UpdateCheck.storedVerdict(from: ["status", "-1"]) == nil)
    #expect(UpdateCheck.storedVerdict(from: ["tooLarge"]) == nil)
    // The key-collision case named in `SettingsKey.lastUpdateVerdict`: a
    // demotable process list landing here matches no tag and stays unknown.
    #expect(UpdateCheck.storedVerdict(from: ["Xcode", "Safari"]) == nil)
}

@Test func aStoredVerdictBecomesTheSameSentenceTheCheckShowed() {
    // The restore path and the check path share `verdict(of:)`, which is what
    // stops a relaunch showing a second spelling of the same answer. Compared
    // against the constants the window renders, not against a copy of them.
    #expect(UpdateCheck.verdict(of: .upToDate) == .upToDate)
    #expect(UpdateCheck.verdict(of: .updateAvailable("0.3.0")) == .updateAvailable("0.3.0"))
    #expect(UpdateCheck.verdict(of: .unreachable)
            == .cannotCompare(UpdateCheck.unreachableLine))
    #expect(UpdateCheck.verdict(of: .refused(.unreadable))
            == .cannotCompare(UpdateCheck.unreadablePublishedLine))
    #expect(UpdateCheck.verdict(of: .refused(.tooLarge(9001)))
            == .cannotCompare(UpdateCheck.tooLargeLine))
    #expect(UpdateCheck.sentence(for: UpdateCheck.verdict(of: .refused(.status(503))))
            .contains("503"))
}
