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
            userId: nil,
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
            userId: nil,
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
        try await SharedReceiptService.shared.ensureAnonymousAuth()

        let myId = KeychainHelper.getOrCreateUserId()
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

    // MARK: - Private

    private func writeConversationMapping(tabId: String, conversationKey: String) async throws {
        try await db.collection("conversationTabs").document(conversationKey).setData([
            "tabId": tabId,
            "updatedAt": FieldValue.serverTimestamp()
        ])
    }
}
