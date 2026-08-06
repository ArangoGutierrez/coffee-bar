// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import Foundation

// `import Foundation` is explicit for `Bundle.main.infoDictionary`. Do not rely
// on SwiftUI re-exporting it — `PanelView.swift` states the same rule.

/// The Preferences window's whole content.
///
/// One scrolling page with headed sections rather than tabs: four short groups
/// do not earn a second navigation layer.
///
/// The version line is here AND in the panel, deliberately. Every surface states
/// the running version, and both read `PanelView.versionLine(from:)` — one seam,
/// so the two can never disagree.
public struct PreferencesView: View {
    @Bindable var model: ServingModel

    public init(model: ServingModel) { self.model = model }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(PanelView.versionLine(from: Bundle.main.infoDictionary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 420, height: 360)
    }
}
