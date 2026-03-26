//
//  MessagesViewController.swift
//  Loot MessagesExtension
//
//  Created by Joshua Liu on 1/1/26.
//
import Foundation
import UIKit
import Messages
import SwiftUI

final class MessagesViewController: MSMessagesAppViewController {

    private let uiModel = LootUIModel()
    private lazy var hostingController = UIHostingController(rootView: RootContainerView(uiModel: uiModel))
    private var hasSetupRootView = false

    override func viewDidLoad() {
        super.viewDidLoad()
        SharedReceiptService.configureFirebaseIfNeeded()

        // Establish anonymous auth immediately so Firestore's WebSocket stream
        // is authenticated before the first write fires.
        Task { try? await SharedReceiptService.shared.ensureAnonymousAuth() }

        uiModel.openInSafari = { [weak self] url in
            self?.extensionContext?.open(url, completionHandler: nil)
        }

        uiModel.sendSettlementCard = { [weak self] fromName, toName, amountCents, methodName, tabColorHex in
            self?.sendSettlementMessage(fromName: fromName, toName: toName,
                                        amountCents: amountCents, methodName: methodName,
                                        tabColorHex: tabColorHex)
        }

        uiModel.sendRequestCard = { [weak self] creditorName, debtorName, amountCents, tabColorHex in
            self?.sendRequestMessage(creditorName: creditorName, debtorName: debtorName,
                                     amountCents: amountCents, tabColorHex: tabColorHex)
        }

        view.isOpaque = true
        view.backgroundColor = .systemBackground
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.isOpaque = true
        hostingController.view.backgroundColor = .systemBackground
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostingController.didMove(toParent: self)
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        applyMessage(conversation.selectedMessage, conversation: conversation)
        setupRootView(conversation: conversation)
    }

    override func didTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.didTransition(to: presentationStyle)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            uiModel.isExpanded = (presentationStyle == .expanded)
        }

        // Force layout so the hosting controller picks up the new container size
        // (fixes content offset after collapse → re-open)
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
    }
    
    override func didSelect(_ message: MSMessage, conversation: MSConversation) {
        super.didSelect(message, conversation: conversation)
        // Use the message parameter directly, not conversation.selectedMessage
        applyMessage(message, conversation: conversation)
    }
}

// MARK: - Card render + sending (no backend, no storage)

extension MessagesViewController {

    private func applyMessage(_ message: MSMessage?, conversation: MSConversation) {
        // expansion state
        uiModel.isExpanded = (presentationStyle == .expanded)

        guard let msg = message, let url = msg.url else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)

        // New path: Firestore doc ID
        if let docId = comps?.queryItems?.first(where: { $0.name == "id" })?.value,
           !docId.isEmpty {
            // Clear old payload first so MessageReceiptViewer unmounts,
            // then remounts fresh once the new payload arrives.
            uiModel.openedMessagePayload = nil
            uiModel.messageLoadingState = .loading
            uiModel.openedMessageDocId = docId
            uiModel.currentScreen = .messageViewer

            // Extract inline fallback payload embedded at send time.
            // Present on every card sent with the current app version.
            let inlinePayload = LootMessageCodec.payload(from: url)

            Task { @MainActor in
                do {
                    let (payload, captureImage) = try await SharedReceiptService.shared.fetch(id: docId)
                    uiModel.openedMessagePayload = payload
                    uiModel.currentReceipt = payload.toReceiptDisplay()
                    if let captureImage {
                        uiModel.scanImageCropped = captureImage
                    }
                    uiModel.messageLoadingState = .loaded(payload)
                    if let tabData = payload.tab { await applyTabData(tabData) }
                } catch {
                    print("[applyMessage] Firestore fetch failed: \(error)")
                    if let inline = inlinePayload {
                        // Use the baked-in payload so the receipt opens immediately,
                        // even without a network connection.
                        print("[applyMessage] Falling back to inline payload for \(docId)")
                        uiModel.openedMessagePayload = inline
                        uiModel.currentReceipt = inline.toReceiptDisplay()
                        uiModel.messageLoadingState = .loaded(inline)
                        if let tabData = inline.tab { await applyTabData(tabData) }
                        // Heal: upload the inline payload to Firestore so future
                        // recipients (and slot-claim updates) can use the doc.
                        Task {
                            do {
                                try await SharedReceiptService.shared.upload(inline, docId: docId)
                                print("[applyMessage] Healed Firestore doc: \(docId)")
                            } catch {
                                print("[applyMessage] Heal upload failed (will retry next open): \(error)")
                            }
                        }
                    } else {
                        uiModel.messageLoadingState = .failed(error)
                    }
                }
            }
            return
        }

        // Tab invite path: ?tabInvite=<tabId>
        if let tabId = comps?.queryItems?.first(where: { $0.name == "tabInvite" })?.value,
           !tabId.isEmpty {
            // Navigate immediately so the screen change is synchronous —
            // avoids race with didTransition when re-tapping the same invite.
            requestPresentationStyle(.expanded)
            uiModel.pendingTabInviteId = tabId
            uiModel.currentScreen = .joinTab
            return
        }

        // Settlement card path: ?tabId=<tabId>
        if let tabId = comps?.queryItems?.first(where: { $0.name == "tabId" })?.value,
           !tabId.isEmpty {
            // Build minimal tab immediately from inline URL params (no Firestore needed)
            let tabName = comps?.queryItems?.first(where: { $0.name == "tn" })?.value
            let colorHex = comps?.queryItems?.first(where: { $0.name == "tc" })?.value
            if let tabName {
                uiModel.activeTab = LootTab.minimal(id: tabId, name: tabName,
                                                    colorHex: colorHex?.isEmpty == true ? nil : colorHex)
            }
            // Try to upgrade with full tab data in background
            Task { @MainActor in
                if let cached = uiModel.userTabs.first(where: { $0.id == tabId }) {
                    uiModel.activeTab = cached
                } else if let full = try? await TabService.shared.fetchTab(id: tabId) {
                    uiModel.activeTab = full
                }
            }
            return
        }

        // Legacy path: inline payload
        if let payload = LootMessageCodec.payload(from: url) {
            uiModel.openedMessagePayload = payload
            uiModel.currentReceipt = payload.toReceiptDisplay()
            uiModel.currentScreen = .messageViewer
            if let tabData = payload.tab { Task { @MainActor in await self.applyTabData(tabData) } }
        }
    }

    private func applyTabData(_ tabData: TabPayload) async {
        let minimal = LootTab.minimal(id: tabData.id, name: tabData.n, colorHex: tabData.c)
        uiModel.receiptTab = minimal

        // No switch needed if the receipt belongs to the already-active tab
        guard uiModel.activeTab?.id != tabData.id else { return }

        let myId = KeychainHelper.getOrCreateUserId()

        // Check local cache first (avoids a network round-trip)
        if let cached = uiModel.userTabs.first(where: { $0.id == tabData.id }) {
            if cached.memberIds.contains(myId) {
                uiModel.activeTab = cached
                if let ck = uiModel.conversationKey {
                    TabService.shared.cacheTab(cached, for: ck)
                }
            }
            // Non-member: SplitsSummaryView's locked screen handles the UI
            return
        }

        // Not in local tabs — fetch to verify membership
        if let tab = try? await TabService.shared.fetchTab(id: tabData.id) {
            if tab.memberIds.contains(myId) {
                uiModel.activeTab = tab
                if let ck = uiModel.conversationKey {
                    TabService.shared.cacheTab(tab, for: ck)
                }
            }
            // Non-member: SplitsSummaryView's locked screen handles the UI
        }
    }

    private func setupRootView(conversation: MSConversation) {
        let participantCount = conversation.remoteParticipantIdentifiers.count + 1

        // Cache localParticipantIdentifier for convenience
        let localId = conversation.localParticipantIdentifier.uuidString
        UserDefaults.standard.set(localId, forKey: DefaultsKeys.localParticipantId)
        uiModel.localParticipantId = localId

        // Compute conversation key from ALL participant identifiers (local + remote)
        var identifiers = conversation.remoteParticipantIdentifiers.map { $0.uuidString }
        identifiers.append(localId)
        uiModel.conversationKey = TabService.conversationKey(from: identifiers)

        // Try to load active tab for this conversation and sync user doc
        if let convKey = uiModel.conversationKey {
            // Instant: restore from local cache so the tab shows immediately
            if uiModel.currentScreen != .joinTab {
                uiModel.activeTab = TabService.shared.cachedTab(for: convKey)
            }

            Task { @MainActor in
                // Only restore the conversation's tab if we're not in the middle
                // of a join flow — otherwise this would overwrite the tab the user
                // is about to join / just joined.
                if uiModel.currentScreen != .joinTab {
                    let myId = KeychainHelper.getOrCreateUserId()
                    let tab = try? await TabService.shared.getTabForConversation(conversationKey: convKey)
                    // Store conversation member IDs for tab relevance sorting,
                    // regardless of whether the current user is still a member.
                    if let t = tab {
                        uiModel.conversationMemberIds = Set(t.memberIds)
                    }
                    // Only set as active if this user is still an active member
                    // (guards against tabs the user has left).
                    if let t = tab, t.memberIds.contains(myId) {
                        uiModel.activeTab = t
                        TabService.shared.cacheTab(t, for: convKey)
                    } else {
                        uiModel.activeTab = nil
                        TabService.shared.cacheTab(nil, for: convKey)
                    }
                }
                do {
                    uiModel.userTabs = try await TabService.shared.fetchUserTabs()
                } catch {
                    print("[setupRootView] fetchUserTabs failed: \(error)")
                    uiModel.userTabs = []
                }

                // If user closed Loot to retrieve their Zelle QR code, route them back
                // to Payment Methods as soon as the app reopens.
                if UserDefaults.standard.bool(forKey: DefaultsKeys.pendingReturnToPaymentMethods) {
                    UserDefaults.standard.removeObject(forKey: DefaultsKeys.pendingReturnToPaymentMethods)
                    uiModel.currentScreen = .paymentMethods
                }

                // Ensure user doc exists and display name stays in sync
                let displayName = myDisplayNameFromDefaults()
                if !displayName.isEmpty {
                    try? await TabService.shared.createOrUpdateUser(
                        userId: KeychainHelper.getOrCreateUserId(),
                        displayName: displayName
                    )
                }
            }
        }

        // Only create the SwiftUI root view once. Re-creating it on every
        // willBecomeActive causes layout glitches when the extension is simply
        // collapsed (tap text field) and re-opened — the new view tree renders
        // while the container is still animating, producing an offset.
        // State updates above still run every time via uiModel.
        guard !hasSetupRootView else { return }
        hasSetupRootView = true

        hostingController.rootView = RootContainerView(
            uiModel: uiModel,
            participantCount: participantCount,
            onScan:   { print("Scan tapped") },
            onExpand: { [weak self] in self?.requestPresentationStyle(.expanded) },
            onCollapse: { [weak self] in self?.requestPresentationStyle(.compact) },
            onSendBill: { [weak self] receiptName, amount in
                self?.sendBillMessage(
                    receiptName: receiptName,
                    amount: amount,
                    participantCount: participantCount
                )
            },
            onSendTabInvite: { [weak self] tabName, tabColorHex, tabId in
                self?.sendTabInvite(tabName: tabName, tabColorHex: tabColorHex, tabId: tabId)
            }
        )
    }
    
    // MARK: - Shared helpers

    /// Renders any SwiftUI view into a UIImage at the given size.
    private func renderView<T: View>(_ view: T, size: CGSize) -> UIImage {
        let hosting = UIHostingController(rootView: view)
        hosting.view.backgroundColor = .clear
        hosting.safeAreaRegions = []
        hosting.view.frame = CGRect(origin: .zero, size: size)
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true)
        }
    }

    /// Builds the base loot URL, optionally appending tab identity params.
    private func lootURLComponents(tab: LootTab? = nil) -> URLComponents {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "plsloot.me"
        components.path = "/loot"
        if let tab, let tabId = tab.id {
            var items: [URLQueryItem] = [URLQueryItem(name: "tabId", value: tabId)]
            items.append(URLQueryItem(name: "tn", value: tab.name))
            if let hex = tab.colorHex, !hex.isEmpty { items.append(URLQueryItem(name: "tc", value: hex)) }
            components.queryItems = items
        }
        return components
    }

    func sendSettlementMessage(fromName: String, toName: String,
                              amountCents: Int, methodName: String,
                              tabColorHex: String?) {
        guard let conversation = activeConversation else { return }

        let card = SettlementCardView(fromName: fromName, toName: toName,
                                     amountCents: amountCents, methodName: methodName,
                                     tabColorHex: tabColorHex)
        let cardImage = renderView(card, size: CGSize(width: 260, height: 60))

        // receiptTab is set when paying from a receipt viewer; activeTab is set otherwise.
        let components = lootURLComponents(tab: uiModel.receiptTab ?? uiModel.activeTab)

        let layout = MSMessageTemplateLayout()
        layout.image = cardImage

        let message = MSMessage(session: MSSession())
        message.layout = layout
        message.url = components.url

        conversation.send(message) { error in
            if let error { print("[MessagesViewController] sendSettlementMessage error: \(error)") }
        }
    }

    func sendRequestMessage(creditorName: String, debtorName: String,
                            amountCents: Int, tabColorHex: String?) {
        guard let conversation = activeConversation else { return }

        let card = SettlementCardView(fromName: creditorName, toName: debtorName,
                                     amountCents: amountCents, methodName: "",
                                     tabColorHex: tabColorHex, isRequest: true)
        let cardImage = renderView(card, size: CGSize(width: 260, height: 60))
        let components = lootURLComponents(tab: uiModel.receiptTab ?? uiModel.activeTab)

        let layout = MSMessageTemplateLayout()
        layout.image = cardImage

        let message = MSMessage(session: MSSession())
        message.layout = layout
        message.url = components.url

        // Changed from insert to send directly
        //conversation.insert(message) { error in
        conversation.send(message) { error in
            if let error { print("[MessagesViewController] sendRequestMessage error: \(error)") }
        }
        requestPresentationStyle(.compact)
    }

    func renderCardImage(receiptName: String,
                         displayAmount: String,
                         participantCount: Int,
                         splitPayload: SplitPayload,
                         tabName: String? = nil,
                         tabColorHex: String? = nil) -> UIImage {

        // Extract owed amounts for ring display (all guests, excluded get 0 to preserve color slots)
        let owedAmounts: [Int] = splitPayload.g.indices.map { idx in
            splitPayload.g[idx].inc && splitPayload.o.indices.contains(idx) ? max(0, splitPayload.o[idx]) : 0
        }

        let card = BillCardView(
            receiptName: receiptName,
            displayAmount: displayAmount,
            displayName: myDisplayNameFromDefaults(),
            splitLabel: splitLabelFromMode(splitPayload.m),
            owedAmounts: owedAmounts.isEmpty ? nil : owedAmounts,  // Only pass if non-empty
            totalCents: splitPayload.tot,
            tabName: tabName,
            tabColorHex: tabColorHex
        )

        return renderView(card, size: CGSize(width: 250, height: 150))
    }
    
    private func splitLabelFromMode(_ mode: SplitPayload.Mode) -> String {
        switch mode {
        case .byItems: return "Split by items"
        case .custom: return "Custom split"
        case .equally: return "Split evenly"
        }
    }

    func sendBillMessage(receiptName: String,
                         amount: String,
                         participantCount: Int) {
        guard let conversation = activeConversation else { return }

        // Build a "portable" receipt + split payload
        let fallbackTotalCents = stringToCents(amount)
        let receiptDisplay = uiModel.currentReceipt ?? ReceiptDisplay(
            id: UUID().uuidString,
            title: receiptName.isEmpty ? "New Receipt" : receiptName,
            createdAt: Date(),
            subtotalCents: fallbackTotalCents,
            feesCents: 0,
            taxCents: 0,
            tipCents: 0,
            discountCents: 0,
            totalCents: fallbackTotalCents,
            items: []
        )

        let draft = uiModel.currentSplitDraft
        let splitPayload = SplitPayload.from(draft: draft,
                                             participantCount: participantCount,
                                             totalCents: receiptDisplay.totalCents)

        let receiptPayload = ReceiptPayload.from(receipt: receiptDisplay, split: splitPayload)

        var payload = LootMessagePayload(r: receiptPayload, s: splitPayload, tid: uiModel.activeTab?.id)
        if let activeTab = uiModel.activeTab, let tabId = activeTab.id {
            payload.tab = TabPayload(id: tabId, n: activeTab.name, c: activeTab.colorHex)
        }

        // Capture scan image before async block (will be nil for manual receipts)
        let captureImage = uiModel.scanImageCropped ?? uiModel.scanImageOriginal

        // Render card image synchronously (before async block)
        let cardImage = renderCardImage(
            receiptName: receiptDisplay.title,
            displayAmount: ReceiptDisplay.money(receiptDisplay.totalCents),
            participantCount: participantCount,
            splitPayload: splitPayload,
            tabName: uiModel.activeTab?.name,
            tabColorHex: uiModel.activeTab?.colorHex
        )

        // Pre-generate a Firestore doc ID (local, no network)
        let docId = SharedReceiptService.shared.generateDocId()

        var components = lootURLComponents()
        components.queryItems = [URLQueryItem(name: "id", value: docId)]
        // Embed the full payload inline (compressed) so the card is readable
        // even if the Firestore upload never completes (e.g. no internet at send time).
        LootMessageCodec.writePayload(into: &components, payload: payload)

        let layout = MSMessageTemplateLayout()
        layout.image = cardImage

        let message = MSMessage(session: MSSession())
        message.layout = layout
        message.url = components.url

        // Changed from insert to send directly
        //conversation.insert(message) { error in
        conversation.send(message) { error in
            if let error { print("Error inserting message: \(error)") }
        }

        requestPresentationStyle(.compact)

        // Upload to Firestore in the background, then add to tab if applicable
        Task {
            do {
                try await SharedReceiptService.shared.upload(payload, captureImage: captureImage, docId: docId)
                print("[sendBillMessage] Uploaded to Firestore: \(docId)")

                // If this receipt belongs to a tab, create a TabReceipt and update balances
                if let tabId = payload.tid, let activeTab = uiModel.activeTab {
                    let tabReceipt = TabReceipt.from(payload: payload, messagePayloadId: docId, tab: activeTab)
                    let trid = try await TabService.shared.addReceipt(tabReceipt, toTab: tabId)

                    // Update the shared receipt with trid
                    var updated = payload
                    updated.trid = trid
                    try await SharedReceiptService.shared.updatePayload(updated, docId: docId)

                    // Refresh cached tab
                    if let refreshed = try await TabService.shared.fetchTab(id: tabId) {
                        await MainActor.run {
                            self.uiModel.activeTab = refreshed
                        }
                        if let ck = self.uiModel.conversationKey {
                            TabService.shared.cacheTab(refreshed, for: ck)
                        }
                    }
                    print("[sendBillMessage] TabReceipt added: \(trid)")
                }
            } catch {
                print("[sendBillMessage] Firestore upload failed: \(error)")
            }
        }
    }

    func sendTabInvite(tabName: String, tabColorHex: String, tabId: String) {
        guard let conversation = activeConversation else { return }

        // Render invite card image
        let card = TabInviteCardView(
            tabName: tabName,
            tabColorHex: tabColorHex,
            creatorName: myDisplayNameFromDefaults()
        )
        let cardImage = renderView(card, size: CGSize(width: 250, height: 150))

        var components = lootURLComponents()
        components.queryItems = [URLQueryItem(name: "tabInvite", value: tabId)]

        let layout = MSMessageTemplateLayout()
        layout.image = cardImage

        let message = MSMessage(session: MSSession())
        message.layout = layout
        message.url = components.url

        // Changed from insert to send directly
        //conversation.insert(message) { error in
        conversation.send(message) { error in
            if let error { print("Error inserting tab invite: \(error)") }
        }

        requestPresentationStyle(.compact)
    }

}

// MARK: - Payload -> ReceiptDisplay (✅ UPDATED for new field names)

extension LootMessagePayload {
    func toReceiptDisplay() -> ReceiptDisplay {
        let receiptData = r
        let splitData = s
        
        let items: [ReceiptDisplay.Item] = receiptData.i.map { it in
            let responsible: [ReceiptDisplay.Responsible] = it.rs.map { slot in
                let nm: String = {
                    guard splitData.g.indices.contains(slot) else { return "Guest \(slot + 1)" }
                    let g = splitData.g[slot]
                    let t = g.n.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { return t }
                    return g.uid == KeychainHelper.getOrCreateUserId() ? "Me" : "Guest \(slot + 1)"
                }()
                return ReceiptDisplay.Responsible(slotIndex: slot, displayName: nm)
            }
            .sorted(by: { $0.slotIndex < $1.slotIndex })

            return ReceiptDisplay.Item(
                id: it.id,
                label: it.l,
                priceCents: it.p,
                responsible: responsible
            )
        }

        return ReceiptDisplay(
            id: receiptData.id,
            title: receiptData.t,
            createdAt: Date(timeIntervalSince1970: receiptData.c),
            subtotalCents: receiptData.sub,
            feesCents: receiptData.f,
            taxCents: receiptData.tx,
            tipCents: receiptData.tip,
            discountCents: receiptData.d,
            totalCents: receiptData.tot,
            items: items
        )
    }
}

// MARK: - Build SplitPayload / ReceiptPayload

private extension SplitPayload {
    static func from(draft: SplitDraft?, participantCount: Int, totalCents: Int) -> SplitPayload {
        // Seed guests if no draft
        let guests: [Guest] = {
            if let d = draft, !d.guests.isEmpty {
                return d.guests.map { Guest(n: $0.name, inc: $0.isIncluded, uid: $0.uid) }
            }
            // default: me + N-1 unnamed
            var out: [Guest] = [Guest(n: myDisplayNameFromDefaults(), inc: true, uid: KeychainHelper.getOrCreateUserId())]
            if participantCount > 1 {
                for _ in 1..<participantCount {
                    out.append(Guest(n: "", inc: true, uid: nil))
                }
            }
            return out
        }()

        let payerIndex: Int = {
            guard let d = draft else { return 0 }
            return d.guests.firstIndex(where: { $0.id == d.payerGuestId }) ?? 0
        }()

        let mode: Mode = {
            guard let d = draft else { return .equally }
            switch d.mode {
            case .equally: return .equally
            case .custom: return .custom
            case .byItems: return .byItems
            }
        }()

        let fees = draft?.feesCents ?? 0
        let tax = draft?.taxCents ?? 0
        let tip = draft?.tipCents ?? 0
        let discount = draft?.discountCents ?? 0

        // ✅ Convert draft items to tuples for SplitMath (no longer creating SplitPayload.Item array)
        let itemsForMath: [(label: String, priceCents: Int, assignedSlots: [Int])] = {
            guard let d = draft, d.mode == .byItems else { return [] }
            let slotIndexByUUID: [UUID: Int] = Dictionary(uniqueKeysWithValues:
                d.guests.enumerated().map { ($0.element.id, $0.offset) })
            return d.items.map { it in
                let slots = it.assignedGuestIds.compactMap { slotIndexByUUID[$0] }.sorted()
                return (label: it.label, priceCents: it.priceCents, assignedSlots: slots)
            }
        }()

        // Compute owed (always) and force sum to total by adjusting payer
        let owed = SplitMath.computeOwedCents(
            mode: mode,
            guests: guests,
            payerIndex: payerIndex,
            totalCents: totalCents,
            perGuestActive: draft?.perGuestCents,
            items: itemsForMath,
            feesCents: fees,
            taxCents: tax,
            tipCents: tip,
            discountCents: discount
        )

        return SplitPayload(
            m: mode,
            g: guests,
            pi: payerIndex,
            o: owed,
            f: fees == 0 ? nil : fees,
            tx: tax == 0 ? nil : tax,
            tip: tip == 0 ? nil : tip,
            d: discount == 0 ? nil : discount,
            tot: totalCents
        )
    }
}

private extension ReceiptPayload {
    static func from(receipt: ReceiptDisplay, split: SplitPayload) -> ReceiptPayload {
        let isByItems = (split.m == .byItems)

        let items: [ReceiptItemPayload] = {
            // ✅ Always use receipt items, add assignments for by-items mode
            return receipt.items.map { it in
                let slots = isByItems ? it.responsible.map { $0.slotIndex }.sorted() : []
                return ReceiptItemPayload(
                    id: it.id,
                    l: it.label,
                    p: it.priceCents,
                    rs: slots
                )
            }
        }()

        return ReceiptPayload(
            id: receipt.id,
            t: receipt.title,
            c: receipt.createdAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970,
            sub: receipt.subtotalCents,
            f: receipt.feesCents,
            tx: receipt.taxCents,
            tip: receipt.tipCents,
            d: receipt.discountCents,
            tot: receipt.totalCents,
            i: items
        )
    }
}

// MARK: - Math (equal/custom/by-items) with stable cents (✅ UPDATED signature)

enum SplitMath {
    static func computeOwedCents(
        mode: SplitPayload.Mode,
        guests: [SplitPayload.Guest],
        payerIndex: Int,
        totalCents: Int,
        perGuestActive: [Int]?,
        items: [(label: String, priceCents: Int, assignedSlots: [Int])],  // ✅ Changed from [SplitPayload.Item]
        feesCents: Int,
        taxCents: Int,
        tipCents: Int,
        discountCents: Int
    ) -> [Int] {

        let included = guests.indices.filter { guests[$0].inc }  // ✅ Changed from .included
        guard !included.isEmpty else { return Array(repeating: 0, count: guests.count) }

        let safePayer = included.contains(payerIndex) ? payerIndex : (included.first ?? 0)

        func clampToTotal(_ owed: inout [Int]) {
            var sum = owed.reduce(0, +)
            let diff = totalCents - sum
            if diff != 0, owed.indices.contains(safePayer) {
                owed[safePayer] = max(0, owed[safePayer] + diff)
                sum = owed.reduce(0, +)
            }
            // still mismatched? (shouldn't happen, but keep safe)
            if sum != totalCents, let first = included.first {
                owed[first] = max(0, owed[first] + (totalCents - sum))
            }
        }

        // Start with all zeros for full guest list
        var owed = Array(repeating: 0, count: guests.count)

        switch mode {
        case .equally:
            let shares = splitEvenly(total: totalCents, count: included.count)
            for (i, idx) in included.enumerated() { owed[idx] = shares[i] }
            clampToTotal(&owed)
            return owed

        case .custom:
            // custom comes as active-only in your app; map in order of included guests
            if let perGuestActive, perGuestActive.count == included.count {
                for (i, idx) in included.enumerated() { owed[idx] = max(0, perGuestActive[i]) }
            } else {
                let shares = splitEvenly(total: totalCents, count: included.count)
                for (i, idx) in included.enumerated() { owed[idx] = shares[i] }
            }
            clampToTotal(&owed)
            return owed

        case .byItems:
            // 1) subtotal from items (split shared items evenly among assigned)
            var subtotals = Array(repeating: 0, count: guests.count)

            for it in items {
                let assigned = it.assignedSlots.filter { guests.indices.contains($0) && guests[$0].inc }
                let targets = assigned.isEmpty ? [safePayer] : assigned.sorted()
                let parts = splitEvenly(total: max(0, it.priceCents), count: targets.count)
                for (i, gidx) in targets.enumerated() { subtotals[gidx] += parts[i] }
            }

            // 2) allocate extras (fees+tax+tip-discount) proportional to subtotal (or evenly if subtotal=0)
            let extras = max(0, feesCents) + max(0, taxCents) + max(0, tipCents) - max(0, discountCents)
            let extrasAlloc = allocateProportional(total: extras, base: subtotals, included: included)

            for idx in included {
                owed[idx] = max(0, subtotals[idx] + extrasAlloc[idx])
            }

            clampToTotal(&owed)
            return owed
        }
    }

    private static func splitEvenly(total: Int, count: Int) -> [Int] {
        guard total > 0, count > 0 else { return Array(repeating: 0, count: max(0, count)) }
        var out = Array(repeating: total / count, count: count)
        let remainder = total - out.reduce(0, +)
        if remainder > 0 {
            for i in 0..<min(remainder, count) { out[i] += 1 }
        }
        return out
    }

    private static func allocateProportional(total: Int, base: [Int], included: [Int]) -> [Int] {
        var out = Array(repeating: 0, count: base.count)
        guard total != 0 else { return out }

        let sumBase = included.reduce(0) { $0 + max(0, base[$1]) }
        if sumBase <= 0 {
            // evenly across included
            let shares = splitEvenly(total: total, count: included.count)
            for (i, idx) in included.enumerated() { out[idx] = shares[i] }
            return out
        }

        // proportional with remainder distribution by fractional part
        var floors: [Int] = []
        var fracs: [(idx: Int, frac: Double)] = []

        var used = 0
        for idx in included {
            let b = Double(max(0, base[idx]))
            let raw = (Double(total) * b) / Double(sumBase)
            let f = Int(floor(raw))
            floors.append(f)
            used += f
            fracs.append((idx: idx, frac: raw - Double(f)))
        }

        for (i, idx) in included.enumerated() {
            out[idx] = floors[i]
        }

        var rem = total - used
        if rem > 0 {
            fracs.sort { $0.frac > $1.frac }
            var j = 0
            while rem > 0 && !fracs.isEmpty {
                out[fracs[j % fracs.count].idx] += 1
                rem -= 1
                j += 1
            }
        }
        return out
    }
}

