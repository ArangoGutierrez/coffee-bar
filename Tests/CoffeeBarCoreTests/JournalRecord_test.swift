import Testing
import Foundation
@testable import CoffeeBarCore

private let provenance = ArmProvenance(
    pid: 4242, binaryPath: "/usr/local/bin/coffee-bar-probe", uid: 501)

@Test func ttlIsClampedToEightHoursOnInit() {
    let r = JournalRecord(intent: .sleepDisabled, priorValue: false,
                          setAt: Date(timeIntervalSince1970: 0),
                          ttlSeconds: 999_999_999, armedBy: provenance)
    #expect(r.ttlSeconds == 28_800)
}

@Test func ttlIsClampedToEightHoursOnDecode() throws {
    // The bug this catches: clamping only in init lets a hand-edited or
    // corrupted journal on disk hold SleepDisabled for 31 years.
    let json = """
    {"schemaVersion":1,"intent":"sleepDisabled","priorValue":false,
     "setAt":0,"ttlSeconds":999999999,
     "armedBy":{"pid":4242,"binaryPath":"/x","uid":501}}
    """
    let r = try JSONDecoder().decode(JournalRecord.self, from: Data(json.utf8))
    #expect(r.ttlSeconds == 28_800)
}

@Test func ttlBelowOneIsRaisedToOne() {
    let r = JournalRecord(intent: .sleepDisabled, priorValue: false,
                          setAt: Date(timeIntervalSince1970: 0),
                          ttlSeconds: -5, armedBy: provenance)
    #expect(r.ttlSeconds == 1)
}

@Test func expiryIsSetAtPlusClampedTTL() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    let r = JournalRecord(intent: .sleepDisabled, priorValue: false,
                          setAt: base, ttlSeconds: 900, armedBy: provenance)
    #expect(r.expiry == base.addingTimeInterval(900))
}

@Test func expiryUsesTheClampedTTLNotTheRequestedOne() {
    // Requested 999999999s; clamped to 28800. If expiry were computed from
    // the requested value the journal would appear valid for 31 years.
    let base = Date(timeIntervalSince1970: 1_000_000)
    let r = JournalRecord(intent: .sleepDisabled, priorValue: false,
                          setAt: base, ttlSeconds: 999_999_999,
                          armedBy: provenance)
    #expect(r.expiry == base.addingTimeInterval(28_800))
}

@Test func decodePathAlsoRaisesNonPositiveTTLToOne() throws {
    let json = """
    {"schemaVersion":1,"intent":"sleepDisabled","priorValue":false,
     "setAt":0,"ttlSeconds":-5,
     "armedBy":{"pid":1,"binaryPath":"/x","uid":501}}
    """
    let r = try JSONDecoder().decode(JournalRecord.self, from: Data(json.utf8))
    #expect(r.ttlSeconds == 1)
}

@Test func schemaVersionIsReadFromTheFileNotAssumed() throws {
    // If this is pinned to currentSchemaVersion, decide()'s
    // .revert(.unknownSchema) becomes unreachable for every on-disk
    // journal, and nothing else in the suite notices.
    let json = """
    {"schemaVersion":99,"intent":"sleepDisabled","priorValue":false,
     "setAt":0,"ttlSeconds":900,
     "armedBy":{"pid":1,"binaryPath":"/x","uid":501}}
    """
    let r = try JSONDecoder().decode(JournalRecord.self, from: Data(json.utf8))
    #expect(r.schemaVersion == 99)
}

@Test func missingPriorValueIsRejectedNotDefaulted() {
    // D6: priorValue is STORED, never assumed. Defaulting it to false
    // silently clobbers a user who had disablesleep set on purpose.
    let json = """
    {"schemaVersion":1,"intent":"sleepDisabled",
     "setAt":0,"ttlSeconds":900,
     "armedBy":{"pid":1,"binaryPath":"/x","uid":501}}
    """
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(JournalRecord.self, from: Data(json.utf8))
    }
}

@Test func priorValueSurvivesRoundTrip() throws {
    // Spec D6: if the user deliberately had disablesleep on, we restore THAT.
    let r = JournalRecord(intent: .sleepDisabled, priorValue: true,
                          setAt: Date(timeIntervalSince1970: 5),
                          ttlSeconds: 60, armedBy: provenance)
    let decoded = try JSONDecoder().decode(
        JournalRecord.self, from: JSONEncoder().encode(r))
    #expect(decoded.priorValue == true)
    #expect(decoded == r)
}
