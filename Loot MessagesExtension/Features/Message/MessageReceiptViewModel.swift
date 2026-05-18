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
import FirebaseFirestore
import Foundation
import Messages
import SwiftUI

@MainActor
final class MessageReceiptViewModel: ObservableObject {

    // MARK: - Opened bubble state

    /// Decoded payload for the currently opened receipt bubble.
    @Published var openedMessagePayload: LootMessagePayload? = nil

    /// Firestore doc ID of the opened message (needed for updates like
    /// slot claims and bill-update broadcasts). The `didSet` swaps a
    /// Firestore snapshot listener via `syncOpenedReceiptListener` so the
    /// open drawer stays in sync with remote slot claims / bill edits.
    @Published var openedMessageDocId: String? = nil {
        didSet {
            syncOpenedReceiptListener(oldId: oldValue, newId: openedMessageDocId)
        }
    }

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

    // MARK: - Persistence

    /// Updates the in-memory payload with a new split, optionally broadcasts
    /// the change via the message bus (so iMessage retracts and replaces the
    /// bubble), and persists the updated payload to Firestore.
    ///
    /// No-op if no bubble is currently opened (no payload/docId).
    func persist(
        split: SplitPayload,
        broadcast: Bool = true,
        action: BillUpdateAction = .edited,
        via bus: MessageBus
    ) {
        guard var payload = openedMessagePayload,
              let docId = openedMessageDocId else { return }

        payload.s = split
        openedMessagePayload = payload
        if broadcast {
            bus.sendBillUpdate(payload: payload, docId: docId, action: action)
        }

        Task {
            do {
                try await SharedReceiptService.shared.updatePayload(payload, docId: docId)
                print("[MessageReceiptViewModel] Split persisted to \(docId)")
            } catch {
                print("[MessageReceiptViewModel] Failed to persist split: \(error)")
            }
        }
    }

    /// Persists both split + receipt items in one round trip. Used by the
    /// Tap-to-Claim recipient flow where claiming an item updates both the
    /// item's partition wire fields (rs/sh/cu) AND the recomputed `split.o`.
    /// State-before-broadcast: `openedMessagePayload` is mutated first, then
    /// the bus broadcast fires, then Firestore writes in a Task.
    func persist(
        split: SplitPayload,
        items: [ReceiptItemPayload],
        broadcast: Bool = true,
        action: BillUpdateAction = .edited,
        via bus: MessageBus
    ) {
        guard var payload = openedMessagePayload,
              let docId = openedMessageDocId else { return }

        payload.s = split
        payload.r.i = items
        openedMessagePayload = payload
        if broadcast {
            bus.sendBillUpdate(payload: payload, docId: docId, action: action)
        }

        Task {
            do {
                try await SharedReceiptService.shared.updatePayload(payload, docId: docId)
                print("[MessageReceiptViewModel] Payload persisted to \(docId)")
            } catch {
                print("[MessageReceiptViewModel] Failed to persist payload: \(error)")
            }
        }
    }

    // MARK: - Live receipt listener

    private var openedReceiptListener: ListenerRegistration? = nil

    /// Tracks which docId the current listener is bound to so listener-fed
    /// updates (which assign back to `openedMessagePayload` and may
    /// re-trigger view reloads) can reject stale-firing snapshots after a
    /// docId swap. Mirrors `TabContextViewModel.activeTabListenerId`.
    private var openedReceiptListenerDocId: String? = nil

    private func syncOpenedReceiptListener(oldId: String?, newId: String?) {
        // Same id (or both nil) means a redundant assignment — leave the
        // existing subscription alone. (Mirrors
        // TabContextViewModel.syncActiveTabListener.)
        guard oldId != newId else { return }

        openedReceiptListener?.remove()
        openedReceiptListener = nil
        openedReceiptListenerDocId = nil

        guard let newId, !newId.isEmpty else { return }

        openedReceiptListenerDocId = newId
        openedReceiptListener = SharedReceiptService.shared.listenToReceipt(docId: newId) { [weak self] payload in
            guard let self, self.openedReceiptListenerDocId == newId else { return }
            // Defensive equality check: skip if payload is unchanged. The
            // listener fires for the local user's OWN writes too (every
            // togglePaid / persistSplit / handleSplitSave round-trips
            // Firestore and bounces back through the snapshot), and we
            // don't want to re-render the view tree for a no-op update.
            // Bug #1's root cause was the same shape of redundant
            // @Published mutation; the equality check guards against
            // reintroducing it here.
            if self.openedMessagePayload != payload {
                self.openedMessagePayload = payload
            }
        }
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
