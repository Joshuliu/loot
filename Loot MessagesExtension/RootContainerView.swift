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
    @State private var receiptName: String = ""
    @State private var splitDraft: SplitDraft? = nil
    @State private var amountString: String = "0"
    @State private var returnScreen: Screen = .tabview
    @Namespace private var titleNamespace
    
    let participantCount: Int
    let onScan: () -> Void
    let onExpand: () -> Void
    let onCollapse: () -> Void
    let onSendBill: (String, String) -> Void

    // Camera sheet state
    @State private var showCamera: Bool = false
    @State private var capturedImage: UIImage? = nil
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
        let cents = amountToCents(amountString)
        return ReceiptDisplay(
            id: "preview",
            title: receiptName.isEmpty ? "New Receipt" : receiptName,
            createdAt: Date(),
            subtotalCents: cents,
            feesCents: 0,
            taxCents: 0,
            tipCents: 0,
            discountCents: 0,
            totalCents: cents,
            items: []
        )
    }

    private func startScanFlow() {
        onScan()
        analyzeError = nil
        capturedImage = nil
        showCamera = true
    }

    private func analyzeCaptured(image: UIImage) {
        isAnalyzing = true
        analyzeError = nil
        
        Task {
            defer { isAnalyzing = false }
            do {
                let parsed = try await LLMClient.shared.analyzeReceipt(image: image)
                await MainActor.run {
                    uiModel.parsedReceipt = parsed

                    // Prefill form fields
                    let bestTotal = parsed.total_cents ?? parsed.bestTotalCents()
                    amountString = String(format: "%.2f", Double(bestTotal) / 100.0)

                    if let merchant = parsed.merchant, !merchant.isEmpty {
                        receiptName = merchant
                    }

                    let breakdown = parsed.breakdownDefaults()
                    let total = parsed.bestTotalCents()
                    let subtotal = max(0, parsed.subtotal_cents ?? total)

                    uiModel.currentReceipt = ReceiptDisplay(
                        id: UUID().uuidString,
                        title: parsed.displayTitle(fallback: receiptName.isEmpty ? "New Receipt" : receiptName),
                        createdAt: Date(),

                        subtotalCents: subtotal,
                        feesCents: breakdown.fees,
                        taxCents: breakdown.tax,
                        tipCents: breakdown.tip,
                        discountCents: breakdown.discount,
                        totalCents: total,

                        items: parsed.toDisplayItems()
                    )

                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        screen = .confirmation
                    }
                }
            } catch {
                print("[Scan] analyzeReceipt failed: \(error)")
                await MainActor.run {
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
            if myDisplayNameFromDefaults().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                                // TODO: Change to upload image instead of scan flow
                                startScanFlow()
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
                            onBack: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    screen = .tabview
                                }
                            },
                            onNext: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    screen = .confirmation
                                }
                            },
                            onRequestExpand: onExpand,
                            onRequestCollapse: onCollapse,
                            titleNamespace: titleNamespace
                        )
                        .transition(.opacity)
                        
                    case .confirmation:
                        ConfirmationView(
                            receiptName: receiptName,
                            amount: amountString,
                            participantCount: participantCount,
                            splitMode: splitDraft?.mode,
                            onBack: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    screen = .fill
                                }
                            },
                            onSend: {
                                onSendBill(receiptName, amountString)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
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
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    screen = .splitview
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
                        
                    case .splitview:
                        SplitView(
                            uiModel: uiModel,
                            amountString: amountString,
                            participantCount: participantCount,
                            initialDraft: splitDraft,
                            onRequestExpand: onExpand,
                            onBack: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    screen = .confirmation
                                }
                            },
                            onApply: { draft in
                                splitDraft = draft
                                uiModel.currentSplitDraft = draft
                                applySplitDraftToCurrentReceipt(draft)
                            }
                        )
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
    case confirmation
    case receipt
    case splitview
    case messageViewer
}
