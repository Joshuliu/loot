//
//  LineItem.swift
//  Loot MessagesExtension
//
//  Canonical receipt line item. Phase 2 of the architectural refactor:
//  unifies the eight pre-refactor representations (ParsedReceipt.Item,
//  Phase2Result.Item, ReceiptDisplay.Item, ReceiptItem (Firestore),
//  ReceiptItemPayload (wire), EditableItem, EditableLineItem,
//  DraftReceiptItem).
//
//  The denormalized `responsible: [Responsible]` slot/displayName pair on the
//  legacy ReceiptDisplay.Item is replaced by `assigneeIDs: [PersonID]` —
//  callers can resolve names via the parent Receipt's participant list rather
//  than carrying a stale snapshot.
//

import Foundation

struct LineItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var label: String
    var priceCents: Int
    var quantity: Int
    /// IDs of participants responsible for this item (by-items split mode).
    /// Empty == unassigned (defaults to splitting among all included participants
    /// per the consuming SplitMath.computeOwed implementation).
    var assigneeIDs: [PersonID]

    init(
        id: UUID = UUID(),
        label: String,
        priceCents: Int,
        quantity: Int = 1,
        assigneeIDs: [PersonID] = []
    ) {
        self.id = id
        self.label = label
        self.priceCents = priceCents
        self.quantity = quantity
        self.assigneeIDs = assigneeIDs
    }

    /// True when this item is assigned to at least one participant.
    var hasAssignees: Bool { !assigneeIDs.isEmpty }

    /// Returns a normalized copy with whitespace-trimmed label.
    /// Items are typically created from user input (manual entry) or LLM output —
    /// both cases benefit from a single canonical normalization step.
    func normalized() -> LineItem {
        LineItem(
            id: id,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            priceCents: priceCents,
            quantity: quantity,
            assigneeIDs: assigneeIDs
        )
    }

    /// True if the label is non-empty after trimming. Used for "is this entry complete?" checks.
    var hasNonEmptyLabel: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// An auxiliary line displayed on a receipt — fees, taxes, discounts as discrete rows.
/// `cents` is signed: negative means a discount line.
///
/// Replaces `ReceiptDisplay.LineItem` (which conflicted naming-wise with the new
/// canonical `LineItem` for receipt items).
struct AuxLine: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var label: String
    /// Signed cents — negative values render as discounts.
    var cents: Int

    init(id: UUID = UUID(), label: String, cents: Int) {
        self.id = id
        self.label = label
        self.cents = cents
    }

    var isDiscount: Bool { cents < 0 }
}
