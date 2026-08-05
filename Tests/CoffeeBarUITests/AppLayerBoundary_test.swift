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
/// `onlyAssertionHolderMayCreateADisplaySleepAssertion`.
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

/// The privileged CLI. Linked into `coffee-bar-probe`, never into `coffee-bar`.
///
/// It is deliberately NOT added to the three lists above. Those are unioned
/// into the `linked == scanned` assertion in
/// `everyTargetLinkedIntoTheBinaryIsContentScanned`, and this target is not in
/// the app binary's closure — adding it there would turn a correct tree red.
/// It is scanned by `noTargetOnThePrivilegedPathReachesForXPCOrSMAppService`,
/// which is the one rule it has to answer for.
private let probeLayerTargets = [
    "CoffeeBarProbe",
]

/// The ONE file entitled to create a display assertion, and the ONE symbol it
/// may name in code.
///
/// Issue #12 settled the design question the old absolute ban encoded: "never
/// holds the display" is a DEFAULT, not a product promise. A user may opt in,
/// so exactly one file has to be allowed to raise the assertion — and that file
/// is `AssertionHolder`, which already owns every other IOKit call in this
/// package.
///
/// It is a FILE and a SYMBOL, never a blanket pass. `AssertionHolder.swift` is
/// still refused `NoDisplaySleep`, `beginActivity`, `performActivity`,
/// `idleDisplaySleepDisabled` and `caffeinate`, because none of those is the
/// route this product chose and each one is a different way to pin the screen
/// awake. Widening this to "AssertionHolder.swift may say anything" would
/// delete the guard for the one file it most needs to read.
///
/// The app layer is NOT covered by this and must not be.
/// `theAppLayerNeverNamesADisplaySleepAssertion` scans `CoffeeBarApp`,
/// `CoffeeBarUI` and `CoffeeBarIngest`, never reaches this file, and keeps its
/// absolute ban: the opt-in reaches IOKit through `DesiredPowerState` and the
/// holder, so no app-layer file has any business naming the assertion.
private let displayAssertionEntitlement = (file: "AssertionHolder.swift",
                                           symbol: "PreventUserIdleDisplaySleep")

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
    "Sources/CoffeeBarUI/AppVersion.swift",
    "Sources/CoffeeBarUI/AttentionListView.swift",
    "Sources/CoffeeBarUI/BrandPalette.swift",
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
    /// Product name -> the targets that product names directly.
    ///
    /// The linker takes a product's targets whether or not any dependency edge
    /// reaches them, so a dependency walk alone cannot see this route.
    let productTargets: [String: [String]]
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

    /// One entry of the package-level `products` array.
    ///
    /// Only the name and the target list matter here. `type` distinguishes an
    /// executable from a library and this check does not care: a target named by
    /// ANY product is a target the linker can take.
    struct Product: Decodable {
        let name: String
        let targets: [String]
    }

    let targets: [Target]
    let dependencies: [Dependency]
    let products: [Product]

    private enum CodingKeys: String, CodingKey {
        case targets, dependencies, products
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        targets = try fields.decode([Target].self, forKey: .targets)
        dependencies = try fields.decodeIfPresent([Dependency].self, forKey: .dependencies) ?? []
        products = try fields.decodeIfPresent([Product].self, forKey: .products) ?? []
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
                           packageDependencies: described.dependencies.map(\.summary),
                           productTargets: Dictionary(
                               described.products.map { ($0.name, $0.targets) },
                               uniquingKeysWith: { first, _ in first }))
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
    let characters = Array(source)
    var kept: [Character] = []
    kept.reserveCapacity(characters.count)
    var index = 0

    /// Whether `text` sits at `start`.
    func matches(_ text: [Character], at start: Int) -> Bool {
        guard start >= 0, start + text.count <= characters.count else { return false }
        for (offset, character) in text.enumerated() where characters[start + offset] != character {
            return false
        }
        return true
    }

    while index < characters.count {
        // A raw string opens with a run of `#` immediately before the quote.
        var hashes = 0
        while index + hashes < characters.count && characters[index + hashes] == "#" { hashes += 1 }
        let pounds = Array(repeating: Character("#"), count: hashes)

        if index + hashes < characters.count && characters[index + hashes] == "\"" {
            // A string literal. Copy it VERBATIM, delimiters and contents.
            let multiline = matches(["\"", "\"", "\""], at: index + hashes)
            let closing = Array(repeating: Character("\""), count: multiline ? 3 : 1) + pounds
            let opening = hashes + (multiline ? 3 : 1)
            kept.append(contentsOf: characters[index ..< index + opening])
            index += opening

            while index < characters.count {
                // `\` escapes the next character — in a raw string only when a
                // matching run of `#` follows it.
                if characters[index] == "\\" && matches(pounds, at: index + 1) {
                    let width = min(hashes + 2, characters.count - index)
                    kept.append(contentsOf: characters[index ..< index + width])
                    index += width
                    continue
                }
                if matches(closing, at: index) {
                    kept.append(contentsOf: characters[index ..< index + closing.count])
                    index += closing.count
                    break
                }
                kept.append(characters[index])
                index += 1
            }
            continue
        }

        if hashes > 0 {
            // A `#` that opens no string: an attribute, a macro, `#filePath`.
            kept.append(contentsOf: characters[index ..< index + hashes])
            index += hashes
            continue
        }

        if matches(["/", "/"], at: index) {
            // To the end of the line. The newline itself is kept next turn, so
            // the stripped text keeps its line structure.
            while index < characters.count && characters[index] != "\n" { index += 1 }
            continue
        }

        if matches(["/", "*"], at: index) {
            // Swift nests block comments, so this counts rather than scanning
            // for the first `*/`.
            var depth = 0
            while index < characters.count {
                if matches(["/", "*"], at: index) { depth += 1; index += 2; continue }
                if matches(["*", "/"], at: index) {
                    depth -= 1
                    index += 2
                    if depth == 0 { break }
                    continue
                }
                if characters[index] == "\n" { kept.append("\n") }
                index += 1
            }
            continue
        }

        kept.append(characters[index])
        index += 1
    }

    return String(kept)
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

@Test func theCoffeeBarProductNamesOnlyTargetsTheGuardScans() throws {
    // Named bug this catches: a target added to the `coffee-bar` product's
    // `targets:` list and to NO dependency list. The linker takes it; the
    // dependency walk in `linkedClosure` never reaches it; every content check
    // in this file therefore skips it. That is the same class as finding B6,
    // through the door B6's fix left open.
    let productTargets = try resolvedPackage.get().productTargets

    let named = try #require(productTargets["coffee-bar"],
                             "no product named coffee-bar; the guard is reading the wrong package")

    // Not decoration: a decode that produced an empty list would pass a subset
    // check against anything.
    #expect(named.isEmpty == false, "the coffee-bar product names no targets")

    let scanned = Set(appLayerTargets + powerLayerTargets + coreLayerTargets)
    let unscanned = Set(named).subtracting(scanned)

    #expect(unscanned.isEmpty, """
        the coffee-bar product names targets this guard never scans.
          unscanned: \(unscanned.sorted())
        Add each to a tier list, or take it out of the product.
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

@Test func onlyAssertionHolderMayCreateADisplaySleepAssertion() throws {
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
    // ONE file is entitled to cross that line, for ONE symbol: issue #12 made
    // the display hold an opt-in DEFAULT rather than a promise, so
    // `AssertionHolder.swift` may raise `PreventUserIdleDisplaySleep`. See
    // `displayAssertionEntitlement`. Every other file, and every other name,
    // is refused exactly as before.
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
    // every `contains` below. Anchor on the file the finding is about — which
    // is also the entitled file, so a scan that misses it silently turns the
    // exemption below into an exemption for nobody.
    #expect(files.contains { $0.lastPathComponent == displayAssertionEntitlement.file }, """
        the below-app scan never reached \(displayAssertionEntitlement.file); it read \
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

    // The entitlement is a HOLE in the list above, so it is worthless once the
    // list stops carrying the symbol it exempts. Named bug this catches: a
    // rename that touches one of the two and not the other, which leaves
    // `PreventUserIdleDisplaySleep` unguarded in EVERY file below the app while
    // this check still reads as though one file were special.
    #expect(forbidden.contains(displayAssertionEntitlement.symbol), """
        the entitlement exempts \(displayAssertionEntitlement.symbol) from a denylist \
        that no longer carries it: \(forbidden). The symbol is then refused \
        nowhere, so this check no longer discriminates for any file.
        """)

    for file in files {
        let code = swiftCodeWithoutComments(try String(contentsOf: file, encoding: .utf8))
        let entitled = file.lastPathComponent == displayAssertionEntitlement.file

        for name in forbidden {
            // ONE file, ONE symbol. `AssertionHolder.swift` still answers for
            // every other name here, and every other file still answers for
            // this one.
            if entitled && name == displayAssertionEntitlement.symbol { continue }

            #expect(!code.contains(name), """
                \(file.lastPathComponent) names \(name) in CODE rather than in a \
                comment. coffee-bar holds PreventUserIdleSystemSleep, and the \
                display assertion is raised in \(displayAssertionEntitlement.file) \
                and nowhere else (design §6.1, issue #12). A comment may name the \
                constant; creating one outside that file is what this refuses.
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

@Test func theCoreLayerReadsNoFilesAtAll() throws {
    // Design §8, the layering rule issue #10c leaned on: `CoffeeBarCore` decides
    // what a session MEANS and performs no I/O. Every parse takes `Data`, and
    // the file read lives in the app layer behind `HookHealthReader`.
    //
    // Named bug this catches, and #10c made it live rather than theoretical:
    // `HookHealth.settingsPath(for:)` now names where each tool keeps its hook
    // file, and the obvious next step is to resolve that path against the home
    // directory and open it RIGHT THERE. That single line would put a filesystem
    // read in the layer both other layers depend on, make the pure parse
    // untestable without a real home directory, and give `HookHealthReader` a
    // second reader to disagree with.
    //
    // `URL(fileURLWithPath:)` is deliberately ABSENT from the list.
    // `SessionHub` builds a `URL` from a payload's `cwd` string, which is value
    // construction and touches no disk; banning it would be red on correct code.
    // Every name below either opens a file or resolves a real location on this
    // machine.
    //
    // Comments are stripped for the reason the checks above strip them: this
    // file's own doc comments must keep explaining what the layer may not do.
    let files = try sources(ofTargets: coreLayerTargets)

    // A scan that reached nothing satisfies every `contains` below. Anchor on
    // the file the rule is now about.
    #expect(files.contains { $0.lastPathComponent == "HookHealth.swift" }, """
        the core scan never reached HookHealth.swift; it read \(files.count) \
        files under \(packageRoot.path)
        """)

    let forbidden = [
        "FileManager",
        "Data(contentsOf",
        "contentsOfFile",
        "fileExists",
        "homeDirectoryForCurrentUser",
        "NSHomeDirectory",
        "FileHandle",
        "InputStream",
    ]

    for file in files {
        let code = swiftCodeWithoutComments(try String(contentsOf: file, encoding: .utf8))
        for name in forbidden {
            #expect(!code.contains(name), """
                \(file.lastPathComponent) names \(name) in CODE. CoffeeBarCore \
                is the decision layer and reads no files: the parse takes Data, \
                and the read lives in the app layer behind HookHealthReader \
                (design §8).
                """)
        }
    }
}

// MARK: - The privileged path M5 chose, and the two it did not

@Test func noTargetOnThePrivilegedPathReachesForXPCOrSMAppService() throws {
    // Carlos's M5 decision, made structural. It is a SECURITY property, not a
    // preference, and the measurement that forced it is this:
    //
    //   codesign -dvvv <the shipped CoffeeBar.app>
    //     Signature=adhoc          TeamIdentifier=not set
    //   codesign -v -R='anchor apple generic' <same>   -> rc=1
    //
    // SECURITY.md:149-151 requires an XPC helper to pin its peer with
    // `setCodeSigningRequirement` and to reject any peer that does not match
    // the app's Team ID and bundle ID. The only bundle that ships today is
    // built from source by the Homebrew formula and carries no Team ID and no
    // certificate chain, so that requirement cannot be met on the one channel
    // that exists. An XPC listener whose peer check cannot be satisfied is not
    // a weaker helper — it is an unauthenticated root service.
    //
    // So M5 ships as a root CLI plus a launchd watchdog, and this refuses the
    // two constructs that would quietly reintroduce the problem. Named bug it
    // catches: an `NSXPCListener(machServiceName:)` added to the probe or to
    // the app, which would compile, run, and accept any local peer.
    //
    // `SMJobBless` is here too though nothing has ever used it: it is the
    // deprecated path SECURITY.md already rules out, and a search for "how do I
    // install a privileged helper" finds it first.
    //
    // Comments are stripped, deliberately. `LidClosedSession.swift`,
    // `CoffeeBarProbe/main.swift` and `LaunchDaemonInstaller.swift` all NAME
    // these APIs in prose to explain why they are not used, and that prose is
    // the reasoning nobody should delete. Naming one in a comment is required;
    // calling one is what this refuses.
    let targets = try linkedClosure(fromTarget: "CoffeeBarApp").sorted()
        + probeLayerTargets
    let files = try sources(ofTargets: targets)

    // Positive controls. A scan that missed either of these would pass
    // vacuously — and the probe is the target this rule exists for, so its
    // absence must fail rather than shrug.
    #expect(files.contains { $0.path.hasSuffix("Sources/CoffeeBarProbe/main.swift") }, """
        the scan never reached the privileged CLI's entry point; it read \
        \(files.count) files across \(targets.count) targets
        """)
    #expect(files.contains { $0.lastPathComponent == "LidClosedSession.swift" }, """
        the scan never reached LidClosedSession.swift, which owns the arm and \
        watchdog paths
        """)

    let forbidden = [
        "SMAppService",
        "SMJobBless",
        "NSXPCListener",
        "NSXPCConnection",
        "setCodeSigningRequirement",
        "machServiceName",
    ]

    for file in files {
        let code = swiftCodeWithoutComments(try String(contentsOf: file, encoding: .utf8))
        for name in forbidden {
            #expect(!code.contains(name), """
                \(file.lastPathComponent) names \(name) in CODE. M5 ships as a \
                root CLI plus a launchd watchdog: the shipped bundle is ad-hoc \
                signed with no Team ID, so the peer pinning SECURITY.md \
                requires cannot be satisfied and an XPC service would accept \
                any local peer. A comment may explain the choice; making the \
                call is what this refuses.
                """)
        }
    }
}

// MARK: - Network egress

@Test func noLinkedTargetCanReachTheNetworkByAddress() throws {
    // `SECURITY.md` tells a reader coffee-bar "makes no network egress", and the
    // 2026-08-01 audit found NOTHING enforced it. Egress genuinely was zero —
    // `lsof -c coffee-bar -a -i` against the running process returned no IP
    // sockets — but a measurement taken once is not a guard, and one added
    // `URLSession` line would have shipped through a fully green suite.
    //
    // The rule is about the DESTINATION, not about Network.framework.
    // `IngestListener` legitimately uses `NWListener`; what no file may do is
    // name an IP address or a hostname. So the forbidden set is the APIs that
    // can only mean an off-machine peer. `AF_UNIX` and `sockaddr_un` are
    // deliberately absent from it: those ARE the filesystem socket.
    let linked = try linkedClosure(fromTarget: "CoffeeBarApp").sorted()
    let files = try sources(ofTargets: linked)

    // Positive control. Without it a mis-resolved root scans zero files and the
    // loop below passes vacuously — the false-absence trap this repository has
    // now hit three separate ways.
    #expect(files.contains { $0.lastPathComponent == "IngestListener.swift" }, """
        the egress scan never reached IngestListener.swift, the one file that \
        touches Network.framework; it read \(files.count) files across \
        \(linked.count) targets under \(packageRoot.path)
        """)

    let forbidden = ["URLSession", "URLRequest", "NSURL", "CFNetwork",
                     "getaddrinfo", "gethostbyname", "NWConnection(host:",
                     "NWEndpoint.hostPort", "AF_INET", "sockaddr_in",
                     "inet_pton", "inet_addr"]

    for file in files {
        let code = swiftCodeWithoutComments(try String(contentsOf: file, encoding: .utf8))
        for name in forbidden {
            #expect(!code.contains(name), """
                \(file.lastPathComponent) names \(name) in CODE. coffee-bar \
                posts nothing off this machine: ingest binds a unix socket and \
                there is no other network path. SECURITY.md states that to \
                users, so this is a promise, not a preference.
                """)
        }
    }
}

@Test func theOnlyListenerIsPinnedToAFilesystemEndpoint() throws {
    // The companion to the rule above, and the half that a name-ban cannot do.
    //
    // `NWListener` defaults to a PORT. `requiredLocalEndpoint = .unix(path:)` is
    // the single line that makes it answer on the filesystem instead. Delete
    // that line and the listener binds TCP — reachable from off the machine —
    // while every name in the forbidden list above stays absent and
    // `noLinkedTargetCanReachTheNetworkByAddress` stays green.
    let linked = try linkedClosure(fromTarget: "CoffeeBarApp").sorted()
    let files = try sources(ofTargets: linked)

    var sawParameters = false
    for file in files {
        let code = swiftCodeWithoutComments(try String(contentsOf: file, encoding: .utf8))
        guard code.contains("NWParameters") else { continue }
        sawParameters = true

        #expect(code.contains("requiredLocalEndpoint"), """
            \(file.lastPathComponent) builds NWParameters without setting \
            requiredLocalEndpoint. A listener with no local endpoint binds a \
            TCP port, which is reachable from off this machine.
            """)
        #expect(code.contains(".unix("), """
            \(file.lastPathComponent) builds NWParameters but never names a \
            .unix(path:) endpoint. The socket must live on the filesystem, \
            where directory permissions bound who can reach it.
            """)
    }

    #expect(sawParameters, """
        no scanned file built NWParameters, so this guard checked nothing. \
        Either the ingest listener stopped using Network.framework, or the \
        target scan no longer reaches it.
        """)
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

@Test func thePanelRendersTheLegalLineItComposes() throws {
    // The same tripwire as the check above, for the licence line. A critic
    // measured the hole before this existed: delete the `Link` from `body` and
    // the suite still passed with 580 tests, because `PanelLegalLine_test`
    // pins the two static members and nothing pins the line the user sees.
    //
    // That matters more here than for a status line. The DMG reaches people who
    // never saw the repository, so this is the ONLY route from the running
    // product to its terms and its no-warranty statement. Losing it silently
    // takes the legal surface off the product while every check stays green —
    // which is exactly what commit 5116326 did to the hook advisory.
    //
    // Same LIMIT as above, stated rather than hidden: this proves the panel
    // NAMES both members, not that it renders them, and not that a click opens
    // anything. A mention inside a comment would satisfy it. M1 design §5.4
    // forbids asserting on rendered AppKit text, so no check in this package
    // can watch the panel draw. A human look is still the only proof of that.
    let files = try appLayerSources()
    #expect(files.count == expectedSourceCount,
            "the boundary guard scanned \(files.count) files at \(packageRoot.path)")

    let panel = try #require(files.first { $0.lastPathComponent == "PanelView.swift" },
                             "the app layer no longer compiles a PanelView.swift")
    let source = try String(contentsOf: panel, encoding: .utf8)

    #expect(source.contains("PanelView.legalLine()"), """
        PanelView.swift composes legalLine() but renders it nowhere, so the \
        licence and the no-warranty statement reach the user nowhere. Render \
        it, or delete the member and the checks that assert its text.
        """)
    #expect(source.contains("PanelView.legalURL()"), """
        PanelView.swift composes legalURL() but renders it nowhere, so the \
        panel offers no route to the terms page. Render it, or delete the \
        member and the checks that assert it.
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

@Test func thePanelOffersTheDisplayHoldControl() throws {
    // Issue #12's acceptance, and the one thing no other check in this
    // repository can see: the user has to be able to FIND the setting.
    // `ServingModel` can store it, `PowerBroker` can weigh it and
    // `AssertionHolder` can raise it with every check green while the panel
    // offers no way to turn it on — which is a feature that does not exist.
    //
    // That is not hypothetical here. Commit 5116326 landed the hook health
    // check, the model published it, and `PanelView` read it nowhere; the
    // check above this one exists because of it.
    //
    // Same LIMIT as the two checks above, stated rather than hidden: this
    // proves the panel NAMES the binding, not that it draws a usable control.
    // M1 design §5.4 forbids asserting on rendered AppKit text, so no check in
    // this package can watch the picker appear. It is a tripwire against
    // deleting the control, not proof the control is right.
    let files = try appLayerSources()
    #expect(files.count == expectedSourceCount,
            "the boundary guard scanned \(files.count) files at \(packageRoot.path)")

    let panel = try #require(files.first { $0.lastPathComponent == "PanelView.swift" },
                             "the app layer no longer compiles a PanelView.swift")
    let source = try String(contentsOf: panel, encoding: .utf8)

    // The BINDING, not the property. `model.holdDisplayAwake` would be
    // satisfied by a line that merely displays the value, and a setting the
    // user can read and not change is not a setting.
    #expect(source.contains("$model.holdDisplayAwake"), """
        PanelView.swift binds no control to model.holdDisplayAwake, so the \
        display hold can be stored and honoured and the user can never turn it \
        on. Issue #12 asks for a control they can see.
        """)

    // The labels come from the model, for the reason the Serving picker's do:
    // a second list of literals in this view can drift from the sentence
    // `servingSummary` writes, and design §5.4 rules out catching that.
    #expect(source.contains("ServingModel.displayLabel"), """
        PanelView.swift names its own labels for the display control. They \
        belong on ServingModel beside the Serving labels, where a check can \
        read them.
        """)

    // And the line that says what is actually held has to be the model's, not
    // a sentence composed here. It reads "the display may still sleep", which
    // is FALSE once the user opts in, and no check could see it in this file.
    #expect(source.contains("model.servingSummary"), """
        PanelView.swift never reads model.servingSummary, so the line telling \
        the user what is held is composed in the view where no check reads it.
        """)
}
