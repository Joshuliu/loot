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
    @State private var subtotalOverride: String
    @State private var totalString: String
    
    @FocusState private var focusedField: FocusableField?
    
    enum FocusableField: Hashable {
        case receiptName
        case item(UUID)
        case itemPrice(UUID)
        case subtotalOverride
        case fee(UUID)
        case feeAmount(UUID)
        case discount(UUID)
        case discountAmount(UUID)
        case total
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
        
        // Convert items
        var editableItems = receipt.items.map { item in
            EditableItem(
                id: UUID(uuidString: item.id) ?? UUID(),
                label: item.label,
                price: Self.formatCentsStatic(item.priceCents)
            )
        }
        // Add empty item for new entry
        editableItems.append(EditableItem(id: UUID(), label: "", price: ""))
        _items = State(initialValue: editableItems)
        
        // Convert taxes & fees
        var fees: [EditableFee] = []
        if receipt.taxCents > 0 {
            fees.append(EditableFee(id: UUID(), label: "Tax", amount: Self.formatCentsStatic(receipt.taxCents)))
        }
        if receipt.feesCents > 0 {
            fees.append(EditableFee(id: UUID(), label: "Fees", amount: Self.formatCentsStatic(receipt.feesCents)))
        }
        if receipt.tipCents > 0 {
            fees.append(EditableFee(id: UUID(), label: "Tip", amount: Self.formatCentsStatic(receipt.tipCents)))
        }
        // Add empty fee for new entry
        fees.append(EditableFee(id: UUID(), label: "", amount: ""))
        _taxesAndFees = State(initialValue: fees)
        
        // Convert discounts
        var discountsList: [EditableDiscount] = []
        if receipt.discountCents > 0 {
            discountsList.append(EditableDiscount(id: UUID(), label: "Discount", amount: Self.formatCentsStatic(receipt.discountCents)))
        }
        // Add empty discount for new entry
        discountsList.append(EditableDiscount(id: UUID(), label: "", amount: ""))
        _discounts = State(initialValue: discountsList)
        
        // Initialize subtotal override
        // If there are no items but receipt has a subtotal, use it as override
        let hasItems = !receipt.items.isEmpty
        let hasBreakdown = receipt.tipCents > 0 || receipt.taxCents > 0 || receipt.feesCents > 0 || receipt.discountCents > 0

        if !hasItems && receipt.subtotalCents > 0 {
            _subtotalOverride = State(initialValue: Self.formatCentsStatic(receipt.subtotalCents))
        } else {
            _subtotalOverride = State(initialValue: "")
        }

        // Initialize total override
        // If there's a breakdown (tip/tax/fees/discount), let total auto-calculate
        // Otherwise use receipt's total as override
        if hasBreakdown {
            _totalString = State(initialValue: "")
        } else {
            _totalString = State(initialValue: Self.formatCentsStatic(receipt.totalCents))
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
    
    private var subtotalCents: Int {
        // Use override if set, otherwise use calculated
        if !subtotalOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return moneyToCents(subtotalOverride)
        }
        return calculatedSubtotalCents
    }
    
    private var hasSubtotalWarning: Bool {
        !subtotalOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        moneyToCents(subtotalOverride) != calculatedSubtotalCents
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
    
    private var calculatedTotalCents: Int {
        subtotalCents + taxesAndFeesCents - discountsCents
    }
    
    private var enteredTotalCents: Int {
        moneyToCents(totalString)
    }
    
    private var hasWarning: Bool {
        !totalString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        enteredTotalCents != calculatedTotalCents
    }
    
    // MARK: - Actions
    
    private func ensureEmptyRows() {
        // Ensure there's always an empty item row
        if !items.contains(where: { !$0.isComplete }) {
            items.append(EditableItem(id: UUID(), label: "", price: ""))
        }
        
        // Ensure there's always an empty fee row
        if !taxesAndFees.contains(where: { !$0.isComplete }) {
            taxesAndFees.append(EditableFee(id: UUID(), label: "", amount: ""))
        }
        
        // Ensure there's always an empty discount row
        if !discounts.contains(where: { !$0.isComplete }) {
            discounts.append(EditableDiscount(id: UUID(), label: "", amount: ""))
        }
    }
    
    private func deleteItem(_ item: EditableItem) {
        items.removeAll { $0.id == item.id }
        ensureEmptyRows()
    }
    
    private func deleteFee(_ fee: EditableFee) {
        taxesAndFees.removeAll { $0.id == fee.id }
        ensureEmptyRows()
    }
    
    private func deleteDiscount(_ discount: EditableDiscount) {
        discounts.removeAll { $0.id == discount.id }
        ensureEmptyRows()
    }
    
    private func saveReceipt() {
        // Auto-calculate total if empty or if it doesn't match
        let finalTotalCents: Int
        if totalString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finalTotalCents = calculatedTotalCents
        } else {
            finalTotalCents = enteredTotalCents
        }
        
        // Aggregate fees by type (tax, tip, fees)
        var taxTotal = 0
        var tipTotal = 0
        var feesTotal = 0
        
        for fee in completedFees {
            let label = fee.label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let amount = moneyToCents(fee.amount)
            
            if label.contains("tax") {
                taxTotal += amount
            } else if label.contains("tip") || label.contains("gratuity") {
                tipTotal += amount
            } else {
                feesTotal += amount
            }
        }
        
        // Aggregate discounts
        let totalDiscounts = discountsCents
        
        let updatedReceipt = ReceiptDisplay(
            id: uiModel.currentReceipt?.id ?? UUID().uuidString,
            title: receiptName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Receipt" : receiptName,
            createdAt: uiModel.currentReceipt?.createdAt ?? Date(),
            subtotalCents: subtotalCents,
            feesCents: feesTotal,
            taxCents: taxTotal,
            tipCents: tipTotal,
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
                        HStack {
                            Text("Items")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary)

                            Spacer()

                            if !completedItems.isEmpty {
                                Text("Swipe to delete")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }

                        // Completed items list
                        if !completedItems.isEmpty {
                            List {
                                ForEach(items.indices, id: \.self) { idx in
                                    let item = items[idx]
                                    if item.isComplete {
                                        HStack(spacing: 12) {
                                            TextField("Item", text: $items[idx].label)
                                                .font(.system(size: 16))
                                                .focused($focusedField, equals: .item(item.id))
                                                .submitLabel(.next)
                                                .onSubmit {
                                                    focusedField = .itemPrice(item.id)
                                                }

                                            TextField("Price", text: $items[idx].price)
                                                .font(.system(size: 16))
                                                .keyboardType(.decimalPad)
                                                .focused($focusedField, equals: .itemPrice(item.id))
                                                .frame(width: 80)
                                        }
                                        .listRowInsets(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                                        .listRowBackground(Color.clear)
                                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                            Button(role: .destructive) {
                                                deleteItem(item)
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .background(Color(.secondarySystemBackground))
                            .frame(height: max(44, CGFloat(completedItems.count * 44)))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .scrollDisabled(true)
                        }

                        // Add new item row
                        if let emptyIndex = items.firstIndex(where: { !$0.isComplete }) {
                            let emptyItem = items[emptyIndex]
                            HStack(spacing: 12) {
                                TextField("Add item", text: $items[emptyIndex].label)
                                    .font(.system(size: 16))
                                    .focused($focusedField, equals: .item(emptyItem.id))
                                    .submitLabel(.next)
                                    .onSubmit {
                                        focusedField = .itemPrice(emptyItem.id)
                                    }

                                TextField("Price", text: $items[emptyIndex].price)
                                    .font(.system(size: 16))
                                    .keyboardType(.decimalPad)
                                    .focused($focusedField, equals: .itemPrice(emptyItem.id))
                                    .frame(width: 80)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemBackground).opacity(0.6))
                            .cornerRadius(12)
                        }
                        
                        HStack {
                            Text("Calculated subtotal")
                                .font(.system(size: 15, weight: .medium))
                            Spacer()
                            Text(formatMoney(calculatedSubtotalCents))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 4)
                        
                        VStack(spacing: 0) {
                            HStack {
                                Text("Override subtotal")
                                    .font(.system(size: 15))
                                
                                Spacer()
                                
                                TextField("Auto", text: $subtotalOverride)
                                    .font(.system(size: 15, weight: .semibold))
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .focused($focusedField, equals: .subtotalOverride)
                                    .frame(width: 100)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        
                        if hasSubtotalWarning {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 13))
                                Text("Subtotal doesn't match items")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundColor(.orange)
                            .padding(.top, 4)
                        }
                    }
                    
                    // MARK: - Taxes & Fees Section
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Taxes & Fees")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary)

                            Spacer()

                            if !completedFees.isEmpty {
                                Text("Swipe to delete")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }

                        // Completed fees list
                        if !completedFees.isEmpty {
                            List {
                                ForEach(taxesAndFees.indices, id: \.self) { idx in
                                    let fee = taxesAndFees[idx]
                                    if fee.isComplete {
                                        HStack(spacing: 12) {
                                            TextField("Name (e.g. Tax, Tip)", text: $taxesAndFees[idx].label)
                                                .font(.system(size: 16))
                                                .focused($focusedField, equals: .fee(fee.id))
                                                .submitLabel(.next)
                                                .onSubmit {
                                                    focusedField = .feeAmount(fee.id)
                                                }

                                            TextField("Amount", text: $taxesAndFees[idx].amount)
                                                .font(.system(size: 16))
                                                .keyboardType(.decimalPad)
                                                .focused($focusedField, equals: .feeAmount(fee.id))
                                                .frame(width: 80)
                                        }
                                        .listRowInsets(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                                        .listRowBackground(Color.clear)
                                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                            Button(role: .destructive) {
                                                deleteFee(fee)
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                                .listRowInsets(EdgeInsets())
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .background(Color(.secondarySystemBackground))
                            .frame(height: max(44, CGFloat(completedFees.count * 44)))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .scrollDisabled(true)
                        }

                        // Add new fee row
                        if let emptyIndex = taxesAndFees.firstIndex(where: { !$0.isComplete }) {
                            let emptyFee = taxesAndFees[emptyIndex]
                            HStack(spacing: 12) {
                                TextField("Add tax/fee (e.g. Tax, Tip)", text: $taxesAndFees[emptyIndex].label)
                                    .font(.system(size: 16))
                                    .focused($focusedField, equals: .fee(emptyFee.id))
                                    .submitLabel(.next)
                                    .onSubmit {
                                        focusedField = .feeAmount(emptyFee.id)
                                    }

                                TextField("Amount", text: $taxesAndFees[emptyIndex].amount)
                                    .font(.system(size: 16))
                                    .keyboardType(.decimalPad)
                                    .focused($focusedField, equals: .feeAmount(emptyFee.id))
                                    .frame(width: 80)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemBackground).opacity(0.6))
                            .cornerRadius(12)
                        }
                        
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
                        HStack {
                            Text("Discounts")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary)

                            Spacer()

                            if !completedDiscounts.isEmpty {
                                Text("Swipe to delete")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }

                        // Completed discounts list
                        if !completedDiscounts.isEmpty {
                            List {
                                ForEach(discounts.indices, id: \.self) { idx in
                                    let discount = discounts[idx]
                                    if discount.isComplete {
                                        HStack(spacing: 12) {
                                            TextField("Name", text: $discounts[idx].label)
                                                .font(.system(size: 16))
                                                .focused($focusedField, equals: .discount(discount.id))
                                                .submitLabel(.next)
                                                .onSubmit {
                                                    focusedField = .discountAmount(discount.id)
                                                }

                                            TextField("Amount", text: $discounts[idx].amount)
                                                .font(.system(size: 16))
                                                .keyboardType(.decimalPad)
                                                .focused($focusedField, equals: .discountAmount(discount.id))
                                                .frame(width: 80)
                                        }
                                        .listRowInsets(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                                        .listRowBackground(Color.clear)
                                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                            Button(role: .destructive) {
                                                deleteDiscount(discount)
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .background(Color(.secondarySystemBackground))
                            .frame(height: max(44, CGFloat(completedDiscounts.count * 44)))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .scrollDisabled(true)
                        }

                        // Add new discount row
                        if let emptyIndex = discounts.firstIndex(where: { !$0.isComplete }) {
                            let emptyDiscount = discounts[emptyIndex]
                            HStack(spacing: 12) {
                                TextField("Add discount", text: $discounts[emptyIndex].label)
                                    .font(.system(size: 16))
                                    .focused($focusedField, equals: .discount(emptyDiscount.id))
                                    .submitLabel(.next)
                                    .onSubmit {
                                        focusedField = .discountAmount(emptyDiscount.id)
                                    }

                                TextField("Amount", text: $discounts[emptyIndex].amount)
                                    .font(.system(size: 16))
                                    .keyboardType(.decimalPad)
                                    .focused($focusedField, equals: .discountAmount(emptyDiscount.id))
                                    .frame(width: 80)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemBackground).opacity(0.6))
                            .cornerRadius(12)
                        }
                        
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
                    
                    // MARK: - Total Section
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Total")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                        
                        HStack {
                            Text("Calculated total")
                                .font(.system(size: 15, weight: .medium))
                            Spacer()
                            Text(formatMoney(calculatedTotalCents))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 4)
                        
                        VStack(spacing: 0) {
                            HStack {
                                Text("Override total")
                                    .font(.system(size: 15))
                                
                                Spacer()
                                
                                TextField("Auto", text: $totalString)
                                    .font(.system(size: 15, weight: .semibold))
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .focused($focusedField, equals: .total)
                                    .frame(width: 100)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        
                        if hasWarning {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 13))
                                Text("Total doesn't match calculated value")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundColor(.orange)
                            .padding(.top, 4)
                        }
                    }
                    
                    Spacer().frame(height: 40)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
        }
        .onChange(of: items) { _, _ in ensureEmptyRows() }
        .onChange(of: taxesAndFees) { _, _ in ensureEmptyRows() }
        .onChange(of: discounts) { _, _ in ensureEmptyRows() }
    }
}
