//
//  TabService.swift
//  Loot MessagesExtension
//

import Foundation
import CryptoKit
import FirebaseFirestore

// MARK: - Tab Service

final class TabService {
    static let shared = TabService()
    private init() {}

    private lazy var db = Firestore.firestore()

    // MARK: - User

    /// Fetches the display name for a user from Firestore, or nil if not found.
    func fetchUserDisplayName(userId: String) async throws -> String? {
        try await SharedReceiptService.shared.ensureAnonymousAuth()

        let snapshot = try await db.collection("users").document(userId).getDocument()
        guard snapshot.exists, let data = snapshot.data() else { return nil }
        let name = data["displayName"] as? String
        return (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name
    }

    func createOrUpdateUser(userId: String, displayName: String) async throws {
        try await SharedReceiptService.shared.ensureAnonymousAuth()

        let docRef = db.collection("users").document(userId)
        let snapshot = try await docRef.getDocument()

        if snapshot.exists {
            // Update display name and timestamp only
            try await docRef.updateData([
                "displayName": displayName,
                "updatedAt": FieldValue.serverTimestamp()
            ])
        } else {
            // First time — set all fields
            try await docRef.setData([
                "displayName": displayName,
                "createdAt": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp()
            ])
        }
        print("[TabService] createOrUpdateUser: \(userId)")
    }

    // MARK: - Tab CRUD

    /// Pre-generates a Firestore document ID for a tab (no network call).
    func generateTabId() -> String {
        db.collection("tabs").document().documentID
    }

    /// Creates a local LootTab object with a pre-generated ID (no network).
    func createLocalTab(name: String, colorHex: String = "005377", tabId: String) -> LootTab {
        let myId = KeychainHelper.getOrCreateUserId()
        let myName = myDisplayNameFromDefaults()
        let me = TabMember(
            memberId: myId,
            userId: myId,
            displayName: myName.isEmpty ? "Me" : myName,
            balanceCents: 0,
            isActive: true
        )
        var tab = LootTab(
            name: name,
            colorHex: colorHex,
            createdBy: myId,
            status: .active,
            members: [me],
            memberIds: [myId],
            receiptCount: 0
        )
        tab.id = tabId
        return tab
    }

    /// Uploads a pre-built tab to Firestore with the given doc ID.
    func uploadTab(_ tab: LootTab, tabId: String, conversationKey: String) async throws {
        try await SharedReceiptService.shared.ensureAnonymousAuth()

        let encoded = try Firestore.Encoder().encode(tab)
        try await db.collection("tabs").document(tabId).setData(encoded)

        // Write conversation → tab mapping
        try await writeConversationMapping(tabId: tabId, conversationKey: conversationKey)

        print("[TabService] uploadTab: \(tabId)")
    }

    func createTab(name: String, colorHex: String = "005377", conversationKey: String) async throws -> LootTab {
        let tabId = generateTabId()
        let tab = createLocalTab(name: name, colorHex: colorHex, tabId: tabId)
        try await uploadTab(tab, tabId: tabId, conversationKey: conversationKey)
        return tab
    }

    func joinTab(tabId: String, conversationKey: String) async throws -> LootTab {
        try await SharedReceiptService.shared.ensureAnonymousAuth()

        let docRef = db.collection("tabs").document(tabId)
        let snapshot = try await docRef.getDocument()
        guard snapshot.exists else {
            throw NSError(domain: "TabService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Tab not found"])
        }
        var tab = try snapshot.data(as: LootTab.self)

        let myId = KeychainHelper.getOrCreateUserId()

        // Don't add if already a member
        guard !tab.memberIds.contains(myId) else {
            try await writeConversationMapping(tabId: tabId, conversationKey: conversationKey)
            return tab
        }

        let myName = myDisplayNameFromDefaults()
        let me = TabMember(
            memberId: myId,
            userId: myId,
            displayName: myName.isEmpty ? "Me" : myName,
            balanceCents: 0,
            isActive: true
        )

        tab.members.append(me)
        tab.memberIds.append(myId)

        // Update the tab document
        let encoded = try Firestore.Encoder().encode(tab)
        try await docRef.setData(encoded)

        // Write conversation → tab mapping
        try await writeConversationMapping(tabId: tabId, conversationKey: conversationKey)

        print("[TabService] joinTab: \(tabId)")
        return tab
    }

    func fetchUserTabs() async throws -> [LootTab] {
        print("[TabService] fetchUserTabs: starting auth...")
        try await SharedReceiptService.shared.ensureAnonymousAuth()

        let myId = KeychainHelper.getOrCreateUserId()
        print("[TabService] fetchUserTabs: querying for userId=\(myId)")
        let snapshot = try await db.collection("tabs")
            .whereField("memberIds", arrayContains: myId)
            .getDocuments()

        let tabs = snapshot.documents.compactMap { doc in
            try? doc.data(as: LootTab.self)
        }
        print("[TabService] fetchUserTabs: \(tabs.count) tabs")
        return tabs
    }

    func fetchTab(id: String) async throws -> LootTab? {
        try await SharedReceiptService.shared.ensureAnonymousAuth()

        let snapshot = try await db.collection("tabs").document(id).getDocument()
        guard snapshot.exists else { return nil }
        let tab = try snapshot.data(as: LootTab.self)
        print("[TabService] fetchTab: \(id)")
        return tab
    }

    func associateConversation(tabId: String, conversationKey: String) async throws {
        try await SharedReceiptService.shared.ensureAnonymousAuth()
        try await writeConversationMapping(tabId: tabId, conversationKey: conversationKey)
        print("[TabService] associateConversation: \(tabId) -> \(conversationKey)")
    }

    func getTabForConversation(conversationKey: String) async throws -> LootTab? {
        try await SharedReceiptService.shared.ensureAnonymousAuth()

        let snapshot = try await db.collection("conversationTabs").document(conversationKey).getDocument()
        guard let data = snapshot.data(), let tabId = data["tabId"] as? String else {
            return nil
        }
        return try await fetchTab(id: tabId)
    }

    // MARK: - Conversation Key

    static func conversationKey(from participantIdentifiers: [String]) -> String {
        let sorted = participantIdentifiers.map { $0.lowercased() }.sorted()
        let joined = sorted.joined(separator: "|")
        let hash = SHA256.hash(data: Data(joined.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Local Cache

    /// Returns the cached LootTab for a conversation (instant, no network).
    func cachedTab(for conversationKey: String) -> LootTab? {
        guard let dict = UserDefaults.standard.dictionary(forKey: cacheKey(for: conversationKey)),
              let name = dict["name"] as? String,
              let createdBy = dict["createdBy"] as? String,
              let statusRaw = dict["status"] as? String,
              let status = TabStatus(rawValue: statusRaw),
              let memberIds = dict["memberIds"] as? [String],
              let receiptCount = dict["receiptCount"] as? Int,
              let membersArray = dict["members"] as? [[String: Any]]
        else { return nil }

        let members = membersArray.compactMap { m -> TabMember? in
            guard let memberId = m["memberId"] as? String,
                  let displayName = m["displayName"] as? String,
                  let balanceCents = m["balanceCents"] as? Int,
                  let isActive = m["isActive"] as? Bool
            else { return nil }
            return TabMember(
                memberId: memberId,
                userId: m["userId"] as? String,
                displayName: displayName,
                balanceCents: balanceCents,
                isActive: isActive
            )
        }

        var tab = LootTab(
            name: name,
            colorHex: dict["colorHex"] as? String,
            createdBy: createdBy,
            status: status,
            members: members,
            memberIds: memberIds,
            receiptCount: receiptCount
        )
        tab.id = dict["id"] as? String
        return tab
    }

    /// Persists the active tab for a conversation locally.
    func cacheTab(_ tab: LootTab?, for conversationKey: String) {
        let key = cacheKey(for: conversationKey)
        guard let tab else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        let dict: [String: Any] = [
            "id": tab.id ?? "",
            "name": tab.name,
            "colorHex": tab.colorHex ?? "",
            "createdBy": tab.createdBy,
            "status": tab.status.rawValue,
            "memberIds": tab.memberIds,
            "receiptCount": tab.receiptCount,
            "members": tab.members.map { m -> [String: Any] in
                [
                    "memberId": m.memberId,
                    "userId": m.userId ?? "",
                    "displayName": m.displayName,
                    "balanceCents": m.balanceCents,
                    "isActive": m.isActive
                ]
            }
        ]
        UserDefaults.standard.set(dict, forKey: key)
    }

    private func cacheKey(for conversationKey: String) -> String {
        "\(DefaultsKeys.conversationTabMap)_\(conversationKey)"
    }

    // MARK: - Tab Update

    /// Updates tab name, color, members, and memberIds in Firestore.
    func updateTab(_ tab: LootTab) async throws {
        try await SharedReceiptService.shared.ensureAnonymousAuth()
        guard let tabId = tab.id else { return }

        let encodedMembers = try tab.members.map { try Firestore.Encoder().encode($0) }
        try await db.collection("tabs").document(tabId).updateData([
            "name": tab.name,
            "colorHex": tab.colorHex as Any,
            "members": encodedMembers,
            "memberIds": tab.memberIds,
            "updatedAt": FieldValue.serverTimestamp()
        ])
        print("[TabService] updateTab: \(tabId)")
    }

    // MARK: - Leave Tab

    /// Marks the current user as inactive and removes them from memberIds.
    /// Their historical receipt/settlement data is preserved via the members array.
    func leaveTab(tabId: String) async throws {
        try await SharedReceiptService.shared.ensureAnonymousAuth()
        let myId = KeychainHelper.getOrCreateUserId()

        let docRef = db.collection("tabs").document(tabId)
        let snapshot = try await docRef.getDocument()
        guard snapshot.exists else {
            throw NSError(domain: "TabService", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "Tab not found"])
        }
        var tab = try snapshot.data(as: LootTab.self)

        // Mark inactive (preserves balance history and name lookups)
        if let idx = tab.members.firstIndex(where: { $0.memberId == myId }) {
            tab.members[idx].isActive = false
        }
        // Remove from memberIds so Firestore queries exclude this user
        tab.memberIds.removeAll { $0 == myId }

        let encodedMembers = try tab.members.map { try Firestore.Encoder().encode($0) }
        try await docRef.updateData([
            "members": encodedMembers,
            "memberIds": tab.memberIds,
            "updatedAt": FieldValue.serverTimestamp()
        ])
        print("[TabService] leaveTab: \(tabId)")
    }

    // MARK: - Delete Tab

    /// Deletes the tab document entirely (use only when you are the sole active member).
    /// Subcollections become orphaned but are preserved for records.
    func deleteTab(tabId: String) async throws {
        try await SharedReceiptService.shared.ensureAnonymousAuth()
        try await db.collection("tabs").document(tabId).delete()
        print("[TabService] deleteTab: \(tabId)")
    }

    // MARK: - Payment Methods

    func updatePaymentMethods(userId: String, methods: [PaymentMethod]) async throws {
        try await SharedReceiptService.shared.ensureAnonymousAuth()

        let encoded = try methods.map { try Firestore.Encoder().encode($0) }
        try await db.collection("users").document(userId).updateData([
            "paymentMethods": encoded,
            "updatedAt": FieldValue.serverTimestamp()
        ])
        print("[TabService] updatePaymentMethods: \(methods.count) methods for \(userId)")
    }

    func fetchPaymentMethods(userId: String) async throws -> [PaymentMethod]? {
        try await SharedReceiptService.shared.ensureAnonymousAuth()

        let snapshot = try await db.collection("users").document(userId).getDocument()
        guard snapshot.exists, let data = snapshot.data(),
              let raw = data["paymentMethods"] as? [[String: Any]]
        else { return nil }

        return raw.compactMap { dict -> PaymentMethod? in
            guard let typeStr = dict["type"] as? String,
                  let type = PaymentMethodType(rawValue: typeStr)
            else { return nil }
            let identifier = dict["identifier"] as? String ?? ""
            let bankName = dict["bankName"] as? String
            let bankURL = dict["bankURL"] as? String
            let zelleData = dict["zelleData"] as? String
            return PaymentMethod(type: type, identifier: identifier, bankName: bankName, bankURL: bankURL, zelleData: zelleData)
        }
    }

    // MARK: - Tab Receipts

    /// Adds a receipt to a tab, updating member balances atomically.
    /// Returns the generated receipt document ID.
    func addReceipt(_ receipt: TabReceipt, toTab tabId: String) async throws -> String {
        try await SharedReceiptService.shared.ensureAnonymousAuth()

        let tabRef = db.collection("tabs").document(tabId)
        let receiptRef = tabRef.collection("receipts").document()

        _ = try await db.runTransaction { transaction, errorPointer in
            let tabSnapshot: DocumentSnapshot
            do {
                tabSnapshot = try transaction.getDocument(tabRef)
            } catch let fetchError as NSError {
                errorPointer?.pointee = fetchError
                return nil
            }

            guard var tab = try? tabSnapshot.data(as: LootTab.self) else {
                let err = NSError(domain: "TabService", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Tab not found"])
                errorPointer?.pointee = err
                return nil
            }

            tab.applyReceipt(receipt)

            do {
                let tabData = try Firestore.Encoder().encode(tab)
                transaction.setData(tabData, forDocument: tabRef)

                let receiptData = try Firestore.Encoder().encode(receipt)
                transaction.setData(receiptData, forDocument: receiptRef)
            } catch let encodeError as NSError {
                errorPointer?.pointee = encodeError
                return nil
            }

            return nil
        }

        print("[TabService] addReceipt to tab \(tabId): \(receiptRef.documentID)")
        return receiptRef.documentID
    }

    /// Records a settlement, updating member balances atomically.
    func recordSettlement(_ settlement: Settlement, forTab tabId: String) async throws {
        try await SharedReceiptService.shared.ensureAnonymousAuth()

        let tabRef = db.collection("tabs").document(tabId)
        let settlementRef = tabRef.collection("settlements").document()

        _ = try await db.runTransaction { transaction, errorPointer in
            let tabSnapshot: DocumentSnapshot
            do {
                tabSnapshot = try transaction.getDocument(tabRef)
            } catch let fetchError as NSError {
                errorPointer?.pointee = fetchError
                return nil
            }

            guard var tab = try? tabSnapshot.data(as: LootTab.self) else {
                let err = NSError(domain: "TabService", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Tab not found"])
                errorPointer?.pointee = err
                return nil
            }

            tab.applySettlement(settlement)

            do {
                let tabData = try Firestore.Encoder().encode(tab)
                transaction.setData(tabData, forDocument: tabRef)

                let settlementData = try Firestore.Encoder().encode(settlement)
                transaction.setData(settlementData, forDocument: settlementRef)
            } catch let encodeError as NSError {
                errorPointer?.pointee = encodeError
                return nil
            }

            return nil
        }

        print("[TabService] recordSettlement for tab \(tabId)")
    }

    /// Computes net balances for all tab members by querying sharedReceipts + settlements.
    /// This is authoritative even for receipts sent before addReceipt was wired up.
    func computeTabBalances(tabId: String, members: [TabMember]) async throws -> [String: Int] {
        try await SharedReceiptService.shared.ensureAnonymousAuth()

        // Start with zero for each known member
        var balances: [String: Int] = Dictionary(uniqueKeysWithValues:
            members.map { ($0.memberId, 0) })

        // Fetch every sharedReceipt that belongs to this tab
        let snapshot = try await db.collection("sharedReceipts")
            .whereField("tid", isEqualTo: tabId)
            .getDocuments()

        for doc in snapshot.documents {
            let dict = doc.data()

            // Extract split data directly from the Firestore dict to avoid the
            // JSON round-trip (Firestore returns numbers as Double/Int64, which
            // causes JSONDecoder to fail on Int fields in LootMessagePayload).
            guard let splitDict = dict["s"] as? [String: Any],
                  let guestsArray = splitDict["g"] as? [[String: Any]],
                  let owedAny = splitDict["o"] as? [Any]
            else {
                print("[TabService] computeTabBalances: skipping doc \(doc.documentID) — missing s/g/o fields")
                continue
            }

            func toInt(_ v: Any?) -> Int {
                if let i = v as? Int { return i }
                if let d = v as? Double { return Int(d) }
                return 0
            }

            let payerIndex = toInt(splitDict["pi"])
            let total = toInt(splitDict["tot"])
            let owed = owedAny.map { toInt($0) }

            // Each included guest owes their share
            for (i, guestDict) in guestsArray.enumerated() {
                let inc = guestDict["inc"] as? Bool ?? false
                guard inc,
                      let uid = guestDict["uid"] as? String, !uid.isEmpty,
                      owed.indices.contains(i)
                else { continue }
                balances[uid, default: 0] -= owed[i]
            }

            // Payer gets the full total back
            if guestsArray.indices.contains(payerIndex),
               let payerUid = guestsArray[payerIndex]["uid"] as? String, !payerUid.isEmpty {
                balances[payerUid, default: 0] += total
            }
        }

        // Apply any recorded settlements
        if let settlementDocs = try? await db.collection("tabs").document(tabId)
            .collection("settlements").getDocuments() {
            for doc in settlementDocs.documents {
                guard let settlement = try? doc.data(as: Settlement.self) else { continue }
                balances[settlement.fromMemberId, default: 0] += settlement.amountCents
                balances[settlement.toMemberId, default: 0] -= settlement.amountCents
            }
        }

        return balances
    }

    /// Fetches all receipts for a tab, ordered by creation date descending.
    func fetchReceipts(forTab tabId: String) async throws -> [TabReceipt] {
        try await SharedReceiptService.shared.ensureAnonymousAuth()

        let snapshot = try await db.collection("tabs").document(tabId)
            .collection("receipts")
            .order(by: "createdAt", descending: true)
            .getDocuments()

        return snapshot.documents.compactMap { try? $0.data(as: TabReceipt.self) }
    }

    /// Fetches all settlements for a tab, ordered by creation date descending.
    func fetchSettlements(forTab tabId: String) async throws -> [Settlement] {
        try await SharedReceiptService.shared.ensureAnonymousAuth()

        let snapshot = try await db.collection("tabs").document(tabId)
            .collection("settlements")
            .order(by: "createdAt", descending: true)
            .getDocuments()

        return snapshot.documents.compactMap { try? $0.data(as: Settlement.self) }
    }

    func removeConversationMapping(conversationKey: String) async throws {
        try await SharedReceiptService.shared.ensureAnonymousAuth()
        try await db.collection("conversationTabs").document(conversationKey).delete()
        print("[TabService] removeConversationMapping: \(conversationKey)")
    }

    // MARK: - Private

    private func writeConversationMapping(tabId: String, conversationKey: String) async throws {
        try await db.collection("conversationTabs").document(conversationKey).setData([
            "tabId": tabId,
            "updatedAt": FieldValue.serverTimestamp()
        ])
    }
}
