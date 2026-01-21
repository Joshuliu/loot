//
//  RootContainerView.swift
//  Loot
//
//  Created by Joshua Liu on 1/1/26.
//

import SwiftUI

struct RootContainerView: View {
    @AppStorage(DefaultsKeys.myDisplayName) private var myName: String = ""
    @ObservedObject var uiModel: LootUIModel

    @State private var screen: Screen = .tabview
    @State private var showSplitViewSheet: Bool = false
    @State private var confirmationCameFromManual: Bool = false
    
    @State private var receiptName: String = ""
    @State private var splitDraft: SplitDraft? = nil
    @State private var amountString: String = "0"
    @State private var tipAmount: String = ""
    @State private var returnScreen: Screen = .tabview
    @Namespace private var titleNamespace
    
    // Computed total: subtotal + tax + fees - discounts + tip
    private var totalAmount: String {
        // If we have a receipt with breakdown, use its total (includes tax, fees, discounts, tip)
        if let receipt = uiModel.currentReceipt {
            return String(format: "%.2f", Double(receipt.totalCents) / 100.0)
        }
        
        // Otherwise, calculate from manual entry (subtotal + tip only, no tax/fees/discounts in manual flow)
        guard !tipAmount.isEmpty, tipAmount != "$0", tipAmount != "$0.00" else {
            return amountString
        }
        let subtotal = amountToCents(amountString)
        let tip = amountToCents(tipAmount)
        let total = subtotal + tip
        return String(format: "%.2f", Double(total) / 100.0)
    }
    
    let participantCount: Int
    let onScan: () -> Void
    let onExpand: () -> Void
    let onCollapse: () -> Void
    let onSendBill: (String, String) -> Void

    // Camera sheet state
    @State private var showCamera: Bool = false
    @State private var capturedImage: UIImage? = nil
    
    // Photo library state
    @State private var showPhotoLibrary: Bool = false
    @State private var photoLibraryImage: UIImage? = nil
    
    @State private var isAnalyzing: Bool = false
    @State private var analyzeError: String?

    init(uiModel: LootUIModel) {
        self.uiModel = uiModel
        self.participantCount = 1
        self.onScan = {}
        self.onExpand = {}
        self.onCollapse = {}
        self.onSendBill = { _, _ in }
    }

    init(
        uiModel: LootUIModel,
        participantCount: Int,
        onScan: @escaping () -> Void,
        onExpand: @escaping () -> Void,
        onCollapse: @escaping () -> Void,
        onSendBill: @escaping (String, String) -> Void
    ) {
        self.uiModel = uiModel
        self.participantCount = participantCount
        self.onScan = onScan
        self.onExpand = onExpand
        self.onCollapse = onCollapse
        self.onSendBill = onSendBill
    }

    // MARK: - Helpers

    private func amountToCents(_ str: String) -> Int {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        if trimmed.isEmpty { return 0 }

        if trimmed.contains(".") {
            let parts = trimmed.split(separator: ".", maxSplits: 1)
            let dollars = Int(parts.first ?? "0") ?? 0
            let centsPart = parts.count > 1 ? String(parts[1]) : ""
            let cents2: Int
            if centsPart.isEmpty {
                cents2 = 0
            } else if centsPart.count == 1 {
                cents2 = Int(centsPart + "0") ?? 0
            } else {
                cents2 = Int(String(centsPart.prefix(2))) ?? 0
            }
            return dollars * 100 + cents2
        } else {
            let dollars = Int(trimmed) ?? 0
            return dollars * 100
        }
    }

    private func makePreviewReceipt() -> ReceiptDisplay {
        let hasTip = !tipAmount.isEmpty && tipAmount != "$0" && tipAmount != "$0.00"
        
        let subtotalCents = amountToCents(amountString)
        let tipCents = hasTip ? amountToCents(tipAmount) : 0
        let totalCents = subtotalCents + tipCents
        
        return ReceiptDisplay(
            id: "preview",
            title: receiptName.isEmpty ? "New Receipt" : receiptName,
            createdAt: Date(),
            subtotalCents: subtotalCents,
            feesCents: 0,
            taxCents: 0,
            tipCents: tipCents,
            discountCents: 0,
            totalCents: totalCents,
            items: []
        )
    }

    private func startScanFlow() {
        onScan()
        analyzeError = nil
        capturedImage = nil
        showCamera = true
    }

    private func startPhotoLibraryFlow() {
        analyzeError = nil
        photoLibraryImage = nil
        showPhotoLibrary = true
    }

    private func analyzeCaptured(image: UIImage) {
        analyzeCapturedTwoPhase(image: image)
    }

    /// Two-phase receipt analysis:
    /// Phase 1: Quick merchant + total extraction → Navigate immediately
    /// Phase 2: Full items + breakdown (runs in background)
    private func analyzeCapturedTwoPhase(image: UIImage) {
        isAnalyzing = true
        analyzeError = nil

        Task {
            do {
                // UPLOAD: Upload image once, get file URI for reuse
                print("[Scan] Uploading image...")
                let fileUri = try await LLMClient.shared.uploadImage(image)

                // PHASE 1: Quick merchant + total extraction
                print("[Scan] Phase 1: Extracting merchant and total...")
                let phase1 = try await LLMClient.shared.analyzeReceiptPhase1(fileUri: fileUri)
                print("[Scan] Phase 1 complete: merchant=\(phase1.merchant ?? "nil"), total=\(phase1.total_cents ?? 0)")

                let total = max(0, phase1.total_cents ?? 0)

                await MainActor.run {
                    // Update form fields with phase 1 data
                    amountString = String(format: "%.2f", Double(total) / 100.0)

                    if let merchant = phase1.merchant, !merchant.isEmpty {
                        receiptName = merchant
                    }

                    // Create partial receipt (empty items - will be populated by phase 2)
                    uiModel.currentReceipt = ReceiptDisplay(
                        id: UUID().uuidString,
                        title: phase1.merchant ?? (receiptName.isEmpty ? "New Receipt" : receiptName),
                        createdAt: Date(),
                        subtotalCents: total,  // Use total as subtotal initially
                        feesCents: 0,
                        taxCents: 0,
                        tipCents: 0,
                        discountCents: 0,
                        totalCents: total,
                        items: []  // Empty - loading
                    )

                    uiModel.itemsLoadingState = .loading
                    confirmationCameFromManual = false

                    // Navigate immediately after phase 1!
                    isAnalyzing = false
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        screen = .confirmation
                    }
                }

                // PHASE 2: Background item extraction (reuses same file URI)
                let knownTotal = total
                uiModel.phase2Task = Task { @MainActor in
                    do {
                        print("[Scan] Phase 2: Extracting items and breakdown...")
                        let phase2 = try await LLMClient.shared.analyzeReceiptPhase2(
                            fileUri: fileUri,
                            knownTotalCents: knownTotal
                        )
                        print("[Scan] Phase 2 complete: \(phase2.items.count) items")

                        // Build full ParsedReceipt for compatibility
                        let fullParsed = ParsedReceipt(
                            merchant: phase1.merchant,
                            total_cents: knownTotal,
                            subtotal_cents: phase2.subtotal_cents,
                            tax_cents: phase2.tax_cents,
                            tip_cents: phase2.tip_cents,
                            fees_cents: phase2.fees_cents,
                            discount_cents: phase2.discount_cents,
                            items: phase2.items.map { ParsedReceipt.Item(label: $0.label, qty: $0.qty, cents: $0.cents) },
                            issues: phase2.issues
                        )
                        uiModel.parsedReceipt = fullParsed

                        // Extract breakdown
                        let breakdown = fullParsed.breakdownDefaults()
                        let subtotal = max(0, phase2.subtotal_cents ?? (knownTotal - breakdown.tax - breakdown.fees - breakdown.tip + breakdown.discount))

                        // Prefill tip if present
                        if breakdown.tip > 0 {
                            tipAmount = String(format: "%.2f", Double(breakdown.tip) / 100.0)
                        }

                        // Update subtotal field
                        amountString = String(format: "%.2f", Double(subtotal) / 100.0)

                        // Rebuild currentReceipt with items + breakdown
                        uiModel.currentReceipt = ReceiptDisplay(
                            id: uiModel.currentReceipt?.id ?? UUID().uuidString,
                            title: phase1.merchant ?? (receiptName.isEmpty ? "New Receipt" : receiptName),
                            createdAt: Date(),
                            subtotalCents: subtotal,
                            feesCents: breakdown.fees,
                            taxCents: breakdown.tax,
                            tipCents: breakdown.tip,
                            discountCents: breakdown.discount,
                            totalCents: knownTotal,
                            items: fullParsed.toDisplayItems()
                        )

                        uiModel.itemsLoadingState = .loaded(phase2)
                    } catch {
                        print("[Scan] Phase 2 failed: \(error)")
                        uiModel.itemsLoadingState = .failed(error)
                        // Receipt is still usable with merchant/total from phase 1
                    }
                }

            } catch {
                print("[Scan] analyzeReceipt failed: \(error)")
                await MainActor.run {
                    isAnalyzing = false
                    analyzeError = "Scan failed: \(error.localizedDescription)"
                }
            }
        }
    }
    @MainActor
    private func applySplitDraftToCurrentReceipt(_ draft: SplitDraft) {
        guard let r = uiModel.currentReceipt else { return }

        let updatedItems: [ReceiptDisplay.Item] = {
            switch draft.mode {
            case .byItems:
                let activeGuests = draft.activeGuests
                func displayName(_ g: SplitGuest, at activeIndex: Int) -> String {
                    let t = g.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { return t }
                    if g.isMe {
                        let me = myDisplayNameFromDefaults().trimmingCharacters(in: .whitespacesAndNewlines)
                        return me.isEmpty ? "Me" : me
                    }
                    return "Guest \(activeIndex + 1)"
                }

                return draft.items.map { it in
                    let responsible = it.assignedGuestIds.compactMap { gid -> ReceiptDisplay.Responsible? in
                        guard let idx = activeGuests.firstIndex(where: { $0.id == gid }) else { return nil }
                        return ReceiptDisplay.Responsible(
                            slotIndex: idx,
                            displayName: displayName(activeGuests[idx], at: idx)
                        )
                    }.sorted(by: { $0.slotIndex < $1.slotIndex })
                    return ReceiptDisplay.Item(
                        id: it.id.uuidString, // adjust if your Item.id type differs
                        label: it.label,
                        priceCents: it.priceCents,
                        responsible: responsible
                    )
                }

            case .equally, .custom:
                return r.items.map { old in
                    ReceiptDisplay.Item(id: old.id, label: old.label, priceCents: old.priceCents, responsible: [])
                }
            }
        }()

        uiModel.currentReceipt = ReceiptDisplay(
            id: r.id,
            title: r.title,
            createdAt: r.createdAt,
            subtotalCents: updatedItems.reduce(0) { $0 + $1.priceCents },
            feesCents: draft.feesCents,
            taxCents: draft.taxCents,
            tipCents: draft.tipCents,
            discountCents: draft.discountCents,
            totalCents: draft.totalCents,
            items: updatedItems
        )
    }
    // MARK: - Body

    var body: some View {
        Group {
            if myName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                IntroView(
                    onRequestExpand: onExpand,
                    onContinue: { name in
                        myName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                )
            } else {
                ZStack {
                    switch screen {
                        
                    case .tabview:
                        TabView(
                            tabName: Binding(
                                get: { receiptName },
                                set: { receiptName = $0 }
                            ),
                            onUpload: {
                                startPhotoLibraryFlow()
                            },
                            onScan: {
                                startScanFlow()
                            },
                            onFill: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    screen = .fill
                                }
                            }
                        )
                        .transition(.opacity)
                        
                    case .fill:
                        ManualInputView(
                            viewModel: uiModel,
                            receiptName: $receiptName,
                            amountString: $amountString,
                            tipAmount: $tipAmount,
                            onBack: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    screen = .tabview
                                }
                            },
                            onNext: {
                                // Create receipt before transitioning
                                uiModel.currentReceipt = makePreviewReceipt()
                                confirmationCameFromManual = true
                                
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    screen = .confirmation
                                }
                            },
                            onAddTip: {
                                // Go to tip view (amountString is already the subtotal)
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    screen = .tipview
                                }
                            },
                            onRequestExpand: onExpand,
                            onRequestCollapse: onCollapse,
                            titleNamespace: titleNamespace
                        )
                        .transition(.opacity)
                        
                    case .tipview:
                        TipView(
                            subtotalString: amountString,  // Pass the subtotal directly
                            onBack: {
                                // Return to fill without changes
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    screen = .fill
                                }
                            },
                            onNext: { tip, _ in
                                // Only update the tip amount, subtotal stays in amountString
                                tipAmount = tip
                                
                                // Create receipt with tip breakdown
                                uiModel.currentReceipt = makePreviewReceipt()
                                
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    screen = .confirmation
                                }
                            }
                        )
                        .transition(.opacity)
                        
                    case .confirmation:
                        ConfirmationView(
                            uiModel: uiModel,
                            receiptName: receiptName,
                            amount: totalAmount,  // Use computed total for display
                            participantCount: participantCount,
                            splitMode: splitDraft?.mode,
                            splitDraft: splitDraft,
                            tipAmount: tipAmount,
                            cameFromManual: confirmationCameFromManual,
                            onBack: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    screen = .fill
                                }
                            },
                            onSend: {
                                onSendBill(receiptName, totalAmount)  // Send the total amount
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        screen = .tabview
                                    }
                                }
                            },
                            onPreviewReceipt: {
                                returnScreen = .confirmation
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    screen = .receipt
                                }
                            },
                            onDeleteToLanding: {
                                uiModel.resetForNewReceipt()
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    screen = .tabview
                                }
                            },
                            onGoToSplit: {
                                showSplitViewSheet = true
                            },
                            onAddTip: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    screen = .tipview
                                }
                            },
                            onRequestCollapse: onCollapse
                        )
                        .transition(.opacity)
                        
                    case .receipt:
                        if let receipt = uiModel.currentReceipt {
                            ReceiptView(uiModel: uiModel, receipt: receipt) {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    screen = returnScreen
                                }
                            }
                        } else {
                            ProgressView("Loading…")
                        }
                    case .messageViewer:
                        if let payload = uiModel.openedMessagePayload {
                            MessageReceiptViewer(
                                uiModel: uiModel,
                                payload: payload,
                                onClose: {
                                    uiModel.openedMessagePayload = nil
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        screen = .tabview
                                    }
                                }
                            )
                        } else {
                            ProgressView("Loading…")
                        }
                    }
                }
                .sheet(
                    isPresented: $showCamera,
                    onDismiss: {
                        guard let img = capturedImage else { return }
                        ReceiptCrop.run(img) { cropped in
                            uiModel.scanImageOriginal = img
                            uiModel.scanImageCropped = cropped
                            analyzeCaptured(image: cropped)
                        }
                    }
                ) { CameraPicker(image: $capturedImage).ignoresSafeArea() }
                .sheet(
                    isPresented: $showPhotoLibrary,
                    onDismiss: {
                        guard let img = photoLibraryImage else { return }
                        ReceiptCrop.run(img) { cropped in
                            uiModel.scanImageOriginal = img
                            uiModel.scanImageCropped = cropped
                            analyzeCaptured(image: cropped)
                        }
                    }
                ) { PhotoLibraryPicker(image: $photoLibraryImage).ignoresSafeArea() }
                .sheet(isPresented: $showSplitViewSheet) {
                    SplitView(
                        uiModel: uiModel,
                        amountString: totalAmount,
                        participantCount: participantCount,
                        initialDraft: splitDraft,
                        onBack: {
                            showSplitViewSheet = false
                        },
                        onApply: { draft in
                            splitDraft = draft
                            uiModel.currentSplitDraft = draft
                            applySplitDraftToCurrentReceipt(draft)
                            showSplitViewSheet = false
                        }
                    )
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationContentInteraction(.scrolls)
                }
                .overlay {
                    if isAnalyzing {
                        ZStack {
                            Color.black.opacity(0.25).ignoresSafeArea()
                            ProgressView("Analyzing receipt…")
                                .padding()
                                .background(Color(.systemBackground))
                                .cornerRadius(12)
                        }
                    }
                }
                .alert("Scan failed", isPresented: Binding(
                    get: { analyzeError != nil },
                    set: { _ in analyzeError = nil }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(analyzeError ?? "")
                }
                .onAppear {
                    if uiModel.openedMessagePayload != nil {
                        screen = .messageViewer
                    }
                }
                .onChange(of: uiModel.openedMessagePayload) { _, newValue in
                    if newValue != nil {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            screen = .messageViewer
                        }
                    }
                }
            }
        }
    }
}

enum Screen {
    case tabview
    case fill
    case tipview
    case confirmation
    case receipt
    case messageViewer
}
