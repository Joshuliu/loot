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

    @State private var showSplitViewSheet: Bool = false
    @State private var confirmationCameFromManual: Bool = false
    @State private var paymentMethodsIsPostSend: Bool = false

    @State private var receiptName: String = ""
    @State private var splitDraft: SplitDraft? = nil
    @State private var amountString: String = "0"
    @State private var tipAmount: String = ""
    @State private var returnScreen: AppScreen = .tabview
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
        let subtotal = stringToCents(amountString)
        let tip = stringToCents(tipAmount)
        let total = subtotal + tip
        return String(format: "%.2f", Double(total) / 100.0)
    }
    
    let participantCount: Int
    let onScan: () -> Void
    let onExpand: () -> Void
    let onCollapse: () -> Void
    let onSendBill: (String, String) -> Void
    let onSendTabInvite: ((String, String, String) -> Void)?  // (tabName, tabColorHex, tabId)

    // Tab creation state
    @State private var pendingTabName: String = ""
    @State private var pendingTabColor: String = TabColorOptions.defaultHex
    @State private var pendingTabId: String = ""
    @State private var tabInviteCameFromTabView: Bool = false

    // DEBUG: Set to true to only run VisionKit OCR and print JSON (no Gemini)
    private let DEBUG_OCR_ONLY = false
    // DEBUG: Set to true to copy OCR transcript to clipboard after each scan
    private let DEBUG_COPY_TRANSCRIPT = true
    // DEBUG: Set to true to show OCR chunk images in Edit Receipt view
    private let DEBUG_SHOW_CHUNKS = true
    @State private var debugOCRResult: OCRResult? = nil
    @State private var debugOriginalImage: UIImage? = nil

    // Camera sheet state
    @State private var showCamera: Bool = false
    @State private var capturedImage: UIImage? = nil
    
    // Photo library state
    @State private var showPhotoLibrary: Bool = false
    @State private var photoLibraryImage: UIImage? = nil
    
    @State private var analyzeError: String?
    @State private var pendingTranscriptTask: Task<String, Error>? = nil

    // Backend user restore state
    @State private var isCheckingBackendUser: Bool = true

    init(uiModel: LootUIModel) {
        self.uiModel = uiModel
        self.participantCount = 1
        self.onScan = {}
        self.onExpand = {}
        self.onCollapse = {}
        self.onSendBill = { _, _ in }
        self.onSendTabInvite = nil
    }

    init(
        uiModel: LootUIModel,
        participantCount: Int,
        onScan: @escaping () -> Void,
        onExpand: @escaping () -> Void,
        onCollapse: @escaping () -> Void,
        onSendBill: @escaping (String, String) -> Void,
        onSendTabInvite: ((String, String, String) -> Void)? = nil
    ) {
        self.uiModel = uiModel
        self.participantCount = participantCount
        self.onScan = onScan
        self.onExpand = onExpand
        self.onCollapse = onCollapse
        self.onSendBill = onSendBill
        self.onSendTabInvite = onSendTabInvite
    }

    private func makePreviewReceipt() -> ReceiptDisplay {
        let hasTip = !tipAmount.isEmpty && tipAmount != "$0" && tipAmount != "$0.00"
        
        let subtotalCents = stringToCents(amountString)
        let tipCents = hasTip ? stringToCents(tipAmount) : 0
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

    // MARK: - Session persistence helpers

    private func saveSession(screen: AppScreen) {
        guard screen.isPersistableScreen,
              let key = uiModel.conversationKey else { return }
        SessionPersistence.save(
            screen: screen,
            receipt: uiModel.currentReceipt,
            parsedReceipt: uiModel.parsedReceipt,
            splitDraft: uiModel.currentSplitDraft,
            image: uiModel.scanImageCropped,
            conversationKey: key
        )
    }

    private func restoreSession(conversationKey: String) {
        // Only restore if we haven't already navigated away from the landing screen
        guard uiModel.currentScreen == .tabview else { return }
        guard let session = SessionPersistence.load(conversationKey: conversationKey) else { return }

        let screen = AppScreen.from(persistenceKey: session.screenName)
        guard screen != .tabview else { return }

        uiModel.currentReceipt = session.currentReceipt
        uiModel.parsedReceipt = session.parsedReceipt
        uiModel.currentSplitDraft = session.splitDraft
        if let img = SessionPersistence.loadImage(conversationKey: conversationKey) {
            uiModel.scanImageCropped = img
        }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            uiModel.currentScreen = screen
        }
        print("[Session] Restored to .\(session.screenName) from \(Int(-session.savedAt.timeIntervalSinceNow))s ago")
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
        if DEBUG_OCR_ONLY {
            debugOCROnly(image: image)
            return
        }
        analyzeCapturedTwoPhase(image: image)
    }

    /// DEBUG: Run VisionKit OCR only and output structured JSON.
    /// Processing logic lives in LegacyOCRPipeline.swift.
    private func debugOCROnly(image: UIImage) {
        analyzeError = nil
        Task {
            do {
                let (straightenedImage, straightenAngle) = try await LegacyOCRPipeline.straightenImage(image)
                print("[Debug] Rotation applied: \(String(format: "%.2f", straightenAngle))°")

                let initialOCR = try await LegacyOCRPipeline.runVisionKitOCR(image: straightenedImage)
                var workingImage = LegacyOCRPipeline.cropToOCRBounds(straightenedImage, ocrResult: initialOCR)

                let slopeThreshold = 0.015
                for iteration in 1...3 {
                    let iterOCR = try await LegacyOCRPipeline.runVisionKitOCR(image: workingImage)
                    guard let slope = LegacyOCRPipeline.detectSkewSlope(from: iterOCR) else { break }
                    if abs(slope) < slopeThreshold { break }
                    print("[Debug] Iteration \(iteration): shear slope \(String(format: "%.4f", slope))")
                    workingImage = LegacyOCRPipeline.applyHorizontalShear(workingImage, slope: -slope)
                }

                workingImage = LegacyOCRPipeline.enhanceImageForOCR(workingImage)

                let rawOCRResult = try await LegacyOCRPipeline.runVisionKitOCR(image: workingImage)
                let processedResult = LegacyOCRPipeline.preprocessOCR(rawOCRResult)

                await MainActor.run {
                    debugOCRResult = processedResult
                    debugOriginalImage = workingImage
                }
            } catch {
                print("[DEBUG OCR] Failed: \(error)")
                await MainActor.run { analyzeError = "OCR failed: \(error.localizedDescription)" }
            }
        }
    }

    /// Two-phase receipt analysis:
    /// Phase 1: Quick merchant + total extraction → Navigate immediately
    /// Phase 2: Full items + breakdown (runs in background)
    private func analyzeCapturedTwoPhase(image: UIImage) {
        analyzeError = nil
        let capturedTranscriptTask = pendingTranscriptTask

        Task {
            do {
                // TRANSCRIPT: Await transcript from background task (started during camera review)
                // or generate it now if no pre-started task is available.
                print("[Scan] Awaiting transcript...")
                let transcriptStart = Date()
                let transcript: String
                if let task = capturedTranscriptTask {
                    transcript = try await task.value
                } else {
                    transcript = try await TranscriptGenerator.generate(from: image)
                }
                let transcriptElapsed = Date().timeIntervalSince(transcriptStart)
                print(String(format: "[Scan] Transcript ready (%d chars, %.1fs)", transcript.count, transcriptElapsed))
                if DEBUG_COPY_TRANSCRIPT {
                    await MainActor.run { UIPasteboard.general.string = transcript }
                    print("[Scan] Transcript copied to clipboard")
                }
                if DEBUG_SHOW_CHUNKS {
                    let chunks = TranscriptGenerator.lastDebugChunks
                    await MainActor.run { uiModel.debugChunkImages = chunks }
                    print("[Scan] \(chunks.count) chunk image(s) saved for debug")
                }

                // PHASE 1: Quick merchant + total extraction
                print("[Scan] Phase 1: Extracting merchant and total...")
                let phase1 = try await LLMClient.shared.analyzeReceiptPhase1(transcript: transcript)
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
                    // Phase 1 complete — clear loading state (navigation already happened)
                    uiModel.isLoadingReceipt = false
                }

                // PHASE 2: Background item extraction (reuses transcript)
                let knownTotal = total
                uiModel.phase2Task = Task { @MainActor in
                    do {
                        print("[Scan] Phase 2: Extracting items and breakdown...")
                        let phase2 = try await LLMClient.shared.analyzeReceiptPhase2(
                            transcript: transcript,
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

                        // Check if user already added a tip manually (don't overwrite it)
                        let userAddedTip = !tipAmount.isEmpty && tipAmount != "$0" && tipAmount != "$0.00"
                        let existingUserTip = uiModel.currentReceipt?.tipCents ?? 0

                        // Only prefill tip from scan if user hasn't added one manually
                        if !userAddedTip && existingUserTip == 0 && breakdown.tip > 0 {
                            tipAmount = String(format: "%.2f", Double(breakdown.tip) / 100.0)
                        }

                        // Preserve user's tip if they added one, otherwise use scanned tip
                        let finalTipCents: Int
                        if userAddedTip {
                            finalTipCents = stringToCents(tipAmount)
                        } else if existingUserTip > 0 {
                            finalTipCents = existingUserTip
                        } else {
                            finalTipCents = breakdown.tip
                        }

                        // Update subtotal field
                        amountString = String(format: "%.2f", Double(subtotal) / 100.0)

                        // Rebuild currentReceipt with items + breakdown, preserving user's tip
                        uiModel.currentReceipt = ReceiptDisplay(
                            id: uiModel.currentReceipt?.id ?? UUID().uuidString,
                            title: phase1.merchant ?? (receiptName.isEmpty ? "New Receipt" : receiptName),
                            createdAt: Date(),
                            subtotalCents: subtotal,
                            feesCents: breakdown.fees,
                            taxCents: breakdown.tax,
                            tipCents: finalTipCents,
                            discountCents: breakdown.discount,
                            totalCents: subtotal + breakdown.tax + breakdown.fees - breakdown.discount + finalTipCents,
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
                    uiModel.isLoadingReceipt = false
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
                // Use full-guest index (matches SplitPayload.g / SplitsSummaryView slot lookup)
                func displayName(_ g: SplitGuest, at allIndex: Int) -> String {
                    let t = g.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { return t }
                    if g.isMe {
                        let me = myDisplayNameFromDefaults().trimmingCharacters(in: .whitespacesAndNewlines)
                        return me.isEmpty ? "Me" : me
                    }
                    return "Guest \(allIndex + 1)"
                }

                return draft.items.map { it in
                    let responsible = it.assignedGuestIds.compactMap { gid -> ReceiptDisplay.Responsible? in
                        guard let idx = draft.guests.firstIndex(where: { $0.id == gid }) else { return nil }
                        return ReceiptDisplay.Responsible(
                            slotIndex: idx,
                            displayName: displayName(draft.guests[idx], at: idx)
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
            if myName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isCheckingBackendUser {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task {
                        do {
                            if let name = try await TabService.shared.fetchUserDisplayName(
                                userId: KeychainHelper.getOrCreateUserId()
                            ) {
                                myName = name
                            }
                        } catch {
                            print("[RootContainerView] backend user check failed: \(error)")
                        }
                        isCheckingBackendUser = false
                    }
            } else if myName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                IntroView(
                    onRequestExpand: onExpand,
                    onContinue: { name in
                        myName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            try? await TabService.shared.createOrUpdateUser(
                                userId: KeychainHelper.getOrCreateUserId(),
                                displayName: myName
                            )
                        }
                    }
                )
            } else {
                mainContent
            }
        }
    }

    // MARK: - Main content (extracted to avoid type-check timeout)

    private var mainContent: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            screenContent
        }
        .fullScreenCover(isPresented: $showCamera) {
            CustomCameraView(
                capturedImage: $capturedImage,
                onCancel: {
                    pendingTranscriptTask?.cancel()
                    pendingTranscriptTask = nil
                    showCamera = false
                },
                onReviewImage: { img in
                    pendingTranscriptTask?.cancel()
                    pendingTranscriptTask = Task {
                        let cropped = await withCheckedContinuation { cont in
                            ReceiptCrop.run(img) { cont.resume(returning: $0) }
                        }
                        return try await TranscriptGenerator.generate(from: cropped)
                    }
                }
            )
            .ignoresSafeArea()
            .onChange(of: capturedImage) { _, img in
                guard let img else { return }
                showCamera = false
                ReceiptCrop.run(img) { cropped in
                    uiModel.scanImageOriginal = img
                    uiModel.scanImageCropped = cropped
                    uiModel.isLoadingReceipt = true
                    confirmationCameFromManual = false
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        uiModel.currentScreen = .confirmation
                    }
                    analyzeCapturedTwoPhase(image: cropped)
                }
            }
        }
        .sheet(
            isPresented: $showPhotoLibrary,
            onDismiss: {
                guard let img = photoLibraryImage else { return }
                ReceiptCrop.run(img) { cropped in
                    pendingTranscriptTask?.cancel()
                    pendingTranscriptTask = Task { try await TranscriptGenerator.generate(from: cropped) }
                    uiModel.scanImageOriginal = img
                    uiModel.scanImageCropped = cropped
                    uiModel.isLoadingReceipt = true
                    confirmationCameFromManual = false
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        uiModel.currentScreen = .confirmation
                    }
                    analyzeCapturedTwoPhase(image: cropped)
                }
            }
        ) { PhotoLibraryPicker(image: $photoLibraryImage).ignoresSafeArea() }
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
                uiModel.currentScreen = .messageViewer
            }
        }
        // MARK: - Session persistence: save on state changes
        .onChange(of: uiModel.currentScreen) { _, screen in
            saveSession(screen: screen)
        }
        .onChange(of: uiModel.currentReceipt) { _, _ in
            saveSession(screen: uiModel.currentScreen)
        }
        .onChange(of: uiModel.currentSplitDraft) { _, _ in
            saveSession(screen: uiModel.currentScreen)
        }
        // Restore when conversationKey is first assigned (app reopened into same chat)
        .onChange(of: uiModel.conversationKey) { _, key in
            guard let key else { return }
            restoreSession(conversationKey: key)
        }
        .onChange(of: uiModel.openedMessagePayload) { _, newValue in
            if newValue != nil {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = .messageViewer
                }
            }
            if let tid = newValue?.tid, !tid.isEmpty {
                if let cached = uiModel.userTabs.first(where: { $0.id == tid }) {
                    uiModel.receiptTab = cached
                } else {
                    Task {
                        uiModel.receiptTab = try? await TabService.shared.fetchTab(id: tid)
                    }
                }
            } else {
                uiModel.receiptTab = nil
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { debugOCRResult != nil },
            set: { if !$0 { debugOCRResult = nil; debugOriginalImage = nil } }
        )) {
            DebugOCRView(
                result: debugOCRResult!,
                originalImage: debugOriginalImage,
                onDismiss: {
                    debugOCRResult = nil
                    debugOriginalImage = nil
                }
            )
        }
    }

    // MARK: - Screen routing (each case is a separate computed var for type-checker performance)

    @ViewBuilder
    private var screenContent: some View {
        switch uiModel.currentScreen {
        case .tabview:              tabviewContent.transition(.opacity)
        case .fill:                 fillContent.transition(.opacity)
        case .tipview:              tipContent.transition(.opacity)
        case .confirmation:         confirmationContent.transition(.opacity)
        case .receipt:              receiptContent
        case .messageViewer:        messageViewerContent
        case .newTab:               newTabContent.transition(.opacity)
        case .tabInviteConfirmation: tabInviteContent.transition(.opacity)
        case .joinTab:              joinTabContent.transition(.opacity)
        case .account:              accountContent.transition(.opacity)
        case .paymentMethods:       paymentMethodsContent.transition(.opacity)
        }
    }

    @ViewBuilder
    private var tabviewContent: some View {
        LootTabView(
            tabName: Binding(get: { receiptName }, set: { receiptName = $0 }),
            onUpload: { startPhotoLibraryFlow() },
            onScan: { startScanFlow() },
            onFill: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = .fill
                }
            },
            activeTab: uiModel.activeTab,
            userTabs: uiModel.userTabs,
            conversationMemberIds: uiModel.conversationMemberIds,
            isExpanded: uiModel.isExpanded,
            onStartTab: {
                pendingTabName = ""
                pendingTabColor = TabColorOptions.defaultHex
                onExpand()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = .newTab
                }
            },
            onSelectTab: { tab in
                uiModel.activeTab = tab
                if let convKey = uiModel.conversationKey {
                    TabService.shared.cacheTab(tab, for: convKey)
                    Task {
                        do {
                            try await TabService.shared.associateConversation(
                                tabId: tab.id ?? "",
                                conversationKey: convKey
                            )
                        } catch {
                            print("[RootContainer] associateConversation failed: \(error)")
                        }
                    }
                }
            },
            onTabNameTapped: { onExpand() },
            onClearTab: {
                uiModel.activeTab = nil
                if let convKey = uiModel.conversationKey {
                    TabService.shared.cacheTab(nil, for: convKey)
                    Task { try? await TabService.shared.removeConversationMapping(conversationKey: convKey) }
                }
            },
            onInviteMembers: {
                if let tab = uiModel.activeTab {
                    pendingTabName = tab.name
                    pendingTabColor = tab.colorHex ?? TabColorOptions.defaultHex
                    pendingTabId = tab.id ?? ""
                    tabInviteCameFromTabView = true
                    onCollapse()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        uiModel.currentScreen = .tabInviteConfirmation
                    }
                }
            },
            onAccountTapped: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = .account
                }
            },
            onTabUpdated: { updatedTab in
                uiModel.activeTab = updatedTab
                if let convKey = uiModel.conversationKey {
                    TabService.shared.cacheTab(updatedTab, for: convKey)
                }
            },
            onTabLeft: {
                let leavingId = uiModel.activeTab?.id
                uiModel.userTabs.removeAll { $0.id == leavingId }
                uiModel.activeTab = nil
                if let convKey = uiModel.conversationKey {
                    TabService.shared.cacheTab(nil, for: convKey)
                }
            },
            onTabDeleted: {
                let deletedId = uiModel.activeTab?.id
                uiModel.userTabs.removeAll { $0.id == deletedId }
                uiModel.activeTab = nil
                if let convKey = uiModel.conversationKey {
                    TabService.shared.cacheTab(nil, for: convKey)
                    Task { try? await TabService.shared.removeConversationMapping(conversationKey: convKey) }
                }
            },
            onSendSettlementCard: uiModel.sendSettlementCard,
            onSendRequestCard: uiModel.sendRequestCard,
            openInSafari: uiModel.openInSafari,
            onRequestCollapse: onCollapse
        )
    }

    @ViewBuilder
    private var fillContent: some View {
        ManualInputView(
            viewModel: uiModel,
            receiptName: $receiptName,
            amountString: $amountString,
            tipAmount: $tipAmount,
            onBack: {
                receiptName = ""
                amountString = "0"
                tipAmount = ""
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = .tabview
                }
            },
            onNext: {
                uiModel.currentReceipt = makePreviewReceipt()
                confirmationCameFromManual = true
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = .confirmation
                }
            },
            onAddTip: {
                confirmationCameFromManual = true
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = .tipview
                }
            },
            onRequestExpand: onExpand,
            onRequestCollapse: onCollapse,
            titleNamespace: titleNamespace
        )
    }

    @ViewBuilder
    private var tipContent: some View {
        TipView(
            subtotalString: amountString,
            taxCents: uiModel.currentReceipt?.taxCents ?? 0,
            feesCents: uiModel.currentReceipt?.feesCents ?? 0,
            discountCents: uiModel.currentReceipt?.discountCents ?? 0,
            existingTipCents: uiModel.currentReceipt?.tipCents ?? 0,
            onBack: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = confirmationCameFromManual ? .fill : .confirmation
                }
            },
            onNext: { tip, _ in
                tipAmount = tip
                if let receipt = uiModel.currentReceipt {
                    let tipCentsValue = stringToCents(tip)
                    uiModel.currentReceipt = ReceiptDisplay(
                        id: receipt.id,
                        title: receipt.title,
                        createdAt: receipt.createdAt,
                        subtotalCents: receipt.subtotalCents,
                        feesCents: receipt.feesCents,
                        taxCents: receipt.taxCents,
                        tipCents: tipCentsValue,
                        discountCents: receipt.discountCents,
                        totalCents: receipt.subtotalCents + receipt.taxCents + receipt.feesCents - receipt.discountCents + tipCentsValue,
                        items: receipt.items
                    )
                } else {
                    uiModel.currentReceipt = makePreviewReceipt()
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = .confirmation
                }
            }
        )
    }

    @ViewBuilder
    private var confirmationContent: some View {
        ConfirmationView(
            uiModel: uiModel,
            receiptName: receiptName,
            amount: totalAmount,
            participantCount: participantCount,
            splitMode: splitDraft?.mode,
            splitDraft: splitDraft,
            tipAmount: tipAmount,
            cameFromManual: confirmationCameFromManual,
            onBack: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = .fill
                }
            },
            onSend: {
                if let draft = uiModel.currentSplitDraft {
                    applySplitDraftToCurrentReceipt(draft)
                }
                onSendBill(receiptName, totalAmount)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        if !hasPaymentMethodsConfigured() {
                            paymentMethodsIsPostSend = true
                            uiModel.currentScreen = .paymentMethods
                        } else {
                            uiModel.currentScreen = .tabview
                        }
                    }
                }
            },
            onPreviewReceipt: {
                returnScreen = .confirmation
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = .receipt
                }
            },
            onDeleteToLanding: {
                uiModel.resetForNewReceipt()
                pendingTranscriptTask?.cancel()
                pendingTranscriptTask = nil
                receiptName = ""
                amountString = "0"
                tipAmount = ""
                splitDraft = nil
                capturedImage = nil
                photoLibraryImage = nil
                analyzeError = nil
                uiModel.currentScreen = .tabview
            },
            onGoToSplit: { showSplitViewSheet = true },
            onAddTip: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = .tipview
                }
            },
            onTipChanged: { tip, _ in
                tipAmount = tip
                if let receipt = uiModel.currentReceipt {
                    let tipCentsValue = stringToCents(tip)
                    uiModel.currentReceipt = ReceiptDisplay(
                        id: receipt.id,
                        title: receipt.title,
                        createdAt: receipt.createdAt,
                        subtotalCents: receipt.subtotalCents,
                        feesCents: receipt.feesCents,
                        taxCents: receipt.taxCents,
                        tipCents: tipCentsValue,
                        discountCents: receipt.discountCents,
                        totalCents: receipt.subtotalCents + receipt.taxCents + receipt.feesCents - receipt.discountCents + tipCentsValue,
                        items: receipt.items
                    )
                }
                if var draft = uiModel.currentSplitDraft {
                    let oldTip = draft.tipCents
                    let newTip = stringToCents(tip)
                    draft.tipCents = newTip
                    draft.totalCents = draft.totalCents - oldTip + newTip
                    uiModel.currentSplitDraft = draft
                }
            },
            onSelectMode: { newMode in
                if var draft = uiModel.currentSplitDraft {
                    draft.mode = newMode
                    uiModel.currentSplitDraft = draft
                    splitDraft = draft
                } else if var draft = splitDraft {
                    draft.mode = newMode
                    splitDraft = draft
                    uiModel.currentSplitDraft = draft
                } else {
                    let meName = myDisplayNameFromDefaults().trimmingCharacters(in: .whitespacesAndNewlines)
                    var seededGuests: [SplitGuest] = [SplitGuest(name: meName, isIncluded: true, isMe: true, uid: KeychainHelper.getOrCreateUserId())]
                    if participantCount > 1 {
                        for _ in 1..<participantCount {
                            seededGuests.append(SplitGuest(name: "", isIncluded: true, isMe: false))
                        }
                    }
                    let newDraft = SplitDraft(
                        guests: seededGuests,
                        payerGuestId: seededGuests.first?.id ?? UUID(),
                        mode: newMode,
                        totalCents: stringToCents(totalAmount),
                        perGuestCents: [],
                        items: [],
                        feesCents: uiModel.currentReceipt?.feesCents ?? 0,
                        taxCents: uiModel.currentReceipt?.taxCents ?? 0,
                        tipCents: uiModel.currentReceipt?.tipCents ?? stringToCents(tipAmount),
                        discountCents: uiModel.currentReceipt?.discountCents ?? 0
                    )
                    splitDraft = newDraft
                    uiModel.currentSplitDraft = newDraft
                }
            },
            onGuestsChanged: { newGuests, newPayerId in
                if var draft = splitDraft {
                    draft.guests = newGuests
                    draft.payerGuestId = newPayerId
                    splitDraft = draft
                    uiModel.currentSplitDraft = draft
                } else {
                    let newDraft = SplitDraft(
                        guests: newGuests,
                        payerGuestId: newPayerId,
                        mode: .equally,
                        totalCents: stringToCents(totalAmount),
                        perGuestCents: [],
                        items: [],
                        feesCents: uiModel.currentReceipt?.feesCents ?? 0,
                        taxCents: uiModel.currentReceipt?.taxCents ?? 0,
                        tipCents: uiModel.currentReceipt?.tipCents ?? stringToCents(tipAmount),
                        discountCents: uiModel.currentReceipt?.discountCents ?? 0
                    )
                    splitDraft = newDraft
                    uiModel.currentSplitDraft = newDraft
                }
            },
            onRequestCollapse: onCollapse,
            onRequestExpand: onExpand
        )
    }

    @ViewBuilder
    private var receiptContent: some View {
        if let receipt = uiModel.currentReceipt {
            ReceiptView(uiModel: uiModel, receipt: receipt) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = returnScreen
                }
            }
            .ignoresSafeArea(edges: .bottom)
        } else {
            ProgressView("Loading…")
        }
    }

    @ViewBuilder
    private var messageViewerContent: some View {
        if let payload = uiModel.openedMessagePayload {
            MessageReceiptViewer(
                uiModel: uiModel,
                payload: payload,
                onClose: {
                    uiModel.openedMessagePayload = nil
                    uiModel.messageLoadingState = .idle
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        uiModel.currentScreen = .tabview
                    }
                }
            )
            .ignoresSafeArea(edges: .bottom)
        } else if uiModel.messageLoadingState.isLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading receipt...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if let error = uiModel.messageLoadingState.error {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Couldn't load receipt")
                    .font(.headline)
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Go Back") {
                    uiModel.messageLoadingState = .idle
                    uiModel.openedMessagePayload = nil
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        uiModel.currentScreen = .tabview
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding()
        } else {
            ProgressView("Loading…")
        }
    }

    @ViewBuilder
    private var newTabContent: some View {
        NewTabView(
            uiModel: uiModel,
            isExpanded: uiModel.isExpanded,
            onRequestExpand: onExpand,
            onBack: {
                pendingTabId = ""
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = .tabview
                }
            },
            onNext: { name, colorHex in
                let tabId = pendingTabId.isEmpty ? TabService.shared.generateTabId() : pendingTabId
                let tab = TabService.shared.createLocalTab(name: name, colorHex: colorHex, tabId: tabId)
                pendingTabName = tab.name
                pendingTabColor = tab.colorHex ?? colorHex
                pendingTabId = tabId
                tabInviteCameFromTabView = false
                uiModel.activeTab = tab
                if let convKey = uiModel.conversationKey {
                    TabService.shared.cacheTab(tab, for: convKey)
                }
                onCollapse()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = .tabInviteConfirmation
                }
                Task {
                    do {
                        try await TabService.shared.uploadTab(tab, tabId: tabId, conversationKey: uiModel.conversationKey ?? "")
                        print("[RootContainer] Tab uploaded: \(tabId)")
                    } catch {
                        print("[RootContainer] Tab upload failed: \(error)")
                    }
                }
            },
            tabName: $pendingTabName,
            selectedColor: $pendingTabColor
        )
    }

    @ViewBuilder
    private var tabInviteContent: some View {
        TabInviteConfirmationView(
            uiModel: uiModel,
            tabName: pendingTabName,
            tabColor: pendingTabColor,
            tabId: pendingTabId,
            creatorName: myName.isEmpty ? "Me" : myName,
            onBack: {
                if tabInviteCameFromTabView {
                    onExpand()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        uiModel.currentScreen = .tabview
                    }
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        uiModel.currentScreen = .newTab
                    }
                }
            },
            onSend: { tabName, tabColorHex, tabId in
                onSendTabInvite?(tabName, tabColorHex, tabId)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        uiModel.currentScreen = .tabview
                    }
                }
            },
            onRequestCollapse: onCollapse
        )
    }

    @ViewBuilder
    private var joinTabContent: some View {
        JoinTabView(
            uiModel: uiModel,
            isExpanded: uiModel.isExpanded,
            onRequestExpand: onExpand,
            onBack: {
                uiModel.pendingTabInviteId = nil
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = .tabview
                }
            },
            onJoined: { tab in
                uiModel.activeTab = tab
                uiModel.pendingTabInviteId = nil
                if let convKey = uiModel.conversationKey {
                    TabService.shared.cacheTab(tab, for: convKey)
                    Task {
                        try? await TabService.shared.associateConversation(
                            tabId: tab.id ?? "",
                            conversationKey: convKey
                        )
                    }
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = .tabview
                }
            },
            onAccountTapped: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = .account
                }
            }
        )
    }

    @ViewBuilder
    private var accountContent: some View {
        AccountView(
            onBack: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = .tabview
                }
            },
            onRequestExpand: onExpand,
            onPaymentMethods: {
                paymentMethodsIsPostSend = false
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = .paymentMethods
                }
            }
        )
    }

    @ViewBuilder
    private var paymentMethodsContent: some View {
        PaymentMethodView(
            onBack: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = paymentMethodsIsPostSend ? .tabview : .account
                }
            },
            onRequestExpand: onExpand,
            onSaved: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = paymentMethodsIsPostSend ? .tabview : .account
                }
            },
            isPostSendPrompt: paymentMethodsIsPostSend
        )
    }
}
