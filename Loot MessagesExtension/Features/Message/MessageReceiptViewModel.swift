//
//  MessageReceiptViewModel.swift
//  Loot MessagesExtension
//
//  Phase 3 step 13a: takes ownership of opened-bubble state off LootUIModel.
//  When the user taps a Loot message, MessagesViewController.applyMessage
//  populates this VM (payload, docId, session, loading state, ignored-uuid
//  cache, pending pay/Apple-Pay state). The drawer's `.messageViewer` screen
//  drives off this VM.
//
//  Conceptually one instance per opened bubble — but there's only ever one
//  drawer open at a time, so a singleton owned by MessagesViewController
//  (parallel to `uiModel` and `receiptDraftVM`) matches lifecycle reality.
//  Step 13b introduces a `MessageBus` protocol so the four
//  UIKit-bridge closures (`sendBillUpdate`, `sendSettlementCard`, ...) stop
//  living on LootUIModel. Step 13c is per-bubble lifecycle refinement.
//
//  Helper methods (`isIgnoredUUID`, `setInlineIgnoredState`, ...) preserve
//  their LootUIModel signatures verbatim so consumer call sites can swap
//  `uiModel.X` → `messageReceiptVM.X` mechanically.
//

import Combine
import Foundation
import Messages
import SwiftUI

@MainActor
final class MessageReceiptViewModel: ObservableObject {

    // MARK: - Opened bubble state

    /// Decoded payload for the currently opened receipt bubble.
    @Published var openedMessagePayload: LootMessagePayload? = nil

    /// Firestore doc ID of the opened message (needed for updates like
    /// slot claims and bill-update broadcasts).
    @Published var openedMessageDocId: String? = nil

    /// Active iMessage session anchor for the currently opened bubble.
    /// Used by `sendBillUpdate` so Messages replaces the bubble in place
    /// rather than inserting a new one.
    @Published var activeMessageSession: MSSession? = nil

    /// Firestore message loading state — drives the spinner / error state
    /// in `messageViewerContent` while the doc is being fetched.
    @Published var messageLoadingState: LoadingState<LootMessagePayload> = .idle

    // MARK: - Ignored-UUID cache (per-bill)

    /// Map of billId -> ignored UUIDs. A non-empty list means the sender
    /// explicitly ignored those participants (they don't see the bubble).
    @Published var ignoredUUIDsByBill: [String: [String]] = [:]

    /// Map of billId -> whether the inline payload envelope had an explicit
    /// ignoredUUIDs list at all (vs. the field being absent).
    @Published var hasIgnoredUUIDsListByBill: [String: Bool] = [:]

    // MARK: - Pending payment state

    /// Pending payment-request card metadata — populated when the recipient
    /// of a pay-request bubble opens the drawer.
    @Published var pendingPayRequest: PendingPayRequest? = nil

    /// Apple Pay reminder for the LootTabView compact strip — set after the
    /// user picks Apple Pay so they see the payment info while reaching the
    /// iMessage Apple Cash drawer.
    @Published var pendingApplePayInfo: PendingApplePayInfo? = nil

    // MARK: - Ignored-UUID helpers

    func hasIgnoredUUIDsList(for billId: String?) -> Bool {
        guard let billId else { return false }
        return hasIgnoredUUIDsListByBill[billId] == true
    }

    func ignoredUUIDs(for billId: String?) -> [String] {
        guard let billId else { return [] }
        return ignoredUUIDsByBill[billId] ?? []
    }

    func setInlineIgnoredState(ignoredUUIDs: [String], hasList: Bool, for billId: String?) {
        guard let billId else { return }
        if hasList {
            hasIgnoredUUIDsListByBill[billId] = true
            ignoredUUIDsByBill[billId] = Self.normalizedUUIDs(ignoredUUIDs)
        } else {
            hasIgnoredUUIDsListByBill[billId] = false
            ignoredUUIDsByBill.removeValue(forKey: billId)
        }
    }

    func addIgnoredUUID(_ uuid: String, for billId: String?) {
        guard let billId else { return }
        let trimmed = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        hasIgnoredUUIDsListByBill[billId] = true
        var current = ignoredUUIDsByBill[billId] ?? []
        if !current.contains(trimmed) {
            current.append(trimmed)
            ignoredUUIDsByBill[billId] = current
        }
    }

    func removeIgnoredUUID(_ uuid: String, for billId: String?) {
        guard let billId else { return }
        let trimmed = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard hasIgnoredUUIDsList(for: billId) else { return }
        guard var current = ignoredUUIDsByBill[billId] else { return }
        current.removeAll { $0 == trimmed }
        ignoredUUIDsByBill[billId] = current
    }

    func isIgnoredUUID(_ uuid: String, for billId: String?) -> Bool {
        let trimmed = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return ignoredUUIDs(for: billId).contains(trimmed)
    }

    private static func normalizedUUIDs(_ uuids: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for raw in uuids {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                out.append(trimmed)
            }
        }
        return out
    }

    // MARK: - Reset

    /// Clears bubble + ignored-UUID + pending-pay state. Called from
    /// `LootUIModel.resetForNewReceipt` alongside the other VM resets so
    /// starting a new scan or returning to the landing screen wipes opened-
    /// bubble residue.
    func reset() {
        openedMessagePayload = nil
        openedMessageDocId = nil
        activeMessageSession = nil
        messageLoadingState = .idle
        ignoredUUIDsByBill = [:]
        hasIgnoredUUIDsListByBill = [:]
        pendingPayRequest = nil
        // Note: pendingApplePayInfo intentionally NOT cleared here — it
        // survives a `resetForNewReceipt` so the Apple Pay reminder stays
        // visible while the user navigates away to compose. The TabView
        // dismiss button is the only thing that clears it.
    }
}
