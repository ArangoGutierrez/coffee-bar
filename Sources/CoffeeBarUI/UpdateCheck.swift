// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

// The update check, issue #29 — and what it deliberately is not.
//
// **It tells you. It does not update itself.** There is no downloader, no
// bundle replacement and no relaunch. `brew install coffee-bar` puts the app
// inside the Homebrew prefix, so an app that replaced its own bundle would
// desynchronise Homebrew's manifest and the next `brew upgrade` would fight it.
// The whole outcome of a check is a sentence — in the panel, and in the
// Preferences window beside the interval.
//
// **No Sparkle, and no package dependency of any kind.** `SECURITY.md` cites
// the empty dependency list as a security fact — "no third-party code is
// fetched or linked, and none of it can open a socket on coffee-bar's behalf" —
// and an updater framework would be the first exception to it, sitting in the
// update path, which is the highest-trust path in the application.
//
// THIS FILE IS THE DECISION HALF and reaches nothing. It takes bytes and two
// strings and answers what they mean. `UpdateChecker.swift` is the only file in
// this application that may reach the network, and
// `noLinkedTargetCanReachTheNetworkByAddress` is what holds that line.

/// What the published manifest says.
///
/// One field, and `thePublishedManifestCarriesNothingButTheVersion` pins the
/// published file to exactly that. It is `Decodable` and not `Codable`: nothing
/// here writes one, and a synthesised encoder is a route to composing a payload
/// that could be sent somewhere.
public struct ReleaseManifest: Equatable, Decodable, Sendable {
    public let version: String

    public init(version: String) { self.version = version }
}

/// What a fetch came back with.
///
/// The STATUS as well as the bytes, because a 404 page and a manifest are both
/// bytes and only the status tells them apart before a decoder is handed
/// either.
public struct FetchedManifest: Equatable, Sendable {
    public let body: Data
    public let statusCode: Int

    public init(body: Data, statusCode: Int) {
        self.body = body
        self.statusCode = statusCode
    }
}

/// Where the published manifest comes from.
///
/// A protocol, so no check in this package reaches the real host. It is the
/// same shape of seam as `SettingsStoring` and `PowerReadingProviding`: one
/// real implementation, injected at the boundary.
///
/// The obvious third sibling to name here is the seam to the power assertion,
/// and it is deliberately absent — including from the name of the guard that
/// pins it. That guard, in `AppLayerBoundary_test.swift`, reads this file's RAW
/// source rather than a comment-stripped one, so a prose mention of the seam
/// fails it exactly as a call would, and citing the check by name is enough to
/// carry the word in. Measured, not reasoned: this comment did that once.
///
/// It is declared HERE rather than beside its implementation on purpose.
/// `ServingModel` holds one of these, and holding it must not put the model in
/// the same file as the one thing in this application allowed to name
/// `URLSession`.
public protocol ReleaseManifestFetching: Sendable {
    func fetch() async throws -> FetchedManifest
}

/// Why a published answer was not believed.
///
/// Three cases and not one, because each wants a different sentence and a
/// different action from the reader: a server error will pass, a body that will
/// not decode is a broken publish, and an oversized one is not this file at all.
public enum ManifestRefusal: Error, Equatable, Sendable {
    /// The answer did not carry HTTP 200. Zero means it carried no HTTP status.
    case status(Int)
    /// The answer was larger than a manifest can be. Carries the byte count.
    case tooLarge(Int)
    /// The bytes are not a manifest, or name no version.
    case unreadable
}

/// What a completed check concluded.
public enum UpdateVerdict: Equatable, Sendable {
    case upToDate
    /// A newer release is published. Carries the published version.
    case updateAvailable(String)
    /// Nothing was compared. Carries the reason, in the words the user reads.
    case cannotCompare(String)
}

/// The rules a check runs by: what the bytes mean, what two stamps mean beside
/// each other, and when the next check is due.
public enum UpdateCheck {

    // MARK: - The one duration this feature has

    /// How long coffee-bar waits between checks.
    ///
    /// **STATED IN THE WINDOW, and `docs/ROADMAP.md` is why that is a
    /// requirement rather than a courtesy.** "No hidden durations": a period the
    /// user cannot see, cannot change and did not ask for is precisely what that
    /// principle forbids, and this one governs the only request this
    /// application makes off the machine. `intervalNote` states it,
    /// `PreferencesView` renders that note unconditionally, and
    /// `theIntervalIsTheOneStatedInTheWindow` holds the constant and the
    /// sentence together so the two cannot drift.
    public static let interval: TimeInterval = 24 * 60 * 60

    /// The most a published manifest may weigh.
    ///
    /// The real file is a few dozen bytes. Anything far larger is not this file
    /// whatever it decodes to, and handing an unbounded stranger's payload to a
    /// decoder is a cost this feature has no reason to accept.
    static let maxManifestBytes = 4096

    /// The stamps that name no release, and must never be compared to one.
    ///
    /// `AppVersion.unknown` is what an absent, missing, mistyped or blank
    /// `CFBundleShortVersionString` reports — a `swift run` build has no info
    /// dictionary at all. `0.0.0-dev` is what `scripts/build-app.sh` stamps when
    /// neither `git describe` nor `COFFEE_BAR_VERSION` answers.
    ///
    /// The second is the dangerous one, and it is why this list exists rather
    /// than the parser being left to reject what it cannot read. `0.0.0-dev`
    /// PARSES: read as a version it is older than every release ever made, so
    /// every untagged build would be told to update — permanently, and probably
    /// to a release it already contains.
    static let unusableStamps: Set<String> = [AppVersion.unknown, "0.0.0-dev"]

    // MARK: - The sentences the window renders

    /// What the window says before any check has run.
    ///
    /// It says NOTHING HAS HAPPENED rather than "up to date", which is the
    /// difference between reporting and assuming. Silence read as good news is
    /// how a check that has been broken for a year goes unnoticed.
    static let neverCheckedLine = "coffee-bar has not looked for a newer version yet."

    static let upToDateLine = "coffee-bar is up to date."

    static let unreachableLine = "coffee-bar could not reach the published version file."

    /// Why a build with no usable stamp is not compared.
    ///
    /// It names the situation rather than blaming the user: a developer build
    /// and a Homebrew build from a tarball with no `COFFEE_BAR_VERSION` both
    /// land here, and neither is a fault.
    static let unstampedLine =
        "This build carries no version coffee-bar can compare to a release, so nothing was compared."

    static let unreadablePublishedLine =
        "The published version file did not say which version is current, so nothing was compared."

    static let tooLargeLine =
        "The published version file was larger than it should ever be, so nothing was compared."

    /// What the window says about how often coffee-bar looks, and what it will
    /// not do with the answer.
    ///
    /// Both halves are load bearing. The first is the visible duration
    /// `docs/ROADMAP.md` requires. The second is the only place a user is told
    /// that a check will not turn into an install — that is the whole difference
    /// between this feature and the Sparkle design it replaces, and it is not
    /// something waiting can confirm.
    /// It names WHEN, and the answer is "when coffee-bar starts" rather than
    /// "when you open this window". That sentence FOLLOWED the code and has
    /// been changed in the commit that changed it: the trigger was
    /// `PreferencesView.onAppear` while this window was the only surface that
    /// could show the answer, and it moved to `main.swift` the moment the panel
    /// gained its own copy of the section. A promise and its behaviour must
    /// never drift, so the two move together or not at all.
    ///
    /// "Once a day" still bounds it and the interval is still enforced across
    /// launches by a stored stamp rather than by a timer this process holds —
    /// a machine left in the menu bar for a week posts once, not seven times.
    static let intervalNote = """
        coffee-bar looks for a newer version once a day, when it starts, and \
        whenever you press Check now. It only tells you: it downloads no \
        update and installs nothing.
        """

    /// The line that makes the timing checkable rather than merely claimed.
    ///
    /// A FIXED format under `en_US_POSIX`, not the user's locale conventions,
    /// and the reason is that this line ends up pasted into bug reports.
    /// "8/6/26, 7:06 AM" is ambiguous to half the world and re-orders itself per
    /// locale, so a maintainer reading two of them cannot tell which is newer.
    ///
    /// The TIME ZONE stays the machine's, because the question a reader is
    /// asking is "how long ago was that" and they think in local time.
    static func lastCheckLine(_ when: Date?, timeZone: TimeZone = .current) -> String {
        guard let when else { return "Last checked: never." }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Last checked: \(formatter.string(from: when))."
    }

    /// The sentence a verdict reads as.
    static func sentence(for verdict: UpdateVerdict) -> String {
        switch verdict {
        case .upToDate:
            return upToDateLine
        case .updateAvailable(let version):
            // It names no download link and no command. coffee-bar is installed
            // four different ways — Homebrew, the disk image, a build from
            // source, a copy handed over on a stick — and a sentence naming one
            // of them is wrong for the other three. Telling the user the route
            // they already took is the only instruction that is right for
            // everybody.
            return "coffee-bar \(version) is published. "
                + "coffee-bar installs nothing: update it the way you installed it."
        case .cannotCompare(let reason):
            // Carried through VERBATIM rather than folded into one vague
            // sentence. "Could not compare" tells a reader nothing they can act
            // on, and the reasons want different actions: reconnect, wait, or
            // report a broken publish.
            return reason
        }
    }

    /// The sentence a refusal reads as.
    static func sentence(for refusal: ManifestRefusal) -> String {
        switch refusal {
        case .status(let code):
            return "The published version file answered \(code), so nothing was compared."
        case .tooLarge:
            return tooLargeLine
        case .unreadable:
            return unreadablePublishedLine
        }
    }

    // MARK: - What the published bytes mean

    /// The manifest those bytes carry, or why they were not believed.
    ///
    /// The order of the three refusals is deliberate: the status is judged
    /// BEFORE the size and the size BEFORE the decode, so a hostile or merely
    /// broken answer is turned away at the cheapest point that can see it. A 500
    /// carrying valid-looking JSON must not be believed just because it parses.
    public static func manifest(from body: Data,
                                statusCode: Int) -> Result<ReleaseManifest, ManifestRefusal> {
        guard statusCode == 200 else { return .failure(.status(statusCode)) }
        guard body.count <= maxManifestBytes else { return .failure(.tooLarge(body.count)) }
        guard let decoded = try? JSONDecoder().decode(ReleaseManifest.self, from: body) else {
            return .failure(.unreadable)
        }

        // Trimmed here rather than at the comparison, so exactly one place knows
        // that a version arrives from a hand-edited file and may carry
        // whitespace. A blank one is refused rather than compared as empty: it
        // says nothing, and a parser that read it as a version would have to
        // invent one.
        let version = decoded.version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { return .failure(.unreadable) }
        return .success(ReleaseManifest(version: version))
    }

    // MARK: - What two version stamps mean beside each other

    /// The three release numbers in a stamp, or `nil` when it names no release.
    ///
    /// `scripts/build-app.sh` stamps `git describe --tags --dirty` with any
    /// leading `v` removed, so a tree three commits past v0.2.2 reports
    /// `0.2.2-3-g1258578` and a dirty one appends `-dirty`. Everything from the
    /// first `-` onward is dropped: what remains names the release the build
    /// descends from, which is the honest thing to compare.
    ///
    /// **ASCII digits only.** `Character.isNumber` is true of `١` and of `½`, so
    /// a parser written on it accepts strings whose value is not what the glyphs
    /// suggest — or accepts one `Int(_:)` then refuses, which is a crash waiting
    /// for a force-unwrap. The refusal belongs at the parse.
    static func releaseCore(of stamp: String) -> [Int]? {
        let trimmed = stamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unusableStamps.contains(trimmed) else { return nil }

        let head = trimmed.prefix { $0 != "-" }
        let parts = head.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }

        var core: [Int] = []
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part)
            else { return nil }
            core.append(value)
        }
        return core
    }

    /// What the running build should be told about the published one.
    ///
    /// **Compared as NUMBERS, never as text**, and that is the bug this function
    /// exists to not have: "0.10.0" sorts before "0.9.0" as a string, so a
    /// string comparison tells the user on the newest build to downgrade and
    /// never mentions 0.10.0 to the user on 0.9.0.
    ///
    /// A running build AHEAD of the published file reports `upToDate` rather
    /// than anything cleverer. That is the ordinary state of this repository
    /// between cutting a tag and editing the site, and a maintainer must not be
    /// nagged to install a release older than the one they are running.
    public static func compare(running: String, published: String) -> UpdateVerdict {
        guard let mine = releaseCore(of: running) else { return .cannotCompare(unstampedLine) }
        guard let theirs = releaseCore(of: published) else {
            return .cannotCompare(unreadablePublishedLine)
        }
        guard mine.lexicographicallyPrecedes(theirs) else { return .upToDate }
        return .updateAvailable(published.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - When the next check is due

    /// Whether enough time has passed to look again.
    ///
    /// A stamp AHEAD of now is due rather than never due again, and that
    /// direction is the whole care in this function. A user who moved their
    /// clock back, or copied a preferences file off another machine, leaves a
    /// last-check time in the future; a plain `elapsed >= interval` is false for
    /// as long as the wall clock takes to catch up, which for a year-ahead stamp
    /// is a year of a feature silently switched off.
    public static func isDue(lastChecked: Date?, now: Date) -> Bool {
        guard let lastChecked else { return true }
        let elapsed = now.timeIntervalSince(lastChecked)
        guard elapsed >= 0 else { return true }
        return elapsed >= interval
    }
}
