import Testing
import CoffeeBarCore
@testable import CoffeeBarPower

@Test func powerTargetLinksAgainstCore() {
    // The Probe -> Power -> Core direction is a build-graph invariant, not a
    // convention. If CoffeeBarPower ever loses its CoffeeBarCore dependency,
    // this file stops compiling and the suite goes red.
    #expect(SpikeID.baseline.rawValue == "baseline")
}
