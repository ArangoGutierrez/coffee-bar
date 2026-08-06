// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarUI

/// The height bound on the waiting list, asserted as a value.
///
/// M1 design §5.4 forbids asserting on rendered AppKit text, and the same limit
/// covers rendered geometry: nothing in this package can watch the list grow off
/// the bottom of the screen. So the decision is a value on `AttentionListView`,
/// the view applies that value and nothing else, and these checks read the
/// value. `PanelLegalLine_test` makes the same argument for the legal line.
///
/// `theWaitingListDrawsInsideABoundedScrollContainer` in
/// `AppLayerBoundary_test.swift` is the other half of the pair: it fails if the
/// view stops applying the bound. A value with no reader is not a fix.

@Test func aWaitingRowIsFourCaptionLinesTall() {
    // The measurement everything below rests on.
    //
    // A row draws three Text views: the repository name (`.caption`), the state
    // (`.caption2`), and the last message (`.caption2`, `lineLimit(2)`). That is
    // four text lines at worst, with two intra-row gaps between the three views.
    //
    // On macOS both styles resolve to the 10pt system font, whose default line
    // height measures 13.0pt:
    //
    //     NSLayoutManager().defaultLineHeight(
    //         for: NSFont.preferredFont(forTextStyle: .caption1))
    //
    // printed 13.0 for `.caption1` and for `.caption2` on macOS 26.5 at the
    // default text size. So a worst-case row is 4 * 13 + 2 * 2 = 56pt.
    //
    // Named bug: somebody rewrites the arithmetic around a guessed row height —
    // 20pt "because captions are small" — and the bound then clips the third row
    // in half. A half-row is worse than no row: it reads as a rendering fault.
    #expect(AttentionListView.maximumRowHeight == 56, """
        a worst-case waiting row is 4 caption lines of 13pt plus 2 gaps of 2pt, \
        which is 56pt. \(AttentionListView.maximumRowHeight) says the row \
        arithmetic no longer describes what a row draws.
        """)
}

@Test func theWaitingListShowsThreeFullRowsAndThenScrolls() {
    // The defect this whole change exists for: with roughly twelve sessions
    // waiting, the list grew without bound and pushed the battery reading, the
    // version line and the legal link off the bottom of the screen. Unbounded,
    // twelve worst-case rows are 12 * 56 + 11 * 8 = 760pt of list alone.
    //
    // Three rows is the choice. The arithmetic, derived here rather than copied
    // from the implementation: three worst-case rows plus the two 8pt gaps
    // between them is 3 * 56 + 2 * 8 = 184pt. A fourth row would need
    // 4 * 56 + 3 * 8 = 248pt.
    //
    // Two named bugs, one at each end:
    //
    //   * below 184 the third row is clipped, so the bound would advertise three
    //     rows and draw two and a half;
    //   * at 248 or above a fourth row fits, and every row added to the bound is
    //     56pt the footer loses. The bound is also the only thing standing
    //     between this panel and the defect, so `.infinity` — which compiles,
    //     keeps the scroll container in place, and restores the defect whole —
    //     has to fail here. A range does that; an inequality on one side would
    //     not.
    #expect(AttentionListView.visibleRowCount == 3, """
        the list is bounded at \(AttentionListView.visibleRowCount) rows. Three \
        is the shipped decision; raising it gives the footer back to the list.
        """)
    #expect(AttentionListView.maximumListHeight >= 184, """
        the bound is \(AttentionListView.maximumListHeight)pt, under the 184pt \
        that three worst-case rows need, so the third row draws clipped.
        """)
    #expect(AttentionListView.maximumListHeight < 248, """
        the bound is \(AttentionListView.maximumListHeight)pt, which is room for \
        a fourth row (248pt) or more. The panel is 260pt wide and already dense; \
        the list may not take the footer back.
        """)
}

@Test func theWaitingListBoundLeavesTheRowsThemselvesAlone() {
    // The bound is a height, and nothing else. The row spacings it is derived
    // from are the spacings the view already used before this change — 8pt
    // between rows, 2pt inside one — and they are read from these constants so
    // the derivation above cannot quietly stop describing the layout.
    //
    // Named bug: somebody tunes the bound by opening the row spacing up instead,
    // which changes what every row looks like and leaves the arithmetic in
    // `aWaitingRowIsFourCaptionLinesTall` describing a row that no longer
    // exists.
    #expect(AttentionListView.rowSpacing == 8,
            "the gap between waiting rows changed; the bound no longer shows 3 rows")
    #expect(AttentionListView.lineSpacing == 2,
            "the gap inside a waiting row changed; the row height arithmetic is stale")
}
