// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import CoffeeBarTestSupport

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
    "Sources/CoffeeBarUI/AdvisoryRow.swift",
    "Sources/CoffeeBarUI/AppVersion.swift",
    "Sources/CoffeeBarUI/AttentionListView.swift",
    "Sources/CoffeeBarUI/BrandPalette.swift",
    "Sources/CoffeeBarUI/HookHealthReader.swift",
    "Sources/CoffeeBarUI/MenuBarGlyphs.swift",
    "Sources/CoffeeBarUI/PanelView.swift",
    "Sources/CoffeeBarUI/PreferencesView.swift",
    "Sources/CoffeeBarUI/PrivilegedHelperClient.swift",
    "Sources/CoffeeBarUI/PrivilegedHelperReader.swift",
    "Sources/CoffeeBarUI/ProcessGovernance.swift",
    "Sources/CoffeeBarUI/QuickStartView.swift",
    "Sources/CoffeeBarUI/ServingModel.swift",
    "Sources/CoffeeBarUI/UpdateCheck.swift",
    "Sources/CoffeeBarUI/UpdateChecker.swift",
]

/// The files entitled to speak XPC, and the exact names each one may say.
///
/// **Issue #71 NARROWED this rule and did not delete it**, which is the shape
/// `networkEntitlement` already set for issue #29. Every other file in the
/// linked closure and on the privileged path stays under the whole six-name
/// ban; these two are relieved of a disjoint slice each, and `SMJobBless` is
/// relieved for NOBODY — it is the deprecated path `SECURITY.md` rules out and
/// nothing here has ever needed it.
///
/// The split is deliberate and is the reason there are two entries rather than
/// one blanket pass. `PrivilegedHelperPeerGate.swift` is the ONLY file in this
/// package that may create, accept or configure a connection, so every peer pin
/// in the product is in one file a reviewer can read end to end. It may not
/// name `SMAppService`. `PrivilegedHelperClient.swift` registers the daemon and
/// may name nothing else — it holds no connection object, because the gate
/// hands it an opaque channel, so there is nowhere in it to resume one unpinned.
///
/// `theEntitledChannelFilePinsEveryPeerItOpens` bounds what the exemption
/// bought, exactly as `theOnlyEntitledFileReachesOnlyThePinnedHost` does for the
/// network one. An entitlement with no bounding check is a deletion with extra
/// steps.
private let privilegedHelperEntitlement: [String: [String]] = [
    "PrivilegedHelperPeerGate.swift": [
        "NSXPCListener",
        "NSXPCConnection",
        "setCodeSigningRequirement",
        "machServiceName",
    ],
    "PrivilegedHelperClient.swift": [
        "SMAppService",
    ],
]

/// The ONE file entitled to reach the network, and the ONE host it may reach.
///
/// Issue #29 is the single pre-authorised exception to this application's
/// no-egress promise, and `SECURITY.md` names it. The rule below did not get
/// deleted to make room for it: every other file in the linked closure stays
/// under the whole twelve-name ban, and this one is relieved of exactly ONE
/// name.
///
/// **`URLSession` and nothing else, which is a structural choice rather than a
/// minimal-diff one.** `URLRequest` stays banned HERE TOO, so the entitled file
/// has no object on which to set a header: `URLSession.data(from:)` takes a
/// bare `URL` and sends the system defaults. A custom `User-Agent` carrying an
/// install identifier — constraint 3 of the issue, and the one most likely to
/// rot silently — is then not something a reviewer has to notice, because there
/// is nowhere in the file to put it.
///
/// The HOST is pinned as well as the file, because a file that may reach the
/// network may reach ANY network. `theOnlyEntitledFileReachesOnlyThePinnedHost`
/// reads every URL literal out of it and refuses one that names anywhere else.
private let networkEntitlement = (file: "UpdateChecker.swift",
                                  allowed: "URLSession",
                                  host: "arangogutierrez.github.io")

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

// THE SOURCE READERS THIS FILE RESTS ON LIVE IN `CoffeeBarTestSupport`.
//
// `swiftCodeWithoutComments`, `swiftSourceReading` and `SwiftSourceReading`
// were declared here, which put them out of reach of `CoffeeBarCoreTests` and
// `CoffeeBarPowerTests` — two targets that needed the same discriminator and
// answered by re-implementing a cruder one or by doing without. They now live
// in `Tests/CoffeeBarTestSupport/SwiftSourceLexer.swift`, declared once, and
// `swiftCodeWithoutCommentsKeepsCodeAndDropsComments` below still pins them
// from here because this file is where every case in that table came from.
//
// `braceBlock(after:in:)` followed the same route on 2026-08-13 and now lives
// in `Tests/CoffeeBarTestSupport/SwiftBraceReader.swift`. `DocsClaims_test.swift`
// resolves WHICH surface renders a documented control by reading that surface's
// `body` block, which is the block this reader returns, and it is compiled into
// `CoffeeBarCoreTests`. `braceDepth(atFirst:in:)` below stays here: it has one
// caller and one target.

/// The argument list of every `call` in `code`, one string per call site.
///
/// Balanced-paren, so a nested call inside an argument does not end the span
/// early — `ancestorPIDs: inspector.ancestors(of: selfPID)` is one argument and
/// not the end of the list.
///
/// LIMIT, stated rather than hidden: `swiftCodeWithoutComments` KEEPS string
/// literals, so a `(` or `)` inside one would misbalance the count. No
/// construction this reads carries a literal today. It is a structural reader,
/// not the Swift grammar.
private func argumentSpans(of call: String, in code: String) -> [String] {
    let characters = Array(code)
    let needle = Array(call)
    var spans: [String] = []
    var index = 0

    while index + needle.count <= characters.count {
        guard Array(characters[index ..< index + needle.count]) == needle else {
            index += 1
            continue
        }
        var cursor = index + needle.count
        let start = cursor
        var depth = 1
        while cursor < characters.count && depth > 0 {
            if characters[cursor] == "(" { depth += 1 }
            if characters[cursor] == ")" { depth -= 1 }
            cursor += 1
        }
        // `cursor - 1` drops the closing paren the loop consumed. An unbalanced
        // span runs to the end of the file, which fails the checks below rather
        // than passing them.
        spans.append(String(characters[start ..< max(start, cursor - 1)]))
        index = cursor
    }
    return spans
}

/// How many braces are still open where `needle` first appears, or `nil` when it
/// does not appear at all.
///
/// The unit of comparison for "is this line as conditional as that one". Two
/// siblings in the same container sit at the same depth; wrapping one in an
/// `if`, a `switch` or a closure adds a brace and moves it. That is the whole
/// mechanism, and it is what tells a live render from a render that is merely
/// SPELLED — `if false { Text(x) }` keeps every `contains` check green.
///
/// `nil` rather than `0` for a missing needle, so a caller cannot compare two
/// absences and find them equal.
///
/// It counts every brace, string literals included, which is a real limit and
/// the caller's job to know about: `swiftCodeWithoutComments` strips comments
/// and keeps strings, so a `{` inside a literal ahead of the needle miscounts.
func braceDepth(atFirst needle: String, in code: String) -> Int? {
    guard let found = code.range(of: needle) else { return nil }
    var depth = 0
    for character in code[code.startIndex ..< found.lowerBound] {
        if character == "{" { depth += 1 }
        if character == "}" { depth -= 1 }
    }
    return depth
}

/// The four `DemotionPolicy` arguments that DEFAULT to empty.
///
/// Each names a deny rule that is OFF unless a caller fills it, and the
/// composition root is the only place that can know any of them:
///
///   - `agentPIDs` — the agent tools coffee-bar tracks;
///   - `frontmostPID` — the application the user is looking at;
///   - `ancestorPIDs` — coffee-bar's own parent chain;
///   - `extraProtectedNames` — coffee-bar's own executables.
///
/// Written WITH the colon, so the check reads an argument LABEL and not a
/// mention of the same word somewhere in an expression.
private let optionalProtections = [
    "agentPIDs:",
    "frontmostPID:",
    "ancestorPIDs:",
    "extraProtectedNames:",
]

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

@Test func thePreferencesWindowOffersTheQuietOthersControl() throws {
    // RETARGETED from `PanelView.swift` to `PreferencesView.swift` when the
    // control moved into the Preferences window. The invariant did not change
    // and is not about the panel: the user has to be able to FIND the switch.
    // The surface that offers it did change, so this follows it rather than
    // being deleted — a findability guard pointed at the wrong surface reports
    // a control missing while it works, and one deleted reports nothing at all.
    //
    // PRESENCE, the same tripwire shape as
    // `thePreferencesWindowOffersTheDisplayHoldControl` and for the same
    // reason: `ServingModel` can store the switch, `ProcessGovernance` can
    // weigh it and `ProcGovernor` can act on it with every check green while
    // no surface offers a way to turn it on.
    //
    // That is not hypothetical on this branch. `ProcGovernor` landed with 2853
    // lines of tested code and ZERO production callers, and issue #13 exists
    // partly to complain that `LaunchDaemonInstaller` shipped the same way.
    //
    // LIMIT, stated rather than hidden: this proves the window NAMES the
    // binding, not that it draws a usable control. Design §5.4 rules out
    // asserting on rendered AppKit text. Wrapping the toggle in `if false { … }`
    // was measured leaving this check green over a window with no switch in it;
    // `everyMovedControlIsRenderedAsUnconditionallyAsTheHeadingsAboveIt`
    // (`PreferencesView_test.swift`) holds the reachability half.
    //
    // COMMENT-STRIPPED, unlike the three panel tripwires above it. Those state
    // that a mention in a comment satisfies them; this one refuses that,
    // because commenting the control out is the likeliest way it disappears and
    // the surrounding prose would keep naming it. A presence guard that a
    // comment satisfies passes over the deletion it exists to catch. That
    // matters more since the move, not less: `PreferencesView.swift` explains
    // this control in prose several lines long.
    let files = try appLayerSources()
    #expect(files.count == expectedSourceCount,
            "the boundary guard scanned \(files.count) files at \(packageRoot.path)")

    let window = try #require(files.first { $0.lastPathComponent == "PreferencesView.swift" },
                              "the app layer no longer compiles a PreferencesView.swift")
    let source = swiftCodeWithoutComments(try String(contentsOf: window, encoding: .utf8))

    // The BINDING, not the property. `model.quietEverythingElse` would be
    // satisfied by a line that merely displays the value, and a switch the user
    // can read and not flip is not a switch.
    #expect(source.contains("$model.quietEverythingElse"), """
        PreferencesView.swift binds no control to model.quietEverythingElse, so \
        the governor can be wired, stored and honoured and the user can never \
        turn it on.
        """)

    // The label comes from the model, where a check can read it. The wording is
    // constrained — macOS cannot promote a process — so a literal composed in
    // this view is a claim nothing in this package could ever check.
    #expect(source.contains("ServingModel.quietOthersLabel"), """
        PreferencesView.swift names its own label for the quiet-others control. \
        It belongs on ServingModel beside the other control labels, where \
        theQuietOthersLabelNamesWhatIsQuietedAndClaimsNoSpeedUp reads it.
        """)
}

@Test func theAppComposesTheProcessGovernanceAndRecoversAtLaunchAndOnQuit() throws {
    // PRESENCE. `ServingModel.governance` is the ONE seam on that type whose
    // default is null rather than the real implementation, so this is what
    // stops the missing wire shipping silently — the exact objection the
    // listener's real-by-default comment raises.
    //
    // FOUR separate things are held, because each can be deleted on its own and
    // the other three still read as a working feature:
    //
    //   1. the app CONSTRUCTS a ProcessGovernance;
    //   2. it HANDS it to the model, rather than building one and dropping it;
    //   3. it RECOVERS AT LAUNCH, so a demotion an earlier run was killed
    //      before undoing does not outlive that run;
    //   4. it RECOVERS ON THE WAY OUT, so a clean quit does not leave a process
    //      on the E-cores until the next launch.
    //
    // 3 and 4 are the same METHOD NAME at two call sites, and until 2026-08-06
    // this guard held them with one `code.contains("restoreDemotedProcesses()")`
    // — which EITHER call site satisfies on its own. Measured: deleting the
    // App.init() call and keeping the terminate block left the whole suite at
    // rc=0 with 732 tests passing. The hazard that leaves is the one
    // docs/ACCEPTED-RISKS.md says the launch recovery closes: a run that ends by
    // SIGKILL posts no willTerminateNotification, so only a later LAUNCH can
    // undo what it left demoted.
    //
    // They are separated STRUCTURALLY rather than by counting to two. A count
    // reaches two when somebody writes the terminate call twice, and the block
    // split says which call site is missing.
    //
    // COMMENT-STRIPPED, because `main.swift` explains all three in prose. A raw
    // read would be satisfied by the explanation of the thing it deleted.
    //
    // Same LIMIT as the panel tripwires: this proves `main.swift` names each
    // call, not that the composition is correct. `ProcessGovernance_test.swift`
    // holds the behaviour; `main.swift` is top-level code that no test target
    // can import, which is why a source read is the only route here at all.
    let files = try appLayerSources()
    let main = try #require(files.first { $0.lastPathComponent == "main.swift" },
                            "the app layer no longer compiles a main.swift")
    let code = swiftCodeWithoutComments(try String(contentsOf: main, encoding: .utf8))

    #expect(code.contains("ProcessGovernance("), """
        main.swift builds no ProcessGovernance, so ProcGovernor has no \
        production caller and the app demotes nothing whatever the user sets.
        """)
    #expect(code.contains("governance:"), """
        main.swift builds a ProcessGovernance and never hands it to the model. \
        ServingModel defaults that seam to nil, so refresh() reconciles nothing.
        """)
    // The terminate block, cut out of the file so the two call sites cannot
    // stand in for one another.
    let split = try #require(
        braceBlock(after: "NSApplication.willTerminateNotification", in: code), """
            main.swift registers no block on NSApplication.willTerminateNotification, \
            so a clean quit leaves every demoted process on the E-cores until the \
            next launch.
            """)

    #expect(split.block.contains("restoreDemotedProcesses()"), """
        main.swift observes willTerminateNotification and does not restore inside \
        that block. The Quit button calls NSApplication.shared.terminate, so a user \
        who quits cleanly keeps their applications on the E-cores until they launch \
        coffee-bar again.
        """)

    #expect(split.rest.contains("restoreDemotedProcesses()"), """
        main.swift restores ONLY from the willTerminateNotification block, and \
        never at launch. A run that ends by SIGKILL posts no such notification, so \
        the processes it was holding down stay there and the journal it wrote is \
        the only record naming them. docs/ACCEPTED-RISKS.md says the launch \
        recovery is what closes that window.
        """)
}

@Test func theAppDeclaresTheSettingsSceneThePanelLinksTo() throws {
    // PRESENCE, the same tripwire shape as the panel affordances below, and the
    // one thing no other check in this repository can see: the Preferences
    // window has to be REACHABLE.
    //
    // Deleting the `Settings` block still COMPILES. `MenuBarExtra` alone
    // satisfies `some Scene`, and `main.swift` is top-level code no test target
    // can import, so nothing else in this package would notice. Measured: the
    // whole suite stays green while `SettingsLink` goes inert, `⌘,` does
    // nothing, and the window cannot be opened at all — a window nobody can
    // open is a window that does not exist, which is the shape issue #13
    // complains about and the shape `ProcGovernor` shipped in.
    //
    // Here rather than in the task that fills the window. Task 5 moves the
    // panel's controls INTO `PreferencesView`, and its own source scans read
    // `PreferencesView.swift` — so a scene deleted before then leaves those
    // scans green over controls sitting in a window nobody can reach. A
    // tripwire added later lands behind the work it protects.
    //
    // COMMENT-STRIPPED, for the reason `thePanelOffersTheQuietOthersControl`
    // gives: commenting the scene out is the likeliest way it disappears, and
    // the prose around it in `main.swift` explains the scene at length. A
    // presence guard that a comment satisfies passes over the deletion it
    // exists to catch.
    //
    // LIMIT, stated rather than hidden: this proves `main.swift` NAMES the
    // scene in code, never that macOS opens a window. Design §5.4 rules out
    // asserting on rendered AppKit anything, and the z-order question — whether
    // the window comes to the front for an `LSUIElement` app — is not visible
    // to any check in this package.
    let files = try appLayerSources()
    #expect(files.count == expectedSourceCount,
            "the boundary guard scanned \(files.count) files at \(packageRoot.path)")

    let main = try #require(files.first { $0.lastPathComponent == "main.swift" },
                            "the app layer no longer compiles a main.swift")
    let code = swiftCodeWithoutComments(try String(contentsOf: main, encoding: .utf8))

    #expect(code.contains("Settings {"), """
        main.swift declares no Settings scene, so SettingsLink in the panel is \
        inert and ⌘, does nothing. The Preferences window cannot be opened by \
        any route. This still compiles: MenuBarExtra alone satisfies some Scene.
        """)

    // The app's OWN model, not a second one. `PreferencesView(model:)` alone
    // would be satisfied by `Settings { PreferencesView(model: ServingModel()) }`,
    // and a second model owns a second listener and a second ticker: a setting
    // changed in the window would never reach the model enforcing the battery
    // floor, and the window would show state the panel does not have.
    #expect(code.contains("PreferencesView(model: model)"), """
        main.swift's Settings scene does not build PreferencesView from the app's \
        own model. A second ServingModel owns a second listener and ticker, so \
        settings changed in the window never reach the model that enforces them.
        """)
}

// MARK: - What the app layer must SAY when it builds a demotion policy

@Test func theAppLayerSuppliesEveryOptionalProtectionToDemotionPolicy() throws {
    // STRUCTURAL. Named bug this catches, and it is the single most
    // user-visible way issue #14 can go wrong: a `DemotionPolicy` built in the
    // app layer that leaves `frontmostPID` at its `nil` default. The rule in
    // `verdict(for:)` refuses `.frontmostApplication` ONLY when the value is
    // non-nil, so the omission makes the application the user is looking at
    // demotable the moment they name it — and every behavioural check in this
    // package still passes, because none of them can see an argument that was
    // never written.
    //
    // `agentPIDs`, `ancestorPIDs` and `extraProtectedNames` default to empty
    // for the same reason and carry the same hazard. FOUR of the nine deny
    // rules are off by default, and only the composition root can fill any of
    // them, so all four are held here rather than the one that prompted this.
    //
    // COMMENT-STRIPPED, and that is load bearing rather than tidy.
    // `ProcessGovernance.swift`'s doc comment names all four labels while
    // explaining why they matter, so a raw read would be satisfied by the
    // prose alone and would pass over a construction that supplied none of
    // them — the exact defect, certified sound by its own documentation.
    //
    // The HARNESS is deliberately out of scope. `CoffeeBarGovernorHarness`
    // passes `frontmostPID: nil` on purpose, to measure that the rule does
    // nothing when it is not told; it ships in no product and this scan does
    // not reach it.
    let files = try appLayerSources()
    #expect(files.count == expectedSourceCount,
            "the boundary guard scanned \(files.count) files at \(packageRoot.path)")

    var sites: [(file: String, arguments: String)] = []
    for file in files {
        let code = swiftCodeWithoutComments(try String(contentsOf: file, encoding: .utf8))
        for span in argumentSpans(of: "DemotionPolicy(", in: code) {
            sites.append((file.lastPathComponent, span))
        }
    }

    // Anti-vacuity, and this one is not a formality. The app layer built no
    // policy at all until issue #14 wired the governor, so a scan that found
    // nothing is indistinguishable from the state this check was written to
    // leave behind — and every assertion below it would pass over an empty
    // list for ever.
    #expect(sites.isEmpty == false, """
        no app-layer file constructs a DemotionPolicy. Either the governor lost \
        its production caller, or this scan is reading the wrong files.
        """)

    for site in sites {
        for label in optionalProtections {
            #expect(site.arguments.contains(label), """
                \(site.file) builds a DemotionPolicy without naming \(label). \
                That argument defaults to empty, which switches its deny rule \
                OFF — the frontmost application, a tracked agent, coffee-bar's \
                own parent shell or coffee-bar's own hook then becomes demotable \
                the moment a user names it. Only this layer can measure any of \
                them, so a default here is a protection removed and not a \
                feature missing.
                """)
        }
    }
}

@Test func theAppLayerNeverMatchesTheDemotableSetAgainstADisplayName() throws {
    // DENYLIST, and the rule is "must not DO", so comments are stripped.
    //
    // The demotable set is matched against the name the KERNEL reports —
    // `ProcSnapshot.name`, read through `proc_pidinfo`. AppKit's own names for
    // the same process are different strings: a user who writes
    // "Visual Studio Code" is naming what `localizedName` answers, while the
    // kernel calls that process "Code".
    //
    // Named bug this catches: an enumeration that carries the display name
    // forward and matches on it. `DemotionPolicy` matches EXACTLY, so the miss
    // is silent and total — nothing is demoted, nothing is logged, and the
    // user sees a setting they configured doing nothing whatever. A feature
    // that appears configured and does nothing is worse than one that fails
    // loudly, because there is no thread to pull.
    //
    // Comment stripping is proven LIVE here rather than argued:
    // `ProcessGovernance.swift`'s own doc comment names `localizedName` while
    // explaining this trap, so this check reads red on correct code the moment
    // it stops stripping.
    let files = try appLayerSources()
    #expect(files.count == expectedSourceCount,
            "the boundary guard scanned \(files.count) files at \(packageRoot.path)")

    // Anchor on the file the rule is about. A mis-resolved root scans nothing
    // and passes every `contains` below.
    #expect(files.contains { $0.lastPathComponent == "ProcessGovernance.swift" }, """
        the app-layer scan never reached ProcessGovernance.swift, the one file \
        that enumerates running applications; it read \(files.count) files
        """)

    // Every AppKit route to a name that is not the kernel's.
    // `NSRunningApplication` is the type itself: holding one is what makes the
    // other two reachable, so the provider hands back pids and stops there.
    let forbidden = ["localizedName", "bundleIdentifier", "NSRunningApplication"]

    for file in files {
        let code = swiftCodeWithoutComments(try String(contentsOf: file, encoding: .utf8))
        for name in forbidden {
            #expect(!code.contains(name), """
                \(file.lastPathComponent) names \(name) in CODE. The demotable \
                set is matched against the name the kernel reports, never a \
                display name: the two differ ("Code" against "Visual Studio \
                Code"), the match is exact, and a miss demotes nothing and says \
                nothing.
                """)
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
    // The limit that discriminator carries, stated at this site because the
    // verdict is this site's (issue #54): a bare regex literal is source it
    // cannot tokenise, and rather than answer for one it records an issue and
    // this scan fails. A file that refuses is a file this check has NOT
    // cleared — which is the safe direction, because the alternative is
    // reporting that nothing below the app raises a display assertion when
    // something does.
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
    // preference.
    //
    // SECURITY.md "It cannot pin a peer" requires an XPC helper to pin its peer with
    // `setCodeSigningRequirement` and to reject any peer that does not match
    // the app's Team ID and bundle ID.
    //
    // **That pin is now IMPLEMENTED, and issue #71 is the change that built
    // it.** It stopped being impossible at v0.2.0 — measured 2026-08-10 against
    // the shipped app, `codesign -R='anchor apple generic'` exits 0,
    // `TeamIdentifier=85FN4Z37V8`, authority `Developer ID Application`. An
    // earlier version of this comment recorded an ad-hoc signature, no Team ID
    // and rc=1, and was CORRECT when it was written: the only build shipping
    // then was the one the Homebrew formula makes from source (issue #86).
    //
    // So the ban is NARROWED rather than lifted, and this paragraph is the
    // whole of the change. `privilegedHelperEntitlement` names the two files
    // that may say these words and the disjoint slice each may say;
    // `theEntitledChannelFilePinsEveryPeerItOpens` bounds what that bought;
    // `Tests/CoffeeBarCoreTests/PrivilegedHelperIdentity_test.swift` decides
    // whether the requirement really pins a team AND a bundle, against the
    // system evaluator rather than against a reading of the string.
    //
    // Every OTHER file stays under the whole ban, and that is what this guard
    // is now for. Named bug it catches: an `NSXPCListener(machServiceName:)`
    // added to `LidClosedSession.swift` or to the probe's `main.swift` —
    // outside the one file whose peer pin anybody has reviewed — which would
    // compile, run, and accept any local peer.
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
    //
    // The limit that stripping carries, stated at this site because the verdict
    // is this site's (issue #54): a bare regex literal is source
    // `swiftCodeWithoutComments` cannot tokenise, and rather than answer for
    // one it records an issue and this scan fails. On a SECURITY rule the
    // refusal is the point: a file this check has not cleared must not read as
    // a file it cleared.
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

    // POSITIVE CONTROL on the entitlement itself. A typo in a key of
    // `privilegedHelperEntitlement` — or a file renamed without it — would
    // silently relieve NOBODY, which is safe, or would leave the loop below
    // reading a name no file has, which is vacuous. Both entitled files must be
    // in the scan for the exemptions to mean anything.
    for entitled in privilegedHelperEntitlement.keys.sorted() {
        #expect(files.contains { $0.lastPathComponent == entitled }, """
            the scan never reached \(entitled), which is entitled to name an \
            XPC symbol; an entitlement for a file no scan reads is an \
            exemption nobody is holding to anything
            """)
    }

    for file in files {
        let code = swiftCodeWithoutComments(try String(contentsOf: file, encoding: .utf8))
        let entitled = privilegedHelperEntitlement[file.lastPathComponent] ?? []
        for name in forbidden where !entitled.contains(name) {
            #expect(!code.contains(name), """
                \(file.lastPathComponent) names \(name) in CODE, and it is not \
                entitled to. Exactly two files may speak XPC — see \
                privilegedHelperEntitlement — so that every peer pin in this \
                product sits in one file a reviewer can read end to end. An \
                unpinned connection accepts any local peer and is worse than \
                the sudo command it replaces, because it looks safe. A comment \
                may name the API; making the call anywhere else is what this \
                refuses.
                """)
        }
    }
}

@Test func theEntitledChannelFilePinsEveryPeerItOpens() throws {
    // What `privilegedHelperEntitlement` BOUGHT, bounded — the same job
    // `theOnlyEntitledFileReachesOnlyThePinnedHost` does for the network
    // exemption. Relieving a file of the ban and then checking nothing about it
    // is a deletion with extra steps.
    //
    // SECURITY.md requires an XPC peer to be pinned by Team ID AND bundle ID.
    // Two named bugs, and both compile:
    //
    //  1. a connection is created and never pinned at all. The root daemon then
    //     accepts every local process, which is the outcome M5 refused to ship
    //     and the reason the CLI exists.
    //  2. a requirement is pasted INLINE — `"anchor apple generic"` on its own
    //     is the shape somebody reaches for when the real one will not compile.
    //     That string is satisfied by every signed Apple-anchored binary on the
    //     machine, and it reads, at a glance, exactly like a pin.
    //
    // So the requirement may only arrive from `PrivilegedHelperIdentity`, whose
    // two constants are the thing the Core checks actually evaluate. A literal
    // `anchor` in this file is refused however well-formed it looks.
    let channelFile = "PrivilegedHelperPeerGate.swift"
    let targets = try linkedClosure(fromTarget: "CoffeeBarApp").sorted() + probeLayerTargets
    let files = try sources(ofTargets: targets)

    let gate = try #require(files.first { $0.lastPathComponent == channelFile }, """
        \(channelFile) is not compiled into anything this guard scans; it read \
        \(files.count) files across \(targets.count) targets
        """)
    let code = swiftCodeWithoutComments(try String(contentsOf: gate, encoding: .utf8))

    #expect(code.contains("setCodeSigningRequirement"), """
        \(channelFile) opens an XPC channel and never pins its peer
        """)
    #expect(code.contains("PrivilegedHelperIdentity.appPeerRequirement"), """
        \(channelFile) must demand the APP's signature of an inbound caller
        """)
    #expect(code.contains("PrivilegedHelperIdentity.helperPeerRequirement"), """
        \(channelFile) must demand the HELPER's signature of the daemon it dials
        """)
    #expect(!code.contains("anchor"), """
        \(channelFile) spells a code-signing requirement out in a literal. The \
        requirement is PrivilegedHelperIdentity's, so that one place decides \
        what a peer must prove and one set of checks evaluates it.
        """)
}

@Test func theAppLayerNeverReachesForPrivilegeEscalation() throws {
    // Design §6.3 and SECURITY.md's "It never elevates its own privilege".
    //
    // M5 put a root path in this product for the first time, and the whole
    // safety of it rests on WHO takes that path: the user types
    // `sudo coffee-bar-probe arm` in their own shell. An app that could elevate
    // itself would turn an opt-in root action into one a menu bar click
    // performs, which is the design SECURITY.md rules out — and the policy now
    // promises it to readers, so this is a commitment rather than a preference.
    //
    // Named bug this catches: an "Arm lid-closed mode" button wired to
    // `AuthorizationExecuteWithPrivileges`, or to a `Process` running
    // `/usr/bin/sudo`. Both compile, both work, and every other check in this
    // file stays green — the app layer's existing denylist is about DISPLAY
    // assertions and knows nothing about privilege.
    //
    // The word `sudo` is deliberately ABSENT from the list. `ServingModel`
    // prints `sudo coffee-bar-probe arm` for the user to run, which is the
    // shipped design, and `swiftCodeWithoutComments` keeps string literals — so
    // banning the word would be red on exactly the correct code. What is banned
    // is EXECUTING with elevated privilege, not naming the command.
    //
    // The limit that discriminator carries, stated at this site because the
    // verdict is this site's (issue #54): a bare regex literal is source it
    // cannot tokenise, and rather than answer for one it records an issue and
    // this scan fails. A green run of THIS check is a claim that the app layer
    // cannot elevate itself, so it may only be made about source the lexer
    // actually read.
    let files = try appLayerSources()
    #expect(files.count == expectedSourceCount,
            "the boundary guard scanned \(files.count) files at \(packageRoot.path)")

    let forbidden = [
        "AuthorizationCreate",              // and AuthorizationCreateFromExternalForm
        "AuthorizationExecuteWithPrivileges",
        "AuthorizationRef",
        "SMAppService",                     // registers a daemon from the app bundle
        "SMJobBless",
        "STPrivilegedTask",
        "setuid",
        "seteuid",
        "launchctl",                        // loading a daemon is the daemon's install path
        "NSAppleScript",                    // "with administrator privileges"
    ]

    for file in files {
        let code = swiftCodeWithoutComments(try String(contentsOf: file, encoding: .utf8))
        let entitled = privilegedHelperEntitlement[file.lastPathComponent] ?? []
        for name in forbidden where !entitled.contains(name) {
            #expect(!code.contains(name), """
                \(file.lastPathComponent) names \(name) in CODE. coffee-bar never \
                elevates its own privilege: the root path is opt-in and the user \
                runs it themselves. The app prints the command and does not run \
                it. A comment may name the API; calling one is what this refuses.
                """)
        }
    }

    // What issue #71 changed, and the exact size of it.
    //
    // `SMAppService` is relieved for ONE file, and the other nine names are
    // relieved for nobody — `AuthorizationExecuteWithPrivileges`,
    // `NSAppleScript` and `/usr/bin/sudo` from a `Process` are the routes this
    // rule was written for and they stay shut. That is not a smaller version of
    // the same thing: `SMAppService.register()` hands the decision to the
    // OPERATING SYSTEM, which presents its own authorisation sheet with the
    // app's name on it and installs the job itself. The refused routes take the
    // user's password inside coffee-bar's own process, or run an interpreter as
    // root. coffee-bar still elevates nothing on its own initiative; what
    // changed is that the user's consent is now collected by macOS rather than
    // typed into a terminal.
    //
    // Named bug this half catches: a second file in the app layer registers a
    // daemon — a "repair" button in Preferences, say — bypassing the one place
    // that knows how to pin the channel afterwards.
    let registrars = try files.filter {
        swiftCodeWithoutComments(try String(contentsOf: $0, encoding: .utf8))
            .contains("SMAppService")
    }
    #expect(registrars.map(\.lastPathComponent) == ["PrivilegedHelperClient.swift"], """
        the set of app-layer files that can register a privileged daemon \
        changed: \(registrars.map(\.lastPathComponent).sorted())
        """)
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
    //
    // **ISSUE #29 NARROWED THIS RULE AND DID NOT DELETE IT.** The update check
    // is the single pre-authorised outbound request in this application, so one
    // of the twelve names above had to become reachable — and the answer was
    // NOT to drop `URLSession` from the list. It stays banned in every file but
    // one, that one file is named in `networkEntitlement`, and the other eleven
    // names still apply to it. Two further checks bound what the exemption
    // bought: `theOnlyEntitledFileReachesOnlyThePinnedHost` pins the
    // destination, and `theOneFileThatReachesTheNetworkSendsNoIdentifier` pins
    // what the request may carry. Deleting the ban outright was the shape this
    // change was most likely to take, and it would have traded a measured
    // promise for an unmeasured one.
    //
    // The limit `swiftCodeWithoutComments` carries, stated at this site because
    // the verdict is this site's (issue #54): a bare regex literal is source it
    // cannot tokenise, and rather than answer for one it records an issue and
    // this scan fails. This is the check the issue's argument turns on — a
    // GREEN here tells a reader of SECURITY.md that nothing linked into the
    // binary can reach the network, and that sentence may not rest on a file
    // the lexer mis-read.
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

    // Positive control on the EXEMPTION, and it is as load-bearing as the one
    // above. An exemption naming a file that does not exist is an exemption
    // nothing is measured against — and worse, it would sit here inviting
    // somebody to create a file by that name and inherit the pass.
    let entitled = files.filter { $0.lastPathComponent == networkEntitlement.file }
    #expect(entitled.count == 1, """
        \(entitled.count) file(s) in the linked closure are named \
        \(networkEntitlement.file); the network entitlement names exactly one
        """)

    for file in files {
        let code = swiftCodeWithoutComments(try String(contentsOf: file, encoding: .utf8))
        // The entitled file is relieved of ONE name. Every other name on the
        // list still applies to it, and every name applies to everything else.
        let refused = file.lastPathComponent == networkEntitlement.file
            ? forbidden.filter { $0 != networkEntitlement.allowed }
            : forbidden

        for name in refused {
            #expect(!code.contains(name), """
                \(file.lastPathComponent) names \(name) in CODE. coffee-bar \
                posts nothing off this machine but the update check, which is \
                \(networkEntitlement.file) and nothing else: ingest binds a \
                unix socket and there is no other network path. SECURITY.md \
                states that to users, so this is a promise, not a preference.
                """)
        }
    }

    // The entitled file DOES reach the network, so the exemption is live rather
    // than a dead pass sitting open for the next person who wants one. Without
    // this, deleting the update check would leave a file-shaped hole in the
    // egress rule that no check would notice.
    let entitledCode = swiftCodeWithoutComments(
        try String(contentsOf: try #require(entitled.first), encoding: .utf8))
    #expect(entitledCode.contains(networkEntitlement.allowed), """
        \(networkEntitlement.file) no longer names \(networkEntitlement.allowed), \
        so the one network exemption in this application is unused. Delete the \
        entitlement rather than leaving it open.
        """)
}

/// Every URL literal in `code`, read from `https://` to the end of the literal.
///
/// Deliberately keyed on the SCHEME rather than on a variable name, so a second
/// address assigned to something innocuous is read the same way as the pinned
/// one. `swiftCodeWithoutComments` keeps string literals, which is what makes
/// this readable at all, and drops comments — so the sentence in a doc comment
/// that names a host is not mistaken for an address the code can reach.
private func httpsAddresses(in code: String) -> [String] {
    code.components(separatedBy: "https://").dropFirst().map { rest in
        String(rest.prefix { $0 != "\"" && !$0.isWhitespace })
    }
}

@Test func theOnlyEntitledFileReachesOnlyThePinnedHost() throws {
    // The second half of the narrowed rule above, and the half a name-ban
    // cannot do. `URLSession` is permitted in one file; that permission says
    // nothing about WHERE it points. Repointing the constant at another host is
    // a one-word edit that leaves every name on the forbidden list absent and
    // `noLinkedTargetCanReachTheNetworkByAddress` green.
    //
    // Read over the whole linked closure and not over the entitled file alone,
    // so an address parked in a neighbouring file — a constant the entitled one
    // then imports — is judged by the same rule.
    let linked = try linkedClosure(fromTarget: "CoffeeBarApp").sorted()
    let files = try sources(ofTargets: linked)

    var seen = 0
    for file in files {
        let code = swiftCodeWithoutComments(try String(contentsOf: file, encoding: .utf8))
        for address in httpsAddresses(in: code) {
            seen += 1
            #expect(address.hasPrefix(networkEntitlement.host + "/"), """
                \(file.lastPathComponent) names the address https://\(address). \
                One host is named anywhere in this application's own code, \
                \(networkEntitlement.host) — the update check fetches from it \
                and the panel's legal line hands a page on it to the browser. \
                SECURITY.md tells users the update check is the only outbound \
                request, so a second address is a new commitment and is written \
                there first.
                """)
        }
    }

    // ANTI-VACUITY. With no address anywhere the loop above never runs and this
    // guard reports success on an application that might reach anything.
    #expect(seen >= 1, """
        no scanned file names an https address at all, so the pinned-host rule \
        checked nothing. Either the update check is gone — in which case the \
        entitlement above should go with it — or the target scan no longer \
        reaches it.
        """)
}

@Test func theOneFileThatReachesTheNetworkSendsNoIdentifier() throws {
    // CONSTRAINT 3 of issue #29: a version check that can count installs is
    // analytics wearing a check's clothes, and handoff §12 bans analytics
    // separately from egress. This is the constraint most likely to rot
    // silently, because every name below reads as harmless on its own and none
    // of them changes what the feature appears to do.
    //
    // WHY HERE and not only in `UpdateChecker_test.swift`: that file asserts the
    // session object carries no additional header, which is the strongest form
    // of the check and the one a reviewer should trust. It cannot see an
    // identifier that reaches the wire another way — a path component built from
    // a UUID, a hostname folded into the address. This scan reads the source for
    // the vocabulary of identity, so the two answer different questions.
    //
    // The limit `swiftCodeWithoutComments` carries, stated at this site for the
    // reason the checks above state it: a bare regex literal is source it cannot
    // tokenise, and rather than answer for one it records an issue and this scan
    // fails.
    let linked = try linkedClosure(fromTarget: "CoffeeBarApp").sorted()
    let files = try sources(ofTargets: linked)
    let entitled = try #require(files.first { $0.lastPathComponent == networkEntitlement.file },
                                "the egress scan never reached \(networkEntitlement.file)")
    let code = swiftCodeWithoutComments(try String(contentsOf: entitled, encoding: .utf8))

    let identifying = [
        "UUID",                     // and NSUUID, and uuidString
        "identifierForVendor",
        "IOPlatformUUID",
        "IOPlatformSerialNumber",
        "hostName",                 // ProcessInfo.processInfo.hostName
        "NSUserName",
        "NSFullUserName",
        "User-Agent",
        "httpAdditionalHeaders",
        "setValue(",                // the URLRequest header setters, both of
        "addValue(",                // which need a URLRequest this file may not name
        "URLQueryItem",
        "queryItems",
        "httpBody",
        "POST",
        "globallyUniqueString",
        "machineID",
        "installID",
    ]

    // THE PRESSURE THIS LIST WILL COME UNDER, recorded at the site so the next
    // reader meets the argument before the edit.
    //
    // Measured, not assumed: pointing the shipped session configuration at a
    // loopback listener shows macOS adds `Accept-Language` — the user's own
    // language — to every request any application makes. Somebody will
    // reasonably want to strip it, and the only way to strip a header is to set
    // one, which needs `URLRequest`, which the ban above keeps refused EVEN IN
    // THE ENTITLED FILE.
    //
    // That refusal is the whole structure. With no request object in that file
    // there is nowhere to put a header, so "no custom User-Agent, no install
    // ID" holds by construction rather than by review. Relaxing this to allow
    // one well-meant header converts a structural guarantee into a judgement
    // call about every header that follows it, and `Accept-Language` identifies
    // no install — it is not what this guard is for. `SECURITY.md` carries the
    // argument and discloses the header instead. The answer is no.

    for name in identifying {
        #expect(!code.contains(name), """
            \(networkEntitlement.file) names \(name) in CODE. The update check \
            sends no identifier of any kind: no install ID, no custom \
            User-Agent, no query parameter, no body. A check that can count \
            installs is telemetry, which handoff §12 rules out on its own terms \
            and SECURITY.md promises against.
            """)
    }

    // The positive half. A file that named none of the above because it had
    // stopped making a request would pass every expectation so far.
    #expect(code.contains(networkEntitlement.host), """
        \(networkEntitlement.file) no longer names \(networkEntitlement.host), so \
        this guard read a file that makes no request and proved nothing about \
        what a request carries.
        """)
}

@Test func theOnlyListenerIsPinnedToAFilesystemEndpoint() throws {
    // The companion to the rule above, and the half that a name-ban cannot do.
    //
    // `NWListener` defaults to a PORT. `requiredLocalEndpoint = .unix(path:)` is
    // the single line that makes it answer on the filesystem instead. Delete
    // that line and the listener binds TCP — reachable from off the machine —
    // while every name in the forbidden list above stays absent and
    // `noLinkedTargetCanReachTheNetworkByAddress` stays green.
    //
    // The limit `swiftCodeWithoutComments` carries, stated at this site because
    // the verdict is this site's (issue #54): a bare regex literal is source it
    // cannot tokenise, and rather than answer for one it records an issue and
    // this scan fails. This guard is `contains`-POSITIVE, which is the shape
    // the hole defeats most cheaply — the required line appearing in a comment
    // is enough — and
    // `aScannedFileCarryingARegexLiteralRefusesRatherThanReportingGreen`
    // constructs exactly that file against exactly this check.
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
    //
    // `suspect` is the fourth column and the negative control for the refusal
    // issue #54 added: every case carrying `nil` there is ordinary Swift the
    // walk can tokenise, INCLUDING the two division cases, and each one must
    // read clean. A detector that refused any of them would take every scan in
    // this file down on correct code.
    let cases: [(name: String, source: String, expected: String, suspect: String?)] = [
        ("a line comment goes, the code around it stays",
         "let a = 1 // PreventUserIdleDisplaySleep\nlet b = 2",
         "let a = 1 \nlet b = 2",
         nil),

        ("a doc comment naming the constant goes",
         "/// does **not** hold `PreventUserIdleDisplaySleep`.\nlet a = 1",
         "\nlet a = 1",
         nil),

        ("a block comment goes and keeps its line breaks",
         "let a = 1\n/* caffeinate -d\n   beginActivity */\nlet b = 2",
         "let a = 1\n\n\nlet b = 2",
         nil),

        ("nested block comments close at the outer end, not the inner one",
         "let a = 1 /* outer /* inner */ still comment */ let b = 2",
         "let a = 1  let b = 2",
         nil),

        // The escape route that stripping literals would open.
        ("a string literal survives, contents and all",
         "IOPMAssertionCreateWithName(\"PreventUserIdleDisplaySleep\" as CFString)",
         "IOPMAssertionCreateWithName(\"PreventUserIdleDisplaySleep\" as CFString)",
         nil),

        ("`//` inside a string literal opens no comment",
         "let url = \"https://example.com/beginActivity\"\nlet a = 1",
         "let url = \"https://example.com/beginActivity\"\nlet a = 1",
         nil),

        ("`/*` inside a string literal opens no comment",
         "let glob = \"/*\"\nlet a = 1",
         "let glob = \"/*\"\nlet a = 1",
         nil),

        ("an escaped quote does not end the string early",
         "let a = \"he said \\\"caffeinate\\\" loudly\" // gone\nlet b = 2",
         "let a = \"he said \\\"caffeinate\\\" loudly\" \nlet b = 2",
         nil),

        ("a raw string keeps its contents and its delimiters",
         "let a = #\"a \\#(x) caffeinate \"quoted\" here\"# // gone",
         "let a = #\"a \\#(x) caffeinate \"quoted\" here\"# ",
         nil),

        ("a multi-line string keeps everything between the fences",
         "let a = \"\"\"\n// not a comment\ncaffeinate\n\"\"\"\nlet b = 2",
         "let a = \"\"\"\n// not a comment\ncaffeinate\n\"\"\"\nlet b = 2",
         nil),

        ("a `#` that opens no string is kept",
         "let p = #filePath // gone",
         "let p = #filePath ",
         nil),

        ("division is not a comment",
         "let half = total / 2 / 1",
         "let half = total / 2 / 1",
         nil),

        ("division with no spaces around it is still not a regex literal",
         "let half = total/2 // gone",
         "let half = total/2 ",
         nil),

        // Issue #54, pinned as a fact rather than as prose. Read the third
        // column: `// caffeinate` comes back as CODE. The `"` inside the regex
        // literal opens a string as far as this walk is concerned, and the walk
        // then copies the rest of the file verbatim — so a scan asking whether
        // a name appears in code is answered by a comment. That is why the
        // fourth column is not `nil`, and why `swiftCodeWithoutComments`
        // refuses on this source instead of returning the second column.
        ("a bare regex literal is source this lexer cannot read",
         "let quote = /\"/\n// caffeinate\nlet a = 1",
         "let quote = /\"/\n// caffeinate\nlet a = 1",
         "let quote = /\"/"),

        // The extended form may run over several lines, so the closing `/#`
        // need not be on the line that opens it. `#/` is enough on its own:
        // nothing else in Swift spells it.
        ("an extended regex literal is source this lexer cannot read either",
         "let quote = #/\n\"\n/#\nlet a = 1",
         "let quote = #/\n\"\n/#\nlet a = 1",
         "let quote = #/"),
    ]

    for testCase in cases {
        let reading = swiftSourceReading(testCase.source)
        #expect(reading.code == testCase.expected,
                "\(testCase.name): got \(reading.code.debugDescription)")
        #expect(reading.regexLiteralSuspect == testCase.suspect,
                "\(testCase.name): suspect \(String(describing: reading.regexLiteralSuspect))")

        // The entry point every guard calls returns the reading's code for
        // source the walk can tokenise, and only for that source. What it does
        // with a suspect is
        // `aScannedFileCarryingARegexLiteralRefusesRatherThanReportingGreen`.
        if testCase.suspect == nil {
            #expect(swiftCodeWithoutComments(testCase.source) == testCase.expected,
                    "\(testCase.name): entry point got \(swiftCodeWithoutComments(testCase.source).debugDescription)")
        }
    }
}

@Test func aScannedFileCarryingARegexLiteralRefusesRatherThanReportingGreen() throws {
    // Issue #54, executed rather than described. `Sources/` carries no regex
    // literal today, so this CONSTRUCTS the file the lexer cannot read and puts
    // it through the pipeline every scan in this file runs: read, strip, ask
    // what the remaining code says.
    //
    // Named bug this catches, and it is why the refusal exists rather than a
    // paragraph of prose. What the constructed file DOES is build NWParameters
    // and set no local endpoint on them — a listener that binds a TCP port,
    // reachable from off this machine, which is the one thing
    // `theOnlyListenerIsPinnedToAFilesystemEndpoint` exists to refuse. The two
    // lines that guard requires appear in a COMMENT and nowhere else, and the
    // walk hands them back as code. Without the refusal that guard reports
    // GREEN on a file that opens the machine to the network.
    let files = FileManager.default
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "coffee-bar-regex-literal-\(UUID().uuidString)")
    try files.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: scratch) }

    let constructed = scratch.appending(path: "IngestListener.swift")
    try #"""
        let quote = /"/
        // requiredLocalEndpoint = .unix(path: socketPath)
        let parameters = NWParameters()
        """#.write(to: constructed, atomically: true, encoding: .utf8)
    let source = try String(contentsOf: constructed, encoding: .utf8)

    // The mis-read itself. `swiftSourceReading` is the walk WITHOUT the
    // refusal, so these state what the lexer returns rather than what the guard
    // does about it — and they are the verdict
    // `theOnlyListenerIsPinnedToAFilesystemEndpoint` would reach on this file:
    // it sees NWParameters, so it checks, and both `contains` it makes are
    // satisfied by the comment. GREEN, on source that pins nothing to the
    // filesystem.
    //
    // If one of these ever fails, the lexer learned to read regex literals
    // (issue #54's option 3) and the premise of this test is gone: rewrite it
    // against the new behaviour rather than deleting it.
    let reading = swiftSourceReading(source)
    #expect(reading.code.contains("NWParameters"),
            "the constructed file no longer reaches the endpoint guard at all")
    #expect(reading.code.contains("requiredLocalEndpoint"), """
        the walk no longer hands the comment back as code, so the hole this \
        test is about has closed: \(reading.code.debugDescription)
        """)
    #expect(reading.code.contains(".unix("), """
        the walk no longer hands the comment back as code, so the hole this \
        test is about has closed: \(reading.code.debugDescription)
        """)

    // What the entry point every guard calls does with the same source: it
    // refuses, and the refusal is an ISSUE rather than a return value because
    // no string it could return would fail a `!code.contains(name)` denylist.
    // `withKnownIssue` fails when NO issue is recorded inside it, so deleting
    // the refusal turns this test red.
    withKnownIssue("the scan refuses a verdict on source carrying a regex literal") {
        _ = swiftCodeWithoutComments(source)
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
    // property in CODE, not that it renders what it reads. It is a tripwire
    // against deleting the render, not proof the render is correct.
    let files = try appLayerSources()
    #expect(files.count == expectedSourceCount,
            "the boundary guard scanned \(files.count) files at \(packageRoot.path)")

    let panel = try #require(files.first { $0.lastPathComponent == "PanelView.swift" },
                             "the app layer no longer compiles a PanelView.swift")

    // CODE, never the raw file, for the reason `2247ae4` records on the
    // lid-closed check below. Proven here by the same mutation: replacing a
    // render with a comment that NAMES the property left the raw-file version
    // of this check green, so the tripwire could be walked past by anyone who
    // documented what they deleted.
    let code = swiftCodeWithoutComments(try String(contentsOf: panel, encoding: .utf8))

    #expect(code.contains("model.hookAdvisory"), """
        PanelView.swift never reads model.hookAdvisory in code, so the hook \
        health check reaches the user nowhere. Render it, or delete the \
        property and the checks that assert its text. A comment naming the \
        property does not satisfy this.
        """)
}

@Test func theStaleHelperAdvisoryReachesThePanelAndThePreferencesWindow() throws {
    // Issue #81, and the same named bug commit 5116326 shipped for the hook
    // advisory: `d53c52a` computed the verdict, `e332687` wrote the sentence,
    // every check was green, and NO view read either — so v0.2.1 detected a
    // stale root binary and told nobody. A published value no view reads is a
    // feature that does not exist.
    //
    // BOTH surfaces, and neither is decoration. The panel is where the user
    // notices, and this is live state about the machine in front of them rather
    // than the documentation issue #56 removed from that column. The Preferences
    // window is where they can act on it: it is the surface that already carries
    // the lid-closed command, and the advisory's own remedy is a command of the
    // same kind.
    //
    // This reads the source because the behavioural route is closed: M1 design
    // §5.4 forbids asserting on rendered AppKit text, so no check in this
    // package can watch either surface draw a line.
    //
    // LIMIT, stated rather than hidden: this proves each view NAMES the property
    // in CODE and hands it a path derived from the running bundle. It cannot
    // prove either renders what it reads, and — unlike the lid-closed summary
    // below — it cannot compare brace depth against an unconditional neighbour,
    // because this line is conditional BY DESIGN. A machine with a current
    // helper must see nothing.
    let files = try appLayerSources()
    #expect(files.count == expectedSourceCount,
            "the boundary guard scanned \(files.count) files at \(packageRoot.path)")

    let panel = try #require(files.first { $0.lastPathComponent == "PanelView.swift" },
                             "the app layer no longer compiles a PanelView.swift")
    let window = try #require(files.first { $0.lastPathComponent == "PreferencesView.swift" },
                              "the app layer no longer compiles a PreferencesView.swift")

    for surface in [panel, window] {
        // CODE, never the raw file, for the reason `2247ae4` records on the
        // lid-closed check below: a comment naming a property that had been
        // deleted left the raw-file version of that guard green.
        //
        // WHITESPACE REMOVED, not merely collapsed, for the reason
        // `thePreferencesWindowAsksTheRunningBundleWhereTheProbeIs` records:
        // the call is long enough that both views wrap it over three lines, so
        // a needle containing `(probeAt:` never matches the raw text and the
        // guard would be red against a correct view.
        let code = swiftCodeWithoutComments(try String(contentsOf: surface, encoding: .utf8))
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)

        #expect(code.contains("model.staleHelperAdvisory(probeAt:"), """
            \(surface.lastPathComponent) never reads model.staleHelperAdvisory \
            in code, so a stale root helper reaches the user nowhere on this \
            surface. Render it, or delete the property and the checks that \
            assert its text. A comment naming the property does not satisfy this.
            """)

        // The PATH, not only the property. Named bug: calling the advisory with
        // `documentedProbePath`, which is right for a disk-image install and
        // names a file a Homebrew user, a `swift build` tree and a copy on the
        // Desktop do not have — so the command the advisory prints copies
        // nothing. `Bundle.main` is read in the VIEW and the model stays pure,
        // which is the split `versionLine(from: Bundle.main.infoDictionary)`
        // already uses in both of these files.
        #expect(code.contains("ServingModel.probePath(besideExecutable:Bundle.main.executableURL)"), """
            \(surface.lastPathComponent) does not hand the advisory a probe path \
            derived from the running bundle, so whatever command it prints is \
            not the derivation this package holds under test.
            """)
    }
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
    // NAMES both members IN CODE, not that it renders them, and not that a
    // click opens anything. M1 design §5.4 forbids asserting on rendered AppKit
    // text, so no check in this package can watch the panel draw. A human look
    // is still the only proof of that.
    let files = try appLayerSources()
    #expect(files.count == expectedSourceCount,
            "the boundary guard scanned \(files.count) files at \(packageRoot.path)")

    let panel = try #require(files.first { $0.lastPathComponent == "PanelView.swift" },
                             "the app layer no longer compiles a PanelView.swift")

    // CODE, never the raw file. The raw version of this check said of itself
    // that "a mention inside a comment would satisfy it", and that was measured
    // rather than feared: replacing the whole `Link(...)` render with a comment
    // naming both members left this check GREEN with zero `Link(` in the file.
    // The legal surface was off the product and the guard reported it present —
    // the exact hole the three checks above carried, and the one `2247ae4`
    // first fixed. It matters most here, because this line is the only route
    // from a DMG install to the terms and the no-warranty statement.
    let code = swiftCodeWithoutComments(try String(contentsOf: panel, encoding: .utf8))

    #expect(code.contains("PanelView.legalLine()"), """
        PanelView.swift composes legalLine() but renders it nowhere in code, so \
        the licence and the no-warranty statement reach the user nowhere. \
        Render it, or delete the member and the checks that assert its text. A \
        comment naming the member does not satisfy this.
        """)
    #expect(code.contains("PanelView.legalURL()"), """
        PanelView.swift composes legalURL() but renders it nowhere in code, so \
        the panel offers no route to the terms page. Render it, or delete the \
        member and the checks that assert it. A comment naming the member does \
        not satisfy this.
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
    // NAMES each property in CODE, not that it renders it correctly. It is a
    // tripwire against deleting the render.
    let files = try appLayerSources()
    #expect(files.count == expectedSourceCount,
            "the boundary guard scanned \(files.count) files at \(packageRoot.path)")

    let panel = try #require(files.first { $0.lastPathComponent == "PanelView.swift" },
                             "the app layer no longer compiles a PanelView.swift")

    // CODE, never the raw file. Same reason as the check above: these three
    // properties are each named in the prose around their own render, so a raw
    // read cannot tell a live render from a note about one.
    let code = swiftCodeWithoutComments(try String(contentsOf: panel, encoding: .utf8))

    for property in ["model.attention", "model.workingSummary", "model.ingestAdvisory"] {
        #expect(code.contains(property), """
            PanelView.swift never reads \(property) in code, so what the model \
            computes for it reaches the user nowhere. Render it, or delete the \
            property and the checks that assert its value. A comment naming the \
            property does not satisfy this.
            """)
    }
}

@Test func theWaitingListDrawsInsideABoundedScrollContainer() throws {
    // BEGIN attention-list scroll tripwire — keep beside
    // `thePanelReadsEverySessionValueTheModelPublishes` above, which guards the
    // same list from the other side: that one says the panel READS
    // `model.attention`, this one says the list it draws cannot grow without
    // limit.
    //
    // The defect, observed: with roughly twelve sessions waiting, the list ran
    // past the bottom of the screen and took the battery reading, the version
    // line and the legal link with it. Nothing bounded the list and nothing
    // scrolled, so the panel had no reachable bottom at all.
    //
    // Same LIMIT as the checks above, stated rather than hidden: this proves the
    // view NAMES a scroll container and applies the bound in CODE. It does not
    // prove the list draws correctly — design §5.4 rules that out. The VALUE of
    // the bound is asserted in `AttentionListLayout_test.swift`, where a check
    // can read it; this is the tripwire against deleting the container that
    // makes the value mean anything.
    let files = try appLayerSources()
    #expect(files.count == expectedSourceCount,
            "the boundary guard scanned \(files.count) files at \(packageRoot.path)")

    let list = try #require(files.first { $0.lastPathComponent == "AttentionListView.swift" },
                            "the app layer no longer compiles an AttentionListView.swift")

    // CODE, never the raw file, for the reason
    // `thePanelTellsTheUserHowToArmLidClosedMode` below documents from a
    // mutation: the doc comment above the scroll container explains why the
    // container is there and names it, so a raw read cannot tell a live
    // container from a note about one. Deleting the `ScrollView` and leaving the
    // prose would keep a raw-file check green.
    let code = swiftCodeWithoutComments(try String(contentsOf: list, encoding: .utf8))

    #expect(code.contains("ScrollView"), """
        AttentionListView.swift draws the waiting list in no scroll container in \
        code, so a long list has nowhere to go and pushes the rest of the panel \
        off the screen. A comment naming ScrollView does not satisfy this.
        """)

    // The bound, applied — not merely declared. The container alone is not the
    // fix: an unbounded ScrollView grows exactly as the VStack did.
    #expect(code.contains("AttentionListView.maximumListHeight"), """
        AttentionListView.swift never applies AttentionListView.maximumListHeight \
        in code, so the scroll container has no bound and the list grows as far \
        as the sessions take it. A comment naming the bound does not satisfy this.
        """)

    // The container has to ENCLOSE the rows, and `contains` cannot say that: a
    // ScrollView wrapped around the empty-state line alone — or added anywhere
    // else in the file — satisfies the check above while the list it was added
    // for still grows without limit. `braceBlock(after:in:)` reads the block and
    // the rows are asserted inside it.
    let container = try #require(braceBlock(after: "ScrollView", in: code)?.block, """
        AttentionListView.swift names a ScrollView that opens no balanced block, \
        so this guard cannot tell what the container holds.
        """)
    #expect(container.contains("ForEach(sessions)"), """
        the scroll container in AttentionListView.swift does not enclose \
        ForEach(sessions), so the rows still grow outside it and the bound holds \
        nothing.
        """)

    // And the container has to be UNSQUEEZABLE. This one was caught in the
    // running app, not here: a ScrollView is the only FLEXIBLE child of the
    // panel's VStack, so when the panel is taller than the window it can use,
    // the stack takes the shortfall out of the one view that can shrink. This
    // list collapsed to zero height and "Nothing waiting on you." disappeared
    // from the panel, with every check in this file green.
    //
    // `fixedSize` vertically pins the container at the size the bound already
    // decided — min(content, maximumListHeight) — so the stack can no longer
    // take height from it. Without it the bound has a floor of ZERO, which is a
    // second way for the list to reach the user nowhere.
    #expect(code.contains(".fixedSize(horizontal: false, vertical: true)"), """
        AttentionListView.swift does not pin its scroll container with \
        fixedSize, so the panel's VStack can squeeze the list to nothing — the \
        rows and the empty-state line then vanish from a panel that is otherwise \
        healthy.
        """)
    // END attention-list scroll tripwire.
}

@Test func theLidClosedSummaryIsInThePreferencesWindowAndNotInThePanel() throws {
    // TWO SURFACES, and the negative half is the point of issue #56.
    //
    // Lid-closed mode is the one capability with NO control anywhere, and that
    // is deliberate: it needs root, and coffee-bar never elevates its own
    // privilege. What is left is telling the user the command — so if NO view
    // reads the property, the feature reaches the user nowhere at all and the
    // app simply has no lid-closed mode as far as anyone can tell. That is what
    // the positive half below refuses.
    //
    // The panel is the wrong surface for it, and the reason is not taste. The
    // panel is 260pt wide and reports what coffee-bar is doing NOW; this
    // sentence is neither live state nor a control, and it rendered as roughly
    // 80 words of documentation inside that column. It belongs beside the other
    // power settings, where somebody configuring behaviour is already looking,
    // and the long explanation belongs on `site/docs.html`.
    //
    // The property carries the command AND the statement that this app cannot
    // read whether the mode is armed. Both halves matter and they are one
    // property for that reason; see
    // `theLidClosedSummaryCarriesBothTheCommandAndWhatTheAppCannotSee`.
    //
    // Same LIMIT as the checks above, stated rather than hidden: this proves
    // which file NAMES the property, not what either surface renders. M1
    // design §5.4 forbids asserting on rendered AppKit text.
    let files = try appLayerSources()
    #expect(files.count == expectedSourceCount,
            "the boundary guard scanned \(files.count) files at \(packageRoot.path)")

    let window = try #require(files.first { $0.lastPathComponent == "PreferencesView.swift" },
                              "the app layer no longer compiles a PreferencesView.swift")
    let panel = try #require(files.first { $0.lastPathComponent == "PanelView.swift" },
                             "the app layer no longer compiles a PanelView.swift")

    // CODE, never the raw file, and this file learned that from a mutation:
    // deleting the whole `Text(ServingModel.lidClosedAdvisory)` render and its
    // modifier chain left the old check GREEN, because the doc comment sitting
    // above that render also named the property. The guard was reading its own
    // explanation and reporting the feature present.
    //
    // The negative half needs it even more than the positive one. `PanelView`
    // still CARRIES a comment saying where this moved and why — deliberately,
    // so the next reader does not put it back — and a raw-file check would read
    // that note and report the prose still rendered.
    let windowCode = swiftCodeWithoutComments(try String(contentsOf: window, encoding: .utf8))
    let panelCode = swiftCodeWithoutComments(try String(contentsOf: panel, encoding: .utf8))

    // `ServingModel.lidClosedSummary` rather than `model.lidClosedSummary`: the
    // sentence depends on no instance state — only on `ProbeVerb` — so it is a
    // static, exactly like `ServingModel.displayLabel`. Requiring the instance
    // spelling would have forced a property that ignores its own instance,
    // which reads as though the window were reporting live state. It is not,
    // and that is the whole point of this surface.
    #expect(windowCode.contains("ServingModel.lidClosedSummary"), """
        PreferencesView.swift never reads ServingModel.lidClosedSummary in code, \
        so the only route a user has to lid-closed mode — the command to run — \
        reaches them nowhere. Render it, or delete the property and the checks \
        on its text. A comment naming the property does not satisfy this.
        """)

    // WIRED, not merely SPELLED. `contains` proves the property is named in
    // code; it cannot tell a live render from a dead one, and the difference is
    // invisible to every other check here because design §5.4 rules out reading
    // the drawn window.
    //
    // Named bug this catches, and it is not hypothetical — the same shape
    // defeated a sibling guard in this repository:
    //
    //     if false {
    //         Text(ServingModel.lidClosedSummary)
    //     }
    //
    // The property is spelled, the assertion above is green, and the user meets
    // nothing. Any disabling condition does it, not just `false`.
    //
    // The test is BRACE DEPTH against an unconditional neighbour. Both renders
    // are direct children of the same `VStack`, so they sit at the same depth;
    // wrapping either in an `if`, a `switch` or a closure adds one. `Text("Power")`
    // is the anchor because it is the section heading — a build where THAT is
    // conditional is not a build where this check is the problem.
    //
    // LIMIT, stated rather than hidden: this counts braces over comment-stripped
    // code, and `swiftCodeWithoutComments` keeps string literals. A brace inside
    // a string in this file would miscount. There is none today — the strings
    // are labels like "Power" and "Battery floor" — and if one arrives, this
    // guard is what has to change.
    //
    // It also cannot prove the VStack itself is reachable. It proves this row is
    // no more conditional than the heading above it, which is the property that
    // was actually at risk.
    let anchorDepth = try #require(braceDepth(atFirst: "Text(\"Power\")", in: windowCode), """
        PreferencesView.swift no longer contains Text("Power"), so this guard has \
        no unconditional neighbour to compare against and measured nothing.
        """)
    let summaryDepth = try #require(braceDepth(atFirst: "ServingModel.lidClosedSummary",
                                               in: windowCode))

    // ANTI-VACUITY. `body`, `ScrollView` and `VStack` are three braces before
    // either render, plus the struct. A depth of nought means the counter read
    // something that is not this view at all, and two zeroes would compare equal
    // and pass.
    #expect(anchorDepth >= 3, """
        the unconditional anchor in PreferencesView.swift sits at brace depth \
        \(anchorDepth), which is shallower than the struct, body, ScrollView and \
        VStack that must enclose it. This guard is reading the wrong thing.
        """)

    #expect(summaryDepth == anchorDepth, """
        PreferencesView.swift spells ServingModel.lidClosedSummary at brace depth \
        \(summaryDepth) while the unconditional Text("Power") beside it sits at \
        \(anchorDepth). The summary is inside something the heading is not — an \
        `if`, a `switch`, a closure — so the text is present in the file and the \
        user may never see it. The lid-closed summary is unconditional: there is \
        no state to condition it on, and silence reads as "lid-closed mode is off".
        """)

    // The negative half. Issue #56: the panel keeps NOTHING about lid-closed
    // mode, so both the current property and the one it replaced are refused.
    // Naming the OLD spelling too is not belt and braces — a revert that
    // restores `lidClosedAdvisory` is the most likely way this comes back, and
    // a guard that only knew the new name would pass over it.
    for property in ["lidClosedSummary", "lidClosedAdvisory"] {
        #expect(!panelCode.contains(property), """
            PanelView.swift reads \(property) in code. Issue #56: the Serving \
            panel keeps nothing about lid-closed mode — it is neither live \
            state nor a control, and it rendered as a paragraph of \
            documentation in a 260pt column. The short version belongs in \
            PreferencesView.swift and the explanation on site/docs.html.
            """)
    }

    // The literal, not only the symbol. A sentence pasted straight into the
    // panel as a string carries no property name at all, and the two checks
    // above would both pass while the paragraph was back on screen — the
    // failure mode M1 design §5.4 makes invisible to every other check here.
    // `swiftCodeWithoutComments` keeps string literals, which is what makes
    // this readable at all.
    #expect(!panelCode.contains("Lid-closed"), """
        PanelView.swift carries the literal "Lid-closed" in code, so the prose \
        is back in the panel as a string rather than as a property. Issue #56: \
        that surface keeps nothing about lid-closed mode.
        """)
}

@Test func thePreferencesWindowOffersTheDisplayHoldControlAndThePanelReportsItsResult() throws {
    // TWO SURFACES, and that split is the point of the name. The control moved
    // into the Preferences window; the line reporting what it achieved stayed
    // in the panel. Both halves are findability, and they are now findable in
    // different places, so a guard reading one file can no longer hold them.
    //
    // Issue #12's acceptance, and the one thing no other check in this
    // repository can see: the user has to be able to FIND the setting.
    // `ServingModel` can store it, `PowerBroker` can weigh it and
    // `AssertionHolder` can raise it with every check green while no surface
    // offers a way to turn it on — which is a feature that does not exist.
    //
    // That is not hypothetical here. Commit 5116326 landed the hook health
    // check, the model published it, and `PanelView` read it nowhere; the
    // check above this one exists because of it.
    //
    // Same LIMIT as the two checks above, stated rather than hidden: this
    // proves the panel NAMES the binding in CODE, not that it draws a usable
    // control. M1 design §5.4 forbids asserting on rendered AppKit text, so no
    // check in this package can watch the picker appear. It is a tripwire
    // against deleting the control, not proof the control is right.
    //
    // AND IT IS SATISFIED BY A DEAD RENDER, which is not a limit that can be
    // left at "stated": wrapping this picker in `if false { … }` was measured
    // leaving this check green over a window with no Display control in it.
    // `everyMovedControlIsRenderedAsUnconditionallyAsTheHeadingsAboveIt`
    // (`PreferencesView_test.swift`) holds the reachability half by brace
    // depth. This one holds the naming half, and neither is sufficient alone.
    let files = try appLayerSources()
    #expect(files.count == expectedSourceCount,
            "the boundary guard scanned \(files.count) files at \(packageRoot.path)")

    let panel = try #require(files.first { $0.lastPathComponent == "PanelView.swift" },
                             "the app layer no longer compiles a PanelView.swift")
    let window = try #require(files.first { $0.lastPathComponent == "PreferencesView.swift" },
                              "the app layer no longer compiles a PreferencesView.swift")

    // CODE, never the raw file, and this check is the one that PROVED the need.
    // Two mutations were run against the raw-file version: deleting the Display
    // picker outright turned it red, but replacing that picker with a comment
    // naming `$model.holdDisplayAwake` left it GREEN. Issue #12's acceptance —
    // the user has to be able to FIND the setting — was therefore unproven
    // against anyone who deleted the control and said so in a comment. The
    // raw-file version was sound only by the accident that no comment in
    // `PanelView.swift` happened to name the binding, and that accident is
    // spent: the panel now explains in prose that this control moved.
    let code = swiftCodeWithoutComments(try String(contentsOf: panel, encoding: .utf8))
    let windowCode = swiftCodeWithoutComments(try String(contentsOf: window, encoding: .utf8))

    // The BINDING, not the property. `model.holdDisplayAwake` would be
    // satisfied by a line that merely displays the value, and a setting the
    // user can read and not change is not a setting.
    #expect(windowCode.contains("$model.holdDisplayAwake"), """
        PreferencesView.swift binds no control to model.holdDisplayAwake in \
        code, so the display hold can be stored and honoured and the user can \
        never turn it on. Issue #12 asks for a control they can see. A comment \
        naming the binding does not satisfy this.
        """)

    // The labels come from the model, for the reason the Serving picker's do:
    // a second list of literals in the view can drift from the sentence
    // `servingSummary` writes, and design §5.4 rules out catching that. The
    // move made this sharper rather than looser — the labels stayed on
    // `ServingModel` while the control crossed to another file, which is the
    // whole benefit of their living there.
    #expect(windowCode.contains("ServingModel.displayLabel"), """
        PreferencesView.swift names its own labels for the display control. \
        They belong on ServingModel beside the Serving labels, where a check \
        can read them.
        """)

    // And the line that says what is actually held has to be the model's, not
    // a sentence composed here. It reads "the display may still sleep", which
    // is FALSE once the user opts in, and no check could see it in this file.
    #expect(code.contains("model.servingSummary"), """
        PanelView.swift never reads model.servingSummary in code, so the line \
        telling the user what is held is composed in the view where no check \
        reads it.
        """)
}

@Test func thePanelOffersTheRouteToThePreferencesWindow() throws {
    // PRESENCE, the same tripwire shape as the two checks above and for the
    // same stated reason: the user has to be able to FIND the setting. The
    // scene can be declared, the window can be built and every check can be
    // green while the panel offers no way in — and this panel is the only route
    // the product ships. An `LSUIElement` app has no Dock icon and no menu bar
    // of its own, so a user who cannot reach Preferences from here has ⌘, and
    // nothing else, and nothing tells them that.
    //
    // `theAppDeclaresTheSettingsSceneThePanelLinksTo` holds the other half.
    // Either one alone leaves the feature unreachable: a scene with no link, or
    // a link with no scene.
    //
    // COMMENT-STRIPPED, for the reason `thePanelOffersTheQuietOthersControl`
    // gives, and this file is the case that proves the need — the block above
    // records a mutation where a deleted control left a raw-text guard GREEN
    // because a comment still named it. `PanelView.swift` explains this route
    // in a comment that names both the API used and the one refused.
    //
    // LIMIT, stated rather than hidden: this proves the panel NAMES the link in
    // code, not that it draws a usable control, and not that the window comes to
    // the front when clicked. Design §5.4 rules out asserting on rendered AppKit
    // text; the z-order behaviour is verifiable only by hand.
    let files = try appLayerSources()
    #expect(files.count == expectedSourceCount,
            "the boundary guard scanned \(files.count) files at \(packageRoot.path)")

    let panel = try #require(files.first { $0.lastPathComponent == "PanelView.swift" },
                             "the app layer no longer compiles a PanelView.swift")
    let code = swiftCodeWithoutComments(try String(contentsOf: panel, encoding: .utf8))

    #expect(code.contains("openSettings("), """
        PanelView.swift calls no openSettings(, so the panel has no route to the \
        Preferences window. The scene can be declared and the view built with \
        every check green while the only affordance the product ships is gone.
        """)

    // The MECHANISM, not only the presence, because the wrong one fails at
    // runtime on some releases and compiles on all of them. AppKit's selector
    // for this window has changed spelling across macOS releases, so
    // `NSApp.sendAction(Selector(("showSettingsWindow:")))` is a string that
    // always builds and sometimes works — a silent failure on exactly the
    // machines the maintainer is not sitting at. `@Environment(\.openSettings)`
    // is the typed equivalent and needs macOS 14, which is already this
    // package's target.
    //
    // IT USED TO BE `SettingsLink`, and this guard named it until issue #63.
    // Both are typed and both open the same window; the difference is that a
    // link is not a closure, so nothing can run on the click. The #50 fix
    // therefore had to live on the Settings scene's `onAppear`, which fires when
    // the window is CREATED — and clicking Preferences with the window already
    // open re-presents it, so the app never came forward. Measured at 54f0058:
    // `before = [coffee-bar Settings] -> after = Finder`. The route is now a
    // `Button` whose action runs on every click.
    //
    // This is still a PRESENCE tripwire and deliberately no more: it says the
    // panel names the route in code. What that action must actually DO —
    // dismiss the panel, take the foreground, and in that order — is held by
    // `PanelView_test.swift`, which reads the action block itself.
    //
    // THE COMMENT STRIPPING IS LOAD-BEARING HERE, NOT STYLISTIC. Read this
    // before changing `swiftCodeWithoutComments` out of the line above.
    //
    // `PanelView.swift` spells this selector out, in the comment explaining why
    // it is refused. So over the RAW file this expectation is not merely blind
    // the way the version guard was — it is INVERTED. It reports a CORRECT
    // implementation as a violation, and the obvious way to make a red build
    // green again is to delete the comment that documents the decision. The
    // guard would then have destroyed the record of the reason it exists,
    // leaving the next person free to reach for the selector with nothing left
    // to warn them off it.
    //
    // A guard that is wrong on a correct tree is worse than no guard: it
    // teaches people to silence it.
    #expect(!code.contains("showSettingsWindow:"), """
        PanelView.swift reaches the Preferences window through the string \
        selector showSettingsWindow:. That spelling has changed across macOS \
        releases, so it compiles everywhere and works somewhere. SettingsLink is \
        the typed route and macOS 14 is already the deployment target.
        """)
}

@Test func theSettingsWindowTakesTheForegroundAndGivesItBack() throws {
    // MEASURED, not anticipated. At 0.1.1-31-g7949c51 clicking Preferences…
    // opened the window and left the app in the background:
    //
    //     before=Finder | after=Finder | windows=[coffee-bar Settings]
    //
    // coffee-bar is `LSUIElement`, and macOS 14 made activation cooperative: an
    // `.accessory` app that asks for the foreground is declined. So the window
    // drew over whatever the user was in, with a grey title bar, taking none of
    // their keystrokes.
    //
    // BOTH HALVES, and the second is the one a fix forgets. Becoming `.regular`
    // is what lets the app activate; going back to `.accessory` when the window
    // closes is what stops a menu-bar-only product keeping a Dock icon for the
    // rest of the session. A tree with the first and not the second passes the
    // acceptance script and is still wrong.
    //
    // THE REAL CHECK FOR THIS IS NOT HERE, and saying so is the point.
    // `scripts/preferences-activation-acceptance.sh` drives the running app
    // through the accessibility API and reads which process is frontmost — the
    // only way to observe it, because M1 design §5.4 rules out asserting on
    // rendered AppKit state and the fault lives in the window server's notion of
    // which application is active. That script needs Accessibility permission
    // and a running build, so it cannot run in CI. This guard is the CI-side net
    // for it: it proves the calls the script measured are still there. It cannot
    // prove they work.
    //
    // COMMENT-STRIPPED, and this file's own history is why that is not optional.
    // The paragraph you are reading names both calls while explaining them, so
    // read raw this expectation would pass on the strength of its own
    // documentation — the blind direction, exactly as the version guard failed.
    let files = try appLayerSources()
    #expect(files.count == expectedSourceCount,
            "the boundary guard scanned \(files.count) files at \(packageRoot.path)")

    let window = try #require(files.first { $0.lastPathComponent == "PreferencesView.swift" },
                              "the app layer no longer compiles a PreferencesView.swift")
    let code = swiftCodeWithoutComments(try String(contentsOf: window, encoding: .utf8))

    #expect(code.contains("NSApp.activate("), """
        PreferencesView.swift never asks for the foreground. coffee-bar is \
        LSUIElement: the window then draws in front of whatever the user was \
        in, with a grey title bar, and their keystrokes go to the other app. \
        Measured at 0.1.1-31-g7949c51 as before=Finder/after=Finder with the \
        Settings window present.
        """)

    #expect(code.contains("setActivationPolicy(.regular)"), """
        PreferencesView.swift calls NSApp.activate without becoming .regular \
        first. Measured on macOS 26.5: under .accessory that call does nothing \
        — the window sits in NSApp.windows and keyWindow stays nil, with or \
        without makeKeyAndOrderFront. Re-run \
        scripts/preferences-activation-acceptance.sh before changing this.
        """)

    // SCOPED TO `.onDisappear`, and the unscoped `contains` this replaces was
    // defeated BY EXECUTION rather than by argument. The mutant: delete
    // `.onDisappear` and put `if false { setActivationPolicy(.accessory) }`
    // inside `onAppear`. The string is still in the file, the old assertion
    // still passed, and the call can never run — so a permanent Dock icon
    // shipped with CI green, which is the exact failure the message below
    // claims to prevent.
    //
    // That is not a hypothetical mutation. The revert is the SOLE condition on
    // which a Dock icon was accepted into a menu-bar-only product at all, so
    // this is the one assertion in this test that has to hold by wiring rather
    // than by spelling.
    //
    // `braceBlock(after:in:)` is the reader the version guard and the
    // attention-list guard already use. One tested brace reader in this target,
    // never a second — two could disagree about what a block is.
    let restore = try #require(braceBlock(after: ".onDisappear", in: code)?.block, """
        PreferencesView.swift opens no `.onDisappear` block, so nothing restores \
        the activation policy when the Preferences window closes. The app turns \
        .regular to take the foreground and never turns back: a menu-bar-only \
        product then keeps a Dock icon for the rest of the session.
        """)

    #expect(restore.contains("setActivationPolicy(.accessory)"), """
        PreferencesView.swift's .onDisappear does not call \
        setActivationPolicy(.accessory), so a Dock icon outlives the window that \
        needed it and a menu-bar-only app keeps one for the rest of the session. \
        The restore belongs on the window's own disappearance, which is the only \
        event that knows it has gone. A call ANYWHERE ELSE in the file does not \
        satisfy this — an unreachable one is what this scoping was added to catch.
        """)
}
