// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "coffee-bar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "coffee-bar-probe", targets: ["CoffeeBarProbe"]),
        .executable(name: "coffee-bar", targets: ["CoffeeBarApp"]),
        .library(name: "CoffeeBarCore", targets: ["CoffeeBarCore"]),
    ],
    targets: [
        .target(name: "CoffeeBarCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "CoffeeBarPower", dependencies: ["CoffeeBarCore"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        // The model, the panel and the glyphs live in a library rather than in
        // the executable: SwiftPM treats an executable target's `main.swift` as
        // top-level code, which a test target cannot import.
        .target(name: "CoffeeBarUI", dependencies: ["CoffeeBarPower"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "CoffeeBarProbe", dependencies: ["CoffeeBarPower"],
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "CoffeeBarApp", dependencies: ["CoffeeBarUI"],
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CoffeeBarCoreTests", dependencies: ["CoffeeBarCore"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CoffeeBarPowerTests", dependencies: ["CoffeeBarPower"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CoffeeBarUITests", dependencies: ["CoffeeBarUI"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
