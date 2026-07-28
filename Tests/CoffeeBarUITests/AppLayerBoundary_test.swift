// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

// The app layer must route every power decision through `DesiredPowerState`.
// A unit test can only see the path it is handed, so these read the app
// layer's own source and fail on a second path to IOKit.
//
// Every content check below reads only the files the scan reaches. That makes
// the SCANNED SET the load-bearing part: a file the walk never visits is a
// file no check can see, and a green suite then means nothing. Three proven
// ways to get a file compiled into the app while the walk misses it:
//
//   1. a symlinked DIRECTORY inside `Sources/CoffeeBarUI` — SwiftPM compiles
//      through it, `FileManager.enumerator` refuses to descend into it;
//   2. a second app-layer target that `CoffeeBarApp` depends on — the walk
//      reads two fixed directories and knows nothing of the build graph;
//   3. the app target's directory moving under a `path:` override — the walk
//      then enumerates a directory that does not exist.
//
// None of the three is a denylist problem: adding names cannot fix a file that
// is never read. So the structure itself is asserted — the exact file set, and
// the app layer's exact place in the build graph — and the denylist stays only
// as a second line of defence.

/// The package root, resolved from `#filePath`.
///
/// Never from the working directory: under `swift test` the working directory
/// is not the package root, and a guard that silently scans nothing is worse
/// than no guard at all.
private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarUITests/AppLayerBoundary_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarUITests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // the package root
}

/// The two directories that make up the app layer.
private let appLayerDirectories = [
    "Sources/CoffeeBarUI",
    "Sources/CoffeeBarApp",
]

/// Every entry the app layer is allowed to contain, package-root relative and
/// sorted.
///
/// A literal, deliberately. Any file that is added, renamed, moved or linked in
/// fails `theAppLayerHoldsExactlyTheFilesThisGuardScans` until a human updates
/// this list. That friction is the point: updating it is the moment somebody
/// reads the new file against design §6.1.
private let expectedAppLayerEntries = [
    "Sources/CoffeeBarApp/main.swift",
    "Sources/CoffeeBarUI/MenuBarGlyphs.swift",
    "Sources/CoffeeBarUI/PanelView.swift",
    "Sources/CoffeeBarUI/ServingModel.swift",
]

private enum BoundaryScanError: Error, CustomStringConvertible {
    /// An app-layer directory is missing, or is not a directory.
    ///
    /// Checked with `fileExists(atPath:isDirectory:)` before the walk, because
    /// `FileManager.enumerator(at:)` returns a NON-nil enumerator for a missing
    /// directory and simply yields nothing. Trusting the enumerator alone made
    /// this case dead code: the app target's directory could move under a
    /// `path:` override in `Package.swift` and every check here stayed green
    /// while `main.swift` went unread.
    case unreadable(String)

    /// `Package.swift` did not contain what the manifest check looks for.
    ///
    /// Raised rather than returning an empty dependency list, which would let a
    /// reformatted or renamed target pass the build-graph assertion silently.
    case unparsableManifest(String)

    var description: String {
        switch self {
        case .unreadable(let path):
            return "app-layer directory missing or not a directory: \(path)"
        case .unparsableManifest(let detail):
            return "Package.swift: \(detail)"
        }
    }
}

/// Every entry under the app layer's directories, package-root relative and
/// sorted.
///
/// Entries, not only `.swift` files, and not only regular files. A symlinked
/// directory is yielded by the enumerator as an entry of its own even though
/// the walk will not descend into it, so listing entries is what turns that
/// escape into a failure.
///
/// Hidden entries are skipped because SwiftPM skips them too: a
/// `Sources/CoffeeBarUI/.hidden/HiddenProbe.swift` produces no object file and
/// never appears on the compiler command line, so it cannot reach the app. This
/// also keeps a stray `.DS_Store` from turning the guard red for no reason.
private func appLayerEntries() throws -> [String] {
    // Paths are made relative by stripping this prefix, never by joining the
    // directory to `lastPathComponent`: that would flatten a nested file down
    // to a name already on the expected list, and the content checks would then
    // read the wrong file. An entry that somehow falls outside the package root
    // keeps its absolute path, matches nothing on the list, and fails.
    let rootPrefix = packageRoot.path + "/"
    var found: [String] = []

    for relativeDirectory in appLayerDirectories {
        let directory = packageRoot.appending(path: relativeDirectory)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path,
                                             isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw BoundaryScanError.unreadable(directory.path) }

        guard let walk = FileManager.default.enumerator(at: directory,
                                                        includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])
        else { throw BoundaryScanError.unreadable(directory.path) }

        for case let entry as URL in walk {
            let path = entry.path
            found.append(path.hasPrefix(rootPrefix)
                         ? String(path.dropFirst(rootPrefix.count))
                         : path)
        }
    }

    return found.sorted()
}

/// The `.swift` files the content checks read, in the same fixed order.
private func appLayerSources() throws -> [URL] {
    try appLayerEntries()
        .filter { $0.hasSuffix(".swift") }
        .map { packageRoot.appending(path: $0) }
}

/// How many `.swift` files a correct scan reaches. The two content checks
/// assert this so that neither can pass by reading nothing.
private let expectedSourceCount = expectedAppLayerEntries.filter { $0.hasSuffix(".swift") }.count

/// The `dependencies:` list one target declares in `Package.swift`.
///
/// Read from the manifest text rather than from `swift package dump-package`:
/// spawning SwiftPM from inside `swift test` contends for the same `.build`
/// lock. The parse throws whenever it cannot find what it looks for, so a
/// renamed or reformatted target fails loudly instead of yielding an empty list
/// that would satisfy nothing and pass everything.
private func manifestDependencies(ofTarget target: String) throws -> [String] {
    let manifest = try String(contentsOf: packageRoot.appending(path: "Package.swift"),
                              encoding: .utf8)

    guard let name = manifest.range(of: "name: \"\(target)\"") else {
        throw BoundaryScanError.unparsableManifest("no target declares name: \"\(target)\"")
    }

    // Bound the search to this one declaration. The next `name: "` starts the
    // next target, and an unbounded search would report a later target's list
    // for a target that declares no dependencies at all.
    var declaration = manifest[name.upperBound...]
    if let next = declaration.range(of: "name: \"") {
        declaration = declaration[..<next.lowerBound]
    }

    guard let label = declaration.range(of: "dependencies:"),
          let open = declaration[label.upperBound...].firstIndex(of: "["),
          let close = declaration[open...].firstIndex(of: "]")
    else {
        throw BoundaryScanError.unparsableManifest("no dependencies list for \"\(target)\"")
    }

    return declaration[declaration.index(after: open)..<close]
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\"")) }
        .filter { !$0.isEmpty }
}

// MARK: - The scanned set itself

@Test func theAppLayerHoldsExactlyTheFilesThisGuardScans() throws {
    // Named bug this catches: any app-layer file the other checks never read.
    // Proven escapes, each of which compiled into the shipped `coffee-bar`
    // binary while the old guard stayed green — a symlinked directory
    // (`LinkProbe.swift.o` was built), and a moved app directory under a
    // `path:` override, which left `main.swift` unscanned.
    let found = try appLayerEntries()
    let expected = expectedAppLayerEntries

    #expect(found == expected, """
        the app layer's file set changed.
          unexpected: \(found.filter { !expected.contains($0) })
          missing:    \(expected.filter { !found.contains($0) })
        Every check in this file reads only the files it scans. Update \
        `expectedAppLayerEntries` deliberately, after reading the new file \
        against design §6.1.
        """)
}

@Test func theAppLayerIsExactlyTwoTargetsDeepInTheBuildGraph() throws {
    // The file set above covers two fixed directories, so it cannot see a
    // THIRD app-layer target. Named bug this catches: a
    // `Sources/CoffeeBarPanelKit` that `CoffeeBarApp` depends on. It compiled
    // (`Escape.swift.o`), linked into `coffee-bar`, named `IOPMAssertion`, and
    // both old checks passed — the walk simply never looked there.
    //
    // `CoffeeBarUI` is asserted as well as `CoffeeBarApp`: a new target hung off
    // the model rather than off the executable ships in the app just the same.
    #expect(try manifestDependencies(ofTarget: "CoffeeBarApp") == ["CoffeeBarUI"],
            "CoffeeBarApp gained a dependency; a new app-layer target is unscanned")
    #expect(try manifestDependencies(ofTarget: "CoffeeBarUI") == ["CoffeeBarPower"],
            "CoffeeBarUI gained a dependency; a new app-layer target is unscanned")
}

// MARK: - What the scanned files may say

@Test func onlyServingModelReachesTheAssertionHolder() throws {
    // `ServingModel` owns the one seam to the holder. Any other file naming it
    // is a second path that no `DesiredPowerState` test can see.
    let files = try appLayerSources()
    #expect(files.count == expectedSourceCount,
            "the boundary guard scanned \(files.count) files at \(packageRoot.path)")

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
    #expect(files.count == expectedSourceCount,
            "the boundary guard scanned \(files.count) files at \(packageRoot.path)")

    // This is a DENYLIST, and it is the SECOND line of defence, not the first.
    // It bounds the escapes we know about against an unbounded API surface; it
    // cannot prove that no other route to a display assertion exists. Only the
    // two structural checks above bound what it never gets to read.
    //
    // `beginActivity` and `performActivity` are both here because either raises
    // a live `PreventUserIdleDisplaySleep` with no IOKit import and none of the
    // original three strings — `performActivity` even with an option built from
    // a raw value, which names `idleDisplaySleepDisabled` nowhere. Add a name
    // here whenever a new route is found; never read a pass as proof of absence.
    let forbidden = [
        "PreventUserIdleDisplaySleep",
        "IOPMAssertion",            // broader than IOPMAssertionCreate
        "import IOKit",
        "beginActivity",
        "performActivity",
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
