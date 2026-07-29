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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sessions.isEmpty {
                Text("Nothing waiting on you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sessions) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        // The session id is the fallback because every session
                        // has one; `repoName` is nil for an event that carried
                        // no `cwd`, and a row with no name at all would be a
                        // row the user cannot act on.
                        Text(verbatim: session.repoName ?? session.sessionID)
                            .font(.caption).bold()

                        // Read off the state rather than composed from free
                        // text, so what the panel says is what the hub decided.
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
}
