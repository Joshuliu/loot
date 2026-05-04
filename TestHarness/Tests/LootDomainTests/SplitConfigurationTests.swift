import XCTest
@testable import LootDomain

final class SplitModeTests: XCTestCase {

    func testRawValues() {
        XCTAssertEqual(SplitMode.equally.rawValue, "equally")
        XCTAssertEqual(SplitMode.byItems.rawValue, "byItems")
        XCTAssertEqual(SplitMode.custom.rawValue, "custom")
    }

    func testAllCases() {
        XCTAssertEqual(SplitMode.allCases.count, 3)
        XCTAssertTrue(SplitMode.allCases.contains(.equally))
        XCTAssertTrue(SplitMode.allCases.contains(.byItems))
        XCTAssertTrue(SplitMode.allCases.contains(.custom))
    }

    func testCodableRoundTrip() throws {
        for mode in SplitMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(SplitMode.self, from: data)
            XCTAssertEqual(decoded, mode)
        }
    }
}

final class SplitConfigurationTests: XCTestCase {

    private func alice() -> Person { Person(id: PersonID("alice"), displayName: "Alice", userId: "kc-alice") }
    private func bob() -> Person { Person(id: PersonID("bob"), displayName: "Bob", userId: "kc-bob") }
    private func carol() -> Person { Person(id: PersonID("carol"), displayName: "Carol", userId: nil) }

    func testBasicConstruction() {
        let config = SplitConfiguration(
            participants: [alice(), bob()],
            includedIDs: [PersonID("alice"), PersonID("bob")],
            payerID: PersonID("alice"),
            mode: .equally
        )
        XCTAssertEqual(config.participants.count, 2)
        XCTAssertEqual(config.includedIDs.count, 2)
        XCTAssertEqual(config.payerID, PersonID("alice"))
        XCTAssertEqual(config.mode, .equally)
        XCTAssertNil(config.customCents)
        XCTAssertTrue(config.paid.isEmpty)
    }

    func testDefaultEquallyHelper() throws {
        let config = try XCTUnwrap(SplitConfiguration.defaultEqually(participants: [alice(), bob(), carol()]))
        XCTAssertEqual(config.participants.count, 3)
        XCTAssertEqual(config.includedIDs.count, 3)
        XCTAssertEqual(config.payerID, PersonID("alice"))
        XCTAssertEqual(config.mode, .equally)
    }

    func testDefaultEquallyEmptyReturnsNil() {
        XCTAssertNil(SplitConfiguration.defaultEqually(participants: []))
    }

    func testIncludedParticipantsPreservesOrder() {
        let config = SplitConfiguration(
            participants: [alice(), bob(), carol()],
            includedIDs: [PersonID("carol"), PersonID("alice")],   // out of insertion order
            payerID: PersonID("alice"),
            mode: .equally
        )
        XCTAssertEqual(config.includedParticipants.map(\.id.rawValue), ["alice", "carol"])
    }

    func testIncludedParticipantsExcludesUnincluded() {
        let config = SplitConfiguration(
            participants: [alice(), bob()],
            includedIDs: [PersonID("alice")],
            payerID: PersonID("alice"),
            mode: .equally
        )
        XCTAssertEqual(config.includedParticipants.map(\.id.rawValue), ["alice"])
    }

    func testIsValidWhenIncludedAndPayerPresent() {
        let config = SplitConfiguration(
            participants: [alice(), bob()],
            includedIDs: [PersonID("alice")],
            payerID: PersonID("alice"),
            mode: .equally
        )
        XCTAssertTrue(config.isValid)
    }

    func testIsValidFalseWhenIncludedEmpty() {
        let config = SplitConfiguration(
            participants: [alice()],
            includedIDs: [],
            payerID: PersonID("alice"),
            mode: .equally
        )
        XCTAssertFalse(config.isValid)
    }

    func testIsValidFalseWhenPayerNotInParticipants() {
        let config = SplitConfiguration(
            participants: [alice()],
            includedIDs: [PersonID("alice")],
            payerID: PersonID("ghost"),
            mode: .equally
        )
        XCTAssertFalse(config.isValid)
    }

    func testIsIncluded() {
        let config = SplitConfiguration(
            participants: [alice(), bob()],
            includedIDs: [PersonID("alice")],
            payerID: PersonID("alice"),
            mode: .equally
        )
        XCTAssertTrue(config.isIncluded(PersonID("alice")))
        XCTAssertFalse(config.isIncluded(PersonID("bob")))
    }

    func testIsPaid() {
        let config = SplitConfiguration(
            participants: [alice(), bob()],
            includedIDs: [PersonID("alice"), PersonID("bob")],
            payerID: PersonID("alice"),
            mode: .equally,
            paid: [PersonID("bob")]
        )
        XCTAssertFalse(config.isPaid(PersonID("alice")))
        XCTAssertTrue(config.isPaid(PersonID("bob")))
    }

    func testParticipantLookup() {
        let config = SplitConfiguration(
            participants: [alice(), bob()],
            includedIDs: [PersonID("alice")],
            payerID: PersonID("alice"),
            mode: .equally
        )
        XCTAssertEqual(config.participant(PersonID("alice"))?.displayName, "Alice")
        XCTAssertNil(config.participant(PersonID("ghost")))
    }

    func testTogglingIncludedAddsParticipant() {
        let config = SplitConfiguration(
            participants: [alice(), bob()],
            includedIDs: [PersonID("alice")],
            payerID: PersonID("alice"),
            mode: .equally
        )
        let toggled = config.togglingIncluded(PersonID("bob"))
        XCTAssertTrue(toggled.isIncluded(PersonID("bob")))
        XCTAssertTrue(toggled.isIncluded(PersonID("alice")))
    }

    func testTogglingIncludedRemovesParticipant() {
        let config = SplitConfiguration(
            participants: [alice(), bob()],
            includedIDs: [PersonID("alice"), PersonID("bob")],
            payerID: PersonID("alice"),
            mode: .equally
        )
        let toggled = config.togglingIncluded(PersonID("bob"))
        XCTAssertTrue(toggled.isIncluded(PersonID("alice")))
        XCTAssertFalse(toggled.isIncluded(PersonID("bob")))
    }

    func testTogglingIncludedIgnoresUnknownPerson() {
        let config = SplitConfiguration(
            participants: [alice()],
            includedIDs: [PersonID("alice")],
            payerID: PersonID("alice"),
            mode: .equally
        )
        let toggled = config.togglingIncluded(PersonID("ghost"))
        XCTAssertEqual(toggled, config)  // unchanged
    }

    func testTogglingPaidAdds() {
        let config = SplitConfiguration(
            participants: [alice(), bob()],
            includedIDs: [PersonID("alice"), PersonID("bob")],
            payerID: PersonID("alice"),
            mode: .equally
        )
        let toggled = config.togglingPaid(PersonID("bob"))
        XCTAssertTrue(toggled.isPaid(PersonID("bob")))
    }

    func testTogglingPaidRemoves() {
        let config = SplitConfiguration(
            participants: [alice(), bob()],
            includedIDs: [PersonID("alice"), PersonID("bob")],
            payerID: PersonID("alice"),
            mode: .equally,
            paid: [PersonID("bob")]
        )
        let toggled = config.togglingPaid(PersonID("bob"))
        XCTAssertFalse(toggled.isPaid(PersonID("bob")))
    }

    func testTogglingPaidIgnoresUnknownPerson() {
        let config = SplitConfiguration(
            participants: [alice()],
            includedIDs: [PersonID("alice")],
            payerID: PersonID("alice"),
            mode: .equally
        )
        let toggled = config.togglingPaid(PersonID("ghost"))
        XCTAssertEqual(toggled, config)
    }

    func testCustomCentsRoundTrip() throws {
        let config = SplitConfiguration(
            participants: [alice(), bob()],
            includedIDs: [PersonID("alice"), PersonID("bob")],
            payerID: PersonID("alice"),
            mode: .custom,
            customCents: [PersonID("alice"): 1000, PersonID("bob"): 500]
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SplitConfiguration.self, from: data)
        XCTAssertEqual(decoded.customCents?[PersonID("alice")], 1000)
        XCTAssertEqual(decoded.customCents?[PersonID("bob")], 500)
    }

    func testCodableRoundTripFull() throws {
        let original = SplitConfiguration(
            participants: [alice(), bob(), carol()],
            includedIDs: [PersonID("alice"), PersonID("carol")],
            payerID: PersonID("alice"),
            mode: .byItems,
            customCents: nil,
            paid: [PersonID("carol")]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SplitConfiguration.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
