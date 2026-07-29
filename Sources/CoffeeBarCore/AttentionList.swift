// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The two questions the panel asks of the session list.
///
/// `rows` answers "what is waiting on me". `working` answers "what is keeping
/// this Mac awake" — design §14, added after a review found that the panel as
/// first planned showed the blocked states only, so the session actually
/// holding the assertion appeared nowhere in a product whose whole pitch is
/// that you can see it.
///
/// Both live here rather than in the view, for two reasons. They test with no
/// SwiftUI and no Mac. And neither may quietly disagree with the broker about
/// which states mean what: `SessionState.attentionStates` and
/// `PowerBroker.activeStates` are the single sources, and both are read here
/// rather than re-stated.
///
/// Design §10.3 leaves the contents and the ordering of the attention list
/// OPEN. This is the provisional answer: the two attention states only,
/// longest wait first.
public enum AttentionList {

    /// The sessions blocked on the human, longest wait first.
    public static func rows(from sessions: [AgentSession]) -> [AgentSession] {
        sessions
            .filter { SessionState.attentionStates.contains($0.state) }
            .sorted { left, right in
                // A TOTAL order. `sorted` is not documented as stable in Swift,
                // so without the `id` tie-break two sessions blocked in the same
                // instant may swap places on every refresh, under the user's
                // cursor.
                //
                // `nil` sorts LAST: an unstamped session is not "waiting since
                // the beginning of time". The final branch carries both the
                // equal-date pair and the nil/nil pair, so neither escapes the
                // tie-break.
                switch (left.attentionSince, right.attentionSince) {
                case let (l?, r?) where l != r: return l < r
                case (nil, _?): return false
                case (_?, nil): return true
                default: return left.id < right.id
                }
            }
    }

    /// The sessions holding the machine awake right now, in the order given.
    ///
    /// Read straight off `PowerBroker.activeStates`, which is the predicate the
    /// hold decision itself uses. A list built from a second definition could
    /// report "0 sessions" while the assertion was held, and a panel that
    /// disagrees with the machine is worse than a panel with nothing on it.
    ///
    /// `holdAwakeWhileBlocked` defaults to the same `false`
    /// `HoldController.evaluate` defaults to. Nothing reaches that knob from the
    /// UI yet; the parameter is here so that the day something does, this count
    /// follows the assertion instead of drifting from it.
    ///
    /// Unsorted, unlike `rows`: this feeds a COUNT, and imposing an order on a
    /// number would be an order no caller reads and no check could hold.
    public static func working(from sessions: [AgentSession],
                               holdAwakeWhileBlocked: Bool = false) -> [AgentSession] {
        let active = PowerBroker.activeStates(holdAwakeWhileBlocked: holdAwakeWhileBlocked)
        return sessions.filter { active.contains($0.state) }
    }
}
