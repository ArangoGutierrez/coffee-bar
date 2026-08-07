// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import Foundation
import CoffeeBarCore

// `import AppKit` is explicit for `NSPasteboard` and `NSWorkspace`,
// `import Foundation` for `Bundle.main.infoDictionary`, and
// `import CoffeeBarCore` for `BatteryFloor`. Do not rely on SwiftUI
// re-exporting any of them — `PanelView.swift` states the same rule.

/// The Preferences window's whole content.
///
/// One scrolling page with headed sections rather than tabs: Power, Focus and
/// Agent tools do not earn a second navigation layer.
///
/// The sections are NAMED here rather than counted. This sentence said "four
/// short groups" while the window held two, which is what a number in prose
/// does — it drifts from the code silently, and no check reads it.
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
                // The two questions about power, together, because they are
                // read together: how long a hold may last, and whether it
                // covers the screen. They arrived here from the panel, which
                // is 260pt wide and had grown four headed controls plus an
                // attention list — the floor alone wanted nine segments.
                Text("Power").font(.headline)

                // The labels come from the model, not from two literals here,
                // and that is not tidiness. Design §5.4 rules out asserting on
                // rendered AppKit text, so a label written in this file is a
                // label no check reads, while `servingSummary` describes the
                // same two states in prose that a check DOES read. The panel
                // carried these exact cases before the move.
                //
                // The label is VISIBLE here, unlike in the panel. There it sat
                // under its own `.headline` and `.labelsHidden()` because a
                // 260pt column has no room for a leading label; a settings
                // window is a form, and a form names its rows.
                Picker("Display", selection: $model.holdDisplayAwake) {
                    Text(ServingModel.displayLabel(for: false)).tag(false)
                    Text(ServingModel.displayLabel(for: true)).tag(true)
                }

                // A SLIDER, and the segmented picker it replaces is why. The
                // permitted range and step derive nine positions, and nine
                // segments across 260pt is unreadable — the defect this task
                // exists to close.
                //
                // Built OVER `BatteryFloor.permitted`, so this view holds no
                // bound of its own. It does not call `BatteryFloor.bounded`
                // and must not: bounding lives at `PowerInputs.init` and in
                // `WatchdogDecision`, and a third site is one value corrected
                // in two places by rules that can disagree. Constructing the
                // control over the range makes an out-of-range position
                // unreachable rather than corrected, which is the stronger
                // guarantee — there is nothing to correct.
                // `theFloorSliderIsBuiltOverThePolicyAndAddsNoSecondBoundingSite`
                // holds both halves.
                HStack {
                    Text("Battery floor")
                    Slider(
                        value: Binding(
                            get: { Double(model.batteryFloorPercent) },
                            set: { model.batteryFloorPercent = Int($0) }
                        ),
                        in: Double(BatteryFloor.permitted.lowerBound)
                            ... Double(BatteryFloor.permitted.upperBound),
                        step: Double(BatteryFloor.step)
                    )
                    // A slider without a readout is unreadable; the picker it
                    // replaces at least named its positions.
                    Text(ServingModel.floorLabel(for: model.batteryFloorPercent))
                        .monospacedDigit()
                }

                // Lid-closed mode: the third power question, and the only one
                // with no control anywhere in this window.
                //
                // It arrived here from the panel, where it rendered as roughly
                // 80 words in a 260pt column — a man page in a popover, issue
                // #56. This is the SHORT version; `site/docs.html` carries the
                // explanation, and the sentence names the commands rather than
                // linking, because a user who has to type `sudo` is already in
                // a terminal.
                //
                // NO CONTROL, and that is not an omission to be fixed later.
                // Arming needs root and coffee-bar never elevates its own
                // privilege (SECURITY.md, design §6.3), so a switch here would
                // have to grow an authorization prompt — the one thing the
                // security posture rules out. Same posture as the Agent tools
                // section below, which prints a snippet and refuses to write
                // the file.
                //
                // LAST IN THE SECTION, under the two real controls, because a
                // paragraph above a slider reads as instructions for the
                // slider.
                //
                // Rendered verbatim from the model with no text built here, for
                // the reason every other line in this file gives: M1 design
                // §5.4 forbids asserting on rendered AppKit text, so a sentence
                // composed in this view is a sentence no check reads. The
                // wording lives on `ServingModel.lidClosedSummary` and is
                // asserted there.
                //
                // Unconditional, unlike `hookAdvisory` below. There is no state
                // to condition it on — the journal is root-owned and this
                // process measurably cannot read it, which is half of what the
                // sentence says.
                Text(ServingModel.lidClosedSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                // Its own section and not a third row under Power, because it
                // is a different question: not how long coffee-bar holds the
                // machine, but what it does to everything that is not the
                // agent.
                //
                // The SECOND of two opt-ins, and it does nothing on its own —
                // the demotable set is empty by default, so a user who has
                // named nothing sees this switch change nothing whatever. The
                // label comes from the model for the reason the picker's do,
                // and its wording is constrained besides: macOS cannot promote
                // a process, so any label implying a speed-up is a false claim
                // (handoff §2.2).
                Text("Focus").font(.headline)

                Toggle(ServingModel.quietOthersLabel, isOn: $model.quietEverythingElse)

                // The remedy, beside the complaint. The panel already tells the
                // user which hook file it cannot confirm; until now that was
                // advice with nothing to act on, and the action it implied was
                // hand-editing JSON copied off a documentation page.
                //
                // PRINT, NEVER WRITE — design §6, and the one rule this section
                // exists under. Each of these files is shared territory, and
                // this workspace records a six-occurrence last-writer-wins
                // clobber in exactly that kind of config: coffee-bar merging
                // its own entry into a file another tool is also editing is how
                // a user loses settings they never told anyone about. The
                // snippet goes to the pasteboard, which IS the user's; the file
                // is not. `thePreferencesWindowNeverWritesAnAgentToolsSettingsFile`
                // holds that line by reading this file.
                Text("Agent tools").font(.headline)

                // The same sentence the panel carries, rendered verbatim from
                // the model with no text built here — M1 design §5.4 forbids
                // asserting on rendered AppKit text, so a sentence composed in
                // this file is a sentence no check reads. It is repeated rather
                // than moved: the panel is where the user notices the problem,
                // and this window is where they can do something about it.
                //
                // Silent when every tool is wired, for the reason the panel's
                // copy of it is silent.
                if let advisory = model.hookAdvisory {
                    Text(advisory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Built over `AgentTool.allCases`, never over a list of tools
                // named here. `hookAdvisory` above iterates the same cases, so
                // a section naming two would advise a user about a third file
                // and then offer them no way to fix it — and a fourth tool
                // would arrive uncopyable with every check still green.
                // `theCopyActionOffersEveryToolTheCheckerCanAdviseAbout` reads
                // this loop out of `body`.
                ForEach(AgentTool.allCases, id: \.self) { tool in
                    HStack {
                        // `settingsPath(for:)` is the one place that says where
                        // each tool keeps its file, and the checker, the
                        // advisory and this label all read it. A path spelled
                        // out here is a fourth spelling that can disagree with
                        // the three.
                        Text("~/" + HookHealth.settingsPath(for: tool))
                            .font(.caption)
                            .monospaced()

                        Spacer()

                        // `json(for:)` is the only public entry point, and it
                        // derives every event from `requiredEvents(for:)` — the
                        // same source the health check reads. A snippet
                        // composed here could tell the user to wire a set the
                        // checker never looks for, leaving them correctly
                        // pasted and permanently reported broken.
                        //
                        // `nil` means there is no advice to give for this tool,
                        // and the button then does nothing rather than clearing
                        // the pasteboard the user was holding something in.
                        Button("Copy hook snippet") {
                            guard let snippet = HookSnippet.json(for: tool) else { return }
                            let board = NSPasteboard.general
                            board.clearContents()
                            board.setString(snippet, forType: .string)
                        }

                        // Finder, with the file selected, rather than opening
                        // it in whatever owns the extension: the user has to
                        // merge a fragment into a file that already holds their
                        // own settings, and that is their editor's job, not
                        // ours. Selecting a file that does not exist opens its
                        // enclosing directory, which is the right answer for a
                        // user who has not set that tool up yet.
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [HookHealthReader.defaultURL(for: tool)]
                            )
                        }
                    }
                }

                Text(PanelView.versionLine(from: Bundle.main.infoDictionary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A FLEXIBLE frame, and every part of it is load-bearing. This was
        // `.frame(width: 420, height: 360)`, and a fixed frame does two things
        // to a `Settings` scene, both measured on this build rather than
        // inferred:
        //
        //   1. IT PINS THE WINDOW. Asking the window server to resize it was
        //      REFUSED — `set-to-820x900 -> 420x392` and `set-to-120x120 ->
        //      420x392` — and `AXZoomButton.AXEnabled=false`. There is no
        //      edge to drag, which is the second half of the complaint.
        //   2. IT IS TOO SHORT FOR THE CONTENT. Measured at
        //      0.1.1-44-g7d96ce2: the deepest element sat 81 points BELOW the
        //      window's bottom edge (`OVERFLOW=81`), so the version line and
        //      the third tool row were unreachable without scrolling a
        //      settings window.
        //
        // `maxWidth`/`maxHeight` at `.infinity` are what actually unpin it.
        // min and ideal alone leave the content's maximum EQUAL to its ideal,
        // and a window whose content cannot grow does not grow either — the
        // fixed frame is only the extreme case of that. The window opens at
        // the ideal size and the user can drag from there.
        //
        // THE IDEAL HEIGHT IS DERIVED FROM THE MEASUREMENT, not chosen to look
        // round. Content ran to 441 points inside a 360-point viewport, and
        // `hookAdvisory` was NIL when that was measured — every tool on this
        // machine is wired. An unwired tool renders a caption above the rows,
        // and the comparable caption below it (lid-closed, similar length)
        // measures 52 points plus 18 of stack spacing. 441 + 70 is 511, so 560
        // is the content budget with headroom, and a 560-point window is
        // unremarkable on any display this app supports.
        //
        // `minHeight` is well under the ideal ON PURPOSE. A user who shrinks
        // the window gets the `ScrollView` back, which is the right answer —
        // what was wrong was having to scroll at the DEFAULT size.
        //
        // `minWidth` is the old fixed width, so the tool rows — a path, then
        // two buttons — are never squeezed tighter than they already ship.
        .frame(
            minWidth: 420, idealWidth: 520, maxWidth: .infinity,
            minHeight: 320, idealHeight: 560, maxHeight: .infinity
        )
        // THE DRAG AFFORDANCE, and it is a second, separate thing from the
        // frame above — the frame decides what SIZE the window may take, this
        // decides whether the user may change it.
        //
        // A flexible frame is NOT enough on its own, which is the whole reason
        // this line exists. Measured on this build: with the frame above
        // already in place and no style-mask change, the window reported
        // `AXSize.settable=false` while `AXPosition.settable=true` on the same
        // window — it could be moved and not resized. A `Settings` scene is
        // created without `.resizable` in its style mask.
        //
        // `.windowResizability(.contentMinSize)` on the scene is the obvious
        // SwiftUI answer and it does NOT work here; `main.swift` records both
        // builds. This line does, and `AXSize.settable=true` with it.
        .background(HostWindowReader { $0.styleMask.insert(.resizable) })
        // TAKE THE FOREGROUND. Opening a window and becoming the active app are
        // different things, and for an `LSUIElement` process the second does not
        // follow from the first. Measured at 0.1.1-31-g7949c51: the window
        // appeared and Finder stayed frontmost — `before=Finder | after=Finder |
        // windows=[coffee-bar Settings]`. The user then gets a settings window
        // drawn over the app they were using, with a grey title bar, taking none
        // of their keystrokes.
        //
        // THE POLICY CHANGE IS WHAT MAKES IT WORK, and it is not decoration.
        // Three routes were measured on macOS 26.5 before this one, and the
        // first two do nothing whatever:
        //
        //   1. `simultaneousGesture` on the panel's `SettingsLink` — NEVER
        //      FIRES. Instrumented with a log line the run never printed, while
        //      a control line from the same build printed every time.
        //   2. `NSApp.activate(ignoringOtherApps: true)` from here under
        //      `.accessory` — synchronously, and again deferred to the next
        //      turn of the main loop with `makeKeyAndOrderFront` on the window
        //      itself. The window was in `NSApp.windows` the whole time and
        //      `keyWindow` stayed `nil`.
        //   3. This. `after=coffee-bar`, five landed runs out of five.
        //
        // macOS 14 made activation cooperative: an `.accessory` app asking for
        // the foreground is declined, which is also why
        // `activate(ignoringOtherApps:)` alone is no longer enough anywhere.
        // Becoming `.regular` for the lifetime of this window is the supported
        // way to ask.
        //
        // WHAT IT COSTS, stated rather than buried: a Dock icon appears while
        // the Preferences window is open. `onDisappear` puts the app back to
        // `.accessory` when the window closes — measured firing on close — so
        // the icon lives exactly as long as the window does and no longer. A
        // product that is menu-bar-only the rest of the time briefly is not,
        // and that is the price of a settings window the user can type into.
        //
        // `scripts/preferences-activation-acceptance.sh` is what measures this.
        // No test in the suite can: M1 design §5.4 rules out asserting on
        // rendered AppKit state, and the fault lives in the window server's
        // notion of which application is active.
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

/// Hands back the `NSWindow` that is rendering this view.
///
/// BY HIERARCHY, never by title or identifier, and that is the whole reason it
/// exists. The two usual spellings — matching `NSApp.windows` on the title
/// "coffee-bar Settings", or on SwiftUI's private
/// `com_apple_SwiftUI_Settings_window` identifier — are a localized string and
/// an implementation detail respectively. Both compile, both work today, and
/// both go silently wrong: the first in any language but English, the second
/// whenever SwiftUI renames its own window. A view's `window` property is the
/// window it is actually in.
///
/// `private` and confined to this file: this is a workaround for one window's
/// style mask, not a facility. `PreferencesView` is the only caller.
private struct HostWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        // `probe.window` is NIL here — the view has not been added to a window
        // yet when `makeNSView` returns it. One turn of the main loop later it
        // has. Reading it synchronously is the version of this that compiles,
        // never fires, and leaves the window pinned.
        DispatchQueue.main.async {
            guard let window = probe.window else { return }
            onWindow(window)
        }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
