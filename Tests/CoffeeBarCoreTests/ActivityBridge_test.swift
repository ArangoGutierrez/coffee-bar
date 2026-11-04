// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

@Test func activityBridgeIsSeparateFromNativeHookSetupTools() {
    #expect(AgentTool.hookTools == [.claudeCode, .codex, .cursor])
    #expect(AgentTool.activityBridge.ingestEndpoint == "/event/activity")
    #expect(AgentTool.activityBridge.shimName == "activity")
    #expect(AgentTool.declared(byEndpoint: "/event/activity") == .activityBridge)
    #expect(AgentTool.declared(byShimName: "activity") == .activityBridge)
    #expect(HookHealth.requiredEvents(for: .activityBridge) == nil)
    #expect(HookSnippet.json(for: .activityBridge) == nil)
}

@Test func activityBridgeUsesTheNormalizedSessionEventVocabulary() {
    let start = Date(timeIntervalSince1970: 2_100_000)
    var sessions = SessionHub.apply(
        from: .activityBridge,
        HookEvent(hookEventName: "SessionStart", sessionID: "stable-session"),
        to: [], now: start)
    #expect(sessions.first?.state == .starting)

    let work = start.addingTimeInterval(1)
    sessions = SessionHub.apply(
        from: .activityBridge,
        HookEvent(hookEventName: "PreToolUse", sessionID: "stable-session"),
        to: sessions, now: work)
    #expect(sessions.first?.state == .working)

    let wait = start.addingTimeInterval(2)
    sessions = SessionHub.apply(
        from: .activityBridge,
        HookEvent(hookEventName: "Stop", sessionID: "stable-session"),
        to: sessions, now: wait)
    #expect(sessions.first?.state == .awaitingInput)

    let end = start.addingTimeInterval(3)
    sessions = SessionHub.apply(
        from: .activityBridge,
        HookEvent(hookEventName: "SessionEnd", sessionID: "stable-session"),
        to: sessions, now: end)
    #expect(sessions.first?.state == .done)
    #expect(sessions.first?.lastMessage == nil)
}
