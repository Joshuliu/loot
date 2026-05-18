//
//  RootContainerView.swift
//  Loot
//
//  Created by Joshua Liu on 1/1/26.
//

import SwiftUI

struct RootContainerView: View {
    @AppStorage(DefaultsKeys.myDisplayName) private var myName: String = ""
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var receiptDraftVM: ReceiptDraftViewModel
    @ObservedObject var messageReceiptVM: MessageReceiptViewModel
    /// Phase 3 step 14: tab + conversation state. Owns activeTab, receiptTab,
    /// userTabs, conversationKey, pendingTabInvite*, conversationMemberIds,
    /// localParticipantId, tabReceiptsRefreshNonce.
    @ObservedObject var tabContextVM: TabContextViewModel
    /// Phase 3 step 13b: UIKit-bridge access. Replaces the five optional
    /// closures that used to hang off `uiModel`.
    let bus: MessageBus

    @State private var showSplitViewSheet: Bool = false
    @State private var confirmationCameFromManual: Bool = false
    @State private var paymentMethodsIsPostSend: Bool = false
    /// True from the moment `onSend` starts until the post-send 2s cleanup
    /// fires. Suppresses `saveSession` so the `.onChange(of:
    /// receiptDraftVM.currentReceipt)` triggered by
    /// `applySplitDraftToCurrentReceipt`'s mutation can't re-write a stale
    /// session right after the synchronous `SessionPersistence.clear`.
    @State private var isSending: Bool = false

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
    private let DEBUG_COPY_TRANSCRIPT = false
    // DEBUG: Set to true to show OCR chunk images in Edit Receipt view
    private let DEBUG_SHOW_CHUNKS = true
    // DEBUG: Set to true to print the raw phase 2 LLM response in the console
    private let DEBUG_PRINT_PHASE2_RESPONSE = true
    @State private var debugOCRResult: OCRResult? = nil
    @State private var debugOriginalImage: UIImage? = nil

    // Camera (full-screen) + unified scan sheet (library → review) state.
    @State private var showCamera: Bool = false
    @State private var capturedImage: UIImage? = nil
    @State private var showScanSheet: Bool = false
    @State private var scanSheetStep: ScanSheetStep = .library
    // Camera and the scan sheet are separate presentations on the same view;
    // hand off through onDismiss flags so we never present one while the
    // other is still dismissing.
    @State private var pendingScanSheet: Bool = false
    @State private var pendingShowCamera: Bool = false

    private enum ScanSheetStep { case library, review }

    @State private var analyzeError: String?
    @State private var pendingTranscriptTask: Task<String, Error>? = nil
    // Phase 1 (merchant + total) is prefetched off the transcript while the
    // user is on the review screen, so the confirmation step can consume it
    // instead of cold-starting the LLM.
    @State private var pendingPhase1Task: Task<Phase1Result, Error>? = nil

    // Backend user restore state
    @State private var isCheckingBackendUser: Bool = true
    init(coordinator: AppCoordinator, receiptDraftVM: ReceiptDraftViewModel, messageReceiptVM: MessageReceiptViewModel, tabContextVM: TabContextViewModel, bus: MessageBus) {
        self.coordinator = coordinator
        self.receiptDraftVM = receiptDraftVM
        self.messageReceiptVM = messageReceiptVM
        self.tabContextVM = tabContextVM
        self.bus = bus
        self.participantCount = 1
        self.onScan = {}
        self.onExpand = {}
        self.onCollapse = {}
        self.onSendBill = { _, _ in }
        self.onSendTabInvite = nil
        self.onSendTabInviteUpdate = nil
    }

    init(
        coordinator: AppCoordinator,
        receiptDraftVM: ReceiptDraftViewModel,
        messageReceiptVM: MessageReceiptViewModel,
        tabContextVM: TabContextViewModel,
        bus: MessageBus,
        participantCount: Int,
        onScan: @escaping () -> Void,
        onExpand: @escaping () -> Void,
        onCollapse: @escaping () -> Void,
        onSendBill: @escaping (String, String) -> Void,
        onSendTabInvite: ((String, String, String) -> Void)? = nil,
        onSendTabInviteUpdate: ((String) -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.receiptDraftVM = receiptDraftVM
        self.messageReceiptVM = messageReceiptVM
        self.tabContextVM = tabContextVM
        self.bus = bus
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
        guard !isSending else { return }
        guard let key = tabContextVM.conversationKey else { return }
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
        guard coordinator.currentScreen == .tabview else { return }
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
            coordinator.currentScreen = screen
        }
        print("[Session] Restored to .\(session.screenName) from \(Int(-session.savedAt.timeIntervalSinceNow))s ago")
    }

    private func startScanFlow() {
        tabContextVM.resetForNewReceipt()
        receiptDraftVM.reset()
        messageReceiptVM.reset()
        onScan()
        analyzeError = nil
        capturedImage = nil
        showCamera = true
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
    /// Image chosen (camera or library) → start transcript + Phase 1 in the
    /// background and seed the split draft, so the review step of the scan
    /// sheet can show payer/mode while the LLM works. Presentation (showing
    /// the sheet at `.review`) is handled by the caller.
    private func handleScannedImage(_ img: UIImage) {
        pendingTranscriptTask?.cancel()
        pendingPhase1Task?.cancel()
        let transcriptTask = Task { () throws -> String in
            let cropped = await withCheckedContinuation { cont in
                ReceiptCrop.run(img) { cont.resume(returning: $0) }
            }
            return try await TranscriptGenerator.generate(from: cropped)
        }
        pendingTranscriptTask = transcriptTask
        pendingPhase1Task = Task {
            let transcript = try await transcriptTask.value
            return try await LLMClient.shared.analyzeReceiptPhase1(transcript: transcript)
        }
        ReceiptCrop.run(img) { cropped in
            receiptDraftVM.scanImageOriginal = img
            receiptDraftVM.scanImageCropped = cropped
            confirmationCameFromManual = false
            seedScanReviewDraftIfNeeded()
        }
    }

    /// Seed a `SplitDraft` (guests + payer + default mode) so the payer/mode
    /// pickers in the scan sheet's review step have something to mutate.
    /// Mirrors the seeding
    /// `SplitEditorViewModel.initializeSplitState` uses, so ConfirmationView
    /// later adopts these choices verbatim instead of reseeding.
    private func seedScanReviewDraftIfNeeded() {
        guard receiptDraftVM.currentSplitDraft == nil else { return }
        let myUid = KeychainHelper.getOrCreateUserId()
        let seeded: [Person]
        let payer: PersonID
        if let tab = tabContextVM.activeTab {
            seeded = tab.members.filter(\.isActive).map { member in
                let uid = (member.userId?.isEmpty == false) ? member.userId! : member.memberId
                return Person.identified(userId: uid, displayName: member.displayName)
            }
            payer = seeded.first(where: { $0.isMe(localUserId: myUid) })?.id
                ?? seeded.first?.id
                ?? PersonID(rawValue: myUid)
        } else {
            let meName = myDisplayNameFromDefaults().trimmingCharacters(in: .whitespacesAndNewlines)
            var s: [Person] = [Person.identified(userId: myUid, displayName: meName)]
            if participantCount > 1 {
                for _ in 1..<participantCount { s.append(Person.newGuest(displayName: "")) }
            }
            seeded = s
            payer = seeded.first?.id ?? PersonID(rawValue: myUid)
        }
        receiptDraftVM.currentSplitDraft = SplitDraft(
            guests: seeded,
            includedIDs: Set(seeded.map(\.id)),
            payerID: payer,
            mode: .equally,
            totalCents: stringToCents(totalAmount),
            perGuestCents: [],
            items: [],
            feesCents: receiptDraftVM.currentReceipt?.feesCents ?? 0,
            discountCents: receiptDraftVM.currentReceipt?.discountCents ?? 0,
            taxCents: receiptDraftVM.currentReceipt?.taxCents ?? 0,
            tipCents: receiptDraftVM.currentReceipt?.tipCents ?? stringToCents(tipAmount)
        )
    }

    /// "Use Photo" in the scan sheet → go to confirmation and run the
    /// two-phase analyze, which consumes the transcript + Phase 1 prefetched.
    private func continueFromScanReview() {
        guard let cropped = receiptDraftVM.scanImageCropped else { return }
        receiptDraftVM.isLoadingReceipt = true
        confirmationCameFromManual = false
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            coordinator.currentScreen = .confirmation
        }
        analyzeCapturedTwoPhase(image: cropped)
    }

    private func analyzeCapturedTwoPhase(image: UIImage) {
        analyzeError = nil
        let capturedTranscriptTask = pendingTranscriptTask
        let capturedPhase1Task = pendingPhase1Task

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

                // PHASE 1: Quick merchant + total extraction. Reuse the task
                // prefetched during review if available; otherwise run now.
                print("[Scan] Phase 1: Extracting merchant and total...")
                let phase1: Phase1Result
                if let p1Task = capturedPhase1Task {
                    phase1 = try await p1Task.value
                } else {
                    phase1 = try await LLMClient.shared.analyzeReceiptPhase1(transcript: transcript)
                }
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

                    // Phase 2 is LAZY: item extraction (the expensive
                    // second LLM round-trip) only runs if the user picks
                    // "By Items". Even Split / Custom never need line
                    // items, so itemsLoadingState stays .idle until
                    // requestPhase2() fires the stored starter below.
                    receiptDraftVM.itemsLoadingState = .idle
                    receiptDraftVM.startPhase2 = {
                        startPhase2Extraction(
                            transcript: transcript,
                            knownTotal: total,
                            phase1: phase1
                        )
                    }
                    // If the user already chose By Items (e.g. on the
                    // scan-review screen), fire Phase 2 NOW — the earliest
                    // correct point, since it needs Phase 1's total. This
                    // is a no-op for Even Split / Custom (no intent).
                    receiptDraftVM.startPhase2IfWanted()
                    // Phase 1 complete — clear loading state (navigation already happened)
                    receiptDraftVM.isLoadingReceipt = false
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

    /// Phase 2 (itemized line extraction). Deferred out of the scan flow
    /// and invoked lazily the first time the user picks "By Items" (via
    /// `ReceiptDraftViewModel.requestPhase2`). Reuses the transcript and
    /// Phase 1 result captured at scan time.
    @MainActor
    private func startPhase2Extraction(
        transcript: String,
        knownTotal: Int,
        phase1: Phase1Result
    ) {
        receiptDraftVM.itemsLoadingState = .loading
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
    }

    // Phase 3 step 12a: reconcileSplitDraftWithLiveReceipt and
    // applySplitDraftToCurrentReceipt now live on ReceiptDraftViewModel.
    // Callers below invoke `receiptDraftVM.reconcileWithLiveReceipt(...)`
    // and `receiptDraftVM.applySplitDraftToCurrentReceipt(_:tipAmount:)` directly.


    private func optimisticMessagePayload(for receipt: TabReceipt) -> LootMessagePayload? {
        guard let tab = tabContextVM.activeTab else { return nil }

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
        .fullScreenCover(isPresented: $showCamera, onDismiss: {
            if pendingScanSheet {
                pendingScanSheet = false
                showScanSheet = true
            }
        }) {
            CustomCameraView(
                capturedImage: $capturedImage,
                onCancel: {
                    pendingTranscriptTask?.cancel()
                    pendingTranscriptTask = nil
                    pendingPhase1Task?.cancel()
                    pendingPhase1Task = nil
                    pendingScanSheet = false
                    showCamera = false
                },
                onLibrary: {
                    scanSheetStep = .library
                    pendingScanSheet = true
                    showCamera = false
                }
            )
            .ignoresSafeArea()
            .onChange(of: capturedImage) { _, img in
                guard let img else { return }
                handleScannedImage(img)
                scanSheetStep = .review
                pendingScanSheet = true
                showCamera = false
            }
        }
        .fullScreenCover(isPresented: $showScanSheet, onDismiss: {
            if pendingShowCamera {
                pendingShowCamera = false
                showCamera = true
            }
        }) {
            scanFlowSheet
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
            if messageReceiptVM.openedMessagePayload != nil {
                coordinator.currentScreen = .messageViewer
            }
        }
        // MARK: - Session persistence: save on state changes t
        .onChange(of: coordinator.currentScreen) { _, screen in
            saveSession(screen: screen)
        }
        .onChange(of: receiptDraftVM.currentReceipt) { _, receipt in
            if messageReceiptVM.openedMessagePayload == nil, let receipt {
                receiptName = receipt.title
            }
            saveSession(screen: coordinator.currentScreen)
        }
        .onChange(of: receiptDraftVM.currentSplitDraft) { _, _ in
            saveSession(screen: coordinator.currentScreen)
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
        .onChange(of: tabContextVM.conversationKey) { _, key in
            guard let key else { return }
            restoreSession(conversationKey: key)
        }
        .onChange(of: messageReceiptVM.openedMessagePayload) { _, newValue in
            if newValue != nil {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    coordinator.currentScreen = .messageViewer
                }
            }
            if let tid = newValue?.tid, !tid.isEmpty {
                if let cached = tabContextVM.userTabs.first(where: { $0.id == tid }) {
                    tabContextVM.receiptTab = cached
                } else {
                    Task {
                        tabContextVM.receiptTab = try? await TabService.shared.fetchTab(id: tid)
                    }
                }
            } else {
                tabContextVM.receiptTab = nil
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
        switch coordinator.currentScreen {
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
            coordinator: coordinator,
            messageReceiptVM: messageReceiptVM,
            tabContextVM: tabContextVM,
            onScan: { startScanFlow() },
            onFill: {
                tabContextVM.resetForNewReceipt()
                receiptDraftVM.reset()
                messageReceiptVM.reset()
                receiptName = ""
                amountString = "0"
                tipAmount = ""
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    coordinator.currentScreen = .fill
                }
            },
            activeTab: tabContextVM.activeTab,
            userTabs: tabContextVM.userTabs,
            conversationMemberIds: tabContextVM.conversationMemberIds,
            isExpanded: coordinator.isExpanded,
            onStartTab: {
                pendingTabName = ""
                pendingTabColor = TabColorOptions.defaultHex
                onExpand()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    coordinator.currentScreen = .newTab
                }
            },
            onSelectTab: { tab in
                tabContextVM.activeTab = tab
                if let convKey = tabContextVM.conversationKey {
                    tabContextVM.cacheTab(tab, for: convKey)
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
                tabContextVM.activeTab = nil
                if let convKey = tabContextVM.conversationKey {
                    tabContextVM.cacheTab(nil, for: convKey)
                    Task { try? await TabService.shared.removeConversationMapping(conversationKey: convKey) }
                }
            },
            onInviteMembers: {
                if let tab = tabContextVM.activeTab {
                    pendingTabName = tab.name
                    pendingTabColor = tab.colorHex ?? TabColorOptions.defaultHex
                    pendingTabId = tab.id ?? ""
                    tabInviteCameFromTabView = true
                    onCollapse()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        coordinator.currentScreen = .tabInviteConfirmation
                    }
                }
            },
            onAccountTapped: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    coordinator.currentScreen = .account
                }
            },
            onTabUpdated: { updatedTab in
                tabContextVM.activeTab = updatedTab
                if let convKey = tabContextVM.conversationKey {
                    tabContextVM.cacheTab(updatedTab, for: convKey)
                }
            },
            onTabLeft: {
                let leavingId = tabContextVM.activeTab?.id
                tabContextVM.userTabs.removeAll { $0.id == leavingId }
                tabContextVM.activeTab = nil
                if let convKey = tabContextVM.conversationKey {
                    tabContextVM.cacheTab(nil, for: convKey)
                }
            },
            onTabDeleted: {
                let deletedId = tabContextVM.activeTab?.id
                tabContextVM.userTabs.removeAll { $0.id == deletedId }
                tabContextVM.activeTab = nil
                if let convKey = tabContextVM.conversationKey {
                    tabContextVM.cacheTab(nil, for: convKey)
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
                    coordinator.currentScreen = .messageViewer
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
            onSendSettlementCard: { [bus] fromName, toName, amountCents, methodName, tabColorHex in
                bus.sendSettlementCard(fromName: fromName, toName: toName,
                                       amountCents: amountCents, methodName: methodName,
                                       tabColorHex: tabColorHex)
            },
            onApplePayHandoff: { [bus] fromName, toName, amountCents, tabColorHex in
                bus.sendApplePayHandoff(fromName: fromName, toName: toName,
                                        amountCents: amountCents, tabColorHex: tabColorHex)
            },
            onSendRequestCard: { [bus] creditorName, debtorName, amountCents, tabColorHex, metadata in
                bus.sendRequestCard(creditorName: creditorName, debtorName: debtorName,
                                    amountCents: amountCents, tabColorHex: tabColorHex,
                                    metadata: metadata)
            },
            openInSafari: { [bus] url in bus.openInSafari(url) },
            pendingPayRequest: messageReceiptVM.pendingPayRequest,
            onConsumePendingPayRequest: {
                messageReceiptVM.pendingPayRequest = nil
            },
            paymentsRefreshNonce: tabContextVM.tabReceiptsRefreshNonce,
            onRequestCollapse: onCollapse
        )
    }

    @ViewBuilder
    private var fillContent: some View {
        ManualInputView(
            viewModel: coordinator,
            receiptName: $receiptName,
            amountString: $amountString,
            tipAmount: $tipAmount,
            onBack: {
                receiptName = ""
                amountString = "0"
                tipAmount = ""
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    coordinator.currentScreen = .tabview
                }
            },
            onNext: {
                receiptDraftVM.currentReceipt = makePreviewReceipt()
                confirmationCameFromManual = true
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    coordinator.currentScreen = .confirmation
                }
            },
            onAddTip: {
                confirmationCameFromManual = true
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    coordinator.currentScreen = .tipview
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
            isExpanded: coordinator.isExpanded,
            onBack: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    coordinator.currentScreen = confirmationCameFromManual ? .fill : .confirmation
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
                    coordinator.currentScreen = .confirmation
                }
            }
        )
    }

    /// The single unified scan sheet: library picker → review, no extra
    /// presentation changes between the two steps.
    @ViewBuilder
    private var scanFlowSheet: some View {
        switch scanSheetStep {
        case .library:
            PhotoLibraryPicker(
                onPicked: { img in
                    handleScannedImage(img)
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        scanSheetStep = .review
                    }
                },
                onCancel: { showScanSheet = false }
            )
            .ignoresSafeArea()

        case .review:
            ScanReviewView(
                receiptDraftVM: receiptDraftVM,
                onRetake: {
                    pendingShowCamera = true
                    showScanSheet = false
                },
                onContinue: {
                    showScanSheet = false
                    continueFromScanReview()
                },
                onSelectMode: { newMode in
                    if var d = receiptDraftVM.currentSplitDraft {
                        d.mode = newMode
                        receiptDraftVM.currentSplitDraft = d
                    }
                    // Capture itemization intent here, on the review
                    // screen, BEFORE Phase 1 has run. requestPhase2() just
                    // records the intent now; it fires the instant Phase 1
                    // finishes (see startPhase2IfWanted in
                    // analyzeCapturedTwoPhase). Switching back to
                    // Evenly/Custom drops the intent so Phase 2 is skipped.
                    if newMode == .byItems {
                        receiptDraftVM.requestPhase2()
                    } else {
                        receiptDraftVM.cancelItemizationIntent()
                    }
                },
                onSelectPayer: { pid in
                    if var d = receiptDraftVM.currentSplitDraft {
                        d.payerID = pid
                        receiptDraftVM.currentSplitDraft = d
                    }
                }
            )
        }
    }

    private var confirmationContent: some View {
        let activeSplitDraft = receiptDraftVM.currentSplitDraft
        return ConfirmationView(
            coordinator: coordinator,
            receiptDraftVM: receiptDraftVM,
            tabContextVM: tabContextVM,
            receiptName: receiptName,
            amount: totalAmount,
            participantCount: participantCount,
            splitMode: activeSplitDraft?.mode,
            splitDraft: activeSplitDraft,
            tipAmount: tipAmount,
            cameFromManual: confirmationCameFromManual,
            onBack: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    coordinator.currentScreen = .fill
                }
            },
            onSend: {
                isSending = true
                if let draft = receiptDraftVM.currentSplitDraft {
                    receiptDraftVM.applySplitDraftToCurrentReceipt(draft, tipAmount: tipAmount)
                }
                onSendBill(receiptName, totalAmount)
                receiptName = ""
                amountString = "0"
                tipAmount = ""
                if let key = tabContextVM.conversationKey {
                    SessionPersistence.clear(conversationKey: key)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    // Always clear isSending — even if we bail out below.
                    // Otherwise saveSession stays suppressed for the rest of
                    // this session.
                    isSending = false
                    // Bail if the user navigated away from .confirmation in
                    // the meantime — most commonly because they tapped the
                    // bubble they just sent and the drawer is now showing
                    // .messageViewer. Without this guard, the post-send
                    // resets stomp on the user's new context, flipping the
                    // screen back to .tabview and clearing the opened bubble.
                    guard coordinator.currentScreen == .confirmation else { return }

                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        if !hasPaymentMethodsConfigured() {
                            paymentMethodsIsPostSend = true
                            coordinator.currentScreen = .paymentMethods
                        } else {
                            // Set view
                            coordinator.currentScreen = .tabview
                        }
                    }
                    // Reset states
                    tabContextVM.resetForNewReceipt()
                    receiptDraftVM.reset()
                    messageReceiptVM.reset()
                    pendingTranscriptTask?.cancel()
                    pendingTranscriptTask = nil
                    pendingPhase1Task?.cancel()
                    pendingPhase1Task = nil
                    receiptName = ""
                    amountString = "0"
                    tipAmount = ""
                    capturedImage = nil
                    analyzeError = nil
                }
            },
            onDeleteToLanding: {
                tabContextVM.resetForNewReceipt()
                receiptDraftVM.reset()
                messageReceiptVM.reset()
                pendingTranscriptTask?.cancel()
                pendingTranscriptTask = nil
                pendingPhase1Task?.cancel()
                pendingPhase1Task = nil
                receiptName = ""
                amountString = "0"
                tipAmount = ""
                capturedImage = nil
                analyzeError = nil
                coordinator.currentScreen = .tabview
            },
            onGoToSplit: { showSplitViewSheet = true },
            onAddTip: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    coordinator.currentScreen = .tipview
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
                coordinator: coordinator,
                userTabs: tabContextVM.userTabs,
                receiptDraftVM: receiptDraftVM,
                messageReceiptVM: messageReceiptVM,
                tabContextVM: tabContextVM,
                bus: bus,
                payload: payload,
                onClose: {
                    messageReceiptVM.openedMessagePayload = nil
                    messageReceiptVM.openedMessageDocId = nil
                    messageReceiptVM.messageLoadingState = .idle
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        coordinator.currentScreen = .tabview
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
                        coordinator.currentScreen = .tabview
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
            coordinator: coordinator,
            isExpanded: coordinator.isExpanded,
            onRequestExpand: onExpand,
            onBack: {
                pendingTabId = ""
                tabContextVM.activeTab = nil
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    coordinator.currentScreen = .tabview
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
                tabContextVM.activeTab = tab
                if let convKey = tabContextVM.conversationKey {
                    tabContextVM.cacheTab(tab, for: convKey)
                }
                onCollapse()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    coordinator.currentScreen = .tabInviteConfirmation
                }
            },
            tabName: $pendingTabName,
            selectedColor: $pendingTabColor
        )
    }

    @ViewBuilder
    private var tabInviteContent: some View {
        TabInviteConfirmationView(
            coordinator: coordinator,
            tabName: pendingTabName,
            tabColor: pendingTabColor,
            tabId: pendingTabId,
            creatorName: myName.isEmpty ? "Me" : myName,
            joinedCount: max(1, tabContextVM.activeTab?.members.filter(\.isActive).count ?? 1),
            targetCount: max(1, participantCount),
            onBack: {
                if tabInviteCameFromTabView {
                    onExpand()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        coordinator.currentScreen = .tabview
                    }
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        coordinator.currentScreen = .newTab
                    }
                }
            },
            onSend: { tabName, tabColorHex, tabId in
                // Upload is intentionally deferred until invite send. If this tab does not
                // exist in the local list yet, insert it locally and then upload in background.
                let hasLocalTab = tabContextVM.userTabs.contains(where: { $0.id == tabId })
                if !hasLocalTab {
                    let localTab: LootTab
                    if let active = tabContextVM.activeTab, active.id == tabId {
                        localTab = active
                    } else {
                        localTab = TabService.shared.createLocalTab(name: tabName, colorHex: tabColorHex, tabId: tabId)
                    }

                    tabContextVM.userTabs.append(localTab)

                    Task {
                        do {
                            try await TabService.shared.uploadTab(localTab, tabId: tabId, conversationKey: tabContextVM.conversationKey ?? "")
                            print("[RootContainer] Tab uploaded on invite send: \(tabId)")
                        } catch {
                            print("[RootContainer] Tab upload failed on invite send: \(error)")
                        }
                    }
                }
                onSendTabInvite?(tabName, tabColorHex, tabId)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        coordinator.currentScreen = .tabview
                    }
                }
            },
            onRequestCollapse: onCollapse
        )
    }

    @ViewBuilder
    private var joinTabContent: some View {
        JoinTabView(
            coordinator: coordinator,
            tabContextVM: tabContextVM,
            isExpanded: coordinator.isExpanded,
            onRequestExpand: onExpand,
            onBack: {
                tabContextVM.pendingTabInviteId = nil
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    coordinator.currentScreen = .tabview
                }
            },
            onJoined: { tab in
                tabContextVM.activeTab = tab
                tabContextVM.pendingTabInviteId = nil
                if let convKey = tabContextVM.conversationKey {
                    tabContextVM.cacheTab(tab, for: convKey)
                    Task {
                        try? await TabService.shared.associateConversation(
                            tabId: tab.id ?? "",
                            conversationKey: convKey
                        )
                    }
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    coordinator.currentScreen = .tabview
                }
            },
            onSendTabInviteUpdate: { tabId in
                onSendTabInviteUpdate?(tabId)
            },
            onAccountTapped: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    coordinator.currentScreen = .account
                }
            }
        )
    }

    @ViewBuilder
    private var accountContent: some View {
        AccountView(
            onBack: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    coordinator.currentScreen = .tabview
                }
            },
            onRequestExpand: onExpand,
            onPaymentMethods: {
                paymentMethodsIsPostSend = false
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    coordinator.currentScreen = .paymentMethods
                }
            }
        )
    }

    @ViewBuilder
    private var paymentMethodsContent: some View {
        PaymentMethodView(
            onBack: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    coordinator.currentScreen = paymentMethodsIsPostSend ? .tabview : .account
                }
            },
            onRequestExpand: onExpand,
            onSaved: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    coordinator.currentScreen = paymentMethodsIsPostSend ? .tabview : .account
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
