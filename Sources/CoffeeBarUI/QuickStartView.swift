// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import CoffeeBarCore

// `import CoffeeBarCore` is explicit for `AgentTool`, `BatteryFloor` and
// `HookHealth`. Do not rely on SwiftUI re-exporting any of them —
// `PanelView.swift` states the same rule.

/// The first-run quick start (issue #52): three questions, then out of the way.
///
/// **It is also the UPGRADE experience.** It is presented once to everyone
/// rather than only to a user with no settings, which is why every control here
/// is bound to a value the user may already have chosen.
///
/// EVERY CONTROL BINDS TO `ServingModel`, and none of them holds a copy. That is
/// what makes two things true at once and neither is a coincidence:
///
///   1. **Pre-filling is free and cannot write.** The page shows what the
///      getters report, and a getter writes nothing. There is no seeding step to
///      forget to leave out, so a user who clicks through without touching
///      anything keeps their 40% floor rather than being handed the product's
///      15%.
///   2. **Every answer lands on the key the Settings window writes.** These are
///      the same properties `PreferencesView` binds to, so the wizard has no
///      write path of its own to spell a key differently in. A key is a STORED
///      FORMAT — `SettingsKey` says so — and a second spelling works until the
///      app restarts and then reverts with nothing to report.
///
/// A `@State` mirror of any answer would give up both.
/// `theQuickStartPageAsksAllThreeQuestionsThroughTheModel` refuses one.
///
/// THREE QUESTIONS AND NO MORE. `quietEverythingElse` and the lid-closed hold
/// are settings, not first-run questions: the first does nothing until a user
/// has named a demotable process, and the second configures a mode this process
/// cannot arm. Both are in the window behind this page, where a user meets them
/// after coffee-bar is already working.
///
/// Every sentence comes from `ServingModel` with none composed here — M1 design
/// §5.4 forbids asserting on rendered AppKit text, so copy written in a view is
/// copy no check reads.
public struct QuickStartView: View {
    @Bindable var model: ServingModel

    public init(model: ServingModel) { self.model = model }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(ServingModel.quickStartIntro)
                    .fixedSize(horizontal: false, vertical: true)

                // The display question. The picker is the one `PreferencesView`
                // draws, labels included, because they are the same question and
                // two wordings of it would be two things for the user to
                // reconcile.
                Text(ServingModel.quickStartDisplayQuestion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Display", selection: $model.holdDisplayAwake) {
                    Text(ServingModel.displayLabel(for: false)).tag(false)
                    Text(ServingModel.displayLabel(for: true)).tag(true)
                }

                Text(ServingModel.quickStartFloorQuestion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Built OVER `BatteryFloor.permitted`, so this page holds no
                // bound of its own. It does not call `BatteryFloor.bounded` and
                // must not: bounding lives at `PowerInputs.init`, and a third
                // site is one value corrected in three places by rules that can
                // disagree. Constructing the control over the range makes an
                // out-of-range position unreachable rather than corrected.
                //
                // `floorReadout` and not `floorLabel(for:)` on the stored
                // setting, for the reason `PreferencesView` gives: the stored
                // value is unbounded, so a readout built from it would state a
                // floor the product does not enforce (issue #68). The model
                // hands over a finished string, which leaves no number here to
                // pick the wrong one of.
                HStack {
                    Slider(
                        value: Binding(
                            get: { Double(model.batteryFloorPercent) },
                            set: { model.batteryFloorPercent = Int($0) }
                        ),
                        in: Double(BatteryFloor.permitted.lowerBound)
                            ... Double(BatteryFloor.permitted.upperBound),
                        step: Double(BatteryFloor.step)
                    )
                    Text(model.floorReadout)
                        .monospacedDigit()
                }

                Text(ServingModel.quickStartToolsQuestion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Built over `AgentTool.allCases`, never over a list named here,
                // for the reason `PreferencesView`'s rows are: a page naming two
                // would leave a fourth tool arriving unaskable with every check
                // still green.
                //
                // The label is the tool's own file path, which is what
                // identifies it without a second name to drift from.
                // `settingsPath(for:)` is the one place that says where each
                // tool keeps its file.
                //
                // NO Copy and NO Reveal here, unlike the window's rows. This
                // page asks which tools the user runs; wiring them up is the
                // next thing they do, in the window behind it, and a first-run
                // page offering three buttons per row asks a beginner to choose
                // between them before they know what any of them does.
                ForEach(AgentTool.allCases, id: \.self) { tool in
                    Toggle(isOn: Binding(get: { model.advises(tool) },
                                         set: { model.setAdvises($0, for: tool) })) {
                        Text("~/" + HookHealth.settingsPath(for: tool))
                            .font(.caption)
                            .monospaced()
                    }
                }

                // BOTH EXITS, and they do different things — see
                // `completeQuickStart()` and `deferQuickStart()`. "Ask me later"
                // records nothing at all, so the page returns next launch; that
                // is the difference between "not now" and "never", and it is one
                // line away from being lost.
                //
                // Neither writes an answer. Every answer was written as the user
                // gave it, by the bindings above.
                HStack {
                    Button(ServingModel.quickStartDeferLabel) {
                        model.deferQuickStart()
                    }

                    Spacer()

                    Button(ServingModel.quickStartFinishLabel) {
                        model.completeQuickStart()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Sized to the window it is presented over, so the page does not open a
        // sheet narrower than the settings behind it. `PreferencesView` opens at
        // 420 and states why that number is the maintainer's rather than a
        // derivation; matching it keeps the two from disagreeing.
        .frame(minWidth: 420, idealWidth: 420, minHeight: 320, idealHeight: 480)
    }
}
