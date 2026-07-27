// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

// spikes-note: THIS IS A POC, NOT MILESTONE CODE.
//
// A throwaway SwiftUI shell built so the shape of the product can be seen in a
// real menu bar today. M1 replaces this target wholesale — do not review it as
// milestone code, do not build on it, do not copy patterns out of it.
//
// The one piece here that IS real, reviewed, tested code lives elsewhere:
// `CoffeeBarPower.AssertionHolder`. Everything in this file is scaffolding
// around it, and the only claim it makes is that toggling "Serving" shows up in
// `pmset -g assertions`.

import AppKit
import CoffeeBarPower
import IOKit.ps
import SwiftUI

// MARK: - Menu-bar glyphs

/// Loads the vendored template glyphs out of the hand-assembled bundle.
///
/// `NSImage(named:)` wants an asset catalogue or a properly-registered bundle
/// resource; this bundle is assembled by `scripts/build-poc-app.sh` with `cp`,
/// so the images are looked up by path instead.
@MainActor
enum MenuBarGlyphs {
    private static var cache: [String: NSImage] = [:]

    /// The menu bar draws at 16pt — the size the art was cut at.
    private static let glyphSize = NSSize(width: 16, height: 16)

    static func image(named name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let resources = Bundle.main.resourcePath else { return nil }

        // PDF first: AppKit's preferred format at this size.
        for ext in ["pdf", "png"] {
            let path = (resources as NSString).appendingPathComponent("\(name).\(ext)")
            guard let image = NSImage(contentsOfFile: path) else { continue }
            // Load-bearing: AppKit tints and inverts template images for light
            // and dark menu bars. Never tint them by hand.
            image.isTemplate = true
            image.size = glyphSize
            cache[name] = image
            return image
        }
        return nil
    }
}

// MARK: - Power source

/// Battery percentage and whether the machine is on AC, read straight from
/// IOKit. M1 gets a real `SystemPowerReader`; this is the two-field version the
/// POC needs.
struct PowerSnapshot {
    var percent: Int?
    var isOnAC: Bool

    static func read() -> PowerSnapshot {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return PowerSnapshot(percent: nil, isOnAC: true)
        }

        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any]
            else { continue }

            let onAC = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue

            guard let current = description[kIOPSCurrentCapacityKey] as? Int,
                let maximum = description[kIOPSMaxCapacityKey] as? Int,
                maximum > 0
            else { continue }

            let percent = Int((Double(current) / Double(maximum) * 100).rounded())
            return PowerSnapshot(percent: percent, isOnAC: onAC)
        }

        // Desktops have no battery power source at all.
        return PowerSnapshot(percent: nil, isOnAC: true)
    }
}

// MARK: - Model

@MainActor
@Observable
final class ServingModel {
    private let holder = AssertionHolder()

    private(set) var isServing = false
    private(set) var power = PowerSnapshot.read()

    /// Bound to the toggle. The setter goes through `AssertionHolder`, and
    /// `isServing` reflects what actually happened rather than what was asked
    /// for — a failed `acquire()` leaves the switch off.
    var serving: Bool {
        get { isServing }
        set {
            if newValue {
                isServing = holder.acquire()
            } else {
                holder.release()
                isServing = false
            }
        }
    }

    func refreshPower() {
        power = PowerSnapshot.read()
    }
}

// MARK: - Views

struct MenuBarLabel: View {
    let isServing: Bool

    var body: some View {
        if let glyph = MenuBarGlyphs.image(
            named: isServing ? "coffee-bar-servingTemplate" : "coffee-bar-idleTemplate")
        {
            Image(nsImage: glyph)
        } else {
            // Fallback so the POC still launches if the bundle is missing its
            // Resources — the script prints a warning in that case.
            Image(systemName: isServing ? "cup.and.saucer.fill" : "cup.and.saucer")
        }
    }
}

struct PanelView: View {
    @Bindable var model: ServingModel

    private var batteryLine: String {
        let charge = model.power.percent.map { "\($0)%" } ?? "no battery"
        return "\(charge) · \(model.power.isOnAC ? "AC power" : "battery")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Serving", isOn: $model.serving)
                .toggleStyle(.switch)
                .font(.headline)

            Text(
                model.isServing
                    ? "Holding the system awake. The display may still sleep."
                    : "Not holding any assertion.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Label(batteryLine, systemImage: "bolt")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Button("Quit coffee-bar") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 240)
        .onAppear { model.refreshPower() }
    }
}

struct CoffeeBarPOCApp: App {
    @State private var model = ServingModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuBarLabel(isServing: model.isServing)
        }
        .menuBarExtraStyle(.window)
    }
}

// SwiftPM treats a file called `main.swift` as top-level code, which rules out
// the `@main` attribute. `App.main()` is the documented equivalent.
CoffeeBarPOCApp.main()
