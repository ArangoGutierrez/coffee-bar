// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

/// Reads `scripts/build-app.sh` as text. `#filePath` anchors the lookup to THIS
/// source file, so the guard cannot green-light a different tree.
private func buildScriptLines() throws -> [String] {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CoffeeBarUITests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
    let text = try String(
        contentsOf: root.appendingPathComponent("scripts/build-app.sh"),
        encoding: .utf8)
    // Comment lines come out first, so every assertion below reads what the
    // script DOES rather than what its prose says about itself. The icon block
    // names `actool` and `make-icns.sh` in its comments to record why they are
    // not used; a whole-file `contains` would read that prose as code.
    return text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
}

@Test("the build script puts an app icon in the bundle")
func bundleCarriesAnAppIcon() throws {
    let code = try buildScriptLines().joined(separator: "\n")

    // The bug this catches: the bundle shipped with no icon at all. No .icns was
    // ever committed and the assembled Resources/ held only the 8 menu-bar
    // glyphs, so Finder drew the generic bundle icon on every install.
    #expect(code.contains("iconutil -c icns"),
            "the build must compile the iconset into an .icns")

    #expect(code.contains("-o \"${CONTENTS}/Resources/AppIcon.icns\""),
            "the .icns must land in the bundle's Resources directory")
}

@Test("the generated Info.plist names the icon file")
func infoPlistDeclaresTheIconKey() throws {
    let code = try buildScriptLines().joined(separator: "\n")

    // The bug this catches: an .icns sitting in Resources is inert on its own.
    // A hand-assembled bundle with no CFBundleIconFile key still gets the
    // generic Finder icon, so dropping this key undoes the whole task while
    // leaving the file in place — invisible to any check that only stats
    // AppIcon.icns.
    #expect(code.contains("<key>CFBundleIconFile</key>"),
            "Info.plist must declare CFBundleIconFile")
    #expect(code.contains("<string>AppIcon</string>"),
            "CFBundleIconFile must name AppIcon")

    // The script must read the key back out of the written plist. `plutil -lint`
    // accepts any well-formed plist and would pass a bundle whose icon key never
    // made it through the heredoc.
    #expect(code.contains("plutil -extract CFBundleIconFile raw -o -"),
            "the build must verify the icon key in the plist it just wrote")
}

@Test("the icon build never touches the tracked iconset")
func iconBuildLeavesTheTrackedTreeAlone() throws {
    let lines = try buildScriptLines()

    // The bug this catches: `assets/art/appicon/make-icns.sh` renames `-2x` to
    // `@2x` IN PLACE, and iconutil needs the `@`. Doing that rename against the
    // tracked iconset makes every build dirty `assets/`, so a release build from
    // a clean checkout silently rewrites the repo it was cut from.
    //
    // Checked per line rather than per file, and as an ALLOW-list. Banning the
    // words `mv` and `iconutil` on a line naming the tracked path looks
    // equivalent but is not: the realistic form of this bug is
    // `for f in "${ICONSET_SRC}"/*-2x.png`, where the loop HEADER names the
    // tracked path and the `mv` sits on the next line. A deny-list misses it.
    // Exactly three uses are legitimate — defining the path, proving the
    // iconset exists, and naming it as the SOURCE of the copy. Any fourth use
    // is the bug.
    //
    // All THREE spellings of the tracked path are matched. Filtering on the
    // braced form alone let the bug back in by ADDING a line rather than
    // changing one: `$ICONSET_SRC` is not a substring of `${ICONSET_SRC}`, and
    // a re-derived `"${REPO_ROOT}/assets/art/appicon/AppIcon.iconset"` names
    // the same directory without mentioning the variable at all. Either writes
    // into the tracked tree while this guard stays green.
    let trackedPath = ["${ICONSET_SRC}",
                       "$ICONSET_SRC",
                       "assets/art/appicon/AppIcon.iconset"]
    let sourceUses = lines.filter { line in trackedPath.contains { line.contains($0) } }

    #expect(!sourceUses.isEmpty, "the script must reference the tracked iconset somewhere")

    for line in sourceUses {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // The definition names the path but writes nothing through it, and it
        // is the one line that must carry the literal form.
        let isDefinition = trimmed.hasPrefix("ICONSET_SRC=")
        let isExistenceCheck = trimmed.hasPrefix("[ -d \"${ICONSET_SRC}\" ]")
        let isCopySource = trimmed.contains("cp -R \"${ICONSET_SRC}\"")
        #expect(isDefinition || isExistenceCheck || isCopySource,
                "only the definition, the existence check and the copy may name the tracked iconset: \(trimmed)")
    }

    // The copy itself has to exist, or there is nothing for the rename to be
    // safely performed against.
    let code = lines.joined(separator: "\n")
    #expect(code.contains("cp -R \"${ICONSET_SRC}\""),
            "the iconset must be copied before the rename")
    #expect(code.contains("\"${ICON_TMP}/AppIcon.iconset\"/*-2x.png"),
            "the rename loop must glob inside the temporary copy")
}
