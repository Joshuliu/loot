//
//  TabModels.swift
//  Loot
//
//  Created by Joshua Liu on 2/6/26.
//

import Foundation
import FirebaseFirestore

// MARK: - User Profile

struct LootUser: Codable, Identifiable {
    @DocumentID var id: String?
    var displayName: String
    var email: String?
    var phoneNumber: String?
    var avatarUrl: String?
    @ServerTimestamp var createdAt: Timestamp?
    @ServerTimestamp var updatedAt: Timestamp?
}

// MARK: - Tab

enum TabColorOptions {
    static let all = ["052F5F", "005377", "06A77D", "D5C67A", "DAA806"]
    static let defaultHex = "005377"
}

struct LootTab: Codable, Identifiable {
    @DocumentID var id: String?
    var name: String
    var colorHex: String?
    var createdBy: String
    var status: TabStatus
    var members: [TabMember]
    var memberIds: [String]
    var receiptCount: Int
    @ServerTimestamp var createdAt: Timestamp?
    @ServerTimestamp var updatedAt: Timestamp?
}

enum TabStatus: String, Codable {
    case active
    case settled
}

struct TabMember: Codable, Identifiable {
    var id: String { memberId }
    var memberId: String
    var userId: String?
    var displayName: String
    var balanceCents: Int
    var isActive: Bool
}

// MARK: - Tab Receipt

struct TabReceipt: Codable, Identifiable {
    @DocumentID var id: String?
    var title: String
    var createdBy: String
    @ServerTimestamp var createdAt: Timestamp?
    var totalCents: Int
    var subtotalCents: Int
    var taxCents: Int
    var tipCents: Int
    var feesCents: Int
    var discountCents: Int
    var splitMode: SplitMode
    var payerMemberId: String
    var splits: [ReceiptSplit]
    var items: [ReceiptItem]?
    var imageUrl: String?
    var messagePayloadId: String?
}

enum SplitMode: String, Codable {
    case equally
    case byItems
    case custom
}

struct ReceiptSplit: Codable {
    var memberId: String
    var owedCents: Int
}

struct ReceiptItem: Codable {
    var label: String
    var priceCents: Int
    var quantity: Int
    var assignedMemberIds: [String]
}

// MARK: - Settlement

struct Settlement: Codable, Identifiable {
    @DocumentID var id: String?
    @ServerTimestamp var createdAt: Timestamp?
    var createdBy: String
    var fromMemberId: String
    var toMemberId: String
    var amountCents: Int
    var note: String?
}

// MARK: - Balance Helpers

extension LootTab {
    /// Apply a receipt to member balances. Call within a Firestore transaction.
    /// The payer gets +totalCents, each split member gets -owedCents.
    mutating func applyReceipt(_ receipt: TabReceipt) {
        for split in receipt.splits {
            if let idx = members.firstIndex(where: { $0.memberId == split.memberId }) {
                members[idx].balanceCents -= split.owedCents
            }
        }
        if let payerIdx = members.firstIndex(where: { $0.memberId == receipt.payerMemberId }) {
            members[payerIdx].balanceCents += receipt.totalCents
        }
        receiptCount += 1
    }

    /// Apply a settlement to member balances. Call within a Firestore transaction.
    /// The debtor's balance increases (less negative), the creditor's decreases (less positive).
    mutating func applySettlement(_ settlement: Settlement) {
        if let fromIdx = members.firstIndex(where: { $0.memberId == settlement.fromMemberId }) {
            members[fromIdx].balanceCents += settlement.amountCents
        }
        if let toIdx = members.firstIndex(where: { $0.memberId == settlement.toMemberId }) {
            members[toIdx].balanceCents -= settlement.amountCents
        }
    }
}
