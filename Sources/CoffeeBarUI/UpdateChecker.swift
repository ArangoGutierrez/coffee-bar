// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

// THE ONE FILE IN THIS APPLICATION THAT REACHES THE NETWORK.
//
// `SECURITY.md` tells a reader coffee-bar makes exactly one outbound request,
// and this is it. `noLinkedTargetCanReachTheNetworkByAddress` in
// `Tests/CoffeeBarUITests/AppLayerBoundary_test.swift` is what makes that
// sentence true rather than merely current: it bans twelve address-shaped APIs
// across every file the `coffee-bar` binary links, and relieves THIS file of
// exactly ONE of them.
//
// **`URLRequest` is still banned here, and that is structural rather than
// tidy.** `URLSession.data(from:)` takes a bare `URL` and sends the system
// defaults, so there is no request object in this file on which to set a
// header. A custom `User-Agent` carrying an install identifier — the constraint
// issue #29 calls the one most likely to rot silently — is then not something a
// reviewer has to notice, because there is nowhere here to put it.
//
// Nothing in this file downloads a release, and nothing replaces a bundle. It
// fetches a few dozen bytes of JSON saying which version is current.
// `UpdateCheck` decides what those bytes mean.

/// The address the manifest lives at could not be made into a URL.
///
/// Unreachable in practice — the address below is a literal — and it exists so
/// that the guard has no force-unwrap to trip over. A `!` here would turn a
/// mistyped constant into a crash on launch.
private struct ManifestAddressUnusable: Error {}

/// Fetches the published version manifest from the project site.
public struct PublishedManifestFetcher: ReleaseManifestFetching {

    /// The ONE host this application reaches.
    ///
    /// The project's own GitHub Pages site, which is where `site/latest.json`
    /// is published from this repository. A STATIC FILE, deliberately, and the
    /// alternative was weighed and rejected on the record: the GitHub Releases
    /// API would answer the same question without a file to keep in step, and
    /// it would make coffee-bar a client of an API whose shape, rate limits and
    /// authentication rules are somebody else's to change. The drift a static
    /// file can suffer is answered by
    /// `thePublishedManifestStatesTheNewestReleaseTheChangelogRecords`, which
    /// holds the published file against `CHANGELOG.md` on every run.
    public static let host = "arangogutierrez.github.io"

    /// The manifest's address, spelled out in full.
    ///
    /// **Not interpolated from `host` above, and that is deliberate.**
    /// `theOnlyEntitledFileReachesOnlyThePinnedHost` reads every `https://`
    /// literal out of this file's source and refuses one naming any other host.
    /// An interpolated address is one that guard cannot read, which would leave
    /// the destination unguarded — the spelling has to be legible to the check
    /// that bounds it. The duplication cannot drift:
    /// `theUpdateCheckResolvesExactlyOnePinnedAddress` parses this string and
    /// asserts its host is the constant above.
    ///
    /// No query and no fragment, ever. A query parameter is where an install
    /// identifier goes, and a version check that can count installs is
    /// analytics wearing a check's clothes — which handoff §12 rules out on its
    /// own terms, separately from egress.
    public static let manifestURL = "https://arangogutierrez.github.io/coffee-bar/latest.json"

    /// How long a check waits before giving up.
    ///
    /// A check with no bound is a hidden duration of the worst kind: on a
    /// captive-portal network the request neither answers nor fails, and the
    /// window sits on its previous sentence with nothing saying why. Short
    /// enough that a user who pressed Check now gets an answer while they are
    /// still looking at the window.
    public static let defaultTimeout: TimeInterval = 10

    private let timeout: TimeInterval

    public init(timeout: TimeInterval = PublishedManifestFetcher.defaultTimeout) {
        self.timeout = timeout
    }

    /// The session this check runs on, and every way it is stripped down.
    ///
    /// Separated from `fetch()` so it can be ASSERTED rather than described:
    /// `UpdateChecker_test.swift` reads these values off the real configuration
    /// object, which is a stronger claim than a scan of this source for the
    /// lines that set them.
    ///
    /// **Each line here is an identity the check would otherwise acquire.**
    /// A default session accepts a cookie and returns it on the next request,
    /// so a static host could hand coffee-bar an identity and count this
    /// machine's checks without coffee-bar ever meaning to send one. A URL cache
    /// leaves the answer, and the fact that a check happened, in a file nobody
    /// was told about. `waitsForConnectivity` would queue a refused check and
    /// fire it whenever the network returned — an outbound request at a moment
    /// the user did not ask for one.
    ///
    /// `httpAdditionalHeaders` is deliberately NOT SET. Its default is `nil`,
    /// which is exactly what is wanted, and the test asserts that rather than
    /// this file asserting it — a file that set headers to an empty dictionary
    /// would read as more careful and would be the same thing with a place to
    /// add one later.
    ///
    /// **WHAT THE REQUEST ACTUALLY SENDS, measured rather than inferred.** The
    /// configuration above was pointed at a loopback listener and the request
    /// head printed. `httpAdditionalHeaders` really is `nil`, and there is no
    /// cookie and no body — and macOS adds `Accept-Language`, carrying the
    /// user's language, on top of `Accept`, `Accept-Encoding`, `User-Agent`,
    /// `Cache-Control` and `Connection`. `SECURITY.md` prints that head in full,
    /// because a policy promising "the whole request" written from reading this
    /// file alone would have been false.
    ///
    /// **DO NOT "FIX" `Accept-Language` BY SETTING IT.** It is OS-supplied for
    /// every application and identifies no install, so it is not what the
    /// no-identifier rule is about. Overriding it needs `URLRequest`, which the
    /// egress guard keeps banned in THIS FILE precisely so that there is no
    /// request object here on which any header could be set. That ban is the
    /// structure behind the promise; a locale string is not worth trading it
    /// for. `SECURITY.md` carries the whole argument.
    static func sessionConfiguration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        return configuration
    }

    /// Asks the project site which version is current.
    ///
    /// It hands back the bytes and the status and judges neither.
    /// `UpdateCheck.manifest(from:statusCode:)` owns that, so the decision is
    /// testable without a network and this file stays the small, readable thing
    /// a reader of `SECURITY.md` can check in one sitting.
    ///
    /// A session per check, invalidated on the way out. This runs at most once a
    /// day, so pooling buys nothing and a session held for the life of the
    /// process is a connection held open for it.
    public func fetch() async throws -> FetchedManifest {
        guard let address = URL(string: Self.manifestURL) else { throw ManifestAddressUnusable() }

        let session = URLSession(configuration: Self.sessionConfiguration(timeout: timeout))
        defer { session.finishTasksAndInvalidate() }

        let (body, response) = try await session.data(from: address)

        // Zero when the answer carried no HTTP status at all, which
        // `UpdateCheck` refuses. Never defaulted to 200: a reply nobody can read
        // a status off is not a reply that said everything is fine.
        return FetchedManifest(body: body,
                               statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
