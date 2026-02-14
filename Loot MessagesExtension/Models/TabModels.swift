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
    var paymentMethods: [PaymentMethod]?
    @ServerTimestamp var createdAt: Timestamp?
    @ServerTimestamp var updatedAt: Timestamp?
}

// MARK: - Payment Methods

enum PaymentMethodType: String, Codable, CaseIterable {
    case venmo
    case zelle
    case cashapp
    case paypal
    case applePay
    case cash

    var displayName: String {
        switch self {
        case .venmo: return "Venmo"
        case .zelle: return "Zelle"
        case .cashapp: return "Cash App"
        case .paypal: return "PayPal"
        case .applePay: return "Apple Pay"
        case .cash: return "Cash"
        }
    }

    var iconName: String {
        switch self {
        case .venmo: return "v.square.fill"
        case .zelle: return "dollarsign.arrow.circlepath"
        case .cashapp: return "dollarsign.square.fill"
        case .paypal: return "p.square.fill"
        case .applePay: return "apple.logo"
        case .cash: return "banknote.fill"
        }
    }

    var requiresIdentifier: Bool {
        switch self {
        case .venmo, .zelle, .cashapp, .paypal: return true
        case .applePay, .cash: return false
        }
    }

    var identifierPlaceholder: String {
        switch self {
        case .venmo: return "@username"
        case .zelle: return "phone number or email"
        case .cashapp: return "$cashtag"
        case .paypal: return "username or email"
        case .applePay, .cash: return ""
        }
    }

    var identifierLabel: String {
        switch self {
        case .venmo: return "Username"
        case .zelle: return "Phone / Email"
        case .cashapp: return "Cashtag"
        case .paypal: return "Username / Email"
        case .applePay, .cash: return ""
        }
    }

    /// Builds a deep link URL for the payment app, or nil if no deep link exists.
    func deepLinkURL(identifier: String, amountCents: Int, note: String) -> URL? {
        let dollars = String(format: "%.2f", Double(amountCents) / 100.0)

        switch self {
        case .venmo:
            let user = identifier.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "@", with: "")
            guard !user.isEmpty else { return nil }
            var comps = URLComponents(string: "venmo://paycharge")!
            comps.queryItems = [
                URLQueryItem(name: "txn", value: "pay"),
                URLQueryItem(name: "recipients", value: user),
                URLQueryItem(name: "amount", value: dollars),
                URLQueryItem(name: "note", value: note)
            ]
            return comps.url

        case .cashapp:
            let tag = identifier.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "$", with: "")
            guard !tag.isEmpty else { return nil }
            return URL(string: "https://cash.app/$\(tag)/\(dollars)")

        case .paypal:
            let user = identifier.trimmingCharacters(in: .whitespaces)
            guard !user.isEmpty else { return nil }
            return URL(string: "https://paypal.me/\(user)/\(dollars)")

        case .zelle, .applePay, .cash:
            return nil
        }
    }
}

struct PaymentMethod: Codable, Identifiable, Equatable {
    var type: PaymentMethodType
    var identifier: String

    var id: String { type.rawValue }
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
