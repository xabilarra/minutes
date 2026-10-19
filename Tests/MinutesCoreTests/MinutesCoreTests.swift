import Testing
@testable import MinutesCore

@Test func moduleVersionIsSet() {
    #expect(!MinutesCore.version.isEmpty)
}
