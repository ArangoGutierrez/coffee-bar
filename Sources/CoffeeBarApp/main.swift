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
        model.startMonitoring()
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
