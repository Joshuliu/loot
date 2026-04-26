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
        case .venmo, .cashapp, .paypal: return true
        case .zelle, .applePay, .cash: return false
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
    func deepLinkURL(identifier: String, amountCents: Int, note: String, bankURL: String? = nil, payeeName: String? = nil, zelleData: String? = nil) -> URL? {
        let dollars = Money(cents: amountCents).inputString

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

        case .zelle:
            guard let bankURL, !bankURL.isEmpty else { return nil }
            // Prefer stored QR data (exact match, no name guessing)
            if let data = zelleData, !data.isEmpty,
               let encoded = data.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                return URL(string: "\(bankURL)?context=qr-codes&data=s%2F%3Fdata%3D\(encoded)"
                    .replacingOccurrences(of: "http://", with: "https://"))
            }
            // Fallback: build from identifier (legacy / manual entry)
            let trimmed = identifier.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let digitsOnly = trimmed.filter(\.isNumber)
            let token = digitsOnly.count == 10 ? String(digitsOnly) : trimmed
            let firstName = (payeeName?.components(separatedBy: " ").first ?? "").uppercased()
            let json: [String: String] = ["name": firstName, "action": "payment", "token": token]
            guard let jsonData = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
                  let base64 = jsonData.base64EncodedString()
                    .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            else { return nil }
            return URL(string: "\(bankURL)?context=qr-codes&data=s%2F%3Fdata%3D\(base64)"
                .replacingOccurrences(of: "http://", with: "https://"))

        case .applePay, .cash:
            return nil
        }
    }
}

struct PaymentMethod: Codable, Identifiable, Equatable {
    var type: PaymentMethodType
    var identifier: String
    var bankName: String?
    var bankURL: String?
    /// Raw base64 data string extracted from a Zelle QR code URL (?data=…).
    /// Used directly in the deep link instead of constructing JSON from identifier.
    var zelleData: String?

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
    var discountCents: Int?
    var splitMode: SplitMode
    var payerMemberId: String
    var splits: [ReceiptSplit]
    var items: [ReceiptItem]?
    var imageUrl: String?
    var messagePayloadId: String?
}

// SplitMode is now defined in Domain/SplitConfiguration.swift as the canonical
// enum (Hashable + Sendable + CaseIterable on top of String + Codable). Raw
// values are unchanged, so existing Firestore documents and decoded
// LootMessagePayload data continue to round-trip cleanly.

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

// MARK: - TabReceipt Factory

extension TabReceipt {
    /// Creates a TabReceipt from a sent message payload and the active tab.
    static func from(payload: LootMessagePayload, messagePayloadId: String, tab: LootTab) -> TabReceipt {
        let myId = KeychainHelper.getOrCreateUserId()
        let split = payload.s
        let receipt = payload.r

        // Build a lookup from guest uid → tab memberId
        let uidToMemberId: [String: String] = Dictionary(
            uniqueKeysWithValues: tab.members.compactMap { m in
                guard let uid = m.userId, !uid.isEmpty else { return nil }
                return (uid, m.memberId)
            }
        )

        // Map payer slot to memberId
        let payerUid = split.g[split.pi].uid ?? myId
        let payerMemberId = uidToMemberId[payerUid] ?? myId

        // Map split mode
        let splitMode: SplitMode = {
            switch split.m {
            case .equally: return .equally
            case .custom: return .custom
            case .byItems: return .byItems
            }
        }()

        // Build splits: for each included guest, map to tab member
        let splits: [ReceiptSplit] = split.g.enumerated().compactMap { idx, guest in
            guard guest.inc, split.o.indices.contains(idx), split.o[idx] > 0 else { return nil }
            let uid = guest.uid ?? ""
            let memberId = uidToMemberId[uid] ?? uid
            guard !memberId.isEmpty else { return nil }
            return ReceiptSplit(memberId: memberId, owedCents: split.o[idx])
        }

        // Build items (if by-items mode)
        let items: [ReceiptItem]? = splitMode == .byItems ? receipt.i.map { item in
            let assignedMemberIds = item.rs.compactMap { slotIdx -> String? in
                guard split.g.indices.contains(slotIdx) else { return nil }
                let uid = split.g[slotIdx].uid ?? ""
                return uidToMemberId[uid] ?? uid
            }
            return ReceiptItem(
                label: item.l,
                priceCents: item.p,
                quantity: 1,
                assignedMemberIds: assignedMemberIds
            )
        } : nil

        return TabReceipt(
            title: receipt.t,
            createdBy: myId,
            createdAt: Timestamp(date: Date(timeIntervalSince1970: receipt.c)),
            totalCents: receipt.tot,
            subtotalCents: receipt.sub,
            taxCents: receipt.tx,
            tipCents: receipt.tip,
            feesCents: receipt.f,
            discountCents: receipt.d == 0 ? nil : receipt.d,
            splitMode: splitMode,
            payerMemberId: payerMemberId,
            splits: splits,
            items: items,
            imageUrl: nil,
            messagePayloadId: messagePayloadId
        )
    }
}

// MARK: - Minimal Tab Construction

extension LootTab {
    /// Builds a lightweight LootTab from inline payload data (no Firestore fetch needed).
    static func minimal(id: String, name: String, colorHex: String?) -> LootTab {
        var tab = LootTab(
            name: name,
            colorHex: colorHex,
            createdBy: "",
            status: .active,
            members: [],
            memberIds: [],
            receiptCount: 0
        )
        tab.id = id
        return tab
    }
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
