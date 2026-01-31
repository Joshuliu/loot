//
//  EditReceiptView.swift
//  Loot
//
//  Created by Assistant
//

import SwiftUI

struct EditReceiptView: View {
    @ObservedObject var uiModel: LootUIModel
    let onSave: (ReceiptDisplay) -> Void
    let onCancel: () -> Void
    
    // Editable state
    @State private var receiptName: String
    @State private var items: [EditableItem]
    @State private var taxesAndFees: [EditableFee]
    @State private var discounts: [EditableDiscount]
    @State private var tipString: String  // Separate tip field (below discounts)
    @State private var preTipTotalOverride: String  // Single override for pre-tip total

    // Editor state for inline add/edit
    @State private var editorMode: EditorMode = .none
    @State private var editorLabel: String = ""
    @State private var editorAmount: String = ""
    @FocusState private var editorFocusedField: EditorFocusField?

    @FocusState private var focusedField: FocusableField?

    enum EditorMode: Equatable {
        case none
        case item(UUID?)      // nil = adding new, UUID = editing existing
        case fee(UUID?)
        case discount(UUID?)

        var isActive: Bool { self != .none }
    }

    enum EditorFocusField: Hashable {
        case label
        case amount
    }

    enum FocusableField: Hashable {
        case receiptName
        case preTipTotal
        case tip
    }
    
    // Editable models
    struct EditableItem: Identifiable, Equatable {
        let id: UUID
        var label: String
        var price: String
        
        var isComplete: Bool {
            !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !price.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    
    struct EditableFee: Identifiable, Equatable {
        let id: UUID
        var label: String
        var amount: String
        
        var isComplete: Bool {
            !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    
    struct EditableDiscount: Identifiable, Equatable {
        let id: UUID
        var label: String
        var amount: String
        
        var isComplete: Bool {
            !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    
    init(uiModel: LootUIModel, onSave: @escaping (ReceiptDisplay) -> Void, onCancel: @escaping () -> Void) {
        self.uiModel = uiModel
        self.onSave = onSave
        self.onCancel = onCancel
        
        let receipt = uiModel.currentReceipt ?? ReceiptDisplay(
            id: UUID().uuidString,
            title: "New Receipt",
            createdAt: Date(),
            subtotalCents: 0,
            feesCents: 0,
            taxCents: 0,
            tipCents: 0,
            discountCents: 0,
            totalCents: 0,
            items: []
        )
        
        _receiptName = State(initialValue: receipt.title)
        
        // Convert items (no empty row - use Add button instead)
        let editableItems = receipt.items.map { item in
            EditableItem(
                id: UUID(uuidString: item.id) ?? UUID(),
                label: item.label,
                price: Self.formatCentsStatic(item.priceCents)
            )
        }
        _items = State(initialValue: editableItems)

        // Convert taxes & fees (no empty row - use Add button instead)
        var fees: [EditableFee] = []
        if receipt.taxCents > 0 {
            fees.append(EditableFee(id: UUID(), label: "Tax", amount: Self.formatCentsStatic(receipt.taxCents)))
        }
        if receipt.feesCents > 0 {
            fees.append(EditableFee(id: UUID(), label: "Fees", amount: Self.formatCentsStatic(receipt.feesCents)))
        }
        _taxesAndFees = State(initialValue: fees)

        // Initialize tip separately
        if receipt.tipCents > 0 {
            _tipString = State(initialValue: Self.formatCentsStatic(receipt.tipCents))
        } else {
            _tipString = State(initialValue: "")
        }

        // Convert discounts (no empty row - use Add button instead)
        var discountsList: [EditableDiscount] = []
        if receipt.discountCents > 0 {
            discountsList.append(EditableDiscount(id: UUID(), label: "Discount", amount: Self.formatCentsStatic(receipt.discountCents)))
        }
        _discounts = State(initialValue: discountsList)

        // Initialize pre-tip total override
        // If there are no items, use the pre-tip total (total - tip) as override
        let hasItems = !receipt.items.isEmpty
        let calculatedPreTip = receipt.subtotalCents + receipt.taxCents + receipt.feesCents - receipt.discountCents

        if !hasItems && calculatedPreTip > 0 {
            _preTipTotalOverride = State(initialValue: Self.formatCentsStatic(calculatedPreTip))
        } else {
            _preTipTotalOverride = State(initialValue: "")
        }
    }
    
    // MARK: - Money helpers
    
    private static func formatCentsStatic(_ cents: Int) -> String {
        let dollars = cents / 100
        let centsRemainder = cents % 100
        return "\(dollars).\(String(format: "%02d", centsRemainder))"
    }
    
    private func formatCents(_ cents: Int) -> String {
        Self.formatCentsStatic(cents)
    }
    
    private func moneyToCents(_ raw: String) -> Int {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        guard !s.isEmpty else { return 0 }
        
        if s.contains(".") {
            let parts = s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let dollars = Int(parts.first ?? "0") ?? 0
            let centsRaw = parts.count > 1 ? String(parts[1]) : ""
            let cents2 = centsRaw.padding(toLength: 2, withPad: "0", startingAt: 0)
            let cents = Int(String(cents2.prefix(2))) ?? 0
            return max(0, dollars * 100 + cents)
        }
        return max(0, (Int(s) ?? 0) * 100)
    }
    
    private func formatMoney(_ cents: Int) -> String {
        let dollars = cents / 100
        let centsRemainder = cents % 100
        return "$\(dollars).\(String(format: "%02d", centsRemainder))"
    }
    
    // MARK: - Computed values

    private var completedItems: [EditableItem] {
        items.filter { $0.isComplete }
    }

    private var calculatedSubtotalCents: Int {
        completedItems.reduce(0) { $0 + moneyToCents($1.price) }
    }

    private var completedFees: [EditableFee] {
        taxesAndFees.filter { $0.isComplete }
    }

    private var taxesAndFeesCents: Int {
        completedFees.reduce(0) { $0 + moneyToCents($1.amount) }
    }

    private var completedDiscounts: [EditableDiscount] {
        discounts.filter { $0.isComplete }
    }

    private var discountsCents: Int {
        completedDiscounts.reduce(0) { $0 + moneyToCents($1.amount) }
    }

    // Calculated pre-tip total from items + taxes + fees - discounts
    private var calculatedPreTipTotalCents: Int {
        calculatedSubtotalCents + taxesAndFeesCents - discountsCents
    }

    // Pre-tip total: use override if set, otherwise use calculated
    private var preTipTotalCents: Int {
        if !preTipTotalOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return moneyToCents(preTipTotalOverride)
        }
        return calculatedPreTipTotalCents
    }

    private var hasPreTipWarning: Bool {
        !preTipTotalOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        moneyToCents(preTipTotalOverride) != calculatedPreTipTotalCents &&
        calculatedPreTipTotalCents > 0  // Only warn if there's something to compare against
    }

    // Tip is separate from taxes & fees (applied after pre-tip total)
    private var tipCents: Int {
        moneyToCents(tipString)
    }

    // Final total: pre-tip total + tip (always calculated, no override)
    private var calculatedTotalCents: Int {
        preTipTotalCents + tipCents
    }
    
    // MARK: - Actions

    private func deleteItem(_ item: EditableItem) {
        items.removeAll { $0.id == item.id }
    }

    private func deleteFee(_ fee: EditableFee) {
        taxesAndFees.removeAll { $0.id == fee.id }
    }

    private func deleteDiscount(_ discount: EditableDiscount) {
        discounts.removeAll { $0.id == discount.id }
    }

    // MARK: - Editor Actions

    private func openEditor(mode: EditorMode, focusField: EditorFocusField = .label) {
        switch mode {
        case .none:
            return
        case .item(let id):
            if let id = id, let item = items.first(where: { $0.id == id }) {
                editorLabel = item.label
                editorAmount = item.price
            } else {
                editorLabel = ""
                editorAmount = ""
            }
        case .fee(let id):
            if let id = id, let fee = taxesAndFees.first(where: { $0.id == id }) {
                editorLabel = fee.label
                editorAmount = fee.amount
            } else {
                editorLabel = ""
                editorAmount = ""
            }
        case .discount(let id):
            if let id = id, let discount = discounts.first(where: { $0.id == id }) {
                editorLabel = discount.label
                editorAmount = discount.amount
            } else {
                editorLabel = ""
                editorAmount = ""
            }
        }
        editorMode = mode
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            editorFocusedField = focusField
        }
    }

    private func saveEditor() {
        let label = editorLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let amount = editorAmount.trimmingCharacters(in: .whitespacesAndNewlines)

        // Don't save if both are empty
        guard !label.isEmpty || !amount.isEmpty else {
            closeEditor()
            return
        }

        switch editorMode {
        case .none:
            break
        case .item(let id):
            if let id = id, let idx = items.firstIndex(where: { $0.id == id }) {
                items[idx].label = label
                items[idx].price = amount
            } else {
                items.append(EditableItem(id: UUID(), label: label, price: amount))
            }
        case .fee(let id):
            if let id = id, let idx = taxesAndFees.firstIndex(where: { $0.id == id }) {
                taxesAndFees[idx].label = label
                taxesAndFees[idx].amount = amount
            } else {
                taxesAndFees.append(EditableFee(id: UUID(), label: label, amount: amount))
            }
        case .discount(let id):
            if let id = id, let idx = discounts.firstIndex(where: { $0.id == id }) {
                discounts[idx].label = label
                discounts[idx].amount = amount
            } else {
                discounts.append(EditableDiscount(id: UUID(), label: label, amount: amount))
            }
        }
        closeEditor()
    }

    private func closeEditor() {
        editorFocusedField = nil
        editorMode = .none
        editorLabel = ""
        editorAmount = ""
    }

    private var editorTitle: String {
        switch editorMode {
        case .none: return ""
        case .item(let id): return id == nil ? "Add Item" : "Edit Item"
        case .fee(let id): return id == nil ? "Add Tax/Fee" : "Edit Tax/Fee"
        case .discount(let id): return id == nil ? "Add Discount" : "Edit Discount"
        }
    }

    private var editorLabelPlaceholder: String {
        switch editorMode {
        case .none: return ""
        case .item: return "Item name"
        case .fee: return "e.g. Tax, Service fee"
        case .discount: return "e.g. Coupon, Promo"
        }
    }
    
    private func saveReceipt() {
        // Aggregate fees by type (tax and fees only - tip is separate)
        var taxTotal = 0
        var feesTotal = 0

        for fee in completedFees {
            let label = fee.label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let amount = moneyToCents(fee.amount)

            if label.contains("tax") {
                taxTotal += amount
            } else {
                // Everything else in taxes & fees section is a fee (service fee, delivery, etc.)
                feesTotal += amount
            }
        }

        // Aggregate discounts
        let totalDiscounts = discountsCents

        // Calculate subtotal: pre-tip total - taxes - fees + discounts
        // (working backwards since user sets the pre-tip total)
        let subtotal = preTipTotalCents - taxTotal - feesTotal + totalDiscounts

        // Final total is always pre-tip + tip
        let finalTotalCents = calculatedTotalCents

        let updatedReceipt = ReceiptDisplay(
            id: uiModel.currentReceipt?.id ?? UUID().uuidString,
            title: receiptName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Receipt" : receiptName,
            createdAt: uiModel.currentReceipt?.createdAt ?? Date(),
            subtotalCents: subtotal,
            feesCents: feesTotal,
            taxCents: taxTotal,
            tipCents: tipCents,
            discountCents: totalDiscounts,
            totalCents: finalTotalCents,
            items: completedItems.map { item in
                ReceiptDisplay.Item(
                    id: item.id.uuidString,
                    label: item.label,
                    priceCents: moneyToCents(item.price),
                    responsible: []
                )
            }
        )

        onSave(updatedReceipt)
    }
    
    // MARK: - Body

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Top bar
                HStack {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.plain)

                    Spacer()

                    Text("Edit Receipt")
                        .font(.system(size: 16, weight: .semibold))

                    Spacer()

                    Button("Save") {
                        saveReceipt()
                    }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {

                        // MARK: - Description Section
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Description")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary)

                            TextField("Loot Description", text: $receiptName)
                                .font(.system(size: 16))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(12)
                                .focused($focusedField, equals: .receiptName)
                        }

                        // MARK: - Items Section
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Items")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary)

                            // Items list (tap to edit, swipe to delete)
                            if !items.isEmpty {
                                VStack(spacing: 0) {
                                    ForEach(items) { item in
                                        VStack(spacing: 0) {
                                            HStack {
                                                Text(item.label)
                                                    .font(.system(size: 16))
                                                    .foregroundColor(.primary)
                                                    .onTapGesture {
                                                        openEditor(mode: .item(item.id), focusField: .label)
                                                    }
                                                Spacer()
                                                Text(formatMoney(moneyToCents(item.price)))
                                                    .font(.system(size: 16, weight: .medium))
                                                    .onTapGesture {
                                                        openEditor(mode: .item(item.id), focusField: .amount)
                                                    }
                                                Button {
                                                    deleteItem(item)
                                                } label: {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .foregroundColor(.secondary)
                                                        .font(.system(size: 18))
                                                }
                                                .buttonStyle(.plain)
                                            }
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 12)

                                            if item.id != items.last?.id {
                                                Divider().padding(.leading, 14)
                                            }
                                        }
                                    }
                                }
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(12)
                            }

                            // Add item button
                            Button {
                                openEditor(mode: .item(nil), focusField: .label)
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundColor(.blue)
                                    Text("Add Item")
                                        .foregroundColor(.blue)
                                    Spacer()
                                }
                                .font(.system(size: 16, weight: .medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(Color(.secondarySystemBackground).opacity(0.6))
                                .cornerRadius(12)
                            }
                            .buttonStyle(.plain)

                            HStack {
                                Text("Items subtotal")
                                    .font(.system(size: 15, weight: .medium))
                                Spacer()
                                Text(formatMoney(calculatedSubtotalCents))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 4)
                        }

                        // MARK: - Taxes & Fees Section
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Taxes & Fees")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary)

                            // Fees list
                            if !taxesAndFees.isEmpty {
                                VStack(spacing: 0) {
                                    ForEach(taxesAndFees) { fee in
                                        VStack(spacing: 0) {
                                            HStack {
                                                Text(fee.label)
                                                    .font(.system(size: 16))
                                                    .foregroundColor(.primary)
                                                    .onTapGesture {
                                                        openEditor(mode: .fee(fee.id), focusField: .label)
                                                    }
                                                Spacer()
                                                Text(formatMoney(moneyToCents(fee.amount)))
                                                    .font(.system(size: 16, weight: .medium))
                                                    .onTapGesture {
                                                        openEditor(mode: .fee(fee.id), focusField: .amount)
                                                    }
                                                Button {
                                                    deleteFee(fee)
                                                } label: {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .foregroundColor(.secondary)
                                                        .font(.system(size: 18))
                                                }
                                                .buttonStyle(.plain)
                                            }
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 12)

                                            if fee.id != taxesAndFees.last?.id {
                                                Divider().padding(.leading, 14)
                                            }
                                        }
                                    }
                                }
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(12)
                            }

                            // Add fee button
                            Button {
                                openEditor(mode: .fee(nil), focusField: .label)
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundColor(.blue)
                                    Text("Add Tax/Fee")
                                        .foregroundColor(.blue)
                                    Spacer()
                                }
                                .font(.system(size: 16, weight: .medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(Color(.secondarySystemBackground).opacity(0.6))
                                .cornerRadius(12)
                            }
                            .buttonStyle(.plain)

                            HStack {
                                Text("Total taxes & fees")
                                    .font(.system(size: 15, weight: .medium))
                                Spacer()
                                Text(formatMoney(taxesAndFeesCents))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 4)
                        }

                        // MARK: - Discounts Section
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Discounts")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary)

                            // Discounts list
                            if !discounts.isEmpty {
                                VStack(spacing: 0) {
                                    ForEach(discounts) { discount in
                                        VStack(spacing: 0) {
                                            HStack {
                                                Text(discount.label)
                                                    .font(.system(size: 16))
                                                    .foregroundColor(.primary)
                                                    .onTapGesture {
                                                        openEditor(mode: .discount(discount.id), focusField: .label)
                                                    }
                                                Spacer()
                                                Text(formatMoney(moneyToCents(discount.amount)))
                                                    .font(.system(size: 16, weight: .medium))
                                                    .onTapGesture {
                                                        openEditor(mode: .discount(discount.id), focusField: .amount)
                                                    }
                                                Button {
                                                    deleteDiscount(discount)
                                                } label: {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .foregroundColor(.secondary)
                                                        .font(.system(size: 18))
                                                }
                                                .buttonStyle(.plain)
                                            }
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 12)

                                            if discount.id != discounts.last?.id {
                                                Divider().padding(.leading, 14)
                                            }
                                        }
                                    }
                                }
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(12)
                            }

                            // Add discount button
                            Button {
                                openEditor(mode: .discount(nil), focusField: .label)
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundColor(.blue)
                                    Text("Add Discount")
                                        .foregroundColor(.blue)
                                    Spacer()
                                }
                                .font(.system(size: 16, weight: .medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(Color(.secondarySystemBackground).opacity(0.6))
                                .cornerRadius(12)
                            }
                            .buttonStyle(.plain)

                            HStack {
                                Text("Total discounts")
                                    .font(.system(size: 15, weight: .medium))
                                Spacer()
                                Text(formatMoney(discountsCents))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 4)
                        }

                        // MARK: - Pre-tip Total & Tip Section
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Total")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary)

                            HStack {
                                Text("Calculated pre-tip")
                                    .font(.system(size: 15, weight: .medium))
                                Spacer()
                                Text(formatMoney(calculatedPreTipTotalCents))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }

                            VStack(spacing: 0) {
                                HStack {
                                    Text("Override pre-tip total")
                                        .font(.system(size: 15))

                                    Spacer()

                                    TextField("Auto", text: $preTipTotalOverride)
                                        .font(.system(size: 15, weight: .semibold))
                                        .keyboardType(.decimalPad)
                                        .multilineTextAlignment(.trailing)
                                        .focused($focusedField, equals: .preTipTotal)
                                        .frame(width: 100)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                            }
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)

                            if hasPreTipWarning {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 13))
                                    Text("Pre-tip total doesn't match calculated")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                .foregroundColor(.orange)
                                .padding(.top, 4)
                            }

                            VStack(spacing: 0) {
                                HStack {
                                    Text("Tip amount")
                                        .font(.system(size: 15))

                                    Spacer()

                                    TextField("0.00", text: $tipString)
                                        .font(.system(size: 15, weight: .semibold))
                                        .keyboardType(.decimalPad)
                                        .multilineTextAlignment(.trailing)
                                        .focused($focusedField, equals: .tip)
                                        .frame(width: 100)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                            }
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)

                            HStack {
                                Text("Final total")
                                    .font(.system(size: 15, weight: .medium))
                                Spacer()
                                Text(formatMoney(calculatedTotalCents))
                                    .font(.system(size: 17, weight: .bold))
                            }
                            .padding(.top, 4)
                        }

                        Spacer().frame(height: 40)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
            }

            // Editor overlay
            if editorMode.isActive {
                VStack {
                    Spacer()
                    VStack(spacing: 0) {
                        // Header
                        HStack {
                            Button("Cancel") {
                                closeEditor()
                            }
                            .foregroundColor(.blue)

                            Spacer()

                            Text(editorTitle)
                                .font(.system(size: 16, weight: .semibold))

                            Spacer()

                            Button("Save") {
                                saveEditor()
                            }
                            .foregroundColor(.blue)
                            .fontWeight(.semibold)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        Divider()

                        // Input fields
                        HStack(spacing: 12) {
                            TextField(editorLabelPlaceholder, text: $editorLabel)
                                .font(.system(size: 16))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(.tertiarySystemBackground))
                                .cornerRadius(8)
                                .focused($editorFocusedField, equals: .label)
                                .submitLabel(.next)
                                .onSubmit {
                                    editorFocusedField = .amount
                                }

                            TextField("0.00", text: $editorAmount)
                                .font(.system(size: 16))
                                .keyboardType(.decimalPad)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(.tertiarySystemBackground))
                                .cornerRadius(8)
                                .frame(width: 100)
                                .focused($editorFocusedField, equals: .amount)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(16, corners: [.topLeft, .topRight])
                    .shadow(color: .black.opacity(0.15), radius: 10, y: -5)
                }
                .transition(.move(edge: .bottom))
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: editorMode.isActive)
            }
        }
    }
}

// Helper for rounded corners on specific sides
// RoundedCorner struct is defined in SplitGuestEditor.swift
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}
