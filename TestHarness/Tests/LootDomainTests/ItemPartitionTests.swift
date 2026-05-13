import XCTest
@testable import LootDomain

final class ItemPartitionTests: XCTestCase {

    private let alice = PersonID("alice")
    private let bob = PersonID("bob")
    private let carol = PersonID("carol")

    // MARK: - legacyAssignedGuests

    func testLegacyAssignedGuestsEmpty() {
        XCTAssertEqual(ItemPartition.legacyAssignedGuests([]), .unclaimed)
    }

    func testLegacyAssignedGuestsSingle() {
        let p = ItemPartition.legacyAssignedGuests([alice])
        XCTAssertEqual(p, .shares(denominator: 1, slots: [alice]))
    }

    func testLegacyAssignedGuestsTwo() {
        let p = ItemPartition.legacyAssignedGuests([alice, bob])
        XCTAssertEqual(p, .shares(denominator: 2, slots: [alice, bob]))
    }

    // MARK: - centsClaimed (shares)

    func testCentsClaimedFullSingleShare() {
        let p = ItemPartition.shares(denominator: 1, slots: [alice])
        XCTAssertEqual(p.centsClaimed(by: alice, priceCents: 3000), 3000)
        XCTAssertEqual(p.centsClaimed(by: bob, priceCents: 3000), 0)
    }

    func testCentsClaimedTwoEvenShares() {
        let p = ItemPartition.shares(denominator: 2, slots: [alice, bob])
        XCTAssertEqual(p.centsClaimed(by: alice, priceCents: 3000), 1500)
        XCTAssertEqual(p.centsClaimed(by: bob, priceCents: 3000), 1500)
    }

    func testCentsClaimedThreeWayUneven() {
        // A=1, B=2 → A pays 1/3, B pays 2/3 of $30
        let p = ItemPartition.shares(denominator: 3, slots: [alice, bob, bob])
        XCTAssertEqual(p.centsClaimed(by: alice, priceCents: 3000), 1000)
        XCTAssertEqual(p.centsClaimed(by: bob, priceCents: 3000), 2000)
    }

    func testCentsClaimedWithUnclaimedShares() {
        // A=1 of 3, rest unclaimed. A pays 1/3.
        let p = ItemPartition.shares(denominator: 3, slots: [alice, nil, nil])
        XCTAssertEqual(p.centsClaimed(by: alice, priceCents: 3000), 1000)
        XCTAssertEqual(p.centsClaimed(by: bob, priceCents: 3000), 0)
    }

    func testCentsClaimedRemainderDistributesToFirstSlot() {
        // $1.00 ÷ 3 = 34, 33, 33 — alice in slot 0 should get the remainder cent.
        let p = ItemPartition.shares(denominator: 3, slots: [alice, bob, carol])
        XCTAssertEqual(p.centsClaimed(by: alice, priceCents: 100), 34)
        XCTAssertEqual(p.centsClaimed(by: bob, priceCents: 100), 33)
        XCTAssertEqual(p.centsClaimed(by: carol, priceCents: 100), 33)
    }

    // MARK: - centsClaimed (custom)

    func testCentsClaimedCustom() {
        let p = ItemPartition.custom([
            CustomClaim(personID: alice, cents: 500),
            CustomClaim(personID: bob, cents: 750)
        ])
        XCTAssertEqual(p.centsClaimed(by: alice, priceCents: 2000), 500)
        XCTAssertEqual(p.centsClaimed(by: bob, priceCents: 2000), 750)
        XCTAssertEqual(p.centsClaimed(by: carol, priceCents: 2000), 0)
    }

    func testCentsClaimedCustomMultipleClaimsBySamePerson() {
        // Two custom claim entries summing for the same person.
        let p = ItemPartition.custom([
            CustomClaim(personID: alice, cents: 200),
            CustomClaim(personID: alice, cents: 300)
        ])
        XCTAssertEqual(p.centsClaimed(by: alice, priceCents: 1000), 500)
    }

    // MARK: - claimedCents

    func testClaimedCentsUnclaimed() {
        XCTAssertEqual(ItemPartition.unclaimed.claimedCents(priceCents: 1000), 0)
    }

    func testClaimedCentsSharesAllFilled() {
        let p = ItemPartition.shares(denominator: 3, slots: [alice, bob, carol])
        XCTAssertEqual(p.claimedCents(priceCents: 3000), 3000)
    }

    func testClaimedCentsSharesPartiallyFilled() {
        // Only 2 of 3 shares claimed → 2/3 of price.
        let p = ItemPartition.shares(denominator: 3, slots: [alice, bob, nil])
        XCTAssertEqual(p.claimedCents(priceCents: 3000), 2000)
    }

    func testClaimedCentsCustomPartial() {
        let p = ItemPartition.custom([
            CustomClaim(personID: alice, cents: 500),
            CustomClaim(personID: bob, cents: 750)
        ])
        XCTAssertEqual(p.claimedCents(priceCents: 2000), 1250)
    }

    func testClaimedAndUnclaimedSumToPriceForFullShares() {
        let p = ItemPartition.shares(denominator: 4, slots: [alice, bob, alice, carol])
        let claimed = p.claimedCents(priceCents: 1000)
        let unclaimed = 1000 - claimed
        XCTAssertEqual(claimed, 1000)
        XCTAssertEqual(unclaimed, 0)
    }

    // MARK: - claimerPersonIDs

    func testClaimerPersonIDsUnclaimed() {
        XCTAssertEqual(ItemPartition.unclaimed.claimerPersonIDs, [])
    }

    func testClaimerPersonIDsSharesDedup() {
        // alice in slots 0 and 2 → only one entry.
        let p = ItemPartition.shares(denominator: 3, slots: [alice, bob, alice])
        XCTAssertEqual(p.claimerPersonIDs, [alice, bob])
    }

    func testClaimerPersonIDsSkipsNilSlots() {
        let p = ItemPartition.shares(denominator: 3, slots: [alice, nil, bob])
        XCTAssertEqual(p.claimerPersonIDs, [alice, bob])
    }

    func testClaimerPersonIDsCustomDedup() {
        let p = ItemPartition.custom([
            CustomClaim(personID: alice, cents: 200),
            CustomClaim(personID: bob, cents: 300),
            CustomClaim(personID: alice, cents: 100)
        ])
        XCTAssertEqual(p.claimerPersonIDs, [alice, bob])
    }

    // MARK: - Codable round-trip

    func testCodableRoundTripUnclaimed() throws {
        let original = ItemPartition.unclaimed
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ItemPartition.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCodableRoundTripShares() throws {
        let original = ItemPartition.shares(denominator: 3, slots: [alice, nil, bob])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ItemPartition.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCodableRoundTripCustom() throws {
        let original = ItemPartition.custom([
            CustomClaim(personID: alice, cents: 500),
            CustomClaim(personID: bob, cents: 750)
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ItemPartition.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCodableSharesEncodesExpectedShape() throws {
        let p = ItemPartition.shares(denominator: 2, slots: [alice, nil])
        let data = try JSONEncoder().encode(p)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["kind"] as? String, "shares")
        XCTAssertEqual(json["denominator"] as? Int, 2)
        let slots = try XCTUnwrap(json["slots"] as? [Any])
        XCTAssertEqual(slots.count, 2)
    }

    // MARK: - SplitDraft.Item Codable backward compat

    func testSplitDraftItemDecodesLegacyAssignedGuestIds() throws {
        let id = UUID()
        let json = """
        {
            "id": "\(id.uuidString)",
            "label": "Pizza",
            "priceCents": 3000,
            "assignedGuestIds": ["alice", "bob"]
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(SplitDraft.Item.self, from: json)
        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.priceCents, 3000)
        XCTAssertEqual(item.partition, .shares(denominator: 2, slots: [alice, bob]))
    }

    func testSplitDraftItemDecodesEmptyLegacyAsUnclaimed() throws {
        let id = UUID()
        let json = """
        {
            "id": "\(id.uuidString)",
            "label": "Pizza",
            "priceCents": 3000,
            "assignedGuestIds": []
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(SplitDraft.Item.self, from: json)
        XCTAssertEqual(item.partition, .unclaimed)
    }

    func testSplitDraftItemPrefersPartitionOverLegacy() throws {
        // When both fields are present, the new partition wins.
        let id = UUID()
        let json = """
        {
            "id": "\(id.uuidString)",
            "label": "Pizza",
            "priceCents": 3000,
            "assignedGuestIds": ["alice"],
            "partition": {
                "kind": "shares",
                "denominator": 3,
                "slots": ["alice", "bob", null]
            }
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(SplitDraft.Item.self, from: json)
        XCTAssertEqual(item.partition, .shares(denominator: 3, slots: [alice, bob, nil]))
    }

    func testSplitDraftItemDecodesMissingFieldsAsUnclaimed() throws {
        let id = UUID()
        let json = """
        {
            "id": "\(id.uuidString)",
            "label": "Pizza",
            "priceCents": 3000
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(SplitDraft.Item.self, from: json)
        XCTAssertEqual(item.partition, .unclaimed)
    }

    func testSplitDraftItemAssignedGuestIdsConvenienceInitMapsToShares() {
        let item = SplitDraft.Item(
            id: UUID(),
            label: "Pizza",
            priceCents: 3000,
            assignedGuestIds: [alice, bob]
        )
        XCTAssertEqual(item.partition, .shares(denominator: 2, slots: [alice, bob]))
        // And the read accessor returns the deduped list.
        XCTAssertEqual(item.assignedGuestIds, [alice, bob])
    }

    func testSplitDraftItemAssignedGuestIdsAccessorDedupsRepeatedShares() {
        // alice owns 2 of 3 shares, bob 1. Read accessor returns each person once.
        let item = SplitDraft.Item(
            id: UUID(),
            label: "Pizza",
            priceCents: 3000,
            partition: .shares(denominator: 3, slots: [alice, bob, alice])
        )
        XCTAssertEqual(item.assignedGuestIds, [alice, bob])
    }

    // MARK: - remappingPersonIDs (PersonID universe boundary)

    func testRemappingSharesIdentity() {
        let p = ItemPartition.shares(denominator: 3, slots: [alice, nil, bob])
        let identity: [PersonID: PersonID] = [alice: alice, bob: bob]
        XCTAssertEqual(p.remappingPersonIDs(identity), p)
    }

    func testRemappingSharesAllSlots() {
        let p = ItemPartition.shares(denominator: 3, slots: [alice, nil, bob])
        let map: [PersonID: PersonID] = [
            alice: PersonID("slot-0"),
            bob: PersonID("slot-1")
        ]
        let expected = ItemPartition.shares(
            denominator: 3,
            slots: [PersonID("slot-0"), nil, PersonID("slot-1")]
        )
        XCTAssertEqual(p.remappingPersonIDs(map), expected)
    }

    func testRemappingSharesDropsMissingToNil() {
        // bob has no entry in the map → his slot becomes nil (unclaimed).
        let p = ItemPartition.shares(denominator: 2, slots: [alice, bob])
        let map: [PersonID: PersonID] = [alice: PersonID("uid-a")]
        let expected = ItemPartition.shares(
            denominator: 2,
            slots: [PersonID("uid-a"), nil]
        )
        XCTAssertEqual(p.remappingPersonIDs(map), expected)
    }

    func testRemappingCustomAllClaims() {
        let p = ItemPartition.custom([
            CustomClaim(personID: alice, cents: 500),
            CustomClaim(personID: bob, cents: 750)
        ])
        let map: [PersonID: PersonID] = [
            alice: PersonID("uid-a"),
            bob: PersonID("uid-b")
        ]
        let expected = ItemPartition.custom([
            CustomClaim(personID: PersonID("uid-a"), cents: 500),
            CustomClaim(personID: PersonID("uid-b"), cents: 750)
        ])
        XCTAssertEqual(p.remappingPersonIDs(map), expected)
    }

    func testRemappingCustomDropsMissing() {
        // bob has no entry in the map → his claim is dropped.
        let p = ItemPartition.custom([
            CustomClaim(personID: alice, cents: 500),
            CustomClaim(personID: bob, cents: 750)
        ])
        let map: [PersonID: PersonID] = [alice: PersonID("uid-a")]
        let expected = ItemPartition.custom([
            CustomClaim(personID: PersonID("uid-a"), cents: 500)
        ])
        XCTAssertEqual(p.remappingPersonIDs(map), expected)
    }

    func testRemappingUnclaimedIsIdempotent() {
        XCTAssertEqual(ItemPartition.unclaimed.remappingPersonIDs([:]), .unclaimed)
    }

    /// Regression: simulates the draft→wire boundary where SplitDraft uses
    /// random UUIDs for anonymous slots but SplitMath looks up via the wire-
    /// canonical "slot-N" form. Without remapping, anonymous-slot claims fail
    /// to match in `centsClaimed(by:)` and the guest's owed amount comes back
    /// as 0 — visible to users as "split 1 way" + missing assignees in the
    /// summary view.
    func testRemappingFixesAnonymousSlotMismatch() {
        // Draft-internal IDs: random UUIDs.
        let draftAlice = PersonID("anonymous-alice-uuid-XXX")
        let draftBob = PersonID("anonymous-bob-uuid-YYY")
        // Item partition is keyed on draft IDs.
        let p = ItemPartition.shares(denominator: 2, slots: [draftAlice, draftBob])

        // Without remap, looking up by wire-canonical "slot-N" returns 0.
        XCTAssertEqual(p.centsClaimed(by: PersonID("slot-0"), priceCents: 1000), 0)
        XCTAssertEqual(p.centsClaimed(by: PersonID("slot-1"), priceCents: 1000), 0)

        // After remap, the partition is wire-canonical and lookups succeed.
        let remap: [PersonID: PersonID] = [
            draftAlice: PersonID("slot-0"),
            draftBob: PersonID("slot-1")
        ]
        let canonical = p.remappingPersonIDs(remap)
        XCTAssertEqual(canonical.centsClaimed(by: PersonID("slot-0"), priceCents: 1000), 500)
        XCTAssertEqual(canonical.centsClaimed(by: PersonID("slot-1"), priceCents: 1000), 500)
    }

    // MARK: - Money.splitEvenly

    func testMoneySplitEvenlyExact() {
        XCTAssertEqual(Money.splitEvenly(totalCents: 600, count: 3), [200, 200, 200])
    }

    func testMoneySplitEvenlyWithRemainderToFirstIndices() {
        XCTAssertEqual(Money.splitEvenly(totalCents: 100, count: 3), [34, 33, 33])
    }

    func testMoneySplitEvenlyZeroTotal() {
        XCTAssertEqual(Money.splitEvenly(totalCents: 0, count: 3), [0, 0, 0])
    }

    func testMoneySplitEvenlyZeroCount() {
        XCTAssertEqual(Money.splitEvenly(totalCents: 100, count: 0), [])
    }
}
