//
//  Receipt.swift
//  Loot MessagesExtension
//
//  Canonical receipt aggregate. Phase 2 of the architectural refactor:
//  replaces the legacy ReceiptDisplay (UI-only) and TabReceipt (storage-only)
//  domain forms with a single shape. ReceiptBreakdown holds the monetary
//  totals; lines holds itemized purchases; auxLines holds individual fee/tax/
//  discount rows for display.
//

import Foundation

struct ReceiptBreakdown: Codable, Hashable, Sendable {
    var subtotalCents: Int
    var feesCents: Int
    var taxCents: Int
    var tipCents: Int
    var discountCents: Int
    var totalCents: Int

    init(
        subtotalCents: Int = 0,
        feesCents: Int = 0,
        taxCents: Int = 0,
        tipCents: Int = 0,
        discountCents: Int = 0,
        totalCents: Int = 0
    ) {
        self.subtotalCents = subtotalCents
        self.feesCents = feesCents
        self.taxCents = taxCents
        self.tipCents = tipCents
        self.discountCents = discountCents
        self.totalCents = totalCents
    }

    static let zero = ReceiptBreakdown()

    /// True when only `totalCents` is meaningful (matches legacy
    /// `ReceiptDisplay.shouldShowOnlyTotal` semantics).
    var hasOnlyTotal: Bool {
        feesCents == 0 && discountCents == 0 && taxCents == 0 && tipCents == 0
    }

    /// Computes the "expected" total from the breakdown components.
    /// Useful as a sanity check; does not mutate `totalCents`. Discount is
    /// subtracted because it's stored as a positive magnitude (not signed).
    var derivedTotalCents: Int {
        subtotalCents + feesCents + taxCents + tipCents - discountCents
    }

    /// True if `totalCents` matches the algebraic combination of the parts.
    /// Most receipts satisfy this, but rounding in upstream sources (LLM, Firestore)
    /// may produce small discrepancies — we trust the explicit `totalCents` value.
    var isInternallyConsistent: Bool {
        totalCents == derivedTotalCents
    }
}

struct Receipt: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var createdAt: Date?
    var lines: [LineItem]
    var auxLines: [AuxLine]
    var breakdown: ReceiptBreakdown

    init(
        id: String,
        title: String,
        createdAt: Date? = nil,
        lines: [LineItem] = [],
        auxLines: [AuxLine] = [],
        breakdown: ReceiptBreakdown = .zero
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.lines = lines
        self.auxLines = auxLines
        self.breakdown = breakdown
    }

    /// Returns the displayed monetary total — convenient single accessor for
    /// the bill-card "$X.XX" rendering.
    var displayTotal: Money { Money(cents: breakdown.totalCents) }

    /// Sum of all line items' priceCents. May differ from breakdown.subtotalCents
    /// when lines aren't yet populated (Phase 1 scan completed, Phase 2 still
    /// loading). Callers that need a guaranteed-correct subtotal should use
    /// `breakdown.subtotalCents`.
    var lineItemSubtotalCents: Int {
        lines.reduce(0) { $0 + $1.priceCents }
    }

    /// Returns lines whose label is non-empty after trimming.
    /// Used by the editor to filter out user-typed-but-incomplete rows.
    var completedLines: [LineItem] {
        lines.filter { $0.hasNonEmptyLabel }
    }
}
