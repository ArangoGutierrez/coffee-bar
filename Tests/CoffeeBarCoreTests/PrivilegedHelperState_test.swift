// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

/// Whether the root binary on disk is the one this build ships.
///
/// Pure over two `Data` values on purpose. The caller reads the files; this
/// decides. A version STRING would have been the obvious design and is the
/// wrong one: the probe carries no version constant, and adding one would mean
/// the check passes whenever two different builds happen to agree on a string
/// somebody remembered to bump. Bytes cannot be forgotten.

@Test func anIdenticalHelperIsCurrent() throws {
    // Named bug: the check reports every install stale, the advisory never
    // clears, and the user learns to ignore it.
    let same = Data("probe-bytes".utf8)
    #expect(PrivilegedHelper.state(bundled: same, installed: same) == .current)
}

@Test func aDifferentHelperIsStale() throws {
    // Named bug this catches, and it is the whole release: installing a new app
    // leaves /Library/PrivilegedHelperTools/coffee-bar-probe untouched, so a
    // user keeps executing an older ROOT binary and no later privileged fix can
    // reach them. Measured on a real upgrade 2026-08-09.
    #expect(PrivilegedHelper.state(bundled: Data("new".utf8),
                                   installed: Data("old".utf8)) == .stale)
}

@Test func anAbsentHelperIsNotStale() throws {
    // Named bug: a user who never armed is told their helper is out of date.
    // "Not installed" and "installed but old" are different sentences, and the
    // install advisory already covers the first.
    #expect(PrivilegedHelper.state(bundled: Data("new".utf8),
                                   installed: nil) == .notInstalled)
}

@Test func anUnreadableBundleIsNotReportedCurrent() throws {
    // Named bug: the app cannot read its own probe and reports `.current`,
    // which is the silent failure this project exists to remove. Not knowing
    // must never be spelled "fine".
    #expect(PrivilegedHelper.state(bundled: nil,
                                   installed: Data("old".utf8)) == .unverifiable)
    #expect(PrivilegedHelper.state(bundled: nil, installed: nil) == .unverifiable)
}
