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
    @ObservedObject var receiptDraftVM: ReceiptDraftViewModel
    @ObservedObject var messageReceiptVM: MessageReceiptViewModel

    @State private var showSplitViewSheet: Bool = false
    @State private var confirmationCameFromManual: Bool = false
    @State private var paymentMethodsIsPostSend: Bool = false

    @State private var receiptName: String = ""
    @State private var amountString: String = "0"
    @State private var tipAmount: String = ""
    @Namespace private var titleNamespace
    
    // Computed total: subtotal + tax + fees (signed) + tip
    private var totalAmount: String {
        // If we have a receipt with breakdown, use its total (includes tax, fees, discounts, tip)
        if let receipt = receiptDraftVM.currentReceipt {
            return Money(cents: receipt.totalCents).inputString
        }

        // Otherwise, calculate from manual entry (subtotal + tip only, no tax/fees in manual flow)
        guard !tipAmount.isEmpty, tipAmount != "$0", tipAmount != "$0.00" else {
            return amountString
        }
        let subtotal = Money(parsing: amountString)
        let tip = Money(parsing: tipAmount)
        return (subtotal + tip).inputString
    }
    
    let participantCount: Int
    let onScan: () -> Void
    let onExpand: () -> Void
    let onCollapse: () -> Void
    let onSendBill: (String, String) -> Void
    let onSendTabInvite: ((String, String, String) -> Void)?  // (tabName, tabColorHex, tabId)
    let onSendTabInviteUpdate: ((String) -> Void)?  // tabId

    // Tab creation state
    @State private var pendingTabName: String = ""
    @State private var pendingTabColor: String = TabColorOptions.defaultHex
    @State private var pendingTabId: String = ""
    @State private var tabInviteCameFromTabView: Bool = false

    // DEBUG: Set to true to only run VisionKit OCR and print JSON (no AI)
    private let DEBUG_OCR_ONLY = false
    // DEBUG: Set to true to copy OCR transcript to clipboard after each scan
    private let DEBUG_COPY_TRANSCRIPT = true
    // DEBUG: Set to true to show OCR chunk images in Edit Receipt view
    private let DEBUG_SHOW_CHUNKS = true
    // DEBUG: Set to true to print the raw phase 2 LLM response in the console
    private let DEBUG_PRINT_PHASE2_RESPONSE = true
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
    init(uiModel: LootUIModel, receiptDraftVM: ReceiptDraftViewModel, messageReceiptVM: MessageReceiptViewModel) {
        self.uiModel = uiModel
        self.receiptDraftVM = receiptDraftVM
        self.messageReceiptVM = messageReceiptVM
        self.participantCount = 1
        self.onScan = {}
        self.onExpand = {}
        self.onCollapse = {}
        self.onSendBill = { _, _ in }
        self.onSendTabInvite = nil
        self.onSendTabInviteUpdate = nil
    }

    init(
        uiModel: LootUIModel,
        receiptDraftVM: ReceiptDraftViewModel,
        messageReceiptVM: MessageReceiptViewModel,
        participantCount: Int,
        onScan: @escaping () -> Void,
        onExpand: @escaping () -> Void,
        onCollapse: @escaping () -> Void,
        onSendBill: @escaping (String, String) -> Void,
        onSendTabInvite: ((String, String, String) -> Void)? = nil,
        onSendTabInviteUpdate: ((String) -> Void)? = nil
    ) {
        self.uiModel = uiModel
        self.receiptDraftVM = receiptDraftVM
        self.messageReceiptVM = messageReceiptVM
        self.participantCount = participantCount
        self.onScan = onScan
        self.onExpand = onExpand
        self.onCollapse = onCollapse
        self.onSendBill = onSendBill
        self.onSendTabInvite = onSendTabInvite
        self.onSendTabInviteUpdate = onSendTabInviteUpdate
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
            totalCents: totalCents,
            items: []
        )
    }

    // MARK: - Session persistence helpers

    private func saveSession(screen: AppScreen) {
        guard let key = uiModel.conversationKey else { return }
        guard screen.isPersistableScreen else {
            if screen == .tabview { SessionPersistence.clear(conversationKey: key) }
            return
        }
        SessionPersistence.save(
            screen: screen,
            receipt: receiptDraftVM.currentReceipt,
            parsedReceipt: receiptDraftVM.parsedReceipt,
            splitDraft: receiptDraftVM.currentSplitDraft,
            image: receiptDraftVM.scanImageCropped,
            conversationKey: key
        )
    }

    private func restoreSession(conversationKey: String) {
        // Only restore if we haven't already navigated away from the landing screen
        guard uiModel.currentScreen == .tabview else { return }
        guard let session = SessionPersistence.load(conversationKey: conversationKey) else { return }

        let screen = AppScreen.from(persistenceKey: session.screenName)
        guard screen != .tabview else { return }

        receiptDraftVM.currentReceipt = session.currentReceipt
        receiptDraftVM.parsedReceipt = session.parsedReceipt
        receiptDraftVM.currentSplitDraft = session.splitDraft
        if let img = SessionPersistence.loadImage(conversationKey: conversationKey) {
            receiptDraftVM.scanImageCropped = img
        }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            uiModel.currentScreen = screen
        }
        print("[Session] Restored to .\(session.screenName) from \(Int(-session.savedAt.timeIntervalSinceNow))s ago")
    }

    private func startScanFlow() {
        uiModel.resetForNewReceipt()
        receiptDraftVM.reset()
        messageReceiptVM.reset()
        onScan()
        analyzeError = nil
        capturedImage = nil
        showCamera = true
    }

    private func startPhotoLibraryFlow() {
        uiModel.resetForNewReceipt()
        receiptDraftVM.reset()
        messageReceiptVM.reset()
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
                    await MainActor.run { receiptDraftVM.debugChunkImages = chunks }
                    print("[Scan] \(chunks.count) chunk image(s) saved for debug")
                }

                // PHASE 1: Quick merchant + total extraction
                print("[Scan] Phase 1: Extracting merchant and total...")
                let phase1 = try await LLMClient.shared.analyzeReceiptPhase1(transcript: transcript)
                print("[Scan] Phase 1 complete: merchant=\(phase1.merchant ?? "nil"), total=\(phase1.total_cents ?? 0)")

                let total = max(0, phase1.total_cents ?? 0)

                await MainActor.run {
                    // Update form fields with phase 1 data
                    amountString = Money(cents: total).inputString

                    if let merchant = phase1.merchant, !merchant.isEmpty {
                        receiptName = merchant
                    }

                    // Create partial receipt (empty items - will be populated by phase 2)
                    receiptDraftVM.currentReceipt = ReceiptDisplay(
                        id: UUID().uuidString,
                        title: phase1.merchant ?? (receiptName.isEmpty ? "New Receipt" : receiptName),
                        createdAt: Date(),
                        subtotalCents: total,  // Use total as subtotal initially
                        feesCents: 0,
                        discountCents: 0,
                        taxCents: 0,
                        tipCents: 0,
                        totalCents: total,
                        items: []  // Empty - loading
                    )

                    receiptDraftVM.itemsLoadingState = .loading
                    // Phase 1 complete — clear loading state (navigation already happened)
                    receiptDraftVM.isLoadingReceipt = false
                }

                // PHASE 2: Background item extraction (reuses transcript)
                let knownTotal = total
                receiptDraftVM.phase2Task = Task { @MainActor in
                    do {
                        print("[Scan] Phase 2: Extracting items and breakdown...")
                        let phase2 = try await LLMClient.shared.analyzeReceiptPhase2(
                            transcript: transcript,
                            knownTotalCents: knownTotal
                        )
                        let resolvedLineItems = LLMClient.shared.lastPhase2LineItems
                        if DEBUG_PRINT_PHASE2_RESPONSE {
                            print("[Scan] Phase 2 raw response:\n\(LLMClient.shared.lastRawPhase2Response ?? "<nil>")")
                        }
                        print("[Scan] Phase 2 complete: \(phase2.items.count) items")

                        let breakdown = (
                            fees: max(0, phase2.fees_cents ?? 0),
                            discount: max(0, phase2.discount_cents ?? 0),
                            tax: max(0, phase2.tax_cents ?? 0),
                            tip: max(0, phase2.tip_cents ?? 0)
                        )
                        let subtotal = max(0, phase2.subtotal_cents ?? (knownTotal - breakdown.tax - breakdown.fees + breakdown.discount - breakdown.tip))
                        let phase2ProjectedTotalCents = subtotal + breakdown.tax + breakdown.fees - breakdown.discount + breakdown.tip

                        // Build full ParsedReceipt for compatibility, using the projected phase-2 total
                        // (not the coarse phase-1 total) so downstream UI can reflect corrections.
                        let fullParsed = ParsedReceipt(
                            merchant: phase1.merchant,
                            total_cents: phase2ProjectedTotalCents,
                            subtotal_cents: subtotal,
                            tax_cents: phase2.tax_cents,
                            tip_cents: phase2.tip_cents,
                            fees_cents: phase2.fees_cents,
                            discount_cents: phase2.discount_cents,
                            items: phase2.items.map { ParsedReceipt.Item(label: $0.label, qty: $0.qty, cents: $0.cents) },
                            issues: phase2.issues
                        )
                        receiptDraftVM.parsedReceipt = fullParsed

                        // If the user added their own tip during scanning (e.g. tapped "Add Tip"
                        // before phase 2 landed), treat it as ADDITIONAL on top of any tip the
                        // receipt itself had — keeps the total they explicitly approved sticky.
                        let userAddedTip = !tipAmount.isEmpty && tipAmount != "$0" && tipAmount != "$0.00"
                        let existingUserTip = receiptDraftVM.currentReceipt?.tipCents ?? 0

                        let userTipCents: Int
                        if userAddedTip {
                            userTipCents = stringToCents(tipAmount)
                        } else if existingUserTip > 0 {
                            userTipCents = existingUserTip
                        } else {
                            userTipCents = 0
                        }

                        let finalTipCents = userTipCents + breakdown.tip

                        // Re-sync the form-field tipAmount so the inline tip panel + bill card
                        // reflect the merged tip on the next render.
                        if finalTipCents > 0 {
                            tipAmount = Money(cents: finalTipCents).inputString
                        }

                        // Tip lives in tipCents alone; lineItems never carries a tip row,
                        // otherwise TotalsBox renders both the lineItem and the breakdown row.
                        var displayLineItems = resolvedLineItems
                        displayLineItems.removeAll {
                            let normalized = $0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                            return normalized.contains("tip") || normalized.contains("gratuity")
                        }

                        // Update subtotal field used by manual/edit flows.
                        amountString = Money(cents: subtotal).inputString

                        // Final total after phase 2 + local post-processing adjustments.
                        let finalizedTotalCents = subtotal + breakdown.tax + breakdown.fees - breakdown.discount + finalTipCents

                        // Rebuild currentReceipt with items + breakdown, preserving user's tip
                        receiptDraftVM.currentReceipt = ReceiptDisplay(
                            id: receiptDraftVM.currentReceipt?.id ?? UUID().uuidString,
                            title: phase1.merchant ?? (receiptName.isEmpty ? "New Receipt" : receiptName),
                            createdAt: Date(),
                            subtotalCents: subtotal,
                            feesCents: breakdown.fees,
                            discountCents: breakdown.discount,
                            taxCents: breakdown.tax,
                            tipCents: finalTipCents,
                            totalCents: finalizedTotalCents,
                            items: fullParsed.toDisplayItems(),
                            lineItems: displayLineItems
                        )

                        // If the user opened split mode mid-scan, the draft's tip is stale
                        // relative to the just-merged finalTipCents. Patch it so per-guest
                        // amounts re-render against the new total.
                        if var draft = receiptDraftVM.currentSplitDraft, draft.tipCents != finalTipCents {
                            let oldTip = draft.tipCents
                            draft.tipCents = finalTipCents
                            draft.totalCents = draft.totalCents - oldTip + finalTipCents
                            receiptDraftVM.currentSplitDraft = draft
                        }

                        receiptDraftVM.itemsLoadingState = .loaded(phase2)
                    } catch {
                        print("[Scan] Phase 2 failed: \(error)")
                        receiptDraftVM.itemsLoadingState = .failed(error)
                        // Receipt is still usable with merchant/total from phase 1
                    }
                }

            } catch {
                print("[Scan] analyzeReceipt failed: \(error)")
                await MainActor.run {
                    receiptDraftVM.isLoadingReceipt = false
                    analyzeError = "Scan failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // Phase 3 step 12a: reconcileSplitDraftWithLiveReceipt and
    // applySplitDraftToCurrentReceipt now live on ReceiptDraftViewModel.
    // Callers below invoke `receiptDraftVM.reconcileWithLiveReceipt(...)`
    // and `receiptDraftVM.applySplitDraftToCurrentReceipt(_:tipAmount:)` directly.


    private func optimisticMessagePayload(for receipt: TabReceipt) -> LootMessagePayload? {
        guard let tab = uiModel.activeTab else { return nil }

        var orderedMemberIds: [String] = []
        func appendMemberId(_ memberId: String) {
            guard !memberId.isEmpty, !orderedMemberIds.contains(memberId) else { return }
            orderedMemberIds.append(memberId)
        }

        appendMemberId(receipt.payerMemberId)
        receipt.splits.forEach { appendMemberId($0.memberId) }
        receipt.items?.forEach { item in
            item.assignedMemberIds.forEach { appendMemberId($0) }
        }
        guard !orderedMemberIds.isEmpty else { return nil }

        let memberById = Dictionary(
            tab.members.map { ($0.memberId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let guests = orderedMemberIds.map { memberId in
            let member = memberById[memberId]
            return SplitPayload.Guest(
                n: member?.displayName ?? "Guest",
                inc: true,
                uid: member?.userId
            )
        }

        let payerIndex = orderedMemberIds.firstIndex(of: receipt.payerMemberId) ?? 0
        let owedByMemberId = Dictionary(
            receipt.splits.map { ($0.memberId, $0.owedCents) },
            uniquingKeysWith: { first, _ in first }
        )
        let owedAmounts = orderedMemberIds.map { owedByMemberId[$0] ?? 0 }

        let splitMode: SplitPayload.Mode = {
            switch receipt.splitMode {
            case .equally: return .equally
            case .custom: return .custom
            case .byItems: return .byItems
            }
        }()

        let items = (receipt.items ?? []).map { item in
            ReceiptItemPayload(
                id: UUID().uuidString,
                l: item.label,
                p: item.priceCents,
                rs: item.assignedMemberIds.compactMap { orderedMemberIds.firstIndex(of: $0) }
            )
        }

        let split = SplitPayload(
            m: splitMode,
            g: guests,
            pi: payerIndex,
            o: owedAmounts,
            f: receipt.feesCents == 0 ? nil : receipt.feesCents,
            tx: receipt.taxCents == 0 ? nil : receipt.taxCents,
            tip: receipt.tipCents == 0 ? nil : receipt.tipCents,
            d: (receipt.discountCents ?? 0) == 0 ? nil : receipt.discountCents,
            tot: receipt.totalCents
        )

        let payloadReceipt = ReceiptPayload(
            id: receipt.messagePayloadId ?? receipt.id ?? UUID().uuidString,
            t: receipt.title,
            c: Date().timeIntervalSince1970,
            sub: receipt.subtotalCents,
            f: receipt.feesCents,
            d: receipt.discountCents ?? 0,
            tx: receipt.taxCents,
            tip: receipt.tipCents,
            tot: receipt.totalCents,
            i: items
        )

        let tabPayload: TabPayload? = {
            guard let tabId = tab.id else { return nil }
            return TabPayload(id: tabId, n: tab.name, c: tab.colorHex)
        }()

        return LootMessagePayload(
            r: payloadReceipt,
            s: split,
            tid: tab.id,
            trid: receipt.id,
            tab: tabPayload,
            su: nil
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
        ZStack(alignment: .topLeading) {
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
                    receiptDraftVM.scanImageOriginal = img
                    receiptDraftVM.scanImageCropped = cropped
                    receiptDraftVM.isLoadingReceipt = true
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
                    receiptDraftVM.scanImageOriginal = img
                    receiptDraftVM.scanImageCropped = cropped
                    receiptDraftVM.isLoadingReceipt = true
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
            if messageReceiptVM.openedMessagePayload != nil {
                uiModel.currentScreen = .messageViewer
            }
        }
        // MARK: - Session persistence: save on state changes t
        .onChange(of: uiModel.currentScreen) { _, screen in
            saveSession(screen: screen)
        }
        .onChange(of: receiptDraftVM.currentReceipt) { _, receipt in
            if messageReceiptVM.openedMessagePayload == nil, let receipt {
                receiptName = receipt.title
            }
            saveSession(screen: uiModel.currentScreen)
        }
        .onChange(of: receiptDraftVM.currentSplitDraft) { _, _ in
            saveSession(screen: uiModel.currentScreen)
        }
        .onChange(of: receiptDraftVM.isLoadingReceipt) { wasLoading, isLoading in
            // Event-driven sync point #1: phase 1 completion (loading true -> false).
            guard wasLoading, !isLoading else { return }
            receiptDraftVM.reconcileWithLiveReceipt(trigger: "phase 1 completion")
        }
        .onChange(of: receiptDraftVM.itemsLoadingState.isLoading) { wasLoading, isLoading in
            // Event-driven sync point #2: phase 2 completion (loading true -> false),
            // regardless of success/failure, so any live receipt totals are reflected in draft.
            guard wasLoading, !isLoading else { return }
            receiptDraftVM.reconcileWithLiveReceipt(trigger: "phase 2 completion")
        }
        // Restore when conversationKey is first assigned (app reopened into same chat)
        .onChange(of: uiModel.conversationKey) { _, key in
            guard let key else { return }
            restoreSession(conversationKey: key)
        }
        .onChange(of: messageReceiptVM.openedMessagePayload) { _, newValue in
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
        case .messageViewer:        messageViewerContent
        case .newTab:               newTabContent.transition(.opacity)
        case .tabInviteConfirmation: tabInviteContent.transition(.opacity)
        case .joinTab:              joinTabContent.transition(.opacity)
        case .account:              accountContent.transition(.opacity)
        case .paymentMethods:       paymentMethodsContent.transition(.opacity)
        case .updateRequired:       updateRequiredContent.transition(.opacity)
        }
    }

    @ViewBuilder
    private var tabviewContent: some View {
        LootTabView(
            tabName: Binding(get: { receiptName }, set: { receiptName = $0 }),
            uiModel: uiModel,
            messageReceiptVM: messageReceiptVM,
            onUpload: { startPhotoLibraryFlow() },
            onScan: { startScanFlow() },
            onFill: {
                uiModel.resetForNewReceipt()
                receiptDraftVM.reset()
                messageReceiptVM.reset()
                receiptName = ""
                amountString = "0"
                tipAmount = ""
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
            onPreviewSplits: { receipt in
                guard let docId = receipt.messagePayloadId, !docId.isEmpty else { return }
                if let optimisticPayload = optimisticMessagePayload(for: receipt) {
                    messageReceiptVM.openedMessagePayload = optimisticPayload
                    receiptDraftVM.currentReceipt = optimisticPayload.toReceiptDisplay()
                    messageReceiptVM.messageLoadingState = .loaded(optimisticPayload)
                } else {
                    messageReceiptVM.openedMessagePayload = nil
                    messageReceiptVM.messageLoadingState = .loading
                }
                messageReceiptVM.openedMessageDocId = docId
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = .messageViewer
                }
                Task { @MainActor in
                    do {
                        let (payload, captureImage) = try await SharedReceiptService.shared.fetch(id: docId)
                        messageReceiptVM.openedMessagePayload = payload
                        receiptDraftVM.currentReceipt = payload.toReceiptDisplay()
                        if let captureImage {
                            receiptDraftVM.scanImageCropped = captureImage
                        }
                        messageReceiptVM.messageLoadingState = .loaded(payload)
                    } catch {
                        print("[LootTabView] Failed to load receipt payload: \(error)")
                        if messageReceiptVM.openedMessagePayload == nil {
                            messageReceiptVM.messageLoadingState = .failed(error)
                        }
                    }
                }
            },
            onSendSettlementCard: uiModel.sendSettlementCard,
            onApplePayHandoff: uiModel.sendApplePayHandoff,
            onSendRequestCard: uiModel.sendRequestCard,
            openInSafari: uiModel.openInSafari,
            pendingPayRequest: messageReceiptVM.pendingPayRequest,
            onConsumePendingPayRequest: {
                messageReceiptVM.pendingPayRequest = nil
            },
            paymentsRefreshNonce: uiModel.tabReceiptsRefreshNonce,
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
                receiptDraftVM.currentReceipt = makePreviewReceipt()
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
        let preTip = stringToCents(amountString)
            + (receiptDraftVM.currentReceipt?.taxCents ?? 0)
            + (receiptDraftVM.currentReceipt?.feesCents ?? 0)
            - (receiptDraftVM.currentReceipt?.discountCents ?? 0)
        TipPanelView(
            preTipTotalCents: preTip,
            existingTipCents: receiptDraftVM.currentReceipt?.tipCents ?? 0,
            isExpanded: uiModel.isExpanded,
            onBack: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = confirmationCameFromManual ? .fill : .confirmation
                }
            },
            onApply: { tip, _ in
                tipAmount = tip
                if let receipt = receiptDraftVM.currentReceipt {
                    let tipCentsValue = stringToCents(tip)
                    receiptDraftVM.currentReceipt = ReceiptDisplay(
                        id: receipt.id,
                        title: receipt.title,
                        createdAt: receipt.createdAt,
                        subtotalCents: receipt.subtotalCents,
                        feesCents: receipt.feesCents,
                        discountCents: receipt.discountCents,
                        taxCents: receipt.taxCents,
                        tipCents: tipCentsValue,
                        totalCents: receipt.subtotalCents + receipt.taxCents + receipt.feesCents - receipt.discountCents + tipCentsValue,
                        items: receipt.items,
                        lineItems: receipt.lineItems
                    )
                } else {
                    receiptDraftVM.currentReceipt = makePreviewReceipt()
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = .confirmation
                }
            }
        )
    }

    @ViewBuilder
    private var confirmationContent: some View {
        let activeSplitDraft = receiptDraftVM.currentSplitDraft
        ConfirmationView(
            uiModel: uiModel,
            receiptDraftVM: receiptDraftVM,
            receiptName: receiptName,
            amount: totalAmount,
            participantCount: participantCount,
            splitMode: activeSplitDraft?.mode,
            splitDraft: activeSplitDraft,
            tipAmount: tipAmount,
            cameFromManual: confirmationCameFromManual,
            onBack: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = .fill
                }
            },
            onSend: {
                if let draft = receiptDraftVM.currentSplitDraft {
                    receiptDraftVM.applySplitDraftToCurrentReceipt(draft, tipAmount: tipAmount)
                }
                onSendBill(receiptName, totalAmount)
                receiptName = ""
                amountString = "0"
                tipAmount = ""
                if let key = uiModel.conversationKey {
                    SessionPersistence.clear(conversationKey: key)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    // Bail if the user navigated away from .confirmation in
                    // the meantime — most commonly because they tapped the
                    // bubble they just sent and the drawer is now showing
                    // .messageViewer. Without this guard, the post-send
                    // resets stomp on the user's new context, flipping the
                    // screen back to .tabview and clearing the opened bubble.
                    guard uiModel.currentScreen == .confirmation else { return }

                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        if !hasPaymentMethodsConfigured() {
                            paymentMethodsIsPostSend = true
                            uiModel.currentScreen = .paymentMethods
                        } else {
                            // Set view
                            uiModel.currentScreen = .tabview
                        }
                    }
                    // Reset states
                    uiModel.resetForNewReceipt()
                    receiptDraftVM.reset()
                    messageReceiptVM.reset()
                    pendingTranscriptTask?.cancel()
                    pendingTranscriptTask = nil
                    receiptName = ""
                    amountString = "0"
                    tipAmount = ""
                    capturedImage = nil
                    photoLibraryImage = nil
                    analyzeError = nil
                }
            },
            onDeleteToLanding: {
                uiModel.resetForNewReceipt()
                receiptDraftVM.reset()
                messageReceiptVM.reset()
                pendingTranscriptTask?.cancel()
                pendingTranscriptTask = nil
                receiptName = ""
                amountString = "0"
                tipAmount = ""
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
                if let receipt = receiptDraftVM.currentReceipt {
                    let tipCentsValue = stringToCents(tip)
                    receiptDraftVM.currentReceipt = ReceiptDisplay(
                        id: receipt.id,
                        title: receipt.title,
                        createdAt: receipt.createdAt,
                        subtotalCents: receipt.subtotalCents,
                        feesCents: receipt.feesCents,
                        discountCents: receipt.discountCents,
                        taxCents: receipt.taxCents,
                        tipCents: tipCentsValue,
                        totalCents: receipt.subtotalCents + receipt.taxCents + receipt.feesCents - receipt.discountCents + tipCentsValue,
                        items: receipt.items,
                        lineItems: receipt.lineItems
                    )
                }
                if var draft = receiptDraftVM.currentSplitDraft {
                    let oldTip = draft.tipCents
                    let newTip = stringToCents(tip)
                    draft.tipCents = newTip
                    draft.totalCents = draft.totalCents - oldTip + newTip
                    receiptDraftVM.currentSplitDraft = draft
                }
            },
            onSelectMode: { newMode in
                if var draft = receiptDraftVM.currentSplitDraft {
                    draft.mode = newMode
                    receiptDraftVM.currentSplitDraft = draft
                } else {
                    let myUid = KeychainHelper.getOrCreateUserId()
                    let meName = myDisplayNameFromDefaults().trimmingCharacters(in: .whitespacesAndNewlines)
                    var seededGuests: [Person] = [Person.identified(userId: myUid, displayName: meName)]
                    if participantCount > 1 {
                        for _ in 1..<participantCount {
                            seededGuests.append(Person.newGuest(displayName: ""))
                        }
                    }
                    let newDraft = SplitDraft(
                        guests: seededGuests,
                        includedIDs: Set(seededGuests.map(\.id)),
                        payerID: seededGuests.first?.id ?? PersonID(rawValue: myUid),
                        mode: newMode,
                        totalCents: stringToCents(totalAmount),
                        perGuestCents: [],
                        items: [],
                        feesCents: receiptDraftVM.currentReceipt?.feesCents ?? 0,
                        discountCents: receiptDraftVM.currentReceipt?.discountCents ?? 0,
                        taxCents: receiptDraftVM.currentReceipt?.taxCents ?? 0,
                        tipCents: receiptDraftVM.currentReceipt?.tipCents ?? stringToCents(tipAmount)
                    )
                    receiptDraftVM.currentSplitDraft = newDraft
                }
            },
            onGuestsChanged: { newGuests, newIncludedIDs, newPayerId in
                if var draft = receiptDraftVM.currentSplitDraft {
                    draft.guests = newGuests
                    draft.includedIDs = newIncludedIDs
                    draft.payerID = newPayerId
                    receiptDraftVM.currentSplitDraft = draft
                } else {
                    let newDraft = SplitDraft(
                        guests: newGuests,
                        includedIDs: newIncludedIDs,
                        payerID: newPayerId,
                        mode: .equally,
                        totalCents: stringToCents(totalAmount),
                        perGuestCents: [],
                        items: [],
                        feesCents: receiptDraftVM.currentReceipt?.feesCents ?? 0,
                        discountCents: receiptDraftVM.currentReceipt?.discountCents ?? 0,
                        taxCents: receiptDraftVM.currentReceipt?.taxCents ?? 0,
                        tipCents: receiptDraftVM.currentReceipt?.tipCents ?? stringToCents(tipAmount)
                    )
                    receiptDraftVM.currentSplitDraft = newDraft
                }
            },
            onRequestCollapse: onCollapse,
            onRequestExpand: onExpand
        )
    }

    @ViewBuilder
    private var messageViewerContent: some View {
        if let payload = messageReceiptVM.openedMessagePayload {
            MessageReceiptViewer(
                uiModel: uiModel,
                userTabs: uiModel.userTabs,
                receiptDraftVM: receiptDraftVM,
                messageReceiptVM: messageReceiptVM,
                payload: payload,
                onClose: {
                    messageReceiptVM.openedMessagePayload = nil
                    messageReceiptVM.openedMessageDocId = nil
                    messageReceiptVM.messageLoadingState = .idle
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        uiModel.currentScreen = .tabview
                    }
                },
                onRequestCollapse: onCollapse
            )
            .ignoresSafeArea(edges: .bottom)
        } else if messageReceiptVM.messageLoadingState.isLoading {
            VStack(spacing: 12) {
                Spacer()
                HStack {
                    Spacer()
                    ProgressView()
                    Text("Loading receipt...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer()
            }
        } else if let error = messageReceiptVM.messageLoadingState.error {
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
                    messageReceiptVM.messageLoadingState = .idle
                    messageReceiptVM.openedMessagePayload = nil
                    messageReceiptVM.openedMessageDocId = nil
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
                uiModel.activeTab = nil
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    uiModel.currentScreen = .tabview
                }
            },
            onNext: { name, colorHex in
                // Build a local-only tab first so invite confirmation can render immediately
                // without waiting on network writes.
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
            joinedCount: max(1, uiModel.activeTab?.members.filter(\.isActive).count ?? 1),
            targetCount: max(1, participantCount),
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
                // Upload is intentionally deferred until invite send. If this tab does not
                // exist in the local list yet, insert it locally and then upload in background.
                let hasLocalTab = uiModel.userTabs.contains(where: { $0.id == tabId })
                if !hasLocalTab {
                    let localTab: LootTab
                    if let active = uiModel.activeTab, active.id == tabId {
                        localTab = active
                    } else {
                        localTab = TabService.shared.createLocalTab(name: tabName, colorHex: tabColorHex, tabId: tabId)
                    }

                    uiModel.userTabs.append(localTab)

                    Task {
                        do {
                            try await TabService.shared.uploadTab(localTab, tabId: tabId, conversationKey: uiModel.conversationKey ?? "")
                            print("[RootContainer] Tab uploaded on invite send: \(tabId)")
                        } catch {
                            print("[RootContainer] Tab upload failed on invite send: \(error)")
                        }
                    }
                }
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
            onSendTabInviteUpdate: { tabId in
                onSendTabInviteUpdate?(tabId)
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

    @ViewBuilder
    private var updateRequiredContent: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.blue)
            Text("Update Required")
                .font(.title2.bold())
            Text("This message was sent from a newer version of Loot. Please update to view it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            UpdateLootButton()
            Spacer()
        }
    }
}

private struct UpdateLootButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Update Loot") {
            if let url = URL(string: "https://apps.apple.com/app/id6757330604") {
                openURL(url)
            }
        }
        .buttonStyle(.borderedProminent)
    }
}
