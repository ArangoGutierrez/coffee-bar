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
// file no check can see, and a green suite then means nothing.
//
// So the scanned set is taken from `swift package describe --type json` — the
// list of files SwiftPM ACTUALLY COMPILES, from the manifest SwiftPM ACTUALLY
// RESOLVED. It is not read out of `Package.swift` as text, and it is not
// produced by walking a hard-coded directory. Four proven ways to get a file
// compiled into the app while a text-and-directory guard misses it:
//
//   1. a symlinked DIRECTORY inside the target — SwiftPM compiles through it,
//      `FileManager.enumerator` refuses to descend into it;
//   2. a second app-layer target that `CoffeeBarApp` depends on — a walk over
//      fixed directories knows nothing of the build graph;
//   3. a `path:` override moving the target's directory — the walk then
//      enumerates a directory that does not exist;
//   4. a `path:` override with the OLD directory left behind as a DECOY. This
//      is the one that defeats a `fileExists(atPath:isDirectory:)` pre-check:
//      that call proves a directory EXISTS, never that it is the one being
//      built. The guard scans the decoy, the compiler reads the real
//      directory, and a live `PreventUserIdleDisplaySleep` ships under a green
//      suite. Proven: `strings .build/debug/coffee-bar` found the assertion
//      while all four checks here passed.
//
// Asking SwiftPM closes all four at once, because the question stops being
// "what does the manifest say" and becomes "what did you compile".
//
// It also closes escape 4's nastiest variant, where the override lives in
// `Package@swift-6.swift` and `Package.swift` stays BYTE-IDENTICAL: SwiftPM
// prefers a version-specific manifest, so a text reader reads one manifest
// while the build uses another. `swift package describe` reports the manifest
// it resolved, on whichever toolchain is running. A `Package@swift-6.1.swift`
// is selected only by the 6.1.x CI toolchain and not by a 6.3 developer
// machine — the same toolchain split that already shipped the `isolated
// deinit` defect here — so `swiftPMResolvesExactlyOneManifest` refuses the
// whole construct on every toolchain as well.
//
// None of this is a denylist problem: adding names cannot fix a file that is
// never read. So the structure itself is asserted — the exact compiled file
// set, and the app layer's exact place in the build graph — and the denylist
// stays only as a second line of defence.

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

/// The targets that make up the app layer.
///
/// Target NAMES, not directories. Where each one lives on disk is SwiftPM's
/// answer to give, and asking it is what closes the `path:` override escapes.
///
/// `CoffeeBarIngest` joined this list when `CoffeeBarUI` gained a dependency on
/// it: the listener now ships INSIDE the `coffee-bar` binary, which is escape 2
/// above. Adding a name here is only half the change — every file that target
/// compiles has to appear in `expectedAppLayerEntries` too, or
/// `theAppLayerCompilesExactlyTheFilesThisGuardScans` goes red on a correct
/// change. The two lists move together, always.
private let appLayerTargets = [
    "CoffeeBarApp",
    "CoffeeBarUI",
    "CoffeeBarIngest",
]

/// The assertion layer: linked into `coffee-bar`, and NOT part of the app layer.
///
/// A fifth escape, and the reason this list exists. `CoffeeBarPower` compiles
/// into the same binary as everything above and no content check had ever read
/// one line of it. Six lines inside `AssertionHolder.acquire()` could raise
/// `kIOPMAssertionTypePreventUserIdleDisplaySleep` with the whole suite green.
///
/// It cannot simply join `appLayerTargets`. The app layer's denylist forbids
/// `import IOKit`, `IOPMAssertion` and the word `PreventUserIdleDisplaySleep`
/// outright, and this target is the assertion layer: it MUST import IOKit, it
/// MUST call `IOPMAssertionCreateWithName`, and `AssertionHolder.swift` MUST
/// keep the doc comment naming the assertion it deliberately does not hold.
/// Appending the name to `appLayerTargets` turns a CORRECT tree red, and a
/// guard that is red on correct code is deleted rather than obeyed.
///
/// So this list is held to a different rule, one that separates NAMING the
/// constant from CREATING the assertion. See
/// `theLayersBelowTheAppNeverCreateADisplaySleepAssertion`.
///
/// Unlike `appLayerTargets`, the files here are not pinned to a literal list. A
/// new file in this target is scanned the moment SwiftPM compiles it, which is
/// strictly safer than a list a human has to remember to extend.
private let powerLayerTargets = [
    "CoffeeBarPower",
]

/// The decision layer: what a session MEANS, and nothing about hardware.
///
/// Linked into `coffee-bar` and, like the power layer, never content-scanned
/// until now. It is held to the power layer's rule AND to a stricter one: it
/// reaches no IOKit at all. It needs none — it holds no assertion.
private let coreLayerTargets = [
    "CoffeeBarCore",
]

/// Every file the app layer is allowed to compile, package-root relative and
/// sorted.
///
/// A literal, deliberately. Any file that is added, renamed, moved or linked in
/// fails `theAppLayerCompilesExactlyTheFilesThisGuardScans` until a human
/// updates this list. That friction is the point: updating it is the moment
/// somebody reads the new file against design §6.1.
private let expectedAppLayerEntries = [
    "Sources/CoffeeBarApp/main.swift",
    "Sources/CoffeeBarIngest/HTTPRequestFramer.swift",
    "Sources/CoffeeBarIngest/IngestListener.swift",
    "Sources/CoffeeBarUI/AttentionListView.swift",
    "Sources/CoffeeBarUI/HookHealthReader.swift",
    "Sources/CoffeeBarUI/MenuBarGlyphs.swift",
    "Sources/CoffeeBarUI/PanelView.swift",
    "Sources/CoffeeBarUI/ServingModel.swift",
]

/// How many `.swift` files a correct scan reaches. The content checks assert
/// this so that neither can pass by reading nothing.
private let expectedSourceCount = expectedAppLayerEntries.filter { $0.hasSuffix(".swift") }.count

private enum BoundaryScanError: Error, CustomStringConvertible {
    /// `swift package describe` could not be run, or did not answer.
    ///
    /// Always fatal, never a silent empty result. A guard that cannot find out
    /// what was compiled must fail; one that shrugs and scans nothing passes
    /// everything.
    case describeFailed(String)

    /// The resolved package declares no target by that name.
    case unknownTarget(String)

    /// A target resolved, but SwiftPM compiles nothing for it.
    case compilesNothing(String)

    var description: String {
        switch self {
        case .describeFailed(let detail):
            return "swift package describe: \(detail)"
        case .unknownTarget(let name):
            return "the resolved package declares no target named \"\(name)\""
        case .compilesNothing(let name):
            return "target \"\(name)\" compiles no sources at all"
        }
    }
}

/// One target, exactly as SwiftPM resolved it.
private struct ResolvedTarget: Sendable {
    /// Package-root relative, whatever `path:` the manifest declared.
    let path: String
    /// `path`-relative, and only the files that reach the compiler.
    let sources: [String]
    let dependencies: [String]
    /// Products this target takes from ANOTHER package. Code that links in
    /// from outside this repository, where no scan below can read it.
    let productDependencies: [String]
}

/// Everything the guard reads out of one `swift package describe`.
private struct ResolvedPackage: Sendable {
    let targets: [String: ResolvedTarget]
    /// The identity of every external package this one resolved.
    let packageDependencies: [String]
}

/// The shape of `swift package describe --type json` that this file reads.
private struct ManifestDescription: Decodable {
    /// One entry of the package-level `dependencies` array.
    ///
    /// Every field is optional on purpose. The keys differ by dependency kind —
    /// a `fileSystem` entry carries `path`, a `sourceControl` entry carries a
    /// location — and this decoder must not fail on a shape it has not seen.
    /// The COUNT is what the check asserts; these fields only name the offender.
    struct Dependency: Decodable {
        let identity: String?
        let type: String?

        var summary: String { identity ?? type ?? "(unnamed)" }
    }

    struct Target: Decodable {
        let name: String
        let path: String
        let sources: [String]
        let dependencies: [String]
        let productDependencies: [String]

        private enum CodingKeys: String, CodingKey {
            case name, path, sources
            case dependencies = "target_dependencies"
            case productDependencies = "product_dependencies"
        }

        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            name = try fields.decode(String.self, forKey: .name)
            path = try fields.decode(String.self, forKey: .path)
            sources = try fields.decode([String].self, forKey: .sources)
            // Absent, not empty, for a target that depends on nothing.
            dependencies = try fields.decodeIfPresent([String].self, forKey: .dependencies) ?? []
            // Absent for every target today. SwiftPM emits the key only for a
            // target that takes a product from another package, so its absence
            // is the PASSING state and not a missing field. Measured against a
            // two-package fixture: the key appears, holding `["Dep"]`.
            productDependencies =
                try fields.decodeIfPresent([String].self, forKey: .productDependencies) ?? []
        }
    }

    let targets: [Target]
    let dependencies: [Dependency]

    private enum CodingKeys: String, CodingKey {
        case targets, dependencies
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        targets = try fields.decode([Target].self, forKey: .targets)
        dependencies = try fields.decodeIfPresent([Dependency].self, forKey: .dependencies) ?? []
    }
}

/// What SwiftPM resolved — or the failure to ask.
///
/// A global `let`, so SwiftPM is spawned ONCE however many checks read it.
/// Swift initialises a global lazily and exactly once, which is the whole
/// reason this is not a function: four checks calling `describe` separately
/// would quadruple the cost for one unchanging answer.
///
/// It holds a `Result` rather than throwing because a global initialiser
/// cannot throw. Every check calls `.get()`, so a failure to ask still fails
/// the check.
private let resolvedPackage: Result<ResolvedPackage, BoundaryScanError> = {
    do { return .success(try describePackage()) }
    catch let error as BoundaryScanError { return .failure(error) }
    catch { return .failure(.describeFailed("\(error)")) }
}()

/// Asks SwiftPM what it compiles.
///
/// Runs with a SCRATCH PATH of its own and a manifest cache inside it. This
/// runs from inside `swift test`, which holds the package's own `.build`; a
/// second SwiftPM sharing that directory would contend for the same lock.
private func describePackage() throws -> ResolvedPackage {
    let files = FileManager.default
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "coffee-bar-boundary-\(UUID().uuidString)")
    let errorLog = scratch.appending(path: "describe.err")

    do {
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
    } catch {
        throw BoundaryScanError.describeFailed("no scratch directory: \(error)")
    }
    defer { try? files.removeItem(at: scratch) }

    guard files.createFile(atPath: errorLog.path, contents: nil),
          let errorHandle = try? FileHandle(forWritingTo: errorLog)
    else { throw BoundaryScanError.describeFailed("could not open \(errorLog.path)") }
    defer { try? errorHandle.close() }

    let output = Pipe()
    let swiftPM = Process()
    swiftPM.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    swiftPM.arguments = [
        "swift", "package",
        "--package-path", packageRoot.path,
        "--scratch-path", scratch.path,
        "--manifest-cache", "local",
        "describe", "--type", "json",
    ]
    swiftPM.standardOutput = output
    // A FILE, not a second pipe. Draining one pipe while the other fills is
    // how a two-pipe child wedges, and this check has no business owning that
    // problem — `CoffeeBarPower.ProbeRun` already does.
    swiftPM.standardError = errorHandle

    do {
        try swiftPM.run()
    } catch {
        throw BoundaryScanError.describeFailed("could not run it: \(error)")
    }

    // Read to EOF, THEN wait. The description is a few kilobytes, well inside
    // the pipe buffer, and stderr goes to a file, so neither end can wedge.
    let json = output.fileHandleForReading.readDataToEndOfFile()
    swiftPM.waitUntilExit()

    guard swiftPM.terminationStatus == 0 else {
        let complaint = (try? String(contentsOf: errorLog, encoding: .utf8)) ?? "(no stderr)"
        throw BoundaryScanError.describeFailed(
            "exited \(swiftPM.terminationStatus): \(complaint)")
    }

    let described: ManifestDescription
    do {
        described = try JSONDecoder().decode(ManifestDescription.self, from: json)
    } catch {
        throw BoundaryScanError.describeFailed("could not decode the description: \(error)")
    }

    // A description listing nothing would satisfy every check below by
    // reaching no file at all.
    guard described.targets.isEmpty == false else {
        throw BoundaryScanError.describeFailed("it listed no targets at all")
    }

    let rootPrefix = packageRoot.path + "/"
    let targets = Dictionary(uniqueKeysWithValues: described.targets.map { target in
        // SwiftPM reports a package-root relative path today. Normalise anyway,
        // so an absolute one would not silently miss `expectedAppLayerEntries`.
        let relative = target.path.hasPrefix(rootPrefix)
            ? String(target.path.dropFirst(rootPrefix.count))
            : target.path
        return (target.name, ResolvedTarget(path: relative,
                                            sources: target.sources,
                                            dependencies: target.dependencies,
                                            productDependencies: target.productDependencies))
    })

    return ResolvedPackage(targets: targets,
                           packageDependencies: described.dependencies.map(\.summary))
}

/// Swift source with every COMMENT removed and every STRING LITERAL kept.
///
/// This is the discriminator the whole below-app scan rests on. A doc comment
/// that names `PreventUserIdleDisplaySleep` is exactly what
/// `AssertionHolder.swift` must keep saying; the same word in CODE raises the
/// assertion this product exists not to hold. A plain `contains` cannot tell
/// the two apart, so the comments go first and the check reads what is left.
///
/// String literals are KEPT, deliberately. `kIOPMAssertionTypePreventUserIdle`
/// `DisplaySleep` is a `String` constant whose value is the plain text
/// `"PreventUserIdleDisplaySleep"`, so
/// `IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString, …)`
/// raises a live display assertion while naming no constant anywhere. Stripping
/// literals would open that route.
///
/// LIMIT, stated rather than hidden: this is a small lexer, not the Swift
/// grammar. It handles `//`, nested `/* */`, escapes, multi-line `"""` and raw
/// `#"…"#` strings, all of which are what the scanned targets contain today. A
/// BARE REGEX LITERAL (`/…/`) would confuse it; the package uses none, and
/// `swiftCodeWithoutCommentsKeepsCodeAndDropsComments` pins the behaviour.
private func swiftCodeWithoutComments(_ source: String) -> String {
    // NOT IMPLEMENTED. The below-app checks are RED until it strips.
    source
}

/// Every file the app layer's targets compile, package-root relative and
/// sorted.
private func appLayerEntries() throws -> [String] {
    let targets = try resolvedPackage.get().targets
    var found: [String] = []

    for name in appLayerTargets {
        guard let target = targets[name] else { throw BoundaryScanError.unknownTarget(name) }
        guard target.sources.isEmpty == false else {
            throw BoundaryScanError.compilesNothing(name)
        }
        found.append(contentsOf: target.sources.map { "\(target.path)/\($0)" })
    }

    return found.sorted()
}

/// The `.swift` files the content checks read, in the same fixed order.
private func appLayerSources() throws -> [URL] {
    try appLayerEntries()
        .filter { $0.hasSuffix(".swift") }
        .map { packageRoot.appending(path: $0) }
}

/// The `dependencies:` SwiftPM resolved for one target.
private func resolvedDependencies(ofTarget name: String) throws -> [String] {
    let targets = try resolvedPackage.get().targets
    guard let target = targets[name] else { throw BoundaryScanError.unknownTarget(name) }
    return target.dependencies
}

/// Every target that reaches the `coffee-bar` binary, walked from the resolved
/// build graph rather than from the manifest text.
///
/// This is what `appLayerTargets` alone cannot express: a NAMED list says what
/// the guard looks at, and this says what the LINKER takes. The gap between the
/// two is finding B6.
private func linkedClosure(fromTarget root: String) throws -> Set<String> {
    let targets = try resolvedPackage.get().targets
    var reached: Set<String> = []
    var pending = [root]

    while let name = pending.popLast() {
        guard reached.insert(name).inserted else { continue }
        guard let target = targets[name] else { throw BoundaryScanError.unknownTarget(name) }
        pending.append(contentsOf: target.dependencies)
    }

    return reached
}

/// The `.swift` files a named group of targets compiles, sorted.
///
/// Kept apart from `appLayerEntries()` on purpose: that one answers the exact
/// pinned file set the app layer is allowed to compile, and no check below the
/// app layer pins a literal list.
private func sources(ofTargets names: [String]) throws -> [URL] {
    let targets = try resolvedPackage.get().targets
    var found: [String] = []

    for name in names {
        guard let target = targets[name] else { throw BoundaryScanError.unknownTarget(name) }
        guard target.sources.isEmpty == false else {
            throw BoundaryScanError.compilesNothing(name)
        }
        found.append(contentsOf: target.sources.map { "\(target.path)/\($0)" })
    }

    return found.sorted()
        .filter { $0.hasSuffix(".swift") }
        .map { packageRoot.appending(path: $0) }
}

// MARK: - The scanned set itself

@Test func theAppLayerCompilesExactlyTheFilesThisGuardScans() throws {
    // Named bug this catches: any app-layer file the other checks never read.
    // Proven escapes, each of which compiled into the shipped `coffee-bar`
    // binary while a text-and-directory guard stayed green — a symlinked
    // directory (`LinkProbe.swift.o` was built); a moved app directory under a
    // `path:` override, which left `main.swift` unscanned; and the same
    // override with the old directory kept as a DECOY, which left the guard
    // reading three innocent files while the compiler read three others.
    let found = try appLayerEntries()
    let expected = expectedAppLayerEntries

    // A scan that reached nothing would satisfy every content check below.
    #expect(found.isEmpty == false,
            "the boundary guard scanned nothing at \(packageRoot.path)")

    #expect(found == expected, """
        the app layer's compiled file set changed.
          unexpected: \(found.filter { !expected.contains($0) })
          missing:    \(expected.filter { !found.contains($0) })
        Every check in this file reads only the files SwiftPM compiles. Update \
        `expectedAppLayerEntries` deliberately, after reading the new file \
        against design §6.1.
        """)
}

@Test func theAppLayerGainsNoUnscannedTargetInTheBuildGraph() throws {
    // The file set above covers the NAMED targets in `appLayerTargets`, so it
    // cannot see one more. Named bug this catches: a `Sources/CoffeeBarPanelKit`
    // that `CoffeeBarApp` depends on. It compiled (`Escape.swift.o`), linked
    // into `coffee-bar`, named `IOPMAssertion`, and both old checks passed —
    // the scan simply never looked there.
    //
    // Every scanned target's own dependency list is asserted, not just the
    // executable's: a new target hung off the model, or off the listener, ships
    // in the app just the same. `CoffeeBarIngest` is scanned since
    // `CoffeeBarUI` gained a dependency on it, so its edges are now the frontier
    // and are pinned here too.
    //
    // Read from the RESOLVED graph, not from the manifest text. A text parser
    // reads the `dependencies:` list of whichever manifest file it opens, and
    // cannot know that SwiftPM opened a different one.
    #expect(try resolvedDependencies(ofTarget: "CoffeeBarApp") == ["CoffeeBarUI"],
            "CoffeeBarApp gained a dependency; a new app-layer target is unscanned")
    #expect(try resolvedDependencies(ofTarget: "CoffeeBarUI")
            == ["CoffeeBarPower", "CoffeeBarIngest"],
            "CoffeeBarUI gained a dependency; a new app-layer target is unscanned")
    #expect(try resolvedDependencies(ofTarget: "CoffeeBarIngest") == ["CoffeeBarCore"],
            "CoffeeBarIngest gained a dependency; a new app-layer target is unscanned")
}

@Test func everyTargetLinkedIntoTheBinaryIsContentScanned() throws {
    // Finding B6, the structural half. Named bug this catches, and it was LIVE:
    // `CoffeeBarPower` and `CoffeeBarCore` link into `coffee-bar` and no content
    // check in this package had ever read one line of either. The audit's six
    // lines inside `AssertionHolder.acquire()`, raising
    // `kIOPMAssertionTypePreventUserIdleDisplaySleep` under any name other than
    // `AssertionHolder.assertionName`, shipped with all 372 checks green.
    //
    // `theAppLayerGainsNoUnscannedTargetInTheBuildGraph` does NOT cover this. It
    // pins the dependency EDGES of three targets, so it catches a NEW dependency
    // appearing. Both targets here were already linked when it was written; a
    // pinned edge is satisfied by the dependency it pins.
    //
    // So this asserts COVERAGE instead of edges: every target the linker reaches
    // from the executable belongs to exactly one tier, and every tier is read by
    // a content check in this file. A new target cannot be linked in without
    // landing in a tier, and choosing the tier is the moment somebody decides
    // what that code is allowed to do.
    let linked = try linkedClosure(fromTarget: "CoffeeBarApp")
    let scanned = Set(appLayerTargets + powerLayerTargets + coreLayerTargets)

    // A walk that reached nothing would equal an empty tier set and pass.
    #expect(linked.isEmpty == false,
            "the closure walk reached no target at \(packageRoot.path)")

    #expect(linked == scanned, """
        the targets linked into coffee-bar are not the targets this guard scans.
          linked but unscanned: \(linked.subtracting(scanned).sorted())
          scanned but unlinked: \(scanned.subtracting(linked).sorted())
        A linked target that no check reads can hold a display assertion under a \
        green suite — that is exactly how CoffeeBarPower went unread. Add each \
        new target to the tier matching what it may do, after reading it \
        against design §6.1.
        """)
}

@Test func swiftPMResolvesExactlyOneManifest() throws {
    // Named bug this catches: a `Package@swift-6.swift` that redirects the app
    // layer while `Package.swift` stays byte-identical. SwiftPM prefers
    // `Package@swift-<major>[.<minor>[.<patch>]].swift` over `Package.swift`,
    // so the two files disagree and only one of them is built.
    //
    // The checks above already read the manifest SwiftPM resolved, so they
    // catch this ON THE TOOLCHAIN THAT SELECTS IT. That is not enough on its
    // own: a `Package@swift-6.1.swift` is selected by the 6.1.2 CI runner and
    // ignored by a 6.3 developer machine, so the developer sees green for a
    // build nobody local performs. This check refuses the construct itself and
    // therefore fails on every toolchain, whichever one would select it.
    //
    // The package has one manifest and needs one. Should it ever need a
    // version-specific manifest, this check is the deliberate stop where
    // somebody re-reads BOTH manifests against design §6.1.
    let root = try FileManager.default.contentsOfDirectory(atPath: packageRoot.path)

    // A listing that reached nothing would pass the filter below trivially.
    #expect(root.contains("Package.swift"),
            "no Package.swift at \(packageRoot.path); this guard listed the wrong directory")

    let versioned = root
        .filter { $0.hasPrefix("Package@swift-") && $0.hasSuffix(".swift") }
        .sorted()

    #expect(versioned.isEmpty, """
        the package root holds a version-specific manifest: \(versioned).
        SwiftPM prefers it over Package.swift on the toolchains it matches, so \
        the manifest a reader opens is not the manifest that gets built. Remove \
        it, or update this guard deliberately after reading every manifest \
        against design §6.1.
        """)
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
    // structural checks above bound what it never gets to read.
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

// MARK: - What the layers BELOW the app may do

@Test func theLayersBelowTheAppNeverCreateADisplaySleepAssertion() throws {
    // Finding B6, the content half, and design §6.1 again — one layer down.
    //
    // The app layer's denylist cannot be pointed at these targets.
    // `CoffeeBarPower` IS the assertion layer: `import IOKit.pwr_mgt` and
    // `IOPMAssertionCreateWithName` are its job, and `AssertionHolder.swift`
    // carries the doc comment explaining which assertion it deliberately does
    // NOT hold. `CoffeeBarCore/PowerTypes.swift` explains the product against
    // `caffeinate -d` in prose. Every one of those is CORRECT code that the
    // app-layer denylist would reject.
    //
    // The discriminator is therefore comments, not words: a comment may NAME
    // the constant, code may not CREATE the assertion. `swiftCodeWithoutComments`
    // draws that line, and keeps string literals so a raw
    // `IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString, …)`
    // is still caught.
    //
    // Named bug this catches: the audit's exact escape, six lines inside
    // `AssertionHolder.acquire()` raising the display assertion under a name
    // other than `AssertionHolder.assertionName`. The holder's own live-IOKit
    // check filtered assertions by NAME, so an assertion raised under a
    // different name was invisible to it — fixed in `AssertionHolder_test.swift`
    // by reading the process's assertion TYPES, which is the behavioural half of
    // the same finding.
    let files = try sources(ofTargets: powerLayerTargets + coreLayerTargets)

    // A scan that reached nothing, or reached the wrong directory, satisfies
    // every `contains` below. Anchor on the file the finding is about.
    #expect(files.contains { $0.lastPathComponent == "AssertionHolder.swift" }, """
        the below-app scan never reached AssertionHolder.swift; it read \
        \(files.count) files under \(packageRoot.path)
        """)

    // Every documented route to pinning the DISPLAY awake.
    //
    // `IOPMAssertion` and `import IOKit` are deliberately ABSENT: this layer
    // owns the system-sleep assertion and must keep both. That is the whole
    // difference between this list and the app layer's.
    //
    // `NoDisplaySleep` covers `kIOPMAssertionTypeNoDisplaySleep`, whose value is
    // `"NoDisplaySleepAssertion"`. `beginActivity` and `performActivity` raise a
    // live display assertion through Foundation with no IOKit call at all.
    // A bare `DisplaySleep` is NOT used here: `DesiredPowerState` carries a
    // legitimate `displaySleepAssertion` property, which such a term would
    // reject on correct code.
    let forbidden = [
        "PreventUserIdleDisplaySleep",  // and kIOPMAssertionTypePreventUserIdleDisplaySleep
        "NoDisplaySleep",               // kIOPMAssertionTypeNoDisplaySleep
        "beginActivity",
        "performActivity",
        "idleDisplaySleepDisabled",
        "caffeinate",
    ]

    for file in files {
        let code = swiftCodeWithoutComments(try String(contentsOf: file, encoding: .utf8))
        for name in forbidden {
            #expect(!code.contains(name), """
                \(file.lastPathComponent) names \(name) in CODE rather than in a \
                comment. coffee-bar holds PreventUserIdleSystemSleep and no \
                display assertion of any kind (design §6.1). A comment may name \
                the constant; creating one is what this refuses.
                """)
        }
    }
}

@Test func theCoreLayerReachesNoIOKitAtAll() throws {
    // `CoffeeBarCore` decides what a session MEANS. It holds no assertion, so
    // unlike `CoffeeBarPower` it has no reason to reach IOKit at all, and the
    // stricter rule costs it nothing. It imports only Foundation today.
    //
    // Named bug this catches: an assertion path opened in the layer that BOTH
    // the app layer and the power layer depend on. `PowerBroker` already decides
    // `DesiredPowerState`, so a direct IOKit call here would leave that decision
    // reading `displaySleepAssertion == false` while the display was pinned
    // awake — the same defect design §6.1 forbids, in the one place both other
    // layers trust.
    //
    // Comments are stripped for the same reason as above: `PowerTypes.swift`
    // must keep explaining the product against `caffeinate -d` in prose.
    let files = try sources(ofTargets: coreLayerTargets)

    #expect(files.contains { $0.lastPathComponent == "PowerBroker.swift" }, """
        the core scan never reached PowerBroker.swift; it read \(files.count) \
        files under \(packageRoot.path)
        """)

    for file in files {
        let code = swiftCodeWithoutComments(try String(contentsOf: file, encoding: .utf8))
        for name in ["IOKit", "IOPMAssertion"] {
            #expect(!code.contains(name), """
                \(file.lastPathComponent) names \(name) in CODE. CoffeeBarCore \
                is the decision layer and reaches no power hardware; the \
                assertion lives in CoffeeBarPower behind AssertionHolder.
                """)
        }
    }
}

// MARK: - Code that arrives from outside this repository

@Test func thePackageResolvesNoExternalDependency() throws {
    // Finding B5. Every content check in this file reads FILES INSIDE THIS
    // REPOSITORY. A dependency on another package links code that no closure
    // walk can reach, however complete the walk is, because the source is not
    // here to read. `everyTargetLinkedIntoTheBinaryIsContentScanned` would still
    // pass: the external product is not a target of this package.
    //
    // Both doors are asserted, and both are read from the description SwiftPM
    // RESOLVED rather than from manifest text — so the `Package@swift-6.swift`
    // escape documented at the top of this file cannot defeat them:
    //
    //   1. the package's own `dependencies`, which is what a `.package(url:)` or
    //      `.package(path:)` in the manifest produces; and
    //   2. every target's `product_dependencies`, which is what actually LINKS
    //      that foreign code into a binary.
    //
    // Door 2 is not redundant. A dependency declared and unused is harmless; a
    // product taken into a target is the one that ships. SwiftPM emits
    // `product_dependencies` only for a target that has one, so its absence
    // today is the passing state and not a missing field — measured against a
    // two-package fixture, where the key appears holding `["Dep"]`.
    //
    // Should this package ever need a dependency, this check is the deliberate
    // stop where somebody decides how the new code gets read for §6.1.
    let package = try resolvedPackage.get()

    // A description of nothing would satisfy both checks below.
    #expect(package.targets.isEmpty == false,
            "the description listed no targets at \(packageRoot.path)")

    #expect(package.packageDependencies.isEmpty, """
        the package resolved external dependencies: \(package.packageDependencies).
        Their sources live outside this repository, so no check in this file can \
        read them for a display assertion. Vendor the code, or extend this guard \
        to scan the checkout deliberately.
        """)

    let importers = package.targets
        .filter { $0.value.productDependencies.isEmpty == false }
        .map { "\($0.key) takes \($0.value.productDependencies.sorted())" }
        .sorted()

    #expect(importers.isEmpty, """
        targets link products from another package: \(importers).
        That code reaches the coffee-bar binary and no content check here reads \
        one line of it.
        """)
}

// MARK: - The discriminator the below-app checks rest on

@Test func swiftCodeWithoutCommentsKeepsCodeAndDropsComments() {
    // The below-app checks are only as good as this function. If it stripped
    // nothing, `AssertionHolder.swift`'s doc comment would fail a correct tree;
    // if it stripped string literals, a display assertion raised from a plain
    // literal would pass. Both directions are pinned here.
    //
    // Each case is a literal in, a literal out — never the function's own logic
    // re-run as the expectation.
    let cases: [(name: String, source: String, expected: String)] = [
        ("a line comment goes, the code around it stays",
         "let a = 1 // PreventUserIdleDisplaySleep\nlet b = 2",
         "let a = 1 \nlet b = 2"),

        ("a doc comment naming the constant goes",
         "/// does **not** hold `PreventUserIdleDisplaySleep`.\nlet a = 1",
         "\nlet a = 1"),

        ("a block comment goes and keeps its line breaks",
         "let a = 1\n/* caffeinate -d\n   beginActivity */\nlet b = 2",
         "let a = 1\n\n\nlet b = 2"),

        ("nested block comments close at the outer end, not the inner one",
         "let a = 1 /* outer /* inner */ still comment */ let b = 2",
         "let a = 1  let b = 2"),

        // The escape route that stripping literals would open.
        ("a string literal survives, contents and all",
         "IOPMAssertionCreateWithName(\"PreventUserIdleDisplaySleep\" as CFString)",
         "IOPMAssertionCreateWithName(\"PreventUserIdleDisplaySleep\" as CFString)"),

        ("`//` inside a string literal opens no comment",
         "let url = \"https://example.com/beginActivity\"\nlet a = 1",
         "let url = \"https://example.com/beginActivity\"\nlet a = 1"),

        ("`/*` inside a string literal opens no comment",
         "let glob = \"/*\"\nlet a = 1",
         "let glob = \"/*\"\nlet a = 1"),

        ("an escaped quote does not end the string early",
         "let a = \"he said \\\"caffeinate\\\" loudly\" // gone\nlet b = 2",
         "let a = \"he said \\\"caffeinate\\\" loudly\" \nlet b = 2"),

        ("a raw string keeps its contents and its delimiters",
         "let a = #\"a \\#(x) caffeinate \"quoted\" here\"# // gone",
         "let a = #\"a \\#(x) caffeinate \"quoted\" here\"# "),

        ("a multi-line string keeps everything between the fences",
         "let a = \"\"\"\n// not a comment\ncaffeinate\n\"\"\"\nlet b = 2",
         "let a = \"\"\"\n// not a comment\ncaffeinate\n\"\"\"\nlet b = 2"),

        ("a `#` that opens no string is kept",
         "let p = #filePath // gone",
         "let p = #filePath "),

        ("division is not a comment",
         "let half = total / 2 / 1",
         "let half = total / 2 / 1"),
    ]

    for testCase in cases {
        #expect(swiftCodeWithoutComments(testCase.source) == testCase.expected,
                "\(testCase.name): got \(swiftCodeWithoutComments(testCase.source).debugDescription)")
    }
}

@Test func thePanelReadsTheHookAdvisoryTheModelPublishes() throws {
    // Named bug this catches, and it SHIPPED: commit 5116326 landed the hook
    // health check, `ServingModel` published it, every check was green — and
    // `PanelView` read it nowhere, so the user saw nothing at all. A published
    // value no view reads is a feature that does not exist.
    //
    // This reads the source because the behavioural route is closed: M1 design
    // §5.4 forbids asserting on rendered AppKit text, so no check in this
    // package can watch the panel draw a line.
    //
    // LIMIT, stated rather than hidden: this proves the panel NAMES the
    // property, not that it renders what it reads. A mention inside a comment
    // would satisfy it. It is a tripwire against deleting the render, not proof
    // the render is correct.
    let files = try appLayerSources()
    #expect(files.count == expectedSourceCount,
            "the boundary guard scanned \(files.count) files at \(packageRoot.path)")

    let panel = try #require(files.first { $0.lastPathComponent == "PanelView.swift" },
                             "the app layer no longer compiles a PanelView.swift")
    let source = try String(contentsOf: panel, encoding: .utf8)

    #expect(source.contains("model.hookAdvisory"), """
        PanelView.swift never reads model.hookAdvisory, so the hook health \
        check reaches the user nowhere. Render it, or delete the property and \
        the checks that assert its text.
        """)
}

@Test func thePanelReadsEverySessionValueTheModelPublishes() throws {
    // The same tripwire as the check above, for the three values the panel
    // gained with the attention list. Each one is computed in `refresh()`, has
    // its own checks in `ServingModelIngest_test.swift`, and reaches the user
    // through exactly one line of `PanelView`. Delete that line and every one
    // of those checks stays green while the panel goes blank.
    //
    // `model.attention` is what design §10.3 asks for; `model.workingSummary`
    // is what design §14 REQUIRES, after a review found that the session
    // holding the machine awake appeared nowhere. `model.ingestAdvisory` is the
    // report that THIS PROCESS is not serving, which no read of the user's
    // settings file can give — PE finding B2. Losing that one silently is how
    // a dead socket ships under a panel that looks healthy.
    //
    // Same LIMIT as above, stated rather than hidden: this proves the panel
    // NAMES each property, not that it renders it correctly. A mention in a
    // comment would satisfy it. It is a tripwire against deleting the render.
    let files = try appLayerSources()
    #expect(files.count == expectedSourceCount,
            "the boundary guard scanned \(files.count) files at \(packageRoot.path)")

    let panel = try #require(files.first { $0.lastPathComponent == "PanelView.swift" },
                             "the app layer no longer compiles a PanelView.swift")
    let source = try String(contentsOf: panel, encoding: .utf8)

    for property in ["model.attention", "model.workingSummary", "model.ingestAdvisory"] {
        #expect(source.contains(property), """
            PanelView.swift never reads \(property), so what the model computes \
            for it reaches the user nowhere. Render it, or delete the property \
            and the checks that assert its value.
            """)
    }
}
