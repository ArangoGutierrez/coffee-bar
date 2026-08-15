// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// One advisory: a warning symbol, then the sentence the model published.
///
/// SHAPE, NOT COLOUR, and that is issue #30. Every advisory line took SwiftUI's
/// semantic orange as its foreground style — systemOrange, the same pigment the
/// brand doc calls `action`. As caption TEXT it measures 1.75:1 to 2.31:1 on the
/// light backdrops these surfaces draw on, where WCAG asks 4.5:1 below ~18pt.
/// The pigment is named nowhere in this file, not even in this note: a literal
/// written in prose is what a guard reading raw source counts. The dark
/// appearance was never the problem: it clears 7.62:1. Darkening the pigment
/// until it passes on light reaches roughly `#8C5200`, which is the roast
/// `state` colour — so the fix that keeps the colour deletes the hue separation
/// these surfaces depend on, where roast means coffee-bar is acting and the
/// other accent means attention. Moving the pigment onto an icon does not rescue
/// it either; it fails even the 3:1 non-text floor on a light backdrop.
///
/// So the meaning moves to a symbol, which no appearance and no contrast setting
/// can wash out, and `assets/art/README.md` line 22 gets its own rule back:
/// neither accent carries body text.
///
/// The KNOWN COST, in issue #30's words: the warnings get quieter, and the
/// dead-socket line is the one users most need to notice. Three things pay it,
/// none of them a colour:
///
///   - the FILLED triangle rather than the outline, because a 1pt stroke at
///     caption size is nearly nothing;
///   - `.imageScale(.large)`, so the symbol reads as a mark beside the text
///     rather than as a character in it;
///   - `.primary` and `.semibold` on the sentence, against the `.secondary` of
///     the neutral lines around it. An advisory now draws DARKER and HEAVIER
///     than the line it interrupts, which is the one axis left once hue is
///     spent — and it is the axis that survives Increase Contrast, Differentiate
///     Without Color and a greyscale display.
///
/// All three are pinned by `AdvisoryRow_test.swift`, which reads the image and
/// the text spans APART: `.accessibilityHidden` on the sentence instead of the
/// symbol would hide the advisory from VoiceOver entirely, and a check that
/// reads the file as one string cannot tell those two apart.
///
/// The symbol is `accessibilityHidden`, exactly as the serving indicator's is:
/// it restates what the sentence beside it already says, and VoiceOver reading
/// "warning triangle" before every advisory is noise, not access. The sentence
/// is the accessible carrier and always was — colour never reached that route at
/// all.
///
/// **Why this is a top-level type in its own file.** It was
/// `private func advisoryRow(_:)` on `PanelView`, and that is why issue #30
/// shipped with a fifth advisory still painted: `PreferencesView` renders the
/// same `staleHelperAdvisory` sentence, could not reach the treatment, and so
/// wrote its own — while the guard that should have caught it read
/// `PanelView.swift` and nothing else. One declaration, reachable from every
/// surface, is what stops the two drifting apart a site at a time;
/// `advisoriesCarryShapeRatherThanColour` now counts the declarations
/// MODULE-WIDE so a second one cannot reappear in a sibling file unnoticed.
///
/// A `View` and not a free function returning `some View`, and the reason is not
/// taste. `PanelView.versionLine(from:)` documents this package's one measured
/// toolchain split: `View` is declared `@preconcurrency @MainActor`, so a type
/// conforming to it infers that isolation for its members while a module-scope
/// function does not — and the two toolchains this repo builds on disagree about
/// when that inference applies. A type composes these views under the same
/// isolation every other surface here already has, so this cannot compile
/// locally and fail on the runner.
///
/// **`.textSelection` is NOT here, deliberately.** One advisory — the stale
/// helper — carries a command meant to be pasted into a root shell, and both
/// surfaces that render it chain `.textSelection(.enabled)` at the call site.
/// The others carry nothing worth selecting. `.textSelection` reaches the `Text`
/// through the Environment, so chaining it onto this row works; putting it
/// inside would make every advisory selectable in order to serve one of them.
struct AdvisoryRow: View {
    let line: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .imageScale(.large)
                .accessibilityHidden(true)
            Text(line)
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.primary)
    }
}
