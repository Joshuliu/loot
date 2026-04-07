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
    // Lazy so transcript bubble instances never allocate these
    private lazy var uiModel = LootUIModel()
    private lazy var hostingController = UIHostingController(rootView: RootContainerView(uiModel: uiModel))
    private var hasSetupRootView = false
    private var isTranscript = false

    override func viewDidLoad() {
        super.viewDidLoad()

        // Transcript bubbles get a lightweight render path — no Firebase, no auth.
        if presentationContext == .media || presentationStyle == .transcript {
            isTranscript = true
            configureAsTranscript()
            return
        }

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

        uiModel.sendRequestCard = { [weak self] creditorName, debtorName, amountCents, tabColorHex, metadata in
            self?.sendRequestMessage(creditorName: creditorName, debtorName: debtorName,
                                     amountCents: amountCents, tabColorHex: tabColorHex,
                                     metadata: metadata)
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

        // Transcript bubbles: render lightweight UIKit card and bail
        if isTranscript {
            renderTranscriptBubble(from: conversation)
            return
        }

        applyMessage(conversation.selectedMessage, conversation: conversation)
        setupRootView(conversation: conversation)
    }

    override func contentSizeThatFits(_ size: CGSize) -> CGSize {
        if isTranscript { return CGSize(width: min(size.width, 260), height: 160) }
        return super.contentSizeThatFits(size)
    }

    override func didTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.didTransition(to: presentationStyle)
        guard !isTranscript else { return }
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
        guard !isTranscript else { return }
        // Use the message parameter directly, not conversation.selectedMessage
        applyMessage(message, conversation: conversation)
    }

    private func setActiveTabIfChanged(_ tab: LootTab?) {
        let currentId = uiModel.activeTab?.id
        let newId = tab?.id

        if currentId == newId {
            if currentId == nil, uiModel.activeTab == nil, tab == nil { return }
            if let current = uiModel.activeTab, let tab,
               current.name == tab.name,
               current.colorHex == tab.colorHex,
               current.memberIds == tab.memberIds,
               current.receiptCount == tab.receiptCount,
               current.status.rawValue == tab.status.rawValue {
                return
            }
        }

        uiModel.activeTab = tab
    }

    // MARK: - Transcript (lightweight UIKit-only path)

    @objc private func transcriptTapped() {
        requestPresentationStyle(.expanded)
    }

    private func configureAsTranscript() {
        view.isOpaque = false
        view.backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: self, action: #selector(transcriptTapped))
        view.addGestureRecognizer(tap)
    }

    private func renderTranscriptBubble(from conversation: MSConversation) {
        // Remove any previous bubble (willBecomeActive can fire multiple times)
        view.subviews.forEach { $0.removeFromSuperview() }
        children.forEach { $0.removeFromParent() }

        guard let msg = conversation.selectedMessage, let url = msg.url else {
            embedTranscriptCard(AnyView(Text("Loot").font(.headline).foregroundColor(.white)))
            return
        }

        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)

        // Bill card — extract full payload for a 1:1 BillCardView
        if let payload = LootMessageCodec.payload(from: url) {
            let split = payload.s
            let owedAmounts: [Int] = split.g.indices.map { idx in
                split.g[idx].inc && split.o.indices.contains(idx) ? max(0, split.o[idx]) : 0
            }
            let splitLabel: String = {
                switch split.m {
                case .byItems: return "Split by items"
                case .custom: return "Custom split"
                case .equally: return "Split evenly"
                }
            }()
            let senderName: String = {
                if let pi = split.g.indices.contains(split.pi) ? split.g[split.pi].n : nil,
                   !pi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return pi
                }
                return myDisplayNameFromDefaults()
            }()

            // Find the viewer's slot to highlight + pulse
            let myUid = KeychainHelper.getOrCreateUserId()
            let mySlot: Int? = split.g.firstIndex(where: { $0.uid == myUid })
            let myOwed: String? = {
                guard let slot = mySlot, owedAmounts.indices.contains(slot), owedAmounts[slot] > 0 else { return nil }
                return ReceiptDisplay.money(owedAmounts[slot])
            }()

            let card = BillCardView(
                receiptName: payload.r.t,
                displayAmount: myOwed ?? ReceiptDisplay.money(payload.r.tot),
                displayName: senderName,
                splitLabel: splitLabel,
                owedAmounts: owedAmounts.isEmpty ? nil : owedAmounts,
                totalCents: split.tot,
                tabName: payload.tab?.n,
                tabColorHex: payload.tab?.c,
                centerTopLabel: mySlot != nil ? "You spent" : nil,
                highlightedSlot: mySlot
            )
            embedTranscriptCard(AnyView(card))
            return
        }

        // Tab invite card
        if let tabId = comps?.queryItems?.first(where: { $0.name == "tabInvite" })?.value,
           !tabId.isEmpty {
            let tabName = comps?.queryItems?.first(where: { $0.name == "tn" })?.value ?? "Tab"
            let tabColorHex = comps?.queryItems?.first(where: { $0.name == "tc" })?.value
            let card = TabInviteCardView(
                tabName: tabName,
                tabColorHex: tabColorHex ?? "#007AFF",
                creatorName: "",
                joinedCount: 0,
                targetCount: 0
            )
            embedTranscriptCard(AnyView(card))
            return
        }

        // Settlement / request card
        if comps?.queryItems?.contains(where: { $0.name == "tabId" }) == true {
            let tabColorHex = comps?.queryItems?.first(where: { $0.name == "tc" })?.value
            let isRequest = comps?.queryItems?.contains(where: { $0.name == "rq" && $0.value == "1" }) == true
            let creditorName = comps?.queryItems?.first(where: { $0.name == "cn" })?.value ?? ""
            let debtorName = comps?.queryItems?.first(where: { $0.name == "dn" })?.value ?? ""
            let amountCents = Int(comps?.queryItems?.first(where: { $0.name == "amt" })?.value ?? "") ?? 0

            if isRequest || amountCents > 0 {
                let card = SettlementCardView(
                    fromName: creditorName,
                    toName: debtorName,
                    amountCents: amountCents,
                    methodName: "",
                    tabColorHex: tabColorHex,
                    isRequest: isRequest
                )
                embedTranscriptCard(AnyView(card))
                return
            }
        }

        // Fallback
        embedTranscriptCard(AnyView(Text("Loot").font(.headline).foregroundColor(.white)))
    }

    private func embedTranscriptCard(_ cardView: AnyView) {
        let host = UIHostingController(rootView: cardView)
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }
}

// MARK: - Card render + sending (no backend, no storage)

extension MessagesViewController {

    private func applyMessage(_ message: MSMessage?, conversation: MSConversation) {
        // expansion state
        uiModel.isExpanded = (presentationStyle == .expanded)

        guard let msg = message, let url = msg.url else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let pendingRequest = pendingPayRequest(from: comps)
        uiModel.pendingPayRequest = pendingRequest
        if pendingRequest != nil {
            requestPresentationStyle(.expanded)
        }

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
                setActiveTabIfChanged(
                    LootTab.minimal(id: tabId, name: tabName,
                                    colorHex: colorHex?.isEmpty == true ? nil : colorHex)
                )
            }
            // Try to upgrade with full tab data in background
            Task { @MainActor in
                if let cached = uiModel.userTabs.first(where: { $0.id == tabId }) {
                    setActiveTabIfChanged(cached)
                } else if let full = try? await TabService.shared.fetchTab(id: tabId) {
                    setActiveTabIfChanged(full)
                }
            }
            uiModel.currentScreen = .tabview
            return
        }

        // Legacy path: inline payload
        if let payload = LootMessageCodec.payload(from: url) {
            uiModel.openedMessagePayload = payload
            uiModel.openedMessageDocId = payload.r.id
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
                setActiveTabIfChanged(cached)
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
                setActiveTabIfChanged(tab)
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
                setActiveTabIfChanged(TabService.shared.cachedTab(for: convKey))
            }

            Task { @MainActor in
                // Only restore the conversation's tab if we're not in the middle
                // of a join flow — otherwise this would overwrite the tab the user
                // is about to join / just joined.
                if uiModel.currentScreen != .joinTab {
                    let myId = KeychainHelper.getOrCreateUserId()
                    do {
                        let tab = try await TabService.shared.getTabForConversation(conversationKey: convKey)

                        // Store conversation member IDs for tab relevance sorting,
                        // regardless of whether the current user is still a member.
                        if let t = tab {
                            uiModel.conversationMemberIds = Set(t.memberIds)
                        } else {
                            uiModel.conversationMemberIds = []
                        }

                        // Only set as active if this user is still an active member
                        // (guards against tabs the user has left).
                        if let t = tab, t.memberIds.contains(myId) {
                            setActiveTabIfChanged(t)
                            TabService.shared.cacheTab(t, for: convKey)
                        } else {
                            setActiveTabIfChanged(nil)
                            TabService.shared.cacheTab(nil, for: convKey)
                        }
                    } catch {
                        // Keep the cached tab on transient lookup failures instead of
                        // silently disassociating the conversation.
                        print("[setupRootView] getTabForConversation failed: \(error)")
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
                            amountCents: Int, tabColorHex: String?,
                            metadata: RequestCardMetadata?) {
        guard let conversation = activeConversation else { return }

        let card = SettlementCardView(fromName: creditorName, toName: debtorName,
                                     amountCents: amountCents, methodName: "",
                                     tabColorHex: tabColorHex, isRequest: true)
        let cardImage = renderView(card, size: CGSize(width: 260, height: 60))
        var components = lootURLComponents(tab: uiModel.receiptTab ?? uiModel.activeTab)
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "rq", value: "1"))
        items.append(URLQueryItem(name: "cn", value: creditorName))
        items.append(URLQueryItem(name: "dn", value: debtorName))
        items.append(URLQueryItem(name: "amt", value: String(amountCents)))
        if let receiptDocId = metadata?.receiptDocId, !receiptDocId.isEmpty {
            items.append(URLQueryItem(name: "id", value: receiptDocId))
            items.append(URLQueryItem(name: "rd", value: receiptDocId))
        }
        if let creditorId = metadata?.creditorId, !creditorId.isEmpty {
            items.append(URLQueryItem(name: "cid", value: creditorId))
        }
        if let debtorId = metadata?.debtorId, !debtorId.isEmpty {
            items.append(URLQueryItem(name: "did", value: debtorId))
        }
        components.queryItems = items

        let layout = MSMessageTemplateLayout()
        layout.image = cardImage

        let message = MSMessage(session: MSSession())
        message.layout = layout
        message.url = components.url

        conversation.send(message) { error in
            if let error { print("[MessagesViewController] sendRequestMessage error: \(error)") }
        }
        requestPresentationStyle(.compact)
    }

    private func pendingPayRequest(from comps: URLComponents?) -> PendingPayRequest? {
        guard let comps,
              comps.queryItems?.contains(where: { $0.name == "rq" && $0.value == "1" }) == true
        else { return nil }

        let myUid = KeychainHelper.getOrCreateUserId()
        let debtorId = comps.queryItems?.first(where: { $0.name == "did" })?.value
        if let debtorId, !debtorId.isEmpty, debtorId != myUid {
            return nil
        }

        return PendingPayRequest(
            receiptDocId: comps.queryItems?.first(where: { $0.name == "rd" })?.value,
            tabId: comps.queryItems?.first(where: { $0.name == "tabId" })?.value,
            creditorId: comps.queryItems?.first(where: { $0.name == "cid" })?.value,
            debtorId: debtorId,
            creditorName: comps.queryItems?.first(where: { $0.name == "cn" })?.value ?? "Requester",
            debtorName: comps.queryItems?.first(where: { $0.name == "dn" })?.value ?? "You",
            amountCents: Int(comps.queryItems?.first(where: { $0.name == "amt" })?.value ?? "") ?? 0
        )
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
            totalCents: fallbackTotalCents,
            items: []
        )

        let draft = uiModel.currentSplitDraft
        let splitPayload = SplitPayload.from(draft: draft,
                                             participantCount: participantCount,
                                             totalCents: receiptDisplay.totalCents)

        let receiptPayload = ReceiptPayload.from(receipt: receiptDisplay, split: splitPayload)

        var payload = LootMessagePayload(r: receiptPayload, s: splitPayload, tid: uiModel.activeTab?.id, su: KeychainHelper.getOrCreateUserId())
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

        let alternateLayout = MSMessageTemplateLayout()
        alternateLayout.image = cardImage

        let layout = MSMessageLiveLayout(alternateLayout: alternateLayout)

        let message = MSMessage(session: MSSession())
        message.layout = layout
        message.url = components.url

        conversation.send(message) { error in
            if let error { print("Error inserting message: \(error)") }
        }

        requestPresentationStyle(.compact)

        // Upload to Firestore in the background, then add to tab if applicable
        Task {
            do {
                try await SharedReceiptService.shared.upload(payload, captureImage: captureImage, docId: docId)
                print("[sendBillMessage] Uploaded to Firestore: \(docId)")

                // If this receipt belongs to a tab, recompute its derived aggregates.
                if let tabId = payload.tid {
                    // Refresh cached tab from the single-source sharedReceipts model.
                    if let refreshed = try await TabService.shared.syncTabDerivedState(tabId: tabId) {
                        await MainActor.run {
                            self.uiModel.activeTab = refreshed
                        }
                        if let ck = self.uiModel.conversationKey {
                            TabService.shared.cacheTab(refreshed, for: ck)
                        }
                    }
                    print("[sendBillMessage] Synced tab aggregates for \(tabId)")
                }
            } catch {
                print("[sendBillMessage] Firestore upload failed: \(error)")
            }
        }
    }

    func sendTabInvite(tabName: String, tabColorHex: String, tabId: String) {
        guard let conversation = activeConversation else { return }

        // Render invite card image
        let joinedCount = max(1, uiModel.activeTab?.members.filter(\.isActive).count ?? 1)
        let targetCount = max(1, (activeConversation?.remoteParticipantIdentifiers.count ?? 0) + 1)
        let card = TabInviteCardView(
            tabName: tabName,
            tabColorHex: tabColorHex,
            creatorName: myDisplayNameFromDefaults(),
            joinedCount: joinedCount,
            targetCount: targetCount
        )
        let cardImage = renderView(card, size: CGSize(width: 250, height: 150))

        var components = lootURLComponents()
        components.queryItems = [URLQueryItem(name: "tabInvite", value: tabId)]

        let layout = MSMessageTemplateLayout()
        layout.image = cardImage

        let message = MSMessage(session: MSSession())
        message.layout = layout
        message.url = components.url

        conversation.send(message) { error in
            if let error { print("Error inserting tab invite: \(error)") }
        }

        requestPresentationStyle(.compact)
    }

}
