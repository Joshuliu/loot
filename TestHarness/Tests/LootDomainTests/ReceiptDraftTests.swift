import XCTest
@testable import LootDomain

// Phase 3 step 11: pure-function tests for ReceiptDraft.reconciled() and
// ReceiptDraft.foldingTip(). These are the same invariants enforced today
// by the imperative reconciliation in RootContainerView; locking them into
// pure functions means the impure wrapper is just plumbing.

final class ReceiptDraftReconciledTests: XCTestCase {

    // MARK: - Helpers

    private func makeAlice() -> Person { .identified(userId: "alice-uid", displayName: "Alice") }
    private func makeBob() -> Person { .identified(userId: "bob-uid", displayName: "Bob") }
    private func makeCharlie() -> Person { .identified(userId: "charlie-uid", displayName: "Charlie") }

    private func makeReceipt(total: Int, fees: Int = 0, tax: Int = 0, tip: Int = 0, discount: Int = 0) -> Receipt {
        Receipt(
            id: "test-receipt",
            title: "Test",
            breakdown: ReceiptBreakdown(
                subtotalCents: max(0, total - fees - tax - tip + discount),
                feesCents: fees,
                taxCents: tax,
                tipCents: tip,
                discountCents: discount,
                totalCents: total
            )
        )
    }

    private func makeSplit(
        guests: [Person],
        included: Set<PersonID>? = nil,
        payerID: PersonID? = nil,
        mode: SplitDraft.Mode = .equally,
        totalCents: Int = 0,
        perGuestCents: [Int] = [],
        feesCents: Int = 0,
        taxCents: Int = 0,
        tipCents: Int = 0,
        discountCents: Int = 0
    ) -> SplitDraft {
        SplitDraft(
            guests: guests,
            includedIDs: included ?? Set(guests.map(\.id)),
            payerID: payerID ?? guests[0].id,
            mode: mode,
            totalCents: totalCents,
            perGuestCents: perGuestCents,
            items: [],
            feesCents: feesCents,
            discountCents: discountCents,
            taxCents: taxCents,
            tipCents: tipCents
        )
    }

    // MARK: - reconciled()

    func testReconciledNoOpWhenReceiptTotalIsZero() {
        let alice = makeAlice()
        let split = makeSplit(guests: [alice], totalCents: 1000, perGuestCents: [1000])
        let receipt = makeReceipt(total: 0)

        let result = ReceiptDraft(receipt: receipt, split: split).reconciled()

        XCTAssertEqual(result.split, split, "Should be unchanged when receipt total is 0")
    }

    func testReconciledNoOpWhenNoGuestsIncluded() {
        let alice = makeAlice()
        let split = makeSplit(guests: [alice], included: [], totalCents: 0, perGuestCents: [])
        let receipt = makeReceipt(total: 5000)

        let result = ReceiptDraft(receipt: receipt, split: split).reconciled()

        XCTAssertEqual(result.split, split, "Should be unchanged when no guests are included")
    }

    func testReconciledCopiesAllBreakdownFields() {
        let alice = makeAlice()
        let split = makeSplit(guests: [alice], mode: .custom, totalCents: 0, perGuestCents: [0])
        let receipt = makeReceipt(total: 5000, fees: 100, tax: 200, tip: 500, discount: 50)

        let result = ReceiptDraft(receipt: receipt, split: split).reconciled()

        XCTAssertEqual(result.split.totalCents, 5000)
        XCTAssertEqual(result.split.feesCents, 100)
        XCTAssertEqual(result.split.taxCents, 200)
        XCTAssertEqual(result.split.tipCents, 500)
        XCTAssertEqual(result.split.discountCents, 50)
    }

    func testReconciledRecomputesPerGuestCentsForEqually() {
        let alice = makeAlice()
        let bob = makeBob()
        let charlie = makeCharlie()
        let split = makeSplit(
            guests: [alice, bob, charlie],
            mode: .equally,
            totalCents: 0,
            perGuestCents: [0, 0, 0]
        )
        let receipt = makeReceipt(total: 100)  // 33 + 33 + 34 (remainder distributes to first)

        let result = ReceiptDraft(receipt: receipt, split: split).reconciled()

        XCTAssertEqual(result.split.perGuestCents, [34, 33, 33])
        XCTAssertEqual(result.split.perGuestCents.reduce(0, +), 100)
    }

    func testReconciledDoesNotRecomputePerGuestCentsForCustom() {
        let alice = makeAlice()
        let bob = makeBob()
        let split = makeSplit(
            guests: [alice, bob],
            mode: .custom,
            totalCents: 0,
            perGuestCents: [3000, 2000]  // user-specified
        )
        let receipt = makeReceipt(total: 5000)

        let result = ReceiptDraft(receipt: receipt, split: split).reconciled()

        XCTAssertEqual(result.split.perGuestCents, [3000, 2000], "custom amounts must not be recomputed")
        XCTAssertEqual(result.split.totalCents, 5000)
    }

    func testReconciledDoesNotRecomputePerGuestCentsForByItems() {
        let alice = makeAlice()
        let bob = makeBob()
        let split = makeSplit(
            guests: [alice, bob],
            mode: .byItems,
            totalCents: 0,
            perGuestCents: [2500, 2500]  // computed from items elsewhere
        )
        let receipt = makeReceipt(total: 5000)

        let result = ReceiptDraft(receipt: receipt, split: split).reconciled()

        XCTAssertEqual(result.split.perGuestCents, [2500, 2500], "byItems amounts must not be recomputed by reconcile")
    }

    func testReconciledOnlyCountsIncludedGuestsForEqually() {
        let alice = makeAlice()
        let bob = makeBob()
        let charlie = makeCharlie()
        let split = makeSplit(
            guests: [alice, bob, charlie],
            included: [alice.id, bob.id],  // exclude Charlie
            mode: .equally,
            totalCents: 0,
            perGuestCents: [0, 0]
        )
        let receipt = makeReceipt(total: 1000)

        let result = ReceiptDraft(receipt: receipt, split: split).reconciled()

        XCTAssertEqual(result.split.perGuestCents, [500, 500])
    }

    func testReconciledFixesInvalidPayer() {
        let alice = makeAlice()
        let bob = makeBob()
        let charlie = makeCharlie()
        let split = makeSplit(
            guests: [alice, bob, charlie],
            included: [bob.id, charlie.id],
            payerID: alice.id,  // not in includedIDs
            mode: .equally,
            totalCents: 0,
            perGuestCents: [0, 0]
        )
        let receipt = makeReceipt(total: 1000)

        let result = ReceiptDraft(receipt: receipt, split: split).reconciled()

        XCTAssertEqual(result.split.payerID, bob.id, "payer should fall back to the first included guest in original guest order")
    }

    func testReconciledKeepsValidPayer() {
        let alice = makeAlice()
        let bob = makeBob()
        let split = makeSplit(
            guests: [alice, bob],
            payerID: bob.id,
            mode: .equally,
            totalCents: 0,
            perGuestCents: [0, 0]
        )
        let receipt = makeReceipt(total: 1000)

        let result = ReceiptDraft(receipt: receipt, split: split).reconciled()

        XCTAssertEqual(result.split.payerID, bob.id, "valid payer must be preserved")
    }

    func testReconciledDoesNotMutateReceipt() {
        let alice = makeAlice()
        let split = makeSplit(guests: [alice], totalCents: 0, perGuestCents: [0])
        let receipt = makeReceipt(total: 5000, tip: 500)

        let result = ReceiptDraft(receipt: receipt, split: split).reconciled()

        XCTAssertEqual(result.receipt, receipt, "reconciled should never mutate the receipt half")
    }
}

final class ReceiptDraftFoldingTipTests: XCTestCase {

    private func makeReceipt(total: Int, tip: Int) -> Receipt {
        Receipt(
            id: "test",
            title: "Test",
            breakdown: ReceiptBreakdown(
                subtotalCents: total - tip,
                tipCents: tip,
                totalCents: total
            )
        )
    }

    private func makeSplit(total: Int, tip: Int) -> SplitDraft {
        let alice = Person.identified(userId: "alice", displayName: "Alice")
        return SplitDraft(
            guests: [alice],
            includedIDs: [alice.id],
            payerID: alice.id,
            mode: .equally,
            totalCents: total,
            perGuestCents: [total],
            items: [],
            feesCents: 0,
            discountCents: 0,
            taxCents: 0,
            tipCents: tip
        )
    }

    func testFoldingTipNoOpWhenZero() {
        let draft = ReceiptDraft(
            receipt: makeReceipt(total: 1000, tip: 200),
            split: makeSplit(total: 1000, tip: 200)
        )

        let result = draft.foldingTip(0)

        XCTAssertEqual(result, draft, "tipCents <= 0 must be a no-op")
    }

    func testFoldingTipNoOpWhenNegative() {
        let draft = ReceiptDraft(
            receipt: makeReceipt(total: 1000, tip: 200),
            split: makeSplit(total: 1000, tip: 200)
        )

        let result = draft.foldingTip(-100)

        XCTAssertEqual(result, draft, "negative tipCents must be a no-op")
    }

    func testFoldingTipNoOpWhenAlreadyMatches() {
        let draft = ReceiptDraft(
            receipt: makeReceipt(total: 1000, tip: 200),
            split: makeSplit(total: 1000, tip: 200)
        )

        let result = draft.foldingTip(200)

        XCTAssertEqual(result, draft, "matching tipCents must be a no-op")
    }

    func testFoldingTipReplacesNotAdds() {
        // Regression for the historical "tip applied twice" bug.
        // If foldingTip used += instead of =, total would become 1000+500 = 1500.
        let draft = ReceiptDraft(
            receipt: makeReceipt(total: 1000, tip: 200),
            split: makeSplit(total: 1000, tip: 200)
        )

        let result = draft.foldingTip(500)

        XCTAssertEqual(result.split.tipCents, 500, "tip must be replaced, not added")
        XCTAssertEqual(result.split.totalCents, 1300, "total = oldTotal - oldTip + newTip = 1000 - 200 + 500")
        XCTAssertEqual(result.receipt.breakdown.tipCents, 500)
        XCTAssertEqual(result.receipt.breakdown.totalCents, 1300)
    }

    func testFoldingTipFromZeroAddsCleanly() {
        let draft = ReceiptDraft(
            receipt: makeReceipt(total: 1000, tip: 0),
            split: makeSplit(total: 1000, tip: 0)
        )

        let result = draft.foldingTip(150)

        XCTAssertEqual(result.split.tipCents, 150)
        XCTAssertEqual(result.split.totalCents, 1150)
        XCTAssertEqual(result.receipt.breakdown.tipCents, 150)
        XCTAssertEqual(result.receipt.breakdown.totalCents, 1150)
    }

    func testFoldingTipClampsTotalAtZero() {
        // If oldTip > totalCents (a malformed state), don't go negative.
        let draft = ReceiptDraft(
            receipt: makeReceipt(total: 100, tip: 500),  // malformed: tip > total
            split: makeSplit(total: 100, tip: 500)
        )

        let result = draft.foldingTip(50)

        XCTAssertGreaterThanOrEqual(result.split.totalCents, 0)
        XCTAssertGreaterThanOrEqual(result.receipt.breakdown.totalCents, 0)
    }
}

final class ReceiptDraftEqualSplitTests: XCTestCase {

    func testEqualSplitDistributesEvenlyWhenDivisible() {
        XCTAssertEqual(ReceiptDraft.equalSplitCents(total: 100, count: 4), [25, 25, 25, 25])
    }

    func testEqualSplitDistributesRemainderToEarliestIndices() {
        XCTAssertEqual(ReceiptDraft.equalSplitCents(total: 100, count: 3), [34, 33, 33])
    }

    func testEqualSplitSumsBackToTotal() {
        for total in [1, 7, 100, 999, 12345] {
            for count in 1...10 {
                let shares = ReceiptDraft.equalSplitCents(total: total, count: count)
                XCTAssertEqual(shares.reduce(0, +), total, "total=\(total), count=\(count)")
                XCTAssertEqual(shares.count, count, "must produce `count` shares")
            }
        }
    }

    func testEqualSplitZeroTotal() {
        XCTAssertEqual(ReceiptDraft.equalSplitCents(total: 0, count: 3), [0, 0, 0])
    }

    func testEqualSplitZeroCount() {
        XCTAssertEqual(ReceiptDraft.equalSplitCents(total: 100, count: 0), [])
    }

    func testEqualSplitNegativeCount() {
        XCTAssertEqual(ReceiptDraft.equalSplitCents(total: 100, count: -1), [])
    }
}

final class ReceiptDraftCodableTests: XCTestCase {

    func testRoundTripPreservesBothHalves() throws {
        let alice = Person.identified(userId: "alice", displayName: "Alice")
        let bob = Person.identified(userId: "bob", displayName: "Bob")

        let original = ReceiptDraft(
            receipt: Receipt(
                id: "r-1",
                title: "Dinner",
                breakdown: ReceiptBreakdown(
                    subtotalCents: 4000,
                    feesCents: 100,
                    taxCents: 200,
                    tipCents: 700,
                    discountCents: 0,
                    totalCents: 5000
                )
            ),
            split: SplitDraft(
                guests: [alice, bob],
                includedIDs: [alice.id, bob.id],
                payerID: alice.id,
                mode: .byItems,
                totalCents: 5000,
                perGuestCents: [2500, 2500],
                items: [],
                feesCents: 100,
                discountCents: 0,
                taxCents: 200,
                tipCents: 700
            )
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReceiptDraft.self, from: data)

        XCTAssertEqual(decoded, original)
    }
}
