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

    enum Tab { case splits, receipt }
    @State private var tab: Tab = .splits
    @State private var showEditSplit: Bool = false
    @State private var editSplitPayload: LootMessagePayload? = nil

    private var captureImage: UIImage? {
        uiModel.scanImageCropped ?? uiModel.scanImageOriginal
    }

    private var canEdit: Bool {
        let myUid = KeychainHelper.getOrCreateUserId()
        return payload.canEdit(myUid: myUid, userTabs: uiModel.userTabs)
    }

    var body: some View {
        TabView(selection: $tab) {
            SplitsSummaryView(uiModel: uiModel, split: payload.s, items: payload.r.i, canEdit: canEdit, onEditSplit: {
                editSplitPayload = uiModel.openedMessagePayload ?? payload
                showEditSplit = true
            })
                .id(uiModel.openedMessageDocId ?? payload.r.id)
                .tabItem { Label("Splits", systemImage: "chart.pie.fill") }
                .tag(Tab.splits)

            Group {
                if let receipt = uiModel.currentReceipt {
                    ReceiptView(uiModel: uiModel, receipt: receipt, onBack: {}, showBackRow: false, showCaptureButton: true, compactCaptureButton: true, canEdit: canEdit, onPostSendSave: { updatedReceipt in
                        handleReceiptEdit(updatedReceipt)
                    })
                } else {
                    ProgressView("Loading…")
                }
            }
            .tabItem { Label("Receipt", systemImage: "doc.text.fill") }
            .tag(Tab.receipt)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbarBackground(.regularMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .sheet(isPresented: $showEditSplit) {
            if let editPayload = editSplitPayload, let docId = uiModel.openedMessageDocId {
                EditSplitView(payload: editPayload, docId: docId, onSave: { updatedPayload in
                    handleSplitSave(updatedPayload)
                    showEditSplit = false
                }, onCancel: {
                    showEditSplit = false
                })
            }
        }
        .onAppear {
            guard #unavailable(iOS 26) else { return }
            let appearance = UITabBarAppearance()
            appearance.configureWithDefaultBackground()
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }

    // MARK: - Receipt Edit Handler

    private func handleReceiptEdit(_ updatedReceipt: ReceiptDisplay) {
        guard var currentPayload = uiModel.openedMessagePayload,
              let docId = uiModel.openedMessageDocId else { return }

        let oldTotal = currentPayload.s.tot
        let oldItems = currentPayload.r.i

        // Rebuild receipt payload from the updated receipt
        currentPayload.r = ReceiptPayload.from(receipt: updatedReceipt, split: currentPayload.s)
        currentPayload.s.tot = updatedReceipt.totalCents
        currentPayload.s.f = updatedReceipt.feesCents == 0 ? nil : updatedReceipt.feesCents
        currentPayload.s.tx = updatedReceipt.taxCents == 0 ? nil : updatedReceipt.taxCents
        currentPayload.s.tip = updatedReceipt.tipCents == 0 ? nil : updatedReceipt.tipCents
        currentPayload.s.d = updatedReceipt.discountCents == 0 ? nil : updatedReceipt.discountCents

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
                tipCents: updatedReceipt.tipCents,
                discountCents: updatedReceipt.discountCents
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
            showEditSplit = true

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
                tipCents: updatedReceipt.tipCents,
                discountCents: updatedReceipt.discountCents
            )
            uiModel.openedMessagePayload = currentPayload

            if hasNewItems {
                // Open split editor so user can assign new items to guests
                editSplitPayload = currentPayload
                showEditSplit = true
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
        guard let docId = uiModel.openedMessageDocId else { return }
        uiModel.openedMessagePayload = updatedPayload
        uiModel.currentReceipt = updatedPayload.toReceiptDisplay()
        persistPayload(updatedPayload, docId: docId)
    }

    // MARK: - Firestore Persistence

    private func persistPayload(_ payload: LootMessagePayload, docId: String) {
        Task {
            do {
                try await SharedReceiptService.shared.updatePayload(payload, docId: docId)
                print("[MessageReceiptViewer] Persisted edit to Firestore: \(docId)")

                // Recompute tab balances if this receipt belongs to a tab
                if let tabId = payload.tid, !tabId.isEmpty {
                    if let tab = uiModel.receiptTab ?? uiModel.activeTab,
                       let trid = payload.trid {
                        let updatedTabReceipt = TabReceipt.from(payload: payload, messagePayloadId: docId, tab: tab)
                        try await TabService.shared.updateReceipt(updatedTabReceipt, inTab: tabId, receiptId: trid)
                        print("[MessageReceiptViewer] Updated TabReceipt and recomputed balances")
                    }
                }
            } catch {
                print("[MessageReceiptViewer] Failed to persist edit: \(error)")
            }
        }
    }
}
