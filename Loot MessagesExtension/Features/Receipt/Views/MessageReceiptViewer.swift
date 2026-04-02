//
//  MessageReceiptViewer.swift
//  Loot
//
//  Created by Joshua Liu on 1/8/26.
//


import SwiftUI

struct MessageReceiptViewer: View {
    @ObservedObject var uiModel: LootUIModel
    let payload: LootMessagePayload
    let onClose: () -> Void
    let onRequestCollapse: () -> Void

    @State private var editSplitPayload: LootMessagePayload? = nil
    @State private var showEditReceipt: Bool = false

    private var canEdit: Bool {
        let myUid = KeychainHelper.getOrCreateUserId()
        return payload.canEdit(myUid: myUid, userTabs: uiModel.userTabs)
    }

    var body: some View {
        SplitsSummaryView(
            uiModel: uiModel,
            split: payload.s,
            items: payload.r.i,
            onEditSplit: {
                editSplitPayload = uiModel.openedMessagePayload ?? payload
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
            onRequestCollapse: {
                onRequestCollapse()
            }
        )
        .id(uiModel.openedMessageDocId ?? payload.r.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $editSplitPayload) { editPayload in
            let docId = uiModel.openedMessageDocId ?? editPayload.r.id
            EditSplitView(payload: editPayload, docId: docId, onSave: { updatedPayload in
                handleSplitSave(updatedPayload)
                editSplitPayload = nil
            }, onCancel: {
                editSplitPayload = nil
            })
        }
        .sheet(isPresented: $showEditReceipt) {
            EditReceiptView(
                uiModel: uiModel,
                onSave: { updatedReceipt in
                    uiModel.currentReceipt = updatedReceipt
                    handleReceiptEdit(updatedReceipt)
                    showEditReceipt = false
                },
                onCancel: {
                    showEditReceipt = false
                }
            )
        }
    }

    // MARK: - Receipt Edit Handler

    private func handleReceiptEdit(_ updatedReceipt: ReceiptDisplay) {
        guard var currentPayload = uiModel.openedMessagePayload else { return }
        let docId = uiModel.openedMessageDocId ?? currentPayload.r.id

        let oldTotal = currentPayload.s.tot
        let oldItems = currentPayload.r.i

        // Rebuild receipt payload from the updated receipt
        currentPayload.r = ReceiptPayload.from(receipt: updatedReceipt, split: currentPayload.s)

        // Preserve existing byItems assignments — EditReceiptView always saves items with
        // responsible: [], so ReceiptPayload.from clears rs for every item. Re-apply the
        // original slot assignments for items that already existed.
        if currentPayload.s.m == .byItems {
            let oldRsByItemId = Dictionary(uniqueKeysWithValues: oldItems.map { ($0.id, $0.rs) })
            currentPayload.r.i = currentPayload.r.i.map { item in
                var updated = item
                if let existingRs = oldRsByItemId[item.id] {
                    updated.rs = existingRs
                }
                return updated
            }
        }

        currentPayload.s.tot = updatedReceipt.totalCents
        currentPayload.s.f = updatedReceipt.feesCents == 0 ? nil : updatedReceipt.feesCents
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
                taxCents: updatedReceipt.taxCents,
                tipCents: updatedReceipt.tipCents
            )
            uiModel.openedMessagePayload = currentPayload
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
            uiModel.openedMessagePayload = currentPayload
            editSplitPayload = currentPayload

        case .byItems:
            // Check if items were added
            let oldIds = Set(oldItems.map { $0.id })
            let newIds = Set(currentPayload.r.i.map { $0.id })
            let hasNewItems = !newIds.subtracting(oldIds).isEmpty

            // Recalculate owed from item assignments
            let items = currentPayload.r.i.map { item in
                (label: item.l, priceCents: item.p, assignedSlots: item.rs)
            }
            currentPayload.s.o = SplitMath.computeOwedCents(
                mode: .byItems,
                guests: currentPayload.s.g,
                payerIndex: currentPayload.s.pi,
                totalCents: updatedReceipt.totalCents,
                perGuestActive: nil,
                items: items,
                feesCents: updatedReceipt.feesCents,
                taxCents: updatedReceipt.taxCents,
                tipCents: updatedReceipt.tipCents
            )
            uiModel.openedMessagePayload = currentPayload

            if hasNewItems {
                // Open split editor so user can assign new items to guests
                editSplitPayload = currentPayload
            } else {
                persistPayload(currentPayload, docId: docId)
            }

        default:
            // .custom with no total change — just persist
            uiModel.openedMessagePayload = currentPayload
            persistPayload(currentPayload, docId: docId)
        }
    }

    // MARK: - Split Save Handler

    private func handleSplitSave(_ updatedPayload: LootMessagePayload) {
        let docId = uiModel.openedMessageDocId ?? updatedPayload.r.id
        uiModel.openedMessagePayload = updatedPayload
        uiModel.currentReceipt = updatedPayload.toReceiptDisplay()
        persistPayload(updatedPayload, docId: docId)
    }

    private func removeFromTab() {
        guard var currentPayload = uiModel.openedMessagePayload,
              let tabId = currentPayload.tid, !tabId.isEmpty
        else { return }

        let docId = uiModel.openedMessageDocId ?? currentPayload.r.id

        currentPayload.tid = nil
        currentPayload.trid = nil
        currentPayload.tab = nil

        Task {
            do {
                try await SharedReceiptService.shared.clearTabAssociation(docId: docId)

                await MainActor.run {
                    uiModel.openedMessagePayload = currentPayload
                    uiModel.currentReceipt = currentPayload.toReceiptDisplay()
                    uiModel.tabReceiptsRefreshNonce += 1
                    if let active = uiModel.activeTab, active.id == tabId {
                        var updated = active
                        updated.receiptCount = max(0, active.receiptCount - 1)
                        uiModel.activeTab = updated
                        if let ck = uiModel.conversationKey {
                            TabService.shared.cacheTab(updated, for: ck)
                        }
                    }
                    if let receiptTab = uiModel.receiptTab, receiptTab.id == tabId {
                        uiModel.receiptTab = nil
                    }
                    uiModel.openedMessagePayload = nil
                    uiModel.openedMessageDocId = nil
                    uiModel.messageLoadingState = .idle
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        uiModel.currentScreen = .tabview
                    }
                }

                Task {
                    if let refreshed = try? await TabService.shared.syncTabDerivedState(tabId: tabId) {
                        await MainActor.run {
                            if self.uiModel.activeTab?.id == tabId {
                                self.uiModel.activeTab = refreshed
                                if let ck = self.uiModel.conversationKey {
                                    TabService.shared.cacheTab(refreshed, for: ck)
                                }
                            }
                            self.uiModel.tabReceiptsRefreshNonce += 1
                        }
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
        Task {
            do {
                try await SharedReceiptService.shared.updatePayload(payload, docId: docId)
                print("[MessageReceiptViewer] Persisted edit to Firestore: \(docId)")

                // Recompute tab aggregates if this receipt belongs to a tab.
                if let tabId = payload.tid, !tabId.isEmpty {
                    if let refreshed = try await TabService.shared.syncTabDerivedState(tabId: tabId) {
                        await MainActor.run {
                            if self.uiModel.activeTab?.id == tabId {
                                self.uiModel.activeTab = refreshed
                                if let ck = self.uiModel.conversationKey {
                                    TabService.shared.cacheTab(refreshed, for: ck)
                                }
                            }
                            if self.uiModel.receiptTab?.id == tabId {
                                self.uiModel.receiptTab = refreshed
                            }
                            self.uiModel.tabReceiptsRefreshNonce += 1
                        }
                    }
                }
            } catch {
                print("[MessageReceiptViewer] Failed to persist edit: \(error)")
            }
        }
    }
}
