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
        // Normalize on read so we never operate on (and never round-trip back)
        // a tab whose `members` array contains duplicates.
        var tab = try snapshot.data(as: LootTab.self).dedupedMembers()

        let myId = KeychainHelper.getOrCreateUserId()
        let myName = myDisplayNameFromDefaults()
        let displayName = myName.isEmpty ? "Me" : myName

        let existingIdx = tab.members.firstIndex { member in
            member.memberId == myId || member.userId == myId
        }

        // Already an ACTIVE member: nothing to do beyond the conversation
        // mapping write. (Previously this also matched inactive past-member
        // entries, so a leave + re-tap-invite would silently no-op and the
        // joiner would never re-appear on either device.)
        if let idx = existingIdx, tab.members[idx].isActive {
            // Make sure memberIds is in sync with the active membership —
            // some legacy paths drifted this apart and the arrayContains
            // query in fetchUserTabs depends on memberIds.
            if !tab.memberIds.contains(myId) {
                tab.memberIds.append(myId)
                try await docRef.updateData([
                    "memberIds": tab.memberIds,
                    "updatedAt": FieldValue.serverTimestamp()
                ])
            }
            try await writeConversationMapping(tabId: tabId, conversationKey: conversationKey)
            print("[TabService] joinTab: \(tabId) (already active member, no-op)")
            return tab
        }

        if let idx = existingIdx {
            // Reactivate a past-member entry rather than appending a duplicate.
            tab.members[idx].isActive = true
            tab.members[idx].displayName = displayName
            if tab.members[idx].userId == nil || tab.members[idx].userId?.isEmpty == true {
                tab.members[idx].userId = myId
            }
            print("[TabService] joinTab: \(tabId) (reactivating past member)")
        } else {
            tab.members.append(TabMember(
                memberId: myId,
                userId: myId,
                displayName: displayName,
                balanceCents: 0,
                isActive: true
            ))
            print("[TabService] joinTab: \(tabId) (new member)")
        }

        if !tab.memberIds.contains(myId) {
            tab.memberIds.append(myId)
        }

        let encoded = try Firestore.Encoder().encode(tab)
        try await docRef.setData(encoded)
        try await writeConversationMapping(tabId: tabId, conversationKey: conversationKey)
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

        let tabs = snapshot.documents.compactMap { doc -> LootTab? in
            guard let raw = try? doc.data(as: LootTab.self) else { return nil }
            let cleaned = raw.dedupedMembers()
            if cleaned.members.count != raw.members.count {
                print("[TabService] fetchUserTabs deduped \(raw.members.count - cleaned.members.count) duplicate(s) in \(doc.documentID)")
                Task { try? await healDuplicateMembers(tab: cleaned) }
            }
            return cleaned
        }
        print("[TabService] fetchUserTabs: \(tabs.count) tabs")
        return tabs
    }

    func fetchTab(id: String) async throws -> LootTab? {
        try await SharedReceiptService.shared.ensureAnonymousAuth()

        let snapshot = try await db.collection("tabs").document(id).getDocument()
        guard snapshot.exists else { return nil }
        let raw = try snapshot.data(as: LootTab.self)
        let tab = raw.dedupedMembers()
        print("[TabService] fetchTab: \(id)")
        // If we just dropped duplicate members, write the cleaned tab back so
        // every other client and every future fetch sees normalized data.
        if tab.members.count != raw.members.count {
            print("[TabService] fetchTab(\(id)) deduped \(raw.members.count - tab.members.count) duplicate member(s); writing back")
            Task { try? await healDuplicateMembers(tab: tab) }
        }
        return tab
    }

    private func healDuplicateMembers(tab: LootTab) async throws {
        guard let tabId = tab.id else { return }
        let encodedMembers = try tab.members.map { try Firestore.Encoder().encode($0) }
        try await db.collection("tabs").document(tabId).updateData([
            "members": encodedMembers,
            "memberIds": tab.memberIds,
            "updatedAt": FieldValue.serverTimestamp()
        ])
        print("[TabService] healDuplicateMembers wrote back \(tab.members.count) members for \(tabId)")
    }

    /// Subscribes to live updates for a tab document. The handler fires on the
    /// main actor with the freshest decoded LootTab whenever the underlying
    /// Firestore document changes (other members joining, name/color edits,
    /// receipts being added that bump derived state). Returns a registration —
    /// call `.remove()` to stop listening.
    func listenToTab(tabId: String, onChange: @escaping @MainActor (LootTab) -> Void) -> ListenerRegistration {
        Task { try? await SharedReceiptService.shared.ensureAnonymousAuth() }

        return db.collection("tabs").document(tabId).addSnapshotListener { snapshot, error in
            if let error {
                print("[TabService] listenToTab(\(tabId)) error: \(error)")
                return
            }
            guard let snapshot, snapshot.exists else { return }
            guard let raw = try? snapshot.data(as: LootTab.self) else {
                print("[TabService] listenToTab(\(tabId)) decode failed")
                return
            }
            let tab = raw.dedupedMembers()
            Task { @MainActor in
                onChange(tab)
            }
        }
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

    /// Recomputes the tab's derived aggregates from sharedReceipts, with legacy
    /// fallback support for older tab receipt docs that may not have shared links.
    @discardableResult
    func syncTabDerivedState(tabId: String) async throws -> LootTab? {
        try await SharedReceiptService.shared.ensureAnonymousAuth()

        let tabRef = db.collection("tabs").document(tabId)
        guard var tab = try await fetchTab(id: tabId) else { return nil }

        let balances = try await computeTabBalances(tabId: tabId, members: tab.members)
        let receipts = try await fetchReceipts(forTab: tabId)

        for i in tab.members.indices {
            tab.members[i].balanceCents = balances[tab.members[i].memberId] ?? 0
        }
        tab.receiptCount = receipts.count

        let tabData = try Firestore.Encoder().encode(tab)
        try await tabRef.setData(tabData, merge: true)
        print("[TabService] syncTabDerivedState for tab \(tabId)")
        return tab
    }

    func removeReceiptFromTab(tabId: String, receiptId: String) async throws {
        try await SharedReceiptService.shared.ensureAnonymousAuth()

        let receiptRef = db.collection("tabs").document(tabId).collection("receipts").document(receiptId)
        try await receiptRef.delete()
        _ = try await syncTabDerivedState(tabId: tabId)
        print("[TabService] removeReceiptFromTab legacy cleanup for tab \(tabId)")
    }

    /// Computes net balances for all tab members by querying sharedReceipts + settlements.
    /// This is authoritative even for receipts sent before addReceipt was wired up.
    func computeTabBalances(tabId: String, members: [TabMember]) async throws -> [String: Int] {
        try await SharedReceiptService.shared.ensureAnonymousAuth()

        // Start with zero for each known member; tolerate duplicate memberIds
        // (corruption-recovery path also covered by `dedupedMembers()`).
        var balances: [String: Int] = Dictionary(
            members.map { ($0.memberId, 0) },
            uniquingKeysWith: { first, _ in first }
        )

        print("[BalanceAudit] === computeTabBalances tabId=\(tabId) ===")
        print("[BalanceAudit] members:")
        for m in members {
            print("[BalanceAudit]   memberId=\(m.memberId) name=\(m.displayName) userId=\(m.userId ?? "nil") active=\(m.isActive)")
        }

        let sharedPayloads = try await fetchSharedReceiptPayloads(forTabId: tabId)
        print("[BalanceAudit] sharedReceipts attached to this tab: \(sharedPayloads.count)")

        for entry in sharedPayloads {
            let before = balances
            applyBalanceDelta(from: entry.payload, into: &balances)
            let split = entry.payload.s
            let payerUid = split.g.indices.contains(split.pi) ? (split.g[split.pi].uid ?? "nil") : "out-of-bounds"
            let guestSummary = split.g.enumerated().map { i, g in
                "[\(i):\(g.n.isEmpty ? "<empty>" : g.n) inc=\(g.inc) uid=\(g.uid ?? "nil") owed=\(split.o.indices.contains(i) ? "\(split.o[i])" : "?")]"
            }.joined(separator: " ")
            print("[BalanceAudit] sharedReceipt docId=\(entry.docId) total=\(split.tot) payerUid=\(payerUid)")
            print("[BalanceAudit]   guests: \(guestSummary)")
            for (uid, after) in balances {
                let beforeAmt = before[uid] ?? 0
                if beforeAmt != after {
                    print("[BalanceAudit]   delta uid=\(uid): \(beforeAmt) -> \(after) (\(after - beforeAmt >= 0 ? "+" : "")\(after - beforeAmt))")
                }
            }
        }

        // Legacy fallback: keep supporting old tab receipt docs that may still
        // exist without a linked shared receipt doc.
        let legacyReceipts = try await fetchLegacyTabReceiptsNeedingFallback(forTabId: tabId)
        print("[BalanceAudit] legacy tab receipts (no linked shared doc): \(legacyReceipts.count)")
        for receipt in legacyReceipts {
            let before = balances
            applyBalanceDelta(from: receipt, into: &balances)
            print("[BalanceAudit] legacyReceipt id=\(receipt.id ?? "nil") title=\(receipt.title) total=\(receipt.totalCents) payer=\(receipt.payerMemberId)")
            for split in receipt.splits {
                print("[BalanceAudit]   split memberId=\(split.memberId) owed=\(split.owedCents)")
            }
            for (uid, after) in balances {
                let beforeAmt = before[uid] ?? 0
                if beforeAmt != after {
                    print("[BalanceAudit]   delta uid=\(uid): \(beforeAmt) -> \(after)")
                }
            }
        }

        // Apply any recorded settlements
        if let settlementDocs = try? await db.collection("tabs").document(tabId)
            .collection("settlements").getDocuments() {
            print("[BalanceAudit] settlements: \(settlementDocs.documents.count)")
            for doc in settlementDocs.documents {
                guard let settlement = try? doc.data(as: Settlement.self) else {
                    print("[BalanceAudit]   settlement docId=\(doc.documentID) FAILED to decode; raw=\(doc.data())")
                    continue
                }
                balances[settlement.fromMemberId, default: 0] += settlement.amountCents
                balances[settlement.toMemberId, default: 0] -= settlement.amountCents
                print("[BalanceAudit]   settlement docId=\(doc.documentID) from=\(settlement.fromMemberId) to=\(settlement.toMemberId) amount=\(settlement.amountCents)")
            }
        }

        print("[BalanceAudit] === final balances ===")
        for (uid, amt) in balances {
            print("[BalanceAudit]   \(uid) = \(amt) cents")
        }
        print("[BalanceAudit] === end audit ===")

        return balances
    }

    /// Fetches all receipts for a tab, ordered by creation date descending.
    func fetchReceipts(forTab tabId: String) async throws -> [TabReceipt] {
        try await SharedReceiptService.shared.ensureAnonymousAuth()
        guard let tab = try await fetchTab(id: tabId) else { return [] }

        let sharedPayloads = try await fetchSharedReceiptPayloads(forTabId: tabId)
        let sharedReceipts = sharedPayloads.map { entry in
            TabReceiptAdapter.fromPayload(entry.payload, messagePayloadId: entry.docId, tab: tab)
        }

        let legacyReceipts = try await fetchLegacyTabReceiptsNeedingFallback(forTabId: tabId)

        return (sharedReceipts + legacyReceipts).sorted {
            ($0.createdAt?.dateValue() ?? .distantPast) > ($1.createdAt?.dateValue() ?? .distantPast)
        }
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

    private func fetchSharedReceiptPayloads(forTabId tabId: String) async throws -> [(docId: String, payload: LootMessagePayload)] {
        let snapshot = try await db.collection("sharedReceipts")
            .whereField("tid", isEqualTo: tabId)
            .getDocuments()

        return snapshot.documents.compactMap { doc in
            guard let payload = decodeSharedReceiptPayload(from: doc.data()) else {
                print("[TabService] failed to decode sharedReceipt \(doc.documentID)")
                return nil
            }
            return (doc.documentID, payload)
        }
    }

    private func fetchLegacyTabReceipts(forTabId tabId: String) async throws -> [TabReceipt] {
        let snapshot = try await db.collection("tabs").document(tabId)
            .collection("receipts")
            .order(by: "createdAt", descending: true)
            .getDocuments()

        return snapshot.documents.compactMap { try? $0.data(as: TabReceipt.self) }
    }

    private func fetchLegacyTabReceiptsNeedingFallback(forTabId tabId: String) async throws -> [TabReceipt] {
        let legacyReceipts = try await fetchLegacyTabReceipts(forTabId: tabId)
        let linkedSharedIds = Set(legacyReceipts.compactMap(\.messagePayloadId))
        let existingSharedIds = try await fetchExistingSharedReceiptDocIds(linkedSharedIds)

        return legacyReceipts.filter { receipt in
            guard let messagePayloadId = receipt.messagePayloadId, !messagePayloadId.isEmpty else {
                return true
            }
            return !existingSharedIds.contains(messagePayloadId)
        }
    }

    private func fetchExistingSharedReceiptDocIds(_ docIds: Set<String>) async throws -> Set<String> {
        guard !docIds.isEmpty else { return [] }

        var existing: Set<String> = []
        for docId in docIds {
            let snapshot = try await db.collection("sharedReceipts").document(docId).getDocument()
            if snapshot.exists {
                existing.insert(docId)
            }
        }
        return existing
    }

    private func decodeSharedReceiptPayload(from dict: [String: Any]) -> LootMessagePayload? {
        var clean = dict
        clean.removeValue(forKey: "_createdAt")
        clean.removeValue(forKey: "_uid")
        clean.removeValue(forKey: "_captureImage")
        guard let data = try? JSONSerialization.data(withJSONObject: clean) else { return nil }
        return try? JSONDecoder().decode(LootMessagePayload.self, from: data)
    }

    private func applyBalanceDelta(from payload: LootMessagePayload, into balances: inout [String: Int]) {
        let split = payload.s

        for (i, guest) in split.g.enumerated() {
            guard guest.inc,
                  let uid = guest.uid, !uid.isEmpty,
                  split.o.indices.contains(i) else { continue }
            balances[uid, default: 0] -= split.o[i]
        }

        if split.g.indices.contains(split.pi),
           let payerUid = split.g[split.pi].uid, !payerUid.isEmpty {
            balances[payerUid, default: 0] += split.tot
        }
    }

    private func applyBalanceDelta(from receipt: TabReceipt, into balances: inout [String: Int]) {
        for split in receipt.splits {
            balances[split.memberId, default: 0] -= split.owedCents
        }
        balances[receipt.payerMemberId, default: 0] += receipt.totalCents
    }
}
