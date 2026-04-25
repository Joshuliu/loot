import XCTest
@testable import LootDomain

/// Regression: Phase 2.6 originally used a computed-property bridge for
/// LineItemForm.assignedGuestIds, which broke @State + array-subscript +
/// Set.insert mutations on device. After fix, `assignedGuestIds` is a
/// stored property; `line.assigneeIDs` is synced only on `committed()`.
/// These tests guard the stored-set semantics.
final class LineItemFormBridgeRegressionTests: XCTestCase {

    /// Reproduces the exact toggle pattern in SplitView.toggleAssignment.
    func testInsertThroughArraySubscriptPersists() {
        let u1 = UUID()
        var items: [LineItemForm] = [
            LineItemForm(label: "Pizza", priceText: "12.00")
        ]
        items[0].assignedGuestIds.insert(u1)
        XCTAssertTrue(items[0].assignedGuestIds.contains(u1),
                      "After insert through subscript, the UUID should be present.")
    }

    func testRemoveThroughArraySubscriptPersists() {
        let u1 = UUID()
        let u2 = UUID()
        var items: [LineItemForm] = [
            LineItemForm(label: "Pizza", priceText: "12.00", assignedGuestIds: [u1, u2])
        ]
        items[0].assignedGuestIds.remove(u1)
        XCTAssertFalse(items[0].assignedGuestIds.contains(u1))
        XCTAssertTrue(items[0].assignedGuestIds.contains(u2))
    }

    func testIntersectionAssignmentThroughSubscript() {
        // Mirrors SplitView.swift's "remove excluded guests from assignments" cleanup.
        let u1 = UUID()
        let u2 = UUID()
        let u3 = UUID()
        var items: [LineItemForm] = [
            LineItemForm(label: "Pizza", priceText: "12.00", assignedGuestIds: [u1, u2, u3])
        ]
        let activeSet: Set<UUID> = [u2]
        items = items.map { it in
            var copy = it
            copy.assignedGuestIds = copy.assignedGuestIds.intersection(activeSet)
            return copy
        }
        XCTAssertEqual(items[0].assignedGuestIds, [u2])
    }

    /// Mirrors `it.assignedGuestIds.sorted { $0.uuidString < $1.uuidString }`
    /// pattern used in buildSplitDraft.
    func testGetterReturnsAllUUIDsForOrderedSort() {
        let u1 = UUID()
        let u2 = UUID()
        let u3 = UUID()
        let item = LineItemForm(label: "Pizza", priceText: "12.00", assignedGuestIds: [u1, u2, u3])
        let sorted = item.assignedGuestIds.sorted { $0.uuidString < $1.uuidString }
        XCTAssertEqual(sorted.count, 3)
        XCTAssertEqual(Set(sorted), [u1, u2, u3])
    }

    /// Verifies that two sequential inserts both stick.
    func testTwoInsertsStick() {
        let u1 = UUID()
        let u2 = UUID()
        var items: [LineItemForm] = [LineItemForm.empty()]
        items[0].assignedGuestIds.insert(u1)
        items[0].assignedGuestIds.insert(u2)
        XCTAssertEqual(items[0].assignedGuestIds, [u1, u2])
    }

    /// Verifies the canonical `line.assigneeIDs` is synced on `committed()` —
    /// this is the path the wire-payload converter ultimately reads.
    func testCommittedSyncsToLineAssigneeIDs() {
        let u1 = UUID()
        var items: [LineItemForm] = [LineItemForm.empty()]
        items[0].assignedGuestIds.insert(u1)
        let committed = items[0].committed()
        XCTAssertEqual(committed.assigneeIDs, [PersonID(rawValue: u1.uuidString)])
    }
}
