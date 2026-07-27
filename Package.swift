// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "coffee-bar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "coffee-bar-probe", targets: ["CoffeeBarProbe"]),
        // Spike: the menu-bar POC. M1 replaces this target wholesale.
        .executable(name: "coffee-bar-poc", targets: ["CoffeeBarMenuBarPOC"]),
        .library(name: "CoffeeBarCore", targets: ["CoffeeBarCore"]),
    ],
    targets: [
        .target(name: "CoffeeBarCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "CoffeeBarPower", dependencies: ["CoffeeBarCore"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "CoffeeBarProbe", dependencies: ["CoffeeBarPower"],
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "CoffeeBarMenuBarPOC", dependencies: ["CoffeeBarPower"],
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CoffeeBarCoreTests", dependencies: ["CoffeeBarCore"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CoffeeBarPowerTests", dependencies: ["CoffeeBarPower"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
