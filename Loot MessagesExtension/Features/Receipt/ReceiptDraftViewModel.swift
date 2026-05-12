//
//  ReceiptDraftViewModel.swift
//  Loot MessagesExtension
//
//  Phase 3 step 12a: takes ownership of `currentReceipt` and `currentSplitDraft`
//  off LootUIModel. The VM holds the in-flight bill state and exposes
//  pure-function reconciliation through the `ReceiptDraft` Domain aggregate.
//
//  The VM keeps `ReceiptDisplay` (UI-shaped) as the public type to minimize
//  diff size. The canonical `Receipt` Domain type only appears as a local
//  inside `reconcileWithLiveReceipt` / `applySplitDraftToCurrentReceipt`,
//  where it bridges to `ReceiptDraft`'s pure functions. A future step
//  migrates the public type to `Receipt`.
//
//  Step 12b moves the remaining draft-adjacent fields off LootUIModel
//  (`isLoadingReceipt`, `itemsLoadingState`, `phase2Task`, `parsedReceipt`,
//  `scanImage*`, `preTipTotalOverrideCents`, `debugChunkImages`).
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class ReceiptDraftViewModel: ObservableObject {
    @Published var currentReceipt: ReceiptDisplay? = nil
    @Published var currentSplitDraft: SplitDraft? = nil

    // MARK: - OCR pipeline state (moved from LootUIModel in step 12b)

    /// True while Phase 1 LLM extraction is in flight.
    @Published var isLoadingReceipt: Bool = false

    /// Phase 2 (itemized line extraction) loading state. Drives the
    /// "Loading receipt items..." indicator and the byItems split panel.
    @Published var itemsLoadingState: LoadingState<Phase2Result> = .idle

    /// Handle to the in-flight Phase 2 task so it can be cancelled when the
    /// user starts a new scan or aborts the flow. Not `@Published` —
    /// observers don't need to react to its identity, only to the loading
    /// state above.
    var phase2Task: Task<Void, Never>? = nil

    // MARK: - Scan / parse intermediates (moved from LootUIModel in step 12c)

    /// Raw Phase 1 LLM output. Used by the EditReceiptView "Override Total"
    /// flow and the bill card's pre-tip preview.
    @Published var parsedReceipt: ParsedReceipt? = nil

    /// Original captured image (camera or photo library) before cropping.
    @Published var scanImageOriginal: UIImage? = nil

    /// Receipt-region-cropped image used for OCR and display.
    @Published var scanImageCropped: UIImage? = nil

    /// Pre-tip total override entered in EditReceiptView. Persists across
    /// re-opens of the editor until the user clears it.
    @Published var preTipTotalOverrideCents: Int? = nil

    /// OCR chunk images for the debug viewer. Populated only when
    /// `RootContainerView.DEBUG_SHOW_CHUNKS == true`.
    @Published var debugChunkImages: [UIImage] = []

    // MARK: - Reconciliation

    /// Reconciles the split draft against the current receipt's totals after
    /// Phase 1/2 completion. Backed by `ReceiptDraft.reconciled()` (Domain).
    ///
    /// No-op when there's no receipt, no draft, or the aggregate's
    /// preconditions fail (zero total, no included guests, etc.). Behavior
    /// matches the legacy `RootContainerView.reconcileSplitDraftWithLiveReceipt`
    /// it replaced — see `TestHarness/Tests/LootDomainTests/ReceiptDraftTests.swift`
    /// for invariant coverage.
    func reconcileWithLiveReceipt(trigger: String) {
        guard let r = currentReceipt else { return }
        guard let draft = currentSplitDraft else { return }

        let aggregate = ReceiptDraft(
            receipt: receiptFromDisplay(r),
            split: draft
        )

        let reconciled = aggregate.reconciled().split
        guard reconciled != draft else { return }

        let previousTotal = draft.totalCents
        currentSplitDraft = reconciled
        if previousTotal != reconciled.totalCents {
            print("[SplitSync] Reconciled draft total after \(trigger): \(previousTotal) -> \(reconciled.totalCents)")
        }
    }

    // MARK: - Send-time apply

    /// Applies the split draft back onto the current receipt at send time.
    /// The tip-fold preamble is backed by `ReceiptDraft.foldingTip()` (Domain),
    /// which guards against the historical "tip applied twice" bug.
    ///
    /// Receipt rebuild (item conversion, subtotal derivation, ReceiptDisplay
    /// reconstruction) stays in this method because it's UI/wire glue, not
    /// domain reconciliation. The Domain layer never sees `ReceiptDisplay`.
    ///
    /// Called from the confirmation card's onSend just before `onSendBill`.
    func applySplitDraftToCurrentReceipt(_ draft: SplitDraft, tipAmount: String) {
        guard let r = currentReceipt else { return }
        var effectiveDraft = draft

        // Tip-fold: if the user typed a non-zero tip in confirmation state,
        // fold it into the draft so payload math and rendered totals agree.
        let tipFromConfirmationCents = stringToCents(tipAmount)
        let hasValidNonZeroTip = !tipAmount.isEmpty &&
            tipAmount != "$0" &&
            tipAmount != "$0.00" &&
            tipFromConfirmationCents > 0
        if hasValidNonZeroTip {
            // Build a probe aggregate purely to call foldingTip(); the receipt
            // half is discarded because the ReceiptDisplay rebuild below
            // re-derives those values from `effectiveDraft`. foldingTip()
            // replaces (not adds) tipCents and recomputes totalCents — see
            // `testFoldingTipReplacesNotAdds` in TestHarness.
            let folded = ReceiptDraft(
                receipt: receiptFromDisplay(r),
                split: effectiveDraft
            ).foldingTip(tipFromConfirmationCents)
            effectiveDraft = folded.split
        }

        let updatedItems: [ReceiptDisplay.Item] = {
            switch effectiveDraft.mode {
            case .byItems:
                return effectiveDraft.items.map { it in
                    // PersonID raw value: guest's Keychain userId when present,
                    // otherwise "slot-N" so the wire encoder's slotIndex(for:)
                    // helper can reverse it.
                    let assigneeIDs: [PersonID] = it.assignedGuestIds.compactMap { gid in
                        guard let idx = effectiveDraft.guests.firstIndex(where: { $0.id == gid }) else { return nil }
                        let g = effectiveDraft.guests[idx]
                        let raw = (g.userId?.isEmpty == false) ? g.userId! : "slot-\(idx)"
                        return PersonID(rawValue: raw)
                    }

                    return ReceiptDisplay.Item(
                        id: it.id.uuidString,
                        label: it.label,
                        priceCents: it.priceCents,
                        assigneeIDs: assigneeIDs
                    )
                }

            case .equally, .custom:
                return r.items.map { old in
                    ReceiptDisplay.Item(id: old.id, label: old.label, priceCents: old.priceCents,
                                        assigneeIDs: [])
                }
            }
        }()

        let subtotalFromItems = updatedItems.reduce(0) { $0 + $1.priceCents }
        // SplitDraft has no explicit subtotal field; derive a fallback from draft totals.
        let subtotalFromDraft = max(
            0,
            effectiveDraft.totalCents
                - effectiveDraft.feesCents
                + effectiveDraft.discountCents
                - effectiveDraft.taxCents
                - effectiveDraft.tipCents
        )
        let resolvedSubtotalCents: Int = {
            // Manual input commonly has no line items; preserve existing/draft-derived subtotal.
            if updatedItems.isEmpty && subtotalFromItems == 0 {
                return max(r.subtotalCents, subtotalFromDraft)
            }
            return subtotalFromItems
        }()

        currentReceipt = ReceiptDisplay(
            id: r.id,
            title: r.title,
            createdAt: r.createdAt,
            subtotalCents: resolvedSubtotalCents,
            feesCents: effectiveDraft.feesCents,
            discountCents: effectiveDraft.discountCents,
            taxCents: effectiveDraft.taxCents,
            tipCents: effectiveDraft.tipCents,
            totalCents: effectiveDraft.totalCents,
            items: updatedItems,
            lineItems: r.lineItems
        )

        currentSplitDraft = effectiveDraft
    }

    // MARK: - Reset

    /// Clears in-flight bill state. Called alongside `LootUIModel.resetForNewReceipt`.
    /// Also cancels any in-flight Phase 2 task so a new scan starts cleanly.
    func reset() {
        phase2Task?.cancel()
        phase2Task = nil
        currentReceipt = nil
        currentSplitDraft = nil
        itemsLoadingState = .idle
        isLoadingReceipt = false
        parsedReceipt = nil
        scanImageOriginal = nil
        scanImageCropped = nil
        preTipTotalOverrideCents = nil
        debugChunkImages = []
    }

    // MARK: - Bridge

    /// Builds a minimal `Receipt` (Domain) from a `ReceiptDisplay` for the
    /// pure-function reconciliation calls. Only `breakdown` is populated —
    /// `lines`/`auxLines` go unread by `reconciled()` and `foldingTip()`.
    /// Disappears when a future step migrates the public type to `Receipt`.
    private func receiptFromDisplay(_ r: ReceiptDisplay) -> Receipt {
        Receipt(
            id: r.id,
            title: r.title,
            createdAt: r.createdAt,
            breakdown: ReceiptBreakdown(
                subtotalCents: r.subtotalCents,
                feesCents: r.feesCents,
                taxCents: r.taxCents,
                tipCents: r.tipCents,
                discountCents: r.discountCents,
                totalCents: r.totalCents
            )
        )
    }
}
