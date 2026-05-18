//
//  DebtSimplifier.swift
//  Loot
//
//  Created by Joshua Liu on 2/18/26.
//

import Foundation

// MARK: - Debt Simplifier

enum DebtSimplifier {

    struct Transaction: Equatable, Identifiable {
        var id: String { "\(from)->\(to)" }
        let from: String   // debtor memberId
        let to: String     // creditor memberId
        let amountCents: Int
    }

    /// Simplify balances into the minimum number of transactions.
    /// - Parameter balances: memberId → net balance in cents (positive = creditor, negative = debtor).
    /// - Returns: Array of transactions (at most N-1) that settle all debts.
    static func simplify(balances: [String: Int]) -> [Transaction] {
        // Separate into debtors and creditors, ignoring zero balances
        var debtors: [(id: String, amount: Int)] = []   // amount stored as positive
        var creditors: [(id: String, amount: Int)] = []

        for (id, balance) in balances {
            if balance < 0 {
                debtors.append((id: id, amount: -balance))
            } else if balance > 0 {
                creditors.append((id: id, amount: balance))
            }
        }

        // Sort by amount descending for greedy matching
        debtors.sort { $0.amount > $1.amount }
        creditors.sort { $0.amount > $1.amount }

        var transactions: [Transaction] = []
        var di = 0
        var ci = 0

        while di < debtors.count && ci < creditors.count {
            let amount = min(debtors[di].amount, creditors[ci].amount)
            if amount > 0 {
                transactions.append(Transaction(
                    from: debtors[di].id,
                    to: creditors[ci].id,
                    amountCents: amount
                ))
            }
            debtors[di].amount -= amount
            creditors[ci].amount -= amount

            if debtors[di].amount == 0 { di += 1 }
            if creditors[ci].amount == 0 { ci += 1 }
        }

        return transactions
    }
}

// MARK: - LootTab convenience

extension LootTab {
    func simplifiedTransactions() -> [DebtSimplifier.Transaction] {
        let balanceMap = Dictionary(
            members.map { ($0.memberId, $0.balanceCents) },
            uniquingKeysWith: { first, _ in first }
        )
        return DebtSimplifier.simplify(balances: balanceMap)
    }
}
