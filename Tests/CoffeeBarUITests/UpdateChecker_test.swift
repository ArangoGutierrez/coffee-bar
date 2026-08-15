// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import CoffeeBarUI

// The one file in this application that reaches the network, held to what it
// is allowed to be.
//
// **What no check here can do, stated rather than hidden.** Nothing in this
// file opens a socket. A unit test that posted to the real project site would
// fail on an aeroplane, would make the suite's result depend on somebody else's
// web server, and would itself be the egress this repository spends so much
// care bounding. So the transport is proven by CONSTRUCTION — the address it
// resolves, and the session configuration it hands `URLSession` — and the rule
// that no OTHER file may do any of this lives in
// `noLinkedTargetCanReachTheNetworkByAddress`, in
// `Tests/CoffeeBarUITests/AppLayerBoundary_test.swift`.
//
// The assertions below read REAL OBJECTS rather than the source text, which is
// what separates them from that boundary scan: a `contains` over source proves
// a line is spelled, and `configuration.httpAdditionalHeaders == nil` proves
// what the session will actually send.

// MARK: - The one address

@Test func theUpdateCheckResolvesExactlyOnePinnedAddress() throws {
    // A hostname a check can read, so a change of destination is a change this
    // guard sees. `AppLayerBoundary_test.swift` pins the same host from the
    // other side — it reads every URL literal out of this file's source and
    // refuses one that names anywhere else — and the two together mean the
    // address cannot move without both going red.
    let parts = try #require(URLComponents(string: PublishedManifestFetcher.manifestURL),
                             "the pinned manifest address does not parse as a URL")

    #expect(parts.scheme == "https")
    #expect(parts.host == PublishedManifestFetcher.host)
    #expect(parts.host == "arangogutierrez.github.io")
    #expect(parts.path == "/coffee-bar/latest.json")
    #expect(parts.port == nil)
}

@Test func theUpdateRequestCarriesNoQueryAndNoFragment() throws {
    // CONSTRAINT 3 of issue #29, held on the parsed address rather than on a
    // sentence about it. A query parameter is where an install identifier goes
    // — `?id=…`, `?since=…`, even `?v=0.2.2` — and every one of those turns a
    // version check into something that can count installs and tell them apart.
    // §12 bans analytics separately from egress, and this is the door analytics
    // would come through.
    let parts = try #require(URLComponents(string: PublishedManifestFetcher.manifestURL))

    #expect(parts.query == nil, "the manifest address carries a query: \(parts.query ?? "")")
    #expect(parts.queryItems == nil)
    #expect(parts.fragment == nil)
    // A user and a password in the address would identify the caller as surely
    // as a query would, and would put a credential in a static-site request.
    #expect(parts.user == nil)
    #expect(parts.password == nil)
}

@Test func theUpdateCheckIsSentOverTLSAndNeverInTheClear() {
    // The answer decides what the window tells the user to do. Over plain HTTP
    // anybody on the same coffee-shop network can rewrite it — into a much
    // higher version, which is a nag, or into the current one, which silences
    // the check for ever.
    #expect(PublishedManifestFetcher.manifestURL.hasPrefix("https://"))
}

// MARK: - What the session will actually send

@Test func theUpdateSessionAddsNoHeaderOfItsOwn() throws {
    // CONSTRAINT 3 again, on the other half of the request. `httpAdditionalHeaders`
    // is where a custom `User-Agent` would go, and a `User-Agent` naming this
    // install — a UUID, a machine name, a licence key — is telemetry however
    // short it is.
    //
    // ASSERTED ON THE CONFIGURATION OBJECT, not on the source text: the session
    // is built from exactly this, so `nil` here means there is no header to
    // send. A source scan for "User-Agent" would pass a file that built the
    // string from two halves.
    let configuration = PublishedManifestFetcher.sessionConfiguration(timeout: 10)

    #expect(configuration.httpAdditionalHeaders == nil,
            "the update session adds headers: \(configuration.httpAdditionalHeaders ?? [:])")
}

@Test func theUpdateSessionKeepsNoCookieAndSetsNone() throws {
    // A cookie IS an install identifier — that is what a cookie is for. A
    // default `URLSession` accepts one from the server and returns it on the
    // next request, so a static file host could hand coffee-bar an identity and
    // count this machine's checks without coffee-bar ever meaning to send one.
    //
    // Both halves, because either alone leaves the loop open: storage `nil`
    // with `httpShouldSetCookies` true still returns whatever the shared
    // storage holds.
    let configuration = PublishedManifestFetcher.sessionConfiguration(timeout: 10)

    #expect(configuration.httpCookieStorage == nil)
    #expect(configuration.httpShouldSetCookies == false)
    #expect(configuration.httpCookieAcceptPolicy == .never)
}

@Test func theUpdateSessionKeepsNothingOnDiskBetweenChecks() {
    // A persistent URL cache would leave the answer — and the fact that a check
    // happened at all — in a file this feature never told the user about. The
    // one thing coffee-bar records about a check is the timestamp the window
    // shows.
    let configuration = PublishedManifestFetcher.sessionConfiguration(timeout: 10)

    #expect(configuration.urlCache == nil)
    #expect(configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    // Not a background session: those are keyed by an identifier that persists
    // across launches, which is exactly the kind of durable handle this feature
    // must not acquire.
    #expect(configuration.identifier == nil)
}

@Test func theUpdateCheckGivesUpRatherThanWaitingForever() throws {
    // A check with no timeout is a hidden duration of the worst kind: on a
    // captive-portal network the request neither answers nor fails, and the
    // window sits on its last sentence with nothing saying why.
    let configuration = PublishedManifestFetcher.sessionConfiguration(timeout: 10)

    #expect(configuration.timeoutIntervalForRequest == 10)
    // The DEFAULT is what ships, and it has to be short enough that a user who
    // pressed Check now gets an answer while they are still looking at the
    // window.
    #expect(PublishedManifestFetcher.defaultTimeout <= 30)
    #expect(PublishedManifestFetcher.defaultTimeout > 0)
}

@Test func theUpdateCheckWaitsForNoNetworkThatIsNotThere() {
    // `waitsForConnectivity` defaults to false and is asserted rather than
    // assumed: with it true, a check made offline is queued by the system and
    // fires whenever connectivity returns — an outbound request at a moment the
    // user did not ask for one, from a process that may have been idle for
    // hours. The refusal has to be immediate so the window can say so.
    let configuration = PublishedManifestFetcher.sessionConfiguration(timeout: 10)

    #expect(configuration.waitsForConnectivity == false)
}
