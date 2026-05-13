import XCTest
@testable import LootDomain

final class LineItemTests: XCTestCase {

    func testBasicConstruction() {
        let li = LineItem(label: "Burger", priceCents: 1299)
        XCTAssertEqual(li.label, "Burger")
        XCTAssertEqual(li.priceCents, 1299)
        XCTAssertEqual(li.quantity, 1)  // default
        XCTAssertTrue(li.assigneeIDs.isEmpty)
        XCTAssertFalse(li.hasAssignees)
    }

    func testConstructionWithAssignees() {
        let alice = PersonID("alice")
        let bob = PersonID("bob")
        let li = LineItem(label: "Pizza", priceCents: 1800, assigneeIDs: [alice, bob])
        XCTAssertEqual(li.assigneeIDs, [alice, bob])
        XCTAssertTrue(li.hasAssignees)
    }

    func testQuantityDefaults() {
        let li = LineItem(label: "Beer", priceCents: 600)
        XCTAssertEqual(li.quantity, 1)
    }

    func testQuantityExplicit() {
        let li = LineItem(label: "Beer", priceCents: 600, quantity: 3)
        XCTAssertEqual(li.quantity, 3)
    }

    func testIDDefaultsToFreshUUID() {
        let a = LineItem(label: "X", priceCents: 100)
        let b = LineItem(label: "X", priceCents: 100)
        XCTAssertNotEqual(a.id, b.id)  // different IDs even with same label/price
    }

    func testIDExplicit() {
        let id = UUID()
        let li = LineItem(id: id, label: "X", priceCents: 100)
        XCTAssertEqual(li.id, id)
    }

    func testNormalizedTrimsLabel() {
        let li = LineItem(label: "   Burger   ", priceCents: 1299)
        let norm = li.normalized()
        XCTAssertEqual(norm.label, "Burger")
        XCTAssertEqual(norm.priceCents, 1299)
        XCTAssertEqual(norm.id, li.id)  // preserved
    }

    func testNormalizedPreservesAssignees() {
        let p = PersonID("a")
        let li = LineItem(label: "  X  ", priceCents: 100, assigneeIDs: [p])
        XCTAssertEqual(li.normalized().assigneeIDs, [p])
    }

    func testHasNonEmptyLabel() {
        XCTAssertTrue(LineItem(label: "Burger", priceCents: 100).hasNonEmptyLabel)
        XCTAssertFalse(LineItem(label: "", priceCents: 100).hasNonEmptyLabel)
        XCTAssertFalse(LineItem(label: "   ", priceCents: 100).hasNonEmptyLabel)
        XCTAssertTrue(LineItem(label: "  X  ", priceCents: 100).hasNonEmptyLabel)
    }

    func testCodableRoundTrip() throws {
        let original = LineItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            label: "Margherita",
            priceCents: 1800,
            quantity: 2,
            assigneeIDs: [PersonID("alice"), PersonID("bob")]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LineItem.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testEqualityRequiresAllFieldsMatch() {
        let id = UUID()
        let a = LineItem(id: id, label: "X", priceCents: 100, quantity: 1, assigneeIDs: [PersonID("p")])
        let b = LineItem(id: id, label: "X", priceCents: 100, quantity: 1, assigneeIDs: [PersonID("p")])
        XCTAssertEqual(a, b)

        // Different price
        let c = LineItem(id: id, label: "X", priceCents: 101, quantity: 1, assigneeIDs: [PersonID("p")])
        XCTAssertNotEqual(a, c)

        // Different assignees
        let d = LineItem(id: id, label: "X", priceCents: 100, quantity: 1, assigneeIDs: [])
        XCTAssertNotEqual(a, d)
    }

    func testHashable() {
        let id = UUID()
        let a = LineItem(id: id, label: "X", priceCents: 100)
        let b = LineItem(id: id, label: "X", priceCents: 100)
        let c = LineItem(label: "X", priceCents: 100)  // different ID
        let set: Set<LineItem> = [a, b, c]
        XCTAssertEqual(set.count, 2)  // a == b, c is distinct
    }
}

final class AuxLineTests: XCTestCase {

    func testBasicConstruction() {
        let aux = AuxLine(label: "Tax", cents: 250)
        XCTAssertEqual(aux.label, "Tax")
        XCTAssertEqual(aux.cents, 250)
        XCTAssertFalse(aux.isDiscount)
    }

    func testDiscountSign() {
        let aux = AuxLine(label: "Discount", cents: -500)
        XCTAssertTrue(aux.isDiscount)
    }

    func testZeroIsNotDiscount() {
        let aux = AuxLine(label: "Free", cents: 0)
        XCTAssertFalse(aux.isDiscount)
    }

    func testCodableRoundTrip() throws {
        let original = AuxLine(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            label: "Service Fee",
            cents: 350
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AuxLine.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testEqualityIncludesId() {
        let a = AuxLine(label: "Tax", cents: 100)
        let b = AuxLine(label: "Tax", cents: 100)
        // Different IDs from default — shouldn't be equal even with same label/cents
        XCTAssertNotEqual(a, b)
    }

    func testHashable() {
        let id = UUID()
        let a = AuxLine(id: id, label: "Tax", cents: 100)
        let b = AuxLine(id: id, label: "Tax", cents: 100)
        let set: Set<AuxLine> = [a, b]
        XCTAssertEqual(set.count, 1)
    }
}
