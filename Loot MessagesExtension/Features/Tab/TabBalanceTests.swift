//
//  TabBalanceTests.swift
//  Loot
//
//  Created by Joshua Liu on 2/6/26.
//
//  Compile-time verifiable balance logic tests.
//  Call TabBalanceTests.runAll() from a debug launch to verify.
//

import Foundation

#if DEBUG
enum TabBalanceTests {

    static func runAll() {
        testReceiptSplitEqually()
        testReceiptSplitCustom()
        testSettlement()
        testMultipleReceiptsAndSettlement()
        testDebtSimplify2Person()
        testDebtSimplify3PersonCycle()
        testDebtSimplifyAllZero()
        testDebtSimplifyMultiWay()
        LLMClient.shared.runPhase2ResolverTests()
        print("[TabBalanceTests] All tests passed")
    }

    // MARK: - Test: $30 receipt split equally 3 ways, Alice paid

    private static func testReceiptSplitEqually() {
        var tab = makeTab(memberNames: ["Alice", "Bob", "Charlie"])

        let receipt = TabReceipt(
            id: "r1",
            title: "Lunch",
            createdBy: "user-alice",
            createdAt: nil,
            totalCents: 3000,
            subtotalCents: 2500,
            taxCents: 300,
            tipCents: 200,
            feesCents: 0,
            discountCents: 0,
            splitMode: .equally,
            payerMemberId: tab.members[0].memberId, // Alice
            splits: [
                ReceiptSplit(memberId: tab.members[0].memberId, owedCents: 1000),
                ReceiptSplit(memberId: tab.members[1].memberId, owedCents: 1000),
                ReceiptSplit(memberId: tab.members[2].memberId, owedCents: 1000),
            ],
            items: nil,
            imageUrl: nil,
            messagePayloadId: nil
        )

        tab.applyReceipt(receipt)

        assert(tab.members[0].balanceCents == 2000, "Alice should be +2000, got \(tab.members[0].balanceCents)")
        assert(tab.members[1].balanceCents == -1000, "Bob should be -1000, got \(tab.members[1].balanceCents)")
        assert(tab.members[2].balanceCents == -1000, "Charlie should be -1000, got \(tab.members[2].balanceCents)")
        assertBalancesSumToZero(tab)
        assert(tab.receiptCount == 1)
        print("  [PASS] testReceiptSplitEqually")
    }

    // MARK: - Test: Custom split

    private static func testReceiptSplitCustom() {
        var tab = makeTab(memberNames: ["Alice", "Bob"])

        let receipt = TabReceipt(
            id: "r1",
            title: "Dinner",
            createdBy: "user-alice",
            createdAt: nil,
            totalCents: 5000,
            subtotalCents: 4000,
            taxCents: 500,
            tipCents: 500,
            feesCents: 0,
            discountCents: 0,
            splitMode: .custom,
            payerMemberId: tab.members[0].memberId, // Alice
            splits: [
                ReceiptSplit(memberId: tab.members[0].memberId, owedCents: 2000),
                ReceiptSplit(memberId: tab.members[1].memberId, owedCents: 3000),
            ],
            items: nil,
            imageUrl: nil,
            messagePayloadId: nil
        )

        tab.applyReceipt(receipt)

        assert(tab.members[0].balanceCents == 3000, "Alice should be +3000, got \(tab.members[0].balanceCents)")
        assert(tab.members[1].balanceCents == -3000, "Bob should be -3000, got \(tab.members[1].balanceCents)")
        assertBalancesSumToZero(tab)
        print("  [PASS] testReceiptSplitCustom")
    }

    // MARK: - Test: Settlement reduces balances

    private static func testSettlement() {
        var tab = makeTab(memberNames: ["Alice", "Bob"])
        // Manually set balances as if a receipt was already applied
        tab.members[0].balanceCents = 2000   // Alice is owed
        tab.members[1].balanceCents = -2000  // Bob owes

        let settlement = Settlement(
            id: "s1",
            createdAt: nil,
            createdBy: "user-bob",
            fromMemberId: tab.members[1].memberId, // Bob pays
            toMemberId: tab.members[0].memberId,    // Alice receives
            amountCents: 2000,
            note: nil
        )

        tab.applySettlement(settlement)

        assert(tab.members[0].balanceCents == 0, "Alice should be 0, got \(tab.members[0].balanceCents)")
        assert(tab.members[1].balanceCents == 0, "Bob should be 0, got \(tab.members[1].balanceCents)")
        assertBalancesSumToZero(tab)
        print("  [PASS] testSettlement")
    }

    // MARK: - Test: Multiple receipts then partial settlement

    private static func testMultipleReceiptsAndSettlement() {
        var tab = makeTab(memberNames: ["Alice", "Bob", "Charlie"])

        // Receipt 1: $30 split equally, Alice paid
        let r1 = TabReceipt(
            id: "r1", title: "Lunch", createdBy: "user-alice", createdAt: nil,
            totalCents: 3000, subtotalCents: 3000, taxCents: 0, tipCents: 0, feesCents: 0, discountCents: 0,
            splitMode: .equally, payerMemberId: tab.members[0].memberId,
            splits: [
                ReceiptSplit(memberId: tab.members[0].memberId, owedCents: 1000),
                ReceiptSplit(memberId: tab.members[1].memberId, owedCents: 1000),
                ReceiptSplit(memberId: tab.members[2].memberId, owedCents: 1000),
            ],
            items: nil, imageUrl: nil, messagePayloadId: nil
        )
        tab.applyReceipt(r1)
        assertBalancesSumToZero(tab)

        // Receipt 2: $60 split equally, Bob paid
        let r2 = TabReceipt(
            id: "r2", title: "Dinner", createdBy: "user-bob", createdAt: nil,
            totalCents: 6000, subtotalCents: 6000, taxCents: 0, tipCents: 0, feesCents: 0, discountCents: 0,
            splitMode: .equally, payerMemberId: tab.members[1].memberId,
            splits: [
                ReceiptSplit(memberId: tab.members[0].memberId, owedCents: 2000),
                ReceiptSplit(memberId: tab.members[1].memberId, owedCents: 2000),
                ReceiptSplit(memberId: tab.members[2].memberId, owedCents: 2000),
            ],
            items: nil, imageUrl: nil, messagePayloadId: nil
        )
        tab.applyReceipt(r2)
        assertBalancesSumToZero(tab)

        // After both receipts:
        // Alice: +2000 (paid r1) -1000 (share r1) -2000 (share r2) = -1000
        // Bob: -1000 (share r1) +6000 (paid r2) -2000 (share r2) = +3000
        // Charlie: -1000 (share r1) -2000 (share r2) = -3000
        assert(tab.members[0].balanceCents == 0, "Alice should be 0, got \(tab.members[0].balanceCents)")
        assert(tab.members[1].balanceCents == 3000, "Bob should be +3000, got \(tab.members[1].balanceCents)")
        assert(tab.members[2].balanceCents == -3000, "Charlie should be -3000, got \(tab.members[2].balanceCents)")

        // Charlie pays Bob $1500 (partial settlement)
        let s1 = Settlement(
            id: "s1", createdAt: nil, createdBy: "user-charlie",
            fromMemberId: tab.members[2].memberId,
            toMemberId: tab.members[1].memberId,
            amountCents: 1500, note: "Partial"
        )
        tab.applySettlement(s1)

        assert(tab.members[1].balanceCents == 1500, "Bob should be +1500, got \(tab.members[1].balanceCents)")
        assert(tab.members[2].balanceCents == -1500, "Charlie should be -1500, got \(tab.members[2].balanceCents)")
        assertBalancesSumToZero(tab)
        assert(tab.receiptCount == 2)
        print("  [PASS] testMultipleReceiptsAndSettlement")
    }

    // MARK: - Helpers

    private static func makeTab(memberNames: [String]) -> LootTab {
        LootTab(
            id: "tab-1",
            name: "Test Tab",
            createdBy: "user-\(memberNames[0].lowercased())",
            status: .active,
            members: memberNames.map { name in
                TabMember(
                    memberId: "m-\(name.lowercased())",
                    userId: "user-\(name.lowercased())",
                    displayName: name,
                    balanceCents: 0,
                    isActive: true
                )
            },
            memberIds: memberNames.map { "user-\($0.lowercased())" },
            receiptCount: 0,
            createdAt: nil,
            updatedAt: nil
        )
    }

    private static func assertBalancesSumToZero(_ tab: LootTab) {
        let sum = tab.members.reduce(0) { $0 + $1.balanceCents }
        assert(sum == 0, "Sum of balances should be 0, got \(sum)")
    }

    // MARK: - Debt Simplification Tests

    private static func testDebtSimplify2Person() {
        // Alice owes Bob $20
        let balances = ["alice": -2000, "bob": 2000]
        let txns = DebtSimplifier.simplify(balances: balances)

        assert(txns.count == 1, "Expected 1 transaction, got \(txns.count)")
        assert(txns[0].from == "alice")
        assert(txns[0].to == "bob")
        assert(txns[0].amountCents == 2000)
        print("  [PASS] testDebtSimplify2Person")
    }

    private static func testDebtSimplify3PersonCycle() {
        // A owes $10, B owed $20, C owes $10
        // Net: A = -1000, B = +2000, C = -1000
        let balances = ["A": -1000, "B": 2000, "C": -1000]
        let txns = DebtSimplifier.simplify(balances: balances)

        assert(txns.count == 2, "Expected 2 transactions, got \(txns.count)")
        let totalPaid = txns.reduce(0) { $0 + $1.amountCents }
        assert(totalPaid == 2000, "Total paid should be 2000, got \(totalPaid)")
        // All transactions should go to B
        for t in txns {
            assert(t.to == "B", "All payments should go to B, got \(t.to)")
        }
        print("  [PASS] testDebtSimplify3PersonCycle")
    }

    private static func testDebtSimplifyAllZero() {
        let balances = ["A": 0, "B": 0, "C": 0]
        let txns = DebtSimplifier.simplify(balances: balances)
        assert(txns.isEmpty, "Expected 0 transactions, got \(txns.count)")
        print("  [PASS] testDebtSimplifyAllZero")
    }

    private static func testDebtSimplifyMultiWay() {
        // 4 people: A=-3000, B=+1000, C=+500, D=+1500
        let balances = ["A": -3000, "B": 1000, "C": 500, "D": 1500]
        let txns = DebtSimplifier.simplify(balances: balances)

        // Should produce at most 3 transactions (N-1)
        assert(txns.count <= 3, "Expected <= 3 transactions, got \(txns.count)")

        // Verify net flow is correct
        var netFlow: [String: Int] = [:]
        for t in txns {
            netFlow[t.from, default: 0] -= t.amountCents
            netFlow[t.to, default: 0] += t.amountCents
        }
        assert(netFlow["A"] == -3000, "A net should be -3000, got \(netFlow["A"] ?? 0)")
        assert((netFlow["B"] ?? 0) + (netFlow["C"] ?? 0) + (netFlow["D"] ?? 0) == 3000)
        print("  [PASS] testDebtSimplifyMultiWay")
    }
}
#endif
