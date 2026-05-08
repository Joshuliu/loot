//
//  EditReceiptView.swift
//  Loot
//
//  Created by Assistant
//

import SwiftUI

struct EditReceiptView: View {
    @ObservedObject var uiModel: LootUIModel
    @ObservedObject var receiptDraftVM: ReceiptDraftViewModel
    let onSave: (ReceiptDisplay) -> Void
    let onCancel: () -> Void
    
    // Editable state
    @State private var receiptName: String
    @State private var items: [LineItemForm]
    @State private var taxesAndFees: [AuxLineForm]  // signed amounts: negative = discount
    @State private var tipString: String
    @State private var preTipTotalOverride: String  // Single override for pre-tip total

    // Capture preview
    @State private var showCapture: Bool = false

    // Debug: OCR chunk viewer
    @State private var showChunks: Bool = false

    // Editor state for inline add/edit
    @State private var editorMode: EditorMode = .none
    @State private var editorLabel: String = ""
    @State private var editorAmount: String = ""
    @State private var editorIsDiscount: Bool = false
    @FocusState private var editorFocusedField: EditorFocusField?

    @FocusState private var focusedField: FocusableField?

    enum EditorMode: Equatable {
        case none
        case item(UUID?)      // nil = adding new, UUID = editing existing
        case fee(UUID?)
        case preTipTotal
        case tip

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
    
    init(uiModel: LootUIModel, receiptDraftVM: ReceiptDraftViewModel, onSave: @escaping (ReceiptDisplay) -> Void, onCancel: @escaping () -> Void) {
        self.uiModel = uiModel
        self.receiptDraftVM = receiptDraftVM
        self.onSave = onSave
        self.onCancel = onCancel

        let receipt = receiptDraftVM.currentReceipt ?? ReceiptDisplay(
            id: UUID().uuidString,
            title: "New Receipt",
            createdAt: Date(),
            subtotalCents: 0,
            feesCents: 0,
            taxCents: 0,
            tipCents: 0,
            totalCents: 0,
            items: []
        )
        
        _receiptName = State(initialValue: receipt.title)
        
        // Convert items (no empty row - use Add button instead)
        let editableItems = receipt.items.map { item in
            LineItemForm(
                id: UUID(uuidString: item.id) ?? UUID(),
                label: item.label,
                priceText: Money(cents: item.priceCents).inputString
            )
        }
        _items = State(initialValue: editableItems)

        // Convert taxes, fees & discounts into one list with signed amounts.
        // Prefer lineItems (individual rows) if present — they were saved by EditReceiptView
        // and preserve each row separately. Fall back to aggregates for scanned receipts.
        var fees: [AuxLineForm] = []
        if !receipt.lineItems.isEmpty {
            func isTipLabel(_ label: String) -> Bool {
                let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized.contains("tip") || normalized.contains("gratuity")
            }

            func isTaxLabel(_ label: String) -> Bool {
                let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized.contains("tax")
            }

            var explicitTaxCents = 0
            var explicitFeeCents = 0
            var explicitDiscountCents = 0
            for item in receipt.lineItems {
                let stableId = UUID(uuidString: item.id) ?? UUID()
                if isTipLabel(item.label) {
                    continue
                }
                fees.append(AuxLineForm(id: stableId, label: item.label, amountText: Money(cents: item.cents).inputString))
                if isTaxLabel(item.label) {
                    explicitTaxCents += item.cents
                } else if item.cents < 0 {
                    explicitDiscountCents += abs(item.cents)
                } else {
                    explicitFeeCents += item.cents
                }
            }

            let missingTaxCents = receipt.taxCents - explicitTaxCents
            if missingTaxCents != 0 {
                fees.append(AuxLineForm(label: "Tax", amountText: Money(cents: missingTaxCents).inputString))
            }

            let missingFeeCents = receipt.feesCents - explicitFeeCents
            if missingFeeCents != 0 {
                fees.append(AuxLineForm(label: "Fees", amountText: Money(cents: missingFeeCents).inputString))
            }
            let missingDiscountCents = receipt.discountCents - explicitDiscountCents
            if missingDiscountCents != 0 {
                fees.append(AuxLineForm(label: "Discount", amountText: Money(cents: -missingDiscountCents).inputString))
            }
        } else {
            if receipt.taxCents != 0 {
                fees.append(AuxLineForm(label: "Tax", amountText: Money(cents: receipt.taxCents).inputString))
            }
            if receipt.feesCents != 0 {
                fees.append(AuxLineForm(label: "Fees", amountText: Money(cents: receipt.feesCents).inputString))
            }
            if receipt.discountCents != 0 {
                fees.append(AuxLineForm(label: "Discount", amountText: Money(cents: -receipt.discountCents).inputString))
            }
        }
        _taxesAndFees = State(initialValue: fees)

        // Initialize tip separately
        if receipt.tipCents > 0 {
            _tipString = State(initialValue: centsToDecimalString(receipt.tipCents))
        } else {
            _tipString = State(initialValue: "")
        }

        // Initialize pre-tip total override.
        // Priority:
        // 1) Explicit override previously saved in this receipt flow (persist user intent),
        // 2) legacy fallback for no-item receipts.
        let hasItems = !receipt.items.isEmpty
        let calculatedPreTip = receipt.subtotalCents + receipt.taxCents + receipt.feesCents - receipt.discountCents

        if let persistedOverride = receiptDraftVM.preTipTotalOverrideCents {
            _preTipTotalOverride = State(initialValue: centsToDecimalString(persistedOverride))
        } else if !hasItems && calculatedPreTip > 0 {
            _preTipTotalOverride = State(initialValue: centsToDecimalString(calculatedPreTip))
        } else {
            _preTipTotalOverride = State(initialValue: "")
        }
    }
    
    // MARK: - Computed values

    private var completedItems: [LineItemForm] {
        items.filter { $0.isComplete }
    }

    private var calculatedSubtotalCents: Int {
        completedItems.reduce(0) { $0 + $1.priceCents }
    }

    private var completedFees: [AuxLineForm] {
        taxesAndFees.filter { $0.isComplete }
    }

    private var taxesAndFeesCents: Int {
        completedFees.reduce(0) { $0 + $1.amountCents }
    }

    // Calculated pre-tip total from items + taxes + fees (fees signed so discounts reduce it)
    private var calculatedPreTipTotalCents: Int {
        calculatedSubtotalCents + taxesAndFeesCents
    }

    // Pre-tip total: use override if set, otherwise use calculated
    private var preTipTotalCents: Int {
        if !preTipTotalOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stringToCents(preTipTotalOverride)
        }
        return calculatedPreTipTotalCents
    }

    private var hasPreTipWarning: Bool {
        !preTipTotalOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        stringToCents(preTipTotalOverride) != calculatedPreTipTotalCents &&
        calculatedPreTipTotalCents > 0  // Only warn if there's something to compare against
    }

    // Tip is separate from taxes & fees (applied after pre-tip total)
    private var tipCents: Int {
        stringToCents(tipString)
    }

    // Final total: pre-tip total + tip (always calculated, no override)
    private var calculatedTotalCents: Int {
        preTipTotalCents + tipCents
    }
    
    // MARK: - Actions

    private func deleteItem(_ item: LineItemForm) {
        items.removeAll { $0.id == item.id }
    }

    private func deleteFee(_ fee: AuxLineForm) {
        taxesAndFees.removeAll { $0.id == fee.id }
    }

    // MARK: - Editor Actions

    private func openEditor(mode: EditorMode, focusField: EditorFocusField = .label, isDiscount: Bool = false) {
        switch mode {
        case .none:
            return
        case .item(let id):
            if let id = id, let item = items.first(where: { $0.id == id }) {
                editorLabel = item.label
                editorAmount = sanitizedUSDAmountInput(item.priceText)
            } else {
                editorLabel = ""
                editorAmount = ""
            }
            editorIsDiscount = false
        case .fee(let id):
            if let id = id, let fee = taxesAndFees.first(where: { $0.id == id }) {
                let cents = fee.amountCents
                editorIsDiscount = cents < 0
                editorLabel = fee.label
                editorAmount = sanitizedUSDAmountInput(Money(cents: abs(cents)).inputString)
            } else {
                editorIsDiscount = isDiscount
                editorLabel = isDiscount ? "Discount" : ""
                editorAmount = ""
            }
        case .preTipTotal:
            editorLabel = "Override total"
            editorAmount = sanitizedUSDAmountInput(preTipTotalOverride)
            editorIsDiscount = false
        case .tip:
            editorLabel = "Tip amount"
            editorAmount = sanitizedUSDAmountInput(tipString)
            editorIsDiscount = false
        }
        editorMode = mode
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            editorFocusedField = focusField
        }
    }

    private func saveEditor() {
        let label = editorLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let amount = normalizedUSDAmountForStorage(editorAmount)

        switch editorMode {
        case .preTipTotal:
            preTipTotalOverride = amount
            closeEditor()
            return
        case .tip:
            tipString = amount
            closeEditor()
            return
        case .none, .item, .fee:
            break
        }

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
                items[idx].priceText = amount
            } else {
                items.append(LineItemForm(label: label, priceText: amount))
            }
        case .fee(let id):
            let storedAmount = editorIsDiscount && !amount.isEmpty ? "-\(amount)" : amount
            if let id = id, let idx = taxesAndFees.firstIndex(where: { $0.id == id }) {
                taxesAndFees[idx].label = label
                taxesAndFees[idx].amountText = storedAmount
            } else {
                taxesAndFees.append(AuxLineForm(label: label, amountText: storedAmount))
            }
        case .preTipTotal, .tip:
            break
        }
        closeEditor()
    }

    private func closeEditor() {
        editorFocusedField = nil
        editorMode = .none
        editorLabel = ""
        editorAmount = ""
        editorIsDiscount = false
    }

    private var editorTitle: String {
        switch editorMode {
        case .none: return ""
        case .item(let id): return id == nil ? "Add Item" : "Edit Item"
        case .fee(let id):
            if editorIsDiscount { return id == nil ? "Add Discount" : "Edit Discount" }
            return id == nil ? "Add Tax / Fee" : "Edit Tax / Fee"
        case .preTipTotal: return "Override Total"
        case .tip: return "Edit Tip Amount"
        }
    }

    private var editorLabelPlaceholder: String {
        switch editorMode {
        case .none: return ""
        case .item: return "Item name"
        case .fee: return editorIsDiscount ? "Discount" : "Tax or fee"
        case .preTipTotal, .tip: return ""
        }
    }

    private var showsEditorLabelField: Bool {
        switch editorMode {
        case .item, .fee:
            return true
        case .none, .preTipTotal, .tip:
            return false
        }
    }

    private var editorAmountPlaceholder: String {
        switch editorMode {
        case .preTipTotal:
            return "Auto"
        case .none, .tip, .item, .fee:
            return "0.00"
        }
    }

    private func sanitizedUSDAmountInput(_ raw: String, allowNegative: Bool = false) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let isNegative = allowNegative && trimmed.hasPrefix("-")
        let digits = isNegative ? String(trimmed.dropFirst()) : trimmed

        var integerPart = ""
        var fractionalPart = ""
        var hasDecimalSeparator = false

        for char in digits {
            if char.isWholeNumber {
                if hasDecimalSeparator {
                    if fractionalPart.count < 2 {
                        fractionalPart.append(char)
                    }
                } else {
                    integerPart.append(char)
                }
            } else if char == "." && !hasDecimalSeparator {
                hasDecimalSeparator = true
            }
        }

        if integerPart.isEmpty {
            integerPart = "0"
        } else {
            integerPart = String(integerPart.drop { $0 == "0" })
            if integerPart.isEmpty {
                integerPart = "0"
            }
        }

        let prefix = isNegative ? "-" : ""
        if hasDecimalSeparator {
            return "\(prefix)\(integerPart).\(fractionalPart)"
        }
        return "\(prefix)\(integerPart)"
    }

    private func normalizedUSDAmountForStorage(_ raw: String) -> String {
        let sanitized = sanitizedUSDAmountInput(raw)
        guard !sanitized.isEmpty else { return "" }
        return centsToDecimalString(stringToCents(sanitized))
    }
    
    private func saveReceipt() {
        // Aggregate fees by type (tax vs fees/discounts — tip is separate)
        // Label containing "tax" → taxTotal; everything else → feesTotal (signed, negative = discount)
        var taxTotal = 0
        var feesTotal = 0
        var discountTotal = 0

        for fee in completedFees {
            let label = fee.label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let amount = fee.amountCents

            if label.contains("tax") {
                taxTotal += max(0, amount)  // tax is always positive
            } else if amount < 0 {
                discountTotal += abs(amount)
            } else {
                feesTotal += amount
            }
        }

        let subtotal = preTipTotalCents - taxTotal - feesTotal + discountTotal

        // Final total is always pre-tip + tip
        let finalTotalCents = calculatedTotalCents

        // Persist explicit override intent only when user kept a non-empty override value.
        if preTipTotalOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            receiptDraftVM.preTipTotalOverrideCents = nil
        } else {
            receiptDraftVM.preTipTotalOverrideCents = preTipTotalCents
        }

        let feeLineItems = completedFees.compactMap { fee -> ReceiptDisplay.LineItem? in
            let amount = fee.amountCents
            guard amount != 0 else { return nil }
            return ReceiptDisplay.LineItem(id: fee.id.uuidString, label: fee.label, cents: amount)
        }

        let updatedReceipt = ReceiptDisplay(
            id: receiptDraftVM.currentReceipt?.id ?? UUID().uuidString,
            title: receiptName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Receipt" : receiptName,
            createdAt: receiptDraftVM.currentReceipt?.createdAt ?? Date(),
            subtotalCents: subtotal,
            feesCents: feesTotal,
            discountCents: discountTotal,
            taxCents: taxTotal,
            tipCents: tipCents,
            totalCents: finalTotalCents,
            items: completedItems.map { item in
                ReceiptDisplay.Item(
                    id: item.id.uuidString,
                    label: item.label,
                    priceCents: item.priceCents
                )
            },
            lineItems: feeLineItems
        )

        onSave(updatedReceipt)
    }
    
    private var captureImage: UIImage? {
        receiptDraftVM.scanImageCropped ?? receiptDraftVM.scanImageOriginal
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

                    HStack(spacing: 16) {
                        if !receiptDraftVM.debugChunkImages.isEmpty {
                            Button {
                                showChunks = true
                            } label: {
                                Image(systemName: "square.grid.3x3")
                                    .font(.system(size: 16))
                            }
                            .buttonStyle(.plain)
                        }

                        if captureImage != nil {
                            Button {
                                showCapture = true
                            } label: {
                                Image(systemName: "doc.viewfinder")
                                    .font(.system(size: 16))
                            }
                            .buttonStyle(.plain)
                        }

                        Button("Save") {
                            saveReceipt()
                        }
                        .buttonStyle(.plain)
                        .fontWeight(.semibold)
                    }
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
                                                Text(ReceiptDisplay.money(item.priceCents))
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
                                Text(ReceiptDisplay.money(calculatedSubtotalCents))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 4)
                        }

                        // MARK: - Taxes, Fees & Discounts Section
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Taxes, Fees & Discounts")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary)

                            // Fees list (signed amounts: negative = discount)
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
                                                Text(ReceiptDisplay.money(fee.amountCents))
                                                    .font(.system(size: 16, weight: .medium))
                                                    .foregroundColor(fee.amountCents < 0 ? .green : .primary)
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

                            // Add tax/fee and add discount buttons
                            HStack(spacing: 10) {
                                Button {
                                    openEditor(mode: .fee(nil), focusField: .label, isDiscount: false)
                                } label: {
                                    HStack {
                                        Image(systemName: "plus.circle.fill")
                                            .foregroundColor(.blue)
                                        Text("Add Tax / Fee")
                                            .foregroundColor(.blue)
                                        Spacer()
                                    }
                                    .font(.system(size: 15, weight: .medium))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .background(Color(.secondarySystemBackground).opacity(0.6))
                                    .cornerRadius(12)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    openEditor(mode: .fee(nil), focusField: .amount, isDiscount: true)
                                } label: {
                                    HStack {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundColor(.green)
                                        Text("Add Discount")
                                            .foregroundColor(.green)
                                        Spacer()
                                    }
                                    .font(.system(size: 15, weight: .medium))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .background(Color(.secondarySystemBackground).opacity(0.6))
                                    .cornerRadius(12)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // MARK: - Pre-tip Total & Tip Section
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Total")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary)

                            VStack(spacing: 0) {
                                HStack {
                                    Text(hasPreTipWarning ? "Pre-tip total (Overridden)" : "Pre-tip total")
                                        .font(.system(size: 14, weight: .regular))
                                    Spacer()
                                    Button {
                                        openEditor(mode: .preTipTotal, focusField: .amount)
                                    } label: {
                                        Text(ReceiptDisplay.money(preTipTotalCents))
                                            .font(.system(size: 14, weight: .regular))
                                            .foregroundColor(hasPreTipWarning ? .primary : .secondary)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color(.tertiarySystemFill))
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)

                                HStack {
                                    Text("Tip amount")
                                        .font(.system(size: 14, weight: .regular))
                                    Spacer()
                                    Button {
                                        openEditor(mode: .tip, focusField: .amount)
                                    } label: {
                                        Text(ReceiptDisplay.money(stringToCents(
                                            tipString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "0.00" : tipString
                                        )))
                                            .font(.system(size: 14, weight: .regular))
                                            .foregroundColor(.blue)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color(.tertiarySystemFill))
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)

                                Divider()
                                    .padding(.horizontal, 16)

                                HStack {
                                    Text("Total")
                                        .font(.system(size: 15, weight: .semibold))
                                    Spacer()
                                    Text(ReceiptDisplay.money(calculatedTotalCents))
                                        .font(.system(size: 15, weight: .semibold))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                            }
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)

                            if hasPreTipWarning {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 13))
                                    Text("Total does not match calculated")
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
                            if showsEditorLabelField {
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
                            }

                            if editorIsDiscount {
                                Text("−")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundColor(.green)
                            }

                            TextField(editorAmountPlaceholder, text: $editorAmount)
                                .font(.system(size: 16))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(.tertiarySystemBackground))
                                .cornerRadius(8)
                                .frame(width: showsEditorLabelField ? 100 : nil)
                                .focused($editorFocusedField, equals: .amount)
                                .onChange(of: editorAmount) { _, newValue in
                                    let sanitized = sanitizedUSDAmountInput(newValue)
                                    if sanitized != newValue {
                                        editorAmount = sanitized
                                    }
                                }
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
        .sheet(isPresented: $showCapture) {
            CapturePreviewView(image: captureImage) {
                showCapture = false
            }
        }
        .sheet(isPresented: $showChunks) {
            ChunkDebugView(chunks: receiptDraftVM.debugChunkImages)
        }
    }
}

// MARK: - Chunk debug sheet

private struct ChunkDebugView: View {
    let chunks: [UIImage]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(Array(chunks.enumerated()), id: \.offset) { index, image in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Chunk \(index + 1)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 16)

                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(8)
                                .padding(.horizontal, 16)
                        }
                    }
                }
                .padding(.vertical, 16)
            }
            .navigationTitle("OCR Chunks (\(chunks.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
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
