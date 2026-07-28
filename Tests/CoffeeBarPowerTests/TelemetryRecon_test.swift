// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarPower
@testable import CoffeeBarCore

private func scratch() -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("cb-otel-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func recon(managed: URL? = nil, user: URL? = nil,
                   codex: URL? = nil) -> TelemetryRecon {
    let missing = scratch().appendingPathComponent("absent.json")
    return TelemetryRecon(managedSettingsURL: managed ?? missing,
                          userSettingsURL: user ?? missing,
                          codexConfigURL: codex ?? missing)
}

@Test func noConfigAnywhereMeansOwnIt() {
    // Matches this machine as measured on 2026-07-27.
    #expect(recon().detectMode() == .ownIt)
}

@Test func managedSettingsForcePassiveMode() throws {
    let d = scratch()
    let managed = d.appendingPathComponent("managed-settings.json")
    try Data(#"{"env":{"OTEL_EXPORTER_OTLP_ENDPOINT":"http://corp:4318"}}"#.utf8)
        .write(to: managed)
    // Handoff §15.4: managed settings cannot be displaced, so mode 1 is
    // simply unavailable.
    #expect(recon(managed: managed).detectMode() == .passive)
}

@Test func userScopeOtelMeansFanOut() throws {
    let d = scratch()
    let user = d.appendingPathComponent("settings.json")
    try Data(#"{"env":{"OTEL_EXPORTER_OTLP_ENDPOINT":"http://localhost:4318"}}"#.utf8)
        .write(to: user)
    #expect(recon(user: user).detectMode() == .fanOut)
}

@Test func codexOtelSectionAlsoMeansFanOut() throws {
    let d = scratch()
    let codex = d.appendingPathComponent("config.toml")
    try Data("[otel]\nexporter = \"otlp-http\"\n".utf8).write(to: codex)
    #expect(recon(codex: codex).detectMode() == .fanOut)
}

@Test func managedSettingsOutrankUserSettings() throws {
    let d = scratch()
    let managed = d.appendingPathComponent("managed-settings.json")
    let user = d.appendingPathComponent("settings.json")
    try Data(#"{"env":{"OTEL_EXPORTER_OTLP_ENDPOINT":"http://corp:4318"}}"#.utf8)
        .write(to: managed)
    try Data(#"{"env":{"OTEL_EXPORTER_OTLP_ENDPOINT":"http://me:4318"}}"#.utf8)
        .write(to: user)
    #expect(recon(managed: managed, user: user).detectMode() == .passive)
}

@Test func reconResultCarriesTheModeAsEvidence() {
    let r = recon().run()
    #expect(r.id == .s8TelemetryCollision)
    #expect(r.verdict == .pass)
    #expect(r.evidence["mode"] == "ownIt")
}

/// The MDM case the whole design note exists for: this machine is managed
/// (FleetDM, Defender DLP) and can acquire a profile between two calls. A
/// verdict computed once and remembered would still claim `ownIt` after the
/// file lands, and coffee-bar would write telemetry config it is not allowed
/// to own.
@Test func detectModeIsRecomputedOnEveryCallNeverCached() throws {
    let d = scratch()
    let managed = d.appendingPathComponent("managed-settings.json")
    let subject = TelemetryRecon(
        managedSettingsURL: managed,
        userSettingsURL: d.appendingPathComponent("absent-settings.json"),
        codexConfigURL: d.appendingPathComponent("absent-config.toml"))

    #expect(subject.detectMode() == .ownIt)

    try Data(#"{"env":{"OTEL_EXPORTER_OTLP_ENDPOINT":"http://corp:4318"}}"#.utf8)
        .write(to: managed)

    #expect(subject.detectMode() == .passive)
}

/// A settings file that exists but configures no telemetry is not a collision.
/// This is the shape of `~/.claude/settings.json` on this machine, and the
/// reason the live verdict is `ownIt` rather than `fanOut`.
@Test func userSettingsWithoutOtelKeysStayOwnIt() throws {
    let d = scratch()
    let user = d.appendingPathComponent("settings.json")
    try Data(#"{"model":"opus","permissions":{"allow":[]}}"#.utf8).write(to: user)
    #expect(recon(user: user).detectMode() == .ownIt)
}

/// `[otel]` has to be a real TOML section header. A substring search would
/// read a commented-out block — or prose naming the word — as a live exporter
/// and needlessly drop coffee-bar into `fanOut`.
@Test func codexMentioningOtelOutsideASectionStaysOwnIt() throws {
    let d = scratch()
    let codex = d.appendingPathComponent("config.toml")
    try Data("""
        model = "gpt-5"
        # otel exporting is off; uncomment to enable
        # [otel]
        # exporter = "otlp-http"

        """.utf8).write(to: codex)
    #expect(recon(codex: codex).detectMode() == .ownIt)
}

/// Evidence has to describe what was inspected. Every field here is wrong for
/// a build that writes the fields out as fixed strings describing the
/// no-config case.
@Test func runEvidenceIsDerivedFromTheFilesInspected() throws {
    let d = scratch()
    let user = d.appendingPathComponent("settings.json")
    try Data(#"{"env":{"OTEL_METRICS_EXPORTER":"otlp"}}"#.utf8).write(to: user)

    let r = recon(user: user).run()

    #expect(r.evidence["mode"] == "fanOut")
    #expect(r.evidence["managedSettingsPresent"] == "false")
    #expect(r.evidence["userSettingsHasOTEL"] == "true")
    #expect(r.evidence["codexHasOtelSection"] == "false")
    #expect(r.detail == "telemetry mode: fanOut")
}

/// §15.4: when Token Tap is disabled it must SAY SO rather than show zeros.
/// The `passive` verdict is carried in both the detail line and the evidence.
@Test func passiveModeIsReportedRatherThanSilentlyImplied() throws {
    let d = scratch()
    let managed = d.appendingPathComponent("managed-settings.json")
    try Data(#"{"env":{"OTEL_EXPORTER_OTLP_ENDPOINT":"http://corp:4318"}}"#.utf8)
        .write(to: managed)

    let r = recon(managed: managed).run()

    #expect(r.evidence["mode"] == "passive")
    #expect(r.evidence["managedSettingsPresent"] == "true")
    #expect(r.detail == "telemetry mode: passive")
}
