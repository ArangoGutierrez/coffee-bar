// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoffeeBarCore

/// Reads `~/.claude/settings.json` and reports whether our hooks are installed.
///
/// **This type only ever reads.** Design §6 forbids putting bytes into that
/// file: it is shared territory, and this workspace records a critical
/// six-occurrence last-writer-wins clobber pattern in exactly it. coffee-bar
/// prints the snippet for the user to paste, and reads the file back so a
/// clobbered snippet becomes visible failure rather than silent failure.
///
/// Two checks hold that line, from two directions —
/// `readingTheStatusLeavesTheFileExactlyAsItWas` runs this type and compares
/// the bytes on disk, and `noSourceFileThatKnowsTheSettingsPathCanWriteToIt`
/// reads this source for any call that puts bytes on disk.
///
/// **What it can and cannot see.** `.wired` means the entries are in the file.
/// It does NOT mean an event has ever arrived: PE finding B2 measured a second
/// app instance stealing the socket path, after which ingest is dead and this
/// file is untouched. A live-socket probe is the separate check that would
/// close that gap.
///
/// Design §8 puts the file read in `CoffeeBarIngest`, so that `CoffeeBarCore`
/// keeps its no-I/O rule. This landed first, before that target existed, and
/// `CoffeeBarUI` is the nearest home that keeps the pure parse in
/// `CoffeeBarCore` — `ServingModel`, the one caller, lives here.
///
/// `CoffeeBarIngest` exists now, and both targets are in the app layer, so the
/// move is a file move and a module change with no behaviour in it. It is
/// DEFERRED rather than done: it buys no correctness, and both directories are
/// scanned by `AppLayerBoundary_test.swift` either way.
public struct HookHealthReader: Sendable {
    public let settingsURL: URL

    public init(settingsURL: URL = HookHealthReader.defaultSettingsURL) {
        self.settingsURL = settingsURL
    }

    /// Design §6 fixes the location.
    public static var defaultSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/settings.json")
    }

    /// Never throws. An absent file, a directory, a permission refusal and a
    /// half-saved file all reach the panel as `.unreadable`, because none of
    /// them is evidence that the entries are gone.
    public func status() -> HookHealthStatus {
        HookHealth.status(ofSettings: try? Data(contentsOf: settingsURL))
    }
}
