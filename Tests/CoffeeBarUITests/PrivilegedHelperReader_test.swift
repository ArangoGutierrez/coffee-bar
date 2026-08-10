// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import CoffeeBarCore
@testable import CoffeeBarUI

/// The read behind the #81 advisory, driven over REAL files.
///
/// `PrivilegedHelperState_test.swift` pins the decision, which takes two
/// `Data?` and touches no disk. This file pins the half that opens the two
/// files, because that is where the states come from and a decision handed the
/// wrong bytes is a correct answer to the wrong question.
///
/// **Every check here supplies both URLs.** The shipping defaults are the
/// running bundle's neighbour and `/Library/PrivilegedHelperTools`, so a check
/// that took them would read whatever the developer happens to have installed
/// and report a different state on every Mac — the same machine dependence
/// `HookHealthReader`'s `hookFiles` comment exists to prevent.

/// A directory of this check's own, removed when it finishes.
private func scratchDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "coffee-bar-helper-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func twoIdenticalCopiesAreCurrent() throws {
    let scratch = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let bundled = scratch.appending(path: "bundled-probe")
    let installed = scratch.appending(path: "installed-probe")
    try Data("the same bytes".utf8).write(to: bundled)
    try Data("the same bytes".utf8).write(to: installed)

    let reader = PrivilegedHelperReader(bundledProbe: bundled, installedProbe: installed)
    #expect(reader.state() == .current)
}

@Test func aDifferentInstalledCopyIsStale() throws {
    // The state this whole release is about. Byte comparison, so a copy that
    // differs only in the middle still reports stale — a length check would
    // call two equally-sized builds current.
    let scratch = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let bundled = scratch.appending(path: "bundled-probe")
    let installed = scratch.appending(path: "installed-probe")
    try Data("v0.2.1 probe".utf8).write(to: bundled)
    try Data("v0.1.1 probe".utf8).write(to: installed)

    let reader = PrivilegedHelperReader(bundledProbe: bundled, installedProbe: installed)
    #expect(reader.state() == .stale)
}

@Test func nothingAtThePrivilegedPathIsNotInstalled() throws {
    // The user who has never armed lid-closed mode. The install advisory
    // already covers them, so this must NOT be reported as a fault.
    let scratch = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let bundled = scratch.appending(path: "bundled-probe")
    try Data("v0.2.1 probe".utf8).write(to: bundled)

    let reader = PrivilegedHelperReader(
        bundledProbe: bundled,
        installedProbe: scratch.appending(path: "nothing-was-ever-installed-here"))
    #expect(reader.state() == .notInstalled)
}

@Test func anUnreadableBundledCopyIsUnverifiable() throws {
    // The app cannot read its own probe, so no comparison happened. Named bug:
    // answering `.notInstalled` here, which reports a clean machine while the
    // app is the broken half — and `.notInstalled` is silent, so the user is
    // told nothing at all.
    let scratch = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let installed = scratch.appending(path: "installed-probe")
    try Data("v0.1.1 probe".utf8).write(to: installed)

    let reader = PrivilegedHelperReader(
        bundledProbe: scratch.appending(path: "this-build-shipped-without-one"),
        installedProbe: installed)
    #expect(reader.state() == .unverifiable, """
        an app that cannot read its own probe reported a verdict about the \
        installed one, which it has nothing to compare against
        """)
}

@Test func theReaderReadsOnlyTheFilesItWasGiven() throws {
    // Named bug this catches: a reader that resolves either path itself instead
    // of using the one it was handed. Both temporary files exist and DIFFER, so
    // a reader reaching for `/Library/PrivilegedHelperTools` or for the running
    // bundle would answer `.notInstalled` or `.unverifiable` here rather than
    // `.stale` — and on a machine that happened to have both installed and
    // current, it would answer `.current` and this check would still be the one
    // that noticed.
    let scratch = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let bundled = scratch.appending(path: "bundled-probe")
    let installed = scratch.appending(path: "installed-probe")
    try Data("bundled".utf8).write(to: bundled)
    try Data("installed".utf8).write(to: installed)

    let reader = PrivilegedHelperReader(bundledProbe: bundled, installedProbe: installed)
    #expect(reader.bundledProbe == bundled)
    #expect(reader.installedProbe == installed)
    #expect(reader.state() == .stale)
}

@Test func theDefaultInstalledProbeIsTheOnePathTheRestOfThePackageNames() {
    // ONE spelling of the privileged location. `ServingModel.privilegedProbePath`
    // is what the printed install command names and what the advisory names, so
    // a reader with its own literal would check a file the user was never told
    // to write — and would report `.notInstalled` for ever while the machine was
    // armed correctly.
    #expect(PrivilegedHelperReader.defaultInstalledProbe.path
            == ServingModel.privilegedProbePath)
}
