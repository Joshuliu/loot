//
//  ReceiptDraft.swift
//  Loot MessagesExtension
//
//  Phase 3 step 11: in-flight bill aggregate. Bundles a Receipt with a
//  SplitDraft so reconciliation and tip-fold operations live as pure
//  functions on a single value type. Pure Foundation; testable via the
//  TestHarness SPM target.
//
//  Step 11 wires `reconciled()` into the live reconciliation path
//  (RootContainerView.reconcileSplitDraftWithLiveReceipt). `foldingTip()`
//  is implemented + tested but not yet wired — step 12 (ReceiptDraftViewModel)
//  takes ownership of the aggregate and migrates the remaining imperative
//  reconciliation in `applySplitDraftToCurrentReceipt`.
//

import Foundation

struct ReceiptDraft: Equatable, Codable, Sendable {
    var receipt: Receipt
    var split: SplitDraft

    init(receipt: Receipt, split: SplitDraft) {
        self.receipt = receipt
        self.split = split
    }

    /// Returns a new draft where `split`'s monetary totals are copied from
    /// `receipt.breakdown`, `perGuestCents` is recomputed for `.equally` mode,
    /// and the payer is corrected if it falls outside the included set.
    ///
    /// No-ops (returns `self`):
    /// - `receipt.breakdown.totalCents <= 0` (no Phase-1 result yet)
    /// - no guests are included in the split
    ///
    /// Mirrors the imperative logic that lived in
    /// `RootContainerView.reconcileSplitDraftWithLiveReceipt` before step 11.
    func reconciled() -> ReceiptDraft {
        guard receipt.breakdown.totalCents > 0 else { return self }
        let active = split.includedGuests
        guard !active.isEmpty else { return self }

        var newSplit = split
        newSplit.totalCents = receipt.breakdown.totalCents
        newSplit.feesCents = receipt.breakdown.feesCents
        newSplit.discountCents = receipt.breakdown.discountCents
        newSplit.taxCents = receipt.breakdown.taxCents
        newSplit.tipCents = receipt.breakdown.tipCents

        if newSplit.mode == .equally {
            newSplit.perGuestCents = ReceiptDraft.equalSplitCents(
                total: receipt.breakdown.totalCents,
                count: active.count
            )
        }

        let payerStillValid = newSplit.guests.contains { g in
            g.id == newSplit.payerID && newSplit.includedIDs.contains(g.id)
        }
        if !payerStillValid {
            newSplit.payerID = active.first?.id ?? newSplit.payerID
        }

        return ReceiptDraft(receipt: receipt, split: newSplit)
    }

    /// Returns a new draft where the tip is **replaced** (not added) by
    /// `tipCents` on both the split and the receipt's breakdown.
    /// `totalCents` on each half is recomputed as `oldTotal - oldTip + newTip`.
    ///
    /// No-ops (returns `self`):
    /// - `tipCents <= 0`
    /// - `split.tipCents == tipCents` already
    ///
    /// Mirrors the tip-fold guard in
    /// `RootContainerView.applySplitDraftToCurrentReceipt` (which protects
    /// against the historical "tip applied twice" bug).
    func foldingTip(_ tipCents: Int) -> ReceiptDraft {
        guard tipCents > 0 else { return self }
        guard split.tipCents != tipCents else { return self }

        var newSplit = split
        let oldSplitTip = newSplit.tipCents
        newSplit.tipCents = tipCents
        newSplit.totalCents = max(0, newSplit.totalCents - oldSplitTip + tipCents)

        var newReceipt = receipt
        let oldReceiptTip = newReceipt.breakdown.tipCents
        newReceipt.breakdown.tipCents = tipCents
        newReceipt.breakdown.totalCents = max(
            0,
            newReceipt.breakdown.totalCents - oldReceiptTip + tipCents
        )

        return ReceiptDraft(receipt: newReceipt, split: newSplit)
    }

    /// Splits `total` cents across `count` slots, distributing the remainder
    /// to the earliest indices so shares always sum back to `total`.
    ///
    /// Duplicates the body of the free `splitCentsEvenly` function in
    /// `Utilities/MoneyHelpers.swift` because that file is not symlinked
    /// into the TestHarness SPM target. Phase 2.9 (or a later cleanup step)
    /// can dedupe by hoisting `splitCentsEvenly` into Domain/.
    static func equalSplitCents(total: Int, count: Int) -> [Int] {
        guard total > 0, count > 0 else { return Array(repeating: 0, count: max(0, count)) }
        var out = Array(repeating: total / count, count: count)
        let remainder = total - out.reduce(0, +)
        if remainder > 0 {
            for i in 0..<min(remainder, count) { out[i] += 1 }
        }
        return out
    }
}
