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

/// Every `.swift` file in the app layer, sorted by name so the scan order is
/// fixed rather than whatever the file system hands back.
private func appLayerSources() throws -> [URL] {
    let directories = [
        packageRoot.appending(path: "Sources/CoffeeBarUI"),
        packageRoot.appending(path: "Sources/CoffeeBarApp"),
    ]
    return try directories
        .flatMap {
            try FileManager.default.contentsOfDirectory(at: $0,
                                                        includingPropertiesForKeys: nil)
        }
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.path < $1.path }
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

    for file in files {
        let source = try String(contentsOf: file, encoding: .utf8)
        for forbidden in ["PreventUserIdleDisplaySleep", "IOPMAssertionCreate", "import IOKit"] {
            #expect(!source.contains(forbidden),
                    "\(file.lastPathComponent) names \(forbidden); the app layer holds no assertion of its own")
        }
    }
}
