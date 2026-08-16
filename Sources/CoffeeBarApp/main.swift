// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import Foundation
import CoffeeBarUI

// `import AppKit` is explicit for `NSApplication.willTerminateNotification`,
// and `import Foundation` for `NotificationCenter` and `NSLog`. Do not rely on
// SwiftUI re-exporting either — `PanelView.swift` states the same rule.

/// The menu-bar app.
///
/// Named `CoffeeBarMenuBarApp` rather than `CoffeeBarApp`: a type whose name
/// equals its module's name puts `CoffeeBarApp.main()` on a lookup ambiguity
/// between the type and the module.
struct CoffeeBarMenuBarApp: App {
    @State private var model: ServingModel

    /// The typed route to the `Settings` scene below, and the reason the
    /// first-run quick start reaches anybody at all.
    ///
    /// THE ALTERNATIVE WAS BUILT AND MEASURED, and it does not work.
    /// `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`
    /// is the AppKit spelling, and it is the obvious one from `init()` where
    /// there is no view to hold an Environment. A probe bundle on macOS 26.5
    /// sent it three ways — synchronously from `App.init`, deferred to the next
    /// turn of the main loop, and from the notification AppKit posts once
    /// launching has finished — and every one of them returned TRUE while the
    /// Settings scene's content never appeared. The same probe called
    /// `openSettings()` and the window came up.
    /// `PanelView.swift` records the selector as a string that "compiles on
    /// every OS and works on some"; this is one it does not work on, and it
    /// fails by reporting success.
    ///
    /// `@Environment` in an `App` rather than in a `View`, which is the part
    /// that is not obvious: it compiles, and the action is live by the time the
    /// scene modifier below runs. Measured, not assumed.
    @Environment(\.openSettings) private var openSettings

    init() {
        // THE composition root for process demotion, and the reason
        // `ProcGovernor` now has a production caller at all. Everything it
        // needs — the running applications, the frontmost application, this
        // process's own identity and its ancestor chain — is live state only a
        // running app can measure, which is why `DemotionPolicy` takes values
        // and decides nothing for itself.
        //
        // Built HERE and handed down. `ServingModel` defaults this seam to
        // `nil`, deliberately: a null governance demotes nothing, which is the
        // product's documented default, and a real default would point every
        // check in the package at the user's own demotion journal.
        // `theAppComposesTheProcessGovernanceAndRecoversAtLaunchAndOnQuit` reads
        // this file for all four calls below, because SwiftPM treats
        // `main.swift` as top-level code that no test target can import. It
        // holds the launch restore and the terminate restore SEPARATELY: they
        // are the same method name, so one guard reading for that name once was
        // satisfied by either call on its own.
        let model = ServingModel(governance: ProcessGovernance())

        // Undo whatever an EARLIER run left demoted, before this one can demote
        // anything.
        //
        // Here rather than in the view, for the reason `startMonitoring` is
        // here: `MenuBarExtra` with `.menuBarExtraStyle(.window)` builds its
        // content only while the panel is open, so a recovery driven from
        // `PanelView` would not run until the user opened the panel — and a
        // user whose Slack is still on the E-cores has no reason to open it.
        //
        // Here rather than in `ServingModel.init`, because this is a statement
        // about the PROCESS and not about a model. `App` may be built twice —
        // the leak note in `ServingModel.swift` records that — and a second
        // recovery costs nothing: the first one emptied the journal, so the
        // second finds no entry and touches no process.
        //
        // Before `startMonitoring`, so the journal is clear before the first
        // `refresh()` can append to it.
        model.restoreDemotedProcesses()

        // And again on the way out, so a clean quit does not leave a process on
        // the E-cores until the next launch. The Quit button calls
        // `NSApplication.shared.terminate`, which posts this.
        //
        // `queue: .main` puts the block on the main thread, which is what makes
        // `assumeIsolated` sound here — the same reasoning the ingest callback
        // uses. `model` is captured STRONGLY on purpose: this block needs the
        // object alive to do the restore, and the process is ending anyway.
        //
        // LIMIT, stated rather than hidden: a `SIGKILL` posts nothing, so this
        // covers the clean exit only. The crash case is what the journal and
        // the launch recovery above exist for, and `docs/ACCEPTED-RISKS.md`
        // records the window between them.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { model.restoreDemotedProcesses() }
        }

        // Started here, exactly once, rather than from the panel.
        // `MenuBarExtra` with `.menuBarExtraStyle(.window)` builds its content
        // only while the panel is open, so a ticker owned by the view stops the
        // moment the user closes it — and a battery floor that is enforced only
        // while the panel is open does not enforce the floor.
        // Ingest failing must not stop the app launching, and the ticker is
        // installed before the socket for exactly this reason: the battery
        // floor still gets enforced when the socket is refused. The likeliest
        // refusal is a second instance already answering on the path.
        //
        // This log line is no longer the only report. `startMonitoring`
        // records the reason on the model on its way past, and the panel
        // renders it as `ingestAdvisory` — a socket refused here used to be
        // visible in Console.app and nowhere else, which for a menu-bar app is
        // the same as invisible. The log stays for the case where the user
        // cannot open the panel at all.
        // Not retried, and that is a decision rather than an omission.
        // `listenerStarted` is set only on success, so `startMonitoring` is
        // already safe to call a second time — nothing calls it. What a retry
        // still needs is a way to tell a socket THIS process leaked from one
        // another process owns. `ServingModel` has no cleanup path for its
        // listener, so an orphaned model's `NWListener` keeps the socket for
        // the life of the process, and `occupant()` connect-probes that socket
        // and reports `.live`. A retry would then fail for ever while the panel
        // told the user to go quit a second instance that does not exist —
        // measured — and a confident wrong explanation is a worse failure than
        // the silence it replaces. The check belongs in `IngestListener`, not
        // here. Read the leak note in `ServingModel.swift` before adding one.
        do {
            try model.startMonitoring()
        } catch {
            NSLog("coffee-bar: ingest did not start: \(error)")
        }

        // IS THERE A NEWER coffee-bar — the automatic half of issue #29, and
        // the ONE outbound request this application makes.
        //
        // HERE NOW, and it was in `PreferencesView.onAppear` until this commit.
        // That file booked the move itself: "WHEN THE PANEL GAINS ITS OWN COPY
        // (the deferred half of issue #29) this moves to App.init, because the
        // answer will then be visible without opening anything. Until it is,
        // moving it early would be egress with no reader." The panel now
        // renders the verdict, the time and a Check now button, so the reader
        // exists and the request belongs where every other launch-time job is.
        //
        // IT MOVED RATHER THAN BEING ADDED. Two callers of one interval-gated
        // check is the duplicate scheduling the issue rules out: each can make
        // the request the other's stamp was meant to have covered. `.onAppear`
        // was also never the right hook — it fires when the window is CREATED
        // and not when an existing one is re-presented, which is the whole of
        // issue #126.
        //
        // `IfDue` and never `checkForUpdates()`. This runs on every launch and
        // a menu-bar app is launched at login; the unconditional call would
        // turn a stated daily check into a request per launch. The interval is
        // enforced against a stamp in the user's settings, so it survives a
        // relaunch — this process holds no timer for it, and a coffee-bar
        // sitting in the menu bar for a week makes no request at all.
        //
        // A `Task` because the call is `async` and `init` is not, and nothing
        // waits on it: a check that cannot reach the network must not delay the
        // menu bar appearing. Failure is silent by design — the model records
        // a verdict the two surfaces render, and there is no banner and no
        // retry.
        Task { await model.checkForUpdatesIfDue() }

        _model = State(initialValue: model)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuBarLabel(isServing: model.isServing)
        }
        .menuBarExtraStyle(.window)

        // The Preferences window, as a `Settings` scene rather than a window
        // this app opens for itself.
        //
        // `Settings` is what puts the standard ⌘, on it and what makes
        // `SettingsLink` in the panel work at all; it also gives the window one
        // identity, so the keyboard route and the panel button raise the SAME
        // window instead of a second copy.
        //
        // The same `model` the panel holds, not a second one. Two models would
        // each own a listener and a ticker, and a setting changed in this
        // window would not reach the one enforcing the battery floor.
        Settings {
            PreferencesView(model: model)
        }
        // NO `.windowResizability(.contentMinSize)` HERE, and that absence is
        // measured rather than an oversight. It is the obvious reach for a
        // pinned settings window, it was tried, and it changes NOTHING for this
        // scene: with it the window still reported `AXSize.settable=false`, and
        // with the style mask fixed in `PreferencesView` it reports
        // `AXSize.settable=true` WITHOUT it. Both directions were built and
        // measured. A modifier that moves no measurement is a claim the next
        // reader has to re-test, so it is not here.
        //
        // What does unpin the window is the style mask, in `PreferencesView`.
        //
        // The size the window OPENS at. `idealWidth`/`idealHeight` on the
        // content did not decide it: with the flexible frame in place the
        // window came up at 900x450, which is SwiftUI's own fallback and far
        // too wide — a 900-point row stretches the battery-floor slider across
        // the window and pushes the two buttons an inch from the path they act
        // on.
        //
        // THE WIDTH IS THE MAINTAINER'S, THE HEIGHT IS THE MEASUREMENT'S.
        // This opened at 520 first and his verdict was "you over did the width,
        // the height is ok now", so the width is back to the 420 this window
        // has always shipped at. His complaint was vertical scrolling; widening
        // it was never part of the fix, and `maxWidth: .infinity` on the
        // content means anyone who wants it wider drags it once and macOS
        // remembers.
        //
        // 560 high is derived from the measurement, not chosen to look round.
        // Content ran to 441 points inside a 360-point viewport, and
        // `hookAdvisory` was NIL when that was measured, so an unwired tool
        // adds a caption the height budget has to carry: the comparable caption
        // below it measures 52 points plus 18 of stack spacing, and 441 + 70 is
        // 511.
        //
        // This is a DEFAULT, and only the first launch sees it. Once the window
        // is resizable macOS autosaves the frame, so a user who drags it keeps
        // their size — which is the point of the whole change.
        .defaultSize(width: 420, height: 560)
        // ASK THE THREE QUESTIONS AT LAUNCH (issue #52, acceptance bullet 1).
        //
        // The wizard has been built, bound and gated since #125, and until now
        // nothing opened the window it is presented in. coffee-bar is
        // `LSUIElement`: no Dock icon, no menu bar of its own, and a `Settings`
        // scene that stays shut until somebody finds the panel and clicks
        // Preferences. A first-run user who never does was never asked
        // anything — which is the complaint issue #52 opens with, still true of
        // the build that closed most of it.
        //
        // A SCENE MODIFIER, and there is no earlier hook that works.
        // `App.init()` runs before the scenes are installed and has no
        // Environment, so the action is not callable there; a `View`'s
        // `onAppear` needs a view, and the only two this app has are the panel
        // (built only while it is open) and the window this would be opening.
        // `onChange(initial: true)` on the scene runs once at launch — measured
        // firing in a probe bundle on every route tried, including the two
        // where nothing else happened.
        //
        // `initial: true` IS THE WHOLE TRIGGER, not a refinement of it.
        // `quickStartPending` is seeded in `ServingModel.init` and does not
        // change again before the page would be shown, so without it this waits
        // for a change that never comes and asks nobody. That is the shape this
        // feature already failed in once.
        //
        // AND THE CONDITION IS WHAT SPARES THE EXISTING USER. `onChange` fires
        // on every subsequent change too, and finishing the quick start is a
        // change: `completeQuickStart()` flips the value to false, this block
        // runs again, and without the `if` it would re-open the window the user
        // has just finished with. `quickStartPending` is the model's gate and
        // the only one — a second condition here would be a second place the
        // page can be switched off that no check in the package reads.
        //
        // Nothing here decides WHETHER to ask. That decision is
        // `quickStartPending`, in `ServingModel`, where a test target can reach
        // it: reading it writes nothing, an answered user reads false, and
        // "Ask me later" is recoverable next launch. This is the wire, not the
        // policy.
        .onChange(of: model.quickStartPending, initial: true) {
            if model.quickStartPending { openSettings() }
        }
    }
}

// SwiftPM treats `main.swift` as top-level code, which rules out `@main`.
// `App.main()` is the documented equivalent.
CoffeeBarMenuBarApp.main()
