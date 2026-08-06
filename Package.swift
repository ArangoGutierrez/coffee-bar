// swift-tools-version: 6.0
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "coffee-bar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "coffee-bar-probe", targets: ["CoffeeBarProbe"]),
        .executable(name: "coffee-bar", targets: ["CoffeeBarApp"]),
        // The name is part of the contract, not a detail: `HookHealth`
        // recognises a wired hook by matching it in the user's settings file,
        // and `docs/QUICKSTART.md` prints it. Renaming it stops every hook the
        // user has already wired being recognised as coffee-bar's.
        .executable(name: "coffeebar-hook", targets: ["CoffeeBarShim"]),
        .library(name: "CoffeeBarCore", targets: ["CoffeeBarCore"]),
    ],
    targets: [
        .target(name: "CoffeeBarCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "CoffeeBarPower", dependencies: ["CoffeeBarCore"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        // The listener and the HTTP framing. Depends on CoffeeBarCore only:
        // ingest produces sessions, it does not decide what they mean.
        .target(name: "CoffeeBarIngest", dependencies: ["CoffeeBarCore"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        // The model, the panel and the glyphs live in a library rather than in
        // the executable: SwiftPM treats an executable target's `main.swift` as
        // top-level code, which a test target cannot import.
        .target(name: "CoffeeBarUI", dependencies: ["CoffeeBarPower", "CoffeeBarIngest"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "CoffeeBarProbe", dependencies: ["CoffeeBarPower"],
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "CoffeeBarApp", dependencies: ["CoffeeBarUI"],
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        // The hook shim. Depends on CoffeeBarCore ONLY, and adds no third-party
        // dependency: a hook runs on every tool call, so process start-up is
        // the dominant cost against the handoff's 50 ms budget. It talks to the
        // socket with raw POSIX calls rather than Network.framework for the
        // same reason. Everything testable about it lives in `HookShim`,
        // because SwiftPM treats this target's `main.swift` as top-level code.
        .executableTarget(name: "CoffeeBarShim", dependencies: ["CoffeeBarCore"],
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        // A demoter a check can SIGKILL. `ProcGovernor` is the first thing here
        // that touches a pid it does not own, and the demotion outlives whatever
        // applied it, so the crash-recovery criterion needs a real second
        // process running the real governor. A SIGKILL cannot be caught, so that
        // process cannot be this one.
        //
        // Deliberately a target and NOT a product: `scripts/build-app.sh` builds
        // `--product coffee-bar`, so this never reaches a release.
        .executableTarget(name: "CoffeeBarGovernorHarness", dependencies: ["CoffeeBarPower"],
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CoffeeBarCoreTests", dependencies: ["CoffeeBarCore"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CoffeeBarPowerTests", dependencies: ["CoffeeBarPower"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CoffeeBarUITests", dependencies: ["CoffeeBarUI"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CoffeeBarIngestTests", dependencies: ["CoffeeBarIngest"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
