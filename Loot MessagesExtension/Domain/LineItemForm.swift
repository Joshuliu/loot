//
//  LineItemForm.swift
//  Loot MessagesExtension
//
//  Editing-form wrapper around the canonical LineItem. Holds the in-progress
//  text input alongside LineItem identity, so SwiftUI bindings work directly
//  with String fields while the canonical model is preserved.
//
//  Used by EditReceiptView (Phase 2 migration replaces the legacy
//  `EditableItem` nested type) and the split editors. AuxLineForm fills the
//  same role for AuxLine-shaped rows (taxes, fees, discounts).
//

import Foundation

/// Form-state wrapper for editing a LineItem.
/// `priceText` is the string the user is currently typing — convert with
/// `priceCents` to get the canonical Int representation.
struct LineItemForm: Identifiable, Equatable, Hashable {
    var line: LineItem
    var priceText: String
    /// Working set of assigned guest UUIDs during by-items editing. Stored
    /// (not computed) so SwiftUI @State + array-subscript + Set.insert
    /// mutations propagate cleanly. Synced to `line.assigneeIDs` at
    /// construction and on `committed()`.
    /// Phase 2.6 bridge: SplitGuest.id is still UUID-based; Phase 2.8
    /// (SplitGuest -> Person) collapses this back to `line.assigneeIDs`.
    var assignedGuestIds: Set<UUID>

    var id: UUID { line.id }

    /// Passthrough to `line.label` so call sites don't need to traverse `.line`.
    var label: String {
        get { line.label }
        set { line.label = newValue }
    }

    init(line: LineItem, priceText: String) {
        self.line = line
        self.priceText = priceText
        self.assignedGuestIds = Set(line.assigneeIDs.compactMap { UUID(uuidString: $0.rawValue) })
    }

    /// Convenience for editor flows that work with an id + label + raw text.
    /// `priceText` is stored as-typed; canonical `LineItem.priceCents` defaults
    /// to 0 until `committed()` is called.
    init(id: UUID = UUID(), label: String, priceText: String) {
        self.line = LineItem(id: id, label: label, priceCents: 0)
        self.priceText = priceText
        self.assignedGuestIds = []
    }

    /// Convenience for split-by-items flows that supply assigned-guest UUIDs.
    init(id: UUID = UUID(), label: String, priceText: String, assignedGuestIds: Set<UUID>) {
        self.line = LineItem(id: id, label: label, priceCents: 0)
        self.priceText = priceText
        self.assignedGuestIds = assignedGuestIds
    }

    /// Construct a form from a canonical LineItem, formatting priceCents into
    /// the display text (e.g. 1250 → "12.50").
    init(from line: LineItem) {
        self.line = line
        self.priceText = Money(cents: line.priceCents).inputString
        self.assignedGuestIds = Set(line.assigneeIDs.compactMap { UUID(uuidString: $0.rawValue) })
    }

    /// Construct a blank form with a fresh ID.
    static func empty() -> LineItemForm {
        LineItemForm(
            line: LineItem(label: "", priceCents: 0),
            priceText: ""
        )
    }

    /// True if both label and price are non-blank after trimming.
    /// Matches the legacy EditableItem.isComplete semantics.
    var isComplete: Bool {
        line.hasNonEmptyLabel &&
        !priceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Parsed price as cents. Driven by `priceText`, not `line.priceCents` —
    /// the canonical line is only updated on save via `committed()`.
    var priceCents: Int {
        Money(parsing: priceText).cents
    }

    /// Returns a finalized LineItem with `priceCents` resolved from `priceText`,
    /// label trimmed, and `assigneeIDs` synced from the working
    /// `assignedGuestIds` set. Use this when persisting form state.
    func committed() -> LineItem {
        LineItem(
            id: line.id,
            label: line.label.trimmingCharacters(in: .whitespacesAndNewlines),
            priceCents: priceCents,
            quantity: line.quantity,
            assigneeIDs: assignedGuestIds.map { PersonID(rawValue: $0.uuidString) }
        )
    }
}

/// Form-state wrapper for editing an AuxLine (tax, fee, or discount row).
/// `amountText` is signed-string input; "-5.00" produces a discount.
struct AuxLineForm: Identifiable, Equatable, Hashable {
    var line: AuxLine
    var amountText: String

    var id: UUID { line.id }

    /// Passthrough to `line.label`.
    var label: String {
        get { line.label }
        set { line.label = newValue }
    }

    init(line: AuxLine, amountText: String) {
        self.line = line
        self.amountText = amountText
    }

    /// Convenience for editor flows that work with an id + label + raw signed-text.
    init(id: UUID = UUID(), label: String, amountText: String) {
        self.line = AuxLine(id: id, label: label, cents: 0)
        self.amountText = amountText
    }

    /// Construct a form from a canonical AuxLine, formatting cents into the
    /// signed display text (e.g. -500 → "-5.00").
    init(from line: AuxLine) {
        self.line = line
        self.amountText = Money(cents: line.cents).inputString
    }

    /// True if both label and amount are non-blank after trimming.
    var isComplete: Bool {
        !line.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Parsed amount as signed cents. Negative values are preserved (discounts).
    var amountCents: Int {
        Money(parsingSigned: amountText).cents
    }

    /// Returns a finalized AuxLine with `cents` resolved from `amountText`
    /// and the label trimmed.
    func committed() -> AuxLine {
        AuxLine(
            id: line.id,
            label: line.label.trimmingCharacters(in: .whitespacesAndNewlines),
            cents: amountCents
        )
    }
}
