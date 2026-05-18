import XCTest
@testable import LootDomain

// SplitDraft is in LootDomain via the Domain symlink. These tests exercise
// the Codable contract: modern shape round-trips, and the legacy SplitGuest
// shape (pre-Phase-2.8 SessionPersistence JSON) decodes into the new model.

final class SplitDraftCodableTests: XCTestCase {

    // MARK: - Modern shape round-trip

    func testRoundTripPreservesAllFields() throws {
        let alice = Person.identified(userId: "alice-uid", displayName: "Alice")
        let bob = Person.identified(userId: "bob-uid", displayName: "Bob")
        let charlie = Person.newGuest(displayName: "Charlie")

        let original = SplitDraft(
            guests: [alice, bob, charlie],
            includedIDs: [alice.id, bob.id],
            payerID: alice.id,
            mode: .byItems,
            totalCents: 4500,
            perGuestCents: [2250, 2250],
            items: [
                SplitDraft.Item(
                    id: UUID(),
                    label: "Pizza",
                    priceCents: 3000,
                    assignedGuestIds: [alice.id, bob.id]
                ),
                SplitDraft.Item(
                    id: UUID(),
                    label: "Drinks",
                    priceCents: 1500,
                    assignedGuestIds: [bob.id]
                )
            ],
            feesCents: 100,
            discountCents: 50,
            taxCents: 200,
            tipCents: 700
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SplitDraft.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testIncludedIDsRoundTrips() throws {
        let alice = Person.identified(userId: "alice", displayName: "Alice")
        let bob = Person.identified(userId: "bob", displayName: "Bob")
        let original = SplitDraft(
            guests: [alice, bob],
            includedIDs: [alice.id],     // bob excluded
            payerID: alice.id,
            mode: .equally,
            totalCents: 1000,
            perGuestCents: [1000],
            items: [],
            feesCents: 0, discountCents: 0, taxCents: 0, tipCents: 0
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SplitDraft.self, from: data)
        XCTAssertEqual(decoded.includedIDs, [alice.id])
        XCTAssertFalse(decoded.includedIDs.contains(bob.id))
    }

    func testItemAssigneesRoundTripAsPersonID() throws {
        let alice = Person.identified(userId: "alice", displayName: "Alice")
        let item = SplitDraft.Item(
            id: UUID(),
            label: "Pizza",
            priceCents: 1500,
            assignedGuestIds: [alice.id]
        )
        let draft = SplitDraft(
            guests: [alice],
            payerID: alice.id,
            mode: .byItems,
            totalCents: 1500,
            perGuestCents: [1500],
            items: [item],
            feesCents: 0, discountCents: 0, taxCents: 0, tipCents: 0
        )
        let data = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(SplitDraft.self, from: data)
        XCTAssertEqual(decoded.items.first?.assignedGuestIds, [alice.id])
    }

    func testIncludedGuestsHelperFiltersByIncludedIDs() {
        let alice = Person.identified(userId: "alice", displayName: "Alice")
        let bob = Person.identified(userId: "bob", displayName: "Bob")
        let draft = SplitDraft(
            guests: [alice, bob],
            includedIDs: [alice.id],
            payerID: alice.id,
            mode: .equally,
            totalCents: 1000,
            perGuestCents: [1000],
            items: [],
            feesCents: 0, discountCents: 0, taxCents: 0, tipCents: 0
        )
        XCTAssertEqual(draft.includedGuests.map(\.id), [alice.id])
    }

    func testDefaultIncludedIDsFromGuests() {
        let alice = Person.identified(userId: "alice", displayName: "Alice")
        let bob = Person.identified(userId: "bob", displayName: "Bob")
        // Pass nil for includedIDs — should default to "everyone included".
        let draft = SplitDraft(
            guests: [alice, bob],
            includedIDs: nil,
            payerID: alice.id,
            mode: .equally,
            totalCents: 1000,
            perGuestCents: [1000, 0],
            items: [],
            feesCents: 0, discountCents: 0, taxCents: 0, tipCents: 0
        )
        XCTAssertEqual(draft.includedIDs, [alice.id, bob.id])
    }

    // MARK: - Legacy session JSON decode (pre-Phase-2.8 shape)

    func testDecodesLegacySplitGuestShape() throws {
        // Mirrors the JSON SessionPersistence wrote before Phase 2.8: each
        // guest is `{id, name, isIncluded, isMe, uid}`, payer is
        // `payerGuestId: <UUID>`, no top-level `includedIDs` field.
        let aliceUUID = UUID()
        let bobUUID = UUID()
        let json = """
        {
          "guests": [
            {"id": "\(aliceUUID.uuidString)", "name": "Alice", "isIncluded": true, "isMe": true, "uid": "alice-uid"},
            {"id": "\(bobUUID.uuidString)", "name": "Bob", "isIncluded": false, "isMe": false, "uid": "bob-uid"}
          ],
          "payerGuestId": "\(aliceUUID.uuidString)",
          "mode": "Split Equally",
          "totalCents": 2000,
          "perGuestCents": [2000],
          "items": [],
          "feesCents": 0,
          "discountCents": 0,
          "taxCents": 0,
          "tipCents": 0
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SplitDraft.self, from: data)

        // Guest list should have both Persons, mapped from legacy IDs.
        XCTAssertEqual(decoded.guests.count, 2)
        XCTAssertEqual(decoded.guests[0].displayName, "Alice")
        XCTAssertEqual(decoded.guests[0].userId, "alice-uid")
        XCTAssertEqual(decoded.guests[1].displayName, "Bob")
        XCTAssertEqual(decoded.guests[1].userId, "bob-uid")

        // PersonIDs derive from the legacy UUID strings.
        XCTAssertEqual(decoded.guests[0].id.rawValue, aliceUUID.uuidString)
        XCTAssertEqual(decoded.guests[1].id.rawValue, bobUUID.uuidString)

        // includedIDs reconstructed from per-guest isIncluded.
        XCTAssertTrue(decoded.includedIDs.contains(decoded.guests[0].id))
        XCTAssertFalse(decoded.includedIDs.contains(decoded.guests[1].id))

        // payerID derived from the legacy payerGuestId UUID.
        XCTAssertEqual(decoded.payerID.rawValue, aliceUUID.uuidString)

        XCTAssertEqual(decoded.mode, .equally)
        XCTAssertEqual(decoded.totalCents, 2000)
    }

    func testLegacyDecodeWithMissingUidProducesAnonymousGuest() throws {
        // A pre-Phase-2.8 anonymous guest had `"uid": null`. After decode the
        // Person should have userId == nil and a PersonID derived from the
        // legacy UUID (so byItems assignments still resolve).
        let guestUUID = UUID()
        let json = """
        {
          "guests": [
            {"id": "\(guestUUID.uuidString)", "name": "", "isIncluded": true, "isMe": false, "uid": null}
          ],
          "payerGuestId": "\(guestUUID.uuidString)",
          "mode": "Custom Split",
          "totalCents": 0,
          "perGuestCents": [0],
          "items": [],
          "feesCents": 0,
          "discountCents": 0,
          "taxCents": 0,
          "tipCents": 0
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SplitDraft.self, from: data)
        XCTAssertEqual(decoded.guests.count, 1)
        XCTAssertNil(decoded.guests[0].userId)
        XCTAssertEqual(decoded.guests[0].id.rawValue, guestUUID.uuidString)
        XCTAssertTrue(decoded.includedIDs.contains(decoded.guests[0].id))
    }

    // MARK: - PersonID stability sanity

    func testIdentifiedPersonRoundTripsToSamePersonID() throws {
        // Re-encoding then decoding an identified Person preserves the
        // PersonID exactly — this is the invariant the wire boundary relies
        // on for "Me" identity to survive bubble round-trips.
        let original = Person.identified(userId: "stable-uid", displayName: "Me")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Person.self, from: data)
        XCTAssertEqual(decoded.id.rawValue, "stable-uid")
        XCTAssertEqual(decoded.userId, "stable-uid")
    }
}
