// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import CoffeeBarCore

/// The sessions blocked on the human, in the order the model published them.
///
/// It sorts nothing and filters nothing. `AttentionList` in `CoffeeBarCore`
/// decides both, so the rule tests with no SwiftUI and the view cannot quietly
/// disagree with it. This draws what it is handed.
///
/// `Text(verbatim:)` for every session-derived string, deliberately. Design §7
/// calls that text attacker-influenced — `repoName` comes off a `cwd` on the
/// wire and `lastMessage` off a permission `reason` — and `verbatim` renders it
/// as characters rather than letting `Text` interpret it as markdown.
struct AttentionListView: View {
    let sessions: [AgentSession]

    /// The gap between two waiting rows.
    ///
    /// A constant rather than a literal in `body` because `maximumListHeight`
    /// below is derived from it. Left as a literal, the derivation would go on
    /// describing a layout the view had stopped drawing, and design §5.4 rules
    /// out any check noticing.
    ///
    /// `nonisolated` on this and on every static below is LOAD-BEARING, for the
    /// reason `PanelView.versionLine(from:)` documents at length: SwiftUICore
    /// declares `View` as `@preconcurrency @MainActor`, so a conforming type
    /// infers main-actor isolation for its members, statics included. A
    /// swift-testing `@Test` function is nonisolated, and the two toolchains
    /// disagree about the inference — it compiled locally on 6.3.3 and failed on
    /// the macos-15 runner's 6.1.2. A green local suite is not evidence for
    /// these keywords; treat CI as the authority.
    nonisolated static let rowSpacing: CGFloat = 8

    /// The gap between the lines inside one row.
    nonisolated static let lineSpacing: CGFloat = 2

    /// The height of one line of caption text.
    ///
    /// MEASURED, not guessed. `.caption` and `.caption2` both resolve to the
    /// 10pt system font on macOS, and
    ///
    ///     NSLayoutManager().defaultLineHeight(
    ///         for: NSFont.preferredFont(forTextStyle: .caption1))
    ///
    /// printed 13.0 for that style and for `.caption2` on macOS 26.5 at the
    /// default text size.
    ///
    /// LIMIT, stated rather than hidden: it is one number for one text size. A
    /// user who raises the system text size draws taller lines, so the bound
    /// then shows fewer rows than the three it is named for. It still bounds,
    /// which is the defect this fixes; it bounds sooner.
    nonisolated static let captionLineHeight: CGFloat = 13

    /// The tallest one waiting row draws.
    ///
    /// A row is at most four lines of caption text — the repository name, the
    /// state, and the two lines of the last message that `lineLimit(2)` caps —
    /// and the two `lineSpacing` gaps between those three views:
    /// 4 * 13 + 2 * 2 = 56pt. A row whose session carries no message draws two
    /// lines, 28pt.
    ///
    /// `aWaitingRowIsFourCaptionLinesTall` pins this against the measurement.
    nonisolated static let maximumRowHeight: CGFloat =
        4 * captionLineHeight + 2 * lineSpacing

    /// How many rows the list shows before it scrolls.
    ///
    /// THREE, and the number is a judgement with a stated reason rather than a
    /// round one. Three worst-case rows are 184pt (see `maximumListHeight`),
    /// which already makes this list the tallest single element in a panel that
    /// is 260pt wide and carries four controls, four advisories, a battery
    /// reading, a version line, a legal link and a Quit button. A fourth row
    /// costs another 64pt, and the panel's footer is what the defect took away.
    ///
    /// Three is the WORST case, not the usual one. Most rows carry no message
    /// and draw 28pt, so the same 184pt holds five of them
    /// (5 * 28 + 4 * 8 = 172pt) before anything scrolls.
    ///
    /// No claim is made here about how tall a screen is. The list is bounded
    /// because an unbounded one has no reachable bottom on ANY screen, which is
    /// the defect that was observed: twelve waiting sessions are up to
    /// 12 * 56 + 11 * 8 = 760pt of list, drawn under everything else the panel
    /// already carries.
    nonisolated static let visibleRowCount = 3

    /// The tallest the waiting list may draw. The whole fix, as one value.
    ///
    /// `visibleRowCount` rows plus the gaps BETWEEN them, which is one gap fewer
    /// than the row count: 3 * 56 + 2 * 8 = 184pt.
    ///
    /// A value on the type rather than a number inside `body`, for the reason
    /// every other line in this package gives: M1 design §5.4 forbids asserting
    /// on rendered AppKit text, and the same limit covers rendered geometry, so
    /// a bound written into the view is a bound no check reads.
    /// `theWaitingListShowsThreeFullRowsAndThenScrolls` asserts it as a range
    /// that excludes both a clipped third row and a fourth one.
    nonisolated static let maximumListHeight: CGFloat =
        CGFloat(visibleRowCount) * maximumRowHeight
        + CGFloat(visibleRowCount - 1) * rowSpacing

    var body: some View {
        // The rows scroll inside a bounded container rather than growing the
        // panel, and that is the defect: with roughly twelve sessions waiting
        // the list ran past the bottom of the screen, taking the battery
        // reading, the version line and the legal link with it. A list nobody
        // can scroll past is a panel with no reachable bottom.
        //
        // The bound is a MAXIMUM and never a height. `frame(maxHeight:)` passes
        // the proposal through to the content and clamps the answer, so one
        // waiting session draws at the height it drew before this change — no
        // dead space under it — and only a list past `maximumListHeight` scrolls.
        // A `frame(height:)` here would pad every short list out to 184pt.
        //
        // `scrollBounceBehavior(.basedOnSize)` for the same reason: without it a
        // one-row list rubber-bands under the trackpad, which is a scroll
        // container announcing itself where there is nothing to scroll.
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: AttentionListView.rowSpacing) {
                if sessions.isEmpty {
                    Text("Nothing waiting on you.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sessions) { session in
                        VStack(alignment: .leading, spacing: AttentionListView.lineSpacing) {
                            // The session id is the fallback because every
                            // session has one; `repoName` is nil for an event
                            // that carried no `cwd`, and a row with no name at
                            // all would be a row the user cannot act on.
                            Text(verbatim: session.repoName ?? session.sessionID)
                                .font(.caption).bold()

                            // Read off the state rather than composed from free
                            // text, so what the panel says is what the hub
                            // decided.
                            Text(session.state == .awaitingPermission
                                 ? "waiting for permission" : "waiting for you")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            if let message = session.lastMessage {
                                Text(verbatim: message)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: AttentionListView.maximumListHeight)
        // The bound needs a FLOOR as well, and this shipped broken before the
        // running app showed it: a ScrollView is the only flexible child of the
        // panel's VStack, so when the panel is taller than the window it can
        // use, the stack takes the shortfall out of the one view that can
        // shrink. This list went to zero height and "Nothing waiting on you."
        // vanished from the panel while every check stayed green.
        //
        // `fixedSize` vertically pins the container at the size the bound has
        // already decided — min(content, maximumListHeight) — so the stack
        // cannot take height from it. `PanelView` pins the lid-closed advisory
        // the same way and for the same kind of reason.
        .fixedSize(horizontal: false, vertical: true)
        .scrollBounceBehavior(.basedOnSize)
    }
}
