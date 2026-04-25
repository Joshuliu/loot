import XCTest
@testable import LootDomain

final class LineItemFormTests: XCTestCase {

    func testEmptyForm() {
        let f = LineItemForm.empty()
        XCTAssertEqual(f.line.label, "")
        XCTAssertEqual(f.priceText, "")
        XCTAssertEqual(f.priceCents, 0)
        XCTAssertFalse(f.isComplete)
    }

    func testFromCanonicalLineItem() {
        let li = LineItem(label: "Burger", priceCents: 1299)
        let f = LineItemForm(from: li)
        XCTAssertEqual(f.line, li)
        XCTAssertEqual(f.priceText, "12.99")
        XCTAssertEqual(f.priceCents, 1299)
    }

    func testFromZeroPrice() {
        let li = LineItem(label: "X", priceCents: 0)
        let f = LineItemForm(from: li)
        XCTAssertEqual(f.priceText, "0.00")
        XCTAssertEqual(f.priceCents, 0)
    }

    func testIDForwardsToLineID() {
        let id = UUID()
        let li = LineItem(id: id, label: "X", priceCents: 100)
        let f = LineItemForm(from: li)
        XCTAssertEqual(f.id, id)
    }

    func testIsCompleteRequiresBoth() {
        var f = LineItemForm.empty()
        XCTAssertFalse(f.isComplete)

        f.line.label = "Burger"
        XCTAssertFalse(f.isComplete)  // price still blank

        f.priceText = "12.99"
        XCTAssertTrue(f.isComplete)
    }

    func testIsCompleteRejectsWhitespaceOnly() {
        var f = LineItemForm.empty()
        f.line.label = "  "
        f.priceText = "12.99"
        XCTAssertFalse(f.isComplete)

        f.line.label = "Burger"
        f.priceText = "  "
        XCTAssertFalse(f.isComplete)
    }

    func testPriceCentsParsesText() {
        var f = LineItemForm.empty()
        f.priceText = "$12.50"
        XCTAssertEqual(f.priceCents, 1250)

        f.priceText = "1,234.56"
        XCTAssertEqual(f.priceCents, 123456)
    }

    func testCommittedTrimsLabelAndUsesParsedCents() {
        var f = LineItemForm.empty()
        f.line.label = "  Burger  "
        f.priceText = "12.99"
        let committed = f.committed()
        XCTAssertEqual(committed.label, "Burger")
        XCTAssertEqual(committed.priceCents, 1299)
        XCTAssertEqual(committed.id, f.line.id)
    }

    func testCommittedPreservesAssignees() {
        var f = LineItemForm(
            line: LineItem(label: "Pizza", priceCents: 0, assigneeIDs: [PersonID("a"), PersonID("b")]),
            priceText: "18.00"
        )
        f.line.label = "Margherita"
        let committed = f.committed()
        XCTAssertEqual(committed.assigneeIDs, [PersonID("a"), PersonID("b")])
        XCTAssertEqual(committed.priceCents, 1800)
    }

    func testEditingTextDoesNotMutateCanonicalCents() {
        var f = LineItemForm(from: LineItem(label: "X", priceCents: 1000))
        f.priceText = "20.00"
        // line.priceCents stays at 1000 until commit
        XCTAssertEqual(f.line.priceCents, 1000)
        XCTAssertEqual(f.priceCents, 2000)  // derived from text
        XCTAssertEqual(f.committed().priceCents, 2000)
    }

    func testHashable() {
        let id = UUID()
        let a = LineItemForm(line: LineItem(id: id, label: "X", priceCents: 100), priceText: "1.00")
        let b = LineItemForm(line: LineItem(id: id, label: "X", priceCents: 100), priceText: "1.00")
        let set: Set<LineItemForm> = [a, b]
        XCTAssertEqual(set.count, 1)
    }
}

final class AuxLineFormTests: XCTestCase {

    func testFromCanonicalAuxLine() {
        let aux = AuxLine(label: "Tax", cents: 250)
        let f = AuxLineForm(from: aux)
        XCTAssertEqual(f.line, aux)
        XCTAssertEqual(f.amountText, "2.50")
        XCTAssertEqual(f.amountCents, 250)
    }

    func testNegativeDiscountFormatsSigned() {
        let aux = AuxLine(label: "Discount", cents: -500)
        let f = AuxLineForm(from: aux)
        XCTAssertEqual(f.amountText, "-5.00")
        XCTAssertEqual(f.amountCents, -500)
    }

    func testIsCompleteRequiresBoth() {
        var f = AuxLineForm(line: AuxLine(label: "", cents: 0), amountText: "")
        XCTAssertFalse(f.isComplete)

        f.line.label = "Tax"
        XCTAssertFalse(f.isComplete)

        f.amountText = "2.50"
        XCTAssertTrue(f.isComplete)
    }

    func testCommittedTrimsLabel() {
        var f = AuxLineForm(line: AuxLine(label: "  Tax  ", cents: 0), amountText: "2.50")
        let committed = f.committed()
        XCTAssertEqual(committed.label, "Tax")
        XCTAssertEqual(committed.cents, 250)
    }

    func testCommittedPreservesNegativeAmount() {
        let f = AuxLineForm(line: AuxLine(label: "Discount", cents: 0), amountText: "-10.00")
        let committed = f.committed()
        XCTAssertEqual(committed.cents, -1000)
        XCTAssertTrue(committed.isDiscount)
    }

    func testIDForwardsToLineID() {
        let id = UUID()
        let aux = AuxLine(id: id, label: "Tax", cents: 100)
        let f = AuxLineForm(from: aux)
        XCTAssertEqual(f.id, id)
    }
}
