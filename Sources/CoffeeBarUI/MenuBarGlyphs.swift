// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Loads the vendored template glyphs from the assembled bundle by path.
///
/// `NSImage(named:)` needs an asset catalogue or a registered bundle resource;
/// `scripts/build-app.sh` copies the art in with `cp`, so lookup is by path.
@MainActor
enum MenuBarGlyphs {
    private static var cache: [String: NSImage] = [:]
    private static let glyphSize = NSSize(width: 16, height: 16)

    static func image(named name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let resources = Bundle.main.resourcePath else { return nil }

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
