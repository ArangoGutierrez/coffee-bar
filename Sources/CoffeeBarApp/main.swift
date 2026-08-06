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
        _model = State(initialValue: model)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuBarLabel(isServing: model.isServing)
        }
        .menuBarExtraStyle(.window)
    }
}

// SwiftPM treats `main.swift` as top-level code, which rules out `@main`.
// `App.main()` is the documented equivalent.
CoffeeBarMenuBarApp.main()
