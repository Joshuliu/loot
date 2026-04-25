import XCTest
@testable import LootDomain

final class ReceiptBreakdownTests: XCTestCase {

    func testZeroDefaults() {
        let b = ReceiptBreakdown.zero
        XCTAssertEqual(b.subtotalCents, 0)
        XCTAssertEqual(b.feesCents, 0)
        XCTAssertEqual(b.taxCents, 0)
        XCTAssertEqual(b.tipCents, 0)
        XCTAssertEqual(b.discountCents, 0)
        XCTAssertEqual(b.totalCents, 0)
    }

    func testHasOnlyTotalTrue() {
        let b = ReceiptBreakdown(subtotalCents: 1000, totalCents: 1000)
        XCTAssertTrue(b.hasOnlyTotal)
    }

    func testHasOnlyTotalFalseWithTax() {
        let b = ReceiptBreakdown(subtotalCents: 1000, taxCents: 50, totalCents: 1050)
        XCTAssertFalse(b.hasOnlyTotal)
    }

    func testHasOnlyTotalFalseWithTip() {
        let b = ReceiptBreakdown(subtotalCents: 1000, tipCents: 200, totalCents: 1200)
        XCTAssertFalse(b.hasOnlyTotal)
    }

    func testDerivedTotalSimple() {
        let b = ReceiptBreakdown(
            subtotalCents: 1000,
            feesCents: 100,
            taxCents: 80,
            tipCents: 200,
            discountCents: 50,
            totalCents: 1330
        )
        XCTAssertEqual(b.derivedTotalCents, 1330)
        XCTAssertTrue(b.isInternallyConsistent)
    }

    func testDerivedTotalDiscountSubtracts() {
        let b = ReceiptBreakdown(
            subtotalCents: 1000,
            feesCents: 0,
            taxCents: 0,
            tipCents: 0,
            discountCents: 100,
            totalCents: 900
        )
        XCTAssertEqual(b.derivedTotalCents, 900)
        XCTAssertTrue(b.isInternallyConsistent)
    }

    func testInternalInconsistencyDetected() {
        let b = ReceiptBreakdown(subtotalCents: 1000, totalCents: 999) // off by 1
        XCTAssertFalse(b.isInternallyConsistent)
    }

    func testCodableRoundTrip() throws {
        let original = ReceiptBreakdown(
            subtotalCents: 1234,
            feesCents: 56,
            taxCents: 78,
            tipCents: 200,
            discountCents: 100,
            totalCents: 1468
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReceiptBreakdown.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}

final class ReceiptTests: XCTestCase {

    func testEmptyConstruction() {
        let r = Receipt(id: "r1", title: "Lunch")
        XCTAssertEqual(r.id, "r1")
        XCTAssertEqual(r.title, "Lunch")
        XCTAssertNil(r.createdAt)
        XCTAssertTrue(r.lines.isEmpty)
        XCTAssertTrue(r.auxLines.isEmpty)
        XCTAssertEqual(r.breakdown, .zero)
    }

    func testDisplayTotal() {
        let r = Receipt(id: "r1", title: "X", breakdown: ReceiptBreakdown(totalCents: 1234))
        XCTAssertEqual(r.displayTotal.cents, 1234)
        XCTAssertEqual(r.displayTotal.displayString, "$12.34")
    }

    func testLineItemSubtotal() {
        let r = Receipt(
            id: "r1",
            title: "X",
            lines: [
                LineItem(label: "A", priceCents: 100),
                LineItem(label: "B", priceCents: 250),
                LineItem(label: "C", priceCents: 1000)
            ]
        )
        XCTAssertEqual(r.lineItemSubtotalCents, 1350)
    }

    func testLineItemSubtotalEmpty() {
        let r = Receipt(id: "r1", title: "X")
        XCTAssertEqual(r.lineItemSubtotalCents, 0)
    }

    func testCompletedLinesFiltersBlankLabels() {
        let r = Receipt(
            id: "r1",
            title: "X",
            lines: [
                LineItem(label: "Burger", priceCents: 1200),
                LineItem(label: "", priceCents: 0),       // user-typing-row
                LineItem(label: "   ", priceCents: 500),  // whitespace
                LineItem(label: "Fries", priceCents: 400)
            ]
        )
        let completed = r.completedLines
        XCTAssertEqual(completed.count, 2)
        XCTAssertEqual(completed.map(\.label), ["Burger", "Fries"])
    }

    func testCodableRoundTrip() throws {
        let original = Receipt(
            id: "r1",
            title: "Pizza Place",
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            lines: [
                LineItem(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    label: "Margherita",
                    priceCents: 1800,
                    assigneeIDs: [PersonID("alice")]
                )
            ],
            auxLines: [
                AuxLine(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    label: "Tax",
                    cents: 144
                )
            ],
            breakdown: ReceiptBreakdown(
                subtotalCents: 1800,
                taxCents: 144,
                totalCents: 1944
            )
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Receipt.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testEqualityRequiresAllFieldsMatch() {
        let r1 = Receipt(id: "r1", title: "X")
        let r2 = Receipt(id: "r1", title: "X")
        XCTAssertEqual(r1, r2)

        let r3 = Receipt(id: "r2", title: "X")
        XCTAssertNotEqual(r1, r3)

        let r4 = Receipt(id: "r1", title: "X", breakdown: ReceiptBreakdown(totalCents: 100))
        XCTAssertNotEqual(r1, r4)
    }
}
