//
//  MessageReceiptViewer.swift
//  Loot
//
//  Created by Joshua Liu on 1/8/26.
//


import SwiftUI

struct MessageReceiptViewer: View {
    // Phase 3 step 13c (option α): plain `let` reference instead of
    // `@ObservedObject`. uiModel is still used imperatively in event
    // handlers (sendBillUpdate, mutating activeTab/receiptTab), but the
    // view no longer re-renders on every `@Published` change to uiModel.
    // userTabs (the only body-relevant uiModel field) is passed
    // explicitly from the parent. This eliminates spurious re-renders
    // during the broadcast retract window — see the deferred-bug entry
    // for the in-place bubble update bug for why that matters.
    let coordinator: AppCoordinator
    let userTabs: [LootTab]
    @ObservedObject var receiptDraftVM: ReceiptDraftViewModel
    @ObservedObject var messageReceiptVM: MessageReceiptViewModel
    @ObservedObject var tabContextVM: TabContextViewModel
    let bus: MessageBus
    let payload: LootMessagePayload
    let onClose: () -> Void
    let onRequestCollapse: () -> Void

    @State private var editSplitPayload: LootMessagePayload? = nil
    @State private var showEditReceipt: Bool = false
    /// Mirrors the compose-flow toast: after an Edit Splits save that
    /// leaves item cents unclaimed in non-claim byItems mode, surface the
    /// "remaining $X split evenly" rule so it doesn't look like a bug.
    @State private var showSplitEvenlyBanner: Bool = false
    @State private var splitEvenlyUnclaimedCents: Int = 0

    private var canEdit: Bool {
        let myUid = KeychainHelper.getOrCreateUserId()
        return payload.canEdit(myUid: myUid, userTabs: userTabs)
    }

    var body: some View {
        SplitsSummaryView(
            coordinator: coordinator,
            receiptDraftVM: receiptDraftVM,
            messageReceiptVM: messageReceiptVM,
            tabContextVM: tabContextVM,
            bus: bus,
            split: payload.s,
            items: payload.r.i,
            onEditSplit: {
                editSplitPayload = messageReceiptVM.openedMessagePayload ?? payload
            },
            onEditReceipt: {
                if canEdit {
                    showEditReceipt = true
                }
            },
            onRemoveFromTab: {
                if canEdit {
                    removeFromTab()
                }
            },
            onClose: {
                onClose()
            },
            onRequestCollapse: {
                onRequestCollapse()
            }
        )
        .id(messageReceiptVM.openedMessageDocId ?? payload.r.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { splitEvenlyBannerOverlay }
        .sheet(item: $editSplitPayload) { editPayload in
            let docId = messageReceiptVM.openedMessageDocId ?? editPayload.r.id
            EditSplitView(payload: editPayload, docId: docId, receiptImage: receiptDraftVM.scanImageCropped, onSave: { updatedPayload in
                handleSplitSave(updatedPayload)
                editSplitPayload = nil
            }, onCancel: {
                editSplitPayload = nil
            })
        }
        .sheet(isPresented: $showEditReceipt) {
            EditReceiptView(
                coordinator: coordinator,
                receiptDraftVM: receiptDraftVM,
                onSave: { updatedReceipt in
                    receiptDraftVM.currentReceipt = updatedReceipt
                    handleReceiptEdit(updatedReceipt)
                    showEditReceipt = false
                },
                onCancel: {
                    showEditReceipt = false
                }
            )
        }
        .task(id: messageReceiptVM.openedMessageDocId ?? payload.r.id) {
            autoPresentClaimIfNeeded()
        }
    }

    @ViewBuilder
    private var splitEvenlyBannerOverlay: some View {
        if showSplitEvenlyBanner {
            UnclaimedSplitToast(amountCents: splitEvenlyUnclaimedCents)
        }
    }

    /// After an Edit Splits save: if the bill is non-claim byItems and
    /// still has unclaimed item cents, surface the same transient toast as
    /// the compose flow so the "split evenly" redistribution doesn't read
    /// as a math error. Claim bills (cl == true) intentionally leave
    /// unclaimed unattributed, so they're excluded.
    private func maybeShowSplitEvenlyBanner(for payload: LootMessagePayload) {
        let s = payload.s
        guard s.m == .byItems, s.cl != true else { return }
        let slotPIDs = s.g.indices.map { s.g.personID(forSlot: $0) }
        let unclaimed = payload.r.i.reduce(0) { acc, it in
            acc + max(0, it.p - it.itemPartition(slotPersonIDs: slotPIDs)
                .claimedCents(priceCents: it.p))
        }
        guard unclaimed > 0 else { return }
        splitEvenlyUnclaimedCents = unclaimed
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            showSplitEvenlyBanner = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            withAnimation(.easeOut(duration: 0.3)) {
                showSplitEvenlyBanner = false
            }
        }
    }

    /// First time a recipient opens a recipients-claim bill they haven't
    /// claimed yet, jump straight into the claim popup (EditSplitView) so
    /// they can pick their items and Save (or Cancel). Skipped for the
    /// sender (they manage via Edit Splits) and once anything's claimed
    /// (they re-enter via "Modify claimed items").
    private func autoPresentClaimIfNeeded() {
        guard payload.s.cl == true, editSplitPayload == nil else { return }
        let myUid = KeychainHelper.getOrCreateUserId()
        if let su = payload.su, !su.isEmpty, su == myUid { return }
        // P0-4: a recipient who EXPLICITLY opted out (added to the per-bill
        // ignored list via "Leave this bill" / opt-out) must NOT get the
        // claim popup auto-re-presented on a subsequent re-tap. `claimed
        // == 0` alone can't distinguish "hasn't claimed yet" from "opted
        // out" — they both have zero claims. Re-entry for an opted-out
        // recipient is only via the explicit "I'm in this bill"
        // affordance, mirroring SplitsSummaryView's `didOptOut`
        // discriminator (feedback_claim_bill_state_model.md).
        let billId = messageReceiptVM.openedMessageDocId ?? payload.r.id
        if messageReceiptVM.isIgnoredUUID(myUid, for: billId) { return }
        let guests = payload.s.g
        let slotPIDs = guests.indices.map { guests.personID(forSlot: $0) }
        let myPID = PersonID(rawValue: myUid)
        let claimed = payload.r.i.reduce(0) {
            $0 + $1.itemPartition(slotPersonIDs: slotPIDs)
                .centsClaimed(by: myPID, priceCents: $1.p)
        }
        guard claimed == 0 else { return }
        editSplitPayload = messageReceiptVM.openedMessagePayload ?? payload
    }

    // MARK: - Receipt Edit Handler

    private func handleReceiptEdit(_ updatedReceipt: ReceiptDisplay) {
        guard var currentPayload = messageReceiptVM.openedMessagePayload else { return }
        let docId = messageReceiptVM.openedMessageDocId ?? currentPayload.r.id

        let oldTotal = currentPayload.s.tot
        let oldItems = currentPayload.r.i

        // Rebuild receipt payload from the updated receipt
        currentPayload.r = ReceiptPayload.from(receipt: updatedReceipt, split: currentPayload.s)

        // Preserve existing byItems assignments — EditReceiptView always saves
        // items with empty partitions, so ReceiptPayload.from emits no rs/sh/cu
        // slots. Re-apply the original slot assignments (rs + sh + cu) for
        // items that already existed in the wire payload.
        if currentPayload.s.m == .byItems {
            let oldByItemId = Dictionary(uniqueKeysWithValues: oldItems.map { ($0.id, $0) })
            currentPayload.r.i = currentPayload.r.i.map { item in
                var updated = item
                if let existing = oldByItemId[item.id] {
                    updated.rs = existing.rs
                    updated.sh = existing.sh
                    updated.cu = existing.cu
                }
                return updated
            }
        }

        currentPayload.s.tot = updatedReceipt.totalCents
        currentPayload.s.f = updatedReceipt.feesCents == 0 ? nil : updatedReceipt.feesCents
        currentPayload.s.d = updatedReceipt.discountCents == 0 ? nil : updatedReceipt.discountCents
        currentPayload.s.tx = updatedReceipt.taxCents == 0 ? nil : updatedReceipt.taxCents
        currentPayload.s.tip = updatedReceipt.tipCents == 0 ? nil : updatedReceipt.tipCents

        let totalChanged = oldTotal != updatedReceipt.totalCents

        switch currentPayload.s.m {
        case .equally:
            // Auto-recalculate owed amounts
            currentPayload.s.o = SplitMath.computeOwedCents(
                mode: .equally,
                guests: currentPayload.s.g,
                payerIndex: currentPayload.s.pi,
                totalCents: updatedReceipt.totalCents,
                perGuestActive: nil,
                items: [],
                feesCents: updatedReceipt.feesCents,
                discountCents: updatedReceipt.discountCents,
                taxCents: updatedReceipt.taxCents,
                tipCents: updatedReceipt.tipCents
            )
            messageReceiptVM.openedMessagePayload = currentPayload
            persistPayload(currentPayload, docId: docId)

        case .custom where totalChanged:
            // Proportionally scale custom amounts, then open split editor
            let oldOwed = currentPayload.s.o
            let included = currentPayload.s.g.indices.filter { currentPayload.s.g[$0].inc }
            let oldSum = included.reduce(0) { $0 + oldOwed[$1] }
            if oldSum > 0 {
                var scaled = oldOwed
                for idx in included {
                    scaled[idx] = Int(round(Double(oldOwed[idx]) * Double(updatedReceipt.totalCents) / Double(oldSum)))
                }
                // Fix rounding so it sums to new total
                let scaledSum = included.reduce(0) { $0 + scaled[$1] }
                let diff = updatedReceipt.totalCents - scaledSum
                if diff != 0, let first = included.first {
                    scaled[first] += diff
                }
                currentPayload.s.o = scaled
            }
            messageReceiptVM.openedMessagePayload = currentPayload
            editSplitPayload = currentPayload

        case .byItems:
            // Check if items were added
            let oldIds = Set(oldItems.map { $0.id })
            let newIds = Set(currentPayload.r.i.map { $0.id })
            let hasNewItems = !newIds.subtracting(oldIds).isEmpty

            // Recalculate owed from item assignments. Decode partition from
            // sh/cu/rs (with rs as the legacy fallback).
            let guests = currentPayload.s.g
            let canonicalSlotPIDs: [PersonID] = guests.indices.map { guests.personID(forSlot: $0) }
            let items = currentPayload.r.i.map { item -> (label: String, priceCents: Int, partition: ItemPartition) in
                (label: item.l, priceCents: item.p,
                 partition: item.itemPartition(slotPersonIDs: canonicalSlotPIDs))
            }
            currentPayload.s.o = SplitMath.computeOwedCents(
                mode: .byItems,
                guests: guests,
                payerIndex: currentPayload.s.pi,
                totalCents: updatedReceipt.totalCents,
                perGuestActive: nil,
                items: items,
                feesCents: updatedReceipt.feesCents,
                discountCents: updatedReceipt.discountCents,
                taxCents: updatedReceipt.taxCents,
                tipCents: updatedReceipt.tipCents,
                claimMode: currentPayload.s.cl ?? false
            )
            messageReceiptVM.openedMessagePayload = currentPayload

            if hasNewItems {
                // Open split editor so user can assign new items to guests
                editSplitPayload = currentPayload
            } else {
                persistPayload(currentPayload, docId: docId)
            }

        default:
            // .custom with no total change — just persist
            messageReceiptVM.openedMessagePayload = currentPayload
            persistPayload(currentPayload, docId: docId)
        }
    }

    // MARK: - Split Save Handler

    private func handleSplitSave(_ updatedPayload: LootMessagePayload) {
        let docId = messageReceiptVM.openedMessageDocId ?? updatedPayload.r.id
        messageReceiptVM.openedMessagePayload = updatedPayload
        receiptDraftVM.currentReceipt = updatedPayload.toReceiptDisplay()
        persistPayload(updatedPayload, docId: docId)
        // persistPayload broadcasts SYNCHRONOUSLY (bus.sendBillUpdate →
        // conversation.send on the bubble's MSSession). The toast mutates
        // host @State with an animation, which re-renders
        // MessageReceiptViewer. Per project_bill_update_state_order.md a
        // host re-render in the window between the broadcast and iOS
        // finishing the MSSession send makes iOS silently drop the
        // retract (no error, bubble unchanged). Defer the toast well
        // clear of that window so it can't disturb the send.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            maybeShowSplitEvenlyBanner(for: updatedPayload)
        }
    }

    private func removeFromTab() {
        guard var currentPayload = messageReceiptVM.openedMessagePayload,
              let tabId = currentPayload.tid, !tabId.isEmpty
        else { return }

        let docId = messageReceiptVM.openedMessageDocId ?? currentPayload.r.id
        // Capture the tab name BEFORE we strip the association — used in the
        // bubble's summaryText so the receiver sees "<sender> removed a bill
        // from <tabName>" instead of a generic "removed from a tab".
        let removedTabName = currentPayload.tab?.n
            ?? (tabContextVM.activeTab?.id == tabId ? tabContextVM.activeTab?.name : nil)

        currentPayload.tid = nil
        currentPayload.trid = nil
        currentPayload.tab = nil

        // Mirror `handleSplitSave` → `persistPayload`, which retracts reliably
        // for both same- and cross-sender. Order matters: update model state
        // first, then broadcast, then Firestore-write in a Task. Earlier
        // versions of removeFromTab broadcast first and tore down the drawer
        // (currentScreen = .tabview, openedMessagePayload = nil) which broke
        // the retract. Keep this method structurally identical to the edit
        // path — the only differences are the action (`.removedFromTab` vs
        // `.edited`) and the Firestore call (`clearTabAssociation` deletes
        // tid/trid/tab fields explicitly because JSONEncoder omits nil
        // optional properties, so a plain `updatePayload` merge would NOT
        // clear them in Firestore).
        messageReceiptVM.openedMessagePayload = currentPayload
        receiptDraftVM.currentReceipt = currentPayload.toReceiptDisplay()

        bus.sendBillUpdate(payload: currentPayload, docId: docId, action: .removedFromTab(tabName: removedTabName))

        // Tab UI optimistics — the LootTabView counter and balances refresh.
        // Matches what `persistPayload`'s Task does for tab-attached edits.
        if let active = tabContextVM.activeTab, active.id == tabId {
            var updated = active
            updated.receiptCount = max(0, active.receiptCount - 1)
            tabContextVM.activeTab = updated
            if let ck = tabContextVM.conversationKey {
                tabContextVM.cacheTab(updated, for: ck)
            }
        }
        if let receiptTab = tabContextVM.receiptTab, receiptTab.id == tabId {
            tabContextVM.receiptTab = nil
        }
        tabContextVM.tabReceiptsRefreshNonce += 1

        // Firestore write in the background (same shape as persistPayload).
        Task {
            do {
                try await SharedReceiptService.shared.clearTabAssociation(docId: docId)

                if let refreshed = try? await TabService.shared.syncTabDerivedState(tabId: tabId) {
                    await MainActor.run {
                        if self.tabContextVM.activeTab?.id == tabId {
                            self.tabContextVM.activeTab = refreshed
                            if let ck = self.tabContextVM.conversationKey {
                                tabContextVM.cacheTab(refreshed, for: ck)
                            }
                        }
                        self.tabContextVM.tabReceiptsRefreshNonce += 1
                    }
                }
                print("[MessageReceiptViewer] Removed receipt \(docId) from tab \(tabId)")
            } catch {
                print("[MessageReceiptViewer] Failed to remove receipt from tab: \(error)")
            }
        }
    }

    // MARK: - Firestore Persistence

    private func persistPayload(_ payload: LootMessagePayload, docId: String) {
        bus.sendBillUpdate(payload: payload, docId: docId, action: .edited)
        Task {
            do {
                try await SharedReceiptService.shared.updatePayload(payload, docId: docId)
                print("[MessageReceiptViewer] Persisted edit to Firestore: \(docId)")

                // Recompute tab aggregates if this receipt belongs to a tab.
                if let tabId = payload.tid, !tabId.isEmpty {
                    if let refreshed = try await TabService.shared.syncTabDerivedState(tabId: tabId) {
                        await MainActor.run {
                            // Don't reassign activeTab here. The Firestore listener
                            // bound by TabContextViewModel.syncActiveTabListener
                            // picks up the syncTabDerivedState write and assigns
                            // activeTab itself, mirroring to cache via
                            // TabContextViewModel.cacheTab. Reassigning explicitly
                            // fires a redundant @Published mutation that races
                            // with sheet dismiss when the sender edits a
                            // tab-attached bill — only the sender's path passes
                            // the `activeTab?.id == tabId` check (per applyTabData,
                            // receivers have receiptTab set instead). That extra
                            // re-render appears to invalidate iOS's cached
                            // MSSession reference for the bubble, causing the
                            // broadcast to append a new bubble instead of
                            // retracting in place. (Bug #1 root cause, May 8 2026.)
                            if self.tabContextVM.receiptTab?.id == tabId {
                                self.tabContextVM.receiptTab = refreshed
                            }
                            self.tabContextVM.tabReceiptsRefreshNonce += 1
                        }
                    }
                }
            } catch {
                print("[MessageReceiptViewer] Failed to persist edit: \(error)")
            }
        }
    }
}
