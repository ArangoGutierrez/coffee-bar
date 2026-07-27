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
