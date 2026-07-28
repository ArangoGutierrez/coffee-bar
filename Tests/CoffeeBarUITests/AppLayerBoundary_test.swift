// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

// The app layer must route every power decision through `DesiredPowerState`.
// A unit test can only see the path it is handed, so these two read the app
// layer's own source and fail on a second path to IOKit.

/// The package root, resolved from `#filePath`.
///
/// Never from the working directory: under `swift test` the working directory
/// is not the package root, and a guard that silently scans nothing is worse
/// than no guard at all. Every test below also asserts the scanned count.
private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarUITests/AppLayerBoundary_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarUITests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // the package root
}

private enum BoundaryScanError: Error {
    /// The scan could not read a directory. Raised rather than returning an
    /// empty list, because a guard that silently scans nothing always passes.
    case unreadable(String)
}

/// Every `.swift` file in the app layer, sorted by name so the scan order is
/// fixed rather than whatever the file system hands back.
///
/// The walk is recursive. `FileManager.contentsOfDirectory` reads one level,
/// and SwiftPM compiles a subdirectory into the same target, so
/// `Sources/CoffeeBarUI/Internal/Probe.swift` would ship inside the app layer
/// while escaping every check below.
private func appLayerSources() throws -> [URL] {
    let directories = [
        packageRoot.appending(path: "Sources/CoffeeBarUI"),
        packageRoot.appending(path: "Sources/CoffeeBarApp"),
    ]

    var found: [URL] = []
    for directory in directories {
        guard let walk = FileManager.default.enumerator(at: directory,
                                                        includingPropertiesForKeys: nil)
        else { throw BoundaryScanError.unreadable(directory.path) }

        for case let file as URL in walk where file.pathExtension == "swift" {
            found.append(file)
        }
    }
    return found.sorted { $0.path < $1.path }
}

@Test func onlyServingModelReachesTheAssertionHolder() throws {
    // `ServingModel` owns the one seam to the holder. Any other file naming it
    // is a second path that no `DesiredPowerState` test can see.
    let files = try appLayerSources()
    #expect(files.count > 0, "the boundary guard scanned no files at \(packageRoot.path)")

    for file in files where file.lastPathComponent != "ServingModel.swift" {
        let source = try String(contentsOf: file, encoding: .utf8)
        #expect(!source.contains("AssertionHolder"),
                "\(file.lastPathComponent) names AssertionHolder; only ServingModel.swift may")
        #expect(!source.contains("AssertionHolding"),
                "\(file.lastPathComponent) names AssertionHolding; only ServingModel.swift may")
    }
}

@Test func theAppLayerNeverNamesADisplaySleepAssertion() throws {
    // Design §6.1. `caffeinate -d` is the thing this product is not, and a
    // direct IOKit call from the app layer would reintroduce it under a green
    // suite: the model's `DesiredPowerState` would still read
    // `displaySleepAssertion == false` while the display was pinned awake.
    let files = try appLayerSources()
    #expect(files.count > 0, "the boundary guard scanned no files at \(packageRoot.path)")

    // This is a DENYLIST. It bounds the escapes we know about; it cannot prove
    // that no other route to a display assertion exists. `beginActivity` is
    // here because a call to
    // `ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled], …)`
    // raises a live `PreventUserIdleDisplaySleep` with no IOKit import and none
    // of the original three strings. Add a name here whenever a new route is
    // found; never read a pass as proof of absence.
    let forbidden = [
        "PreventUserIdleDisplaySleep",
        "IOPMAssertion",            // broader than IOPMAssertionCreate
        "import IOKit",
        "beginActivity",
        "idleDisplaySleepDisabled",
        "caffeinate",
    ]

    for file in files {
        let source = try String(contentsOf: file, encoding: .utf8)
        for name in forbidden {
            #expect(!source.contains(name),
                    "\(file.lastPathComponent) names \(name); the app layer holds no assertion of its own")
        }
    }
}
