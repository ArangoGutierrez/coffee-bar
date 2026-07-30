// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import CoffeeBarUI

/// The menu-bar app.
///
/// Named `CoffeeBarMenuBarApp` rather than `CoffeeBarApp`: a type whose name
/// equals its module's name puts `CoffeeBarApp.main()` on a lookup ambiguity
/// between the type and the module.
struct CoffeeBarMenuBarApp: App {
    @State private var model: ServingModel

    init() {
        let model = ServingModel()
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
