// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

/// Placeholder anchoring the `CoffeeBarPower` target so SwiftPM can resolve
/// it. The probe implementations (journal store, `pmset` controller, spike
/// probes) land in later M0 tasks.
///
/// The import below is load-bearing: it is the Power -> Core edge. Removing
/// `CoffeeBarCore` from this target's dependencies in `Package.swift` makes
/// this file fail to compile with "no such module".
import CoffeeBarCore
